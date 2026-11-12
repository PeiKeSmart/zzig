//! Web 应用装配（对齐 ASP.NET Core `WebApplication` 的最小一层）。
//!
//! 把已实现的四块拼成可直接跑的 Web 服务：
//! ```text
//! 请求 ──▶ http/server（监听 + 线程 + 上限 + 收报文）
//!              └─▶ App.dispatch
//!                     ├─ Router（路由 + 中间件 + 控制器挂载）
//!                     ├─ StaticFiles（wwwroot / 区域 wwwroot / 嵌入资源 / SPA 回退）
//!                     └─ 404 / 405 / 500 统一响应
//! ```
//!
//! 目录约定（与 ASP.NET Core 一致，也是本模块的默认值）：
//! - 视图：`Views/`，区域：`Areas/{Area}/Views/`；
//! - 静态资源：`wwwroot/`，区域静态资源：`Areas/{Area}/wwwroot`，
//!   区域 URL 前缀取**区域名小写**（`Admin` → `/admin`，对齐 `{{area}}` 路由约定）；
//! - 控制器：`Controller.initArea(alloc, io, "Admin", "Home")` → 动作 `/{area}/{controller}/{action}`。
//!
//! 处理顺序：**路由优先 → 静态资源兜底 → 404**。这与 DH.RustBase 把 `StaticFiles` 挂路由 fallback
//! 的用法一致；SPA 深链接回退也在静态资源这一层（`spaFallback(true)`）。

const std = @import("std");
const fsio = @import("../file/fsio.zig");
const server = @import("server.zig");
const router = @import("router.zig");
const controller = @import("controller.zig");
const static_files = @import("static_files.zig");
const view = @import("view.zig");
const value = @import("value.zig");

/// 请求上下文。
pub const Ctx = router.Ctx;
/// 响应。
pub const Response = router.Response;
/// 请求。
pub const Request = router.Request;

/// 应用选项（默认值即 ASP.NET Core 约定目录）。
pub const Options = struct {
    /// 主静态资源目录（`null` = 不提供静态资源；可改成任意相对/绝对路径）
    wwwroot: ?[]const u8 = "wwwroot",
    /// 额外静态根（如 `.{ .url_prefix = "/downloads", .dir = "data/downloads" }`）
    static_roots: []const static_files.RootOptions = &.{},
    /// 视图根（默认 `Views`）
    views_root: []const u8 = "Views",
    /// 区域根（默认 `Areas`）
    areas_root: []const u8 = "Areas",
    /// 是否启用 SPA 深链接回退（未命中的无扩展名路径回退 `index.html`）
    spa_fallback: bool = false,
    /// SPA 回退排除前缀（后端 API 前缀保持 JSON 404）
    spa_excludes: []const []const u8 = &.{"/api"},
};

