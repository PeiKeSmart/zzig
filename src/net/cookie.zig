//! Cookie **请求头**解析（`Cookie: a=1; b=2`）。
//!
//! 只负责读：值原样返回（不做 URL 解码，调用方按需处理）。
//! 写 `Set-Cookie` 属于业务策略（`HttpOnly` / `SameSite` / `Max-Age`），留在各消费方。

const std = @import("std");

/// 从 `Cookie` 请求头取指定名字的值（名字精确匹配、大小写敏感）。
///
/// - 自动跳过 `;` 两侧空白；
/// - 值里允许出现 `=`（只按第一个 `=` 切分）；
/// - 同名出现多次时取第一个（与浏览器语义一致）。
pub fn value(header: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var iterator = std.mem.splitScalar(u8, header, ';');
    while (iterator.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        if (std.mem.eql(u8, item[0..eq], name)) return item[eq + 1 ..];
    }
    return null;
}

/// 取指定名字的 Cookie，缺省返回 `""`（便于 `orelse` 场景写成空串比较）。
pub fn valueOrEmpty(header: ?[]const u8, name: []const u8) []const u8 {
    const text = header orelse return "";
    return value(text, name) orelse "";
}

const testing = std.testing;

test "cookie：解析 Cookie 头" {
    try testing.expectEqualStrings("v1", value("a=v1; biz_token=v2", "a").?);
    try testing.expectEqualStrings("v2", value("a=v1; biz_token=v2", "biz_token").?);
    try testing.expectEqualStrings("v2", value("a=v1;biz_token=v2", "biz_token").?);
    try testing.expectEqualStrings("v2", value(" a=v1 ; biz_token=v2 ", "biz_token").?);

    // 值里带 `=`
    try testing.expectEqualStrings("a=b=c", value("token=a=b=c", "token").?);

    // 缺失 / 空头 / 空名
    try testing.expect(value("a=v1", "biz_token") == null);
    try testing.expect(value("", "biz_token") == null);
    try testing.expect(value("a=v1", "") == null);

    // 前缀相同的名字不能误命中
    try testing.expect(value("biz_token_old=v1", "biz_token") == null);

    try testing.expectEqualStrings("", valueOrEmpty(null, "biz_token"));
    try testing.expectEqualStrings("", valueOrEmpty("a=v1", "biz_token"));
    try testing.expectEqualStrings("v1", valueOrEmpty("biz_token=v1", "biz_token"));
}
