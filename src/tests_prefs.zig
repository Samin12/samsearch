//! Issues #8, #9 and #10 through the Tester: the panel's first frame on
//! the Mac, searches sent to the browser, and the two Settings rows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const settings_view = @import("settings_view.zig");
const tests = @import("tests.zig");
const mac = @import("builtin").os.tag == .macos;
const placeholder = "Search apps, do math, ask anything…";

/// Where the field's placeholder is in the first frame after the panel
/// shows, and once it has settled.
fn firstAndSettled(fades: bool) ![2]ui.Rect {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix, .window_fades = fades, .margin = view.shadow_margin };
    defer s.query.deinit();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width + 2 * view.shadow_margin, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.frame();
    const first = t.findText(placeholder) orelse return error.NoField;
    t.settle(1);
    return .{ first, t.findText(placeholder) orelse return error.NoField };
}

test "on the Mac the panel's first frame is where it settles (issue #9)" {
    // The window fades in, the system's glass with it: the panel drawn
    // over that glass comes in at once, not from above and transparent.
    const r = try firstAndSettled(true);
    try std.testing.expectEqual(r[1].y, r[0].y);
    try std.testing.expectEqual(r[1].x, r[0].x);
    // Over its own glass (the film, the promo) it still comes in: this is
    // what the Mac's panel did over a glass that didn't.
    const own = try firstAndSettled(false);
    try std.testing.expect(own[0].y < own[1].y);
}

fn findRow(t: *ui.Tester, s: *view.Nanolight, words: []const u8) void {
    tests.press(t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = words } });
    while (s.res.rows[s.sel].kind != .search_web) _ = t.shortcut(.{ .key = ui.Shortcut.down });
}

test "searches can open in the browser, ⌘↩ showing them in the panel (issue #10)" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix, .searches_out = true };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    // Return: the browser, and the panel goes.
    findRow(&t, &s, "pizza");
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizza", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden and web.page_len == null and !s.previewing);
    // ⌘↩: the page in the panel, which stays.
    web.probe = .{};
    s.reveal();
    t.settle(1);
    findRow(&t, &s, "pasta");
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pasta", web.page[0..web.page_len.?]);
    try std.testing.expect(!web.probe.hidden and web.probe.opened_len == 0 and s.previewing);
}

test "Settings hides the menu bar icon and sends searches out (issues #8, #10)" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try t.clickText("Show in Menu Bar");
    t.settle(1);
    try std.testing.expect(!prefs.menu_bar_on);
    try t.clickText("Open Searches in Browser");
    t.settle(1);
    try std.testing.expect(s.searches_out and prefs.searches_out.?);
    // Twice more each: back as they were.
    try t.clickText("Show in Menu Bar");
    try t.clickText("Open Searches in Browser");
    t.settle(1);
    try std.testing.expect(prefs.menu_bar_on and !s.searches_out and !prefs.searches_out.?);
    // The rows fit: the last one is inside Settings, Settings in the window.
    const quit = t.findText("Quit SamSearch").?;
    try std.testing.expect(quit.y + quit.h <= settings_view.height);
    try std.testing.expect(settings_view.height <= view.max_height);
}

test "System Settings' panes open from the panel, which stays in its window (#12)" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("System Settings", "/System/Applications/System Settings.app");
    for ([_][]const u8{ "Sound A", "Sound B", "Sound C", "Sound D", "Sound E", "Sound F" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    tests.press(&t, &.{.{ .insert = "login items" }});
    try std.testing.expect(t.hasText("Login Items & Extensions"));
    try std.testing.expect(t.hasText("Open in System Settings"));
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden);
    // Every app row, a pane, and Google's completions: the tallest list
    // with four sections still fits.
    s.reveal();
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "sound" } });
    var four: @import("suggest.zig").List = .{};
    for ([_][]const u8{ "sound 1", "sound 2", "sound 3", "sound 4" }) |w| four.push(w);
    s.answered("sound", &four);
    t.settle(1);
    try std.testing.expect(t.hasText("System Settings"));
    try std.testing.expect(s.height() <= view.max_height);
}

