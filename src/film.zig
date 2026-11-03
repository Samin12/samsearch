//! A 26-second walkthrough of Nanolight, rendered offscreen: the panel on
//! a desktop in a Tester, 30 frames a second, each frame's pixels to
//! standard output for ffmpeg. Keys reach it as they would from the
//! keyboard (text operations and shortcuts), through the Tester alone:
//! no window shows, nothing reaches the screen, nothing is opened.
//!
//!     tools/film.sh [out.mp4]          # renders, adds key ticks
//!     zig-out/bin/nanolight-film --still=10.5:/tmp/f.png
//!     zig-out/bin/nanolight-film --cues
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const results = @import("results.zig");
const Stage = @import("stage.zig").Stage;
const stage = @import("stage.zig");

const fps = 30;
const scale = 1.5;
const length: f32 = 26.5;

const Op = union(enum) {
    show,
    hide,
    /// The system's appearance turns light.
    light,
    /// →: the completion taken.
    accept,
    intro_off,
    outro_on,
    caption: []const u8,
    text: []const u8,
    clear,
    enter,
    key: struct { sc: ui.Shortcut, label: []const u8 },
};

const Step = struct { at: f32, op: Op };

const S = ui.Shortcut;
const down: Op = .{ .key = .{ .sc = .{ .key = S.down }, .label = "↓" } };
const up: Op = .{ .key = .{ .sc = .{ .key = S.up }, .label = "↑" } };
const esc: Op = .{ .key = .{ .sc = .{ .key = S.escape }, .label = "esc" } };

/// Typed a character at a time, `every` seconds apart.
fn typing(comptime at: f32, comptime str: []const u8, comptime every: f32) [str.len]Step {
    var out: [str.len]Step = undefined;
    for (str, 0..) |_, i| out[i] = .{ .at = at + every * @as(f32, @floatFromInt(i)), .op = .{ .text = str[i .. i + 1] } };
    return out;
}

const script = [_]Step{
    .{ .at = 1.9, .op = .intro_off },
    .{ .at = 2.2, .op = .show },
    .{ .at = 2.2, .op = .{ .caption = "⌘Space, from any app" } },
    .{ .at = 3.5, .op = .{ .caption = "Every app, ranked and completed as you type" } },
} ++ typing(3.7, "saf", 0.16) ++ [_]Step{
    .{ .at = 4.6, .op = .accept },
    .{ .at = 5.3, .op = down },
    .{ .at = 5.8, .op = down },
    .{ .at = 6.3, .op = up },
    .{ .at = 6.9, .op = .clear },
    .{ .at = 6.9, .op = .{ .caption = "Initials work too: ss → System Settings" } },
} ++ typing(7.2, "ss", 0.18) ++ [_]Step{
    .{ .at = 9.1, .op = .clear },
    .{ .at = 9.1, .op = .{ .caption = "Math, answered as you type" } },
} ++ typing(9.4, "2^10 * 3", 0.09) ++ [_]Step{
    .{ .at = 11.0, .op = .enter },
    .{ .at = 11.0, .op = .{ .caption = "↩ copies the answer" } },
    .{ .at = 12.5, .op = .clear },
    .{ .at = 12.5, .op = .{ .caption = "Anything else: ask Grok, or search X" } },
} ++ typing(12.8, "liquid glass", 0.065) ++ [_]Step{
    .{ .at = 14.5, .op = down },
    .{ .at = 15.4, .op = .enter },
    .{ .at = 15.4, .op = .{ .caption = "→ x.com/search?q=liquid+glass" } },
    .{ .at = 16.9, .op = .show },
    .{ .at = 16.9, .op = .{ .caption = "Back with the last query selected" } },
    .{ .at = 18.0, .op = esc },
    .{ .at = 18.0, .op = .{ .caption = "esc clears the query" } },
    .{ .at = 18.6, .op = .hide },
    .{ .at = 18.6, .op = .{ .caption = "Light or dark, as the system is" } },
    .{ .at = 19.1, .op = .light },
    .{ .at = 19.1, .op = .show },
} ++ typing(19.5, "cal", 0.14) ++ [_]Step{
    .{ .at = 20.6, .op = down },
    .{ .at = 21.3, .op = esc },
    .{ .at = 21.3, .op = .{ .caption = "esc, esc: gone" } },
    .{ .at = 21.8, .op = esc },
    .{ .at = 22.5, .op = .{ .caption = "" } },
    .{ .at = 22.6, .op = .outro_on },
};

