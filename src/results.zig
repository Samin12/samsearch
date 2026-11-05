//! What the panel lists for a query, in order: the answer when it is math,
//! the apps that match it (or, with no query, suggestions), strong DigUp
//! hits, then Google:
//! a search for exactly what is typed, first, and Google's completions of
//! it under that, a key or two away; last, Quick Ask, a new T3 thread,
//! and DigUp. With no app or answer, Return searches what was typed
//! (as an address bar's does). Completions land a moment after the rest;
//! the panel keeps the selection on the row it was on (`Nanolight.answered`).
const std = @import("std");
const search = @import("search.zig");
const files = @import("files.zig");
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
    file,
    digup_hit,
    quick_ask,
    new_thread,
    digup,
    codes,
    search_web,
    /// One of Google's completions (`Row.web`).
    suggest,
    /// SamSearch's own Settings, listed when the query asks for them.
    settings,
    /// A pane of System Settings (`Row.app` its place in settings_panes.zig).
    pane,

    /// The row's kind as its trailing label shows it.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app => "Application",
            .file => "File",
            .digup_hit => "DigUp",
            .settings => "SamSearch",
            .pane => "System Settings",
            .quick_ask, .new_thread, .digup, .codes => "Ask & Search",
            .search_web, .suggest => "Web",
        };
    }

    /// What Return does to it.
    pub fn action(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Copy Answer",
            .app => "Open Application",
            .file, .digup_hit => "Open",
            .settings => "Open Settings",
            .pane => "Open in System Settings",
            .quick_ask => "Ask",
            .new_thread => "Start T3 Thread",
            .digup => "Search DigUp",
            .codes => "Find 2FA codes",
            .search_web, .suggest => "Search Google",
        };
    }

    fn section(k: Kind, suggested: bool) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app => if (suggested) "Suggestions" else "Applications",
            .file => "Files",
            .digup_hit => "DigUp",
            .settings => "SamSearch",
            .pane => "System Settings",
            .search_web, .suggest => "Google",
            .quick_ask, .new_thread, .digup, .codes => "Ask & Search",
        };
    }
};

