//! UTF-8 helpers for search and completion (no allocation).
const std = @import("std");

pub fn hasNonAscii(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return true;
    return false;
}

pub fn hasCjk(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i) orelse break;
        i += d.len;
        const cp = d.cp;
        if (cp >= 0x3400 and cp <= 0x9FFF) return true;
        if (cp >= 0xF900 and cp <= 0xFAFF) return true;
    }
    return false;
}

pub fn fold(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + ('a' - 'A');
    return cp;
}

/// One codepoint at byte index `i`, or null if bytes are invalid.
pub fn decodeAt(s: []const u8, i: usize) ?struct { cp: u21, len: usize } {
    if (i >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + len > s.len) return null;
    const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

/// Case-insensitive prefix on whole codepoints (ASCII letters folded).
pub fn utf8StartsWithFold(hay: []const u8, needle: []const u8) bool {
    if (!hasNonAscii(hay) and !hasNonAscii(needle)) {
        if (needle.len > hay.len) return false;
        for (needle, 0..) |ch, j| if (fold(ch) != fold(hay[j])) return false;
        return true;
    }
    var hi: usize = 0;
    var ni: usize = 0;
    while (ni < needle.len) {
        const h = decodeAt(hay, hi) orelse return false;
        const n = decodeAt(needle, ni) orelse return false;
        if (fold(h.cp) != fold(n.cp)) return false;
        hi += h.len;
        ni += n.len;
    }
    return true;
}

/// Byte offset of codepoint index `want` in `s`, or null.
pub fn utf8ByteAtCp(s: []const u8, want: usize) ?usize {
    var i: usize = 0;
    var cp: usize = 0;
    while (i < s.len) {
        if (cp == want) return i;
        const d = decodeAt(s, i) orelse return null;
        i += d.len;
        cp += 1;
    }
    if (cp == want) return i;
    return null;
}
