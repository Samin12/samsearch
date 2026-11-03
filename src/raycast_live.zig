//! The running app's side of Raycast extensions (raycast.zig): what the
//! host may ask of it (open, copy, hide), its rows found again after an
//! install, and a command opened from its row, the panel staying up.
const std = @import("std");
const nanoui = @import("nanoui");
const main = @import("main.zig");
const raycast = @import("raycast.zig");
const sc = @import("script_commands.zig");
const apps = @import("apps.zig");
const Live = main.Live;

pub fn isCommand(target: []const u8) bool {
    return std.mem.startsWith(u8, target, raycast.prefix) or std.mem.eql(u8, target, raycast.store_path) or
        std.mem.startsWith(u8, target, sc.prefix) or std.mem.eql(u8, target, sc.folder_path);
}

/// Sets up the runner: Node and the host found once, the panel told.
pub fn init(l: *Live, env: *const std.process.Environ.Map) void {
    const gpa = l.app.gpa;
    l.ext_ui = .{ .gpa = gpa, .back = &l.s.query };
    l.runner = .{ .gpa = gpa, .io = l.app.io, .ext = &l.ext_ui, .hooks = hooks(l), .node = raycast.findNode(gpa, env) };
    // The host is written out only where Node can run it.
    if (l.runner.node != null) l.runner.host = raycast.findHost(gpa, env);
    l.scripts = .{ .gpa = gpa, .io = l.app.io, .ext = &l.ext_ui, .hooks = .{ .ctx = l, .hide = hide, .redraw = redraw, .copy = copy, .footer = footer } };
    l.s.ext = &l.ext_ui;
    l.env = env;
}

fn footer(ctx: *anyopaque, text: []const u8) void {
    const l = live(ctx);
    l.s.note = text;
    redraw(l);
}

pub fn deinit(l: *Live) void {
    l.scripts.deinit();
    l.runner.stop();
    if (l.runner.node) |n| l.app.gpa.free(n);
    if (l.runner.host) |h| l.app.gpa.free(h);
    l.runner.line.deinit(l.app.gpa);
    l.ext_ui.deinit();
}

/// A command's row was chosen: it runs in the panel, which stays up (the
/// panel hides after opening a row; this open keeps it).
pub fn start(l: *Live, target: []const u8) void {
    if (std.mem.eql(u8, target, sc.folder_path)) {
        const d = sc.dir(l.app.gpa) catch return;
        defer l.app.gpa.free(d);
        _ = nanoui.shell.openPath(d);
        return;
    }
    l.keep_open = true;
    const ix = l.s.index;
    var title: []const u8 = "Raycast";
    var png: ?[]const u8 = null;
    for (ix.apps.items, 0..) |a, i| if (std.mem.eql(u8, a.path, target)) {
        title = a.name;
        png = ix.icon(@intCast(i));
        break;
    };
    l.s.query.clear();
    // The other kind's command, if one runs, ends.
    if (std.mem.startsWith(u8, target, sc.prefix)) {
        l.runner.stop();
        return l.scripts.start(target, title, png);
    }
    l.scripts.stop();
    l.runner.start(target, title, png);
}

fn hooks(l: *Live) raycast.Hooks {
    return .{ .ctx = l, .open = open, .copy = copy, .read_clipboard = readClipboard, .hide = hide, .redraw = redraw, .rescan = rescan };
}

fn live(ctx: *anyopaque) *Live {
    return @ptrCast(@alignCast(ctx));
}

fn open(ctx: *anyopaque, target: []const u8) void {
    const l = live(ctx);
    if (apps.isUrl(target)) {
        _ = nanoui.shell.openUrl(target);
    } else _ = apps.launch(l.app.io, target);
}

fn copy(_: *anyopaque, text: []const u8) void {
    nanoui.clipboard.writeText(text);
}

fn readClipboard(_: *anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    return nanoui.clipboard.readText(gpa) catch null;
}

fn hide(ctx: *anyopaque) void {
    const l = live(ctx);
    if (l.window) |w| w.hide();
}

fn redraw(ctx: *anyopaque) void {
    const l = live(ctx);
    if (l.window) |w| w.redraw();
}

/// The apps and installed commands found again, their counts kept.
pub fn rescan(ctx: *anyopaque) void {
    const l = live(ctx);
    const env = l.env orelse return;
    const ix = l.s.index;
    ix.deinit();
    ix.* = .init(l.app.gpa);
    fill(l, ix, env);
    changed(l);
}

/// As the panel opens: an app installed or removed since Nanolight started
/// is found (#15; after omerdikyol's #4). A look at a few folders; when it
/// finds what the index has, the index stays, its icons with it.
pub fn refresh(ctx: *anyopaque) void {
    const l = live(ctx);
    const env = l.env orelse return;
    var fresh: apps.Index = .init(l.app.gpa);
    fill(l, &fresh, env);
    if (l.s.index.same(&fresh)) return fresh.deinit();
    l.s.index.deinit();
    l.s.index.* = fresh;
    changed(l);
}

fn fill(l: *Live, ix: *apps.Index, env: *const std.process.Environ.Map) void {
    apps.scanSystem(ix, l.app.io, env);
    // TypeScript extensions only where Node is (the user's own; none is
    // shipped); script commands everywhere.
    if (l.runner.node != null) raycast.scan(ix, l.app.gpa);
    sc.scan(ix, l.app.gpa);
    ix.sort();
    ix.load(l.kv);
}

/// The rows again at once: theirs are places in the old index.
fn changed(l: *Live) void {
    l.s.built = 1;
    l.s.rebuild();
    redraw(l);
}
