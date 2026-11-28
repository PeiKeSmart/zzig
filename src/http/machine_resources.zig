//! 机器可读资源（**通用**）：`robots.txt` / `sitemap.xml` / `llms.txt` 的文本生成。
//!
//! 为什么进框架：这三份文件是「写错一行就白送 SEO」的典型 ——
//! - sitemap 里 `&` 不转义是 XML 硬错，`<lastmod>` 格式错搜索引擎直接忽略；
//! - robots 的 `Disallow` 一旦漏掉后台前缀，后台就被抓；
//! - `llms.txt` 是 llmstxt.org 的约定格式，各站各写一份必然走样。
//!
//! 这里只做**纯文本拼装**：不读数据库、不认识业务表。调用方把「页面/栏目/文章」
//! 归一成 `SitemapUrl` / `LlmsSection` 传进来即可（数据的筛选口径属于业务）。
//!
//! ```zig
//! const mr = zzig.web.machine_resources;
//! const body = try mr.sitemapAlloc(arena, &.{
//!     .{ .loc = "https://a.example.com/", .changefreq = "weekly", .priority = "1.0" },
//!     .{ .loc = "https://a.example.com/about.html", .lastmod_unix = 1795852494, .alterates = ... },
//! });
//! ```

const std = @import("std");
const DateTime = @import("../time/datetime.zig").DateTime;

/// 一个语言备选（`<xhtml:link rel="alternate">`）。
pub const Alternate = struct {
    /// `LanguageCulture`（`zh-CN` / `en-US`），原样写进 `hreflang`
    hreflang: []const u8,
    /// 绝对 URL
    href: []const u8,
};

/// sitemap 里的一条地址。
pub const SitemapUrl = struct {
    /// 绝对 URL（`https://…/path`）
    loc: []const u8,
    /// `always` / `hourly` / `daily` / `weekly` / `monthly` / `yearly` / `never`；空 = 不写
    changefreq: []const u8 = "",
    /// `0.0`–`1.0`；空 = 不写
    priority: []const u8 = "",
    /// 最后修改（Unix 秒）；`null` = 不写 `<lastmod>`
    lastmod_unix: ?i64 = null,
    /// `<lastmod>` 用的时区偏移（秒）：换台服务器结果不能变
    tz_offset_seconds: i32 = 8 * 3600,
    /// 多语言备选（含自身）；`x-default` 由 `default_href` 单独给
    alternates: []const Alternate = &.{},
    /// `hreflang="x-default"` 指向的地址（通常是默认语言版本）；空 = 不写
    x_default_href: []const u8 = "",
};

/// 生成完整 `sitemap.xml`。
pub fn sitemapAlloc(arena: std.mem.Allocator, urls: []const SitemapUrl) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    try out.appendSlice(arena, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try out.appendSlice(arena, "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\"\n" ++
        "        xmlns:xhtml=\"http://www.w3.org/1999/xhtml\">\n");
    for (urls) |url| {
        try out.appendSlice(arena, "  <url><loc>");
        try out.appendSlice(arena, try xmlEscapeAlloc(arena, url.loc));
        try out.appendSlice(arena, "</loc>");
        if (url.lastmod_unix) |secs| {
            if (try lastmodDate(arena, secs, url.tz_offset_seconds)) |text| {
                try out.appendSlice(arena, "<lastmod>");
                try out.appendSlice(arena, text);
                try out.appendSlice(arena, "</lastmod>");
            }
        }
        if (url.changefreq.len > 0) {
            try out.appendSlice(arena, "<changefreq>");
            try out.appendSlice(arena, url.changefreq);
            try out.appendSlice(arena, "</changefreq>");
        }
        if (url.priority.len > 0) {
            try out.appendSlice(arena, "<priority>");
            try out.appendSlice(arena, url.priority);
            try out.appendSlice(arena, "</priority>");
        }
        try out.appendSlice(arena, "\n");
        for (url.alternates) |alt| {
            try out.appendSlice(arena, "    <xhtml:link rel=\"alternate\" hreflang=\"");
            try out.appendSlice(arena, try xmlEscapeAlloc(arena, alt.hreflang));
            try out.appendSlice(arena, "\" href=\"");
            try out.appendSlice(arena, try xmlEscapeAlloc(arena, alt.href));
            try out.appendSlice(arena, "\"/>\n");
        }
        if (url.x_default_href.len > 0) {
            try out.appendSlice(arena, "    <xhtml:link rel=\"alternate\" hreflang=\"x-default\" href=\"");
            try out.appendSlice(arena, try xmlEscapeAlloc(arena, url.x_default_href));
            try out.appendSlice(arena, "\"/>\n");
        }
        try out.appendSlice(arena, "  </url>\n");
    }
    try out.appendSlice(arena, "</urlset>\n");
    return out.toOwnedSlice(arena);
}

