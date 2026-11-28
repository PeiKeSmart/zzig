//! C# `PekHtmlHelper` 的 Zig 等价物 —— **head 里的 SEO 元素可以分片累加、组合复用**。
//!
//! 为什么不是「在 pageModel 里拼字符串就完了」：C# 侧（`Pek.NCubeUI/UI/PekHtmlHelper.cs`）
//! 的 title / meta description / keywords / head 自定义标签都是 **parts 列表**：
//!
//! ```csharp
//! PekHtml.AppendTitleParts("公司简介");   // 局部视图 / 组件也能追加
//! var title = PekHtml.GenerateTitle();        // 统一拼装
//! ```
//!
//! 主布局、局部视图、组件、事件订阅者都能往同一份列表里加片段，最后由 `GenerateXxx`
//! 一次性拼出来 —— 这样一页的 head 才能「跨模板组合」而不是各拼各的。
//!
//! 本文件照抄它的语义（含默认值回退顺序）：
//!
//! | 输出 | 有 parts 时 | 没有 parts 时 |
//! |---|---|---|
//! | `<title>` | `页面标题 - 站点名`（`site_name_first` 可反转） | 后台 `SeoTitle` |
//! | description | parts 用 `", "` 连接 | 后台 `SeoDescribe` |
//! | keywords | parts 用 `", "` 连接 | 后台 `SeoKey` |
//!
//! `addXxxPart` 追加到**末尾**（后加的排后面），`appendXxxPart` **插到开头**（优先展示），
//! 与 C# 的 `Add*` / `Append*` 一致；拼装时统一 `reverse`，所以「后加的在前」。

const std = @import("std");
const value = @import("value.zig");

/// 站点级默认值（来自后台「站点设置」或配置文件）。
pub const Defaults = struct {
    /// 网站名称（C# `SiteInfo.GetDefaultSeo().SiteName`）
    site_name: []const u8 = "",
    /// 默认 SEO 标题：**页面一个标题片段都没有时**才用它（C# 同口径）
    seo_title: []const u8 = "",
    seo_describe: []const u8 = "",
    seo_key: []const u8 = "",
    /// 标题分隔符（C# `DHSetting.PageTitleSeparator`）
    separator: []const u8 = " - ",
    /// `PageTitleSeoAdjustment == 0` → 站点名在**前**；默认 false = 页面标题在前（C# 默认 1）
    site_name_first: bool = false,
    lang: []const u8 = "zh-CN",
    og_type: []const u8 = "website",
    /// `og:image`（**绝对 URL**）：社交平台分享时的大图；空则不输出。
    og_image: []const u8 = "",
};

/// 一个 hreflang 交替链接。
pub const Alternate = struct { hreflang: []const u8, href: []const u8 };

