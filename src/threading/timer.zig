//! 定时器（对齐 DH.NCore `TimerX` + `TimerScheduler` 的“到点执行”语义）。
//!
//! 两部分：
//! 1. **每日时刻辅助**（原有）：`parseHhmm` / `parseSchedule` / `nextDelayMs` / `sleepUntilNext`；
//! 2. **调度器**（新增）：`Scheduler` + `Timer`，对齐 `TimerX` 的关键语义：
//!    - 周期定时器（`due_ms` + `period_ms`）、一次性（`period_ms <= 0`）；
//!    - 绝对定时器（`absolutely`，按墙上时钟对齐）；
//!    - Cron 定时器（`crons`，多个表达式取最近）；
//!    - **不可重入**：回调执行中不会被再次触发（`calling`）；
//!    - `cost_ms` 平均耗时、`timers` 调用次数、`max_cost_ms` 超时告警；
//!    - 周期 < 10ms 直接拒绝（对齐 `TimerX`，避免占满 CPU）；
//!    - 周期调度用**开机滴答**（`nowTickMs`），无惧系统时间回拨；
//!    - 调度线程名 `T`（对齐 `TimerScheduler` 名为 Default 时的 `WriteLogEventArgs.CurrentThreadName`）。
//!
//! 未对齐项（明确记录）：弱引用回收（Zig 无 GC）、链路追踪（`Tracer`）、多调度器分组、
//! 空闲 60s 销毁调度线程（这里调度线程随 `Scheduler` 生命周期，由 `deinit` 停止）。
//!
//! 线程安全：`add` / `remove` / `deinit` 与调度线程之间用 `compat.Mutex` + `Io.Condition` 保护。

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const level = @import("../logs/level.zig");
const cron_mod = @import("cron.zig");

pub const Cron = cron_mod.Cron;

/// 周期下限：小于它直接拒绝（对齐 TimerX「禁止小于 10ms 的任务调度」）。
pub const min_period_ms: i64 = 10;

