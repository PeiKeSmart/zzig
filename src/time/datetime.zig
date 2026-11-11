//! 日期时间值：无时区的日历时间 + 纳秒，带**数据库友好的固定文本格式**。
//!
//! - `format` 系列输出 `YYYY-MM-DD HH:MM:SS.fffffff`（7 位小数秒 = 100ns 刻度）；
//! - `parse` 容忍 ISO 8601、纯日期、无小数秒、1~9 位小数秒、`/` 分隔符；
//! - 不做时区换算（默认按本地无时区值处理），需要 UTC/本地时钟用 `nowUtc` / `nowLocal`。
//!
//! 该格式与 XCode/DH.NCode 的落库文本一致，可直接用于 C# 侧互读。

const std = @import("std");

pub const DateTime = struct {
    year: i32 = 0,
    month: u8 = 1,
    day: u8 = 1,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    /// 纳秒（0..999_999_999）；XCode 落库只保留 100ns 精度
    nanos: u32 = 0,

    pub const min = DateTime{ .year = 1, .month = 1, .day = 1 };

    /// 解析（容忍：`YYYY-MM-DD`、`YYYY/MM/DD`、带/不带秒、带 1~9 位小数秒）。
    pub fn parse(text: []const u8) !DateTime {
        const s = std.mem.trim(u8, text, " \t\r\n");
        if (s.len < 8) return error.InvalidDateTime;

        var dt = DateTime{};
        var i: usize = 0;
        dt.year = @intCast(try readNumber(s, &i, 4, &[_]u8{}));
        if (i >= s.len) return error.InvalidDateTime;
        if (s[i] != '-' and s[i] != '/') return error.InvalidDateTime;
        i += 1;
        dt.month = @intCast(try readNumber(s, &i, 2, &[_]u8{}));
        if (i >= s.len) return error.InvalidDateTime;
        if (s[i] != '-' and s[i] != '/') return error.InvalidDateTime;
        i += 1;
        dt.day = @intCast(try readNumber(s, &i, 2, &[_]u8{}));

        // 先校验日期，再进入时间部分（否则纯日期会绕过校验）
        if (dt.month < 1 or dt.month > 12) return error.InvalidDateTime;
        if (dt.day < 1 or dt.day > 31) return error.InvalidDateTime;

        if (i >= s.len) return dt;
        if (s[i] == 'T' or s[i] == ' ') i += 1 else return error.InvalidDateTime;
        if (i >= s.len) return dt;

        dt.hour = @intCast(try readNumber(s, &i, 2, &[_]u8{}));
        if (i < s.len and s[i] == ':') {
            i += 1;
            dt.minute = @intCast(try readNumber(s, &i, 2, &[_]u8{}));
            if (i < s.len and s[i] == ':') {
                i += 1;
                dt.second = @intCast(try readNumber(s, &i, 2, &[_]u8{}));
                if (i < s.len and (s[i] == '.' or s[i] == ',')) {
                    i += 1;
                    var frac: u64 = 0;
                    var count: usize = 0;
                    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                        if (count < 9) {
                            frac = frac * 10 + (s[i] - '0');
                            count += 1;
                        }
                    }
                    if (count == 0) return error.InvalidDateTime;
                    while (count < 9) : (count += 1) frac *= 10;
                    dt.nanos = @intCast(frac);
                }
            }
        }
        // 允许尾随 'Z' 或时区偏移（值本身仍按本地无时区处理）
        if (i < s.len) {
            const rest = s[i..];
            if (!(rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z'))) {
                if (!(rest[0] == '+' or rest[0] == '-')) return error.InvalidDateTime;
            }
        }
        if (dt.month < 1 or dt.month > 12) return error.InvalidDateTime;
        if (dt.day < 1 or dt.day > 31) return error.InvalidDateTime;
        if (dt.hour > 23 or dt.minute > 59 or dt.second > 59) return error.InvalidDateTime;
        return dt;
    }

    fn readNumber(s: []const u8, i: *usize, want: usize, stop: []const u8) !u32 {
        var value: u32 = 0;
        var count: usize = 0;
        while (i.* < s.len and count < want) : (count += 1) {
            const c = s[i.*];
            if (c < '0' or c > '9') break;
            value = value * 10 + (c - '0');
            i.* += 1;
        }
        if (count == 0) return error.InvalidDateTime;
        if (count < want and stop.len == 0) {
            // 月/日/时/分/秒允许 1 位（如 "2026-1-5"）
            if (want != 2) return error.InvalidDateTime;
        }
        return value;
    }

    /// 输出 XCode 数据库格式：`YYYY-MM-DD HH:MM:SS.fffffff`（7 位小数秒）。
    pub fn formatAlloc(self: DateTime, gpa: std.mem.Allocator) ![]u8 {
        var scratch: [40]u8 = undefined;
        const text = try self.formatBuf(&scratch);
        return gpa.dupe(u8, text);
    }

    /// 写入固定缓冲（无分配；`out` 至少 32 字节）。
    pub fn formatBuf(self: DateTime, out: []u8) ![]const u8 {
        const ticks: u32 = self.nanos / 100; // 100ns
        return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>7}", .{
            @as(u32, @intCast(@max(self.year, 0))),
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
            ticks,
        });
    }

    /// 仅日期部分：`YYYY-MM-DD`。
    pub fn formatDateAlloc(self: DateTime, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            @as(u32, @intCast(@max(self.year, 0))),
            self.month,
            self.day,
        });
    }

    /// 当前本地时间（按系统时区偏移换算；无时区数据库场景够用）。
    pub fn nowLocal() DateTime {
        return fromUnixSeconds(nowUnix() + localOffsetSeconds());
    }

    /// 当前 UTC 时间。
    pub fn nowUtc() DateTime {
        return fromUnixSeconds(nowUnix());
    }

    /// 当前 Unix 秒（0.17 已移除 `std.time.timestamp`，这里直接问 Win32）。
    pub fn nowUnix() i64 {
        const builtin = @import("builtin");
        if (builtin.os.tag == .windows) {
            const win = struct {
                const FILETIME = extern struct { dwLowDateTime: u32, dwHighDateTime: u32 };
                extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
            };
            var ft: win.FILETIME = undefined;
            win.GetSystemTimeAsFileTime(&ft);
            const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime; // 100ns since 1601-01-01
            const epoch_diff: u64 = 116_444_736_000_000_000; // 1601→1970 的 100ns 数
            if (ticks < epoch_diff) return 0;
            return @intCast((ticks - epoch_diff) / 10_000_000);
        }
        return 0;
    }

    /// Unix 秒 → 日期时间（Howard Hinnant 的 civil_from_days 算法）。
    pub fn fromUnixSeconds(secs: i64) DateTime {
        const days: i64 = @divFloor(secs, 86400);
        const rem: i64 = @mod(secs, 86400);

        var z = days + 719468;
        const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
        const doe: u64 = @intCast(z - era * 146097);
        const yoe: u64 = (doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096)) / 365;
        z = @intCast(@as(i64, @intCast(yoe)) + era * 400);
        const doy: u64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: u64 = @divFloor(5 * doy + 2, 153);
        const day: u64 = doy - @divFloor(153 * mp + 2, 5) + 1;
        const month: u64 = if (mp < 10) mp + 3 else mp - 9;
        const year: i64 = z + @as(i64, if (month <= 2) 1 else 0);

        return .{
            .year = @intCast(year),
            .month = @intCast(month),
            .day = @intCast(day),
            .hour = @intCast(@divFloor(rem, 3600)),
            .minute = @intCast(@mod(@divFloor(rem, 60), 60)),
            .second = @intCast(@mod(rem, 60)),
            .nanos = 0,
        };
    }

    fn localOffsetSeconds() i64 {
        if (@import("builtin").os.tag == .windows) {
            const win = struct {
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
                    Bias: i32,
                    StandardName: [32]u16,
                    StandardDate: SYSTEMTIME,
                    StandardBias: i32,
                    DaylightName: [32]u16,
                    DaylightDate: SYSTEMTIME,
                    DaylightBias: i32,
                };
                extern "kernel32" fn GetTimeZoneInformation(lpTimeZoneInformation: *TIME_ZONE_INFORMATION) callconv(.winapi) u32;
            };
            var tz: win.TIME_ZONE_INFORMATION = undefined;
            // 返回 2 = 夏令时生效，需同时减去 DaylightBias
            const rc = win.GetTimeZoneInformation(&tz);
            var bias: i64 = tz.Bias;
            if (rc == 2) bias += tz.DaylightBias;
            return -bias * 60;
        }
        return 0;
    }

    /// 是否早于另一个时间。
    pub fn before(self: DateTime, other: DateTime) bool {
        if (self.year != other.year) return self.year < other.year;
        if (self.month != other.month) return self.month < other.month;
        if (self.day != other.day) return self.day < other.day;
        if (self.hour != other.hour) return self.hour < other.hour;
        if (self.minute != other.minute) return self.minute < other.minute;
        if (self.second != other.second) return self.second < other.second;
        return self.nanos < other.nanos;
    }

    pub fn eql(self: DateTime, other: DateTime) bool {
        return self.year == other.year and self.month == other.month and self.day == other.day and
            self.hour == other.hour and self.minute == other.minute and self.second == other.second and
            self.nanos == other.nanos;
    }
};

