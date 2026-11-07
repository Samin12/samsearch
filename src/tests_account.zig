//! Account callbacks driven directly; no network, browser or Keychain.
const std = @import("std");
const nanoui = @import("nanoui");
const account = @import("account.zig");
const settings = @import("settings.zig");
const t = std.testing;

const start_body = "{\"device_code\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"verification_uri_complete\":\"https://example.test/approve\"}";
const ok_body = "{\"status\":\"ok\",\"api_key\":\"same-key\",\"email\":\"test@example.test\"}";
const remote_body = "{\"records\":[{\"id\":\"settings\",\"body\":\"{\\\"hotkey\\\":\\\"opt_space\\\",\\\"suggest\\\":false,\\\"at\\\":100}\"}]}";

const Fixture = struct {
    const Request = struct {
        p: *account.Pending,
        done: *const fn (*account.Pending, nanoui.http.Response) void,
    };
    const Timer = struct {
        p: *account.Pending,
        done: *const fn (?*anyopaque) callconv(.c) void,
    };
    memory: nanoui.kv.Memory = .{ .gpa = t.allocator },
    a: account.Account = undefined,
    effects: account.Effects = undefined,
    requests: [64]?Request = @splat(null),
    timers: [64]?Timer = @splat(null),
    request_count: usize = 0,
    timer_count: usize = 0,
    opened: usize = 0,
    saved: usize = 0,
    loaded: usize = 0,
    removed: usize = 0,
    remove_ok: bool = true,
    applied: usize = 0,
    local: settings.Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 0 },
    last_hotkey: [32]u8 = undefined,
    last_hotkey_len: usize = 0,

    fn init(f: *Fixture) void {
        f.effects = .{ .ctx = f, .fetch = fetch, .after = after, .open = open, .get_key = getKey, .set_key = setKey, .remove_key = removeKey };
        f.a = .{ .gpa = t.allocator, .kv = f.memory.store(), .effects = &f.effects, .hooks = .{ .ctx = f, .snapshot = snapshot, .apply = apply, .changed = changed } };
    }

    fn deinit(f: *Fixture) void {
        for (f.requests) |req| if (req) |r| discard(r.p);
        for (f.timers) |timer| if (timer) |r| discard(r.p);
        if (f.a.key) |key| t.allocator.free(key);
        f.memory.deinit();
    }

    fn discard(p: *account.Pending) void {
        if (p.key) |key| t.allocator.free(key);
        t.allocator.destroy(p);
    }

    fn cast(ctx: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(ctx));
    }

    fn fetch(ctx: *anyopaque, _: nanoui.http.Request, p: *account.Pending, done: *const fn (*account.Pending, nanoui.http.Response) void) void {
        const f = cast(ctx);
        f.requests[f.request_count] = .{ .p = p, .done = done };
        f.request_count += 1;
    }

    fn after(ctx: *anyopaque, _: u64, p: *account.Pending, done: *const fn (?*anyopaque) callconv(.c) void) void {
        const f = cast(ctx);
        f.timers[f.timer_count] = .{ .p = p, .done = done };
        f.timer_count += 1;
    }

    fn respond(f: *Fixture, i: usize, status: u16, body: []const u8) void {
        const req = f.requests[i].?;
        f.requests[i] = null;
        req.done(req.p, .{ .status = status, .body = body });
    }

    fn fire(f: *Fixture, i: usize) void {
        const timer = f.timers[i].?;
        f.timers[i] = null;
        timer.done(timer.p);
    }

    fn open(ctx: *anyopaque, _: []const u8) void {
        cast(ctx).opened += 1;
    }
    fn getKey(ctx: *anyopaque, gpa: std.mem.Allocator) ?[]u8 {
        cast(ctx).loaded += 1;
        return gpa.dupe(u8, "same-key") catch null;
    }
    fn setKey(ctx: *anyopaque, _: []const u8) bool {
        cast(ctx).saved += 1;
        return true;
    }
    fn removeKey(ctx: *anyopaque) bool {
        const f = cast(ctx);
        f.removed += 1;
        return f.remove_ok;
    }
    fn snapshot(ctx: *anyopaque, _: std.mem.Allocator) settings.Settings {
        return cast(ctx).local;
    }
    fn apply(ctx: *anyopaque, s: settings.Settings) void {
        const f = cast(ctx);
        f.applied += 1;
        f.last_hotkey_len = s.hotkey.len;
        @memcpy(f.last_hotkey[0..s.hotkey.len], s.hotkey);
    }
    fn changed(_: *anyopaque) void {}

    fn signIn(f: *Fixture) void {
        f.a.signIn();
        f.respond(f.request_count - 1, 200, start_body);
        f.fire(f.timer_count - 1);
        f.respond(f.request_count - 1, 200, ok_body);
    }
};

test "sign-in epoch drops stale starts and poll timers; starting can cancel" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.a.signIn();
    const old_epoch = f.a.epoch;
    f.a.signOut();
    f.a.signIn();
    try t.expect(f.a.epoch != old_epoch);
    f.respond(0, 500, "");
    try t.expectEqual(account.State.starting, f.a.state);
    f.respond(1, 200, start_body);
    try t.expectEqual(@as(usize, 1), f.timer_count);
    f.a.signOut();
    f.a.signIn();
    f.respond(2, 200, start_body);
    f.fire(0);
    try t.expectEqual(@as(usize, 3), f.request_count);
    try t.expectEqual(.scheduled, f.a.poll);
    f.fire(1);
    try t.expectEqual(@as(usize, 4), f.request_count);
    try t.expectEqual(.in_flight, f.a.poll);
}

