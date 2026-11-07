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
    t.frame();
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

// These tests use the production script/host senders. The testing allocator
// poisons freed arenas and reports leaks; Tester renders the entire frame
// after each key/control callback before the queued mutation is consumed.
const ScriptRunner = @import("script_run.zig").Runner;
const HostRunner = @import("raycast.zig").Runner;
const mac = @import("builtin").os.tag == .macos;

const Rig = struct {
    ix: Index,
    s: view.Nanolight,
    ext: Ext,
    threaded: std.Io.Threaded,
    script: ScriptRunner,
    tester: ui.Tester,
    probe: u8 = 0,

    fn init(r: *Rig) !void {
        const a = std.testing.allocator;
        r.ix = .init(a);
        r.s = .{ .index = &r.ix };
        r.ext = .{ .gpa = a, .back = &r.s.query };
        r.s.ext = &r.ext;
        r.s.host = .{ .ctx = &r.probe, .open = noopOpen, .hide = noop };
        r.threaded = .init(a, .{});
        r.script = .{ .gpa = a, .io = r.threaded.io(), .ext = &r.ext, .hooks = .{ .ctx = &r.probe, .hide = noop, .redraw = noop, .copy = noopOpen, .footer = noopOpen } };
        try r.tester.init(a, .init(&r.s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    }

    fn deinit(r: *Rig) void {
        r.tester.deinit();
        r.script.deinit();
        r.ext.deinit();
        r.s.query.deinit();
        r.ix.deinit();
        r.threaded.deinit();
    }

    fn start(r: *Rig, tmp: std.testing.TmpDir, bytes: []const u8) !void {
        const a = std.testing.allocator;
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "command.sh", .data = bytes });
        const file = try tmp.dir.realPathFileAlloc(std.testing.io, "command.sh", a);
        defer a.free(file);
        const target = try std.fmt.allocPrint(a, "script:{s}", .{file});
        defer a.free(target);
        r.script.start(target, "Regression", null);
        r.tester.settle(0.1);
    }
};

test "real script Return on argument and confirmation forms preserves the drawing arena" {
    if (!mac) return error.SkipZigTest;
    for ([_][]const u8{
        "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title Regression\n# @raycast.mode fullOutput\n# @raycast.argument1 {\"type\":\"text\",\"placeholder\":\"Name\"}\nexec /bin/sleep 30\n",
        "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title Regression\n# @raycast.mode fullOutput\n# @raycast.needsConfirmation true\nexec /bin/sleep 30\n",
    }) |source| {
        var r: Rig = undefined;
        try r.init();
        defer r.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try r.start(tmp, source);
        if (r.ext.view.?.isForm()) {
            r.tester.typeText("Samin");
            r.tester.settle(0.1);
        }
        const generation = r.ext.generation;
        r.tester.textOps(&.{.{ .command = .insert_newline }});
        // The key callback has only queued the action; the frame still
        // references this exact generation until it finishes drawing.
        try std.testing.expectEqual(generation, r.ext.generation);
        try std.testing.expect(r.script.child == null);
        r.tester.frame();
        try std.testing.expect(r.script.child != null);
        try std.testing.expect(r.ext.generation > generation);
        _ = r.tester.shortcut(.{ .key = ui.Shortcut.escape });
        try std.testing.expect(r.ext.open);
        r.tester.frame();
        try std.testing.expect(!r.ext.open);
        try std.testing.expect(r.script.child == null);
    }
}

test "real script dropdown callback and Run Again defer replacement until the next frame" {
    if (!mac) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try r.start(tmp, "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title Regression\n# @raycast.mode fullOutput\n# @raycast.argument1 {\"type\":\"dropdown\",\"data\":[{\"title\":\"First\",\"value\":\"one\"},{\"title\":\"Second\",\"value\":\"two\"}]}\nprintf done\n");
    const generation = r.ext.generation;
    try r.tester.clickText("Second");
    try std.testing.expectEqual(generation, r.ext.generation);
    r.tester.frame();
    try std.testing.expectEqualStrings("two", r.script.args[0].items);
    r.tester.textOps(&.{.{ .command = .insert_newline }});
    r.tester.frame();
    try std.testing.expect(r.script.child != null);
    // The production EOF callback hands wait/reap to a worker; the test
    // pumps its UI completion without a native application event loop.
    ScriptRunner.ended(&r.script);
    for (0..200) |_| {
        r.tester.frame();
        if (r.script.state == .stopped) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@import("raycast.zig").Lifecycle.stopped, r.script.state);
    try std.testing.expectEqualStrings("Run Again", r.ext.view.?.actions[1].title);
    const done_generation = r.ext.generation;
    _ = r.tester.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true });
    try std.testing.expectEqual(done_generation, r.ext.generation);
    r.tester.frame();
    try std.testing.expect(r.ext.view.?.isForm());
    try std.testing.expectEqualStrings("two", r.script.args[0].items);
}

fn noClipboard(_: *anyopaque, _: std.mem.Allocator) ?[]u8 {
    return null;
}

