//! The promo: 40 seconds at 60 fps, of what is new in Nanolight 2.0 (the
//! 0.2 releases), after its titles (tools/promo.sh). The interface
//! is the shot: Apple's MacBook Air (Blender, tools/promo/laptop.py)
//! pushes into its display as ⌘Space opens the panel, then the panel fills
//! the frame and one new thing is done a shot (Settings, a Raycast
//! extension, a script command), the camera held still on the whole
//! stage; then Windows and Linux. Labels are small and quiet; the
//! end is the panel becoming the icon beside the name. (After a study of
//! Apple's, Raycast's, Linear's and Cursor's launch films, and Emil
//! Kowalski's easing: docs/promo.md.)
//!
//! Everything is drawn by nanoui offscreen, the panel by the app's own
//! code driven by keys through a Tester: no window shows, nothing opens.
//!
//!     tools/promo.sh                                  # the whole video
//!     zig-out/bin/nanolight-promo --shot=screen > f.bgra   # 1838×1195, the display
//!     zig-out/bin/nanolight-promo --shot=main [--from=S --to=S] > f.bgra  # 1920×1080
//!     zig-out/bin/nanolight-promo --cues              # when sounds land
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const cam = @import("promo_camera.zig");
const scene_mod = @import("promo_scene.zig");
const Scene = scene_mod.Scene;
const Label = scene_mod.Label;
const model = @import("raycast_model.zig");
const Ext = @import("raycast_view.zig").Ext;

/// What Hacker News's extension (raycast/extensions) rendered through
/// Nanolight's host on 3 November 2026: its first nine stories, ranked.
const hn_render = @embedFile("promo_hn.json");
/// The System Info script command's output on the Mac that made the video.
const sysinfo = @embedFile("promo_sysinfo.txt");

fn quiet(_: *anyopaque, _: []const u8) void {}

pub const fps = 60;
/// The opening's extra time: the MacBook and the XPS side by side, their
/// panels opening together, before the camera pushes into the Mac's
/// display. Every time below includes it.
pub const lead: f32 = 2.0;
pub const total: f32 = 37 + lead;
/// The laptops' shot is the first `laptop` seconds; the main shot takes
/// over from `main_from` (they cross for the difference).
pub const laptop: f32 = 3.4 + lead;
pub const main_from: f32 = 3.2 + lead;
/// When the panel opens on the laptop's display (and the XPS's).
pub const open_at: f32 = 1.4 + lead;
pub const end_at: f32 = 32.4 + lead;
/// The Mac's part ends here; the XPS (Windows, then Linux) takes over
/// until the end (tools/promo.sh splices it in).
pub const mac_until: f32 = 16.3 + lead;

const S = ui.Shortcut;

const Op = union(enum) {
    show,
    label: struct { []const u8, []const u8 },
    text: []const u8,
    clear,
    enter,
    accept,
    key: struct { sc: ui.Shortcut, label: []const u8 },
    /// A Raycast extension's list (Hacker News), a script command's output,
    /// opened from their rows; and leaving them.
    ext_list,
    ext_script,
    ext_stop,
    end,
};

const Step = struct { at: f32, op: Op };

fn typing(comptime at: f32, comptime str: []const u8, comptime every: f32) [str.len]Step {
    var out: [str.len]Step = undefined;
    // Human: a little uneven, every third key a touch slower.
    for (str, 0..) |_, i| out[i] = .{ .at = at + every * @as(f32, @floatFromInt(i)) + if (i % 3 == 2) every * 0.35 else 0, .op = .{ .text = str[i .. i + 1] } };
    return out;
}

fn say(text: []const u8, key: []const u8) Op {
    return .{ .label = .{ text, key } };
}

const down: Op = .{ .key = .{ .sc = .{ .key = S.down }, .label = "↓" } };
const tab: Op = .{ .key = .{ .sc = .{ .key = S.tab }, .label = "Tab" } };
const esc: Op = .{ .key = .{ .sc = .{ .key = S.escape }, .label = "esc" } };

