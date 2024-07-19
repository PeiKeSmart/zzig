const std = @import("std");
const builtin = @import("builtin");
const strings = @import("../zzig.zig").Strings;

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
        std.debug.print("Error: The '{s}' placeholder is missing from the formatted string.", .{"{s}"});
    }
}

/// PrintString 打印格式化字符串。
///
/// 参数:
/// - `fmt`: 格式化字符串，使用 comptime 确定格式。
/// - `args`: 要打印的字符串参数。
///
/// 返回:
/// - 无返回值。
pub fn PrintNumber(comptime fmt: []const u8, args: anytype) void {
    if (strings.Contains(fmt, "{d}")) {
        std.debug.print(fmt, .{args});
    } else {
        //@compileError("错误: 格式化字符串中缺少 '{d}' 占位符。");
        std.debug.print("Error: The '{s}' placeholder is missing from the formatted string.", .{"{d}"});
    }
}
