//! What the panel lists for a query, in order: the answer when it is math,
//! the apps that match it (or, with no query, suggestions), then Google:
//! a search for exactly what is typed, first, and Google's completions of
//! it under that, a key or two away; last, the query asked of Grok or
//! searched on X. With no app or answer, Return searches what was typed
//! (as an address bar's does). Completions land a moment after the rest;
//! the panel keeps the selection on the row it was on (`Nanolight.answered`).
const std = @import("std");
const search = @import("search.zig");
const calc = @import("calc.zig");
const panes = @import("settings_panes.zig");
const mac = @import("builtin").os.tag == .macos;
const Index = @import("apps.zig").Index;

/// The key held for the panel's shortcuts (⌘1, ⌘↩, ⌘,): Ctrl on a PC.
pub const mod = if (mac) "⌘" else "Ctrl+";
/// What the panel calls the computer it runs on.
pub const machine = if (mac) "Mac" else "PC";

pub const Kind = enum {
    calc,
    app,
    ask_grok,
    search_x,
    search_web,
    /// One of Google's completions (`Row.web`).
    suggest,
    /// Nanolight's own Settings, listed when the query asks for them.
    settings,
    /// A pane of System Settings (`Row.app` its place in settings_panes.zig).
    pane,

    /// The row's kind as its trailing label shows it.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app => "Application",
            .settings => "Nanolight",
            .pane => "System Settings",
            .ask_grok, .search_x, .search_web, .suggest => "Web",
        };
    }

    /// What Return does to it.
    pub fn action(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Copy Answer",
            .app => "Open Application",
            .settings => "Open Settings",
            .pane => "Open in System Settings",
            .ask_grok => "Ask Grok",
            .search_x => "Search X",
            .search_web, .suggest => "Search Google",
        };
    }

    fn section(k: Kind, suggested: bool) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app => if (suggested) "Suggestions" else "Applications",
            .settings => "Nanolight",
            .pane => "System Settings",
            .search_web, .suggest => "Google",
            .ask_grok, .search_x => "Ask & Search",
        };
    }
};

pub const Row = struct {
    kind: Kind,
    /// The app's index (`.app`).
    app: u32 = 0,
    /// Which of the completions (`.suggest`).
    web: u8 = 0,
    /// Which of its name's bytes the query matched.
    match: search.Match = .{ .score = 0 },
};

pub const max_apps = 6;
/// System Settings' panes, under the apps (the Mac's).
pub const max_panes = 3;
/// Google's completions fill what room is left, up to four.
pub const max_web = 4;
/// Every app and the three web rows leave room for three completions.
pub const max_rows = max_apps + 3 + 3;
/// The web rows that always follow the apps: Google, Grok, X.
const handoffs = 3;

