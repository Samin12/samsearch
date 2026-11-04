//! Opening at login. Mac: the system's login items (SMAppService, macOS 13
//! and later), which need the app to run from its bundle. Windows: a value
//! under HKCU's Run key. Linux: an XDG autostart entry
//! (~/.config/autostart/nanolight.desktop). `set` null only asks.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

pub fn login(set: ?bool) bool {
    return switch (builtin.os.tag) {
        .macos => Mac.login(set),
        .windows => Windows.login(set),
        else => Linux.login(set),
    };
}

const Mac = struct {
    const objc = nanoui.objc;
    extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

    fn login(set: ?bool) bool {
        const cls = objc_getClass("SMAppService") orelse return false;
        const svc = objc.msg(objc.Object, cls, "mainAppService", .{});
        if (set) |on| _ = objc.msg(objc.BOOL, svc, if (on) "registerAndReturnError:" else "unregisterAndReturnError:", .{@as(?*anyopaque, null)});
        return objc.msg(objc.NSInteger, svc, "status", .{}) == 1; // enabled
    }
};

const Windows = struct {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const hkcu: *anyopaque = @ptrFromInt(0x80000001);
    const run_key = L("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    const value = L("SamSearch");
    const reg_sz: u32 = 1;
    const rrf_rt_reg_sz: u32 = 2;
    extern "advapi32" fn RegSetKeyValueW(key: *anyopaque, sub: [*:0]const u16, name: [*:0]const u16, kind: u32, data: ?*const anyopaque, size: u32) callconv(.winapi) i32;
    extern "advapi32" fn RegGetValueW(key: *anyopaque, sub: [*:0]const u16, name: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegDeleteKeyValueW(key: *anyopaque, sub: [*:0]const u16, name: [*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) callconv(.winapi) u32;

    fn login(set: ?bool) bool {
        if (set) |on| {
            if (on) {
                // "C:\...\nanolight.exe", quoted for the spaces in paths.
                var cmd: [1100]u16 = undefined;
                cmd[0] = '"';
                const n = GetModuleFileNameW(null, cmd[1..1025].ptr, 1024);
                if (n == 0 or n >= 1024) return false;
                cmd[n + 1] = '"';
                cmd[n + 2] = 0;
                _ = RegSetKeyValueW(hkcu, run_key, value, reg_sz, &cmd, @intCast((n + 3) * 2));
            } else _ = RegDeleteKeyValueW(hkcu, run_key, value);
        }
        return RegGetValueW(hkcu, run_key, value, rrf_rt_reg_sz, null, null, null) == 0;
    }
};

const Linux = struct {
    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    fn entryPath(buf: []u8) ?[]const u8 {
        if (std.c.getenv("XDG_CONFIG_HOME")) |d| return std.fmt.bufPrint(buf, "{s}/autostart/nanolight.desktop", .{std.mem.span(d)}) catch null;
        const home = std.c.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.config/autostart/nanolight.desktop", .{std.mem.span(home)}) catch null;
    }

    fn login(set: ?bool) bool {
        var buf: [1024]u8 = undefined;
        const path = entryPath(&buf) orelse return false;
        const cwd = std.Io.Dir.cwd();
        if (set) |on| {
            if (on) {
                var exe: [1024]u8 = undefined;
                const n = std.c.readlink("/proc/self/exe", &exe, exe.len);
                if (n <= 0) return false;
                var entry: [2048]u8 = undefined;
                const text = std.fmt.bufPrint(&entry, "[Desktop Entry]\nType=Application\nName=SamSearch\nComment=A launcher, on Alt Space\nExec=\"{s}\"\nIcon=nanolight\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n", .{exe[0..@intCast(n)]}) catch return false;
                if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io(), dir) catch {};
                cwd.writeFile(io(), .{ .sub_path = path, .data = text }) catch return false;
            } else cwd.deleteFile(io(), path) catch {};
        }
        cwd.access(io(), path, .{}) catch return false;
        return true;
    }
};
