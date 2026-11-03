//! Google's completions for what is typed, got as browse
//! (github.com/justrach/browse, GoogleSuggestions.swift) gets them: the
//! endpoint Firefox uses, no cookies kept, a short answer or none. Google
//! doesn't publish it as an API, so a failure only leaves the other rows.
//!
//! Nothing that reads as an address goes out (a dot, a slash, a colon, an
//! @: a URL, a host, an email), and an answer counts only for the words it
//! says it answers. Answers are kept (`Cache`), and while a new one is on
//! its way the answer to fewer letters stands in for it, cut to what still
//! begins with what is typed: the rows don't blink at every key.
const std = @import("std");
const results = @import("results.zig");

/// At most this many completions are listed.
pub const max_rows = 4;
/// A query or a completion longer than this is left out.
pub const max_len = 120;
/// A longer answer is not read.
pub const max_bytes = 32 * 1024;
/// How long typing pauses before asking: long enough for a burst of keys
/// to pass, short enough to land while the words are still being read.
pub const pause_ms = 90;

/// Whether `typed` may be sent to Google at all.
pub fn eligible(typed: []const u8) bool {
    const t = std.mem.trim(u8, typed, " \t\r\n");
    if (t.len < 2 or t.len > max_len) return false;
    if (std.ascii.startsWithIgnoreCase(t, "www.") or std.ascii.startsWithIgnoreCase(t, "localhost")) return false;
    for (t) |ch| switch (ch) {
        0...0x1f, 0x7f, ':', '@', '\\', '/', '.' => return false,
        else => {},
    };
    return true;
}

/// The address that asks for `typed`'s completions.
pub fn url(buf: []u8, typed: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("https://suggestqueries.google.com/complete/search?client=firefox&q=") catch return "";
    results.escape(&w, typed);
    return w.buffered();
}

/// `s` as words to compare: ASCII lowered, runs of spaces made one, and
/// none at either end.
pub fn plain(buf: *[max_len]u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var space = false;
    for (std.mem.trim(u8, s, " \t\r\n")) |ch| {
        if (n == buf.len) break;
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            space = true;
            continue;
        }
        if (space) {
            buf[n] = ' ';
            n += 1;
            space = false;
            if (n == buf.len) break;
        }
        if (ch < 0x80) buf[n] = std.ascii.toLower(ch) else buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

/// Whether `a` and `b` are the same words.
pub fn same(a: []const u8, b: []const u8) bool {
    var ba: [max_len]u8 = undefined;
    var bb: [max_len]u8 = undefined;
    return std.mem.eql(u8, plain(&ba, a), plain(&bb, b));
}

/// Completions, kept by value.
pub const List = struct {
    text: [max_rows][max_len]u8 = undefined,
    lens: [max_rows]u8 = @splat(0),
    n: usize = 0,

    pub fn get(l: *const List, i: usize) []const u8 {
        return l.text[i][0..l.lens[i]];
    }

    pub fn push(l: *List, s: []const u8) void {
        if (l.n == max_rows or s.len > max_len) return;
        @memcpy(l.text[l.n][0..s.len], s);
        l.lens[l.n] = @intCast(s.len);
        l.n += 1;
    }

    /// Its completions as slices, into `out`.
    pub fn slices(l: *const List, out: *[max_rows][]const u8) []const []const u8 {
        for (0..l.n) |i| out[i] = l.get(i);
        return out[0..l.n];
    }

    fn has(l: *const List, s: []const u8) bool {
        for (0..l.n) |i| if (same(l.get(i), s)) return true;
        return false;
    }
};

/// Google's answer (`["typed", ["completion", …], …]`) as completions of
/// `typed` into `out`: false when it isn't one, or answers other words.
/// The words typed themselves, repeats, and long ones are left out.
pub fn decode(arena: std.mem.Allocator, body: []const u8, typed: []const u8, out: *List) bool {
    out.n = 0;
    if (body.len > max_bytes) return false;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return false;
    if (v != .array or v.array.items.len < 2) return false;
    const echoed = v.array.items[0];
    const choices = v.array.items[1];
    if (echoed != .string or choices != .array or !same(echoed.string, typed)) return false;
    for (choices.array.items) |choice| {
        if (choice != .string) continue;
        const text = std.mem.trim(u8, choice.string, " \t\r\n");
        if (text.len == 0 or text.len > max_len or same(text, typed) or out.has(text)) continue;
        out.push(text);
        if (out.n == max_rows) break;
    }
    return true;
}

/// The last answers, by the words they answer.
pub const Cache = struct {
    const slots = 64;
    keys: [slots][max_len]u8 = undefined,
    key_lens: [slots]u8 = @splat(0),
    lists: [slots]List = undefined,
    n: usize = 0,
    /// The slot the next new answer takes (the oldest, once full).
    next: usize = 0,

    pub fn put(c: *Cache, typed: []const u8, l: *const List) void {
        var buf: [max_len]u8 = undefined;
        const key = plain(&buf, typed);
        const i = c.find(key) orelse blk: {
            const slot = c.next;
            c.next = (c.next + 1) % slots;
            c.n = @min(c.n + 1, slots);
            @memcpy(c.keys[slot][0..key.len], key);
            c.key_lens[slot] = @intCast(key.len);
            break :blk slot;
        };
        c.lists[i] = l.*;
    }

    fn find(c: *const Cache, key: []const u8) ?usize {
        for (0..c.n) |i| if (std.mem.eql(u8, c.keys[i][0..c.key_lens[i]], key)) return i;
        return null;
    }

    /// What to show for `typed` now, into `out`: Google's answer to it
    /// (true: there is no need to ask), or its answer to fewer of the
    /// letters, kept to what still begins with them (false).
    pub fn lookup(c: *const Cache, typed: []const u8, out: *List) bool {
        out.n = 0;
        var buf: [max_len]u8 = undefined;
        const key = plain(&buf, typed);
        if (key.len == 0) return false;
        if (c.find(key)) |i| {
            out.* = c.lists[i];
            return true;
        }
        var len = key.len;
        while (len > 1) {
            len -= 1;
            const i = c.find(key[0..len]) orelse continue;
            const said = &c.lists[i];
            for (0..said.n) |k| {
                var cb: [max_len]u8 = undefined;
                const p = plain(&cb, said.get(k));
                if (p.len > key.len and std.mem.startsWith(u8, p, key)) out.push(said.get(k));
            }
            return false;
        }
        return false;
    }
};

test "addresses, emails and paths never go out" {
    const t = std.testing;
    try t.expect(eligible("liquid glass"));
    try t.expect(eligible("  zig  "));
    try t.expect(!eligible("z"));
    for ([_][]const u8{ "github.com", "www.zig", "localhost 3000", "me@x", "a/b", "http://x", "c:\\x", "tab\there" }) |q|
        try t.expect(!eligible(q));
    var long: [max_len + 1]u8 = @splat('a');
    try t.expect(!eligible(&long));
}

test "the address is escaped" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://suggestqueries.google.com/complete/search?client=firefox&q=liquid+gl+%26+co", url(&buf, " liquid gl & co "));
}

