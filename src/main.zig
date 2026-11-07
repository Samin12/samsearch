//! Nanolight, after Peekalight: a launcher that opens over everything on
//! ⌘Space, or the key picked in its welcome (onboard.zig), or from its
//! menu bar icon; finds apps as you type (initials
//! too: "ss" is System Settings), answers math, and hands anything else to
//! Quick Ask, T3, DigUp or Google, with Google's completions of it (suggest.zig) and its
//! results in the panel (preview.zig). Its panel is the system's vibrancy
//! (NSVisualEffectView, as launchers use), nanoui drawing on it.
//! It lives in the menu bar: no Dock icon, nothing drawn while idle.
//! `zig build run`, or `zig build app` and open zig-out/Nanolight.app.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const mac = builtin.os.tag == .macos;
const apps = @import("apps.zig");
const Index = apps.Index;
const view = @import("view.zig");
const Nanolight = view.Nanolight;
const hotkey = @import("hotkey.zig");
const shortcut = @import("shortcut.zig");
const Onboard = @import("onboard.zig").Onboard;
const suggest = @import("suggest.zig");
/// The panel's window, the page in it and clicks through it: the Mac's own,
/// or Windows' and Linux's (panel_pc.zig, pc_stubs.zig).
const panel = if (mac) @import("panel_mac.zig") else @import("panel_pc.zig");
const preview_mod = if (mac) @import("preview.zig") else @import("pc_stubs.zig");
const Preview = preview_mod.Preview;
const single = @import("single.zig");
const ClickThrough = if (mac) @import("clickthrough.zig").ClickThrough else @import("pc_stubs.zig").ClickThrough;
const Recorder = if (mac) @import("recorder.zig").Recorder else @import("pc_stubs.zig").Recorder;
const account = @import("account.zig");
const rc = @import("raycast_live.zig");
const Settings = @import("settings.zig").Settings;
const suggest_key = "nanolight.suggest";
/// "1": Return opens searches in the browser (issue #10).
const searches_out_key = "nanolight.searches_out";
/// "0": no menu bar icon (issue #8).
const menu_bar_key = "nanolight.menu_bar";

pub fn applyChoice(ctx: *anyopaque, choice: shortcut.Choice) void {
    Live.apply(ctx, choice);
}

pub fn tryApplyChoice(ctx: *anyopaque, choice: shortcut.Choice) anyerror!void {
    const live: *Live = @ptrCast(@alignCast(ctx));
    try live.changeKey(choice);
}

pub fn loginStatus(_: *anyopaque, set: ?bool) @import("settings_host.zig").LoginState {
    const login = @import("login.zig");
    if (set != null) _ = login.login(set);
    return switch (login.state()) {
        .enabled => .on,
        .requires_approval => .requires_approval,
        .off, .unavailable => .off,
    };
}

pub fn loginSettings(_: *anyopaque) void {
    @import("login.zig").openSettings();
}

pub fn recordKey(ctx: *anyopaque, on: bool) void {
    Live.record(ctx, on);
}

pub fn loginItem(ctx: *anyopaque, set: ?bool) bool {
    return Live.login(ctx, set);
}
/// The version 0.1.6 and before left when they restarted into an update
/// themselves (nanoui's updater does it now, `autoRestart`).
pub const updated_key = "nanolight.updated";
/// When this Mac last changed its key or suggestions (settings.zig's `at`).
const sync_at_key = "nanolight.sync.at";