test "SamSearch handoffs use local previews and page-specific command Return" {
    const gpa = std.testing.allocator;
    // Google's browser preference must never redirect a local helper page.
    for ([_]bool{ false, true }) |searches_out| {
        var ix: Index = .init(gpa);
        defer ix.deinit();
        var web: tests.Web = .{};
        var s: view.Nanolight = .{ .index = &ix, .searches_out = searches_out };
        defer s.query.deinit();
        s.host = web.host();
        s.reveal();
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
        defer t.deinit();
        t.settle(1);
        tests.press(&t, &.{.{ .insert = "liquid glass & UI" }});
        try std.testing.expect(t.hasText("Ask “liquid glass & UI”"));
        try std.testing.expect(t.hasText("Haiku · sees your screen"));
        try std.testing.expect(t.hasText("New T3 thread: “liquid glass & UI”"));
        try std.testing.expect(t.hasText("T3 Code · default settings"));
        try std.testing.expect(t.hasText("Search DigUp for “liquid glass & UI”"));
        try std.testing.expect(t.hasText("Files, screenshots, email and Drive"));
        // ⌘1 is always Quick Ask, using the same activation as Return.
        try std.testing.expect(t.shortcut(.{ .key = '1', .cmd = true }));
        t.settle(1);
        try std.testing.expectEqualStrings("http://127.0.0.1:47213/ask?q=liquid+glass+%26+UI", web.page[0..web.page_len.?]);
        try std.testing.expect(s.previewing and !web.probe.hidden);
        try std.testing.expect(t.hasText("Open Answer Window"));
        // The WKWebView callback must also ignore any navigated URL.
        s.openPreviewOut("http://127.0.0.1:47213/anything-else");
        try std.testing.expectEqualStrings("quickask://answer?q=liquid+glass+%26+UI", web.probe.opened[0..web.probe.opened_len]);
        try std.testing.expect(web.probe.hidden);
        s.reveal();
        web.probe = .{};
        t.settle(1);
        // Direct ⌘↩ on Quick Ask opens the floating window.
        s.sel = 1;
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
        try std.testing.expectEqualStrings("quickask://answer?q=liquid+glass+%26+UI", web.probe.opened[0..web.probe.opened_len]);
        try std.testing.expect(web.probe.hidden and !s.previewing);
        s.reveal();
        web.probe = .{};
        t.settle(1);
        s.sel = 1;
        tests.press(&t, &.{.{ .command = .insert_newline }});
        try std.testing.expect(s.previewing and !web.probe.hidden);
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
        try std.testing.expectEqualStrings("quickask://answer?q=liquid+glass+%26+UI", web.probe.opened[0..web.probe.opened_len]);
        s.reveal();
        web.probe = .{};
        t.settle(1);
        // ⌘2 is always the T3 thread; Return and ⌘↩ use the same deep link.
        try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
        try std.testing.expectEqualStrings("quickask://t3-thread-create?q=liquid+glass+%26+UI", web.probe.opened[0..web.probe.opened_len]);
        try std.testing.expect(web.probe.hidden and !s.previewing);
        for ([_]bool{ false, true }) |command| {
            s.reveal();
            web.probe = .{};
            t.settle(1);
            s.sel = 2;
            if (command) {
                try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
            } else tests.press(&t, &.{.{ .command = .insert_newline }});
            try std.testing.expectEqualStrings("quickask://t3-thread-create?q=liquid+glass+%26+UI", web.probe.opened[0..web.probe.opened_len]);
            try std.testing.expect(web.probe.hidden and !s.previewing);
        }
        s.reveal();
        web.probe = .{};
        t.settle(1);
        // ⌘3 is always DigUp, in the panel. ⌘↩ while previewing is a no-op.
        try std.testing.expect(t.shortcut(.{ .key = '3', .cmd = true }));
        t.settle(1);
        try std.testing.expectEqualStrings("http://127.0.0.1:47213/digup?q=liquid+glass+%26+UI", web.page[0..web.page_len.?]);
        try std.testing.expect(!t.hasText("Open in Browser"));
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
        s.openPreviewOut("https://www.google.com/");
        try std.testing.expect(s.previewing and !web.probe.hidden and web.probe.opened_len == 0);
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
        try std.testing.expect(!s.previewing and web.page_len == null);
        // ⌘↩ on the DigUp row uses the same local preview as Return.
        s.sel = 3;
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
        try std.testing.expectEqualStrings("http://127.0.0.1:47213/digup?q=liquid+glass+%26+UI", web.page[0..web.page_len.?]);
        tests.press(&t, &.{.{ .insert = " ideas" }});
        try std.testing.expect(!s.previewing and web.page_len == null);
    }
}

