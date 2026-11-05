//! Panel positions, relative to each screen's visible top left.
const std = @import("std");
const nanoui = @import("nanoui");

const key = "nanolight.panel.positions";
pub const Point = struct { x: f64, y: f64 };
pub const Saved = struct { screen: []const u8, x: f64, y: f64 };

/// The whole panel must fit, including the room it may grow into.
pub fn valid(p: Point, screen_width: f64, screen_height: f64, width: f64, height: f64) bool {
    return std.math.isFinite(p.x) and std.math.isFinite(p.y) and p.x >= 0 and p.y >= 0 and
        p.x + width <= screen_width and p.y + height <= screen_height;
}

pub fn load(store: nanoui.kv.Store, gpa: std.mem.Allocator, screen: []const u8, width: f64, height: f64) ?Point {
    const bytes = (store.get(gpa, key) catch null) orelse return null;
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice([]Saved, gpa, bytes, .{}) catch return null;
    defer parsed.deinit();
    for (parsed.value) |p| if (std.mem.eql(u8, p.screen, screen)) {
        const point: Point = .{ .x = p.x, .y = p.y };
        return if (valid(point, width, height, @import("view.zig").width, @import("view.zig").max_height)) point else null;
    };
    return null;
}

pub fn save(store: nanoui.kv.Store, gpa: std.mem.Allocator, screen: []const u8, point: Point) void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var entries: [16]Saved = undefined;
    var n: usize = 0;
    if (store.get(allocator, key) catch null) |bytes| {
        if (std.json.parseFromSliceLeaky([]Saved, allocator, bytes, .{})) |parsed| {
            for (parsed) |p| if (!std.mem.eql(u8, p.screen, screen) and n < entries.len - 1) {
                entries[n] = p;
                n += 1;
            };
        } else |_| {}
    }
    entries[n] = .{ .screen = screen, .x = point.x, .y = point.y };
    n += 1;
    const bytes = std.json.Stringify.valueAlloc(gpa, entries[0..n], .{}) catch return;
    defer gpa.free(bytes);
    store.set(key, bytes) catch {};
}

pub fn reset(store: nanoui.kv.Store) void {
    store.remove(key);
}

test "positions belong to their screen, invalid positions fall back, reset forgets all" {
    const t = std.testing;
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    try t.expect(load(mem.store(), t.allocator, "first", 1920, 1080) == null);
    save(mem.store(), t.allocator, "first", .{ .x = 100, .y = 50 });
    save(mem.store(), t.allocator, "second", .{ .x = 200, .y = 70 });
    try t.expectEqual(@as(f64, 100), load(mem.store(), t.allocator, "first", 1920, 1080).?.x);
    try t.expectEqual(@as(f64, 200), load(mem.store(), t.allocator, "second", 1920, 1080).?.x);
    try t.expect(load(mem.store(), t.allocator, "unplugged", 1920, 1080) == null);
    try t.expect(load(mem.store(), t.allocator, "first", 700, 700) == null);
    try t.expect(!valid(.{ .x = -1, .y = 0 }, 1920, 1080, 680, 674));
    try t.expect(!valid(.{ .x = 0, .y = std.math.nan(f64) }, 1920, 1080, 680, 674));
    try t.expect(valid(.{ .x = 0, .y = 0 }, 680, 674, 680, 674));
    reset(mem.store());
    try t.expect(load(mem.store(), t.allocator, "first", 1920, 1080) == null);
    try mem.store().set(key, "bad");
    try t.expect(load(mem.store(), t.allocator, "first", 1920, 1080) == null);
}
