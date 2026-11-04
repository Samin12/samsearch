//! System Settings' panes, found by name or by what people call them
//! ("login items", "wifi", "dark mode"), and opened at the pane (#12).
//! Mac only. Each is the pane's settings extension; one this Mac doesn't
//! have (Touch ID on a Mac without it, a pane newer than its macOS) is
//! never listed.
const std = @import("std");
const search = @import("search.zig");
const mac = @import("builtin").os.tag == .macos;

pub const Pane = struct {
    name: []const u8,
    /// The extension's bundle id: its address is `url_prefix ++ id`.
    id: []const u8,
    /// Its bundle in /System/Library/ExtensionKit/Extensions, without `.appex`.
    /// Where a macOS names it differently, the one macOS 15 (the oldest
    /// Nanolight runs on) has.
    appex: []const u8,
    keywords: []const []const u8 = &.{},

    pub fn url(comptime p: Pane) []const u8 {
        return url_prefix ++ p.id;
    }
};

pub const url_prefix = "x-apple.systempreferences:";

pub const all = [_]Pane{
    .{ .name = "Wi-Fi", .id = "com.apple.wifi-settings-extension", .appex = "Wi-Fi", .keywords = &.{ "wifi", "wireless" } },
    .{ .name = "Bluetooth", .id = "com.apple.BluetoothSettings", .appex = "Bluetooth" },
    .{ .name = "Network", .id = "com.apple.Network-Settings.extension", .appex = "Network", .keywords = &.{ "ethernet", "internet", "firewall", "proxy", "dns" } },
    .{ .name = "VPN", .id = "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", .appex = "VPN" },
    .{ .name = "Notifications", .id = "com.apple.Notifications-Settings.extension", .appex = "NotificationsSettings", .keywords = &.{ "alerts", "banners" } },
    .{ .name = "Sound", .id = "com.apple.Sound-Settings.extension", .appex = "Sound", .keywords = &.{ "volume", "audio", "speakers", "microphone", "output", "input" } },
    .{ .name = "Focus", .id = "com.apple.Focus-Settings.extension", .appex = "FocusSettingsExtension", .keywords = &.{ "do not disturb", "dnd" } },
    .{ .name = "Screen Time", .id = "com.apple.Screen-Time-Settings.extension", .appex = "ScreenTimePreferencesExtension", .keywords = &.{ "parental controls", "app limits" } },
    .{ .name = "General", .id = "com.apple.systempreferences.GeneralSettings", .appex = "Shell" },
    .{ .name = "About", .id = "com.apple.SystemProfiler.AboutExtension", .appex = "AboutExtension", .keywords = &.{ "about this mac", "serial number", "macos version" } },
    .{ .name = "Software Update", .id = "com.apple.Software-Update-Settings.extension", .appex = "SoftwareUpdateSettingsExtension", .keywords = &.{ "update macos", "upgrade" } },
    .{ .name = "Storage", .id = "com.apple.settings.Storage", .appex = "Storage", .keywords = &.{ "disk space", "free space" } },
    .{ .name = "AirDrop & Handoff", .id = "com.apple.AirDrop-Handoff-Settings.extension", .appex = "AirDropHandoffExtension", .keywords = &.{ "airplay receiver", "continuity" } },
    .{ .name = "Login Items & Extensions", .id = "com.apple.LoginItems-Settings.extension", .appex = "LoginItems", .keywords = &.{ "open at login", "startup items", "background items", "extensions" } },
    .{ .name = "Language & Region", .id = "com.apple.Localization-Settings.extension", .appex = "Localization", .keywords = &.{ "language", "region", "locale", "date format" } },
    .{ .name = "Date & Time", .id = "com.apple.Date-Time-Settings.extension", .appex = "DateAndTime Extension", .keywords = &.{ "clock", "time zone" } },
    .{ .name = "Sharing", .id = "com.apple.Sharing-Settings.extension", .appex = "Sharing", .keywords = &.{ "file sharing", "screen sharing", "remote login", "ssh", "computer name" } },
    .{ .name = "Time Machine", .id = "com.apple.Time-Machine-Settings.extension", .appex = "TimeMachineSettings", .keywords = &.{"backup"} },
    .{ .name = "Transfer or Reset", .id = "com.apple.Transfer-Reset-Settings.extension", .appex = "TransferResetExtension", .keywords = &.{ "erase all content", "factory reset" } },
    .{ .name = "Startup Disk", .id = "com.apple.Startup-Disk-Settings.extension", .appex = "StartupDisk" },
    .{ .name = "Device Management", .id = "com.apple.Profiles-Settings.extension", .appex = "ProfilesSettingsExt", .keywords = &.{ "profiles", "mdm" } },
    .{ .name = "Appearance", .id = "com.apple.Appearance-Settings.extension", .appex = "Appearance", .keywords = &.{ "dark mode", "light mode", "accent color", "theme" } },
    .{ .name = "Accessibility", .id = "com.apple.Accessibility-Settings.extension", .appex = "AccessibilitySettingsExtension", .keywords = &.{ "voiceover", "zoom", "reduce motion" } },
    .{ .name = "Control Center", .id = "com.apple.ControlCenter-Settings.extension", .appex = "ControlCenterSettings", .keywords = &.{"menu bar"} },
    .{ .name = "Siri", .id = "com.apple.Siri-Settings.extension", .appex = "SiriPreferenceExtension", .keywords = &.{ "apple intelligence", "dictation" } },
    .{ .name = "Spotlight", .id = "com.apple.Spotlight-Settings.extension", .appex = "SpotlightPreferenceExtension" },
    .{ .name = "Privacy & Security", .id = "com.apple.settings.PrivacySecurity.extension", .appex = "SecurityPrivacyExtension", .keywords = &.{ "permissions", "full disk access", "accessibility access", "location services", "camera access", "filevault", "gatekeeper" } },
    .{ .name = "Desktop & Dock", .id = "com.apple.Desktop-Settings.extension", .appex = "DesktopSettings", .keywords = &.{ "dock", "mission control", "hot corners", "stage manager", "widgets" } },
    .{ .name = "Displays", .id = "com.apple.Displays-Settings.extension", .appex = "DisplaysExt", .keywords = &.{ "monitor", "resolution", "brightness", "night shift" } },
    .{ .name = "Wallpaper", .id = "com.apple.Wallpaper-Settings.extension", .appex = "Wallpaper", .keywords = &.{ "background", "desktop picture" } },
    .{ .name = "Battery", .id = "com.apple.Battery-Settings.extension", .appex = "PowerPreferences", .keywords = &.{ "energy", "power", "low power mode" } },
    .{ .name = "Lock Screen", .id = "com.apple.Lock-Screen-Settings.extension", .appex = "LockScreen", .keywords = &.{ "screen saver", "require password" } },
    .{ .name = "Touch ID & Password", .id = "com.apple.Touch-ID-Settings.extension", .appex = "Touch ID & Password", .keywords = &.{ "fingerprint", "password" } },
    .{ .name = "Users & Groups", .id = "com.apple.Users-Groups-Settings.extension", .appex = "UsersGroups", .keywords = &.{ "accounts", "users", "guest user" } },
    .{ .name = "Internet Accounts", .id = "com.apple.Internet-Accounts-Settings.extension", .appex = "InternetAccountsSettingsExtension", .keywords = &.{ "mail accounts", "email accounts" } },
    .{ .name = "Game Center", .id = "com.apple.Game-Center-Settings.extension", .appex = "GameCenterMacOSSettingsExtension" },
    .{ .name = "Game Controllers", .id = "com.apple.Game-Controller-Settings.extension", .appex = "GameControllerMacSettings", .keywords = &.{"gamepad"} },
    .{ .name = "Wallet & Apple Pay", .id = "com.apple.WalletSettingsExtension", .appex = "WalletSettingsExtension" },
    .{ .name = "Keyboard", .id = "com.apple.Keyboard-Settings.extension", .appex = "KeyboardSettings", .keywords = &.{ "keyboard shortcuts", "input sources", "key repeat" } },
    .{ .name = "Mouse", .id = "com.apple.Mouse-Settings.extension", .appex = "MouseExtension", .keywords = &.{ "pointer speed", "natural scrolling" } },
    .{ .name = "Trackpad", .id = "com.apple.Trackpad-Settings.extension", .appex = "TrackpadExtension", .keywords = &.{ "gestures", "tap to click", "natural scrolling" } },
    .{ .name = "Printers & Scanners", .id = "com.apple.Print-Scan-Settings.extension", .appex = "PrinterScannerSettings", .keywords = &.{"printer"} },
    .{ .name = "Apple Account", .id = "com.apple.systempreferences.AppleIDSettings", .appex = "AppleIDSettings", .keywords = &.{ "apple id", "icloud" } },
    .{ .name = "Family", .id = "com.apple.Family-Settings.extension", .appex = "FamilySettings", .keywords = &.{"family sharing"} },
};

