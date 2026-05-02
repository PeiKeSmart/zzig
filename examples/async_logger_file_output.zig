const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n🚀 异步日志文件输出测试\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // 从配置文件初始化 (不存在则自动生成)
    var logger = try zzig.AsyncLogger.AsyncLogger.initFromConfigFile(
        allocator,
        "logger_config.json",
    );
    defer logger.deinit();

    std.debug.print("⏳ 开始写入日志...\n\n", .{});

    // 测试不同级别的日志
    logger.debug("这是一条调试日志 - Debug Log", .{});
    logger.info("应用启动成功 - Application started", .{});
    logger.warn("警告: 磁盘空间不足 - Warning: Low disk space", .{});
    logger.err("错误: 数据库连接失败 - Error: Database connection failed", .{});

    // 测试格式化输出
    const user_id = 12345;
    const username = "张三";
    logger.info("用户登录: ID={d}, 用户名={s}", .{ user_id, username });

    // 批量写入测试
    std.debug.print("📊 批量写入 1000 条日志...\n", .{});
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        logger.info("批量日志 #{d} - Batch log entry", .{i});
    }

    // 等待所有日志处理完毕
    compat.sleep(2 * std.time.ns_per_s);

    // 获取统计信息
    const stats = logger.getStats();
    std.debug.print("\n📈 统计信息:\n", .{});
    std.debug.print("  已处理: {d}\n", .{stats.processed_count});
    std.debug.print("  已丢弃: {d}\n", .{stats.dropped_count});
    std.debug.print("  丢弃率: {d:.2}%\n", .{stats.drop_rate});
    std.debug.print("  队列剩余: {d}\n", .{stats.queue_size});

    std.debug.print("\n✅ 测试完成!\n", .{});
    std.debug.print("📁 请检查 'logs/app.log' 文件查看输出结果\n", .{});
    std.debug.print("\n💡 提示: 修改 logger_config.json 中的:\n", .{});
    std.debug.print("   - output_target: \"console\" (控制台)\n", .{});
    std.debug.print("   - output_target: \"file\" (仅文件)\n", .{});
    std.debug.print("   - output_target: \"both\" (两者都输出)\n", .{});
    std.debug.print("   - max_file_size: 1048576 (1MB, 测试日志轮转)\n\n", .{});
}
