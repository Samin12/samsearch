//! What a Raycast extension's host (raycast/dist/host.js) says, one JSON
//! object a line on its stdout (raycast/README.md, "Protocol"), and what
//! Nanolight answers on its stdin. Parsed into an arena per message.
const std = @import("std");

pub const Icon = struct {
    text: ?[]const u8 = null,
    file: ?[]const u8 = null,
    url: ?[]const u8 = null,
    builtin: ?[]const u8 = null,
};

pub const Action = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    shortcut: ?[]const u8 = null,
};

pub const Item = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    subtitle: ?[]const u8 = null,
    icon: ?Icon = null,
    accessories: []const []const u8 = &.{},
    actions: []const Action = &.{},
};

pub const Section = struct {
    title: ?[]const u8 = null,
    items: []const Item = &.{},
};

pub const Empty = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const Meta = struct {
    label: []const u8 = "",
    text: ?[]const u8 = null,
};

pub const Option = struct {
    value: []const u8 = "",
    title: []const u8 = "",
};

pub const Field = struct {
    controlled: bool = false,
    id: []const u8 = "",
    type: []const u8 = "text",
    title: ?[]const u8 = null,
    value: std.json.Value = .null,
    placeholder: ?[]const u8 = null,
    options: []const Option = &.{},
};

/// The top view: a list (a Grid comes as one), a detail or a form.
pub const View = struct {
    viewId: u64 = 0,
    searchText: ?[]const u8 = null,
    searchControlled: bool = false,
    kind: []const u8 = "list",
    title: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    loading: bool = false,
    sections: []const Section = &.{},
    empty: ?Empty = null,
    selected: ?[]const u8 = null,
    actions: []const Action = &.{},
    markdown: ?[]const u8 = null,
    /// Text shown as printed (a script command's output; Nanolight's own).
    output: ?[]const u8 = null,
    metadata: []const Meta = &.{},
    fields: []const Field = &.{},

    pub fn isList(v: *const View) bool {
        return std.mem.eql(u8, v.kind, "list");
    }

    pub fn isForm(v: *const View) bool {
        return std.mem.eql(u8, v.kind, "form");
    }

    pub fn count(v: *const View) usize {
        var n: usize = 0;
        for (v.sections) |s| n += s.items.len;
        return n;
    }

    /// The `i`th item counting through the sections.
    pub fn item(v: *const View, i: usize) ?*const Item {
        var k = i;
        for (v.sections) |s| {
            if (k < s.items.len) return &s.items[k];
            k -= s.items.len;
        }
        return null;
    }

    /// The actions in play: the selected item's in a list, else the view's.
    pub fn actionsAt(v: *const View, sel: usize) []const Action {
        if (v.isList()) if (v.item(sel)) |it| return it.actions;
        return v.actions;
    }
};

pub const Message = struct {
    type: []const u8 = "",
    view: ?View = null,
    style: ?[]const u8 = null,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
    target: ?[]const u8 = null,
    text: ?[]const u8 = null,
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    /// A form field's new value (`field`, from the panel).
    value: std.json.Value = .null,
};

pub fn parse(arena: std.mem.Allocator, line: []const u8) !Message {
    return std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// A message to the host: `{"type":kind, field: value}` and a newline.
pub fn say(buf: []u8, kind: []const u8, field: ?[]const u8, value: anytype) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var s: std.json.Stringify = .{ .writer = &w };
    try s.beginObject();
    try s.objectField("type");
    try s.write(kind);
    if (field) |f| {
        try s.objectField(f);
        try s.write(value);
    }
    try s.endObject();
    try w.writeByte('\n');
    return w.buffered();
}

/// Markdown as plain lines for the panel: headings, emphasis and code
/// marks dropped, images left out, links as their words.
pub fn plain(buf: []u8, md: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var line_start = true;
    while (i < md.len and n < buf.len) {
        const ch = md[i];
        if (line_start) {
            while (i < md.len and (md[i] == '#' or (md[i] == '>' and (i + 1 >= md.len or md[i + 1] == ' ')))) i += 1;
            while (i < md.len and md[i] == ' ' and n > 0 and buf[n - 1] == '\n') i += 1;
            line_start = false;
            continue;
        }
        if (ch == '!' and i + 1 < md.len and md[i + 1] == '[') {
            // ![alt](src): left out.
            const close = std.mem.indexOfScalarPos(u8, md, i, ')') orelse md.len - 1;
            i = close + 1;
            continue;
        }
        if (ch == '[') {
            // [words](href): the words.
            if (std.mem.indexOfScalarPos(u8, md, i, ']')) |rb| if (rb + 1 < md.len and md[rb + 1] == '(') {
                const words = md[i + 1 .. rb];
                const m = @min(words.len, buf.len - n);
                @memcpy(buf[n..][0..m], words[0..m]);
                n += m;
                i = (std.mem.indexOfScalarPos(u8, md, rb, ')') orelse md.len - 1) + 1;
                continue;
            };
        }
        if (ch == '*' or ch == '`' or (ch == '_' and (i + 1 < md.len and md[i + 1] == '_'))) {
            i += 1;
            continue;
        }
        buf[n] = ch;
        n += 1;
        if (ch == '\n') line_start = true;
        i += 1;
    }
    return std.mem.trim(u8, buf[0..n], " \n");
}

test "a host's render parses, and markdown reads as text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "{\"type\":\"render\",\"view\":{\"kind\":\"list\",\"loading\":false,\"sections\":[{\"title\":\"\",\"items\":[{\"id\":\"a\",\"title\":\"Story\",\"subtitle\":\"pg\",\"icon\":{\"text\":\"🔥\"},\"accessories\":[\"3\",\"0\"],\"actions\":[{\"id\":\"o\",\"title\":\"Open in Browser\",\"shortcut\":null},{\"id\":\"c\",\"title\":\"Copy Link\",\"shortcut\":\"cmd+.\"}]}]}],\"extra\":1}}");
    const v = m.view.?;
    try std.testing.expect(v.isList());
    try std.testing.expectEqual(@as(usize, 1), v.count());
    try std.testing.expectEqualStrings("Copy Link", v.actionsAt(0)[1].title);
    try std.testing.expectEqualStrings("🔥", v.item(0).?.icon.?.text.?);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world\nSee docs and code.", plain(&buf, "# Hello **world**\n![x](y.png)See [docs](https://a.b) and `code`."));
    try std.testing.expectEqualStrings("{\"type\":\"search\",\"text\":\"hn\"}\n", try say(&buf, "search", "text", "hn"));
    try std.testing.expectEqualStrings("{\"type\":\"pop\"}\n", try say(&buf, "pop", null, null));
}