/// What the film's panel opens: nothing, it only hides.
const Host = struct {
    fn open(_: *anyopaque, _: []const u8) void {}
    fn hide(ctx: *anyopaque) void {
        const d: *Stage = @ptrCast(@alignCast(ctx));
        d.shown = false;
    }
};

extern "c" fn CACurrentMediaTime() f64;

/// How long building the rows for the query takes, in microseconds: the
/// math, the ranking of every app, the rows, as on each key.
fn measure(ix: *Index, query: []const u8) f64 {
    var r: results.Results = .{};
    var sug: [results.max_apps]u32 = undefined;
    const ns = ix.suggestions(&sug);
    const runs = 2000;
    const t0 = CACurrentMediaTime();
    for (0..runs) |_| {
        r.build(query, ix, sug[0..ns], &.{});
        std.mem.doNotOptimizeAway(&r);
    }
    return (CACurrentMediaTime() - t0) / runs * 1e6;
}

fn cues(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    for (script) |st| switch (st.op) {
        .text, .clear, .enter, .key, .accept => try o.print("click {d:.3}\n", .{st.at}),
        .show, .outro_on => try o.print("cut {d:.3}\n", .{st.at}),
        else => {},
    };
    try o.print("cut {d:.3}\n", .{15.4});
    try o.flush();
}

