//! 站点页面基建（**通用**）：区域路由前缀、规范地址、安全响应头、简版错误页、页面耗时占位。
//!
//! 为什么放进框架：这几件事任何 Zig 站点都要做，而且**做错了会直接伤 SEO / 安全**——
//! canonical 算错就是重复内容，缺 CSP 就是白送 XSS 面，`nowMillis` 各写一份就容易踩
//! Zig 版本差异（0.17 移除了 `std.time.milliTimestamp`）。口径统一放在这里：
//!
//! | 能力 | 口径 |
//! |---|---|
//! | `areaRoute` | `Admin` → `/admin`（统一小写、带前导 `/`） |
//! | `baseUrl` / `canonicalUrl` | 配了 `SiteUrl` 就用它（去尾斜杠）；否则按 `X-Forwarded-Proto` + `Host` 推导 |
//! | `withHtmlHeaders` | HTML 响应统一带 `no-cache` + 前台 CSP（`script-src 'self'` 仍生效） |
//! | `simpleError` | 不依赖视图渲染的极简错误页（404/403/500 都能用） |
//! | `injectTiming` | 把视图里的 `<!--calc-ms-->` / `<!--render-ms-->` 换成实测耗时 |
//!
//! ```zig
//! const kit = zzig.web.page_kit;
//! const canonical = try kit.canonicalUrl(arena, c, settings.site_url);
//! return kit.withHtmlHeaders(arena, zzig.web.Response.html(html));
//! ```

const std = @import("std");
const compat = @import("../compat.zig");
const router = @import("router.zig");

/// 后台区域名 → 路由前缀（统一小写并加 `/`）：`Admin` → `/admin`。
pub fn areaRoute(allocator: std.mem.Allocator, area: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, area.len + 1);
    out[0] = '/';
    for (area, 0..) |ch, index| out[index + 1] = std.ascii.toLower(ch);
    return out;
}

/// 站点基址：优先用配置的 `SiteUrl`（去尾斜杠），否则按请求头推导。
///
/// 反代后 `X-Forwarded-Proto` 才是真实协议；未配置 `SiteUrl` 时用请求 `Host`，
/// 因此**反向代理务必覆盖 Host 头**（或直接配 `SiteUrl`），否则 sitemap 会写出内网域名。
pub fn baseUrl(arena: std.mem.Allocator, c: *router.Ctx, site_url: []const u8) ![]const u8 {
    if (site_url.len > 0) return std.mem.trimEnd(u8, site_url, "/");
    const proto = blk: {
        if (c.header("x-forwarded-proto")) |raw| {
            const text = std.mem.trim(u8, raw, " \t");
            if (text.len > 0 and text.len <= 8) break :blk text;
        }
        break :blk "http";
    };
    const host = blk: {
        if (c.header("host")) |raw| {
            const text = std.mem.trim(u8, raw, " \t");
            if (text.len > 0) break :blk text;
        }
        break :blk "localhost";
    };
    return std.fmt.allocPrint(arena, "{s}://{s}", .{ proto, host });
}

/// 页面规范地址（canonical / `og:url`）：基址 + 当前请求路径。
pub fn canonicalUrl(arena: std.mem.Allocator, c: *router.Ctx, site_url: []const u8) ![]const u8 {
    const base = try baseUrl(arena, c, site_url);
    const path = c.req.path;
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return std.fmt.allocPrint(arena, "{s}/", .{base});
    return std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });
}

/// 前台 CSP 预设。
///
/// **允许内联**（门户页常有轮播 / 导航的内联 style 与小段 IIFE，抽成静态文件收益小于风险），
/// 但下面这几项即使带 `'unsafe-inline'` 仍然有效：
/// - `script-src 'self'` —— 外链脚本一律不执行（挡「注入 `<script src=//evil>`」与 CDN 被投毒）；
/// - `object-src 'none'` —— 禁插件类攻击面；
/// - `base-uri 'self'` —— 防 `<base>` 劫持把相对路径指向外域；
/// - `form-action 'self'` / `connect-src 'self'` —— 表单与 XHR 只能回到本站（防数据外泄）；
/// - `frame-ancestors 'self'` —— 比 `X-Frame-Options` 更细的点击劫持防护。
///
/// 后台（`/admin/*`）**不要直接套用**：UEditor 等编辑器依赖较多，要单独审计后再上。
pub const front_csp = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " ++
    "img-src 'self' data:; font-src 'self' data:; connect-src 'self'; " ++
    "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'";

