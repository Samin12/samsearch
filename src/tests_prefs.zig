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
const placeholder = "Search apps, do math, ask Grok…";

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
    const quit = t.findText("Quit Nanolight").?;
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