/// The addresses of `all`, in step with it.
pub const urls = blk: {
    var u: [all.len][]const u8 = undefined;
    for (all, 0..) |p, i| u[i] = p.url();
    break :blk u;
};

/// Whether this Mac has each pane, looked at once.
var have: [all.len]bool = undefined;
var looked = false;

fn present(i: usize) bool {
    if (!mac) return false;
    if (!looked) {
        const io = std.Io.Threaded.global_single_threaded.io();
        var buf: [256]u8 = undefined;
        for (all, 0..) |p, k| {
            const path = std.fmt.bufPrint(&buf, "/System/Library/ExtensionKit/Extensions/{s}.appex", .{p.appex}) catch {
                have[k] = false;
                continue;
            };
            have[k] = if (std.Io.Dir.accessAbsolute(io, path, .{})) true else |_| false;
        }
        looked = true;
    }
    return have[i];
}

/// What System Settings' own words add nothing to: "login settings" is
/// asking for login.
fn strip(query: []const u8) []const u8 {
    var q = std.mem.trim(u8, query, " ");
    for ([_][]const u8{ " settings", " preferences", " pane" }) |tail| {
        if (q.len > tail.len and std.ascii.endsWithIgnoreCase(q, tail)) q = std.mem.trimEnd(u8, q[0 .. q.len - tail.len], " ");
    }
    return q;
}