pub const Results = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,
    /// No query: the apps are suggestions, nothing else is listed.
    suggested: bool = false,
    /// The math's answer, as shown.
    answer_buf: [64]u8 = undefined,
    answer: []const u8 = "",
    /// A whole answer in hexadecimal too ("0xC00"), else empty.
    hex_buf: [24]u8 = undefined,
    hex: []const u8 = "",

    pub fn slice(r: *const Results) []const Row {
        return r.rows[0..r.n];
    }

    /// Lists what `query` finds among `names` (with how often each was
    /// opened, `boost`) and Google's completions of it (`web`), or
    /// `suggestions` when the query is empty.
    pub fn build(r: *Results, query_in: []const u8, ix: *const Index, suggestions: []const u32, web: []const []const u8) void {
        const boost = ix.launches.items;
        r.n = 0;
        const query = std.mem.trim(u8, query_in, " ");
        r.suggested = query.len == 0;
        if (query.len == 0) {
            for (suggestions[0..@min(suggestions.len, max_apps)]) |i| r.push(.{ .kind = .app, .app = i });
            return;
        }
        if (calc.eval(query)) |v| {
            r.answer = calc.format(&r.answer_buf, v, true);
            r.hex = if (v >= 0 and v < 1e15 and v == @round(v))
                std.fmt.bufPrint(&r.hex_buf, "0x{X}", .{@as(u64, @intFromFloat(v))}) catch ""
            else
                "";
            r.push(.{ .kind = .calc });
        }
        var ranked: [max_apps]search.Ranked = undefined;
        const n = search.rankApps(query, ix, boost, &ranked);
        for (ranked[0..n]) |x| r.push(.{ .kind = .app, .app = x.index, .match = x.match });
        // "settings" / "preferences": Nanolight's own screen, right under
        // the apps: Return still opens System Settings, a key away from this.
        if (isSettings(query)) r.push(.{ .kind = .settings });
        if (r.n > 0 and r.rows[0].kind == .calc) return;
        // System Settings' panes, in their own section. A section's header
        // is less than a row: one completion fewer pays for it, so the
        // panel never grows past its tallest (view.max_height).
        var pane_rows: [max_panes]search.Ranked = undefined;
        const np = if (isSettings(query)) 0 else panes.rank(query, &pane_rows);
        for (pane_rows[0..np]) |x| r.push(.{ .kind = .pane, .app = x.index, .match = x.match });
        // The search for what was typed, its completions (as many as leave
        // room for the rest), then Grok and X.
        const room = max_rows - r.n - handoffs - @intFromBool(np > 0);
        r.push(.{ .kind = .search_web });
        for (0..@min(web.len, max_web, room)) |i| r.push(.{ .kind = .suggest, .web = @intCast(i) });
        r.push(.{ .kind = .ask_grok });
        r.push(.{ .kind = .search_x });
    }

    /// "settings" and "preferences", the words people type for this.
    fn isSettings(query: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(query, "settings") or std.ascii.eqlIgnoreCase(query, "preferences")) return true;
        const keys = [_][]const u8{ "设置", "偏好设置", "系统设置", "nanolight 设置" };
        const q = std.mem.trim(u8, query, " ");
        for (keys) |k| if (std.mem.eql(u8, q, k)) return true;
        return false;
    }

    fn push(r: *Results, row: Row) void {
        if (r.n == max_rows) return;
        r.rows[r.n] = row;
        r.n += 1;
    }

    /// The header above row `i`, if a section starts there.
    pub fn section(r: *const Results, i: usize) ?[]const u8 {
        const k = r.rows[i].kind;
        const name = k.section(r.suggested);
        if (i > 0 and std.mem.eql(u8, r.rows[i - 1].kind.section(r.suggested), name)) return null;
        return name;
    }
};

/// The address a web row opens for `query`.
pub fn url(buf: []u8, kind: Kind, query: []const u8) []const u8 {
    const base = switch (kind) {
        .ask_grok => "https://grok.com/?q=",
        .search_x => "https://x.com/search?f=live&q=",
        .search_web, .suggest => "https://www.google.com/search?q=",
        .calc, .app, .settings, .pane => return "",
    };
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(base) catch return "";
    escape(&w, query);
    return w.buffered();
}

/// `query`, trimmed, as a URL's query value: spaces as `+`, the rest of
/// what isn't plain as `%XX`. Stops where `w` is full.
pub fn escape(w: *std.Io.Writer, query: []const u8) void {
    for (std.mem.trim(u8, query, " ")) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            w.writeByte(ch) catch break;
        } else if (ch == ' ') {
            w.writeByte('+') catch break;
        } else w.print("%{X:0>2}", .{ch}) catch break;
    }
}

