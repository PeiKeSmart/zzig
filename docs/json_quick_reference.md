# JSON 解析器快速参考

## 创建解析器

```zig
const zzig = @import("zzig");

// 默认配置（推荐）
const Parser = zzig.json.createParser();

// 嵌入式环境（零堆分配）
const EmbeddedParser = zzig.json.createEmbeddedParser();

// 桌面/服务器（SIMD 优化）
const DesktopParser = zzig.json.createDesktopParser();

// 自定义配置
const custom_config = zzig.json.Config{
    .index_type = u32,
    .enable_helpers = true,
    .compact_tokens = true,
    .max_depth = 128,
    .tiny_mode = false,
    .use_simd = true,
    .force_simd = false,
    .force_scalar = false,
};
const CustomParser = zzig.json.Jsmn(custom_config);
```

## 基本解析

### 栈分配（小型 JSON）

```zig
const Parser = zzig.json.createParser();
const json = "{\"key\":\"value\"}";

var tokens: [16]Parser.Token = undefined;
var parents: [16]Parser.IndexT = undefined;

const count = try Parser.parseTokens(&tokens, &parents, json);
```

### 混合模式（自动选择栈/堆）

```zig
const Parser = zzig.json.createParser();
const json = /* ... */;

var result = try Parser.parseHybrid(allocator, json);
defer result.deinit(allocator);

// 访问 token
for (0..result.count()) |i| {
    if (result.getToken(i)) |token| {
        const start = token.getStart();
        const end = token.getEnd();
        // ...
    }
}
```

## Token 操作

### 获取 Token 文本

```zig
const text = Parser.tokenText(token, json);
```

### 判断 Token 类型

```zig
switch (token.typ) {
    .Object => { /* 对象 */ },
    .Array => { /* 数组 */ },
    .String => { /* 字符串 */ },
    .Primitive => { /* 原始值 */ },
    else => { /* 未定义 */ },
}
```

### 跳过 Token

```zig
// 跳过当前 token 及其所有子元素
const next_idx = Parser.skipToken(&tokens, current_idx);
```

## 字符串处理

### 基本字符串提取

```zig
const str_tok = tokens[idx];
if (str_tok.typ == .String) {
    const str = Parser.tokenText(str_tok, json);
}
```

### 转义字符处理

```zig
const str_token = Parser.StringToken{
    .start = tokens[idx].start,
    .end = tokens[idx].end,
    .has_escapes = true,
};

var buffer: [256]u8 = undefined;
const unescaped = try Parser.parseStringToBuffer(str_token, json, &buffer);
```

## 数字解析

### 整数

```zig
const num_tok = tokens[idx];
const value = try Parser.parseInteger(num_tok, json);
```

### 浮点数

```zig
const num_tok = tokens[idx];
const value = try Parser.parseFloat(num_tok, json);
```

### 使用 NumberToken

```zig
const num_token = Parser.NumberToken{
    .start = tokens[idx].start,
    .end = tokens[idx].end,
    .is_float = true,
    .is_negative = false,
};

const value = try num_token.parse(json);        // f64
const int_val = try num_token.parseInteger(json); // i64
```

## 对象操作

### 查找字段

```zig
const Parser = zzig.json.createDesktopParser();
const json = "{\"name\":\"Alice\",\"age\":30}";

var tokens: [16]Parser.Token = undefined;
var parents: [16]Parser.IndexT = undefined;
const count = try Parser.parseTokens(&tokens, &parents, json);

// 查找 "age" 字段值
if (Parser.findObjectValue(&tokens, count, json, "age")) |idx| {
    const age = try Parser.parseInteger(tokens[idx], json);
}
```

### 遍历对象字段

```zig
const obj_tok = tokens[obj_idx];
if (obj_tok.typ == .Object) {
    var i = obj_idx + 1;
    var remaining = obj_tok.size;
    
    while (remaining > 0) {
        const key_tok = tokens[i];
        const val_tok = tokens[i + 1];
        
        const key = Parser.tokenText(key_tok, json);
        const val = Parser.tokenText(val_tok, json);
        
        std.debug.print("{s}: {s}\n", .{key, val});
        
        i += 2;
        remaining -= 2;
    }
}
```

### 使用辅助函数

```zig
const Parser = zzig.json.createDesktopParser();

const entries = Parser.getObjectEntries(&tokens, obj_idx);
for (entries.keys, entries.values) |key_tok, val_tok| {
    const key = Parser.tokenText(key_tok, json);
    const val = Parser.tokenText(val_tok, json);
    // ...
}
```

## 数组操作

### 遍历数组

```zig
const arr_tok = tokens[arr_idx];
if (arr_tok.typ == .Array) {
    const size = arr_tok.size;
    
    for (tokens[arr_idx+1..arr_idx+1+size], 0..) |elem_tok, i| {
        const elem = Parser.tokenText(elem_tok, json);
        std.debug.print("[{}]: {s}\n", .{i, elem});
    }
}
```