/// Web 应用。
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    router: router.Router,
    statics: static_files.StaticFiles,
    areas: std.ArrayList([]const u8) = .empty,
    /// 视图组件注册表（启动期注册、运行期只读）
    components: view.ComponentRegistry,

    /// 创建应用（静态资源与路由器一并初始化）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !App {
        var statics = if (options.wwwroot) |dir|
            try static_files.StaticFiles.init(allocator, io, dir)
        else
            static_files.StaticFiles{ .allocator = allocator, .io = io };

        if (options.spa_fallback) {
            statics.spaFallback(true);
            try statics.spaExcludes(options.spa_excludes);
        }
        for (options.static_roots) |root| {
            try statics.addRootOptions(root);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .router = router.Router.init(allocator),
            .statics = statics,
            .components = view.ComponentRegistry.init(allocator),
        };
    }

    /// 释放路由器、静态资源、区域记录与组件注册表。
    pub fn deinit(self: *App) void {
        self.router.deinit();
        self.statics.deinit();
        for (self.areas.items) |area| self.allocator.free(area);
        self.areas.deinit(self.allocator);
        self.components.deinit();
    }

    /// 注册路由。
    pub fn map(self: *App, method: []const u8, pattern: []const u8, handler: router.Handler) !void {
        try self.router.map(method, pattern, handler);
    }

    /// 注册 GET 路由。
    pub fn get(self: *App, pattern: []const u8, handler: router.Handler) !void {
        try self.router.get(pattern, handler);
    }

    /// 注册 POST 路由。
    pub fn post(self: *App, pattern: []const u8, handler: router.Handler) !void {
        try self.router.post(pattern, handler);
    }

    /// 注册中间件（先注册先进入）。
    pub fn useMiddleware(self: *App, mw: router.Middleware) !void {
        try self.router.useMiddleware(mw);
    }

    /// 挂载控制器（统一使用本应用的视图根/区域根/组件注册表）。
    pub fn mountController(self: *App, ctrl: *controller.Controller) !void {
        ctrl.setViewsRoot(self.options.views_root);
        ctrl.setAreasRoot(self.options.areas_root);
        ctrl.setComponents(&self.components);
        try ctrl.mount(&self.router);
    }

    /// 注册视图组件（模板里用 `@await Component.InvokeAsync("名称", 参数)` 调用）。
    pub fn registerComponent(self: *App, name: []const u8, ctx: ?*anyopaque, func: view.ComponentFn) !void {
        try self.components.register(name, ctx, func);
    }

    /// 追加静态根（`url_prefix` 为空或 `/downloads` 形式；目录支持绝对路径）。
    pub fn addStaticRoot(self: *App, url_prefix: []const u8, dir: []const u8) !void {
        try self.statics.addRoot(url_prefix, dir);
    }

    /// 追加静态根（带每根配置：大小上限 / 流式阈值 / 缓存头）。
    pub fn addStaticRootOptions(self: *App, options: static_files.RootOptions) !void {
        try self.statics.addRootOptions(options);
    }

    /// 注册区域：自动挂载 `Areas/{Area}/wwwroot` 到 `/{area}`（目录不存在则跳过）。
    ///
    /// 控制器侧用 `Controller.initArea(alloc, io, area, controller)` 保持一致的区域名。
    pub fn addArea(self: *App, area: []const u8) !void {
        const name = std.mem.trim(u8, area, "/");
        if (name.len == 0) return error.InvalidArea;

        const pascal_name = try self.allocator.alloc(u8, name.len);
        defer self.allocator.free(pascal_name);
        for (name, 0..) |c, index| pascal_name[index] = if (index == 0) std.ascii.toUpper(c) else c;

        const dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}/wwwroot", .{ self.options.areas_root, pascal_name });
        defer self.allocator.free(dir);

        const lower_name = try self.allocator.alloc(u8, name.len);
        defer self.allocator.free(lower_name);
        for (name, 0..) |c, index| lower_name[index] = std.ascii.toLower(c);
        const url_prefix = try std.fmt.allocPrint(self.allocator, "/{s}", .{lower_name});
        defer self.allocator.free(url_prefix);

        if (fsio.exists(self.io, dir)) {
            try self.statics.addRoot(url_prefix, dir);
        }

        try self.areas.append(self.allocator, try self.allocator.dupe(u8, pascal_name));
    }

    /// 处理一个请求（路由 → 静态资源 → 404）。
    pub fn dispatch(self: *App, arena: std.mem.Allocator, req: Request) !Response {
        var ctx = try Ctx.build(arena, req);
        defer ctx.deinit();

        switch (try self.router.dispatch(&ctx)) {
            .response => |response| return response,
            .method_not_allowed => |allow| {
                const headers = try arena.alloc(std.http.Header, 1);
                headers[0] = .{ .name = "allow", .value = allow };
                const body = try std.fmt.allocPrint(
                    arena,
                    "{{\"code\":405,\"message\":\"Method Not Allowed\",\"allow\":\"{s}\"}}",
                    .{allow},
                );
                return .{
                    .status = .method_not_allowed,
                    .content_type = "application/json; charset=utf-8",
                    .body = body,
                    .headers = headers,
                };
            },
            .not_found => {
                if (try self.statics.serveRequest(arena, req)) |response| return response;
                return Response.notFound();
            },
        }
    }

    /// 桥接 `http/server` 的处理函数（`server.Server.ctx` 指向本应用）。
    pub fn serverHandler(raw: *anyopaque, req: server.RequestView, arena: std.mem.Allocator) anyerror!server.Reply {
        const self: *App = @ptrCast(@alignCast(raw));
        const response = self.dispatch(arena, .{
            .method = @tagName(req.method),
            .path = req.path,
            .query = req.query,
            .body = req.body,
            .headers = req.headers,
        }) catch |e| {
            // 失败必须可定位：方法 + 路径 + 具体错误（不接受只有"服务器错误"的笼统文案）
            std.debug.print("[zzig.web] 处理 {s} {s} 失败：{s}\n", .{ @tagName(req.method), req.path, @errorName(e) });
            const body = try std.fmt.allocPrint(
                arena,
                "{{\"code\":500,\"message\":\"Internal Server Error\",\"detail\":\"{s}\"}}",
                .{@errorName(e)},
            );
            return .{
                .status = .internal_server_error,
                .body = body,
                .content_type = "application/json; charset=utf-8",
            };
        };

        return .{
            .status = response.status,
            .body = response.body,
            .content_type = response.content_type,
            .headers = response.headers,
            // 文件响应交由服务端流式发送并关闭句柄
            .file = if (response.file) |file_body| .{
                .file = file_body.file,
                .length = file_body.length,
            } else null,
            .content_length = response.content_length,
        };
    }

    /// 创建底层服务端（需要自己控制 `run`/`stop` 时使用）。
    pub fn makeServer(self: *App, server_options: server.Options) server.Server {
        return .{
            .gpa = self.allocator,
            .io = self.io,
            .ctx = @ptrCast(self),
            .handler = serverHandler,
            .opts = server_options,
        };
    }

    /// 阻塞运行（`host` 必须是 IP 字面量）。
    pub fn run(self: *App, host: []const u8, port: u16, server_options: server.Options) !void {
        var srv = self.makeServer(server_options);
        std.debug.print("[zzig.web] 监听 http://{s}:{d}\n", .{ host, port });
        try srv.run(host, port);
    }
};

