//! A secret kept in the login Keychain: the Codegraff key Nanolight signs
//! in with (account.zig). A generic password, by service and account; the
//! queries are NSDictionaries, which the Security framework takes as the
//! CFDictionaries they are.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const CFRef = *anyopaque;
extern const kSecClass: CFRef;
extern const kSecClassGenericPassword: CFRef;
extern const kSecAttrService: CFRef;
extern const kSecAttrAccount: CFRef;
extern const kSecValueData: CFRef;
extern const kSecReturnData: CFRef;
extern const kSecMatchLimit: CFRef;
extern const kSecMatchLimitOne: CFRef;
extern const kSecAttrAccessible: CFRef;
extern const kSecAttrAccessibleAfterFirstUnlock: CFRef;
extern fn SecItemCopyMatching(query: CFRef, result: *?CFRef) i32;
extern fn SecItemAdd(attributes: CFRef, result: ?*?CFRef) i32;
extern fn SecItemUpdate(query: CFRef, changes: CFRef) i32;
extern fn SecItemDelete(query: CFRef) i32;
extern fn CFRelease(ref: CFRef) void;

const err_not_found: i32 = -25300;

fn obj(r: CFRef) objc.Object {
    return @ptrCast(r);
}

fn dict(keys: []const objc.Object, values: []const objc.Object) objc.Object {
    return objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ values.ptr, keys.ptr, @as(objc.NSUInteger, keys.len) });
}

fn query(service: []const u8, account: []const u8, extra_keys: []const objc.Object, extra_values: []const objc.Object) objc.Object {
    var k: [8]objc.Object = undefined;
    var v: [8]objc.Object = undefined;
    k[0] = obj(kSecClass);
    v[0] = obj(kSecClassGenericPassword);
    k[1] = obj(kSecAttrService);
    v[1] = objc.nsString(service);
    k[2] = obj(kSecAttrAccount);
    v[2] = objc.nsString(account);
    for (extra_keys, extra_values, 0..) |ek, ev, i| {
        k[3 + i] = ek;
        v[3 + i] = ev;
    }
    const n = 3 + extra_keys.len;
    return dict(k[0..n], v[0..n]);
}

fn data(bytes: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) });
}

/// The secret, copied with `gpa`, or null when there is none.
pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    const q = query(service, account, &.{ obj(kSecReturnData), obj(kSecMatchLimit) }, &.{ yes, obj(kSecMatchLimitOne) });
    var out: ?CFRef = null;
    if (SecItemCopyMatching(@ptrCast(q), &out) != 0) return null;
    const d = out orelse return null;
    defer CFRelease(d);
    const len = objc.msg(objc.NSUInteger, obj(d), "length", .{});
    const bytes = objc.msg(?[*]const u8, obj(d), "bytes", .{}) orelse return null;
    return gpa.dupe(u8, bytes[0..len]) catch null;
}

/// Keeps `secret`, in place of one kept before. Readable once the Mac has
/// been unlocked since it started, by this app.
pub fn set(service: []const u8, account: []const u8, secret: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const changes = dict(&.{obj(kSecValueData)}, &.{data(secret)});
    const updated = SecItemUpdate(@ptrCast(query(service, account, &.{}, &.{})), @ptrCast(changes));
    if (updated == 0) return true;
    if (updated != err_not_found) return false;
    const add = query(service, account, &.{ obj(kSecValueData), obj(kSecAttrAccessible) }, &.{ data(secret), obj(kSecAttrAccessibleAfterFirstUnlock) });
    return SecItemAdd(@ptrCast(add), null) == 0;
}

pub fn remove(service: []const u8, account: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const status = SecItemDelete(@ptrCast(query(service, account, &.{}, &.{})));
    return status == 0 or status == err_not_found;
}