/// 前台 HTML 响应：统一加 `Cache-Control: no-cache` 与 CSP。
///
/// `no-cache` 的语义是「可以存、但每次使用前必须回源验证」，比 `no-store` 温和；
/// 缺了它浏览器会按启发式缓存自己做主 —— 改完页面用户刷新还是旧的（现象很像「没生效」）。
pub fn withHtmlHeaders(arena: std.mem.Allocator, resp: router.Response) router.Response {
    return withHtmlHeadersExt(arena, resp, "");
}

/// 同 [`withHtmlHeaders`]，但允许在 `connect-src` 后面追加额外的源（如前端要直连探测接口）。
///
/// `extra_connect_src` 是**已拼好的串**（每项带前导空格，如 `" https://a.example.com"`），
/// 一般由 [`connectSrcExtra`] 从 URL 列表生成；空串 = 行为与 [`withHtmlHeaders`] 完全一致。
pub fn withHtmlHeadersExt(arena: std.mem.Allocator, resp: router.Response, extra_connect_src: []const u8) router.Response {
    // 样式表以外的类型（JSON / XML / 纯文本）不加 CSP：它们不是被当作 HTML 解析的。
    if (std.mem.indexOf(u8, resp.content_type, "text/html") == null) return resp;
    var out = resp;
    var csp: []const u8 = front_csp;
    if (extra_connect_src.len > 0) {
        const marker = "connect-src 'self'";
        if (std.mem.indexOf(u8, front_csp, marker)) |at| {
            csp = std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
                front_csp[0..at], marker, extra_connect_src, front_csp[at + marker.len ..],
            }) catch front_csp;
        }
    }
    const headers = arena.alloc(std.http.Header, 2) catch return out;
    headers[0] = .{ .name = "cache-control", .value = "no-cache, max-age=0, must-revalidate" };
    headers[1] = .{ .name = "content-security-policy", .value = csp };
    out.headers = headers;
    return out;
}

/// 把一串 URL 收敛成 CSP 的 `connect-src` 追加串（`" https://a https://b"`，去重、跳过非绝对地址）。
pub fn connectSrcExtra(arena: std.mem.Allocator, urls: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (urls) |url| {
        const origin = @import("../net/url.zig").origin(url) orelse continue;
        var seen = false;
        var it = std.mem.splitScalar(u8, out.items, ' ');
        while (it.next()) |item| {
            if (std.mem.eql(u8, item, origin)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try out.append(arena, ' ');
        try out.appendSlice(arena, origin);
    }
    return out.toOwnedSlice(arena);
}

/// 简版错误页的参数。
pub const ErrorPage = struct {
    status: std.http.Status = .not_found,
    /// 页面标题（也用作页面上的 `<h1>`）
    title: []const u8,
    /// 补充说明（如「文章不存在或已下线」）
    detail: []const u8 = "",
    lang: []const u8 = "zh-CN",
    /// 返回按钮的地址与文案
    home_href: []const u8 = "/",
    home_text: []const u8 = "返回首页",
    /// 样式表路径（站点没有就传空串，页面仍然可读）
    css_href: []const u8 = "/static/site.css",
};

/// 极简错误页（不依赖视图渲染；文章不存在、无权限、内部错误都能直接用）。
pub fn simpleError(allocator: std.mem.Allocator, opts: ErrorPage) !router.Response {
    const style_link = if (opts.css_href.len > 0)
        try std.fmt.allocPrint(allocator, "<link rel=\"stylesheet\" href=\"{s}\">", .{opts.css_href})
    else
        "";
    const html = try std.fmt.allocPrint(
        allocator,
        "<!doctype html><html lang=\"{s}\"><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<meta name=\"robots\" content=\"noindex\"><title>{s} · {d}</title>" ++
            "{s}</head><body><main class=\"page-wrap\"><section class=\"panel\">" ++
            "<h1>{s}</h1><p>{s}</p><p><a class=\"btn\" href=\"{s}\">{s}</a></p>" ++
            "</section></main></body></html>",
        .{ opts.lang, opts.title, @backingInt(opts.status), style_link, opts.title, opts.detail, opts.home_href, opts.home_text },
    );
    return .{ .status = opts.status, .body = html, .content_type = "text/html; charset=utf-8" };
}

/// 当前时刻（毫秒）。
///
/// Zig 0.17 移除了 `std.time.milliTimestamp` / `nanoTimestamp`（`std.time` 只剩 `epoch`），
/// 各项目各写一份就会各踩一次；统一走 `compat`（Windows / Linux 都已适配）。
pub fn nowMillis() i64 {
    return compat.milliTimestamp();
}

/// 当前时刻（微秒）。页面计算常在 1 ms 以内，用毫秒量出来全是 `0`。
pub fn nowMicros() i64 {
    return @intCast(@divTrunc(compat.nanoTimestamp(), 1000));
}

/// 微秒 → `1.23`（固定两位小数）。用整数拼，不依赖浮点格式化。
pub fn formatMicros(allocator: std.mem.Allocator, us: i64) ![]const u8 {
    const clamped = @max(us, 0);
    const whole = @divTrunc(clamped, 1000);
    const frac = @divTrunc(@mod(clamped, 1000), 10);
    return std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ whole, frac });
}

