//! Nanolight's parts, and its panel driven through a Tester: keys in,
//! rows and the clipboard out. Nothing is opened; no window shows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");

test {
    _ = @import("search.zig");
    _ = @import("calc.zig");
    _ = @import("results.zig");
    _ = @import("suggest.zig");
    _ = @import("promo_camera.zig");
    _ = @import("single.zig");
    _ = @import("clickthrough.zig");
    _ = @import("settings.zig");
    _ = @import("apps.zig");
    _ = @import("hotkey.zig");
    _ = @import("shortcut.zig");
    _ = @import("recorder.zig");
}

const Probe = struct {
    opened: [256]u8 = undefined,
    opened_len: usize = 0,
    hidden: bool = false,

    fn open(ctx: *anyopaque, target: []const u8) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        @memcpy(p.opened[0..target.len], target);
        p.opened_len = target.len;
    }
    fn hide(ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.hidden = true;
    }
};

fn press(t: *ui.Tester, ops: []const ui.TextOp) void {
    t.textOps(ops);
    t.settle(1);
}

test "the panel finds, moves, answers and hands off" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    for ([_][]const u8{ "Safari", "System Settings", "Notes", "Calculator", "Finder" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var probe: Probe = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = .{ .ctx = &probe, .open = Probe.open, .hide = Probe.hide };
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = 480, .dark = true });
    defer t.deinit();
    t.settle(1);
    // No query: suggestions.
    try std.testing.expect(t.hasText("Suggestions"));
    try std.testing.expect(t.hasText("Safari"));
    // After an automatic update, the footer says so in place of the name.
    try std.testing.expect(t.hasText("Nanolight · 5 apps"));
    s.note = "Updated to 0.1.3";
    t.settle(1);
    try std.testing.expect(t.hasText("Updated to 0.1.3 · 5 apps"));
    s.note = "";

    // The top app's name completes what is typed; → takes it.
    press(&t, &.{.{ .insert = "saf" }});
    try std.testing.expect(t.hasText("ari"));
    press(&t, &.{.{ .command = .move_right }});
    try std.testing.expectEqualStrings("safari", s.query.text());
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward } });

    press(&t, &.{.{ .insert = "ss" }});
    try std.testing.expect(t.hasText("System Settings"));
    try std.testing.expectEqual(@as(u32, ix.find("System Settings").?), s.res.rows[0].app);
    // Down and back up, then Return opens the first.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try std.testing.expectEqual(@as(usize, 1), s.sel);
    _ = t.shortcut(.{ .key = ui.Shortcut.up });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("/Applications/System Settings.app", probe.opened[0..probe.opened_len]);
    try std.testing.expect(probe.hidden);
    try std.testing.expectEqual(@as(u16, 1), ix.launches.items[ix.find("System Settings").?]);

    // ⌘2 opens the second row at once: Safari, under System Settings,
    // which was just opened.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "s" } });
    try std.testing.expect(t.hasText("⌘2"));
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    try std.testing.expectEqualStrings("/Applications/Safari.app", probe.opened[0..probe.opened_len]);

    // Math: answered, and Return copies it.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "2^10 * 3" } });
    try std.testing.expect(t.hasText("3,072"));
    try std.testing.expect(t.hasText("Result · 0xC00"));
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("3072", t.clipboard.items);

    // Anything else: Google, Grok, X.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "liquid glass" } });
    try std.testing.expect(t.containsText("Search X for"));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://x.com/search?f=live&q=liquid+glass", probe.opened[0..probe.opened_len]);

    // Escape clears the query, then closes.
    probe.hidden = false;
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expectEqualStrings("", s.query.text());
    try std.testing.expect(!probe.hidden);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(probe.hidden);
}

const suggest = @import("suggest.zig");
const results = @import("results.zig");

/// A host that answers for Google and shows pages: what was asked, shown.
const Web = struct {
    probe: Probe = .{},
    asked: [64]u8 = undefined,
    asked_len: usize = 0,
    page: [256]u8 = undefined,
    page_len: ?usize = null,

    fn host(w: *Web) view.Host {
        return .{ .ctx = w, .open = open, .hide = hide, .suggest = ask, .preview = show };
    }
    fn open(ctx: *anyopaque, target: []const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        Probe.open(&w.probe, target);
    }
    fn hide(ctx: *anyopaque) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        Probe.hide(&w.probe);
    }
    fn ask(ctx: *anyopaque, q: []const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        @memcpy(w.asked[0..q.len], q);
        w.asked_len = q.len;
    }
    fn show(ctx: *anyopaque, url: ?[]const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        const u = url orelse {
            w.page_len = null;
            return;
        };
        @memcpy(w.page[0..u.len], u);
        w.page_len = u.len;
    }
};

