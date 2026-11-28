//! 通用定时作业注册表（**与数据库无关**）：任务注册 + 调度 + 结果观测。
//!
//! 定位：任何项目（含不用数据库的工具、Agent、面板）都能用的一份「作业」能力。
//! 底层是 [`timer`]（对齐 DH.NCore `TimerX` / `TimerScheduler`）：一个后台线程 + 一组 Cron 定时器；
//! 本文件只加三样上层建筑：
//! 1. **任务注册表**：Zig 没有反射，作业里的「方法名」用注册名匹配（`registerTask`）；
//! 2. **全量同步**：调用方每次把「当前想要的作业列表」交给 `sync()`，本层负责摘旧建新
//!    （典型用法是从数据库/配置读一遍后整表同步，调用方不必关心定时器生命周期）；
//! 3. **结果观测**：每次触发后回调 `after_run`，把「谁、成功否、耗时」交给调用方
//!    （业务侧用它回写数据库/打点/告警，本层不碰存储）。
//!
//! 内存与并发：
//! - 作业条目（`Slot`）堆分配并带引用计数：`sync()` 摘表时若正在执行，不会提前释放；
//! - 触发时会**复制**方法名/参数再执行，因此调用方可以在执行期间安全地 `sync()` 换表；
//! - `specs`（含 `crons`）只需在 `sync()` 调用期间有效：本层会自己复制一份，
//!   因此调用方可以每次从数据库/配置重新读一遍就交给 `sync()`，不必维护生命周期。
//!
//! ```zig
//! var reg = try Registry.create(gpa, io, "MyJobs");
//! defer reg.deinit();
//! try reg.registerTask(.{ .name = "MyApp.Jobs.Ping", .run = ping, .ctx = state });
//! reg.setAfterRun(.{ .ctx = state, .call = onRun });
//! var crons = [_]Cron{try Cron.parse("0 */5 * * * *")};
//! try reg.sync(&.{.{ .key = "1", .method = "MyApp.Jobs.Ping", .crons = &crons }});
//! ```

const std = @import("std");
const timer_mod = @import("timer.zig");
const cron_mod = @import("cron.zig");
const compat = @import("../compat.zig");

const Cron = cron_mod.Cron;

/// 内置任务回调。`ctx` 是注册时给的上下文，`alloc` 是本次调用的临时 arena（退出即回收）。
pub const TaskFn = *const fn (ctx: ?*anyopaque, argument: []const u8, alloc: std.mem.Allocator) anyerror!void;

pub const Task = struct {
    /// 作业定义里的「方法名」（`JobSpec.method` 与它比较）
    name: []const u8,
    run: TaskFn,
    ctx: ?*anyopaque = null,
};

/// 一条作业定义。字符串只在 `sync()` 期间需要有效。
pub const JobSpec = struct {
    /// 调用方自己的标识（通常是表主键的文本形式），只用于回调时定位
    key: []const u8,
    /// 要执行的方法名（必须在 `registerTask` 里注册过；未注册会记警告并计入 skipped）
    method: []const u8,
    argument: []const u8 = "",
    /// 多个表达式取最近一次
    crons: []const Cron,
    /// Cron 按哪个时区解释（秒）。0 = UTC，东八区传 `8 * 3600`
    cron_offset_seconds: i64 = 0,
};

/// 一次触发的观测数据（回调期间有效，回调返回后即释放）。
pub const Outcome = struct {
    key: []const u8,
    method: []const u8,
    argument: []const u8,
    /// 是否成功（方法未注册、回调报错都算失败）
    ok: bool,
    elapsed_ms: i64,
    /// 失败原因（成功时为 null）
    err_name: ?[]const u8,
};

pub const AfterRun = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, outcome: Outcome) void,
};