test "real host failed write preserves view memory and its terminal diagnostic" {
    if (!mac) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var host: HostRunner = .{ .gpa = std.testing.allocator, .io = r.threaded.io(), .ext = &r.ext, .hooks = .{ .ctx = &r.probe, .open = noopOpen, .copy = noopOpen, .read_clipboard = noClipboard, .hide = noop, .redraw = noop, .rescan = noop } };
    defer host.line.deinit(std.testing.allocator);
    defer host.stop();
    // A real pipe whose reader has exited: writing to it fails with EPIPE.
    var child = try std.process.spawn(r.threaded.io(), .{ .argv = &.{"/usr/bin/true"}, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    var status: c_int = 0;
    try std.testing.expect(std.c.waitpid(child.id.?, &status, 0) == child.id.?);
    child.id = null;
    host.child = child;
    host.state = .running;
    r.ext.start("Host", null, .{ .ctx = &host, .func = HostRunner.send });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const a = arena.allocator();
    const acts = try a.dupe(model.Action, &.{.{ .id = "dead", .title = "Send to dead host" }});
    r.ext.show(arena, .{ .kind = "detail", .markdown = try a.dupe(u8, "Still owned"), .actions = acts });
    r.tester.settle(0.1);
    const generation = r.ext.generation;
    r.tester.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expectEqual(generation, r.ext.generation);
    r.tester.frame();
    try std.testing.expect(r.ext.open);
    try std.testing.expect(r.ext.generation > generation);
    try std.testing.expect(r.tester.hasText("The extension host disconnected"));
}

test "command icons own bytes and navigation restores query and selection by view id" {
    const a = std.testing.allocator;
    var ext: Ext = .{ .gpa = a };
    defer ext.deinit();
    var heard: Heard = .{};
    const icon = try a.dupe(u8, "image bytes");
    ext.start("Icon", icon, .{ .ctx = &heard, .func = Heard.said });
    a.free(icon);
    try std.testing.expectEqualStrings("image bytes", ext.icon.?);
    for ([_]u64{ 1, 2, 1 }) |id| {
        var arena: std.heap.ArenaAllocator = .init(a);
        const source = try std.fmt.allocPrint(arena.allocator(), "{{\"type\":\"render\",\"view\":{{\"viewId\":{d},\"searchText\":\"Two\",\"selected\":\"b\",\"sections\":[{{\"items\":[{{\"id\":\"a\",\"title\":\"One\"}},{{\"id\":\"b\",\"title\":\"Two\"}}]}}]}}}}", .{id});
        const message = try model.parse(arena.allocator(), source);
        ext.show(arena, message.view.?);
        try std.testing.expectEqualStrings("Two", ext.query.text());
        try std.testing.expectEqual(@as(usize, 1), ext.sel);
    }
}

test "real script Run Again starts a fresh run without growing its command arena" {
    if (!mac) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try r.start(tmp, "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title Regression\n# @raycast.mode fullOutput\nprintf done\n");
    const capacity = r.script.arena.?.queryCapacity();
    for (0..3) |_| {
        ScriptRunner.ended(&r.script);
        for (0..200) |_| {
            r.tester.frame();
            if (r.script.state == .stopped) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        }
        try std.testing.expectEqualStrings("Run Again", r.ext.view.?.actions[1].title);
        const generation = r.ext.generation;
        _ = r.tester.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true });
        try std.testing.expectEqual(generation, r.ext.generation);
        r.tester.frame();
        try std.testing.expect(r.script.child != null);
        try std.testing.expectEqual(capacity, r.script.arena.?.queryCapacity());
    }
}

fn largeClipboard(_: *anyopaque, a: std.mem.Allocator) ?[]u8 {
    const bytes = a.alloc(u8, 100000) catch return null;
    @memset(bytes, 'x');
    return bytes;
}

