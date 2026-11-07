//! Headless regression tests for panel and application lifecycles.
const std = @import("std");
const t = std.testing;
const mac = @import("builtin").os.tag == .macos;
const shortcut = @import("shortcut.zig");

const Backend = struct {
    fail: bool = false,
    acquired: *bool,
    released: *bool,
    pub const Handle = u32;

    pub fn acquire(b: Backend) !Handle {
        try t.expect(!b.released.*);
        if (b.fail) return error.HotKeyTaken;
        b.acquired.* = true;
        return 2;
    }

    pub fn release(b: Backend, old: Handle) void {
        std.debug.assert(b.acquired.* and old == 1);
        b.released.* = true;
    }
};

test "a shortcut replacement acquires first and preserves the old key on failure" {
    var acquired = false;
    var released = false;
    var backend: Backend = .{ .acquired = &acquired, .released = &released };
    const replace = @import("hotkey.zig").replace;
    try t.expectEqual(@as(u32, 2), try replace(Backend, backend, 1));
    try t.expect(acquired and released);
    acquired = false;
    released = false;
    backend.fail = true;
    try t.expectError(error.HotKeyTaken, replace(Backend, backend, 1));
    try t.expect(!acquired and !released);
}

const Welcome = struct {
    applied: bool = false,
    finished: bool = false,
    started: bool = false,

    fn apply(ctx: *anyopaque, _: shortcut.Choice) void {
        const w: *Welcome = @ptrCast(@alignCast(ctx));
        w.applied = true;
    }
    fn done(ctx: *anyopaque) void {
        const w: *Welcome = @ptrCast(@alignCast(ctx));
        w.finished = true;
    }
    fn starting(ctx: *anyopaque) void {
        const w: *Welcome = @ptrCast(@alignCast(ctx));
        w.started = true;
    }
    fn fix(_: *anyopaque, _: shortcut.Clash) void {}
    fn failed(_: *anyopaque) ?[]const u8 {
        return "Couldn't register the shortcut.";
    }
};

test "skipping welcome finishes without applying the highlighted key" {
    var ix = @import("apps.zig").Index.init(t.allocator);
    defer ix.deinit();
    var s: @import("view.zig").Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var w: Welcome = .{};
    var o: @import("onboard.zig").Onboard = .{ .active = true, .choice = .opt_space, .hooks = .{
        .ctx = &w,
        .apply = Welcome.apply,
        .fix = Welcome.fix,
        .done = Welcome.done,
    } };
    o.finish(&s, "");
    try t.expect(!o.active and w.finished and !w.applied);
}

test "welcome start cancels recording and registration failure is a visible state" {
    var w: Welcome = .{};
    var o: @import("onboard.zig").Onboard = .{ .hooks = .{
        .ctx = &w,
        .apply = Welcome.apply,
        .fix = Welcome.fix,
        .done = Welcome.done,
        .starting = Welcome.starting,
        .key_error = Welcome.failed,
    } };
    o.start(.cmd_space);
    try t.expect(w.started);
    o.active = false;
    o.step = .try_it;
    try t.expectEqualStrings("Couldn't register the shortcut.", o.registrationError().?);
    o.pressed(true);
    try t.expect(!o.closed);
    o.active = true;
    o.pressed(true);
    o.pressed(false);
    try t.expect(o.closed and o.reopened);
}

test "every native drag failure resets the state and copied path" {
    if (!mac) return error.SkipZigTest;
    const drag = @import("drag_mac.zig");
    for ([_]drag.State{ .idle, .candidate, .window, .file }) |state| {
        var d: drag.Drag = .{ .state = state, .path_len = 4 };
        d.reset();
        try t.expectEqual(drag.State.idle, d.state);
        try t.expect(!d.active());
        try t.expectEqual(@as(usize, 0), d.path_len);
    }
}

test "helper supervisor distinguishes absence health failures and stale binaries" {
    if (!mac) return error.SkipZigTest;
    const helper = @import("helper_mac.zig");
    var s: helper.Supervisor = .{};
    try t.expectEqual(helper.Action.launch, s.observe(.missing, 1000));
    try t.expectEqual(helper.State.launching, s.state);
    try t.expectEqual(helper.Action.none, s.observe(.healthy, 1010));
    try t.expectEqual(helper.State.running, s.state);
    try t.expectEqual(helper.Action.none, s.observe(.failed, 1020));
    try t.expectEqual(helper.State.unhealthy, s.state);
    try t.expectEqual(helper.Action.none, s.observe(.healthy, 1030));
    try t.expectEqual(@as(u8, 0), s.failures);
    try t.expectEqual(helper.Action.none, s.observe(.failed, 1040));
    try t.expectEqual(helper.Action.restart, s.observe(.failed, 1050));
    try t.expectEqual(helper.Action.restart, s.observe(.stale, 1060));
    try t.expectEqual(helper.State.restarting, s.state);
}

