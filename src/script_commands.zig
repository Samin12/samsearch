//! Raycast Script Commands (github.com/raycast/script-commands, MIT), run
//! by Nanolight itself: no JavaScript. A script command is any script
//! (bash, Python, Ruby, PowerShell…) whose comments say what it is:
//!
//!     # @raycast.schemaVersion 1
//!     # @raycast.title Generate UUID
//!     # @raycast.mode silent
//!     # @raycast.packageName Developer Utilities
//!     # @raycast.icon 💻
//!     # @raycast.argument1 { "type": "text", "placeholder": "Name" }
//!
//! Scripts dropped in `<data dir>/script-commands` (a folder down too) are
//! rows among the apps: `script:<file>`, their folder the package's name.
//! script_run.zig runs one and shows what it prints.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const Index = @import("apps.zig").Index;
const windows = builtin.os.tag == .windows;

pub const prefix = "script:";
/// The row that opens the scripts' folder.
pub const folder_path = "script-folder:";

pub const Mode = enum { silent, compact, full_output, inline_ };

pub const Argument = struct {
    /// "text", "password" or "dropdown".
    type: []const u8 = "text",
    placeholder: []const u8 = "",
    optional: bool = false,
    percentEncoded: bool = false,
    data: []const struct { title: []const u8 = "", value: []const u8 = "" } = &.{},
};

pub const Meta = struct {
    title: []const u8 = "",
    mode: Mode = .full_output,
    package: []const u8 = "",
    icon: []const u8 = "",
    description: []const u8 = "",
    cwd: []const u8 = "",
    confirm: bool = false,
    args: [3]?Argument = .{ null, null, null },
    schema: bool = false,

    pub fn argCount(m: *const Meta) usize {
        var n: usize = 0;
        for (m.args) |a| if (a != null) {
            n += 1;
        };
        return n;
    }
};

/// The `@raycast.` keys in a script's comments (`#`, `//`, `--`), values
/// pointing into `bytes`; arguments parsed into `arena`. Null when it isn't
/// a script command (no schemaVersion or no title).
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ?Meta {
    var m: Meta = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| {
        seen += 1;
        if (seen > 200) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        const body = for ([_][]const u8{ "#", "//", "--", ";" }) |c| {
            if (std.mem.startsWith(u8, line, c)) break std.mem.trimStart(u8, line[c.len..], " \t#/-;");
        } else continue;
        const key_at = std.mem.indexOf(u8, body, "@raycast.") orelse continue;
        const kv = body[key_at + "@raycast.".len ..];
        const sp = std.mem.indexOfAny(u8, kv, " \t") orelse kv.len;
        const key = kv[0..sp];
        const value = std.mem.trim(u8, kv[sp..], " \t");
        if (std.mem.eql(u8, key, "schemaVersion")) m.schema = true else if (std.mem.eql(u8, key, "title")) m.title = value else if (std.mem.eql(u8, key, "packageName")) m.package = value else if (std.mem.eql(u8, key, "icon")) m.icon = value else if (std.mem.eql(u8, key, "description")) m.description = value else if (std.mem.eql(u8, key, "currentDirectoryPath")) m.cwd = value else if (std.mem.eql(u8, key, "needsConfirmation")) m.confirm = std.mem.eql(u8, value, "true") else if (std.mem.eql(u8, key, "mode")) {
            m.mode = if (std.mem.eql(u8, value, "silent")) .silent else if (std.mem.eql(u8, value, "compact")) .compact else if (std.mem.eql(u8, value, "inline")) .inline_ else .full_output;
        } else if (std.mem.startsWith(u8, key, "argument") and key.len == 9 and key[8] >= '1' and key[8] <= '3') {
            m.args[key[8] - '1'] = std.json.parseFromSliceLeaky(Argument, arena, value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
        }
    }
    if (!m.schema or m.title.len == 0) return null;
    return m;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `<data dir>/script-commands`, made if missing. Caller frees it.
pub fn dir(gpa: std.mem.Allocator) ![]u8 {
    const data = try @import("data_dir.zig").prepare(gpa, io());
    defer gpa.free(data);
    const d = try std.fs.path.join(gpa, &.{ data, "script-commands" });
    std.Io.Dir.cwd().createDirPath(io(), d) catch {};
    return d;
}

/// Adds each script command in the folder (and a folder down) to `ix`,
/// and the row that opens the folder.
pub fn scan(ix: *Index, gpa: std.mem.Allocator) void {
    ix.addIn("Script Commands Folder", folder_path, "Raycast") catch {};
    const root = dir(gpa) catch return;
    defer gpa.free(root);
    scanDir(ix, gpa, root, 1);
}

fn scanDir(ix: *Index, gpa: std.mem.Allocator, path: []const u8, depth: u8) void {
    var d = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch return;
    defer d.close(io());
    var it = d.iterate();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    while (it.next(io()) catch null) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        const a = arena.allocator();
        const full = std.fs.path.join(a, &.{ path, e.name }) catch continue;
        if (e.kind == .directory) {
            if (depth > 0) scanDir(ix, gpa, full, depth - 1);
            continue;
        }
        // The header is in the first lines: the file's first 8 KB.
        var buf: [8192]u8 = undefined;
        const head = d.readFile(io(), e.name, &buf) catch continue;
        const m = parse(a, head) orelse continue;
        const row = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, full }) catch continue;
        ix.addIn(m.title, row, if (m.package.len > 0) m.package else "Script Command") catch {};
    }
}

