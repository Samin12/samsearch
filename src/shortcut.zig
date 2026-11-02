//! Which key combination opens the panel, kept in the app's defaults, and
//! who else may answer it. Carbon grants a hot key even when another app
//! holds the same one, so clashes are found here instead: in the system's
//! own shortcuts (Spotlight's ⌘Space, the input sources' ⌃Space) and among
//! the launchers that are running.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const hotkey = @import("hotkey.zig");
const mac = builtin.os.tag == .macos;
const objc = nanoui.objc;

/// The keys that open the panel: one key, by where it is on the keyboard
/// (macOS's virtual key code, which Carbon takes, whatever the layout),
/// and modifiers. Four are offered; any other can be recorded in Settings.
pub const Choice = struct {
    code: u32 = hotkey.space,
    /// Carbon's modifier bits.
    mods: u32 = hotkey.cmd,
    /// What the key types, for its name (a recorded key's; 0: by its code).
    ch: u21 = 0,

    pub const cmd_space: Choice = .{ .mods = hotkey.cmd };
    pub const opt_space: Choice = .{ .mods = hotkey.option };
    pub const ctrl_space: Choice = .{ .mods = hotkey.control };
    pub const opt_cmd_space: Choice = .{ .mods = hotkey.option | hotkey.cmd };

    pub const all = [_]Choice{ cmd_space, opt_space, ctrl_space, opt_cmd_space };
    /// The names the offered ones are kept and synced by (as before).
    const names = [_][]const u8{ "cmd_space", "opt_space", "ctrl_space", "opt_cmd_space" };

    pub fn eql(a: Choice, b: Choice) bool {
        return a.code == b.code and a.mods == b.mods;
    }

    /// Which of `all` it is; null for a recorded key.
    pub fn preset(c: Choice) ?usize {
        for (all, 0..) |p, i| if (p.eql(c)) return i;
        return null;
    }

    /// The offered one before or after it (from a recorded key: the last
    /// or the first).
    pub fn step(c: Choice, dir: i8) Choice {
        const i = c.preset() orelse return all[if (dir < 0) all.len - 1 else 0];
        return all[if (dir < 0) (i + all.len - 1) % all.len else (i + 1) % all.len];
    }

    /// "⌥ ⌘ Space", "⌥ X": the modifiers, then the key.
    pub fn format(c: Choice, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (glyphs) |g| if (c.mods & g[0] != 0) try w.print("{s} ", .{g[1]});
        try w.print("{f}", .{c.key()});
    }

    /// The modifiers' glyphs alone, for a key cap: "⌥⌘".
    pub fn held(c: Choice) Mods {
        return .{ .mods = c.mods };
    }

    /// The key alone, for a key cap: "Space", "X".
    pub fn key(c: Choice) Key {
        return .{ .code = c.code, .ch = c.ch };
    }

    /// AppKit's modifier flags, as the system's shortcut table keeps them.
    pub fn appkit(c: Choice) u64 {
        var f: u64 = 0;
        if (c.mods & hotkey.cmd != 0) f |= ns_cmd;
        if (c.mods & hotkey.option != 0) f |= ns_opt;
        if (c.mods & hotkey.control != 0) f |= ns_ctrl;
        if (c.mods & hotkey.shift != 0) f |= ns_shift;
        return f;
    }

    /// Fit to open the panel: with ⌘, ⌥ or ⌃ (Shift alone would take a
    /// letter from typing everywhere), or a function key by itself.
    pub fn usable(c: Choice) bool {
        if (c.code > 127 or c.mods & ~all_mods != 0) return false;
        return c.mods & (hotkey.cmd | hotkey.option | hotkey.control) != 0 or isFunction(c.code);
    }

    /// How it is kept and synced: an offered one's name, else
    /// "key:<code>:<mods>:<char>" (older versions ignore it).
    pub fn name(c: Choice, buf: *[32]u8) []const u8 {
        if (c.preset()) |i| return names[i];
        return std.fmt.bufPrint(buf, "key:{d}:{d}:{d}", .{ c.code, c.mods, c.ch }) catch names[0];
    }

    pub fn parse(s: []const u8) ?Choice {
        for (names, all) |n, p| if (std.mem.eql(u8, s, n)) return p;
        if (!std.mem.startsWith(u8, s, "key:")) return null;
        var it = std.mem.splitScalar(u8, s[4..], ':');
        const c: Choice = .{
            .code = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null,
            .mods = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null,
            .ch = std.fmt.parseInt(u21, it.next() orelse return null, 10) catch return null,
        };
        return if (it.next() == null and c.usable()) c else null;
    }
};