/// The main shot, in seconds into the video (written without the `lead`,
/// which `later` adds): only what 0.2 brings (the apps, math and Google
/// were the first film's).
const script = later([_]Step{
    .{ .at = 2.4, .op = .show },
    .{ .at = 3.0, .op = say("New in Nanolight 2.0", "") },
    .{ .at = 5.1, .op = .{ .key = .{ .sc = .{ .key = ',', .cmd = true }, .label = "⌘ ," } } },
    .{ .at = 5.1, .op = say("Settings, in the panel", "⌘ ,") },
    .{ .at = 7.6, .op = esc },
    .{ .at = 7.6, .op = say("", "") },
    .{ .at = 8.0, .op = say("Raycast extensions", "") },
} ++ typing(8.0, "hacker", 0.09) ++ [_]Step{
    .{ .at = 9.0, .op = .ext_list },
    .{ .at = 9.0, .op = say("Raycast extensions", "↩") },
    .{ .at = 10.4, .op = down },
    .{ .at = 10.8, .op = down },
    .{ .at = 11.4, .op = .{ .key = .{ .sc = .{ .key = 'k', .cmd = true }, .label = "⌘ K" } } },
    .{ .at = 11.4, .op = say("Their actions", "⌘ K") },
    .{ .at = 12.7, .op = .ext_stop },
    .{ .at = 12.7, .op = say("", "") },
    .{ .at = 13.0, .op = say("Raycast script commands, run in Zig", "") },
} ++ typing(13.0, "system", 0.08) ++ [_]Step{
    .{ .at = 13.8, .op = .ext_script },
    .{ .at = 13.8, .op = say("Raycast script commands, run in Zig", "↩") },
    .{ .at = 15.9, .op = .ext_stop },
    .{ .at = 15.9, .op = say("", "") },
    .{ .at = 16.1, .op = .clear },
}) ++ [_]Step{.{ .at = end_at, .op = .end }};

fn later(comptime steps: anytype) @TypeOf(steps) {
    var out = steps;
    for (&out) |*s| s.at += lead;
    return out;
}

/// The laptop's display: the desktop, then ⌘Space.
const screen_script = [_]Step{.{ .at = open_at, .op = .show }};

/// The camera: the whole stage, held still. Zooming in and out with each
/// shot, and following the panel's springing height as results came and
/// went, made the frame bob with every key; the panel is large enough to
/// read without it.
const centre: cam.View = .{ .zoom = 1, .cx = scene_mod.width / 2, .cy = scene_mod.height / 2 };

/// What each loupe lifts: text the scene shows (found as it opens), else
/// a stage point. None in this cut (the first film's lifted the math's
/// answer and Google's completion).
const Lift = struct { loupe: cam.Loupe, find: []const u8 = "", dy: f32 = 0 };
const lifts = [_]Lift{};

/// The apps the panel finds: Apple's own and Chrome (the typo's), the same
/// on any Mac, rather than whatever this one has.
const apps = [_][]const u8{
    "/Applications/Safari.app",                            "/Applications/Google Chrome.app",
    "/System/Applications/System Settings.app",            "/System/Applications/Calculator.app",
    "/System/Applications/Calendar.app",                   "/System/Applications/Mail.app",
    "/System/Applications/Maps.app",                       "/System/Applications/Messages.app",
    "/System/Applications/Music.app",                      "/System/Applications/Notes.app",
    "/System/Applications/Photos.app",                     "/System/Applications/FaceTime.app",
    "/System/Library/CoreServices/Finder.app",             "/System/Applications/App Store.app",
    "/System/Applications/Books.app",                      "/System/Applications/Freeform.app",
    "/System/Applications/Preview.app",                    "/System/Applications/Reminders.app",
    "/System/Applications/Shortcuts.app",                  "/System/Applications/Utilities/Terminal.app",
    "/System/Applications/Utilities/Activity Monitor.app", "/System/Applications/Weather.app",
    "/System/Applications/Podcasts.app",                   "/System/Applications/TV.app",
    "/System/Applications/TextEdit.app",                   "/System/Applications/Contacts.app",
};

fn isKey(op: Op) bool {
    return switch (op) {
        .text, .clear, .enter, .accept, .key, .ext_list, .ext_script => true,
        else => false,
    };
}

