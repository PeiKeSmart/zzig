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

var temp_name_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// 生成一个唯一的**文件名**（不含目录，调用方负责 free）。
///
/// 用途：测试库文件、导出中间文件、临时下载文件——避免不同进程/不同轮次互相覆盖。
/// 唯一性来自「纳秒时间戳 + 进程内计数器」，不依赖随机数（0.17 已移除 `std.crypto.random`）。
pub fn UniqueTempName(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const id = temp_name_counter.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(allocator, ".{c}{s}-{d}-{d}{s}", .{
        std.fs.path.sep,
        prefix,
        compat.nanoTimestamp(),
        id,
        suffix,
    });
}

/// 尽力删除文件：文件不存在、被占用、非 Windows 平台一律静默忽略。
///
/// 仅供收尾清理（测试临时文件、一次性产物）使用；需要感知失败请直接用 `std.Io.Dir.deleteFile`。
pub fn DeleteQuiet(path: []const u8) void {
    if (builtin.os.tag != .windows) return;

    const k32 = struct {
        extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) i32;
    };
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    _ = k32.DeleteFileA(path_z);
}
