//! Vue/SPA 单 exe 演示：前端构建产物由 `zzig-spa-gen` 编译期嵌入（对齐 DH.RustBase 的 build.rs 方案）。
//!
//! 运行：`zig build spa-demo`（默认 127.0.0.1:18080）
//!
//! 一个端口内同时提供：
//! - `/`、`/dashboard`、`/user/42` → SPA 入口（history 路由回退 `index.html`）
//! - `/assets/*.js|css`           → 嵌入的前端产物
//! - `/api/ping`                  → JSON 控制器
//! - `/api/unknown`               → JSON 404（`spa_excludes` 排除，不回退 index.html）
//!
//! 注意：本示例**不需要** `wwwroot` —— 只靠编译期嵌入的资源表即可提供服务，
//! 这正是"生产环境单 exe、无前端运行环境"的形态。

const std = @import("std");
const zzig = @import("zzig");
/// 由 `zzig-spa-gen` 在构建期生成（见 build.zig 的 spa-demo 步骤）。
const spa_assets = @import("spa_assets");

fn ping(c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult {
    return .{ .response = try zzig.web.jsonResult(c.arena, 0, "", "{\"pong\":true}") };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try zzig.web.App.init(allocator, io, .{
        // 故意指向不存在的目录：证明"只靠嵌入资源"也能工作（部署时不需要 wwwroot）
        .wwwroot = "examples/spa/no-wwwroot",
        .views_root = "examples/web/Views",
        // SPA 深链接回退；`/api` 前缀保持 JSON 404
        .spa_fallback = true,
        .spa_excludes = &.{ "/api" },
    });
    defer app.deinit();

    // 嵌入前端构建产物（Vite/Vue 的 dist）
    try app.statics.embedAssets(&spa_assets.files);

    var api = try zzig.web.Controller.init(allocator, io, "api");
    defer api.deinit();
    try api.get("ping", ping);
    try app.mountController(&api);

    std.debug.print("[spa-demo] 已嵌入 {d} 个前端资源（源：{s}）\n", .{
        spa_assets.files.len,
        spa_assets.source_dir,
    });
    std.debug.print("[spa-demo] http://127.0.0.1:18080/  与  /dashboard  /assets/*.js  /api/ping\n", .{});

    try app.run("127.0.0.1", 18080, .{});
}
