//! Runs a Raycast script command (script_commands.zig) from its row, in
//! Zig: its arguments asked for first (a form in the panel, ⌘↩ runs), then
//! the script started with them, what it prints read as it comes (nothing
//! polls) and shown by its mode: `silent` hides the panel and says the last
//! line in the footer, `compact` and `inline` show the last line,
//! `fullOutput` everything, live. The panel's screen is raycast_view.zig's.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const sc = @import("script_commands.zig");
const model = @import("raycast_model.zig");
const Ext = @import("raycast_view.zig").Ext;
const ProcessJob = @import("raycast.zig").ProcessJob;
const Lifecycle = @import("raycast.zig").Lifecycle;
const windows = builtin.os.tag == .windows;

pub const Hooks = struct {
    ctx: *anyopaque,
    hide: *const fn (ctx: *anyopaque) void,
    redraw: *const fn (ctx: *anyopaque) void,
    copy: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// Said in the search's footer (a silent script's last line).
    footer: *const fn (ctx: *anyopaque, text: []const u8) void,
};

const max_out = 256 * 1024;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Runner = struct {
    gpa: std.mem.Allocator,
    /// The app's (processes need a real one: the global single-threaded
    /// Io can't start them).
    io: std.Io,
    ext: *Ext,
    hooks: Hooks,
    /// The script: its path, its bytes and its header (in `arena`).
    arena: ?std.heap.ArenaAllocator = null,
    file: []const u8 = "",
    bytes: []const u8 = "",
    meta: sc.Meta = .{},
    title: []const u8 = "",
    args: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty },
    state: Lifecycle = .stopped,
    reaping: ?*ProcessJob = null,
    child: ?std.process.Child = null,
    watch: ?nanoui.fdwatch.Watch = null,
    out: std.ArrayList(u8) = .empty,
    /// The command's screen is up (not a silent run).
    shown: bool = false,
    footer_buf: [160]u8 = undefined,

    pub fn deinit(r: *Runner) void {
        r.stop();
        r.drop();
        for (&r.args) |*a| a.deinit(r.gpa);
        r.out.deinit(r.gpa);
    }

    fn drop(r: *Runner) void {
        if (r.arena) |*a| a.deinit();
        r.arena = null;
    }

    /// Opens a row's script (`script:<file>`).
    pub fn start(r: *Runner, path: []const u8, title: []const u8, icon: ?[]const u8) void {
        r.stop();
        r.drop();
        r.arena = .init(r.gpa);
        const a = r.arena.?.allocator();
        r.file = a.dupe(u8, path[sc.prefix.len..]) catch return;
        r.title = a.dupe(u8, title) catch return;
        r.bytes = std.Io.Dir.cwd().readFileAlloc(io(), r.file, a, .limited(1 << 20)) catch "";
        r.meta = sc.parse(a, r.bytes) orelse .{ .title = r.title };
        for (&r.args) |*x| x.clearRetainingCapacity();
        r.ext.start(r.title, icon, .{ .ctx = r, .func = said });
        r.ext.tick = .{ .ctx = r, .func = tick };
        r.shown = true;
        if (r.meta.argCount() > 0 or r.meta.confirm) return r.ask();
        r.run();
    }

    /// The arguments' form (or, with none, \"Run X?\"), Run on ⌘↩.
    fn ask(r: *Runner) void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const a = arena.allocator();
        var fields: std.ArrayList(model.Field) = .empty;
        for (r.meta.args, 0..) |maybe, i| {
            const arg = maybe orelse continue;
            var opts: std.ArrayList(model.Option) = .empty;
            for (arg.data) |d| opts.append(a, .{ .value = d.value, .title = d.title }) catch {};
            const dropdown = std.mem.eql(u8, arg.type, "dropdown");
            if (dropdown and arg.data.len > 0 and r.args[i].items.len == 0) r.args[i].appendSlice(r.gpa, arg.data[0].value) catch {};
            const first: std.json.Value = .{ .string = a.dupe(u8, r.args[i].items) catch "" };
            fields.append(a, .{
                .id = a.dupe(u8, &.{ 'a', 'r', 'g', @intCast('1' + i) }) catch continue,
                .type = if (dropdown) "dropdown" else "text",
                .title = if (arg.placeholder.len > 0) arg.placeholder else "Argument",
                .placeholder = if (arg.optional) "Optional" else "",
                .value = first,
                .options = opts.items,
            }) catch {};
        }
        const run_action = a.dupe(model.Action, &.{.{ .id = "run", .title = "Run" }}) catch &.{};
        const v: model.View = if (fields.items.len > 0)
            .{ .kind = "form", .title = r.title, .fields = fields.items, .actions = run_action }
        else
            .{ .kind = "detail", .title = r.title, .markdown = std.fmt.allocPrint(a, "# Run {s}?\n{s}", .{ r.title, r.meta.description }) catch "", .actions = run_action };
        r.ext.show(arena, v);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// Starts the script with its arguments.
    fn run(r: *Runner) void {
        r.stop();
        r.out.clearRetainingCapacity();
        var scratch: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        r.state = .spawning;
        var cmd_buf: [8][]const u8 = undefined;
        const cmd = sc.command(r.bytes, r.file, &cmd_buf);
        var argv: std.ArrayList([]const u8) = .empty;
        // Its errors with its output: through sh, where there is one.
        if (!windows) argv.appendSlice(a, &.{ "/bin/sh", "-c", "exec \"$@\" 2>&1", "sh" }) catch return;
        argv.appendSlice(a, cmd) catch return;
        for (r.meta.args, 0..) |maybe, i| {
            const arg = maybe orelse continue;
            const v = r.args[i].items;
            if (v.len == 0 and !arg.optional) return r.fail("Fill in every argument that isn't optional.");
            var enc: [2048]u8 = undefined;
            argv.append(a, a.dupe(u8, if (arg.percentEncoded) sc.encode(&enc, v) else v) catch return) catch return;
        }
        const dir = r.workDir(a);
        const child = std.process.spawn(r.io, .{ .argv = argv.items, .cwd = .{ .path = dir }, .stdin = .ignore, .stdout = .pipe, .stderr = if (windows) .ignore else .inherit, .create_no_window = windows }) catch
            return r.fail("The script couldn't be started (is its interpreter installed?).");
        r.child = child;
        r.state = .running;
        const out = child.stdout.?;
        r.watch = if (windows)
            nanoui.fdwatch.reader(out.handle, r, bytesIn, ended) catch null
        else
            nanoui.fdwatch.readable(out.handle, r, readable) catch null;
        if (r.meta.mode == .silent) {
            r.shown = false;
            r.ext.stop();
            r.hooks.hide(r.hooks.ctx);
        } else r.showOutput(false);
    }

    /// Its directory: `currentDirectoryPath` (with ~), else the script's.
    fn workDir(r: *Runner, a: std.mem.Allocator) []const u8 {
        const d = r.meta.cwd;
        if (d.len > 0) {
            if (d[0] != '~') return d;
            const home = std.c.getenv(if (windows) "USERPROFILE" else "HOME") orelse return d;
            return std.fs.path.join(a, &.{ std.mem.span(home), d[1..] }) catch d;
        }
        return std.fs.path.dirname(r.file) orelse ".";
    }

    fn fail(r: *Runner, why: []const u8) void {
        r.state = .stopped;
        // Said in the panel (and the footer), not left at "Starting…".
        if (r.ext.view == null) {
            var arena: std.heap.ArenaAllocator = .init(r.gpa);
            const md = std.fmt.allocPrint(arena.allocator(), "# {s}\n{s}", .{ r.title, why }) catch "";
            r.ext.show(arena, .{ .kind = "detail", .title = r.title, .markdown = md });
        }
        r.ext.note(why, true);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// What it printed so far, as its mode shows it.
    fn showOutput(r: *Runner, done: bool) void {
        if (!r.shown) return;
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const a = arena.allocator();
        const text = std.mem.trimEnd(u8, r.out.items, " \r\n");
        const acts = a.dupe(model.Action, &.{ .{ .id = "copy", .title = "Copy Output" }, .{ .id = "again", .title = "Run Again" } }) catch &.{};
        var v: model.View = .{ .kind = "detail", .title = r.title, .loading = !done, .actions = if (done) acts else &.{} };
        if (r.meta.mode == .full_output) {
            v.output = a.dupe(u8, if (text.len == 0 and done) "(no output)" else text) catch "";
        } else {
            const last = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| text[nl + 1 ..] else text;
            v.markdown = std.fmt.allocPrint(a, "# {s}", .{if (last.len > 0) last else if (done) "Done" else "Running…"}) catch "";
        }
        r.ext.show(arena, v);
        r.hooks.redraw(r.hooks.ctx);
    }

    pub fn said(ctx: *anyopaque, line: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const m = model.parse(arena.allocator(), line) catch return;
        const id = if (m.id) |v| (if (v == .string) v.string else "") else "";
        if (std.mem.eql(u8, m.type, "field")) {
            if (id.len == 4 and id[3] >= '1' and id[3] <= '3') {
                const slot = &r.args[id[3] - '1'];
                slot.clearRetainingCapacity();
                if (m.value == .string) slot.appendSlice(r.gpa, m.value.string) catch {};
                // A dropdown shows what was picked (text fields keep their own).
                if (r.meta.args[id[3] - '1']) |arg| if (std.mem.eql(u8, arg.type, "dropdown")) r.ask();
            }
        } else if (std.mem.eql(u8, m.type, "action")) {
            if (std.mem.eql(u8, id, "run") or std.mem.eql(u8, id, "again")) {
                if (std.mem.eql(u8, id, "again") and (r.meta.argCount() > 0 or r.meta.confirm)) return r.ask();
                r.run();
            } else if (std.mem.eql(u8, id, "copy")) {
                r.hooks.copy(r.hooks.ctx, std.mem.trimEnd(u8, r.out.items, "\n"));
                r.ext.note("Copied to the clipboard", false);
            }
        } else if (std.mem.eql(u8, m.type, "pop")) {
            r.stop();
            r.shown = false;
            r.ext.stop();
            r.hooks.redraw(r.hooks.ctx);
        }
    }

    /// Ends a script still running.
    pub fn stop(r: *Runner) void {
        if (r.watch) |w| w.cancel();
        r.watch = null;
        r.state = .closing;
        // A script that closed its output may still be working: stop it too.
        if (r.reaping) |job| job.drop(true);
        r.reaping = null;
        if (r.child) |child| {
            if (ProcessJob.start(child, true)) |job| job.release();
        }
        r.child = null;
        r.state = .stopped;
    }

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const c = r.child orelse return;
        var buf: [16 * 1024]u8 = undefined;
        const n = std.c.read(c.stdout.?.handle, &buf, buf.len);
        if (n <= 0) return ended(ctx);
        r.feed(buf[0..@intCast(n)]);
    }

    fn bytesIn(ctx: ?*anyopaque, bytes: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        r.feed(bytes);
    }

    fn feed(r: *Runner, bytes: []const u8) void {
        const room = max_out -| r.out.items.len;
        r.out.appendSlice(r.gpa, bytes[0..@min(bytes.len, room)]) catch {};
        if (r.meta.mode == .full_output) r.showOutput(false);
    }

    pub fn ended(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        if (r.watch) |w| w.cancel();
        r.watch = null;
        const child = r.child orelse return;
        r.child = null;
        r.state = .closing;
        r.reaping = ProcessJob.startNotify(child, false, r, completed);
        if (r.reaping == null) r.complete(null);
        r.hooks.redraw(r.hooks.ctx);
    }

    fn completed(ctx: *anyopaque) void {
        tick(ctx, "");
    }

    fn tick(ctx: *anyopaque, _: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const job = r.reaping orelse return;
        if (!job.done.load(.acquire)) return;
        const term = job.term;
        job.owner = null;
        job.release();
        r.reaping = null;
        r.complete(term);
    }

    fn complete(r: *Runner, term: ?std.process.Child.Term) void {
        r.state = .stopped;
        const ok = if (term) |t| t.success() else false;
        const text = std.mem.trimEnd(u8, r.out.items, " \r\n");
        const last = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| text[nl + 1 ..] else text;
        if (!r.shown) {
            // Silent: the last line, said in the footer of the search.
            const said_text = if (last.len > 0) last else if (ok) r.title else "Failed";
            const n = @min(said_text.len, r.footer_buf.len);
            @memcpy(r.footer_buf[0..n], said_text[0..n]);
            r.hooks.footer(r.hooks.ctx, r.footer_buf[0..n]);
            return;
        }
        r.showOutput(true);
        if (!ok) {
            var buf: [64]u8 = undefined;
            const why = if (term) |t| switch (t) {
                .exited => |code| std.fmt.bufPrint(&buf, "Exited with code {d}", .{code}) catch "Failed",
                else => "Stopped",
            } else "Failed";
            r.ext.note(why, true);
        }
    }
};