/// 主流**生成式引擎抓取器**（谷歌 / OpenAI / Anthropic / Perplexity 等）。
///
/// 显式列出来比 `User-agent: *` 更明确：部分抓取器只看专项段。
pub const DEFAULT_AI_BOTS = [_][]const u8{
    "GPTBot",
    "OAI-SearchBot",
    "ChatGPT-User",
    "ClaudeBot",
    "anthropic-ai",
    "PerplexityBot",
    "Google-Extended",
    "Bytespider",
    "CCBot",
};

pub const RobotsOptions = struct {
    /// `Sitemap: <绝对 URL>`；空 = 不写
    sitemap_url: []const u8 = "",
    /// 逐条输出 `Disallow: <path>`（顺序即输出顺序；空串会被跳过）
    disallow: []const []const u8 = &.{},
    /// 是否允许 AI 抓取（口径应与 WAF 的「允许 AI 爬虫」开关一致，别两处打架）
    ai_bots_allowed: bool = true,
    /// 参与专项段的抓取器名单
    ai_bots: []const []const u8 = &DEFAULT_AI_BOTS,
    /// 站点自定义段落（原样追加，如 llms.txt 的地址）
    extra_lines: []const []const u8 = &.{},
};

/// 生成完整 `robots.txt`。
pub fn robotsAlloc(arena: std.mem.Allocator, opts: RobotsOptions) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    try out.appendSlice(arena, "User-agent: *\nAllow: /\n");
    for (opts.disallow) |path| {
        if (path.len == 0) continue;
        try out.appendSlice(arena, "Disallow: ");
        try out.appendSlice(arena, path);
        try out.appendSlice(arena, "\n");
    }
    if (opts.sitemap_url.len > 0) {
        try out.appendSlice(arena, "\nSitemap: ");
        try out.appendSlice(arena, opts.sitemap_url);
        try out.appendSlice(arena, "\n");
    }
    if (opts.ai_bots.len > 0) {
        const rule: []const u8 = if (opts.ai_bots_allowed) "Allow: /" else "Disallow: /";
        try out.appendSlice(arena, "\n# GEO: 生成式引擎抓取器（https://llmstxt.org/）\n");
        for (opts.ai_bots) |agent| {
            try out.appendSlice(arena, "User-agent: ");
            try out.appendSlice(arena, agent);
            try out.appendSlice(arena, "\n");
            try out.appendSlice(arena, rule);
            try out.appendSlice(arena, "\n");
        }
    }
    for (opts.extra_lines) |line| {
        if (line.len == 0) continue;
        try out.appendSlice(arena, line);
        try out.appendSlice(arena, "\n");
    }
    return out.toOwnedSlice(arena);
}

/// `llms.txt` 的一项。
pub const LlmsItem = struct {
    name: []const u8,
    /// 绝对 URL
    url: []const u8,
    /// 一句话说明（空 = 只写链接）
    description: []const u8 = "",
};

/// `llms.txt` 的一节（`## 标题` + 列表）。
pub const LlmsSection = struct {
    title: []const u8,
    items: []const LlmsItem,
};

pub const LlmsOptions = struct {
    site_name: []const u8,
    /// 站点一句话简介（写在 `>` 引用块里）
    summary: []const u8 = "",
    sections: []const LlmsSection = &.{},
};

/// 生成 `llms.txt`（Markdown，纯文本、无 HTML 噪声）。
pub fn llmsAlloc(arena: std.mem.Allocator, opts: LlmsOptions) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    try out.appendSlice(arena, "# ");
    try out.appendSlice(arena, opts.site_name);
    try out.appendSlice(arena, "\n\n");
    if (opts.summary.len > 0) {
        try out.appendSlice(arena, "> ");
        try out.appendSlice(arena, opts.summary);
        try out.appendSlice(arena, "\n\n");
    }
    for (opts.sections) |section| {
        if (section.items.len == 0) continue;
        try out.appendSlice(arena, "## ");
        try out.appendSlice(arena, section.title);
        try out.appendSlice(arena, "\n\n");
        for (section.items) |item| {
            try out.appendSlice(arena, "- [");
            try out.appendSlice(arena, item.name);
            try out.appendSlice(arena, "](");
            try out.appendSlice(arena, item.url);
            try out.appendSlice(arena, ")");
            if (item.description.len > 0) {
                try out.appendSlice(arena, ": ");
                try out.appendSlice(arena, item.description);
            }
            try out.appendSlice(arena, "\n");
        }
        try out.appendSlice(arena, "\n");
    }
    return out.toOwnedSlice(arena);
}

