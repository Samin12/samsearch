//! What the Settings screen (settings_view.zig) asks of the app: the
//! shortcut, opening at login, the Codegraff account, updates. Optional,
//! like the panel's other host callbacks: tests, the film and the promo
//! draw Settings with defaults and call nothing.
const shortcut = @import("shortcut.zig");
const account = @import("account.zig");

pub const SettingsHost = struct {
    ctx: *anyopaque,
    choice: *const fn (ctx: *anyopaque) shortcut.Choice,
    apply: *const fn (ctx: *anyopaque, c: shortcut.Choice) void,
    /// Starts or stops recording a key of one's own: the keys pressed go
    /// to `Settings.took`, not the panel (recorder.zig).
    record: *const fn (ctx: *anyopaque, on: bool) void,
    /// Whether it opens at login; `set` changes it first.
    login: *const fn (ctx: *anyopaque, set: ?bool) bool,
    /// Google's suggestions turned on or off in Settings.
    suggest: *const fn (ctx: *anyopaque, on: bool) void,
    account: *const fn (ctx: *anyopaque) account.State,
    email: *const fn (ctx: *anyopaque) []const u8,
    sign_in: *const fn (ctx: *anyopaque) void,
    sign_out: *const fn (ctx: *anyopaque) void,
    /// Codegraff's terms and privacy, in the browser.
    terms: *const fn (ctx: *anyopaque) void,
    /// The version running, and a newer one waiting (else null).
    version: *const fn (ctx: *anyopaque) []const u8,
    ready: *const fn (ctx: *anyopaque) ?[]const u8,
    check: *const fn (ctx: *anyopaque) void,
    restart: *const fn (ctx: *anyopaque) void,
    welcome: *const fn (ctx: *anyopaque) void,
    quit: *const fn (ctx: *anyopaque) void,
};
