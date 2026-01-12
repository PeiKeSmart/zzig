const std = @import("std");
const zzig = @import("zzig");
const Menu = zzig.Menu;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Menu 动态菜单示例 ===\n\n", .{});

    // ========== 示例 1: 完全动态构建菜单 ==========
    std.debug.print("【示例1】动态构建菜单项\n", .{});

    // 在运行时动态创建菜单项列表
    var menu_items = std.ArrayList(Menu.MenuItem).empty;
    defer menu_items.deinit(allocator);

    // 动态添加菜单项
    try menu_items.append(allocator, .{
        .key = "1",
        .label = "新增用户",
        .description = "添加新用户到系统",
    });

    try menu_items.append(allocator, .{
        .key = "2",
        .label = "删除用户",
        .description = "从系统删除用户",
    });

    try menu_items.append(allocator, .{
        .key = "3",
        .label = "列出用户",
        .description = "显示所有用户列表",
    });

    // 根据条件动态添加管理员选项
    const is_admin = true; // 模拟权限检查
    if (is_admin) {
        try menu_items.append(allocator, .{
            .key = "4",
            .label = "系统设置",
            .description = "管理员专用设置",
        });
    }

    try menu_items.append(allocator, .{
        .key = "q",
        .label = "退出",
    });

    std.debug.print("已动态生成 {d} 个菜单项\n", .{menu_items.items.len});

    // 显示动态菜单
    const choice = try Menu.showMenu(allocator, .{
        .title = "\n用户管理系统",
        .prompt = "请选择操作: ",
        .default_key = "1",
    }, menu_items.items) orelse {
        std.debug.print("未选择任何选项\n", .{});
        return;
    };
    defer allocator.free(choice);

    std.debug.print("你选择了: {s}\n\n", .{choice});

    // ========== 示例 2: 根据配置文件动态加载菜单 ==========
    std.debug.print("【示例2】从配置数据动态加载\n", .{});

    // 模拟从配置文件/数据库加载的菜单定义
    const MenuDef = struct {
        id: []const u8,
        name: []const u8,
        desc: ?[]const u8,
        enabled: bool,
    };

    const config_menus = [_]MenuDef{
        .{ .id = "start", .name = "启动服务", .desc = "启动后台服务", .enabled = true },
        .{ .id = "stop", .name = "停止服务", .desc = "停止后台服务", .enabled = true },
        .{ .id = "restart", .name = "重启服务", .desc = "重启后台服务", .enabled = false }, // 禁用
        .{ .id = "status", .name = "查看状态", .desc = null, .enabled = true },
    };

    var service_items = std.ArrayList(Menu.MenuItem).empty;
    defer service_items.deinit(allocator);

    // 只添加启用的菜单项
    for (config_menus) |cfg| {
        if (cfg.enabled) {
            try service_items.append(allocator, .{
                .key = cfg.id,
                .label = cfg.name,
                .description = cfg.desc,
            });
        }
    }

    std.debug.print("从配置加载了 {d} 个有效菜单项\n", .{service_items.items.len});

    const service_choice = try Menu.showMenu(allocator, .{
        .title = "\n服务管理",
        .prompt = "选择服务操作: ",
    }, service_items.items);

    if (service_choice) |sc| {
        defer allocator.free(sc);
        std.debug.print("执行操作: {s}\n\n", .{sc});
    }

    // ========== 示例 3: 运行时动态修改菜单 ==========
    std.debug.print("【示例3】运行时动态修改菜单\n", .{});

    var dynamic_items = std.ArrayList(Menu.MenuItem).empty;
    defer dynamic_items.deinit(allocator);

    // 初始菜单
    try dynamic_items.append(allocator, .{ .key = "1", .label = "添加任务" });
    try dynamic_items.append(allocator, .{ .key = "2", .label = "查看任务" });

    // 模拟：用户完成了某些操作后，动态添加新选项
    const has_tasks = true;
    if (has_tasks) {
        try dynamic_items.append(allocator, .{
            .key = "3",
            .label = "删除任务",
            .description = "需要先有任务才能删除",
        });
    }

    std.debug.print("当前菜单共有 {d} 项\n", .{dynamic_items.items.len});

    // ========== 示例 4: 使用函数生成菜单 ==========
    std.debug.print("\n【示例4】使用函数生成菜单\n", .{});

    var generated_items = try generateMenuForUser(allocator, "admin");
    defer generated_items.deinit(allocator);

    std.debug.print("为 admin 用户生成了 {d} 个菜单项:\n", .{generated_items.items.len});
    for (generated_items.items) |item| {
        std.debug.print("  - {s}: {s}\n", .{ item.key, item.label });
    }

    // ========== 示例 5: 多级动态菜单 ==========
    std.debug.print("\n【示例5】多级动态菜单\n", .{});

    var main_menu = std.ArrayList(Menu.MenuItem).empty;
    defer main_menu.deinit(allocator);

    try main_menu.append(allocator, .{ .key = "1", .label = "文件操作", .description = "文件相关功能" });
    try main_menu.append(allocator, .{ .key = "2", .label = "编辑操作", .description = "编辑相关功能" });
    try main_menu.append(allocator, .{ .key = "3", .label = "工具", .description = "实用工具" });
    try main_menu.append(allocator, .{ .key = "q", .label = "退出" });

    const main_choice = try Menu.showMenu(allocator, .{
        .title = "\n主菜单",
        .prompt = "选择功能模块: ",
    }, main_menu.items);

    if (main_choice) |mc| {
        defer allocator.free(mc);

        // 根据选择动态生成子菜单
        if (std.mem.eql(u8, mc, "1")) {
            var file_menu = std.ArrayList(Menu.MenuItem).empty;
            defer file_menu.deinit(allocator);

            try file_menu.append(allocator, .{ .key = "n", .label = "新建文件" });
            try file_menu.append(allocator, .{ .key = "o", .label = "打开文件" });
            try file_menu.append(allocator, .{ .key = "s", .label = "保存文件" });
            try file_menu.append(allocator, .{ .key = "b", .label = "返回" });

            const file_choice = try Menu.showMenu(allocator, .{
                .title = "\n文件操作",
                .prompt = "选择文件操作: ",
            }, file_menu.items);

            if (file_choice) |fc| {
                defer allocator.free(fc);
                std.debug.print("执行文件操作: {s}\n", .{fc});
            }
        }
    }

    std.debug.print("\n✅ 动态菜单示例完成\n", .{});
}

/// 根据用户角色生成不同的菜单
fn generateMenuForUser(allocator: std.mem.Allocator, role: []const u8) !std.ArrayList(Menu.MenuItem) {
    var items = std.ArrayList(Menu.MenuItem).empty;

    // 所有用户都有的基础功能
    try items.append(allocator, .{ .key = "1", .label = "查看信息" });
    try items.append(allocator, .{ .key = "2", .label = "修改资料" });

    // 管理员额外功能
    if (std.mem.eql(u8, role, "admin")) {
        try items.append(allocator, .{ .key = "3", .label = "用户管理", .description = "管理员专用" });
        try items.append(allocator, .{ .key = "4", .label = "系统配置", .description = "管理员专用" });
        try items.append(allocator, .{ .key = "5", .label = "查看日志", .description = "管理员专用" });
    }

    // VIP 用户额外功能
    if (std.mem.eql(u8, role, "vip")) {
        try items.append(allocator, .{ .key = "v", .label = "VIP 专区", .description = "VIP 独享功能" });
    }

    try items.append(allocator, .{ .key = "q", .label = "退出" });

    return items;
}