/// XML 文本/属性转义（`&` / `<` / `>` / `"` / `'`）。
///
/// 站点地址与栏目别名来自配置/数据库，不转义就可能把 sitemap 写坏（`&` 在 XML 里是硬错）。
/// 无需转义时**原样返回**（不额外分配）。
pub fn xmlEscapeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var needs = false;
    for (text) |ch| {
        switch (ch) {
            '&', '<', '>', '"', '\'' => {
                needs = true;
                break;
            },
            else => {},
        }
    }
    if (!needs) return text;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `<lastmod>` 用的本地日期 `yyyy-MM-dd`（sitemap 允许只到日期）；秒数非法时返回 null。
fn lastmodDate(arena: std.mem.Allocator, unix_seconds: i64, tz_offset_seconds: i32) !?[]const u8 {
    if (unix_seconds <= 0) return null;
    const text = try DateTime.fromUnixSecondsOffset(unix_seconds, tz_offset_seconds).formatSecondAlloc(arena);
    if (text.len < 10) return null;
    return text[0..10];
}

// ————— 单测 —————

const testing = std.testing;

test "zzig.web.machine_resources：XML 转义（含属性引号），无需转义时原样返回" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("a&amp;b", try xmlEscapeAlloc(a, "a&b"));
    try testing.expectEqualStrings("&lt;x&gt;", try xmlEscapeAlloc(a, "<x>"));
    try testing.expectEqualStrings("&quot;q&quot;", try xmlEscapeAlloc(a, "\"q\""));
    try testing.expectEqualStrings("https://a.example.com/x", try xmlEscapeAlloc(a, "https://a.example.com/x"));
}

test "zzig.web.machine_resources：sitemap 含 lastmod / alternates / x-default，且转义" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const body = try sitemapAlloc(a, &.{
        .{ .loc = "https://a.example.com/", .changefreq = "weekly", .priority = "1.0" },
        .{
            .loc = "https://a.example.com/a?x=1&y=2",
            .lastmod_unix = 1_700_000_000,
            .changefreq = "monthly",
            .priority = "0.7",
            .tz_offset_seconds = 8 * 3600,
            .alternates = &.{
                .{ .hreflang = "zh-CN", .href = "https://a.example.com/a" },
                .{ .hreflang = "en-US", .href = "https://a.example.com/en/a" },
            },
            .x_default_href = "https://a.example.com/a",
        },
    });

    try testing.expect(std.mem.indexOf(u8, body, "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<loc>https://a.example.com/</loc><changefreq>weekly</changefreq><priority>1.0</priority>") != null);
    // `&` 已转义
    try testing.expect(std.mem.indexOf(u8, body, "x=1&amp;y=2") != null);
    // lastmod 只到日期，且按给定时区（+08）取本地日期
    try testing.expect(std.mem.indexOf(u8, body, "<lastmod>2023-11-15</lastmod>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "hreflang=\"zh-CN\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "hreflang=\"x-default\"") != null);
}

test "zzig.web.machine_resources：robots 含后台前缀与 AI 抓取器开关" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const allowed = try robotsAlloc(a, .{
        .sitemap_url = "https://a.example.com/sitemap.xml",
        .disallow = &.{ "/admin", "/api/" },
    });
    try testing.expect(std.mem.indexOf(u8, allowed, "User-agent: *\nAllow: /\n") != null);
    try testing.expect(std.mem.indexOf(u8, allowed, "Disallow: /admin\n") != null);
    try testing.expect(std.mem.indexOf(u8, allowed, "Sitemap: https://a.example.com/sitemap.xml") != null);
    try testing.expect(std.mem.indexOf(u8, allowed, "User-agent: GPTBot\nAllow: /") != null);

    const denied = try robotsAlloc(a, .{ .ai_bots_allowed = false });
    try testing.expect(std.mem.indexOf(u8, denied, "User-agent: GPTBot\nDisallow: /") != null);
}

test "zzig.web.machine_resources：llms.txt 分节 + 说明，空节不输出" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const body = try llmsAlloc(a, .{
        .site_name = "某某官网",
        .summary = "企业官网",
        .sections = &.{
            .{ .title = "栏目", .items = &.{
                .{ .name = "关于我们", .url = "https://a.example.com/c/about.html", .description = "公司简介" },
            } },
            .{ .title = "空节", .items = &.{} },
        },
    });
    try testing.expect(std.mem.startsWith(u8, body, "# 某某官网\n\n> 企业官网\n\n"));
    try testing.expect(std.mem.indexOf(u8, body, "## 栏目\n\n- [关于我们](https://a.example.com/c/about.html): 公司简介\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "空节") == null);
}
