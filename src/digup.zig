//! Strong DigUp hits for the main list, in the helper's order.
const std = @import("std");
const files = @import("files.zig");

pub const enabled_key = "nanolight.digup";
pub const max_rows = 3;
pub const max_query = 256;
pub const max_bytes = 1024 * 1024;

pub const List = struct {
    found: files.List = .{},
    kinds: [max_rows][64]u8 = undefined,
    lens: [max_rows]usize = @splat(0),

    pub fn deinit(l: *List) void {
        l.found.deinit();
    }

    pub fn replace(l: *List, source: *List) void {
        l.found.replace(&source.found);
        l.kinds = source.kinds;
        l.lens = source.lens;
    }

    pub fn kind(l: *const List, i: usize) []const u8 {
        return l.kinds[i][0..l.lens[i]];
    }
};

/// An archived email (`…/Mail & Drive Archive/<account>/email/<month>/<date> <subject> [<id>]/message.md`),
/// as its row shows it: the subject, then the account and the day.
pub const Email = struct { subject: []const u8, account: []const u8, date: []const u8 };

pub fn email(path: []const u8) ?Email {
    if (!std.mem.endsWith(u8, path, "/message.md")) return null;
    var parts = std.mem.splitBackwardsScalar(u8, path, '/');
    _ = parts.next();
    const folder = parts.next() orelse return null;
    _ = parts.next() orelse return null; // the month
    if (!std.mem.eql(u8, parts.next() orelse return null, "email")) return null;
    const account = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "Mail & Drive Archive")) return null;
    // "2026-01-07 Subject [19b982ea99748ae4]"
    if (folder.len < 12 or folder[10] != ' ') return null;
    var subject = folder[11..];
    if (std.mem.lastIndexOf(u8, subject, " [")) |i| if (std.mem.endsWith(u8, subject, "]")) {
        subject = subject[0..i];
    };
    if (subject.len == 0) return null;
    return .{ .subject = subject, .account = account, .date = folder[0..10] };
}

pub fn eligible(q: []const u8) bool {
    if (q.len > max_query or (std.unicode.utf8CountCodepoints(q) catch return false) < 3) return false;
    for (q) |c| if (c < 0x20 or c == 0x7f) return false;
    return @import("calc.zig").eval(q) == null;
}

/// Only the strong prefix may supply rows; malformed paths are skipped.
pub fn decode(allocator: std.mem.Allocator, body: []const u8, out: *List) bool {
    out.deinit();
    if (body.len > max_bytes) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const root = parsed.value.object;
    const hits = root.get("hits") orelse return false;
    const strong = root.get("strong") orelse return false;
    if (hits != .array or strong != .integer or strong.integer < 0) return false;
    for (hits.array.items[0..@min(hits.array.items.len, @as(u64, @intCast(strong.integer)))], 0..) |hit, i| {
        if (out.found.n == max_rows) break;
        if (hit != .object) continue;
        const path = hit.object.get("path") orelse continue;
        if (path != .string or path.string.len == 0 or path.string[0] != '/' or
            std.mem.indexOfScalar(u8, path.string, 0) != null) continue;
        const k = hit.object.get("kind");
        const kind = if (k != null and k.? == .string) k.?.string else "File";
        const before = out.found.n;
        out.found.add(path.string, std.mem.eql(u8, kind, "folder"), .{ .score = @intCast(1000 - @min(i, 999)) });
        if (before == out.found.n) continue;
        const len = @min(kind.len, out.kinds[before].len);
        @memcpy(out.kinds[before][0..len], kind[0..len]);
        out.lens[before] = len;
    }
    return true;
}

test "DigUp keeps only strong file hits, in order, at most three" {
    const t = std.testing;
    var out: List = .{ .found = .{ .allocator = t.allocator } };
    defer out.deinit();
    try t.expect(decode(t.allocator,
        \\{"hits":[{"path":"/tmp/a.pdf","kind":"pdf","excerpt":"a"},{"path":"relative"},{"path":"/tmp/b","kind":"doc"},{"path":"/tmp/c"},{"path":"/tmp/d"}],"strong":4}
    , &out));
    try t.expectEqual(@as(usize, 3), out.found.n);
    try t.expectEqualStrings("/tmp/a.pdf", out.found.entries[0].path());
    try t.expectEqualStrings("pdf", out.kind(0));
    try t.expectEqualStrings("/tmp/c", out.found.entries[2].path());
    try t.expect(decode(t.allocator, "{\"hits\":[{\"path\":\"/tmp/a\"},{\"path\":\"/tmp/b\"}],\"strong\":1}", &out));
    try t.expectEqual(@as(usize, 1), out.found.n);
    try t.expect(decode(t.allocator, "{\"hits\":[],\"strong\":0}", &out));
    try t.expectEqual(@as(usize, 0), out.found.n);
    for ([_][]const u8{ "bad", "{}", "{\"hits\":[],\"strong\":-1}", "{\"hits\":{},\"strong\":2}" }) |bad| try t.expect(!decode(t.allocator, bad, &out));
    try t.expect(!eligible("ab"));
    try t.expect(!eligible("2+2"));
    try t.expect(!eligible("a\nb"));
    try t.expect(eligible("invoice"));
    try t.expect(eligible("截图文"));
}

test "archived emails show their subject, account and day, not message.md" {
    const t = std.testing;
    const e = email("/Users/s/Documents/Mail & Drive Archive/aianswer/email/2026-01/2026-01-22 😴 Sleep train like a baby [19be57fdddaa0006]/message.md").?;
    try t.expectEqualStrings("😴 Sleep train like a baby", e.subject);
    try t.expectEqualStrings("aianswer", e.account);
    try t.expectEqualStrings("2026-01-22", e.date);
    try t.expectEqualStrings("No id", email("/x/Mail & Drive Archive/personal/email/2026-02/2026-02-01 No id/message.md").?.subject);
    try t.expect(email("/Users/s/SaminOS/50 Health/Resources/Sleep Log.md") == null);
    try t.expect(email("/Users/s/notes/email/2026-01/2026-01-22 Hi [1]/message.md") == null);
    try t.expect(email("/Users/s/Documents/Mail & Drive Archive/aianswer/email/2026-01/2026-01-22 Hi/attachment.pdf") == null);
}
