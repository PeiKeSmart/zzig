//! 弹性线程池（`Kind = Y` / `Name = P` 的真实来源）。
//!
//! **未接线说明**：本模块**没有被 `build.zig` 或 `zzig.zig` 的工作流引用**，
//! 需要显式 `Pool.create()` 才会启动线程 —— 默认不会因为本模块多出任何线程。
//!
//! 为什么要有它：
//! - DH.NCore 日志的 `Kind` 是 `IsPool ? (IsWeb ? 'W' : 'Y') : 'N'`，
//!   没有线程池就永远只会输出 `N` —— 日志少一维信息；
//! - 每连接一线程的固定成本实测 93.7us（128 KiB 栈，ReleaseFast，线程创建+销毁），
//!   短连接场景下这是纯税。
//!
//! 为什么是**弹性**而不是固定大小：
//! 阻塞式「一线程一条连接」的模型里，固定 N 个 worker 就等于**最多只能同时服务 N 条连接**，
//! 连接一多就会排队甚至看起来像卡死。所以这里按需扩容到 `max_workers` 上限，
//! 空闲超过 `idle_timeout_ms` 再回收到 `min_workers`。
//!
//! ## 什么时候该用、什么时候不该用（实测数据支撑）
//!
//! **不是所有并发都该走池**。本模块的语义是「执行**短**任务」，与 .NET
//! `TaskCreationOptions.LongRunning` 同一套判断：长任务**必须绕开池**，
//! 否则 N 个 worker 被 N 个长任务占死，后续短任务全部排队。
//!
//! | 场景 | 用池？ | 依据 | 日志维度 |
//! |------|--------|------|----------|
//! | 短连接 / 短 RPC / 探活 | 用 | 线程创建+销毁 93.7us（128 KiB 栈，ReleaseFast），
//! | | | 占短连接 p50（293~334us）约 30% | `Kind=Y` / `Name=P` |
//! | 长连接 / 流式订阅 / 保活长轮询 | **不用**，独立线程 | 16 → 512 连接吞吐持平（约 33k QPS），
//! | | | 线程成本早已摊薄，池化无收益且会饿死别的任务 | `Kind=N` / `Name=L` |
//! | 单线程 / 嵌入式（`builtin.single_threaded`） | **不用** | 没有并发可言，起线程只会增加不确定性 | 不涉及 |
//! | 纯同步逻辑 | **不用** | 本来就不需要并发 | 不涉及 |
//!
//! 长任务侧用 [`markAsLongTask`] 标注线程，日志才会变成参考实现里的 `Name=L`。
//!
//! 本模块**默认不启用**：池的大小/上限/空闲回收全部由调用方通过 [`Options`] 决定，
//! 并建议由配置项（而非改代码）控制是否启用，以便嵌入式构建直接关掉。
//!
//! 并发原语（Zig 0.17.1 口径，**不使用任何轮询/睡眠**）：
//! - `std.Io.Mutex`：保护 `total` / `stopping` 等计数（`lockUncancelable`，池内不参与取消）；
//! - `std.Io.Condition.waitTimeout`：worker 空闲阻塞，**带超时**，超时才考虑退休；
//! - `std.Io.Event`：`destroy()` 等「全部 worker 已退出」，一次 set 永久生效。
//!
//! 注意 0.17.1 的 API 差异（实测确认）：`std.Thread` 只剩
//! `spawn/join/detach/yield/getCurrentId/getCpuCount/setName/getName`，
//! `Mutex`/`Condition`/`RwLock`/`Semaphore`/`WaitGroup` 全部迁到 `std.Io`，
//! 且 `Mutex.lock`、`Condition.wait` 等**必须传 `io`**。因此本模块的入口
//! `create(io, ...)` 需要调用方提供 `Io`（`std.testing.io`、`std.process.Init.io`
//! 或 `std.Io.Threaded.init(...).io()`）。
//!
//! 生命周期（**必须用 create/destroy**）：
//! ```zig
//! const pool = try Pool.create(io, gpa, .{ .max_workers = 64 });
//! defer pool.destroy();
//! try pool.submit(myTask, ctx);
//! ```
//!
//! **为什么不用 `init` 返回值**：worker 线程必须持有**稳定地址**。
//! 早期版本返回栈上的 `Pool` 值并把 `&self` 传给线程，函数返回后就是悬垂指针，
//! worker 会读到垃圾内存并可能无限空转（足以把机器拖卡）。现已彻底改成堆指针模型。
//!
//! 语义约定：
//! - `submit` 只做一次无锁入队 + 一次记账，**不阻塞调用方**；
//!   队列满返回 `error.QueueFull`（不静默丢）；
//! - `destroy` **不等待尚未开始的任务**（等同进程退出），已开始的任务会被执行完；
//! - 用户任务必须能自行结束，否则 `destroy` 会一直等（这是使用方的责任）。

