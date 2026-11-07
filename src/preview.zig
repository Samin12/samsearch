//! A search's page in the panel: a WKWebView over the panel's body
//! (`view.webArea`), made the first time one shows and kept, hidden,
//! after. It tells sites it is Safari, as browse does, so Google serves
//! its own page, and a link that asks for a new window opens in it.
//! Escape and ⌘↩ reach the panel even while the page has the keys
//! (`watch`): back to the rows, or into the browser; ⌘[ goes back a page.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const view = @import("view.zig");

pub const Key = enum { escape, open_out };

pub const Watch = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, key: Key) void,
};

/// Told whether Quick Ask moved its conversation to the floating window.
pub const Moved = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ok: bool) void,
};

pub const Preview = struct {
    web: ?objc.Object = null,
    /// Opens a link's new window in this one.
    ui_delegate: ?objc.Object = null,
    watcher: ?Watch = null,
    navigation_delegate: ?objc.Object = null,
    navigation: ?objc.Object = null,
    state: enum { idle, loading, recovering, retrying, shown, failed } = .idle,
    generation: u64 = 0,
    /// Waiting on the page's `openAnswerWindow()`, for this page generation.
    moving: ?Moved = null,
    move_generation: u64 = 0,
    url: [8192]u8 = undefined,
    url_len: usize = 0,

    /// Shows `url` over the panel of `window`, which is `h` tall now.
    pub fn show(p: *Preview, window: *nanoui.Window, url: []const u8, h: f32) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const web = p.web orelse p.make(window) orelse return;
        if (url.len > p.url.len) return;
        @memcpy(p.url[0..url.len], url);
        p.url_len = url.len;
        p.generation +%= 1;
        p.state = .loading;
        p.load();
        p.fit(h);
        objc.msg(void, web, "setHidden:", .{objc.NO});
    }

    /// Takes the page away, and empties it: no sound left playing, and no
    /// old page under the next one while it loads.
    pub fn hide(p: *Preview) void {
        p.generation +%= 1;
        p.state = .idle;
        p.navigation = null;
        const web = p.web orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, web, "setHidden:", .{objc.YES});
        objc.msg(void, web, "stopLoading", .{});
        _ = objc.msg(?objc.Object, web, "loadHTMLString:baseURL:", .{ objc.nsString(""), @as(?objc.Object, null) });
    }

    pub fn showing(p: *const Preview) bool {
        const web = p.web orelse return false;
        return objc.msg(objc.BOOL, web, "isHidden", .{}) == objc.NO;
    }

    /// The page to the panel's height `h` (it springs as it opens).
    pub fn fit(p: *Preview, h: f32) void {
        const web = p.web orelse return;
        const host = objc.msg(?objc.Object, web, "superview", .{}) orelse return;
        const area = view.webArea(h);
        const m = view.shadow_margin;
        var y: f64 = m + area.y;
        if (objc.msg(objc.BOOL, host, "isFlipped", .{}) == objc.NO)
            y = objc.msg(objc.CGRect, host, "bounds", .{}).size.height - y - area.h;
        objc.msg(void, web, "setFrame:", .{objc.CGRect{ .origin = .{ .x = m, .y = y }, .size = .{ .width = view.width, .height = area.h } }});
    }

    /// The page's address now (it may have been followed on), into `buf`.
    pub fn current(p: *const Preview, buf: []u8) ?[]const u8 {
        const web = p.web orelse return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(?objc.Object, web, "URL", .{}) orelse return null;
        const s = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
        if (!std.mem.startsWith(u8, s, "http") or s.len > buf.len) return null;
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }

    fn load(p: *Preview) void {
        const web = p.web orelse return;
        const u = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(p.url[0..p.url_len])}) orelse return;
        const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{u});
        p.navigation = objc.msg(?objc.Object, web, "loadRequest:", .{req});
        p.later(8000, false);
    }

    fn failed(p: *Preview) void {
        if (p.state != .loading and p.state != .retrying) return;
        if (!std.mem.startsWith(u8, p.url[0..p.url_len], "http://127.0.0.1:47213/")) return;
        const retry = p.state == .loading;
        p.state = if (retry) .recovering else .failed;
        p.navigation = null;
        const web = p.web orelse return;
        objc.msg(void, web, "stopLoading", .{});
        const message = if (retry) "Quick Ask isn't responding. Restarting it…" else "Quick Ask isn't responding. Try again in a moment.";
        const html = std.fmt.allocPrint(std.heap.page_allocator, "<body style=\"font:14px -apple-system;color:#888;padding:28px\">{s}</body>", .{message}) catch return;
        defer std.heap.page_allocator.free(html);
        _ = objc.msg(?objc.Object, web, "loadHTMLString:baseURL:", .{ objc.nsString(html), @as(?objc.Object, null) });
        if (retry) {
            @import("helper_mac.zig").restart();
            p.later(3000, true);
        }
    }

    const Timer = struct {
        preview: *Preview,
        generation: u64,
        retry: bool,

        fn fire(ctx: ?*anyopaque) callconv(.c) void {
            const t: *Timer = @ptrCast(@alignCast(ctx.?));
            defer std.heap.page_allocator.destroy(t);
            const p = t.preview;
            if (p.generation != t.generation) return;
            if (t.retry) {
                if (p.state != .recovering) return;
                p.generation +%= 1;
                p.state = .retrying;
                p.load();
            } else p.failed();
        }
    };

    fn later(p: *Preview, ms: u32, retry: bool) void {
        const timer = std.heap.page_allocator.create(Timer) catch return;
        timer.* = .{ .preview = p, .generation = p.generation, .retry = retry };
        nanoui.App.after(ms, timer, Timer.fire);
    }

    fn make(p: *Preview, window: *nanoui.Window) ?objc.Object {
        const surface = window.surface orelse return null;
        const host = objc.msg(?objc.Object, surface.nsview, "superview", .{}) orelse return null;
        const config = objc.msg(objc.Object, objc.alloc("WKWebViewConfiguration"), "init", .{});
        defer objc.release(config);
        var ua: [64]u8 = undefined;
        objc.msg(void, config, "setApplicationNameForUserAgent:", .{objc.nsString(safariName(&ua))});
        const zero: objc.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
        const web = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{ zero, config });
        // Clear until the page draws: the panel's "Searching" shows through.
        const no = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.NO});
        objc.msg(void, web, "setValue:forKey:", .{ no, objc.nsString("drawsBackground") });
        objc.msg(void, web, "setAllowsBackForwardNavigationGestures:", .{objc.YES});
        objc.msg(void, web, "setAutoresizingMask:", .{@as(objc.NSUInteger, 0)});
        const cls = objc.defineClass(.{
            .name = "SamSearchPreviewUI",
            .protocols = &.{"WKUIDelegate"},
            .methods = &.{.{ .name = "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", .imp = &newWindow, .types = "@@:@@@@" }},
        });
        const delegate = objc.msg(objc.Object, cls, "new", .{});
        objc.msg(void, web, "setUIDelegate:", .{delegate});
        const nav_cls = objc.defineClass(.{
            .name = "SamSearchPreviewNavigation",
            .protocols = &.{"WKNavigationDelegate"},
            .methods = &.{
                .{ .name = "webView:didFinishNavigation:", .imp = &loaded, .types = "v@:@@" },
                .{ .name = "webView:didFailNavigation:withError:", .imp = &loadFailed, .types = "v@:@@@" },
                .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &loadFailed, .types = "v@:@@@" },
            },
        });
        const nav = objc.msg(objc.Object, nav_cls, "new", .{});
        objc.setZig(nav, p);
        objc.msg(void, web, "setNavigationDelegate:", .{nav});
        p.navigation_delegate = nav;
        // Above the panel's drawing (a subview added last is on top).
        objc.msg(void, host, "addSubview:", .{web});
        p.web = web;
        p.ui_delegate = delegate;
        return web;
    }

    /// Asks the Quick Ask page to hand its conversation (history and the
    /// answer so far) to the floating window. `done` hears whether it did;
    /// an older helper without `openAnswerWindow` says no.
    pub fn moveAnswer(p: *Preview, done: Moved) void {
        const web = p.web orelse return done.func(done.ctx, false);
        if (p.moving != null) return;
        p.moving = done;
        p.move_generation = p.generation;
        const pool = objc.Pool.push();
        defer pool.pop();
        const world = objc.msg(objc.Object, objc.class("WKContentWorld"), "pageWorld", .{});
        var block = objc.Block(Preview, &.{ ?objc.Object, ?objc.Object }).init(p, moved);
        objc.msg(void, web, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", .{
            objc.nsString("return await window.openAnswerWindow()"),
            @as(?objc.Object, null),
            @as(?objc.Object, null),
            world,
            @as(*anyopaque, @ptrCast(&block)),
        });
    }

    fn moved(p: *Preview, _: ?objc.Object, err: ?objc.Object) void {
        const m = p.moving orelse return;
        p.moving = null;
        // The page went away meanwhile: nothing left to hand over.
        if (p.generation != p.move_generation) return;
        m.func(m.ctx, err == null);
    }

    /// Escape, ⌘↩ and ⌘[ while a page shows, before whoever has the keys.
    /// The monitor stays for the app's life.
    pub fn watch(p: *Preview, w: Watch) void {
        p.watcher = w;
        var block = objc.BlockRet(Preview, &.{objc.Object}, ?objc.Object).init(p, keyDown);
        const key_down_mask: u64 = 1 << 10;
        _ = objc.msg(?objc.Object, objc.class("NSEvent"), "addLocalMonitorForEventsMatchingMask:handler:", .{ key_down_mask, @as(*anyopaque, @ptrCast(&block)) });
    }

    fn keyDown(p: *Preview, ev: objc.Object) ?objc.Object {
        if (!p.showing()) return ev;
        const w = p.watcher orelse return ev;
        const code = objc.msg(u16, ev, "keyCode", .{});
        const cmd = objc.msg(objc.NSUInteger, ev, "modifierFlags", .{}) & (1 << 20) != 0;
        if (code == 53) {
            w.func(w.ctx, .escape);
        } else if (cmd and (code == 36 or code == 76)) {
            w.func(w.ctx, .open_out);
        } else if (cmd and code == 33) {
            _ = objc.msg(?objc.Object, p.web.?, "goBack", .{});
        } else return ev;
        return null;
    }
};