const testing = std.testing;
const compat = @import("../compat.zig");

fn buildRequest(method: []const u8, path: []const u8) Request {
    return .{ .method = method, .path = path };
}

/// 取响应正文（磁盘静态文件是文件流，需要从句柄读出来校对）。
fn responseBody(io: std.Io, arena: std.mem.Allocator, response: Response) ![]const u8 {
    const file_body = response.file orelse return response.body;
    defer file_body.file.close(io);

    const size: usize = @intCast(file_body.length);
    const out = try arena.alloc(u8, size);
    var buffer: [4096]u8 = undefined;
    var reader = file_body.file.reader(io, &buffer);
    var got: usize = 0;
    while (got < size) {
        const n = try reader.interface.readSliceShort(out[got..]);
        if (n == 0) break;
        got += n;
    }
    return out[0..got];
}

test "web：路由优先、静态兜底、404" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var app = try App.init(testing.allocator, io, .{ .wwwroot = null });
    defer app.deinit();

    const S = struct {
        fn ping(_: *Ctx) anyerror!Response {
            return Response.json("{\"ok\":true}");
        }
    };
    try app.get("/api/ping", router.handler(S.ping));

    const pong = try app.dispatch(arena, buildRequest("GET", "/api/ping"));
    try testing.expectEqualStrings("{\"ok\":true}", pong.body);

    const missing = try app.dispatch(arena, buildRequest("GET", "/nope"));
    try testing.expectEqual(std.http.Status.not_found, missing.status);
}

test "web：静态资源兜底与 SPA 回退" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var app = try App.init(testing.allocator, io, .{
        .wwwroot = "not-exists-wwwroot",
        .spa_fallback = true,
    });
    defer app.deinit();
    try app.statics.embed("/index.html", "<spa/>", "text/html; charset=utf-8");

    const home = try app.dispatch(arena, buildRequest("GET", "/"));
    try testing.expectEqualStrings("<spa/>", home.body);

    const deep = try app.dispatch(arena, buildRequest("GET", "/user/42"));
    try testing.expectEqualStrings("<spa/>", deep.body);

    const api = try app.dispatch(arena, buildRequest("GET", "/api/missing"));
    try testing.expectEqual(std.http.Status.not_found, api.status);
}

test "web：控制器挂载 + 区域静态根 + 405 带 Allow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var app = try App.init(testing.allocator, io, .{ .wwwroot = null });
    defer app.deinit();

    var ctrl = try controller.Controller.init(testing.allocator, io, "api");
    defer ctrl.deinit();
    try ctrl.post("save", struct {
        fn save(c: *Ctx) anyerror!controller.ActionResult {
            const name = controller.arg(c, "name") orelse "";
            return .{ .response = try controller.jsonResult(
                c.arena,
                0,
                "",
                try std.fmt.allocPrint(c.arena, "\"{s}\"", .{name}),
            ) };
        }
    }.save);
    try app.mountController(&ctrl);

    const ok = try app.dispatch(arena, .{
        .method = "POST",
        .path = "/api/save",
        .query = "name=abc",
    });
    try testing.expectEqualStrings("{\"code\":0,\"data\":\"abc\"}", ok.body);

    const wrong = try app.dispatch(arena, buildRequest("GET", "/api/save"));
    try testing.expectEqual(std.http.Status.method_not_allowed, wrong.status);
    var allow: ?[]const u8 = null;
    for (wrong.headers) |header| {
        if (std.mem.eql(u8, header.name, "allow")) allow = header.value;
    }
    try testing.expectEqualStrings("POST", allow.?);

    // 区域注册（目录不存在时不报错，仅记录）
    try app.addArea("Admin");
    try testing.expectEqual(@as(usize, 1), app.areas.items.len);
}

test "web：serverHandler 桥接保留响应头（302 + Location）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var app = try App.init(testing.allocator, io, .{ .wwwroot = null });
    defer app.deinit();

    const S = struct {
        fn go(c: *Ctx) anyerror!Response {
            return Response.redirectAlloc(c.arena, "/login");
        }
    };
    try app.get("/old", router.handler(S.go));

    const request_view = server.RequestView{
        .method = .GET,
        .target = "/old",
        .path = "/old",
        .query = "",
        .body = "",
    };
    const reply = try App.serverHandler(@ptrCast(&app), request_view, arena);
    try testing.expectEqual(std.http.Status.found, reply.status);
    try testing.expectEqual(@as(usize, 1), reply.headers.len);
    try testing.expectEqualStrings("location", reply.headers[0].name);
    try testing.expectEqualStrings("/login", reply.headers[0].value);
}