/// How to run `file`: its shebang's interpreter (`#!/usr/bin/env python3`),
/// else by its extension on Windows, else `sh`. Written into `out`.
pub fn command(bytes: []const u8, file: []const u8, out: *[8][]const u8) [][]const u8 {
    var n: usize = 0;
    const ext = std.fs.path.extension(file);
    if (windows) {
        const by_ext: ?[]const []const u8 = if (std.ascii.eqlIgnoreCase(ext, ".ps1"))
            &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" }
        else if (std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd"))
            &.{ "cmd", "/c" }
        else if (std.ascii.eqlIgnoreCase(ext, ".py"))
            &.{"python"}
        else if (std.ascii.eqlIgnoreCase(ext, ".js"))
            &.{"node"}
        else
            null;
        if (by_ext) |parts| {
            for (parts) |p| {
                out[n] = p;
                n += 1;
            }
            out[n] = file;
            return out[0 .. n + 1];
        }
    }
    if (std.mem.startsWith(u8, bytes, "#!")) {
        const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
        var words = std.mem.tokenizeAny(u8, std.mem.trim(u8, bytes[2..nl], " \t\r"), " \t");
        while (words.next()) |w| if (n < out.len - 1) {
            // On Windows "/usr/bin/env bash" is "bash" from the PATH (Git's).
            out[n] = if (windows) std.fs.path.basename(w) else w;
            n += 1;
        };
        if (n > 1 and std.mem.eql(u8, std.fs.path.basename(out[0]), "env")) {
            // env's own name goes on Windows; elsewhere it finds the rest.
            if (windows) {
                std.mem.copyForwards([]const u8, out[0 .. n - 1], out[1..n]);
                n -= 1;
            }
        }
    }
    if (n == 0) {
        out[0] = if (windows) "sh" else "/bin/sh";
        n = 1;
    }
    out[n] = file;
    return out[0 .. n + 1];
}

/// `value` percent-encoded (an argument with `percentEncoded`).
pub fn encode(buf: []u8, value: []const u8) []const u8 {
    var n: usize = 0;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            if (n + 1 > buf.len) break;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) break;
            _ = std.fmt.bufPrint(buf[n..][0..3], "%{X:0>2}", .{ch}) catch break;
            n += 3;
        }
    }
    return buf[0..n];
}

test "a script command's header" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\#!/usr/bin/env bash
        \\# Required parameters:
        \\# @raycast.schemaVersion 1
        \\# @raycast.title Search Wikipedia
        \\# @raycast.mode silent
        \\# @raycast.packageName Web Searches
        \\# @raycast.icon 📖
        \\# @raycast.argument1 { "type": "text", "placeholder": "Query", "percentEncoded": true }
        \\# @raycast.argument2 { "type": "dropdown", "placeholder": "Lang", "data": [{"title": "English", "value": "en"}] }
        \\open "https://$2.wikipedia.org/w/index.php?search=$1"
    ;
    const m = parse(arena.allocator(), src).?;
    try std.testing.expectEqualStrings("Search Wikipedia", m.title);
    try std.testing.expectEqual(Mode.silent, m.mode);
    try std.testing.expectEqualStrings("Web Searches", m.package);
    try std.testing.expectEqual(@as(usize, 2), m.argCount());
    try std.testing.expect(m.args[0].?.percentEncoded);
    try std.testing.expectEqualStrings("en", m.args[1].?.data[0].value);
    try std.testing.expect(parse(arena.allocator(), "#!/bin/sh\necho hi\n") == null);
    // AppleScript's and JavaScript's comments too.
    try std.testing.expectEqualStrings("A", parse(arena.allocator(), "-- @raycast.schemaVersion 1\n-- @raycast.title A\n").?.title);
    try std.testing.expectEqualStrings("B", parse(arena.allocator(), "// @raycast.schemaVersion 1\n// @raycast.title B\n").?.title);

    var out: [8][]const u8 = undefined;
    const argv = command(src, "/s/wiki.sh", &out);
    try std.testing.expectEqualStrings("/s/wiki.sh", argv[argv.len - 1]);
    if (!windows) try std.testing.expectEqualStrings("/usr/bin/env", argv[0]);
    try std.testing.expectEqualStrings(if (windows) "sh" else "/bin/sh", command("echo", "x", &out)[0]);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a%20b%26c", encode(&buf, "a b&c"));
}