/// 一条已注册的作业。堆分配：`Timer` 的地址被调度器持有。
const Slot = struct {
    key: []const u8,
    method: []const u8,
    argument: []const u8,
    /// 自有副本（`Timer.crons` 引用它），`sync` 时从调用方复制
    crons: []Cron,
    timer: timer_mod.Timer,
    owner: *Registry,
    /// 表里 1 + 正在执行的回调各 1
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    sched: *timer_mod.Scheduler,
    mutex: std.Io.Mutex = .init,
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    slots: std.ArrayListUnmanaged(*Slot) = .empty,
    /// 已从调度器摘除、但**不能立即释放**的作业：`timer` 模块的约定是「Timer 内存活到
    /// `Scheduler.deinit` 返回」（调度线程在«取出 due 指针»到«执行»之间仍会读它）。
    /// 因此 sync() 摘表时只做 remove + 入这里，真正释放统一在 deinit 里（线程已 join）。
    retired: std.ArrayListUnmanaged(*Slot) = .empty,
    after_run: ?AfterRun = null,
    /// 已成功执行 / 已跳过（未注册方法、执行失败）
    executed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    skipped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// 创建并立刻启动调度线程（`name` 会成为线程名，便于排查）。
    pub fn create(gpa: std.mem.Allocator, io_handle: std.Io, name: []const u8) !*Registry {
        const sched = try timer_mod.Scheduler.startNamed(io_handle, gpa, name);
        errdefer sched.deinit();

        const self = try gpa.create(Registry);
        self.* = .{ .gpa = gpa, .sched = sched };
        return self;
    }

    pub fn deinit(self: *Registry) void {
        // 摘掉所有定时器 —— **不释放内存**：`timer` 模块的约定是「Timer 内存活到
        // `Scheduler.deinit` 返回」（调度线程取出 due 指针后仍会读）。
        self.lock();
        const active = self.slots;
        const retired = self.retired;
        self.slots = .empty;
        self.retired = .empty;
        self.unlock();

        for (active.items) |slot| self.sched.remove(&slot.timer);
        self.sched.deinit();

        for (active.items) |slot| releaseSlot(slot);
        for (retired.items) |slot| releaseSlot(slot);

        var bulk_active = active;
        bulk_active.deinit(self.gpa);
        var bulk_retired = retired;
        bulk_retired.deinit(self.gpa);

        self.lock();
        self.tasks.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.retired.deinit(self.gpa);
        self.unlock();
        self.gpa.destroy(self);
    }

    /// 调度线程使用的 `std.Io`（调用方如需自己的锁/等待可复用同一个）。
    pub fn io(self: *Registry) std.Io {
        return self.sched.io;
    }

    fn lock(self: *Registry) void {
        self.mutex.lockUncancelable(self.io());
    }

    fn unlock(self: *Registry) void {
        self.mutex.unlock(self.io());
    }

    /// 设置执行后回调（用于回写数据库 / 打点 / 告警）。传 `null` 取消。
    pub fn setAfterRun(self: *Registry, hook: ?AfterRun) void {
        self.lock();
        self.after_run = hook;
        self.unlock();
    }

    /// 注册任务（同名重复注册直接忽略，保证幂等）。
    pub fn registerTask(self: *Registry, task: Task) !void {
        self.lock();
        defer self.unlock();
        for (self.tasks.items) |existing| {
            if (std.mem.eql(u8, existing.name, task.name)) return;
        }
        try self.tasks.append(self.gpa, task);
    }

    /// 已注册任务数。
    pub fn taskCount(self: *Registry) usize {
        self.lock();
        defer self.unlock();
        return self.tasks.items.len;
    }

    /// 当前作业数（内存快照）。
    pub fn count(self: *Registry) usize {
        self.lock();
        defer self.unlock();
        return self.slots.items.len;
    }

    /// 已退役、等 deinit 释放的作业数（频繁 sync 时会增长，健康值应接近 0）。
    pub fn retiredCount(self: *Registry) usize {
        self.lock();
        defer self.unlock();
        return self.retired.items.len;
    }

    /// **全量同步**：摘掉现有作业，按 `specs` 重建。
    ///
    /// 单条注册失败（Cron 无未来时刻等）只跳过该条并记警告，不影响其余作业；
    /// 失败原因可读（含 key / method）。
    pub fn sync(self: *Registry, specs: []const JobSpec) !void {
        var fresh: std.ArrayListUnmanaged(*Slot) = .empty;
        errdefer {
            for (fresh.items) |slot| releaseSlot(slot);
            fresh.deinit(self.gpa);
        }

        for (specs) |spec| {
            const key = try self.gpa.dupe(u8, spec.key);
            errdefer self.gpa.free(key);
            const method = try self.gpa.dupe(u8, spec.method);
            errdefer self.gpa.free(method);
            const argument = try self.gpa.dupe(u8, spec.argument);
            errdefer self.gpa.free(argument);
            const crons = try self.gpa.dupe(Cron, spec.crons);
            errdefer self.gpa.free(crons);

            const slot = try self.gpa.create(Slot);
            slot.* = .{
                .key = key,
                .method = method,
                .argument = argument,
                .crons = crons,
                .timer = timer_mod.Timer.cronOffset(onFired, slot, crons, spec.cron_offset_seconds) catch |err| {
                    std.debug.print(
                        "[zzig.jobs] 作业 {s}（方法 {s}）注册失败：{s}\n",
                        .{ key, method, @errorName(err) },
                    );
                    self.gpa.free(key);
                    self.gpa.free(method);
                    self.gpa.free(argument);
                    self.gpa.free(crons);
                    self.gpa.destroy(slot);
                    continue;
                },
                .owner = self,
            };
            try fresh.append(self.gpa, slot);
        }

        // 换表：先摘旧（不再触发），再装新。退役区扩容失败就本次不重建——
        // 宁可保留旧作业，也不要「旧的新的一起跑」或泄漏内存。
        if (!self.retireSlots()) {
            for (fresh.items) |slot| releaseSlot(slot);
            fresh.deinit(self.gpa);
            return error.RetireFailed;
        }

        var added: usize = 0;
        for (fresh.items) |slot| {
            self.sched.add(&slot.timer) catch |err| {
                std.debug.print(
                    "[zzig.jobs] 作业 {s}（方法 {s}）加入调度失败：{s}\n",
                    .{ slot.key, slot.method, @errorName(err) },
                );
                releaseSlot(slot);
                continue;
            };
            self.lock();
            self.slots.append(self.gpa, slot) catch |err| {
                self.unlock();
                std.debug.print("[zzig.jobs] 作业 {s} 登记失败：{s}\n", .{ slot.key, @errorName(err) });
                self.sched.remove(&slot.timer);
                releaseSlot(slot);
                continue;
            };
            self.unlock();
            added += 1;
        }
        fresh.deinit(self.gpa);
        if (added == 0 and specs.len > 0) {
            std.debug.print("[zzig.jobs] 本次 sync 没有作业注册成功（传入 {d} 条）\n", .{specs.len});
        }
    }

    /// 摘掉当前全部作业（定时器从调度器移除，内存移到 `retired` 等 deinit 释放）。
    ///
    /// 返回 false = 退役区扩容失败（本次什么都没动，调用方应放弃重建）。
    fn retireSlots(self: *Registry) bool {
        self.lock();
        if (self.slots.items.len == 0) {
            self.unlock();
            return true;
        }
        self.retired.ensureUnusedCapacity(self.gpa, self.slots.items.len) catch |err| {
            self.unlock();
            std.debug.print("[zzig.jobs] 退役区扩容失败（{s}）：本次不重建作业\n", .{@errorName(err)});
            return false;
        };
        const old = self.slots;
        self.slots = .empty;
        for (old.items) |slot| self.retired.appendAssumeCapacity(slot);
        self.unlock();

        for (old.items) |slot| self.sched.remove(&slot.timer);
        var copy = old;
        copy.deinit(self.gpa);
        return true;
    }

    /// 立刻触发一次（对齐 TimerX 的 `Wake(id, -1)`）。找到并已安排返回 true。
    pub fn trigger(self: *Registry, key: []const u8) bool {
        self.lock();
        const found = blk: {
            for (self.slots.items) |slot| {
                if (std.mem.eql(u8, slot.key, key)) break :blk slot;
            }
            break :blk null;
        };
        self.unlock();

        const slot = found orelse return false;
        self.sched.triggerNow(&slot.timer);
        return true;
    }

    fn findTask(self: *Registry, method: []const u8) ?Task {
        self.lock();
        defer self.unlock();
        for (self.tasks.items) |task| {
            if (std.mem.eql(u8, task.name, method)) return task;
        }
        return null;
    }
};

