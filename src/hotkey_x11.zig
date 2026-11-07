//! Linux: the panel's key, from any app, on X11: a passive grab of Space
//! with the choice's modifiers on the root window, over an Xlib connection
//! of Nanolight's own (libX11, opened with dlopen), whose socket nanoui's
//! loop watches. Wayland has no such grab for apps: there the desktop's
//! keyboard settings run `nanolight --toggle` (`unavailable` says so).
const std = @import("std");
const nanoui = @import("nanoui");
const Choice = @import("shortcut.zig").Choice;

const Display = opaque {};
const Window = c_ulong;
/// XEvent: a union 24 longs long; `type` first.
const XEvent = extern struct { type: c_int, pad: [188]u8 = undefined };
/// XKeyEvent's `time`, after type, serial, send_event, display, window,
/// root and subwindow.
const time_offset = 7 * @sizeOf(c_long);
const ErrorHandler = *const fn (*Display, *anyopaque) callconv(.c) c_int;

const X = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) Window,
    XKeysymToKeycode: *const fn (*Display, c_ulong) callconv(.c) u8,
    XGrabKey: *const fn (*Display, c_int, c_uint, Window, c_int, c_int, c_int) callconv(.c) c_int,
    XUngrabKey: *const fn (*Display, c_int, c_uint, Window) callconv(.c) c_int,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int,
    XSync: *const fn (*Display, c_int) callconv(.c) c_int,
    XSetErrorHandler: *const fn (?ErrorHandler) callconv(.c) ?ErrorHandler,
    XSelectInput: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) c_ulong,
    XGetWindowProperty: *const fn (*Display, Window, c_ulong, c_long, c_long, c_int, c_ulong, *c_ulong, *c_int, *c_ulong, *c_ulong, *?[*]u8) callconv(.c) c_int,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
};

const shift_mask: c_uint = 1;
const lock_mask: c_uint = 2;
const control_mask: c_uint = 4;
const mod1_mask: c_uint = 8; // Alt
const mod2_mask: c_uint = 16; // Num Lock
const key_press: c_int = 2;
const property_notify: c_int = 28;
const property_change_mask: c_long = 1 << 22;
/// XPropertyEvent's `atom`, after type, serial, send_event, display and window.
const atom_offset = 5 * @sizeOf(c_long);
const xk_space: c_ulong = 0x20;

pub const Pressed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

var x: ?X = null;
var dpy: ?*Display = null;
var watch: ?nanoui.fdwatch.Watch = null;
var pressed: ?Pressed = null;
var grabbed: ?c_uint = null;
var failed = false;
/// The X server's time of the last press, for focusing the panel with it
/// (window managers refuse focus to a window shown without a recent one).
pub var last_time: u32 = 0;
/// The panel's X window, when it is shown: the window manager's word on
/// whether it is the active window (`panelActive`), and `away` called as
/// another window becomes the active one.
pub var panel: ?*const fn () Window = null;
pub var away: ?Pressed = null;
var net_active: c_ulong = 0;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// Why no key can be taken here: on Wayland, or without a display.
pub fn unavailable() ?[]const u8 {
    if (std.mem.eql(u8, env("XDG_SESSION_TYPE") orelse "", "wayland") or env("DISPLAY") == null)
        return "Wayland gives no app a key of its own: in your desktop's keyboard settings, add a shortcut that runs \"nanolight --toggle\".";
    return null;
}

fn load() ?X {
    if (x) |v| return v;
    const lib = std.c.dlopen("libX11.so.6", .{ .NOW = true }) orelse return null;
    var v: X = undefined;
    inline for (@typeInfo(X).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return null;
        @field(v, name) = @ptrCast(@alignCast(sym));
    }
    x = v;
    return v;
}

fn onError(_: *Display, _: *anyopaque) callconv(.c) c_int {
    failed = true;
    return 0;
}

fn readable(_: ?*anyopaque) callconv(.c) void {
    const xl = x orelse return;
    const d = dpy orelse return;
    while (xl.XPending(d) > 0) {
        var ev: XEvent = .{ .type = 0 };
        _ = xl.XNextEvent(d, &ev);
        if (ev.type == property_notify) {
            const bytes = std.mem.asBytes(&ev);
            const atom = std.mem.readInt(c_ulong, bytes[atom_offset..][0..@sizeOf(c_ulong)], .little);
            if (atom == net_active and panelActive() == false) if (away) |a| a.func(a.ctx);
            continue;
        }
        if (ev.type != key_press) continue;
        const bytes = std.mem.asBytes(&ev);
        last_time = @truncate(std.mem.readInt(c_ulong, bytes[time_offset..][0..@sizeOf(c_ulong)], .little));
        if (pressed) |p| p.func(p.ctx);
    }
}

