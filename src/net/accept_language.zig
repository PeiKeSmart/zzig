//! `Accept-Language` 头解析与语言挑选（HTTP 语义，与具体站点无关）。
//!
//! 为什么放在框架里：**每个有语言前缀的站点都要做同一件事**，而标签与站内前缀的对应关系
//! 各站点不同（`zh-CN` 的标签是 `zh`，URL 前缀却常写成 `cn`），所以解析归框架、
//! 「哪些语言可用」由调用方传进来。
//!
//! 典型用法（`q` 权重降序、忽略 `*`、`en-US` 只取 `en`）：
//!
//! ```zig
//! const langs = [_]zzig.accept_language.Lang{
//!     .{ .tag = "zh", .prefix = "cn" },
//!     .{ .tag = "en", .prefix = "en" },
//! };
//! const picked = try zzig.accept_language.pick(arena, "en-US,en;q=0.9,zh;q=0.8", &langs, "cn");
//! // picked = "en"（命中默认语言 `cn` 时返回 null，表示不必跳转）
//! ```

const std = @import("std");

/// 一门可切换语言的两个标识。
///
/// **必须成对传**：`Accept-Language` 给的是语言标签（`zh-CN` → `zh`），
/// 而站内 URL 前缀往往不同（`zh-CN` → `cn`）—— 直接拿标签比前缀会把中文漏掉。
pub const Lang = struct {
    /// 语言标签主段（小写），如 `zh` / `en` / `ja`
    tag: []const u8,
    /// 站内 URL 前缀，如 `cn` / `en` / `ja`（默认语言可能是空串）
    prefix: []const u8,
};

/// 从 `Accept-Language` 里挑一个**已启用且非默认**的语言，返回它的 **URL 前缀**。
///
/// 规则：
/// - 按 `q` 权重降序，同权重保持出现顺序；
/// - 候选既能按语言标签（`zh`）也能按前缀（`cn`）命中；
/// - `*` 与空项忽略；`en-US` 只取主段 `en`；
/// - 命中默认语言（`default_prefix`）时返回 `null` = 不用跳。
pub fn pick(
    arena: std.mem.Allocator,
    header: []const u8,
    langs: []const Lang,
    default_prefix: []const u8,
) !?[]const u8 {
    if (header.len == 0 or langs.len == 0) return null;

    const Candidate = struct { tag: []const u8, q: u16 };
    var list: std.ArrayList(Candidate) = .empty;
    defer list.deinit(arena);

    var iter = std.mem.splitScalar(u8, header, ',');
    while (iter.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) continue;
        var tag = item;
        var q: u16 = 1000;
        if (std.mem.indexOfScalar(u8, item, ';')) |semi| {
            tag = std.mem.trim(u8, item[0..semi], " \t");
            const params = item[semi + 1 ..];
            if (std.mem.indexOf(u8, params, "q=")) |qi| {
                const text = std.mem.trim(u8, params[qi + 2 ..], " \t;");
                const parsed = std.fmt.parseFloat(f32, text) catch 1.0;
                q = @intFromFloat(@round(parsed * 1000.0));
            }
        }
        if (tag.len == 0 or std.mem.eql(u8, tag, "*")) continue;
        if (std.mem.indexOfScalar(u8, tag, '-')) |dash| tag = tag[0..dash];
        try list.append(arena, .{ .tag = tag, .q = q });
    }

    // 权重降序（稳定：同权重按原顺序）
    std.mem.sort(Candidate, list.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            return a.q > b.q;
        }
    }.lt);

    for (list.items) |cand| {
        for (langs) |lang| {
            const hit = std.ascii.eqlIgnoreCase(cand.tag, lang.tag) or
                (lang.prefix.len > 0 and std.ascii.eqlIgnoreCase(cand.tag, lang.prefix));
            if (!hit) continue;
            if (std.ascii.eqlIgnoreCase(lang.prefix, default_prefix)) return null;
            if (default_prefix.len == 0 and lang.prefix.len == 0) return null;
            return lang.prefix;
        }
    }
    return null;
}

/// 语言标签主段（小写）：`zh-CN` → `zh`；空串/无文化码时用 `fallback` 兜底。
pub fn primaryTagAlloc(arena: std.mem.Allocator, language_culture: []const u8, fallback: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, language_culture, " \t\r\n");
    const source = if (text.len > 0) text else fallback;
    if (source.len == 0) return "";
    const primary = if (std.mem.indexOfScalar(u8, source, '-')) |dash| source[0..dash] else source;
    return try std.ascii.allocLowerString(arena, primary);
}

const testing = std.testing;

test "accept_language：按权重挑语言，标签与前缀成对匹配" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const langs = [_]Lang{
        .{ .tag = "zh", .prefix = "cn" },
        .{ .tag = "en", .prefix = "en" },
        .{ .tag = "ja", .prefix = "ja" },
    };

    // 首选中文 → 命中默认语言，不跳
    try testing.expect((try pick(a, "zh-CN,zh;q=0.9,en;q=0.8", &langs, "cn")) == null);
    // 首选英文 → 跳 en
    try testing.expectEqualStrings("en", (try pick(a, "en-US,en;q=0.9,zh;q=0.8", &langs, "cn")).?);
    // 不认识的语言退到英文
    try testing.expectEqualStrings("en", (try pick(a, "ko-KR,ko;q=0.9,en;q=0.8", &langs, "cn")).?);
    // 全不认识 → 不跳
    try testing.expect((try pick(a, "ko-KR,ko;q=0.9", &langs, "cn")) == null);
    // 权重更高者胜出
    try testing.expectEqualStrings("en", (try pick(a, "ja;q=0.2,en;q=0.9", &langs, "cn")).?);
    // 通配与空头
    try testing.expect((try pick(a, "*", &langs, "cn")) == null);
    try testing.expect((try pick(a, "", &langs, "cn")) == null);
}

test "accept_language：primaryTagAlloc 取主段并小写" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("zh", try primaryTagAlloc(a, "zh-CN", "cn"));
    try testing.expectEqualStrings("en", try primaryTagAlloc(a, "EN-us", "en"));
    try testing.expectEqualStrings("cn", try primaryTagAlloc(a, "", "cn"));
    try testing.expectEqualStrings("", try primaryTagAlloc(a, "", ""));
}
