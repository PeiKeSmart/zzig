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
const pool_mod = @import("pool.zig");

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

/// 链路追踪钩子（对齐 DH.NCore `TimerX.Tracer` 的 `NewSpan` 语义）。
///
/// 用法：把自研打点 / OpenTelemetry / 你家的 APM 包在这两个回调里。
/// `begin` 返回的 `span` 会原样传给 `end`（可为 null）。
///
/// 注意：`TimerCallback` 返回 `void`（Zig 回调不携带错误），
/// 因此 `end` 的 `failed` 目前恒为 `false` —— 要标错得由业务在回调里自行记录。
pub const Tracer = struct {
    ctx: ?*anyopaque = null,
    /// 回调执行前调用，返回一个可选的 span 句柄
    begin: *const fn (ctx: ?*anyopaque, name: []const u8) ?*anyopaque,
    /// 回调执行后调用（`elapsed_us` 为微秒）
    end: *const fn (ctx: ?*anyopaque, span: ?*anyopaque, elapsed_us: i64, failed: bool) void,
};

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

    /// 是否异步执行（对齐 TimerX 的 `Async`）：
    ///
    /// - `false`（默认）：在调度线程内联执行 —— 与 TimerX 的 `Async=false` 一致，
    ///   但**慢回调会阻塞其它所有定时器**；
    /// - `true`：提交到 `Scheduler` 绑定的弹性线程池（`setPool`）；
    ///   池未绑定或提交失败（队列满）时**回退内联**，绝不丢这一轮触发。
    async: bool = false,

    /// 回调执行中 → 不可重入
    calling: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 累计执行次数
    timers: u64 = 0,
    /// 平均耗时（毫秒）：`cost = cost==0 ? ms : (cost+ms)/2`（同 TimerX）
    ///
    /// **精度限制**：耗时用开机滴答测量（Windows 为 `GetTickCount64`），
    /// 粒度约 1~15.6ms（取决于系统时钟中断）。短于一个滴答的回调可能被计为 0ms，
    /// 因此 `max_cost_ms` 告警只适合拓粗粒度异常，不适合当微基准。
    cost_ms: i64 = 0,
    /// 已从调度器移除
    removed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 所属调度器（`add` 时设置）
    sched: ?*Scheduler = null,
    /// 链路追踪钩子（null = 不追踪）
    tracer: ?Tracer = null,
    /// 追踪名（空则用 `"timer"`）
    tracer_name: []const u8 = "",

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
    /// 调度器名。`"Default"` 的调度线程名对齐 DH.NCore 为 `T`，其它名字直接用名字。
    name: []const u8 = "Default",

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    timers: std.ArrayListUnmanaged(*Timer) = .empty,

    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// 单次执行超过它就告警（对齐 `MaxCost`，默认 500ms）
    max_cost_ms: i64 = default_max_cost_ms,
    /// `Timer.async = true` 时使用的线程池（由调用方创建与销毁）
    pool: ?*pool_mod.Pool = null,

    pub fn start(io: std.Io, gpa: std.mem.Allocator) !*Scheduler {
        return startNamed(io, gpa, "Default");
    }

    /// 创建**命名**调度器（多调度器分组的基本单位）。
    ///
    /// 分组的意义：某组的慢回调（即使已用 `async`）不该与其它组的高频定时器
    /// 抢同一条调度线程。每组一条调度线程，互不干扰。
    ///
    /// 需要“同名复用”请用 [`createNamed`]。
    pub fn startNamed(io: std.Io, gpa: std.mem.Allocator, name: []const u8) !*Scheduler {
        const self = try gpa.create(Scheduler);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .alloc = gpa, .name = name };
        self.thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, loop, .{self});
        return self;
    }

    /// 停止调度线程并释放（不会等待正在执行的回调）。
    pub fn deinit(self: *Scheduler) void {
        // 先摘注册表，避免 `shutdownAll()` 拿到野指针
        unregisterFromRegistry(self);

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

    /// 绑定线程池后，`Timer.async = true` 的回调会在线程池里执行。
    ///
    /// **生命周期顺序（重要）**：池必须比 `Scheduler` **先销毁**（或至少先停止），
    /// 否则池线程可能正在执行回调并访问已释放的 `Scheduler`（use-after-free）。
    pub fn setPool(self: *Scheduler, pool: ?*pool_mod.Pool) void {
        self.pool = pool;
    }

    /// 内联执行一次触发（同步路径与异步回退共用）。
    fn runInline(self: *Scheduler, t: *Timer) void {
        const t0 = nowTickMs(self.io);

        // 链路追踪：begin → 回调 → end（对应 TimerX 的 `Tracer.NewSpan`）
        var span: ?*anyopaque = null;
        const trace_name = if (t.tracer_name.len > 0) t.tracer_name else "timer";
        if (t.tracer) |tr| span = tr.begin(tr.ctx, trace_name);

        t.callback(t.ctx);

        const cost = nowTickMs(self.io) - t0;
        if (t.tracer) |tr| tr.end(tr.ctx, span, cost * 1000, false);

        self.finishRun(t, cost);
    }

    /// 执行完毕：记耗时/次数 → 算下一次 → 必要时移除。
    ///
    /// 会在**线程池线程**上被调用，所以对 `next_*` 的读写在 mutex 内，
    /// 与调度线程的 `dueTick` 读取互斥。
    fn finishRun(self: *Scheduler, t: *Timer, cost: i64) void {
        var drop = false;
        self.mutex.lockUncancelable(self.io);
        t.cost_ms = if (t.cost_ms == 0) cost else @divTrunc(t.cost_ms + cost, 2);
        t.timers +%= 1;
        const after_tick = nowTickMs(self.io);
        const after_unix = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        drop = !Timer.scheduleNext(t, after_tick, after_unix);
        self.mutex.unlock(self.io);

        if (cost > self.max_cost_ms) {
            std.debug.print(
                "[zzig.timer] 定时任务耗时过长 {d}ms（阈值 {d}ms，累计 {d} 次）\n",
                .{ cost, self.max_cost_ms, t.timers },
            );
        }
        if (drop) self.remove(t);
        t.calling.store(false, .release);

        // **必须唤醒调度线程**：异步回调完成后，调度线程可能正因该定时器
        // “due 但 calling”而无所事事地长睡 60s（同步路径下不可能出现，异步路径下每轮都会）。
        std.Io.Condition.signal(&self.cond, self.io);
    }

    fn loop(self: *Scheduler) void {
        // 对齐 TimerScheduler：默认调度器（Default）的调度线程名就是 `T`，
        // 其余分组直接用分组名（排查时能一眼看出哪个调度器在跑）。
        if (self.name.len == 0 or std.mem.eql(u8, self.name, "Default")) {
            level.setThreadName("T");
        } else {
            level.setThreadName(self.name);
        }

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
                    // 已在执行中的（不可重入）跳过，不再累积。
                    // 注意：这里也要把 wait_ms 降下来 —— 否则“due 但 calling”会让本轮
                    // 退化成 60s 长睡（异步回调完成后靠 `finishRun` 的 signal 唤醒）。
                    if (!t.calling.load(.acquire) and due_n < due.len) {
                        due[due_n] = t;
                        due_n += 1;
                    } else {
                        wait_ms = @min(wait_ms, 1);
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
            for (due[0..due_n]) |t| {
                t.calling.store(true, .release);
                if (t.removed.load(.acquire)) {
                    t.calling.store(false, .release);
                    continue;
                }

                // Async：交给池，慢回调不会阻塞调度线程（对齐 TimerX 的 Async）。
                // 池未绑定 / 队列满 → 回退内联，绝不丢这一轮触发。
                if (t.async) {
                    if (self.pool) |pool| {
                        pool.submit(runTimerAsync, t) catch self.runInline(t);
                        continue;
                    }
                }
                self.runInline(t);
            }
        }
    }
};

