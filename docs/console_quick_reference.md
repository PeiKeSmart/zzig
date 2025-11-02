# Console 工具快速参考

## 📦 导入

```zig
const zzig = @import("zzig");
const Console = zzig.Console;
```

---

## 🚀 初始化

```zig
// 快速初始化(推荐)
Console.setup();

// 完整初始化(带 defer 恢复)
const result = Console.init(.{});
defer Console.deinit(result);

// 部分启用
const result = Console.init(.{
    .utf8 = true,
    .ansi_colors = false,  // 禁用颜色
});
```

---

## 🎨 颜色代码

### 基础 8 色

| 颜色 | 前景色 | 背景色 |
|------|--------|--------|
| 黑色 | `Console.Color.Code.black.fg()` | `Console.Color.Code.black.bg()` |
| 红色 | `Console.Color.Code.red.fg()` | `Console.Color.Code.red.bg()` |
| 绿色 | `Console.Color.Code.green.fg()` | `Console.Color.Code.green.bg()` |
| 黄色 | `Console.Color.Code.yellow.fg()` | `Console.Color.Code.yellow.bg()` |
| 蓝色 | `Console.Color.Code.blue.fg()` | `Console.Color.Code.blue.bg()` |
| 品红 | `Console.Color.Code.magenta.fg()` | `Console.Color.Code.magenta.bg()` |
| 青色 | `Console.Color.Code.cyan.fg()` | `Console.Color.Code.cyan.bg()` |
| 白色 | `Console.Color.Code.white.fg()` | `Console.Color.Code.white.bg()` |

### 高亮 8 色

| 颜色 | 前景色 | 背景色 |
|------|--------|--------|
| 灰色 | `Console.Color.Code.bright_black.fg()` | `Console.Color.Code.bright_black.bg()` |
| 亮红 | `Console.Color.Code.bright_red.fg()` | `Console.Color.Code.bright_red.bg()` |
| 亮绿 | `Console.Color.Code.bright_green.fg()` | `Console.Color.Code.bright_green.bg()` |
| 亮黄 | `Console.Color.Code.bright_yellow.fg()` | `Console.Color.Code.bright_yellow.bg()` |
| 亮蓝 | `Console.Color.Code.bright_blue.fg()` | `Console.Color.Code.bright_blue.bg()` |
| 亮品红 | `Console.Color.Code.bright_magenta.fg()` | `Console.Color.Code.bright_magenta.bg()` |
| 亮青 | `Console.Color.Code.bright_cyan.fg()` | `Console.Color.Code.bright_cyan.bg()` |
| 亮白 | `Console.Color.Code.bright_white.fg()` | `Console.Color.Code.bright_white.bg()` |

### 重置

| 操作 | 代码 |
|------|------|
| 重置所有样式 | `Console.Color.Code.reset.fg()` |

---

## ✨ 文本样式

| 样式 | 代码 |
|------|------|
| 粗体 | `Console.Color.Style.bold.code()` |
| 暗淡 | `Console.Color.Style.dim.code()` |
| 斜体 | `Console.Color.Style.italic.code()` |
| 下划线 | `Console.Color.Style.underline.code()` |
| 闪烁 | `Console.Color.Style.blink.code()` |
| 反色 | `Console.Color.Style.reverse.code()` |
| 隐藏 | `Console.Color.Style.hidden.code()` |
| 删除线 | `Console.Color.Style.strikethrough.code()` |

---

## 📋 常用模式

### 彩色日志

```zig
const Color = Console.Color.Code;

// INFO
std.debug.print("{s}[INFO]{s} {s}\n", .{
    Color.green.fg(), Color.reset.fg(), msg
});

// WARN
std.debug.print("{s}[WARN]{s} {s}\n", .{
    Color.yellow.fg(), Color.reset.fg(), msg
});

// ERROR
std.debug.print("{s}[ERROR]{s} {s}\n", .{
    Color.red.fg(), Color.reset.fg(), msg
});
```

### 组合样式

```zig
const Color = Console.Color.Code;
const Style = Console.Color.Style;

// 粗体绿色
std.debug.print("{s}{s}{s}{s}\n", .{
    Style.bold.code(),
    Color.green.fg(),
    "成功",
    Color.reset.fg(),
});

// 黄底黑字粗体
std.debug.print("{s}{s}{s} 警告 {s}\n", .{
    Color.yellow.bg(),
    Color.black.fg(),
    Style.bold.code(),
    Color.reset.fg(),
});
```

### 条件彩色输出

```zig
const use_colors = Console.supportsAnsiColors();

if (use_colors) {
    std.debug.print("{s}彩色{s}\n", .{
        Console.Color.Code.green.fg(),
        Console.Color.Code.reset.fg(),
    });
} else {
    std.debug.print("纯文本\n", .{});
}
```

---

## 🔧 工具函数

```zig
// 检测 ANSI 支持
const supports = Console.supportsAnsiColors();

// 检查初始化结果
const result = Console.init(.{});
if (result.utf8_enabled) { ... }
if (result.ansi_enabled) { ... }
```

---

## 📦 构建命令

```bash
# 运行示例
zig build console-demo

# 运行测试
zig build test

# 查看帮助
zig build --help
```

---

## 🌐 平台支持

| 平台 | UTF-8 | ANSI 颜色 | 说明 |
|------|-------|-----------|------|
| Windows 10+ | ✅ | ✅ | 需调用初始化 |
| Linux | ✅ | ✅ | 默认支持 |
| macOS | ✅ | ✅ | 默认支持 |

---

## 📚 完整文档

- [详细使用指南](./console_usage.md)
- [项目总览](../README.md)
- [完成报告](./console_module_completion_report.md)

---

**版本:** 1.0.0 | **更新:** 2024-01-XX
