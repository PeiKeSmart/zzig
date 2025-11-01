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

/// 全局日志级别，可通过环境变量或配置调整
var global_level: Level = .debug;

/// 设置全局日志级别
pub fn setLevel(level: Level) void {
    global_level = level;
}

/// 获取当前时间戳字符串 (格式: YYYY-MM-DD HH:MM:SS.nnnnnnnnn)
fn getTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    // 获取纳秒级时间戳
    const nanos: i128 = std.time.nanoTimestamp();

    // 转换为秒和纳秒部分
    const timestamp: i64 = @intCast(@divFloor(nanos, std.time.ns_per_s));
    const nano_part: u32 = @intCast(@mod(nanos, std.time.ns_per_s));

    // 获取本地时区偏移（秒）
    const local_offset: i64 = getLocalTimezoneOffset();
    const local_timestamp: i64 = timestamp + local_offset;

    const seconds_since_epoch: i64 = local_timestamp;

    // 转换为本地时间
    const days_since_epoch = @divFloor(seconds_since_epoch, 86400);
    const seconds_today = @mod(seconds_since_epoch, 86400);

    const hour: u32 = @intCast(@divFloor(seconds_today, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(seconds_today, 3600), 60));
    const second: u32 = @intCast(@mod(seconds_today, 60));

    // 准确的日期计算（考虑闰年）
    const date = epochDaysToDate(days_since_epoch);

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{
        date.year, date.month, date.day, hour, minute, second, nano_part,
    });
}

/// 日期结构
const Date = struct {
    year: u32,
    month: u32,
    day: u32,
};

/// 判断是否为闰年
fn isLeapYear(year: i64) bool {
    return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
}

/// 获取指定月份的天数
fn getDaysInMonth(year: i64, month: u32) u32 {
    const days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) {
        return 29;
    }
    return days[month - 1];
}

/// 将 epoch 天数转换为日期
fn epochDaysToDate(days: i64) Date {
    // 从 1970-01-01 开始计算
    var year: i64 = 1970;
    var remaining_days = days;

    // 计算年份
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) {
            break;
        }
        remaining_days -= days_in_year;
        year += 1;
    }

    // 计算月份和日期
    var month: u32 = 1;
    while (month <= 12) {
        const days_in_month = getDaysInMonth(year, month);
        if (remaining_days < days_in_month) {
            break;
        }
        remaining_days -= days_in_month;
        month += 1;
    }

    const day: u32 = @intCast(remaining_days + 1);

    return Date{
        .year = @intCast(year),
        .month = month,
        .day = day,
    };
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
fn printUtf8(text: []const u8) void {
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

    // 转换为 UTF-16LE
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 获取时间戳
    const timestamp = getTimestamp(allocator) catch "????-??-?? ??:??:??.?????????";

    // 格式化用户消息
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;

    // 组装完整日志
    const color_code = level.color();
    const reset_code = "\x1b[0m";
    const level_label = level.label();

    const full_message = std.fmt.allocPrint(
        allocator,
        "{s}[{s}] {s}{s}{s} {s}\n",
        .{ color_code, timestamp, color_code, level_label, reset_code, message },
    ) catch return;

    printUtf8(full_message);
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

/// 强制输出日志（忽略全局日志级别，用于启动信息等关键日志）
pub fn always(comptime fmt: []const u8, args: anytype) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 获取时间戳
    const timestamp = getTimestamp(allocator) catch "????-??-?? ??:??:??.?????????";

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

    printUtf8(full_message);
}

/// 不带时间戳和级别的简单打印（用于替换原有的简单打印场景）
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    printUtf8(message);
}
