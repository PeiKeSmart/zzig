const std = @import("std");
const builtin = @import("builtin");

// 导入配置模块类型
const config_mod = @import("async_logger_config.zig");
pub const ConfigFile = config_mod.AsyncLoggerConfig;
pub const ConfigLogLevel = config_mod.LogLevel;
pub const ConfigOutputTarget = config_mod.OutputTarget;

/// 日志级别
pub const Level = enum {
    debug,
    info,
    warn,
    err,

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m",
            .info => "\x1b[32m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
        };
    }

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// 日志消息（固定大小，避免跨线程内存管理复杂性）
pub const LogMessage = struct {
    level: Level,
    timestamp: i128,
    message: [1024]u8, // 1KB 缓冲区
    len: usize,

    pub fn init(level: Level, timestamp: i128, formatted: []const u8) LogMessage {
        var msg: LogMessage = undefined;
        msg.level = level;
        msg.timestamp = timestamp;
        msg.len = @min(formatted.len, msg.message.len);
        @memcpy(msg.message[0..msg.len], formatted[0..msg.len]);
        return msg;
    }
};

/// 无锁环形队列（单生产者单消费者）
pub const RingQueue = struct {
    buffer: []LogMessage,
    capacity: usize,
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingQueue {
        // 容量必须是 2 的幂，便于位运算优化
        const actual_capacity = std.math.ceilPowerOfTwo(usize, capacity) catch capacity;
        const buffer = try allocator.alloc(LogMessage, actual_capacity);

        return RingQueue{
            .buffer = buffer,
            .capacity = actual_capacity,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingQueue) void {
        self.allocator.free(self.buffer);
    }

    /// 尝试推入消息（非阻塞，失败返回 false）
    pub fn tryPush(self: *RingQueue, msg: LogMessage) bool {
        const write = self.write_pos.load(.acquire);
        const read = self.read_pos.load(.acquire);

        // 计算下一个写位置
        const next = (write + 1) % self.capacity;

        // 队列满
        if (next == read) {
            return false;
        }

        // 写入消息
        self.buffer[write] = msg;

        // 更新写指针
        self.write_pos.store(next, .release);
        return true;
    }

    /// 尝试弹出消息（非阻塞，队列空返回 null）
    pub fn tryPop(self: *RingQueue) ?LogMessage {
        const read = self.read_pos.load(.acquire);
        const write = self.write_pos.load(.acquire);

        // 队列空
        if (read == write) {
            return null;
        }

        // 读取消息
        const msg = self.buffer[read];

        // 更新读指针
        const next = (read + 1) % self.capacity;
        self.read_pos.store(next, .release);

        return msg;
    }

    /// 获取当前队列大小（近似值，因为无锁）
    pub fn size(self: *RingQueue) usize {
        const write = self.write_pos.load(.acquire);
        const read = self.read_pos.load(.acquire);
        if (write >= read) {
            return write - read;
        }
        return self.capacity - read + write;
    }

    /// 检查队列是否为空
    pub fn isEmpty(self: *RingQueue) bool {
        const read = self.read_pos.load(.acquire);
        const write = self.write_pos.load(.acquire);
        return read == write;
    }
};

/// 异步日志器配置
pub const AsyncLoggerConfig = struct {
    /// 队列容量（建议 2 的幂）
    queue_capacity: usize = 8192,

    /// 后台线程休眠时间（微秒），队列空时
    idle_sleep_us: u64 = 100,

    /// 全局日志级别
    global_level: Level = .debug,

    /// 是否启用丢弃计数
    enable_drop_counter: bool = true,

    /// 批处理大小（工作线程每次处理的最大消息数）
    batch_size: usize = 100,
};

/// 异步日志器
pub const AsyncLogger = struct {
    queue: RingQueue,
    worker_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    dropped_count: std.atomic.Value(usize),
    processed_count: std.atomic.Value(usize),
    config: AsyncLoggerConfig,
    allocator: std.mem.Allocator,

    /// 从配置文件初始化 AsyncLogger
    pub fn initFromConfigFile(allocator: std.mem.Allocator, config_path: []const u8) !*AsyncLogger {
        var file_config = try ConfigFile.loadOrCreate(allocator, config_path);
        defer file_config.deinit();

        // 打印配置信息
        file_config.print();

        // 转换为 AsyncLoggerConfig
        const logger_config = AsyncLoggerConfig{
            .queue_capacity = file_config.queue_capacity,
            .idle_sleep_us = 100,
            .global_level = switch (file_config.min_level) {
                .debug => .debug,
                .info => .info,
                .warn => .warn,
                .err => .err,
            },
            .enable_drop_counter = file_config.enable_statistics,
            .batch_size = file_config.batch_size,
        };

        return try init(allocator, logger_config);
    }

    pub fn init(allocator: std.mem.Allocator, config: AsyncLoggerConfig) !*AsyncLogger {
        const self = try allocator.create(AsyncLogger);
        errdefer allocator.destroy(self);

        self.* = AsyncLogger{
            .queue = try RingQueue.init(allocator, config.queue_capacity),
            .worker_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .dropped_count = std.atomic.Value(usize).init(0),
            .processed_count = std.atomic.Value(usize).init(0),
            .config = config,
            .allocator = allocator,
        };

        // 启动后台工作线程
        self.worker_thread = try std.Thread.spawn(.{}, workerLoop, .{self});

        return self;
    }

    pub fn deinit(self: *AsyncLogger) void {
        // 标记停止
        self.should_stop.store(true, .release);

        // 等待工作线程结束
        if (self.worker_thread) |thread| {
            thread.join();
        }

        // 清理资源
        self.queue.deinit();
        self.allocator.destroy(self);
    }

    /// 后台工作线程主循环
    fn workerLoop(self: *AsyncLogger) void {
        while (!self.should_stop.load(.acquire)) {
            var processed_this_round: usize = 0;

            // 批量处理消息（减少原子操作开销）- 使用配置的 batch_size
            while (processed_this_round < self.config.batch_size) {
                if (self.queue.tryPop()) |msg| {
                    self.writeLog(msg);
                    _ = self.processed_count.fetchAdd(1, .monotonic);
                    processed_this_round += 1;
                } else {
                    // 队列空，跳出批处理
                    break;
                }
            }

            // 如果这轮没处理任何消息，短暂休眠避免空转
            if (processed_this_round == 0) {
                std.Thread.sleep(self.config.idle_sleep_us * std.time.ns_per_us);
            }
        }

        // 优雅关闭：清空剩余消息
        while (self.queue.tryPop()) |msg| {
            self.writeLog(msg);
            _ = self.processed_count.fetchAdd(1, .monotonic);
        }
    }

    /// 实际写入日志（在后台线程执行）
    fn writeLog(self: *AsyncLogger, msg: LogMessage) void {
        _ = self;

        // 格式化输出（使用与同步 logger 相同的格式）
        const color_code = msg.level.color();
        const reset_code = "\x1b[0m";
        const level_label = msg.level.label();

        // 转换时间戳（简化版，实际应该使用完整的时间戳格式化）
        const timestamp_s = @divFloor(msg.timestamp, std.time.ns_per_s);
        const timestamp_ns = @mod(msg.timestamp, std.time.ns_per_s);

        // 输出日志
        printUtf8(std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}[{d}.{d:0>9}] {s}{s}{s} {s}\n",
            .{
                color_code,
                timestamp_s,
                timestamp_ns,
                color_code,
                level_label,
                reset_code,
                msg.message[0..msg.len],
            },
        ) catch return);
    }

    /// 异步记录日志
    pub fn log(self: *AsyncLogger, level: Level, comptime fmt: []const u8, args: anytype) void {
        // 级别过滤
        if (@intFromEnum(level) < @intFromEnum(self.config.global_level)) {
            return;
        }

        // 在调用线程预先格式化（避免跨线程传递复杂参数）
        var buf: [1024]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            // 缓冲区不足，截断
            const truncated = "...[TRUNCATED]";
            const max_len = buf.len - truncated.len;
            _ = std.fmt.bufPrint(buf[0..max_len], fmt, args) catch buf[0..max_len];
            @memcpy(buf[max_len .. max_len + truncated.len], truncated);
            break :blk buf[0 .. max_len + truncated.len];
        };

        // 创建日志消息
        const msg = LogMessage.init(level, std.time.nanoTimestamp(), formatted);

        // 尝试推入队列
        if (!self.queue.tryPush(msg)) {
            // 队列满，丢弃消息
            if (self.config.enable_drop_counter) {
                _ = self.dropped_count.fetchAdd(1, .monotonic);
            }
        }
    }

    /// 获取丢弃的日志数量
    pub fn getDroppedCount(self: *AsyncLogger) usize {
        return self.dropped_count.load(.acquire);
    }

    /// 获取已处理的日志数量
    pub fn getProcessedCount(self: *AsyncLogger) usize {
        return self.processed_count.load(.acquire);
    }

    /// 获取当前队列大小
    pub fn getQueueSize(self: *AsyncLogger) usize {
        return self.queue.size();
    }

    /// 统计信息结构
    pub const Stats = struct {
        processed_count: usize,
        dropped_count: usize,
        queue_size: usize,
    };

    /// 获取统计信息
    pub fn getStats(self: *AsyncLogger) Stats {
        return Stats{
            .processed_count = self.getProcessedCount(),
            .dropped_count = self.getDroppedCount(),
            .queue_size = self.getQueueSize(),
        };
    }

    /// 设置全局日志级别
    pub fn setLevel(self: *AsyncLogger, level: Level) void {
        self.config.global_level = level;
    }

    // 便捷方法
    pub fn debug(self: *AsyncLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *AsyncLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *AsyncLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *AsyncLogger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

/// 跨平台 UTF-8 打印（复用同步 logger 的实现）
fn printUtf8(text: []const u8) void {
    if (builtin.os.tag != .windows) {
        std.debug.print("{s}", .{text});
        return;
    }

    const w = std.os.windows;
    const h = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
    if (h == null or h == w.INVALID_HANDLE_VALUE) {
        std.debug.print("{s}", .{text});
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const utf16 = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch {
        std.debug.print("{s}", .{text});
        return;
    };

    var written: w.DWORD = 0;
    _ = w.kernel32.WriteConsoleW(h.?, utf16.ptr, @as(w.DWORD, @intCast(utf16.len)), &written, null);
}
