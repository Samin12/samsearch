//! Optional Mac file search. Spotlight owns the index; only paths and names
//! are read here. Explicit paths use a parent directory listing instead.
const std = @import("std");
const search = @import("search.zig");
const mac = @import("builtin").os.tag == .macos;

pub const enabled_key = "nanolight.files";
pub const locations_key = "nanolight.files.locations";
pub const exclusions_key = "nanolight.files.exclusions";
pub const max_rows = 5;
pub const max_path = 4096;

pub const Entry = struct {
    bytes: [max_path]u8 = undefined,
    len: usize = 0,
    folder: bool = false,
    match: search.Match = .{ .score = 0 },
    png: []u8 = &.{},

    pub fn path(e: *const Entry) []const u8 {
        return e.bytes[0..e.len];
    }

    pub fn name(e: *const Entry) []const u8 {
        const p = e.path();
        return if (std.mem.eql(u8, p, "/")) p else std.fs.path.basename(p);
    }
};

pub const List = struct {
    /// Owns every entry icon; a list must be moved, never copied.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    entries: [max_rows]Entry = undefined,
    n: usize = 0,
    exact: bool = false,

    pub fn deinit(l: *List) void {
        for (l.entries[0..l.n]) |e| l.allocator.free(e.png);
        l.n = 0;
        l.exact = false;
    }

    /// Transfer ownership, leaving the source safe to destroy on the main thread.
    pub fn replace(l: *List, source: *List) void {
        std.debug.assert(l != source);
        l.deinit();
        l.* = source.*;
        source.n = 0;
        source.exact = false;
    }

    pub fn add(l: *List, path: []const u8, folder: bool, m: search.Match) void {
        if (path.len == 0 or path.len >= max_path) return;
        for (l.entries[0..l.n]) |*e| if (std.mem.eql(u8, e.path(), path)) return;
        var at: usize = 0;
        while (at < l.n and l.entries[at].match.score >= m.score) : (at += 1) {}
        if (at == max_rows) return;
        if (l.n == max_rows) l.allocator.free(l.entries[max_rows - 1].png);
        var i = @min(l.n, max_rows - 1);
        while (i > at) : (i -= 1) l.entries[i] = l.entries[i - 1];
        l.entries[at] = .{ .len = path.len, .folder = folder, .match = m };
        @memcpy(l.entries[at].bytes[0..path.len], path);
        l.n = @min(l.n + 1, max_rows);
    }

    /// Keep the last answer's matching rows while a new answer is on its way.
    pub fn filter(l: *List, query: []const u8) void {
        var expanded: [max_path]u8 = undefined;
        const path = if (isPath(query)) expand(&expanded, query) else null;
        const clean = if (path) |p| (if (p.len > 1) std.mem.trimEnd(u8, p, "/") else p) else "";
        const old_n = l.n;
        var n: usize = 0;
        l.exact = false;
        for (0..old_n) |i| {
            const e = &l.entries[i];
            var keep = false;
            defer if (!keep) l.allocator.free(e.png);
            const m = if (path) |p| blk: {
                if (std.mem.eql(u8, e.path(), clean)) {
                    l.exact = true;
                    break :blk search.Match{ .score = 2000 };
                }
                const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse continue;
                const dir = if (slash == 0) "/" else p[0..slash];
                if (!std.mem.eql(u8, std.fs.path.dirname(e.path()) orelse "/", dir)) continue;
                const prefix = p[slash + 1 ..];
                if (!std.ascii.startsWithIgnoreCase(e.name(), prefix)) continue;
                if (e.name()[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
                break :blk search.score(prefix, e.name()) orelse search.Match{ .score = 1 };
            } else if (isPath(query)) continue else search.score(query, e.name()) orelse continue;
            keep = true;
            l.entries[n] = e.*;
            l.entries[n].match = m;
            n += 1;
        }
        l.n = n;
        std.sort.insertion(Entry, l.entries[0..n], {}, struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                return a.match.score > b.match.score;
            }
        }.before);
    }

    /// Finder icons are prepared off the UI thread along with the answer.
    pub fn icons(l: *List) void {
        if (!mac) return;
        for (l.entries[0..l.n]) |*e| {
            const png = @import("apps.zig").iconPng(l.allocator, e.path()) orelse continue;
            l.allocator.free(e.png);
            e.png = png;
        }
    }
};

