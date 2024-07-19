const std = @import("std");
const builtin = @import("builtin");

/// 函数用于获取当前工作目录的绝对路径。
///
/// 参数:
/// - allocator: 用于分配内存的分配器。
///
/// 返回:
/// - 当前工作目录的绝对路径，或者在失败时返回错误。
pub fn CurrentPath(allocator: std.mem.Allocator) ![]u8 {
    // 获取当前工作目录的句柄
    const cwd = std.fs.cwd();

    // 获取当前工作目录的绝对路径
    return cwd.realpathAlloc(allocator, ".");
}
