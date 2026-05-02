const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");

/// 函数用于获取当前工作目录的绝对路径。
///
/// 参数:
/// - allocator: 用于分配内存的分配器。
///
/// 返回:
/// - 当前工作目录的绝对路径，或者在失败时返回错误。
pub fn CurrentPathZ(allocator: std.mem.Allocator) ![:0]u8 {
    const cwd = compat.fs.cwd();
    return cwd.realpathAlloc(allocator, ".");
}

/// 函数用于获取当前工作目录的绝对路径。
///
/// 参数:
/// - allocator: 用于分配内存的分配器。
///
/// 返回:
/// - 当前工作目录的绝对路径，或者在失败时返回错误。
///
/// 说明:
/// - 为保持兼容，此函数仍返回 `[]u8`。
/// - 若调用方可接受 sentinel 结尾路径，优先使用 `CurrentPathZ` 以避免额外拷贝。
pub fn CurrentPath(allocator: std.mem.Allocator) ![]u8 {
    const path_z = try CurrentPathZ(allocator);
    defer allocator.free(path_z);
    return allocator.dupe(u8, path_z[0..path_z.len]);
}
