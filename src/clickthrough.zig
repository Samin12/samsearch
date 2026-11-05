//! Clicks outside the panel reach what is under it. The window is as tall
//! as the panel can be, and a shadow's margin wider (it never resizes: see
//! main.zig's `Live`), so below a short panel it is clear but still there:
//! a click there landed on Nanolight's own window, which kept the keys, so
//! the panel stayed and the app beneath got nothing. While the panel shows,
//! the window ignores the mouse wherever the pointer is not over the panel:
//! the click goes to the app beneath, which takes the keys, and the panel,
//! losing them, hides as it always does. The pointer is followed only while
//! the panel shows (two event monitors, removed as it hides): an idle
//! Nanolight wakes for nothing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const view = @import("view.zig");

const mouse_moved: u64 = 1 << 5;
const left_dragged: u64 = 1 << 6;
const mask = mouse_moved | left_dragged;

pub const ClickThrough = struct {
    window: ?*nanoui.Window = null,
    /// The panel's height as drawn now (it springs).
    height: ?*const f32 = null,
    global: ?objc.Object = null,
    local: ?objc.Object = null,
    ignoring: bool = false,
    /// AppKit owns a press or drag until its release, even outside the panel.
    holding: bool = false,

    /// As the panel shows: follow the pointer.
    pub fn start(c: *ClickThrough) void {
        const w = c.window orelse return;
        if (c.global == null) {
            objc.msg(void, w.nswindow, "setAcceptsMouseMovedEvents:", .{objc.YES});
            const cls = objc.class("NSEvent");
            var g = objc.Block(ClickThrough, &.{objc.Object}).init(c, seen);
            c.global = keep(objc.msg(?objc.Object, cls, "addGlobalMonitorForEventsMatchingMask:handler:", .{ mask, @as(*anyopaque, @ptrCast(&g)) }));
            var l = objc.BlockRet(ClickThrough, &.{objc.Object}, ?objc.Object).init(c, seenHere);
            c.local = keep(objc.msg(?objc.Object, cls, "addLocalMonitorForEventsMatchingMask:handler:", .{ mask, @as(*anyopaque, @ptrCast(&l)) }));
        }
        c.update();
    }

    /// As the panel hides: stop following, and take the mouse again.
    pub fn stop(c: *ClickThrough) void {
        const cls = objc.class("NSEvent");
        for ([_]*?objc.Object{ &c.global, &c.local }) |m| if (m.*) |obj| {
            objc.msg(void, cls, "removeMonitor:", .{obj});
            objc.release(obj);
            m.* = null;
        };
        c.holding = false;
        c.set(false);
    }

    /// Whether the pointer is over the panel now; the window takes the
    /// mouse there only. Cheap: called on each move and as the panel grows.
    pub fn update(c: *ClickThrough) void {
        const w = c.window orelse return;
        if (c.global == null) return;
        if (!w.isVisible()) return c.stop();
        if (c.holding) return c.set(false);
        const at = objc.msg(objc.CGPoint, objc.class("NSEvent"), "mouseLocation", .{});
        const f = objc.msg(objc.CGRect, w.nswindow, "frame", .{});
        const h: f64 = if (c.height) |p| p.* else 0;
        c.set(!overPanel(f, at, view.shadow_margin, view.width, h));
    }

    fn set(c: *ClickThrough, ignore: bool) void {
        const w = c.window orelse return;
        if (ignore == c.ignoring) return;
        c.ignoring = ignore;
        objc.msg(void, w.nswindow, "setIgnoresMouseEvents:", .{if (ignore) objc.YES else objc.NO});
    }

    fn seen(c: *ClickThrough, _: objc.Object) void {
        c.update();
    }

    fn seenHere(c: *ClickThrough, ev: objc.Object) ?objc.Object {
        c.update();
        return ev;
    }
};

fn keep(obj: ?objc.Object) ?objc.Object {
    const o = obj orelse return null;
    objc.msg(void, o, "retain", .{});
    return o;
}

/// Whether screen point `at` (AppKit's: from the bottom left) is over the
/// panel in a window at `frame`: `margin` in from its left and top,
/// `width` by `height`.
pub fn overPanel(frame: objc.CGRect, at: objc.CGPoint, margin: f64, width: f64, height: f64) bool {
    const left = frame.origin.x + margin;
    const top = frame.origin.y + frame.size.height - margin;
    return at.x >= left and at.x <= left + width and at.y <= top and at.y >= top - height;
}

test "only the panel takes the mouse, not the clear window round it" {
    const f: objc.CGRect = .{ .origin = .{ .x = 100, .y = 200 }, .size = .{ .width = 760, .height = 754 } };
    // The panel: x 140…820, y from 914 (the top, 40 in) down 300 to 614.
    const t = std.testing;
    try t.expect(overPanel(f, .{ .x = 480, .y = 900 }, 40, 680, 300));
    try t.expect(overPanel(f, .{ .x = 140, .y = 614 }, 40, 680, 300));
    // Below a short panel, in the margin, and outside the window.
    try t.expect(!overPanel(f, .{ .x = 480, .y = 500 }, 40, 680, 300));
    try t.expect(!overPanel(f, .{ .x = 120, .y = 900 }, 40, 680, 300));
    try t.expect(!overPanel(f, .{ .x = 480, .y = 930 }, 40, 680, 300));
    try t.expect(!overPanel(f, .{ .x = 10, .y = 10 }, 40, 680, 300));
    // A taller panel reaches further down.
    try t.expect(overPanel(f, .{ .x = 480, .y = 500 }, 40, 680, 600));
}
