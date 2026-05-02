/// 测试 "both" 输出模式
const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n🧪 测试 both 输出模式\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // 从配置文件初始化
    var logger = try zzig.AsyncLogger.AsyncLogger.initFromConfigFile(
        allocator,
        "logger_config.json",
    );
    defer logger.deinit();

    std.debug.print("⏳ 写入几条测试日志...\n\n", .{});

    // 写入几条日志查看控制台是否也有输出
    logger.debug("测试消息 #{d} - 调试级别", .{1});
    logger.info("测试消息 #{d} - 信息级别", .{2});
    logger.warn("测试消息 #{d} - 警告级别", .{3});
    logger.err("测试消息 #{d} - 错误级别", .{4});

    // 等待处理完成
    compat.sleep(1 * std.time.ns_per_s);

    std.debug.print("\n✅ 测试完成!\n", .{});
    std.debug.print("📁 请检查 logs/app.log 文件\n", .{});
    std.debug.print("🖥️ 上面应该也显示了彩色日志输出\n", .{});
}