pub const Row = struct {
    kind: Kind,
    /// The app's index (`.app`).
    app: u32 = 0,
    file: u8 = 0,
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
/// Every app and four handoffs leave room for two completions, keeping
/// the original twelve-row height budget.
pub const max_rows = max_apps + 4 + 2;
/// The rows that always follow the apps: Google, Quick Ask, T3, DigUp.
const handoffs = 4;

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

    /// Lists what `query` finds in the app index and files, with Google's
    /// completions (`web`), or
    /// `suggestions` when the query is empty.
    pub fn build(r: *Results, query_in: []const u8, ix: *const Index, suggestions: []const u32, web: []const []const u8, found: *const files.List) void {
        r.buildWithDigup(query_in, ix, suggestions, web, found, 0);
    }

    /// DigUp uses only the room left for completions, including its head.
    pub fn buildWithDigup(r: *Results, query_in: []const u8, ix: *const Index, suggestions: []const u32, web: []const []const u8, found: *const files.List, digup_count: usize) void {
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
        const settings = isSettings(query);
        // Math keeps its answer and the matching apps, without handoffs.
        if (r.n > 0 and r.rows[0].kind == .calc) {
            for (ranked[0..n]) |x| r.push(.{ .kind = .app, .app = x.index, .match = x.match });
            return;
        }
        var pane_rows: [max_panes]search.Ranked = undefined;
        const np = if (settings) 0 else panes.rank(query, &pane_rows);
        // One row pays for each section head beyond the original three, so
        // the panel never grows past its tallest (view.max_height).
        const heads: usize = 2 + @as(usize, @intFromBool(n > 0)) + @as(usize, @intFromBool(np > 0)) +
            @as(usize, @intFromBool(settings)) + @as(usize, @intFromBool(found.n > 0));
        const limit = max_rows -| (heads -| 3);
        const codes = isCodes(query);
        const fixed = handoffs + @as(usize, @intFromBool(codes)) + @as(usize, @intFromBool(settings));
        const first_pane: usize = @intFromBool(np > 0);
        const file_row: usize = @intFromBool(found.n > 0);
        // Apps come first. Panes and files are sure of a row each and take
        // only what is left: a full list of apps ("hola") leaves room for
        // one pane, not three.
        const app_count = @min(n, limit -| fixed -| first_pane -| file_row);
        const pane_count = @min(np, limit -| fixed -| file_row -| app_count);
        const count = @min(found.n, limit -| fixed -| app_count -| pane_count);
        // An exact path leads, with its siblings under one Files head.
        if (found.exact) for (0..count) |i| {
            r.push(.{ .kind = .file, .file = @intCast(i), .match = found.entries[i].match });
        };
        for (ranked[0..app_count]) |x| r.push(.{ .kind = .app, .app = x.index, .match = x.match });
        // "settings" / "preferences": SamSearch's own screen, right under
        // the apps: Return still opens System Settings, a key away from this.
        if (settings) r.push(.{ .kind = .settings });
        for (pane_rows[0..pane_count]) |x| r.push(.{ .kind = .pane, .app = x.index, .match = x.match });
        if (!found.exact) for (0..count) |i| {
            r.push(.{ .kind = .file, .file = @intCast(i), .match = found.entries[i].match });
        };
        // The search for what was typed, its completions (as many as leave
        // room for the rest), then Quick Ask, T3 and DigUp.
        const room = limit -| r.n -| handoffs -| @as(usize, @intFromBool(codes));
        const head_cost: usize = @intFromBool(heads >= 3);
        const hits = @min(digup_count, @import("digup.zig").max_rows, room -| head_cost);
        for (0..hits) |i| r.push(.{ .kind = .digup_hit, .file = @intCast(i) });
        const web_room = room -| hits -| (if (hits > 0) head_cost else 0);
        r.push(.{ .kind = .search_web });
        for (0..@min(web.len, max_web, web_room)) |i| r.push(.{ .kind = .suggest, .web = @intCast(i) });
        if (codes) r.push(.{ .kind = .codes });
        r.push(.{ .kind = .quick_ask });
        r.push(.{ .kind = .new_thread });
        r.push(.{ .kind = .digup });
    }

    /// "settings" and "preferences", the words people type for this.
    fn isSettings(query: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(query, "settings") or std.ascii.eqlIgnoreCase(query, "preferences")) return true;
        const keys = [_][]const u8{ "设置", "偏好设置", "系统设置", "samsearch 设置" };
        const q = std.mem.trim(u8, query, " ");
        for (keys) |k| if (std.mem.eql(u8, q, k)) return true;
        return false;
    }

    /// A code request starts with one of these words, never part of one.
    fn isCodes(query: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, query, " \t\r\n:?!");
        const first = words.next() orelse return false;
        for ([_][]const u8{ "2fa", "otp", "code", "codes", "verification", "verify" }) |key| {
            if (std.ascii.eqlIgnoreCase(first, key)) return true;
        }
        return false;
    }

    fn push(r: *Results, row: Row) void {
        if (r.n == max_rows) return;
        r.rows[r.n] = row;
        r.n += 1;
    }

    /// Row `i`'s ⌘ number, if it has one. Ask, the T3 thread and DigUp are
    /// always ⌘1, ⌘2 and ⌘3 wherever they sit; the other rows count on from
    /// ⌘4 in order. With no handoffs listed (math, an empty query) the rows
    /// are simply ⌘1 to ⌘9.
    pub fn number(r: *const Results, i: usize) ?u8 {
        if (i >= r.n) return null;
        const handoffs_listed = for (r.slice()) |row| {
            if (row.kind == .quick_ask) break true;
        } else false;
        if (!handoffs_listed) return if (i < 9) @intCast(i + 1) else null;
        switch (r.rows[i].kind) {
            .quick_ask => return 1,
            .new_thread => return 2,
            .digup => return 3,
            else => {},
        }
        var next: u8 = 4;
        for (r.rows[0..i]) |row| switch (row.kind) {
            .quick_ask, .new_thread, .digup => {},
            else => next += 1,
        };
        return if (next <= 9) next else null;
    }

    /// The row whose ⌘ number is `d` (1–9).
    pub fn rowFor(r: *const Results, d: u8) ?usize {
        for (0..r.n) |i| if (r.number(i) == d) return i;
        return null;
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
        .quick_ask => "http://127.0.0.1:47213/ask?q=",
        .new_thread => "quickask://t3-thread-create?q=",
        .digup => "http://127.0.0.1:47213/digup?q=",
        .codes => return "http://127.0.0.1:47213/codes",
        .search_web, .suggest => "https://www.google.com/search?q=",
        .calc, .app, .file, .digup_hit, .settings, .pane => return "",
    };
    return queryUrl(buf, base, query);
}