### 使用辅助函数

```zig
const Parser = zzig.json.createDesktopParser();

const items = Parser.getArrayItems(&tokens, arr_idx);
for (items, 0..) |item_tok, i| {
    const item = Parser.tokenText(item_tok, json);
    // ...
}
```

## 流式解析

### 分块处理

```zig
const Parser = zzig.json.createParser();

var tokens: [32]Parser.Token = undefined;
var parents: [32]Parser.IndexT = undefined;
var state: Parser.ParserState = .{ 
    .pos = 0, 
    .stack_top = 0, 
    .tokens_written = 0 
};

// 第一块
_ = Parser.parseChunk(&state, &tokens, &parents, chunk1, false) catch |err| {
    if (err == Parser.Error.NeedMoreInput) {
        // 正常 - 需要更多数据
    } else return err;
};

// 第二块
_ = Parser.parseChunk(&state, &tokens, &parents, chunk2, false) catch |err| {
    if (err == Parser.Error.NeedMoreInput) {
        // 正常 - 需要更多数据
    } else return err;
};

// 最后一块
const count = try Parser.parseChunk(&state, &tokens, &parents, chunk3, true);
```

### 重置解析状态

```zig
state.reset();
```

## 紧凑格式

### 压缩 Token

```zig
const Parser = zzig.json.createParser();

// 解析为标准 token
var std_tokens: [32]Parser.Token = undefined;
var parents: [32]Parser.IndexT = undefined;
const count = try Parser.parseTokens(&std_tokens, &parents, json);

// 压缩为紧凑格式
var compact: [32]Parser.CompactToken = undefined;
const compact_count = try Parser.compressTokens(&std_tokens, count, &compact);
```

### 访问紧凑 Token

```zig
const ct = compact[idx];

const start = Parser.compactGetStart(ct);
const len = Parser.compactGetLen(ct);
const typ = Parser.compactGetType(ct);
const is_key = Parser.compactIsKey(ct);
```

## 性能优化

### 估算 Token 数量

```zig
const estimated = Parser.estimateTokenCount(json);
const tokens = try allocator.alloc(Parser.Token, estimated);
defer allocator.free(tokens);
```

### 选择合适的索引类型

```zig
// 小型 JSON（< 64KB）
const config = zzig.json.Config{ .index_type = u16, /* ... */ };

// 中型 JSON（< 4GB）
const config = zzig.json.Config{ .index_type = u32, /* ... */ };

// 大型 JSON
const config = zzig.json.Config{ .index_type = usize, /* ... */ };
```

### 启用 SIMD

```zig
const config = zzig.json.Config{
    .use_simd = true,  // 自动检测
    // 或
    .force_simd = true,  // 强制启用
    // ...
};
```

## 错误处理

```zig
const count = Parser.parseTokens(&tokens, &parents, json) catch |err| {
    switch (err) {
        error.InvalidJson => {
            // 无效的 JSON 格式
        },
        error.OutOfTokens => {
            // token 缓冲区不足，增加缓冲区大小
        },
        error.InvalidString => {
            // 无效的字符串（未闭合引号或非法转义）
        },
        error.NeedMoreInput => {
            // 流式解析中需要更多输入
        },
        error.TooDeep => {
            // 嵌套层级超过 max_depth
        },
        error.CompactOverflow => {
            // 紧凑格式溢出（JSON 太大）
        },
        error.NumberParseError => {
            // 数字格式错误
        },
        else => return err,
    }
};
```

## 常见模式

### 解析 JSON 对象到结构体

```zig
const User = struct {
    id: i64,
    name: []const u8,
    age: i64,
};

fn parseUser(allocator: std.mem.Allocator, json: []const u8) !User {
    const Parser = zzig.json.createDesktopParser();
    
    var tokens: [32]Parser.Token = undefined;
    var parents: [32]Parser.IndexT = undefined;
    const count = try Parser.parseTokens(&tokens, &parents, json);
    
    var user: User = undefined;
    
    if (Parser.findObjectValue(&tokens, count, json, "id")) |idx| {
        user.id = try Parser.parseInteger(tokens[idx], json);
    }
    
    if (Parser.findObjectValue(&tokens, count, json, "name")) |idx| {
        user.name = Parser.tokenText(tokens[idx], json);
    }
    
    if (Parser.findObjectValue(&tokens, count, json, "age")) |idx| {
        user.age = try Parser.parseInteger(tokens[idx], json);
    }
    
    return user;
}
```

### 解析 JSON 数组到切片

