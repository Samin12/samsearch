//! The menu bar's account rows: who is synced, or how to sign in. The
//! clicks stay on Live (main.zig); this only names the items.
const std = @import("std");
const nanoui = @import("nanoui");
const account = @import("account.zig");

pub fn items(a: ?*account.Account, label: []u8, click: nanoui.menu.Click, terms: nanoui.menu.Click) [2]nanoui.menu.MenuItem {
    const acct = a orelse return .{ .{ .label = "Sync Across Macs…", .disabled = true }, .separator };
    const who: []const u8 = if (acct.email().len > 0) acct.email() else "your Codegraff account";
    return switch (acct.state) {
        .signed_out => .{ .{ .label = "Sign In with Codegraff to Sync Across Macs…", .click = click }, .{ .label = "Codegraff Terms & Privacy", .click = terms } },
        .starting => .{ .{ .label = "Signing In… (Click to Cancel)", .click = click }, .{ .label = "Codegraff Terms & Privacy", .click = terms } },
        .waiting => .{ .{ .label = "Approve in Your Browser… (Click to Cancel)", .click = click }, .{ .label = "Codegraff Terms & Privacy", .click = terms } },
        .signed_in => .{
            .{ .label = std.fmt.bufPrint(label, "Synced as {s}", .{who}) catch "Synced", .disabled = true },
            .{ .label = "Sign Out of Codegraff", .click = click },
        },
    };
}
