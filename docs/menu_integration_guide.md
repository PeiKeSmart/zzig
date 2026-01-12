# Menu 模块第三方集成指南

## 📦 概述

Menu 模块是一个轻量级、跨平台的 Zig 菜单和输入读取库，支持完全动态的菜单构建。**菜单项并非固定**，可以在运行时根据条件动态添加、修改或删除。

### 核心特性

✅ **完全动态**：菜单项可在运行时构建和修改  
✅ **跨平台**：Windows、Linux、macOS 全支持  
✅ **零依赖**：仅依赖 Zig 标准库  
✅ **类型安全**：利用 Zig 编译期类型检查  
✅ **灵活配置**：支持默认值、多级菜单、条件菜单  

---

## 🚀 快速集成

### 方式 1：作为 zzig 模块依赖（推荐）

#### 1.1 添加依赖

在你的 `build.zig.zon` 中添加 zzig 依赖：

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .zzig = .{
            .url = "https://github.com/PeiKeSmart/zzig/archive/refs/tags/v0.x.x.tar.gz",
            .hash = "1220...", // 使用 zig fetch 获取正确的 hash
        },
    },
}
```

#### 1.2 在 build.zig 中配置

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 获取 zzig 依赖
    const zzig = b.dependency("zzig", .{
        .target = target,
        .optimize = optimize,
    });

    // 创建你的可执行文件
    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 添加 zzig 模块
    exe.root_module.addImport("zzig", zzig.module("zzig"));

    b.installArtifact(exe);
}
```

#### 1.3 在代码中使用

```zig
const std = @import("std");
const zzig = @import("zzig");
const Menu = zzig.Menu;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 使用 Menu 模块
    const name = try Menu.readString(allocator, "请输入名字: ", "默认名");
    defer allocator.free(name);

    std.debug.print("你好, {s}!\n", .{name});
}
```

---

### 方式 2：直接复制文件

#### 2.1 复制文件

将 `src/menu/menu.zig` 复制到你的项目目录，例如 `src/utils/menu.zig`。

#### 2.2 导入使用

```zig
const menu = @import("utils/menu.zig");

pub fn main() !void {
    // 使用 menu 模块
    const items = [_]menu.MenuItem{
        .{ .key = "1", .label = "选项1" },
        .{ .key = "2", .label = "选项2" },
    };

    // ...
}
```

---

## 🔥 动态菜单特性

### ✨ 重要说明：菜单并非固定

**Menu 模块的菜单项完全动态，不是固定的！** 你可以：

- 🔧 **运行时构建**：根据配置/数据库/用户权限动态生成菜单
- ➕ **动态添加**：在程序运行过程中添加新菜单项
- ➖ **动态删除**：根据条件移除某些菜单项
- 🔄 **动态修改**：更新菜单标签、描述等
- 🌳 **多级菜单**：根据用户选择动态生成子菜单

---

## 📖 动态菜单示例

### 示例 1：运行时动态构建菜单

```zig
const std = @import("std");
const zzig = @import("zzig");
const Menu = zzig.Menu;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 动态创建菜单列表
    var menu_items = std.ArrayList(Menu.MenuItem).empty;
    defer menu_items.deinit(allocator);

    // 添加基础菜单项
    try menu_items.append(allocator, .{
        .key = "1",
        .label = "查看信息",
    });

    try menu_items.append(allocator, .{
        .key = "2",
        .label = "编辑数据",
    });

    // 根据条件动态添加管理员菜单
    const is_admin = checkUserPermission(); // 你的权限检查逻辑
    if (is_admin) {
        try menu_items.append(allocator, .{
            .key = "9",
            .label = "管理员设置",
            .description = "仅管理员可见",
        });
    }

    // 显示动态菜单
    const choice = try Menu.showMenu(allocator, .{
        .title = "主菜单",
        .prompt = "请选择: ",
    }, menu_items.items);

    if (choice) |c| {
        defer allocator.free(c);
        std.debug.print("你选择了: {s}\n", .{c});
    }
}

fn checkUserPermission() bool {
    // 你的权限检查逻辑
    return true;
}
```

### 示例 2：从配置文件动态加载菜单

```zig
const MenuConfig = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool,
};

fn loadMenuFromConfig(allocator: std.mem.Allocator) !std.ArrayList(Menu.MenuItem) {
    var items = std.ArrayList(Menu.MenuItem).empty;

    // 模拟从配置文件读取
    const configs = [_]MenuConfig{
        .{ .id = "new", .name = "新建文档", .enabled = true },
        .{ .id = "open", .name = "打开文档", .enabled = true },
        .{ .id = "save", .name = "保存文档", .enabled = false }, // 禁用
    };

    // 只添加启用的菜单项
    for (configs) |cfg| {
        if (cfg.enabled) {
            try items.append(allocator, .{
                .key = cfg.id,
                .label = cfg.name,
            });
        }
    }

    return items;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 从配置动态加载菜单
    var menu_items = try loadMenuFromConfig(allocator);
    defer menu_items.deinit(allocator);

    const choice = try Menu.showMenu(allocator, .{
        .title = "文档操作",
        .prompt = "选择操作: ",
    }, menu_items.items);

    if (choice) |c| {
        defer allocator.free(c);
        // 处理选择
    }
}
```