test "stale polled responses cannot save a key or add a second poll chain" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.a.signIn();
    f.respond(0, 200, start_body);
    f.fire(0);
    f.a.signOut();
    f.a.signIn();
    f.respond(2, 200, start_body);
    f.respond(1, 200, ok_body);
    try t.expectEqual(@as(usize, 0), f.saved);
    try t.expectEqual(account.State.waiting, f.a.state);
    try t.expectEqual(.scheduled, f.a.poll);
    f.a.signIn();
    try t.expectEqual(@as(usize, 2), f.timer_count);
    f.fire(1);
    f.respond(3, 200, "{\"status\":\"pending\"}");
    try t.expectEqual(@as(usize, 3), f.timer_count);
    try t.expectEqual(.scheduled, f.a.poll);
}

test "re-sign-in starts a fresh pull and drops stale pull apply and authorization failures" {
    for ([_]u16{ 200, 401, 403 }) |status| {
        var f: Fixture = .{};
        f.init();
        defer f.deinit();
        f.signIn();
        const old_pull = f.request_count - 1;
        f.a.signOut();
        f.signIn();
        const fresh_pull = f.request_count - 1;
        try t.expect(fresh_pull > old_pull);
        f.respond(old_pull, status, remote_body);
        try t.expectEqual(account.State.signed_in, f.a.state);
        try t.expectEqual(.pulling, f.a.sync);
        try t.expectEqual(@as(usize, 0), f.applied);
        f.respond(fresh_pull, 200, remote_body);
        try t.expectEqual(@as(usize, 1), f.applied);
        try t.expectEqualStrings("opt_space", f.last_hotkey[0..f.last_hotkey_len]);
    }
}

test "late push authorization and success responses cannot change a newer flow" {
    for ([_]u16{ 200, 401, 403 }) |status| {
        var f: Fixture = .{};
        f.init();
        defer f.deinit();
        f.signIn();
        f.respond(f.request_count - 1, 200, "{\"records\":[]}");
        const old_push = f.request_count - 1;
        try t.expectEqual(.pushing, f.a.sync);
        f.a.signOut();
        f.signIn();
        f.respond(old_push, status, "");
        try t.expectEqual(account.State.signed_in, f.a.state);
        try t.expectEqual(.pulling, f.a.sync);
        try t.expect(!f.a.kv.has(account.signed_out_key));
        try t.expect(!f.a.kv.has("nanolight.account.synced"));
    }
}

test "sync serializes pull and push, queues a fresh pull, and debounces by revision" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.signIn();
    const pull = f.request_count - 1;
    f.a.changed();
    f.a.changed();
    f.fire(1);
    f.fire(2);
    try t.expectEqual(pull + 1, f.request_count);
    f.respond(pull, 200, "{\"records\":[]}");
    const push = f.request_count - 1;
    try t.expectEqual(.pushing, f.a.sync);
    f.a.pull();
    try t.expectEqual(.pushing_then_pull, f.a.sync);
    try t.expectEqual(push + 1, f.request_count);
    f.respond(push, 200, "{}");
    try t.expectEqual(.pulling, f.a.sync);
    try t.expectEqual(push + 2, f.request_count);
}

test "partial or malformed sync listings never blindly overwrite settings" {
    for ([_][]const u8{
        "{}",
        "{\"records\":[{\"id\":\"unrelated\"}]}",
        "{\"records\":[],\"has_more\":true}",
        "{\"records\":[{\"id\":\"settings\",\"body\":\"bad json\"}]}",
        "{\"records\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"},{\"id\":\"d\"},{\"id\":\"e\"},{\"id\":\"f\"},{\"id\":\"g\"},{\"id\":\"h\"},{\"id\":\"i\"},{\"id\":\"j\"}]}",
    }) |body| {
        var f: Fixture = .{};
        f.init();
        defer f.deinit();
        f.signIn();
        const count = f.request_count;
        f.respond(count - 1, 200, body);
        try t.expectEqual(count, f.request_count);
        try t.expectEqual(@as(usize, 0), f.applied);
    }
}

test "failed credential deletion clears local account and blocks reloading a leftover key" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.signIn();
    try f.a.kv.set("nanolight.account.synced", "1");
    f.remove_ok = false;
    f.a.signOut();
    try t.expectEqual(account.State.signed_out, f.a.state);
    try t.expect(f.a.key == null and f.a.email().len == 0);
    try t.expect(!f.a.kv.has("nanolight.account.email") and !f.a.kv.has("nanolight.account.synced"));
    f.a.load();
    try t.expectEqual(@as(usize, 0), f.loaded);
    try t.expectEqual(account.State.signed_out, f.a.state);
}

test "a pull merges with the latest local edit instead of its request-time snapshot" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.signIn();
    const pull = f.request_count - 1;
    try f.a.kv.set("nanolight.account.synced", "1");
    f.local = .{ .hotkey = "ctrl_space", .suggest = true, .at = 200 };
    f.a.changed();
    f.respond(pull, 200, remote_body);
    try t.expectEqualStrings("ctrl_space", f.last_hotkey[0..f.last_hotkey_len]);
    try t.expectEqual(.pushing, f.a.sync);
}

test "a stale debounced push timer cannot start a pull in a new account flow" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    f.signIn();
    f.respond(f.request_count - 1, 200, remote_body);
    f.a.changed();
    const old_timer = f.timer_count - 1;
    f.a.signOut();
    f.signIn();
    f.respond(f.request_count - 1, 200, remote_body);
    const count = f.request_count;
    f.fire(old_timer);
    try t.expectEqual(count, f.request_count);
    try t.expectEqual(.idle, f.a.sync);
}