/// 默认超时告警阈值（毫秒）
pub const default_max_cost_ms: i64 = 500;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// 开机以来的毫秒数（Windows = `GetTickCount64`，其它平台用单调时钟 `.awake`）。
///
/// 用开机滴答做周期调度，系统时间被向前/向后改都不会影响定时精度。
pub fn nowTickMs(io: std.Io) i64 {
    if (builtin.os.tag == .windows) return @intCast(GetTickCount64());
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

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

// ===========================================================================
// 调度器（对齐 DH.NCore TimerX / TimerScheduler）
// ===========================================================================

pub const TimerCallback = *const fn (ctx: ?*anyopaque) void;

/// 触发方式
pub const Kind = enum {
    /// 周期（`period_ms > 0`）
    period,
    /// 一次性（触发后自动移除）
    once,
    /// 绝对时刻 + 周期（按墙上时钟对齐）
    absolute,
    /// Cron 表达式（多个取最近）
    cron,
};

/// 一个定时器。由调用方持有（**不要**放在会被移动的栈变量上，调度器保存其指针）。
pub const Timer = struct {
    callback: TimerCallback,
    ctx: ?*anyopaque = null,

    kind: Kind = .period,
    /// 周期（毫秒）；`<= 0` 表示只跑一次
    period_ms: i64 = 0,
    /// 周期/一次性：下一次的开机滴答（毫秒）
    next_tick: i64 = 0,
    /// 绝对/Cron：下一次的 Unix 毫秒
    next_unix_ms: i64 = 0,
    /// Cron 表达式
    crons: []const Cron = &.{},

    /// 回调执行中 → 不可重入
    calling: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 累计执行次数
    timers: u64 = 0,
    /// 平均耗时（毫秒）：`cost = cost==0 ? ms : (cost+ms)/2`（同 TimerX）
    cost_ms: i64 = 0,
    /// 已从调度器移除
    removed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 所属调度器（`add` 时设置）
    sched: ?*Scheduler = null,

    /// 周期定时器：`due_ms` 之后首次触发，之后每 `period_ms` 一次。
    pub fn period(cb: TimerCallback, ctx: ?*anyopaque, due_ms: i64, period_ms: i64) !Timer {
        // `<= 0` 均为一次性（对齐 TimerX：period 0 或 -1 只调用一次）
        if (period_ms > 0 and period_ms < min_period_ms) return error.PeriodTooSmall;
        if (due_ms < 0) return error.InvalidDue;
        return .{
            .callback = cb,
            .ctx = ctx,
            .kind = if (period_ms > 0) .period else .once,
            .period_ms = period_ms,
            .next_tick = due_ms, // 相对于「加入时的 now」，由 Scheduler.add 换算成绝对滴答
        };
    }

    /// 绝对定时器：从 `start_unix_ms` 起每 `period_ms` 一次（早于当前时刻会自动对齐到未来）。
    pub fn absolute(cb: TimerCallback, ctx: ?*anyopaque, start_unix_ms: i64, period_ms: i64) !Timer {
        if (period_ms < min_period_ms) return error.PeriodTooSmall;
        return .{
            .callback = cb,
            .ctx = ctx,
            .kind = .absolute,
            .period_ms = period_ms,
            .next_unix_ms = start_unix_ms,
        };
    }

    /// Cron 定时器：多个表达式取最近一次。
    pub fn cron(cb: TimerCallback, ctx: ?*anyopaque, crons: []const Cron) !Timer {
        if (crons.len == 0) return error.EmptySchedule;
        return .{ .callback = cb, .ctx = ctx, .kind = .cron, .crons = crons };
    }

    /// 下次到期对应的开机滴答（把绝对/Cron 的墙上时刻换算成滴答）。
    fn dueTick(t: *const Timer, now_tick: i64, now_unix_ms: i64) i64 {
        return switch (t.kind) {
            .period, .once => t.next_tick,
            .absolute, .cron => now_tick + @max(t.next_unix_ms - now_unix_ms, 0),
        };
    }

    /// 触发后计算下一次（对齐 `SetAndGetNextTime`：**本次执行完成后**才开始计时）。
    /// 返回 false 表示不再触发。
    fn scheduleNext(t: *Timer, now_tick: i64, now_unix_ms: i64) bool {
        switch (t.kind) {
            .once => return false,
            .period => {
                t.next_tick = now_tick + t.period_ms;
                return true;
            },
            .absolute => {
                var next = t.next_unix_ms + t.period_ms;
                while (next <= now_unix_ms) next += t.period_ms;
                t.next_unix_ms = next;
                return true;
            },
            .cron => {
                const from_sec = @divFloor(now_unix_ms, 1000);
                var best: ?i64 = null;
                for (t.crons) |*c| {
                    if (c.nextAfter(from_sec)) |n| {
                        if (best == null or n < best.?) best = n;
                    }
                }
                if (best) |b| {
                    t.next_unix_ms = b * 1000;
                    return true;
                }
                return false;
            },
        }
    }
};

/// 调度器：一个后台线程 + 一组定时器。
///
/// ```zig
/// const sched = try Scheduler.start(io, gpa);
/// defer sched.deinit();
/// var t = try Timer.period(onTick, null, 100, 1000);
/// try sched.add(&t);
/// ```
pub const Scheduler = struct {
    io: std.Io,
    alloc: std.mem.Allocator,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    timers: std.ArrayListUnmanaged(*Timer) = .empty,

    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// 单次执行超过它就告警（对齐 `MaxCost`，默认 500ms）
    max_cost_ms: i64 = default_max_cost_ms,

    pub fn start(io: std.Io, gpa: std.mem.Allocator) !*Scheduler {
        const self = try gpa.create(Scheduler);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .alloc = gpa };
        self.thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, loop, .{self});
        return self;
    }

    /// 停止调度线程并释放（不会等待正在执行的回调）。
    pub fn deinit(self: *Scheduler) void {
        const gpa = self.alloc;
        const io = self.io;
        self.stopping.store(true, .release);
        std.Io.Condition.broadcast(&self.cond, io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.timers.deinit(gpa);
        gpa.destroy(self);
    }

    /// 加入定时器。周期/一次性会用**加入时刻**把相对 `due_ms` 换算成绝对滴答。
    pub fn add(self: *Scheduler, t: *Timer) !void {
        t.removed.store(false, .release);
        if (t.kind == .period or t.kind == .once) {
            t.next_tick = nowTickMs(self.io) + t.next_tick;
        }
        if (t.kind == .absolute) {
            const now_unix_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            var next = t.next_unix_ms;
            while (next <= now_unix_ms) next += t.period_ms;
            t.next_unix_ms = next;
        }
        if (t.kind == .cron) {
            if (!Timer.scheduleNext(t, 0, std.Io.Timestamp.now(self.io, .real).toMilliseconds())) {
                return error.NoFutureOccurrence;
            }
        }
        t.sched = self;

        self.mutex.lockUncancelable(self.io);
        try self.timers.append(self.alloc, t);
        std.Io.Condition.signal(&self.cond, self.io);
        self.mutex.unlock(self.io);
    }

    /// 移除定时器（幂等）。
    pub fn remove(self: *Scheduler, t: *Timer) void {
        t.removed.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        for (self.timers.items, 0..) |item, i| {
            if (item == t) {
                _ = self.timers.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock(self.io);
    }

    pub fn count(self: *Scheduler) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.timers.items.len;
    }

    fn loop(self: *Scheduler) void {
        // 对齐 TimerScheduler：默认调度器（Default）的调度线程名就是 `T`
        level.setThreadName("T");

        var due: [64]*Timer = undefined;

        while (!self.stopping.load(.acquire)) {
            const now_tick = nowTickMs(self.io);
            const now_unix_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();

            var due_n: usize = 0;
            var wait_ms: i64 = 60_000;

            self.mutex.lockUncancelable(self.io);
            for (self.timers.items) |t| {
                const deadline = t.dueTick(now_tick, now_unix_ms);
                const delta = deadline - now_tick;
                if (delta <= 0) {
                    // 已在执行中的（不可重入）跳过，不再累积
                    if (!t.calling.load(.acquire) and due_n < due.len) {
                        due[due_n] = t;
                        due_n += 1;
                    }
                } else if (delta < wait_ms) {
                    wait_ms = delta;
                }
            }

            // 注意：`Condition.waitTimeout` **要求调用时持有互斥量**（内部先注册 waiter 再解锁，
            // 返回前会重新加锁）。所以必须保持在锁内调用，不能先 unlock。
            if (due_n == 0) {
                _ = std.Io.Condition.waitTimeout(&self.cond, self.io, &self.mutex, .{
                    .duration = .{
                        .raw = .{ .nanoseconds = @as(i96, wait_ms) * std.time.ns_per_ms },
                        .clock = .awake,
                    },
                }) catch {};
                self.mutex.unlock(self.io);
                continue;
            }

            self.mutex.unlock(self.io);

            // 标记后**立即解锁**再执行回调：回调里可以增删定时器，不会自锁
            for (due[0..due_n]) |t| t.calling.store(true, .release);

            for (due[0..due_n]) |t| {
                if (t.removed.load(.acquire)) {
                    t.calling.store(false, .release);
                    continue;
                }
                const t0 = nowTickMs(self.io);
                t.callback(t.ctx);
                const cost = nowTickMs(self.io) - t0;

                t.cost_ms = if (t.cost_ms == 0) cost else @divTrunc(t.cost_ms + cost, 2);
                t.timers += 1;
                if (cost > self.max_cost_ms) {
                    std.debug.print(
                        "[zzig.timer] 定时任务耗时过长 {d}ms（阈值 {d}ms，累计 {d} 次）\n",
                        .{ cost, self.max_cost_ms, t.timers },
                    );
                }

                const after_tick = nowTickMs(self.io);
                const after_unix = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
                if (!Timer.scheduleNext(t, after_tick, after_unix)) {
                    self.remove(t);
                }
                t.calling.store(false, .release);
            }
        }
    }
};

// ---------------------------------------------------------------------------

const timer_testing = std.testing;

const TickCounter = struct {
    runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    concurrent: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_concurrent: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    overlap: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn onTick(ctx: ?*anyopaque) void {
    const c: *TickCounter = @ptrCast(@alignCast(ctx.?));
    const cur = c.concurrent.fetchAdd(1, .acq_rel) + 1;
    if (cur > 1) _ = c.overlap.fetchAdd(1, .acq_rel);
    // 记录并发峰值
    var prev = c.max_concurrent.load(.acquire);
    while (cur > prev) {
        prev = c.max_concurrent.cmpxchgWeak(prev, cur, .acq_rel, .acquire) orelse break;
    }
    // 故意耗时，验证「不可重入」
    compat.sleep(5 * std.time.ns_per_ms);
    _ = c.concurrent.fetchSub(1, .acq_rel);
    _ = c.runs.fetchAdd(1, .acq_rel);
}

/// 有界等待
fn waitRuns(c: *TickCounter, target: u32, max_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < max_ms) : (waited += 1) {
        if (c.runs.load(.acquire) >= target) return true;
        compat.sleep(1 * std.time.ns_per_ms);
    }
    return c.runs.load(.acquire) >= target;
}

test "timer：周期定时器按周期重复触发" {
    const sched = try Scheduler.start(timer_testing.io, timer_testing.allocator);
    defer sched.deinit();

    var c = TickCounter{};
    var t = try Timer.period(onTick, &c, 10, 20);
    try sched.add(&t);
    defer sched.remove(&t);

    try timer_testing.expect(waitRuns(&c, 3, 3000));
    try timer_testing.expect(c.runs.load(.acquire) >= 3);
    // 不可重入：回调里 sleep 5ms < 周期 20ms，不应有并发重叠
    try timer_testing.expectEqual(@as(u32, 0), c.overlap.load(.acquire));
}

test "timer：一次性定时器只跑一次并自动移除" {
    const sched = try Scheduler.start(timer_testing.io, timer_testing.allocator);
    defer sched.deinit();

    var c = TickCounter{};
    var t = try Timer.period(onTick, &c, 10, 0); // period 0 → once
    try sched.add(&t);

    try timer_testing.expect(waitRuns(&c, 1, 3000));
    compat.sleep(120 * std.time.ns_per_ms);
    try timer_testing.expectEqual(@as(u32, 1), c.runs.load(.acquire));
    try timer_testing.expectEqual(@as(usize, 0), sched.count());
}

test "timer：周期小于 10ms 直接拒绝（对齐 TimerX）" {
    try timer_testing.expectError(error.PeriodTooSmall, Timer.period(onTick, null, 0, 5));
}

test "timer：Cron 定时器能算出未来触发点（不早于当前）" {
    const crons = [_]Cron{try Cron.parse("* * * * * *")}; // 每秒
    var t = try Timer.cron(onTick, null, &crons);
    const now_unix_ms = std.Io.Timestamp.now(timer_testing.io, .real).toMilliseconds();
    try timer_testing.expect(Timer.scheduleNext(&t, 0, now_unix_ms));
    try timer_testing.expect(t.next_unix_ms > now_unix_ms);
    try timer_testing.expect(t.next_unix_ms - now_unix_ms <= 2000);
}