/// Below this, a match is letters in order or a typo: too loose for a
/// pane, which would list under nearly every query.
const min_score = 500;

/// The panes `query` asks for, best first, into `out`; how many.
pub fn rank(query: []const u8, out: []search.Ranked) usize {
    const q = strip(query);
    if (q.len < 2) return 0;
    var n: usize = 0;
    for (all, 0..) |p, i| {
        var best = search.score(q, p.name);
        if (best != null and best.?.score < min_score) best = null;
        for (p.keywords) |k| if (search.score(q, k)) |m| {
            // A word for it matches a little lower than its name, and lights
            // nothing in the name shown.
            var via = m;
            via.score -= 40;
            via.n = 0;
            if (m.score >= min_score and (best == null or via.score > best.?.score)) best = via;
        };
        const m = best orelse continue;
        if (!present(i)) continue;
        const r: search.Ranked = .{ .index = @intCast(i), .match = m };
        if (n < out.len) {
            out[n] = r;
            n += 1;
        } else {
            var worst: usize = 0;
            for (out[1..n], 1..) |o, j| if (o.match.score < out[worst].match.score) {
                worst = j;
            };
            if (m.score > out[worst].match.score) out[worst] = r;
        }
    }
    std.sort.pdq(search.Ranked, out[0..n], {}, struct {
        fn f(_: void, a: search.Ranked, b: search.Ranked) bool {
            return a.match.score > b.match.score;
        }
    }.f);
    return n;
}

test "panes are found by name and by the words people use (#12)" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    var out: [3]search.Ranked = undefined;
    const name = struct {
        fn of(r: search.Ranked) []const u8 {
            return all[r.index].name;
        }
    }.of;
    try t.expect(rank("login items", &out) > 0);
    try t.expectEqualStrings("Login Items & Extensions", name(out[0]));
    try t.expect(rank("login settings", &out) > 0);
    try t.expectEqualStrings("Login Items & Extensions", name(out[0]));
    try t.expect(rank("wifi", &out) > 0);
    try t.expectEqualStrings("Wi-Fi", name(out[0]));
    try t.expect(rank("dark mode", &out) > 0);
    try t.expectEqualStrings("Appearance", name(out[0]));
    try t.expect(rank("bluetooth", &out) > 0);
    try t.expectEqualStrings("Bluetooth", name(out[0]));
    // Its name's letters light up; a keyword's light nothing.
    try t.expect(rank("blue", &out) > 0 and out[0].match.n == 4);
    _ = rank("wifi", &out);
    try t.expectEqual(@as(u8, 0), out[0].match.n);
    // Not for loose letters, nor one letter.
    try t.expectEqual(@as(usize, 0), rank("saf", &out));
    try t.expectEqual(@as(usize, 0), rank("w", &out));
    try t.expectEqualStrings(url_prefix ++ "com.apple.LoginItems-Settings.extension", urls[13]);
    // General's extension is GeneralSettings.appex from macOS 26; macOS 15,
    // the oldest Nanolight runs on, calls it Shell.appex.
    try std.testing.expectEqualStrings("Shell", all[8].appex);
}

test "every pane's extension is on this Mac's macOS, or is known not to be" {
    if (!mac) return error.SkipZigTest;
    // The panes every Mac running Nanolight has (macOS 14 or later): a
    // typo in a bundle name here would hide its pane for good.
    for ([_][]const u8{ "Wi-Fi", "Bluetooth", "Network", "Sound", "General", "Appearance", "Keyboard", "Displays", "Login Items & Extensions", "Privacy & Security" }) |want| {
        const i = for (all, 0..) |p, k| {
            if (std.mem.eql(u8, p.name, want)) break k;
        } else return error.NoPane;
        try std.testing.expect(present(i));
    }
}
