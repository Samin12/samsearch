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
const digup = @import("digup.zig");
const gmail = @import("gmail.zig");
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
    digup: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    reveal: ?*const fn (ctx: *anyopaque, path: []const u8) void = null,
    /// Opens a URL in one of Chrome's profiles (gmail.zig); without it, in
    /// the default browser.
    chrome: ?*const fn (ctx: *anyopaque, profile: []const u8, url: []const u8) void = null,
    /// Shows a search's page in the panel, over `webArea`; null takes it
    /// away. Without it, searches open in the browser.
    preview: ?*const fn (ctx: *anyopaque, url: ?[]const u8) void = null,
    /// Moves the Quick Ask conversation shown in the panel to its floating
    /// window, then calls `answerMoved`. Without it, the question is asked
    /// again there.
    move_answer: ?*const fn (ctx: *anyopaque) void = null,
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
    pipeline: @import("search.zig").Query = .{},
    query_hash: ?u64 = null,
    source_flags: u3 = 0,
    filled_lists: u64 = 0,
    numbers: [9]?results.RowKey = @splat(null),
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
    copied_query: ?u64 = null,
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
    digup_on: bool = true,
    dug: digup.List = .{},
    /// Last frame's controls, for the Mac's native drag gestures.
    row_ids: [results.max_rows]u64 = @splat(0),
    row_keys: [results.max_rows]?results.RowKey = @splat(null),
    query_id: u64 = 0,
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
        s.row_ids = @splat(0);
        s.query_id = 0;
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

        // Settings and index refreshes can invalidate rows between frames.
        if (s.built != std.hash.Wyhash.hash(0, s.query.text()) or s.filled_lists != s.listsHash()) s.rebuild();
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
        if (c.shortcut(.{ .key = 'r', .cmd = true })) {
            if (s.sel < s.res.n) if (s.filePath(s.res.rows[s.sel])) |path| {
                if (s.host) |h| if (h.reveal) |f| f(h.ctx, path);
            };
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
        s.query_id = c.peekId(null);
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

    /// One generation for a query and its enabled sources.
    pub fn rebuild(s: *Nanolight) void {
        const q = s.query.text();
        const h = std.hash.Wyhash.hash(0, q);
        const flags = @as(u3, @intFromBool(s.suggest_on)) |
            (@as(u3, @intFromBool(s.files_on)) << 1) | (@as(u3, @intFromBool(s.digup_on)) << 2);
        const changed = s.query_hash == null or s.query_hash.? != h or s.source_flags != flags;
        if (!changed) {
            if (s.built != h or s.filled_lists != s.listsHash()) {
                s.built = h;
                s.refill();
            }
            return;
        }
        s.query_hash = h;
        s.source_flags = flags;
        s.built = h;
        s.pipeline.begin();
        s.numbers = @splat(null);
        s.copied_query = null;
        s.sel = 0;
        files_view.rebuild(s);
        s.dug.deinit();
        if (s.host) |host| if (host.digup) |ask| {
            if (s.digup_on and digup.eligible(std.mem.trim(u8, q, " \t\r\n"))) s.pipeline.set(.digup, .pending);
            ask(host.ctx, q);
        };
        s.web.n = 0;
        if (s.suggest_on and suggest.eligible(q) and @import("calc.zig").eval(q) == null) {
            if (s.cache.lookup(q, &s.web)) {
                s.pipeline.set(.google, .answered);
            } else if (s.host) |host| if (host.suggest) |ask| {
                s.pipeline.set(.google, .pending);
                ask(host.ctx, q);
            };
        }
        s.pipeline.set(.gmail, .answered);
        s.fill();
    }

    fn listsHash(s: *const Nanolight) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (s.found.entries[0..s.found.n]) |*e| hash.update(e.path());
        for (s.dug.found.entries[0..s.dug.found.n]) |*e| hash.update(e.path());
        for (0..s.web.n) |i| hash.update(s.web.get(i));
        return hash.final();
    }

    pub fn fill(s: *Nanolight) void {
        var sug: [results.max_apps]u32 = undefined;
        const ns = s.index.suggestions(&sug);
        var web: [suggest.max_rows][]const u8 = undefined;
        s.res.buildWithDigup(s.query.text(), s.index, sug[0..ns], s.web.slices(&web), &s.found, if (s.digup_on) s.dug.found.n else 0);
        const handoffs = for (s.res.slice()) |r| {
            if (r.kind == .quick_ask) break true;
        } else false;
        // Reserve the three handoffs even before any other rows arrive.
        if (handoffs) {
            s.numbers[0] = .{ .kind = .quick_ask };
            s.numbers[1] = .{ .kind = .new_thread };
            s.numbers[2] = .{ .kind = .digup };
        }
        for (s.res.rows[0..s.res.n]) |*r| {
            r.key = s.makeKey(r.*);
            for (&s.numbers, 0..) |*slot, i| {
                if (slot.*) |key| {
                    if (!key.eql(r.key)) continue;
                } else slot.* = r.key;
                r.number = @intCast(i + 1);
                break;
            }
        }
        s.res.stable_numbers = true;
        s.filled_lists = s.listsHash();
    }

    fn makeKey(s: *const Nanolight, r: Row) results.RowKey {
        return switch (r.kind) {
            .app => .init(r.kind, s.index.apps.items[r.app].path),
            .file => .init(r.kind, s.found.entries[r.file].path()),
            .digup_hit => .init(r.kind, s.dug.found.entries[r.file].path()),
            .suggest => .init(r.kind, s.web.get(r.web)),
            .gmail => .init(r.kind, gmail.accounts[r.file].email),
            .pane => .{ .kind = r.kind, .id = r.app },
            else => .{ .kind = r.kind },
        };
    }

    pub fn selectedKey(s: *const Nanolight) ?results.RowKey {
        return if (s.sel < s.res.n) s.res.rows[s.sel].key else null;
    }

    /// Resolve last frame's identity against the current source lists.
    pub fn rowByKey(s: *const Nanolight, key: results.RowKey) ?Row {
        for (s.res.slice()) |r| {
            if (!r.key.eql(key)) continue;
            if ((r.kind == .file and r.file >= s.found.n) or
                (r.kind == .digup_hit and r.file >= s.dug.found.n) or
                (r.kind == .suggest and r.web >= s.web.n) or
                (r.kind == .app and r.app >= s.index.apps.items.len)) return null;
            if (s.makeKey(r).eql(key)) return r;
        }
        return null;
    }

    pub fn refill(s: *Nanolight) void {
        s.refillSelected(s.selectedKey());
    }

    pub fn refillSelected(s: *Nanolight, was: ?results.RowKey) void {
        s.fill();
        s.sel = 0;
        const key = was orelse return;
        for (s.res.slice(), 0..) |r, i| if (r.key.eql(key)) {
            s.sel = i;
            return;
        };
    }

    /// Only a successful Google answer may enter the completion cache.
    pub fn googleAnswered(s: *Nanolight, generation: u64, said: ?*const suggest.List) void {
        s.rebuild();
        if (!s.suggest_on or !s.pipeline.finish(generation, .google, if (said != null) .answered else .failed)) return;
        const was = s.selectedKey();
        s.web = if (said) |said_list| said_list.* else .{};
        if (said) |said_list| s.cache.put(s.query.text(), said_list);
        s.refillSelected(was);
    }

    /// Synchronous compatibility for panel fixtures; workers pass generations.
    pub fn answered(s: *Nanolight, typed: []const u8, said: *const suggest.List) void {
        if (!suggest.same(typed, s.query.text())) return;
        s.rebuild();
        s.googleAnswered(s.pipeline.generation, said);
    }

    pub const filesAnswered = files_view.filesAnswered;
    pub const filesAnsweredGeneration = files_view.filesAnsweredGeneration;

    pub fn digupAnsweredGeneration(s: *Nanolight, generation: u64, found: ?*digup.List) void {
        s.rebuild();
        if (!s.digup_on or !s.pipeline.finish(generation, .digup, if (found != null) .answered else .failed)) return;
        const was = s.selectedKey();
        if (found) |found_list| s.dug.replace(found_list) else s.dug.deinit();
        s.refillSelected(was);
    }

    pub fn digupAnswered(s: *Nanolight, typed: []const u8, found: *digup.List) void {
        if (!std.mem.eql(u8, typed, std.mem.trim(u8, s.query.text(), " \t\r\n"))) return;
        s.rebuild();
        s.digupAnsweredGeneration(s.pipeline.generation, found);
    }

    pub fn copied(s: *const Nanolight, time: f64) bool {
        return s.copied_query != null and s.copied_query.? == std.hash.Wyhash.hash(0, s.query.text()) and time - s.copied_at < 1.4;
    }

    /// A real file behind a row; extension commands are not app bundles.
    pub fn filePath(s: *const Nanolight, r: Row) ?[]const u8 {
        const path = switch (r.kind) {
            .app => s.index.apps.items[r.app].path,
            .file => s.found.entries[r.file].path(),
            .digup_hit => s.dug.found.entries[r.file].path(),
            else => return null,
        };
        return if (path.len > 0 and path[0] == '/') path else null;
    }

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
        s.row_ids[i] = d.id();
        s.row_keys[i] = r.key;
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
            .digup_hit => {
                const e = &s.dug.found.entries[r.file];
                if (digup.email(e.path())) |m| {
                    ui.text(c, m.subject, .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82), .truncate = .ellipsis });
                    ui.textf(c, .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis }, "Email · {s} · {s}", .{ m.account, m.date });
                } else {
                    ui.text(c, e.name(), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82), .truncate = .ellipsis });
                    var buf: [files.max_path]u8 = undefined;
                    ui.textf(c, .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis }, "{s} · {s}", .{ s.dug.kind(r.file), files.parent(&buf, e.path()) });
                }
            },
            .settings => {
                ui.text(c, "SamSearch Settings", .{ .size = 13.5, .weight = .medium, .color = p.text });
                ui.text(c, "Shortcut, sync, updates", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .gmail => {
                const a = gmail.accounts[r.file];
                const words = gmail.terms(q);
                if (words.len > 0)
                    ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis }, "Search {s} Gmail for “{s}”", .{ a.name, words })
                else
                    ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text }, "Gmail · {s}", .{a.name});
                ui.textf(c, .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis }, "{s} · Chrome", .{a.email});
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
            ui.text(c, if (r.kind == .app or r.kind == .file or r.kind == .digup_hit or r.kind == .settings or r.kind == .pane or r.kind == .gmail) "Open" else "Go", .{ .size = 12, .weight = .medium, .color = p.sub });
            ui.kbd(c, "↩");
        } else if (s.res.number(i)) |num| ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.5), .tabular = true }, "{s}{d}", .{ results.mod, num });
    }

    fn calcCard(s: *Nanolight, c: *ui.Context, p: Palette) void {
        @import("calc_card.zig").draw(c, p, s.query.text(), s.res.answer, s.res.hex, s.copied(c.time));
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
        if (r.kind == .gmail) {
            const box = ui.div(c).size(26, 26).center();
            defer box.end();
            _ = ui.image(c, .{ .key = "gmail-icon", .bytes = gmail.icon_png, .max_width = 22, .max_height = 22, .radius = 0, .scale = 2 });
            return;
        }
        if (r.kind == .digup_hit) {
            const e = &s.dug.found.entries[r.file];
            if (e.png.len > 0) {
                const box = ui.div(c).size(26, 26).center();
                defer box.end();
                _ = ui.image(c, .{ .key = e.path(), .bytes = e.png, .max_width = 26, .max_height = 26, .radius = 0, .scale = 1 });
                return;
            }
        }
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
                s.copied_query = std.hash.Wyhash.hash(0, s.query.text());
                return;
            },
            .app => {
                s.index.opened(r.app, s.kv);
                s.index.picked(s.query.text(), r.app, s.kv);
                s.go(s.index.apps.items[r.app].path);
            },
            .file => s.go(s.found.entries[r.file].path()),
            .digup_hit => s.go(s.dug.found.entries[r.file].path()),
            .quick_ask, .digup, .codes => s.page(r.kind, s.query.text(), true),
            .new_thread => s.go(results.url(&s.url_buf, .new_thread, s.query.text())),
            .search_web => s.search(s.query.text(), !s.searches_out),
            .settings => s.openSettings(),
            .pane => s.go(@import("settings_panes.zig").urls[r.app]),
            .gmail => {
                const h = s.host orelse return;
                const open = h.chrome orelse return s.go(gmail.url(&s.url_buf, r.file, s.query.text()));
                open(h.ctx, gmail.accounts[r.file].profile, gmail.url(&s.url_buf, r.file, s.query.text()));
                h.hide(h.ctx);
            },
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
            .quick_ask => {
                const h = s.host orelse return;
                const move = h.move_answer orelse return s.go(s.preview_answer);
                move(h.ctx);
            },
            .digup, .codes => {},
            .search_web => s.go(current_url orelse s.preview_url),
            else => {},
        }
    }

    /// Quick Ask answered `move_answer`: the floating window has the
    /// conversation now, or (not `ok`, e.g. an older helper) it asks again.
    pub fn answerMoved(s: *Nanolight, ok: bool) void {
        if (!s.previewing or s.preview_kind != .quick_ask) return;
        const h = s.host orelse return;
        s.back();
        if (ok) h.hide(h.ctx) else s.go(s.preview_answer);
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