/// The welcome's three steps as this Mac would show them (its shortcuts
/// and running launchers), `<prefix>-1.png` to `-3.png`; the last also
/// light, `-3-light.png`.
fn onboardStills(t: *ui.Tester, d: *Stage, s: *view.Nanolight, prefix: []const u8) !void {
    const onboard = @import("onboard.zig");
    const shortcut = @import("shortcut.zig");
    var o: onboard.Onboard = .{};
    o.start(.cmd_space);
    o.system = shortcut.systemKeys(&o.system_buf);
    o.others = shortcut.runningLaunchers();
    s.onboard = &o;
    d.intro = false;
    d.shown = true;
    s.reveal();
    var buf: [512]u8 = undefined;
    t.settle(2);
    try t.screenshot(try std.fmt.bufPrint(&buf, "{s}-1.png", .{prefix}));
    o.step = .try_it;
    o.closed = true;
    t.ctx.input.cmd = true;
    t.settle(2);
    try t.screenshot(try std.fmt.bufPrint(&buf, "{s}-2.png", .{prefix}));
    t.ctx.input.cmd = false;
    o.step = .done;
    t.settle(2);
    try t.screenshot(try std.fmt.bufPrint(&buf, "{s}-3.png", .{prefix}));
    t.theme = ui.Theme.light;
    t.settle(2);
    try t.screenshot(try std.fmt.bufPrint(&buf, "{s}-3-light.png", .{prefix}));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var wall_path: []const u8 = "zig-out/nanolight/wallpaper.jpg";
    var stills: std.ArrayList(struct { frame: usize, path: []const u8 }) = .empty;
    defer stills.deinit(gpa);
    var dark = true;
    var cover: ?[]const u8 = null;
    var welcome: ?[]const u8 = null;
    // What the cover's panel has found (`--query=`): "saf" for the README.
    var cover_query: []const u8 = "saf";
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cues")) return cues(io);
        if (std.mem.eql(u8, arg, "--light")) {
            dark = false;
        } else if (std.mem.startsWith(u8, arg, "--wallpaper=")) {
            wall_path = arg["--wallpaper=".len..];
        } else if (std.mem.startsWith(u8, arg, "--cover=")) {
            cover = arg["--cover=".len..];
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            cover_query = arg["--query=".len..];
        } else if (std.mem.startsWith(u8, arg, "--onboard=")) {
            welcome = arg["--onboard=".len..];
        } else if (std.mem.startsWith(u8, arg, "--still=")) {
            const v = arg["--still=".len..];
            const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.BadStill;
            const secs = try std.fmt.parseFloat(f32, v[0..colon]);
            try stills.append(gpa, .{ .frame = @intFromFloat(@round(secs * fps)), .path = v[colon + 1 ..] });
        } else return error.UnknownArgument;
    }
    const wall = std.Io.Dir.cwd().readFileAlloc(io, wall_path, gpa, .limited(64 << 20)) catch null;
    defer if (wall) |w| gpa.free(w);

    var ix: Index = .init(gpa);
    defer ix.deinit();
    const t0 = CACurrentMediaTime();
    ix.scan(io, init.environ_map.get("HOME"));
    const scan_ms = (CACurrentMediaTime() - t0) * 1000;

    var s: view.Nanolight = .{ .index = &ix, .own_glass = true };
    defer s.query.deinit();
    var d: Stage = .{ .s = &s, .wall = wall };
    s.host = .{ .ctx = &d, .open = Host.open, .hide = Host.hide };
    var worst: f64 = 0;
    // A typo, and a query nothing matches: the typo tier then runs on every app.
    for ([_][]const u8{ "s", "saf", "ss", "2^10 * 3", "liquid glass", "chorme", "zqxjkvwy" }) |q| worst = @max(worst, measure(&ix, q));
    std.debug.print("nanolight-film: {d} apps, the slowest key {d:.1} µs\n", .{ ix.apps.items.len, worst });
    d.outro_lines = .{
        try std.fmt.bufPrint(&d.outro_buf[0], "{d} apps indexed in {d:.1} ms", .{ ix.apps.items.len, scan_ms }),
        try std.fmt.bufPrint(&d.outro_buf[1], "every key ranked in under {d:.0} µs", .{@ceil(worst)}),
        "no frames drawn while it waits",
    };

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&d, Stage.draw), .{ .width = stage.width, .height = stage.height, .scale = scale, .theme = if (dark) ui.Theme.dark_theme else ui.Theme.light });
    defer t.deinit();
    t.dt = 1.0 / @as(f32, fps);
    t.time = 0;
    // The cover (README, the video's thumbnail): the title beside the
    // panel, which has found Safari from "saf".
    if (cover) |path| {
        d.intro = false;
        d.cover = true;
        d.shown = true;
        d.panel_x = stage.width - view.width - 56;
        d.panel_y = 150;
        s.reveal();
        t.settle(2);
        t.textOps(&.{.{ .insert = cover_query }});
        t.settle(3);
        return t.screenshot(path);
    }
    if (welcome) |prefix| return onboardStills(&t, &d, &s, prefix);
    const clear_ops = [_]ui.TextOp{ .{ .command = .select_all }, .{ .command = .delete_backward } };
    const enter_ops = [_]ui.TextOp{.{ .command = .insert_newline }};
    const accept_ops = [_]ui.TextOp{.{ .command = .move_right }};
    var last: usize = @intFromFloat(length * fps);
    if (stills.items.len > 0) {
        last = 0;
        for (stills.items) |st| last = @max(last, st.frame + 1);
    }
    var next: usize = 0;
    var ops: [1]ui.TextOp = undefined;
    const out = std.Io.File.stdout();
    for (0..last) |i| {
        const now = @as(f32, @floatFromInt(i)) / fps;
        var measured: ?[]const u8 = null;
        while (next < script.len and script[next].at <= now) : (next += 1) switch (script[next].op) {
            .show => {
                d.shown = true;
                s.reveal();
                d.pressed(t.time, "⌘ Space");
            },
            .hide => d.shown = false,
            .light => t.theme = ui.Theme.light,
            .accept => {
                t.ctx.input.ops = &accept_ops;
                d.pressed(t.time, "→");
            },
            .intro_off => d.intro = false,
            .outro_on => d.outro = true,
            .caption => |cap| d.caption = cap,
            .text => |ch| {
                ops[0] = .{ .insert = ch };
                t.ctx.input.ops = &ops;
                measured = ch;
            },
            .clear => {
                t.ctx.input.ops = &clear_ops;
                d.pressed(t.time, "⌘A ⌫");
            },
            .enter => {
                t.ctx.input.ops = &enter_ops;
                d.pressed(t.time, "↩");
            },
            .key => |k| {
                t.ctx.shortcut_taken = false;
                t.ctx.input.shortcut = k.sc;
                d.pressed(t.time, k.label);
            },
        };
        t.frame();
        t.ctx.input.ops = &.{};
        t.ctx.input.shortcut = null;
        if (measured != null) {
            const us = measure(&ix, s.query.text());
            d.stat = std.fmt.bufPrint(&d.stat_buf, "{d} apps ranked in {d:.1} µs", .{ ix.apps.items.len, us }) catch "";
        }
        if (stills.items.len > 0) {
            for (stills.items) |st| if (st.frame == i) try t.screenshot(st.path);
            continue;
        }
        const pixels = try t.render(gpa);
        defer pixels.deinit(gpa);
        try out.writeStreamingAll(io, pixels.bytes);
    }
}