/// Quick Ask in its floating answer window.
pub fn answerUrl(buf: []u8, query: []const u8) []const u8 {
    return queryUrl(buf, "quickask://answer?q=", query);
}

fn queryUrl(buf: []u8, base: []const u8, query: []const u8) []const u8 {
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
    r.build("saf", &ix, &.{}, &.{}, &.{});
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 0), r.rows[0].app);
    try t.expectEqual(Kind.search_web, r.rows[r.n - 4].kind);
    try t.expectEqualStrings("Applications", r.section(0).?);
    try t.expectEqualStrings("Google", r.section(1).?);
    try t.expectEqualStrings("Ask & Search", r.section(2).?);
    try t.expect(r.section(3) == null);
    r.build("2^10 * 3", &ix, &.{}, &.{"ignored"}, &.{});
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("3,072", r.answer);
    try t.expectEqualStrings("0xC00", r.hex);
    try t.expectEqual(@as(usize, 1), r.n);
    r.build("", &ix, &.{ 2, 0 }, &.{}, &.{});
    try t.expectEqual(@as(usize, 2), r.n);
    try t.expectEqualStrings("Suggestions", r.section(0).?);
    r.build("liquid glass", &ix, &.{}, &.{}, &.{});
    try t.expectEqual(@as(usize, 4), r.n);
    // No app: the search for what was typed comes first.
    try t.expectEqual(Kind.search_web, r.rows[0].kind);
    try t.expectEqualStrings("Google", r.section(0).?);
    try t.expectEqualStrings("Ask & Search", r.section(1).?);
    // Completions under it, in the same section, then Quick Ask, T3 and DigUp.
    r.build("liquid gl", &ix, &.{}, &.{ "liquid glass", "liquid glue" }, &.{});
    try t.expectEqual(@as(usize, 6), r.n);
    try t.expectEqual(Kind.search_web, r.rows[0].kind);
    try t.expectEqual(Kind.suggest, r.rows[1].kind);
    try t.expectEqual(@as(u8, 1), r.rows[2].web);
    try t.expectEqual(Kind.quick_ask, r.rows[3].kind);
    try t.expect(r.section(1) == null and r.section(2) == null);
    try t.expectEqualStrings("Ask & Search", r.section(3).?);
    // "settings": System Settings first, SamSearch's own a row under it.
    r.build("settings", &ix, &.{}, &.{}, &.{});
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 1), r.rows[0].app);
    try t.expectEqual(Kind.settings, r.rows[1].kind);
    // A full list of apps still ends with every handoff.
    var many_ix = try testIndex(t.allocator, &.{ "Safari", "Mail", "Maps", "Pages", "Calendar", "Calculator", "FaceTime" });
    defer many_ix.deinit();
    r.build("a", &many_ix, &.{}, &.{ "a1", "a2", "a3", "a4" }, &.{});
    try t.expectEqual(max_rows, r.n);
    try t.expectEqual(Kind.search_web, r.rows[max_apps].kind);
    try t.expectEqual(Kind.suggest, r.rows[max_apps + 1].kind);
    try t.expectEqual(Kind.suggest, r.rows[max_apps + 2].kind);
    try t.expectEqual(Kind.quick_ask, r.rows[max_apps + 3].kind);
    try t.expectEqual(Kind.new_thread, r.rows[max_apps + 4].kind);
    try t.expectEqual(Kind.digup, r.rows[max_rows - 1].kind);
}

