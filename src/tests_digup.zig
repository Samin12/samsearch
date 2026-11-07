//! Inline DigUp rows keep the panel's height, keys and file actions.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const view = @import("view.zig");
const results = @import("results.zig");
const files = @import("files.zig");
const digup = @import("digup.zig");
const Index = @import("apps.zig").Index;
const tests = @import("tests.zig");

fn hits(out: *digup.List) !void {
    try std.testing.expect(digup.decode(std.testing.allocator,
        \\{"hits":[{"path":"/tmp/report.pdf","kind":"pdf"},{"path":"/tmp/notes.md","kind":"doc"},{"path":"/tmp/photo.png","kind":"image"}],"strong":3}
    , out));
}

test "DigUp spends completion room, preserving local rows, handoffs and height" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    for ([_][]const u8{ "Home", "Hopper", "Hotspot Shield", "Photos", "Shortcuts", "Photo Booth" }) |n| {
        var buf: [128]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    for (0..results.max_apps) |i| {
        var name: [32]u8 = undefined;
        var path: [64]u8 = undefined;
        try ix.add(try std.fmt.bufPrint(&name, "Report {d}", .{i}), try std.fmt.bufPrint(&path, "/Applications/Report{d}.app", .{i}));
    }
    const web = [_][]const u8{ "home", "hola", "hotmail", "hotel" };
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    for ([_][]const u8{ "ho", "home", "report", "settings", "login items", "2fa codes", "invoice" }) |query| {
        for (0..6) |file_count| {
            found.deinit();
            for (0..file_count) |i| {
                var buf: [64]u8 = undefined;
                found.add(try std.fmt.bufPrint(&buf, "/tmp/hit{d}", .{i}), false, .{ .score = 1 });
            }
            var base: results.Results = .{};
            base.build(query, &ix, &.{}, &web, &found);
            for (0..4) |hit_count| {
                var s: view.Nanolight = .{ .index = &ix };
                s.res.buildWithDigup(query, &ix, &.{}, &web, &found, hit_count);
                try t.expect(s.height() <= view.max_height);
                var local: usize = 0;
                for (base.slice()) |r| switch (r.kind) {
                    .app, .pane, .file, .settings => {
                        try t.expectEqual(r.kind, s.res.rows[local].kind);
                        try t.expectEqual(r.app, s.res.rows[local].app);
                        local += 1;
                    },
                    else => {},
                };
                var seen_google = false;
                var seen_hit = false;
                for (s.res.slice(), 0..) |r, i| {
                    if (r.kind == .digup_hit) {
                        try t.expect(!seen_google);
                        try t.expect(i >= local);
                        if (!seen_hit) try t.expectEqualStrings("DigUp", s.res.section(i).?);
                        seen_hit = true;
                    }
                    if (r.kind == .search_web) seen_google = true;
                }
                try t.expectEqual(results.Kind.quick_ask, s.res.rows[s.res.rowFor(1).?].kind);
                try t.expectEqual(results.Kind.new_thread, s.res.rows[s.res.rowFor(2).?].kind);
                try t.expectEqual(results.Kind.digup, s.res.rows[s.res.rowFor(3).?].kind);
                if (std.mem.eql(u8, query, "report") and file_count == 0 and hit_count == 3) {
                    // Apps still lead, and at least one hit fits a full app list.
                    try t.expectEqual(results.Kind.app, s.res.rows[0].kind);
                    try t.expect(seen_hit);
                    try t.expectEqual(@as(usize, results.max_apps), local);
                    try t.expectEqual(results.Kind.digup_hit, s.res.rows[results.max_apps].kind);
                }
            }
        }
    }
    var r: results.Results = .{};
    r.buildWithDigup("invoice", &ix, &.{}, &web, &.{}, 3);
    for (0..3) |i| {
        try t.expectEqual(results.Kind.digup_hit, r.rows[i].kind);
        try t.expectEqual(@as(?u8, @intCast(4 + i)), r.number(i));
    }
    r.buildWithDigup("2+2", &ix, &.{}, &web, &.{}, 3);
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(results.Kind.calc, r.rows[0].kind);
    r.buildWithDigup("", &ix, &.{0}, &web, &.{}, 3);
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(results.Kind.app, r.rows[0].kind);
}

const Probe = struct {
    probe: tests.Probe = .{},
    revealed: []const u8 = "",
    queries: usize = 0,

    fn open(ctx: *anyopaque, path: []const u8) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        @memcpy(p.probe.opened[0..path.len], path);
        p.probe.opened_len = path.len;
    }

    fn hide(ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.probe.hidden = true;
    }

    fn reveal(ctx: *anyopaque, path: []const u8) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.revealed = path;
    }

    fn ask(ctx: *anyopaque, _: []const u8) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.queries += 1;
    }
};