/// 定时器回调（在调度线程里执行）。为避免「执行期间 sync() 换表」导致本层持有已释放内存，
/// 先复制 key / method / argument，再放开锁去执行。
fn onFired(ctx: ?*anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(ctx orelse return));
    _ = slot.refs.fetchAdd(1, .monotonic);
    defer releaseSlot(slot);

    const owner = slot.owner;
    const a = owner.gpa;

    owner.lock();
    const key_copy = a.dupe(u8, slot.key) catch null;
    const method_copy = a.dupe(u8, slot.method) catch null;
    const argument_copy = a.dupe(u8, slot.argument) catch null;
    const hook = owner.after_run;
    owner.unlock();

    defer {
        if (key_copy) |v| a.free(v);
        if (method_copy) |v| a.free(v);
        if (argument_copy) |v| a.free(v);
    }
    if (key_copy == null or method_copy == null or argument_copy == null) {
        std.debug.print("[zzig.jobs] 作业触发前复制失败（内存不足）：本次跳过\n", .{});
        _ = owner.skipped.fetchAdd(1, .monotonic);
        return;
    }

    const key = key_copy.?;
    const method = method_copy.?;
    const argument = argument_copy.?;

    var ok = true;
    var err_name: ?[]const u8 = null;
    var elapsed_ms: i64 = 0;

    if (owner.findTask(method)) |task| {
        var call_arena = std.heap.ArenaAllocator.init(a);
        defer call_arena.deinit();
        const started_ns = compat.nanoTimestamp();
        if (task.run(task.ctx, argument, call_arena.allocator())) |_| {
            elapsed_ms = @intCast(@divFloor(compat.nanoTimestamp() - started_ns, std.time.ns_per_ms));
        } else |err| {
            elapsed_ms = @intCast(@divFloor(compat.nanoTimestamp() - started_ns, std.time.ns_per_ms));
            ok = false;
            err_name = @errorName(err);
        }
    } else {
        ok = false;
        err_name = "TaskNotRegistered";
        std.debug.print(
            "[zzig.jobs] 作业 {s} 的方法 `{s}` 未注册：Zig 没有反射，需先 registerTask\n",
            .{ key, method },
        );
    }

    if (ok) {
        _ = owner.executed.fetchAdd(1, .monotonic);
    } else {
        _ = owner.skipped.fetchAdd(1, .monotonic);
    }

    if (hook) |h| {
        h.call(h.ctx, .{
            .key = key,
            .method = method,
            .argument = argument,
            .ok = ok,
            .elapsed_ms = elapsed_ms,
            .err_name = err_name,
        });
    }
}

