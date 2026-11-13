//! 轻量级 Cron 表达式（对齐 DH.NCore `Cron`）。
//!
//! 字段：`秒 分 时 日 月 周`，周支持 `#n`（第 n 个）与 `#Ln`（倒数第 n 个）。
//! 语法与 C# 版一致：
//! - `*` / `?`  全部值；
//! - `a-b`      区间；
//! - `a/b`      从 a 开始每 b 个；
//! - `a,b,c`    枚举；
//! - `2-5`、`0`、`*/2` 等。
//!
//! 周几采用 .NET 口径：**0 = 周日**，1 = 周一 … 6 = 周六。
//!
//! 实现用**位图**（秒/分 ≤59 用 u64，时 ≤23 / 日 ≤31 / 月 ≤12 用 u32/u16），
//! 判断与跳转都是 O(1)，避免 C# 版「逐秒扫描」在大跨度表达式上的开销。

const std = @import("std");

pub const Error = error{
    /// 字段个数不足或语法非法
    InvalidCron,
    /// 步进值为 0（C# 版会因此死循环，这里直接报错）
    ZeroStep,
};

/// 时间分量（本地/UTC 由调用方决定，本模块只做算术）。
pub const Civil = struct {
    year: i32,
    month: u8, // 1..12
    day: u8, // 1..31
    hour: u8, // 0..23
    minute: u8, // 0..59
    second: u8, // 0..59
    weekday: u8, // 0 = 周日
};

