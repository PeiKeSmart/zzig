# 迁移指南

## DebugLog 和 XTrace 模块移除

**版本：** v0.2.0+  
**日期：** 2025-11-01

### 📢 变更说明

为了简化 API 并提供更强大的日志功能，我们移除了 `DebugLog` 和 `XTrace` 模块，统一使用功能更完善的 `Logger` 模块。

### 🔄 迁移对照表

#### DebugLog → Logger

**旧代码 (DebugLog):**
```zig
const zzig = @import("zzig");

// 打印字符串
zzig.DebugLog.PrintString("Hello: {s}\n", "World");

// 打印数字
zzig.DebugLog.PrintNumber("Count: {d}\n", 42);
```

**新代码 (Logger):**
```zig
const zzig = @import("zzig");

// 使用 debug 级别（开发时）
zzig.Logger.debug("Hello: {s}", .{"World"});
zzig.Logger.debug("Count: {d}", .{42});

// 或使用 print（简单输出，不带时间戳）
zzig.Logger.print("Hello: {s}\n", .{"World"});
zzig.Logger.print("Count: {d}\n", .{42});
```

#### 功能对比

| 功能 | DebugLog | Logger |
|------|----------|--------|
| 基础打印 | ✅ | ✅ |
| 格式化参数 | ⚠️ 限制（单一类型） | ✅ 完全支持 `anytype` |
| 日志级别 | ❌ | ✅ debug/info/warn/err |
| 时间戳 | ❌ | ✅ 纳秒精度 |
| 彩色输出 | ❌ | ✅ 级别色彩 |
| 跨平台中文 | ❌ | ✅ Windows 特殊处理 |
| 级别过滤 | ❌ | ✅ `setLevel()` |

### 📝 详细迁移步骤

#### 1. 替换 import（如果直接导入）

```zig
// 旧代码
const DebugLog = @import("zzig").DebugLog;

// 新代码
const Logger = @import("zzig").Logger;
```

#### 2. 替换函数调用

##### 简单字符串打印

```zig
// 旧代码
DebugLog.PrintString("Message: {s}\n", message);

// 新代码 - 选项 1: 使用 debug 级别
Logger.debug("Message: {s}", .{message});

// 新代码 - 选项 2: 使用 print（无时间戳）
Logger.print("Message: {s}\n", .{message});
```

##### 数字打印

```zig
// 旧代码
DebugLog.PrintNumber("Count: {d}\n", count);

// 新代码 - 选项 1: 使用 debug 级别
Logger.debug("Count: {d}", .{count});

// 新代码 - 选项 2: 使用 print
Logger.print("Count: {d}\n", .{count});
```

##### 混合类型（新功能）

```zig
// Logger 支持多个不同类型的参数
Logger.info("User {s} has {d} items", .{ username, item_count });
Logger.warn("Error code: 0x{x:0>4}", .{error_code});
```

#### 3. 利用新功能

##### 添加日志级别

```zig
// 开发调试
Logger.debug("详细调试信息: {any}", .{data_structure});

// 正常运行信息
Logger.info("服务启动成功，端口: {d}", .{port});

// 警告信息
Logger.warn("内存使用率: {d}%", .{memory_usage});

// 错误信息
Logger.err("数据库连接失败: {s}", .{err_msg});
```

##### 生产环境级别过滤

```zig
pub fn main() void {
    // 生产环境只显示 info 及以上级别
    Logger.setLevel(.info);
    
    Logger.debug("这条不会显示", .{});  // 被过滤
    Logger.info("这条会显示", .{});     // ✅
    Logger.warn("这条会显示", .{});     // ✅
}
```

### ⚠️ 注意事项

1. **参数包装**：Logger 的参数需要用 `.{...}` 包装（匿名元组）
   ```zig
   // ❌ 错误
   Logger.info("Value: {d}", value);
   
   // ✅ 正确
   Logger.info("Value: {d}", .{value});
   ```

2. **换行符**：`Logger.debug/info/warn/err` 会自动添加换行，无需 `\n`
   ```zig
   // DebugLog 需要手动换行
   DebugLog.PrintString("Hello{s}\n", "!");
   
   // Logger 自动换行
   Logger.info("Hello{s}", .{"!"});
   ```

3. **简单打印**：如果不需要时间戳和级别，使用 `Logger.print`
   ```zig
   Logger.print("纯文本输出\n", .{});
   ```

### 🚀 迁移检查清单

迁移完成后，请确认：

- [ ] 所有 `DebugLog.PrintString` 调用已替换
- [ ] 所有 `DebugLog.PrintNumber` 调用已替换
- [ ] 参数已正确包装在 `.{...}` 中
- [ ] 不需要的 `\n` 已移除（如果使用 `debug/info/warn/err`）
- [ ] 编译通过 (`zig build`)
- [ ] 测试通过 (`zig build test`)
- [ ] 运行验证输出符合预期

### 📚 更多信息

- **Logger 完整文档**：[docs/logger_usage.md](logger_usage.md)
- **示例代码**：[examples/logger_example.zig](../examples/logger_example.zig)

### ❓ 常见问题

**Q: 为什么移除 DebugLog？**  
A: Logger 功能更强大且完全覆盖 DebugLog 的功能，保留两者会造成 API 混淆和维护负担。

**Q: XTrace 去哪了？**  
A: XTrace 一直是空实现，未来如需专门的追踪功能会重新设计。

**Q: 能否保留兼容层？**  
A: 由于两者 API 差异较大且影响面小（当前无使用），直接迁移更清晰。

**Q: 性能有影响吗？**  
A: Logger 使用 ArenaAllocator 批量分配，性能优于 DebugLog。且支持级别过滤，生产环境可关闭 debug 输出。

---

**如有迁移问题，请提交 Issue 或联系维护者。**
