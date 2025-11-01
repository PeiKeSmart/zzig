const std = @import("std");
const zzig = @import("zzig");

/// 工作线程函数
fn workerThread(thread_id: usize) void {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        zzig.Logger.info("线程 {d} - 消息 {d}", .{ thread_id, i });
        zzig.Logger.debug("线程 {d} - 调试信息 {d}", .{ thread_id, i });

        // 模拟一些工作
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    std.debug.print("\n=== Logger 多线程测试 ===\n\n", .{});

    // 测试 1: 不启用线程安全（默认）
    std.debug.print("【测试 1】不启用线程安全（可能会看到日志交错）\n", .{});
    {
        var threads: [3]std.Thread = undefined;

        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{i + 1});
        }

        for (threads) |thread| {
            thread.join();
        }
    }

    std.debug.print("\n" ++ "=" ** 50 ++ "\n\n", .{});
    std.time.sleep(100 * std.time.ns_per_ms);

    // 测试 2: 启用线程安全
    std.debug.print("【测试 2】启用线程安全（日志应该完整且不交错）\n", .{});
    zzig.Logger.enableThreadSafe();
    std.debug.print("线程安全模式: {}\n\n", .{zzig.Logger.isThreadSafe()});

    {
        var threads: [3]std.Thread = undefined;

        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{i + 1});
        }

        for (threads) |thread| {
            thread.join();
        }
    }

    std.debug.print("\n【测试完成】\n", .{});
}
