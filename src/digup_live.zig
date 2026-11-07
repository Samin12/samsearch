//! Debounced DigUp requests: one session worker, stale answers discarded.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const digup = @import("digup.zig");
const Live = @import("main.zig").Live;

pub const State = struct {
    query: [digup.max_query]u8 = undefined,
    len: usize = 0,
    generation: u64 = 0,
    sent: ?u64 = null,
    active: ?*Ask = null,
    attempt: u8 = 0,
};

/// Supersede immediately; the cancelled callback owns its cleanup.
pub fn ask(ctx: *anyopaque, query: []const u8) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (l.digup.active) |a| objc.msg(void, a.session.?, "invalidateAndCancel", .{});
    l.digup.active = null;
    const q = std.mem.trim(u8, query, " \t\r\n");
    l.digup.generation = l.s.pipeline.generation;
    l.digup.attempt = 0;
    l.digup.sent = null;
    l.digup.len = if (l.s.digup_on and digup.eligible(q)) q.len else 0;
    if (l.digup.len == 0) return;
    @memcpy(l.digup.query[0..l.digup.len], q[0..l.digup.len]);
    const timer = l.app.gpa.create(Timer) catch {
        l.s.digupAnsweredGeneration(l.digup.generation, null);
        return;
    };
    timer.* = .{ .live = l, .generation = l.digup.generation };
    nanoui.App.after(@import("suggest.zig").pause_ms, timer, Timer.done);
}

const Timer = struct {
    live: *Live,
    generation: u64,

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const timer: *Timer = @ptrCast(@alignCast(ctx.?));
        const l = timer.live;
        const generation = timer.generation;
        l.app.gpa.destroy(timer);
        if (generation == l.digup.generation) send(l);
    }
};

fn send(l: *Live) void {
    if (l.digup.active != null or l.digup.sent == l.digup.generation or
        !l.s.digup_on or l.digup.len == 0 or l.digup.generation != l.s.pipeline.generation) return;
    const q = l.digup.query[0..l.digup.len];
    const a = l.app.gpa.create(Ask) catch {
        l.s.digupAnsweredGeneration(l.digup.generation, null);
        return;
    };
    a.* = .{ .live = l, .len = q.len, .generation = l.digup.generation, .found = .{ .found = .{ .allocator = l.app.gpa } } };
    @memcpy(a.text[0..q.len], q);
    l.digup.active = a;
    l.digup.sent = l.digup.generation;
    const pool = objc.Pool.push();
    defer pool.pop();
    const config = objc.msg(objc.Object, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
    objc.msg(void, config, "setTimeoutIntervalForRequest:", .{@as(f64, 1.5)});
    objc.msg(void, config, "setTimeoutIntervalForResource:", .{@as(f64, 1.5)});
    a.session = objc.retain(objc.msg(objc.Object, objc.class("NSURLSession"), "sessionWithConfiguration:", .{config}));
    const url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString("http://127.0.0.1:47213/api/digup")});
    const req = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{url});
    objc.msg(void, req, "setHTTPMethod:", .{objc.nsString("POST")});
    objc.msg(void, req, "setTimeoutInterval:", .{@as(f64, 1.5)});
    objc.msg(void, req, "setValue:forHTTPHeaderField:", .{ objc.nsString("1"), objc.nsString("X-QuickAsk") });
    objc.msg(void, req, "setValue:forHTTPHeaderField:", .{ objc.nsString("application/json"), objc.nsString("Content-Type") });
    var body: [2048]u8 = undefined;
    var wr: std.Io.Writer = .fixed(&body);
    wr.writeAll("{\"q\":") catch unreachable;
    std.json.Stringify.encodeJsonString(q, .{}, &wr) catch unreachable;
    wr.writeByte('}') catch unreachable;
    const bytes = wr.buffered();
    objc.msg(void, req, "setHTTPBody:", .{objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) })});
    var block = objc.Block(Ask, &.{ ?objc.Object, ?objc.Object, ?objc.Object }).init(a, Ask.answered);
    const task = objc.msg(objc.Object, a.session.?, "dataTaskWithRequest:completionHandler:", .{ req, @as(*anyopaque, @ptrCast(&block)) });
    objc.msg(void, task, "resume", .{});
}

const Ask = struct {
    live: *Live,
    text: [digup.max_query]u8 = undefined,
    len: usize,
    generation: u64,
    timed_out: bool = false,
    session: ?objc.Object = null,
    found: digup.List,
    ok: bool = false,

    /// NSURLSession's queue does the parsing and icon work, never the UI thread.
    fn answered(a: *Ask, data: ?objc.Object, response: ?objc.Object, err: ?objc.Object) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (err == null and data != null and response != null and objc.msg(objc.NSInteger, response.?, "statusCode", .{}) == 200) {
            const len = objc.msg(objc.NSUInteger, data.?, "length", .{});
            if (len <= digup.max_bytes) if (objc.msg(?[*]const u8, data.?, "bytes", .{})) |bytes| {
                a.ok = digup.decode(a.live.app.gpa, bytes[0..len], &a.found);
                if (a.ok) a.found.found.icons();
            };
        }
        if (err) |e| a.timed_out = objc.msg(objc.NSInteger, e, "code", .{}) == -1001;
        nanoui.App.after(0, a, done);
    }

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Ask = @ptrCast(@alignCast(ctx.?));
        const l = a.live;
        defer {
            objc.msg(void, a.session.?, "invalidateAndCancel", .{});
            objc.release(a.session.?);
            a.found.deinit();
            l.app.gpa.destroy(a);
        }
        if (l.digup.active != a) return;
        l.digup.active = null;
        if (a.generation != l.s.pipeline.generation or !l.s.digup_on) return;
        if (digup.retry(a.timed_out, l.digup.attempt)) {
            l.digup.attempt += 1;
            l.digup.sent = null;
            send(l);
            return;
        }
        l.s.digupAnsweredGeneration(a.generation, if (a.ok) &a.found else null);
        if (l.window) |w| w.redraw();
    }
};
