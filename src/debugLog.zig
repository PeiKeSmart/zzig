const std = @import("std");
const builtin = @import("builtin");
const strings = @import("strings.zig");

/// PrintStrings 打印字符串。
///
/// 参数:
/// - args: 用于拼接字符串的参数列表。
///
/// 返回:
/// - 无返回值。
pub fn PrintStrings(args: []const []const u8) void {
    std.debug.print("{s}\n", .{args});
}

/// PrintString 打印格式化字符串。
///
/// 参数:
/// - `fmt`: 格式化字符串，使用 comptime 确定格式。
/// - `args`: 要打印的字符串参数。
///
/// 返回:
/// - 无返回值。
pub fn PrintString(comptime fmt: []const u8, args: []u8) void {
    if (strings.Contains(fmt, "{s}")) {
        std.debug.print(fmt, .{args});
    } else {
        //@compileError("错误: 格式化字符串中缺少 '{s}' 占位符。");
        std.debug.print("错误: 格式化字符串中缺少 '{s}' 占位符。", .{"{s}"});
    }
}