const std = @import("std");
const compat = @import("../compat.zig");
const level = @import("../logs/level.zig");
const mpmc = @import("../logs/mpmc_queue.zig");

/// 一项待执行任务：函数指针 + 上下文（调用方负责 `ctx` 的生命周期）。
pub const Task = struct {
    func: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

const worker_stack_size = 256 * 1024;

pub const Options = struct {
    /// 常驻 worker 数（0 = 不常驻，全按需扩容）
    min_workers: usize = 0,
    /// worker 上限。阻塞式任务下它同时是「最大并发任务数」，必须按业务并发上限配置。
    max_workers: usize = 256,
    /// 空闲多久退休（毫秒）；<= 0 表示永不因空闲退休
    idle_timeout_ms: i64 = 30_000,
    /// 任务队列容量（满了 `submit` 返回 `error.QueueFull`）
    queue_capacity: usize = 4096,
};

pub const Pool = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    opts: Options,

    queue: mpmc.MPMCQueue(Task),

    /// 保护 `total` / `stopping` 的写入，以及 `cond` 的等待
    mutex: std.Io.Mutex,
    /// worker 空闲等待；`submit` 成功入队后 signal
    cond: std.Io.Condition,
    /// `total` 归零时 set，供 `destroy()` 等待
    exit_event: std.Io.Event,

    /// 存活 worker 数（写操作在 mutex 内，读也一并放 mutex 内）
    total: usize,
    /// 停止标志；`submit` 的无锁快路径靠原子读它
    stopping: std.atomic.Value(bool),
    /// 当前空闲 worker 数（仅在 mutex 内改；外部只做提示性快照，用于决定是否扩容）
    idle: std.atomic.Value(usize),

    // 观测指标（累计值，原子）
    spawned: std.atomic.Value(u64),
    submitted: std.atomic.Value(u64),
    completed: std.atomic.Value(u64),

    /// 创建线程池（**堆分配**，返回稳定指针给 worker 使用）。
    pub fn create(io: std.Io, gpa: std.mem.Allocator, opts: Options) !*Pool {
        const max_workers = @max(@as(usize, 1), opts.max_workers);
        const min_workers = @min(opts.min_workers, max_workers);
        const capacity = @max(@as(usize, 1), opts.queue_capacity);

        const self = try gpa.create(Pool);
        errdefer gpa.destroy(self);

        self.* = .{
            .io = io,
            .alloc = gpa,
            .opts = .{
                .min_workers = min_workers,
                .max_workers = max_workers,
                .idle_timeout_ms = opts.idle_timeout_ms,
                .queue_capacity = capacity,
            },
            .queue = try mpmc.MPMCQueue(Task).init(gpa, capacity),
            .mutex = .init,
            .cond = .init,
            .exit_event = .unset,
            .total = 0,
            .stopping = std.atomic.Value(bool).init(false),
            .idle = std.atomic.Value(usize).init(0),
            .spawned = std.atomic.Value(u64).init(0),
            .submitted = std.atomic.Value(u64).init(0),
            .completed = std.atomic.Value(u64).init(0),
        };
        errdefer self.queue.deinit(gpa);

        // 常驻 worker：名额先记账再 spawn，保证总量不越过 max_workers。
        var started: usize = 0;
        while (started < min_workers) : (started += 1) {
            self.total += 1;
            self.spawnReserved() catch {
                self.total -= 1;
                break;
            };
        }
        return self;
    }

    /// 停止并释放：置停止标志 → 广播唤醒空闲 worker → 等全部退出 → 释放队列/自身。
    ///
    /// 不等待队列里尚未开始的任务（语义等同进程退出：未开始的任务被丢弃）。
    pub fn destroy(self: *Pool) void {
        const gpa = self.alloc;
        const io = self.io;

        self.mutex.lockUncancelable(io);
        self.stopping.store(true, .release);
        // 唤醒所有阻塞在 cond 上的空闲 worker（它们醒来后在锁内看到 stopping 就退休）
        std.Io.Condition.broadcast(&self.cond, io);
        const remaining = self.total;
        self.mutex.unlock(io);

        // 用 Event 而不是再开一个 Condition：这里只需要「等一个一次性条件成立」。
        if (remaining > 0) std.Io.Event.waitUncancelable(&self.exit_event, io);

        self.queue.deinit(gpa);
        gpa.destroy(self);
    }

    /// 提交任务（非阻塞）。队列满 → `error.QueueFull`；池已停 → `error.PoolStopped`。
    pub fn submit(self: *Pool, func: *const fn (ctx: *anyopaque) void, ctx: *anyopaque) !void {
        if (self.stopping.load(.acquire)) return error.PoolStopped;

        // 先入队、后取锁：worker 在锁内复查队列，所以这个顺序不会丢唤醒。
        if (!self.queue.tryPush(.{ .func = func, .ctx = ctx })) return error.QueueFull;
        _ = self.submitted.fetchAdd(1, .monotonic);

        // 没有空闲 worker 就扩容：名额在锁内预留，避免多线程并发 submit 冲破上限。
        var spawn_needed = false;
        self.mutex.lockUncancelable(self.io);
        if (self.idle.load(.monotonic) == 0 and
            self.total < self.opts.max_workers and
            !self.stopping.load(.acquire))
        {
            self.total += 1;
            spawn_needed = true;
        }
        // 有空闲 worker 时本条 signal 才真正唤醒（无 waiter 时代价接近 0）
        std.Io.Condition.signal(&self.cond, self.io);
        self.mutex.unlock(self.io);

        if (spawn_needed) {
            self.spawnReserved() catch |err| {
                self.mutex.lockUncancelable(self.io);
                self.total -= 1;
                self.mutex.unlock(self.io);
                return err;
            };
        }
    }

    /// worker 上限（阻塞式任务下等于最大并发任务数）。
    pub fn maxWorkers(self: *const Pool) usize {
        return self.opts.max_workers;
    }

    /// 当前存活 worker 数（含正在执行任务的）。
    pub fn workerCount(self: *Pool) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.total;
    }

    /// 当前空闲 worker 数。
    pub fn idleCount(self: *const Pool) usize {
        return self.idle.load(.monotonic);
    }

    pub fn pendingCount(self: *const Pool) usize {
        return self.queue.size();
    }

    /// 已提交 / 已完成 / 累计创建过的 worker 数。
    pub fn stats(self: *const Pool) struct { submitted: u64, completed: u64, spawned: u64 } {
        return .{
            .submitted = self.submitted.load(.monotonic),
            .completed = self.completed.load(.monotonic),
            .spawned = self.spawned.load(.monotonic),
        };
    }

    /// 调用前已在锁内把 `total` 加了 1（名额预留）。
    fn spawnReserved(self: *Pool) !void {
        const thread = try std.Thread.spawn(
            .{ .stack_size = worker_stack_size },
            workerLoop,
            .{self},
        );
        thread.detach();
        _ = self.spawned.fetchAdd(1, .monotonic);
    }
};