fn testIndex(a: std.mem.Allocator, names: []const []const u8) !Index {
    var ix: Index = .init(a);
    for (names) |n| {
        var buf: [128]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    return ix;
}

test "math first, then apps; ask and search only without an answer" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build("saf", &ix, &.{}, &.{});
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 0), r.rows[0].app);
    try t.expectEqual(Kind.search_web, r.rows[r.n - 3].kind);
    try t.expectEqualStrings("Applications", r.section(0).?);
    try t.expectEqualStrings("Google", r.section(1).?);
    try t.expectEqualStrings("Ask & Search", r.section(2).?);
    try t.expect(r.section(3) == null);
    r.build("2^10 * 3", &ix, &.{}, &.{"ignored"});
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("3,072", r.answer);
    try t.expectEqualStrings("0xC00", r.hex);
    try t.expectEqual(@as(usize, 1), r.n);
    r.build("", &ix, &.{ 2, 0 }, &.{});
    try t.expectEqual(@as(usize, 2), r.n);
    try t.expectEqualStrings("Suggestions", r.section(0).?);
    r.build("liquid glass", &ix, &.{}, &.{});
    try t.expectEqual(@as(usize, 3), r.n);
    // No app: the search for what was typed comes first.
    try t.expectEqual(Kind.search_web, r.rows[0].kind);
    try t.expectEqualStrings("Google", r.section(0).?);
    try t.expectEqualStrings("Ask & Search", r.section(1).?);
    // Completions under it, in the same section, then Grok and X.
    r.build("liquid gl", &ix, &.{}, &.{ "liquid glass", "liquid glue" });
    try t.expectEqual(@as(usize, 5), r.n);
    try t.expectEqual(Kind.search_web, r.rows[0].kind);
    try t.expectEqual(Kind.suggest, r.rows[1].kind);
    try t.expectEqual(@as(u8, 1), r.rows[2].web);
    try t.expectEqual(Kind.ask_grok, r.rows[3].kind);
    try t.expect(r.section(1) == null and r.section(2) == null);
    try t.expectEqualStrings("Ask & Search", r.section(3).?);
    // "settings": System Settings first, Nanolight's own a row under it.
    r.build("settings", &ix, &.{}, &.{});
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 1), r.rows[0].app);
    try t.expectEqual(Kind.settings, r.rows[1].kind);
    // A full list of apps still ends with every handoff.
    var many_ix = try testIndex(t.allocator, &.{ "Safari", "Mail", "Maps", "Pages", "Calendar", "Calculator", "FaceTime" });
    defer many_ix.deinit();
    r.build("a", &many_ix, &.{}, &.{ "a1", "a2", "a3", "a4" });
    try t.expectEqual(max_rows, r.n);
    try t.expectEqual(Kind.search_web, r.rows[max_apps].kind);
    try t.expectEqual(Kind.suggest, r.rows[max_apps + 1].kind);
    try t.expectEqual(Kind.search_x, r.rows[max_rows - 1].kind);
}

test "queries are escaped into the address" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://x.com/search?f=live&q=liquid+glass+%26+UI", url(&buf, .search_x, " liquid glass & UI "));
}

test "System Settings' panes come under the apps and keep the panel's height (#12)" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    const names = [_][]const u8{ "Safari", "System Settings", "Calculator" };
    var r: Results = .{};
    r.build("login items", &names, &.{}, &.{}, &.{ "login items mac", "login items windows", "login items iphone" });
    try t.expectEqual(Kind.pane, r.rows[0].kind);
    try t.expectEqualStrings("System Settings", r.section(0).?);
    try t.expectEqualStrings("Login Items & Extensions", panes.all[r.rows[0].app].name);
    // Google's completions give up a row for the section's header.
    try t.expect(r.n <= max_rows - 1);
    // "settings" is Nanolight's own Settings and System Settings the app,
    // not every pane with "settings" in a word for it.
    r.build("settings", &names, &.{}, &.{}, &.{});
    for (r.slice()) |row| try t.expect(row.kind != .pane);
    // Math lists no panes.
    r.build("2+2", &names, &.{}, &.{}, &.{});
    try t.expectEqual(@as(usize, 1), r.n);
}
