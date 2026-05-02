/// 日志轮转压力测试
/// 用于测试文件大小达到阈值时的自动轮转功能
const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;
const AsyncLogger = zzig.AsyncLogger;
const LogLevel = AsyncLogger.LogLevel;

pub fn main() !void {
    // 使用通用分配器
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 从配置文件初始化
    var logger = try zzig.AsyncLogger.AsyncLogger.initFromConfigFile(allocator, "logger_config.json");
    defer logger.deinit();

    std.debug.print("🚀 开始日志轮转测试...\n", .{});
    std.debug.print("📋 配置:\n", .{});
    std.debug.print("  最大文件: {d} MB\n", .{logger.max_file_size / (1024 * 1024)});
    std.debug.print("  保留备份: {d}\n", .{logger.max_backup_files});
    std.debug.print("\n", .{});

    // 生成大量日志以触发轮转（每条约60-80字节）
    const total_batches = 100; // 100批
    const batch_size = 500; // 每批500条
    const total_logs = total_batches * batch_size; // 总计50000条

    std.debug.print("📊 计划写入 {d} 条日志 ({d}批 × {d}条)\n", .{ total_logs, total_batches, batch_size });
    std.debug.print("⏳ 预计生成约 {d} MB 数据\n", .{(total_logs * 70) / (1024 * 1024)});
    std.debug.print("\n", .{});

    var batch_num: usize = 0;
    while (batch_num < total_batches) : (batch_num += 1) {
        var i: usize = 0;
        while (i < batch_size) : (i += 1) {
            const msg_num = batch_num * batch_size + i;

            // 使用不同日志级别
            switch (msg_num % 5) {
                0 => logger.debug("轮转测试日志 #{d} - 这是一条调试消息用于测试文件轮转功能", .{msg_num}),
                1 => logger.info("轮转测试日志 #{d} - 这是一条信息消息用于测试文件轮转功能", .{msg_num}),
                2 => logger.warn("轮转测试日志 #{d} - 这是一条警告消息用于测试文件轮转功能", .{msg_num}),
                3 => logger.err("轮转测试日志 #{d} - 这是一条错误消息用于测试文件轮转功能", .{msg_num}),
                else => logger.info("轮转测试日志 #{d} - 混合内容测试: ID={d}, 用户=测试用户{d}", .{ msg_num, msg_num * 123, msg_num % 100 }),
            }
        }

        // 每10批打印一次进度
        if ((batch_num + 1) % 10 == 0) {
            const progress = (batch_num + 1) * batch_size;
            std.debug.print("✅ 已写入 {d}/{d} 条日志 ({d}%)...\n", .{ progress, total_logs, (progress * 100) / total_logs });
        }

        // 给工作线程一些处理时间
        if (batch_num % 20 == 0) {
            compat.sleep(100 * std.time.ns_per_ms); // 100ms
        }
    }

    // 等待处理完成
    std.debug.print("\n⏳ 等待日志处理完成...\n", .{});
    compat.sleep(3 * std.time.ns_per_s); // 等待3秒

    // 打印统计信息
    std.debug.print("\n📈 最终统计信息:\n", .{});
    const stats = logger.getStats();
    std.debug.print("  已处理: {d}\n", .{stats.processed_count});
    std.debug.print("  已丢弃: {d}\n", .{stats.dropped_count});
    std.debug.print("  丢弃率: {d:.2}%\n", .{stats.drop_rate});
    std.debug.print("  队列剩余: {d}\n", .{stats.queue_size});

    std.debug.print("\n🔍 检查生成的日志文件:\n", .{});
    std.debug.print("  主文件: logs/app.log\n", .{});
    std.debug.print("  备份文件: logs/app.log.1, logs/app.log.2, logs/app.log.3\n", .{});
    std.debug.print("\n✅ 轮转测试完成!\n", .{});
}