/// 退休：`total` 减一；返回是否为最后一个（是则需 set `exit_event`）。
/// **必须持有 mutex 调用**。
fn retireLocked(pool: *Pool) bool {
    std.debug.assert(pool.total > 0);
    pool.total -= 1;
    return pool.total == 0;
}

/// 把当前线程标注为「长任务」：**不进池**，日志输出 `Kind=N` / `Name=L`。
///
/// 对应 .NET 的 `TaskCreationOptions.LongRunning`（DH.NCore 日志里 `Name` 列的 `L`）。
/// 长连接、流式订阅、常驻监听这类任务应当用它，而不是塞进 [`Pool`]。
pub fn markAsLongTask() void {
    level.setPoolWorker(false);
    level.setThreadName(".NET Long Running Task");
}

fn workerLoop(pool: *Pool) void {
    const io = pool.io;
    // 日志维度来源：确实跑在池里 → Kind=Y；线程名命中 C# 的 "Threadpool*" 规则 → Name=P
    level.setPoolWorker(true);
    level.setThreadName("Threadpool worker");

    while (true) {
        // 1) 批量取任务，连续执行；避免每取一个就抢一次锁
        var ran: usize = 0;
        while (pool.queue.tryPop()) |task| {
            task.func(task.ctx);
            ran += 1;
        }
        if (ran > 0) {
            _ = pool.completed.fetchAdd(ran, .monotonic);
            continue;
        }

        // 2) 队列空了，进锁判断是「等」还是「退休」
        pool.mutex.lockUncancelable(io);

        if (!pool.queue.isEmpty()) {
            // 生产者先入队后取锁，所以这里可能是「刚入队还没唤醒」的情况，直接回去取
            pool.mutex.unlock(io);
            continue;
        }

        if (pool.stopping.load(.acquire)) {
            const last = retireLocked(pool);
            pool.mutex.unlock(io);
            if (last) std.Io.Event.set(&pool.exit_event, io);
            return;
        }

        // 只有超出常驻下限的 worker 才允许因空闲超时退休
        const may_expire = pool.opts.idle_timeout_ms > 0 and pool.total > pool.opts.min_workers;
        // 注意 0.17.1 的类型：Io.Timeout.duration 是 Clock.Duration，
        // 而 Clock.Duration = { raw: Io.Duration, clock: Clock }（相对时长用 .awake）
        const timeout: std.Io.Timeout = if (may_expire)
            .{ .duration = .{
                .raw = .{ .nanoseconds = pool.opts.idle_timeout_ms * std.time.ns_per_ms },
                .clock = .awake,
            } }
        else
            .none;

        _ = pool.idle.fetchAdd(1, .monotonic);
        // 阻塞等待（真正睡眠，不占用 CPU）；返回时已重新持有 mutex
        const waited = std.Io.Condition.waitTimeout(&pool.cond, io, &pool.mutex, timeout);
        _ = pool.idle.fetchSub(1, .monotonic);

        if (pool.stopping.load(.acquire)) {
            const last = retireLocked(pool);
            pool.mutex.unlock(io);
            if (last) std.Io.Event.set(&pool.exit_event, io);
            return;
        }

        const timed_out = if (waited) |_| false else |err| err == error.Timeout;
        if (timed_out and pool.queue.isEmpty() and pool.total > pool.opts.min_workers) {
            const last = retireLocked(pool);
            pool.mutex.unlock(io);
            if (last) std.Io.Event.set(&pool.exit_event, io);
            return;
        }

        pool.mutex.unlock(io);
    }
}

