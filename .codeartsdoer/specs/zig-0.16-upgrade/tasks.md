# Zig 0.16 升级 — 编码任务清单

## 1. 构建系统适配

- [ ] 将 `build.zig` 中 `min_zig_string` 从 `"0.15.2"` 更新为 `"0.16.0"`
- [ ] 移除 `build.zig` 中基于 `current_zig.minor` 的 `switch` 版本分发逻辑，删除 `version_15` 命名空间包裹，将 `version_15.build()` 函数体直接提升为 `build()` 函数体
- [ ] 将 `version_15` 内部的 `const Build`、`const Module`、`const OptimizeMode` 类型别名提升到 `build.zig` 文件顶层
- [ ] 保留 `comptime` 块中对最低 Zig 版本的检查逻辑，确认版本号已更新为 0.16.0，使用 `.lt` 语义允许 patch 版本向上兼容
- [ ] 适配 `build.zig` 中 Build 系统 API 调用到 Zig 0.16 新签名：
  - 检查并适配 `b.addModule(name, .{ .root_source_file = ... })`
  - 检查并适配 `b.createModule(.{ .root_source_file, .target, .optimize })`
  - 检查并适配 `module.addImport(name, dep)`
  - 检查并适配 `b.addExecutable(.{ .name, .root_module })`
  - 检查并适配 `b.addTest(.{ .name, .root_module })`
  - 检查并适配 `b.addObject(.{ .name, .root_module })`
  - 检查并适配 `b.addRunArtifact(artifact)`
  - 检查并适配 `b.addInstallDirectory(.{ .source_dir, .install_dir, .install_subdir })`
  - 检查并适配 `lib.getEmittedDocs()`
- [ ] 确认 `build.zig.zon` 中 `minimum_zig_version` 已为 `"0.16.0"`（无需变更则跳过）
- [ ] 验证 `build.zig` 中无残留 `version_15`、`minor == 15`、`"0.15"` 引用

## 2. 并发与同步 API 迁移

- [ ] 适配 `src/console/console.zig` 中 `std.once` 调用：将 `std.once(fn)` + `call()` 模式迁移到 Zig 0.16 的 `std.Once` API（若 `std.once` 被移除则使用 `std.atomic.Value(bool)` + `cmpxchgStrong` 回退方案）
- [ ] 适配 `src/logs/async_logger.zig` 中 `std.atomic.Value` 调用：更新 `std.atomic.Value(usize)`、`std.atomic.Value(bool)`、`std.atomic.Value(u64)`、`std.atomic.Value(i64)` 的 `.init()` 及方法调用
- [ ] 适配 `src/logs/dynamic_queue.zig` 中 `std.atomic.Value(bool)` 的 `.init()` 调用
- [ ] 适配 `src/logs/mpmc_queue.zig` 中 `std.atomic.Value(usize)` 的 `.init()`、`.load()`、`.cmpxchgWeak()` 调用
- [ ] 适配 `src/logs/rotation_manager.zig` 中 `std.atomic.Value(usize)`、`std.atomic.Value(bool)`、`std.atomic.Value(u64)` 的 `.init()` 调用
- [ ] 适配 `src/logs/async_logger.zig` 中 `std.Thread.spawn` 调用到 Zig 0.16 新签名
- [ ] 适配 `src/logs/mpmc_queue.zig` 中 `std.Thread.spawn`、`std.Thread.yield` 调用
- [ ] 适配 `src/profiler/profiler.zig` 中 `std.Thread` 相关 API（如有变更）
- [ ] 检查 `std.Thread.Mutex` 初始化方式 `.{}` 在 Zig 0.16 下是否兼容，不兼容则适配
- [ ] 检查 `std.Thread.sleep`、`std.Thread.getCurrentId` 在 Zig 0.16 下的模块路径和签名是否变更

## 3. 系统 API 迁移 — std.posix

- [ ] 适配 `src/console/console.zig` 中 `std.posix.getenv` 调用（检查模块路径是否迁移至 `std.system` 或 `std.c`）
- [ ] 适配 `src/input/input.zig` 中 `std.posix.read`、`std.posix.STDIN_FILENO`、`std.posix.termios`、`std.posix.tcgetattr`、`std.posix.tcsetattr`、`std.posix.V.MIN`、`std.posix.V.TIME` 调用
- [ ] 适配 `src/menu/menu.zig` 中 `std.posix.read` 调用

## 4. 系统 API 迁移 — std.os.windows

- [ ] 更新 `src/console/console.zig` 中 Windows API 路径：`const windows = std.os.windows` → 确认 Zig 0.16 新路径（如 `std.windows`），更新 `w.kernel32.*`、`w.HANDLE`、`w.DWORD`、`w.BOOL`、`w.STD_OUTPUT_HANDLE`、`w.INVALID_HANDLE_VALUE` 引用
- [ ] 适配 `src/console/console.zig` 中 `callconv(winapi)` 语法到 Zig 0.16 新写法
- [ ] 更新 `src/input/input.zig` 中 Windows API 路径及 `callconv(winapi)` 语法：`w.kernel32.GetStdHandle`、`w.kernel32.ReadFile` 等
- [ ] 更新 `src/menu/menu.zig` 中 Windows API 路径：`w.kernel32.GetStdHandle`、`w.kernel32.GetConsoleMode` 等
- [ ] 更新 `src/logs/logger.zig` 中 Windows API 路径：`w.kernel32.GetStdHandle`、`w.kernel32.WriteConsoleW` 等
- [ ] 更新 `src/logs/async_logger.zig` 中 Windows API 路径：`w.kernel32.GetStdHandle`、`w.kernel32.WriteConsoleW` 等

