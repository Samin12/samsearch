//! Quick Ask, SamSearch's helper, ships inside the app
//! (Contents/Helpers/Quick Ask.app): its server shows the Ask and DigUp
//! pages in the panel, and it handles the quickask:// links. SamSearch
//! starts it, in the background, when SamSearch starts. Opening an app
//! that is already running does nothing, so a second start is harmless.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const relative = "/Contents/Helpers/Quick Ask.app";

pub fn start(io: std.Io) void {
    var buf: [1024]u8 = undefined;
    const path = helperPath(&buf) orelse return;
    std.Io.Dir.cwd().access(io, path, .{}) catch return;
    // -g: in the background, nothing comes forward.
    var child = std.process.spawn(io, .{ .argv = &.{ "/usr/bin/open", "-g", path }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    const t = std.Thread.spawn(.{}, reap, .{ io, child }) catch {
        child.kill(io);
        return;
    };
    t.detach();
}

/// The bundled helper's path, from SamSearch's own bundle.
fn helperPath(buf: []u8) ?[]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const main = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    const bundle = objc.fromNSString(objc.msg(?objc.Object, main, "bundlePath", .{}));
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ bundle, relative }) catch null;
}

fn reap(io: std.Io, child: std.process.Child) void {
    var c = child;
    _ = c.wait(io) catch {};
}
