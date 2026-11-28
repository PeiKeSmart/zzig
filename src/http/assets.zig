//! 站点随包资源（**通用**）：从视图里推导静态资源清单、校验存在、预压缩 `.gz`、算 `?v=` 指纹。
//!
//! 为什么进框架：`Views/` + `wwwroot/` 是这套 web 栈的固定约定，于是「随包资源」的处理在每个
//! Zig 站点里都会被重写一遍（本项目与兄弟站 `Pek.ZTools/src/site_assets.zig` 就是逐行同款）。
//! 这里把机器收进框架，**不手写资源清单**：扫 `{views_dir}/**/*.zshtml` + 抠视图里引用的
//! `~/static/...` 就是「这一版该有哪些文件」。
//!
//! 三条踩过的坑已内置：
//! 1. **`.gz` 存在就跳过 = 改了 CSS 不生效** —— 必须比 mtime，源文件更新就重压；
//! 2. **`?v=` 只看一个文件名 = 改了别的静态文件浏览器还用旧缓存** —— 取一组候选文件的 mtime 最大值；
//! 3. **开发模式下留着 `.gz` 会盖住源码改动** —— `removePrecompressed` 一次清干净。
//!
//! ```zig
//! const assets = zzig.web.assets;
//! const opts: assets.Options = .{
//!     .required_views = &.{"Views/Shared/_SiteLayout.zshtml"},
//!     .version_files = &.{ "static/site.css", "static/js/app.js" },
//! };
//! try assets.ensure(allocator, io, base_dir, opts);
//! assets.precompress(allocator, io, base_dir, opts);
//! ```

const std = @import("std");
const fsio = @import("../file/fsio.zig");
const http = @import("http.zig");
const Logger = @import("../logs/logger.zig");

pub const Options = struct {
    /// 视图目录（相对 `base_dir`）
    views_dir: []const u8 = "Views",
    /// 静态资源根（相对 `base_dir`）
    wwwroot_dir: []const u8 = "wwwroot",
    /// 视图里引用的静态前缀（`~/static/...` 抠出来保留 `static/...`）
    static_prefix: []const u8 = "static/",
    /// 必须存在的视图（缺了整站不可用，如页面外壳）
    required_views: []const []const u8 = &.{},
    /// 参与预压缩的扩展名
    gzip_exts: []const []const u8 = &.{ ".css", ".js" },
    /// 参与 `?v=` 指纹的文件（相对 `wwwroot_dir`）；空 = 不使用指纹
    version_files: []const []const u8 = &.{},
    /// 打开文件的上限（防呆）
    max_view_bytes: usize = 4 * 1024 * 1024,
    /// 日志前缀
    log_tag: []const u8 = "[assets]",
};

/// 推导出来的清单（全部在传入的 arena 上）。
pub const Manifest = struct {
    /// 相对 `base_dir` 的视图路径，如 `Views/Home/Index.zshtml`
    views: []const []const u8 = &.{},
    /// 相对 `wwwroot_dir` 的静态资源，如 `static/css/site.css`
    statics: []const []const u8 = &.{},
};

/// 扫 `{base_dir}/{views_dir}` 得到「视图清单 + 视图里引用的静态资源」。
///
/// 静态引用截断符：`"` `'` `?` 空格 `\n` `\r` `>`
/// —— `~/static/site.css?v=@Model.assetVersion` 抠出来是 `static/site.css`。
pub fn collect(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, opts: Options) !Manifest {
    const views_root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, opts.views_dir });
    if (!fsio.exists(io, views_root)) return error.MissingAssets;

    var views: std.ArrayList([]const u8) = .empty;
    // 前缀从 `views_dir/` 起算：返回的路径直接与 `base_dir` 拼接即可用
    const prefix = try std.fmt.allocPrint(arena, "{s}/", .{opts.views_dir});
    try walkViews(arena, io, views_root, prefix, &views);

    var statics: std.ArrayList([]const u8) = .empty;
    const needle = try std.fmt.allocPrint(arena, "~/{s}", .{opts.static_prefix});
    for (views.items) |relative| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, relative });
        const text = fsio.readFileAlloc(io, arena, path, opts.max_view_bytes) catch continue;
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_from, needle)) |at| {
            const start = at + 2; // 跳过 `~/`
            var end = start;
            while (end < text.len) : (end += 1) {
                const ch = text[end];
                if (ch == '"' or ch == '\'' or ch == '?' or ch == ' ' or ch == '\n' or ch == '\r' or ch == '>') break;
            }
            if (end > start + opts.static_prefix.len) {
                const ref = text[start..end];
                var seen = false;
                for (statics.items) |existing| {
                    if (std.mem.eql(u8, existing, ref)) seen = true;
                }
                if (!seen) try statics.append(arena, ref);
            }
            search_from = end;
            if (search_from >= text.len) break;
        }
    }
    return .{ .views = views.items, .statics = statics.items };
}