const all_mods = hotkey.cmd | hotkey.shift | hotkey.option | hotkey.control;
/// In the order macOS draws them.
const glyphs = [_]struct { u32, []const u8 }{
    .{ hotkey.control, "⌃" }, .{ hotkey.option, "⌥" }, .{ hotkey.shift, "⇧" }, .{ hotkey.cmd, "⌘" },
};

pub const Mods = struct {
    mods: u32,

    pub fn format(m: Mods, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (glyphs) |g| if (m.mods & g[0] != 0) try w.writeAll(g[1]);
    }
};

/// Keys that type nothing, by their codes (kVK_*); F1 to F20 first.
const named = [_]struct { u32, []const u8 }{
    .{ 122, "F1" },  .{ 120, "F2" },  .{ 99, "F3" },   .{ 118, "F4" },  .{ 96, "F5" },
    .{ 97, "F6" },   .{ 98, "F7" },   .{ 100, "F8" },  .{ 101, "F9" },  .{ 109, "F10" },
    .{ 103, "F11" }, .{ 111, "F12" }, .{ 105, "F13" }, .{ 107, "F14" }, .{ 113, "F15" },
    .{ 106, "F16" }, .{ 64, "F17" },  .{ 79, "F18" },  .{ 80, "F19" },  .{ 90, "F20" },
    .{ 49, "Space" }, .{ 36, "↩" },   .{ 76, "⌤" },    .{ 48, "⇥" },    .{ 51, "⌫" },
    .{ 117, "⌦" },   .{ 53, "⎋" },    .{ 123, "←" },   .{ 124, "→" },   .{ 125, "↓" },
    .{ 126, "↑" },   .{ 115, "↖" },   .{ 119, "↘" },   .{ 116, "⇞" },   .{ 121, "⇟" },
};

fn isFunction(code: u32) bool {
    for (named[0..20]) |n| if (n[0] == code) return true;
    return false;
}

pub const Key = struct {
    code: u32,
    ch: u21,

    pub fn format(k: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (named) |n| if (n[0] == k.code) return w.writeAll(n[1]);
        if (k.ch > 0x20 and k.ch != 0x7f) {
            const up: u21 = if (k.ch < 128) std.ascii.toUpper(@intCast(k.ch)) else k.ch;
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(up, &b) catch return w.print("Key {d}", .{k.code});
            return w.writeAll(b[0..n]);
        }
        try w.print("Key {d}", .{k.code});
    }
};

/// A key pressed while Settings records one (recorder.zig).
pub const Recorded = union(enum) {
    key: Choice,
    /// Esc by itself: recording stops, the key stays as it was.
    cancel,
    /// Not fit to open the panel (`Choice.usable`): it waits for another.
    unusable,
};

/// The key event's code, AppKit's modifier flags and the character the
/// key types without modifiers, as a recorded key.
pub fn recorded(code: u16, flags: u64, ch: u21) Recorded {
    var mods: u32 = 0;
    if (flags & ns_cmd != 0) mods |= hotkey.cmd;
    if (flags & ns_opt != 0) mods |= hotkey.option;
    if (flags & ns_ctrl != 0) mods |= hotkey.control;
    if (flags & ns_shift != 0) mods |= hotkey.shift;
    if (code == 53 and mods == 0) return .cancel;
    const c: Choice = .{ .code = code, .mods = mods, .ch = if (ch > 0x20 and ch != 0x7f and ch < 0xF700) ch else 0 };
    return if (c.usable()) .{ .key = c } else .unusable;
}

const ns_shift: u64 = 1 << 17;
const ns_ctrl: u64 = 1 << 18;
const ns_opt: u64 = 1 << 19;
const ns_cmd: u64 = 1 << 20;
const ns_mods: u64 = ns_shift | ns_ctrl | ns_opt | ns_cmd;
const store_key = "nanolight.hotkey";
const onboarded_key = "nanolight.onboarded";

pub fn load(store: nanoui.kv.Store, gpa: std.mem.Allocator) Choice {
    const v = (store.get(gpa, store_key) catch null) orelse return .cmd_space;
    defer gpa.free(v);
    return Choice.parse(v) orelse .cmd_space;
}

pub fn save(store: nanoui.kv.Store, c: Choice) void {
    var buf: [32]u8 = undefined;
    store.set(store_key, c.name(&buf)) catch {};
}

pub fn onboarded(store: nanoui.kv.Store) bool {
    return store.has(onboarded_key);
}

pub fn setOnboarded(store: nanoui.kv.Store) void {
    store.set(onboarded_key, "1") catch {};
}

/// One of the system's shortcuts, as `com.apple.symbolichotkeys` keeps it.
pub const SystemKey = struct { id: u32, enabled: bool, key: u32, mods: u64 };

/// The launchers that are running, by name.
pub const Others = struct {
    names: [6][]const u8 = undefined,
    n: usize = 0,

    pub fn slice(o: *const Others) []const []const u8 {
        return o.names[0..o.n];
    }
};

