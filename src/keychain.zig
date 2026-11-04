//! A secret kept by the system: the Codegraff key Nanolight signs in with
//! (account.zig). The login Keychain on the Mac (keychain_mac.zig), the
//! Credential Manager on Windows; on Linux a file only its owner can read
//! (`~/.local/share/Nanolight/secret-<service>-<account>`, mode 0600), as
//! command-line tools keep their tokens, since a Secret Service isn't on
//! every desktop.
const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("keychain_mac.zig"),
    .windows => Windows,
    else => File,
};

/// The secret, copied with `gpa`, or null when there is none.
pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ?[]u8 {
    return impl.get(gpa, service, account);
}

/// Keeps `secret`, in place of one kept before.
pub fn set(service: []const u8, account: []const u8, secret: []const u8) bool {
    return impl.set(service, account, secret);
}

pub fn remove(service: []const u8, account: []const u8) void {
    impl.remove(service, account);
}

const Windows = struct {
    const FILETIME = extern struct { lo: u32 = 0, hi: u32 = 0 };
    const CREDENTIALW = extern struct {
        Flags: u32 = 0,
        Type: u32 = cred_type_generic,
        TargetName: ?[*:0]u16 = null,
        Comment: ?[*:0]u16 = null,
        LastWritten: FILETIME = .{},
        CredentialBlobSize: u32 = 0,
        CredentialBlob: ?[*]u8 = null,
        Persist: u32 = cred_persist_local_machine,
        AttributeCount: u32 = 0,
        Attributes: ?*anyopaque = null,
        TargetAlias: ?[*:0]u16 = null,
        UserName: ?[*:0]u16 = null,
    };
    const cred_type_generic: u32 = 1;
    const cred_persist_local_machine: u32 = 2;
    extern "advapi32" fn CredWriteW(cred: *const CREDENTIALW, flags: u32) callconv(.winapi) i32;
    extern "advapi32" fn CredReadW(target: [*:0]const u16, kind: u32, flags: u32, out: *?*CREDENTIALW) callconv(.winapi) i32;
    extern "advapi32" fn CredDeleteW(target: [*:0]const u16, kind: u32, flags: u32) callconv(.winapi) i32;
    extern "advapi32" fn CredFree(buf: ?*anyopaque) callconv(.winapi) void;

    /// "service/account", as UTF-16.
    fn target(buf: *[512:0]u16, service: []const u8, account: []const u8) ?[*:0]u16 {
        var utf8: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&utf8, "{s}/{s}", .{ service, account }) catch return null;
        const n = std.unicode.utf8ToUtf16Le(buf[0..511], name) catch return null;
        buf[n] = 0;
        return buf[0..n :0].ptr;
    }

    fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ?[]u8 {
        var buf: [512:0]u16 = undefined;
        const t = target(&buf, service, account) orelse return null;
        var out: ?*CREDENTIALW = null;
        if (CredReadW(t, cred_type_generic, 0, &out) == 0) return null;
        const cred = out orelse return null;
        defer CredFree(cred);
        const blob = cred.CredentialBlob orelse return null;
        return gpa.dupe(u8, blob[0..cred.CredentialBlobSize]) catch null;
    }

    fn set(service: []const u8, account: []const u8, secret: []const u8) bool {
        var buf: [512:0]u16 = undefined;
        const t = target(&buf, service, account) orelse return false;
        const cred: CREDENTIALW = .{ .TargetName = t, .CredentialBlobSize = @intCast(secret.len), .CredentialBlob = @constCast(secret.ptr) };
        return CredWriteW(&cred, 0) != 0;
    }

    fn remove(service: []const u8, account: []const u8) void {
        var buf: [512:0]u16 = undefined;
        const t = target(&buf, service, account) orelse return;
        _ = CredDeleteW(t, cred_type_generic, 0);
    }
};

const File = struct {
    const nanoui = @import("nanoui");

    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    fn path(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ?[]u8 {
        const dir = nanoui.path(gpa, .data, "SamSearch") catch return null;
        defer gpa.free(dir);
        var name: [256]u8 = undefined;
        const base = std.fmt.bufPrint(&name, "secret-{s}-{s}", .{ service, account }) catch return null;
        for (base) |*ch| if (ch.* == '/' or ch.* == '\\') {
            ch.* = '_';
        };
        return std.fs.path.join(gpa, &.{ dir, base }) catch null;
    }

    fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ?[]u8 {
        const p = path(gpa, service, account) orelse return null;
        defer gpa.free(p);
        return std.Io.Dir.cwd().readFileAlloc(io(), p, gpa, .limited(64 << 10)) catch null;
    }

    fn set(service: []const u8, account: []const u8, secret: []const u8) bool {
        const gpa = std.heap.page_allocator;
        const p = path(gpa, service, account) orelse return false;
        defer gpa.free(p);
        const z = gpa.dupeSentinel(u8, p, 0) catch return false;
        defer gpa.free(z);
        // Made with no one else's permissions before the secret goes in.
        const fd = std.c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return false;
        defer _ = std.c.close(fd);
        _ = std.c.fchmod(fd, 0o600);
        return std.c.write(fd, secret.ptr, secret.len) == secret.len;
    }

    fn remove(service: []const u8, account: []const u8) void {
        const gpa = std.heap.page_allocator;
        const p = path(gpa, service, account) orelse return;
        defer gpa.free(p);
        std.Io.Dir.cwd().deleteFile(io(), p) catch {};
    }
};
