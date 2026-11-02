//! A key combination the whole system hands to this app, from any app:
//! Carbon's hot keys, which every launcher uses (they need no
//! Accessibility permission, and the keys go to no other app).
const std = @import("std");

const EventTypeSpec = extern struct { class: u32, kind: u32 };
const HotKeyId = extern struct { signature: u32, id: u32 };
const Handler = *const fn (call: ?*anyopaque, event: ?*anyopaque, user: ?*anyopaque) callconv(.c) i32;

extern "c" fn GetApplicationEventTarget() ?*anyopaque;
extern "c" fn InstallEventHandler(target: ?*anyopaque, handler: Handler, count: u32, list: [*]const EventTypeSpec, user: ?*anyopaque, out: ?*?*anyopaque) i32;
extern "c" fn RegisterEventHotKey(key_code: u32, modifiers: u32, id: HotKeyId, target: ?*anyopaque, options: u32, out: *?*anyopaque) i32;
extern "c" fn UnregisterEventHotKey(ref: ?*anyopaque) i32;

/// Carbon's modifier bits.
pub const cmd: u32 = 1 << 8;
pub const shift: u32 = 1 << 9;
pub const option: u32 = 1 << 11;
pub const control: u32 = 1 << 12;
/// kVK_Space.
pub const space: u32 = 49;

pub const Pressed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

var pressed: ?Pressed = null;
var installed = false;
var current: ?*anyopaque = null;

fn handle(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    if (pressed) |p| p.func(p.ctx);
    return 0;
}

/// Calls `on` on the main thread each time `key` with `modifiers` is
/// pressed. One hot key per app: registering again replaces it. Carbon
/// grants it even when another app holds the same keys (`shortcut.zig`
/// looks for those).
pub fn register(key: u32, modifiers: u32, on: Pressed) !void {
    pressed = on;
    if (!installed) {
        const spec = [_]EventTypeSpec{.{ .class = fourcc("keyb"), .kind = 5 }}; // kEventHotKeyPressed
        if (InstallEventHandler(GetApplicationEventTarget(), &handle, 1, &spec, null, null) != 0) return error.HandlerFailed;
        installed = true;
    }
    if (current) |r| _ = UnregisterEventHotKey(r);
    current = null;
    if (RegisterEventHotKey(key, modifiers, .{ .signature = fourcc("nsPL"), .id = 1 }, GetApplicationEventTarget(), 0, &current) != 0) return error.HotKeyTaken;
}

/// Gives the key back (while another is recorded); `register` takes one again.
pub fn unregister() void {
    if (current) |r| _ = UnregisterEventHotKey(r);
    current = null;
}

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

test "four characters read as Carbon's codes" {
    try std.testing.expectEqual(@as(u32, 0x6B657962), fourcc("keyb"));
}
