const std = @import("std");
const testing = std.testing;
const zzig = @import("zzig");
const compat = zzig.compat;

// 字符串处理测试
test "Strings - AddString concatenates two strings" {
    const allocator = testing.allocator;

    const result = try zzig.Strings.AddString(allocator, "Hello", "World");
    defer allocator.free(result);

    try testing.expectEqualStrings("HelloWorld", result);
}

test "Strings - AddStrings concatenates multiple strings" {
    const allocator = testing.allocator;

    const slices = [_][]const u8{ "Hello", " ", "Zig", " ", "World" };
    const result = try zzig.Strings.AddStrings(allocator, &slices);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello Zig World", result);
}

test "Strings - Contains returns true for existing substring" {
    const str = "Hello Zig World";
    try testing.expect(zzig.Strings.Contains(str, "Zig"));
    try testing.expect(zzig.Strings.Contains(str, "World"));
}

test "Strings - Contains returns false for non-existing substring" {
    const str = "Hello Zig World";
    try testing.expect(!zzig.Strings.Contains(str, "Python"));
}

test "Strings - CompareStrings compares lexicographically" {
    try testing.expect(zzig.Strings.CompareStrings({}, "abc", "xyz"));
    try testing.expect(!zzig.Strings.CompareStrings({}, "xyz", "abc"));
}

// 随机数处理测试
test "Randoms - RandomString generates string of correct length" {
    const allocator = testing.allocator;

    const len: usize = 10;
    const result = try zzig.Randoms.RandomString(allocator, len);
    defer allocator.free(result);

    try testing.expectEqual(len, result.len);
}

test "Randoms - RandomString contains valid characters" {
    const allocator = testing.allocator;

    const result = try zzig.Randoms.RandomString(allocator, 20);
    defer allocator.free(result);

    // 验证所有字符都是有效的字母数字字符
    for (result) |char| {
        const is_valid = (char >= 'A' and char <= 'Z') or
            (char >= 'a' and char <= 'z') or
            (char >= '0' and char <= '9');
        try testing.expect(is_valid);
    }
}

// 文件处理测试
test "File - CurrentPath returns non-empty path" {
    const allocator = testing.allocator;

    const path = try zzig.File.CurrentPath(allocator);
    defer allocator.free(path);

    try testing.expect(path.len > 0);
}

// Logger 线程安全测试
test "Logger - thread safe enable/disable" {
    // 默认应该是关闭的
    try testing.expect(!zzig.Logger.isThreadSafe());

    // 启用线程安全
    zzig.Logger.enableThreadSafe();
    try testing.expect(zzig.Logger.isThreadSafe());

    // 禁用线程安全
    zzig.Logger.disableThreadSafe();
    try testing.expect(!zzig.Logger.isThreadSafe());
}

test "Logger - basic logging functions work" {
    // 这个测试主要确保日志函数不会崩溃
    zzig.Logger.setLevel(.debug);

    zzig.Logger.debug("Test debug message", .{});
    zzig.Logger.info("Test info message", .{});
    zzig.Logger.warn("Test warn message", .{});
    zzig.Logger.err("Test error message", .{});
    zzig.Logger.always("Test always message", .{});
    zzig.Logger.print("Test print\n", .{});
}

test "Logger - thread safe mode does not crash" {
    zzig.Logger.enableThreadSafe();
    defer zzig.Logger.disableThreadSafe();

    zzig.Logger.info("Thread safe test", .{});
    zzig.Logger.debug("With multiple", .{});
    zzig.Logger.warn("Different levels", .{});
}

// AsyncLogger 测试
test "AsyncLogger - RingQueue basic operations" {
    const allocator = testing.allocator;

    var queue = try zzig.AsyncLogger.RingQueue.init(allocator, 4);
    defer queue.deinit();

    // 测试空队列
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 0), queue.size());

    // 测试推入
    const msg1 = zzig.AsyncLogger.LogMessage.init(.info, 12345, 0, "test message 1");
    try testing.expect(queue.tryPush(msg1));
    try testing.expectEqual(@as(usize, 1), queue.size());

    // 测试弹出
    const popped = queue.tryPop().?;
    try testing.expectEqual(zzig.AsyncLogger.Level.info, popped.level);
    try testing.expectEqual(@as(usize, 0), queue.size());

    // 测试队列满
    for (0..3) |_| {
        _ = queue.tryPush(msg1);
    }
    try testing.expect(!queue.tryPush(msg1)); // 第4次应该失败（容量3）
}