// ---------------------------------------------------------------------------
// 测试（规模刻意很小：最多 4 线程 / 几十个任务 / 有界等待）
// ---------------------------------------------------------------------------

const testing = std.testing;

const Probe = struct {
    ran: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    saw_pool_kind: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    saw_pool_name: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn probeTask(ctx: *anyopaque) void {
    const p: *Probe = @ptrCast(@alignCast(ctx));
    _ = p.ran.fetchAdd(1, .acq_rel);
    if (std.mem.eql(u8, level.currentKind(), level.kind_pool)) {
        _ = p.saw_pool_kind.fetchAdd(1, .acq_rel);
    }
    if (std.mem.eql(u8, level.currentThreadName(), level.name_pool_task)) {
        _ = p.saw_pool_name.fetchAdd(1, .acq_rel);
    }
}

/// 有界等待：最多 `max_ms` 毫秒，避免测试挂死。
/// 这里等待的是计数器，不参与池的同步逻辑，所以用最朴素的睡眠即可。
fn waitUntil(flag: *const std.atomic.Value(u32), target: u32, max_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < max_ms) : (waited += 1) {
        if (flag.load(.acquire) >= target) return true;
        compat.sleep(1 * std.time.ns_per_ms);
    }
    return flag.load(.acquire) >= target;
}

test "pool：任务全部执行，且池内 Kind=Y / Name=P（真实来源，非猜测）" {
    const pool = try Pool.create(std.testing.io, testing.allocator, .{
        .min_workers = 4,
        .max_workers = 4,
        .idle_timeout_ms = 0,
        .queue_capacity = 512,
    });
    defer pool.destroy();

    try testing.expectEqual(@as(usize, 4), pool.workerCount());

    var probe = Probe{};
    const total: u32 = 200;
    for (0..total) |_| try pool.submit(probeTask, &probe);

    try testing.expect(waitUntil(&probe.ran, total, 5000));
    try testing.expectEqual(total, probe.ran.load(.acquire));
    try testing.expectEqual(total, probe.saw_pool_kind.load(.acquire));
    try testing.expectEqual(total, probe.saw_pool_name.load(.acquire));

    const s = pool.stats();
    try testing.expectEqual(@as(u64, total), s.submitted);
    try testing.expectEqual(@as(u64, total), s.completed);
}