/// What is in the way of a choice: a system shortcut that takes it first,
/// and launchers that may be using it too.
pub const Clash = struct {
    /// "Spotlight", "Input sources"…, when the system takes it.
    system: ?[]const u8 = null,
    /// The system's shortcut id (Keyboard Shortcuts in System Settings).
    system_id: u32 = 0,
    launchers: []const []const u8 = &.{},

    pub fn clear(c: Clash) bool {
        return c.system == null and c.launchers.len == 0;
    }
};

fn systemName(id: u32) []const u8 {
    return switch (id) {
        64 => "Spotlight",
        65 => "Finder's search window",
        60, 61 => "the input source switcher",
        else => "a macOS shortcut",
    };
}

/// The clash for `c`, from the system's shortcuts and the running launchers.
pub fn clash(c: Choice, system: []const SystemKey, others: *const Others) Clash {
    var out: Clash = .{};
    for (system) |k| if (k.enabled and k.key == c.code and k.mods & ns_mods == c.appkit()) {
        out.system = systemName(k.id);
        out.system_id = k.id;
        break;
    };
    // Launchers live on ⌘Space and ⌥Space; ⌃Space and ⌥⌘Space are quiet.
    if (c.eql(.cmd_space) or c.eql(.opt_space)) out.launchers = others.slice();
    return out;
}

/// The system's shortcuts (macOS keeps them in its defaults).
pub fn systemKeys(buf: []SystemKey) []SystemKey {
    if (!mac) return buf[0..0];
    const pool = objc.Pool.push();
    defer pool.pop();
    const ud = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    const domain = objc.msg(?objc.Object, ud, "persistentDomainForName:", .{objc.nsString("com.apple.symbolichotkeys")}) orelse return buf[0..0];
    const table = objc.msg(?objc.Object, domain, "objectForKey:", .{objc.nsString("AppleSymbolicHotKeys")}) orelse return buf[0..0];
    const keys = objc.msg(objc.Object, table, "allKeys", .{});
    var n: usize = 0;
    for (0..objc.msg(objc.NSUInteger, keys, "count", .{})) |i| {
        if (n == buf.len) break;
        const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
        const entry = objc.msg(?objc.Object, table, "objectForKey:", .{k}) orelse continue;
        const enabled = objc.msg(?objc.Object, entry, "objectForKey:", .{objc.nsString("enabled")}) orelse continue;
        const value = objc.msg(?objc.Object, entry, "objectForKey:", .{objc.nsString("value")}) orelse continue;
        const params = objc.msg(?objc.Object, value, "objectForKey:", .{objc.nsString("parameters")}) orelse continue;
        if (objc.msg(objc.NSUInteger, params, "count", .{}) < 3) continue;
        const key: objc.NSInteger = objc.msg(objc.NSInteger, objc.msg(objc.Object, params, "objectAtIndex:", .{@as(objc.NSUInteger, 1)}), "integerValue", .{});
        if (key < 0 or key > 127) continue;
        const flags = objc.msg(objc.NSInteger, objc.msg(objc.Object, params, "objectAtIndex:", .{@as(objc.NSUInteger, 2)}), "integerValue", .{});
        buf[n] = .{
            .id = @intCast(@max(0, objc.msg(objc.NSInteger, k, "integerValue", .{}))),
            .enabled = objc.msg(objc.BOOL, enabled, "boolValue", .{}),
            .key = @intCast(key),
            .mods = @bitCast(@as(i64, flags)),
        };
        n += 1;
    }
    return buf[0..n];
}

const launchers = [_]struct { []const u8, []const u8 }{
    .{ "com.raycast.macos", "Raycast" },
    .{ "com.runningwithcrayons.Alfred", "Alfred" },
    .{ "com.peeklight.peekalight", "Peekalight" },
    .{ "at.obdev.LaunchBar", "LaunchBar" },
};

/// Asks the launcher called `name` to quit, as its Quit menu item would.
pub fn quit(name: []const u8) void {
    if (!mac) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = for (launchers) |l| {
        if (std.mem.eql(u8, l[1], name)) break l[0];
    } else return;
    const apps = objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{objc.nsString(id)});
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i|
        _ = objc.msg(objc.BOOL, objc.msg(objc.Object, apps, "objectAtIndex:", .{i}), "terminate", .{});
}

/// The launchers that are running now.
pub fn runningLaunchers() Others {
    var o: Others = .{};
    if (!mac) return o;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const apps = objc.msg(objc.Object, ws, "runningApplications", .{});
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
        const a = objc.msg(objc.Object, apps, "objectAtIndex:", .{i});
        const id = objc.fromNSString(objc.msg(?objc.Object, a, "bundleIdentifier", .{}));
        for (launchers) |l| {
            if (!std.mem.eql(u8, id, l[0]) or o.n == o.names.len) continue;
            const seen = for (o.slice()) |name| {
                if (std.mem.eql(u8, name, l[1])) break true;
            } else false;
            if (!seen) {
                o.names[o.n] = l[1];
                o.n += 1;
            }
        }
    }
    return o;
}

