//! Web MVC 示例：Controller + Razor 子集视图 + 区域（Areas）+ wwwroot 静态资源。
//!
//! 运行（在项目根目录）：
//!   zig build web-demo
//! 然后浏览：
//!   http://127.0.0.1:8080/home/index        常规控制器 + 布局 + 循环 + 分区
//!   http://127.0.0.1:8080/home/about        另一个视图
//!   http://127.0.0.1:8080/api/ping          JSON 信封响应
//!   http://127.0.0.1:8080/admin/dashboard/index   区域视图（Areas/Admin/Views）
//!   http://127.0.0.1:8080/app.css           wwwroot 静态资源
//!   http://127.0.0.1:8080/admin/admin.css   区域 wwwroot（/admin 前缀）
//!   http://127.0.0.1:8080/user/42           SPA 回退到 index.html

const std = @import("std");
const zzig = @import("zzig");

/// 首页控制器（`/home/{action}`）。
const Home = struct {
    fn index(c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult {
        // 模型一律用 ObjectBuilder 构造：字段名/数组都复制进请求 arena，
        // 动作返回后栈帧失效也不会留下悬垂切片。
        var items: std.ArrayList(zzig.web.Value) = .empty;
        try items.append(c.arena, try zzig.web.value.strAlloc(c.arena, "路由参数 → 查询串 → 表单 → JSON body"));
        try items.append(c.arena, try zzig.web.value.strAlloc(c.arena, "视图：Views/{Controller}/{Action}.cshtml"));
        try items.append(c.arena, try zzig.web.value.strAlloc(c.arena, "区域：Areas/{Area}/Views/{Controller}/{Action}.cshtml"));

        var model = zzig.web.value.ObjectBuilder.init(c.arena);
        try model.str("Title", "首页");
        try model.int("Count", @intCast(items.items.len));
        try model.list("Items", items.items);
        return zzig.web.viewResult(model.finish());
    }

    fn about(c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult {
        var model = zzig.web.value.ObjectBuilder.init(c.arena);
        try model.str("Title", "关于");
        try model.int("Year", 2026);
        return zzig.web.viewResult(model.finish());
    }
};

/// JSON 接口控制器（`/api/{action}`）。
const Api = struct {
    fn ping(c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult {
        return .{ .response = try zzig.web.jsonResult(c.arena, 0, "", "{\"pong\":true}") };
    }
};

/// 区域后台控制器（`/admin/dashboard/{action}`，视图在 `Areas/Admin/Views/Dashboard/`）。
const Dashboard = struct {
    fn index(c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult {
        var model = zzig.web.value.ObjectBuilder.init(c.arena);
        try model.str("Title", "区域后台");
        return zzig.web.viewResult(model.finish());
    }
};

pub fn main() !void {
    // 服务端多线程：io 用线程安全的 page_allocator 构造（见 http/server.zig 的踩坑记录）
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try zzig.web.App.init(allocator, io, .{
        .wwwroot = "examples/web/wwwroot",
        .views_root = "examples/web/Views",
        .areas_root = "examples/web/Areas",
        .spa_fallback = true,
    });
    defer app.deinit();

    var home = try zzig.web.Controller.init(allocator, io, "home");
    defer home.deinit();
    try home.get("index", Home.index);
    try home.get("about", Home.about);
    try app.mountController(&home);

    var api = try zzig.web.Controller.init(allocator, io, "api");
    defer api.deinit();
    try api.get("ping", Api.ping);
    try app.mountController(&api);

    var dashboard = try zzig.web.Controller.initArea(allocator, io, "Admin", "Dashboard");
    defer dashboard.deinit();
    try dashboard.get("index", Dashboard.index);
    try app.mountController(&dashboard);

    // 区域静态资源：Areas/Admin/wwwroot → /admin
    try app.addArea("Admin");

    try app.run("127.0.0.1", 8080, .{});
}