test "queries are escaped into the address" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:47213/digup?q=liquid+glass+%26+UI", url(&buf, .digup, " liquid glass & UI "));
}

test "System Settings' panes come under the apps and keep the panel's height (#12)" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build("login items", &ix, &.{}, &.{ "login items mac", "login items windows", "login items iphone" }, &.{});
    try t.expectEqual(Kind.pane, r.rows[0].kind);
    try t.expectEqualStrings("System Settings", r.section(0).?);
    try t.expectEqualStrings("Login Items & Extensions", panes.all[r.rows[0].app].name);
    // Google's completions give up a row for the section's header.
    try t.expect(r.n <= max_rows - 1);
    // "settings" is SamSearch's own Settings and System Settings the app,
    // not every pane with "settings" in a word for it.
    r.build("settings", &ix, &.{}, &.{}, &.{});
    for (r.slice()) |row| try t.expect(row.kind != .pane);
    // Math lists no panes.
    r.build("2+2", &ix, &.{}, &.{}, &.{});
    try t.expectEqual(@as(usize, 1), r.n);
}

test "a full list of apps and three panes still fits, with every handoff" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    // Six apps match "ho", and so do three panes (Desktop & Dock, Sound,
    // Keyboard): typing "hola" used to overflow the room left for Google.
    var ix = try testIndex(t.allocator, &.{ "Home", "Hopper", "Hotspot Shield", "Photos", "Shortcuts", "Photo Booth", "Phone" });
    defer ix.deinit();
    var r: Results = .{};
    const web = [_][]const u8{ "hola", "hotmail", "hoy", "horoscopo" };
    r.build("ho", &ix, &.{}, &web, &.{});
    var apps_n: usize = 0;
    var panes_n: usize = 0;
    for (r.slice()) |row| switch (row.kind) {
        .app => apps_n += 1,
        .pane => panes_n += 1,
        else => {},
    };
    try t.expectEqual(@as(usize, max_apps), apps_n);
    // The header costs a row: one pane, not three.
    try t.expectEqual(@as(usize, 1), panes_n);
    try t.expect(r.n <= max_rows - @as(usize, @intFromBool(panes_n > 0)));
    try t.expectEqual(Kind.search_web, r.rows[r.n - 4].kind);
    try t.expectEqual(Kind.quick_ask, r.rows[r.n - 3].kind);
    try t.expectEqual(Kind.digup, r.rows[r.n - 1].kind);
    // With files too there are five heads: every section keeps a row, and
    // the apps keep the rest.
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    for (0..files.max_rows) |i| {
        var path: [64]u8 = undefined;
        found.add(try std.fmt.bufPrint(&path, "/tmp/ho{d}", .{i}), false, .{ .score = 1 });
    }
    r.build("ho", &ix, &.{}, &web, &found);
    var counts = std.enums.EnumArray(Kind, usize).initFill(0);
    for (r.slice()) |row| counts.set(row.kind, counts.get(row.kind) + 1);
    try t.expectEqual(@as(usize, max_apps - 2), counts.get(.app));
    try t.expectEqual(@as(usize, 1), counts.get(.pane));
    try t.expectEqual(@as(usize, 1), counts.get(.file));
    try t.expectEqual(@as(usize, max_rows - 2), r.n);
    try t.expectEqual(Kind.search_web, r.rows[r.n - 4].kind);
    try t.expectEqual(Kind.digup, r.rows[r.n - 1].kind);
}