test "host clipboard replies exceed 64 KB and unsupported confirmation is rejected" {
    if (!mac) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var host: HostRunner = .{ .gpa = std.testing.allocator, .io = rig.threaded.io(), .ext = &rig.ext, .hooks = .{ .ctx = &rig.probe, .open = noopOpen, .copy = noopOpen, .read_clipboard = largeClipboard, .hide = noop, .redraw = noop, .rescan = noop } };
    defer host.line.deinit(std.testing.allocator);
    defer host.stop();
    host.child = try std.process.spawn(rig.threaded.io(), .{ .argv = &.{ "/bin/sh", "-c", "IFS= read -r line; printf '%s' \"$line\" | /usr/bin/wc -c" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    host.state = .running;
    host.feed("{\"type\":\"request\",\"method\":\"clipboard.readText\",\"id\":1}\n");
    var buf: [256]u8 = undefined;
    const n = std.c.read(host.child.?.stdout.?.handle, &buf, buf.len);
    try std.testing.expect(n > 0);
    const length = try std.fmt.parseInt(usize, std.mem.trim(u8, buf[0..@intCast(n)], " \n\r"), 10);
    try std.testing.expect(length > 100000);
    host.stop();
    host.child = try std.process.spawn(rig.threaded.io(), .{ .argv = &.{ "/bin/sh", "-c", "IFS= read -r line; printf '%s' \"$line\"" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    host.state = .running;
    host.feed("{\"type\":\"request\",\"method\":\"confirm\",\"id\":2}\n");
    const reply_len = std.c.read(host.child.?.stdout.?.handle, &buf, buf.len);
    try std.testing.expect(reply_len > 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf[0..@intCast(reply_len)], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") != null);
    try std.testing.expect(parsed.value.object.get("result") == null);
}

test "host drains messages after exit, retains its final error, and scopes toast hide by id" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var host: HostRunner = .{ .gpa = std.testing.allocator, .io = rig.threaded.io(), .ext = &rig.ext, .hooks = .{ .ctx = &rig.probe, .open = noopOpen, .copy = noopOpen, .read_clipboard = noClipboard, .hide = noop, .redraw = noop, .rescan = noop } };
    defer host.line.deinit(std.testing.allocator);
    defer host.stop();
    rig.ext.start("Final output", null, .{ .ctx = &host, .func = HostRunner.send });
    host.feed("{\"type\":\"toast\",\"id\":1,\"title\":\"final toast\"}\n");
    HostRunner.ended(&host);
    try std.testing.expectEqualStrings("final toast", rig.ext.view.?.markdown.?);
    rig.ext.stop();
    rig.ext.start("Final output", null, .{ .ctx = &host, .func = HostRunner.send });
    // The real stdout watcher can receive exit and the final diagnostic
    // in the same read. Every complete line must still be dispatched.
    host.feed("{\"type\":\"exit\"}\n{\"type\":\"error\",\"message\":\"last diagnostic\"}\n");
    HostRunner.ended(&host);
    rig.tester.settle(0.1);
    try std.testing.expect(rig.ext.open);
    try std.testing.expect(rig.tester.hasText("last diagnostic"));
    host.feed("{\"type\":\"toast\",\"id\":1,\"title\":\"old\"}\n");
    host.feed("{\"type\":\"toast\",\"id\":2,\"title\":\"new\"}\n");
    host.feed("{\"type\":\"toast_hide\",\"id\":1}\n");
    try std.testing.expectEqualStrings("new", rig.ext.note_buf[0..rig.ext.note_len]);
    host.feed("{\"type\":\"toast_hide\",\"id\":2}\n");
    try std.testing.expectEqual(@as(usize, 0), rig.ext.note_len);
    host.feed("{\"type\":\"hud\",\"title\":\"expires on hide\"}\n");
    try std.testing.expectEqual(@as(usize, 0), rig.ext.note_len);
}

test "refresh keeps unsent edits and applies later controlled form and search values" {
    const a = std.testing.allocator;
    var ext: Ext = .{ .gpa = a };
    defer ext.deinit();
    for ([_][]const u8{
        "{\"type\":\"render\",\"view\":{\"viewId\":1,\"kind\":\"form\",\"fields\":[{\"id\":\"text\",\"value\":\"default\"}]}}",
        "{\"type\":\"render\",\"view\":{\"viewId\":1,\"kind\":\"form\",\"fields\":[{\"id\":\"text\",\"value\":\"default\"}]}}",
        "{\"type\":\"render\",\"view\":{\"viewId\":1,\"kind\":\"form\",\"fields\":[{\"id\":\"text\",\"controlled\":true,\"value\":\"server\"}]}}",
    }, 0..) |source, i| {
        var arena: std.heap.ArenaAllocator = .init(a);
        const message = try model.parse(arena.allocator(), source);
        ext.show(arena, message.view.?);
        try std.testing.expectEqualStrings(if (i == 0) "default" else if (i == 1) "typed" else "server", ext.fields[0].text());
        if (i == 0) ext.fields[0].set("typed");
    }
    for ([_][]const u8{
        "{\"type\":\"render\",\"view\":{\"viewId\":2,\"searchText\":\"\"}}",
        "{\"type\":\"render\",\"view\":{\"viewId\":2,\"searchText\":\"\"}}",
        "{\"type\":\"render\",\"view\":{\"viewId\":2,\"searchText\":\"controlled\",\"searchControlled\":true}}",
    }, 0..) |source, i| {
        var arena: std.heap.ArenaAllocator = .init(a);
        const message = try model.parse(arena.allocator(), source);
        ext.show(arena, message.view.?);
        try std.testing.expectEqualStrings(if (i == 0) "" else if (i == 1) "typed query" else "controlled", ext.query.text());
        if (i == 0) ext.query.set("typed query");
    }
}

test "a command that closes its output keeps running until it exits on its own" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    // Closes stdout (EOF for the panel), then works for 4 s and exits 7.
    const child = try std.process.spawn(threaded.io(), .{ .argv = &.{ "/bin/sh", "-c", "exec >&-; sleep 4; exit 7" }, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
    const job = @import("raycast.zig").ProcessJob.start(child, false) orelse return error.SpawnFailed;
    defer job.release();
    var waited: usize = 0;
    while (!job.done.load(.acquire) and waited < 400) : (waited += 1) {
        std.Io.sleep(threaded.io(), .fromMilliseconds(20), .awake) catch {};
    }
    try std.testing.expect(job.done.load(.acquire));
    // Exited by itself, not killed after the 2 s stop deadline.
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, job.term.?);
}
