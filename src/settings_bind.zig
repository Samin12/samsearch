//! Live's answers to Settings. The box is one, its context set to the
//! Live that is showing the panel (one Nanolight runs).
const nanoui = @import("nanoui");
const shortcut = @import("shortcut.zig");
const account = @import("account.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
pub var box: SettingsHost = .{
    .ctx = undefined,
    .choice = choice,
    .apply = @import("main.zig").applyChoice,
    .record = @import("main.zig").recordKey,
    .login = @import("main.zig").loginItem,
    .suggest = suggest,
    .account = acct,
    .email = email,
    .sign_in = signIn,
    .sign_out = signOut,
    .terms = terms,
    .version = version,
    .ready = ready,
    .check = check,
    .restart = restart,
    .welcome = welcome,
    .quit = quit,
};

const Live = @import("main.zig").Live;

fn l(ctx: *anyopaque) *Live {
    return @ptrCast(@alignCast(ctx));
}

fn choice(ctx: *anyopaque) shortcut.Choice {
    return l(ctx).choice;
}

fn suggest(ctx: *anyopaque, on: bool) void {
    var item: nanoui.menu.Item = undefined;
    item.checked = on;
    l(ctx).toggleSuggest(&item);
}

fn acct(ctx: *anyopaque) account.State {
    return if (l(ctx).acct) |*a| a.state else .signed_out;
}

fn email(ctx: *anyopaque) []const u8 {
    return if (l(ctx).acct) |*a| a.email() else "";
}

fn signIn(ctx: *anyopaque) void {
    if (l(ctx).acct) |*a| a.signIn();
}

fn signOut(ctx: *anyopaque) void {
    if (l(ctx).acct) |*a| a.signOut();
}

fn terms(_: *anyopaque) void {
    _ = nanoui.shell.openUrl(account.terms_url);
}

fn version(ctx: *anyopaque) []const u8 {
    const u = l(ctx).updater orelse return "0.1.0";
    return if (u.current.len > 0) u.current else "0.1.0";
}

fn ready(ctx: *anyopaque) ?[]const u8 {
    const u = l(ctx).updater orelse return null;
    return u.ready();
}

fn check(ctx: *anyopaque) void {
    if (l(ctx).updater) |u| u.checkNow();
}

fn restart(ctx: *anyopaque) void {
    const live = l(ctx);
    const u = live.updater orelse return;
    if (u.ready() != null and u.restart()) live.app.quit();
}

fn welcome(ctx: *anyopaque) void {
    const live = l(ctx);
    live.o.start(live.choice);
    if (live.window) |w| if (w.isVisible()) w.redraw();
}

fn quit(ctx: *anyopaque) void {
    l(ctx).app.quit();
}