test "Google's completions land below, and a search shows in the panel" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var web: Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    // An address is never asked about; words are.
    press(&t, &.{.{ .insert = "ziglang.org" }});
    try std.testing.expectEqual(@as(usize, 0), web.asked_len);
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "liquid gl" } });
    try std.testing.expectEqualStrings("liquid gl", web.asked[0..web.asked_len]);
    // Return would search what was typed. The selection, moved before
    // the answer comes, stays on its row, though the completions land
    // above it, a key under the search.
    try std.testing.expectEqual(results.Kind.search_web, s.res.rows[s.sel].kind);
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expectEqual(results.Kind.search_x, s.res.rows[s.sel].kind);
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid glass", "liquid glass apple" }) |w| said.push(w);
    s.answered("liquid gl", &said);
    t.settle(1);
    try std.testing.expect(t.hasText("Google"));
    try std.testing.expect(t.hasText("liquid glass apple"));
    try std.testing.expectEqual(results.Kind.suggest, s.res.rows[1].kind);
    try std.testing.expectEqual(results.Kind.search_x, s.res.rows[s.sel].kind);
    // The first completion shows faintly in the field; Tab takes it.
    try std.testing.expect(t.hasText("ass"));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab }));
    t.settle(1);
    try std.testing.expectEqualStrings("liquid glass", s.query.text());
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "liquid gl" } });
    // Known at once this time, yet Return still searches what was typed,
    // not a completion nobody picked.
    try std.testing.expectEqual(results.Kind.suggest, s.res.rows[1].kind);
    try std.testing.expectEqual(results.Kind.search_web, s.res.rows[s.sel].kind);
    // ⌘2 is Google's first completion.
    try std.testing.expect(t.hasText("⌘2"));
    // One more letter: the answer so far stands in, and nothing is asked
    // again for words already answered.
    web.asked_len = 0;
    press(&t, &.{.{ .insert = "a" }});
    try std.testing.expectEqualStrings("liquid gla", web.asked[0..web.asked_len]);
    try std.testing.expect(t.hasText("liquid glass apple"));
    web.asked_len = 0;
    press(&t, &.{.{ .command = .delete_backward }});
    try std.testing.expectEqual(@as(usize, 0), web.asked_len);

    // ⌘3, the second completion: its words in the field, Google's page in the panel.
    try std.testing.expect(t.shortcut(.{ .key = '3', .cmd = true }));
    t.settle(1);
    try std.testing.expectEqualStrings("liquid glass apple", s.query.text());
    try std.testing.expectEqualStrings("https://www.google.com/search?q=liquid+glass+apple", web.page[0..web.page_len.?]);
    t.settle(2);
    try std.testing.expect(t.hasText("Open in Browser"));
    try std.testing.expectEqual(view.max_height, s.height());
    try std.testing.expect(!web.probe.hidden);
    // Escape: the rows again, the page gone.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(web.page_len == null);
    try std.testing.expectEqualStrings("liquid glass apple", s.query.text());

    // Return on words no app matches: Google's page; typing takes it away.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "pizza" } });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizza", web.page[0..web.page_len.?]);
    press(&t, &.{.{ .insert = "s" }});
    try std.testing.expect(web.page_len == null);
    try std.testing.expect(t.hasText("Search Google for “pizzas”"));

    // ⌘↩ in the page, and on the row: the browser, and the panel hides.
    while (s.res.rows[s.sel].kind != .search_web) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expect(web.page_len != null);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizzas", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden);
    s.reveal();
    try std.testing.expect(web.page_len == null);
    web.probe = .{};
    t.settle(1);
    while (s.res.rows[s.sel].kind != .search_web) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizzas", web.probe.opened[0..web.probe.opened_len]);
}

const onboard = @import("onboard.zig");
const shortcut = @import("shortcut.zig");

const Steps = struct {
    applied: ?shortcut.Choice = null,
    done: bool = false,
    fn apply(ctx: *anyopaque, c: shortcut.Choice) void {
        const p: *Steps = @ptrCast(@alignCast(ctx));
        p.applied = c;
    }
    fn fix(_: *anyopaque, _: shortcut.Clash) void {}
    fn finished(ctx: *anyopaque) void {
        const p: *Steps = @ptrCast(@alignCast(ctx));
        p.done = true;
    }
};

