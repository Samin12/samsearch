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
pub const signed_out_key = "nanolight.account.signed_out";
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

/// All asynchronous work owns its flow identity and a copy of its key.
/// A stale completion must not even clear the current flow's busy state.
pub const Pending = struct {
    account: *Account,
    epoch: u64,
    revision: u64,
    key: ?[]u8,

    fn current(p: *const Pending, state: State) bool {
        const a = p.account;
        if (a.epoch != p.epoch or a.state != state) return false;
        if (state == .signed_in) {
            const key = a.key orelse return false;
            const kept = p.key orelse return false;
            return std.mem.eql(u8, key, kept);
        }
        return true;
    }

    fn deinit(p: *Pending) void {
        const gpa = p.account.gpa;
        if (p.key) |key| gpa.free(key);
        gpa.destroy(p);
    }
};

/// Injected in tests: callbacks are driven directly, without a browser,
/// timer, network request or system credential store.
pub const Effects = struct {
    ctx: *anyopaque,
    fetch: *const fn (*anyopaque, nanoui.http.Request, *Pending, *const fn (*Pending, nanoui.http.Response) void) void,
    after: *const fn (*anyopaque, u64, *Pending, *const fn (?*anyopaque) callconv(.c) void) void,
    open: *const fn (*anyopaque, []const u8) void,
    get_key: *const fn (*anyopaque, std.mem.Allocator) ?[]u8,
    set_key: *const fn (*anyopaque, []const u8) bool,
    remove_key: *const fn (*anyopaque) bool,
};

