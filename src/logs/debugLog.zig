const std = @import("std");
const builtin = @import("builtin");

/// PrintString 打印字符串。
///
/// 参数:
/// - args: 用于拼接字符串的参数列表。
///
/// 返回:
/// - 无返回值。
pub fn PrintString(args: []const []const u8) void {
    std.debug.print("{s}\n", .{args});
}