/// Nanolight's own connection, opened once: its socket watched, and the
/// root window's property changes (the active window) delivered to it.
fn open(xl: X) ?*Display {
    if (dpy) |d| return d;
    const d = xl.XOpenDisplay(null) orelse return null;
    dpy = d;
    net_active = xl.XInternAtom(d, "_NET_ACTIVE_WINDOW", 0);
    _ = xl.XSelectInput(d, xl.XDefaultRootWindow(d), property_change_mask);
    watch = nanoui.fdwatch.readable(xl.XConnectionNumber(d), null, readable) catch null;
    return d;
}

/// Whether the window manager has the panel as its active window; null
/// when that can't be known (no X, no panel window, a window manager
/// without _NET_ACTIVE_WINDOW). GTK can't say while the hot key is held:
/// the key's grab takes the keyboard's focus from it until it is let go.
pub fn panelActive() ?bool {
    const xl = x orelse return null;
    const d = dpy orelse return null;
    const f = panel orelse return null;
    const ours = f();
    if (ours == 0) return null;
    var kind: c_ulong = 0;
    var format: c_int = 0;
    var n: c_ulong = 0;
    var left: c_ulong = 0;
    var data: ?[*]u8 = null;
    // XA_WINDOW is 33.
    if (xl.XGetWindowProperty(d, xl.XDefaultRootWindow(d), net_active, 0, 1, 0, 33, &kind, &format, &n, &left, &data) != 0) return null;
    defer _ = xl.XFree(data);
    const bytes = data orelse return null;
    if (n == 0 or format != 32) return null;
    const active = std.mem.readInt(c_ulong, bytes[0..@sizeOf(c_ulong)], .little);
    return active == ours;
}

pub fn modifiers(choice: Choice) c_uint {
    const p = choice.pc();
    var m: c_uint = 0;
    if (p.ctrl) m |= control_mask;
    if (p.alt) m |= mod1_mask;
    if (p.shift) m |= shift_mask;
    return m;
}

pub fn register(choice: Choice, on: Pressed) !void {
    if (unavailable() != null) return error.Wayland;
    const xl = load() orelse return error.NoX11;
    const d = open(xl) orelse return error.NoDisplay;
    const root = xl.XDefaultRootWindow(d);
    const code: c_int = xl.XKeysymToKeycode(d, xk_space);
    // Caps Lock and Num Lock are modifiers too: grab with each.
    const extra = [_]c_uint{ 0, lock_mask, mod2_mask, lock_mask | mod2_mask };
    const m = modifiers(choice);
    if (grabbed == m) {
        pressed = on;
        return;
    }
    // Another client holding the key answers BadAccess, asynchronously:
    // caught here, with GDK's handler put back after.
    failed = false;
    const before = xl.XSetErrorHandler(&onError);
    for (extra) |e| _ = xl.XGrabKey(d, code, m | e, root, 0, 1, 1);
    _ = xl.XSync(d, 0);
    _ = xl.XSetErrorHandler(before);
    if (failed) {
        for (extra) |e| _ = xl.XUngrabKey(d, code, m | e, root);
        _ = xl.XSync(d, 0);
        return error.HotKeyTaken;
    }
    if (grabbed) |old| for (extra) |e| {
        _ = xl.XUngrabKey(d, code, old | e, root);
    };
    grabbed = m;
    pressed = on;
}

/// Whether another client (the window manager: Alt Space is its window
/// menu on many desktops) holds `choice`: grabbed and let go again.
pub fn taken(choice: Choice) bool {
    if (unavailable() != null) return false;
    const m = modifiers(choice);
    if (grabbed == m) return false;
    const xl = load() orelse return false;
    const d = open(xl) orelse return false;
    const root = xl.XDefaultRootWindow(d);
    const code: c_int = xl.XKeysymToKeycode(d, xk_space);
    failed = false;
    const before = xl.XSetErrorHandler(&onError);
    _ = xl.XGrabKey(d, code, m, root, 0, 1, 1);
    _ = xl.XSync(d, 0);
    _ = xl.XSetErrorHandler(before);
    const held = failed;
    if (!held) _ = xl.XUngrabKey(d, code, m, root);
    _ = xl.XSync(d, 0);
    return held;
}

test "the choices' modifiers" {
    try std.testing.expectEqual(mod1_mask, modifiers(.cmd_space));
    try std.testing.expectEqual(control_mask | shift_mask, modifiers(.opt_cmd_space));
}

pub fn unregister() void {
    const m = grabbed orelse return;
    const xl = x orelse return;
    const d = dpy orelse return;
    const code: c_int = xl.XKeysymToKeycode(d, xk_space);
    for ([_]c_uint{ 0, lock_mask, mod2_mask, lock_mask | mod2_mask }) |e|
        _ = xl.XUngrabKey(d, code, m | e, xl.XDefaultRootWindow(d));
    _ = xl.XSync(d, 0);
    grabbed = null;
}
