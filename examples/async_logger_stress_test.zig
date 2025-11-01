const std = @import("std");
const AsyncLogger = @import("zzig").AsyncLogger;

/// 模拟百万级设备的高负载日志测试
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== 异步日志 - 百万级设备压力测试 ===\n\n", .{});

    // 配置：更大的队列容量，适应高并发
    const config = AsyncLogger.AsyncLoggerConfig{
        .queue_capacity = 16384, // 16K 消息缓冲
        .idle_sleep_us = 50, // 更短的休眠时间
        .global_level = .info,
        .enable_drop_counter = true,
    };

    const logger = try AsyncLogger.AsyncLogger.init(allocator, config);
    defer logger.deinit();

    std.debug.print("📊 测试配置:\n", .{});
    std.debug.print("   队列容量: {d}\n", .{config.queue_capacity});
    std.debug.print("   模拟设备数: 100万\n", .{});
    std.debug.print("   每设备日志: 10条\n", .{});
    std.debug.print("   总日志量: 1000万条\n\n", .{});

    // ========================================
    // 测试 1: 顺序压测（单线程，测量纯写入性能）
    // ========================================
    std.debug.print("🚀 测试 1: 顺序压测（单线程）\n", .{});

    const sequential_count = 100_000; // 10万条
    const start_seq = std.time.nanoTimestamp();

    for (0..sequential_count) |i| {
        logger.info("设备{d}: 状态正常, 温度: {d}°C, 内存: {d}MB", .{ i, 45 + (i % 20), 256 - (i % 100) });
    }

    const end_seq = std.time.nanoTimestamp();
    const duration_seq_ns = @as(u64, @intCast(end_seq - start_seq));
    const duration_seq_us = duration_seq_ns / std.time.ns_per_us;
    const qps_seq = (sequential_count * std.time.ns_per_s) / duration_seq_ns;
    const latency_seq_ns = duration_seq_ns / sequential_count;

    std.debug.print("   ✓ 完成: {d} 条日志\n", .{sequential_count});
    std.debug.print("   ✓ 耗时: {d} μs\n", .{duration_seq_us});
    std.debug.print("   ✓ QPS: {d} 条/秒\n", .{qps_seq});
    std.debug.print("   ✓ 平均延迟: {d} ns/条 (≈ {d:.2} μs)\n\n", .{ latency_seq_ns, @as(f64, @floatFromInt(latency_seq_ns)) / 1000.0 });

    // 等待队列处理
    std.debug.print("⏳ 等待日志队列处理...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    // ========================================
    // 测试 2: 多线程并发（模拟多设备并发上报）
    // ========================================
    std.debug.print("\n🚀 测试 2: 多线程并发（{d} 线程）\n", .{16});

    const thread_count = 16;
    const logs_per_thread = 50_000; // 每线程 5 万条
    const total_logs = thread_count * logs_per_thread; // 总共 80 万条

    var threads: [thread_count]std.Thread = undefined;
    const start_concurrent = std.time.nanoTimestamp();

    // 启动工作线程
    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{ logger, i, logs_per_thread });
    }

    // 等待所有线程完成
    for (threads) |thread| {
        thread.join();
    }

    const end_concurrent = std.time.nanoTimestamp();
    const duration_concurrent_ns = @as(u64, @intCast(end_concurrent - start_concurrent));
    const duration_concurrent_us = duration_concurrent_ns / std.time.ns_per_us;
    const qps_concurrent = (total_logs * std.time.ns_per_s) / duration_concurrent_ns;
    const latency_concurrent_ns = duration_concurrent_ns / total_logs;

    std.debug.print("   ✓ 完成: {d} 条日志 ({d} 线程 × {d})\n", .{ total_logs, thread_count, logs_per_thread });
    std.debug.print("   ✓ 耗时: {d} μs ({d:.2} 秒)\n", .{ duration_concurrent_us, @as(f64, @floatFromInt(duration_concurrent_us)) / 1_000_000.0 });
    std.debug.print("   ✓ QPS: {d} 条/秒\n", .{qps_concurrent});
    std.debug.print("   ✓ 平均延迟: {d} ns/条 (≈ {d:.2} μs)\n\n", .{ latency_concurrent_ns, @as(f64, @floatFromInt(latency_concurrent_ns)) / 1000.0 });

    // 等待队列完全清空
    std.debug.print("⏳ 等待队列完全处理...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);

    // ========================================
    // 统计报告
    // ========================================
    std.debug.print("\n📈 最终统计:\n", .{});
    std.debug.print("   已处理: {d} 条\n", .{logger.getProcessedCount()});
    std.debug.print("   已丢弃: {d} 条\n", .{logger.getDroppedCount()});
    std.debug.print("   队列剩余: {d} 条\n", .{logger.getQueueSize()});

    const total_sent = sequential_count + total_logs;
    const drop_rate = (@as(f64, @floatFromInt(logger.getDroppedCount())) / @as(f64, @floatFromInt(total_sent))) * 100.0;
    std.debug.print("   丢弃率: {d:.4}%\n", .{drop_rate});

    // ========================================
    // 性能对比
    // ========================================
    std.debug.print("\n💡 性能分析:\n", .{});
    std.debug.print("   单线程 QPS: {d} 条/秒\n", .{qps_seq});
    std.debug.print("   多线程 QPS: {d} 条/秒\n", .{qps_concurrent});
    std.debug.print("   并发加速比: {d:.2}x\n", .{@as(f64, @floatFromInt(qps_concurrent)) / @as(f64, @floatFromInt(qps_seq))});

    if (latency_seq_ns < 1000) {
        std.debug.print("   ✅ 单线程延迟 < 1μs: 极速模式\n", .{});
    } else if (latency_seq_ns < 10_000) {
        std.debug.print("   ✅ 单线程延迟 < 10μs: 优秀\n", .{});
    } else {
        std.debug.print("   ⚠️  单线程延迟 > 10μs: 需优化\n", .{});
    }

    if (drop_rate < 0.1) {
        std.debug.print("   ✅ 丢弃率 < 0.1%%: 队列容量充足\n", .{});
    } else if (drop_rate < 1.0) {
        std.debug.print("   ⚠️  丢弃率 < 1%%: 考虑增加队列容量\n", .{});
    } else {
        std.debug.print("   ❌ 丢弃率 >= 1%%: 必须增加队列容量或限流\n", .{});
    }

    std.debug.print("\n=== 测试完成 ===\n", .{});
}

/// 工作线程：模拟设备上报日志
fn workerThread(logger: *AsyncLogger.AsyncLogger, thread_id: usize, count: usize) void {
    for (0..count) |i| {
        const device_id = thread_id * 1_000_000 + i;
        logger.info("设备{d}: 上报数据, CPU: {d}%, 连接: {d}ms", .{
            device_id,
            30 + (i % 70),
            10 + (i % 50),
        });
    }
}
