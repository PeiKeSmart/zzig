# Console 控制台工具模块

## 概述

`Console` 模块提供跨平台的控制台初始化和样式工具,解决 Windows 平台中文乱码和 ANSI 颜色不显示的问题。

### 主要功能

- ✅ **UTF-8 编码支持** - Windows 自动设置代码页为 65001,Linux/macOS 默认支持
- ✅ **ANSI 颜色显示** - Windows 启用虚拟终端处理(VT100),全平台统一 API
- ✅ **文本样式控制** - 粗体、斜体、下划线、反色等 8 种样式
- ✅ **16 色前景/背景** - 基础 8 色 + 高亮 8 色,共 16 种颜色
- ✅ **零依赖** - 仅依赖 Zig 标准库,无第三方库
- ✅ **跨平台兼容** - Windows/Linux/macOS 统一接口

---

## 快速开始

### 1. 基础用法

```zig
const std = @import("std");
const zzig = @import("zzig");

pub fn main() !void {
    // 快速初始化(推荐)
    zzig.Console.setup();
    
    // 现在可以正常显示中文和 ANSI 颜色
    std.debug.print("✅ 中文显示正常\n", .{});
    std.debug.print("{s}绿色文本{s}\n", .{
        zzig.Console.Color.Code.green.fg(),
        zzig.Console.Color.Code.reset.fg(),
    });
}
```

### 2. 完整初始化(带结果检查)

```zig
pub fn main() !void {
    const result = zzig.Console.init(.{
        .utf8 = true,
        .ansi_colors = true,
        .virtual_terminal = true,
    });
    defer zzig.Console.deinit(result); // 退出时恢复原始设置
    
    // 检查初始化结果
    if (result.utf8_enabled) {
        std.debug.print("✅ UTF-8 已启用\n", .{});
    }
    
    if (result.ansi_enabled) {
        std.debug.print("✅ ANSI 颜色已启用\n", .{});
    }
}
```

### 3. 检测 ANSI 支持

```zig
pub fn main() !void {
    const supports = zzig.Console.supportsAnsiColors();
    
    if (supports) {
        std.debug.print("{s}彩色模式{s}\n", .{
            zzig.Console.Color.Code.green.fg(),
            zzig.Console.Color.Code.reset.fg(),
        });
    } else {
        std.debug.print("纯文本模式\n", .{});
    }
}
```

---

## API 文档

### 初始化函数

#### `setup()`

快速初始化控制台,启用所有功能。

```zig
pub fn setup() void
```

**特点:**
- 无返回值,自动处理失败情况
- 启用 UTF-8 + ANSI 颜色
- 适合简单场景

**示例:**
```zig
zzig.Console.setup();
std.debug.print("🚀 控制台已配置\n", .{});
```

---

#### `init(features)`

完整初始化,返回详细结果。

```zig
pub fn init(features: ConsoleFeatures) InitResult
```

**参数:**
- `features: ConsoleFeatures` - 要启用的功能
  - `utf8: bool` - 是否启用 UTF-8 (默认 true)
  - `ansi_colors: bool` - 是否启用 ANSI 颜色 (默认 true)
  - `virtual_terminal: bool` - 是否启用虚拟终端处理 (默认 true)

**返回:**
- `InitResult` - 初始化结果
  - `utf8_enabled: bool` - UTF-8 是否成功启用
  - `ansi_enabled: bool` - ANSI 颜色是否成功启用
  - `original_mode: ?u32` - 原始控制台模式(仅 Windows)

**示例:**
```zig
// 仅启用 UTF-8
const result = zzig.Console.init(.{ .utf8 = true, .ansi_colors = false });
defer zzig.Console.deinit(result);

std.debug.print("UTF-8: {}\n", .{result.utf8_enabled});
```

---

#### `deinit(result)`

恢复控制台原始设置。

```zig
pub fn deinit(result: InitResult) void
```

**参数:**
- `result: InitResult` - `init()` 返回的结果

**说明:**
- 通常不需要手动调用,使用 `defer` 自动恢复
- 操作系统会在进程退出时自动恢复设置

**示例:**
```zig
const result = zzig.Console.init(.{});
defer zzig.Console.deinit(result); // 自动恢复
```

---

#### `supportsAnsiColors()`

检测当前终端是否支持 ANSI 颜色。

```zig
pub fn supportsAnsiColors() bool
```

**返回:**
- `true` - 支持 ANSI 颜色
- `false` - 不支持(使用纯文本模式)

