//! Settings, in the panel itself: the shortcut, Google's suggestions and
//! where searches open, opening at login, the menu bar icon, syncing
//! across Macs, updates. The same glass, the
//! same rows. Esc goes back to search; ↑/↓ move, Return and Space do the
//! row. The shortcut is one of four, or any key recorded with ⌘, ⌥ or ⌃
//! (the last chip). Without a host (tests, the film) it still draws, and changes
//! nothing the app keeps.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const panel = @import("view.zig");
const shortcut = @import("shortcut.zig");
const account = @import("account.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Choice = shortcut.Choice;
const Palette = panel.Palette;
const mac = @import("builtin").os.tag == .macos;

const RowKind = enum { choice, suggest, files, browser, login, menu_bar, sync, terms, updates, welcome, quit };

/// As tall as its sections, never past the window. Tighter Mac spacing
/// fits file search, where searches open, and the menu bar icon.
pub const height: f32 = if (mac) 666 else 560;

pub const Settings = struct {
    open: bool = false,
    sel: usize = 0,
    /// Return already handled for this key event (a frame may draw twice).
    took_return: bool = false,
    choice: Choice = .cmd_space,
    /// The last chip's key, recorded (this run or before), if any.
    custom: ?Choice = null,
    /// Waiting for a key to be pressed for the last chip; the one pressed
    /// last wasn't fit (no ⌘, ⌥ or ⌃).
    recording: bool = false,
    refused: bool = false,
    suggest: bool = true,
    files: bool = false,
    /// Return sends searches to the browser (`Nanolight.searches_out`).
    browser: bool = false,
    login: bool = false,
    menu_bar: bool = true,
    account: account.State = .signed_out,
    email: []const u8 = "",
    version: []const u8 = "0.1.0",
    ready: ?[]const u8 = null,

    pub fn show(s: *Settings) void {
        s.open = true;
        s.sel = 0;
    }

    pub fn hide(s: *Settings) void {
        s.open = false;
        s.recording = false;
    }

    fn hooks(s: *Settings, n: *panel.Nanolight) ?*const SettingsHost {
        _ = s;
        const h = n.host orelse return null;
        return h.settings;
    }

    fn pull(s: *Settings, n: *panel.Nanolight) void {
        s.suggest = n.suggest_on;
        s.files = n.files_on;
        s.browser = n.searches_out;
        const h = s.hooks(n) orelse return;
        s.menu_bar = h.menu_bar(h.ctx, null);
        s.choice = h.choice(h.ctx);
        if (s.choice.preset() == null) s.custom = s.choice;
        s.login = h.login(h.ctx, null);
        s.account = h.account(h.ctx);
        s.email = h.email(h.ctx);
        s.version = h.version(h.ctx);
        s.ready = h.ready(h.ctx);
    }

    pub fn view(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        s.pull(n);
        const rows = rowList(s.account);
        if (s.sel >= rows.len) s.sel = rows.len - 1;
        s.keys(c, n, rows);
        ui.key(c, "settings");
        const f = motion.frame(c, .{ .initial = .{ .opacity = 0, .x = 14 }, .transition = .{ .spring = panel.spring } });
        const page = ui.div(c).column().wFull().grow().motion(f);
        defer page.end();
        head(c, p);
        s.body(c, n, p, rows);
        foot(c, p);
    }

    fn head(c: *ui.Context, p: Palette) void {
        const bar = ui.div(c).row().wFull().h(panel.header_h).px(16).gap(10).itemsCenter();
        defer bar.end();
        const badge = ui.div(c).size(28, 28).rounded(8).center().bg(p.tile);
        ui.icon(c, "gearshape", .{ .size = 15, .weight = .medium, .color = p.text });
        badge.end();
        ui.text(c, "Settings", .{ .size = 18, .weight = .semibold, .color = p.text, .tracking = -0.2 });
    }

    fn body(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette, rows: []const RowKind) void {
        const col = ui.div(c).column().wFull().px(20).pt(2).pb(6).gap(if (mac) 8 else 10).grow();
        defer col.end();
        label(c, p, "Open SamSearch with");
        s.choices(c, n, p);
        label(c, p, "Search");
        s.switchRow(c, n, p, rows, .suggest, "Google Suggestions");
        if (mac) s.switchRow(c, n, p, rows, .files, "File Search");
        if (mac) s.switchRow(c, n, p, rows, .browser, "Open Searches in Browser");
        label(c, p, "This " ++ @import("results.zig").machine);
        s.switchRow(c, n, p, rows, .login, "Open at Login");
        if (mac) s.switchRow(c, n, p, rows, .menu_bar, "Show in Menu Bar");
        label(c, p, if (@import("builtin").os.tag == .macos) "Sync Across Macs" else "Sync Across Computers");
        s.sync(c, n, p, rows);
        label(c, p, "Updates");
        s.updates(c, n, p, rows);
        s.button(c, n, p, rows, .welcome, "Show Welcome Again");
        s.button(c, n, p, rows, .quit, "Quit SamSearch");
    }

    fn label(c: *ui.Context, p: Palette, name: []const u8) void {
        ui.text(c, name, .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
    }

    fn choices(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        const row = ui.div(c).row().gap(8);
        defer row.end();
        for (Choice.all) |ch| {
            ui.key(c, c.print("key-{d}-{d}", .{ ch.code, ch.mods }));
            const on = ch.eql(s.choice) and !s.recording;
            const b = ui.div(c).row().h(36).px(14).itemsCenter().rounded(10).control()
                .bg(if (on) p.sel else p.tile.alpha(0.5)).border(if (on) p.text.alpha(0.35) else p.rim);
            defer b.end();
            if (b.clicked()) s.pick(n, ch);
            ui.text(c, c.print("{f}", .{ch}), .{ .size = 13.5, .weight = if (on) .semibold else .medium, .color = if (on) p.text else p.sub });
        }
        // One's own: the key recorded, or a press away (on the Mac, where
        // Carbon takes any key; a PC keeps to the four).
        if (!mac) return;
        ui.key(c, "key-own");
        const on = s.recording or (s.custom != null and s.custom.?.eql(s.choice));
        const b = ui.div(c).row().h(36).px(14).gap(6).itemsCenter().rounded(10).control()
            .bg(if (on) p.sel else p.tile.alpha(0.5)).border(if (on) p.text.alpha(0.35) else p.rim);
        defer b.end();
        if (b.clicked()) s.record(n, !s.recording);
        const text = if (s.refused) "Add ⌘, ⌥ or ⌃" else if (s.recording) "Type a shortcut" else if (s.custom) |k| c.print("{f}", .{k}) else "Record…";
        ui.text(c, text, .{ .size = 13.5, .weight = if (on) .semibold else .medium, .color = if (on) p.text else p.sub });
        if (s.recording) ui.kbd(c, "esc");
    }

    /// Starts or stops waiting for a key of one's own.
    fn record(s: *Settings, n: *panel.Nanolight, on: bool) void {
        s.recording = on;
        s.refused = false;
        const h = s.hooks(n) orelse return;
        h.record(h.ctx, on);
    }

    /// A key pressed while recording: kept and used, or not.
    pub fn took(s: *Settings, n: *panel.Nanolight, r: shortcut.Recorded) void {
        if (!s.recording) return;
        switch (r) {
            .unusable => s.refused = true,
            .cancel => s.record(n, false),
            .key => |k| {
                s.record(n, false);
                s.custom = k;
                s.pick(n, k);
            },
        }
    }

    fn pick(s: *Settings, n: *panel.Nanolight, ch: Choice) void {
        if (s.recording) s.record(n, false);
        s.choice = ch;
        const h = s.hooks(n) orelse return;
        h.apply(h.ctx, ch);
    }

    fn switchRow(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette, rows: []const RowKind, kind: RowKind, title: []const u8) void {
        const on = isSel(rows, s.sel, kind);
        const d = ui.div(c).row().wFull().h(36).px(4).gap(10).itemsCenter().rounded(10).control().bg(if (on) p.sel else p.fill.alpha(0));
        defer d.end();
        if (d.clicked()) s.flip(n, kind);
        ui.text(c, title, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        mark(c, p, switch (kind) {
            .suggest => s.suggest,
            .files => s.files,
            .browser => s.browser,
            .login => s.login,
            .menu_bar => s.menu_bar,
            else => false,
        });
    }

    /// A quiet on/off mark. Not `ui.toggle`: that flips on its own click,
    /// and this row already does.
    fn mark(c: *ui.Context, p: Palette, on: bool) void {
        const ok = c.theme.success;
        const d = ui.div(c).row().w(40).h(24).px(2).itemsCenter().roundedFull().bg(if (on) ok else p.tile);
        defer d.end();
        // On: the knob at the right, as the system's switches have it.
        if (on) ui.spacer(c);
        ui.div(c).size(20, 20).roundedFull().bg(ui.Color.white).end();
        if (!on) ui.spacer(c);
    }

    fn flip(s: *Settings, n: *panel.Nanolight, kind: RowKind) void {
        const h = s.hooks(n);
        switch (kind) {
            .suggest => {
                n.suggest_on = !n.suggest_on;
                s.suggest = n.suggest_on;
                n.built = 1;
                if (h) |host| host.suggest(host.ctx, s.suggest);
            },
            .files => {
                n.files_on = !n.files_on;
                s.files = n.files_on;
                n.built = 1;
                if (n.kv) |kv| kv.set(@import("files.zig").enabled_key, if (n.files_on) "1" else "0") catch {};
            },
            .browser => {
                n.searches_out = !n.searches_out;
                s.browser = n.searches_out;
                if (h) |host| host.searches_out(host.ctx, s.browser);
            },
            .login => {
                const next = !s.login;
                s.login = if (h) |host| host.login(host.ctx, next) else next;
            },
            .menu_bar => {
                const next = !s.menu_bar;
                s.menu_bar = if (h) |host| host.menu_bar(host.ctx, next) else next;
            },
            else => {},
        }
    }

    fn sync(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette, rows: []const RowKind) void {
        switch (s.account) {
            .signed_out, .starting => {
                s.button(c, n, p, rows, .sync, if (s.account == .starting) "Signing In…" else "Sign In with Codegraff");
                s.termsLine(c, n, p, rows);
            },
            .waiting => {
                ui.text(c, "Approve in your browser…", .{ .size = 13.5, .weight = .medium, .color = p.text });
                s.button(c, n, p, rows, .sync, "Cancel");
            },
            .signed_in => {
                const who = if (s.email.len > 0) s.email else "your Codegraff account";
                ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text }, "Synced as {s}", .{who});
                s.button(c, n, p, rows, .sync, "Sign Out");
            },
        }
    }

    fn termsLine(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette, rows: []const RowKind) void {
        const on = isSel(rows, s.sel, .terms);
        ui.key(c, "terms");
        const line = ui.div(c).row().wFull().h(28).px(4).gap(4).itemsCenter().rounded(8).control().bg(if (on) p.sel else p.fill.alpha(0));
        defer line.end();
        if (line.clicked()) s.activate(n, .terms);
        ui.text(c, "Uses your Codegraff account; Codegraff's", .{ .size = 11.5, .color = p.sub.alpha(0.75) });
        ui.text(c, "Terms & Privacy", .{ .size = 11.5, .weight = .medium, .color = p.text.alpha(0.9) });
        ui.text(c, "apply", .{ .size = 11.5, .color = p.sub.alpha(0.75) });
    }

    fn updates(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette, rows: []const RowKind) void {
        ui.textf(c, .{ .size = 12.5, .color = p.sub }, "SamSearch {s}", .{s.version});
        const text = if (s.ready) |v| c.print("Restart to Update to {s}", .{v}) else "Check for Updates";
        s.button(c, n, p, rows, .updates, text);
    }

    fn button(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette, rows: []const RowKind, kind: RowKind, text: []const u8) void {
        const on = isSel(rows, s.sel, kind);
        ui.key(c, @tagName(kind));
        const d = ui.div(c).row().wFull().h(36).px(12).gap(8).itemsCenter().rounded(10).control()
            .bg(if (on) p.sel else p.tile.alpha(0.45)).border(p.rim);
        defer d.end();
        if (d.clicked()) s.activate(n, kind);
        ui.text(c, text, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        if (on) ui.kbd(c, "↩");
    }

    fn foot(c: *ui.Context, p: Palette) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(panel.footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        ui.text(c, "Back", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }

    fn keys(s: *Settings, c: *ui.Context, n: *panel.Nanolight, rows: []const RowKind) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) {
            s.hide();
            n.query.focus();
            return;
        }
        if (!s.returned(c)) s.took_return = false;
        if (c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true })) s.sel = (s.sel + 1) % rows.len;
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) s.sel = (s.sel + rows.len - 1) % rows.len;
        if (c.shortcut(.{ .key = S.left })) s.nudge(n, rows, -1);
        if (c.shortcut(.{ .key = S.right })) s.nudge(n, rows, 1);
        // Space is also typed into the field once Settings closes; only
        // Return and Space while this view has the keys.
        if (c.shortcut(.{ .key = ' ' })) s.activate(n, rows[s.sel]);
    }

    /// Return, as a key or as the field's newline command.
    /// Settings in place of the rows, the panel's height following them.
    pub fn inPanel(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        // Return is the field's command, or a key. One event, one act.
        if (s.returned(c) and !s.took_return) {
            s.took_return = true;
            s.activateSelected(n);
        }
        const h = n.follow(c, height);
        const box = ui.div(c).column().wFull().h(h).clip();
        defer box.end();
        s.view(c, n, p);
    }

    pub fn returned(s: *Settings, c: *ui.Context) bool {
        _ = s;
        if (c.input.key == .enter) return true;
        for (c.input.ops) |op| if (op == .command and op.command == .insert_newline) return true;
        return false;
    }

    /// Return on the selected row. The field would have taken it.
    pub fn activateSelected(s: *Settings, n: *panel.Nanolight) void {
        s.pull(n);
        const rows = rowList(s.account);
        if (s.sel >= rows.len) return;
        s.activate(n, rows[s.sel]);
    }

    fn nudge(s: *Settings, n: *panel.Nanolight, rows: []const RowKind, dir: i8) void {
        if (rows[s.sel] != .choice) return;
        s.pick(n, s.choice.step(dir));
    }

    fn activate(s: *Settings, n: *panel.Nanolight, kind: RowKind) void {
        const h = s.hooks(n);
        switch (kind) {
            // ←/→ step through the four; Return records one's own.
            .choice => if (mac) s.record(n, !s.recording) else s.nudge(n, rowList(s.account), 1),
            .suggest, .files, .browser, .login, .menu_bar => s.flip(n, kind),
            .sync => if (h) |host| switch (s.account) {
                .signed_out => host.sign_in(host.ctx),
                .waiting, .signed_in => host.sign_out(host.ctx),
                .starting => {},
            },
            .terms => if (h) |host| host.terms(host.ctx),
            .updates => if (h) |host| {
                if (s.ready != null) host.restart(host.ctx) else host.check(host.ctx);
            },
            .welcome => if (h) |host| {
                s.hide();
                host.welcome(host.ctx);
            },
            .quit => if (h) |host| host.quit(host.ctx),
        }
    }
};

fn rowList(state: account.State) []const RowKind {
    return switch (state) {
        .signed_out, .starting => if (mac) &.{ .choice, .suggest, .files, .browser, .login, .menu_bar, .sync, .terms, .updates, .welcome, .quit } else &.{ .choice, .suggest, .login, .sync, .terms, .updates, .welcome, .quit },
        .waiting, .signed_in => if (mac) &.{ .choice, .suggest, .files, .browser, .login, .menu_bar, .sync, .updates, .welcome, .quit } else &.{ .choice, .suggest, .login, .sync, .updates, .welcome, .quit },
    };
}

fn isSel(rows: []const RowKind, sel: usize, kind: RowKind) bool {
    if (sel >= rows.len) return false;
    return rows[sel] == kind;
}
