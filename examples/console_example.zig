const std = @import("std");
const zzig = @import("zzig");

/// Console 使用示例
///
/// 功能演示:
/// 1. 控制台初始化（UTF-8 + ANSI 颜色）
/// 2. 中文字符显示
/// 3. ANSI 颜色输出
/// 4. 文本样式（粗体、斜体、下划线等）
/// 5. 跨平台兼容性
pub fn main() !void {
    // ========================================
    // 方式 1: 快速初始化（推荐）
    // ========================================
    zzig.Console.setup();
    std.debug.print("✅ 控制台已初始化（快速模式）\n\n", .{});

    // ========================================
    // 方式 2: 完整初始化（带结果检查）
    // ========================================
    const result = zzig.Console.init(.{
        .utf8 = true,
        .ansi_colors = true,
        .virtual_terminal = true,
    });
    defer zzig.Console.deinit(result);

    std.debug.print("📊 初始化结果:\n", .{});
    std.debug.print("  - UTF-8 编码: {s}\n", .{if (result.utf8_enabled) "✅ 已启用" else "❌ 失败"});
    std.debug.print("  - ANSI 颜色: {s}\n", .{if (result.ansi_enabled) "✅ 已启用" else "❌ 失败"});

    if (result.original_mode) |mode| {
        std.debug.print("  - 原始模式: 0x{X:0>8} (已保存)\n\n", .{mode});
    } else {
        std.debug.print("  - 原始模式: 无需保存\n\n", .{});
    }

    // ========================================
    // 1. 中文字符显示测试
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("1️⃣  中文字符显示测试\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("你好，世界！\n", .{});
    std.debug.print("沛柯智能 PeiKeSmart\n", .{});
    std.debug.print("Zig 0.15.2 跨平台支持\n", .{});
    std.debug.print("各种符号：✅ ❌ 🚀 ⚡ 📊 🔧\n\n", .{});

    // ========================================
    // 2. ANSI 颜色测试
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("2️⃣  ANSI 颜色测试\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const Color = zzig.Console.Color.Code;

    // 基础颜色
    std.debug.print("{s}黑色文本{s}\n", .{ Color.black.fg(), Color.reset.fg() });
    std.debug.print("{s}红色文本{s}\n", .{ Color.red.fg(), Color.reset.fg() });
    std.debug.print("{s}绿色文本{s}\n", .{ Color.green.fg(), Color.reset.fg() });
    std.debug.print("{s}黄色文本{s}\n", .{ Color.yellow.fg(), Color.reset.fg() });
    std.debug.print("{s}蓝色文本{s}\n", .{ Color.blue.fg(), Color.reset.fg() });
    std.debug.print("{s}品红文本{s}\n", .{ Color.magenta.fg(), Color.reset.fg() });
    std.debug.print("{s}青色文本{s}\n", .{ Color.cyan.fg(), Color.reset.fg() });
    std.debug.print("{s}白色文本{s}\n\n", .{ Color.white.fg(), Color.reset.fg() });

    // 高亮颜色
    std.debug.print("{s}高亮红色{s}\n", .{ Color.bright_red.fg(), Color.reset.fg() });
    std.debug.print("{s}高亮绿色{s}\n", .{ Color.bright_green.fg(), Color.reset.fg() });
    std.debug.print("{s}高亮黄色{s}\n", .{ Color.bright_yellow.fg(), Color.reset.fg() });
    std.debug.print("{s}高亮蓝色{s}\n", .{ Color.bright_blue.fg(), Color.reset.fg() });
    std.debug.print("{s}高亮品红{s}\n", .{ Color.bright_magenta.fg(), Color.reset.fg() });
    std.debug.print("{s}高亮青色{s}\n", .{ Color.bright_cyan.fg(), Color.reset.fg() });
    std.debug.print("{s}高亮白色{s}\n\n", .{ Color.bright_white.fg(), Color.reset.fg() });

    // ========================================
    // 3. 背景色测试
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("3️⃣  背景色测试\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("{s} 红色背景 {s}\n", .{ Color.red.bg(), Color.reset.fg() });
    std.debug.print("{s} 绿色背景 {s}\n", .{ Color.green.bg(), Color.reset.fg() });
    std.debug.print("{s} 蓝色背景 {s}\n", .{ Color.blue.bg(), Color.reset.fg() });
    std.debug.print("{s}{s} 黄底蓝字 {s}\n", .{ Color.yellow.bg(), Color.blue.fg(), Color.reset.fg() });
    std.debug.print("{s}{s} 青底红字 {s}\n\n", .{ Color.cyan.bg(), Color.red.fg(), Color.reset.fg() });

    // ========================================
    // 4. 文本样式测试
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("4️⃣  文本样式测试\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const Style = zzig.Console.Color.Style;
    std.debug.print("{s}粗体文本{s}\n", .{ Style.bold.code(), Color.reset.fg() });
    std.debug.print("{s}暗淡文本{s}\n", .{ Style.dim.code(), Color.reset.fg() });
    std.debug.print("{s}斜体文本{s}\n", .{ Style.italic.code(), Color.reset.fg() });
    std.debug.print("{s}下划线文本{s}\n", .{ Style.underline.code(), Color.reset.fg() });
    std.debug.print("{s}闪烁文本{s}\n", .{ Style.blink.code(), Color.reset.fg() });
    std.debug.print("{s}反转文本{s}\n", .{ Style.reverse.code(), Color.reset.fg() });
    std.debug.print("{s}删除线文本{s}\n\n", .{ Style.strikethrough.code(), Color.reset.fg() });

    // ========================================
    // 5. 组合样式测试
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("5️⃣  组合样式测试\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("{s}{s}粗体绿色文本{s}\n", .{ Style.bold.code(), Color.green.fg(), Color.reset.fg() });
    std.debug.print("{s}{s}粗体红色文本{s}\n", .{ Style.bold.code(), Color.red.fg(), Color.reset.fg() });
    std.debug.print("{s}{s}下划线蓝色文本{s}\n", .{ Style.underline.code(), Color.blue.fg(), Color.reset.fg() });
    std.debug.print("{s}{s}{s}粗体+斜体+品红{s}\n", .{ Style.bold.code(), Style.italic.code(), Color.magenta.fg(), Color.reset.fg() });
    std.debug.print("{s}{s}{s}黄底+黑字+粗体{s}\n\n", .{ Color.yellow.bg(), Color.black.fg(), Style.bold.code(), Color.reset.fg() });

    // ========================================
    // 6. 实际应用场景
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("6️⃣  实际应用场景\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    // 日志级别示例
    std.debug.print("{s}[INFO]{s}  服务器启动成功\n", .{ Color.green.fg(), Color.reset.fg() });
    std.debug.print("{s}[WARN]{s}  内存使用率 85%\n", .{ Color.yellow.fg(), Color.reset.fg() });
    std.debug.print("{s}[ERROR]{s} 数据库连接失败\n", .{ Color.red.fg(), Color.reset.fg() });
    std.debug.print("{s}[DEBUG]{s} 请求耗时: 23ms\n\n", .{ Color.cyan.fg(), Color.reset.fg() });

    // 进度条示例
    std.debug.print("下载进度: ", .{});
    std.debug.print("{s}████████████{s}", .{ Color.green.bg(), Color.reset.fg() });
    std.debug.print("░░░░░░░░ 60%\n\n", .{});

    // 表格示例
    std.debug.print("┌─────────────┬──────────┬────────┐\n", .{});
    std.debug.print("│ {s}服务名称{s}    │ {s}状态{s}     │ {s}CPU%{s}  │\n", .{ Style.bold.code(), Color.reset.fg(), Style.bold.code(), Color.reset.fg(), Style.bold.code(), Color.reset.fg() });
    std.debug.print("├─────────────┼──────────┼────────┤\n", .{});
    std.debug.print("│ web-server  │ {s}运行中{s}   │ 45.2%  │\n", .{ Color.green.fg(), Color.reset.fg() });
    std.debug.print("│ db-master   │ {s}运行中{s}   │ 78.9%  │\n", .{ Color.green.fg(), Color.reset.fg() });
    std.debug.print("│ cache-node  │ {s}已停止{s}   │  0.0%  │\n", .{ Color.red.fg(), Color.reset.fg() });
    std.debug.print("└─────────────┴──────────┴────────┘\n\n", .{});

    // ========================================
    // 7. 兼容性检测
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("7️⃣  兼容性检测\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    const supports_ansi = zzig.Console.supportsAnsiColors();
    std.debug.print("ANSI 颜色支持: {s}\n", .{if (supports_ansi) "✅ 是" else "❌ 否"});

    const builtin = @import("builtin");
    std.debug.print("操作系统: {s}\n", .{@tagName(builtin.os.tag)});
    std.debug.print("CPU 架构: {s}\n\n", .{@tagName(builtin.cpu.arch)});

    // ========================================
    // 总结
    // ========================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("{s}{s}✅ 所有测试完成！{s}\n", .{ Style.bold.code(), Color.green.fg(), Color.reset.fg() });
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
}