/// The app around the panel: its window, shown and hidden (panel_mac.zig,
/// panel_pc.zig), its key, its menu, its updates and its account.
pub const Live = struct {
    app: *nanoui.App,
    s: *Nanolight,
    o: *Onboard,
    kv: nanoui.kv.Store,
    choice: shortcut.Choice = .cmd_space,
    window: ?*nanoui.Window = null,
    preview: Preview = .{},
    /// Clicks outside the panel go to what is under it (clickthrough.zig).
    through: ClickThrough = .{},
    /// A key of one's own, being recorded in Settings (recorder.zig).
    recorder: Recorder = .{},
    /// The words Google is to be asked about once typing pauses, and how
    /// many pauses are still being waited out (only the last one asks).
    asking: [suggest.max_len]u8 = undefined,
    asking_len: usize = 0,
    asking_generation: u64 = 0,
    waiting: u32 = 0,
    files: @import("files_live.zig").State = .{},
    digup: @import("digup_live.zig").State = .{},
    drag: if (mac) @import("drag_mac.zig").Drag else struct {} = .{},
    /// Updates from GitHub's releases (a signed build only), and the menu
    /// bar icon whose menu offers one once it's ready.
    updater: ?*nanoui.Updater = null,
    tray: ?*nanoui.Tray = null,
    update_label: [64]u8 = undefined,
    /// Signed in to Codegraff, settings synced between Macs (account.zig).
    /// Null in headless runs.
    acct: ?account.Account = null,
    account_label: [192]u8 = undefined,
    /// Raycast extensions: the command running in the panel (raycast_live.zig).
    ext_ui: @import("raycast_view.zig").Ext = undefined,
    runner: @import("raycast.zig").Runner = undefined,
    /// Raycast script commands, run by Nanolight itself (script_run.zig).
    scripts: @import("script_run.zig").Runner = undefined,
    env: ?*const std.process.Environ.Map = null,
    /// The next `hide` is skipped: a command just took the panel.
    keep_open: bool = false,
    visibility: enum { hidden, shown, hiding } = .hidden,
    key_error: ?anyerror = null,
    pending_key: ?shortcut.Choice = null,

    fn host(l: *Live) view.Host {
        const bind = @import("settings_bind.zig");
        bind.box.ctx = l;
        return .{ .ctx = l, .open = open, .hide = hide, .resize = resize, .suggest = ask, .files = if (mac) @import("files_live.zig").askFiles else null, .digup = if (mac) @import("digup_live.zig").ask else null, .reveal = if (mac) revealFile else null, .chrome = if (mac) openInChrome else null, .preview = if (mac) showPage else null, .move_answer = if (mac) moveAnswer else null, .settings = &bind.box };
    }

    fn openInChrome(ctx: *anyopaque, profile: []const u8, url: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        @import("gmail.zig").openInChrome(l.app.io, profile, url);
    }

    fn revealFile(_: *anyopaque, path: []const u8) void {
        if (comptime !mac) return;
        const objc = nanoui.objc;
        const pool = objc.Pool.push();
        defer pool.pop();
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
        const urls = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{url});
        const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
        objc.msg(void, ws, "activateFileViewerSelectingURLs:", .{urls});
    }

    fn open(ctx: *anyopaque, target: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (apps.isUrl(target)) {
            _ = nanoui.shell.openUrl(target);
        } else if (rc.isCommand(target)) {
            rc.start(l, target);
            nanoui.App.after(0, l, clearKeepOpen);
        } else if (single.isSelf(target)) {
            // Nanolight is already open: the panel comes back, empty,
            // rather than macOS starting a second copy.
            l.s.query.clear();
            nanoui.App.after(60, l, struct {
                fn f(c: ?*anyopaque) callconv(.c) void {
                    toggle(c.?);
                }
            }.f);
        } else {
            _ = apps.launch(l.app.io, target);
            // Its count went up: the other Macs suggest it too.
            if (l.acct) |*a| a.changed();
        }
    }

    // ----- sync (account.zig) -----

    fn accountHooks(l: *Live) account.Hooks {
        return .{ .ctx = l, .snapshot = snapshot, .apply = applySynced, .changed = accountChanged };
    }

    fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator) Settings {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const ix = l.s.index;
        var list: std.ArrayList(@import("settings.zig").Launch) = .empty;
        for (ix.apps.items, ix.launches.items) |a, n| if (n > 0) list.append(arena, .{ .name = a.name, .path = a.path, .count = n }) catch break;
        var at: i64 = 0;
        if (l.kv.get(arena, sync_at_key) catch null) |v| at = std.fmt.parseInt(i64, v, 10) catch 0;
        const name = arena.create([32]u8) catch return .{ .hotkey = "cmd_space", .suggest = l.s.suggest_on, .at = at, .launches = list.items };
        return .{ .hotkey = l.choice.name(name), .suggest = l.s.suggest_on, .at = at, .launches = list.items };
    }

    /// The account's settings, merged: the key, the suggestions, the counts.
    fn applySynced(ctx: *anyopaque, st: Settings) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        var at: [24]u8 = undefined;
        l.kv.set(sync_at_key, std.fmt.bufPrint(&at, "{d}", .{st.at}) catch "0") catch {};
        if (shortcut.Choice.parse(st.hotkey)) |c| if (!c.eql(l.choice)) {
            if (l.recorder.active()) {
                l.pending_key = c;
            } else {
                if (l.useKey(c)) |_| {
                    shortcut.save(l.kv, c);
                } else |_| {}
            }
        };
        if (st.suggest != l.s.suggest_on) {
            l.s.suggest_on = st.suggest;
            l.kv.set(suggest_key, if (st.suggest) "1" else "0") catch {};
        }
        const ix = l.s.index;
        for (st.launches) |la| {
            const i = if (la.path.len > 0)
                ix.findPath(la.path) orelse ix.find(la.name)
            else
                ix.find(la.name);
            if (i) |idx| ix.launches.items[idx] = @max(ix.launches.items[idx], la.count);
        }
        ix.save(l.kv);
        l.s.built = 1;
        l.menu();
        if (l.window) |w| w.redraw();
    }

    fn accountChanged(ctx: *anyopaque) void {
        menu(@ptrCast(@alignCast(ctx)));
    }

    /// This Mac chose its key or turned suggestions on or off, just now.
    fn touched(l: *Live) void {
        var at: [24]u8 = undefined;
        l.kv.set(sync_at_key, std.fmt.bufPrint(&at, "{d}", .{account.now()}) catch "0") catch {};
        if (l.acct) |*a| a.changed();
    }

    fn accountClick(l: *Live, _: *nanoui.menu.Item) void {
        const a = if (l.acct) |*x| x else return;
        switch (a.state) {
            .signed_out => a.signIn(),
            .starting, .waiting, .signed_in => a.signOut(),
        }
    }

    fn openTerms(_: *Live, _: *nanoui.menu.Item) void {
        _ = nanoui.shell.openUrl(account.terms_url);
    }

    fn accountItems(l: *Live) [2]nanoui.menu.MenuItem {
        return @import("account_menu.zig").items(if (l.acct) |*x| x else null, &l.account_label, .of(l, Live.accountClick), .of(l, Live.openTerms));
    }

    /// Google is asked once typing pauses (`suggest.pause_ms`).
    fn ask(ctx: *anyopaque, query: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const q = std.mem.trim(u8, query, " ");
        if (q.len > suggest.max_len) {
            l.s.googleAnswered(l.s.pipeline.generation, null);
            return;
        }
        @memcpy(l.asking[0..q.len], q);
        l.asking_len = q.len;
        l.asking_generation = l.s.pipeline.generation;
        l.waiting += 1;
        nanoui.App.after(suggest.pause_ms, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(c.?));
                live.waiting -= 1;
                if (live.waiting == 0) live.send();
            }
        }.f);
    }

    fn send(l: *Live) void {
        const q = l.asking[0..l.asking_len];
        // Typed on, or turned off, while it waited.
        const generation = l.asking_generation;
        if (generation != l.s.pipeline.generation or !l.s.suggest_on or !suggest.same(q, l.s.query.text())) return;
        const a = l.app.gpa.create(Ask) catch {
            l.s.googleAnswered(generation, null);
            if (l.window) |w| w.redraw();
            return;
        };
        a.* = .{ .live = l, .len = q.len, .generation = generation };
        @memcpy(a.text[0..q.len], q);
        var buf: [512]u8 = undefined;
        nanoui.http.fetch(l.app.gpa, .{
            .url = suggest.url(&buf, q),
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = 4,
        }, a, Ask.done);
    }

    /// A search's page in the panel, or (null) not.
    fn showPage(ctx: *anyopaque, url: ?[]const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const w = l.window orelse return;
        if (url) |u| l.preview.show(w, u, l.s.last_h) else l.preview.hide();
    }

    /// ⌘↩ on a Quick Ask page: its conversation moves to the floating window.
    fn moveAnswer(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (comptime mac) l.preview.moveAnswer(.{ .ctx = l, .func = answerMoved });
    }

    fn answerMoved(ctx: *anyopaque, ok: bool) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.answerMoved(ok);
        if (l.window) |w| w.redraw();
    }

    /// Escape or ⌘↩ while the page has the keys.
    fn pageKey(ctx: *anyopaque, key: preview_mod.Key) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        switch (key) {
            .escape => l.s.back(),
            .open_out => {
                var buf: [2048]u8 = undefined;
                l.s.openPreviewOut(l.preview.current(&buf));
            },
        }
        if (l.window) |w| w.redraw();
    }

    pub fn toggleSuggest(l: *Live, item: *nanoui.menu.Item) void {
        l.s.suggest_on = item.checked;
        l.kv.set(suggest_key, if (item.checked) "1" else "0") catch {};
        l.touched();
        // The rows again, with or without them.
        l.s.built = 1;
        if (l.window) |w| w.redraw();
    }

    pub fn setSearchesOut(l: *Live, on: bool) void {
        l.s.searches_out = on;
        l.kv.set(searches_out_key, if (on) "1" else "0") catch {};
    }

    /// Whether the menu bar icon shows; `set` shows or hides it. Hidden,
    /// Nanolight is its key alone: Settings stays in the panel (⌘,), and
    /// opening the app again shows the panel. The status item stays, only
    /// unseen (nanoui's App keeps its trays until it quits).
    pub fn menuBar(l: *Live, set: ?bool) bool {
        if (comptime !mac) return false;
        const objc = nanoui.objc;
        const t = l.tray orelse return false;
        if (set) |on| {
            l.kv.set(menu_bar_key, if (on) "1" else "0") catch {};
            objc.msg(void, t.item, "setVisible:", .{if (on) objc.YES else objc.NO});
        }
        return objc.msg(objc.BOOL, t.item, "isVisible", .{});
    }

    /// The menu bar icon's menu, with the update waiting, if one is.
    fn menu(l: *Live) void {
        // No tray icon in nanoui on Windows and Linux yet: Settings has it all.
        if (comptime !mac) return;
        const t = l.tray orelse return;
        const ready = if (l.updater) |u| u.ready() else null;
        const label = if (ready) |v| std.fmt.bufPrint(&l.update_label, "Restart to Update to {s}", .{v}) catch "Restart to Update" else "Check for Updates";
        const acc = l.accountItems();
        t.setMenu("SamSearch", &.{
            .{ .label = "Settings…", .accelerator = "Cmd+,", .click = .of(l, Live.menuSettings) },
            .{ .label = "Open SamSearch", .click = .of(l, Live.menuShow) },
            .{ .label = "Reset Panel Position", .click = .of(l, Live.resetPosition) },
            .{ .label = "Welcome…", .click = .of(l, Live.welcome) },
            .{ .label = "Google Suggestions", .kind = .checkbox, .checked = l.s.suggest_on, .click = .of(l, Live.toggleSuggest) },
            .separator,
            acc[0],
            acc[1],
            .separator,
            .{ .label = label, .disabled = l.updater == null, .click = .of(l, Live.updateNow) },
            .{ .label = "Quit SamSearch", .click = .of(l, Live.quitMenu) },
        }) catch {};
    }

    fn resetPosition(l: *Live, _: *nanoui.menu.Item) void {
        if (comptime mac) @import("panel_position.zig").reset(l.kv);
    }

    fn updateNow(l: *Live, _: *nanoui.menu.Item) void {
        const u = l.updater orelse return;
        if (u.ready() != null) {
            if (u.restart()) l.app.quit();
        } else u.checkNow();
    }

    fn updated(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        menu(l);
        if (!mac) @import("update_pc.zig").away(l);
    }

    /// The panel became, or stopped being, the key window (it hides as it
    /// stops): an "Updated" note is done. (An update waiting goes in once
    /// the panel has been away a while: nanoui's `autoRestart`.)
    fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        if (w.isFocused()) return;
        hidePanel(ctx);
    }

    fn clearKeepOpen(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Live = @ptrCast(@alignCast(ctx.?));
        l.keep_open = false;
    }

    fn hide(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const keep = l.keep_open;
        l.keep_open = false;
        if (!keep) hidePanel(ctx);
    }

    /// Every forced hide shares the same cleanup, including a native drag's end.
    pub fn hidePanel(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.keep_open = false;
        if (comptime mac) if (l.drag.active()) return;
        if (l.visibility == .hiding) return;
        l.visibility = .hiding;
        l.s.settings_ui.finishRecording();
        l.through.stop();
        l.s.back();
        l.preview.hide();
        l.s.note = "";
        if (l.window) |w| if (w.isVisible()) w.hide();
        l.visibility = .hidden;
        if (!mac) @import("update_pc.zig").away(l);
    }

    /// The window (or the Mac's glass under the panel) to its height.
    fn resize(ctx: *anyopaque, h: f32) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.preview.fit(h);
        // The panel grew or shrank under a still pointer.
        l.through.update();
        if (l.window) |w| panel.resize(w, h);
    }

    fn toggle(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (comptime mac) if (l.drag.active()) return;
        const w = l.window orelse return;
        const showing = w.isVisible() and panel.focused(w);
        l.o.pressed(showing);
        if (showing) hidePanel(l) else l.showPanel();
    }

    pub fn showPanel(l: *Live) void {
        const w = l.window orelse return;
        l.keep_open = false;
        if (comptime mac) {
            const objc = nanoui.objc;
            objc.msg(void, l.app.nsapp, "unhide:", .{@as(?objc.Object, null)});
            @import("helper_mac.zig").check();
        }
        if (w.isVisible() and panel.focused(w)) return;
        if (l.o.active) {
            l.s.settings_ui.finishRecording();
            l.o.refresh();
        }
        panel.place(w);
        rc.refresh(l);
        l.s.reveal();
        l.visibility = .shown;
        w.show();
        panel.shown(w);
        l.through.start();
        if (l.acct) |*a| a.maybePull();
        w.redraw();
    }

    fn hooks(l: *Live) @import("onboard.zig").Hooks {
        return .{ .ctx = l, .apply = apply, .fix = fix, .login = login, .done = done, .key_error = keyError, .starting = cancelRecording };
    }

    fn cancelRecording(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.settings_ui.finishRecording();
    }

    pub fn keyError(ctx: *anyopaque) ?[]const u8 {
        const l: *Live = @ptrCast(@alignCast(ctx));
        return if (l.key_error) |_| "That shortcut couldn't be registered. Your previous shortcut is still set." else null;
    }

    fn useKey(l: *Live, choice: shortcut.Choice) !void {
        hotkey.register(choice, .{ .ctx = l, .func = toggle }) catch |err| {
            l.key_error = err;
            return err;
        };
        l.choice = choice;
        l.key_error = null;
    }

    pub fn changeKey(l: *Live, choice: shortcut.Choice) !void {
        if (l.recorder.active()) return error.RecordingShortcut;
        try l.useKey(choice);
        shortcut.save(l.kv, choice);
        l.touched();
    }

    /// Settings records a key: until it has one, keys pressed go to it,
    /// and the current key is let go (pressed, it is recorded too).
    pub fn record(ctx: *anyopaque, on: bool) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (on) {
            l.recorder.start(.{ .ctx = l, .func = recorded });
            if (l.recorder.active()) hotkey.unregister() else {
                l.key_error = error.RecorderFailed;
                l.s.settings_ui.finishRecording();
            }
            return;
        }
        l.recorder.stop();
        const choice = l.pending_key orelse l.choice;
        l.pending_key = null;
        l.useKey(choice) catch {
            // The deferred synced key failed; resume the key recording paused.
            hotkey.register(l.choice, .{ .ctx = l, .func = toggle }) catch {};
            return;
        };
        shortcut.save(l.kv, choice);
    }

    fn recorded(ctx: *anyopaque, r: shortcut.Recorded) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.settings_ui.took(l.s, r);
        if (l.window) |w| w.redraw();
    }

    pub fn apply(ctx: *anyopaque, choice: shortcut.Choice) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.changeKey(choice) catch {
            if (l.window) |w| w.redraw();
        };
    }

    fn fix(ctx: *anyopaque, clash: shortcut.Clash) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (clash.system != null) {
            _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.Keyboard-Settings.extension");
        } else for (clash.launchers) |name| shortcut.quit(name);
        // A launcher takes a moment to quit: then the panel looks again.
        nanoui.App.after(900, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(c.?));
                live.o.refresh();
                if (live.window) |w| w.redraw();
            }
        }.f);
    }

    /// Open at login (login.zig).
    pub fn login(_: *anyopaque, set: ?bool) bool {
        return @import("login.zig").login(set);
    }

    /// `nanolight --toggle`, or a newer copy starting (single.zig).
    fn command(ctx: *anyopaque, cmd: single.Command) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        switch (cmd) {
            .toggle => toggle(l),
            .quit => l.app.quit(),
        }
    }

    fn done(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        shortcut.setOnboarded(l.kv);
    }

    fn welcome(l: *Live, item: *nanoui.menu.Item) void {
        l.s.settings_ui.finishRecording();
        l.o.start(l.choice);
        hidePanel(l);
        l.menuShow(item);
    }

    /// The menu opens the panel straight into Settings.
    fn menuSettings(l: *Live, _: *nanoui.menu.Item) void {
        nanoui.App.after(50, l, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(ctx.?));
                const w = live.window orelse return;
                live.showPanel();
                live.s.settings_ui.finishRecording();
                if (live.o.active) live.o.finish(live.s, "");
                live.s.openSettings();
                w.redraw();
            }
        }.f);
    }

    fn menuShow(l: *Live, _: *nanoui.menu.Item) void {
        // The menu closes first; then the panel takes the keys.
        nanoui.App.after(50, l, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(ctx.?));
                live.showPanel();
            }
        }.f);
    }
    fn quitMenu(l: *Live, _: *nanoui.menu.Item) void {
        l.app.quit();
    }

    fn reopen(ctx: ?*anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx orelse return));
        l.showPanel();
    }

    fn terminate(_: ?*anyopaque) void {
        if (comptime mac) @import("helper_mac.zig").stop();
    }

    fn panelKey(l: *Live) void {
        hidePanel(l);
    }
};

