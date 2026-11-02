//! The first run, inside the panel itself: no tour, no permissions (Carbon's
//! hot keys need none). Three steps, each one thing to do:
//!   1. the shortcut: ⌘Space by default, and who else holds it, by name,
//!      with the one thing that frees it;
//!   2. press it for real: the panel closes, and comes back on the second
//!      press — nothing advances on a button;
//!   3. a first search to run, where Nanolight lives (the menu bar), and
//!      whether it opens at login.
//! Esc skips at any step and it stays skipped; the menu bar icon replays it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const panel = @import("view.zig");
const shortcut = @import("shortcut.zig");
const Choice = shortcut.Choice;
const Palette = panel.Palette;

pub const Step = enum { key, try_it, done };

/// What the steps ask of the app: none of it is done from a test.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Uses `choice` from now on (registers it, keeps it).
    apply: *const fn (ctx: *anyopaque, choice: Choice) void,
    /// Frees the shortcut: Keyboard Shortcuts opened, a launcher quit.
    fix: *const fn (ctx: *anyopaque, clash: shortcut.Clash) void,
    /// Whether it opens at login; `set` changes it first.
    login: ?*const fn (ctx: *anyopaque, set: ?bool) bool = null,
    /// The welcome is over: keep that.
    done: *const fn (ctx: *anyopaque) void,
};

const examples = [_]struct { q: []const u8, what: []const u8, icon: []const u8 }{
    .{ .q = "saf", .what = "Open Safari", .icon = "app.badge" },
    .{ .q = "2^10 * 3", .what = "Do math", .icon = "plus.forwardslash.minus" },
    .{ .q = "liquid glass", .what = "Ask Grok or search X", .icon = "sparkles" },
};

