//! The key combination that opens the panel from any app: Carbon's hot keys
//! on the Mac (hotkey_mac.zig), RegisterHotKey on Windows (hotkey_win.zig),
//! a key grab on X11 (hotkey_x11.zig). Wayland lets no app take a key for
//! the whole desktop: there the desktop's own shortcut settings run
//! `nanolight --toggle` (single.zig).
const builtin = @import("builtin");
const Choice = @import("shortcut.zig").Choice;

const impl = switch (builtin.os.tag) {
    .macos => @import("hotkey_mac.zig"),
    .windows => @import("hotkey_win.zig"),
    else => @import("hotkey_x11.zig"),
};

/// The Mac's key codes and Carbon's modifier bits, which `Choice` keeps
/// everywhere (a PC reads its four presets from them, shortcut.zig).
pub const cmd = keys.cmd;
pub const shift = keys.shift;
pub const option = keys.option;
pub const control = keys.control;
pub const space = keys.space;
const keys = @import("hotkey_mac.zig");

pub const Pressed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

/// Calls `on` on the main thread each time `choice` is pressed, from any
/// app. One per app: registering again replaces it.
pub fn register(choice: Choice, on: Pressed) !void {
    return impl.register(choice, .{ .ctx = on.ctx, .func = on.func });
}

/// Gives the key back (while another is recorded); `register` takes one again.
pub fn unregister() void {
    if (@hasDecl(impl, "unregister")) impl.unregister();
}

/// Whether another program holds `choice` (Windows, X11; on the Mac the
/// system's shortcut table says, shortcut.zig).
pub fn taken(choice: Choice) bool {
    return if (@hasDecl(impl, "taken")) impl.taken(choice) else false;
}

/// Why no key can be taken here, for the welcome and Settings to say: null
/// when one can.
pub fn unavailable() ?[]const u8 {
    return if (@hasDecl(impl, "unavailable")) impl.unavailable() else null;
}

/// Acquire before releasing, so a failed replacement keeps the working handle.
pub fn replace(comptime Backend: type, backend: Backend, old: ?Backend.Handle) !Backend.Handle {
    const next = try backend.acquire();
    if (old) |handle| backend.release(handle);
    return next;
}
