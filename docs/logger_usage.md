# Logger 模块使用说明

## 概述

`Logger` 是 zzig 库中的结构化日志模块，提供多级别、带时间戳、彩色输出的跨平台日志功能。

## 特性

- ✅ **多级别日志**：debug、info、warn、err 四个级别
- ✅ **精确时间戳**：纳秒级时间戳，格式：`YYYY-MM-DD HH:MM:SS.nnnnnnnnn`
- ✅ **彩色输出**：不同级别使用不同颜色（青、绿、黄、红）
- ✅ **跨平台支持**：Windows 使用 `WriteConsoleW` 确保中文正确显示，Unix 使用标准输出
- ✅ **零外部依赖**：仅依赖 Zig 标准库
- ✅ **可配置级别**：支持全局日志级别过滤
- ✅ **性能友好**：使用 `ArenaAllocator` 批量释放内存

## 快速开始

### 1. 在 build.zig.zon 中添加依赖

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .zzig = .{
            .url = "https://github.com/PeiKeSmart/zzig/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "1220...", // 使用 zig fetch 获取
        },
    },
}
```

### 2. 在 build.zig 中引入模块

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 获取 zzig 依赖
    const zzig = b.dependency("zzig", .{
        .target = target,
        .optimize = optimize,
    });

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

### 3. 在代码中使用

```zig
const std = @import("std");
const zzig = @import("zzig");

pub fn main() void {
    // 设置全局日志级别（可选）
    zzig.Logger.setLevel(.info);

    // 记录不同级别的日志
    zzig.Logger.debug("调试信息", .{});
    zzig.Logger.info("普通信息", .{});
    zzig.Logger.warn("警告信息", .{});
    zzig.Logger.err("错误信息", .{});
}
```

## API 参考

### 日志级别

```zig
pub const Level = enum {
    debug,  // 调试级别（青色）
    info,   // 信息级别（绿色）
    warn,   // 警告级别（黄色）
    err,    // 错误级别（红色）
};
```

### 主要函数

#### setLevel

设置全局日志级别，低于此级别的日志将被过滤。

```zig
pub fn setLevel(level: Level) void
```

**示例：**
```zig
zzig.Logger.setLevel(.warn); // 只显示 warn 和 err 级别
```

#### debug

输出调试级别日志（青色）。

```zig
pub fn debug(comptime fmt: []const u8, args: anytype) void
```

**示例：**
```zig
const value = 42;
zzig.Logger.debug("变量值: {d}", .{value});
```

#### info

输出信息级别日志（绿色）。

```zig
pub fn info(comptime fmt: []const u8, args: anytype) void
```

**示例：**
```zig
zzig.Logger.info("服务启动成功，监听端口: {d}", .{8080});
```

#### warn

输出警告级别日志（黄色）。

```zig
pub fn warn(comptime fmt: []const u8, args: anytype) void
```

**示例：**
```zig
zzig.Logger.warn("配置文件未找到: {s}，使用默认配置", .{config_path});
```

#### err

输出错误级别日志（红色）。

```zig
pub fn err(comptime fmt: []const u8, args: anytype) void
```

**示例：**
```zig
zzig.Logger.err("数据库连接失败: {s}", .{error_msg});
```

#### always

强制输出日志，忽略全局日志级别设置（使用 info 样式）。

```zig
pub fn always(comptime fmt: []const u8, args: anytype) void
```

**示例：**
```zig
zzig.Logger.always("应用程序版本: {s}", .{version});
```

#### print

简单打印，不带时间戳和级别标签。

```zig
pub fn print(comptime fmt: []const u8, args: anytype) void
```

**示例：**
```zig
zzig.Logger.print("纯文本输出\n", .{});
```

## 使用场景

### 应用程序启动日志

```zig
pub fn main() !void {
    zzig.Logger.always("========================================", .{});
    zzig.Logger.always("应用程序: {s} v{s}", .{ app_name, version });
    zzig.Logger.always("========================================", .{});
    
    zzig.Logger.info("正在初始化配置...", .{});
    try loadConfig();
    zzig.Logger.info("配置加载完成", .{});
    
    zzig.Logger.info("正在连接数据库...", .{});
    try connectDatabase();
    zzig.Logger.info("数据库连接成功", .{});
}
```

### 错误处理与日志记录

```zig
fn processFile(path: []const u8) !void {
    zzig.Logger.debug("开始处理文件: {s}", .{path});
    
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        zzig.Logger.err("无法打开文件 {s}: {}", .{ path, err });
        return err;
    };
    defer file.close();
    
    zzig.Logger.info("文件 {s} 处理成功", .{path});
}
```

### 开发调试

```zig
pub fn complexCalculation(a: i32, b: i32) i32 {
    zzig.Logger.debug("输入参数: a={d}, b={d}", .{ a, b });
    
    const result = a * b + 10;
    
    zzig.Logger.debug("计算结果: {d}", .{result});
    return result;
}
```

### 生产环境使用

```zig
pub fn main() !void {
    // 生产环境只记录 info 及以上级别
    if (std.process.getEnvVarOwned(allocator, "ENV")) |env| {
        defer allocator.free(env);
        if (std.mem.eql(u8, env, "production")) {
            zzig.Logger.setLevel(.info);
        }
    } else |_| {
        zzig.Logger.setLevel(.debug); // 开发环境显示全部
    }
    
    // ... 应用逻辑
}
```

## 输出示例

```
[2025-11-01 14:30:25.123456789] DEBUG 变量初始化: count=42
[2025-11-01 14:30:25.234567890] INFO 服务启动成功，监听端口: 8080
[2025-11-01 14:30:26.345678901] WARN 配置文件未找到，使用默认配置
[2025-11-01 14:30:27.456789012] ERROR 数据库连接失败: connection timeout
```

## 平台兼容性

| 平台 | 支持情况 | 备注 |
|------|---------|------|
| Windows | ✅ | 使用 `WriteConsoleW` 确保中文显示 |
| Linux | ✅ | 标准输出 |
| macOS | ✅ | 标准输出 |
| BSD | ✅ | 标准输出 |

## 性能说明

- **内存分配**：每次日志调用使用独立的 `ArenaAllocator`，在函数结束时批量释放
- **时间戳计算**：使用 `std.time.nanoTimestamp()` 获取纳秒级时间戳
- **跨平台时区**：Windows 通过 `GetTimeZoneInformation` API 获取，Unix 简化为 UTC+8（可根据需求调整）

## 注意事项

1. **日志级别过滤**：被过滤的日志不会执行格式化，性能损耗极小
2. **中文支持**：Windows 平台确保终端支持 UTF-8，Linux/macOS 需终端配置 UTF-8
3. **颜色输出**：如果重定向到文件，颜色代码会保留（可根据需求扩展）
4. **线程安全**：当前版本未实现线程安全，多线程环境需外部同步

## 未来计划

- [ ] 线程安全支持（添加互斥锁）
- [ ] 日志文件输出（支持文件滚动）
- [ ] 自定义格式化器
- [ ] 性能指标统计
- [ ] 异步日志支持

## 许可证

本模块随 zzig 库一起发布，遵循项目的开源许可证。

---

**维护者：** PeiKeSmart  
**最后更新：** 2025-11-01