test "the welcome: a key, pressed for real, then a first search" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var o: onboard.Onboard = .{};
    // Hooks only once started: the system's shortcuts are not read in tests.
    o.start(.cmd_space);
    const sys = [_]shortcut.SystemKey{.{ .id = 64, .enabled = true, .key = 49, .mods = 1 << 20 }};
    o.system = &sys;
    var steps: Steps = .{};
    o.hooks = .{ .ctx = &steps, .apply = Steps.apply, .fix = Steps.fix, .done = Steps.finished };
    var s: view.Nanolight = .{ .index = &ix, .onboard = &o };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = 480, .dark = true });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Welcome to Nanolight"));
    // Who holds ⌘Space, by name; going on anyway is said as such.
    try std.testing.expect(t.hasText("macOS gives ⌘ Space to Spotlight first."));
    try std.testing.expect(t.hasText("Use ⌘ Space anyway"));
    t.key(.right);
    try std.testing.expect(t.hasText("⌥ Space is free on this Mac."));
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqual(shortcut.Choice.opt_space, steps.applied.?);
    try std.testing.expect(t.hasText("Press ⌥ Space now"));
    // A button never moves it on: the key closing the panel, then opening it.
    o.pressed(false);
    t.settle(1);
    try std.testing.expectEqual(onboard.Step.try_it, o.step);
    o.pressed(true);
    o.pressed(false);
    t.settle(2);
    try std.testing.expect(t.hasText("You're set."));
    // ⌘2: the math example, run in the launcher.
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(1);
    try std.testing.expect(steps.done and !o.active);
    try std.testing.expect(t.hasText("3,072"));

    // Esc skips from the first step, keeping the key shown there.
    steps = .{};
    o.start(.ctrl_space);
    t.settle(1);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(steps.done and !o.active);
    try std.testing.expectEqual(shortcut.Choice.ctrl_space, steps.applied.?);
}

const SettingsHost = @import("settings_host.zig").SettingsHost;

/// A host that records what Settings asked it to do.
const Prefs = struct {
    probe: Probe = .{},
    key: shortcut.Choice = .cmd_space,
    applied: ?shortcut.Choice = null,
    recording: bool = false,
    login_on: bool = false,
    suggest_sets: u8 = 0,
    box: SettingsHost = undefined,

    fn init(p: *Prefs) void {
        p.box = .{
            .ctx = p,
            .choice = choice,
            .apply = apply,
            .record = record,
            .login = login,
            .suggest = suggestSet,
            .account = acct,
            .email = email,
            .sign_in = noop,
            .sign_out = noop,
            .terms = noop,
            .version = ver,
            .ready = ready,
            .check = noop,
            .restart = noop,
            .welcome = noop,
            .quit = noop,
        };
    }
    fn host(p: *Prefs) view.Host {
        return .{ .ctx = p, .open = open, .hide = hide, .settings = &p.box };
    }
    fn open(ctx: *anyopaque, target: []const u8) void {
        Probe.open(&@as(*Prefs, @ptrCast(@alignCast(ctx))).probe, target);
    }
    fn hide(ctx: *anyopaque) void {
        Probe.hide(&@as(*Prefs, @ptrCast(@alignCast(ctx))).probe);
    }
    fn choice(ctx: *anyopaque) shortcut.Choice {
        return @as(*Prefs, @ptrCast(@alignCast(ctx))).key;
    }
    fn apply(ctx: *anyopaque, c: shortcut.Choice) void {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.applied = c;
        p.key = c;
    }
    fn record(ctx: *anyopaque, on: bool) void {
        @as(*Prefs, @ptrCast(@alignCast(ctx))).recording = on;
    }
    fn login(ctx: *anyopaque, set: ?bool) bool {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        if (set) |on| p.login_on = on;
        return p.login_on;
    }
    fn suggestSet(ctx: *anyopaque, _: bool) void {
        @as(*Prefs, @ptrCast(@alignCast(ctx))).suggest_sets += 1;
    }
    fn acct(_: *anyopaque) @import("account.zig").State {
        return .signed_out;
    }
    fn email(_: *anyopaque) []const u8 {
        return "";
    }
    fn ver(_: *anyopaque) []const u8 {
        return "0.1.0";
    }
    fn ready(_: *anyopaque) ?[]const u8 {
        return null;
    }
    fn noop(_: *anyopaque) void {}
};

