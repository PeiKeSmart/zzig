//! URL 规范化（SEO：**同一内容只能有一个地址**）。
//!
//! 典型的重复内容来源：路由器把路径参数当成整段匹配，于是
//! `/x`、`/x/`、`/x.html`、`/X.HTML` 会命中同一个处理器、全部返回 200 ——
//! 搜索引擎把权重摊到多个地址上，收录也会抖。正确做法是**301 到一个规范形式**。
//!
//! 本模块只做纯文本推导，不认识业务语义：
//! - 「哪些前缀要管」由调用方给（`prefixes`，如 `&.{"/category/","/article/"}`）；
//! - 规范形式由调用方通过 `Style` 选择（**带后缀** / **不带后缀**），两种都是常见站点口径；
//! - 语言前缀（`/en/...`）自动识别为「单段、长度 ≤ `MAX_LANG_PREFIX_LEN`」。
//!
//! 不管的路径一律返回 `null`（调用方原样处理）：首页、后台、`/robots.txt` 这类
//! —— 把 `/admin` 改写成 `/admin.html` 那种事故不能有。
//!
//! ```zig
//! const target = try zzig.url_canon.canonicalAlloc(arena, c.req.path, &.{"/category/"}, .{ .suffix = ".html" });
//! if (target) |path| return redirect301(path);
//! ```

const std = @import("std");

/// 语言前缀最长长度（`/en`、`/zh-cn` 都在内）；超过就不当语言前缀。
pub const MAX_LANG_PREFIX_LEN: usize = 8;

/// 规范形式。
pub const Style = struct {
    /// 期望的后缀，`".html"` / `""`（空 = 不带后缀）。
    suffix: []const u8 = ".html",
    /// 是否把整条路径转小写（别名/语言前缀通常都是小写）。
    lowercase: bool = true,
    /// 是否去掉尾斜杠。
    strip_trailing_slash: bool = true,
};

const Marker = struct { at: usize, len: usize };

/// 在（已小写的）路径里定位 `prefix`（含语言前缀的情况）。
/// 前缀部分只能是空串或**单段**语言前缀（`/en`），否则视为不相关路径。
fn markerAt(low: []const u8, prefixes: []const []const u8) ?Marker {
    for (prefixes) |prefix| {
        if (prefix.len == 0) continue;
        const at = std.mem.indexOf(u8, low, prefix) orelse continue;
        const before = low[0..at];
        if (before.len == 0) return .{ .at = at, .len = prefix.len };
        if (before.len <= MAX_LANG_PREFIX_LEN and before[0] == '/' and
            std.mem.indexOf(u8, before[1..], "/") == null)
        {
            return .{ .at = at, .len = prefix.len };
        }
    }
    return null;
}

/// 计算规范地址；**已经是规范形式时返回 `null`**（调用方据此决定要不要 301）。
///
/// 不处理的情况（返回 `null`，交给后续 404）：
/// - 不匹配任何 `prefixes`；
/// - 参数段为空（`/category/`）或含多余层级（`/category/a/b`）；
/// - 后缀是别的带点形式（`/category/x.htm`，不猜）。
pub fn canonicalAlloc(
    arena: std.mem.Allocator,
    path: []const u8,
    prefixes: []const []const u8,
    style: Style,
) !?[]const u8 {
    if (path.len == 0 or prefixes.len == 0) return null;

    // ① 去尾斜杠（可能多个）
    var end = path.len;
    if (style.strip_trailing_slash) {
        while (end > 0 and path[end - 1] == '/') end -= 1;
    }
    const trimmed = path[0..end];
    if (trimmed.len == 0) return null;

    // ② 小写（可选）
    const low = if (style.lowercase)
        try std.ascii.allocLowerString(arena, trimmed)
    else
        trimmed;

    // ③ 定位前缀段
    const marker = markerAt(low, prefixes) orelse return null;
    const tail = low[marker.at + marker.len ..];
    if (tail.len == 0) return null;
    if (std.mem.indexOfScalar(u8, tail, '/') != null) return null;

    // ④ 补/去后缀
    var out: []const u8 = low;
    if (style.suffix.len > 0) {
        // 要求带后缀时：带点但不是期望后缀（`.htm` / `.php`）不猜
        if (std.mem.indexOfScalar(u8, tail, '.')) |dot| {
            if (!std.mem.endsWith(u8, tail, style.suffix) or dot + style.suffix.len != tail.len) return null;
        }
        if (!std.mem.endsWith(u8, tail, style.suffix)) {
            out = try std.fmt.allocPrint(arena, "{s}{s}", .{ low, style.suffix });
        }
    } else {
        // 带后缀的站点口径：去掉最后一段的点后缀（只认最后一个 `.`）
        if (std.mem.lastIndexOfScalar(u8, low, '.')) |dot| {
            if (dot > marker.at + marker.len) out = low[0..dot];
        }
    }

    if (std.mem.eql(u8, out, path)) return null;
    return out;
}

const testing = std.testing;

test "url_canon：补 .html / 去尾斜杠 / 转小写 / 语言前缀 / 不相关路径不动" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const prefixes = [_][]const u8{ "/category/", "/article/" };
    const style = Style{};

    const cases = [_]struct { in: []const u8, want: ?[]const u8 }{
        .{ .in = "/category/about-us", .want = "/category/about-us.html" },
        .{ .in = "/category/about-us/", .want = "/category/about-us.html" },
        .{ .in = "/category/about-us///", .want = "/category/about-us.html" },
        .{ .in = "/category/ABOUT-US.html", .want = "/category/about-us.html" },
        .{ .in = "/Category/About-Us", .want = "/category/about-us.html" },
        // 已规范 → 不跳（否则 301 循环）
        .{ .in = "/category/about-us.html", .want = null },
        // 语言前缀
        .{ .in = "/en/category/about-us", .want = "/en/category/about-us.html" },
        .{ .in = "/en/article/news-1/", .want = "/en/article/news-1.html" },
        // 不在清单里的路径一律不动
        .{ .in = "/", .want = null },
        .{ .in = "/admin/home/index", .want = null },
        .{ .in = "/robots.txt", .want = null },
        .{ .in = "/en/articles", .want = null },
        // 不猜的后缀 / 多余层级 / 前缀过长
        .{ .in = "/category/about-us.htm", .want = null },
        .{ .in = "/category/", .want = null },
        .{ .in = "/category/a/b.html", .want = null },
        .{ .in = "/verylongprefix/category/x", .want = null },
    };
    for (cases) |case| {
        const got = try canonicalAlloc(a, case.in, &prefixes, style);
        if (case.want) |want| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(want, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "url_canon：不带后缀的站点口径（suffix = \"\"）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const prefixes = [_][]const u8{"/p/"};

    try testing.expectEqualStrings("/p/about", (try canonicalAlloc(a, "/p/about.html", &prefixes, .{ .suffix = "" })).?);
    try testing.expect((try canonicalAlloc(a, "/p/about", &prefixes, .{ .suffix = "" })) == null);
}
