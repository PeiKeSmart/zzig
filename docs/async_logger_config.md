# 异步日志配置文件支持

## 功能概述

异步日志器现在支持通过 JSON 配置文件动态管理参数，让生产环境的日志配置更加灵活可控。

## 核心特性

✅ **自动生成默认配置** - 配置文件不存在时自动创建  
✅ **热配置更新** - 修改配置文件后重启即可生效  
✅ **完整参数说明** - 配置文件内含中文注释说明  
✅ **类型安全验证** - 自动验证参数合法性（如队列容量必须是 2 的幂次）

---

## 快速开始

### 1. 使用配置文件初始化日志器

```zig
const std = @import("std");
const zzig = @import("zzig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 从配置文件初始化 (不存在则自动生成)
    var logger = try zzig.AsyncLogger.AsyncLogger.initFromConfigFile(
        allocator,
        "logger_config.json"
    );
    defer logger.deinit();

    // 使用日志器
    logger.info("应用启动", .{});
    logger.debug("调试信息: {d}", .{42});
}
```

### 2. 配置文件示例

```json
{
  "queue_capacity": 16384,
  "_queue_capacity_comment": "环形队列容量,必须是2的幂次 (1024/2048/4096/8192/16384/32768/65536)",

  "min_level": "info",
  "_min_level_comment": "最低日志级别 (debug/info/warn/err)",

  "output_target": "console",
  "_output_target_comment": "输出目标 (console/file/both)",

  "log_file_path": "logs/app.log",
  "_log_file_path_comment": "日志文件路径 (当 output_target 为 file 或 both 时使用)",

  "batch_size": 100,
  "_batch_size_comment": "批处理大小 (工作线程每次处理的最大消息数)",

  "drop_rate_warning_threshold": 10.0,
  "_drop_rate_warning_threshold_comment": "丢弃告警阈值 (0-100,超过此丢弃率时打印警告)",

  "enable_statistics": true,
  "_enable_statistics_comment": "是否启用性能监控统计"
}
```

---

## 配置参数详解

### `queue_capacity` (队列容量)

- **类型**: 整数 (u32)
- **默认值**: 16384
- **约束**: 必须是 2 的幂次 (1024, 2048, 4096, 8192, 16384, 32768, 65536)
- **说明**: 环形队列的最大容量，影响突发流量的缓冲能力

**调整建议**:
- **低流量场景** (< 10K QPS): 1024 - 4096
- **中流量场景** (10K - 100K QPS): 8192 - 16384
- **高流量场景** (> 100K QPS): 32768 - 65536

### `min_level` (最低日志级别)

- **类型**: 枚举字符串
- **可选值**: `"debug"` | `"info"` | `"warn"` | `"err"`
- **默认值**: `"debug"`
- **说明**: 低于此级别的日志会被过滤，不进入队列

**级别说明**:
- `debug`: 开发调试信息（最详细）
- `info`: 普通运行信息
- `warn`: 警告信息
- `err`: 错误信息（最严格）

**调整建议**:
- **开发环境**: `debug` (查看所有日志)
- **测试环境**: `info` (过滤调试日志)
- **生产环境**: `warn` (只记录异常)
- **高负载场景**: `err` (仅记录错误)

### `output_target` (输出目标)

- **类型**: 枚举字符串
- **可选值**: `"console"` | `"file"` | `"both"`
- **默认值**: `"console"`
- **说明**: 日志输出位置

**性能对比**:
- `console`: 控制台输出 (~2ms/条, 适合开发调试)
- `file`: 文件输出 (~20μs/条, **推荐生产环境使用**)
- `both`: 同时输出 (综合两者延迟)

### `log_file_path` (日志文件路径)

- **类型**: 字符串
- **默认值**: `"logs/app.log"`
- **说明**: 当 `output_target` 为 `file` 或 `both` 时的文件路径
- **注意**: 目录不存在时会自动创建

### `batch_size` (批处理大小)

- **类型**: 整数 (u32)
- **默认值**: 100
- **范围**: 50 - 200
- **说明**: 工作线程每次从队列取出的最大消息数

**调整建议**:
- **低延迟优先**: 50 (更快响应)
- **高吞吐优先**: 200 (减少原子操作开销)
- **平衡模式**: 100 (推荐)

### `drop_rate_warning_threshold` (丢弃告警阈值)

- **类型**: 浮点数 (f32)
- **默认值**: 10.0
- **范围**: 0.0 - 100.0
- **说明**: 丢弃率超过此值时触发警告（未来版本可能实现动态降级）

### `enable_statistics` (性能统计开关)

- **类型**: 布尔值
- **默认值**: `true`
- **说明**: 是否记录处理数、丢弃数等统计信息
- **性能影响**: 极小 (仅原子计数器开销 ~5ns)

---

## 使用场景与最佳实践

### 场景 1: 开发环境调试

```json
{
  "queue_capacity": 4096,
  "min_level": "debug",
  "output_target": "console",
  "batch_size": 50
}
```

**特点**: 队列小、全日志、控制台输出、快速响应

### 场景 2: 生产环境 (常规流量)

```json
{
  "queue_capacity": 16384,
  "min_level": "info",
  "output_target": "file",
  "log_file_path": "/var/log/myapp/app.log",
  "batch_size": 100,
  "drop_rate_warning_threshold": 5.0
}
```