test "AsyncLogger - basic initialization and cleanup" {
    const allocator = testing.allocator;

    const config = zzig.AsyncLogger.AsyncLoggerConfig{
        .queue_capacity = 16,
        .idle_sleep_us = 100,
    };

    const logger = try zzig.AsyncLogger.AsyncLogger.init(allocator, config);
    defer logger.deinit();

    try testing.expect(logger.getProcessedCount() == 0);
    try testing.expect(logger.getDroppedCount() == 0);
}

test "AsyncLogger - log messages are queued" {
    const allocator = testing.allocator;

    const config = zzig.AsyncLogger.AsyncLoggerConfig{
        .queue_capacity = 128,
        .global_level = .debug,
    };

    const logger = try zzig.AsyncLogger.AsyncLogger.init(allocator, config);
    defer logger.deinit();

    // 发送一些日志
    logger.info("Test message 1", .{});
    logger.debug("Test message 2", .{});
    logger.warn("Test message 3", .{});

    // 短暂等待后台处理
    compat.sleep(100 * std.time.ns_per_ms);

    // 验证已处理（可能还有未处理的）
    try testing.expect(logger.getProcessedCount() > 0);
}

test "AsyncLogger - level filtering works" {
    const allocator = testing.allocator;

    const config = zzig.AsyncLogger.AsyncLoggerConfig{
        .queue_capacity = 128,
        .global_level = .warn, // 只记录 warn 及以上
    };

    const logger = try zzig.AsyncLogger.AsyncLogger.init(allocator, config);
    defer logger.deinit();

    // 这些应该被过滤
    logger.debug("Filtered debug", .{});
    logger.info("Filtered info", .{});

    // 这些应该被记录
    logger.warn("Logged warn", .{});
    logger.err("Logged error", .{});

    compat.sleep(100 * std.time.ns_per_ms);

    // 应该只有 2 条被处理
    try testing.expectEqual(@as(usize, 2), logger.getProcessedCount());
}

// ─────────────────────── 通用数值 / 时间 / 缓冲 ───────────────────────

test "Decimal - 解析与格式化保留尾随零" {
    const allocator = testing.allocator;

    const d = try zzig.Decimal.parse("12.3400");
    try testing.expectEqual(@as(u8, 4), d.scale);

    const text = try d.formatAlloc(allocator);
    defer allocator.free(text);
    try testing.expectEqualStrings("12.3400", text);

    // 数值相等忽略尾随零
    try testing.expect(d.eql(try zzig.Decimal.parse("12.34")));
    try testing.expect(!d.eql(try zzig.Decimal.parse("12.35")));
}

test "Decimal - 指数形式与精度往返" {
    try testing.expect((try zzig.Decimal.parse("1.2e3")).eql(try zzig.Decimal.parse("1200")));
    try testing.expect((try zzig.Decimal.parse("1e-3")).eql(try zzig.Decimal.parse("0.001")));
    try testing.expectError(error.InvalidDecimal, zzig.Decimal.parse("abc"));
}

