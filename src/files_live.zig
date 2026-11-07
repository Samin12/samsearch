//! File lookups run off the main thread; answers move their icons to the view.
const std = @import("std");
const nanoui = @import("nanoui");
const files = @import("files.zig");
const suggest = @import("suggest.zig");
const Live = @import("main.zig").Live;
const mac = @import("builtin").os.tag == .macos;

/// A new query cancels the old Spotlight round within its next poll.
pub fn askFiles(ctx: *anyopaque, q: []const u8) void {
    if (!mac or q.len >= files.max_path) return;
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (l.files.active) |a| a.cancel.store(true, .release);
    l.files.active = null;
    if (l.s.pipeline.status(.files) != .pending) return;
    @memcpy(l.files.query[0..q.len], q);
    l.files.len = q.len;
    l.files.generation = l.s.pipeline.generation;
    const timer = l.app.gpa.create(Timer) catch {
        l.s.filesAnsweredGeneration(l.s.pipeline.generation, null);
        return;
    };
    timer.* = .{ .live = l, .generation = l.files.generation };
    nanoui.App.after(suggest.pause_ms, timer, Timer.done);
}

const Timer = struct {
    live: *Live,
    generation: u64,

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const timer: *Timer = @ptrCast(@alignCast(ctx.?));
        const l = timer.live;
        const generation = timer.generation;
        l.app.gpa.destroy(timer);
        if (generation == l.files.generation) sendFiles(l);
    }
};

fn sendFiles(l: *Live) void {
    if (!mac or l.files.active != null or l.files.sent == l.files.generation or !l.s.files_on or l.files.generation != l.s.pipeline.generation) return;
    const q = l.files.query[0..l.files.len];
    const a = l.app.gpa.create(FileAsk) catch {
        l.s.filesAnsweredGeneration(l.files.generation, null);
        return;
    };
    a.* = .{ .live = l, .len = q.len, .generation = l.files.generation, .found = .{ .allocator = l.app.gpa } };
    @memcpy(a.text[0..q.len], q);
    a.locations = l.kv.get(l.app.gpa, files.locations_key) catch null;
    a.exclusions = l.kv.get(l.app.gpa, files.exclusions_key) catch null;
    l.files.active = a;
    l.files.sent = l.files.generation;
    const thread = std.Thread.spawn(.{}, FileAsk.run, .{a}) catch {
        l.files.active = null;
        l.s.filesAnsweredGeneration(a.generation, null);
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
    generation: u64,
    cancel: files.Cancel = .init(false),
    locations: ?[]u8 = null,
    exclusions: ?[]u8 = null,
    found: files.List = .{},
    ok: bool = false,

    fn run(a: *FileAsk) void {
        const q = a.text[0..a.len];
        if (files.isPath(q)) {
            files.complete(a.live.app.io, q, &a.found);
            a.ok = true;
        } else a.ok = files.findCancelable(a.live.app.io, q, a.locations orelse "", a.exclusions orelse "", &a.found, &a.cancel);
        if (a.ok and !a.cancel.load(.acquire)) a.found.icons();
        nanoui.App.after(0, a, done);
    }

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const a: *FileAsk = @ptrCast(@alignCast(ctx.?));
        const l = a.live;
        defer a.destroy();
        if (l.files.active == a) l.files.active = null;
        if (!a.cancel.load(.acquire)) {
            l.s.filesAnsweredGeneration(a.generation, if (a.ok) &a.found else null);
            if (l.window) |w| w.redraw();
        }
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
    generation: u64 = 0,
    sent: u64 = 0,
    active: ?*FileAsk = null,
};

pub fn load(l: *Live) void {
    // File search is local to this Mac and off unless explicitly enabled.
    if (mac) if (l.kv.get(l.app.gpa, files.enabled_key) catch null) |v| {
        defer l.app.gpa.free(v);
        l.s.files_on = std.mem.eql(u8, v, "1");
    };
}
