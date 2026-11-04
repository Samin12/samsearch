//! SamSearch owns its data. On first use, copy only Nanolight's installed
//! extensions and script commands, publishing the copy only when complete.
const std = @import("std");
const nanoui = @import("nanoui");

/// Caller frees the path. Must run before app/kv initialization creates it.
pub fn prepare(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    // nanoui.path(.data, name) creates that folder. Ask only for its
    // parent so checking SamSearch's existence cannot create it first.
    const base = try nanoui.path(gpa, .data, "");
    defer gpa.free(base);
    return prepareAt(gpa, io, std.Io.Dir.cwd(), base);
}

fn prepareAt(gpa: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, base: []const u8) ![]u8 {
    const dest = try std.fs.path.join(gpa, &.{ base, "SamSearch" });
    errdefer gpa.free(dest);
    const old = try std.fs.path.join(gpa, &.{ base, "Nanolight" });
    defer gpa.free(old);
    try migrate(gpa, io, parent, old, dest);
    return dest;
}

fn migrate(gpa: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, old: []const u8, dest: []const u8) !void {
    if (parent.openDir(io, dest, .{})) |d| {
        d.close(io);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var source = parent.openDir(io, old, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer source.close(io);
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const stage = try std.fmt.allocPrint(gpa, "{s}.migrating-{x}", .{ dest, std.mem.readInt(u64, &nonce, .little) });
    defer gpa.free(stage);
    try parent.createDir(io, stage, .default_dir);
    defer parent.deleteTree(io, stage) catch {};
    var target = try parent.openDir(io, stage, .{});
    defer target.close(io);
    for ([_][]const u8{ "extensions", "script-commands" }) |name| {
        var src = source.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer src.close(io);
        try target.createDir(io, name, .default_dir);
        var dst = try target.openDir(io, name, .{});
        defer dst.close(io);
        var walker = try src.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| switch (entry.kind) {
            .directory => try dst.createDirPath(io, entry.path),
            .file => try entry.dir.copyFile(entry.basename, dst, entry.path, io, .{ .replace = false }),
            .sym_link => {
                var link: [std.fs.max_path_bytes]u8 = undefined;
                const n = try entry.dir.readLink(io, entry.basename, &link);
                try dst.symLink(io, link[0..n], entry.path, .{});
            },
            else => return error.UnsupportedMigrationEntry,
        };
    }
    // Never replace an existing SamSearch folder, even if another copy starts.
    try parent.renamePreserve(stage, parent, dest, io);
}

test "first use copies commands and symlinks, preserves source, and never overwrites existing data" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Nanolight/extensions/demo/bin");
    try tmp.dir.createDirPath(t.io, "Nanolight/script-commands");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Nanolight/extensions/demo/package.json", .data = "demo" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Nanolight/script-commands/hello.sh", .data = "#!/bin/sh\necho hello\n", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Nanolight/prefs.json", .data = "old preferences" });
    if (@import("builtin").os.tag != .windows)
        try tmp.dir.symLink(t.io, "../package.json", "Nanolight/extensions/demo/bin/link", .{});
    const prepared = try prepareAt(t.allocator, t.io, tmp.dir, ".");
    defer t.allocator.free(prepared);
    try t.expectEqualStrings("SamSearch", std.fs.path.basename(prepared));
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("demo", try tmp.dir.readFile(t.io, "SamSearch/extensions/demo/package.json", &buf));
    try t.expectEqualStrings("#!/bin/sh\necho hello\n", try tmp.dir.readFile(t.io, "SamSearch/script-commands/hello.sh", &buf));
    try t.expectEqualStrings("demo", try tmp.dir.readFile(t.io, "Nanolight/extensions/demo/package.json", &buf));
    if (std.Io.File.Permissions.has_executable_bit) {
        const copied = try tmp.dir.openFile(t.io, "SamSearch/script-commands/hello.sh", .{});
        defer copied.close(t.io);
        const stat = try copied.stat(t.io);
        try t.expect(stat.permissions.toMode() & 0o100 != 0);
    }
    try t.expectError(error.FileNotFound, tmp.dir.openFile(t.io, "SamSearch/prefs.json", .{}));
    if (@import("builtin").os.tag != .windows) {
        const n = try tmp.dir.readLink(t.io, "SamSearch/extensions/demo/bin/link", &buf);
        try t.expectEqualStrings("../package.json", buf[0..n]);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "SamSearch/extensions/demo/package.json", .data = "personalized" });
    try migrate(t.allocator, t.io, tmp.dir, "Nanolight", "SamSearch");
    try t.expectEqualStrings("personalized", try tmp.dir.readFile(t.io, "SamSearch/extensions/demo/package.json", &buf));
    // No old folder: leave creation to the normal app/kv path.
    try migrate(t.allocator, t.io, tmp.dir, "Missing", "Fresh");
    try t.expectError(error.FileNotFound, tmp.dir.openDir(t.io, "Fresh", .{}));
}

test "preparing a fresh data directory does not invent a legacy folder" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const prepared = try prepareAt(t.allocator, t.io, tmp.dir, ".");
    defer t.allocator.free(prepared);
    try t.expectEqualStrings("SamSearch", std.fs.path.basename(prepared));
    try t.expectError(error.FileNotFound, tmp.dir.openDir(t.io, "Nanolight", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.openDir(t.io, "SamSearch", .{}));
}
