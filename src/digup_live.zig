//! Debounced DigUp requests: one session worker, stale answers discarded.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const digup = @import("digup.zig");
const Live = @import("main.zig").Live;

pub const State = struct {
    query: [digup.max_query]u8 = undefined,
    len: usize = 0,
    epoch: u64 = 0,
    sent: u64 = 0,
    waiting: u32 = 0,
    busy: bool = false,
};

/// Every changed query invalidates the previous answer, including empty ones.
pub fn ask(ctx: *anyopaque, query: []const u8) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    const q = std.mem.trim(u8, query, " \t\r\n");
    l.digup.epoch +%= 1;
    l.digup.len = if (l.s.digup_on and digup.eligible(q)) q.len else 0;
    @memcpy(l.digup.query[0..l.digup.len], q[0..l.digup.len]);
    l.digup.waiting += 1;
    nanoui.App.after(@import("suggest.zig").pause_ms, l, struct {
        fn f(c: ?*anyopaque) callconv(.c) void {
            const live: *Live = @ptrCast(@alignCast(c.?));
            live.digup.waiting -= 1;
            if (live.digup.waiting == 0) send(live);
        }
    }.f);
}

fn send(l: *Live) void {
    if (l.digup.busy or l.digup.waiting > 0 or l.digup.sent == l.digup.epoch or !l.s.digup_on or l.digup.len == 0) return;
    const q = l.digup.query[0..l.digup.len];
    if (!std.mem.eql(u8, q, std.mem.trim(u8, l.s.query.text(), " \t\r\n"))) return;
    const a = l.app.gpa.create(Ask) catch return;
    a.* = .{ .live = l, .len = q.len, .epoch = l.digup.epoch, .started = std.Io.Clock.awake.now(l.app.io).toMilliseconds(), .found = .{ .found = .{ .allocator = l.app.gpa } } };
    @memcpy(a.text[0..q.len], q);
    l.digup.busy = true;
    l.digup.sent = l.digup.epoch;
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
    epoch: u64,
    started: i64,
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
        if (std.Io.Clock.awake.now(a.live.app.io).toMilliseconds() - a.started > 1500) a.ok = false;
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
        l.digup.busy = false;
        if (a.ok and a.epoch == l.digup.epoch) {
            l.s.digupAnswered(a.text[0..a.len], &a.found);
            if (l.window) |w| w.redraw();
        }
        send(l);
    }
};
