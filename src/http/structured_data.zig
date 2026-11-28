//! 结构化数据（schema.org / JSON-LD）——**通用构造器，任何站点都用同一套字段口径**。
//!
//! 为什么放进框架：JSON-LD 一旦各项目各拼一份，同一种页面在搜索引擎眼里就是两种实体
//! （字段名/嵌套层级稍有出入，Rich Results 就不认）。这里只做「按给定数据生成」，
//! 不读数据库、不认识业务表：
//! - `Article` + `BreadcrumbList`（文章 / 详情页）
//! - `CollectionPage` + `ItemList` + `BreadcrumbList`（列表 / 栏目页）
//!
//! 口径：
//! - 全部用**绝对 URL**（`url` / `item` 字段）；
//! - `inLanguage` 由调用方给（与 `<html lang>` 同源，别在这里猜）；
//! - 日期用 ISO 8601，时区**必须显式传** `tz_offset_seconds`（换台服务器结果不能变）；
//! - 返回已包好 `<script type="application/ld+json">` 的片段，直接放 head。
//!
//! ```zig
//! const json_ld = try zzig.web.structured_data.articleAlloc(arena, .{
//!     .title = "公司简介",
//!     .url = "https://a.example.com/category/about.html",
//!     .lang = "zh-CN",
//!     .site_name = "某某官网",
//!     .updated_unix = row.update_time,
//!     .tz_offset_seconds = 8 * 3600,
//!     .breadcrumbs = &.{.{ .name = "首页", .url = "https://a.example.com/" }},
//! });
//! ```

const std = @import("std");
const value = @import("value.zig");
const DateTime = @import("../time/datetime.zig").DateTime;

/// 面包屑一项（页面上的可见面包屑与 JSON-LD 用**同一份**数据）。
pub const Crumb = struct {
    name: []const u8,
    /// 绝对 URL
    url: []const u8,
};

/// `Article` 的输入。
pub const ArticleInput = struct {
    title: []const u8,
    summary: []const u8 = "",
    /// 本页 canonical（绝对 URL）
    url: []const u8,
    /// 与 `<html lang>` 同源（`zh-CN` / `en-US`）
    lang: []const u8,
    site_name: []const u8,
    /// 更新时间（Unix 秒；0 = 不输出日期字段）
    updated_unix: i64 = 0,
    /// 时区偏移（秒）。东八区写 `8 * 3600`；不要留默认值猜。
    tz_offset_seconds: i64 = 0,
    breadcrumbs: []const Crumb = &.{},
};

/// 列表项（`ItemList` 的一项）。
pub const Item = struct {
    name: []const u8,
    /// 绝对 URL
    url: []const u8,
};

/// `CollectionPage` + `ItemList` 的输入。
pub const CollectionInput = struct {
    title: []const u8,
    summary: []const u8 = "",
    url: []const u8,
    lang: []const u8,
    site_name: []const u8,
    /// 站点根地址（`https://host`），用于 `isPartOf`
    site_base: []const u8,
    items: []const Item = &.{},
    breadcrumbs: []const Crumb = &.{},
};

/// 一篇文章页：`Article` + `BreadcrumbList`。
pub fn articleAlloc(arena: std.mem.Allocator, in: ArticleInput) ![]const u8 {
    var graph: std.ArrayList(value.Value) = .empty;

    var article = value.ObjectBuilder.init(arena);
    try article.str("@type", "Article");
    try article.str("headline", in.title);
    if (in.summary.len > 0) try article.str("description", in.summary);
    try article.str("url", in.url);
    try article.str("inLanguage", in.lang);
    if (in.updated_unix > 0) {
        const iso = try isoTimeAlloc(arena, in.updated_unix, in.tz_offset_seconds);
        try article.str("datePublished", iso);
        try article.str("dateModified", iso);
    }
    var author = value.ObjectBuilder.init(arena);
    try author.str("@type", "Organization");
    try author.str("name", in.site_name);
    try article.put("author", author.finish());
    var publisher = value.ObjectBuilder.init(arena);
    try publisher.str("@type", "Organization");
    try publisher.str("name", in.site_name);
    try article.put("publisher", publisher.finish());
    var main_entity = value.ObjectBuilder.init(arena);
    try main_entity.str("@type", "WebPage");
    try main_entity.str("@id", in.url);
    try article.put("mainEntityOfPage", main_entity.finish());
    try graph.append(arena, article.finish());

    try appendBreadcrumb(arena, &graph, in.breadcrumbs);
    return wrapGraph(arena, graph.items);
}

/// 列表 / 栏目页：`CollectionPage`（含 `ItemList`）+ `BreadcrumbList`。
pub fn collectionAlloc(arena: std.mem.Allocator, in: CollectionInput) ![]const u8 {
    var graph: std.ArrayList(value.Value) = .empty;

    var page = value.ObjectBuilder.init(arena);
    try page.str("@type", "CollectionPage");
    try page.str("name", in.title);
    if (in.summary.len > 0) try page.str("description", in.summary);
    try page.str("url", in.url);
    try page.str("inLanguage", in.lang);
    var site = value.ObjectBuilder.init(arena);
    try site.str("@type", "WebSite");
    try site.str("name", in.site_name);
    try site.str("url", try std.fmt.allocPrint(arena, "{s}/", .{in.site_base}));
    try page.put("isPartOf", site.finish());

    if (in.items.len > 0) {
        var list = value.ObjectBuilder.init(arena);
        try list.str("@type", "ItemList");
        try list.int("numberOfItems", @intCast(in.items.len));
        var elements: std.ArrayList(value.Value) = .empty;
        for (in.items, 0..) |item, idx| {
            var element = value.ObjectBuilder.init(arena);
            try element.str("@type", "ListItem");
            try element.int("position", @intCast(idx + 1));
            try element.str("name", item.name);
            try element.str("url", item.url);
            try elements.append(arena, element.finish());
        }
        try list.put("itemListElement", .{ .list = elements.items });
        try page.put("mainEntity", list.finish());
    }
    try graph.append(arena, page.finish());

    try appendBreadcrumb(arena, &graph, in.breadcrumbs);
    return wrapGraph(arena, graph.items);
}

