//! One Nanolight at a time. Opening its own row from the panel would ask
//! macOS to open Nanolight.app, and once the bundle on disk has been
//! replaced (an update, a reinstall) macOS takes it for another app and
//! starts a second copy: a second menu bar icon, a second hot key. So the
//! panel recognises itself (`isSelf`), and a copy that starts while others
//! run quits them (`quitOthers`): the newest launch is the newest code.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

fn ours() ?objc.Object {
    const main = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.msg(?objc.Object, main, "bundleIdentifier", .{});
}

/// Whether the app at `path` is Nanolight (any copy of it).
pub fn isSelf(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = ours() orelse return false;
    const b = objc.msg(?objc.Object, objc.class("NSBundle"), "bundleWithPath:", .{objc.nsString(path)}) orelse return false;
    const theirs = objc.msg(?objc.Object, b, "bundleIdentifier", .{}) orelse return false;
    return objc.msg(objc.BOOL, id, "isEqualToString:", .{theirs}) != objc.NO;
}

/// Asks every other running Nanolight to quit. Returns how many.
pub fn quitOthers() usize {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = ours() orelse return 0;
    const cls = objc.class("NSRunningApplication");
    const me = objc.msg(i32, objc.msg(objc.Object, cls, "currentApplication", .{}), "processIdentifier", .{});
    const apps = objc.msg(objc.Object, cls, "runningApplicationsWithBundleIdentifier:", .{id});
    var n: usize = 0;
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
        const a = objc.msg(objc.Object, apps, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (objc.msg(i32, a, "processIdentifier", .{}) == me) continue;
        _ = objc.msg(objc.BOOL, a, "terminate", .{});
        n += 1;
    }
    return n;
}

const single = @import("single.zig");
const notification = "com.samin.samsearch.command";
var listener: ?single.Listener = null;
var observer: ?objc.Object = null;

pub fn claim(on: single.Listener) usize {
    const n = quitOthers();
    listener = on;
    if (observer == null) {
        const cls = objc.defineClass(.{
            .name = "SamSearchCommands",
            .methods = &.{.{ .name = "command:", .imp = &command, .types = "v@:@" }},
        });
        observer = objc.msg(objc.Object, cls, "new", .{});
        const center = objc.msg(objc.Object, objc.class("NSDistributedNotificationCenter"), "defaultCenter", .{});
        objc.msg(void, center, "addObserver:selector:name:object:", .{ observer.?, objc.sel("command:"), objc.nsString(notification), ours() });
    }
    return n;
}

fn command(_: objc.Object, _: objc.SEL, note: objc.Object) callconv(.c) void {
    const l = listener orelse return;
    const info = objc.msg(objc.Object, note, "userInfo", .{});
    const value = objc.fromNSString(objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("command")}));
    if (std.mem.eql(u8, value, "toggle")) l.func(l.ctx, .toggle) else if (std.mem.eql(u8, value, "quit")) l.func(l.ctx, .quit);
}

pub fn send(cmd: single.Command) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = ours() orelse return false;
    const list = objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{id});
    const me = std.c.getpid();
    var other = false;
    for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        const app = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (objc.msg(i32, app, "processIdentifier", .{}) != me) other = true;
    }
    if (!other) return false;
    const info = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ objc.nsString(@tagName(cmd)), objc.nsString("command") });
    const center = objc.msg(objc.Object, objc.class("NSDistributedNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "postNotificationName:object:userInfo:deliverImmediately:", .{ objc.nsString(notification), id, info, objc.YES });
    return true;
}

test "an app that isn't Nanolight isn't taken for it" {
    try std.testing.expect(!isSelf("/System/Applications/Calculator.app"));
    try std.testing.expect(!isSelf("/nowhere/Nothing.app"));
}
