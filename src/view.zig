//! The launcher panel: the query, then what it finds in sections, then a
//! footer naming what Return does. Neutral glass, a hairline rim, 40-point
//! rows, the selection a grey step that slides between them. Nothing moves
//! while nothing happens: frames come from keys, and from height settling.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const Index = @import("apps.zig").Index;
const results = @import("results.zig");
const files = @import("files.zig");
const files_view = @import("files_view.zig");
const suggest = @import("suggest.zig");
const text = @import("text.zig");
const settings_view = @import("settings_view.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Row = results.Row;

/// What the panel asks of whatever shows it (the window, or the film).
pub const Host = struct {
    ctx: *anyopaque,
    /// Opens an app's path or a URL.
    open: *const fn (ctx: *anyopaque, target: []const u8) void,
    hide: *const fn (ctx: *anyopaque) void,
    /// The panel's height changed: a window follows it.
    resize: ?*const fn (ctx: *anyopaque, h: f32) void = null,
    /// Request completions, returned through `Nanolight.answered`.
    suggest: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    files: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    /// Shows a search's page in the panel, over `webArea`; null takes it
    /// away. Without it, searches open in the browser.
    preview: ?*const fn (ctx: *anyopaque, url: ?[]const u8) void = null,
    /// Settings callbacks; without them, changes are not persisted.
    settings: ?*const SettingsHost = null,
};

pub const width: f32 = 680;

/// The app's icon (icon.png, made smaller), for the panel and the film.
pub const icon_png = @embedFile("icon-256.png");

/// The app's icon, `size` points square.
pub fn appIcon(c: *ui.Context, size: f32) void {
    _ = ui.image(c, .{ .key = "nanolight-icon", .bytes = icon_png, .max_width = size, .max_height = size, .radius = 0, .scale = 2 });
}
pub const header_h = 58;
const row_h = 40;
const calc_h = 92;
const section_h = 28;
pub const footer_h = 38;
const list_pad = 6;
/// The room a window leaves round the panel for its shadow (`Nanolight.margin`).
pub const shadow_margin: f32 = 40;
/// The tallest the panel gets: every app row, the four handoff rows and
/// Google's completions, under three section heads (math lists fewer), or
/// a search's page. The window is this tall.
pub const max_height: f32 = header_h + footer_h + 2 + list_pad * 2 + results.max_rows * row_h + 3 * section_h;

/// Where a search's page goes in a panel `h` tall: from `y` down from its
/// top, `h` tall, between the header and the footer, the panel's width.
pub fn webArea(h: f32) struct { y: f32, h: f32 } {
    return .{ .y = header_h + 1, .h = @max(0, h - header_h - footer_h - 2) };
}
/// Opening and growing: snappy, a touch under critical damping.
pub const spring: motion.Spring = .{ .stiffness = 320, .damping = 32 };
const slide: motion.Spring = .{ .stiffness = 700, .damping = 52 };

pub const Palette = @import("palette.zig").Palette;
pub const palette = @import("palette.zig").palette;

pub const Nanolight = struct {
    index: *Index,
    query: ui.TextBuffer = .{},
    res: results.Results = .{},
    sel: usize = 0,
    /// The query the rows were built for.
    built: u64 = 1,
    host: ?Host = null,
    /// Draws its own Liquid Glass (over a desktop nanoui painted, as the
    /// film does); otherwise the window's system glass is under it.
    own_glass: bool = false,
    /// Clear room round the panel in its window, for its shadow.
    margin: f32 = 0,
    /// The window fades in as it shows, the system's glass with it
    /// (panel_mac.zig): the panel has no entrance of its own (issue #9).
    window_fades: bool = false,
    /// Return sends a Google search to the browser and ⌘↩ shows it in
    /// the panel, the other way round from the default (issue #10).
    searches_out: bool = false,
    /// Each showing gets a new one: the panel comes in again.
    shown: u32 = 0,
    copied_at: f64 = -10,
    kv: ?nanoui.kv.Store = null,
    spans: [results.max_rows][16]ui.Span = undefined,
    url_buf: [1024]u8 = undefined,
    last_h: f32 = 0,
    /// The query as it was shown: selected, so no completion after it yet.
    revealed: u64 = 0,
    /// Said in the footer in place of the name ("Updated to 0.1.3"), if set.
    note: []const u8 = "",
    /// The first-run welcome, drawn while it is active.
    onboard: ?*@import("onboard.zig").Onboard = null,
    /// Local file search is opt-in on this Mac.
    files_on: bool = false,
    found: files.List = .{},
    /// Google's completions: whether to ask, those listed, the answers.
    suggest_on: bool = true,
    web: suggest.List = .{},
    cache: suggest.Cache = .{},
    /// A search's page is in the panel, for the query as it was then.
    previewing: bool = false,
    preview_q: u64 = 0,
    preview_kind: results.Kind = .search_web,
    preview_answer_buf: [1024]u8 = undefined,
    preview_answer: []const u8 = "",
    preview_buf: [1024]u8 = undefined,
    preview_url: []const u8 = "",
    /// Settings, drawn in the panel in place of the rows.
    settings_ui: settings_view.Settings = .{},
    ext: ?*@import("raycast_view.zig").Ext = null,

    /// Called as it is shown: the query selected, the keys its own.
    pub fn reveal(s: *Nanolight) void {
        s.back();
        s.settings_ui.hide();
        s.shown +%= 1;
        // Suggestions follow what was opened since.
        s.built = 1;
        s.revealed = std.hash.Wyhash.hash(0, s.query.text());
        s.query.want_selection = .{ 0, s.query.text().len };
        s.query.focus();
    }

    /// The panel's height for the rows it lists.
    pub fn height(s: *const Nanolight) f32 {
        if (s.settings_ui.open) return settings_view.height;
        if (s.ext) |e| if (e.open) return e.height();
        if (s.previewing) return max_height;
        var h: f32 = header_h + footer_h + 1;
        if (s.res.n == 0) return h;
        h += 1 + list_pad * 2;
        for (s.res.slice(), 0..) |r, i| {
            h += if (r.kind == .calc) calc_h else row_h;
            if (s.res.section(i) != null) h += section_h;
        }
        return h;
    }

    /// The window's view: the panel, `margin` in from the window's edges.
    pub fn view(s: *Nanolight, c: *ui.Context) void {
        ui.key(c, c.print("panel-{d}", .{s.shown}));
        const entrance: motion.Target = .{ .opacity = 0, .y = -6, .scale = 0.985 };
        const f = motion.frame(c, .{ .initial = if (s.window_fades) null else entrance, .transition = .{ .spring = spring } });
        const root = ui.div(c).wFull().p(s.margin).motion(f);
        defer root.end();
        s.panel(c);
    }

    pub fn panel(s: *Nanolight, c: *ui.Context) void {
        const p = palette(c.theme.dark);
        const shell = ui.div(c).column().w(width).rounded(18).border(p.hair).clip();
        if (s.own_glass) {
            _ = shell.glass(.{ .tint = if (c.theme.dark) ui.Color.black.alpha(0.42) else ui.Color.white.alpha(0.5) })
                .shadows(&.{ .{ .color = .{ .a = 0.22 }, .blur = 4, .y = 1 }, .{ .color = .{ .a = 0.28 }, .blur = 40, .y = 18 } });
        } else {
            // The system's shadow is off (its outline drew a black ring
            // round the panel): this one is soft, and outside the panel
            // only, so the glass under it stays clear.
            _ = shell.bg(p.fill).shadows(&.{
                .{ .color = .{ .a = 0.16 }, .blur = 3, .y = 1, .knockout = true },
                .{ .color = .{ .a = 0.24 }, .blur = 28, .y = 12, .knockout = true },
            });
        }
        defer shell.end();
        if (s.onboard) |o| if (o.active) {
            const h = s.follow(c, o.height());
            const body = ui.div(c).column().wFull().h(h).clip();
            defer body.end();
            o.view(c, s, p);
            return;
        };
        if (s.settings_ui.open) return s.settings_ui.inPanel(c, s, p);
        // A Raycast extension's command, while it runs (raycast_view.zig).
        if (s.ext) |e| if (e.open) return e.panel(c, s, p);

        s.keys(c);
        const submitted = s.header(c, p);
        s.rebuild();
        // Typing takes the page away: the rows are for the new words.
        if (s.previewing and std.hash.Wyhash.hash(0, s.query.text()) != s.preview_q) s.back();
        if (submitted) s.activate(c);
        const h = s.follow(c, s.height());
        {
            const body = ui.div(c).column().wFull().h(h - header_h).clip();
            defer body.end();
            if (s.previewing) {
                // Under the page, until it draws.
                ui.div(c).wFull().h(1).bg(p.hair).end();
                const wait = ui.div(c).wFull().h(webArea(h).h).center();
                defer wait.end();
                ui.text(c, switch (s.preview_kind) {
                    .quick_ask => "Asking…",
                    .digup => "Searching DigUp…",
                    .codes => "Looking for codes…",
                    else => "Searching Google…",
                }, .{ .size = 13, .color = p.sub.alpha(0.8) });
            } else if (s.res.n > 0) {
                ui.div(c).wFull().h(1).bg(p.hair).end();
                s.list(c, p);
            }
            ui.spacer(c);
            s.footer(c, p);
        }
    }

    /// The panel's height, springing to `target`; a window follows it.
    pub fn follow(s: *Nanolight, c: *ui.Context, target: f32) f32 {
        const h = motion.number(c, "panel-h", @min(target, max_height), .{ .spring = spring });
        if (s.host) |host| if (host.resize) |f| if (@abs(h - s.last_h) > 0.25) {
            s.last_h = h;
            f(host.ctx, h);
        };
        return h;
    }

    /// Arrows, ^N/^P and Escape, before the field sees them.
    fn keys(s: *Nanolight, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (s.previewing) {
            if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.openPreviewOut(null);
            if (c.shortcut(.{ .key = S.escape })) s.back();
            return;
        }
        // ⌘,: Settings, as on the Mac. The comma never reaches the field.
        if (c.shortcut(.{ .key = ',', .cmd = true })) return s.openSettings();
        // ⌘↩: a search in the browser rather than in the panel.
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.activateOut(c);
        // Tab takes the faint completion, as → does.
        const more = s.completion();
        if (!files_view.takeOnTab(s, c) and more.len > 0 and c.shortcut(.{ .key = S.tab })) s.take(more);
        const n = s.res.n;
        if (c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true })) {
            if (n > 0) s.sel = (s.sel + 1) % n;
        }
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) {
            if (n > 0) s.sel = (s.sel + n - 1) % n;
        }
        // ⌘1…⌘9: the row of that number, at once (Ask, T3 and DigUp are
        // always ⌘1, ⌘2, ⌘3: `Results.number`).
        for (1..10) |d| if (c.shortcut(.{ .key = @intCast('0' + d), .cmd = true })) {
            if (s.res.rowFor(@intCast(d))) |k| {
                s.sel = k;
                s.activate(c);
            }
        };
        if (c.shortcut(.{ .key = S.escape })) {
            if (s.query.text().len > 0) s.query.clear() else if (s.host) |h| h.hide(h.ctx);
        }
    }

    fn header(s: *Nanolight, c: *ui.Context, p: Palette) bool {
        const bar = ui.div(c).row().wFull().h(header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        ui.icon(c, "magnifyingglass", .{ .size = 19, .weight = .medium, .color = p.sub, .frame = 22 });
        s.rebuild();
        const r = ui.textField(c, &s.query, .{
            .suggestion = s.completion(),
            .bare = true,
            .size = 21,
            .width = .fill,
            .placeholder = "Search apps, do math, ask anything…",
            .placeholder_color = p.sub.alpha(0.75),
            .color = p.text,
        });
        return r.submitted;
    }

    /// What the query is the start of, drawn faintly after the caret; →
    /// or Tab takes it. The top app's name when one is listed first ("saf"
    /// → "ari"), else Google's first completion that goes on from the
    /// words ("liquid gl" → "ass"), so it is one key away, not a walk
    /// down the rows. Return never takes it: Return is the selected row.
    fn completion(s: *const Nanolight) []const u8 {
        const q = s.query.text();
        if (q.len == 0 or s.res.n == 0 or std.hash.Wyhash.hash(0, q) == s.revealed) return "";
        const r = s.res.rows[0];
        if (r.kind == .app) {
            const name = s.index.apps.items[r.app].name;
            if (name.len <= q.len or !text.utf8StartsWithFold(name, q)) return "";
            return name[q.len..];
        }
        if (r.kind != .search_web) return "";
        for (0..s.web.n) |i| {
            const w = s.web.get(i);
            if (w.len > q.len and text.utf8StartsWithFold(w, q)) return w[q.len..];
        }
        return "";
    }

    fn take(s: *Nanolight, more: []const u8) void {
        var buf: [suggest.max_len * 2]u8 = undefined;
        const q = s.query.text();
        if (q.len + more.len > buf.len) return;
        @memcpy(buf[0..q.len], q);
        @memcpy(buf[q.len..][0..more.len], more);
        const len = q.len + more.len;
        s.query.set(buf[0..len]);
        s.query.want_selection = .{ len, len };
    }

    /// Rebuild changed queries, asking for missing completions.
    pub fn rebuild(s: *Nanolight) void {
        const q = s.query.text();
        const h = std.hash.Wyhash.hash(0, q);
        if (h == s.built) return;
        s.built = h;
        files_view.rebuild(s);
        s.web.n = 0;
        if (s.host) |host| if (host.suggest) |ask| if (s.suggest_on and suggest.eligible(q) and @import("calc.zig").eval(q) == null) {
            if (!s.cache.lookup(q, &s.web)) ask(host.ctx, q);
        };
        s.fill();
        // The first row: an app, the answer, or the search for what was
        // typed; never a completion nobody picked (they come after it).
        s.sel = 0;
    }

    pub fn fill(s: *Nanolight) void {
        var sug: [results.max_apps]u32 = undefined;
        const ns = s.index.suggestions(&sug);
        var web: [suggest.max_rows][]const u8 = undefined;
        s.res.build(s.query.text(), s.index, sug[0..ns], s.web.slices(&web), &s.found);
    }

    /// Google's completions of `typed` (what `Host.suggest` asked): kept,
    /// and listed if it is still what is typed. The selection stays on the
    /// row it was on, wherever that row now is: Return a moment after
    /// typing does what the panel showed, not a completion that just came.
    pub fn answered(s: *Nanolight, typed: []const u8, said: *const suggest.List) void {
        s.cache.put(typed, said);
        if (!suggest.same(typed, s.query.text())) return;
        const was: ?Row = if (s.sel < s.res.n) s.res.rows[s.sel] else null;
        var was_text: [suggest.max_len]u8 = undefined;
        var was_len: usize = 0;
        if (was) |r| if (r.kind == .suggest) {
            const w = s.web.get(r.web);
            @memcpy(was_text[0..w.len], w);
            was_len = w.len;
        };
        s.web = said.*;
        s.fill();
        s.sel = 0;
        const r = was orelse return;
        for (s.res.slice(), 0..) |now, i| {
            const same_row = now.kind == r.kind and switch (r.kind) {
                .app, .pane => now.app == r.app,
                .file => now.file == r.file,
                .suggest => suggest.same(s.web.get(now.web), was_text[0..was_len]),
                else => true,
            };
            if (same_row) {
                s.sel = i;
                return;
            }
        }
    }

    pub const filesAnswered = files_view.filesAnswered;

    fn list(s: *Nanolight, c: *ui.Context, p: Palette) void {
        const box = ui.div(c).column().wFull().p(list_pad);
        defer box.end();
        // Where the selected row is, so the highlight can slide to it.
        var y: f32 = 0;
        var sel_y: f32 = 0;
        var sel_h: f32 = row_h;
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i) != null) y += section_h;
            const rh: f32 = if (r.kind == .calc) calc_h else row_h;
            if (i == s.sel) {
                sel_y = y;
                sel_h = rh;
            }
            y += rh;
        }
        // A new list: the highlight is there at once; moving in it, it slides.
        const fresh = c.print("{d}", .{s.built});
        const hy = motion.number(c, fresh, sel_y, .{ .spring = slide });
        const hh = motion.number(c, c.print("{d}h", .{s.built}), sel_h, .{ .spring = slide });
        ui.div(c).absolute().offset(0, hy).w(width - list_pad * 2).h(hh).rounded(10).bg(p.sel).border(p.rim).end();
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i)) |name| {
                const head = ui.div(c).row().wFull().h(section_h).px(12).pb(6).itemsEnd();
                defer head.end();
                ui.text(c, name, .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
            }
            s.row(c, p, i, r);
        }
    }

    fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
        const big = r.kind == .calc;
        const d = ui.div(c).row().wFull().h(if (big) calc_h else row_h).px(10).gap(12).itemsCenter().control();
        defer d.end();
        if (d.clicked()) {
            s.sel = i;
            s.activate(c);
        }
        if (big) return s.calcCard(c, p);
        s.tile(c, p, r);
        const q = s.query.text();
        switch (r.kind) {
            .calc => unreachable,
            .app => {
                const a = s.index.apps.items[r.app];
                ui.richText(c, a.name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, a.folder, .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .pane => {
                const pane = @import("settings_panes.zig").all[r.app];
                ui.richText(c, pane.name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, "System Settings", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .file => files_view.row(s, c, p, i, r),
            .settings => {
                ui.text(c, "SamSearch Settings", .{ .size = 13.5, .weight = .medium, .color = p.text });
                ui.text(c, "Shortcut, sync, updates", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .codes => {
                ui.text(c, "Find 2FA codes", .{ .size = 13.5, .weight = .medium, .color = p.text });
                ui.text(c, "Gmail and Messages", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .suggest => {
                const w = s.web.get(r.web);
                ui.richText(c, w, s.added(i, w, p), .{ .size = 13.5, .color = p.text.alpha(0.72), .truncate = .ellipsis });
            },
            .quick_ask, .new_thread, .digup, .search_web => {
                const verb = switch (r.kind) {
                    .quick_ask => "Ask",
                    .new_thread => "New T3 thread:",
                    .digup => "Search DigUp for",
                    else => "Search Google for",
                };
                ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis }, "{s} “{s}”", .{ verb, std.mem.trim(u8, q, " ") });
                ui.text(c, switch (r.kind) {
                    .quick_ask => "Haiku · sees your screen",
                    .new_thread => "T3 Code · default settings",
                    .digup => "Files, screenshots, email and Drive",
                    else => "google.com",
                }, .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
        }
        ui.spacer(c);
        if (i == s.sel) {
            ui.text(c, if (r.kind == .app or r.kind == .file or r.kind == .settings or r.kind == .pane) "Open" else "Go", .{ .size = 12, .weight = .medium, .color = p.sub });
            ui.kbd(c, "↩");
        } else if (s.res.number(i)) |num| ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.5), .tabular = true }, "{s}{d}", .{ results.mod, num });
    }

    fn calcCard(s: *Nanolight, c: *ui.Context, p: Palette) void {
        @import("calc_card.zig").draw(c, p, s.query.text(), s.res.answer, s.res.hex, c.time - s.copied_at < 1.4);
    }

    /// The row's picture: the app's icon, or a symbol on a quiet tile.
    fn tile(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
        // A pane: System Settings' own icon.
        const app = if (r.kind == .pane) s.index.find("System Settings") else if (r.kind == .app) r.app else null;
        if (app) |a| if (s.index.icon(a)) |png| {
            const box = ui.div(c).size(26, 26).center();
            defer box.end();
            _ = ui.image(c, .{ .key = s.index.apps.items[a].path, .bytes = png, .max_width = 26, .max_height = 26, .radius = 0, .scale = 1 });
            return;
        };
        if (r.kind == .file) return files_view.tile(s, c, p, r);
        const big = r.kind == .calc;
        const side: f32 = if (big) 34 else 26;
        const box = ui.div(c).size(side, side).rounded(if (big) 9 else 7).bg(p.tile).center();
        defer box.end();
        ui.icon(c, switch (r.kind) {
            .calc => "plus.forwardslash.minus",
            .quick_ask => "sparkles",
            .new_thread => "terminal",
            .digup => "doc.text.magnifyingglass",
            .codes => "lock",
            .search_web => "globe",
            .suggest => "magnifyingglass",
            .settings => "gearshape",
            else => "app.dashed",
        }, .{ .size = if (big) 16 else 13, .weight = .medium, .color = p.text });
    }

    /// The matched letters, full strength and heavier.
    pub fn highlight(s: *Nanolight, i: usize, r: Row, p: Palette) []const ui.Span {
        const hits = r.match.matched();
        var n: usize = 0;
        var k: usize = 0;
        while (k < hits.len and n < s.spans[i].len) {
            var end = k + 1;
            while (end < hits.len and hits[end] == hits[end - 1] + 1) end += 1;
            s.spans[i][n] = .{ .start = hits[k], .end = @as(u32, hits[end - 1]) + 1, .color = p.text, .weight = .semibold };
            n += 1;
            k = end;
        }
        return s.spans[i][0..n];
    }

    /// A completion as a search box shows it: the words typed plain, what
    /// it adds stronger.
    fn added(s: *Nanolight, i: usize, w: []const u8, p: Palette) []const ui.Span {
        const q = std.mem.trim(u8, s.query.text(), " ");
        if (q.len == 0 or w.len <= q.len or !text.utf8StartsWithFold(w, q)) return &.{};
        s.spans[i][0] = .{ .start = @intCast(q.len), .end = @intCast(w.len), .color = p.text, .weight = .semibold };
        return s.spans[i][0..1];
    }

    fn footer(s: *Nanolight, c: *ui.Context, p: Palette) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        appIcon(c, 16);
        ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8) }, "{s} · {d} apps", .{ if (s.note.len > 0) s.note else "SamSearch", s.index.apps.items.len });
        ui.spacer(c);
        {
            ui.key(c, "settings-gear");
            const g = ui.div(c).size(26, 26).rounded(7).center().control().hover(p.sel);
            defer g.end();
            if (g.clicked()) s.openSettings();
            ui.icon(c, "gearshape", .{ .size = 13, .weight = .medium, .color = p.sub });
            ui.text(c, "Settings", .{ .size = 1, .color = p.sub.alpha(0) });
        }
        if (s.previewing) {
            if (s.preview_kind != .digup and s.preview_kind != .codes) {
                ui.text(c, if (s.preview_kind == .quick_ask) "Open Answer Window" else "Open in Browser", .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
                ui.kbd(c, results.mod ++ "↩");
                ui.div(c).w(1).h(14).bg(p.hair).end();
            }
            ui.text(c, "Back", .{ .size = 12, .color = p.sub.alpha(0.8) });
            ui.kbd(c, "esc");
            return;
        }
        if (s.res.n == 0) return;
        ui.text(c, s.res.rows[@min(s.sel, s.res.n - 1)].kind.action(), .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
        ui.kbd(c, "↩");
        ui.div(c).w(1).h(14).bg(p.hair).end();
        ui.text(c, "Close", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }

    /// Return on the selected row.
    pub fn activate(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[@min(s.sel, s.res.n - 1)];
        switch (r.kind) {
            .calc => {
                var buf: [64]u8 = undefined;
                const v = @import("calc.zig").eval(s.query.text()) orelse return;
                c.clipboard.write(c.clipboard.ctx, @import("calc.zig").format(&buf, v, false));
                s.copied_at = c.time;
                return;
            },
            .app => {
                s.index.opened(r.app, s.kv);
                s.go(s.index.apps.items[r.app].path);
            },
            .file => s.go(s.found.entries[r.file].path()),
            .quick_ask, .digup, .codes => s.page(r.kind, s.query.text(), true),
            .new_thread => s.go(results.url(&s.url_buf, .new_thread, s.query.text())),
            .search_web => s.search(s.query.text(), !s.searches_out),
            .settings => s.openSettings(),
            .pane => s.go(@import("settings_panes.zig").urls[r.app]),
            .suggest => {
                // Its words fill the field, as a search box's would.
                s.query.set(s.web.get(r.web));
                s.search(s.query.text(), !s.searches_out);
            },
        }
    }

    /// ⌘↩ on the selected row: a search goes where Return doesn't send it.
    fn activateOut(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[@min(s.sel, s.res.n - 1)];
        switch (r.kind) {
            .quick_ask => s.go(results.answerUrl(&s.url_buf, s.query.text())),
            .search_web => s.search(s.query.text(), s.searches_out),
            .suggest => s.search(s.web.get(r.web), s.searches_out),
            else => s.activate(c),
        }
    }

    /// Google's page for `words`: in the panel when `in_panel` and the host
    /// can show it there, else in the browser.
    fn search(s: *Nanolight, words: []const u8, in_panel: bool) void {
        s.page(.search_web, words, in_panel);
    }

    fn page(s: *Nanolight, kind: results.Kind, words: []const u8, in_panel: bool) void {
        const h = s.host orelse return;
        const u = results.url(&s.preview_buf, kind, words);
        const show = (if (in_panel) h.preview else null) orelse return s.go(u);
        s.preview_url = u;
        s.preview_kind = kind;
        s.preview_answer = if (kind == .quick_ask) results.answerUrl(&s.preview_answer_buf, words) else "";
        s.previewing = true;
        s.preview_q = std.hash.Wyhash.hash(0, s.query.text());
        show(h.ctx, u);
    }

    /// Both the panel and WKWebView use the same page-specific handoff.
    /// Only Google may open a navigated browser URL; local pages never do.
    pub fn openPreviewOut(s: *Nanolight, current_url: ?[]const u8) void {
        if (!s.previewing) return;
        switch (s.preview_kind) {
            .quick_ask => s.go(s.preview_answer),
            .digup, .codes => {},
            .search_web => s.go(current_url orelse s.preview_url),
            else => {},
        }
    }

    pub fn openSettings(s: *Nanolight) void {
        s.back();
        s.settings_ui.show();
    }

    /// The rows again, the page gone.
    pub fn back(s: *Nanolight) void {
        if (!s.previewing) return;
        s.previewing = false;
        if (s.host) |h| if (h.preview) |f| f(h.ctx, null);
    }

    fn go(s: *Nanolight, target: []const u8) void {
        const h = s.host orelse return;
        h.open(h.ctx, target);
        h.hide(h.ctx);
    }
};
