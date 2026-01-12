const std = @import("std");
const zzig = @import("zzig");
const menu = zzig.Menu;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Menu 模块示例程序 ===\n\n", .{});

    // 示例1: 简单的读取输入
    std.debug.print("【示例1】简单输入\n", .{});
    const name = try menu.readString(allocator, "请输入你的名字: ", "张三");
    defer allocator.free(name);
    std.debug.print("你好, {s}!\n\n", .{name});

    // 示例2: 读取整数
    std.debug.print("【示例2】整数输入\n", .{});
    const age = try menu.readInt(u8, allocator, "请输入年龄: ", 25);
    std.debug.print("年龄: {d} 岁\n\n", .{age});

    // 示例3: 菜单选择
    std.debug.print("【示例3】菜单选择\n", .{});
    const action_items = [_]menu.MenuItem{
        .{ .key = "1", .label = "查看信息", .description = "显示系统信息" },
        .{ .key = "2", .label = "编辑配置", .description = "修改配置文件" },
        .{ .key = "3", .label = "运行测试", .description = "执行单元测试" },
        .{ .key = "q", .label = "退出程序" },
    };

    const choice = try menu.showMenu(allocator, .{
        .title = "\n请选择操作:",
        .prompt = "输入序号: ",
        .default_key = "1",
    }, &action_items) orelse {
        std.debug.print("未选择任何选项\n", .{});
        return;
    };
    defer allocator.free(choice);

    // 查找选中的菜单项
    if (menu.findMenuItem(&action_items, choice)) |selected| {
        std.debug.print("\n你选择了: {s}\n", .{selected.label});
        if (selected.description) |desc| {
            std.debug.print("说明: {s}\n", .{desc});
        }
    }

    // 示例4: 确认操作
    std.debug.print("\n【示例4】确认提示\n", .{});
    if (try menu.confirm(allocator, "是否继续执行?")) {
        std.debug.print("✓ 已确认，继续执行\n", .{});

        // 示例5: 更详细的布尔值输入
        const save_config = try menu.readBool(allocator, "是否保存配置?", true);
        if (save_config) {
            std.debug.print("✓ 配置将被保存\n", .{});
        } else {
            std.debug.print("✗ 配置不会被保存\n", .{});
        }
    } else {
        std.debug.print("✗ 操作已取消\n", .{});
    }

    // 示例6: 多级菜单
    std.debug.print("\n【示例6】配置菜单\n", .{});
    const config_items = [_]menu.MenuItem{
        .{ .key = "1", .label = "语言设置", .description = "更改界面语言" },
        .{ .key = "2", .label = "主题设置", .description = "选择界面主题" },
        .{ .key = "3", .label = "网络设置", .description = "配置网络参数" },
        .{ .key = "b", .label = "返回" },
    };

    const config_choice = try menu.showMenu(allocator, .{
        .title = "\n配置菜单:",
        .prompt = "选择配置项: ",
    }, &config_items);

    if (config_choice) |cfg| {
        defer allocator.free(cfg);
        if (std.mem.eql(u8, cfg, "1")) {
            // 语言设置子菜单
            const lang_items = [_]menu.MenuItem{
                .{ .key = "1", .label = "简体中文" },
                .{ .key = "2", .label = "English" },
                .{ .key = "3", .label = "日本語" },
            };

            const lang = try menu.showMenu(allocator, .{
                .title = "\n选择语言:",
                .prompt = "语言: ",
                .default_key = "1",
            }, &lang_items);

            if (lang) |l| {
                defer allocator.free(l);
                if (menu.findMenuItem(&lang_items, l)) |selected_lang| {
                    std.debug.print("已设置语言: {s}\n", .{selected_lang.label});
                }
            }
        } else if (std.mem.eql(u8, cfg, "3")) {
            // 网络设置
            std.debug.print("\n网络配置:\n", .{});
            const host = try menu.readString(allocator, "主机地址: ", "127.0.0.1");
            defer allocator.free(host);

            const port = try menu.readInt(u16, allocator, "端口号: ", 8080);

            const use_ssl = try menu.readBool(allocator, "启用 SSL?", false);

            std.debug.print("\n配置摘要:\n", .{});
            std.debug.print("  主机: {s}\n", .{host});
            std.debug.print("  端口: {d}\n", .{port});
            std.debug.print("  SSL: {}\n", .{use_ssl});
        }
    }

    std.debug.print("\n程序结束\n", .{});
}
