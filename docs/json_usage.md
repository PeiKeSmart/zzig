# JSON 解析器使用教程

## 概述

ZZig JSON 解析器是一个高性能、低内存占用的 JSON 解析库，基于 [jsmn_zig](https://github.com/Ferki-git-creator/jsmn_zig) 实现。它提供了以下特性：

- **流式解析**：支持分块处理大文件或网络流
- **紧凑格式**：可选的紧凑 token 格式，节省 60%+ 内存
- **SIMD 优化**：在支持的平台上自动启用 SIMD 加速
- **零分配模式**：嵌入式环境可完全使用栈内存
- **混合模式**：自动在栈和堆之间选择最优分配策略
- **跨平台**：支持 x86/x64/ARM/AArch64 等多种架构

## 快速开始

### 基本用法

```zig
const std = @import("std");
const zzig = @import("zzig");

pub fn main() !void {
    // 1. 创建解析器（使用默认配置）
    const Parser = zzig.json.createParser();

    // 2. 准备 JSON 数据
    const json = "{\"name\":\"Alice\",\"age\":30}";

    // 3. 准备 token 缓冲区
    var tokens: [16]Parser.Token = undefined;
    var parents: [16]Parser.IndexT = undefined;

    // 4. 执行解析
    const count = try Parser.parseTokens(&tokens, &parents, json);

    // 5. 访问解析结果
    for (tokens[0..count]) |tok| {
        const text = Parser.tokenText(tok, json);
        std.debug.print("{s}\n", .{text});
    }
}
```

### 使用混合模式（推荐）

混合模式会自动选择栈或堆分配，简化内存管理：

```zig
const Parser = zzig.json.createParser();
const json = "{\"key\":\"value\"}";

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// 自动选择最优分配策略
var result = try Parser.parseHybrid(allocator, json);
defer result.deinit(allocator);

// 访问 token
for (0..result.count()) |i| {
    if (result.getToken(i)) |token| {
        const start = token.getStart();
        const end = token.getEnd();
        std.debug.print("{s}\n", .{json[start..end]});
    }
}
```

## 核心概念

### Token 类型

JSON 解析器识别以下 token 类型：

- **Object**：JSON 对象 `{...}`
- **Array**：JSON 数组 `[...]`
- **String**：字符串 `"text"`
- **Primitive**：原始值（数字、布尔值、null）

### Token 结构

```zig
pub const Token = struct {
    typ: TokenType,      // token 类型
    start: IndexT,       // 起始位置
    end: IndexT,         // 结束位置
    size: IndexT,        // 子元素数量（仅对象/数组）
};
```

### 紧凑 Token

紧凑格式将 token 压缩到 32 位整数，显著减少内存占用：

```zig
// 标准 Token: 通常 16-32 字节
// 紧凑 Token: 固定 4 字节

pub const CompactToken = u32;
```

## 配置选项

### 预定义配置

#### 1. 默认配置（推荐）

```zig
const Parser = zzig.json.createParser();
// - 紧凑 token 格式
// - 自动 SIMD 检测
// - 完整功能集
```

#### 2. 嵌入式配置

```zig
const Parser = zzig.json.createEmbeddedParser();
// - 紧凑格式
// - 禁用 SIMD
// - Tiny 模式（最小内存）
// - 无辅助函数
```

#### 3. 桌面/服务器配置

```zig
const Parser = zzig.json.createDesktopParser();
// - 标准 token 格式
// - 启用 SIMD
// - 完整辅助函数
```

### 自定义配置

```zig
const custom_config = zzig.json.Config{
    .index_type = u32,           // 索引类型（usize/u32/u16）
    .enable_helpers = true,      // 辅助函数
    .compact_tokens = true,      // 紧凑格式
    .max_depth = 128,            // 最大嵌套深度
    .tiny_mode = false,          // Tiny 模式
    .use_simd = true,            // SIMD 优化
    .force_simd = false,         // 强制 SIMD
    .force_scalar = false,       // 强制标量
};

const Parser = zzig.json.Jsmn(custom_config);
```

## 常见用法

### 1. 字符串解析与转义

```zig
const Parser = zzig.json.createParser();
const json = "\"Hello\\nWorld\\t\\u4E2D\\u6587\"";

var tokens: [8]Parser.Token = undefined;
var parents: [8]Parser.IndexT = undefined;
const count = try Parser.parseTokens(&tokens, &parents, json);

// 处理转义字符
const str_token = Parser.StringToken{
    .start = tokens[0].start,
    .end = tokens[0].end,
    .has_escapes = true,
};

var buffer: [256]u8 = undefined;
const unescaped = try Parser.parseStringToBuffer(str_token, json, &buffer);
std.debug.print("{s}\n", .{unescaped}); // 输出: Hello\nWorld\t中文
```

### 2. 数字解析

```zig
const Parser = zzig.json.createParser();

// 整数
const int_json = "42";
var tokens: [4]Parser.Token = undefined;
var parents: [4]Parser.IndexT = undefined;
_ = try Parser.parseTokens(&tokens, &parents, int_json);
const int_val = try Parser.parseInteger(tokens[0], int_json);

// 浮点数
const float_json = "3.14159";
_ = try Parser.parseTokens(&tokens, &parents, float_json);
const float_val = try Parser.parseFloat(tokens[0], float_json);
```

### 3. 对象字段查找

```zig
const Parser = zzig.json.createDesktopParser();
const json = "{\"name\":\"Bob\",\"age\":25,\"active\":true}";

var tokens: [16]Parser.Token = undefined;
var parents: [16]Parser.IndexT = undefined;
const count = try Parser.parseTokens(&tokens, &parents, json);

// 查找 "age" 字段
if (Parser.findObjectValue(&tokens, count, json, "age")) |idx| {
    const age = try Parser.parseInteger(tokens[idx], json);
    std.debug.print("Age: {}\n", .{age});
}
```

### 4. 数组遍历

```zig
const Parser = zzig.json.createParser();
const json = "[1,2,3,\"four\",true,null]";

var tokens: [16]Parser.Token = undefined;
var parents: [16]Parser.IndexT = undefined;
const count = try Parser.parseTokens(&tokens, &parents, json);

// 第一个 token 是数组
if (tokens[0].typ == .Array) {
    const size = tokens[0].size;
    std.debug.print("数组长度: {}\n", .{size});

    // 遍历元素
    for (tokens[1..1+size], 0..) |tok, i| {
        const text = Parser.tokenText(tok, json);
        std.debug.print("元素[{}]: {s}\n", .{i, text});
    }
}
```

### 5. 流式解析（分块处理）

```zig
const Parser = zzig.json.createParser();

var tokens: [32]Parser.Token = undefined;
var parents: [32]Parser.IndexT = undefined;
var state: Parser.ParserState = .{ 
    .pos = 0, 
    .stack_top = 0, 
    .tokens_written = 0 
};

// 第一块数据
const chunk1 = "{\"message\":\"Hello";
_ = Parser.parseChunk(&state, &tokens, &parents, chunk1, false) catch |err| {
    if (err == Parser.Error.NeedMoreInput) {
        // 正常情况 - 需要更多数据
    } else return err;
};

// 第二块数据
const chunk2 = " World\"}";
const count = try Parser.parseChunk(&state, &tokens, &parents, chunk2, true);

// 使用完整 JSON 提取内容
const full_json = "{\"message\":\"Hello World\"}";
for (tokens[0..count]) |tok| {
    const text = Parser.tokenText(tok, full_json);
    std.debug.print("{s}\n", .{text});
}
```

### 6. 嵌套结构解析

```zig
const Parser = zzig.json.createParser();
const json =
    \\{
    \\  "user": {
    \\    "id": 123,
    \\    "name": "Charlie"
    \\  }
    \\}
;

var result = try Parser.parseHybrid(allocator, json);
defer result.deinit(allocator);

// 遍历所有 token
for (0..result.count()) |i| {
    if (result.getToken(i)) |tok| {
        const start = tok.getStart();
        const end = tok.getEnd();
        const text = json[start..end];
        std.debug.print("Token[{}]: {s}\n", .{i, text});
    }
}
```

## 高级特性

### 紧凑格式优化

```zig
const Parser = zzig.json.createParser();
const json = "{\"key\":\"value\"}";

// 解析为标准 token
var std_tokens: [16]Parser.Token = undefined;
var parents: [16]Parser.IndexT = undefined;
const count = try Parser.parseTokens(&std_tokens, &parents, json);

// 压缩为紧凑格式
var compact: [16]Parser.CompactToken = undefined;
const compact_count = try Parser.compressTokens(&std_tokens, count, &compact);

std.debug.print("标准大小: {} 字节\n", .{@sizeOf(Parser.Token) * count});
std.debug.print("紧凑大小: {} 字节\n", .{@sizeOf(Parser.CompactToken) * compact_count});
```

### 性能估算

```zig
const Parser = zzig.json.createParser();
const json = /* 大型 JSON */;

// 估算所需 token 数量
const estimated = Parser.estimateTokenCount(json);
std.debug.print("预估需要 {} 个 token\n", .{estimated});

// 根据估算分配缓冲区
const tokens = try allocator.alloc(Parser.Token, estimated);
defer allocator.free(tokens);
```

### 辅助函数

```zig
const Parser = zzig.json.createDesktopParser();

// 跳过整个 token（包括子元素）
const next_idx = Parser.skipToken(&tokens, current_idx);

// 获取数组项
const items = Parser.getArrayItems(&tokens, array_idx);

// 获取对象条目
const entries = Parser.getObjectEntries(&tokens, object_idx);
```

## 错误处理

```zig
const Parser = zzig.json.createParser();

const result = Parser.parseTokens(&tokens, &parents, json) catch |err| {
    switch (err) {
        error.InvalidJson => std.debug.print("无效的 JSON 格式\n", .{}),
        error.OutOfTokens => std.debug.print("token 缓冲区不足\n", .{}),
        error.InvalidString => std.debug.print("无效的字符串\n", .{}),
        error.NeedMoreInput => std.debug.print("需要更多输入数据\n", .{}),
        error.TooDeep => std.debug.print("嵌套层级过深\n", .{}),
        else => return err,
    }
};
```

## 性能优化建议

### 1. 选择合适的配置

- **嵌入式/ARM 设备**：使用 `createEmbeddedParser()`
- **桌面/服务器**：使用 `createDesktopParser()`
- **通用场景**：使用 `createParser()`

### 2. 内存分配策略

```zig
// 小型 JSON - 使用栈分配
var tokens: [64]Parser.Token = undefined;

// 大型 JSON - 使用混合模式
var result = try Parser.parseHybrid(allocator, json);
defer result.deinit(allocator);

// 已知 token 数量 - 预分配
const estimated = Parser.estimateTokenCount(json);
const tokens = try allocator.alloc(Parser.Token, estimated);
```

### 3. 流式处理大文件

```zig
var state: Parser.ParserState = .{ .pos = 0, .stack_top = 0, .tokens_written = 0 };

while (try readChunk(&buffer)) |chunk| {
    const is_final = chunk.is_last;
    _ = try Parser.parseChunk(&state, &tokens, &parents, chunk.data, is_final);
}
```

### 4. SIMD 优化

```zig
// 显式启用 SIMD（仅在支持的平台上）
const config = zzig.json.Config{
    .use_simd = true,
    // ... 其他配置
};
const Parser = zzig.json.Jsmn(config);
```

## 平台支持

| 平台 | 架构 | SIMD 支持 | 推荐配置 |
|------|------|-----------|----------|
| Windows | x86_64 | ✓ | Desktop |
| Linux | x86_64 | ✓ | Desktop |
| macOS | x86_64/ARM64 | ✓ | Desktop |
| 嵌入式 | ARM Cortex-M | ✗ | Embedded |
| Raspberry Pi | ARM/AArch64 | ✓/✗ | Custom |

## 常见问题

### Q: 如何判断使用栈还是堆分配？

**A**: 使用 `parseHybrid()` 自动选择，或遵循以下规则：
- JSON < 1KB → 栈分配
- JSON >= 1KB → 堆分配
- 嵌入式环境 → 始终栈分配

### Q: 紧凑格式有什么限制？

**A**: 紧凑格式限制：
- JSON 大小 < 1MB（20 位地址）
- Token 长度 < 256（8 位长度）
- 超出限制时会自动回退到标准格式

### Q: SIMD 优化有多大提升？

**A**: 根据实际基准测试（Windows x86_64, Debug 模式）：

**零分配优化实测数据：**
- 小型 JSON (261B): 5.32 μs → 2.04 μs，**2.5x 加速**，堆分配 0 → 0
- 中型 JSON (5KB): 128.65 μs → 38.98 μs，**3.3x 加速**，堆分配 100% 减少
- 大型 JSON (64KB): 1249.39 μs → 467.12 μs，**2.7x 加速**，堆分配 100% 减少

**紧凑格式：**
- 内存节省：87.5%（4 字节 vs 32 字节/token）
- 性能开销：比标准格式慢 7-14%（打包解包成本）
- 限制：JSON 需 < 1MB，token 长度 < 256

**注意：** 当前 SIMD 功能尚未实现，上述数据为零分配优化效果。

运行基准测试：
```bash
zig build json-bench
```

### Q: 如何处理超大 JSON 文件？

**A**: 使用流式解析：
```zig
var state: Parser.ParserState = .{ .pos = 0, .stack_top = 0, .tokens_written = 0 };
// 分块读取和解析
```

### Q: 线程安全吗？

**A**: 解析过程本身是线程安全的（无共享状态），但需确保：
- 每个线程使用独立的 token 缓冲区
- 每个线程使用独立的解析器状态

## 完整示例

参见 `examples/` 目录：
- `json_example.zig` - 基础用法示例
- `json_advanced_example.zig` - 高级特性示例

运行示例：
```bash
zig build json-demo         # 基础示例
zig build json-advanced     # 高级示例
```

## API 参考

完整 API 文档请参见：[json_quick_reference.md](json_quick_reference.md)

## 许可证

本模块基于 [jsmn_zig](https://github.com/Ferki-git-creator/jsmn_zig) 项目。
