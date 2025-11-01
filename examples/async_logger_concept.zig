const std = @import("std");
const builtin = @import("builtin");

/// 异步日志设计方案（概念验证）
///
/// 注意：这是一个简化的设计示例，完整实现需要更多错误处理和边界情况处理
/// 日志消息结构（预分配，避免跨线程内存问题）
const LogMessage = struct {
    level: Level,
    timestamp: i128,
    message: [512]u8, // 固定大小缓冲区
    len: usize,

    pub fn format(
        self: LogMessage,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(self.message[0..self.len]);
    }
};

/// 环形缓冲队列
const RingBuffer = struct {
    buffer: []LogMessage,
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        const buffer = try allocator.alloc(LogMessage, capacity);
        return RingBuffer{
            .buffer = buffer,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.buffer);
    }

    /// 尝试推入消息（非阻塞）
    pub fn tryPush(self: *RingBuffer, msg: LogMessage) bool {
        const write = self.write_pos.load(.acquire);
        const read = self.read_pos.load(.acquire);
        const next = (write + 1) % self.buffer.len;

        // 队列满
        if (next == read) {
            return false;
        }

        self.buffer[write] = msg;
        self.write_pos.store(next, .release);
        return true;
    }

    /// 尝试弹出消息（非阻塞）
    pub fn tryPop(self: *RingBuffer) ?LogMessage {
        const read = self.read_pos.load(.acquire);
        const write = self.write_pos.load(.acquire);

        // 队列空
        if (read == write) {
            return null;
        }

        const msg = self.buffer[read];
        const next = (read + 1) % self.buffer.len;
        self.read_pos.store(next, .release);
        return msg;
    }
};

/// 异步日志器
pub const AsyncLogger = struct {
    queue: RingBuffer,
    worker_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    dropped_count: std.atomic.Value(usize),
    global_level: Level,

    pub fn init(allocator: std.mem.Allocator, queue_size: usize) !*AsyncLogger {
        const self = try allocator.create(AsyncLogger);
        self.* = AsyncLogger{
            .queue = try RingBuffer.init(allocator, queue_size),
            .worker_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .dropped_count = std.atomic.Value(usize).init(0),
            .global_level = .debug,
        };

        // 启动后台线程
        self.worker_thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        return self;
    }

    pub fn deinit(self: *AsyncLogger, allocator: std.mem.Allocator) void {
        // 通知停止
        self.should_stop.store(true, .release);

        // 等待线程结束
        if (self.worker_thread) |thread| {
            thread.join();
        }

        self.queue.deinit();
        allocator.destroy(self);
    }

    /// 后台工作线程
    fn workerLoop(self: *AsyncLogger) void {
        while (!self.should_stop.load(.acquire)) {
            if (self.queue.tryPop()) |msg| {
                // 实际输出日志
                self.writeLog(msg);
            } else {
                // 队列空，短暂休眠避免空转
                std.time.sleep(100 * std.time.ns_per_us);
            }
        }

        // 清空剩余消息
        while (self.queue.tryPop()) |msg| {
            self.writeLog(msg);
        }
    }

    /// 实际写入日志（在后台线程执行）
    fn writeLog(self: *AsyncLogger, msg: LogMessage) void {
        _ = self;
        // 这里可以调用原有的 printUtf8 或其他输出函数
        std.debug.print("{s}", .{msg.message[0..msg.len]});
    }

    /// 异步日志接口
    pub fn log(self: *AsyncLogger, level: Level, comptime fmt: []const u8, args: anytype) void {
        // 级别过滤
        if (@intFromEnum(level) < @intFromEnum(self.global_level)) {
            return;
        }

        // 在调用线程格式化消息（避免跨线程内存问题）
        var msg: LogMessage = undefined;
        msg.level = level;
        msg.timestamp = std.time.nanoTimestamp();

        // 格式化到固定缓冲区
        const formatted = std.fmt.bufPrint(&msg.message, fmt, args) catch {
            // 缓冲区不足
            const truncated = "...[TRUNCATED]";
            @memcpy(msg.message[msg.message.len - truncated.len ..], truncated);
            msg.len = msg.message.len;
            return;
        };
        msg.len = formatted.len;

        // 尝试放入队列
        if (!self.queue.tryPush(msg)) {
            // 队列满，丢弃消息
            _ = self.dropped_count.fetchAdd(1, .monotonic);
        }
    }

    pub fn getDroppedCount(self: *AsyncLogger) usize {
        return self.dropped_count.load(.acquire);
    }
};

/// 日志级别（简化版）
pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

// ============================================================================
// 使用示例
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化异步日志器（队列大小 1024）
    var logger = try AsyncLogger.init(allocator, 1024);
    defer logger.deinit(allocator);

    std.debug.print("=== 异步日志性能测试 ===\n\n", .{});

    // 测试 1: 单线程高速写入
    std.debug.print("测试 1: 写入 10000 条日志...\n", .{});
    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        logger.log(.info, "测试消息 {d}\n", .{i});
    }

    const end = std.time.nanoTimestamp();
    const duration_us = @divTrunc(end - start, std.time.ns_per_us);
    const avg_ns = @divTrunc(end - start, 10000);

    std.debug.print("完成! 耗时: {d} μs, 平均: {d} ns/条\n", .{ duration_us, avg_ns });
    std.debug.print("丢弃: {d} 条\n\n", .{logger.getDroppedCount()});

    // 等待后台线程处理完
    std.time.sleep(1 * std.time.ns_per_s);

    std.debug.print("=== 测试完成 ===\n", .{});
}