```zig
fn parseIntArray(allocator: std.mem.Allocator, json: []const u8) ![]i64 {
    const Parser = zzig.json.createParser();
    
    var tokens: [128]Parser.Token = undefined;
    var parents: [128]Parser.IndexT = undefined;
    const count = try Parser.parseTokens(&tokens, &parents, json);
    
    if (count == 0 or tokens[0].typ != .Array) {
        return error.InvalidJson;
    }
    
    const arr_size = tokens[0].size;
    const result = try allocator.alloc(i64, arr_size);
    
    for (tokens[1..1+arr_size], 0..) |tok, i| {
        result[i] = try Parser.parseInteger(tok, json);
    }
    
    return result;
}
```

### 验证 JSON 格式

```zig
fn isValidJson(json: []const u8) bool {
    const Parser = zzig.json.createParser();
    
    var tokens: [1]Parser.Token = undefined;
    var parents: [1]Parser.IndexT = undefined;
    
    _ = Parser.parseTokens(&tokens, &parents, json) catch {
        return false;
    };
    
    return true;
}
```

## 配置对照表

| 场景 | index_type | compact | simd | helpers | tiny_mode |
|------|------------|---------|------|---------|-----------|
| 嵌入式 | u16/u32 | ✓ | ✗ | ✗ | ✓ |
| 移动端 | u32 | ✓ | auto | ✓ | ✗ |
| 桌面 | usize | ✗ | ✓ | ✓ | ✗ |
| 服务器 | usize | ✗ | ✓ | ✓ | ✗ |
| 默认 | usize | ✓ | auto | ✓ | ✗ |

## 性能指标参考

| JSON 大小 | 标准 Token | 紧凑 Token | 内存节省 |
|-----------|------------|------------|----------|
| 1KB | ~640 字节 | ~256 字节 | 60% |
| 10KB | ~6.4KB | ~2.5KB | 61% |
| 100KB | ~64KB | ~25KB | 61% |

| 操作 | SIMD | 标量 | 提升 |
|------|------|------|------|
| 字符串解析 | 100ms | 130ms | 30% |
| 大型 JSON | 500ms | 700ms | 40% |
| 小型 JSON | 10ms | 11ms | 10% |

## 快速诊断

### Token 数量不够

```zig
// 增加缓冲区大小
var tokens: [256]Parser.Token = undefined;

// 或使用混合模式
var result = try Parser.parseHybrid(allocator, json);
```

### JSON 太大无法使用紧凑格式

```zig
// 使用标准格式
const config = zzig.json.Config{
    .compact_tokens = false,
    // ...
};
```

### 嵌套太深

```zig
// 增加最大深度
const config = zzig.json.Config{
    .max_depth = 2048,
    // ...
};
```

### 流式解析中断

```zig
// 确保最后一块标记为 final
const count = try Parser.parseChunk(&state, &tokens, &parents, last_chunk, true);
//                                                                           ^^^^
```

## 性能基准测试结果

### 实测数据（Windows x86_64, Debug 模式）

| JSON 大小 | 原版解析器 | 零分配优化 | 性能提升 | 堆分配减少 |
|----------|-----------|-----------|---------|----------|
| 小型 (261B) | 5.32 μs | 2.04 μs | **2.5x** | 0 → 0 |
| 中型 (5KB) | 128.65 μs | 38.98 μs | **3.3x** | 100% |
| 大型 (64KB) | 1249.39 μs | 467.12 μs | **2.7x** | 100% |

### 吞吐量对比

| JSON 大小 | 原版吞吐量 | 零分配吞吐量 | 提升 |
|----------|-----------|-------------|------|
| 小型 (261B) | 48 MB/s | 122 MB/s | **2.5x** |
| 中型 (5KB) | 39 MB/s | 128 MB/s | **3.3x** |
| 大型 (64KB) | 49 MB/s | 132 MB/s | **2.7x** |

### 内存占用对比

| Token 格式 | 单个 Token 大小 | 1000 个 Token | 内存节省 |
|-----------|---------------|-------------|---------|
| 标准格式 | 32 字节 | 31 KB | - |
| 紧凑格式 | 4 字节 | 3 KB | **87.5%** |

**注意：**
- 紧凑格式有性能开销（比标准格式慢 7-14%）
- 紧凑格式限制：JSON < 1MB，token 长度 < 256
- 超出限制时自动回退到标准格式

### 运行基准测试

```bash
zig build json-bench  # 完整性能测试
zig build json-large  # 大型 JSON 回退测试
```

## 更多资源

- 完整教程：[json_usage.md](json_usage.md)
- 基础示例：`examples/json_example.zig`
- 高级示例：`examples/json_advanced_example.zig`
- 性能基准：`examples/json_performance_benchmark.zig`
- 源代码：`src/json/jsmn_zig.zig`
- 原始项目：https://github.com/Ferki-git-creator/jsmn_zig

