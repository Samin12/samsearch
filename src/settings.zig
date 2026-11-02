//! What Nanolight syncs between a person's Macs, as one record: the key
//! that opens it, whether Google's suggestions are on, and how often each
//! app was opened (what an empty panel suggests). JSON, so the server keeps
//! it as it came (the gateway's /v1/sync, collection `nanolight`).
//!
//! Two Macs merge, never overwrite: the key and the suggestions go with
//! whichever Mac changed them last (`at`), and each app keeps the higher
//! count of the two, so what you open most anywhere comes up first.
const std = @import("std");

pub const Launch = struct { name: []const u8, count: u16 };

pub const Settings = struct {
    v: u8 = 1,
    /// shortcut.Choice's name: "cmd_space", or a recorded "key:7:2048:120".
    hotkey: []const u8,
    suggest: bool,
    /// When `hotkey` or `suggest` last changed, on whichever Mac (unix seconds).
    at: i64,
    launches: []const Launch = &.{},
};

pub fn encode(gpa: std.mem.Allocator, s: Settings) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, s, .{});
}

/// A record's body, or null when it isn't one of ours.
pub fn decode(arena: std.mem.Allocator, body: []const u8) ?Settings {
    const s = std.json.parseFromSliceLeaky(Settings, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    if (s.v != 1 or s.hotkey.len == 0 or s.hotkey.len > 32) return null;
    return s;
}

/// The two, merged. `prefer_remote`: this Mac's first sync, where the
/// account's key and choices win over what a fresh install picked.
pub fn merge(arena: std.mem.Allocator, local: Settings, remote: Settings, prefer_remote: bool) !Settings {
    const theirs = prefer_remote or remote.at > local.at;
    var out: Settings = if (theirs)
        .{ .hotkey = remote.hotkey, .suggest = remote.suggest, .at = remote.at }
    else
        .{ .hotkey = local.hotkey, .suggest = local.suggest, .at = local.at };
    var list: std.ArrayList(Launch) = .empty;
    for ([_][]const Launch{ local.launches, remote.launches }) |side| for (side) |l| {
        if (l.name.len == 0 or l.name.len > 255) continue;
        for (list.items) |*have| {
            if (std.mem.eql(u8, have.name, l.name)) {
                have.count = @max(have.count, l.count);
                break;
            }
        } else try list.append(arena, l);
    };
    // A steady order, so the same counts encode the same.
    std.sort.pdq(Launch, list.items, {}, struct {
        fn f(_: void, a: Launch, b: Launch) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.f);
    out.launches = list.items;
    return out;
}

/// Whether the two say the same.
pub fn same(a: Settings, b: Settings) bool {
    if (!std.mem.eql(u8, a.hotkey, b.hotkey) or a.suggest != b.suggest or a.at != b.at or a.launches.len != b.launches.len) return false;
    for (a.launches, b.launches) |x, y| if (x.count != y.count or !std.mem.eql(u8, x.name, y.name)) return false;
    return true;
}

test "two Macs merge: the later choice wins, and each app keeps its higher count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const here: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 100, .launches = &.{ .{ .name = "Safari", .count = 5 }, .{ .name = "Notes", .count = 1 } } };
    const there: Settings = .{ .hotkey = "opt_space", .suggest = false, .at = 200, .launches = &.{ .{ .name = "Notes", .count = 4 }, .{ .name = "Mail", .count = 2 } } };
    const m = try merge(a, here, there, false);
    try std.testing.expectEqualStrings("opt_space", m.hotkey);
    try std.testing.expect(!m.suggest);
    try std.testing.expectEqual(@as(usize, 3), m.launches.len);
    try std.testing.expectEqualStrings("Mail", m.launches[0].name);
    try std.testing.expectEqual(@as(u16, 4), m.launches[1].count);
    try std.testing.expectEqual(@as(u16, 5), m.launches[2].count);
    // Merged either way round, the same.
    try std.testing.expect(same(m, try merge(a, there, here, false)));
    // This Mac changed its key last: it stays.
    const later: Settings = .{ .hotkey = "ctrl_space", .suggest = true, .at = 300 };
    try std.testing.expectEqualStrings("ctrl_space", (try merge(a, later, there, false)).hotkey);
    // But a first sync takes the account's, whatever this Mac picked.
    try std.testing.expectEqualStrings("opt_space", (try merge(a, later, there, true)).hotkey);
}

test "a record round-trips, and what isn't one isn't taken" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 1793600000, .launches = &.{.{ .name = "Visual \"Studio\" Code", .count = 3 }} };
    const body = try encode(a, s);
    const back = decode(a, body).?;
    try std.testing.expect(same(s, back));
    try std.testing.expect(decode(a, "{\"v\":2,\"hotkey\":\"x\",\"suggest\":true,\"at\":1}") == null);
    try std.testing.expect(decode(a, "not json") == null);
    // Fields a later version adds are passed over.
    try std.testing.expect(decode(a, "{\"v\":1,\"hotkey\":\"cmd_space\",\"suggest\":false,\"at\":5,\"theme\":\"dark\"}") != null);
}
