//! Gmail, one row per account, each opened in the Chrome profile signed in
//! to it. "gm" to "gmail" lists both inboxes; "gmail invoice" searches
//! each for "invoice".
const std = @import("std");

pub const Account = struct {
    /// What the row calls it.
    name: []const u8,
    email: []const u8,
    /// Chrome's folder for the profile signed in to it.
    profile: []const u8,
};

pub const accounts = [_]Account{
    .{ .name = "Personal", .email = "samin.yasar12@gmail.com", .profile = "Default" },
    .{ .name = "AI Answers", .email = "samin@aianswer.us", .profile = "Profile 1" },
};

/// The Gmail logo, for the rows' tile.
pub const icon_png = @embedFile("gmail.png");

/// Whether `query` asks for Gmail: a start of the word ("gm", "gmai"), or
/// "gmail" and words to search for.
pub fn matches(query_in: []const u8) bool {
    const query = std.mem.trim(u8, query_in, " ");
    const space = std.mem.indexOfScalar(u8, query, ' ');
    const first = query[0 .. space orelse query.len];
    if (space != null) return std.ascii.eqlIgnoreCase(first, "gmail");
    return first.len >= 2 and std.ascii.startsWithIgnoreCase("gmail", first);
}

/// What to search each inbox for: the words after "gmail", else empty.
pub fn terms(query_in: []const u8) []const u8 {
    const query = std.mem.trim(u8, query_in, " ");
    const space = std.mem.indexOfScalar(u8, query, ' ') orelse return "";
    return std.mem.trim(u8, query[space..], " ");
}

/// The page account `i` opens on: its inbox, or a search of it.
pub fn url(buf: []u8, i: usize, query: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("https://mail.google.com/mail/?authuser={s}", .{accounts[i].email}) catch return "";
    const words = terms(query);
    if (words.len > 0) {
        w.writeAll("#search/") catch return "";
        @import("results.zig").escape(&w, words);
    }
    return w.buffered();
}

/// Opens `target` in Chrome's profile `profile`, in a new tab of the
/// Chrome already running (or a new one), without waiting for it.
pub fn openInChrome(io: std.Io, profile: []const u8, target: []const u8) void {
    var arg: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&arg, "--profile-directory={s}", .{profile}) catch return;
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/open", "-na", "Google Chrome", "--args", dir, target },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    const t = std.Thread.spawn(.{}, reap, .{ io, child }) catch {
        child.kill(io);
        return;
    };
    t.detach();
}

fn reap(io: std.Io, child: std.process.Child) void {
    var c = child;
    _ = c.wait(io) catch {};
}

test "gm to gmail lists the inboxes; gmail and words searches them" {
    const t = std.testing;
    for ([_][]const u8{ "gm", "GMA", " gmail ", "gmai", "gmail invoice", "Gmail  stripe receipt" }) |q| try t.expect(matches(q));
    for ([_][]const u8{ "", "g", "gmails", "gmx", "mail", "gm invoice", "my gmail" }) |q| try t.expect(!matches(q));
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("https://mail.google.com/mail/?authuser=samin.yasar12@gmail.com", url(&buf, 0, "gmail"));
    try t.expectEqualStrings("https://mail.google.com/mail/?authuser=samin@aianswer.us#search/stripe+receipt", url(&buf, 1, "gmail  stripe receipt "));
}