/// 池任务入口：`ctx` 就是 `*Timer`。
fn runTimerAsync(ctx: *anyopaque) void {
    const t: *Timer = @ptrCast(@alignCast(ctx));
    const sched = t.sched orelse {
        t.calling.store(false, .release);
        return;
    };
    sched.runInline(t);
}

// ===========================================================================
// 多调度器分组（对齐 DH.NCore `TimerScheduler.Create(name)`）
// ===========================================================================
//
// 注册表固定用 `page_allocator`：它不依赖调用方 allocator（避免与业务 allocator
// 的生命周期纠缠），名字由注册表 dupe 持有并在 `shutdownAll()` 里统一释放。

var registry_mutex: compat.Mutex = .{};
var registry: std.ArrayListUnmanaged(*Scheduler) = .empty;

/// 按名字创建或复用调度器（同名返回同一实例）。
pub fn createNamed(io: std.Io, gpa: std.mem.Allocator, name: []const u8) !*Scheduler {
    registry_mutex.lock();
    for (registry.items) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            registry_mutex.unlock();
            return s;
        }
    }
    registry_mutex.unlock();

    const owned_name = try std.heap.page_allocator.dupe(u8, name);
    errdefer std.heap.page_allocator.free(owned_name);

    const sched = try Scheduler.startNamed(io, gpa, owned_name);

    registry_mutex.lock();
    // 并发下可能别人先建了同名：若已存在则以先建的为准，销毁自己刚建的
    for (registry.items) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            registry_mutex.unlock();
            sched.deinit();
            std.heap.page_allocator.free(owned_name);
            return s;
        }
    }
    registry.append(std.heap.page_allocator, sched) catch {
        registry_mutex.unlock();
        sched.deinit();
        return error.OutOfMemory;
    };
    registry_mutex.unlock();
    return sched;
}

/// 取已存在的命名调度器（不存在返回 null）。
pub fn get(name: []const u8) ?*Scheduler {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    for (registry.items) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// 已注册的调度器数量（可观测）。
pub fn schedulerCount() usize {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    return registry.items.len;
}

fn unregisterFromRegistry(sched: *Scheduler) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    for (registry.items, 0..) |s, i| {
        if (s == sched) {
            _ = registry.swapRemove(i);
            return;
        }
    }
}

