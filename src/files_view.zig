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

/// Worker answers carry the query generation, never a text comparison.
pub fn filesAnsweredGeneration(s: *Nanolight, generation: u64, found: ?*files.List) void {
    s.rebuild();
    if (!s.files_on or !s.pipeline.finish(generation, .files, if (found != null) .answered else .failed)) return;
    const was = s.selectedKey();
    if (found) |list| s.found.replace(list) else s.found.deinit();
    s.refillSelected(was);
}

pub fn filesAnswered(s: *Nanolight, typed: []const u8, found: *files.List) void {
    if (!std.mem.eql(u8, typed, std.mem.trim(u8, s.query.text(), " \t\r\n"))) return;
    s.rebuild();
    filesAnsweredGeneration(s, s.pipeline.generation, found);
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
        if (s.host) |host| if (host.files) |ask| {
            s.pipeline.set(.files, .pending);
            ask(host.ctx, q);
        };
    } else {
        s.found.deinit();
        if (s.host) |host| if (host.files) |ask| ask(host.ctx, q);
    }
}

pub fn takeOnTab(s: *Nanolight, c: *ui.Context) bool {
    if (s.sel >= s.res.n or s.res.rows[s.sel].kind != .file or !files.isPath(s.query.text())) return false;
    if (c.shortcut(.{ .key = ui.Shortcut.tab })) takeFile(s, s.res.rows[s.sel].file);
    return true;
}
