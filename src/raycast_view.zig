//! A Raycast extension's command, drawn in the panel in place of the rows
//! while it runs: its list (a search field over sections of items), its
//! detail (markdown as text) or its form, with its actions in the footer
//! (Return the first, ⌘↩/Ctrl+↩ the second, ⌘K/Ctrl+K all of them). What
//! it shows comes from its host process (raycast.zig) as `View`s; keys and
//! choices go back as messages (raycast_model.zig's `say`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("raycast_model.zig");
const pview = @import("view.zig");
const results = @import("results.zig");
const Palette = pview.Palette;

const row_h: f32 = 44;
const section_h: f32 = 26;
const pad: f32 = 6;
const max_fields = 12;

fn isTyped(kind: []const u8) bool {
    for ([_][]const u8{ "text", "textarea", "password" }) |k| if (std.mem.eql(u8, kind, k)) return true;
    return false;
}

fn hasArea(v: model.View) bool {
    for (v.fields) |f| if (std.mem.eql(u8, f.type, "textarea")) return true;
    return false;
}

pub const Sender = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, line: []const u8) void };

pub const Ext = struct {
    gpa: std.mem.Allocator,
    open: bool = false,
    /// The command's name and its extension's icon (PNG), for the header.
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    icon: ?[]const u8 = null,
    /// The top view and the arena it lives in (one per render).
    arena: ?std.heap.ArenaAllocator = null,
    view: ?model.View = null,
    query: ui.TextBuffer = .{},
    sent: u64 = 0,
    sel: usize = 0,
    actions_open: bool = false,
    act_sel: usize = 0,
    took_return: bool = false,
    /// A toast or HUD, said in the footer for a while.
    note_buf: [200]u8 = undefined,
    note_len: usize = 0,
    note_at: f64 = -10,
    note_bad: bool = false,
    /// What the host is told.
    to: ?Sender = null,
    /// Item icons from files, read once.
    files: std.StringHashMapUnmanaged(?[]u8) = .empty,
    /// A form's text fields and switches, by the field's place.
    fields: [max_fields]ui.TextBuffer = @splat(.{}),
    checks: [max_fields]bool = @splat(false),
    form_key: u64 = 0,
    /// The field that has the keys once the command's screen goes (the
    /// panel's search).
    back: ?*ui.TextBuffer = null,

    pub fn start(e: *Ext, name: []const u8, icon: ?[]const u8, to: Sender) void {
        e.stop();
        const n = @min(name.len, e.name_buf.len);
        @memcpy(e.name_buf[0..n], name[0..n]);
        e.name_len = n;
        e.icon = icon;
        e.to = to;
        e.open = true;
        e.query.clear();
        e.query.focus();
        e.sent = std.hash.Wyhash.hash(0, "");
    }

    pub fn stop(e: *Ext) void {
        e.open = false;
        e.view = null;
        if (e.arena) |*a| a.deinit();
        e.arena = null;
        e.sel = 0;
        e.actions_open = false;
        e.note_len = 0;
        e.form_key = 0;
        if (e.back) |b| b.focus();
    }

    pub fn deinit(e: *Ext) void {
        e.stop();
        var it = e.files.iterator();
        while (it.next()) |kv| {
            e.gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |b| e.gpa.free(b);
        }
        e.files.deinit(e.gpa);
        e.query.deinit();
        for (&e.fields) |*f| f.deinit();
    }

    /// The host's new top view; `arena` holds it and is now this one's.
    pub fn show(e: *Ext, arena: std.heap.ArenaAllocator, v: model.View) void {
        // The old view lives in the old arena: read it before freeing that.
        const was_list = if (e.view) |old| old.isList() else true;
        e.view = v;
        if (e.arena) |*a| a.deinit();
        e.arena = arena;
        // A new kind of view (a push, a pop) starts at the top.
        if (!v.isList() or !was_list) e.sel = 0;
        if (v.isList()) {
            if (v.selected) |id| for (0..v.count()) |i| if (std.mem.eql(u8, v.item(i).?.id, id)) {
                e.sel = i;
            };
            e.sel = @min(e.sel, v.count() -| 1);
        }
        if (v.isForm()) e.loadForm(v);
    }

    /// Says `text` in the footer for a while, from the next frame.
    pub fn note(e: *Ext, text: []const u8, bad: bool) void {
        const n = @min(text.len, e.note_buf.len);
        @memcpy(e.note_buf[0..n], text[0..n]);
        e.note_len = n;
        e.note_bad = bad;
        e.note_at = -1;
    }

    fn say(e: *Ext, kind: []const u8, field: ?[]const u8, value: anytype) void {
        const to = e.to orelse return;
        var buf: [4096]u8 = undefined;
        const line = model.say(&buf, kind, field, value) catch return;
        to.func(to.ctx, line);
    }

    fn run(e: *Ext, a: model.Action) void {
        e.actions_open = false;
        e.say("action", "id", a.id);
    }

    pub fn height(e: *const Ext) f32 {
        const v = e.view orelse return pview.header_h + pview.footer_h + 80;
        const chrome: f32 = pview.header_h + pview.footer_h + 2;
        // As tall as what is shown, no taller.
        if (e.actions_open) {
            const n: f32 = @floatFromInt(v.actionsAt(e.sel).len);
            return @min(chrome + pad * 2 + section_h + n * 38, pview.max_height);
        }
        if (v.isForm()) return @min(chrome + 32 + @as(f32, @floatFromInt(@max(v.fields.len, 1))) * 44, pview.max_height);
        if (!v.isList()) {
            var lines: f32 = 0;
            if (v.output) |out| {
                lines = @floatFromInt(@min(std.mem.count(u8, std.mem.trimEnd(u8, out, "\n"), "\n") + 1, 200));
                return @min(@max(chrome + 36 + lines * 19, 150), pview.max_height);
            }
            const md = v.markdown orelse "";
            lines = @floatFromInt(std.mem.count(u8, md, "\n") + 1);
            // Long paragraphs wrap: about 80 characters a line.
            lines += @floatFromInt(md.len / 80);
            return @min(@max(chrome + 46 + lines * 24 + @as(f32, @floatFromInt(v.metadata.len)) * 22, 150), pview.max_height);
        }
        var h: f32 = chrome + pad * 2;
        if (v.count() == 0) return h + 80;
        for (v.sections) |s| {
            if (s.items.len == 0) continue;
            if (s.title) |t| if (t.len > 0) {
                h += section_h;
            };
            h += @as(f32, @floatFromInt(s.items.len)) * row_h;
        }
        return @min(h, pview.max_height);
    }

    /// The command in the panel (Nanolight.panel calls it while `open`).
    pub fn panel(e: *Ext, c: *ui.Context, n: *pview.Nanolight, p: Palette) void {
        const h = n.follow(c, e.height());
        const body = ui.div(c).column().wFull().h(h).clip();
        defer body.end();
        const v = e.view;
        const acts: []const model.Action = if (v) |vv| vv.actionsAt(e.sel) else &.{};
        e.keys(c, acts);
        e.header(c, p);
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const mid = ui.div(c).column().wFull().grow().clip();
        if (e.actions_open) {
            e.actionList(c, p, acts);
        } else if (v) |vv| {
            if (vv.isList()) e.list(c, p, vv) else if (vv.isForm()) e.form(c, p, vv) else e.detail(c, p, vv);
        } else {
            const w = ui.div(c).wFull().h(80).center();
            ui.text(c, "Starting…", .{ .size = 13, .color = p.sub.alpha(0.8) });
            w.end();
        }
        mid.end();
        e.footer(c, p, acts);
    }

    fn keys(e: *Ext, c: *ui.Context, acts: []const model.Action) void {
        const S = ui.Shortcut;
        const v = e.view;
        const n = if (e.actions_open) acts.len else if (v) |vv| (if (vv.isList()) vv.count() else 0) else 0;
        const sel = if (e.actions_open) &e.act_sel else &e.sel;
        const before = e.sel;
        if (c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true })) {
            if (n > 0) sel.* = (sel.* + 1) % n;
        }
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) {
            if (n > 0) sel.* = (sel.* + n - 1) % n;
        }
        if (!e.actions_open and e.sel != before) if (v) |vv| if (vv.item(e.sel)) |it| e.say("select", "id", it.id);
        if (c.shortcut(.{ .key = 'k', .cmd = true })) {
            e.actions_open = !e.actions_open and acts.len > 0;
            e.act_sel = 0;
        }
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) {
            // A form submits with its first action, as Raycast's does.
            const k: usize = if (v != null and v.?.isForm()) 0 else 1;
            if (acts.len > k) e.run(acts[k]);
        }
        const ret = c.input.key == .enter or for (c.input.ops) |op| {
            if (op == .command and op.command == .insert_newline) break true;
        } else false;
        if (!ret) e.took_return = false;
        // A form takes Return as a new line only in a text area.
        const form_keeps = v != null and v.?.isForm() and hasArea(v.?) and !e.actions_open;
        if (ret and !e.took_return and !form_keeps) {
            e.took_return = true;
            if (e.actions_open) {
                if (e.act_sel < acts.len) e.run(acts[e.act_sel]);
            } else if (acts.len > 0) e.run(acts[0]);
        }
        if (c.shortcut(.{ .key = S.escape })) {
            if (e.actions_open) {
                e.actions_open = false;
            } else if (e.query.text().len > 0 and v != null and v.?.isList()) {
                e.query.clear();
            } else e.say("pop", null, null);
        }
    }

    fn header(e: *Ext, c: *ui.Context, p: Palette) void {
        const bar = ui.div(c).row().wFull().h(pview.header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        const back = ui.div(c).size(26, 26).center().rounded(7).bg(p.tile).control();
        if (back.clicked()) e.say("pop", null, null);
        ui.icon(c, "chevron.left", .{ .size = 13, .weight = .semibold, .color = p.sub });
        back.end();
        const v = e.view;
        if (v == null or v.?.isList()) {
            const ph = if (v) |vv| (if (vv.placeholder) |s| (if (s.len > 0) s else null) else null) else null;
            _ = ui.textField(c, &e.query, .{
                .bare = true,
                .size = 19,
                .width = .fill,
                .placeholder = ph orelse c.print("Search {s}…", .{e.name_buf[0..e.name_len]}),
                .placeholder_color = p.sub.alpha(0.75),
                .color = p.text,
            });
            const h = std.hash.Wyhash.hash(0, e.query.text());
            if (h != e.sent) {
                e.sent = h;
                e.sel = 0;
                e.say("search", "text", e.query.text());
            }
        } else {
            const t = v.?.title orelse "";
            ui.text(c, if (t.len > 0) t else e.name_buf[0..e.name_len], .{ .size = 17, .weight = .semibold, .color = p.text, .truncate = .ellipsis });
            ui.spacer(c);
        }
        if (v) |vv| if (vv.loading) ui.text(c, "Loading…", .{ .size = 12, .color = p.sub.alpha(0.7) });
    }

    fn list(e: *Ext, c: *ui.Context, p: Palette, v: model.View) void {
        if (v.count() == 0) {
            const box = ui.div(c).column().wFull().h(80).center().gap(4);
            defer box.end();
            const empty = v.empty orelse model.Empty{};
            ui.text(c, empty.title orelse (if (v.loading) "Loading…" else "No Results"), .{ .size = 14, .weight = .medium, .color = p.text });
            if (empty.description) |d| ui.text(c, d, .{ .size = 12, .color = p.sub });
            return;
        }
        const rows = ui.div(c).column().wFull().px(8).py(pad).grow().scrollY();
        defer rows.end();
        var i: usize = 0;
        for (v.sections, 0..) |s, si| {
            if (s.items.len == 0) continue;
            if (s.title) |t| if (t.len > 0) {
                ui.key(c, c.print("rc-sec-{d}", .{si}));
                const sh = ui.div(c).row().wFull().h(section_h).px(12).itemsEnd().pb(4);
                ui.text(c, t, .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
                sh.end();
            };
            for (s.items) |*it| {
                e.row(c, p, it, i);
                i += 1;
            }
        }
    }

    fn row(e: *Ext, c: *ui.Context, p: Palette, it: *const model.Item, i: usize) void {
        ui.key(c, c.print("rc-row-{d}", .{i}));
        const r = ui.div(c).row().wFull().h(row_h).px(12).gap(12).itemsCenter().rounded(10).control();
        defer r.end();
        if (i == e.sel) _ = r.bg(p.sel).border(p.rim);
        if (r.clicked()) {
            if (e.sel == i) {
                if (it.actions.len > 0) e.run(it.actions[0]);
            } else {
                e.sel = i;
                e.say("select", "id", it.id);
            }
        }
        e.iconTile(c, p, it.icon, i);
        ui.text(c, it.title, .{ .size = 14, .weight = .medium, .color = p.text, .truncate = .ellipsis });
        if (it.subtitle) |sub| if (sub.len > 0) ui.text(c, sub, .{ .size = 12.5, .color = p.sub.alpha(0.85), .truncate = .ellipsis });
        ui.spacer(c);
        for (it.accessories) |a| if (a.len > 0) ui.text(c, a, .{ .size = 12, .color = p.sub.alpha(0.7), .tabular = true });
    }

    fn iconTile(e: *Ext, c: *ui.Context, p: Palette, icon: ?model.Icon, i: usize) void {
        const box = ui.div(c).size(24, 24).center().rounded(6);
        defer box.end();
        const ic = icon orelse return;
        // An emoji, or a word or number (a rank) on a tile.
        if (ic.text) |t| {
            const emoji = t.len > 0 and t[0] >= 0xf0;
            if (!emoji) _ = box.bg(p.tile).border(p.rim);
            return ui.text(c, t, .{ .size = if (emoji) 15 else 12, .weight = .semibold, .color = p.text, .tabular = true });
        }
        if (ic.file) |f| if (e.fileBytes(f)) |bytes| {
            _ = ui.image(c, .{ .key = f, .bytes = bytes, .max_width = 24, .max_height = 24, .radius = 5, .scale = 1 });
            return;
        };
        _ = i;
        // A picture from the web (nothing is fetched): the extension's own
        // icon stands in; a built-in Raycast icon, a dot.
        if (ic.url != null) if (e.icon) |png| {
            _ = ui.image(c, .{ .key = e.name_buf[0..e.name_len], .bytes = png, .max_width = 20, .max_height = 20, .radius = 5, .scale = 2 });
            return;
        };
        _ = box.bg(p.tile);
        ui.icon(c, "circle", .{ .size = 9, .color = p.sub.alpha(0.6) });
    }

    fn fileBytes(e: *Ext, path: []const u8) ?[]const u8 {
        if (e.files.get(path)) |b| return b;
        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, e.gpa, .limited(4 << 20)) catch null;
        const key = e.gpa.dupe(u8, path) catch return bytes;
        e.files.put(e.gpa, key, bytes) catch {};
        return bytes;
    }

    fn detail(e: *Ext, c: *ui.Context, p: Palette, v: model.View) void {
        _ = e;
        const col = ui.div(c).column().wFull().px(26).py(18).gap(10).grow().scrollY();
        defer col.end();
        // A script's output: its lines as printed, monospaced, the last 200.
        if (v.output) |out| {
            var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
            var from: usize = out.len;
            var k: usize = 0;
            while (lines.next()) |l| : (k += 1) {
                if (k == 200) break;
                from = @intFromPtr(l.ptr) - @intFromPtr(out.ptr);
            }
            var rest = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out[@min(from, out.len)..], "\n"), '\n');
            const lines_box = ui.div(c).column().wFull().gap(4);
            defer lines_box.end();
            while (rest.next()) |line| ui.text(c, if (line.len == 0) " " else line, .{ .size = 12.5, .mono = true, .color = p.text });
            return;
        }
        var buf: [8192]u8 = undefined;
        const text = model.plain(&buf, v.markdown orelse "");
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // `buf` is this call's; the frame draws the text after it returns.
            ui.text(c, c.print("{s}", .{line}), .{ .size = if (first) 19 else 14, .weight = if (first) .semibold else .regular, .color = p.text, .wrap = true });
            first = false;
        }
        if (v.metadata.len > 0) {
            ui.div(c).wFull().h(1).bg(p.hair).end();
            for (v.metadata) |m| {
                const r = ui.div(c).row().wFull().gap(10);
                ui.text(c, m.label, .{ .size = 12, .weight = .medium, .color = p.sub });
                ui.spacer(c);
                ui.text(c, m.text orelse "", .{ .size = 12, .color = p.text });
                r.end();
            }
        }
    }

    fn loadForm(e: *Ext, v: model.View) void {
        var h = std.hash.Wyhash.init(0);
        for (v.fields) |f| h.update(f.id);
        const key = h.final();
        if (key == e.form_key) return;
        e.form_key = key;
        var focused = false;
        for (v.fields[0..@min(v.fields.len, max_fields)], 0..) |f, i| {
            switch (f.value) {
                .string => |s| e.fields[i].set(s),
                .bool => |b| e.checks[i] = b,
                else => e.fields[i].clear(),
            }
            // The first field typed into has the keys.
            if (!focused and isTyped(f.type)) {
                e.fields[i].focus();
                focused = true;
            }
        }
    }

    fn form(e: *Ext, c: *ui.Context, p: Palette, v: model.View) void {
        const col = ui.div(c).column().wFull().px(26).py(16).gap(12).grow().scrollY();
        defer col.end();
        for (v.fields[0..@min(v.fields.len, max_fields)], 0..) |f, i| {
            ui.key(c, c.print("rc-field-{d}", .{i}));
            const t = f.type;
            if (std.mem.eql(u8, t, "separator")) {
                ui.div(c).wFull().h(1).bg(p.hair).end();
                continue;
            }
            if (std.mem.eql(u8, t, "description")) {
                ui.text(c, f.title orelse "", .{ .size = 12.5, .color = p.sub, .wrap = true });
                continue;
            }
            const r = ui.div(c).row().wFull().gap(14).itemsCenter();
            defer r.end();
            const lab = ui.div(c).w(130);
            ui.text(c, f.title orelse f.id, .{ .size = 13, .weight = .medium, .color = p.sub, .truncate = .ellipsis });
            lab.end();
            if (std.mem.eql(u8, t, "checkbox")) {
                if (ui.toggle(c, "", &e.checks[i])) e.fieldValue(f.id, .{ .bool = e.checks[i] });
            } else if (std.mem.eql(u8, t, "dropdown")) {
                const opts = ui.div(c).row().gap(6);
                defer opts.end();
                for (f.options[0..@min(f.options.len, 4)]) |o| {
                    const on = f.value == .string and std.mem.eql(u8, f.value.string, o.value);
                    const b = ui.div(c).h(26).px(10).center().rounded(7).bg(if (on) p.sel else p.tile).control();
                    if (b.clicked()) e.fieldValue(f.id, .{ .string = o.value });
                    ui.text(c, o.title, .{ .size = 12, .color = p.text });
                    b.end();
                }
            } else {
                const box = ui.div(c).grow().h(32).px(10).itemsCenter().row().rounded(8).bg(p.tile).border(p.rim);
                defer box.end();
                const before = std.hash.Wyhash.hash(0, e.fields[i].text());
                _ = ui.textField(c, &e.fields[i], .{ .bare = true, .size = 14, .width = .fill, .placeholder = f.placeholder orelse "", .color = p.text, .placeholder_color = p.sub.alpha(0.6) });
                if (std.hash.Wyhash.hash(0, e.fields[i].text()) != before) e.fieldValue(f.id, .{ .string = e.fields[i].text() });
            }
        }
    }

    fn fieldValue(e: *Ext, id: []const u8, value: std.json.Value) void {
        const to = e.to orelse return;
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var s: std.json.Stringify = .{ .writer = &w };
        s.beginObject() catch return;
        s.objectField("type") catch return;
        s.write("field") catch return;
        s.objectField("id") catch return;
        s.write(id) catch return;
        s.objectField("value") catch return;
        s.write(value) catch return;
        s.endObject() catch return;
        w.writeByte('\n') catch return;
        to.func(to.ctx, w.buffered());
    }

    fn actionList(e: *Ext, c: *ui.Context, p: Palette, acts: []const model.Action) void {
        const col = ui.div(c).column().wFull().px(8).py(pad).grow().scrollY();
        defer col.end();
        const t = ui.div(c).row().wFull().h(section_h).px(12).itemsEnd().pb(4);
        ui.text(c, "Actions", .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
        t.end();
        for (acts, 0..) |a, i| {
            ui.key(c, c.print("rc-act-{d}", .{i}));
            const r = ui.div(c).row().wFull().h(38).px(12).gap(10).itemsCenter().rounded(9).control();
            if (i == e.act_sel) _ = r.bg(p.sel).border(p.rim);
            if (r.clicked()) e.run(a);
            ui.text(c, a.title, .{ .size = 13.5, .weight = .medium, .color = p.text });
            ui.spacer(c);
            if (i == 0) ui.kbd(c, "↩") else if (i == 1) ui.kbd(c, results.mod ++ "↩");
            r.end();
        }
    }

    fn footer(e: *Ext, c: *ui.Context, p: Palette, acts: []const model.Action) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(pview.footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        if (e.icon) |png| _ = ui.image(c, .{ .key = e.name_buf[0..e.name_len], .bytes = png, .max_width = 16, .max_height = 16, .radius = 4, .scale = 2 });
        if (e.note_len > 0 and e.note_at == -1) e.note_at = c.time;
        if (e.note_len > 0 and c.time - e.note_at < 2.5) {
            ui.text(c, e.note_buf[0..e.note_len], .{ .size = 12, .weight = .medium, .color = if (e.note_bad) c.theme.danger else p.text, .truncate = .ellipsis });
            c.animationFrame();
        } else ui.text(c, e.name_buf[0..e.name_len], .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis });
        ui.spacer(c);
        if (acts.len == 0) return;
        const v = e.view;
        const form_view = v != null and v.?.isForm();
        ui.text(c, acts[0].title, .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
        ui.kbd(c, if (form_view and hasArea(v.?)) results.mod ++ "↩" else "↩");
        if (acts.len > 1) {
            ui.div(c).w(1).h(14).bg(p.hair).end();
            ui.text(c, "Actions", .{ .size = 12, .color = p.sub.alpha(0.8) });
            ui.kbd(c, results.mod ++ "K");
        }
    }
};
