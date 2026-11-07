//! Raycast extensions in Nanolight. Installed ones live in
//! `<data dir>/extensions/<name>` (raycast/README.md: the host installs
//! them from github.com/raycast/extensions and bundles each command). Each
//! command is a row among the apps (`scan`: its path `raycast:<dir>#<cmd>`,
//! its folder the extension's title), found, ranked and counted like one.
//! Opening it starts the host, `node host.js run <dir> <cmd>`, whose JSON
//! lines (raycast_model.zig) draw the panel (raycast_view.zig) until the
//! command ends or Escape leaves it. "Install Raycast Extension…" runs the
//! host's store the same way. Nothing polls: the host's output is watched.
//!
//! Node runs the host (it must be installed: Node 20 or later). The host is
//! raycast/dist/host.js, built into the program (`findHost`).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const model = @import("raycast_model.zig");
const Ext = @import("raycast_view.zig").Ext;
const Index = @import("apps.zig").Index;
const windows = builtin.os.tag == .windows;

pub const prefix = "raycast:";
pub const store_path = "raycast-store:";

pub const Hooks = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, target: []const u8) void,
    copy: *const fn (ctx: *anyopaque, text: []const u8) void,
    read_clipboard: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) ?[]u8,
    hide: *const fn (ctx: *anyopaque) void,
    redraw: *const fn (ctx: *anyopaque) void,
    /// An extension was installed or removed: the rows again.
    rescan: *const fn (ctx: *anyopaque) void,
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `<data dir>/extensions`, made if missing. Caller frees it.
pub fn dir(gpa: std.mem.Allocator) ![]u8 {
    const data = try @import("data_dir.zig").prepare(gpa, io());
    defer gpa.free(data);
    const d = try std.fs.path.join(gpa, &.{ data, "extensions" });
    std.Io.Dir.cwd().createDirPath(io(), d) catch {};
    return d;
}

const Pkg = struct {
    name: []const u8 = "",
    title: []const u8 = "",
    icon: ?[]const u8 = null,
    commands: []const struct { name: []const u8 = "", title: []const u8 = "", mode: []const u8 = "view" } = &.{},
};

