# Menu 模块

一个简单、跨平台的 Zig 菜单和输入读取库，适用于 Zig 0.15.2+。

## 特性

- ✅ **完全动态**：菜单项可在运行时构建和修改（非固定）
- ✅ **跨平台支持** (Windows, Linux, macOS)
- ✅ **简单易用**的 API
- ✅ **支持默认值**
- ✅ **菜单项结构化管理**
- ✅ **多种输入类型**（字符串、整数、布尔值）
- ✅ **零外部依赖**
- ✅ **完整的测试覆盖**

> 💡 **重要提示**：菜单项并非固定！你可以根据配置、权限、运行时条件等动态构建菜单。详见 [动态菜单示例](#动态菜单)。

## 快速开始

### 1. 添加到项目

**方式 A：作为 zzig 模块依赖（推荐）**

```zig
const zzig = @import("zzig");
const Menu = zzig.Menu;
```

**方式 B：直接复制文件**

将 `menu.zig` 复制到你的项目中：

```zig
const menu = @import("menu.zig");
```

> 📖 完整集成指南请参考：[Menu 第三方集成指南](menu_integration_guide.md)

### 2. 基本用法

#### 读取单行输入

```zig
const std = @import("std");
const menu = @import("menu.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const name = try menu.readLine(allocator);
    defer allocator.free(name);
    
    std.debug.print("你好, {s}!\n", .{name});
}
```

#### 显示菜单

```zig
const items = [_]menu.MenuItem{
    .{ .key = "1", .label = "选项1", .description = "第一个选项" },
    .{ .key = "2", .label = "选项2", .description = "第二个选项" },
    .{ .key = "3", .label = "选项3" },
};

const choice = try menu.showMenu(allocator, .{
    .title = "请选择一个选项:",
    .prompt = "输入序号: ",
    .default_key = "1",
}, &items);

defer if (choice) |c| allocator.free(c);
```

#### 读取字符串（带默认值）

```zig
const host = try menu.readString(allocator, "请输入主机地址: ", "127.0.0.1");
defer allocator.free(host);
```

#### 读取整数

```zig
const port = try menu.readInt(u16, allocator, "请输入端口号: ", 8080);
std.debug.print("端口: {d}\n", .{port});
```

#### 读取布尔值

```zig
const confirmed = try menu.readBool(allocator, "确认操作?", false);
if (confirmed) {
    std.debug.print("已确认\n", .{});
}

// 或使用更简洁的 confirm 函数
if (try menu.confirm(allocator, "是否继续?")) {
    // 执行操作...
}
```

## API 文档

### 核心函数

#### `readLine`
```zig
pub fn readLine(allocator: std.mem.Allocator) ![]u8
```
读取一行用户输入，自动处理不同平台的换行符。

**返回**: 用户输入的字符串（需要 free）

**错误**: 
- `error.EndOfStream` - 到达输入流末尾
- `error.InvalidHandle` - (Windows) 无效的句柄
- `error.ReadFailed` - 读取失败

---

#### `showMenu`
```zig
pub fn showMenu(
    allocator: std.mem.Allocator,
    config: MenuConfig,
    items: []const MenuItem
) !?[]u8
```
显示菜单并获取用户选择。

**参数**:
- `allocator`: 内存分配器
- `config`: 菜单配置
- `items`: 菜单项数组

**返回**: 用户选择的 key（需要 free），如果输入为空且无默认值则返回 `null`

---

#### `readString`
```zig
pub fn readString(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_value: ?[]const u8
) ![]u8
```
读取字符串输入，支持默认值。

---

#### `readInt`
```zig
pub fn readInt(
    comptime T: type,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_value: ?T
) !T
```
读取整数输入，支持默认值。

**类型参数**: `T` - 整数类型（如 `u16`, `i32` 等）

---

#### `readBool`
```zig
pub fn readBool(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_value: ?bool
) !bool
```
读取布尔值输入（y/n），支持默认值。

---

#### `confirm`
```zig
pub fn confirm(allocator: std.mem.Allocator, prompt: []const u8) !bool
```
简单的确认提示（默认为 false）。

---

### 数据结构

#### `MenuItem`
```zig
pub const MenuItem = struct {
    key: []const u8,              // 选项编号或按键
    label: []const u8,            // 显示文本
    description: ?[]const u8 = null, // 可选的详细描述
};
```

#### `MenuConfig`
```zig
pub const MenuConfig = struct {
    title: []const u8,           // 菜单标题
    prompt: []const u8 = "请选择: ", // 输入提示
    default_key: ?[]const u8 = null, // 默认选项
    show_keys: bool = true,      // 是否显示按键提示
};
```

---

### 工具函数

#### `findMenuItem`
```zig
pub fn findMenuItem(items: []const MenuItem, key: []const u8) ?MenuItem
```
根据 key 查找菜单项。

#### `clearScreen`
```zig
pub fn clearScreen() void
```
清屏（跨平台）。

---

## 完整示例

```zig
const std = @import("std");
const menu = @import("menu.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 主菜单
    const main_items = [_]menu.MenuItem{
        .{ .key = "1", .label = "新建项目", .description = "创建一个新项目" },
        .{ .key = "2", .label = "打开项目", .description = "打开现有项目" },
        .{ .key = "3", .label = "设置", .description = "配置应用设置" },
        .{ .key = "q", .label = "退出" },
    };

    const choice = try menu.showMenu(allocator, .{
        .title = "=== 主菜单 ===",
        .prompt = "请选择操作: ",
        .default_key = "1",
    }, &main_items) orelse {
        std.debug.print("已取消\n", .{});
        return;
    };
    defer allocator.free(choice);

    if (std.mem.eql(u8, choice, "1")) {
        // 创建新项目
        const project_name = try menu.readString(
            allocator,
            "项目名称: ",
            "my-project"
        );
        defer allocator.free(project_name);

        const use_git = try menu.readBool(
            allocator,
            "初始化 Git 仓库?",
            true
        );

        std.debug.print("创建项目: {s}, Git: {}\n", .{ project_name, use_git });
    } else if (std.mem.eql(u8, choice, "2")) {
        // 打开项目
        const path = try menu.readString(
            allocator,
            "项目路径: ",
            "./project"
        );
        defer allocator.free(path);

        std.debug.print("打开项目: {s}\n", .{path});
    } else if (std.mem.eql(u8, choice, "q")) {
        std.debug.print("再见!\n", .{});
    }
}
```

## 测试

运行测试：

```bash
zig test menu.zig
```

## 提交到 zzig 库

要将此模块提交到 [zzig](https://github.com/PeiKeSmart/zzig) 库，请按照以下步骤操作：

### 1. 准备文件

```
zzig/
├── src/
│   └── menu/
│       ├── menu.zig      # 主模块文件
│       └── README.md     # 本文档
└── examples/
    └── menu_demo.zig     # 示例程序
```

### 2. 模块集成

在 zzig 的主模块中添加导出：

```zig
// zzig/src/menu.zig 或 zzig/src/root.zig
pub const Menu = @import("menu/menu.zig");
```

### 3. 使用方式

其他项目可以这样引用：

```zig
// build.zig.zon
.{
    .dependencies = .{
        .zzig = .{
            .url = "https://github.com/PeiKeSmart/zzig/archive/refs/tags/v0.1.0.tar.gz",
        },
    },
}

// build.zig
const zzig = b.dependency("zzig", .{});
exe.root_module.addImport("zzig", zzig.module("zzig"));

// 代码中使用
const zzig = @import("zzig");
const menu = zzig.Menu;
```

## 性能考虑

- **零分配**：除了返回的字符串外，不进行额外的内存分配
- **低延迟**：直接使用系统调用读取输入，无额外缓冲

---

## 动态菜单

### 核心概念

**Menu 模块的菜单项完全动态，不是固定的！** 你可以：

- 🔧 **运行时构建**：根据配置/数据库/用户权限动态生成菜单
- ➕ **动态添加**：在程序运行过程中添加新菜单项
- ➖ **动态删除**：根据条件移除某些菜单项
- 🔄 **动态修改**：更新菜单标签、描述等
- 🌳 **多级菜单**：根据用户选择动态生成子菜单

### 示例：动态构建菜单

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

    // 根据权限动态添加管理员菜单
    const is_admin = checkUserPermission();
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

### 更多动态示例

查看完整的动态菜单示例：

- [`examples/menu_dynamic_example.zig`](../examples/menu_dynamic_example.zig) - 包含 5 个完整的动态菜单场景
- [第三方集成指南](menu_integration_guide.md) - 详细的集成和使用文档

运行动态示例：

```bash
zig build menu-dynamic
```

---

## 相关资源

- 📖 [第三方集成指南](menu_integration_guide.md) - 完整的第三方项目集成文档
- 💻 [基础示例](../examples/menu_demo.zig) - 基本功能演示
- 🚀 [动态菜单示例](../examples/menu_dynamic_example.zig) - 动态构建菜单完整示例
- 🏠 [zzig 项目主页](https://github.com/PeiKeSmart/zzig)

---
- **跨平台**：使用条件编译确保在所有平台上都有最优实现

## 许可证

MIT License - 与 zzig 库保持一致

## 贡献

欢迎提交 Pull Request 或 Issue！

---

**注意**：此模块遵循 [PeiKeSmart Copilot 协作指令](../../.github/copilot-instructions.md) 中的编码规范。
