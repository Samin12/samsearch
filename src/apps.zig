//! The apps Nanolight finds: on the Mac every `.app` in the usual folders
//! (and one folder down, for Utilities and suites), named without `.app`;
//! on Linux the desktop entries (apps_linux.zig), on Windows the Start
//! menu's shortcuts (apps_win.zig). Sorted and without duplicates. How often each was opened is kept in the
//! app's defaults and lifts it in the ranking. Icons are asked of the
//! system only for the rows on screen, and kept.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const mac = builtin.os.tag == .macos;
const objc = nanoui.objc;

pub const App = struct {
    name: []const u8,
    path: []const u8,
    /// The folder it is in, as the row shows it: "Applications", "Utilities".
    folder: []const u8,
    /// Mandarin reading as ASCII (scan time), for Latin queries.
    pinyin: []const u8 = "",
};

/// Where apps are, in the order a name is first taken from.
pub const roots = [_][]const u8{
    "/Applications",
    "/System/Applications",
    "/System/Library/CoreServices/Applications",
};

/// Shown with an empty query before anything was opened.
pub const default_starters: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "Safari", "Notes", "Calendar", "System Settings", "Finder" },
    .windows => &.{ "File Explorer", "Microsoft Edge", "Settings", "Notepad", "Calculator" },
    else => &.{ "Files", "Firefox", "Terminal", "Settings", "Text Editor" },
};

/// Finds this machine's apps.
pub fn scanSystem(ix: *Index, io: std.Io, env: *const std.process.Environ.Map) void {
    switch (builtin.os.tag) {
        .macos => return ix.scan(io, env.get("HOME")),
        .windows => @import("apps_win.zig").scan(ix, io, env),
        else => @import("apps_linux.zig").scan(ix, io),
    }
    ix.sort();
}

/// Opens an app found by `scanSystem` (or a file, a folder).
pub fn launch(io: std.Io, path: []const u8) bool {
    if (builtin.os.tag == .linux and std.mem.endsWith(u8, path, ".desktop")) return @import("apps_linux.zig").launch(io, path);
    if (mac and std.mem.endsWith(u8, path, ".app")) {
        openApp(path);
        return true;
    }
    return nanoui.shell.openPath(path);
}

