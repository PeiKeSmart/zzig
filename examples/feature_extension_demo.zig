const std = @import("std");
const zzig = @import("zzig");
const MPMCQueue = zzig.MPMCQueue;
const StructuredLog = zzig.StructuredLog;

/// 演示 MPMC 队列和结构化日志
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== 🚀 功能扩展演示 ===\n\n", .{});

    // ========== Part 1: MPMC 队列 ==========
    std.debug.print("📦 Part 1: MPMC 无锁队列测试\n", .{});
    try testMPMCQueue(allocator);

    std.debug.print("\n", .{});

    // ========== Part 2: 结构化日志 ==========
    std.debug.print("📝 Part 2: 结构化日志（JSON 格式）\n", .{});
    try testStructuredLog(allocator);

    std.debug.print("\n✅ 所有演示完成！\n", .{});
}

/// 测试 MPMC 队列
fn testMPMCQueue(allocator: std.mem.Allocator) !void {
    var queue = try MPMCQueue(u32).init(allocator, 1024);
    defer queue.deinit(allocator);

    // 启动多个生产者和消费者
    const producer_count = 4;
    const consumer_count = 2;
    const items_per_producer = 250; // 总共 1000 个消息

    var producers: [producer_count]std.Thread = undefined;
    var consumers: [consumer_count]std.Thread = undefined;
    var consumed_total = std.atomic.Value(usize).init(0);

    const ProducerCtx = struct {
        queue: *MPMCQueue(u32),
        id: usize,
        count: usize,
    };

    const ConsumerCtx = struct {
        queue: *MPMCQueue(u32),
        id: usize,
        total: *std.atomic.Value(usize),
        target: usize,
    };

    // 生产者函数
    const producerFn = struct {
        fn run(ctx: ProducerCtx) void {
            for (0..ctx.count) |i| {
                const value: u32 = @intCast(ctx.id * 1000 + i);
                while (!ctx.queue.tryPush(value)) {
                    std.Thread.yield() catch {};
                }
            }
            std.debug.print("  生产者 {} 完成 ({} 条消息)\n", .{ ctx.id, ctx.count });
        }
    }.run;

    // 消费者函数
    const consumerFn = struct {
        fn run(ctx: ConsumerCtx) void {
            var local_count: usize = 0;
            while (ctx.total.load(.monotonic) < ctx.target) {
                if (ctx.queue.tryPop()) |_| {
                    local_count += 1;
                    _ = ctx.total.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {};
                }
            }
            std.debug.print("  消费者 {} 完成 ({} 条消息)\n", .{ ctx.id, local_count });
        }
    }.run;

    const start_time = std.time.milliTimestamp();

    // 启动生产者
    for (&producers, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, producerFn, .{ProducerCtx{
            .queue = &queue,
            .id = i,
            .count = items_per_producer,
        }});
    }

    // 启动消费者
    for (&consumers, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, consumerFn, .{ConsumerCtx{
            .queue = &queue,
            .id = i,
            .total = &consumed_total,
            .target = producer_count * items_per_producer,
        }});
    }

    // 等待所有线程完成
    for (producers) |thread| thread.join();
    for (consumers) |thread| thread.join();

    const duration = std.time.milliTimestamp() - start_time;

    std.debug.print("\n  ✅ MPMC 队列测试通过:\n", .{});
    std.debug.print("     - 生产者数量: {}\n", .{producer_count});
    std.debug.print("     - 消费者数量: {}\n", .{consumer_count});
    std.debug.print("     - 总消息数: {}\n", .{producer_count * items_per_producer});
    std.debug.print("     - 已消费: {}\n", .{consumed_total.load(.monotonic)});
    std.debug.print("     - 耗时: {} ms\n", .{duration});
}

/// 测试结构化日志
fn testStructuredLog(allocator: std.mem.Allocator) !void {
    // ========== 动态分配版本 ==========
    std.debug.print("\n  📊 动态分配版本:\n", .{});

    var log1 = StructuredLog.StructuredLog.init(allocator, .info);
    defer log1.deinit();

    log1.setMessage("用户登录成功");
    try log1.addString("user", "alice");
    try log1.addString("ip", "192.168.1.100");
    try log1.addInt("user_id", 12345);
    try log1.addBool("is_admin", true);
    try log1.addFloat("session_duration", 3.14);

    const json1 = try log1.build();
    defer allocator.free(json1);

    std.debug.print("     {s}\n", .{json1});

    // ========== 错误日志 ==========
    var log2 = StructuredLog.StructuredLog.init(allocator, .@"error");
    defer log2.deinit();

    log2.setMessage("数据库连接失败");
    try log2.addString("db_host", "localhost");
    try log2.addInt("port", 5432);
    try log2.addString("error", "connection refused");
    try log2.addNull("retry_count");

    const json2 = try log2.build();
    defer allocator.free(json2);

    std.debug.print("     {s}\n", .{json2});

    // ========== 零分配版本 ==========
    std.debug.print("\n  📊 零分配版本:\n", .{});

    var log3 = StructuredLog.StructuredLogZeroAlloc.init(.warn);
    log3.setMessage("内存使用率过高");
    try log3.addString("module", "allocator");
    try log3.addInt("used_mb", 512);
    try log3.addInt("total_mb", 1024);

    var buffer: [2048]u8 = undefined;
    const json3 = try log3.buildToBuffer(&buffer);

    std.debug.print("     {s}\n", .{json3});

    std.debug.print("\n  ✅ 结构化日志测试通过\n", .{});
}
