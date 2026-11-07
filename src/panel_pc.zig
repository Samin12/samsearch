//! The panel's window on Windows and Linux: borderless, over other windows,
//! out of the taskbar, exactly the panel's size (it follows the panel's
//! height). nanoui draws the panel on it; there is no system vibrancy
//! under it, so the panel paints its own fill. The window is transparent
//! (nanoui's `transparent`): only the rounded panel shows, nothing square
//! behind its corners.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const view = @import("view.zig");
const windows = builtin.os.tag == .windows;

pub fn adjust(o: *nanoui.WindowOptions, _: bool, h: f32) void {
    o.width = view.width;
    o.height = h;
    o.decorations = false;
    o.skip_taskbar = true;
    o.always_on_top = true;
    o.transparent = true;
}

pub fn setup(_: *nanoui.App, w: *nanoui.Window, s: *view.Nanolight, _: f32) void {
    s.margin = 0;
    if (windows) return;
    // X11: the window manager says which window is active (GTK can't
    // while the hot key's grab holds the keyboard), and when another one
    // becomes it, the panel goes, as the Mac's popover does.
    window = w;
    const x11 = @import("hotkey_x11.zig");
    x11.panel = xid;
    x11.away = .{ .ctx = w, .func = hideAway };
}

/// Whether the panel has the keys: on X11 by the window manager's word.
pub fn focused(w: *nanoui.Window) bool {
    if (!windows) if (@import("hotkey_x11.zig").panelActive()) |active| return active;
    return w.isFocused();
}

var window: ?*nanoui.Window = null;
pub var on_hide: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null;

fn hideAway(ctx: *anyopaque) void {
    _ = ctx;
    if (on_hide) |h| h.func(h.ctx);
}

/// The panel's X window (0 before it is first shown, or off X11).
fn xid() c_ulong {
    if (windows) return 0;
    const w = window orelse return 0;
    const win = w.gtkwindow orelse return 0;
    const gtk = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .NOLOAD = true }) orelse return 0;
    const gdk = std.c.dlopen("libgdk-3.so.0", .{ .NOW = true, .NOLOAD = true }) orelse return 0;
    const get_window: *const fn (*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(gtk, "gtk_widget_get_window") orelse return 0));
    const get_xid: *const fn (*anyopaque) callconv(.c) c_ulong = @ptrCast(@alignCast(std.c.dlsym(gdk, "gdk_x11_window_get_xid") orelse return 0));
    const gw = get_window(@ptrCast(win)) orelse return 0;
    return get_xid(gw);
}

/// A fifth of the way down the screen, centered.
pub fn place(w: *nanoui.Window) void {
    const m = w.monitorSize();
    // A fifth of the way down, but high enough that the panel at its
    // tallest (a command's screen) stays on a small screen.
    w.setPosition(@max(0, (m[0] - view.width) / 2), @max(0, @min(m[1] * 0.2, m[1] - view.max_height - 16)));
    // X11: the panel's user time is the hot key's, set before it maps, so a
    // window manager that prevents focus stealing (Xfce, KDE) lets it take
    // the keys from the window that had them.
    if (windows) return;
    const t = @import("hotkey_x11.zig").last_time;
    if (t == 0) return;
    const win = w.gtkwindow orelse return;
    const gtk = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .NOLOAD = true }) orelse return;
    const gdk = std.c.dlopen("libgdk-3.so.0", .{ .NOW = true, .NOLOAD = true }) orelse return;
    const get_window: *const fn (*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(gtk, "gtk_widget_get_window") orelse return));
    const set_time: *const fn (*anyopaque, u32) callconv(.c) void = @ptrCast(@alignCast(std.c.dlsym(gdk, "gdk_x11_window_set_user_time") orelse return));
    const gw = get_window(@ptrCast(win)) orelse return;
    set_time(gw, t);
}

pub fn resize(w: *nanoui.Window, h: f32) void {
    w.setSize(view.width, @ceil(h));
}

/// After `show`: on X11 the window manager is given the hot key's time, or
/// it may refuse the panel the focus (focus stealing prevention).
pub fn shown(w: *nanoui.Window) void {
    if (windows) return;
    const t = @import("hotkey_x11.zig").last_time;
    if (t == 0) return;
    const win = w.gtkwindow orelse return;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .NOLOAD = true }) orelse return;
    const f = std.c.dlsym(lib, "gtk_window_present_with_time") orelse return;
    const present: *const fn (*anyopaque, u32) callconv(.c) void = @ptrCast(@alignCast(f));
    present(@ptrCast(win), t);
}