pub const Icon = struct { png: []u8 };

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    apps: std.ArrayList(App) = .empty,
    /// The names alone, for `search.rank`.
    names: std.ArrayList([]const u8) = .empty,
    /// Times each was opened.
    launches: std.ArrayList(u16) = .empty,
    icons: std.AutoHashMapUnmanaged(u32, ?Icon) = .empty,
    /// Listed with an empty query before anything was opened.
    starters: []const []const u8 = default_starters,

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ix: *Index) void {
        var it = ix.icons.valueIterator();
        while (it.next()) |v| if (v.*) |i| ix.gpa.free(i.png);
        ix.icons.deinit(ix.gpa);
        ix.apps.deinit(ix.gpa);
        ix.names.deinit(ix.gpa);
        ix.launches.deinit(ix.gpa);
        ix.arena.deinit();
    }

    /// Adds an app unless one of its name is there already, its folder
    /// the one it is in.
    pub fn add(ix: *Index, name: []const u8, path: []const u8) !void {
        return ix.addIn(name, path, std.fs.path.basename(std.fs.path.dirname(path) orelse ""));
    }

    /// Adds an app, its row saying `folder` ("Applications", "Start").
    pub fn addIn(ix: *Index, name: []const u8, path: []const u8, folder: []const u8) !void {
        for (ix.names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) return;
        const a = ix.arena.allocator();
        const p = try a.dupe(u8, path);
        try ix.apps.append(ix.gpa, .{ .name = try a.dupe(u8, name), .path = p, .folder = try a.dupe(u8, folder) });
        try ix.names.append(ix.gpa, ix.apps.items[ix.apps.items.len - 1].name);
        try ix.launches.append(ix.gpa, 0);
    }

    /// Finds the apps on this machine; `home` adds ~/Applications.
    pub fn scan(ix: *Index, io: std.Io, home: ?[]const u8) void {
        for (roots) |r| ix.scanDir(io, r, 1);
        ix.add("Finder", "/System/Library/CoreServices/Finder.app") catch {};
        if (home) |h| {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}/Applications", .{h})) |p| ix.scanDir(io, p, 1) else |_| {}
        }
        ix.sort();
        ix.localize();
    }

    /// Localized display names and pinyin keys for search (macOS only).
    pub fn localize(ix: *Index) void {
        if (!mac) return;
        const text = @import("text.zig");
        const a = ix.arena.allocator();
        for (ix.apps.items) |*app| {
            if (!wantsLocalizedDisplayName(app.path)) continue;
            if (displayNameInto(a, app.path)) |loc| {
                if (!std.ascii.eqlIgnoreCase(loc, app.name)) app.name = loc;
            }
            if (text.hasCjk(app.name)) app.pinyin = pinyinKey(a, app.name) orelse "";
        }
        ix.sort();
    }

    fn scanDir(ix: *Index, io: std.Io, dir_path: []const u8, depth: u8) void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        var buf: [1024]u8 = undefined;
        while (it.next(io) catch null) |e| {
            if (e.name.len == 0 or e.name[0] == '.') continue;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, e.name }) catch continue;
            if (std.mem.endsWith(u8, e.name, ".app")) {
                ix.add(e.name[0 .. e.name.len - 4], full) catch return;
            } else if (depth > 0 and e.kind == .directory) {
                // The callee formats into its own buffer: copy the path first.
                var sub: [1024]u8 = undefined;
                @memcpy(sub[0..full.len], full);
                ix.scanDir(io, sub[0..full.len], depth - 1);
            }
        }
    }

    /// Alphabetical, case-insensitive; names and counts kept in step.
    pub fn sort(ix: *Index) void {
        const Ctx = struct {
            pub fn lessThan(_: @This(), a: App, b: App) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        };
        std.sort.pdq(App, ix.apps.items, Ctx{}, Ctx.lessThan);
        for (ix.apps.items, 0..) |a, i| ix.names.items[i] = a.name;
    }

    /// Whether `other` lists the same apps and commands, at the same
    /// paths: a rescan that found nothing new (raycast_live.zig `refresh`).
    pub fn same(ix: *const Index, other: *const Index) bool {
        if (ix.apps.items.len != other.apps.items.len) return false;
        for (ix.apps.items, other.apps.items) |a, b| {
            if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.name, b.name)) return false;
        }
        return true;
    }

    pub fn find(ix: *const Index, name: []const u8) ?u32 {
        for (ix.names.items, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
        return null;
    }

    pub fn findPath(ix: *const Index, path: []const u8) ?u32 {
        for (ix.apps.items, 0..) |a, i| if (std.mem.eql(u8, a.path, path)) return @intCast(i);
        return null;
    }

    /// Up to `out.len` apps for an empty query: the most opened, else a
    /// few every Mac has.
    pub fn suggestions(ix: *const Index, out: []u32) usize {
        var n: usize = 0;
        // Most opened first: a few passes from the highest count down.
        var best: u16 = std.math.maxInt(u16);
        while (n < out.len) {
            var next: u16 = 0;
            for (ix.launches.items) |l| if (l < best and l > next) {
                next = l;
            };
            if (next == 0) break;
            for (ix.launches.items, 0..) |l, i| if (l == next and n < out.len) {
                out[n] = @intCast(i);
                n += 1;
            };
            best = next;
        }
        for (ix.starters) |s| {
            if (n == out.len) break;
            const i = ix.find(s) orelse continue;
            if (std.mem.indexOfScalar(u32, out[0..n], i) == null) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// Counts an opening, and keeps the counts in `store`.
    pub fn opened(ix: *Index, i: u32, store: ?nanoui.kv.Store) void {
        ix.launches.items[i] +|= 1;
        if (store) |kv| ix.save(kv);
    }

    /// Keeps every count in `kv` (as `opened` does, and a sync after it).
    pub fn save(ix: *Index, kv: nanoui.kv.Store) void {
        var aw: std.Io.Writer.Allocating = .init(ix.gpa);
        defer aw.deinit();
        for (ix.apps.items, ix.launches.items) |a, l| if (l > 0) aw.writer.print("{s}\t{d}\n", .{ a.path, l }) catch return;
        kv.set(store_key, aw.written()) catch {};
    }

    /// The counts `opened` kept. Keys are app paths; older rows used
    /// display names and are still read once.
    pub fn load(ix: *Index, store: nanoui.kv.Store) void {
        const v = (store.get(ix.gpa, store_key) catch null) orelse return;
        defer ix.gpa.free(v);
        var lines = std.mem.splitScalar(u8, v, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const key = line[0..tab];
            const count = std.fmt.parseInt(u16, line[tab + 1 ..], 10) catch 0;
            const i = resolveLaunchKey(ix, key) orelse continue;
            ix.launches.items[i] = count;
        }
    }

    /// The app's icon as PNG, made the first time it is asked for.
    pub fn icon(ix: *Index, i: u32) ?[]const u8 {
        if (ix.icons.get(i)) |cached| return if (cached) |c| c.png else null;
        const path = ix.apps.items[i].path;
        const png = if (std.mem.startsWith(u8, path, "raycast")) @import("raycast.zig").icon(ix.gpa, path) else switch (builtin.os.tag) {
            .macos => iconPng(ix.gpa, path),
            .windows => @import("apps_win.zig").icon(ix.gpa, path),
            else => @import("apps_linux.zig").icon(ix.gpa, std.Io.Threaded.global_single_threaded.io(), path),
        };
        ix.icons.put(ix.gpa, i, if (png) |p| .{ .png = p } else null) catch {};
        return png;
    }
};

const store_key = "nanolight.launches";

fn resolveLaunchKey(ix: *const Index, key: []const u8) ?u32 {
    if (ix.findPath(key)) |i| return i;
    return ix.find(key);
}

/// Opens the Mac app at `path` without waiting for it: LaunchServices
/// answers when the app has started, which can take seconds (an app
/// reinstalled while Nanolight ran, issue #7), and `openURL:` waited on
/// the main thread meanwhile, with the panel frozen in front.
fn openApp(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const config = objc.msg(objc.Object, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    objc.msg(void, ws, "openApplicationAtURL:configuration:completionHandler:", .{ url, config, @as(?*anyopaque, null) });
}

fn wantsLocalizedDisplayName(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "zig-cache") != null) return false;
    for (roots) |r| if (std.mem.startsWith(u8, path, r)) return true;
    return std.mem.indexOf(u8, path, "/Applications/") != null;
}

/// The Finder's icon for `path`, drawn at 64 pixels and encoded as PNG.
fn displayNameInto(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const ns = objc.msg(objc.Object, fm, "displayNameAtPath:", .{objc.nsString(path)});
    const utf8 = objc.msg(?[*]const u8, ns, "UTF8String", .{}) orelse return null;
    return a.dupe(u8, std.mem.sliceTo(utf8, 0)) catch null;
}

fn pinyinKey(a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns = objc.nsString(name);
    const step1 = objc.msg(objc.Object, ns, "stringByApplyingTransform:reverse:", .{ objc.nsString("Mandarin-Latin"), objc.NO });
    const step2 = objc.msg(objc.Object, step1, "stringByApplyingTransform:reverse:", .{ objc.nsString("Latin-ASCII"), objc.NO });
    const latin = objc.msg(?[*]const u8, step2, "UTF8String", .{}) orelse return null;
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (std.mem.sliceTo(latin, 0)) |ch| {
        if (ch == ' ' or ch == '\'') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    if (n == 0) return null;
    return a.dupe(u8, buf[0..n]) catch null;
}

fn iconPng(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const img = objc.msg(objc.Object, ws, "iconForFile:", .{objc.nsString(path)});
    var rect: objc.CGRect = .{ .size = .{ .width = 64, .height = 64 } };
    const cg = objc.msg(?*anyopaque, img, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const rep = objc.msg(objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg});
    defer objc.release(rep);
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    // NSBitmapImageFileTypePNG
    const data = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), props }) orelse return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return null;
    return gpa.dupe(u8, bytes[0..len]) catch null;
}

