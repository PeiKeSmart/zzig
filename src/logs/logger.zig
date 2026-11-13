const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");

/// 日志级别。
///
/// **对齐 DH.NCore `LogLevel`**（`All/Debug/Info/Warn/Error/Fatal/Off`）：
/// - 判断恒为「输出 `>=` 配置级别」，所以 `all` 放行一切、`off` 关闭一切；
/// - `error` 是 Zig 关键字，枚举成员写作 `err`，但 `asStr()` 输出 `ERROR`（与 C# 一致）。
pub const Level = enum(u8) {
    all = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,
    off = 6,

    /// 级别的规范名称（大写），对齐 DH.NCore `LogLevel::as_str()`。
    pub fn asStr(self: Level) []const u8 {
        return switch (self) {
            .all => "ALL",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
            .off => "OFF",
        };
    }

    /// 级别的 C# 枚举名（PascalCase）。
    ///
    /// DH.NCore 的 `LogLineFormat` 含 `Level` 时输出的是 `[{Level}]`，
    /// 而 `Level` 是 `LogLevel` 枚举，`ToString()` 结果就是 PascalCase（`[Info]`），
    /// 与大写的 `asStr()` 不同 —— 两者不能混用。
    pub fn pascalName(self: Level) []const u8 {
        return switch (self) {
            .all => "All",
            .debug => "Debug",
            .info => "Info",
            .warn => "Warn",
            .err => "Error",
            .fatal => "Fatal",
            .off => "Off",
        };
    }

    /// 解析级别名（不区分大小写），对齐 DH.NCore `LogLevel::parse`。
    ///
    /// 额外容忍常见别名：`trace`→debug、`warning`→warn、`error`→err、`none`/`silent`→off。
    /// 非法值返回 `null`（调用方保持原级别）。
    pub fn parse(name: []const u8) ?Level {
        const eq = std.ascii.eqlIgnoreCase;
        const t = std.mem.trim(u8, name, " \t\r\n");
        if (eq(t, "all")) return .all;
        if (eq(t, "debug") or eq(t, "trace")) return .debug;
        if (eq(t, "info")) return .info;
        if (eq(t, "warn") or eq(t, "warning")) return .warn;
        if (eq(t, "err") or eq(t, "error")) return .err;
        if (eq(t, "fatal")) return .fatal;
        if (eq(t, "off") or eq(t, "none") or eq(t, "silent")) return .off;
        return null;
    }

    /// 获取日志级别的标签
    fn label(self: Level) []const u8 {
        return self.asStr();
    }
};

/// 日志行格式（对齐 DH.NCore `Setting.LogLineFormat`）。
///
/// DH.NCore 默认 `Time|ThreadId|Kind|Name|Message`，并说明「还支持 Level」——
/// 两种都在这里提供；`legacy` 保留 zzig 早期格式，供已依赖旧输出的项目按需切回。
pub const LineFormat = enum {
    /// `HH:MM:SS.mmm ThreadId Kind Name Message`（对齐 DH.NCore 默认值）
    ncore,
    /// `HH:MM:SS.mmm ThreadId Kind Name Level Message`（DH.NCore 的含 Level 变体）
    ncore_level,
    /// `[YYYY-MM-DD HH:MM:SS.nnnnnnnnn] [LEVEL] message`（zzig 旧格式）
    legacy,
};

/// 当前行格式（默认对齐 DH.NCore）
var line_format: LineFormat = .ncore;

/// 设置日志行格式。
pub fn setLineFormat(f: LineFormat) void {
    line_format = f;
}

/// 取当前行格式。
pub fn getLineFormat() LineFormat {
    return line_format;
}

/// 线程类别标识（对齐 DH.NCore 的 Kind 列）。
///
/// C# 侧由 `XTrace` 按场景置位（Y=线程池 / W=网页 / N=普通 / T=定时 / P / L）；
/// Zig 侧暂不区分运行场景，统一 `N`（普通），保持列数与前缀形状稳定。
const kind_normal = "N";

/// Kit/Name 列占位：Zig 无「线程名」运行时 API，用 `-` 占位使 5 列结构稳定可解析。
const name_placeholder = "-";

// ============ 时间偏移支持 ============

/// 服务器时间偏移量（毫秒）
/// server_time = local_time + time_offset_ms
var time_offset_ms: i64 = 0;

