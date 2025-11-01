const std = @import("std");
const AsyncLogger = @import("../src/logs/async_logger.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== 异步日志器快速测试 ===\n\n", .{});

    const logger = try AsyncLogger.AsyncLogger.init(allocator, .{});
    defer logger.deinit();

    // 快速测试
    logger.info("测试 1: 基本消息", .{});
    logger.warn("测试 2: 格式化 {s}", .{"成功"});

    const start = std.time.nanoTimestamp();
    for (0..1000) |i| {
        logger.info("消息 {d}", .{i});
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / 1000;
    const qps = (1000 * std.time.ns_per_s) / duration_ns;

    std.debug.print("✓ 1000 条日志\n", .{});
    std.debug.print("✓ 平均延迟: {d} ns\n", .{avg_ns});
    std.debug.print("✓ QPS: {d} 条/秒\n", .{qps});

    std.Thread.sleep(1 * std.time.ns_per_s);

    std.debug.print("\n已处理: {d} 条\n", .{logger.getProcessedCount()});
    std.debug.print("已丢弃: {d} 条\n", .{logger.getDroppedCount()});

    std.debug.print("\n=== 测试完成 ===\n", .{});
}