## 5. 系统 API 迁移 — std.process 与 std.unicode

- [ ] 适配 `src/menu/menu.zig` 中 `std.process.Child.run` 调用到 Zig 0.16 新签名（检查参数结构体字段名是否变更）
- [ ] 适配 `src/logs/async_logger.zig` 中 `std.unicode.utf8ToUtf16LeAlloc` 调用（检查函数签名或路径是否变更）
- [ ] 适配 `src/logs/logger.zig` 中 `std.unicode.utf8ToUtf16LeAlloc` 调用
- [ ] 适配 `src/xml/scanner.zig` 中 `std.unicode.utf8ByteSequenceLength`、`std.unicode.utf8Decode`、`std.unicode.utf8Encode` 调用

## 6. 工具库 API 迁移

- [ ] 适配 `src/profiler/profiler.zig` 中 `std.Random.DefaultPrng` 及 `prng.random().float(f32)` 到 Zig 0.16 新 API
- [ ] 适配 `src/profiler/profiler.zig` 中 `@TypeOf(func).ReturnType` → `@TypeOf(func).return_type`（Zig 0.16 内省 API 命名从 PascalCase 变更为 snake_case）
- [ ] 适配 `src/logs/async_logger_config.zig` 中 `std.json` API：`json.parseFromSlice`、`json.Value` 联合体字段（`.integer`、`.float`、`.string`、`.bool` 可能重命名），`parsed.value.object` 访问路径
- [ ] 适配 `src/random/randoms.zig` 中 `std.crypto.random.uintLessThan` 调用（确认签名是否变更，该 API 较稳定，大概率无需修改）

## 7. 其他源文件编译适配

- [ ] 检查 `src/zzig.zig`（主入口）中是否有需适配的 std 库调用
- [ ] 检查 `src/file/file.zig` 中是否有需适配的 std 库调用
- [ ] 检查 `src/json/jsmn_zig.zig`、`src/json/json_simd_optimized.zig`、`src/json/json_zero_alloc_optimized.zig` 中是否有需适配的 std 库调用
- [ ] 检查 `src/logs/structured_log.zig` 中是否有需适配的 std 库调用
- [ ] 检查 `src/string/strings.zig` 中是否有需适配的 std 库调用
- [ ] 检查 `src/xml/dom.zig`、`src/xml/reader.zig`、`src/xml/writer.zig`、`src/xml/xml.zig` 中是否有需适配的 std 库调用
- [ ] 检查 `src/async_logger_test.zig`、`src/test.zig` 中是否有需适配的 std 库调用

## 8. 示例程序编译适配

- [ ] 适配 `examples/console_example.zig`、`examples/console_concurrent_test.zig` 中受主模块变更影响的 API 调用
- [ ] 适配 `examples/async_logger_*.zig`（10 个文件）中受主模块变更影响的 API 调用
- [ ] 适配 `examples/logger_*.zig`（3 个文件）中受主模块变更影响的 API 调用
- [ ] 适配 `examples/json_*.zig`（4 个文件）中受主模块变更影响的 API 调用
- [ ] 适配 `examples/menu_*.zig`（2 个文件）中受主模块变更影响的 API 调用
- [ ] 适配 `examples/profiler_demo.zig`、`examples/xml_example.zig`、`examples/quick_test.zig`、`examples/advanced_features_demo.zig`、`examples/feature_extension_demo.zig` 中受主模块变更影响的 API 调用

## 9. 编译验证

- [ ] 执行 `zig build` 全量编译，确保退出码为 0，无编译错误
- [ ] 根据编译错误逐项修正，直至全量编译通过
- [ ] 执行 `zig build test` 单元测试，确保所有测试用例通过，无 FAIL
- [ ] 若测试用例失败，分析原因：标准库行为微调则更新测试预期值，回归缺陷则修复代码逻辑
- [ ] 逐个编译示例程序（通过 `zig build` 各示例 step），确保全部编译成功
- [ ] 检查编译输出中无新增 warning

## 10. 版本标识一致性检查与收尾

- [ ] 确认 `build.zig` 中 `min_zig_string` 为 `"0.16.0"`
- [ ] 确认 `build.zig.zon` 中 `minimum_zig_version` 为 `"0.16.0"`
- [ ] 全文搜索源码确认无残留 `"0.15"`、`version_15`、`minor == 15` 引用
- [ ] 确认 zzig 库所有 `pub` 导出的类型和函数签名未发生破坏性变更
- [ ] 确认条件原子类型模型（`supportsAtomicU64()`/`supportsAtomicI64()`）的 ARMv6 降级策略保持不变