/// 设置时间偏移量（毫秒）
/// 用于与服务器时间同步
pub fn setTimeOffset(offset_ms: i64) void {
    time_offset_ms = offset_ms;
}

/// 获取时间偏移量
pub fn getTimeOffset() i64 {
    return time_offset_ms;
}

/// 全局日志级别（对齐 DH.NCore：默认 `Info`，只输出 `>=` 该级别的日志）
var global_level: Level = .info;

/// 线程安全互斥锁
var log_mutex: compat.Mutex = .{};

/// 线程安全开关（默认关闭以保持性能）
var thread_safe_enabled: bool = false;

/// 启用线程安全模式
///
/// 在多线程环境中调用此函数以确保日志输出不会交错。
/// 注意：启用后会有轻微性能开销。
///
/// 示例：
/// ```zig
/// Logger.enableThreadSafe();
/// ```
pub fn enableThreadSafe() void {
    thread_safe_enabled = true;
}

/// 禁用线程安全模式（默认状态）
///
/// 在单线程环境或对性能要求极高的场景可以禁用。
pub fn disableThreadSafe() void {
    thread_safe_enabled = false;
}

/// 检查是否启用了线程安全模式
pub fn isThreadSafe() bool {
    return thread_safe_enabled;
}

/// 设置全局日志级别
pub fn setLevel(level: Level) void {
    global_level = level;
}

/// 取当前全局日志级别
pub fn getLevel() Level {
    return global_level;
}

/// 当前设置下该级别是否会真正输出。
pub fn enabled(level: Level) bool {
    return @backingInt(level) >= @backingInt(global_level);
}

/// 读环境变量 `ZZIG_LOG` 并应用级别（对应 DH.NCore / DH.RustBase 的 `RUST_LOG` 习惯）。
///
/// 不存在或值非法时保持当前级别；返回最终生效的级别。
pub fn applyEnv(environ_map: *const std.process.Environ.Map) Level {
    const raw = environ_map.get("ZZIG_LOG") orelse return global_level;
    if (Level.parse(raw)) |lv| global_level = lv;
    return global_level;
}

/// 按线程号取日志行颜色（对齐 DH.NCore `ConsoleLog`）：
/// 警告黄、错误/严重错误红，其余级别按线程号取自 10 色调色板，1 号线程灰白。
///
/// 返回**不含** `\x1b[` 前缀与 `m` 后缀的色号，由调用方拼接（保持 fmt 为 comptime 字面量）。
fn colorCode(level: Level, thread_id: u32) []const u8 {
    return switch (level) {
        .warn => "33",
        .err, .fatal => "31",
        else => if (thread_id == 1) "37" else palette[thread_id % palette.len],
    };
}

/// 调色板（顺序对齐 DH.NCore `ConsoleLog.colors`，以 ANSI 亮色/标准色近似）
const palette = [10][]const u8{ "92", "96", "95", "97", "93", "32", "36", "35", "31", "33" };

/// 当前线程 id（用作 `ThreadId` 列；取模 100 保证两位宽度）
fn currentThreadId() u32 {
    return @intCast(std.Thread.getCurrentId() % 100);
}

/// 将时间戳格式化为 `HH:MM:SS.mmm`（对齐 DH.NCore 行首 `Time` 列，不含日期：日期已在文件名里）。
///
/// buf 至少 16 字节；返回写入的切片。
fn formatClock(buf: *[16]u8) []u8 {
    const nanos: i128 = compat.nanoTimestamp();
    const offset_nanos: i128 = @as(i128, time_offset_ms) * std.time.ns_per_ms;
    const adjusted_nanos: i128 = nanos + offset_nanos;

    const timestamp: i64 = @intCast(@divFloor(adjusted_nanos, std.time.ns_per_s));
    const nano_part: u32 = @intCast(@mod(adjusted_nanos, std.time.ns_per_s));
    const millis: u32 = nano_part / std.time.ns_per_ms;

    const local_offset: i64 = getLocalTimezoneOffset();
    const seconds_since_epoch: i64 = timestamp + local_offset;
    const seconds_today = @mod(seconds_since_epoch, 86400);

    const hour: u32 = @intCast(@divFloor(seconds_today, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(seconds_today, 3600), 60));
    const second: u32 = @intCast(@mod(seconds_today, 60));

    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hour, minute, second, millis }) catch buf[0..12];
}

