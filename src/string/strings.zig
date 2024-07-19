const std = @import("std");
const builtin = @import("builtin");

/// 函数用于将两个字符串拼接成一个新字符串。
///
/// 参数:
/// - allocator: 用于分配内存的分配器。
/// - a: 第一个要拼接的字符串。
/// - b: 第二个要拼接的字符串。
///
/// 返回:
/// - 拼接后的新字符串，或者在失败时返回错误。
pub fn AddString(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    // 使用指定的分配器将两个字符串拼接成一个新字符串
    return try std.mem.concat(allocator, u8, &[_][]const u8{ a, b });
}

/// 函数用于将多个字符串拼接成一个新字符串。
///
/// 参数:
/// - allocator: 用于分配内存的分配器。
/// - slices: 要拼接的字符串数组。
///
/// 返回:
/// - 拼接后的新字符串，或者在失败时返回错误。
pub fn AddStrings(allocator: std.mem.Allocator, slices: []const []const u8) ![]u8 {
    // 使用指定的分配器将两个字符串拼接成一个新字符串
    return try std.mem.concat(allocator, u8, slices);
}

/// 检查字符串 `a` 是否包含子字符串 `b`。
///
/// 参数:
/// - `a`: 要搜索的字符串。
/// - `b`: 要查找的子字符串。
///
/// 返回值:
/// - 如果 `a` 包含 `b`，则返回 `true`；否则返回 `false`。
pub fn Contains(a: []const u8, b: []const u8) bool {
    const found = std.mem.indexOf(u8, a, b) != null;

    return found;
}