test "Quick Ask, T3 and DigUp follow Google completions in order with escaped handoffs" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var r: Results = .{};
    r.build(" liquid glass & UI ", &ix, &.{}, &.{"liquid glass & UI ideas"}, &.{});
    const kinds = [_]Kind{ .search_web, .suggest, .quick_ask, .new_thread, .digup };
    try t.expectEqual(kinds.len, r.n);
    for (kinds, r.slice()) |kind, row| try t.expectEqual(kind, row.kind);
    try t.expectEqualStrings("Ask & Search", r.section(2).?);
    try t.expect(r.section(3) == null and r.section(4) == null);
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("http://127.0.0.1:47213/ask?q=liquid+glass+%26+UI", url(&buf, .quick_ask, " liquid glass & UI "));
    try t.expectEqualStrings("quickask://t3-thread-create?q=liquid+glass+%26+UI", url(&buf, .new_thread, " liquid glass & UI "));
    try t.expectEqualStrings("http://127.0.0.1:47213/digup?q=liquid+glass+%26+UI", url(&buf, .digup, " liquid glass & UI "));
    try t.expectEqualStrings("quickask://answer?q=liquid+glass+%26+UI", answerUrl(&buf, " liquid glass & UI "));
    try t.expectEqualStrings("Ask", Kind.quick_ask.action());
    try t.expectEqualStrings("Start T3 Thread", Kind.new_thread.action());
    try t.expectEqualStrings("Search DigUp", Kind.digup.action());
}

test "Ask, T3 and DigUp are always ⌘1, ⌘2, ⌘3; the rest count on from ⌘4" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build("saf", &ix, &.{}, &.{"safari download"}, &.{});
    // Safari, Google, a completion, then the three handoffs.
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(?u8, 4), r.number(0));
    try t.expectEqual(@as(?u8, 5), r.number(1));
    try t.expectEqual(@as(?u8, 6), r.number(2));
    try t.expectEqual(Kind.quick_ask, r.rows[r.rowFor(1).?].kind);
    try t.expectEqual(Kind.new_thread, r.rows[r.rowFor(2).?].kind);
    try t.expectEqual(Kind.digup, r.rows[r.rowFor(3).?].kind);
    try t.expectEqual(@as(?usize, 0), r.rowFor(4));
    try t.expectEqual(@as(?usize, null), r.rowFor(9));
    // No handoffs (math, an empty query): plain ⌘1 to ⌘9.
    r.build("2+2", &ix, &.{}, &.{}, &.{});
    try t.expectEqual(@as(?u8, 1), r.number(0));
    r.build("", &ix, &.{ 2, 0 }, &.{}, &.{});
    try t.expectEqual(@as(?usize, 1), r.rowFor(2));
}

test "2FA codes appear only for a leading code request, with the fixed handoff keys" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Code", "Codec", "Code Editor", "Code Runner", "Code Studio", "Codes" });
    defer ix.deinit();
    var r: Results = .{};
    for ([_][]const u8{ "2fa", "OTP", "code", "codes", "Verification", "verify", " 2FA code ", "codes for Google", "verify: login" }) |q| {
        r.build(q, &ix, &.{}, &.{ "code one", "code two", "code three", "code four" }, &.{});
        var count: usize = 0;
        for (r.slice(), 0..) |row, i| if (row.kind == .codes) {
            count += 1;
            try t.expectEqualStrings("Ask & Search", r.section(i).?);
            if (r.number(i)) |d| try t.expectEqual(@as(?usize, i), r.rowFor(d));
        };
        try t.expectEqual(@as(usize, 1), count);
        try t.expect(r.n <= max_rows);
        try t.expectEqual(Kind.quick_ask, r.rows[r.rowFor(1).?].kind);
        try t.expectEqual(Kind.new_thread, r.rows[r.rowFor(2).?].kind);
        try t.expectEqual(Kind.digup, r.rows[r.rowFor(3).?].kind);
    }
    for ([_][]const u8{ "", "codec", "coding", "decode", "verificationary", "find code", "my otp", "safari" }) |q| {
        r.build(q, &ix, &.{}, &.{}, &.{});
        for (r.slice()) |row| try t.expect(row.kind != .codes);
    }
    r.build("otp", &ix, &.{}, &.{}, &.{});
    try t.expectEqual(Kind.codes, r.rows[r.rowFor(5).?].kind);
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("http://127.0.0.1:47213/codes", url(&buf, .codes, "2fa code"));
    try t.expectEqualStrings("Find 2FA codes", Kind.codes.action());
}