/// 将时间戳格式化到调用者提供的栈缓冲区（零堆分配）
/// buf 至少 32 字节；格式固定为 YYYY-MM-DD HH:MM:SS.nnnnnnnnn（29 字节）
fn formatTimestamp(buf: *[32]u8) []u8 {
    // 获取纳秒级时间戳
    const nanos: i128 = compat.nanoTimestamp();

    // 应用时间偏移量（毫秒转纳秒）
    // server_time = local_time + time_offset_ms
    const offset_nanos: i128 = @as(i128, time_offset_ms) * std.time.ns_per_ms;
    const adjusted_nanos: i128 = nanos + offset_nanos;

    // 转换为秒和纳秒部分
    const timestamp: i64 = @intCast(@divFloor(adjusted_nanos, std.time.ns_per_s));
    const nano_part: u32 = @intCast(@mod(adjusted_nanos, std.time.ns_per_s));

    // 获取本地时区偏移（秒）
    const local_offset: i64 = getLocalTimezoneOffset();
    const seconds_since_epoch: i64 = timestamp + local_offset;

    // 转换为本地时间
    const days_since_epoch = @divFloor(seconds_since_epoch, 86400);
    const seconds_today = @mod(seconds_since_epoch, 86400);

    const hour: u32 = @intCast(@divFloor(seconds_today, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(seconds_today, 3600), 60));
    const second: u32 = @intCast(@mod(seconds_today, 60));

    // 准确的日期计算（考虑闰年）
    const date = epochDaysToDate(days_since_epoch);

    // 直接写入栈缓冲区，无堆分配
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{
        date.year, date.month, date.day, hour, minute, second, nano_part,
    }) catch buf[0..29]; // bufPrint 不会失败（buf 足够大），catch 仅供编译器满足
}

/// 日期结构
const Date = struct {
    year: u32,
    month: u32,
    day: u32,
};

/// 将 epoch 天数转换为日期（Howard Hinnant proleptic Gregorian 算法，O(1)）
/// 替代原来从 1970 年逐年迭代的 O(N) 实现
fn epochDaysToDate(days: i64) Date {
    // 将历元平移到公历 0000-03-01，使闰年处理更简洁
    const z: i64 = days + 719468;
    // 400 年周期（每周期 146097 天）
    const era: i64 = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097); // 周期内天数 [0, 146096]
    // 周期内年份（Hinnant 公式）
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // 年内天数 [0, 365]
    // 月份（以 3 月为第 0 月）
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1; // 日 [1, 31]
    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // 月 [1, 12]
    const yr: u32 = @intCast(y + @as(i64, if (m <= 2) 1 else 0));
    return Date{ .year = yr, .month = m, .day = d };
}

/// 获取本地时区偏移量（秒）
fn getLocalTimezoneOffset() i64 {
    if (builtin.os.tag == .windows) {
        // Windows: 直接调用 _get_timezone 或使用简化的 API
        // 使用 extern 声明 Windows API
        const LONG = i32;
        const WCHAR = u16;

        const SYSTEMTIME = extern struct {
            wYear: u16,
            wMonth: u16,
            wDayOfWeek: u16,
            wDay: u16,
            wHour: u16,
            wMinute: u16,
            wSecond: u16,
            wMilliseconds: u16,
        };

        const TIME_ZONE_INFORMATION = extern struct {
            Bias: LONG,
            StandardName: [32]WCHAR,
            StandardDate: SYSTEMTIME,
            StandardBias: LONG,
            DaylightName: [32]WCHAR,
            DaylightDate: SYSTEMTIME,
            DaylightBias: LONG,
        };

        const GetTimeZoneInformation = struct {
            extern "kernel32" fn GetTimeZoneInformation(lpTimeZoneInformation: *TIME_ZONE_INFORMATION) u32;
        }.GetTimeZoneInformation;

        var tzi: TIME_ZONE_INFORMATION = undefined;
        _ = GetTimeZoneInformation(&tzi);

        // Bias 是以分钟为单位的偏移，且是负值（例如 UTC+8 返回 -480）
        // 需要转换为秒并反转符号
        return -tzi.Bias * 60;
    } else {
        // Unix/Linux: 尝试读取 /etc/timezone 或使用环境变量
        // 简化处理：假设 UTC+8（中国标准时间）
        return 8 * 3600;
    }
}

