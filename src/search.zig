//! How well a query matches a name, and which of its bytes matched (drawn
//! brighter in the row). Case-insensitive, ASCII-folded, no allocation:
//! it runs on every name at every keystroke, so it stays a few loops.
//!
//! Tiers, best first: the whole name, its start, a word's start, the
//! words' initials ("vsc" for Visual Studio Code), anywhere inside it,
//! then the letters in order (a subsequence), worse the more they spread,
//! and last, typos: a name or a word in it that begins like the query but
//! for a letter or two swapped, wrong, missing or extra ("chorme" for
//! Chrome, "calandar" for Calendar).
const std = @import("std");
const text = @import("text.zig");

/// Up to this many matched bytes are kept for highlighting.
pub const max_hits = 32;

pub const Match = struct {
    score: i32,
    /// The bytes of the name the query matched, in order.
    hits: [max_hits]u8 = undefined,
    n: u8 = 0,

    pub fn matched(m: *const Match) []const u8 {
        return m.hits[0..m.n];
    }

    fn run(points: i32, from: usize, len: usize) Match {
        var m: Match = .{ .score = points };
        for (from..from + len) |i| m.add(i);
        return m;
    }

    fn add(m: *Match, i: usize) void {
        if (m.n < max_hits and i < 256) {
            m.hits[m.n] = @intCast(i);
            m.n += 1;
        }
    }
};

fn lower(ch: u8) u8 {
    return std.ascii.toLower(ch);
}

/// Whether byte `i` of `name` starts a word: the name's start, after a
/// space or punctuation, or a capital after a lowercase letter (FaceTime).
pub fn wordStart(name: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = name[i - 1];
    const ch = name[i];
    if (prev == ' ' or prev == '-' or prev == '_' or prev == '.' or prev == '/' or prev == '(') return ch != ' ';
    return std.ascii.isUpper(ch) and std.ascii.isLower(prev);
}

fn startsWithFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (needle, 0..) |ch, i| if (lower(hay[i]) != lower(ch)) return false;
    return true;
}

fn indexOfFold(hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) if (startsWithFold(hay[i..], needle)) return i;
    return null;
}

/// The match of `query` in `name`, or null when its letters aren't all
/// there in order. Spaces in the query are ignored past its first word.
pub fn score(query_in: []const u8, name: []const u8) ?Match {
    const query = std.mem.trim(u8, query_in, " ");
    if (query.len == 0 or name.len == 0) return null;
    if (text.hasNonAscii(query) or text.hasNonAscii(name)) return scoreUnicode(query, name);
    return scoreAscii(query, name);
}

fn scoreAscii(query: []const u8, name: []const u8) ?Match {
    const slack: i32 = @intCast(@min(name.len -| query.len, 60));
    if (query.len == name.len and startsWithFold(name, query)) return .run(1000, 0, name.len);
    if (startsWithFold(name, query)) return .run(900 - slack, 0, query.len);
    // A word's start: "code" in Visual Studio Code.
    var at: usize = 0;
    while (indexOfFold(name, query, at)) |i| : (at = i + 1) {
        if (wordStart(name, i)) return .run(800 - slack - @as(i32, @intCast(@min(i, 60))), i, query.len);
    }
    if (initials(query, name)) |m| return m;
    if (indexOfFold(name, query, 0)) |i| return .run(600 - slack - @as(i32, @intCast(@min(i, 60))), i, query.len);
    return subsequence(query, name) orelse typo(query, name);
}

fn cpWordStart(name: []const u8, byte_i: usize) bool {
    if (byte_i == 0) return true;
    const ch = text.decodeAt(name, byte_i) orelse return false;
    const ch_cp = ch.cp;
    var pi = byte_i;
    while (pi > 0) {
        pi -= 1;
        if ((name[pi] & 0xC0) != 0x80) break;
    }
    const prev = text.decodeAt(name, pi) orelse return true;
    const prev_cp = prev.cp;
    if (prev_cp == ' ' or prev_cp == '-' or prev_cp == '_' or prev_cp == '.' or prev_cp == '/' or prev_cp == '(') return ch_cp != ' ';
    if (ch_cp < 0x80 and prev_cp < 0x80) return std.ascii.isUpper(@intCast(ch_cp)) and std.ascii.isLower(@intCast(prev_cp));
    if (ch_cp >= 0x3400 and ch_cp <= 0x9FFF) return true;
    return false;
}