pub const Account = struct {
    gpa: std.mem.Allocator,
    kv: nanoui.kv.Store,
    hooks: Hooks,
    base: []const u8 = gateway,
    effects: ?*const Effects = null,
    state: State = .signed_out,
    epoch: u64 = 0,
    key: ?[]u8 = null,
    email_buf: [128]u8 = undefined,
    email_len: usize = 0,
    device_code: [64]u8 = undefined,
    interval_ms: u64 = 5000,
    deadline: i64 = 0,
    last_pull: i64 = 0,
    poll: enum { idle, scheduled, in_flight } = .idle,
    sync: enum { idle, pulling, pushing, pushing_then_pull } = .idle,
    revision: u64 = 0,

    pub fn email(a: *const Account) []const u8 {
        return a.email_buf[0..a.email_len];
    }

    /// A persisted sign-out wins even if deleting the Keychain item failed.
    pub fn load(a: *Account) void {
        if (a.state != .signed_out or a.kv.has(signed_out_key)) return;
        a.key = if (a.effects) |e| e.get_key(e.ctx, a.gpa) else liveGet(a.gpa);
        if (a.key == null) return;
        a.newFlow();
        if (a.kv.get(a.gpa, email_key) catch null) |e| {
            defer a.gpa.free(e);
            a.setEmail(e);
        }
        a.state = .signed_in;
        a.pull();
    }

    fn newFlow(a: *Account) void {
        a.epoch +%= 1;
        a.poll = .idle;
        a.sync = .idle;
        a.last_pull = 0;
        a.revision = 0;
    }

    fn pending(a: *Account) ?*Pending {
        const p = a.gpa.create(Pending) catch return null;
        const key = if (a.key) |k| a.gpa.dupe(u8, k) catch {
            a.gpa.destroy(p);
            return null;
        } else null;
        p.* = .{ .account = a, .epoch = a.epoch, .revision = a.revision, .key = key };
        return p;
    }

    fn fetch(a: *Account, req: nanoui.http.Request, p: *Pending, comptime done: fn (*Pending, nanoui.http.Response) void) void {
        if (a.effects) |e| return e.fetch(e.ctx, req, p, done);
        if (@import("builtin").is_test) @panic("account tests must inject effects");
        nanoui.http.fetch(a.gpa, req, p, done);
    }

    fn after(a: *Account, ms: u64, p: *Pending, comptime done: fn (?*anyopaque) callconv(.c) void) void {
        if (a.effects) |e| return e.after(e.ctx, ms, p, done);
        if (@import("builtin").is_test) @panic("account tests must inject effects");
        nanoui.App.after(ms, p, done);
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
        a.newFlow();
        a.state = .starting;
        const p = a.pending() orelse return a.fail();
        a.hooks.changed(a.hooks.ctx);
        var u: [256]u8 = undefined;
        a.fetch(.{
            .url = a.url(&u, "/v1/device/start"),
            .method = "POST",
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .body = "{\"device_label\":\"nanolight\"}",
            .timeout = 15,
        }, p, started);
    }

    fn started(p: *Pending, r: nanoui.http.Response) void {
        defer p.deinit();
        if (!p.current(.starting)) return;
        const a = p.account;
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
        if (a.effects) |e| e.open(e.ctx, st.verification_uri_complete) else {
            if (@import("builtin").is_test) @panic("account tests must inject effects");
            _ = nanoui.shell.openUrl(st.verification_uri_complete);
        }
        a.hooks.changed(a.hooks.ctx);
        a.schedulePoll();
    }

    fn fail(a: *Account) void {
        a.newFlow();
        a.state = .signed_out;
        a.hooks.changed(a.hooks.ctx);
    }

    fn schedulePoll(a: *Account) void {
        if (a.state != .waiting or a.poll != .idle) return;
        const p = a.pending() orelse return a.fail();
        a.poll = .scheduled;
        a.after(a.interval_ms, p, pollC);
    }

    fn pollC(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Pending = @ptrCast(@alignCast(ctx.?));
        const a = p.account;
        if (!p.current(.waiting) or a.poll != .scheduled) return p.deinit();
        if (now() > a.deadline) {
            p.deinit();
            return a.fail();
        }
        a.poll = .in_flight;
        var u: [256]u8 = undefined;
        var body: [128]u8 = undefined;
        a.fetch(.{
            .url = a.url(&u, "/v1/device/poll"),
            .method = "POST",
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .body = std.fmt.bufPrint(&body, "{{\"device_code\":\"{s}\"}}", .{a.device_code}) catch unreachable,
            .timeout = 15,
        }, p, polled);
    }

    fn polled(p: *Pending, r: nanoui.http.Response) void {
        defer p.deinit();
        const a = p.account;
        if (!p.current(.waiting) or a.poll != .in_flight) return;
        a.poll = .idle;
        if (now() > a.deadline) return a.fail();
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const Poll = struct { status: []const u8 = "", api_key: ?[]const u8 = null, email: ?[]const u8 = null };
        const result = std.json.parseFromSliceLeaky(Poll, arena.allocator(), r.body, .{ .ignore_unknown_fields = true }) catch Poll{};
        if (r.status == 0 or std.mem.eql(u8, result.status, "pending")) return a.schedulePoll();
        const key = result.api_key orelse return a.fail();
        if (r.status != 200 or !std.mem.eql(u8, result.status, "ok") or key.len == 0) return a.fail();
        const kept = a.gpa.dupe(u8, key) catch return a.fail();
        const saved = if (a.effects) |e| e.set_key(e.ctx, key) else liveSet(key);
        if (!saved) {
            a.gpa.free(kept);
            return a.fail();
        }
        a.kv.remove(signed_out_key);
        a.key = kept;
        if (result.email) |e| {
            a.setEmail(e);
            a.kv.set(email_key, e) catch {};
        }
        a.state = .signed_in;
        a.hooks.changed(a.hooks.ctx);
        a.pull();
    }

    /// Starting and waiting are both cancellable. Revocation is best effort;
    /// local sign-out is authoritative even if credentials cannot be removed.
    pub fn signOut(a: *Account) void {
        if (a.key != null) if (a.pending()) |p| {
            var u: [256]u8 = undefined;
            var auth: [256]u8 = undefined;
            a.fetch(.{
                .url = a.url(&u, "/v1/keys/revoke"),
                .method = "POST",
                .headers = &.{.{ .name = "Authorization", .value = a.bearer(&auth) }},
                .timeout = 15,
            }, p, revoked);
        };
        a.forget();
    }

    fn revoked(p: *Pending, _: nanoui.http.Response) void {
        p.deinit();
    }

    fn forget(a: *Account) void {
        a.newFlow();
        // Write the tombstone before touching the system store. Never load a
        // leftover key after a failed deletion (or a crash during deletion).
        a.kv.set(signed_out_key, "1") catch |err| std.log.warn("samsearch: couldn't persist sign-out ({s})", .{@errorName(err)});
        const removed = if (a.effects) |e| e.remove_key(e.ctx) else liveRemove();
        if (!removed) std.log.warn("samsearch: couldn't remove account key; persisted sign-out prevents loading it", .{});
        if (a.key) |key| a.gpa.free(key);
        a.key = null;
        a.kv.remove(email_key);
        a.kv.remove(synced_key);
        a.email_len = 0;
        a.state = .signed_out;
        a.hooks.changed(a.hooks.ctx);
    }

    // ----- syncing -----

    pub fn maybePull(a: *Account) void {
        if (a.state == .signed_in and now() - a.last_pull > pull_every_s) a.pull();
    }

    pub fn pull(a: *Account) void {
        if (a.state != .signed_in) return;
        switch (a.sync) {
            .pulling, .pushing_then_pull => return,
            .pushing => {
                a.sync = .pushing_then_pull;
                return;
            },
            .idle => {},
        }
        const p = a.pending() orelse return;
        a.sync = .pulling;
        var u: [256]u8 = undefined;
        var auth: [256]u8 = undefined;
        a.fetch(.{
            .url = a.url(&u, "/v1/sync/nanolight?since=0&limit=1000"),
            .headers = &.{.{ .name = "Authorization", .value = a.bearer(&auth) }},
            .timeout = 15,
        }, p, pulled);
    }

    fn pulled(p: *Pending, r: nanoui.http.Response) void {
        defer p.deinit();
        const a = p.account;
        if (!p.current(.signed_in) or a.sync != .pulling) return;
        a.sync = .idle;
        if (r.status == 401 or r.status == 403) return a.forget();
        if (r.status != 200) return;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const al = arena.allocator();
        const Rec = struct { id: []const u8, body: ?[]const u8 = null, deleted: bool = false };
        const Page = struct { records: []const Rec, has_more: bool = false };
        const page = std.json.parseFromSliceLeaky(Page, al, r.body, .{ .ignore_unknown_fields = true }) catch return;
        var remote: ?Settings = null;
        var found = false;
        for (page.records) |rec| if (std.mem.eql(u8, rec.id, "settings")) {
            found = true;
            if (!rec.deleted) {
                remote = settings.decode(al, rec.body orelse return) orelse return;
            }
        };
        // Do not infer that settings are absent from a partial listing.
        // The gateway may cap the limit. Only a wholly empty collection
        // proves this is a new account; any nonempty page missing our ID
        // must fail closed until the gateway offers an exact-ID read.
        if (!found and (page.has_more or page.records.len != 0)) {
            std.log.warn("samsearch: sync skipped: settings record absent from first page ({d} records, has_more={}); remote left unchanged", .{ page.records.len, page.has_more });
            return;
        }
        a.last_pull = now();
        const here = a.hooks.snapshot(a.hooks.ctx, al);
        const theirs = remote orelse return a.send(here);
        const merged = settings.merge(al, here, theirs, !a.kv.has(synced_key)) catch return;
        a.hooks.apply(a.hooks.ctx, merged);
        a.kv.set(synced_key, "1") catch {};
        if (!settings.same(merged, theirs)) a.send(merged);
    }

    /// Changes debounce by revision, then pull before pushing. A push and a
    /// pull never overlap; a response merges with the latest local snapshot.
    pub fn changed(a: *Account) void {
        if (a.state != .signed_in) return;
        a.revision +%= 1;
        const p = a.pending() orelse return;
        a.after(push_after_ms, p, pushC);
    }

    fn pushC(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Pending = @ptrCast(@alignCast(ctx.?));
        defer p.deinit();
        if (!p.current(.signed_in) or p.revision != p.account.revision) return;
        p.account.pull();
    }

    fn send(a: *Account, s: Settings) void {
        if (a.state != .signed_in or a.sync != .idle) return;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const al = arena.allocator();
        const rec = settings.encode(al, s) catch return;
        const Push = struct { records: []const struct { id: []const u8, body: []const u8 } };
        const body = std.json.Stringify.valueAlloc(al, Push{ .records = &.{.{ .id = "settings", .body = rec }} }, .{}) catch return;
        const p = a.pending() orelse return;
        a.sync = .pushing;
        var u: [256]u8 = undefined;
        var auth: [256]u8 = undefined;
        a.fetch(.{
            .url = a.url(&u, "/v1/sync/nanolight"),
            .method = "POST",
            .headers = &.{ .{ .name = "Authorization", .value = a.bearer(&auth) }, .{ .name = "Content-Type", .value = "application/json" } },
            .body = body,
            .timeout = 15,
        }, p, sent);
    }

    fn sent(p: *Pending, r: nanoui.http.Response) void {
        defer p.deinit();
        const a = p.account;
        if (!p.current(.signed_in) or (a.sync != .pushing and a.sync != .pushing_then_pull)) return;
        const again = a.sync == .pushing_then_pull or a.revision != p.revision;
        a.sync = .idle;
        if (r.status == 401 or r.status == 403) return a.forget();
        if (r.status == 200) a.kv.set(synced_key, "1") catch {};
        if (again) a.pull();
    }
};

fn liveGet(gpa: std.mem.Allocator) ?[]u8 {
    if (@import("builtin").is_test) @panic("account tests must inject effects");
    return keychain.get(gpa, service, key_account);
}

fn liveSet(key: []const u8) bool {
    if (@import("builtin").is_test) @panic("account tests must inject effects");
    return keychain.set(service, key_account, key);
}

fn liveRemove() bool {
    if (@import("builtin").is_test) @panic("account tests must inject effects");
    return keychain.remove(service, key_account);
}

extern "c" fn time(t: ?*i64) i64;

pub fn now() i64 {
    return time(null);
}