const StatefulPrefs = struct {
    prefs: tests.Prefs = .{},
    state: @import("account.zig").State = .signed_out,
    quits: usize = 0,
    welcomes: usize = 0,
    cancels: usize = 0,
    login_reads: usize = 0,
    login_opens: usize = 0,
    digup_requests: usize = 0,
    files_requests: usize = 0,
    google_requests: usize = 0,
    login_state: @import("settings_host.zig").LoginState = .off,

    fn init(p: *StatefulPrefs) void {
        p.prefs.init();
        p.prefs.box.account = acct;
        p.prefs.box.quit = quit;
        p.prefs.box.welcome = welcome;
        p.prefs.box.sign_out = cancel;
        p.prefs.box.login_status = login;
        p.prefs.box.login_settings = openLogin;
    }
    fn from(ctx: *anyopaque) *StatefulPrefs {
        const prefs: *tests.Prefs = @ptrCast(@alignCast(ctx));
        return @fieldParentPtr("prefs", prefs);
    }
    fn acct(ctx: *anyopaque) @import("account.zig").State {
        return from(ctx).state;
    }
    fn quit(ctx: *anyopaque) void {
        from(ctx).quits += 1;
    }
    fn welcome(ctx: *anyopaque) void {
        from(ctx).welcomes += 1;
    }
    fn cancel(ctx: *anyopaque) void {
        from(ctx).cancels += 1;
    }
    fn login(ctx: *anyopaque, set: ?bool) @import("settings_host.zig").LoginState {
        const p = from(ctx);
        p.login_reads += 1;
        if (set) |on| p.login_state = if (on) .on else .off;
        return p.login_state;
    }
    fn openLogin(ctx: *anyopaque) void {
        from(ctx).login_opens += 1;
    }
    fn askDigup(ctx: *anyopaque, _: []const u8) void {
        from(ctx).digup_requests += 1;
    }
    fn askFiles(ctx: *anyopaque, _: []const u8) void {
        from(ctx).files_requests += 1;
    }
    fn askGoogle(ctx: *anyopaque, _: []const u8) void {
        from(ctx).google_requests += 1;
    }
    fn reject(_: *anyopaque, _: @import("shortcut.zig").Choice) anyerror!void {
        return error.ShortcutTaken;
    }
};

test "every recording exit clears the fake monitor and refused state" {
    if (!mac) return error.SkipZigTest;
    const Exit = enum { close, show, focus_lost, escape, taken, welcome, quit };
    for (std.enums.values(Exit)) |exit| {
        var ix: Index = .init(std.testing.allocator);
        defer ix.deinit();
        var prefs: StatefulPrefs = .{};
        prefs.init();
        var s: view.Nanolight = .{ .index = &ix };
        defer s.query.deinit();
        s.host = prefs.prefs.host();
        s.openSettings();
        s.settings_ui.activateSelected(&s);
        try std.testing.expect(prefs.prefs.recording);
        s.settings_ui.took(&s, .unusable);
        try std.testing.expectEqual(.refused, s.settings_ui.recording);
        switch (exit) {
            .close => s.settings_ui.hide(),
            .show => s.settings_ui.show(),
            .focus_lost => s.settings_ui.finishRecording(),
            .escape => s.settings_ui.took(&s, .cancel),
            .taken => s.settings_ui.took(&s, .{ .key = .opt_space }),
            .welcome, .quit => {
                s.settings_ui.sel = @backingInt(if (exit == .welcome) settings_view.RowKind.welcome else settings_view.RowKind.quit);
                s.settings_ui.activateSelected(&s);
            },
        }
        try std.testing.expect(!prefs.prefs.recording);
        try std.testing.expectEqual(.idle, s.settings_ui.recording);
        if (exit == .welcome) try std.testing.expectEqual(@as(usize, 1), prefs.welcomes);
        if (exit == .quit) try std.testing.expectEqual(@as(usize, 1), prefs.quits);
    }
}