/// 一次请求一份（`arena` 分配，请求结束即释放）。
pub const PekHtml = struct {
    arena: std.mem.Allocator,
    defaults: Defaults,
    title_parts: std.ArrayList([]const u8) = .empty,
    desc_parts: std.ArrayList([]const u8) = .empty,
    keyword_parts: std.ArrayList([]const u8) = .empty,
    head_parts: std.ArrayList([]const u8) = .empty,
    canonical: []const u8 = "",
    alternates: std.ArrayList(Alternate) = .empty,
    /// 已包好 `<script type="application/ld+json">…</script>` 的片段（原样输出，不转义）
    json_ld: []const u8 = "",
    /// 是否允许索引（404 页应设 false → `noindex`）
    indexable: bool = true,

    pub fn init(arena: std.mem.Allocator, defaults: Defaults) PekHtml {
        return .{ .arena = arena, .defaults = defaults };
    }

    // ————— 标题 —————

    /// 追加标题片段（排在**后面**）。
    pub fn addTitlePart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.title_parts.append(self.arena, trimmed) catch {};
    }

    /// 把标题片段插到**最前面**（优先级高于先加的那些）。
    pub fn appendTitlePart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.title_parts.insert(self.arena, 0, trimmed) catch {};
    }

    /// 生成完整标题（与 C# `GenerateTitle` 同口径）。
    pub fn generateTitle(self: *PekHtml, allocator: std.mem.Allocator) ![]const u8 {
        var specific: std.ArrayList(u8) = .empty;
        defer specific.deinit(allocator);
        var i = self.title_parts.items.len;
        while (i > 0) {
            i -= 1;
            if (specific.items.len > 0) try specific.appendSlice(allocator, self.defaults.separator);
            try specific.appendSlice(allocator, self.title_parts.items[i]);
        }

        // 没有页面标题（首页/没有 SEO 标题的页）→ 后台 `SeoTitle`；
        // 后台也没配 → **站点名**（实测踩过：直接返回 `seo_title` 会让 `<title>` 变成空字符串）。
        if (specific.items.len == 0) {
            return if (self.defaults.seo_title.len > 0) self.defaults.seo_title else self.defaults.site_name;
        }
        if (self.defaults.site_name.len == 0) return specific.items;
        return if (self.defaults.site_name_first)
            std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.defaults.site_name, self.defaults.separator, specific.items })
        else
            std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ specific.items, self.defaults.separator, self.defaults.site_name });
    }

    // ————— 描述 / 关键词 —————

    pub fn addMetaDescriptionPart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.desc_parts.append(self.arena, trimmed) catch {};
    }

    pub fn appendMetaDescriptionPart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.desc_parts.insert(self.arena, 0, trimmed) catch {};
    }

    pub fn generateMetaDescription(self: *PekHtml, allocator: std.mem.Allocator) ![]const u8 {
        return joinReversed(allocator, self.desc_parts.items, ", ", self.defaults.seo_describe);
    }

    pub fn addMetaKeywordPart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.keyword_parts.append(self.arena, trimmed) catch {};
    }

    pub fn appendMetaKeywordPart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.keyword_parts.insert(self.arena, 0, trimmed) catch {};
    }

    pub fn generateMetaKeywords(self: *PekHtml, allocator: std.mem.Allocator) ![]const u8 {
        return joinReversed(allocator, self.keyword_parts.items, ", ", self.defaults.seo_key);
    }

    /// 是否有关键词（页面片段或后台默认）—— 视图/模型据此决定要不要输出 meta。
    pub fn hasKeywords(self: *PekHtml, allocator: std.mem.Allocator) !bool {
        return (try self.generateMetaKeywords(allocator)).len > 0;
    }

    // ————— canonical / 交替链接 / 自定义 head —————

    pub fn setCanonical(self: *PekHtml, href: []const u8) void {
        self.canonical = href;
    }

    pub fn addAlternate(self: *PekHtml, hreflang: []const u8, href: []const u8) void {
        if (hreflang.len == 0 or href.len == 0) return;
        self.alternates.append(self.arena, .{ .hreflang = hreflang, .href = href }) catch {};
    }

    /// 追加任意 head 元素（如 `<meta name="msvalidate.01" …>`）——
    /// 对应 C# `AddHeadCustomParts` / `AppendHeadCustomParts`。
    pub fn addHeadPart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.head_parts.append(self.arena, trimmed) catch {};
    }

    pub fn appendHeadPart(self: *PekHtml, part: []const u8) void {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return;
        self.head_parts.insert(self.arena, 0, trimmed) catch {};
    }

    pub fn setJsonLd(self: *PekHtml, script_html: []const u8) void {
        self.json_ld = script_html;
    }

    /// 生成整段 `<head>` 内部内容（视图里 `@Raw(Model.head)` 一次输出）。
    ///
    /// 顺序：title → description → keywords → robots → canonical → hreflang →
    ///      og:* → JSON-LD → 自定义片段。
    pub fn renderHead(self: *PekHtml, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;

        const title = try self.generateTitle(allocator);
        const description = try self.generateMetaDescription(allocator);
        const keywords = try self.generateMetaKeywords(allocator);

        try out.print(allocator, "<title>{s}</title>\n", .{try escape(allocator, title)});
        if (description.len > 0) {
            try out.print(allocator, "    <meta name=\"description\" content=\"{s}\">\n", .{try escape(allocator, description)});
        }
        if (keywords.len > 0) {
            try out.print(allocator, "    <meta name=\"keywords\" content=\"{s}\">\n", .{try escape(allocator, keywords)});
        }
        try out.print(allocator, "    <meta name=\"robots\" content=\"{s}\">\n", .{if (self.indexable) "index,follow" else "noindex,nofollow"});
        if (self.canonical.len > 0) {
            try out.print(allocator, "    <link rel=\"canonical\" href=\"{s}\">\n", .{try escape(allocator, self.canonical)});
        }
        for (self.alternates.items) |alt| {
            try out.print(allocator, "    <link rel=\"alternate\" hreflang=\"{s}\" href=\"{s}\">\n", .{
                try escape(allocator, alt.hreflang),
                try escape(allocator, alt.href),
            });
        }
        try out.print(allocator, "    <meta property=\"og:type\" content=\"{s}\">\n", .{try escape(allocator, self.defaults.og_type)});
        if (self.defaults.site_name.len > 0) {
            try out.print(allocator, "    <meta property=\"og:site_name\" content=\"{s}\">\n", .{try escape(allocator, self.defaults.site_name)});
        }
        // `og:locale` 用 `xx_YY` 形式（Open Graph 规定）；`zh-CN` → `zh_CN`。
        try out.print(allocator, "    <meta property=\"og:locale\" content=\"{s}\">\n", .{try escape(allocator, try ogLocale(allocator, self.defaults.lang))});
        if (self.defaults.og_image.len > 0) {
            try out.print(allocator, "    <meta property=\"og:image\" content=\"{s}\">\n", .{try escape(allocator, self.defaults.og_image)});
        }
        if (self.canonical.len > 0) {
            try out.print(allocator, "    <meta property=\"og:url\" content=\"{s}\">\n", .{try escape(allocator, self.canonical)});
        }
        try out.print(allocator, "    <meta property=\"og:title\" content=\"{s}\">\n", .{try escape(allocator, title)});
        if (description.len > 0) {
            try out.print(allocator, "    <meta property=\"og:description\" content=\"{s}\">\n", .{try escape(allocator, description)});
        }
        // Twitter 卡片（X/微信等分享时的标题与简介）
        try out.print(allocator, "    <meta name=\"twitter:card\" content=\"summary\">\n", .{});
        try out.print(allocator, "    <meta name=\"twitter:title\" content=\"{s}\">\n", .{try escape(allocator, title)});
        if (description.len > 0) {
            try out.print(allocator, "    <meta name=\"twitter:description\" content=\"{s}\">\n", .{try escape(allocator, description)});
        }
        if (self.json_ld.len > 0) {
            try out.print(allocator, "    {s}\n", .{self.json_ld});
        }
        for (self.head_parts.items) |part| {
            try out.print(allocator, "    {s}\n", .{part});
        }
        return out.toOwnedSlice(allocator);
    }

    /// `<html lang="…">` 用的语言码。
    pub fn lang(self: *const PekHtml) []const u8 {
        return self.defaults.lang;
    }
};

