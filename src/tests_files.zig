//! File search regression coverage.
const std = @import("std");
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const suggest = @import("suggest.zig");
const results = @import("results.zig");

test "files and extra section heads fit the original window" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    for ([_][]const u8{ "Safari", "Mail", "Maps", "Calendar", "Calculator", "System Settings Alpha" }) |name| {
        var buf: [64]u8 = undefined;
        try ix.add(name, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{name}));
    }
    var s: view.Nanolight = .{ .index = &ix, .files_on = true };
    defer s.query.deinit();
    defer s.found.deinit();
    // Settings adds a fifth head; "a" matches all six apps without it.
    for ([_][]const u8{ "settings", "a" }) |q| {
        s.query.set(q);
        s.rebuild();
        var four: suggest.List = .{};
        for (0..4) |i| {
            var buf: [64]u8 = undefined;
            four.push(try std.fmt.bufPrint(&buf, "{s}{d}", .{ q, i }));
        }
        for ([_]bool{ false, true }) |exact| {
            var found: @import("files.zig").List = .{ .allocator = gpa, .exact = exact };
            defer found.deinit();
            for (0..5) |i| {
                var path: [64]u8 = undefined;
                found.add(try std.fmt.bufPrint(&path, "/tmp/settings{d}", .{i}), false, .{ .score = 0 });
            }
            s.filesAnswered(q, &found);
            s.answered(q, &four);
            try std.testing.expect(s.height() <= view.max_height);
            var apps: usize = 0;
            var file_heads: usize = 0;
            for (s.res.slice(), 0..) |row, i| {
                if (row.kind == .app) apps += 1;
                if (s.res.section(i)) |head| {
                    if (std.mem.eql(u8, head, "Files")) file_heads += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, q, "settings")) 1 else 6), apps);
            try std.testing.expectEqual(@as(usize, 1), file_heads);
            if (exact) try std.testing.expectEqual(results.Kind.file, s.res.rows[0].kind);
            try std.testing.expectEqual(results.Kind.ask_grok, s.res.rows[s.res.n - 2].kind);
            try std.testing.expectEqual(results.Kind.search_x, s.res.rows[s.res.n - 1].kind);
            var google: usize = 0;
            for (s.res.slice()) |row| {
                if (row.kind == .search_web) google += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), google);
        }
    }
}

test "file tiers merge duplicates and keep exact names against many subsequences" {
    const files = @import("files.zig");
    const search = @import("search.zig");
    var found: files.List = .{};
    // The first tier's exact name must survive a later, much larger tier.
    const exact = "/files/README";
    found.add(exact, false, search.score("readme", "README").?);
    var buf: [128]u8 = undefined;
    for (0..600) |i| {
        const path = try std.fmt.bufPrint(&buf, "/files/r-e-a-d-m-e-{d}", .{i});
        found.add(path, false, search.score("readme", std.fs.path.basename(path)).?);
    }
    const prefix = "/files/README.md";
    found.add(prefix, false, search.score("readme", "README.md").?);
    // Both prefix and subsequence Spotlight queries can return earlier paths.
    found.add(exact, false, search.score("readme", "README").?);
    found.add(prefix, false, search.score("readme", "README.md").?);
    try std.testing.expectEqual(@as(usize, files.max_rows), found.n);
    try std.testing.expectEqualStrings(exact, found.entries[0].path());
    try std.testing.expectEqualStrings(prefix, found.entries[1].path());
    for (found.entries[0..found.n], 0..) |*entry, i| {
        for (found.entries[i + 1 .. found.n]) |*other| {
            try std.testing.expect(!std.mem.eql(u8, entry.path(), other.path()));
        }
    }
    // A high-ranked entry also replaces an already-full weak tier.
    var late: files.List = .{};
    for (0..600) |i| {
        const path = try std.fmt.bufPrint(&buf, "/files/r-e-a-d-m-e-{d}", .{i});
        late.add(path, false, search.score("readme", std.fs.path.basename(path)).?);
    }
    try std.testing.expectEqual(@as(usize, files.max_rows), late.n);
    late.add(exact, false, search.score("readme", "README").?);
    try std.testing.expectEqualStrings(exact, late.entries[0].path());
}

test "Spotlight predicates prioritize literal names before subsequences" {
    const files = @import("files.zig");
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("kMDItemFSName == \"readme\"cd", files.predicate(&buf, "readme", .exact).?);
    try std.testing.expectEqualStrings("kMDItemFSName == \"readme*\"cd", files.predicate(&buf, "readme", .prefix).?);
    try std.testing.expectEqualStrings("kMDItemFSName == \"* readme*\"cd", files.predicate(&buf, "readme", .word).?);
    try std.testing.expectEqualStrings("kMDItemFSName == \"*r*e*a*d*m*e*\"cd", files.predicate(&buf, "readme", .subsequence).?);
    try std.testing.expectEqualStrings("kMDItemFSName == \"a\\*\\?\\\"\\\\*\"cd", files.predicate(&buf, "a*?\"\\", .prefix).?);
}

test "name search excludes the home Library subtree by default" {
    const files = @import("files.zig");
    if (files.home().len == 0) return;
    var buf: [files.max_path]u8 = undefined;
    for ([_][]const u8{ "Library", "Library/Application Support/App/readme", "Library/Logs/readme", "Library/WebKit/readme", "Library/HTTPStorages/readme", "Library/Application Scripts/readme", "Library/Caches/readme" }) |part| {
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ files.home(), part });
        try std.testing.expect(files.excluded(path, ""));
    }
    const lookalike = try std.fmt.bufPrint(&buf, "{s}/LibraryWork/readme", .{files.home()});
    try std.testing.expect(!files.excluded(lookalike, ""));
}