fn scoreUnicode(query: []const u8, name: []const u8) ?Match {
    const slack: i32 = @intCast(@min(name.len -| query.len, 60));
    if (text.utf8StartsWithFold(name, query)) {
        var m: Match = .{ .score = 900 - slack };
        var ni: usize = 0;
        var hi: usize = 0;
        while (ni < query.len and hi < name.len) {
            const nl = std.unicode.utf8ByteSequenceLength(query[ni]) catch break;
            const hl = std.unicode.utf8ByteSequenceLength(name[hi]) catch break;
            for (0..hl) |d| m.add(hi + d);
            ni += nl;
            hi += hl;
        }
        return m;
    }
    if (indexOfUnicode(name, query)) |i| {
        var m: Match = .{ .score = 600 - slack - @as(i32, @intCast(@min(i, 60))) };
        var ni: usize = 0;
        var at = i;
        while (ni < query.len and at < name.len) {
            const nl = std.unicode.utf8ByteSequenceLength(query[ni]) catch break;
            const hl = std.unicode.utf8ByteSequenceLength(name[at]) catch break;
            for (0..hl) |d| m.add(at + d);
            ni += nl;
            at += hl;
        }
        return m;
    }
    return subsequenceUnicode(query, name);
}

fn indexOfUnicode(hay: []const u8, needle: []const u8) ?usize {
    var i: usize = 0;
    while (i < hay.len) {
        if (text.utf8StartsWithFold(hay[i..], needle)) return i;
        const l = std.unicode.utf8ByteSequenceLength(hay[i]) catch {
            i += 1;
            continue;
        };
        i += l;
    }
    return null;
}

fn subsequenceUnicode(query: []const u8, name: []const u8) ?Match {
    var m: Match = .{ .score = 300 };
    var last: ?usize = null;
    var qi: usize = 0;
    var hi: usize = 0;
    while (qi < query.len) {
        if (query[qi] == ' ') {
            qi += 1;
            continue;
        }
        const qd = text.decodeAt(query, qi) orelse return null;
        const qc = qd.cp;
        var found: ?usize = null;
        while (hi < name.len) {
            const hd = text.decodeAt(name, hi) orelse {
                hi += 1;
                continue;
            };
            if (text.fold(hd.cp) == text.fold(qc)) {
                found = hi;
                hi += hd.len;
                break;
            }
            hi += hd.len;
        }
        const at = found orelse return null;
        if (cpWordStart(name, at)) m.score += 12;
        if (last) |l| {
            const step_len = if (text.decodeAt(name, l)) |d| d.len else 1;
            if (at == l + step_len) m.score += 8 else m.score -= @intCast(@min(at - l, 20));
        } else m.score -= @intCast(@min(at, 20));
        const at_len = if (text.decodeAt(name, at)) |d| d.len else 1;
        for (0..at_len) |d| m.add(at + d);
        last = at;
        qi += qd.len;
    }
    m.score -= @intCast(@min(name.len, 60) / 4);
    return m;
}

/// The typos a query of this length may have: none under 4 letters (too
/// many names are a letter from "map"), one, then two from 7.
fn allowed(len: usize) u8 {
    return if (len < 4) 0 else if (len < 7) 1 else 2;
}

const max_q = 32;
const max_n = 64;
/// Edit distances between the query's first i bytes and the name's first
/// j bytes from a word's start (`dist`).
const Table = [max_q + 1][max_n + 1]u8;