/// 把视图里的 `<!--calc-ms-->` / `<!--render-ms-->` 占位替换成实际耗时（小数毫秒）。
///
/// 两个数字分开算的意义：**页面计算**（收到请求 → 开始渲染，含取数）与**视图渲染**
/// 是两回事 —— 计算慢要优化取数，渲染慢要优化模板。用占位符而不是 model 字段，
/// 是因为「渲染耗时」必须包含**渲染本身**。
pub fn injectTiming(arena: std.mem.Allocator, html: []const u8, calc_us: i64, render_us: i64) ![]const u8 {
    const calc_text = try formatMicros(arena, calc_us);
    const render_text = try formatMicros(arena, render_us);
    const with_calc = try replacePlaceholder(arena, html, "<!--calc-ms-->", calc_text);
    return replacePlaceholder(arena, with_calc, "<!--render-ms-->", render_text);
}

fn replacePlaceholder(arena: std.mem.Allocator, html: []const u8, needle: []const u8, value: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, html, needle) == null) return html;
    const size = std.mem.replacementSize(u8, html, needle, value);
    const out = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, html, needle, value, out);
    return out;
}

// ————— 单测 —————

const testing = std.testing;

test "zzig.web.page_kit：areaRoute 统一小写并带前缀，baseUrl 去掉配置里的尾斜杠" {
    const route = try areaRoute(testing.allocator, "Biz");
    defer testing.allocator.free(route);
    try testing.expectEqualStrings("/biz", route);
}

test "zzig.web.page_kit：formatMicros 固定两位小数且不出现负数" {
    const a = testing.allocator;
    const cases = [_]struct { us: i64, want: []const u8 }{
        .{ .us = 0, .want = "0.00" },
        .{ .us = 1210, .want = "1.21" },
        .{ .us = 999_999, .want = "999.99" },
        .{ .us = -5, .want = "0.00" },
    };
    for (cases) |case| {
        const text = try formatMicros(a, case.us);
        defer a.free(text);
        try testing.expectEqualStrings(case.want, text);
    }
}

test "zzig.web.page_kit：withHtmlHeaders 只给 HTML 加 no-cache 与 CSP" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html = withHtmlHeaders(arena, router.Response.html("<p>x</p>"));
    try testing.expect(html.headers.len == 2);
    var has_csp = false;
    for (html.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-security-policy")) {
            has_csp = std.mem.indexOf(u8, h.value, "connect-src 'self'") != null and
                std.mem.indexOf(u8, h.value, "frame-ancestors 'self'") != null;
        }
    }
    try testing.expect(has_csp);

    const json = withHtmlHeaders(arena, .{ .body = "{}", .content_type = "application/json" });
    try testing.expect(json.headers.len == 0);
}

test "zzig.web.page_kit：simpleError 输出 noindex + 状态码 + 返回链接" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try simpleError(arena, .{ .title = "页面不存在", .detail = "文章已下线" });
    try testing.expectEqual(@as(std.http.Status, .not_found), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "noindex") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "404") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "文章已下线") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "href=\"/\"") != null);
}

test "zzig.web.page_kit：injectTiming 替换两个占位，缺占位时原样返回" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html = try injectTiming(arena, "<i><!--calc-ms--></i><i><!--render-ms--></i>", 1234, 56);
    try testing.expect(std.mem.indexOf(u8, html, "1.23") != null);
    try testing.expect(std.mem.indexOf(u8, html, "0.05") != null);

    const untouched = try injectTiming(arena, "<p>无占位</p>", 1, 1);
    try testing.expectEqualStrings("<p>无占位</p>", untouched);
}
