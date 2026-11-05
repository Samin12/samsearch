//! A command's screen in the panel (raycast_view.zig), driven through a
//! Tester: a script's output, a list's rows and actions, a form. No
//! process runs; what a host would say is handed to the screen directly.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const model = @import("raycast_model.zig");
const Ext = @import("raycast_view.zig").Ext;

const Heard = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn said(ctx: *anyopaque, line: []const u8) void {
        const h: *Heard = @ptrCast(@alignCast(ctx));
        const n = @min(line.len, h.buf.len - h.len);
        @memcpy(h.buf[h.len..][0..n], line[0..n]);
        h.len += n;
    }

    fn text(h: *const Heard) []const u8 {
        return h.buf[0..h.len];
    }
};

fn noop(_: *anyopaque) void {}
fn noopOpen(_: *anyopaque, _: []const u8) void {}

test "a script's output shows every line, and Escape gives the search its keys back" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var probe: u8 = 0;
    s.host = .{ .ctx = &probe, .open = noopOpen, .hide = noop };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    s.reveal();
    var heard: Heard = .{};
    ext.start("System Info", null, .{ .ctx = &heard, .func = Heard.said });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    // As a script prints: its first line, then the rest.
    for ([_][]const u8{ "", "Linux 6.17 on x86_64\n", "Linux 6.17 on x86_64\nUp: 3 min\n\nFilesystem Size Used\n/dev/vda1 10G 2G" }) |sofar| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const out = try arena.allocator().dupe(u8, sofar);
        ext.show(arena, .{ .kind = "detail", .title = "System Info", .output = out, .loading = sofar.len < 40 });
        t.settle(0.2);
    }
    t.settle(1);
    if (std.c.getenv("NANOLIGHT_SHOT")) |p| try t.screenshot(std.mem.span(p));
    try std.testing.expect(t.hasText("Linux 6.17 on x86_64"));
    try std.testing.expect(t.hasText("Up: 3 min"));
    try std.testing.expect(t.hasText("/dev/vda1 10G 2G"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"pop\"") != null);
    // The runner stops the screen on a pop; the search has the keys again.
    ext.stop();
    t.settle(1);
    t.typeText("gre");
    t.settle(1);
    try std.testing.expectEqualStrings("gre", s.query.text());
}

test "a list's rows, its actions on ⌘K, and Return runs the first" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var probe: u8 = 0;
    s.host = .{ .ctx = &probe, .open = noopOpen, .hide = noop };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    var heard: Heard = .{};
    ext.start("Hacker News", null, .{ .ctx = &heard, .func = Heard.said });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const line = "{\"type\":\"render\",\"view\":{\"kind\":\"list\",\"sections\":[{\"title\":\"Front Page\",\"items\":[{\"id\":\"a\",\"title\":\"Show HN: Nanolight\",\"subtitle\":\"rach\",\"icon\":{\"text\":\"1\"},\"accessories\":[\"128\"],\"actions\":[{\"id\":\"open\",\"title\":\"Open in Browser\"},{\"id\":\"copy\",\"title\":\"Copy Link\"}]},{\"id\":\"b\",\"title\":\"Zig 0.17\",\"actions\":[{\"id\":\"open2\",\"title\":\"Open in Browser\"}]}]}]}}";
    const m = try model.parse(arena.allocator(), line);
    ext.show(arena, m.view.?);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Front Page"));
    try std.testing.expect(t.hasText("Show HN: Nanolight"));
    try std.testing.expect(t.hasText("128"));
    try std.testing.expect(t.shortcut(.{ .key = 'k', .cmd = true }));
    t.settle(1);
    try std.testing.expect(t.hasText("Copy Link"));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.textOps(&.{.{ .command = .insert_newline }});
    t.settle(1);
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"id\":\"copy\"") != null);
}

test "a script's arguments: typed at once, Return runs it" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var probe: u8 = 0;
    s.host = .{ .ctx = &probe, .open = noopOpen, .hide = noop };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    var heard: Heard = .{};
    ext.start("Greet", null, .{ .ctx = &heard, .func = Heard.said });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const a = arena.allocator();
    const fields = try a.dupe(model.Field, &.{.{ .id = "arg1", .type = "text", .title = "Name", .value = .{ .string = "" } }});
    const acts = try a.dupe(model.Action, &.{.{ .id = "run", .title = "Run" }});
    ext.show(arena, .{ .kind = "form", .title = "Greet", .fields = fields, .actions = acts });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    t.typeText("Rach");
    t.settle(0.2);
    t.textOps(&.{.{ .command = .insert_newline }});
    t.settle(0.2);
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"value\":\"Rach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"id\":\"run\"") != null);
}

test "a compact script's last line, as the detail's heading" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var probe: u8 = 0;
    s.host = .{ .ctx = &probe, .open = noopOpen, .hide = noop };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    var heard: Heard = .{};
    ext.start("Greet", null, .{ .ctx = &heard, .func = Heard.said });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const md = try arena.allocator().dupe(u8, "# Hello, Rach - from a script");
    ext.show(arena, .{ .kind = "detail", .title = "Greet", .markdown = md });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    if (std.c.getenv("NANOLIGHT_SHOT2")) |p| try t.screenshot(std.mem.span(p));
    try std.testing.expect(t.hasText("Hello, Rach - from a script"));
}

test "a list that renders again keeps its selection, and the old render is freed only after it is read" {
    const gpa = std.testing.allocator;
    var ext: Ext = .{ .gpa = gpa };
    defer ext.deinit();
    const line = "{\"type\":\"render\",\"view\":{\"kind\":\"list\",\"sections\":[{\"items\":[{\"id\":\"a\",\"title\":\"One\"},{\"id\":\"b\",\"title\":\"Two\"},{\"id\":\"c\",\"title\":\"Three\"}]}]}}";
    // A refreshing extension (a timer, a live feed) renders the same list over and over.
    for (0..3) |i| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const m = try model.parse(arena.allocator(), line);
        ext.show(arena, m.view.?);
        if (i == 0) ext.sel = 2;
        try std.testing.expectEqual(@as(usize, 2), ext.sel);
    }
}
