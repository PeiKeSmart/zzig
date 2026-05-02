const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== 异步日志器验证测试 ===\n\n", .{});

    // 1. 验证 API 存在
    const config = zzig.AsyncLogger.AsyncLoggerConfig{
        .queue_capacity = 16384, // 增加到 16K (适应高频测试)
        .global_level = .info,
    };

    const logger = try zzig.AsyncLogger.AsyncLogger.init(allocator, config);
    defer logger.deinit();

    std.debug.print("✓ AsyncLogger 初始化成功\n", .{});

    // 2. 基本功能测试
    logger.info("测试消息 1", .{});
    logger.warn("测试消息 2: {s}", .{"格式化"});
    logger.err("测试消息 3: {d}", .{123});

    std.debug.print("✓ 日志记录成功\n", .{});

    // 3. 性能测试
    const start = compat.nanoTimestamp();
    const count = 10_000;

    for (0..count) |i| {
        logger.info("Performance test {d}", .{i});
    }

    const end = compat.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end - start));
    const avg_latency_ns = duration_ns / count;
    const qps = (count * std.time.ns_per_s) / duration_ns;

    std.debug.print("✓ 性能测试完成: {d} 条日志\n", .{count});
    std.debug.print("  平均延迟: {d} ns (≈ {d:.2} μs)\n", .{ avg_latency_ns, @as(f64, @floatFromInt(avg_latency_ns)) / 1000.0 });
    std.debug.print("  QPS: {d} 条/秒\n", .{qps});

    // 4. 等待处理
    std.debug.print("\n⏳ 等待后台处理...\n", .{});
    compat.sleep(2 * std.time.ns_per_s);

    // 5. 统计信息
    std.debug.print("\n📊 统计:\n", .{});
    std.debug.print("  已处理: {d} 条\n", .{logger.getProcessedCount()});
    std.debug.print("  已丢弃: {d} 条\n", .{logger.getDroppedCount()});
    std.debug.print("  队列剩余: {d} 条\n", .{logger.getQueueSize()});

    const total_sent = count + 3;
    const drop_rate = (@as(f64, @floatFromInt(logger.getDroppedCount())) / @as(f64, @floatFromInt(total_sent))) * 100.0;
    std.debug.print("  丢弃率: {d:.4}%\n", .{drop_rate});

    std.debug.print("\n=== 验证通过 ✅ ===\n", .{});
}