/// The query as a misspelt start of the name, or of one of its words: the
/// fewest edits (a byte put in, left out, changed, or two neighbours
/// swapped) that make the query some prefix of it, if few enough.
fn typo(query: []const u8, name: []const u8) ?Match {
    const most = allowed(query.len);
    if (most == 0 or query.len > max_q) return null;
    var t: Table = undefined;
    var best: ?struct { errs: u8, start: usize, end: usize } = null;
    for (0..name.len) |s| {
        if (!wordStart(name, s)) continue;
        const word = name[s..@min(name.len, s + max_n)];
        const r = dist(&t, query, word);
        if (r.errs <= most and (best == null or r.errs < best.?.errs)) best = .{ .errs = r.errs, .start = s, .end = r.end };
    }
    const b = best orelse return null;
    // The bytes that line up with the query's, for the row's highlight.
    const word = name[b.start..@min(name.len, b.start + max_n)];
    _ = dist(&t, query, word);
    var back: [max_hits]u8 = undefined;
    var n: usize = 0;
    var i = query.len;
    var j = b.end;
    while (i > 0 and j > 0) {
        const here = t[i][j];
        if (lower(query[i - 1]) == lower(word[j - 1]) and here == t[i - 1][j - 1]) {
            if (n < back.len) back[n] = @intCast(@min(b.start + j - 1, 255));
            n += 1;
            i -= 1;
            j -= 1;
        } else if (i > 1 and j > 1 and swapped(query, word, i, j) and here == t[i - 2][j - 2] + 1) {
            // Both letters are there, the wrong way round: both lit.
            for ([_]usize{ 1, 2 }) |d| {
                if (n < back.len) back[n] = @intCast(@min(b.start + j - d, 255));
                n += 1;
            }
            i -= 2;
            j -= 2;
        } else if (here == t[i - 1][j - 1] + 1) {
            i -= 1;
            j -= 1;
        } else if (here == t[i - 1][j] + 1) {
            i -= 1;
        } else j -= 1;
    }
    var m: Match = .{ .score = 260 - 70 * @as(i32, b.errs) - @as(i32, @intCast(@min(name.len, 60) / 4)) - @as(i32, @intCast(@min(b.start, 20))) };
    var k = @min(n, back.len);
    while (k > 0) : (k -= 1) m.add(back[k - 1]);
    return m;
}

fn swapped(q: []const u8, w: []const u8, i: usize, j: usize) bool {
    return lower(q[i - 1]) == lower(w[j - 2]) and lower(q[i - 2]) == lower(w[j - 1]);
}

/// Fills `t` (optimal string alignment: insert, delete, change, swap
/// neighbours) and returns the fewest edits to any prefix of `word`, and
/// that prefix's length.
fn dist(t: *Table, q: []const u8, word: []const u8) struct { errs: u8, end: usize } {
    for (0..word.len + 1) |j| t[0][j] = @intCast(j);
    for (1..q.len + 1) |i| {
        t[i][0] = @intCast(i);
        for (1..word.len + 1) |j| {
            const same = lower(q[i - 1]) == lower(word[j - 1]);
            var v = @min(t[i - 1][j] + 1, t[i][j - 1] + 1, t[i - 1][j - 1] + @intFromBool(!same));
            if (i > 1 and j > 1 and swapped(q, word, i, j)) v = @min(v, t[i - 2][j - 2] + 1);
            t[i][j] = v;
        }
    }
    var errs: u8 = 255;
    var end: usize = 0;
    for (0..word.len + 1) |j| if (t[q.len][j] < errs) {
        errs = t[q.len][j];
        end = j;
    };
    return .{ .errs = errs, .end = end };
}

/// The query as the words' initials, in order, every one of them.
fn initials(query: []const u8, name: []const u8) ?Match {
    if (query.len < 2) return null;
    var m: Match = .{ .score = 0 };
    var q: usize = 0;
    for (name, 0..) |ch, i| {
        if (q == query.len) break;
        if (!wordStart(name, i)) continue;
        if (lower(ch) == lower(query[q])) {
            m.add(i);
            q += 1;
        }
    }
    if (q < query.len) return null;
    m.score = 750 - @as(i32, @intCast(@min(name.len, 60)));
    return m;
}

