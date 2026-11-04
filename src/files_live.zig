//! File lookups run off the main thread; answers move their icons to the view.
const std = @import("std");
const nanoui = @import("nanoui");
const files = @import("files.zig");
const suggest = @import("suggest.zig");
const Live = @import("main.zig").Live;
const mac = @import("builtin").os.tag == .macos;

/// File lookups share the suggestions' pause and keep at most one worker.
pub fn askFiles(ctx: *anyopaque, q: []const u8) void {
    if (!mac or q.len >= files.max_path) return;
    const l: *Live = @ptrCast(@alignCast(ctx));
    @memcpy(l.files.query[0..q.len], q);
    l.files.len = q.len;
    l.files.epoch +%= 1;
    l.files.waiting += 1;
    nanoui.App.after(suggest.pause_ms, l, struct {
        fn f(c: ?*anyopaque) callconv(.c) void {
            const live: *Live = @ptrCast(@alignCast(c.?));
            live.files.waiting -= 1;
            if (live.files.waiting == 0) sendFiles(live);
        }
    }.f);
}

fn sendFiles(l: *Live) void {
    if (!mac or l.files.busy or l.files.waiting > 0 or l.files.sent == l.files.epoch or !l.s.files_on) return;
    const q = l.files.query[0..l.files.len];
    if (!std.mem.eql(u8, q, std.mem.trim(u8, l.s.query.text(), " \t\r\n"))) return;
    const a = l.app.gpa.create(FileAsk) catch return;
    a.* = .{ .live = l, .len = q.len, .epoch = l.files.epoch, .found = .{ .allocator = l.app.gpa } };
    @memcpy(a.text[0..q.len], q);
    a.locations = l.kv.get(l.app.gpa, files.locations_key) catch null;
    a.exclusions = l.kv.get(l.app.gpa, files.exclusions_key) catch null;
    l.files.busy = true;
    l.files.sent = l.files.epoch;
    const thread = std.Thread.spawn(.{}, FileAsk.run, .{a}) catch {
        l.files.busy = false;
        a.destroy();
        return;
    };
    thread.detach();
}

/// One file query, with all filesystem, process and icon work off the UI thread.
const FileAsk = struct {
    live: *Live,
    text: [files.max_path]u8 = undefined,
    len: usize,
    epoch: u64,
    locations: ?[]u8 = null,
    exclusions: ?[]u8 = null,
    found: files.List = .{},
    ok: bool = false,

    fn run(a: *FileAsk) void {
        const q = a.text[0..a.len];
        if (files.isPath(q)) {
            files.complete(a.live.app.io, q, &a.found);
            a.ok = true;
        } else a.ok = files.find(a.live.app.io, q, a.locations orelse "", a.exclusions orelse "", &a.found);
        if (a.ok) a.found.icons();
        nanoui.App.after(0, a, done);
    }

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const a: *FileAsk = @ptrCast(@alignCast(ctx.?));
        const l = a.live;
        defer a.destroy();
        l.files.busy = false;
        if (a.ok and a.epoch == l.files.epoch) {
            l.s.filesAnswered(a.text[0..a.len], &a.found);
            if (l.window) |w| w.redraw();
        }
        sendFiles(l);
    }

    fn destroy(a: *FileAsk) void {
        const gpa = a.live.app.gpa;
        if (a.locations) |v| gpa.free(v);
        if (a.exclusions) |v| gpa.free(v);
        a.found.deinit();
        gpa.destroy(a);
    }
};

pub const State = struct {
    query: [files.max_path]u8 = undefined,
    len: usize = 0,
    waiting: u32 = 0,
    epoch: u64 = 0,
    sent: u64 = 0,
    busy: bool = false,
};

pub fn load(l: *Live) void {
    // File search is local to this Mac and off unless explicitly enabled.
    if (mac) if (l.kv.get(l.app.gpa, files.enabled_key) catch null) |v| {
        defer l.app.gpa.free(v);
        l.s.files_on = std.mem.eql(u8, v, "1");
    };
}