test "helper restart cap recovers after its two minute window" {
    if (!mac) return error.SkipZigTest;
    const helper = @import("helper_mac.zig");
    var s: helper.Supervisor = .{};
    for (0..5) |_| try t.expectEqual(helper.Action.restart, s.observe(.restart, 1000));
    try t.expectEqual(helper.Action.none, s.observe(.restart, 1100));
    try t.expectEqual(helper.State.limited, s.state);
    try t.expectEqual(helper.Action.launch, s.observe(.missing, 1120));
    try t.expectEqual(@as(u8, 1), s.restarts);
}

test "failed registration lets welcome return to key selection" {
    const ui = @import("nanoui").ui;
    const view = @import("view.zig");
    var ix = @import("apps.zig").Index.init(t.allocator);
    defer ix.deinit();
    var w: Welcome = .{};
    var o: @import("onboard.zig").Onboard = .{ .active = true, .step = .try_it, .hooks = .{
        .ctx = &w,
        .apply = Welcome.apply,
        .fix = Welcome.fix,
        .done = Welcome.done,
        .key_error = Welcome.failed,
    } };
    var s: view.Nanolight = .{ .index = &ix, .onboard = &o };
    defer s.query.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    try t.expect(tester.hasText("Couldn't register the shortcut."));
    tester.key(.enter);
    tester.settle(1);
    try t.expectEqual(@import("onboard.zig").Step.key, o.step);
    try t.expect(!w.applied);
}

test "drag hit resolves the displayed row after current results reorder" {
    if (!mac) return error.SkipZigTest;
    const ui = @import("nanoui").ui;
    const view = @import("view.zig");
    var ix = @import("apps.zig").Index.init(t.allocator);
    defer ix.deinit();
    try ix.add("Alpha", "/Applications/Alpha.app");
    try ix.add("Beta", "/Applications/Beta.app");
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.reveal();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    @import("tests.zig").press(&tester, &.{.{ .insert = "a" }});
    s.last_h = s.height();
    const rect = tester.ctx.rects.get(s.row_ids[0]).?;
    const path = s.filePath(s.res.rows[0]).?;
    std.mem.swap(@import("results.zig").Row, &s.res.rows[0], &s.res.rows[1]);
    const hit = @import("drag_mac.zig").target(&s, &tester.ctx, .{ .x = rect.x + 10, .y = rect.y + 10 });
    try t.expect(hit == .file);
    try t.expectEqualStrings(path, hit.file);
}

test "hiding a preview invalidates delayed recovery even without a web view" {
    if (!mac) return error.SkipZigTest;
    var preview: @import("preview.zig").Preview = .{ .state = .recovering, .generation = 7 };
    preview.hide();
    try t.expect(preview.state == .idle);
    try t.expectEqual(@as(u64, 8), preview.generation);
    try t.expect(preview.navigation == null);
}

test "forced panel hide tears down a page and consumes keep_open" {
    if (!mac) return error.SkipZigTest;
    var ix = @import("apps.zig").Index.init(t.allocator);
    defer ix.deinit();
    var s: @import("view.zig").Nanolight = .{ .index = &ix, .previewing = true, .note = "Updated" };
    defer s.query.deinit();
    var live: @import("main.zig").Live = .{
        .app = undefined,
        .kv = undefined,
        .s = &s,
        .o = undefined,
        .keep_open = true,
        .visibility = .shown,
        .preview = .{ .state = .recovering },
    };
    @import("main.zig").Live.hidePanel(&live);
    try t.expect(!s.previewing and !live.keep_open);
    try t.expect(live.visibility == .hidden and live.preview.state == .idle);
    try t.expectEqualStrings("", s.note);
    @import("main.zig").Live.hidePanel(&live);
    try t.expect(live.visibility == .hidden);
}

var moves: u32 = 0;
fn moveAnswer(_: *anyopaque) void {
    moves += 1;
}

test "Open Answer Window moves the Quick Ask conversation instead of asking again" {
    const tests = @import("tests.zig");
    const view = @import("view.zig");
    const ui = @import("nanoui").ui;
    const gpa = t.allocator;
    var ix: @import("apps.zig").Index = .init(gpa);
    defer ix.deinit();
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var h = web.host();
    h.move_answer = moveAnswer;
    s.host = h;
    s.reveal();
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    tests.press(&tester, &.{.{ .insert = "liquid glass" }});
    for ([_]bool{ true, false }) |ok| {
        moves = 0;
        web.probe = .{};
        try t.expect(tester.shortcut(.{ .key = '1', .cmd = true }));
        tester.settle(1);
        try t.expect(s.previewing);
        // ⌘↩ asks the page to hand over; nothing opens until it answers.
        s.openPreviewOut(null);
        try t.expectEqual(@as(u32, 1), moves);
        try t.expectEqual(@as(usize, 0), web.probe.opened_len);
        s.answerMoved(ok);
        try t.expect(web.probe.hidden and !s.previewing);
        // An older helper can't move it: the question is asked there instead.
        if (!ok) try t.expectEqualStrings("quickask://answer?q=liquid+glass", web.probe.opened[0..web.probe.opened_len]);
        if (ok) try t.expectEqual(@as(usize, 0), web.probe.opened_len);
        s.reveal();
        tester.settle(1);
    }
}
