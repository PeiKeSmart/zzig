//! 定时器辅助（对齐 DH.RustBase `TimerX/TimerScheduler` 的“到点执行”语义）。
//!
//! 本项目只做常驻进程需要的最小集合：
//! - `parseHhmm`：解析 `HH:MM`（0..23:00..59）；
//! - `nextDelayMs`：给定“每天的触发点（秒）”和当前时间，算下一次触发的毫秒数。
//! 时间基准统一 UTC（与项目日志/快照时间一致）。

const std = @import("std");

pub const day_ms: u64 = 24 * 60 * 60 * 1000;

pub fn parseHhmm(text: []const u8) !u32 {
    const t = std.mem.trim(u8, text, " \t");
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return error.InvalidTime;
    const h = std.fmt.parseInt(u32, t[0..colon], 10) catch return error.InvalidTime;
    const m = std.fmt.parseInt(u32, t[colon + 1 ..], 10) catch return error.InvalidTime;
    if (h > 23 or m > 59) return error.InvalidTime;
    return h * 3600 + m * 60;
}

/// 解析 `["02:30","14:00"]`；返回按从早到晚排序的“当天秒数”。
pub fn parseSchedule(allocator: std.mem.Allocator, times: []const []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    for (times) |t| try out.append(allocator, try parseHhmm(t));
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return out.toOwnedSlice(allocator);
}

/// 当前时刻距下一次触发的毫秒数。
pub fn nextDelayMs(now_ms: i64, times_sec: []const u32) !u64 {
    if (times_sec.len == 0) return error.EmptySchedule;
    const day: u64 = @intCast(@mod(now_ms, @as(i64, @intCast(day_ms))));
    for (times_sec) |t| {
        const target: u64 = @as(u64, t) * 1000;
        if (target > day) return target - day;
    }
    return day_ms - day + @as(u64, times_sec[0]) * 1000;
}

/// 阻塞等待到下一次触发；返回被触发的“当天秒数”。
pub fn sleepUntilNext(io: std.Io, times_sec: []const u32) !u32 {
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const delay = try nextDelayMs(now, times_sec);
    std.Io.sleep(io, .{ .nanoseconds = @as(i96, @intCast(delay)) * std.time.ns_per_ms }, .awake) catch {};
    const after = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const sod: u64 = @intCast(@mod(after, @as(i64, @intCast(day_ms))));
    // 找到刚刚越过（或最接近）的触发点
    var chosen: u32 = times_sec[0];
    for (times_sec) |t| {
        if (@as(u64, t) * 1000 <= sod) chosen = t;
    }
    return chosen;
}

const testing = std.testing;

test "timer: 解析与下一次触发" {
    try testing.expectEqual(@as(u32, 2 * 3600 + 30 * 60), try parseHhmm("02:30"));
    try testing.expectError(error.InvalidTime, parseHhmm("24:00"));
    try testing.expectError(error.InvalidTime, parseHhmm("x"));

    const times = [_]u32{ 2 * 3600, 14 * 3600 };
    // 当天 01:00 → 02:00
    try testing.expectEqual(@as(u64, 3600 * 1000), try nextDelayMs(3600 * 1000, &times));
    // 当天 03:00 → 当天 14:00
    try testing.expectEqual(@as(u64, 11 * 3600 * 1000), try nextDelayMs(3 * 3600 * 1000, &times));
    // 当天 15:00 → 次日 02:00
    try testing.expectEqual(@as(u64, 11 * 3600 * 1000), try nextDelayMs(15 * 3600 * 1000, &times));
}