/// When sounds land, in seconds into the video: `key`, `tab`, `enter` for
/// keys, `open` as the panel opens, `lift` as a loupe does, `page` as
/// Google's page shows, `cross` where the laptop gives way, and `end`,
/// `name` for the end.
fn cues(io: std.Io) !void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    // ⌘Space, then the panel.
    try o.print("key {d:.3}\nopen {d:.3}\ncross {d:.3}\n", .{ open_at - 0.12, open_at, main_from });
    for (script) |st| if (isKey(st.op) and st.at >= main_from) {
        const kind = switch (st.op) {
            .key => |k| if (k.sc.key == S.tab) "tab" else "key",
            .enter, .ext_list, .ext_script => "enter",
            else => "key",
        };
        try o.print("{s} {d:.3}\n", .{ kind, st.at });
    };
    for (lifts) |l| try o.print("lift {d:.3}\n", .{l.loupe.at});
    try o.print("end {d:.3}\nname {d:.3}\n", .{ end_at, end_at + 0.7 });
    // The PC part's turns (tools/promo.sh splices it in).
    try o.print("cross {d:.3}\ncross {d:.3}\n", .{ mac_until, end_at });
    try o.flush();
}

fn readAll(io: std.Io, gpa: std.mem.Allocator, path: ?[]const u8) ?[]const u8 {
    const p = path orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 20)) catch |e| {
        std.debug.print("nanolight-promo: {s}: {t}\n", .{ p, e });
        return null;
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var shot: []const u8 = "";
    var wall_path: ?[]const u8 = null;
    var serp_path: ?[]const u8 = null;
    var hn_icon_path: ?[]const u8 = null;
    var from: f32 = -1;
    var to: f32 = -1;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cues")) return cues(io);
        if (std.mem.startsWith(u8, arg, "--shot=")) shot = arg[7..] else if (std.mem.startsWith(u8, arg, "--wall=")) wall_path = arg[7..] else if (std.mem.startsWith(u8, arg, "--serp=")) serp_path = arg[7..] else if (std.mem.startsWith(u8, arg, "--hn-icon=")) hn_icon_path = arg[10..] else if (std.mem.startsWith(u8, arg, "--from=")) from = try std.fmt.parseFloat(f32, arg[7..]) else if (std.mem.startsWith(u8, arg, "--to=")) to = try std.fmt.parseFloat(f32, arg[5..]) else return error.UnknownArgument;
    }
    const screen = std.mem.eql(u8, shot, "screen");
    if (!screen and !std.mem.eql(u8, shot, "main")) {
        std.debug.print("nanolight-promo: --shot=main or --shot=screen\n", .{});
        return error.UnknownShot;
    }
    const wall = readAll(io, gpa, wall_path);
    defer if (wall) |b| gpa.free(b);
    const serp = readAll(io, gpa, serp_path);
    defer if (serp) |b| gpa.free(b);

    var ix: Index = .init(gpa);
    defer ix.deinit();
    for (apps) |p| ix.add(std.fs.path.stem(p), p) catch {};
    // A Raycast extension's command and a script command, among the apps.
    ix.addIn("Hacker News", "raycast:/promo/hacker-news#frontpage", "Hacker News") catch {};
    ix.addIn("System Info", "script:/promo/system-info.sh", "Nanolight Demos") catch {};
    ix.sort();
    const hn_icon = readAll(io, gpa, hn_icon_path);
    if (hn_icon) |png| if (ix.find("Hacker News")) |i| {
        ix.icons.put(gpa, ix.apps.items[i].path, .{ .png = try gpa.dupe(u8, png) }) catch {};
    };
    defer if (hn_icon) |b| gpa.free(b);

    var s: view.Nanolight = .{ .index = &ix, .own_glass = true };
    defer s.query.deinit();
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    const host_to: @import("raycast_view.zig").Sender = .{ .ctx = &ext, .func = quiet };
    var sc: Scene = .{ .s = &s, .gpa = gpa, .wall = wall, .serp = serp, .screen = screen };
    // The display is a 13-inch MacBook Air's desktop (1470×956 points).
    if (screen) {
        sc.w = 1470;
        sc.h = 956;
    }
    s.host = sc.host();
    const scale: f32 = if (screen) 1.25 else 3840.0 / scene_mod.width;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&sc, Scene.draw), .{ .width = sc.w, .height = sc.h, .scale = scale, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.dt = 1.0 / @as(f32, fps);

    const steps: []const Step = if (screen) &screen_script else &script;
    // The main shot runs from before it is seen, so the panel has opened.
    const start: f32 = if (screen) 0 else 2.2 + lead;
    const first: f32 = if (from >= 0) from else if (screen) 0 else main_from;
    const last: f32 = if (to >= 0) to else if (screen) laptop else total;
    t.time = start;
    const lens: cam.Lens = .{ .stage_w = scene_mod.width, .stage_h = scene_mod.height, .out_w = 1920, .out_h = 1080 };
    var out_buf: []u8 = &.{};
    if (!screen) out_buf = try gpa.alloc(u8, 1920 * 1080 * 4);
    defer if (!screen) gpa.free(out_buf);
    var found: [lifts.len]?[2]f32 = @splat(null);

    const clear_ops = [_]ui.TextOp{ .{ .command = .select_all }, .{ .command = .delete_backward } };
    const enter_ops = [_]ui.TextOp{.{ .command = .insert_newline }};
    const accept_ops = [_]ui.TextOp{.{ .command = .move_right }};
    var ops: [1]ui.TextOp = undefined;
    var next: usize = 0;
    const out = std.Io.File.stdout();
    var i: u32 = 0;
    while (true) : (i += 1) {
        const now = start + @as(f32, @floatFromInt(i)) / fps;
        if (now >= last - 0.5 / @as(f32, fps)) break;
        sc.now = now;
        sc.view = centre;
        while (next < steps.len and steps[next].at <= now) : (next += 1) switch (steps[next].op) {
            .show => {
                sc.shown = true;
                s.reveal();
            },
            .label => |l| {
                // The same words keep their place; only the key changes.
                const same = if (sc.label) |old| std.mem.eql(u8, old.text, l[0]) else false;
                sc.label = .{ .text = l[0], .key = l[1], .at = if (same) sc.label.?.at else now };
            },
            .text => |ch| {
                ops[0] = .{ .insert = ch };
                t.ctx.input.ops = &ops;
            },
            .clear => t.ctx.input.ops = &clear_ops,
            .enter => t.ctx.input.ops = &enter_ops,
            .accept => t.ctx.input.ops = &accept_ops,
            .key => |k| {
                t.ctx.shortcut_taken = false;
                t.ctx.input.shortcut = k.sc;
            },
            .ext_list => {
                s.query.clear();
                ext.start("Hacker News", hn_icon, host_to);
                var arena: std.heap.ArenaAllocator = .init(gpa);
                const m = try model.parse(arena.allocator(), hn_render);
                ext.show(arena, m.view.?);
            },
            .ext_script => {
                s.query.clear();
                ext.start("System Info", null, host_to);
                const arena: std.heap.ArenaAllocator = .init(gpa);
                ext.show(arena, .{ .kind = "detail", .title = "System Info", .output = sysinfo, .actions = &.{ .{ .id = "copy", .title = "Copy Output" }, .{ .id = "again", .title = "Run Again" } } });
            },
            .ext_stop => ext.stop(),
            .end => sc.end_at = now,
        };
        t.frame();
        t.ctx.input.ops = &.{};
        t.ctx.input.shortcut = null;
        sc.google();
        if (now < first - 0.5 / @as(f32, fps)) continue;
        const pixels = try t.render(gpa);
        defer pixels.deinit(gpa);
        if (screen) {
            try out.writeStreamingAll(io, pixels.bytes);
            continue;
        }
        // The loupe open now, if one is: where its text is, found as it opens.
        var lit: ?cam.Lit = null;
        for (lifts, 0..) |lf, k| {
            const a = lf.loupe.amount(now);
            if (a <= 0) continue;
            if (found[k] == null) {
                var p: [2]f32 = .{ lf.loupe.x, lf.loupe.y };
                if (lf.find.len > 0) if (t.findText(lf.find)) |r| {
                    p = .{ r.x + r.w / 2, r.y + r.h / 2 + lf.dy };
                };
                found[k] = p;
            }
            const at = found[k].?;
            const o = lens.toOut(lens.clamp(sc.view), at[0], at[1]);
            lit = (cam.Lit{ .ox = o[0], .oy = o[1], .x = at[0], .y = at[1], .mag = lf.loupe.mag, .a = a, .w = lf.loupe.w, .h = lf.loupe.h }).placed(lens);
        }
        cam.shoot(.{ .bytes = pixels.bytes, .w = pixels.width, .h = pixels.height, .px_per_pt = scale }, lens, sc.view, lit, i, out_buf);
        try out.writeStreamingAll(io, out_buf);
    }
}

test {
    _ = cam;
}