fn releaseSlot(slot: *Slot) void {
    if (slot.refs.fetchSub(1, .acq_rel) != 1) return;
    const gpa = slot.owner.gpa;
    gpa.free(slot.key);
    gpa.free(slot.method);
    gpa.free(slot.argument);
    gpa.free(slot.crons);
    gpa.destroy(slot);
}

test "jobs：sync 后按 Cron 触发已注册任务（未注册方法计入 skipped）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Counter = struct {
        hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn run(ctx: ?*anyopaque, argument: []const u8, alloc: std.mem.Allocator) anyerror!void {
            _ = argument;
            _ = alloc;
            const self: *@This() = @ptrCast(@alignCast(ctx orelse return error.MissingContext));
            _ = self.hits.fetchAdd(1, .monotonic);
        }
    };

    var counter = Counter{};
    const reg = try Registry.create(gpa, io, "zzig-jobs-test");
    defer reg.deinit();

    try reg.registerTask(.{ .name = "test.tick", .run = Counter.run, .ctx = &counter });

    var crons = [_]Cron{try Cron.parse("*/1 * * * * *")};
    try reg.sync(&.{
        .{ .key = "1", .method = "test.tick", .crons = &crons },
    });
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    var waited: usize = 0;
    while (waited < 3000 and counter.hits.load(.acquire) == 0) : (waited += 1) {
        compat.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(counter.hits.load(.acquire) >= 1);

    // 手动触发：未注册的方法会被计入 skipped，不影响整体
    var slow = [_]Cron{try Cron.parse("0 */5 * * * *")};
    try reg.sync(&.{
        .{ .key = "2", .method = "test.missing", .crons = &slow },
    });
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expectEqual(@as(usize, 1), reg.retiredCount());
    try std.testing.expect(reg.trigger("2"));
    try std.testing.expect(!reg.trigger("不存在"));
}