pub const Onboard = struct {
    active: bool = false,
    step: Step = .key,
    choice: Choice = .cmd_space,
    hooks: ?Hooks = null,
    system_buf: [96]shortcut.SystemKey = undefined,
    system: []const shortcut.SystemKey = &.{},
    others: shortcut.Others = .{},
    /// Step 2: the shortcut closed the panel, then opened it again.
    closed: bool = false,
    reopened: bool = false,
    reopened_at: ?f64 = null,
    login: bool = false,

    pub fn start(o: *Onboard, choice: Choice) void {
        o.active = true;
        o.step = .key;
        o.choice = choice;
        o.closed = false;
        o.reopened = false;
        o.reopened_at = null;
        o.refresh();
    }

    /// Looks again at who holds the keys (after a fix, on each showing).
    pub fn refresh(o: *Onboard) void {
        // Without hooks (tests, the film) what the caller set is kept.
        const h = o.hooks orelse return;
        o.system = shortcut.systemKeys(&o.system_buf);
        o.others = shortcut.runningLaunchers();
        if (h.login) |f| o.login = f(h.ctx, null);
    }

    pub fn clash(o: *const Onboard) shortcut.Clash {
        return shortcut.clash(o.choice, o.system, &o.others);
    }

    /// The hot key fired, the panel `visible` before it: step 2's presses.
    pub fn pressed(o: *Onboard, visible: bool) void {
        if (!o.active or o.step != .try_it) return;
        if (visible) o.closed = true else if (o.closed) o.reopened = true;
    }

    pub fn height(o: *const Onboard) f32 {
        const c = o.clash();
        return switch (o.step) {
            .key => 330 + @as(f32, if (c.clear()) 0 else 30),
            .try_it => 318,
            .done => if (o.hooks != null and o.hooks.?.login != null) 396 else 350,
        };
    }

    pub fn view(o: *Onboard, c: *ui.Context, s: *panel.Nanolight, p: Palette) void {
        const S = ui.Shortcut;
        const enter = c.input.key == .enter;
        // Return moves it on: what changed shows in this frame.
        if (enter) c.changed = true;
        if (c.shortcut(.{ .key = S.escape })) return o.finish(s, "");
        // A step's content comes in from the right, briefly.
        ui.key(c, @tagName(o.step));
        const f = motion.frame(c, .{ .initial = .{ .opacity = 0, .x = 14 }, .transition = .{ .spring = panel.spring } });
        const page = ui.div(c).column().wFull().grow().motion(f);
        switch (o.step) {
            .key => o.keyStep(c, p, enter),
            .try_it => o.tryStep(c, p),
            .done => o.doneStep(c, s, p, enter),
        }
        page.end();
        o.footer(c, p);
    }

    fn keyStep(o: *Onboard, c: *ui.Context, p: Palette, enter: bool) void {
        if (c.input.key == .left) o.choice = o.choice.step(-1);
        if (c.input.key == .right) o.choice = o.choice.step(1);
        if (enter) return o.next(c, .try_it);
        {
            const top = ui.div(c).row().wFull().px(28).pt(28).pb(22).gap(16).itemsCenter();
            defer top.end();
            panel.appIcon(c, 56);
            const t = ui.div(c).column().gap(4);
            defer t.end();
            ui.text(c, "Welcome to Nanolight", .{ .size = 22, .weight = .semibold, .color = p.text, .tracking = -0.3 });
            ui.text(c, "Apps, math, Grok and X — one keystroke away.", .{ .size = 13.5, .color = p.sub });
        }
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const body = ui.div(c).column().wFull().px(28).pt(18).gap(12);
        defer body.end();
        ui.text(c, "Open it with", .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
        {
            const row = ui.div(c).row().gap(8);
            defer row.end();
            // The four, and a key recorded in Settings when it is the one.
            var shown: [Choice.all.len + 1]Choice = undefined;
            @memcpy(shown[0..Choice.all.len], &Choice.all);
            shown[Choice.all.len] = o.choice;
            for (shown[0 .. Choice.all.len + @intFromBool(o.choice.preset() == null)]) |ch| {
                ui.key(c, c.print("key-{d}-{d}", .{ ch.code, ch.mods }));
                const on = ch.eql(o.choice);
                const b = ui.div(c).row().h(36).px(16).itemsCenter().rounded(10).control()
                    .bg(if (on) p.sel else p.tile.alpha(0.5)).border(if (on) p.text.alpha(0.35) else p.rim);
                defer b.end();
                if (b.clicked()) o.choice = ch;
                ui.text(c, c.print("{f}", .{ch}), .{ .size = 14, .weight = if (on) .semibold else .medium, .color = if (on) p.text else p.sub });
            }
        }
        o.status(c, p);
        const sure = ui.div(c).row().gap(6).itemsCenter().pt(2);
        defer sure.end();
        ui.icon(c, "lock.open", .{ .size = 11, .color = p.sub.alpha(0.7) });
        ui.text(c, "No permissions to grant: the shortcut works as it is.", .{ .size = 12, .color = p.sub.alpha(0.7) });
    }

    /// Who else answers the keys, by name, and the one thing that frees them.
    fn status(o: *Onboard, c: *ui.Context, p: Palette) void {
        const cl = o.clash();
        const keys = c.print("{f}", .{o.choice});
        const ok = c.theme.success;
        const warn: ui.Color = if (c.theme.dark) .hex(0xe0a33a) else .hex(0xb26b00);
        const box = ui.div(c).column().wFull().gap(8).p(12).rounded(10).bg((if (cl.clear()) ok else warn).alpha(0.1));
        defer box.end();
        const line = ui.div(c).row().gap(8).itemsCenter();
        if (cl.clear()) {
            ui.icon(c, "checkmark.circle.fill", .{ .size = 14, .color = ok });
            ui.textf(c, .{ .size = 13, .weight = .medium, .color = p.text }, "{s} is free on this Mac.", .{keys});
            line.end();
            return;
        }
        ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 13, .color = warn });
        if (cl.system) |who| {
            ui.textf(c, .{ .size = 13, .weight = .medium, .color = p.text }, "macOS gives {s} to {s} first.", .{ keys, who });
        } else {
            ui.textf(c, .{ .size = 13, .weight = .medium, .color = p.text }, "{s} {s} running and may answer {s} too.", .{ list(c, cl.launchers), if (cl.launchers.len == 1) "is" else "are", keys });
        }
        line.end();
        const fix = ui.div(c).row().gap(10).itemsCenter().pl(22);
        defer fix.end();
        const label = if (cl.system != null) "Open Keyboard Shortcuts" else c.print("Quit {s}", .{cl.launchers[0]});
        const b = ui.div(c).row().h(26).px(12).itemsCenter().rounded(7).bg(p.sel).border(p.rim).control();
        if (b.clicked()) if (o.hooks) |h| h.fix(h.ctx, cl);
        ui.text(c, label, .{ .size = 12, .weight = .semibold, .color = p.text });
        b.end();
        ui.text(c, "or pick another key above", .{ .size = 12, .color = p.sub.alpha(0.8) });
    }

    fn list(c: *ui.Context, names: []const []const u8) []const u8 {
        if (names.len == 1) return names[0];
        return c.print("{s} and {s}", .{ names[0], names[1] });
    }

    fn tryStep(o: *Onboard, c: *ui.Context, p: Palette) void {
        if (o.reopened) {
            const at = o.reopened_at orelse blk: {
                o.reopened_at = c.time;
                break :blk c.time;
            };
            // Both ticks show for a moment, then the last step.
            if (c.time - at > 0.75) return o.next(c, .done);
            c.animationFrame();
        }
        const col = ui.div(c).column().wFull().pt(34).gap(18).itemsCenter();
        defer col.end();
        {
            const caps = ui.div(c).row().gap(10).itemsCenter();
            defer caps.end();
            const ch = o.choice;
            const hotkey = @import("hotkey.zig");
            const held_mod = (ch.mods & hotkey.cmd == 0 or c.input.cmd) and (ch.mods & hotkey.option == 0 or c.input.alt) and
                (ch.mods & hotkey.control == 0 or c.input.ctrl) and (ch.mods & hotkey.shift == 0 or c.input.shift);
            const mods = c.print("{f}", .{ch.held()});
            if (mods.len > 0) {
                const n: f32 = @floatFromInt(@popCount(ch.mods));
                cap(c, p, mods, 68 + 22 * @max(0, n - 2), held_mod or o.reopened);
                ui.text(c, "+", .{ .size = 20, .weight = .medium, .color = p.sub.alpha(0.6) });
            }
            cap(c, p, c.print("{f}", .{ch.key()}), if (ch.code == hotkey.space) 180 else 68, o.reopened);
        }
        {
            const t = ui.div(c).column().gap(6).itemsCenter();
            defer t.end();
            ui.textf(c, .{ .size = 20, .weight = .semibold, .color = p.text, .tracking = -0.2 }, "Press {f} now", .{o.choice});
            ui.text(c, "It closes. Press it again and it comes back, from any app.", .{ .size = 13.5, .color = p.sub });
        }
        const ticks = ui.div(c).row().gap(10);
        defer ticks.end();
        tick(c, p, "Closed", o.closed);
        tick(c, p, "Back again", o.reopened);
    }

    fn cap(c: *ui.Context, p: Palette, str: []const u8, w: f32, lit: bool) void {
        const t = motion.number(c, str, if (lit) 1 else 0, .{ .spring = .{ .stiffness = 600, .damping = 40 } });
        const d = ui.div(c).w(w).h(64).center().rounded(14).bg(p.tile.mix(p.text.alpha(0.22), t)).border(p.rim.mix(p.text.alpha(0.45), t))
            .shadow(.{ .color = .{ .a = 0.18 * (1 - t) }, .blur = 0, .y = 3 }).offset(0, 2 * t);
        defer d.end();
        ui.text(c, str, .{ .size = if (str.len > 3) 18 else 26, .weight = .medium, .color = p.text });
    }

    fn tick(c: *ui.Context, p: Palette, str: []const u8, on: bool) void {
        const ok = c.theme.success;
        const d = ui.div(c).row().gap(6).h(28).px(12).itemsCenter().roundedFull().bg(if (on) ok.alpha(0.16) else p.tile);
        defer d.end();
        ui.icon(c, if (on) "checkmark.circle.fill" else "circle", .{ .size = 13, .color = if (on) ok else p.sub.alpha(0.6) });
        ui.text(c, str, .{ .size = 12.5, .weight = .medium, .color = if (on) p.text else p.sub });
    }

    fn doneStep(o: *Onboard, c: *ui.Context, s: *panel.Nanolight, p: Palette, enter: bool) void {
        if (enter) return o.finish(s, "");
        for (examples, 0..) |e, i| if (c.shortcut(.{ .key = @intCast('1' + i), .cmd = true })) return o.finish(s, e.q);
        {
            const top = ui.div(c).column().wFull().px(28).pt(26).pb(16).gap(4);
            defer top.end();
            ui.text(c, "You're set.", .{ .size = 22, .weight = .semibold, .color = p.text, .tracking = -0.3 });
            ui.textf(c, .{ .size = 13.5, .color = p.sub }, "{f} opens it anywhere. Start with one of these:", .{o.choice});
        }
        {
            const rows = ui.div(c).column().wFull().px(16).gap(2);
            defer rows.end();
            for (examples, 0..) |e, i| {
                ui.key(c, e.q);
                const r = ui.div(c).row().wFull().h(40).px(12).gap(12).itemsCenter().rounded(10).control().hover(p.sel);
                defer r.end();
                if (r.clicked()) return o.finish(s, e.q);
                const tile = ui.div(c).size(26, 26).rounded(7).bg(p.tile).center();
                ui.icon(c, e.icon, .{ .size = 13, .weight = .medium, .color = p.text });
                tile.end();
                ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text, .mono = true }, "{s}", .{e.q});
                ui.text(c, e.what, .{ .size = 12, .color = p.sub.alpha(0.8) });
                ui.spacer(c);
                ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.55), .tabular = true }, "⌘{d}", .{i + 1});
            }
        }
        const home = ui.div(c).column().wFull().px(28).pt(16).gap(12);
        defer home.end();
        {
            const r = ui.div(c).row().gap(10).itemsCenter();
            defer r.end();
            const tile = ui.div(c).size(26, 22).rounded(6).bg(p.tile).center();
            ui.icon(c, "magnifyingglass", .{ .size = 12, .weight = .semibold, .color = p.text });
            tile.end();
            ui.text(c, "Settings are on ⌘, and the gear. It also lives in your menu bar.", .{ .size = 12.5, .color = p.sub });
        }
        const h = o.hooks orelse return;
        const f = h.login orelse return;
        if (ui.toggle(c, "Open Nanolight when you log in", &o.login)) o.login = f(h.ctx, o.login);
    }

    fn footer(o: *Onboard, c: *ui.Context, p: Palette) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(38).px(16).gap(8).itemsCenter();
        defer bar.end();
        const n: usize = @intFromEnum(o.step);
        for (0..3) |i| ui.div(c).w(if (i == n) 16 else 6).h(6).roundedFull().bg(if (i == n) p.text.alpha(0.7) else p.sub.alpha(0.3)).end();
        ui.textf(c, .{ .size = 12, .color = p.sub.alpha(0.8), .tabular = true }, "  {d} of 3", .{n + 1});
        ui.spacer(c);
        const action: []const u8 = switch (o.step) {
            .key => if (o.clash().clear()) "Continue" else c.print("Use {f} anyway", .{o.choice}),
            .try_it => "",
            .done => "Start searching",
        };
        if (action.len > 0) {
            ui.text(c, action, .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
            ui.kbd(c, "↩");
            ui.div(c).w(1).h(14).bg(p.hair).end();
        }
        ui.text(c, if (o.step == .done) "Close" else "Skip", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }

    fn next(o: *Onboard, c: *ui.Context, step: Step) void {
        // This frame drew the old step: the new one is drawn now too.
        c.changed = true;
        c.animationFrame();
        if (o.step == .key) if (o.hooks) |h| h.apply(h.ctx, o.choice);
        o.step = step;
    }

    /// Over: into the launcher, with `query` typed (a first search) or not.
    pub fn finish(o: *Onboard, s: *panel.Nanolight, query: []const u8) void {
        if (o.step == .key) if (o.hooks) |h| h.apply(h.ctx, o.choice);
        o.active = false;
        if (o.hooks) |h| h.done(h.ctx);
        if (query.len > 0) s.query.set(query) else s.query.clear();
        s.built = 1;
        s.revealed = 0;
        s.query.focus();
    }
};