test "Settings selection follows row kind across account row changes" {
    var ix: Index = .init(std.testing.allocator);
    defer ix.deinit();
    var prefs: StatefulPrefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.prefs.host();
    s.openSettings();
    // An async sign-in removes Terms: Updates stays Updates on Return.
    s.settings_ui.sel = @backingInt(settings_view.RowKind.updates);
    prefs.state = .signed_in;
    s.settings_ui.activateSelected(&s);
    try std.testing.expectEqual(settings_view.RowKind.updates, s.settings_ui.selected());
    try std.testing.expectEqual(@as(usize, 0), prefs.quits + prefs.welcomes);
    prefs.state = .signed_out;
    s.settings_ui.activateSelected(&s);
    try std.testing.expectEqual(settings_view.RowKind.updates, s.settings_ui.selected());
    // If Terms itself vanishes, selection falls back to the account.
    s.settings_ui.sel = @backingInt(settings_view.RowKind.terms);
    prefs.state = .starting;
    prefs.state = .waiting;
    s.settings_ui.activateSelected(&s);
    try std.testing.expectEqual(settings_view.RowKind.sync, s.settings_ui.selected());
    try std.testing.expectEqual(@as(usize, 1), prefs.cancels);
    try std.testing.expectEqual(@as(usize, 0), prefs.quits + prefs.welcomes);
    prefs.state = .starting;
    s.settings_ui.activateSelected(&s);
    try std.testing.expectEqual(@as(usize, 2), prefs.cancels);
}

test "shortcut registration failure stays on the previous choice and is shown" {
    if (!mac) return error.SkipZigTest;
    var ix: Index = .init(std.testing.allocator);
    defer ix.deinit();
    var prefs: StatefulPrefs = .{};
    prefs.init();
    prefs.prefs.box.try_apply = StatefulPrefs.reject;
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.prefs.host();
    s.openSettings();
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    _ = tester.shortcut(.{ .key = ui.Shortcut.right });
    tester.settle(1);
    try std.testing.expect(s.settings_ui.choice.eql(.cmd_space));
    try std.testing.expect(s.settings_ui.failed_choice.?.eql(.opt_space));
    try std.testing.expect(tester.hasText("Couldn't use ⌥Space: another app has it"));
}

test "login approval is visible and login status is cached until Settings shows again" {
    var ix: Index = .init(std.testing.allocator);
    defer ix.deinit();
    var prefs: StatefulPrefs = .{};
    prefs.init();
    prefs.login_state = .requires_approval;
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.prefs.host();
    s.openSettings();
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    try std.testing.expect(tester.hasText("Needs approval in System Settings"));
    tester.frame();
    tester.frame();
    try std.testing.expectEqual(@as(usize, 1), prefs.login_reads);
    s.settings_ui.sel = @backingInt(settings_view.RowKind.login);
    s.settings_ui.activateSelected(&s);
    try std.testing.expectEqual(@as(usize, 1), prefs.login_opens);
    try std.testing.expectEqual(@as(usize, 1), prefs.login_reads);
    s.settings_ui.hide();
    s.openSettings();
    tester.settle(1);
    try std.testing.expectEqual(@as(usize, 2), prefs.login_reads);
}

test "Settings source toggles immediately invalidate results and request each source once" {
    // The DigUp and Files rows are the Mac's.
    if (!mac) return error.SkipZigTest;
    var ix: Index = .init(std.testing.allocator);
    defer ix.deinit();
    var prefs: StatefulPrefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.dug.deinit();
    defer s.found.deinit();
    var host = prefs.prefs.host();
    host.digup = StatefulPrefs.askDigup;
    host.files = StatefulPrefs.askFiles;
    host.suggest = StatefulPrefs.askGoogle;
    s.host = host;
    s.query.set("report");
    s.rebuild();
    s.openSettings();
    for ([_]settings_view.RowKind{ .digup, .files, .suggest }) |kind| {
        const generation = s.pipeline.generation;
        prefs.digup_requests = 0;
        prefs.files_requests = 0;
        prefs.google_requests = 0;
        s.settings_ui.sel = @backingInt(kind);
        s.settings_ui.activateSelected(&s);
        try std.testing.expect(s.pipeline.generation != generation);
        try std.testing.expectEqual(@as(usize, 1), prefs.digup_requests);
        try std.testing.expect(prefs.files_requests <= 1 and prefs.google_requests <= 1);
        // A second frame/rebuild cannot issue another copy of a request.
        s.rebuild();
        try std.testing.expectEqual(@as(usize, 1), prefs.digup_requests);
        try std.testing.expect(prefs.files_requests <= 1 and prefs.google_requests <= 1);
    }
}