pub fn isPath(q: []const u8) bool {
    return q.len > 0 and (q[0] == '/' or q[0] == '~');
}

pub fn eligible(q: []const u8) bool {
    if (!mac or q.len < 2 or q.len > 256 or isPath(q)) return false;
    for (q) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn home() []const u8 {
    if (!mac) return "";
    return if (std.c.getenv("HOME")) |p| std.mem.span(p) else "";
}

pub fn expand(buf: []u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "~")) return path;
    if (path.len > 1 and path[1] != '/') return null;
    const h = home();
    if (h.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ h, path[1..] }) catch null;
}

pub fn parent(buf: []u8, path: []const u8) []const u8 {
    const p = std.fs.path.dirname(path) orelse "/";
    const h = home();
    if (h.len > 0 and within(p, h)) return std.fmt.bufPrint(buf, "~{s}", .{p[h.len..]}) catch p;
    return p;
}

/// Existing paths lead; partial paths list a handful of matching siblings.
pub fn complete(io: std.Io, query: []const u8, out: *List) void {
    out.deinit();
    if (!mac or !isPath(query)) return;
    var expanded: [max_path]u8 = undefined;
    const path = expand(&expanded, query) orelse return;
    const clean = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    if (std.Io.Dir.cwd().statFile(io, clean, .{})) |st| {
        out.add(clean, st.kind == .directory, .{ .score = 2000 });
        out.exact = true;
        if (!std.mem.endsWith(u8, path, "/")) return;
    } else |_| {}
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    const dir_path = if (slash == 0) "/" else path[0..slash];
    const prefix = path[slash + 1 ..];
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var buf: [max_path]u8 = undefined;
    // Bound work even in very large directories. No recursive crawl.
    var seen: usize = 0;
    while (seen < 2048) : (seen += 1) {
        const e = (it.next(io) catch null) orelse break;
        if (e.name.len == 0 or (e.name[0] == '.' and (prefix.len == 0 or prefix[0] != '.'))) continue;
        if (!std.ascii.startsWithIgnoreCase(e.name, prefix)) continue;
        const full = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir_path, if (slash == 0) "" else "/", e.name }) catch continue;
        const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        out.add(full, st.kind == .directory, search.score(prefix, e.name) orelse .{ .score = 1 });
        if (out.n == max_rows) break;
    }
}

fn within(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or (std.mem.startsWith(u8, path, root) and (std.mem.endsWith(u8, root, "/") or (path.len > root.len and path[root.len] == '/')));
}

fn hasComponent(path: []const u8, component: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, path, from, component)) |i| {
        const end = i + component.len;
        if ((i == 0 or path[i - 1] == '/') and (end == path.len or path[end] == '/')) return true;
        from = i + 1;
    }
    return false;
}

pub fn excluded(path: []const u8, extra: []const u8) bool {
    var library_buf: [max_path]u8 = undefined;
    const h = home();
    if (h.len > 0) {
        const library = std.fmt.bufPrint(&library_buf, "{s}/Library", .{h}) catch return true;
        if (within(path, library)) return true;
    }
    for ([_][]const u8{ "node_modules", ".git", "Library/Caches", ".cache", ".Trash", ".zig-cache", "zig-cache", "zig-out" }) |part| {
        if (hasComponent(path, part)) return true;
    }
    var lines = std.mem.tokenizeScalar(u8, extra, '\n');
    var buf: [max_path]u8 = undefined;
    while (lines.next()) |line| {
        const p = expand(&buf, std.mem.trim(u8, line, " \r\t")) orelse continue;
        if (p.len == 0) continue;
        if (p[0] == '/') {
            if (within(path, std.mem.trimEnd(u8, p, "/"))) return true;
        } else if (hasComponent(path, p)) return true;
    }
    return false;
}

pub const Tier = enum { exact, prefix, word, subsequence };