fn walkViews(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = fsio.openDirIterable(io, dir_path) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        const relative = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, entry.name });
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
        if (entry.kind == .directory) {
            const child_prefix = try std.fmt.allocPrint(arena, "{s}/", .{relative});
            try walkViews(arena, io, full, child_prefix, out);
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".zshtml")) continue;
        try out.append(arena, relative);
    }
}

/// 校验随包资源存在（**不内嵌、不自动生成**：缺失就报错并列出清单）。
pub fn ensure(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, opts: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var missing: std.ArrayList([]const u8) = .empty;

    // ① 必须存在的视图（其余视图由目录扫描兜底）
    for (opts.required_views) |required| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, required });
        if (!fsio.exists(io, path)) try missing.append(arena, required);
    }

    // ② 扫视图 + 视图里的静态引用，逐个校验
    const manifest = collect(arena, io, base_dir, opts) catch Manifest{};
    if (manifest.views.len == 0 and missing.items.len == 0) try missing.append(arena, opts.views_dir);
    for (manifest.statics) |relative| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ base_dir, opts.wwwroot_dir, relative });
        if (!fsio.exists(io, path)) try missing.append(arena, relative);
    }
    if (missing.items.len == 0) return;

    Logger.err("{s} 缺少随包资源 {d} 个（资源根 {s}，程序需与 {s}/ 、{s}/ 同目录）：", .{
        opts.log_tag, missing.items.len, base_dir, opts.views_dir, opts.wwwroot_dir,
    });
    for (missing.items) |relative| Logger.err("  - {s}", .{relative});
    return error.MissingAssets;
}

/// 为随包静态资源预压缩一份 `.gz`（缺源更新才重压）。
///
/// `StaticFiles` 在客户端 `Accept-Encoding: gzip` 时**优先下发 `.gz`** 并补 `Vary`；
/// 预压缩是一次性开销，比每请求压缩省 CPU（契合「非必要不做周期性全量劳作」）。
pub fn precompress(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, opts: Options) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const manifest = collect(arena, io, base_dir, opts) catch return;
    for (manifest.statics) |relative| {
        if (!matchesExt(relative, opts.gzip_exts)) continue;

        const path = std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ base_dir, opts.wwwroot_dir, relative }) catch continue;
        if (!fsio.exists(io, path)) continue;

        const gz_path = std.fmt.allocPrint(allocator, "{s}.gz", .{path}) catch continue;
        defer allocator.free(gz_path);
        if (fsio.exists(io, gz_path)) {
            // ★ 源文件比 `.gz` 新 → 重新压缩。
            // 踩过：原来「`.gz` 存在就跳过」，改了 `site.css` 之后下发的还是旧压缩版
            // → 页面样式整块丢失，用户看到的就是「排版不对」。
            const src_ms = if (fsio.statFile(io, path)) |st| st.mtime.toMilliseconds() else |_| null;
            const gz_ms = if (fsio.statFile(io, gz_path)) |st| st.mtime.toMilliseconds() else |_| null;
            if (src_ms != null and gz_ms != null and src_ms.? <= gz_ms.?) continue;
            Logger.info("{s} 静态资源有更新，重新预压缩：{s}", .{ opts.log_tag, relative });
        }

        const content = fsio.readFileAlloc(io, allocator, path, 8 * 1024 * 1024) catch |err| {
            Logger.warn("{s} 预压缩读取失败（{s}）：{s}", .{ opts.log_tag, path, @errorName(err) });
            continue;
        };
        defer allocator.free(content);
        const gz = http.gzipCompressAlloc(allocator, content, .default) catch |err| {
            Logger.warn("{s} 预压缩失败（{s}）：{s}", .{ opts.log_tag, path, @errorName(err) });
            continue;
        };
        defer allocator.free(gz);
        fsio.writeFile(io, gz_path, gz) catch |err| {
            Logger.warn("{s} 写入 .gz 失败（{s}）：{s}", .{ opts.log_tag, gz_path, @errorName(err) });
        };
    }
}