test "names are kept once, sorted, and opening one suggests it" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    ix.starters = &.{ "Safari", "Notes", "Calendar" };
    try ix.add("Safari", "/Applications/Safari.app");
    try ix.add("notes", "/System/Applications/Notes.app");
    try ix.add("Notes", "/Applications/Notes.app");
    try ix.add("Calculator", "/System/Applications/Calculator.app");
    ix.sort();
    try t.expectEqual(@as(usize, 3), ix.apps.items.len);
    try t.expectEqualStrings("Calculator", ix.names.items[0]);
    try t.expectEqualStrings("Applications", ix.apps.items[0].folder);
    var out: [3]u32 = undefined;
    // Nothing opened yet: the starters there are.
    try t.expectEqual(@as(usize, 2), ix.suggestions(&out));
    try t.expectEqualStrings("Safari", ix.names.items[out[0]]);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.opened(0, mem.store());
    ix.opened(0, mem.store());
    try t.expectEqual(@as(usize, 3), ix.suggestions(&out));
    try t.expectEqualStrings("Calculator", ix.names.items[out[0]]);
    // Kept, and read back.
    ix.launches.items[0] = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.launches.items[0]);
}

test "a second look tells an app installed since from no change (#15)" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Applications/Alpha.app");
    var buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    ix.scan(t.io, home);
    var again: Index = .init(t.allocator);
    defer again.deinit();
    again.scan(t.io, home);
    try t.expect(ix.same(&again));
    // DOSBox-X, installed while Nanolight ran.
    try tmp.dir.createDirPath(t.io, "Applications/DOSBox-X.app");
    var later: Index = .init(t.allocator);
    defer later.deinit();
    later.scan(t.io, home);
    try t.expect(!ix.same(&later));
    try t.expect(later.find("DOSBox-X") != null);
}

test "launch counts resolve stored paths on Windows-style keys" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Explorer", "C:\\Windows\\explorer.exe");
    const i = ix.findPath("C:\\Windows\\explorer.exe").?;
    ix.opened(i, null);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.save(mem.store());
    ix.launches.items[i] = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 1), ix.launches.items[i]);
}

test "launch counts follow the app path when the display name changes" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("WeChat", "/Applications/WeChat.app");
    const i = ix.findPath("/Applications/WeChat.app").?;
    ix.opened(i, null);
    ix.opened(i, null);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.save(mem.store());
    ix.apps.items[i].name = "微信";
    ix.names.items[i] = "微信";
    ix.launches.items[i] = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.launches.items[i]);
}