test "cached path rows are filtered without directory IO" {
    const files = @import("files.zig");
    var found: files.List = .{};
    found.add("/folder", true, .{ .score = 2000 });
    found.add("/folder/README.md", false, .{ .score = 900 });
    found.add("/folder/Report", true, .{ .score = 850 });
    found.add("/elsewhere/README.md", false, .{ .score = 800 });
    found.add("/folder/.hidden", false, .{ .score = 700 });
    found.filter("/folder/");
    try std.testing.expect(found.exact);
    try std.testing.expectEqual(@as(usize, 3), found.n);
    try std.testing.expectEqualStrings("/folder", found.entries[0].path());
    found.filter("/folder/Rea");
    try std.testing.expect(!found.exact);
    try std.testing.expectEqual(@as(usize, 1), found.n);
    try std.testing.expectEqualStrings("/folder/README.md", found.entries[0].path());
    found.filter("/other/");
    try std.testing.expectEqual(@as(usize, 0), found.n);
}

test "apps, panes, files, Google and Ask & Search share the window budget" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    for (0..results.max_apps) |i| {
        var name: [64]u8 = undefined;
        var path: [128]u8 = undefined;
        try ix.add(try std.fmt.bufPrint(&name, "Login {d}", .{i}), try std.fmt.bufPrint(&path, "/Applications/Login {d}.app", .{i}));
    }
    var s: view.Nanolight = .{ .index = &ix, .files_on = true };
    defer s.query.deinit();
    defer s.found.deinit();
    s.query.set("login");
    s.rebuild();
    var found: @import("files.zig").List = .{ .allocator = t.allocator };
    defer found.deinit();
    for (0..5) |i| {
        var path: [64]u8 = undefined;
        found.add(try std.fmt.bufPrint(&path, "/tmp/login{d}", .{i}), false, .{ .score = 1 });
    }
    s.filesAnswered("login", &found);
    var web: suggest.List = .{};
    for ([_][]const u8{ "login mac", "login windows", "login iphone", "login help" }) |q| web.push(q);
    s.answered("login", &web);
    var heads: usize = 0;
    var apps = false;
    var panes = false;
    var files = false;
    var google = false;
    var ask = false;
    for (s.res.slice(), 0..) |row, i| {
        if (s.res.section(i) != null) heads += 1;
        switch (row.kind) {
            .app => apps = true,
            .pane => panes = true,
            .file => files = true,
            .search_web => google = true,
            .ask_grok => ask = true,
            else => {},
        }
    }
    try t.expect(apps and panes and files and google and ask);
    try t.expectEqual(@as(usize, 5), heads);
    try t.expectEqual(results.max_rows - 2, s.res.n);
    try t.expect(s.height() <= view.max_height);
}

test "file icon allocations survive filtering, eviction and owning replacement" {
    const t = std.testing;
    const files = @import("files.zig");
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    // Keeping paths inline is intentional; the 32 KiB icons must stay out of rows.
    try t.expect(@sizeOf(files.Entry) < files.max_path + 1024);
    for (0..files.max_rows) |i| {
        var path: [64]u8 = undefined;
        found.add(try std.fmt.bufPrint(&path, "/tmp/keep{d}", .{i}), false, .{ .score = @intCast(100 - i) });
        found.entries[i].png = try t.allocator.dupe(u8, "icon");
    }
    found.add("/tmp/keep-new", false, .{ .score = 200 });
    found.entries[0].png = try t.allocator.dupe(u8, "new icon");
    found.filter("/tmp/keep0");
    try t.expectEqual(@as(usize, 1), found.n);
    try t.expectEqualStrings("icon", found.entries[0].png);
    var destination: files.List = .{ .allocator = t.allocator };
    defer destination.deinit();
    destination.add("/tmp/old", false, .{ .score = 1 });
    destination.entries[0].png = try t.allocator.dupe(u8, "old icon");
    destination.replace(&found);
    found.deinit();
    try t.expectEqual(@as(usize, 0), found.n);
    try t.expectEqualStrings("icon", destination.entries[0].png);
    destination.filter("nothing matches");
    try t.expectEqual(@as(usize, 0), destination.n);
}

test "file answers move icons only for the current enabled query" {
    const t = std.testing;
    const files = @import("files.zig");
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix, .files_on = true };
    defer s.query.deinit();
    defer s.found.deinit();
    s.query.set("report");
    s.rebuild();
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/report", false, .{ .score = 100 });
    found.entries[0].png = try t.allocator.dupe(u8, "worker icon");
    const bytes = found.entries[0].png.ptr;
    s.filesAnswered("stale", &found);
    try t.expectEqual(@as(usize, 1), found.n);
    try t.expectEqual(@as(usize, 0), s.found.n);
    s.files_on = false;
    s.filesAnswered("report", &found);
    try t.expectEqual(@as(usize, 1), found.n);
    s.files_on = true;
    s.filesAnswered("report", &found);
    try t.expectEqual(@as(usize, 0), found.n);
    try t.expectEqual(bytes, s.found.entries[0].png.ptr);
    found.deinit();
    try t.expectEqualStrings("worker icon", s.found.entries[0].png);
    var replacement: files.List = .{ .allocator = t.allocator };
    defer replacement.deinit();
    replacement.add("/tmp/report2", false, .{ .score = 100 });
    replacement.entries[0].png = try t.allocator.dupe(u8, "replacement");
    s.filesAnswered("report", &replacement);
    try t.expectEqualStrings("replacement", s.found.entries[0].png);
    s.query.clear();
    s.rebuild();
    try t.expectEqual(@as(usize, 0), s.found.n);
}