/// The letters in order anywhere; each one on a word's start or right
/// after the last scores more, gaps score less.
fn subsequence(query: []const u8, name: []const u8) ?Match {
    var m: Match = .{ .score = 300 };
    var last: ?usize = null;
    var i: usize = 0;
    for (query) |qc| {
        if (qc == ' ') continue;
        const found = while (i < name.len) : (i += 1) {
            if (lower(name[i]) == lower(qc)) break i;
        } else return null;
        if (wordStart(name, found)) m.score += 12;
        if (last) |l| {
            if (found == l + 1) m.score += 8 else m.score -= @intCast(@min(found - l, 20));
        } else m.score -= @intCast(@min(found, 20));
        m.add(found);
        last = found;
        i = found + 1;
    }
    m.score -= @intCast(@min(name.len, 60) / 4);
    return m;
}

/// A ranked candidate: which one (an index the caller keeps) and its score.
pub const Ranked = struct {
    index: u32,
    match: Match,

    fn before(_: void, a: Ranked, b: Ranked) bool {
        return a.match.score > b.match.score;
    }
};

const Index = @import("apps.zig").Index;

/// The best `out.len` of `names` for `query`, best first, with `boost`
/// (how often each was opened) added to its score.
pub fn rank(query: []const u8, names: []const []const u8, boost: []const u16, out: []Ranked) usize {
    return rankNames(query, names, &.{}, boost, out);
}

/// Like `rank`, with optional `pinyin` per name (same length as `names`).
pub fn rankNames(query: []const u8, names: []const []const u8, pinyin: []const []const u8, boost: []const u16, out: []Ranked) usize {
    var n: usize = 0;
    for (names, 0..) |name, i| {
        var m = score(query, name);
        const py = if (i < pinyin.len) pinyin[i] else "";
        if (py.len > 0) {
            if (scoreAscii(query, py)) |mp| {
                var via = mp;
                via.score -= 70;
                via.n = 0;
                if (m == null or via.score > m.?.score) m = via;
            }
        }
        const hit = m orelse continue;
        var scored = hit;
        if (i < boost.len) scored.score += @min(@as(i32, boost[i]) * 25, 250);
        const r: Ranked = .{ .index = @intCast(i), .match = scored };
        if (n < out.len) {
            out[n] = r;
            n += 1;
            continue;
        }
        // Full: replace the worst kept one if this is better.
        var worst: usize = 0;
        for (out[1..n], 1..) |o, j| if (o.match.score < out[worst].match.score) {
            worst = j;
        };
        if (scored.score > out[worst].match.score) out[worst] = r;
    }
    std.sort.pdq(Ranked, out[0..n], {}, Ranked.before);
    return n;
}

/// Ranks apps using each entry's display name and optional pinyin key.
pub fn rankApps(query: []const u8, ix: *const Index, boost: []const u16, out: []Ranked) usize {
    var n: usize = 0;
    for (ix.names.items, 0..) |name, i| {
        var m = score(query, name);
        const py = ix.apps.items[i].pinyin;
        if (py.len > 0) {
            if (scoreAscii(query, py)) |mp| {
                var via = mp;
                via.score -= 70;
                via.n = 0;
                if (m == null or via.score > m.?.score) m = via;
            }
        }
        const hit = m orelse continue;
        var scored = hit;
        if (i < boost.len) scored.score += @min(@as(i32, boost[i]) * 25, 250);
        const r: Ranked = .{ .index = @intCast(i), .match = scored };
        if (n < out.len) {
            out[n] = r;
            n += 1;
            continue;
        }
        var worst: usize = 0;
        for (out[1..n], 1..) |o, j| {
            if (o.match.score < out[worst].match.score) worst = j;
        }
        if (scored.score > out[worst].match.score) out[worst] = r;
    }
    std.sort.pdq(Ranked, out[0..n], {}, Ranked.before);
    return n;
}

