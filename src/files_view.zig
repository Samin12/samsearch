//! File rows and the answer transferred from the lookup worker.
const std = @import("std");
const ui = @import("nanoui").ui;
const files = @import("files.zig");
const Nanolight = @import("view.zig").Nanolight;
const Palette = @import("palette.zig").Palette;
const Row = @import("results.zig").Row;

pub fn takeFile(s: *Nanolight, i: usize) void {
    const e = &s.found.entries[i];
    var buf: [files.max_path + 1]u8 = undefined;
    const path = e.path();
    const text = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, if (e.folder and !std.mem.endsWith(u8, path, "/")) "/" else "" }) catch return;
    s.query.set(text);
    s.query.want_selection = .{ text.len, text.len };
}

/// A Spotlight answer lands only for the query still in the field.
pub fn filesAnswered(s: *Nanolight, typed: []const u8, found: *files.List) void {
    if (!s.files_on or !std.mem.eql(u8, typed, std.mem.trim(u8, s.query.text(), " \t\r\n"))) return;
    const was: ?Row = if (s.sel < s.res.n) s.res.rows[s.sel] else null;
    var path: [files.max_path]u8 = undefined;
    var path_len: usize = 0;
    if (was) |r| if (r.kind == .file) {
        const p = s.found.entries[r.file].path();
        @memcpy(path[0..p.len], p);
        path_len = p.len;
    };
    s.found.replace(found);
    s.fill();
    s.sel = 0;
    const r = was orelse return;
    for (s.res.slice(), 0..) |now, i| {
        if (now.kind != r.kind) continue;
        const same = switch (r.kind) {
            .app, .pane => now.app == r.app,
            .file => std.mem.eql(u8, s.found.entries[now.file].path(), path[0..path_len]),
            .suggest => now.web == r.web,
            .digup_hit => now.file == r.file,
            else => true,
        };
        if (same) {
            s.sel = i;
            return;
        }
    }
}

pub fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const e = &s.found.entries[r.file];
    ui.richText(c, e.name(), s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
    var buf: [files.max_path]u8 = undefined;
    // `buf` is this call's; the frame draws the text after it returns.
    ui.text(c, c.print("{s}", .{files.parent(&buf, e.path())}), .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis });
    ui.text(c, if (e.folder) "Folder" else "File", .{ .size = 11.5, .color = p.sub });
}

pub fn tile(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    const e = &s.found.entries[r.file];
    if (e.png.len > 0) {
        const box = ui.div(c).size(26, 26).center();
        defer box.end();
        _ = ui.image(c, .{ .key = e.path(), .bytes = e.png, .max_width = 26, .max_height = 26, .radius = 0, .scale = 1 });
        return;
    }
    const box = ui.div(c).size(26, 26).rounded(7).bg(p.tile).center();
    defer box.end();
    ui.icon(c, if (e.folder) "folder" else "doc", .{ .size = 13, .weight = .medium, .color = p.text });
}

/// Retain matching rows while the worker answers the new query.
pub fn rebuild(s: *Nanolight) void {
    const q = std.mem.trim(u8, s.query.text(), " \t\r\n");
    if (@import("builtin").os.tag == .macos and s.files_on and
        (files.isPath(q) or (files.eligible(q) and @import("calc.zig").eval(q) == null)))
    {
        s.found.filter(q);
        if (s.host) |host| if (host.files) |ask| ask(host.ctx, q);
    } else s.found.deinit();
}

pub fn takeOnTab(s: *Nanolight, c: *ui.Context) bool {
    if (s.sel >= s.res.n or s.res.rows[s.sel].kind != .file or !files.isPath(s.query.text())) return false;
    if (c.shortcut(.{ .key = ui.Shortcut.tab })) takeFile(s, s.res.rows[s.sel].file);
    return true;
}