/// A question to Google on its way: the words it is about.
const Ask = struct {
    live: *Live,
    text: [suggest.max_len]u8 = undefined,
    len: usize,
    generation: u64,

    fn done(a: *Ask, r: nanoui.http.Response) void {
        const l = a.live;
        defer l.app.gpa.destroy(a);
        defer if (l.window) |w| w.redraw();
        if (r.status != 200) {
            l.s.googleAnswered(a.generation, null);
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(l.app.gpa);
        defer arena.deinit();
        var list: suggest.List = .{};
        if (!suggest.decode(arena.allocator(), r.body, a.text[0..a.len], &list)) {
            l.s.googleAnswered(a.generation, null);
            return;
        }
        l.s.googleAnswered(a.generation, &list);
    }
};

/// This platform's archive in each release (macos/package.sh, pc/package.sh).
const asset = switch (builtin.os.tag) {
    .macos => "nanolight-macos-arm64.zip",
    .windows => "nanolight-windows-x86_64.zip",
    else => "nanolight-linux-" ++ @tagName(builtin.cpu.arch) ++ ".tar.gz",
};
const version = @import("build_options").version;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    // `nanolight --toggle`: the running copy's panel (Wayland's shortcut);
    // `--version`: what the updater asks a downloaded copy.
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    for (try init.minimal.args.toSlice(arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var out: [64]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &out);
            try w.interface.print("samsearch {s}\n", .{version});
            return w.interface.flush();
        }
        if (std.mem.eql(u8, arg, "--toggle")) {
            if (single.send(.toggle)) return;
            break;
        }
    }
    // Linux: GTK 3, where a window can be put somewhere (GTK 4 lets only
    // the compositor place one), unless the user asked for another.
    if (builtin.os.tag == .linux and std.c.getenv("NANOUI_GTK") == null) _ = setenv("NANOUI_GTK", "3", 0);
    // Copy installed commands before app/kv initialization creates the new folder.
    const data = try @import("data_dir.zig").prepare(init.gpa, init.io);
    init.gpa.free(data);
    const app = try nanoui.App.create(init, .{ .name = "SamSearch", .quit_on_last_window_closed = false, .on_reopen = Live.reopen, .on_terminate = Live.terminate });
    defer app.destroy();
    var index: Index = .init(init.gpa);
    defer index.deinit();
    apps.scanSystem(&index, init.io, init.environ_map);
    const kv = nanoui.kv.standard();
    index.load(kv);
    var o: Onboard = .{};
    var s: Nanolight = .{ .index = &index, .kv = kv, .onboard = &o };
    defer s.query.deinit();
    defer s.found.deinit();
    defer s.dug.deinit();
    var live: Live = .{ .app = app, .s = &s, .o = &o, .kv = kv, .choice = shortcut.load(kv, init.gpa) };
    app.options.ctx = &live;
    s.host = live.host();
    @import("files_live.zig").load(&live);
    if (kv.get(init.gpa, @import("digup.zig").enabled_key) catch null) |v| {
        defer init.gpa.free(v);
        s.digup_on = !std.mem.eql(u8, v, "0");
    }
    // Google's completions are on unless turned off in Settings.
    if (kv.get(init.gpa, suggest_key) catch null) |v| {
        defer init.gpa.free(v);
        s.suggest_on = !std.mem.eql(u8, v, "0");
    }
    if (kv.get(init.gpa, searches_out_key) catch null) |v| {
        defer init.gpa.free(v);
        s.searches_out = std.mem.eql(u8, v, "1");
    }
    s.reveal();
    // The rows first, so a snapshot is as tall as the panel.
    s.rebuild();
    var options: nanoui.WindowOptions = .{
        .title = "SamSearch",
        .resizable = false,
        .visible = false,
        .on_key = .{ .ctx = &live, .func = Live.keyChanged },
        .content = .{ .view = .init(&s, Nanolight.view) },
    };
    panel.adjust(&options, app.flags.hidden, s.height());
    live.window = try app.newWindow(options);
    if (app.flags.hidden) return app.run();
    // Raycast extensions' commands among the apps (never in headless runs:
    // they're this machine's).
    rc.init(&live, init.environ_map);
    live.runner.hooks.hide = Live.hidePanel;
    live.scripts.hooks.hide = Live.hidePanel;
    defer rc.deinit(&live);
    rc.rescan(&live);
    // The newest launch is the one that stays; it hears `--toggle` (single.zig).
    if (single.claim(.{ .ctx = &live, .func = Live.command }) > 0) std.log.info("nanolight: asked an older copy to quit", .{});
    panel.setup(app, live.window.?, &s, if (o.active) o.height() else s.height());
    live.useKey(live.choice) catch {};
    live.through = .{ .window = live.window, .height = &s.last_h };
    if (mac) {
        live.drag.start(live.window.?, &s, &live.through);
        live.drag.on_hide = .{ .ctx = &live, .func = Live.hidePanel };
        panel.watchKeys(&live, Live.panelKey);
        try app.setMenu(&.{
            .{ .label = "SamSearch", .submenu = &.{
                .{ .role = .about },
                .{ .role = .hide },
                .separator,
                .{ .label = "Quit SamSearch", .click = .of(&live, Live.quitMenu) },
            } },
            .{ .role = .edit_menu },
        });
    } else panel.on_hide = .{ .ctx = &live, .func = Live.hidePanel };
    defer if (mac) live.drag.stop();
    live.preview.watch(.{ .ctx = &live, .func = Live.pageKey });
    o.hooks = live.hooks();
    // The first run: the welcome, in the panel.
    if (!shortcut.onboarded(kv)) o.start(live.choice);
    if (mac) live.tray = try app.newTray(.{ .symbol = "magnifyingglass", .tooltip = "SamSearch" });
    // Quick Ask, the helper inside the app: the Ask and DigUp pages, the T3 links.
    if (mac) @import("helper_mac.zig").start(init.io);
    defer if (mac) @import("helper_mac.zig").stop();
    // The menu bar icon, unless Settings took it away.
    if (kv.get(init.gpa, menu_bar_key) catch null) |v| {
        defer init.gpa.free(v);
        if (std.mem.eql(u8, v, "0")) _ = live.menuBar(false);
    }
    // A release build checks its GitHub releases; one run from zig-out
    // can't replace itself, and leaves the item off.
    // A shared nanoui development feed could belong to another launcher.
    // Disable updates under that override rather than inherit its artifacts.
    const updater = if (init.environ_map.get("NANOUI_UPDATE_FEED") == null) nanoui.Updater.start(init, .{
        .repo = "Samin12/samsearch",
        .asset = asset,
        .version = version,
        .name = "SamSearch",
        .changed = .{ .ctx = &live, .func = Live.updated },
    }) catch null else null;
    defer if (updater) |u| u.deinit();
    if (updater) |u| if (u.phase.load(.acquire) != .off) {
        live.updater = u;
        // A launcher almost never quits, so installing at quit would mean
        // never: it restarts into an update once the panel has been away
        // 10 s, unseen, and comes back as it was (update_pc.zig off the Mac).
        u.autoRestart(app, .{ .idle_ms = 10 * 1000 });
        if (u.updatedFrom() != null) Live.hidePanel(&live);
    };
    // Signed in before: synced now. Signing in is from the menu.
    live.acct = .{ .gpa = init.gpa, .kv = kv, .hooks = live.accountHooks() };
    live.acct.?.load();
    live.menu();
    // Restarted by an automatic update: quietly, the panel saying so the
    // next time it opens. Otherwise launching shows the panel.
    var note_buf: [64]u8 = undefined;
    const old = kv.get(init.gpa, updated_key) catch null;
    defer if (old) |v| init.gpa.free(v);
    if (old != null) kv.remove(updated_key);
    const restarted = if (live.updater) |u| u.updatedFrom() != null else false;
    if (restarted or old != null) {
        const now = if (live.updater) |u| u.current else old.?;
        s.note = std.fmt.bufPrint(&note_buf, "Updated to {s}", .{now}) catch "Updated";
    } else Live.toggle(&live);
    try app.run();
}