### 示例 3：多级动态菜单

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 主菜单
    var main_menu = std.ArrayList(Menu.MenuItem).empty;
    defer main_menu.deinit(allocator);

    try main_menu.append(allocator, .{ .key = "1", .label = "用户管理" });
    try main_menu.append(allocator, .{ .key = "2", .label = "系统设置" });
    try main_menu.append(allocator, .{ .key = "q", .label = "退出" });

    const choice = try Menu.showMenu(allocator, .{
        .title = "主菜单",
        .prompt = "选择: ",
    }, main_menu.items);

    if (choice) |c| {
        defer allocator.free(c);

        // 根据选择动态生成子菜单
        if (std.mem.eql(u8, c, "1")) {
            var user_menu = std.ArrayList(Menu.MenuItem).empty;
            defer user_menu.deinit(allocator);

            // 动态构建用户管理子菜单
            try user_menu.append(allocator, .{ .key = "a", .label = "添加用户" });
            try user_menu.append(allocator, .{ .key = "d", .label = "删除用户" });
            try user_menu.append(allocator, .{ .key = "l", .label = "列出用户" });

            const user_choice = try Menu.showMenu(allocator, .{
                .title = "用户管理",
                .prompt = "选择操作: ",
            }, user_menu.items);

            if (user_choice) |uc| {
                defer allocator.free(uc);
                // 处理用户管理操作
            }
        }
    }
}
```

### 示例 4：根据用户角色生成不同菜单

```zig
fn generateMenuForRole(allocator: std.mem.Allocator, role: []const u8) !std.ArrayList(Menu.MenuItem) {
    var items = std.ArrayList(Menu.MenuItem).empty;

    // 所有角色通用菜单
    try items.append(allocator, .{ .key = "1", .label = "个人信息" });
    try items.append(allocator, .{ .key = "2", .label = "修改密码" });

    // 管理员专属菜单
    if (std.mem.eql(u8, role, "admin")) {
        try items.append(allocator, .{ .key = "a", .label = "用户管理" });
        try items.append(allocator, .{ .key = "b", .label = "系统配置" });
        try items.append(allocator, .{ .key = "c", .label = "日志查看" });
    }

    // VIP 用户专属菜单
    if (std.mem.eql(u8, role, "vip")) {
        try items.append(allocator, .{ .key = "v", .label = "VIP 特权" });
    }

    try items.append(allocator, .{ .key = "q", .label = "退出" });

    return items;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const user_role = "admin"; // 从认证系统获取

    // 根据角色生成菜单
    var menu_items = try generateMenuForRole(allocator, user_role);
    defer menu_items.deinit(allocator);

    const choice = try Menu.showMenu(allocator, .{
        .title = "个人中心",
        .prompt = "选择: ",
    }, menu_items.items);

    if (choice) |c| {
        defer allocator.free(c);
        // 处理选择
    }
}
```

---

## 📚 API 参考

### 核心类型

#### `MenuItem`
```zig
pub const MenuItem = struct {
    key: []const u8,          // 选项标识
    label: []const u8,        // 显示文本
    description: ?[]const u8, // 可选描述
};
```

#### `MenuConfig`
```zig
pub const MenuConfig = struct {
    title: []const u8,            // 菜单标题
    prompt: []const u8,           // 输入提示（默认 "请选择: "）
    default_key: ?[]const u8,     // 默认选项
    show_keys: bool,              // 是否显示按键（默认 true）
};
```

### 主要函数

#### `showMenu`
```zig
pub fn showMenu(
    allocator: std.mem.Allocator,
    config: MenuConfig,
    items: []const MenuItem,
) !?[]u8
```

显示菜单并返回用户选择。返回 `null` 表示无效输入。

#### `readString`
```zig
pub fn readString(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_value: ?[]const u8,
) ![]u8
```

读取字符串输入，支持默认值。

#### `readInt`
```zig
pub fn readInt(
    comptime T: type,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_value: ?T,
) !T
```

读取整数输入，支持默认值。

#### `readBool` / `confirm`
```zig
pub fn readBool(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_value: ?bool,
) !bool