pub const Cron = struct {
    /// bit i = 第 i 秒
    seconds: u64 = 0,
    /// bit i = 第 i 分
    minutes: u64 = 0,
    /// bit i = 第 i 时
    hours: u32 = 0,
    /// bit (d-1) = 第 d 日
    days: u32 = 0,
    /// bit (m-1) = 第 m 月
    months: u16 = 0,
    /// bit i = 周几 i 出现在表达式里
    weekday_set: u8 = 0,
    /// 每个周几对应的「第几个」，0 = 不限制，正数 = 第 n 个，负数 = 倒数第 n 个
    weekday_index: [7]i8 = @splat(0),
    /// 原始表达式（`toString` 用）
    expression: []const u8 = "",

    /// 解析表达式。失败返回 `error.InvalidCron` / `error.ZeroStep`。
    pub fn parse(expression: []const u8) Error!Cron {
        var it = std.mem.tokenizeAny(u8, expression, " \t");
        const f_sec = it.next() orelse return Error.InvalidCron;
        const f_min = it.next() orelse "*";
        const f_hour = it.next() orelse "*";
        const f_day = it.next() orelse "*";
        const f_month = it.next() orelse "*";
        const f_week = it.next() orelse "*";

        var cron = Cron{ .expression = expression };
        cron.seconds = try parseSet(u64, f_sec, 0, 60);
        cron.minutes = try parseSet(u64, f_min, 0, 60);
        cron.hours = try parseSet(u32, f_hour, 0, 24);
        cron.days = try parseSet(u32, f_day, 1, 32);
        cron.months = try parseSet(u16, f_month, 1, 13);
        try cron.parseWeekdays(f_week);
        return cron;
    }

    /// 解析 `秒/分/时/日/月` 的位图：`start` 是允许的最小值，`end` 是**开区间上界**。
    fn parseSet(comptime T: type, text: []const u8, start: u32, end: u32) Error!T {
        var out: T = 0;

        // 逗号枚举：递归展开
        if (std.mem.indexOfScalar(u8, text, ',')) |_| {
            var it = std.mem.tokenizeAny(u8, text, ",");
            while (it.next()) |item| {
                out |= try parseSet(T, item, start, end);
            }
            return out;
        }

        var body = text;
        var step: u32 = 1;
        var has_step = false;
        if (std.mem.indexOfScalar(u8, body, '/')) |slash| {
            step = std.fmt.parseInt(u32, body[slash + 1 ..], 10) catch return Error.InvalidCron;
            if (step == 0) return Error.ZeroStep;
            has_step = true;
            body = body[0..slash];
        }

        var lo: u32 = start;
        var hi: u32 = end; // 开区间
        if (std.mem.eql(u8, body, "*") or std.mem.eql(u8, body, "?")) {
            lo = 0;
        } else if (std.mem.indexOfScalar(u8, body, '-')) |dash| {
            lo = std.fmt.parseInt(u32, body[0..dash], 10) catch return Error.InvalidCron;
            const b = std.fmt.parseInt(u32, body[dash + 1 ..], 10) catch return Error.InvalidCron;
            hi = b + 1;
        } else {
            lo = std.fmt.parseInt(u32, body, 10) catch return Error.InvalidCron;
            // `a/b` 的语义是「从 a 到上界每 b 个」；只有纯数字 `a` 才是单个值
            if (!has_step) hi = lo + 1;
        }

        var i = lo;
        while (i < hi) : (i += step) {
            if (i >= start and i < end) {
                // 位图按 `i - start` 归一：日/月的 start 是 1，而查询时用的是「值-1」
                const bit: std.math.Log2Int(T) = @intCast(i - start);
                out |= @as(T, 1) << bit;
            }
            if (i + step < i) break; // 防溢出兜底
        }
        return out;
    }

    /// 解析周几字段：支持 `*`、`?`、`a-b`、`a/b`、`a,b`、`n#k`、`n#Lk`。
    fn parseWeekdays(self: *Cron, text: []const u8) Error!void {
        if (std.mem.indexOfScalar(u8, text, ',')) |_| {
            var it = std.mem.tokenizeAny(u8, text, ",");
            while (it.next()) |item| try self.parseWeekdays(item);
            return;
        }

        var body = text;
        var step: u32 = 1;
        var has_step = false;
        if (std.mem.indexOfScalar(u8, body, '/')) |slash| {
            step = std.fmt.parseInt(u32, body[slash + 1 ..], 10) catch return Error.InvalidCron;
            if (step == 0) return Error.ZeroStep;
            has_step = true;
            body = body[0..slash];
        }

        // 第几个周几
        var index: i8 = 0;
        if (std.mem.indexOfScalar(u8, body, '#')) |hash| {
            const spec = body[hash + 1 ..];
            if (spec.len >= 2 and (spec[0] == 'L' or spec[0] == 'l')) {
                const n = std.fmt.parseInt(i8, spec[1..], 10) catch return Error.InvalidCron;
                index = -n;
            } else {
                index = std.fmt.parseInt(i8, spec, 10) catch return Error.InvalidCron;
            }
            body = body[0..hash];
            step = 7;
        }

        var lo: u32 = 0;
        var hi: u32 = 7; // 开区间
        if (std.mem.eql(u8, body, "*") or std.mem.eql(u8, body, "?")) {
            lo = 0;
            hi = 7;
        } else if (std.mem.indexOfScalar(u8, body, '-')) |dash| {
            lo = std.fmt.parseInt(u32, body[0..dash], 10) catch return Error.InvalidCron;
            const b = std.fmt.parseInt(u32, body[dash + 1 ..], 10) catch return Error.InvalidCron;
            hi = b + 1;
            step = 1;
        } else {
            lo = std.fmt.parseInt(u32, body, 10) catch return Error.InvalidCron;
            if (!has_step) hi = lo + 1;
        }

        var i = lo;
        while (i < hi) : (i += step) {
            if (i < 7) {
                const w: u3 = @intCast(i);
                self.weekday_set |= @as(u8, 1) << w;
                self.weekday_index[w] = index;
            }
            if (i + step < i) break;
        }
    }

    /// 指定时刻是否命中表达式。
    pub fn isTime(self: *const Cron, c: Civil) bool {
        if (c.second > 59 or c.minute > 59 or c.hour > 23) return false;
        if (self.seconds & (@as(u64, 1) << @intCast(c.second)) == 0) return false;
        if (self.minutes & (@as(u64, 1) << @intCast(c.minute)) == 0) return false;
        if (self.hours & (@as(u32, 1) << @intCast(c.hour)) == 0) return false;
        if (c.day < 1 or c.day > 31) return false;
        if (self.days & (@as(u32, 1) << @intCast(c.day - 1)) == 0) return false;
        if (c.month < 1 or c.month > 12) return false;
        if (self.months & (@as(u16, 1) << @intCast(c.month - 1)) == 0) return false;

        const w: u3 = @intCast(c.weekday % 7);
        if (self.weekday_set & (@as(u8, 1) << w) == 0) return false;

        const idx = self.weekday_index[w];
        if (idx > 0) {
            // 当月第几个该周几：每月 1~7 号正好各含一个，故可直接算
            const occ: i8 = @intCast((c.day - 1) / 7 + 1);
            if (occ != idx) return false;
        } else if (idx < 0) {
            // 从月末倒数：本月最后一天是第 1 个（倒序）
            const dim = daysInMonth(c.year, c.month);
            const occ: i8 = @intCast((dim - c.day) / 7 + 1);
            if (occ != -idx) return false;
        }
        return true;
    }

    /// 严格晚于 `after_unix` 的下一次命中（Unix 秒）。一年内无命中返回 null。
    pub fn nextAfter(self: *const Cron, after_unix: i64) ?i64 {
        var t = after_unix + 1;
        const limit = after_unix + 366 * 86400;
        while (t <= limit) {
            const c = civilFromUnix(t);

            if (self.months & (@as(u16, 1) << @intCast(c.month - 1)) == 0) {
                t = startOfNextMonth(t, c);
                continue;
            }
            if (!self.dayMatches(c)) {
                t = t + (86400 - daySeconds(c));
                continue;
            }
            if (self.hours & (@as(u32, 1) << @intCast(c.hour)) == 0) {
                t = t + (3600 - @as(i64, c.minute) * 60 - @as(i64, c.second));
                continue;
            }
            if (self.minutes & (@as(u64, 1) << @intCast(c.minute)) == 0) {
                t = t + (60 - @as(i64, c.second));
                continue;
            }
            if (self.seconds & (@as(u64, 1) << @intCast(c.second)) == 0) {
                t += 1;
                continue;
            }
            return t;
        }
        return null;
    }

    fn dayMatches(self: *const Cron, c: Civil) bool {
        if (self.days & (@as(u32, 1) << @intCast(c.day - 1)) == 0) return false;
        const w: u3 = @intCast(c.weekday % 7);
        if (self.weekday_set & (@as(u8, 1) << w) == 0) return false;
        const idx = self.weekday_index[w];
        if (idx > 0) {
            const occ: i8 = @intCast((c.day - 1) / 7 + 1);
            return occ == idx;
        } else if (idx < 0) {
            const dim = daysInMonth(c.year, c.month);
            const occ: i8 = @intCast((dim - c.day) / 7 + 1);
            return occ == -idx;
        }
        return true;
    }
};

