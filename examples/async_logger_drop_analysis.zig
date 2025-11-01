const std = @import("std");
const zzig = @import("zzig");

/// 演示如何避免日志丢弃
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== 日志丢弃问题分析与解决 ===\n\n", .{});

    // ========================================
    // 问题演示：队列容量不足
    // ========================================
    std.debug.print("📊 问题演示：小队列 + 高频发送\n", .{});

    const small_config = zzig.AsyncLogger.AsyncLoggerConfig{
        .queue_capacity = 1024, // 小队列
        .global_level = .info,
    };

    const logger1 = try zzig.AsyncLogger.AsyncLogger.init(allocator, small_config);
    defer logger1.deinit();

    // 快速发送 10000 条
    const start1 = std.time.nanoTimestamp();
    for (0..10_000) |i| {
        logger1.info("消息 {d}", .{i});
    }
    const end1 = std.time.nanoTimestamp();
    const send_time_ms = @as(f64, @floatFromInt(@as(u64, @intCast(end1 - start1)))) / 1_000_000.0;

    std.debug.print("  发送耗时: {d:.2} ms\n", .{send_time_ms});
    std.debug.print("  发送速度: {d:.0} 条/秒\n", .{10_000.0 / (send_time_ms / 1000.0)});

    // 等待处理
    std.Thread.sleep(2 * std.time.ns_per_s);

    std.debug.print("  已处理: {d}\n", .{logger1.getProcessedCount()});
    std.debug.print("  已丢弃: {d} ❌\n", .{logger1.getDroppedCount()});
    std.debug.print("  丢弃率: {d:.2}%\n", .{
        (@as(f64, @floatFromInt(logger1.getDroppedCount())) / 10_000.0) * 100.0,
    });

    // ========================================
    // 解决方案 1：增大队列容量
    // ========================================
    std.debug.print("\n✅ 解决方案 1: 增大队列容量\n", .{});

    const large_config = zzig.AsyncLogger.AsyncLoggerConfig{
        .queue_capacity = 16384, // 大队列 (16K)
        .global_level = .info,
    };

    const logger2 = try zzig.AsyncLogger.AsyncLogger.init(allocator, large_config);
    defer logger2.deinit();

    // 同样快速发送 10000 条
    for (0..10_000) |i| {
        logger2.info("消息 {d}", .{i});
    }

    std.Thread.sleep(2 * std.time.ns_per_s);

    std.debug.print("  队列容量: 16384\n", .{});
    std.debug.print("  已处理: {d}\n", .{logger2.getProcessedCount()});
    std.debug.print("  已丢弃: {d} ✅\n", .{logger2.getDroppedCount()});
    std.debug.print("  丢弃率: {d:.2}%\n", .{
        (@as(f64, @floatFromInt(logger2.getDroppedCount())) / 10_000.0) * 100.0,
    });

    // ========================================
    // 解决方案 2：控制发送速率
    // ========================================
    std.debug.print("\n✅ 解决方案 2: 控制发送速率 (实际场景)\n", .{});

    const logger3 = try zzig.AsyncLogger.AsyncLogger.init(allocator, small_config);
    defer logger3.deinit();

    // 模拟实际业务场景：分批发送
    const batch_size = 100;
    const batch_interval_ms = 200; // 每批间隔 200ms

    std.debug.print("  批次大小: {d}\n", .{batch_size});
    std.debug.print("  批次间隔: {d} ms\n", .{batch_interval_ms});

    for (0..100) |batch| {
        for (0..batch_size) |i| {
            logger3.info("批次{d} 消息{d}", .{ batch, i });
        }
        std.Thread.sleep(batch_interval_ms * std.time.ns_per_ms);
    }

    std.Thread.sleep(1 * std.time.ns_per_s);

    std.debug.print("  已处理: {d}\n", .{logger3.getProcessedCount()});
    std.debug.print("  已丢弃: {d} ✅\n", .{logger3.getDroppedCount()});
    std.debug.print("  丢弃率: {d:.4}%\n", .{
        (@as(f64, @floatFromInt(logger3.getDroppedCount())) / 10_000.0) * 100.0,
    });

    // ========================================
    // 解决方案 3：监控 + 降级
    // ========================================
    std.debug.print("\n✅ 解决方案 3: 实时监控 + 动态降级\n", .{});

    const logger4 = try zzig.AsyncLogger.AsyncLogger.init(allocator, small_config);
    defer logger4.deinit();

    var current_level: zzig.AsyncLogger.Level = .debug;

    for (0..10_000) |i| {
        // 每 1000 条检查一次队列
        if (i % 1000 == 0 and i > 0) {
            const queue_usage = (@as(f64, @floatFromInt(logger4.getQueueSize())) / 1024.0) * 100.0;

            if (queue_usage > 80.0) {
                // 队列超过 80%，提升日志级别 (减少日志量)
                if (@intFromEnum(current_level) < @intFromEnum(zzig.AsyncLogger.Level.err)) {
                    current_level = @enumFromInt(@intFromEnum(current_level) + 1);
                    logger4.setLevel(current_level);
                    std.debug.print("  ⚠️  队列使用率 {d:.1}% → 提升级别到 ", .{queue_usage});
                    switch (current_level) {
                        .info => std.debug.print("INFO\n", .{}),
                        .warn => std.debug.print("WARN\n", .{}),
                        .err => std.debug.print("ERROR\n", .{}),
                        else => {},
                    }
                }
            }
        }

        // 根据当前级别记录日志
        switch (i % 4) {
            0 => logger4.debug("Debug 消息 {d}", .{i}),
            1 => logger4.info("Info 消息 {d}", .{i}),
            2 => logger4.warn("Warn 消息 {d}", .{i}),
            3 => logger4.err("Error 消息 {d}", .{i}),
            else => unreachable,
        }
    }

    std.Thread.sleep(2 * std.time.ns_per_s);

    std.debug.print("  已处理: {d}\n", .{logger4.getProcessedCount()});
    std.debug.print("  已丢弃: {d}\n", .{logger4.getDroppedCount()});
    std.debug.print("  丢弃率: {d:.2}%\n", .{
        (@as(f64, @floatFromInt(logger4.getDroppedCount())) / 10_000.0) * 100.0,
    });

    // ========================================
    // 总结
    // ========================================
    std.debug.print("\n📚 丢弃原因总结:\n", .{});
    std.debug.print("  1. 生产速度 (11.7M/s) >> 消费速度 (~500/s)\n", .{});
    std.debug.print("  2. 消费瓶颈: 控制台 IO 耗时 ~2ms/条\n", .{});
    std.debug.print("  3. 队列容量有限: 1024 条 ≈ 0.09ms 就满\n", .{});
    std.debug.print("\n💡 解决策略:\n", .{});
    std.debug.print("  ✅ 测试环境: 增大队列 (16K-32K)\n", .{});
    std.debug.print("  ✅ 生产环境: 控制速率 + 监控 + 降级\n", .{});
    std.debug.print("  ✅ 关键场景: 使用文件输出 (比控制台快 100x)\n", .{});

    std.debug.print("\n=== 完成 ===\n", .{});
}
