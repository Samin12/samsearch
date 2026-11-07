//! Windows: the panel's key, from any app (RegisterHotKey). The system
//! sends WM_HOTKEY to Nanolight's message window (win_msg.zig); pressing it
//! also lets Nanolight bring its window to the front.
const std = @import("std");
const Choice = @import("shortcut.zig").Choice;
const msg = @import("win_msg.zig");

extern "user32" fn RegisterHotKey(hwnd: ?msg.HWND, id: i32, mods: u32, vk: u32) callconv(.winapi) i32;
extern "user32" fn UnregisterHotKey(hwnd: ?msg.HWND, id: i32) callconv(.winapi) i32;

const mod_alt: u32 = 0x1;
const mod_control: u32 = 0x2;
const mod_shift: u32 = 0x4;
const mod_norepeat: u32 = 0x4000;
const vk_space: u32 = 0x20;
var id: i32 = 1;

pub const Pressed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

var pressed: ?Pressed = null;
var registered = false;
var current: u32 = 0;

fn hot(_: *anyopaque, _: u32) void {
    if (pressed) |p| p.func(p.ctx);
}

pub fn modifiers(choice: Choice) u32 {
    const p = choice.pc();
    var m: u32 = mod_norepeat;
    if (p.ctrl) m |= mod_control;
    if (p.alt) m |= mod_alt;
    if (p.shift) m |= mod_shift;
    return m;
}

pub fn register(choice: Choice, on: Pressed) !void {
    const h = msg.window() orelse return error.NoWindow;
    const mods = modifiers(choice);
    if (registered and current == mods) {
        pressed = on;
        return;
    }
    const next: i32 = if (id == 1) 2 else 1;
    if (RegisterHotKey(h, next, mods, vk_space) == 0) return error.HotKeyTaken;
    if (registered) _ = UnregisterHotKey(h, id);
    id = next;
    registered = true;
    current = mods;
    pressed = on;
    msg.on_hotkey = .{ .ctx = h, .func = hot };
}

/// Whether another app holds `choice`: registered and let go again.
pub fn taken(choice: Choice) bool {
    const m = modifiers(choice);
    if (registered and m == current) return false;
    const h = msg.window() orelse return false;
    if (RegisterHotKey(h, 3, m, vk_space) == 0) return true;
    _ = UnregisterHotKey(h, 3);
    return false;
}

test "the choices' modifiers" {
    try std.testing.expectEqual(mod_alt | mod_norepeat, modifiers(.cmd_space));
    try std.testing.expectEqual(mod_control | mod_shift | mod_norepeat, modifiers(.opt_cmd_space));
}

pub fn unregister() void {
    const h = msg.window() orelse return;
    if (registered) _ = UnregisterHotKey(h, id);
    registered = false;
}