fn daySeconds(c: Civil) i64 {
    return @as(i64, c.hour) * 3600 + @as(i64, c.minute) * 60 + @as(i64, c.second);
}

fn startOfNextMonth(t: i64, c: Civil) i64 {
    const dim = daysInMonth(c.year, c.month);
    return t + (86400 - daySeconds(c)) + @as(i64, dim - c.day) * 86400;
}

pub fn isLeap(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(year)) 29 else 28,
        else => 0,
    };
}

/// Unix 秒 → 年月日时分秒 + 周几（0 = 周日）。用 Hinnant 的 `civil_from_days`。
pub fn civilFromUnix(unix_sec: i64) Civil {
    const days = @divFloor(unix_sec, 86400);
    const sod: i64 = unix_sec - days * 86400;

    // 1970-01-01 是周四（.NET DayOfWeek: 周日=0 → 4）
    var weekday: u8 = @intCast(@mod(days + 4, 7));
    if (@mod(days + 4, 7) < 0) weekday = @intCast(@mod(days + 4, 7) + 7);

    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year: i32 = @intCast(if (m <= 2) y + 1 else y);

    return .{
        .year = year,
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(sod, 3600)),
        .minute = @intCast(@divFloor(@mod(sod, 3600), 60)),
        .second = @intCast(@mod(sod, 60)),
        .weekday = weekday,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "cron：基本字段解析与命中" {
    var c = try Cron.parse("0 0 2 * * 1-5");
    try testing.expect(c.isTime(.{ .year = 2026, .month = 11, .day = 13, .hour = 2, .minute = 0, .second = 0, .weekday = 5 }));
    // 2026-11-14 是周六
    try testing.expect(!c.isTime(.{ .year = 2026, .month = 11, .day = 14, .hour = 2, .minute = 0, .second = 0, .weekday = 6 }));
    // 秒不对
    try testing.expect(!c.isTime(.{ .year = 2026, .month = 11, .day = 13, .hour = 2, .minute = 0, .second = 1, .weekday = 5 }));
}

test "cron：步进与枚举" {
    const c = try Cron.parse("5/20 * * * * *");
    try testing.expect(c.isTime(.{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 5, .weekday = 4 }));
    try testing.expect(c.isTime(.{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 25, .weekday = 4 }));
    try testing.expect(c.isTime(.{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 45, .weekday = 4 }));
    try testing.expect(!c.isTime(.{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 6, .weekday = 4 }));

    const list = try Cron.parse("0,1,2 * * * * *");
    try testing.expect(list.isTime(.{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 2, .weekday = 4 }));
    try testing.expect(!list.isTime(.{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 3, .weekday = 4 }));
}

test "cron：步进 0 必须报错（C# 版会死循环）" {
    try testing.expectError(Error.ZeroStep, Cron.parse("*/0 * * * * *"));
}

test "cron：第 n 个 / 倒数第 n 个周几" {
    // 每月第一周的周一 00:00
    const first_mon = try Cron.parse("0 0 0 ? * 1#1");
    // 2026-11-02 是 11 月第一个周一
    try testing.expect(first_mon.isTime(.{ .year = 2026, .month = 11, .day = 2, .hour = 0, .minute = 0, .second = 0, .weekday = 1 }));
    try testing.expect(!first_mon.isTime(.{ .year = 2026, .month = 11, .day = 9, .hour = 0, .minute = 0, .second = 0, .weekday = 1 }));

    // 每月最后一个周五 00:00
    const last_fri = try Cron.parse("0 0 0 ? * 5#L1");
    // 2026-11-27 是 11 月最后一个周五
    try testing.expect(last_fri.isTime(.{ .year = 2026, .month = 11, .day = 27, .hour = 0, .minute = 0, .second = 0, .weekday = 5 }));
    try testing.expect(!last_fri.isTime(.{ .year = 2026, .month = 11, .day = 20, .hour = 0, .minute = 0, .second = 0, .weekday = 5 }));
}

test "cron：civilFromUnix 与闰年" {
    const c = civilFromUnix(0);
    try testing.expectEqual(@as(i32, 1970), c.year);
    try testing.expectEqual(@as(u8, 1), c.month);
    try testing.expectEqual(@as(u8, 1), c.day);
    try testing.expectEqual(@as(u8, 4), c.weekday); // 周四

    try testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try testing.expectEqual(@as(u8, 28), daysInMonth(2026, 2));
    try testing.expectEqual(@as(u8, 29), daysInMonth(2000, 2));
    try testing.expectEqual(@as(u8, 28), daysInMonth(1900, 2));
}

test "cron：nextAfter 跳转正确（不逐秒扫描）" {
    // 每年 1 月 1 日 00:00:00
    const yearly = try Cron.parse("0 0 0 1 1 *");
    // 从 2026-06-01 00:00:00 UTC 起算，下一次应为 2027-01-01 00:00:00
    const from: i64 = 1780272000; // 2026-06-01T00:00:00Z
    const next = yearly.nextAfter(from) orelse return error.TestUnexpectedResult;
    const civ = civilFromUnix(next);
    try testing.expectEqual(@as(i32, 2027), civ.year);
    try testing.expectEqual(@as(u8, 1), civ.month);
    try testing.expectEqual(@as(u8, 1), civ.day);
    try testing.expectEqual(@as(u8, 0), civ.hour);

    // 每分钟一次：应从 00:00:30 跳到 00:01:00
    const every_min = try Cron.parse("0 * * * * *");
    const n2 = every_min.nextAfter(from + 30) orelse return error.TestUnexpectedResult;
    const c2 = civilFromUnix(n2);
    try testing.expectEqual(@as(u8, 1), c2.minute);
    try testing.expectEqual(@as(u8, 0), c2.second);
}
