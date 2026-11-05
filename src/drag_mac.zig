//! Native panel moves and file drags, before nanoui sees a dragged row's release.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const view = @import("view.zig");
const Kind = @import("results.zig").Kind;
const ClickThrough = @import("clickthrough.zig").ClickThrough;

pub fn pastThreshold(start: objc.CGPoint, at: objc.CGPoint) bool {
    const dx = at.x - start.x;
    const dy = at.y - start.y;
    return dx * dx + dy * dy >= 25;
}

pub fn draggable(kind: Kind, path: []const u8) bool {
    return (kind == .app or kind == .file or kind == .digup_hit) and path.len > 0 and path[0] == '/';
}

pub const Target = union(enum) { control, window, file: []const u8 };

/// Last frame's hit map keeps controls and text selection ahead of drags.
pub fn target(s: *const view.Nanolight, c: *const nanoui.ui.Context, p: nanoui.ui.Point) Target {
    const m = s.margin;
    if (p.x < m or p.x > m + view.width or p.y < m or p.y > m + s.last_h) return .control;
    if (s.previewing and p.y >= m + view.webArea(s.last_h).y and p.y < m + s.last_h - view.footer_h) return .control;
    var hot: u64 = 0;
    var h = c.hits.items.len;
    while (h > 0) {
        h -= 1;
        const hit = c.hits.items[h];
        if (!hit.scroll and hit.rect.contains(p)) {
            hot = hit.id;
            break;
        }
    }
    for (s.row_ids, 0..) |id, i| if (id != 0 and id == hot and i < s.res.n) {
        const row = s.res.rows[i];
        if (s.filePath(row)) |path| if (draggable(row.kind, path)) return .{ .file = path };
        return .window;
    };
    if (hot == s.query_id and hot != 0) {
        const rect = c.rects.get(hot) orelse return .control;
        const edit = c.edits.get(hot);
        const scroll = if (edit) |e| e.scroll_x else 0;
        const text_end = rect.x + c.text.width(s.query.text(), .{ .size = 21 }) - scroll;
        if (s.query.text().len > 0 and p.x <= text_end + 3) return .control;
        return .window;
    }
    return if (hot == 0) .window else .control;
}