test "a clash is found in the system's shortcuts and among launchers" {
    const t = std.testing;
    const sys = [_]SystemKey{
        .{ .id = 64, .enabled = true, .key = 49, .mods = ns_cmd },
        .{ .id = 60, .enabled = false, .key = 49, .mods = ns_ctrl },
        .{ .id = 65, .enabled = true, .key = 49, .mods = ns_cmd | ns_opt | (1 << 23) },
    };
    var others: Others = .{};
    others.names[0] = "Peekalight";
    others.n = 1;
    const a = clash(.cmd_space, &sys, &others);
    try t.expectEqualStrings("Spotlight", a.system.?);
    try t.expectEqual(@as(usize, 1), a.launchers.len);
    // Turned off in System Settings: free.
    try t.expect(clash(.ctrl_space, &sys, &.{}).clear());
    // Device bits beyond the modifiers don't hide a clash.
    try t.expectEqualStrings("Finder's search window", clash(.opt_cmd_space, &sys, &others).system.?);
    try t.expect(clash(.opt_cmd_space, &sys, &others).launchers.len == 0);
}

test "the choice is kept" {
    var mem: nanoui.kv.Memory = .{ .gpa = std.testing.allocator };
    defer mem.deinit();
    try std.testing.expectEqual(Choice.cmd_space, load(mem.store(), std.testing.allocator));
    save(mem.store(), .ctrl_space);
    try std.testing.expectEqual(Choice.ctrl_space, load(mem.store(), std.testing.allocator));
    try std.testing.expect(!onboarded(mem.store()));
    setOnboarded(mem.store());
    try std.testing.expect(onboarded(mem.store()));
}

test "any key with ⌘, ⌥ or ⌃ can be recorded, kept and named" {
    const t = std.testing;
    // ⌥X, as AppKit reports it: X's code, Option's flag, "x".
    const r = recorded(7, ns_opt, 'x');
    try t.expect(r == .key);
    const x = r.key;
    try t.expectEqual(@as(u32, 7), x.code);
    try t.expectEqual(hotkey.option, x.mods);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("⌥ X", try std.fmt.bufPrint(&buf, "{f}", .{x}));
    try t.expectEqual(@as(?usize, null), x.preset());
    // Kept as its code, so a layout's letters don't move it; read back.
    const kept = x.name(&buf);
    try t.expectEqualStrings("key:7:2048:120", kept);
    try t.expect(Choice.parse(kept).?.eql(x));
    // The offered ones keep the names older versions read.
    try t.expectEqualStrings("opt_space", Choice.opt_space.name(&buf));
    try t.expect(Choice.parse("ctrl_space").?.eql(.ctrl_space));
    try t.expectEqualStrings("⌥ ⌘ Space", try std.fmt.bufPrint(&buf, "{f}", .{Choice.opt_cmd_space}));
    try t.expectEqualStrings("⌥⌘", try std.fmt.bufPrint(&buf, "{f}", .{Choice.opt_cmd_space.held()}));
    // ⇧⌃F5 and F5 by itself are fine; a letter alone or with Shift is not.
    try t.expectEqualStrings("⌃ ⇧ F5", try std.fmt.bufPrint(&buf, "{f}", .{recorded(96, ns_ctrl | ns_shift, 0xF708).key}));
    try t.expect(recorded(96, 0, 0xF708) == .key);
    try t.expect(recorded(7, 0, 'x') == .unusable);
    try t.expect(recorded(7, ns_shift, 'x') == .unusable);
    try t.expect(recorded(53, 0, 0x1b) == .cancel);
    // Garbled or unusable kept values fall back.
    try t.expect(Choice.parse("key:7:0:120") == null);
    try t.expect(Choice.parse("key:7:2048") == null);
    try t.expect(Choice.parse("cmd_spaces") == null);
    // Stepping from a recorded key lands on the offered ones.
    try t.expect(x.step(1).eql(.cmd_space));
    try t.expect(Choice.cmd_space.step(-1).eql(.opt_cmd_space));
}

test "a recorded key clashes with the system's shortcut on the same key" {
    const sys = [_]SystemKey{.{ .id = 33, .enabled = true, .key = 7, .mods = ns_opt }};
    const c = clash(recorded(7, ns_opt, 'x').key, &sys, &.{});
    try std.testing.expectEqualStrings("a macOS shortcut", c.system.?);
    try std.testing.expect(clash(recorded(7, ns_cmd, 'x').key, &sys, &.{}).clear());
}