fn loaded(obj: objc.Object, _: objc.SEL, _: objc.Object, nav: ?objc.Object) callconv(.c) void {
    const p = objc.getZig(Preview, obj) orelse return;
    if (nav != null and nav == p.navigation) {
        p.state = .shown;
        p.navigation = null;
    }
}

fn loadFailed(obj: objc.Object, _: objc.SEL, _: objc.Object, nav: ?objc.Object, err: objc.Object) callconv(.c) void {
    const p = objc.getZig(Preview, obj) orelse return;
    if (nav == null or nav != p.navigation) return;
    if (objc.msg(objc.NSInteger, err, "code", .{}) == -999) return;
    p.failed();
}

/// A link that asks for a new window loads here instead.
fn newWindow(_: objc.Object, _: objc.SEL, web: objc.Object, _: objc.Object, action: objc.Object, _: objc.Object) callconv(.c) ?objc.Object {
    const req = objc.msg(objc.Object, action, "request", .{});
    _ = objc.msg(?objc.Object, web, "loadRequest:", .{req});
    return null;
}

/// "Version/26.1 Safari/605.1.15", with the installed Safari's version.
fn safariName(buf: []u8) []const u8 {
    var version: []const u8 = "26.0";
    for ([_][]const u8{ "/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app" }) |path| {
        const b = objc.msg(?objc.Object, objc.class("NSBundle"), "bundleWithPath:", .{objc.nsString(path)}) orelse continue;
        const v = objc.msg(?objc.Object, b, "objectForInfoDictionaryKey:", .{objc.nsString("CFBundleShortVersionString")}) orelse continue;
        const s = objc.fromNSString(v);
        if (s.len > 0 and s.len < 16) {
            version = s;
            break;
        }
    }
    return std.fmt.bufPrint(buf, "Version/{s} Safari/605.1.15", .{version}) catch "Safari/605.1.15";
}
