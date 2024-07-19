const std = @import("std");
const builtin = @import("builtin");

/// JointoString 函数用于将两个字符串拼接成一个新字符串。
///
/// 参数:
/// - allocator: 用于分配内存的分配器。
/// - a: 第一个要拼接的字符串。
/// - b: 第二个要拼接的字符串。
///
/// 返回:
/// - 拼接后的新字符串，或者在失败时返回错误。
pub fn JointoString(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    // 使用指定的分配器将两个字符串拼接成一个新字符串
    return try std.mem.concat(allocator, u8, &[_][]const u8{ a, b });
}
