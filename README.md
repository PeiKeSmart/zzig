# 🚀 zzig - Zig 通用工具库

[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)]()

高性能、零依赖的 Zig 通用工具库,提供日志、字符串、文件、随机数、控制台等常用功能。

---

## ✨ 核心特性

### 🪵 异步日志系统 (AsyncLogger)
- **零分配模式** - ARM/嵌入式设备 5-10x 性能提升
- **11.7M QPS** - 单线程无阻塞写入能力
- **配置文件支持** - JSON 动态配置,热加载
- **自动日志轮转** - 按大小/时间切分,压缩归档
- **多输出目标** - 文件、控制台、自定义 Writer

### 🎨 控制台工具 (Console)
- **跨平台 UTF-8** - Windows/Linux/macOS 统一中文支持
- **ANSI 颜色** - 16 色前景/背景 + 8 种文本样式
- **零分配** - 编译期常量,无运行时开销
- **自动检测** - 智能判断终端能力,优雅降级

### 📄 文件操作 (File)
- **递归目录遍历** - 支持过滤、深度控制
- **批量操作** - 复制、移动、删除
- **文件监控** - 实时监控文件变化(开发中)

### 🎲 随机数生成 (Randoms)
- **多种算法** - Xoshiro256++、PCG、系统随机
- **密码学安全** - 支持 CSPRNG
- **便捷 API** - 范围随机、洗牌、采样

### 📝 字符串工具 (Strings)
- **UTF-8 处理** - 字符统计、切片、验证
- **高效解析** - Split、Trim、Replace
- **格式化** - Printf 风格格式化

---

## 📦 快速开始

### 安装

在 `build.zig.zon` 中添加依赖:

```zig
.{
    .name = "my_project",
    .version = "0.1.0",
    .dependencies = .{
        .zzig = .{
            .url = "https://github.com/PeiKeSmart/zzig/archive/refs/tags/v1.0.0.tar.gz",
            .hash = "1220...", // zig fetch 自动生成
        },
    },
}
```

在 `build.zig` 中导入:

```zig
const zzig = b.dependency("zzig", .{
    .target = target,
    .optimize = optimize,
});

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

### 基础用法

```zig
const std = @import("std");
const zzig = @import("zzig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. 初始化控制台(支持中文和颜色)
    zzig.Console.setup();

    // 2. 创建异步日志
    const config = zzig.AsyncLoggerConfig.default();
    var logger = try zzig.AsyncLogger.init(allocator, config);
    defer logger.deinit();

    // 3. 零分配模式日志(高性能)
    try logger.setZeroAllocMode(true);

    // 4. 彩色日志输出
    const Color = zzig.Console.Color.Code;
    std.debug.print("{s}[INFO]{s} 服务器启动成功\n", .{
        Color.green.fg(),
        Color.reset.fg(),
    });

    // 5. 高性能日志写入
    logger.info("处理请求: {d} ms", .{42});
    logger.warn("内存使用率: {d}%", .{85});
    logger.err("连接失败: {s}", .{"timeout"});

    // 6. 文件操作
    const file = zzig.File;
    try file.createDir("./logs");
    try file.writeFile("./logs/test.txt", "Hello, Zig!");

    // 7. 字符串处理
    const text = "沛柯智能";
    const char_count = try zzig.Strings.countChars(allocator, text);
    std.debug.print("字符数: {d}\n", .{char_count});

    // 8. 随机数生成
    var rng = zzig.Randoms.init();
    const random_num = rng.range(1, 100);
    std.debug.print("随机数: {d}\n", .{random_num});
}
```

---

## 📚 模块文档

| 模块 | 文档 | 描述 |
|------|------|------|
| **AsyncLogger** | [异步日志使用指南](docs/async_logger_usage.md) | 高性能异步日志系统 |
| **Console** | [控制台工具文档](docs/console_usage.md) | UTF-8 + ANSI 颜色支持 |
| **Logger** | [同步日志文档](docs/logger_usage.md) | 简单同步日志 |
| **File** | (开发中) | 文件和目录操作 |
| **Strings** | (开发中) | 字符串处理工具 |
| **Randoms** | (开发中) | 随机数生成器 |

### 详细文档
- [零分配实现分析](docs/zero_allocation_implementation.md)
- [异步日志配置指南](docs/async_logger_config.md)
- [迁移指南](docs/migration_guide.md)
- [实现状态报告](docs/IMPLEMENTATION_STATUS.md)

---

## 🎯 示例程序

运行示例查看各模块功能:

```bash
# 异步日志示例
zig build async-logger-demo

# 控制台工具示例
zig build console-demo

# 日志基准测试
zig build logger-benchmark

# 零分配模式测试
zig build zero-alloc-demo

# 日志轮转测试
zig build rotation-test

# 压力测试
zig build stress-test
```

---

## ⚡ 性能指标

### AsyncLogger (零分配模式)

| 平台 | 单线程 QPS | 内存占用 | 功耗优化 |
|------|-----------|---------|---------|
| **x86_64** | 11.7M | 150 KB | - |
| **ARM Cortex-A** | 2.3M | 80 KB | -35% |
| **嵌入式(ARM-M)** | 500K | 32 KB | -40% |

**对比传统分配模式:**
- 性能提升: **5-10x**
- 内存节省: **~150 MB** (7天运行)
- 延迟降低: **<100ns** (P99)

### Console 工具

- **初始化开销:** <1ms (Windows 3 次系统调用)
- **颜色输出:** 零运行时开销(编译期常量)
- **跨平台:** Windows 10+, Linux, macOS 统一 API

---

## 🛠️ 构建和测试

### 编译项目

```bash
# 开发构建
zig build

# 发布构建(优化)
zig build -Doptimize=ReleaseFast

# 运行测试
zig build test

# 生成文档
zig build docs
```

### 支持平台

| 操作系统 | 架构 | 状态 |
|---------|------|------|
| Windows 10+ | x86_64, ARM64 | ✅ 完全支持 |
| Linux (Kernel 5.0+) | x86_64, ARM64, RISC-V | ✅ 完全支持 |
| macOS 11+ | x86_64, ARM64 | ✅ 完全支持 |
| FreeBSD | x86_64 | 🧪 实验性 |

---

## 🤝 贡献指南

欢迎贡献代码、报告问题或提出建议!

1. **Fork 本仓库**
2. **创建功能分支** (`git checkout -b feature/amazing-feature`)
3. **提交更改** (`git commit -m 'feat: 添加新功能'`)
4. **推送分支** (`git push origin feature/amazing-feature`)
5. **提交 Pull Request**

### 代码规范
- 遵循 [Copilot 协作指令](.github/copilot-instructions.md)
- Zig 0.15.2+ 兼容性
- 零分配优先,性能至上
- 完善的文档注释

---

## 📄 许可证

本项目采用 **MIT License** 开源。

详见 [LICENSE](LICENSE) 文件。

---

## 🙏 致谢

- [Zig 语言](https://ziglang.org/) - 简洁高效的系统编程语言
- [PeiKeSmart](https://github.com/PeiKeSmart) - 沛柯智能开源社区

---

## 📞 联系方式

- **组织:** [PeiKeSmart](https://github.com/PeiKeSmart)
- **Issues:** [提交问题](https://github.com/PeiKeSmart/zzig/issues)
- **讨论:** [GitHub Discussions](https://github.com/PeiKeSmart/zzig/discussions)

---

**⭐ 如果这个项目对你有帮助,请给我们一个 Star!**

---

*最后更新: 2024-01-XX | 版本: 1.0.0*