test "the tiers rank as they should" {
    const t = std.testing;
    try t.expect(score("safari", "Safari").?.score > score("saf", "Safari").?.score);
    try t.expect(score("saf", "Safari").?.score > score("code", "Visual Studio Code").?.score);
    try t.expect(score("code", "Visual Studio Code").?.score > score("vsc", "Visual Studio Code").?.score);
    try t.expect(score("vsc", "Visual Studio Code").?.score > score("tudi", "Visual Studio Code").?.score);
    try t.expect(score("tudi", "Visual Studio Code").?.score > score("vsco", "Visual Studio Code").?.score);
    try t.expect(score("xyz", "Safari") == null);
    try t.expect(score("", "Safari") == null);
}

test "initials and capitals start words" {
    const t = std.testing;
    const m = score("ft", "FaceTime").?;
    try t.expectEqualSlices(u8, &.{ 0, 4 }, m.matched());
    const s = score("ss", "System Settings").?;
    try t.expectEqualSlices(u8, &.{ 0, 7 }, s.matched());
}

test "typos still find the app, below every exact match" {
    const t = std.testing;
    // Swapped, changed, extra, and two wrong in a long word.
    try t.expect(score("chorme", "Google Chrome") != null);
    try t.expect(score("notse", "Notes") != null);
    try t.expect(score("safaro", "Safari") != null);
    try t.expect(score("safarii", "Safari") != null);
    try t.expect(score("calandr", "Calendar") != null);
    try t.expect(score("sistem", "System Settings") != null);
    // The word it misspells is the one lit: "Chrome", not "Google".
    try t.expectEqualSlices(u8, &.{ 7, 8, 9, 10, 11, 12 }, score("chorme", "Google Chrome").?.matched());
    try t.expect(score("notse", "Notes").?.score < score("nts", "Notes").?.score);
    // Too far, or too short to guess at.
    try t.expect(score("zebra", "Safari") == null);
    try t.expect(score("sax", "Safari") == null);
    try t.expect(score("mapz", "Mail") == null);
}

test "a subsequence highlights the letters it took" {
    const m = score("sfr", "Safari").?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 4 }, m.matched());
}

test "unicode display names match by prefix and subsequence" {
    const t = std.testing;
    try t.expect(score("微信", "微信") != null);
    try t.expect(score("微", "微信") != null);
    try t.expect(score("信", "微信") != null);
    try t.expect(score("wx", "微信") == null);
}

test "pinyin keys find CJK display names" {
    const t = std.testing;
    var ix = Index.init(t.allocator);
    defer ix.deinit();
    try ix.add("WeChat", "/Applications/WeChat.app");
    const a = ix.arena.allocator();
    ix.apps.items[0].name = try a.dupe(u8, "微信");
    ix.names.items[0] = ix.apps.items[0].name;
    ix.apps.items[0].pinyin = try a.dupe(u8, "weixin");
    var out: [1]Ranked = undefined;
    try t.expectEqual(@as(usize, 1), rankApps("weixin", &ix, &.{}, &out));
    try t.expectEqual(@as(u32, 0), out[0].index);
}

test "rank keeps the best, best first, and opening often lifts a name" {
    const names = [_][]const u8{ "Notes Helper", "Notes", "Numbers", "Keynote" };
    var out: [3]Ranked = undefined;
    const n = rank("no", &names, &.{}, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 1), out[0].index);
    try std.testing.expectEqual(@as(u32, 3), out[2].index);
    // The helper, opened once, climbs past Notes.
    const n2 = rank("no", &names, &.{ 1, 0, 0, 0 }, &out);
    try std.testing.expectEqual(@as(usize, 3), n2);
    try std.testing.expectEqual(@as(u32, 0), out[0].index);
    // Only as many as there's room for: the worst one is the one dropped.
    var two: [2]Ranked = undefined;
    try std.testing.expectEqual(@as(usize, 2), rank("no", &names, &.{}, &two));
    try std.testing.expectEqual(@as(u32, 0), two[1].index);
}