test "XCode 7 位小数秒往返" {
    const text = "2026-09-26 18:01:02.1230000";
    const dt = try DateTime.parse(text);
    try std.testing.expectEqual(@as(u32, 123_000_000), dt.nanos);
    const out = try dt.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(text, out);
}

test "无小数秒与纯日期" {
    try std.testing.expect((try DateTime.parse("2026-09-26 18:01:02")).eql(.{
        .year = 2026,
        .month = 9,
        .day = 26,
        .hour = 18,
        .minute = 1,
        .second = 2,
    }));
    try std.testing.expect((try DateTime.parse("2026-09-26")).eql(.{ .year = 2026, .month = 9, .day = 26 }));
    try std.testing.expect((try DateTime.parse("2026/09/26 08:00")).eql(.{
        .year = 2026,
        .month = 9,
        .day = 26,
        .hour = 8,
    }));
}

test "Unix 秒换算" {
    // 2026-09-26 18:01:02 UTC = 1790445662
    const dt = DateTime.fromUnixSeconds(1790445662);
    try std.testing.expectEqual(@as(i32, 2026), dt.year);
    try std.testing.expectEqual(@as(u8, 9), dt.month);
    try std.testing.expectEqual(@as(u8, 26), dt.day);
    try std.testing.expectEqual(@as(u8, 18), dt.hour);
    try std.testing.expectEqual(@as(u8, 1), dt.minute);
    try std.testing.expectEqual(@as(u8, 2), dt.second);
}

test "非法时间" {
    try std.testing.expectError(error.InvalidDateTime, DateTime.parse(""));
    try std.testing.expectError(error.InvalidDateTime, DateTime.parse("2026-13-01"));
}