pub const Drag = struct {
    window: ?*nanoui.Window = null,
    s: ?*view.Nanolight = null,
    through: ?*ClickThrough = null,
    monitor: ?objc.Object = null,
    source: ?objc.Object = null,
    down: ?objc.Object = null,
    start_at: objc.CGPoint = .{},
    path: [@import("files.zig").max_path]u8 = undefined,
    path_len: usize = 0,
    candidate: bool = false,
    /// The drag session keeps the panel alive until its source callback.
    active: bool = false,
    swallowing: bool = false,

    pub fn start(d: *Drag, w: *nanoui.Window, s: *view.Nanolight, through: *ClickThrough) void {
        d.window = w;
        d.s = s;
        d.through = through;
        const cls = objc.defineClass(.{
            .name = "SamSearchDragSource",
            .protocols = &.{"NSDraggingSource"},
            .methods = &.{
                .{ .name = "draggingSession:sourceOperationMaskForDraggingContext:", .imp = &sourceMask, .types = "Q@:@q" },
                .{ .name = "ignoreModifierKeysForDraggingSession:", .imp = &ignoreModifiers, .types = "B@:@" },
                .{ .name = "draggingSession:endedAtPoint:operation:", .imp = &ended, .types = "v@:@{CGPoint=dd}Q" },
            },
        });
        d.source = objc.msg(objc.Object, cls, "new", .{});
        objc.setZig(d.source.?, d);
        var block = objc.BlockRet(Drag, &.{objc.Object}, ?objc.Object).init(d, event);
        const mask: u64 = (1 << 1) | (1 << 2) | (1 << 6);
        d.monitor = objc.msg(?objc.Object, objc.class("NSEvent"), "addLocalMonitorForEventsMatchingMask:handler:", .{ mask, @as(*anyopaque, @ptrCast(&block)) });
        if (d.monitor) |m| _ = objc.retain(m);
    }

    pub fn stop(d: *Drag) void {
        if (d.monitor) |m| {
            objc.msg(void, objc.class("NSEvent"), "removeMonitor:", .{m});
            objc.release(m);
            d.monitor = null;
        }
        d.clear();
        if (d.source) |s| {
            objc.setZig(s, null);
            objc.release(s);
            d.source = null;
        }
    }

    fn clear(d: *Drag) void {
        if (d.down) |ev| objc.release(ev);
        d.down = null;
        d.candidate = false;
        d.path_len = 0;
    }

    fn cancelPress(d: *Drag) void {
        const surface = d.window.?.surface orelse return;
        surface.ctx.active = 0;
        surface.ctx.input.down = false;
        surface.ctx.input.pressed = false;
        surface.ctx.input.released = false;
        if (surface.ctx.edits.getPtr(d.s.?.query_id)) |edit| edit.selecting = false;
        surface.requestFrame();
    }

    fn event(d: *Drag, ev: objc.Object) ?objc.Object {
        const w = d.window orelse return ev;
        const ty = objc.msg(objc.NSUInteger, ev, "type", .{});
        if (d.active) return ev;
        if (ty == 2) {
            const swallow = d.swallowing;
            d.swallowing = false;
            d.clear();
            d.through.?.holding = false;
            d.through.?.update();
            return if (swallow) null else ev;
        }
        if (objc.msg(?objc.Object, ev, "window", .{}) != w.nswindow or !w.isVisible()) return ev;
        const surface = w.surface orelse return ev;
        const at = objc.msg(objc.CGPoint, ev, "locationInWindow", .{});
        if (ty == 1) {
            d.clear();
            d.swallowing = false;
            if (objc.msg(objc.NSUInteger, ev, "modifierFlags", .{}) & (1 << 18) != 0) return ev;
            const p = surface.toView(at);
            const s = d.s.?;
            if (p.x < s.margin or p.x > s.margin + view.width or p.y < s.margin or p.y > s.margin + s.last_h) return ev;
            d.through.?.holding = true;
            d.through.?.update();
            const chosen = target(s, &surface.ctx, p);
            switch (chosen) {
                .control => return ev,
                .window => {},
                .file => |path| {
                    if (path.len >= d.path.len) return ev;
                    @memcpy(d.path[0..path.len], path);
                    d.path_len = path.len;
                },
            }
            surface.ctx.input.mouse = p;
            surface.ctx.updateHot();
            d.start_at = at;
            d.down = objc.retain(ev);
            d.candidate = true;
            return if (surface.ctx.hot == 0) null else ev;
        }
        if (ty != 6 or !d.candidate or !pastThreshold(d.start_at, at)) return ev;
        d.cancelPress();
        d.candidate = false;
        d.swallowing = true;
        if (d.path_len > 0) {
            d.beginFile(ev);
        } else {
            // AppKit tracks the move; the fixed-size window keeps its top edge.
            d.active = true;
            objc.msg(void, w.nswindow, "performWindowDragWithEvent:", .{d.down.?});
            d.active = false;
            d.swallowing = false;
            @import("panel_mac.zig").remember(w);
            d.through.?.holding = false;
            d.through.?.update();
        }
        d.clear();
        return null;
    }

    fn beginFile(d: *Drag, ev: objc.Object) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const surface = d.window.?.surface orelse return;
        const path = objc.nsString(d.path[0..d.path_len]);
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{path});
        const item = objc.msg(objc.Object, objc.alloc("NSDraggingItem"), "initWithPasteboardWriter:", .{url});
        defer objc.release(item);
        const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
        const image = objc.msg(objc.Object, ws, "iconForFile:", .{path});
        const at = objc.msg(objc.CGPoint, surface.nsview, "convertPoint:fromView:", .{ objc.msg(objc.CGPoint, ev, "locationInWindow", .{}), @as(?objc.Object, null) });
        const frame: objc.CGRect = .{ .origin = .{ .x = at.x - 16, .y = at.y - 16 }, .size = .{ .width = 32, .height = 32 } };
        objc.msg(void, item, "setDraggingFrame:contents:", .{ frame, image });
        const items = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{item});
        d.active = true;
        const session = objc.msg(?objc.Object, surface.nsview, "beginDraggingSessionWithItems:event:source:", .{ items, ev, d.source.? });
        if (session) |s| {
            objc.msg(void, s, "setAnimatesToStartingPositionsOnCancelOrFail:", .{objc.YES});
        } else {
            d.active = false;
            d.through.?.holding = false;
        }
    }
};

