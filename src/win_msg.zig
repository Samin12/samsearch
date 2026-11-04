//! Windows: Nanolight's message-only window, where the system sends the
//! hot key (WM_HOTKEY, hotkey_win.zig) and a second copy sends its command
//! (`nanolight --toggle`, a newer copy asking this one to quit: single.zig).
//! nanoui's message loop dispatches to it like to any window of the thread.
const std = @import("std");

pub const HWND = *opaque {};
const HINSTANCE = ?*anyopaque;
const WNDPROC = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, name: ?[*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn FindWindowExW(parent: ?HWND, after: ?HWND, class: [*:0]const u16, name: ?[*:0]const u16) callconv(.winapi) ?HWND;
extern "user32" fn PostMessageW(?HWND, u32, usize, isize) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HINSTANCE;

pub const wm_hotkey: u32 = 0x0312;
/// WM_APP + n: a second copy's commands.
pub const wm_toggle: u32 = 0x8001;
pub const wm_quit: u32 = 0x8002;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("SamSearchMessages");
/// HWND_MESSAGE: the parent of message-only windows.
const message_parent: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

pub const Handler = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, msg: u32) void };

var hwnd: ?HWND = null;
/// The hot key's callback, and the commands'.
pub var on_hotkey: ?Handler = null;
pub var on_command: ?Handler = null;

fn proc(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    const handler = switch (msg) {
        wm_hotkey => on_hotkey,
        wm_toggle, wm_quit => on_command,
        else => return DefWindowProcW(h, msg, wp, lp),
    };
    if (handler) |hd| hd.func(hd.ctx, msg);
    return 0;
}

/// Ours, made the first time it is asked for.
pub fn window() ?HWND {
    if (hwnd) |h| return h;
    const inst = GetModuleHandleW(null);
    _ = RegisterClassExW(&.{ .lpfnWndProc = &proc, .hInstance = inst, .lpszClassName = class_name });
    hwnd = CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, message_parent, null, inst, null);
    return hwnd;
}

/// Another running copy's window (call before making ours).
pub fn other() ?HWND {
    return FindWindowExW(message_parent, null, class_name, null);
}

pub fn post(to: HWND, msg: u32) bool {
    return PostMessageW(to, msg, 0, 0) != 0;
}