/// 跨平台打印函数：Windows 使用 WriteConsoleW 确保中文正确显示
/// alloc 由调用方传入（复用外层 arena），避免 Windows 路径下的二次 arena 创建
fn printUtf8(alloc: std.mem.Allocator, text: []const u8) void {
    if (builtin.os.tag != .windows) {
        std.debug.print("{s}", .{text});
        return;
    }

    // Windows 平台：使用 WriteConsoleW 保证中文显示
    const w = std.os.windows;
    const h = compat.windows.getStdHandle(compat.windows.STD_OUTPUT_HANDLE);
    if (h == null or h == w.INVALID_HANDLE_VALUE) {
        // 降级到普通打印
        std.debug.print("{s}", .{text});
        return;
    }

    // 转换为 UTF-16LE，复用调用方的 arena，无额外年算层开销
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch {
        std.debug.print("{s}", .{text});
        return;
    };

    var written: w.DWORD = 0;
    _ = compat.windows.writeConsoleW(h.?, utf16, &written);
}

/// 生成日志行前缀（不含消息）。
///
/// `ncore` / `ncore_level` 走 DH.NCore 的 `Time ThreadId Kind Name [Level]` 形状；
/// `legacy` 保留 zzig 早期的 `[完整时间戳] [LEVEL] ` 形状。
fn buildPrefix(buf: *[96]u8, level: Level, thread_id: u32) []const u8 {
    switch (line_format) {
        .ncore => {
            var clock_buf: [16]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s} {d:0>2} {s} {s} ", .{
                formatClock(&clock_buf), thread_id, kind_normal, name_placeholder,
            }) catch buf[0..0];
        },
        .ncore_level => {
            var clock_buf: [16]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s} {d:0>2} {s} {s} [{s}] ", .{
                formatClock(&clock_buf), thread_id, kind_normal, name_placeholder, level.pascalName(),
            }) catch buf[0..0];
        },
        .legacy => {
            var ts_buf: [32]u8 = undefined;
            return std.fmt.bufPrint(buf, "[{s}] [{s}] ", .{
                formatTimestamp(&ts_buf), level.asStr(),
            }) catch buf[0..0];
        },
    }
}

/// 通用日志打印函数
fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    // 级别过滤（对齐 DH.NCore：只输出 >= 配置级别）
    if (!enabled(level)) {
        return;
    }

    // 线程安全保护
    if (thread_safe_enabled) {
        log_mutex.lock();
        defer log_mutex.unlock();
    }

    const thread_id = currentThreadId();
    var prefix_buf: [96]u8 = undefined;
    const prefix = buildPrefix(&prefix_buf, level, thread_id);
    const color_code = colorCode(level, thread_id);

    // 非 Windows：直接写 stderr，零堆分配（无 arena、无 allocPrint）
    // log_mutex（已在上方持有）保证同一进程内日志行不交错
    if (builtin.os.tag != .windows) {
        std.debug.print("\x1b[{s}m", .{color_code});
        std.debug.print("{s}", .{prefix});
        std.debug.print(fmt ++ "\n" ++ "\x1b[0m", args);
        return;
    }

    // Windows：需要 UTF-16 转换，使用单个 writer 顺序组装整行，
    // 避免先生成 message 再作为 {s} 拼接回 full_message 触发别名拷贝。
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer: std.ArrayList(u8) = .empty;
    var writer_allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    const writer = &writer_allocating.writer;

    writer.print("\x1b[{s}m", .{color_code}) catch return;
    writer.writeAll(prefix) catch return;
    writer.print(fmt, args) catch return;
    writer.writeAll("\n\x1b[0m") catch return;

    buffer = writer_allocating.toArrayList();
    printUtf8(allocator, buffer.items);
}

/// 调试级别日志
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

/// 信息级别日志
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

/// 警告级别日志
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

/// 错误级别日志
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

/// 严重错误级别日志（对齐 DH.NCore `Fatal`：进程级不可恢复错误）
pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    log(.fatal, fmt, args);
}