/// Literal, case/diacritic-insensitive queries, never shell text.
pub fn predicate(buf: []u8, query: []const u8, tier: Tier) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("kMDItemFSName == \"") catch return null;
    w.writeAll(switch (tier) {
        .exact, .prefix => "",
        .word => "* ",
        .subsequence => "*",
    }) catch return null;
    var i: usize = 0;
    while (i < query.len) {
        const len = std.unicode.utf8ByteSequenceLength(query[i]) catch return null;
        if (i + len > query.len) return null;
        if (len == 1 and (query[i] == '"' or query[i] == '*' or query[i] == '\\' or query[i] == '?')) w.writeByte('\\') catch return null;
        w.writeAll(query[i..][0..len]) catch return null;
        if (tier == .subsequence) w.writeByte('*') catch return null;
        i += len;
    }
    if (tier == .prefix or tier == .word) w.writeByte('*') catch return null;
    w.writeAll("\"cd") catch return null;
    return w.buffered();
}

/// Bounded tiers share one two-second deadline and one ranked, deduplicated list.
pub fn find(io: std.Io, query: []const u8, locations: []const u8, extra: []const u8, out: *List) bool {
    out.deinit();
    if (!eligible(query)) return false;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(a, "/usr/bin/mdfind") catch return false;
    var lines = std.mem.tokenizeScalar(u8, if (std.mem.trim(u8, locations, " \r\n\t").len == 0) home() else locations, '\n');
    while (lines.next()) |line| {
        var buf: [max_path]u8 = undefined;
        const path = expand(&buf, std.mem.trim(u8, line, " \r\t")) orelse continue;
        if (path.len == 0 or path[0] != '/') continue;
        const owned = a.dupe(u8, path) catch return false;
        argv.appendSlice(a, &.{ "-onlyin", owned }) catch return false;
    }
    if (argv.items.len == 1) return false;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 2000;
    argv.append(a, "") catch return false;
    var ok = false;
    for ([_]Tier{ .exact, .prefix, .word, .subsequence }) |tier| {
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (now >= deadline) break;
        var pred_buf: [2048]u8 = undefined;
        argv.items[argv.items.len - 1] = predicate(&pred_buf, query, tier) orelse return false;
        ok = collect(io, argv.items, query, extra, out, @min(deadline, now + 500)) or ok;
    }
    return ok;
}

fn collect(io: std.Io, argv: []const []const u8, query: []const u8, extra: []const u8, out: *List, deadline: i64) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return false;
    defer child.kill(io);
    var read_buf: [8192]u8 = undefined;
    var path_buf: [max_path]u8 = undefined;
    var used: usize = 0;
    var count: usize = 0;
    var total: usize = 0;
    var oversized = false;
    // A wall-clock deadline also bounds a process that keeps producing output.
    while (count < 256 and total < 256 * max_path) {
        const remaining = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) break;
        var fds = [_]std.posix.pollfd{.{ .fd = child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if ((std.posix.poll(&fds, @intCast(@min(remaining, 20))) catch return false) == 0) continue;
        const n = std.c.read(child.stdout.?.handle, &read_buf, read_buf.len);
        if (n < 0) return false;
        if (n == 0) {
            if (used > 0 and !oversized) candidate(io, out, query, path_buf[0..used], extra);
            return true;
        }
        total += @intCast(n);
        for (read_buf[0..@intCast(n)]) |c| {
            if (c == '\n') {
                if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return count > 0;
                count += 1;
                if (!oversized) candidate(io, out, query, path_buf[0..used], extra);
                used = 0;
                oversized = false;
                if (count == 256) return true;
            } else if (used < path_buf.len) {
                path_buf[used] = c;
                used += 1;
            } else oversized = true;
        }
    }
    return count > 0;
}

fn candidate(io: std.Io, out: *List, query: []const u8, path: []const u8, extra: []const u8) void {
    if (path.len == 0 or path[0] != '/' or excluded(path, extra)) return;
    for (out.entries[0..out.n]) |*e| if (std.mem.eql(u8, e.path(), path)) return;
    // Spotlight also folds diacritics, which the ASCII matcher does not.
    // Keep those matches below the tiers it can score and highlight.
    const m = search.score(query, std.fs.path.basename(path)) orelse search.Match{ .score = 0 };
    if (out.n == max_rows and m.score <= out.entries[out.n - 1].match.score) return;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
    out.add(path, st.kind == .directory, m);
}