fn joinReversed(
    allocator: std.mem.Allocator,
    parts: []const []const u8,
    sep: []const u8,
    fallback: []const u8,
) ![]const u8 {
    if (parts.len == 0) return fallback;
    var out: std.ArrayList(u8) = .empty;
    var i = parts.len;
    while (i > 0) {
        i -= 1;
        if (out.items.len > 0) try out.appendSlice(allocator, sep);
        try out.appendSlice(allocator, parts[i]);
    }
    return out.toOwnedSlice(allocator);
}

fn escape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return value.escapeHtmlAlloc(allocator, text);
}

/// BCP47（`zh-CN` / `en`）→ Open Graph 的 `xx_YY`（`zh_CN` / `en`）。
fn ogLocale(allocator: std.mem.Allocator, lang: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, lang, '-') == null) return lang;
    const out = try allocator.dupe(u8, lang);
    for (out) |*ch| {
        if (ch.* == '-') ch.* = '_';
    }
    return out;
}

// ————— 单测（语义对齐 C# `PekHtmlHelper`）—————

test "zzig.web.pek_html：标题 = 页面标题 - 站点名（默认）/ 站点名在前可反转" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var html = PekHtml.init(arena, .{ .site_name = "海林兴", .seo_title = "默认 SEO 标题" });
    html.addTitlePart("公司简介");
    try std.testing.expectEqualStrings("公司简介 - 海林兴", try html.generateTitle(arena));

    var reversed = PekHtml.init(arena, .{ .site_name = "海林兴", .site_name_first = true });
    reversed.addTitlePart("公司简介");
    try std.testing.expectEqualStrings("海林兴 - 公司简介", try reversed.generateTitle(arena));
}

test "zzig.web.pek_html：没有页面标题时回退后台 SeoTitle（不是站点名）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var html = PekHtml.init(arena, .{ .site_name = "海林兴", .seo_title = "海林兴官网" });
    try std.testing.expectEqualStrings("海林兴官网", try html.generateTitle(arena));
}

test "zzig.web.pek_html：SeoTitle 也没配时回退站点名（不能是空标题）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var html = PekHtml.init(arena, .{ .site_name = "海林兴" });
    try std.testing.expectEqualStrings("海林兴", try html.generateTitle(arena));
}

test "zzig.web.pek_html：后加的片段排在前面；append 插到最前" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var html = PekHtml.init(arena, .{ .site_name = "站点" });
    html.addTitlePart("外层");
    html.addTitlePart("内层");
    try std.testing.expectEqualStrings("内层 - 外层 - 站点", try html.generateTitle(arena));

    var html2 = PekHtml.init(arena, .{ .site_name = "站点" });
    html2.addTitlePart("后加");
    html2.appendTitlePart("先显");
    try std.testing.expectEqualStrings("后加 - 先显 - 站点", try html2.generateTitle(arena));
}

test "zzig.web.pek_html：描述与关键词用逗号连接，空则回退后台默认" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var html = PekHtml.init(arena, .{ .seo_describe = "默认描述", .seo_key = "默认关键词" });
    html.addMetaDescriptionPart("页面描述");
    try std.testing.expectEqualStrings("页面描述", try html.generateMetaDescription(arena));
    try std.testing.expectEqualStrings("默认关键词", try html.generateMetaKeywords(arena));

    var empty = PekHtml.init(arena, .{ .seo_describe = "默认描述" });
    try std.testing.expectEqualStrings("默认描述", try empty.generateMetaDescription(arena));
}

test "zzig.web.pek_html：renderHead 转义特殊字符、noindex 生效、JSON-LD 原样输出" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var html = PekHtml.init(arena, .{ .site_name = "A&B<工具>" });
    html.addTitlePart("\"引号\"");
    html.setCanonical("https://example.com/a?x=1&y=2");
    html.setJsonLd("<script type=\"application/ld+json\">{\"a\":1}</script>");
    html.indexable = false;

    const head = try html.renderHead(arena);
    try std.testing.expect(std.mem.indexOf(u8, head, "&amp;") != null); // 站点名里的 &
    try std.testing.expect(std.mem.indexOf(u8, head, "&lt;工具&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "noindex,nofollow") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "<script type=\"application/ld+json\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "x=1&amp;y=2") != null);
}
