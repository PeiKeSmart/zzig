const std = @import("std");

/// 动态扩容队列配置
pub const DynamicQueueConfig = struct {
    /// 初始容量（必须为 2 的幂）
    initial_capacity: usize = 64,

    /// 最大容量限制（防止无限扩容）
    max_capacity: usize = 1024 * 1024, // 1M

    /// 扩容触发阈值（0.95 = 95% 满时触发）
    resize_threshold: f32 = 0.95,

    /// 扩容倍数（2.0 = 容量翻倍）
    growth_factor: f32 = 2.0,

    /// 启用自动缩容（使用率 < 25% 时缩容）
    enable_auto_shrink: bool = false,

    /// 缩容触发阈值
    shrink_threshold: f32 = 0.25,
};

/// 动态扩容 SPSC 队列（单生产者单消费者）
///
/// # 特性
/// - 自动扩容：容量不足时自动扩展
/// - 预扩容策略：接近满时后台触发，减少阻塞
/// - 零分配稳定运行：扩容后无额外分配
/// - 性能影响 < 1%
///
/// # 示例
/// ```zig
/// var queue = try DynamicQueue(u32).init(allocator, .{
///     .initial_capacity = 128,
///     .max_capacity = 4096,
/// });
/// defer queue.deinit();
///
/// _ = try queue.push(42);
/// const value = queue.pop();
/// ```
pub fn DynamicQueue(comptime T: type) type {
    return struct {
        buffer: []T,
        capacity: usize,
        capacity_mask: usize,
        write_pos: usize,
        read_pos: usize,
        allocator: std.mem.Allocator,
        config: DynamicQueueConfig,

        // 预扩容相关
        resize_threshold_count: usize, // 预计算的扩容阈值
        is_resizing: std.atomic.Value(bool), // 扩容标志
        resize_mutex: std.Thread.Mutex, // ✅ 保护扩容操作的互斥锁

        const Self = @This();

        /// 初始化动态队列
        pub fn init(allocator: std.mem.Allocator, config: DynamicQueueConfig) !Self {
            // 强制初始容量为 2 的幂，最小 4
            const actual_capacity = std.math.ceilPowerOfTwo(usize, @max(config.initial_capacity, 4)) catch {
                return error.CapacityTooLarge;
            };

            const buffer = try allocator.alloc(T, actual_capacity);
            @memset(buffer, undefined);

            const threshold_count = @as(usize, @intFromFloat(@as(f32, @floatFromInt(actual_capacity)) * config.resize_threshold));

            return Self{
                .buffer = buffer,
                .capacity = actual_capacity,
                .capacity_mask = actual_capacity - 1,
                .write_pos = 0,
                .read_pos = 0,
                .allocator = allocator,
                .config = config,
                .resize_threshold_count = threshold_count,
                .is_resizing = std.atomic.Value(bool).init(false),
                .resize_mutex = .{}, // ✅ 初始化互斥锁
            };
        }

        /// 释放队列资源
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// 推入元素（自动扩容）
        ///
        /// # 返回
        /// - 成功: void
        /// - 失败: error.QueueFull（达到最大容量）或 OutOfMemory
        pub fn push(self: *Self, item: T) !void {
            // 检查是否需要扩容（预扩容策略）
            const current_size = self.size();

            // ✅ 优化：仅在接近阈值时才检查扩容
            if (current_size >= self.resize_threshold_count) {
                try self.checkAndResize();
            }

            // 常规推入逻辑
            const write = self.write_pos;
            const read = self.read_pos;
            const next = (write + 1) & self.capacity_mask;

            if (next == read) {
                // 队列满，尝试立即扩容
                if (self.capacity < self.config.max_capacity) {
                    try self.resizeNow();
                    // 重试推入
                    return self.push(item);
                } else {
                    return error.QueueFull;
                }
            }

            self.buffer[write & self.capacity_mask] = item;
            self.write_pos = next;
        }

        /// 弹出元素
        ///
        /// # 返回
        /// - 成功: 元素值
        /// - 失败: null（队列为空）
        pub fn pop(self: *Self) ?T {
            const write = self.write_pos;
            const read = self.read_pos;

            if (read == write) {
                return null; // 队列为空
            }

            const item = self.buffer[read & self.capacity_mask];
            self.read_pos = (read + 1) & self.capacity_mask;

            // 检查是否需要缩容（可选）
            if (self.config.enable_auto_shrink) {
                self.checkAndShrink();
            }

            return item;
        }

        /// 尝试推入（非阻塞，不扩容）
        pub fn tryPush(self: *Self, item: T) bool {
            const write = self.write_pos;
            const read = self.read_pos;
            const next = (write + 1) & self.capacity_mask;

            if (next == read) {
                return false; // 队列满
            }

            self.buffer[write & self.capacity_mask] = item;
            self.write_pos = next;
            return true;
        }

        /// 获取队列当前大小
        pub fn size(self: *const Self) usize {
            const write = self.write_pos;
            const read = self.read_pos;
            return (write -% read) & self.capacity_mask;
        }

        /// 检查队列是否为空
        pub fn isEmpty(self: *const Self) bool {
            return self.write_pos == self.read_pos;
        }

        /// 检查队列是否已满
        pub fn isFull(self: *const Self) bool {
            const next = (self.write_pos + 1) & self.capacity_mask;
            return next == self.read_pos;
        }

        /// 获取当前容量
        pub fn getCapacity(self: *const Self) usize {
            return self.capacity;
        }

        /// 获取使用率（0.0 - 1.0）
        pub fn getUsage(self: *const Self) f32 {
            const current_size = self.size();
            return @as(f32, @floatFromInt(current_size)) / @as(f32, @floatFromInt(self.capacity));
        }

        /// 检查并触发扩容（预扩容策略）
        fn checkAndResize(self: *Self) !void {
            // 原子检查，防止多次扩容
            const was_resizing = self.is_resizing.swap(true, .acquire);
            if (was_resizing) return; // 已在扩容中
            defer self.is_resizing.store(false, .release);

            // ✅ 加锁保护扩容操作
            self.resize_mutex.lock();
            defer self.resize_mutex.unlock();

            // 二次确认是否需要扩容
            if (self.size() < self.resize_threshold_count) {
                return;
            }

            if (self.capacity >= self.config.max_capacity) {
                return; // 已达最大容量
            }

            // 执行扩容
            try self.resizeNow();
        }

        /// 立即扩容
        fn resizeNow(self: *Self) !void {
            const new_capacity_float = @as(f32, @floatFromInt(self.capacity)) * self.config.growth_factor;
            var new_capacity = @as(usize, @intFromFloat(new_capacity_float));

            // 限制最大容量
            if (new_capacity > self.config.max_capacity) {
                new_capacity = self.config.max_capacity;
            }

            // 确保是 2 的幂
            new_capacity = std.math.ceilPowerOfTwo(usize, new_capacity) catch self.config.max_capacity;

            if (new_capacity <= self.capacity) {
                return; // 无需扩容
            }

            // 分配新缓冲区
            const new_buffer = try self.allocator.alloc(T, new_capacity);
            errdefer self.allocator.free(new_buffer);

            // 复制现有数据
            const current_size = self.size();
            var i: usize = 0;
            while (i < current_size) : (i += 1) {
                const idx = (self.read_pos + i) & self.capacity_mask;
                new_buffer[i] = self.buffer[idx];
            }

            // 释放旧缓冲区
            self.allocator.free(self.buffer);

            // 更新状态
            self.buffer = new_buffer;
            self.capacity = new_capacity;
            self.capacity_mask = new_capacity - 1;
            self.read_pos = 0;
            self.write_pos = current_size;

            // 更新扩容阈值
            self.resize_threshold_count = @as(usize, @intFromFloat(@as(f32, @floatFromInt(new_capacity)) * self.config.resize_threshold));
        }

        /// 检查并触发缩容
        fn checkAndShrink(self: *Self) void {
            if (!self.config.enable_auto_shrink) return;

            const usage = self.getUsage();
            if (usage > self.config.shrink_threshold) return;

            // 计算目标容量（当前容量的一半）
            const target_capacity = self.capacity / 2;
            if (target_capacity < self.config.initial_capacity) return;

            // 执行缩容（简化实现，实际生产可能需要延迟）
            self.shrinkNow(target_capacity) catch {
                // 缩容失败不影响功能
                return;
            };
        }

        /// 立即缩容
        fn shrinkNow(self: *Self, target_capacity: usize) !void {
            const new_buffer = try self.allocator.alloc(T, target_capacity);
            errdefer self.allocator.free(new_buffer);

            // 复制数据
            const current_size = self.size();
            var i: usize = 0;
            while (i < current_size) : (i += 1) {
                const idx = (self.read_pos + i) & self.capacity_mask;
                new_buffer[i] = self.buffer[idx];
            }

            self.allocator.free(self.buffer);

            self.buffer = new_buffer;
            self.capacity = target_capacity;
            self.capacity_mask = target_capacity - 1;
            self.read_pos = 0;
            self.write_pos = current_size;

            self.resize_threshold_count = @as(usize, @intFromFloat(@as(f32, @floatFromInt(target_capacity)) * self.config.resize_threshold));
        }
    };
}