test "DateTime - 7 位小数秒往返" {
    const allocator = testing.allocator;

    const text = "2026-09-26 18:01:02.1230000";
    const dt = try zzig.DateTime.parse(text);
    const out = try dt.formatAlloc(allocator);
    defer allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "DateTime - 兼容纯日期/斜杠分隔/时区后缀" {
    try testing.expect((try zzig.DateTime.parse("2026-09-26")).eql(.{ .year = 2026, .month = 9, .day = 26 }));
    try testing.expect((try zzig.DateTime.parse("2026/09/26 08:00")).eql(.{ .year = 2026, .month = 9, .day = 26, .hour = 8 }));
    try testing.expectError(error.InvalidDateTime, zzig.DateTime.parse("2026-13-01"));
}

test "DateTime - Unix 秒换算" {
    const dt = zzig.DateTime.fromUnixSeconds(1790445662);
    try testing.expectEqual(@as(i32, 2026), dt.year);
    try testing.expectEqual(@as(u8, 9), dt.month);
    try testing.expectEqual(@as(u8, 26), dt.day);
}

test "Buf - 追加与格式化" {
    var b = zzig.Buf.init(testing.allocator);
    defer b.deinit();

    try b.add("SELECT ");
    try b.fmt("{d}", .{42});
    try b.add(" FROM t");
    try testing.expectEqualStrings("SELECT 42 FROM t", b.slice());
}

// ─────────────────────── 数据库通用层 ───────────────────────

test "db.Value - 跨类型取值与 SQL 字面量" {
    const allocator = testing.allocator;
    const Value = zzig.db.Value;

    try testing.expectEqual(@as(?i64, 42), (Value{ .text = "42" }).asI64());
    try testing.expectEqual(@as(?bool, true), (Value{ .int = 1 }).asBool());

    const lit = try (Value{ .text = "O'Reilly" }).toSqlLiteralAlloc(allocator);
    defer allocator.free(lit);
    try testing.expectEqualStrings("'O''Reilly'", lit);

    const dt = Value{ .datetime = try zzig.DateTime.parse("2026-09-26 18:01:02.1230000") };
    const text = try dt.toTextAlloc(allocator);
    defer allocator.free(text);
    try testing.expectEqualStrings("2026-09-26 18:01:02.1230000", text);
}

test "sqlite - 动态加载并在内存库上跑通 CRUD" {
    const allocator = testing.allocator;

    var lib = zzig.sqlite.Lib.load(allocator) catch {
        // 本机无可用 sqlite3.dll / winsqlite3.dll 时跳过（不是失败）
        std.debug.print("[SKIP] 本机未找到 SQLite 动态库\n", .{});
        return;
    };
    defer lib.deinit();

    var db = try zzig.sqlite.Db.open(&lib, ":memory:");
    defer db.close();

    _ = try db.exec(allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, amount TEXT)");
    _ = try db.exec(allocator, "INSERT INTO t (name, amount) VALUES ('a', '12.3400')");

    const stmt = try db.prepare(allocator, "SELECT name, amount FROM t WHERE id = ?");
    defer stmt.finalize();
    try stmt.bindAll(&.{.{ .int = 1 }});

    const rc = lib.step(stmt.handle);
    try testing.expectEqual(zzig.sqlite.sqlite_row, rc);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const row = try stmt.readRow(arena.allocator());
    try testing.expectEqualStrings("a", row.get("name").?.text);
    // 文本参数走 SQLITE_TRANSIENT：写入的尾随零必须原样读回
    try testing.expectEqualStrings("12.3400", row.get("amount").?.text);
}

test "File - 唯一临时文件名与静默删除" {
    const allocator = testing.allocator;

    const p1 = try zzig.File.UniqueTempName(allocator, "zzig-test", ".db");
    defer allocator.free(p1);
    const p2 = try zzig.File.UniqueTempName(allocator, "zzig-test", ".db");
    defer allocator.free(p2);

    try testing.expect(!std.mem.eql(u8, p1, p2));
    // 文件不存在时不得 panic
    zzig.File.DeleteQuiet(p1);
}

test "File - ReadAllAlloc / WriteAll 往返" {
    const allocator = testing.allocator;

    const path = try zzig.File.UniqueTempName(allocator, "zzig-io", ".tmp");
    defer allocator.free(path);
    defer zzig.File.DeleteQuiet(path);

    try zzig.File.WriteAll(path, "hello 世界");
    const content = try zzig.File.ReadAllAlloc(allocator, path, 1024);
    defer allocator.free(content);
    try testing.expectEqualStrings("hello 世界", content);
}