/// Copy, link and generic are allowed in every context, never move or delete.
fn sourceMask(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.NSInteger) callconv(.c) objc.NSUInteger {
    return 1 | 2 | 4;
}

fn ignoreModifiers(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn ended(obj: objc.Object, _: objc.SEL, _: objc.Object, _: objc.CGPoint, _: objc.NSUInteger) callconv(.c) void {
    const d = objc.getZig(Drag, obj) orelse return;
    d.active = false;
    d.swallowing = false;
    d.clear();
    d.cancelPress();
    d.through.?.holding = false;
    const w = d.window orelse return;
    if (!w.isFocused()) {
        d.through.?.stop();
        w.hide();
    } else d.through.?.update();
}

test "native drags require five points and real app or file paths" {
    const t = std.testing;
    try t.expect(!pastThreshold(.{}, .{ .x = 3, .y = 3 }));
    try t.expect(pastThreshold(.{}, .{ .x = 3, .y = 4 }));
    try t.expect(pastThreshold(.{ .x = 20, .y = 20 }, .{ .x = 14, .y = 20 }));
    for ([_]Kind{ .app, .file, .digup_hit }) |k| try t.expect(draggable(k, "/tmp/file"));
    for ([_]Kind{ .pane, .settings, .calc, .quick_ask, .new_thread, .digup, .search_web, .suggest, .codes }) |k| try t.expect(!draggable(k, "/tmp/file"));
    try t.expect(!draggable(.app, "raycast:command"));
    try t.expect(!draggable(.file, ""));
}

test "the hit map keeps text and controls, drags files, and moves quiet panel areas" {
    const ui = nanoui.ui;
    const t = std.testing;
    var ix: @import("apps.zig").Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var s: view.Nanolight = .{ .index = &ix, .margin = view.shadow_margin, .window_fades = true };
    defer s.query.deinit();
    s.reveal();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width + 2 * view.shadow_margin, .height = view.max_height + 2 * view.shadow_margin, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    @import("tests.zig").press(&tester, &.{.{ .insert = "saf" }});
    s.last_h = s.height();
    const field = tester.ctx.rects.get(s.query_id).?;
    try t.expect(target(&s, &tester.ctx, .{ .x = field.x + 5, .y = field.y + field.h / 2 }) == .control);
    try t.expect(target(&s, &tester.ctx, .{ .x = field.x + field.w - 10, .y = field.y + field.h / 2 }) == .window);
    const row = tester.ctx.rects.get(s.row_ids[0]).?;
    const file = target(&s, &tester.ctx, .{ .x = row.x + 10, .y = row.y + 20 });
    try t.expect(file == .file);
    try t.expectEqualStrings("/Applications/Safari.app", file.file);
    const gear = tester.findText("Settings").?;
    try t.expect(target(&s, &tester.ctx, .{ .x = gear.x + gear.w / 2, .y = gear.y + gear.h / 2 }) == .control);
    try t.expect(target(&s, &tester.ctx, .{ .x = s.margin + 1, .y = s.margin + 30 }) == .window);
    try t.expect(target(&s, &tester.ctx, .{ .x = s.margin + 100, .y = s.margin + s.last_h - 10 }) == .window);
    try t.expect(target(&s, &tester.ctx, .{ .x = s.margin - 1, .y = s.margin + 30 }) == .control);
    try t.expect(target(&s, &tester.ctx, .{ .x = s.margin + 100, .y = s.margin + s.last_h + 1 }) == .control);
    const google = tester.ctx.rects.get(s.row_ids[1]).?;
    try t.expect(target(&s, &tester.ctx, .{ .x = google.x + 10, .y = google.y + 20 }) == .window);
    s.previewing = true;
    s.last_h = view.max_height;
    try t.expect(target(&s, &tester.ctx, .{ .x = s.margin + 100, .y = s.margin + view.header_h + 30 }) == .control);
}