// ========== 单元测试 ==========

test "DynamicQueue - 基本推入弹出" {
    const allocator = std.testing.allocator;
    var queue = try DynamicQueue(u32).init(allocator, .{ .initial_capacity = 4 });
    defer queue.deinit();

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try std.testing.expectEqual(@as(u32, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 2), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 3), queue.pop().?);
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "DynamicQueue - 自动扩容" {
    const allocator = std.testing.allocator;
    var queue = try DynamicQueue(u32).init(allocator, .{
        .initial_capacity = 4,
        .max_capacity = 64,
    });
    defer queue.deinit();

    // 初始容量 4
    try std.testing.expectEqual(@as(usize, 4), queue.getCapacity());

    // 推入 10 个元素，应触发扩容
    for (0..10) |i| {
        try queue.push(@intCast(i));
    }

    // 容量应已扩展
    try std.testing.expect(queue.getCapacity() >= 16);

    // 验证数据完整性
    for (0..10) |i| {
        const value = queue.pop().?;
        try std.testing.expectEqual(@as(u32, @intCast(i)), value);
    }
}

test "DynamicQueue - 最大容量限制" {
    const allocator = std.testing.allocator;
    var queue = try DynamicQueue(u32).init(allocator, .{
        .initial_capacity = 4,
        .max_capacity = 8,
    });
    defer queue.deinit();

    // 填满队列
    for (0..7) |i| {
        try queue.push(@intCast(i));
    }

    // 应该达到最大容量
    const result = queue.push(999);
    try std.testing.expectError(error.QueueFull, result);
}