/// 销毁所有已注册的调度器（进程退出前调用）。
pub fn shutdownAll() void {
    registry_mutex.lock();
    const items = registry;
    registry = .empty;
    registry_mutex.unlock();

    for (items.items) |s| {
        // `deinit` 会释放 Scheduler 自身，名字要在之前抓住
        const name_ptr: []const u8 = s.name;
        s.deinit();
        std.heap.page_allocator.free(@constCast(name_ptr));
    }
    std.heap.page_allocator.free(items.items);
}

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

const AsyncProbe = struct {
    runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    saw_pool_worker: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn onTickAsync(ctx: ?*anyopaque) void {
    const p: *AsyncProbe = @ptrCast(@alignCast(ctx.?));
    if (level.isPoolWorker()) _ = p.saw_pool_worker.fetchAdd(1, .acq_rel);
    _ = p.runs.fetchAdd(1, .acq_rel);
}

test "timer：Async 回调跑在线程池里（不占调度线程）" { // 注意销毁顺序（LIFO）：先 remove → 再 pool.destroy（join 掉 worker）→ 最后 sched.deinit，
    // 否则池线程可能访问已释放的 Scheduler。
    const sched = try Scheduler.start(timer_testing.io, timer_testing.allocator);
    defer sched.deinit();

    const pool = try pool_mod.Pool.create(timer_testing.io, timer_testing.allocator, .{
        .min_workers = 1,
        .max_workers = 2,
        .idle_timeout_ms = 0,
        .queue_capacity = 64,
    });
    defer pool.destroy();
    sched.setPool(pool);

    var p = AsyncProbe{};
    var t = try Timer.period(onTickAsync, &p, 10, 20);
    t.async = true;
    try sched.add(&t);
    defer sched.remove(&t);

    var waited: u32 = 0;
    while (waited < 3000) : (waited += 1) {
        if (p.runs.load(.acquire) >= 2) break;
        compat.sleep(1 * std.time.ns_per_ms);
    }
    try timer_testing.expect(p.runs.load(.acquire) >= 2);
    // 至少有一次确实跑在池 worker 上（Kind=Y 的来源），而不是调度线程
    try timer_testing.expect(p.saw_pool_worker.load(.acquire) >= 1);
}

const TraceProbe = struct {
    begins: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ends: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_us: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
};

fn trBegin(ctx: ?*anyopaque, name: []const u8) ?*anyopaque {
    _ = name;
    const p: *TraceProbe = @ptrCast(@alignCast(ctx.?));
    _ = p.begins.fetchAdd(1, .acq_rel);
    return p;
}

fn trEnd(ctx: ?*anyopaque, span: ?*anyopaque, elapsed_us: i64, failed: bool) void {
    _ = ctx;
    _ = failed;
    const p: *TraceProbe = @ptrCast(@alignCast(span.?));
    p.last_us.store(elapsed_us, .release);
    _ = p.ends.fetchAdd(1, .acq_rel);
}

const SlowProbe = struct {
    runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn onTickSlow(ctx: ?*anyopaque) void {
    const p: *SlowProbe = @ptrCast(@alignCast(ctx.?));
    // 睡 30ms：远大于时钟粒度（1~15.6ms），耗时统计才有意义
    compat.sleep(30 * std.time.ns_per_ms);
    _ = p.runs.fetchAdd(1, .acq_rel);
}

test "timer：Tracer 在每次触发前后各调一次" {
    const sched = try Scheduler.start(timer_testing.io, timer_testing.allocator);
    defer sched.deinit();

    var c = SlowProbe{};
    var tp = TraceProbe{};
    var t = try Timer.period(onTickSlow, &c, 10, 100);
    t.tracer = .{ .ctx = &tp, .begin = trBegin, .end = trEnd };
    t.tracer_name = "test:tick";
    try sched.add(&t);
    defer sched.remove(&t);

    var waited: u32 = 0;
    while (waited < 3000) : (waited += 1) {
        if (tp.ends.load(.acquire) >= 1) break;
        compat.sleep(1 * std.time.ns_per_ms);
    }
    try timer_testing.expect(tp.begins.load(.acquire) >= 1);
    try timer_testing.expect(tp.ends.load(.acquire) >= 1);
    // 回调里睡 30ms；时钟粒度 ≤ 15.6ms，所以至少能测到 15ms
    try timer_testing.expect(tp.last_us.load(.acquire) >= 15_000);
}

test "timer：多调度器分组（同名复用 + 计数 + get）" {
    const s1 = try createNamed(timer_testing.io, timer_testing.allocator, "zzig-test-group");
    const s2 = try createNamed(timer_testing.io, timer_testing.allocator, "zzig-test-group");
    defer shutdownAll();

    try timer_testing.expectEqual(s1, s2);
    try timer_testing.expectEqual(@as(usize, 1), schedulerCount());
    try timer_testing.expect(get("zzig-test-group") == s1);
    try timer_testing.expect(get("not-exist") == null);
}
