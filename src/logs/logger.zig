const std = @import("std");
const builtin = @import("builtin");

/// 日志级别
pub const Level = enum {
    debug,
    info,
    warn,
    err,

    /// 获取日志级别的颜色代码
    fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // 青色
            .info => "\x1b[32m", // 绿色
            .warn => "\x1b[33m", // 黄色
            .err => "\x1b[31m", // 红色
        };
    }

    /// 获取日志级别的标签
    fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

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

/// 全局日志级别，可通过环境变量或配置调整
var global_level: Level = .debug;

/// 线程安全互斥锁
var log_mutex: std.Thread.Mutex = .{};

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

/// 将时间戳格式化到调用者提供的栈缓冲区（零堆分配）
/// buf 至少 32 字节；格式固定为 YYYY-MM-DD HH:MM:SS.nnnnnnnnn（29 字节）
fn formatTimestamp(buf: *[32]u8) []u8 {
    // 获取纳秒级时间戳
    const nanos: i128 = std.time.nanoTimestamp();

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
    const h = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
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
    _ = w.kernel32.WriteConsoleW(h.?, utf16.ptr, @as(w.DWORD, @intCast(utf16.len)), &written, null);
}

/// 通用日志打印函数
fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    // 级别过滤
    if (@intFromEnum(level) < @intFromEnum(global_level)) {
        return;
    }

    // 线程安全保护
    if (thread_safe_enabled) {
        log_mutex.lock();
        defer log_mutex.unlock();
    }

    // 时间戳写入栈内存，无堆分配
    var ts_buf: [32]u8 = undefined;
    const timestamp = formatTimestamp(&ts_buf);

    const color_code = level.color();
    const reset_code = "\x1b[0m";
    const level_label = level.label();

    // 非 Windows：直接两次写 stderr，零堆分配（无 arena、无 allocPrint）
    // log_mutex（已在上方持有）保证同一进程内日志行不交错
    if (builtin.os.tag != .windows) {
        std.debug.print("{s}[{s}] {s}{s}{s} ", .{ color_code, timestamp, color_code, level_label, reset_code });
        std.debug.print(fmt ++ "\n", args);
        return;
    }

    // Windows：需要 UTF-16 转换，使用 arena 承载中间字符串
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 格式化用户消息
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;

    // 组装完整日志（WriteConsoleW 需要一次性写入）
    const full_message = std.fmt.allocPrint(
        allocator,
        "{s}[{s}] {s}{s}{s} {s}\n",
        .{ color_code, timestamp, color_code, level_label, reset_code, message },
    ) catch return;

    printUtf8(allocator, full_message);
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

    // 时间戳写入栈内存，无堆分配
    var ts_buf: [32]u8 = undefined;
    const timestamp = formatTimestamp(&ts_buf);

    // 格式化用户消息
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;

    // 组装完整日志（使用 INFO 级别的样式）
    const color_code = "\x1b[32m"; // 绿色
    const reset_code = "\x1b[0m";
    const level_label = "INFO";

    const full_message = std.fmt.allocPrint(
        allocator,
        "{s}[{s}] {s}{s}{s} {s}\n",
        .{ color_code, timestamp, color_code, level_label, reset_code, message },
    ) catch return;

    printUtf8(allocator, full_message);
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