/// 强制输出日志（忽略全局日志级别,用于启动信息等关键日志）
pub fn always(comptime fmt: []const u8, args: anytype) void {
    // 线程安全保护
    if (thread_safe_enabled) {
        log_mutex.lock();
        defer log_mutex.unlock();
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 固定按 info 级别出前缀与配色（`always` 的语义是「不受级别过滤」）
    const thread_id = currentThreadId();
    var prefix_buf: [96]u8 = undefined;
    const prefix = buildPrefix(&prefix_buf, .info, thread_id);
    const color_code = colorCode(.info, thread_id);

    var buffer: std.ArrayList(u8) = .empty;
    var writer_allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    const writer = &writer_allocating.writer;

    writer.print("\x1b[{s}m", .{color_code}) catch return;
    writer.writeAll(prefix) catch return;
    writer.print(fmt, args) catch return;
    writer.writeAll("\n\x1b[0m") catch return;

    buffer = writer_allocating.toArrayList();
    printUtf8(allocator, buffer.items);
}

/// 不带时间戳和级别的简单打印（用于替换原有的简单打印场景）
pub fn print(comptime fmt: []const u8, args: anytype) void {
    // 线程安全保护
    if (thread_safe_enabled) {
        log_mutex.lock();
        defer log_mutex.unlock();
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    printUtf8(allocator, message);
}

// ============ 对齐 DH.NCore 的规则测试 ============

const testing = std.testing;

test "logger：默认级别为 info（对齐 DH.NCore 默认 LogLevel=Info）" {
    const saved = getLevel();
    defer setLevel(saved);
    setLevel(.info);
    try testing.expect(enabled(.info));
    try testing.expect(enabled(.warn));
    try testing.expect(enabled(.err));
    try testing.expect(enabled(.fatal));
    try testing.expect(!enabled(.debug)); // 明细默认看不到
    try testing.expect(!enabled(.all));
}

test "logger：7 级对齐 All/Debug/Info/Warn/Error/Fatal/Off 且门槛为 >=" {
    // 枚举顺序必须与 DH.NCore 一致（all < debug < info < warn < error < fatal < off）
    try testing.expect(@backingInt(Level.all) < @backingInt(Level.debug));
    try testing.expect(@backingInt(Level.debug) < @backingInt(Level.info));
    try testing.expect(@backingInt(Level.info) < @backingInt(Level.warn));
    try testing.expect(@backingInt(Level.warn) < @backingInt(Level.err));
    try testing.expect(@backingInt(Level.err) < @backingInt(Level.fatal));
    try testing.expect(@backingInt(Level.fatal) < @backingInt(Level.off));

    const saved = getLevel();
    defer setLevel(saved);

    setLevel(.all);
    try testing.expect(enabled(.debug));
    setLevel(.off);
    try testing.expect(!enabled(.fatal)); // off 关掉一切
}

test "logger：asStr 与 parse 对齐 C# LogLevel（含大小写与别名）" {
    try testing.expectEqualStrings("INFO", Level.info.asStr());
    try testing.expectEqualStrings("ERROR", Level.err.asStr());
    try testing.expectEqualStrings("FATAL", Level.fatal.asStr());
    try testing.expectEqualStrings("OFF", Level.off.asStr());

    try testing.expectEqual(Level.debug, Level.parse("DEBUG").?);
    try testing.expectEqual(Level.debug, Level.parse(" trace ").?);
    try testing.expectEqual(Level.warn, Level.parse("Warning").?);
    try testing.expectEqual(Level.err, Level.parse("error").?);
    try testing.expectEqual(Level.fatal, Level.parse("FATAL").?);
    try testing.expectEqual(Level.off, Level.parse("none").?);
    try testing.expectEqual(@as(?Level, null), Level.parse("乱写"));
}

test "logger：行格式默认为 NCore，可切换" {
    const saved = getLineFormat();
    defer setLineFormat(saved);
    try testing.expectEqual(LineFormat.ncore, getLineFormat());
    setLineFormat(.legacy);
    try testing.expectEqual(LineFormat.legacy, getLineFormat());
}

test "logger：applyEnv 读 ZZIG_LOG（不存在保持、非法保持）" {
    const saved = getLevel();
    defer setLevel(saved);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    setLevel(.info);
    try testing.expectEqual(Level.info, applyEnv(&env));

    try env.put("ZZIG_LOG", " warn ");
    try testing.expectEqual(Level.warn, applyEnv(&env));

    try env.put("ZZIG_LOG", "乱写");
    try testing.expectEqual(Level.warn, applyEnv(&env));
}

test "logger：clock 前缀形状为 HH:MM:SS.mmm" {
    var buf: [16]u8 = undefined;
    const s = formatClock(&buf);
    try testing.expectEqual(@as(usize, 12), s.len);
    try testing.expectEqual(@as(u8, ':'), s[2]);
    try testing.expectEqual(@as(u8, ':'), s[5]);
    try testing.expectEqual(@as(u8, '.'), s[8]);
}