pub fn confirm(
    allocator: std.mem.Allocator,
    prompt: []const u8,
) !bool
```

读取布尔值（y/n），`confirm` 默认为 `false`。

#### `findMenuItem`
```zig
pub fn findMenuItem(items: []const MenuItem, key: []const u8) ?MenuItem
```

根据 key 查找菜单项。

---

## 🎯 最佳实践

### 1. 内存管理

```zig
// ✅ 正确：使用 defer 确保释放
const choice = try Menu.showMenu(allocator, config, items);
if (choice) |c| {
    defer allocator.free(c);
    // 使用 c
}

// ✅ 正确：动态菜单也要正确释放
var menu_items = std.ArrayList(Menu.MenuItem).empty;
defer menu_items.deinit(allocator);
```

### 2. 错误处理

```zig
// ✅ 处理用户取消输入的情况
const choice = try Menu.showMenu(allocator, config, items) orelse {
    std.debug.print("操作已取消\n", .{});
    return;
};
defer allocator.free(choice);
```

### 3. 菜单验证

```zig
// ✅ 使用 findMenuItem 验证选择
if (Menu.findMenuItem(&items, choice)) |selected| {
    std.debug.print("执行: {s}\n", .{selected.label});
} else {
    std.debug.print("无效选项: {s}\n", .{choice});
}
```

### 4. 多级菜单循环

```zig
// ✅ 实现可返回的多级菜单
while (true) {
    var menu = std.ArrayList(Menu.MenuItem).empty;
    defer menu.deinit(allocator);

    try menu.append(allocator, .{ .key = "1", .label = "功能1" });
    try menu.append(allocator, .{ .key = "b", .label = "返回" });
    try menu.append(allocator, .{ .key = "q", .label = "退出" });

    const choice = try Menu.showMenu(allocator, .{
        .title = "子菜单",
        .prompt = "选择: ",
    }, menu.items) orelse continue;
    defer allocator.free(choice);

    if (std.mem.eql(u8, choice, "b")) break;  // 返回上级
    if (std.mem.eql(u8, choice, "q")) return; // 退出程序

    // 处理其他选项
}
```

---

## 🛠️ 构建和测试

### 运行官方示例

```bash
# 基础演示
zig build menu-demo

# 动态菜单示例
zig build menu-dynamic
```

### 在你的项目中测试

```bash
# 编译
zig build

# 运行
./zig-out/bin/your-app
```

---

## 🌐 跨平台注意事项

Menu 模块已处理跨平台差异：

- ✅ **Windows**：使用 `kernel32.ReadFile`
- ✅ **Linux/macOS**：使用 `std.posix.read`
- ✅ **换行符**：自动处理 `\r\n` 和 `\n`
- ✅ **编码**：支持 UTF-8

无需额外配置，直接使用即可。

---

## 📖 完整示例

查看项目中的示例文件：

- [`examples/menu_demo.zig`](../examples/menu_demo.zig) - 基础功能演示
- [`examples/menu_dynamic_example.zig`](../examples/menu_dynamic_example.zig) - 动态菜单完整示例

---

## ❓ 常见问题

### Q1: 菜单项是固定的吗？

**A:** 不是！菜单项完全动态，可以在运行时根据任何条件构建、添加、删除或修改。

### Q2: 如何实现权限控制的菜单？

**A:** 在构建菜单时检查用户权限，只添加用户有权限的菜单项：

```zig
if (user.hasPermission("admin")) {
    try menu_items.append(allocator, .{ .key = "a", .label = "管理" });
}
```

### Q3: 支持多级菜单吗？

**A:** 支持！根据用户在主菜单的选择，动态构建并显示子菜单。

### Q4: 如何处理用户按 Ctrl+C？

**A:** `readLine` 会返回 `error.EndOfStream`，你可以捕获并处理：

```zig
const choice = Menu.showMenu(allocator, config, items) catch |err| {
    if (err == error.EndOfStream) {
        std.debug.print("\n用户取消操作\n", .{});
        return;
    }
    return err;
};
```

### Q5: 能否国际化？

**A:** 可以！所有字符串都是 `[]const u8`，你可以根据语言设置动态提供不同的标签：

```zig
const label = if (lang == "en") "Settings" else "设置";
try menu_items.append(allocator, .{ .key = "s", .label = label });
```

---

## 📄 许可证

Menu 模块是 [zzig](https://github.com/PeiKeSmart/zzig) 项目的一部分。

---

## 🔗 相关文档

- [Menu 模块使用指南](menu.md)
- [zzig 项目主页](https://github.com/PeiKeSmart/zzig)
- [完整 API 文档](menu.md#api-%E6%96%87%E6%A1%A3)

---

**总结：Menu 模块提供完全动态的菜单构建能力，适合各种需要交互式命令行界面的应用场景。**