test "web：处理失败返回 500 且带错误名" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var app = try App.init(testing.allocator, io, .{ .wwwroot = null });
    defer app.deinit();

    const S = struct {
        fn boom(_: *Ctx) anyerror!Response {
            return error.DatabaseDown;
        }
    };
    try app.get("/boom", router.handler(S.boom));

    const request_view = server.RequestView{
        .method = .GET,
        .target = "/boom",
        .path = "/boom",
        .query = "",
        .body = "",
    };
    const reply = try App.serverHandler(@ptrCast(&app), request_view, arena);
    try testing.expectEqual(std.http.Status.internal_server_error, reply.status);
    try testing.expect(std.mem.indexOf(u8, reply.body, "DatabaseDown") != null);
}

test "web：注册组件后可在控制器视图中调用" {    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/web-component-{d}", .{compat.nanoTimestamp()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const page_path = try std.fmt.allocPrint(arena, "{s}/Views/Home/Index.cshtml", .{dir});
    const widget_path = try std.fmt.allocPrint(arena, "{s}/Views/Shared/Components/Clock/Default.cshtml", .{dir});
    try fsio.ensureParent(io, page_path);
    try fsio.writeFile(io, page_path, "<main>@await Component.InvokeAsync(\"Clock\", Model)</main>");
    try fsio.ensureParent(io, widget_path);
    try fsio.writeFile(io, widget_path, "<span>tick:@Model.Ticks</span>");

    var app = try App.init(testing.allocator, io, .{ .wwwroot = null, .views_root = try std.fmt.allocPrint(arena, "{s}/Views", .{dir}) });
    defer app.deinit();

    const Clock = struct {
        fn render(_: ?*anyopaque, c: *view.ComponentContext) anyerror!view.ComponentResult {
            var model = value.ObjectBuilder.init(c.arena);
            try model.int("Ticks", (c.args.get("Ticks") orelse value.ofInt(0)).asInt() orelse 0);
            return .{ .view = .{ .model = model.finish() } };
        }
    };
    try app.registerComponent("Clock", null, Clock.render);

    var ctrl = try controller.Controller.init(testing.allocator, io, "home");
    defer ctrl.deinit();
    try ctrl.get("index", struct {
        fn index(c: *Ctx) anyerror!controller.ActionResult {
            var model = value.ObjectBuilder.init(c.arena);
            try model.int("Ticks", 42);
            return .{ .view = .{ .model = model.finish() } };
        }
    }.index);
    try app.mountController(&ctrl);

    const response = try app.dispatch(arena, buildRequest("GET", "/home/index"));
    try testing.expectEqualStrings("<main><span>tick:42</span></main>", response.body);
}

test "web：wwwroot 可改 + 额外静态根 + 流式文件桥接" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const site_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/web-site-{d}", .{compat.nanoTimestamp()});
    const dl_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/web-downloads-{d}", .{compat.nanoTimestamp()});
    defer std.Io.Dir.cwd().deleteTree(io, site_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dl_dir) catch {};

    try fsio.makePath(io, site_dir);
    try fsio.makePath(io, dl_dir);
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/app.css", .{site_dir}), "site-css");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/a.txt", .{dl_dir}), "download-a");

    var app = try App.init(testing.allocator, io, .{
        // 改默认静态目录路径
        .wwwroot = site_dir,
        // 额外静态根（下载目录）
        .static_roots = &.{.{ .url_prefix = "/downloads", .dir = dl_dir }},
    });
    defer app.deinit();

    const css = try app.dispatch(arena, buildRequest("GET", "/app.css"));
    try testing.expectEqualStrings("site-css", try responseBody(io, arena, css));

    const download = try app.dispatch(arena, buildRequest("GET", "/downloads/a.txt"));
    try testing.expectEqualStrings("download-a", try responseBody(io, arena, download));

    // 大文件阈值调到 1 字节：改为流式，经 serverHandler 传给服务端并由服务端关闭
    app.statics.setStreamThreshold(1);
    const request_view = server.RequestView{
        .method = .GET,
        .target = "/downloads/a.txt",
        .path = "/downloads/a.txt",
        .query = "",
        .body = "",
    };
    const reply = try App.serverHandler(@ptrCast(&app), request_view, arena);
    try testing.expect(reply.file != null);
    try testing.expectEqual(@as(u64, 10), reply.file.?.length);
    reply.file.?.file.close(io);
}