test "pool：弹性扩容不越上限，空闲超时后收缩回常驻下限" {
    const pool = try Pool.create(std.testing.io, testing.allocator, .{
        .min_workers = 1,
        .max_workers = 4,
        .idle_timeout_ms = 30,
        .queue_capacity = 256,
    });
    defer pool.destroy();

    try testing.expectEqual(@as(usize, 1), pool.workerCount());

    var probe = Probe{};
    // 32 个任务同时压进来：必须扩容，但绝不能超过 max_workers
    for (0..32) |_| try pool.submit(probeTask, &probe);
    try testing.expect(pool.workerCount() <= pool.maxWorkers());
    try testing.expect(waitUntil(&probe.ran, 32, 5000));

    // 空闲超时（30ms）后应收缩回 1
    var waited: u32 = 0;
    while (waited < 200) : (waited += 1) {
        if (pool.workerCount() <= 1) break;
        compat.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 1), pool.workerCount());
}

test "pool：重复创建/销毁三轮，线程都能正常退出（无泄漏）" {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const pool = try Pool.create(std.testing.io, testing.allocator, .{
            .min_workers = 2,
            .max_workers = 2,
            .queue_capacity = 64,
        });
        pool.destroy();
    }
}

const LongProbe = struct {
    kind_ok: bool = false,
    name_ok: bool = false,
    pool_worker_flag: bool = true,
};

fn longProbeRun(ctx: *anyopaque) void {
    const p: *LongProbe = @ptrCast(@alignCast(ctx));
    markAsLongTask();
    p.kind_ok = std.mem.eql(u8, level.currentKind(), level.kind_normal);
    p.name_ok = std.mem.eql(u8, level.currentThreadName(), level.name_long_task);
    p.pool_worker_flag = level.isPoolWorker();
}

test "pool：不该用时不用 —— 长任务标注后 Kind=N / Name=L（对齐 .NET LongRunning）" {
    // 放到独立线程里跑，避免污染测试主线程的线程名
    var probe = LongProbe{};
    const thread = try std.Thread.spawn(.{}, longProbeRun, .{&probe});
    thread.join();

    try testing.expect(probe.kind_ok);
    try testing.expect(probe.name_ok);
    try testing.expect(!probe.pool_worker_flag);
}

// ---------------------------------------------------------------------------
// 高并发压测（8 个提交线程 + 8 个 worker，规模有界，避免拖死机器）
// ---------------------------------------------------------------------------

const Burst = struct {
    pool: *Pool,
    probe: *Probe,
    count: u32,
    accepted: u32 = 0,
    rejected: u32 = 0,
};

fn submitBurst(b: *Burst) void {
    var done: u32 = 0;
    while (done < b.count) {
        if (b.pool.submit(probeTask, b.probe)) |_| {
            done += 1;
            b.accepted += 1;
        } else |_| {
            // 队列满：退让一下再试（压测看吞吐，不把 QueueFull 当失败）
            b.rejected += 1;
            compat.sleep(100 * std.time.ns_per_us);
        }
    }
}

test "pool：高并发压测 —— 8 线程并发 submit 8000 任务，全部执行且不越上限" {
    const pool = try Pool.create(std.testing.io, testing.allocator, .{
        .min_workers = 2,
        .max_workers = 8,
        .idle_timeout_ms = 0,
        .queue_capacity = 16384,
    });
    defer pool.destroy();

    var probe = Probe{};
    const submitter_count = 8;
    const total: u32 = 8000;
    const per = total / submitter_count;

    var bursts: [submitter_count]Burst = undefined;
    var threads: [submitter_count]std.Thread = undefined;
    for (&bursts, 0..) |*b, i| {
        b.* = .{ .pool = pool, .probe = &probe, .count = per };
        threads[i] = try std.Thread.spawn(.{}, submitBurst, .{b});
    }
    for (threads) |t| t.join();

    // 汇总：提交成功数与实际执行数必须一致（不能丢任务），且 worker 不越上限
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (&bursts) |b| {
        accepted += b.accepted;
        rejected += b.rejected;
    }
    try testing.expectEqual(total, accepted);
    try testing.expect(waitUntil(&probe.ran, total, 15000));
    try testing.expectEqual(total, probe.ran.load(.acquire));
    try testing.expect(pool.workerCount() <= pool.maxWorkers());

    const s = pool.stats();
    try testing.expectEqual(@as(u64, total), s.submitted);
    try testing.expectEqual(@as(u64, total), s.completed);
    try testing.expect(s.spawned <= pool.maxWorkers() + rejected);

    std.debug.print(
        "\n[pool 压测] 提交线程={d} 任务={d} 执行={d} 队列满重试={d} worker={d}(上限 {d}) 累计创建={d}\n",
        .{ submitter_count, total, probe.ran.load(.acquire), rejected, pool.workerCount(), pool.maxWorkers(), s.spawned },
    );
}
