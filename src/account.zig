//! Signing in to Codegraff, and syncing settings (settings.zig) through it
//! to every Mac on the same account. Optional: nothing leaves the Mac until
//! someone signs in from the menu bar, and signing out stops it.
//!
//! Sign-in is the device flow graff uses (the gateway's /v1/device/*): the
//! browser opens codegraff.com to approve it, where Codegraff's terms and
//! privacy policy apply, and the key it gives is kept in the Keychain. Its
//! label is `nanolight`, which credits a new account (frontend/src/lib/
//! signup-source.ts in zigrepper). The record lives in the gateway's sync
//! store (/v1/sync/nanolight, the account's own, which browse's sync uses
//! too). It is pulled at launch, after signing in, and when the panel opens
//! if the last pull is five minutes old; pushed two seconds after a change.
const std = @import("std");
const nanoui = @import("nanoui");
const settings = @import("settings.zig");
const keychain = @import("keychain.zig");
const Settings = settings.Settings;

pub const gateway = "https://gateway.codegraff.com";
pub const terms_url = "https://codegraff.com/terms";
const service = "dev.samin.samsearch";
const key_account = "codegraff";
const email_key = "nanolight.account.email";
/// Set once this Mac has synced: from then on its own later choices win.
const synced_key = "nanolight.account.synced";
const pull_every_s = 5 * 60;
const push_after_ms = 2000;

pub const Hooks = struct {
    ctx: *anyopaque,
    /// This Mac's settings now (allocated with `arena`).
    snapshot: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) Settings,
    /// The account's settings merged with this Mac's: take them.
    apply: *const fn (ctx: *anyopaque, s: Settings) void,
    /// Signed in or out, or waiting on the browser: the menu changes.
    changed: *const fn (ctx: *anyopaque) void,
};

pub const State = enum { signed_out, starting, waiting, signed_in };

