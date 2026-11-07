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
    const old = std.fs.path.join(gpa, &.{ base, "Nanolight" }) catch |err| {
        std.log.warn("samsearch: data migration skipped ({s})", .{@errorName(err)});
        return dest;
    };
    defer gpa.free(old);
    try migrate(gpa, io, parent, old, dest);
    return dest;
}

fn migrate(gpa: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, old: []const u8, dest: []const u8) !void {
    migrateInner(gpa, io, parent, old, dest) catch |err| {
        std.log.warn("samsearch: data migration skipped ({s})", .{@errorName(err)});
    };
}

fn migrateInner(gpa: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, old: []const u8, dest: []const u8) !void {
    cleanupStages(io, parent, dest);
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
    const pid = if (@import("builtin").os.tag == .windows) 0 else getpid();
    const stage = try std.fmt.allocPrint(gpa, "{s}.migrating-{d}-{x}", .{ dest, pid, std.mem.readInt(u64, &nonce, .little) });
    defer gpa.free(stage);
    try parent.createDir(io, stage, .default_dir);
    defer parent.deleteTree(io, stage) catch {};
    var target = try parent.openDir(io, stage, .{});
    defer target.close(io);
    for ([_][]const u8{ "extensions", "script-commands" }) |name| {
        copyEntry(gpa, io, source, target, name, .directory) catch |err| {
            std.log.warn("samsearch: migration skipped {s} ({s})", .{ name, @errorName(err) });
        };
    }
    // A concurrent launch may have published first: keep its data.
    try publish(io, parent, stage, dest);
}

fn publish(io: std.Io, parent: std.Io.Dir, stage: []const u8, dest: []const u8) !void {
    parent.renamePreserve(stage, parent, dest, io) catch |err| {
        if (parent.openDir(io, dest, .{})) |d| {
            d.close(io);
            return;
        } else |_| {}
        return err;
    };
}

fn copyEntry(gpa: std.mem.Allocator, io: std.Io, source: std.Io.Dir, target: std.Io.Dir, name: []const u8, kind: std.Io.File.Kind) anyerror!void {
    switch (kind) {
        .directory => {
            var src = try source.openDir(io, name, .{ .iterate = true });
            defer src.close(io);
            try target.createDir(io, name, .default_dir);
            var dst = try target.openDir(io, name, .{});
            defer dst.close(io);
            var it = src.iterate();
            while (try it.next(io)) |entry| {
                copyEntry(gpa, io, src, dst, entry.name, entry.kind) catch |err| {
                    std.log.warn("samsearch: migration skipped {s} ({s})", .{ entry.name, @errorName(err) });
                };
            }
        },
        .file => try source.copyFile(name, target, name, io, .{ .replace = false }),
        .sym_link => {
            var link: [std.fs.max_path_bytes]u8 = undefined;
            const n = try source.readLink(io, name, &link);
            try target.symLink(io, link[0..n], name, .{});
        },
        else => return error.UnsupportedMigrationEntry,
    }
}

extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

/// New stages carry their owner's PID, so cleanup cannot delete another
/// launch's in-progress copy. Old-format stages have no live owner.
fn cleanupStages(io: std.Io, parent: std.Io.Dir, dest: []const u8) void {
    const path = std.fs.path.dirname(dest) orelse ".";
    var dir = parent.openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s}.migrating-", .{std.fs.path.basename(dest)}) catch return;
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        const suffix = entry.name[prefix.len..];
        if (std.mem.indexOfScalar(u8, suffix, '-')) |dash| {
            const pid = std.fmt.parseInt(c_int, suffix[0..dash], 10) catch continue;
            if (@import("builtin").os.tag == .windows or pid <= 0) continue;
            // EPERM means alive too. Only ESRCH proves the owner is gone.
            if (std.c.errno(kill(pid, 0)) != .SRCH) continue;
        }
        dir.deleteTree(io, entry.name) catch |err| {
            std.log.warn("samsearch: couldn't clean migration stage ({s})", .{@errorName(err)});
        };
    }
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

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "migration skips a special entry, cleans abandoned stages, and preserves live stages" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Nanolight/extensions/demo");
    try tmp.dir.createDirPath(t.io, "SamSearch.migrating-abandoned");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Nanolight/extensions/demo/valid", .data = "kept" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const fifo = try std.fmt.allocPrintSentinel(t.allocator, "{s}/Nanolight/extensions/demo/pipe", .{root}, 0);
    defer t.allocator.free(fifo);
    try t.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    const live_stage = try std.fmt.allocPrint(t.allocator, "SamSearch.migrating-{d}-test", .{getpid()});
    defer t.allocator.free(live_stage);
    try tmp.dir.createDirPath(t.io, live_stage);
    const prepared = try prepareAt(t.allocator, t.io, tmp.dir, ".");
    defer t.allocator.free(prepared);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("kept", try tmp.dir.readFile(t.io, "SamSearch/extensions/demo/valid", &buf));
    try t.expectError(error.FileNotFound, tmp.dir.openFile(t.io, "SamSearch/extensions/demo/pipe", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.openDir(t.io, "SamSearch.migrating-abandoned", .{}));
    const live = try tmp.dir.openDir(t.io, live_stage, .{});
    live.close(t.io);
    // A legacy top-level entry that is not a directory is also skipped.
    try tmp.dir.createDirPath(t.io, "Other");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Other/extensions", .data = "not a directory" });
    try migrate(t.allocator, t.io, tmp.dir, "Other", "OtherCopy");
    const other = try tmp.dir.openDir(t.io, "OtherCopy", .{});
    other.close(t.io);
}

test "another launch winning publication preserves its data and does not fail" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "stage");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "stage/record", .data = "staged" });
    // The competing process creates SamSearch after our initial check,
    // immediately before our atomic rename.
    try tmp.dir.createDirPath(t.io, "SamSearch");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "SamSearch/record", .data = "winner" });
    try publish(t.io, tmp.dir, "stage", "SamSearch");
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("winner", try tmp.dir.readFile(t.io, "SamSearch/record", &buf));
}
