// ============================================================================
// 异步日志配置文件示例
// ============================================================================
// 演示如何使用配置文件来管理异步日志参数
//
// 运行: zig build config-demo -Doptimize=ReleaseFast
//
// 功能:
//   1. 自动检测配置文件是否存在
//   2. 不存在则自动生成默认配置
//   3. 从配置文件加载参数初始化日志器
//   4. 支持运行时调整队列大小、日志级别等
// ============================================================================

const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("🚀 异步日志配置文件示例\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // ========================================================================
    // 方式 1: 使用配置文件初始化 (推荐生产环境使用)
    // ========================================================================
    std.debug.print("📌 方式 1: 从配置文件加载\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});

    const config_path = "logger_config.json";

    // initFromConfigFile 会自动:
    // 1. 检查配置文件是否存在
    // 2. 不存在则生成默认配置
    // 3. 加载配置并打印参数
    // 4. 使用配置初始化日志器
    var logger = try zzig.AsyncLogger.AsyncLogger.initFromConfigFile(allocator, config_path);
    defer logger.deinit();

    std.debug.print("\n✅ 日志器已就绪,开始测试...\n\n", .{});

    // ========================================================================
    // 测试: 发送不同级别的日志
    // ========================================================================
    logger.debug("这是 DEBUG 级别日志 - 调试信息", .{});
    logger.info("这是 INFO 级别日志 - 普通信息", .{});
    logger.warn("这是 WARN 级别日志 - 警告信息", .{});
    logger.err("这是 ERROR 级别日志 - 错误信息", .{});

    // 模拟业务操作
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        logger.info("处理任务 {d}/100", .{i + 1});

        if (i % 10 == 0) {
            logger.debug("检查点: 已完成 {d}%", .{i});
        }

        if (i == 42) {
            logger.warn("检测到特殊情况: i == 42", .{});
        }
    }

    // 等待日志全部输出
    compat.sleep(100_000_000); // 100ms

    // ========================================================================
    // 打印统计信息
    // ========================================================================
    const stats = logger.getStats();
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("📊 运行统计:\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("  已处理: {d} 条\n", .{stats.processed_count});
    std.debug.print("  已丢弃: {d} 条\n", .{stats.dropped_count});
    std.debug.print("  队列剩余: {d} 条\n", .{stats.queue_size});

    if (stats.processed_count > 0) {
        const drop_rate = @as(f64, @floatFromInt(stats.dropped_count)) /
            @as(f64, @floatFromInt(stats.processed_count + stats.dropped_count)) * 100.0;
        std.debug.print("  丢弃率: {d:.4}%\n", .{drop_rate});

        if (drop_rate > 10.0) {
            std.debug.print("\n⚠️  丢弃率较高,建议:\n", .{});
            std.debug.print("   1. 增大配置文件中的 queue_capacity (当前可能不足)\n", .{});
            std.debug.print("   2. 提高 min_level 过滤低级别日志 (减少日志量)\n", .{});
            std.debug.print("   3. 批量发送日志并添加延迟 (避免突发)\n", .{});
        }
    }

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("✅ 示例完成!\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // ========================================================================
    // 配置文件说明
    // ========================================================================
    std.debug.print("💡 配置文件位置: {s}\n", .{config_path});
    std.debug.print("💡 修改配置后重新运行本程序即可生效\n", .{});
    std.debug.print("💡 关键参数:\n", .{});
    std.debug.print("   - queue_capacity: 队列大小 (建议 8192/16384/32768)\n", .{});
    std.debug.print("   - min_level: 最低级别 (debug/info/warn/err)\n", .{});
    std.debug.print("   - output_target: 输出目标 (console/file/both)\n", .{});
    std.debug.print("   - batch_size: 批处理量 (建议 50-200)\n", .{});
    std.debug.print("\n", .{});
}