test "settings opens from ⌘,, from typing, and from the gear" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var prefs: Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    // The gear is in the footer, named.
    try std.testing.expect(t.hasText("Settings"));
    try t.clickText("Settings");
    t.settle(1);
    try std.testing.expect(s.settings_ui.open);
    try std.testing.expect(t.hasText("Open Nanolight with"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!s.settings_ui.open);

    // ⌘, opens it; Esc goes back to search.
    try std.testing.expect(t.shortcut(.{ .key = ',', .cmd = true }));
    t.settle(1);
    try std.testing.expect(s.settings_ui.open);
    try std.testing.expect(t.hasText("Google Suggestions"));
    try std.testing.expect(t.hasText("Open at Login"));
    try std.testing.expect(t.hasText("Sign In with Codegraff"));
    try std.testing.expect(t.hasText("Terms & Privacy"));
    try std.testing.expect(t.hasText("Check for Updates"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try std.testing.expect(!s.settings_ui.open);
    try std.testing.expect(t.hasText("Safari"));

    // Typing "settings" lists the row; Return opens it.
    press(&t, &.{.{ .insert = "settings" }});
    try std.testing.expect(t.hasText("Nanolight Settings"));
    try std.testing.expectEqual(results.Kind.settings, s.res.rows[0].kind);
    press(&t, &.{.{ .command = .insert_newline }});
    t.settle(1);
    try std.testing.expect(s.settings_ui.open);

    // → picks the next shortcut and tells the host.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
    try std.testing.expectEqual(shortcut.Choice.opt_space, prefs.applied.?);

    // Return on it records a key of one's own (issue #1): a letter alone
    // is refused, ⌥X is taken, kept, and shown as the chosen one.
    press(&t, &.{.{ .command = .insert_newline }});
    t.settle(1);
    try std.testing.expect(prefs.recording and t.hasText("Type a shortcut"));
    s.settings_ui.took(&s, shortcut.recorded(7, 0, 'x'));
    t.settle(1);
    try std.testing.expect(prefs.recording and t.hasText("Add ⌘, ⌥ or ⌃"));
    s.settings_ui.took(&s, shortcut.recorded(7, 1 << 19, 'x'));
    t.settle(1);
    try std.testing.expect(!prefs.recording and t.hasText("⌥ X"));
    try std.testing.expect(prefs.applied.?.eql(.{ .code = 7, .mods = 1 << 11 }));
    // ← goes back to the four.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.left }));
    try std.testing.expect(prefs.applied.?.eql(.opt_cmd_space));
    try std.testing.expect(t.hasText("⌥ X"));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
    try std.testing.expectEqual(shortcut.Choice.opt_space, prefs.applied.?);

    // ↓ onto Google Suggestions, Return flips it.
    try std.testing.expect(s.suggest_on);
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqual(@as(usize, 1), s.settings_ui.sel);
    try std.testing.expectEqual(true, s.settings_ui.open);
    try std.testing.expectEqual(@as(u8, 1), prefs.suggest_sets);
    try std.testing.expect(!s.suggest_on);
    try std.testing.expectEqual(@as(u8, 1), prefs.suggest_sets);
    try std.testing.expect(s.height() <= view.max_height);
}

test "the panel never outgrows its window, which is never resized" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    for ([_][]const u8{ "Safari", "Mail", "Maps", "Music", "Notes", "Numbers", "Pages", "Photos", "Calendar", "Calculator" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var tallest: f32 = 0;
    for ([_][]const u8{ "", "a", "s", "ma", "2^10 * 3", "1+a", "liquid glass" }) |q| {
        s.query.set(q);
        s.rebuild();
        tallest = @max(tallest, s.height());
    }
    try std.testing.expect(tallest <= view.max_height);
    // "a" fills every app row there is, and Google's completions the
    // rest: the bound is the real one.
    s.query.set("a");
    s.rebuild();
    var four: @import("suggest.zig").List = .{};
    for ([_][]const u8{ "a1", "a2", "a3", "a4" }) |w| four.push(w);
    s.answered("a", &four);
    try std.testing.expectEqual(view.max_height, s.height());
    var o: onboard.Onboard = .{};
    for ([_]onboard.Step{ .key, .try_it, .done }) |step| {
        o.step = step;
        try std.testing.expect(o.height() <= view.max_height);
    }
}