fn readPkg(a: std.mem.Allocator, ext_dir: []const u8) ?Pkg {
    const p = std.fs.path.join(a, &.{ ext_dir, "package.json" }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io(), p, a, .limited(1 << 20)) catch return null;
    return std.json.parseFromSliceLeaky(Pkg, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// Adds each installed command to `ix`, and the store's row.
pub fn scan(ix: *Index, gpa: std.mem.Allocator) void {
    ix.addIn("Install Raycast Extension…", store_path, "Raycast") catch {};
    const root = dir(gpa) catch return;
    defer gpa.free(root);
    var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return;
    defer d.close(io());
    var it = d.iterate();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    while (it.next(io()) catch null) |e| {
        if (e.kind != .directory or e.name[0] == '.') continue;
        const a = arena.allocator();
        const ext_dir = std.fs.path.join(a, &.{ root, e.name }) catch continue;
        const pkg = readPkg(a, ext_dir) orelse continue;
        for (pkg.commands) |cmd| {
            const path = std.fmt.allocPrint(a, "{s}{s}#{s}", .{ prefix, ext_dir, cmd.name }) catch continue;
            ix.addIn(if (cmd.title.len > 0) cmd.title else cmd.name, path, if (pkg.title.len > 0) pkg.title else pkg.name) catch {};
        }
    }
}

/// The extension directory and command of a row's path.
pub fn split(path: []const u8) ?struct { dir: []const u8, cmd: []const u8 } {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const hash = std.mem.lastIndexOfScalar(u8, rest, '#') orelse return null;
    return .{ .dir = rest[0..hash], .cmd = rest[hash + 1 ..] };
}

/// An extension's icon (its package.json's, in assets/), for its rows.
pub fn icon(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (std.mem.eql(u8, path, store_path)) return null;
    const s = split(path) orelse return null;
    const pkg = readPkg(a, s.dir) orelse return null;
    const name = pkg.icon orelse return null;
    const file = std.fs.path.join(a, &.{ s.dir, "assets", name }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io(), file, gpa, .limited(4 << 20)) catch null;
}

/// Node, where it usually is: $NANOLIGHT_NODE, the PATH, Homebrew, nvm,
/// Volta, Program Files (an app opened from the Finder gets a short PATH).
pub fn findNode(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    if (env.get("NANOLIGHT_NODE")) |p| return gpa.dupe(u8, p) catch null;
    const exe = if (windows) "node.exe" else "node";
    var it = std.mem.tokenizeScalar(u8, env.get("PATH") orelse env.get("Path") orelse "", if (windows) ';' else ':');
    while (it.next()) |d| if (exists(gpa, &.{ d, exe })) |p| return p;
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse "";
    const fixed = [_][]const []const u8{
        &.{ "/opt/homebrew/bin", exe },    &.{ "/usr/local/bin", exe },
        &.{ "/usr/bin", exe },             &.{ home, ".volta", "bin", exe },
        &.{ home, ".bun", "bin", "node" }, &.{ env.get("ProgramFiles") orelse "C:\\Program Files", "nodejs", exe },
    };
    for (fixed) |parts| if (exists(gpa, parts)) |p| return p;
    // nvm: the newest version there.
    const nvm = std.fs.path.join(gpa, &.{ home, ".nvm", "versions", "node" }) catch return null;
    defer gpa.free(nvm);
    var d = std.Io.Dir.cwd().openDir(io(), nvm, .{ .iterate = true }) catch return null;
    defer d.close(io());
    var best: [64]u8 = undefined;
    var best_len: usize = 0;
    var di = d.iterate();
    while (di.next(io()) catch null) |e| if (e.name.len <= best.len and std.mem.order(u8, e.name, best[0..best_len]) == .gt) {
        @memcpy(best[0..e.name.len], e.name);
        best_len = e.name.len;
    };
    if (best_len == 0) return null;
    return exists(gpa, &.{ nvm, best[0..best_len], "bin", exe });
}

fn exists(gpa: std.mem.Allocator, parts: []const []const u8) ?[]u8 {
    const p = std.fs.path.join(gpa, parts) catch return null;
    std.Io.Dir.cwd().access(io(), p, .{}) catch {
        gpa.free(p);
        return null;
    };
    return p;
}

/// The host script (raycast/dist/host.js), built into the program.
const host_js = @embedFile("raycast_host");

/// The host script for Node: $NANOLIGHT_RAYCAST_HOST, else the built-in
/// one written to the cache, once a version (named by its hash, so an
/// update never runs an older one).
pub fn findHost(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    if (env.get("NANOLIGHT_RAYCAST_HOST")) |p| return gpa.dupe(u8, p) catch null;
    const cache = nanoui.path(gpa, .cache, "SamSearch") catch return null;
    defer gpa.free(cache);
    var name: [48]u8 = undefined;
    const file = std.fmt.bufPrint(&name, "raycast-host-{x}.js", .{std.hash.Wyhash.hash(0, host_js)}) catch return null;
    const p = std.fs.path.join(gpa, &.{ cache, file }) catch return null;
    std.Io.Dir.cwd().access(io(), p, .{}) catch {
        // A fresh account has no cache folder yet (~/.cache/Nanolight).
        std.Io.Dir.cwd().createDirPath(io(), cache) catch {};
        std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = host_js }) catch {
            gpa.free(p);
            return null;
        };
    };
    return p;
}

