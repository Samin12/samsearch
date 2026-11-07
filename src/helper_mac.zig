//! The bundled Quick Ask helper, checked off the UI thread on panel show.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const relative = "/Contents/Helpers/Quick Ask.app";
const bundle_id = "com.samin.quickask";
pub const State = enum { absent, launching, running, unhealthy, stale, restarting, limited };
pub const Observation = enum { missing, healthy, failed, stale, restart };
pub const Action = enum { none, launch, restart };

/// Only the worker owns this state; transitions are also testable without AppKit.
pub const Supervisor = struct {
    state: State = .absent,
    failures: u8 = 0,
    restarts: u8 = 0,
    since: f64 = 0,

    pub fn observe(s: *Supervisor, observation: Observation, now: f64) Action {
        if (now - s.since >= 120) {
            s.since = now;
            s.restarts = 0;
        }
        switch (observation) {
            .healthy => {
                s.state = .running;
                s.failures = 0;
                return .none;
            },
            .failed => {
                s.failures +|= 1;
                s.state = .unhealthy;
                if (s.failures < 2) return .none;
            },
            .stale => s.state = .stale,
            .restart => {},
            .missing => s.state = .absent,
        }
        if (s.restarts >= 5) {
            s.state = .limited;
            return .none;
        }
        s.restarts += 1;
        s.failures = 0;
        s.state = if (observation == .missing) .launching else .restarting;
        return if (observation == .missing) .launch else .restart;
    }
};

var supervisor: Supervisor = .{};
var helper: [2048]u8 = undefined;
var helper_len: usize = 0;
var helper_io: std.Io = undefined;
var busy: std.atomic.Value(bool) = .init(false);
var stopped: std.atomic.Value(bool) = .init(true);
var forced: std.atomic.Value(bool) = .init(false);
var last_check: f64 = -100;

pub fn start(io: std.Io) void {
    const path = helperPath(&helper) orelse return;
    helper_len = path.len;
    helper_io = io;
    stopped.store(false, .release);
    check();
}

pub fn check() void {
    if (stopped.load(.acquire)) return;
    const now = time();
    if (!forced.load(.acquire) and now - last_check < 10) return;
    if (busy.swap(true, .acq_rel)) return;
    last_check = now;
    const thread = std.Thread.spawn(.{}, inspect, .{}) catch {
        busy.store(false, .release);
        return;
    };
    thread.detach();
}

/// A failed panel page asks for a restart, even between periodic checks.
pub fn restart() void {
    forced.store(true, .release);
    check();
}

pub fn stop() void {
    if (stopped.swap(true, .acq_rel)) return;
    terminate();
}

fn time() f64 {
    return objc.msg(f64, objc.class("NSDate"), "timeIntervalSinceReferenceDate", .{});
}

fn applications() objc.Object {
    return objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{objc.nsString(bundle_id)});
}

fn terminate() void {
    quit("terminate");
}

/// For a helper that ignored `terminate` (hung, or mid-turn).
fn forceTerminate() void {
    quit("forceTerminate");
}

fn quit(comptime how: [:0]const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const list = applications();
    for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        const app = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        _ = objc.msg(objc.BOOL, app, how, .{});
    }
}

/// Waits up to `tenths` × 0.1 s for every helper to be gone.
fn gone(tenths: usize) bool {
    for (0..tenths) |_| {
        if (stopped.load(.acquire)) return false;
        if (objc.msg(objc.NSUInteger, applications(), "count", .{}) == 0) return true;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return objc.msg(objc.NSUInteger, applications(), "count", .{}) == 0;
}

fn inspect() void {
    // Taken first, so every way out of this check has used it: only a
    // request made while checking (another failed page) runs one more.
    const restart_asked = forced.swap(false, .acq_rel);
    defer {
        busy.store(false, .release);
        if (forced.load(.acquire) and !stopped.load(.acquire)) objc.dispatchMain(null, checkAgain);
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    if (stopped.load(.acquire)) return;
    const path = helper[0..helper_len];
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    // No helper in this bundle (a bare dev build): nothing to start.
    if (objc.msg(objc.BOOL, fm, "fileExistsAtPath:", .{objc.nsString(path)}) == objc.NO) return;
    const list = applications();
    const count = objc.msg(objc.NSUInteger, list, "count", .{});
    var observation: Observation = if (count == 0) .missing else .healthy;
    for (0..count) |i| {
        const app = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const url = objc.msg(?objc.Object, app, "bundleURL", .{}) orelse continue;
        const actual = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
        if (!std.mem.eql(u8, actual, path)) {
            observation = .stale;
            break;
        }
        const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "bundleWithPath:", .{objc.nsString(path)});
        const exe = objc.msg(?objc.Object, bundle, "executablePath", .{}) orelse continue;
        const attrs = objc.msg(?objc.Object, fm, "attributesOfItemAtPath:error:", .{ exe, @as(?*anyopaque, null) }) orelse continue;
        const modified = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("NSFileModificationDate")}) orelse continue;
        const launched = objc.msg(?objc.Object, app, "launchDate", .{}) orelse continue;
        if (objc.msg(f64, modified, "timeIntervalSinceDate:", .{launched}) > 0) observation = .stale;
    }
    if (restart_asked) {
        observation = if (count == 0) .missing else .restart;
    } else if (observation == .healthy) {
        if (!run(&.{ "/usr/bin/curl", "--fail", "--silent", "--max-time", "2", "http://127.0.0.1:47213/health" })) observation = .failed;
    }
    const action = supervisor.observe(observation, time());
    if (action == .none or stopped.load(.acquire)) return;
    if (action == .restart) {
        terminate();
        // Give the old server time to release its port; this is the worker.
        if (!gone(20)) {
            forceTerminate();
            if (!gone(10)) return;
        }
    }
    if (stopped.load(.acquire)) return;
    _ = run(&.{ "/usr/bin/open", "-g", path });
    // A quit racing LaunchServices must not leave an orphan helper.
    if (stopped.load(.acquire)) terminate();
}

fn checkAgain(_: ?*anyopaque) callconv(.c) void {
    check();
}

fn run(argv: []const []const u8) bool {
    var child = std.process.spawn(helper_io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(helper_io) catch return false;
    return term == .exited and term.exited == 0;
}

fn helperPath(buf: []u8) ?[]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const main = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    const bundle = objc.fromNSString(objc.msg(?objc.Object, main, "bundlePath", .{}));
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ bundle, relative }) catch null;
}
