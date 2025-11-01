const std = @import("std");
const zzig = @import("zzig");

pub fn main() void {
    // 设置全局日志级别（可选，默认为 debug）
    zzig.Logger.setLevel(.info);

    // 使用不同级别的日志
    zzig.Logger.debug("这是一条调试信息（因为级别设置为 info，此条不会显示）", .{});
    zzig.Logger.info("应用程序启动成功", .{});
    zzig.Logger.warn("配置文件未找到，使用默认配置", .{});
    zzig.Logger.err("数据库连接失败: {s}", .{"connection timeout"});

    // 强制输出日志（忽略全局级别设置）
    zzig.Logger.always("这是关键日志，总是会显示", .{});

    // 简单打印（不带时间戳和级别）
    zzig.Logger.print("纯文本输出，支持中文\n", .{});

    // 带格式化参数的日志
    const user = "张三";
    const count: u32 = 42;
    zzig.Logger.info("用户 {s} 执行了 {d} 次操作", .{ user, count });
}