test "an answer counts only for the words it answers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\["liquid gl",["liquid glass","Liquid  Gl","liquid glass","liquid glue","liquid glass apple","liquid glass ui","liquid glucose"],[],{"google:suggestsubtypes":[[512]]}]
    ;
    var l: List = .{};
    try std.testing.expect(decode(arena.allocator(), body, "Liquid  GL", &l));
    // Itself and the repeat left out, four kept.
    try std.testing.expectEqual(@as(usize, 4), l.n);
    try std.testing.expectEqualStrings("liquid glass", l.get(0));
    try std.testing.expectEqualStrings("liquid glass ui", l.get(3));
    try std.testing.expect(!decode(arena.allocator(), body, "liquid", &l));
    try std.testing.expect(!decode(arena.allocator(), "<html>", "liquid gl", &l));
    try std.testing.expect(!decode(arena.allocator(), "[\"x\"]", "x", &l));
    // Escapes are read: "caf\u00e9".
    try std.testing.expect(decode(arena.allocator(), "[\"caf\",[\"caf\\u00e9\"]]", "caf", &l));
    try std.testing.expectEqualStrings("café", l.get(0));
}

test "a shorter answer stands in, cut to what still fits" {
    var c: Cache = .{};
    var said: List = .{};
    for ([_][]const u8{ "liquid glass", "liquid glue", "liquid glass apple" }) |s| said.push(s);
    c.put("liquid gl", &said);
    var out: List = .{};
    try std.testing.expect(c.lookup("Liquid GL", &out));
    try std.testing.expectEqual(@as(usize, 3), out.n);
    try std.testing.expect(!c.lookup("liquid gla", &out));
    try std.testing.expectEqual(@as(usize, 2), out.n);
    try std.testing.expectEqualStrings("liquid glass apple", out.get(1));
    try std.testing.expect(!c.lookup("pizza", &out));
    try std.testing.expectEqual(@as(usize, 0), out.n);
    // Full: the oldest answer goes.
    for (0..Cache.slots) |i| {
        var b: [16]u8 = undefined;
        c.put(std.fmt.bufPrint(&b, "q{d}", .{i}) catch unreachable, &said);
    }
    try std.testing.expect(!c.lookup("liquid gl", &out) or out.n == 0);
    try std.testing.expect(c.lookup("q63", &out));
}