**逻辑:**
- **Windows:** 检查虚拟终端处理是否启用
- **Unix:** 检查 `TERM` 环境变量(`dumb` 表示不支持)

**示例:**
```zig
if (zzig.Console.supportsAnsiColors()) {
    std.debug.print("{s}彩色输出{s}\n", .{...});
} else {
    std.debug.print("纯文本输出\n", .{});
}
```

---

### 颜色工具

#### `Color.Code` 枚举

定义 16 种颜色代码。

```zig
pub const Code = enum {
    reset,           // 重置所有样式
    black,           // 黑色
    red,             // 红色
    green,           // 绿色
    yellow,          // 黄色
    blue,            // 蓝色
    magenta,         // 品红
    cyan,            // 青色
    white,           // 白色
    bright_black,    // 高亮黑色(灰色)
    bright_red,      // 高亮红色
    bright_green,    // 高亮绿色
    bright_yellow,   // 高亮黄色
    bright_blue,     // 高亮蓝色
    bright_magenta,  // 高亮品红
    bright_cyan,     // 高亮青色
    bright_bright_white, // 高亮白色
};
```

**方法:**

##### `fg()` - 获取前景色代码

```zig
pub fn fg(self: Code) []const u8
```

**示例:**
```zig
const red_fg = zzig.Console.Color.Code.red.fg();
std.debug.print("{s}红色文本{s}\n", .{red_fg, reset});
```

##### `bg()` - 获取背景色代码

```zig
pub fn bg(self: Code) []const u8
```

**示例:**
```zig
const red_bg = zzig.Console.Color.Code.red.bg();
std.debug.print("{s} 红色背景 {s}\n", .{red_bg, reset});
```

---

#### `Color.Style` 枚举

定义 8 种文本样式。

```zig
pub const Style = enum {
    bold,           // 粗体
    dim,            // 暗淡
    italic,         // 斜体
    underline,      // 下划线
    blink,          // 闪烁
    reverse,        // 反色
    hidden,         // 隐藏
    strikethrough,  // 删除线
};
```

**方法:**

##### `code()` - 获取样式代码

```zig
pub fn code(self: Style) []const u8
```

**示例:**
```zig
const bold = zzig.Console.Color.Style.bold.code();
std.debug.print("{s}粗体文本{s}\n", .{bold, reset});
```

---

## 实战示例

### 1. 日志级别彩色输出

```zig
const Color = zzig.Console.Color.Code;

pub fn logInfo(msg: []const u8) void {
    std.debug.print("{s}[INFO]{s} {s}\n", .{
        Color.green.fg(),
        Color.reset.fg(),
        msg,
    });
}

pub fn logWarn(msg: []const u8) void {
    std.debug.print("{s}[WARN]{s} {s}\n", .{
        Color.yellow.fg(),
        Color.reset.fg(),
        msg,
    });
}

pub fn logError(msg: []const u8) void {
    std.debug.print("{s}[ERROR]{s} {s}\n", .{
        Color.red.fg(),
        Color.reset.fg(),
        msg,
    });
}

// 使用
logInfo("服务器启动成功");
logWarn("内存使用率 85%");
logError("数据库连接失败");
```

### 2. 进度条显示

```zig
pub fn showProgress(percent: u8) void {
    const filled = percent / 5; // 每 5% 一个方块
    const empty = 20 - filled;
    
    std.debug.print("进度: {s}", .{zzig.Console.Color.Code.green.bg()});
    
    var i: u8 = 0;
    while (i < filled) : (i += 1) {
        std.debug.print("█", .{});
    }
    
    std.debug.print("{s}", .{zzig.Console.Color.Code.reset.fg()});
    
    i = 0;
    while (i < empty) : (i += 1) {
        std.debug.print("░", .{});
    }
    
    std.debug.print(" {}%\n", .{percent});
}

// 使用
showProgress(60); // 进度: ████████████░░░░░░░░ 60%
```

### 3. 状态表格

```zig
pub fn printServiceStatus() void {
    const Color = zzig.Console.Color.Code;
    const Style = zzig.Console.Color.Style;
    
    std.debug.print("┌─────────────┬──────────┬────────┐\n", .{});
    std.debug.print("│ {s}服务名称{s}    │ {s}状态{s}     │ {s}CPU%{s}  │\n", .{
        Style.bold.code(), Color.reset.fg(),
        Style.bold.code(), Color.reset.fg(),
        Style.bold.code(), Color.reset.fg(),
    });
    std.debug.print("├─────────────┼──────────┼────────┤\n", .{});
    
    // 运行中的服务(绿色)
    std.debug.print("│ web-server  │ {s}运行中{s}   │ 45.2%  │\n", .{
        Color.green.fg(), Color.reset.fg(),
    });
    
    // 已停止的服务(红色)
    std.debug.print("│ cache-node  │ {s}已停止{s}   │  0.0%  │\n", .{
        Color.red.fg(), Color.reset.fg(),
    });
    
    std.debug.print("└─────────────┴──────────┴────────┘\n", .{});
}
```

