//! The film's desktop: a wallpaper, a menu bar, and over them the panel in
//! nanoui's own Liquid Glass, a caption naming what is shown, the keys as
//! they are pressed, and the time the ranking took.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const view = @import("view.zig");

pub const width: f32 = 1280;
pub const height: f32 = 720;

pub const Stage = struct {
    s: *view.Nanolight,
    wall: ?[]const u8 = null,
    shown: bool = false,
    intro: bool = true,
    outro: bool = false,
    /// The cover still: the icon and the title beside the panel.
    cover: bool = false,
    panel_x: f32 = (width - view.width) / 2,
    panel_y: f32 = 118,
    caption: []const u8 = "",
    /// The last key pressed, shown for a moment.
    key: []const u8 = "",
    key_at: f64 = -10,
    stat: []const u8 = "",
    stat_buf: [96]u8 = undefined,
    outro_lines: [3][]const u8 = .{ "", "", "" },
    outro_buf: [3][96]u8 = undefined,

    pub fn draw(d: *Stage, c: *ui.Context) void {
        const root = ui.div(c).sizeFull();
        defer root.end();
        d.desktop(c);
        d.menuBar(c);
        const glass_pill: ui.Glass = .{ .tint = ui.Color.black.alpha(0.35) };
        const in: motion.Motion = .{ .initial = .{ .opacity = 0, .y = 10 }, .exit = .{ .opacity = 0, .y = -6 }, .transition = .{ .spring = view.spring } };
        if (motion.present(c, "intro", d.intro, in)) |f| {
            const t = ui.div(c).absolute().offset(0, 190).w(width).column().itemsCenter().gap(10).motion(f);
            defer t.end();
            view.appIcon(c, 112);
            ui.text(c, "SamSearch", .{ .size = 64, .weight = .bold, .color = .white, .tracking = -1 });
            ui.text(c, "a launcher in Zig, drawn by nanoui", .{ .size = 22, .weight = .medium, .color = ui.Color.white.alpha(0.85) });
        }
        if (motion.present(c, c.print("panel-{d}", .{d.s.shown}), d.shown, .{
            .initial = .{ .opacity = 0, .y = -12, .scale = 0.97 },
            .exit = .{ .opacity = 0, .scale = 0.98 },
            .transition = .{ .spring = view.spring },
        })) |f| {
            const p = ui.div(c).absolute().offset(d.panel_x, d.panel_y).motion(f);
            defer p.end();
            d.s.panel(c);
        }
        if (d.cover) title(c);
        if (d.caption.len > 0) {
            ui.key(c, d.caption);
            const f = motion.frame(c, .{ .initial = .{ .opacity = 0, .y = 8 }, .transition = .{ .spring = view.spring } });
            const row = ui.div(c).absolute().offset(0, 620).w(width).row().justifyCenter().motion(f);
            defer row.end();
            const pill = ui.div(c).row().px(22).h(46).itemsCenter().roundedFull().glass(glass_pill);
            defer pill.end();
            ui.text(c, d.caption, .{ .size = 19, .weight = .semibold, .color = .white });
        }
        if (motion.present(c, c.print("key-{s}-{d}", .{ d.key, @as(i64, @intFromFloat(d.key_at * 100)) }), c.time - d.key_at < 0.9, .{
            .initial = .{ .opacity = 0, .scale = 0.8 },
            .exit = .{ .opacity = 0, .scale = 0.95 },
            .transition = .{ .spring = .{ .stiffness = 500, .damping = 30 } },
        })) |f| {
            if (c.time - d.key_at < 0.9) c.animationFrame();
            const k = ui.div(c).absolute().offset(width - 210, 620).w(170).row().justifyEnd().motion(f);
            defer k.end();
            const cap = ui.div(c).row().px(16).h(46).minW(46).justifyCenter().itemsCenter().rounded(12).glass(glass_pill).border(ui.Color.white.alpha(0.25));
            defer cap.end();
            ui.text(c, d.key, .{ .size = 19, .weight = .semibold, .color = .white });
        }
        if (motion.present(c, "stat", d.stat.len > 0 and d.shown, in)) |f| {
            const st = ui.div(c).absolute().offset(40, 628).row().gap(8).px(14).h(32).itemsCenter().roundedFull().glass(glass_pill).motion(f);
            defer st.end();
            ui.icon(c, "bolt.fill", .{ .size = 12, .color = .hex(0xffd60a) });
            ui.text(c, d.stat, .{ .size = 13, .weight = .medium, .color = .white, .tabular = true });
        }
        if (motion.present(c, "outro", d.outro, in)) |f| {
            const t = ui.div(c).absolute().offset((width - 560) / 2, 190).w(560).column().itemsCenter().gap(14).p(36).rounded(28)
                .glass(.{ .tint = ui.Color.black.alpha(0.4) }).border(ui.Color.white.alpha(0.14)).motion(f);
            defer t.end();
            view.appIcon(c, 76);
            ui.text(c, "SamSearch", .{ .size = 44, .weight = .bold, .color = .white, .tracking = -0.5 });
            for (d.outro_lines, 0..) |line, i| {
                ui.key(c, c.print("outro-{d}", .{i}));
                const lf = motion.frame(c, .{ .initial = .{ .opacity = 0, .y = 8 }, .delay = 0.25 + motion.stagger(i, 0.18), .transition = .{ .spring = view.spring } });
                const l = ui.div(c).row().gap(8).itemsCenter().motion(lf);
                defer l.end();
                ui.icon(c, "checkmark", .{ .size = 13, .weight = .bold, .color = .hex(0x30d158) });
                ui.text(c, line, .{ .size = 17, .weight = .medium, .color = ui.Color.white.alpha(0.9), .tabular = true });
            }
            ui.div(c).h(4).end();
            const k = ui.div(c).row().gap(10).itemsCenter();
            defer k.end();
            ui.text(c, "github.com/Samin12/samsearch", .{ .size = 14, .mono = true, .color = ui.Color.white.alpha(0.7) });
            ui.text(c, "·", .{ .size = 14, .color = ui.Color.white.alpha(0.5) });
            ui.text(c, "⌘Space", .{ .size = 14, .weight = .semibold, .color = ui.Color.white.alpha(0.85) });
        }
    }

    fn desktop(d: *Stage, c: *ui.Context) void {
        const w = ui.div(c).absolute().offset(0, 0).size(width, height).bg(.hex(0x203a5c));
        defer w.end();
        if (d.wall) |bytes| _ = ui.image(c, .{ .key = "wallpaper", .bytes = bytes, .max_width = width, .max_height = height, .radius = 0, .scale = 2 });
    }

    fn menuBar(d: *Stage, c: *ui.Context) void {
        const bar = ui.div(c).absolute().offset(0, 0).size(width, 28).row().px(18).gap(20).itemsCenter().bg(ui.Color.black.alpha(0.12));
        defer bar.end();
        const st: ui.TextStyle = .{ .size = 13.5, .weight = .medium, .color = .white };
        ui.text(c, "\u{F8FF}", .{ .size = 15, .color = .white });
        ui.text(c, "Finder", .{ .size = 13.5, .weight = .bold, .color = .white });
        for ([_][]const u8{ "File", "Edit", "View", "Go", "Window", "Help" }) |m| ui.text(c, m, st);
        ui.spacer(c);
        {
            const on = ui.div(c).row().px(6).h(22).itemsCenter().rounded(6).bg(ui.Color.white.alpha(if (d.shown) 0.25 else 0));
            defer on.end();
            ui.icon(c, "magnifyingglass", .{ .size = 13, .weight = .semibold, .color = .white });
        }
        ui.icon(c, "wifi", .{ .size = 14, .weight = .medium, .color = .white });
        ui.icon(c, "battery.75percent", .{ .size = 16, .color = .white });
        ui.text(c, "Sun 1 Nov  9:41", st);
    }

    /// The cover's words, left of the panel.
    fn title(c: *ui.Context) void {
        const t = ui.div(c).absolute().offset(64, 168).w(420).column().gap(14);
        defer t.end();
        view.appIcon(c, 96);
        ui.text(c, "SamSearch", .{ .size = 66, .weight = .bold, .color = .white, .tracking = -1.2 });
        ui.text(c, "Ask about your screen, start a T3 thread, find any file. One keystroke away.", .{ .size = 23, .weight = .medium, .color = ui.Color.white.alpha(0.88), .wrap = true, .line_height = 30 });
        const k = ui.div(c).row().gap(10).pt(8).itemsCenter();
        defer k.end();
        {
            const cap = ui.div(c).row().px(12).h(32).itemsCenter().rounded(9).glass(.{ .tint = ui.Color.black.alpha(0.35) }).border(ui.Color.white.alpha(0.22));
            defer cap.end();
            ui.text(c, "⌃ Space", .{ .size = 15, .weight = .semibold, .color = .white });
        }
        ui.text(c, "· Zig, Haiku, T3 Code, DigUp", .{ .size = 15, .weight = .medium, .color = ui.Color.white.alpha(0.7) });
    }

    pub fn pressed(d: *Stage, now: f64, key: []const u8) void {
        d.key = key;
        d.key_at = now;
    }
};
