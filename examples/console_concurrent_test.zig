const std = @import("std");
const Console = @import("zzig").Console;

/// 测试 Console 并发初始化安全性
pub fn main() !void {
    std.debug.print("🧪 测试 Console 并发初始化...\n", .{});

    // 创建多个线程同时初始化 Console
    const thread_count = 10;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{});
    }

    // 等待所有线程完成
    for (threads) |thread| {
        thread.join();
    }

    std.debug.print("✅ 并发初始化测试通过！\n", .{});
    std.debug.print("✨ 中文和 ANSI 颜色显示正常\n", .{});
    std.debug.print("\x1b[32m绿色文本\x1b[0m\n", .{});
    std.debug.print("\x1b[33m黄色文本\x1b[0m\n", .{});
    std.debug.print("\x1b[34m蓝色文本\x1b[0m\n", .{});
}

fn workerThread() void {
    // 每个线程都尝试初始化 Console
    const result = Console.init(.{});

    // 使用 volatile 防止编译器优化掉（防止死代码消除）
    var dummy: u32 = 0;
    if (result.utf8_enabled) dummy +%= 1;
    if (result.ansi_enabled) dummy +%= 1;
    std.mem.doNotOptimizeAway(&dummy);

    // 模拟一些工作
    std.Thread.sleep(10 * std.time.ns_per_ms);
}