/// Process ownership moves to a worker. No wait or kill-and-wait runs on
/// the UI thread; the worker has no pointer into a command or view arena.
pub const ProcessJob = struct {
    refs: std.atomic.Value(u32) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,
    child: std.process.Child,
    terminate: bool,
    /// Only the UI callback reads/writes owner. The worker carries an
    /// independent reference until delivery, including after deinit.
    owner: ?*anyopaque = null,
    completed: ?*const fn (*anyopaque) void = null,

    pub fn start(child: std.process.Child, terminate: bool) ?*ProcessJob {
        return startNotify(child, terminate, null, null);
    }

    pub fn startNotify(child: std.process.Child, terminate: bool, owner: ?*anyopaque, completed: ?*const fn (*anyopaque) void) ?*ProcessJob {
        const job = std.heap.page_allocator.create(ProcessJob) catch return null;
        job.* = .{ .child = child, .terminate = terminate, .owner = owner, .completed = completed };
        const thread = std.Thread.spawn(.{}, work, .{job}) catch {
            std.heap.page_allocator.destroy(job);
            return null;
        };
        thread.detach();
        return job;
    }

    pub fn release(job: *ProcessJob) void {
        if (job.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(job);
    }

    fn work(job: *ProcessJob) void {
        defer job.release();
        var child = job.child;
        const worker_io = std.Io.Threaded.global_single_threaded.io();
        if (windows) {
            if (job.terminate) child.kill(worker_io) else job.term = child.wait(worker_io) catch null;
        } else if (child.id) |pid| {
            if (job.terminate) _ = std.c.kill(pid, .TERM);
            var status: c_int = 0;
            var ticks: usize = 0;
            while (true) {
                const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
                if (result == pid) {
                    job.term = std.Io.Threaded.statusToTerm(@bitCast(status));
                    break;
                }
                if (result < 0 and std.posix.errno(result) != .INTR) break;
                if (ticks == 100) _ = std.c.kill(pid, .KILL);
                std.Io.sleep(worker_io, .fromMilliseconds(20), .awake) catch {};
                ticks += 1;
            }
        }
        if (!windows) {
            if (child.stdin) |f| f.close(worker_io);
            if (child.stdout) |f| f.close(worker_io);
            if (child.stderr) |f| f.close(worker_io);
        }
        job.done.store(true, .release);
        if (job.completed != null and !builtin.is_test) {
            _ = job.refs.fetchAdd(1, .monotonic);
            nanoui.App.after(0, job, delivered);
        }
    }
    fn delivered(ctx: ?*anyopaque) callconv(.c) void {
        const job: *ProcessJob = @ptrCast(@alignCast(ctx.?));
        defer job.release();
        if (job.owner) |owner| if (job.completed) |completed| completed(owner);
    }
};

pub const Lifecycle = enum { spawning, starting, running, closing, stopped };

pub const Runner = struct {
    gpa: std.mem.Allocator,
    /// The app's (processes need a real one: the global single-threaded
    /// Io can't start them).
    io: std.Io,
    ext: *Ext,
    hooks: Hooks,
    node: ?[]u8 = null,
    host: ?[]u8 = null,
    state: Lifecycle = .stopped,
    reaping: ?*ProcessJob = null,
    child: ?std.process.Child = null,
    watch: ?nanoui.fdwatch.Watch = null,
    line: std.ArrayList(u8) = .empty,
    toast_id: ?i64 = null,

    /// Opens a row's command (`raycast:<dir>#<cmd>`) or the store.
    pub fn start(r: *Runner, path: []const u8, title: []const u8, ext_icon: ?[]const u8) void {
        r.stop();
        r.state = .spawning;
        const node = r.node orelse return r.fail(title, "Raycast extensions need Node.js: install it from nodejs.org.");
        const host = r.host orelse return r.fail(title, "The Raycast host couldn't be written to SamSearch's cache.");
        var argv_buf: [6][]const u8 = undefined;
        const root = if (split(path) == null) dir(r.gpa) catch return else null;
        defer if (root) |value| r.gpa.free(value);
        const argv: []const []const u8 = if (split(path)) |s| blk: {
            argv_buf = .{ node, "--no-deprecation", host, "run", s.dir, s.cmd };
            break :blk &argv_buf;
        } else blk: {
            argv_buf[0..5].* = .{ node, "--no-deprecation", host, "store", root.? };
            break :blk argv_buf[0..5];
        };
        r.ext.start(title, ext_icon, .{ .ctx = r, .func = send });
        r.ext.tick = .{ .ctx = r, .func = tick };
        const child = std.process.spawn(r.io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = if (windows) .ignore else .inherit, .create_no_window = windows }) catch
            return r.fail(title, "Node.js couldn't be started.");
        const out = child.stdout.?;
        r.child = child;
        r.state = .starting;
        r.watch = if (windows)
            nanoui.fdwatch.reader(out.handle, r, bytesIn, ended) catch null
        else
            nanoui.fdwatch.readable(out.handle, r, readable) catch null;
        r.hooks.redraw(r.hooks.ctx);
    }

    fn fail(r: *Runner, title: []const u8, why: []const u8) void {
        r.state = .closing;
        r.ext.start(title, null, .{ .ctx = r, .func = send });
        r.ext.note(why, true);
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const a = arena.allocator();
        const v: model.View = .{ .kind = "detail", .title = a.dupe(u8, title) catch "", .markdown = a.dupe(u8, why) catch "" };
        r.ext.show(arena, v);
        r.state = .stopped;
        r.hooks.redraw(r.hooks.ctx);
    }

    /// Ends the running command, if one is, and leaves its screen.
    pub fn stop(r: *Runner) void {
        r.close();
        if (r.reaping) |job| {
            job.owner = null;
            job.release();
        }
        r.reaping = null;
        if (r.ext.open) r.ext.stop();
        r.hooks.redraw(r.hooks.ctx);
    }

    fn close(r: *Runner) void {
        if (r.reaping) |job| {
            job.owner = null;
            job.release();
        }
        r.reaping = null;
        r.state = .closing;
        if (r.watch) |w| w.cancel();
        r.watch = null;
        // Consume already-buffered output before handing off the process.
        if (!windows) if (r.child) |child| if (child.stdout) |out| {
            var fds = [_]std.c.pollfd{.{ .fd = out.handle, .events = std.c.POLL.IN, .revents = 0 }};
            var buf: [16 * 1024]u8 = undefined;
            var drained: usize = 0;
            while (drained < 4 * 1024 * 1024 and std.c.poll(&fds, 1, 0) > 0) {
                drained += buf.len;
                const n = std.c.read(out.handle, &buf, buf.len);
                if (n <= 0) break;
                r.feed(buf[0..@intCast(n)]);
            }
        };
        if (r.line.items.len > 0) r.handle(r.line.items);
        r.line.clearRetainingCapacity();
        if (r.child) |child| {
            r.reaping = ProcessJob.startNotify(child, true, r, completed);
        }
        r.child = null;
        if (r.reaping == null) r.state = .stopped;
    }

    fn completed(ctx: *anyopaque) void {
        tick(ctx, "");
    }

    fn tick(ctx: *anyopaque, _: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const job = r.reaping orelse return;
        if (!job.done.load(.acquire)) return;
        job.owner = null;
        job.release();
        r.reaping = null;
        r.state = .stopped;
        if (r.ext.open) if (r.ext.view) |*v| {
            v.loading = false;
        };
        r.hooks.redraw(r.hooks.ctx);
    }

    /// UI messages reach this only at the next frame's boundary.
    pub fn send(ctx: *anyopaque, line: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        if (r.state == .closing) {
            if (std.mem.indexOf(u8, line, "\"pop\"") != null) r.ext.stop();
            return;
        }
        const c = &(r.child orelse {
            if (std.mem.indexOf(u8, line, "\"pop\"") != null) r.ext.stop();
            return;
        });
        const f = c.stdin orelse return;
        f.writeStreamingAll(r.io, line) catch {
            r.close();
            if (!r.ext.note_bad) r.errorView("The extension host disconnected");
            r.hooks.redraw(r.hooks.ctx);
        };
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

    pub fn ended(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        r.close();
        if (r.ext.open and r.ext.view == null) {
            var arena: std.heap.ArenaAllocator = .init(r.gpa);
            const text = if (r.ext.note_len > 0) r.ext.note_buf[0..r.ext.note_len] else "Command finished";
            const markdown = arena.allocator().dupe(u8, text) catch "";
            r.ext.show(arena, .{ .kind = "detail", .markdown = markdown });
        }
        r.hooks.redraw(r.hooks.ctx);
    }

    pub fn feed(r: *Runner, bytes: []const u8) void {
        r.line.appendSlice(r.gpa, bytes) catch return;
        while (std.mem.indexOfScalar(u8, r.line.items, '\n')) |nl| {
            // Remove before dispatch: a failed reply may close/drain the
            // host recursively, and must never dispatch this line twice.
            const line = r.gpa.dupe(u8, r.line.items[0..nl]) catch return;
            r.line.replaceRangeAssumeCapacity(0, nl + 1, &.{});
            r.handle(line);
            r.gpa.free(line);
        }
        r.hooks.redraw(r.hooks.ctx);
    }

    fn errorView(r: *Runner, message: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const text = arena.allocator().dupe(u8, message) catch "Extension error";
        r.ext.show(arena, .{ .kind = "detail", .title = "Error", .markdown = text });
        r.ext.note(message, true);
    }

    fn handle(r: *Runner, line: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const m = model.parse(arena.allocator(), line) catch {
            arena.deinit();
            return;
        };
        const kind = m.type;
        if (r.state == .starting) r.state = .running;
        if (std.mem.eql(u8, kind, "render")) if (m.view) |v| return r.ext.show(arena, v);
        defer arena.deinit();
        const h = r.hooks;
        if (std.mem.eql(u8, kind, "toast") or std.mem.eql(u8, kind, "error")) {
            var buf: [200]u8 = undefined;
            const t = m.title orelse m.message orelse "";
            const text = if (m.title != null and m.message != null and m.message.?.len > 0) std.fmt.bufPrint(&buf, "{s}: {s}", .{ t, m.message.? }) catch t else t;
            if (std.mem.eql(u8, kind, "error")) {
                r.toast_id = null;
                r.errorView(text);
            } else {
                r.toast_id = if (m.id) |id| (if (id == .integer) id.integer else null) else null;
                r.ext.note(text, std.mem.eql(u8, m.style orelse "", "failure"));
            }
        } else if (std.mem.eql(u8, kind, "toast_hide")) {
            const id = if (m.id) |value| (if (value == .integer) value.integer else null) else null;
            if (id != null and id == r.toast_id) r.ext.note_len = 0;
        } else if (std.mem.eql(u8, kind, "hud")) {
            // Hiding is the HUD's lifetime boundary. Never save it for a
            // future panel show (possibly hours after this command).
            r.ext.note_len = 0;
            h.hide(h.ctx);
        } else if (std.mem.eql(u8, kind, "open")) {
            if (m.target) |t| h.open(h.ctx, t);
        } else if (std.mem.eql(u8, kind, "copy") or std.mem.eql(u8, kind, "paste")) {
            if (m.text) |t| h.copy(h.ctx, t);
            r.ext.note("Copied to the clipboard", false);
            if (std.mem.eql(u8, kind, "paste")) h.hide(h.ctx);
        } else if (std.mem.eql(u8, kind, "close")) {
            h.hide(h.ctx);
        } else if (std.mem.eql(u8, kind, "installed")) {
            h.rescan(h.ctx);
        } else if (std.mem.eql(u8, kind, "pop_to_root")) {
            // Navigation leaves the extension screen, not its process.
            r.ext.stop();
        } else if (std.mem.eql(u8, kind, "exit")) {
            // Keep watching through EOF: more output may follow this line.
            r.state = .closing;
        } else if (std.mem.eql(u8, kind, "request")) {
            r.reply(m);
        }
    }

    fn reply(r: *Runner, m: model.Message) void {
        const id = m.id orelse return;
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();
        const w = &out.writer;
        var s: std.json.Stringify = .{ .writer = w };
        const method = m.method orelse "";
        const clip = if (std.mem.eql(u8, method, "clipboard.readText")) r.hooks.read_clipboard(r.hooks.ctx, r.gpa) else null;
        defer if (clip) |c| r.gpa.free(c);
        s.beginObject() catch return;
        s.objectField("type") catch return;
        s.write("reply") catch return;
        s.objectField("id") catch return;
        s.write(id) catch return;
        if (std.mem.eql(u8, method, "confirm")) {
            // There is no confirmation surface in this host yet. Reject
            // rather than authorize an operation the user hasn't approved.
            s.objectField("error") catch return;
            s.write("confirmAlert is unavailable in SamSearch; confirmation was rejected") catch return;
        } else {
            s.objectField("result") catch return;
            s.write(clip) catch return;
        }
        s.endObject() catch return;
        w.writeByte('\n') catch return;
        send(r, out.written());
    }
};

test "a command's row path splits into its directory and name" {
    const s = split("raycast:/home/me/.local/share/SamSearch/extensions/hacker-news#frontpage").?;
    try std.testing.expectEqualStrings("/home/me/.local/share/SamSearch/extensions/hacker-news", s.dir);
    try std.testing.expectEqualStrings("frontpage", s.cmd);
    try std.testing.expect(split("/Applications/Safari.app") == null);
}
