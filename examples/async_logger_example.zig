const std = @import("std");
const AsyncLogger = @import("zzig").AsyncLogger;
const compat = @import("zzig").compat;

/// 异步日志器基本使用示例
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== 异步日志器使用示例 ===\n\n", .{});

    // 1. 创建异步日志器（使用默认配置）
    const logger = try AsyncLogger.AsyncLogger.init(allocator, .{});
    defer logger.deinit();

    std.debug.print("✓ 异步日志器已启动\n\n", .{});

    // 2. 基本日志记录（非阻塞）
    std.debug.print("📝 测试 1: 基本日志记录\n", .{});
    logger.debug("这是一条调试消息", .{});
    logger.info("这是一条信息消息", .{});
    logger.warn("这是一条警告消息", .{});
    logger.err("这是一条错误消息", .{});

    // 3. 格式化参数
    std.debug.print("\n📝 测试 2: 格式化参数\n", .{});
    const user = "张三";
    const age = 25;
    logger.info("用户 {s} 已登录，年龄: {d}", .{ user, age });

    // 4. 性能测试：快速写入
    std.debug.print("\n📝 测试 3: 高频日志写入 (10000 条)\n", .{});
    const start = compat.nanoTimestamp();

    for (0..10000) |i| {
        logger.info("消息 #{d}: 系统运行正常", .{i});
    }

    const end = compat.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end - start));
    const duration_us = duration_ns / std.time.ns_per_us;
    const qps = (10000 * std.time.ns_per_s) / duration_ns;
    const avg_latency_ns = duration_ns / 10000;

    std.debug.print("   ✓ 耗时: {d} μs\n", .{duration_us});
    std.debug.print("   ✓ QPS: {d} 条/秒\n", .{qps});
    std.debug.print("   ✓ 平均延迟: {d} ns (≈ {d:.2} μs)\n", .{ avg_latency_ns, @as(f64, @floatFromInt(avg_latency_ns)) / 1000.0 });

    // 5. 等待日志处理完成
    std.debug.print("\n⏳ 等待后台线程处理日志...\n", .{});
    compat.sleep(2 * std.time.ns_per_s);

    // 6. 查看统计信息
    std.debug.print("\n📊 统计信息:\n", .{});
    std.debug.print("   已处理: {d} 条\n", .{logger.getProcessedCount()});
    std.debug.print("   已丢弃: {d} 条\n", .{logger.getDroppedCount()});
    std.debug.print("   队列剩余: {d} 条\n", .{logger.getQueueSize()});

    // 7. 日志级别控制
    std.debug.print("\n📝 测试 4: 日志级别控制\n", .{});
    logger.setLevel(.warn);
    std.debug.print("   设置级别为 WARN，debug 和 info 将被过滤\n", .{});

    logger.debug("这条 debug 不会显示", .{});
    logger.info("这条 info 也不会显示", .{});
    logger.warn("这条 warn 会显示", .{});
    logger.err("这条 error 会显示", .{});

    // 等待最后的日志
    compat.sleep(500 * std.time.ns_per_ms);

    std.debug.print("\n=== 示例完成 ===\n", .{});
    std.debug.print("\n💡 提示:\n", .{});
    std.debug.print("   • 异步日志器自动在后台线程处理日志\n", .{});
    std.debug.print("   • 主线程不会被日志输出阻塞\n", .{});
    std.debug.print("   • 适用于高并发、高性能场景\n", .{});
    std.debug.print("   • 队列满时会丢弃新日志（可通过统计监控）\n", .{});
}