**特点**: 中等队列、过滤 DEBUG、文件输出 (快 100 倍)、监控丢弃率

### 场景 3: 高负载平台 (百万设备)

```json
{
  "queue_capacity": 32768,
  "min_level": "warn",
  "output_target": "file",
  "log_file_path": "/mnt/fast-disk/logs/critical.log",
  "batch_size": 200,
  "drop_rate_warning_threshold": 1.0
}
```

**特点**: 大队列、仅警告/错误、文件输出、大批处理、严格监控

### 场景 4: 调试特定问题

```json
{
  "queue_capacity": 8192,
  "min_level": "debug",
  "output_target": "both",
  "batch_size": 50
}
```

**特点**: 同时输出到控制台和文件，便于实时查看和事后分析

---

## 运行时监控

### 获取统计信息

```zig
const stats = logger.getStats();
std.debug.print("已处理: {d} 条\n", .{stats.processed_count});
std.debug.print("已丢弃: {d} 条\n", .{stats.dropped_count});
std.debug.print("队列剩余: {d} 条\n", .{stats.queue_size});

// 计算丢弃率
const total = stats.processed_count + stats.dropped_count;
if (total > 0) {
    const drop_rate = @as(f64, @floatFromInt(stats.dropped_count)) /
                      @as(f64, @floatFromInt(total)) * 100.0;
    std.debug.print("丢弃率: {d:.2}%\n", .{drop_rate});
}
```

### 动态调整日志级别

```zig
// 高负载时自动降级
if (stats.dropped_count > 1000) {
    logger.setLevel(.warn); // 只记录警告和错误
    std.debug.print("⚠️  检测到丢弃过多，已自动调整到 WARN 级别\n", .{});
}
```

---

## 配置文件管理

### 自动生成

首次运行时，如果 `logger_config.json` 不存在，会自动生成默认配置：

```
⚠️  配置文件不存在,生成默认配置: logger_config.json
✅ 默认配置已生成
```

### 手动创建

也可以手动创建简化版配置（注释字段可省略）：

```json
{
  "queue_capacity": 8192,
  "min_level": "info",
  "output_target": "console",
  "log_file_path": "logs/app.log",
  "batch_size": 100,
  "drop_rate_warning_threshold": 10.0,
  "enable_statistics": true
}
```

### 配置验证

加载时会自动验证：
- `queue_capacity` 不是 2 的幂次 → 回退到 16384
- `min_level` 值非法 → 返回错误
- `output_target` 值非法 → 返回错误

---

## 性能影响

配置文件加载**仅在初始化时执行一次**，运行时性能不受影响：

| 操作 | 耗时 | 说明 |
|------|------|------|
| 配置文件加载 | ~500μs | 仅初始化时 |
| 日志记录 (队列插入) | ~85ns | 运行时性能 |
| 统计计数器更新 | ~5ns | 可忽略 |

---

## 常见问题

### Q1: 修改配置后不生效？

**A**: 需要重启应用。配置在 `initFromConfigFile` 时加载，运行时不会重新读取。

### Q2: 队列容量设置为 10000 会怎样？

**A**: 自动向上取整到最近的 2 的幂次 (16384)，并打印警告：

```
⚠️  queue_capacity 必须是 2 的幂次,使用默认值 16384
```

### Q3: 配置文件路径可以自定义吗？

**A**: 可以，调用时传入路径：

```zig
var logger = try AsyncLogger.initFromConfigFile(allocator, "config/my_logger.json");
```

### Q4: 能否在运行时动态修改队列大小？

**A**: 不行。队列容量在初始化时分配，运行时不可更改。但可以动态调整 `min_level` 来减少日志量。

---

## 示例程序

运行配置示例：

```bash
# 自动生成配置并运行
zig build config-demo -Doptimize=ReleaseFast

# 修改 logger_config.json 后重新运行
zig build config-demo -Doptimize=ReleaseFast
```

示例代码: `examples/async_logger_with_config.zig`

---

## API 参考

### 配置加载

```zig
pub fn loadOrCreate(
    allocator: std.mem.Allocator,
    config_path: []const u8
) !AsyncLoggerConfig
```

- **自动生成**: 文件不存在时生成默认配置
- **异常处理**: 文件格式错误时返回错误

### 从配置初始化日志器

```zig
pub fn initFromConfigFile(
    allocator: std.mem.Allocator,
    config_path: []const u8
) !*AsyncLogger
```

- **内部流程**: 加载配置 → 打印参数 → 初始化日志器
- **返回**: 日志器指针，需调用 `deinit()` 释放

---

## 总结

配置文件支持让异步日志器更适合生产环境：

✅ **灵活调整** - 无需重新编译，修改配置即可调整行为  
✅ **自动化** - 首次运行自动生成，零配置启动  
✅ **可观测** - 配置加载时打印参数，便于审计  
✅ **类型安全** - 编译期和运行期双重验证  

对于百万设备平台，推荐：

```json
{
  "queue_capacity": 32768,
  "min_level": "warn",
  "output_target": "file",
  "batch_size": 200
}
```

配合监控系统实时调整 `min_level`，即可在性能和日志完整性间取得最佳平衡！🚀