/// 删掉随包静态资源的 `.gz` 预压缩副本（开发模式用）。
///
/// `StaticFiles` 在客户端支持 gzip 时**优先下发 `.gz`**，留着旧副本就会盖住源码改动
/// （改 CSS 刷新看不到效果）。开发模式不生成、也不保留 `.gz`，直接读源码。
pub fn removePrecompressed(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, opts: Options) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const manifest = collect(arena, io, base_dir, opts) catch return;
    for (manifest.statics) |relative| {
        if (!matchesExt(relative, opts.gzip_exts)) continue;
        const gz_path = std.fmt.allocPrint(arena, "{s}/{s}/{s}.gz", .{ base_dir, opts.wwwroot_dir, relative }) catch continue;
        fsio.deleteFile(io, gz_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => Logger.warn("{s} 删除过期 .gz 失败（{s}）：{s}", .{ opts.log_tag, gz_path, @errorName(err) }),
        };
    }
}

/// 静态资源指纹（`?v=`）：取 `version_files` 里 mtime 的**最大值**。
///
/// ★ 不能只看一个文件：改了 `app.js` 而 `site.css` 没动时，URL 不变 → 浏览器与 `.gz`
/// 预压缩副本都会继续下发旧脚本。取不到文件时回退到 `fallback`（宁可退回 ETag，
/// 也不能让页面渲染失败）。
pub fn fingerprint(io: std.Io, base_dir: []const u8, opts: Options, fallback: []const u8, arena: std.mem.Allocator) []const u8 {
    var newest: i64 = 0;
    for (opts.version_files) |relative| {
        const path = std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ base_dir, opts.wwwroot_dir, relative }) catch continue;
        const stat = fsio.statFile(io, path) catch continue;
        const ms = stat.mtime.toMilliseconds();
        if (ms > newest) newest = ms;
    }
    if (newest == 0) return fallback;
    return std.fmt.allocPrint(arena, "{x}", .{newest}) catch fallback;
}

fn matchesExt(name: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

// ————— 单测 —————

const testing = std.testing;

test "zzig.web.assets：从视图抠出静态引用并去重" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try fsio.makePath(io, try std.fmt.allocPrint(arena, "{s}/Views/Home", .{base}));
    try fsio.makePath(io, try std.fmt.allocPrint(arena, "{s}/Views/Shared", .{base}));
    try fsio.makePath(io, try std.fmt.allocPrint(arena, "{s}/wwwroot/static", .{base}));
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/Views/Shared/_Layout.zshtml", .{base}), "<link href=\"~/static/site.css?v=1\">");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/Views/Home/Index.zshtml", .{base}), "<link href=\"~/static/site.css?v=2\"><script src='~/static/app.js'></script>");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/wwwroot/static/site.css", .{base}), "body{}");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/wwwroot/static/app.js", .{base}), "1;");

    const opts: Options = .{ .required_views = &.{"Views/Shared/_Layout.zshtml"} };
    const manifest = try collect(arena, io, base, opts);
    try testing.expectEqual(@as(usize, 2), manifest.views.len);
    try testing.expectEqual(@as(usize, 2), manifest.statics.len);
    try testing.expectEqualStrings("static/site.css", manifest.statics[0]);
    try testing.expectEqualStrings("static/app.js", manifest.statics[1]);

    // 资源齐 → 不报错；缺一个 → 报 MissingAssets
    try ensure(a, io, base, opts);
    try fsio.deleteFile(io, try std.fmt.allocPrint(arena, "{s}/wwwroot/static/app.js", .{base}));
    try testing.expectError(error.MissingAssets, ensure(a, io, base, opts));
}

test "zzig.web.assets：required_views 缺失时报错；fingerprint 取 mtime 最大值" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try fsio.makePath(io, try std.fmt.allocPrint(arena, "{s}/Views", .{base}));
    try fsio.makePath(io, try std.fmt.allocPrint(arena, "{s}/wwwroot/static", .{base}));
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/Views/A.zshtml", .{base}), "<p>x</p>");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/wwwroot/static/site.css", .{base}), "body{}");

    const opts: Options = .{
        .required_views = &.{"Views/Missing.zshtml"},
        .version_files = &.{"static/site.css"},
    };
    try testing.expectError(error.MissingAssets, ensure(a, io, base, opts));

    const version = fingerprint(io, base, opts, "fallback", arena);
    try testing.expect(!std.mem.eql(u8, version, "fallback"));

    // 文件不存在 → 回退
    const missing_fp = fingerprint(io, base, .{ .version_files = &.{"static/none.css"} }, "fallback", arena);
    try testing.expectEqualStrings("fallback", missing_fp);
}
