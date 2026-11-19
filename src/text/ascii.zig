//! ASCII 大小写不敏感的前缀/后缀/子串判定。
//!
//! 各消费方此前各写一份（`startsWithIgnoreCase` / `containsIgnoreCase` / `endsWithIgnoreCase`），
//! 现统一到这里：只做 ASCII 折叠，非 ASCII 字节原样比较（UTF-8 多字节不受影响）。

const std = @import("std");

/// 是否以 `prefix` 开头（ASCII 大小写不敏感）。
pub fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

/// 是否以 `suffix` 结尾（ASCII 大小写不敏感）。
pub fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (suffix.len == 0 or text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

/// 子串位置（ASCII 大小写不敏感）；空 `needle` 返回 0。
pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

/// 是否包含 `needle`（ASCII 大小写不敏感）。
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

const testing = std.testing;

test "ascii：前缀/后缀/子串（大小写不敏感）" {
    try testing.expect(startsWithIgnoreCase("/Biz/Home/Index", "/biz/"));
    try testing.expect(!startsWithIgnoreCase("/biz", "/biz/"));
    try testing.expect(startsWithIgnoreCase("/biz", "/BIZ"));

    try testing.expect(endsWithIgnoreCase("/about.HTML", ".html"));
    try testing.expect(!endsWithIgnoreCase("/about", ".html"));
    try testing.expect(!endsWithIgnoreCase("x", ""));

    try testing.expectEqual(@as(?usize, 5), indexOfIgnoreCase("/biz/Config/Index", "config"));
    try testing.expect(indexOfIgnoreCase("/biz", "config") == null);
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("abc", ""));
    try testing.expect(containsIgnoreCase("application/JSON", "json"));

    // 非 ASCII 只做逐字节比较：中文不受影响
    try testing.expect(endsWithIgnoreCase("站点设置", "设置"));
    try testing.expect(!endsWithIgnoreCase("站点设置", "配置"));
}
