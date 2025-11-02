const std = @import("std");

/// 多生产者多消费者 (MPMC) 无锁环形队列
///
/// # 特性
/// - 线程安全的多生产者多消费者模型
/// - 基于 CAS (Compare-And-Swap) 的无锁设计
/// - 固定容量（必须为 2 的幂）
/// - 零分配（初始化后无堆分配）
///
/// # 性能
/// - 推入/弹出: O(1) 平均复杂度
/// - 高并发场景下性能优于互斥锁队列
/// - 适用于日志收集、事件总线等高吞吐场景
///
/// # 示例
/// ```zig
/// const allocator = std.heap.page_allocator;
/// var queue = try MPMCQueue(u32).init(allocator, 1024);
/// defer queue.deinit(allocator);
///
/// // 生产者
/// _ = queue.tryPush(42);
///
/// // 消费者
/// if (queue.tryPop()) |value| {
///     std.debug.print("Got: {}\n", .{value});
/// }
/// ```
pub fn MPMCQueue(comptime T: type) type {
    return struct {
        buffer: []Slot,
        capacity: usize,
        capacity_mask: usize,
        head: std.atomic.Value(usize), // 消费者游标
        tail: std.atomic.Value(usize), // 生产者游标

        const Self = @This();

        const Slot = struct {
            data: T,
            sequence: std.atomic.Value(usize),
        };

        /// 初始化 MPMC 队列
        ///
        /// # 参数
        /// - `allocator`: 内存分配器
        /// - `capacity`: 队列容量（自动向上取整到 2 的幂，最小 4）
        ///
        /// # 返回
        /// - 成功: 初始化后的队列
        /// - 失败: OutOfMemory 或 CapacityTooLarge
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            // 强制容量为 2 的幂，最小 4
            const actual_capacity = std.math.ceilPowerOfTwo(usize, @max(capacity, 4)) catch {
                return error.CapacityTooLarge;
            };

            const buffer = try allocator.alloc(Slot, actual_capacity);

            // 初始化序列号
            for (buffer, 0..) |*slot, i| {
                slot.sequence = std.atomic.Value(usize).init(i);
                slot.data = undefined;
            }

            return Self{
                .buffer = buffer,
                .capacity = actual_capacity,
                .capacity_mask = actual_capacity - 1,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
            };
        }

        /// 释放队列资源
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        /// 尝试推入元素（非阻塞）
        ///
        /// # 参数
        /// - `item`: 要推入的元素
        ///
        /// # 返回
        /// - `true`: 推入成功
        /// - `false`: 队列已满
        ///
        /// # 线程安全
        /// 多个生产者可以并发调用此方法
        pub fn tryPush(self: *Self, item: T) bool {
            var tail = self.tail.load(.monotonic);

            while (true) {
                const slot = &self.buffer[tail & self.capacity_mask];
                const seq = slot.sequence.load(.acquire);
                const diff: isize = @as(isize, @intCast(seq)) - @as(isize, @intCast(tail));

                if (diff == 0) {
                    // 槽位可用，尝试 CAS 占位
                    if (self.tail.cmpxchgWeak(tail, tail + 1, .monotonic, .monotonic)) |new_tail| {
                        // CAS 失败，重试
                        tail = new_tail;
                        continue;
                    }

                    // CAS 成功，写入数据
                    slot.data = item;
                    slot.sequence.store(tail + 1, .release);
                    return true;
                } else if (diff < 0) {
                    // 队列已满
                    return false;
                } else {
                    // 其他生产者正在推入，重新加载 tail
                    tail = self.tail.load(.monotonic);
                }
            }
        }

        /// 尝试弹出元素（非阻塞）
        ///
        /// # 返回
        /// - 成功: 弹出的元素
        /// - 失败: null（队列为空）
        ///
        /// # 线程安全
        /// 多个消费者可以并发调用此方法
        pub fn tryPop(self: *Self) ?T {
            var head = self.head.load(.monotonic);

            while (true) {
                const slot = &self.buffer[head & self.capacity_mask];
                const seq = slot.sequence.load(.acquire);
                const diff: isize = @as(isize, @intCast(seq)) - @as(isize, @intCast(head + 1));

                if (diff == 0) {
                    // 槽位有数据，尝试 CAS 占位
                    if (self.head.cmpxchgWeak(head, head + 1, .monotonic, .monotonic)) |new_head| {
                        // CAS 失败，重试
                        head = new_head;
                        continue;
                    }

                    // CAS 成功，读取数据
                    const item = slot.data;
                    slot.sequence.store(head + self.capacity_mask + 1, .release);
                    return item;
                } else if (diff < 0) {
                    // 队列为空
                    return null;
                } else {
                    // 其他消费者正在弹出，重新加载 head
                    head = self.head.load(.monotonic);
                }
            }
        }

        /// 获取队列当前大小（近似值）
        ///
        /// # 注意
        /// 在并发环境下，返回值可能不精确，仅供参考
        pub fn size(self: *const Self) usize {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.monotonic);
            return (tail -% head) & self.capacity_mask;
        }

        /// 检查队列是否为空（近似）
        pub fn isEmpty(self: *const Self) bool {
            return self.size() == 0;
        }

        /// 检查队列是否已满（近似）
        pub fn isFull(self: *const Self) bool {
            return self.size() >= self.capacity;
        }
    };
}

// ========== 单元测试 ==========

test "MPMC Queue - 基本推入弹出" {
    const allocator = std.testing.allocator;
    var queue = try MPMCQueue(u32).init(allocator, 8);
    defer queue.deinit(allocator);

    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expect(queue.tryPush(3));

    try std.testing.expectEqual(@as(u32, 1), queue.tryPop().?);
    try std.testing.expectEqual(@as(u32, 2), queue.tryPop().?);
    try std.testing.expectEqual(@as(u32, 3), queue.tryPop().?);
    try std.testing.expectEqual(@as(?u32, null), queue.tryPop());
}

test "MPMC Queue - 队列满检测" {
    const allocator = std.testing.allocator;
    var queue = try MPMCQueue(u32).init(allocator, 4);
    defer queue.deinit(allocator);

    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expect(queue.tryPush(3));
    try std.testing.expect(queue.tryPush(4));

    // 队列已满
    try std.testing.expect(!queue.tryPush(5));
}

test "MPMC Queue - 并发推入弹出" {
    const allocator = std.testing.allocator;
    var queue = try MPMCQueue(u32).init(allocator, 1024);
    defer queue.deinit(allocator);

    const ThreadContext = struct {
        queue: *MPMCQueue(u32),

        fn producer(ctx: *@This()) void {
            for (0..100) |i| {
                while (!ctx.queue.tryPush(@intCast(i))) {
                    std.Thread.yield() catch {};
                }
            }
        }

        fn consumer(ctx: *@This()) void {
            var count: usize = 0;
            while (count < 100) {
                if (ctx.queue.tryPop()) |_| {
                    count += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    var ctx = ThreadContext{ .queue = &queue };

    const producer_thread = try std.Thread.spawn(.{}, ThreadContext.producer, .{&ctx});
    const consumer_thread = try std.Thread.spawn(.{}, ThreadContext.consumer, .{&ctx});

    producer_thread.join();
    consumer_thread.join();
}