fn appendBreadcrumb(arena: std.mem.Allocator, graph: *std.ArrayList(value.Value), crumbs: []const Crumb) !void {
    if (crumbs.len == 0) return;
    var elements: std.ArrayList(value.Value) = .empty;
    for (crumbs, 0..) |crumb, idx| {
        var element = value.ObjectBuilder.init(arena);
        try element.str("@type", "ListItem");
        try element.int("position", @intCast(idx + 1));
        try element.str("name", crumb.name);
        try element.str("item", crumb.url);
        try elements.append(arena, element.finish());
    }
    var list = value.ObjectBuilder.init(arena);
    try list.str("@type", "BreadcrumbList");
    try list.put("itemListElement", .{ .list = elements.items });
    try graph.append(arena, list.finish());
}

fn wrapGraph(arena: std.mem.Allocator, graph: []const value.Value) ![]const u8 {
    var root = value.ObjectBuilder.init(arena);
    try root.str("@context", "https://schema.org");
    try root.put("@graph", .{ .list = graph });
    const json = try root.finish().jsonAlloc(arena);
    const safe = try jsonLdSafe(arena, json);
    return std.fmt.allocPrint(arena, "<script type=\"application/ld+json\">{s}</script>", .{safe});
}

/// JSON-LD 里不允许出现字面量 `<`：标题/站点名一旦含 `</script>` 会提前闭合脚本（XSS）。
/// JSON 的 `\u003c` 与 `<` 等价，替换后语义不变。
pub fn jsonLdSafe(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, json, '<') == null) return json;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.ensureTotalCapacity(arena, json.len + 16);
    for (json) |ch| {
        if (ch == '<') {
            try out.appendSlice(arena, "\\u003c");
        } else {
            try out.append(arena, ch);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Unix 秒 → ISO 8601（带显式时区偏移）`2026-11-28T15:04:05+08:00`。
pub fn isoTimeAlloc(arena: std.mem.Allocator, unix_seconds: i64, tz_offset_seconds: i64) ![]const u8 {
    const dt = DateTime.fromUnixSecondsOffset(unix_seconds, tz_offset_seconds);
    const local = try dt.formatSecondAlloc(arena); // `YYYY-MM-DD HH:MM:SS`
    if (local.len < 19) return local;
    const sign: u8 = if (tz_offset_seconds < 0) '-' else '+';
    const abs_off: i64 = if (tz_offset_seconds < 0) -tz_offset_seconds else tz_offset_seconds;
    // ★ 必须转成无符号再格式化：Zig 对**有符号**整数用 `{d:0>2}` 会把符号位算进宽度，
    //   输出成 `+8` / `+0`（本项目 `2023-11-15T06:13:20++8:+0` 就是这类事故，与年份 `+2023` 同源）。
    const hours: u32 = @intCast(@divTrunc(abs_off, 3600));
    const minutes: u32 = @intCast(@divTrunc(@mod(abs_off, 3600), 60));
    return std.fmt.allocPrint(arena, "{s}T{s}{c}{d:0>2}:{d:0>2}", .{
        local[0..10],
        local[11..19],
        sign,
        hours,
        minutes,
    });
}

const testing = std.testing;

test "structured_data：Article 含 headline / 带时区的 datePublished / BreadcrumbList" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const html = try articleAlloc(a, .{
        .title = "公司简介",
        .summary = "专注组态串口屏",
        .url = "https://example.com/category/about.html",
        .lang = "zh-CN",
        .site_name = "某某官网",
        .updated_unix = 1700000000,
        .tz_offset_seconds = 8 * 3600,
        .breadcrumbs = &.{
            .{ .name = "首页", .url = "https://example.com/" },
            .{ .name = "公司简介", .url = "https://example.com/category/about.html" },
        },
    });
    try testing.expect(std.mem.startsWith(u8, html, "<script type=\"application/ld+json\">"));
    try testing.expect(std.mem.indexOf(u8, html, "\"Article\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"datePublished\":\"2023-11-15T06:13:20+08:00\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"BreadcrumbList\"") != null);
}

test "structured_data：CollectionPage 的 ItemList 位置从 1 递增；无面包屑不输出 BreadcrumbList" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const html = try collectionAlloc(a, .{
        .title = "新闻动态",
        .url = "https://example.com/category/news.html",
        .lang = "zh-CN",
        .site_name = "某某官网",
        .site_base = "https://example.com",
        .items = &.{
            .{ .name = "第一条", .url = "https://example.com/article/a.html" },
            .{ .name = "第二条", .url = "https://example.com/article/b.html" },
        },
    });
    try testing.expect(std.mem.indexOf(u8, html, "\"CollectionPage\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"numberOfItems\":2") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"position\":1") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"position\":2") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"BreadcrumbList\"") == null);
}

test "structured_data：jsonLdSafe 把 < 转义成 \\u003c（防 </script> 提前闭合）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try jsonLdSafe(a, "{\"t\":\"a</script>b\"}");
    try testing.expect(std.mem.indexOf(u8, out, "<") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\\u003c") != null);
}