test "inline DigUp answers drop stale hits, preserve selection, open and reveal files" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var probe: Probe = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.dug.deinit();
    s.host = .{ .ctx = &probe, .open = Probe.open, .hide = Probe.hide, .reveal = Probe.reveal, .digup = Probe.ask };
    s.reveal();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    tests.press(&tester, &.{.{ .insert = "invoice" }});
    var answer: digup.List = .{ .found = .{ .allocator = t.allocator } };
    defer answer.deinit();
    try hits(&answer);
    s.digupAnswered("old query", &answer);
    try t.expectEqual(@as(usize, 0), s.dug.found.n);
    s.sel = s.res.rowFor(2).?;
    s.digupAnswered("invoice", &answer);
    try t.expectEqual(results.Kind.new_thread, s.res.rows[s.sel].kind);
    try t.expectEqual(@as(usize, 0), answer.found.n);
    tester.settle(1);
    try t.expect(tester.hasText("DigUp"));
    try t.expect(tester.hasText("report.pdf"));
    try t.expect(tester.containsText("pdf · /tmp"));
    s.sel = 0;
    try t.expectEqualStrings("/tmp/report.pdf", s.filePath(s.res.rows[0]).?);
    try t.expect(tester.shortcut(.{ .key = 'r', .cmd = true }));
    try t.expectEqualStrings("/tmp/report.pdf", probe.revealed);
    try t.expect(!probe.probe.hidden);
    // Google completions do not displace a selected DigUp hit.
    var web: @import("suggest.zig").List = .{};
    web.push("invoice sample");
    s.answered("invoice", &web);
    try t.expectEqual(results.Kind.digup_hit, s.res.rows[s.sel].kind);
    tests.press(&tester, &.{.{ .command = .insert_newline }});
    try t.expectEqualStrings("/tmp/report.pdf", probe.probe.opened[0..probe.probe.opened_len]);
    try t.expect(probe.probe.hidden);
    // Typing clears semantic hits immediately, rather than relabeling old answers.
    tests.press(&tester, &.{.{ .insert = "s" }});
    try t.expectEqual(@as(usize, 0), s.dug.found.n);
    s.digup_on = false;
    try hits(&answer);
    s.digupAnswered("invoices", &answer);
    try t.expectEqual(@as(usize, 0), s.dug.found.n);
    try t.expect(probe.queries > 0);
}

test "DigUp's setting is on by default, persists, and fits with the footer" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    var s: view.Nanolight = .{ .index = &ix, .kv = mem.store() };
    defer s.query.deinit();
    s.openSettings();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    try t.expect(s.digup_on);
    try tester.clickText("Search DigUp as you type");
    try t.expect(!s.digup_on);
    const value = (try mem.store().get(t.allocator, digup.enabled_key)).?;
    defer t.allocator.free(value);
    try t.expectEqualStrings("0", value);
    const quit = tester.findText("Quit SamSearch").?;
    const back = tester.findText("Back").?;
    try t.expect(quit.y + quit.h < back.y);
    try t.expect(s.height() <= view.max_height);
    try tester.clickText("Search DigUp as you type");
    try t.expect(s.digup_on);
}

test "DigUp refills never cache Google stand-ins and cleared hits force a refill" {
    const t = std.testing;
    const suggest = @import("suggest.zig");
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.dug.deinit();
    var web: suggest.List = .{};
    web.push("invoice example");
    s.cache.put("invo", &web);
    s.query.set("invoice");
    s.rebuild();
    try t.expectEqual(@as(usize, 1), s.web.n);
    const generation = s.pipeline.generation;
    const google_key = s.res.rows[s.res.rowFor(4).?].key;
    var answer: digup.List = .{ .found = .{ .allocator = t.allocator } };
    defer answer.deinit();
    try hits(&answer);
    s.digupAnsweredGeneration(generation, &answer);
    try t.expect(google_key.eql(s.res.rows[s.res.rowFor(4).?].key));
    var out: suggest.List = .{};
    try t.expect(!s.cache.lookup("invoice", &out));
    try t.expectEqual(@as(usize, 1), out.n);
    const hit_key = s.res.rows[0].key;
    s.dug.deinit();
    try t.expect(s.rowByKey(hit_key) == null);
    s.rebuild();
    try t.expectEqual(generation, s.pipeline.generation);
    for (s.res.slice()) |r| try t.expect(r.kind != .digup_hit);
}

test "DigUp rejects old generations, reports failure and retries a timeout once" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.dug.deinit();
    s.query.set("invoice");
    s.rebuild();
    const old = s.pipeline.generation;
    s.query.set("report");
    s.rebuild();
    s.query.set("invoice");
    s.rebuild();
    var answer: digup.List = .{ .found = .{ .allocator = t.allocator } };
    defer answer.deinit();
    try hits(&answer);
    s.digupAnsweredGeneration(old, &answer);
    try t.expectEqual(@as(usize, 0), s.dug.found.n);
    try t.expectEqual(@as(usize, 3), answer.found.n);
    s.digupAnsweredGeneration(s.pipeline.generation, &answer);
    s.digupAnsweredGeneration(s.pipeline.generation, null);
    try t.expectEqual(@as(usize, 0), s.dug.found.n);
    try t.expectEqual(@import("search.zig").Status.failed, s.pipeline.status(.digup));
    try t.expect(digup.retry(true, 0));
    try t.expect(!digup.retry(true, 1));
    try t.expect(!digup.retry(false, 0));
}

test "DigUp selection and shortcuts follow paths when the ranking changes" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.dug.deinit();
    s.query.set("invoice");
    s.rebuild();
    var answer: digup.List = .{ .found = .{ .allocator = t.allocator } };
    defer answer.deinit();
    try hits(&answer);
    s.digupAnsweredGeneration(s.pipeline.generation, &answer);
    s.sel = 1;
    const selected = s.selectedKey().?;
    const number = s.res.number(s.sel);
    try t.expect(digup.decode(t.allocator,
        \\{"hits":[{"path":"/tmp/notes.md"},{"path":"/tmp/report.pdf"}],"strong":2}
    , &answer));
    s.digupAnsweredGeneration(s.pipeline.generation, &answer);
    try t.expect(selected.eql(s.selectedKey().?));
    try t.expectEqual(@as(usize, 0), s.sel);
    try t.expectEqual(number, s.res.number(s.sel));
    try t.expectEqualStrings("/tmp/notes.md", s.filePath(s.rowByKey(selected).?).?);
}
