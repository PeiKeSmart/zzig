//! 进程工具模块 - 提供外部进程执行和输出读取功能
//!
//! 设计目标：
//! 1. 跨平台：支持 Windows、Linux、macOS
//! 2. 轻量级：基于 std.process.Child 的薄包装
//! 3. 易用性：简化常见的外部命令执行场景
//! 4. 安全性：自动处理退出码和输出清理

const std = @import("std");

/// 进程执行结果
pub const ProcessResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

/// 执行外部命令并读取输出
/// 命令成功执行（退出码为 0）时返回修剪后的 stdout
/// 命令失败时返回 ProcessFailed 错误
///
/// 参数:
/// - allocator: 内存分配器
/// - exe: 可执行文件路径或名称
/// - args: 命令参数列表
///
/// 返回:
/// - 修剪后的 stdout 字符串（去除首尾空白、换行符），由调用方负责释放
/// - 失败时返回 ProcessFailed 错误
pub fn runAndReadOutput(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]u8 {
    var argv = try allocator.alloc([]const u8, 1 + args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    for (args, 0..) |a, i| argv[i + 1] = a;
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    switch (res.term) {
        .Exited => |code| {
            if (code != 0) return error.ProcessFailed;
        },
        else => return error.ProcessFailed,
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \r\n\t");
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(res.stdout);
    return out;
}

/// 执行外部命令并获取完整结果（包括 stdout、stderr、退出码）
/// 不自动判断退出码，由调用方自行处理
///
/// 参数:
/// - allocator: 内存分配器
/// - exe: 可执行文件路径或名称
/// - args: 命令参数列表
///
/// 返回:
/// - ProcessResult 结构体，包含 stdout、stderr 和 exit_code
///   stdout 和 stderr 由调用方负责释放
pub fn runWithResult(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !ProcessResult {
    var argv = try allocator.alloc([]const u8, 1 + args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    for (args, 0..) |a, i| argv[i + 1] = a;
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    const exit_code: u8 = switch (res.term) {
        .Exited => |code| code,
        else => return error.ProcessFailed,
    };
    return ProcessResult{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = exit_code,
    };
}

// ============================================================================
// 测试用例
// ============================================================================

test "runAndReadOutput executes echo command" {
    const allocator = std.testing.allocator;
    const result = runAndReadOutput(allocator, "echo", &.{"hello"}) catch |err| {
        // 在某些平台上 echo 可能不存在或路径不同，跳过测试
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}