pub const Account = struct {
    gpa: std.mem.Allocator,
    kv: nanoui.kv.Store,
    hooks: Hooks,
    base: []const u8 = gateway,
    state: State = .signed_out,
    key: ?[]u8 = null,
    email_buf: [128]u8 = undefined,
    email_len: usize = 0,
    device_code: [64]u8 = undefined,
    interval_ms: u64 = 5000,
    deadline: i64 = 0,
    last_pull: i64 = 0,
    pulling: bool = false,
    pushes_waiting: u32 = 0,

    pub fn email(a: *const Account) []const u8 {
        return a.email_buf[0..a.email_len];
    }

    /// At launch: signed in already if a key is kept, and then synced.
    pub fn load(a: *Account) void {
        a.key = keychain.get(a.gpa, service, key_account) orelse return;
        if (a.kv.get(a.gpa, email_key) catch null) |e| {
            defer a.gpa.free(e);
            a.setEmail(e);
        }
        a.state = .signed_in;
        a.pull();
    }

    fn setEmail(a: *Account, e: []const u8) void {
        a.email_len = @min(e.len, a.email_buf.len);
        @memcpy(a.email_buf[0..a.email_len], e[0..a.email_len]);
    }

    fn url(a: *const Account, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ a.base, path }) catch "";
    }

    fn bearer(a: *const Account, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "Bearer {s}", .{a.key orelse ""}) catch "";
    }

    // ----- signing in -----

    pub fn signIn(a: *Account) void {
        if (a.state != .signed_out) return;
        a.state = .starting;
        a.hooks.changed(a.hooks.ctx);
        var u: [256]u8 = undefined;
        nanoui.http.fetch(a.gpa, .{
            .url = a.url(&u, "/v1/device/start"),
            .method = "POST",
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .body = "{\"device_label\":\"nanolight\"}",
            .timeout = 15,
        }, a, started);
    }

    fn started(a: *Account, r: nanoui.http.Response) void {
        if (a.state != .starting) return;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const Start = struct { device_code: []const u8, verification_uri_complete: []const u8, interval: u32 = 5, expires_in: u32 = 600 };
        const s = if (r.status == 200) std.json.parseFromSliceLeaky(Start, arena.allocator(), r.body, .{ .ignore_unknown_fields = true }) catch null else null;
        const st = s orelse return a.fail();
        if (st.device_code.len != a.device_code.len or !std.mem.startsWith(u8, st.verification_uri_complete, "https://")) return a.fail();
        @memcpy(&a.device_code, st.device_code);
        a.interval_ms = @as(u64, std.math.clamp(st.interval, 2, 30)) * 1000;
        a.deadline = now() + st.expires_in;
        a.state = .waiting;
        _ = nanoui.shell.openUrl(st.verification_uri_complete);
        a.hooks.changed(a.hooks.ctx);
        nanoui.App.after(a.interval_ms, a, pollC);
    }

    fn fail(a: *Account) void {
        a.state = .signed_out;
        a.hooks.changed(a.hooks.ctx);
    }

    fn pollC(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Account = @ptrCast(@alignCast(ctx.?));
        if (a.state != .waiting) return;
        if (now() > a.deadline) return a.fail();
        var u: [256]u8 = undefined;
        var body: [128]u8 = undefined;
        nanoui.http.fetch(a.gpa, .{
            .url = a.url(&u, "/v1/device/poll"),
            .method = "POST",
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .body = std.fmt.bufPrint(&body, "{{\"device_code\":\"{s}\"}}", .{a.device_code}) catch return a.fail(),
            .timeout = 15,
        }, a, polled);
    }

    fn polled(a: *Account, r: nanoui.http.Response) void {
        if (a.state != .waiting) return;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const Poll = struct { status: []const u8 = "", api_key: ?[]const u8 = null, email: ?[]const u8 = null };
        const p = std.json.parseFromSliceLeaky(Poll, arena.allocator(), r.body, .{ .ignore_unknown_fields = true }) catch Poll{};
        // Offline for a moment, or still waiting: ask again.
        if (r.status == 0 or std.mem.eql(u8, p.status, "pending")) return nanoui.App.after(a.interval_ms, a, pollC);
        const key = p.api_key orelse return a.fail();
        if (!std.mem.eql(u8, p.status, "ok") or !keychain.set(service, key_account, key)) return a.fail();
        a.key = a.gpa.dupe(u8, key) catch return a.fail();
        if (p.email) |e| {
            a.setEmail(e);
            a.kv.set(email_key, e) catch {};
        }
        a.state = .signed_in;
        a.hooks.changed(a.hooks.ctx);
        a.pull();
    }

    /// Signs out: the key is revoked and forgotten; this Mac's settings stay.
    /// While waiting on the browser, stops waiting.
    pub fn signOut(a: *Account) void {
        if (a.key) |k| {
            var u: [256]u8 = undefined;
            var auth: [256]u8 = undefined;
            nanoui.http.fetch(a.gpa, .{
                .url = a.url(&u, "/v1/keys/revoke"),
                .method = "POST",
                .headers = &.{.{ .name = "Authorization", .value = a.bearer(&auth) }},
                .timeout = 15,
            }, a, revoked);
            a.gpa.free(k);
        }
        a.forget();
    }

    fn revoked(_: *Account, _: nanoui.http.Response) void {}

    fn forget(a: *Account) void {
        a.key = null;
        keychain.remove(service, key_account);
        a.kv.remove(email_key);
        a.kv.remove(synced_key);
        a.email_len = 0;
        a.state = .signed_out;
        a.hooks.changed(a.hooks.ctx);
    }

    // ----- syncing -----

    /// When the panel opens: the account's record, if the last look is old.
    pub fn maybePull(a: *Account) void {
        if (a.state == .signed_in and now() - a.last_pull > pull_every_s) a.pull();
    }

    pub fn pull(a: *Account) void {
        if (a.state != .signed_in or a.pulling) return;
        a.pulling = true;
        a.last_pull = now();
        var u: [256]u8 = undefined;
        var auth: [256]u8 = undefined;
        nanoui.http.fetch(a.gpa, .{
            .url = a.url(&u, "/v1/sync/nanolight?since=0&limit=10"),
            .headers = &.{.{ .name = "Authorization", .value = a.bearer(&auth) }},
            .timeout = 15,
        }, a, pulled);
    }

    fn pulled(a: *Account, r: nanoui.http.Response) void {
        a.pulling = false;
        if (a.state != .signed_in) return;
        // The key was revoked (signed out elsewhere, or deleted on the web).
        if (r.status == 401 or r.status == 403) return a.forget();
        if (r.status != 200) return;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const al = arena.allocator();
        const Rec = struct { id: []const u8, body: ?[]const u8 = null, deleted: bool = false };
        const Page = struct { records: []const Rec = &.{} };
        const page = std.json.parseFromSliceLeaky(Page, al, r.body, .{ .ignore_unknown_fields = true }) catch return;
        var remote: ?Settings = null;
        for (page.records) |rec| if (std.mem.eql(u8, rec.id, "settings") and !rec.deleted) {
            remote = settings.decode(al, rec.body orelse continue);
        };
        const here = a.hooks.snapshot(a.hooks.ctx, al);
        const first = !a.kv.has(synced_key);
        const theirs = remote orelse return a.send(here);
        const merged = settings.merge(al, here, theirs, first) catch return;
        a.hooks.apply(a.hooks.ctx, merged);
        a.kv.set(synced_key, "1") catch {};
        if (!settings.same(merged, theirs)) a.send(merged);
    }

    /// This Mac's settings changed: sent once changes pause.
    pub fn changed(a: *Account) void {
        if (a.state != .signed_in) return;
        a.pushes_waiting += 1;
        nanoui.App.after(push_after_ms, a, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const acc: *Account = @ptrCast(@alignCast(ctx.?));
                acc.pushes_waiting -= 1;
                if (acc.pushes_waiting > 0 or acc.state != .signed_in) return;
                var arena: std.heap.ArenaAllocator = .init(acc.gpa);
                defer arena.deinit();
                acc.send(acc.hooks.snapshot(acc.hooks.ctx, arena.allocator()));
            }
        }.f);
    }

    fn send(a: *Account, s: Settings) void {
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const al = arena.allocator();
        const rec = settings.encode(al, s) catch return;
        const Push = struct { records: []const struct { id: []const u8, body: []const u8 } };
        const body = std.json.Stringify.valueAlloc(al, Push{ .records = &.{.{ .id = "settings", .body = rec }} }, .{}) catch return;
        var u: [256]u8 = undefined;
        var auth: [256]u8 = undefined;
        nanoui.http.fetch(a.gpa, .{
            .url = a.url(&u, "/v1/sync/nanolight"),
            .method = "POST",
            .headers = &.{ .{ .name = "Authorization", .value = a.bearer(&auth) }, .{ .name = "Content-Type", .value = "application/json" } },
            .body = body,
            .timeout = 15,
        }, a, sent);
    }

    fn sent(a: *Account, r: nanoui.http.Response) void {
        if (r.status == 200) a.kv.set(synced_key, "1") catch {};
        if (r.status == 401 or r.status == 403) a.forget();
    }
};

extern "c" fn time(t: ?*i64) i64;

/// Unix seconds.
pub fn now() i64 {
    return time(null);
}