### 4. 组合样式

```zig
pub fn printHighlight(text: []const u8) void {
    const Color = zzig.Console.Color.Code;
    const Style = zzig.Console.Color.Style;
    
    // 粗体 + 下划线 + 绿色
    std.debug.print("{s}{s}{s}{s}{s}\n", .{
        Style.bold.code(),
        Style.underline.code(),
        Color.green.fg(),
        text,
        Color.reset.fg(),
    });
}

pub fn printAlert(text: []const u8) void {
    const Color = zzig.Console.Color.Code;
    const Style = zzig.Console.Color.Style;
    
    // 黄色背景 + 黑色字 + 粗体
    std.debug.print("{s}{s}{s} {s} {s}\n", .{
        Color.yellow.bg(),
        Color.black.fg(),
        Style.bold.code(),
        text,
        Color.reset.fg(),
    });
}
```

---

## 构建和运行

### 编译示例

```bash
# 运行完整示例
zig build console-demo

# 仅编译(不运行)
zig build

# 查看所有可用命令
zig build --help
```

### 集成到项目

在 `build.zig` 中:

```zig
const zzig = b.dependency("zzig", .{
    .target = target,
    .optimize = optimize,
});

// 添加 Console 模块
const my_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
});
my_module.addImport("zzig", zzig.module("zzig"));

const exe = b.addExecutable(.{
    .name = "my_app",
    .root_module = my_module,
    .target = target,
    .optimize = optimize,
});
```

在代码中:

```zig
const zzig = @import("zzig");

pub fn main() !void {
    zzig.Console.setup();
    // 使用 Console 功能...
}
```

---

## 平台差异

### Windows

- **UTF-8:** 调用 `SetConsoleOutputCP(65001)` 和 `SetConsoleCP(65001)`
- **ANSI 颜色:** 启用 `ENABLE_VIRTUAL_TERMINAL_PROCESSING` 标志
- **兼容性:** Windows 10+ 原生支持,旧版本可能需要 ConEmu/ANSICON

### Linux/macOS

- **UTF-8:** 默认支持,无需特殊处理
- **ANSI 颜色:** 默认支持 VT100/xterm 转义序列
- **终端检测:** 检查 `TERM` 环境变量(`dumb` 表示不支持颜色)

---

## 常见问题

### Q1: Windows 终端中文显示为 `???`

**A:** 确保调用了 `zzig.Console.setup()` 或 `zzig.Console.init(.{})`。

### Q2: ANSI 颜色不显示

**A:** 
1. 检查 `supportsAnsiColors()` 返回值
2. Windows 确保使用 Windows 10+ 的 Terminal 或 PowerShell
3. 确认终端支持 VT100(避免使用 `cmd.exe` 旧版本)

### Q3: 如何关闭颜色输出?

**A:** 根据 `supportsAnsiColors()` 条件判断:

```zig
const use_colors = zzig.Console.supportsAnsiColors();

if (use_colors) {
    std.debug.print("{s}彩色{s}\n", .{...});
} else {
    std.debug.print("纯文本\n", .{});
}
```

### Q4: 退出时需要手动恢复设置吗?

**A:** 不需要。使用 `defer zzig.Console.deinit(result)` 即可自动恢复,或者让操作系统在进程退出时恢复。

---

## 性能考虑

- **零分配:** 所有 API 均无内存分配,适合高性能场景
- **最小开销:** Windows 初始化仅调用 3 次系统调用,Unix 无开销
- **缓存友好:** 颜色/样式代码均为编译期常量字符串

---

## 许可证

MIT License - 参见项目根目录 `LICENSE` 文件

---

## 相关文档

- [Logger 使用文档](./logger_usage.md) - 日志系统与 Console 结合使用
- [AsyncLogger 使用文档](./async_logger_usage.md) - 异步日志的彩色输出
- [Zig 官方文档](https://ziglang.org/documentation/master/) - Zig 语言参考

---

**版本:** 1.0.0  
**更新日期:** 2024-01-XX  
**维护者:** PeiKeSmart Team
