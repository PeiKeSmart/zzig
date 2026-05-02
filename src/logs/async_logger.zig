const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const fs = compat.fs;

// 导入配置模块类型
const config_mod = @import("async_logger_config.zig");
pub const ConfigFile = config_mod.AsyncLoggerConfig;
pub const ConfigLogLevel = config_mod.LogLevel;
pub const ConfigOutputTarget = config_mod.OutputTarget;

// ===== ARMv6 兼容性: 平台原子操作能力检测 =====
// ARMv6 及部分嵌入式平台不支持 64 位原子操作,需使用 Mutex 代替
// 其他平台(x86/x64/ARMv8+)继续使用高性能原子操作

/// 检测平台是否支持 u64 原子操作
///
/// 关键修复: 使用编译时架构检测而非运行时字符串匹配
/// builtin.cpu.model.llvm_name 在 baseline 模式下为 null,不可靠
fn supportsAtomicU64() bool {
    return switch (builtin.cpu.arch) {
        // 32 位 ARM 架构统一不支持 64 位原子操作
        // ARMv6/ARMv7 都是 32 位,即使 ARMv7 理论上支持,为安全起见统一处理
        .arm, .armeb, .thumb, .thumbeb => false,

        // 64 位 ARM 支持
        .aarch64, .aarch64_be => true,

        // 32 位 MIPS 不支持
        .mips, .mipsel => false,

        // 64 位 MIPS 支持
        .mips64, .mips64el => true,

        // RISC-V: 32 位不支持, 64 位支持
        .riscv32 => false,
        .riscv64 => true,

        // x86 系列: 32 位理论支持 CMPXCHG8B,但为兼容性考虑使用 Mutex
        .x86 => false,

        // x86_64 完全支持
        .x86_64 => true,

        // PowerPC: 32 位不支持, 64 位支持
        .powerpc, .powerpcle => false,
        .powerpc64, .powerpc64le => true,

        // 其他架构保守处理: 默认不支持,除非明确已知
        else => false,
    };
}

/// 检测平台是否支持 i64 原子操作
fn supportsAtomicI64() bool {
    return supportsAtomicU64(); // 有符号和无符号支持性相同
}

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

    /// 单字符类型标识，参考 NewLife 日志风格
    /// D=调试 I=信息 W=警告 E=错误
    pub fn kindChar(self: Level) u8 {
        return switch (self) {
            .debug => 'D',
            .info => 'I',
            .warn => 'W',
            .err => 'E',
        };
    }
};

/// 日志消息（固定大小，避免跨线程内存管理复杂性）
pub const LogMessage = struct {
    level: Level,
    timestamp: i128,
    thread_id: u64, // 发起日志的线程 ID（调用 log() 时捕获）
    message: [1024]u8, // 1KB 缓冲区
    len: usize,

    pub fn init(level: Level, timestamp: i128, thread_id: u64, formatted: []const u8) LogMessage {
        var msg: LogMessage = undefined;
        msg.level = level;
        msg.timestamp = timestamp;
        msg.thread_id = thread_id;
        msg.len = @min(formatted.len, msg.message.len);
        @memcpy(msg.message[0..msg.len], formatted[0..msg.len]);
        return msg;
    }
};

/// 无锁环形队列（单生产者单消费者 - SPSC）
///
/// 注意: 此队列假定只有一个生产者线程和一个消费者线程。
/// 多生产者或多消费者场景会导致数据竞争。
pub const RingQueue = struct {
    buffer: []LogMessage,
    capacity: usize,
    capacity_mask: usize, // 容量掩码,用于快速取模(容量必须是2的幂)
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingQueue {
        // 强制容量为 2 的幂,至少 4,便于位运算优化
        // 测试环境允许小容量,生产环境建议 >= 256
        const actual_capacity = std.math.ceilPowerOfTwo(usize, @max(capacity, 4)) catch {
            return error.CapacityTooLarge;
        };
        const buffer = try allocator.alloc(LogMessage, actual_capacity);

        return RingQueue{
            .buffer = buffer,
            .capacity = actual_capacity,
            .capacity_mask = actual_capacity - 1, // 2的幂减1得到掩码
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingQueue) void {
        self.allocator.free(self.buffer);
    }

    /// 尝试推入消息（非阻塞，失败返回 false）
    ///
    /// 内存序说明:
    /// - write_pos.load(.monotonic): 只需保证读到单调递增的值
    /// - read_pos.load(.acquire): 同步消费者对 read_pos 的更新
    /// - write_pos.store(.release): 发布写入,确保 buffer 写入对消费者可见
    pub fn tryPush(self: *RingQueue, msg: LogMessage) bool {
        const write = self.write_pos.load(.monotonic);
        const read = self.read_pos.load(.acquire);

        // 使用位运算计算下一个写位置(快速取模)
        const next = (write + 1) & self.capacity_mask;

        // 队列满: next == read 表示写指针追上读指针
        if (next == read) {
            return false;
        }

        // 写入消息到当前位置
        self.buffer[write & self.capacity_mask] = msg;

        // 使用 .release 确保上面的写入在此之前完成
        // .release 语义保证所有前序写入对后续 acquire 可见
        self.write_pos.store(next, .release);
        return true;
    }

    /// 尝试弹出消息（非阻塞，队列空返回 null）
    ///
    /// 内存序说明:
    /// - read_pos.load(.monotonic): 只需保证读到单调递增的值
    /// - write_pos.load(.acquire): 同步生产者的写入,确保能读到最新数据
    /// - read_pos.store(.release): 发布读取位置,让生产者知道可复用空间
    pub fn tryPop(self: *RingQueue) ?LogMessage {
        const read = self.read_pos.load(.monotonic);
        const write = self.write_pos.load(.acquire);

        // 队列空: read == write 表示读指针追上写指针
        if (read == write) {
            return null;
        }

        // .acquire 保证能读到生产者写入的最新数据
        const msg = self.buffer[read & self.capacity_mask];

        // 更新读指针,通知生产者可以复用空间
        const next = (read + 1) & self.capacity_mask;
        self.read_pos.store(next, .release);

        return msg;
    }

    /// 获取当前队列大小（近似值，因为无锁）
    pub fn size(self: *RingQueue) usize {
        const write = self.write_pos.load(.monotonic);
        const read = self.read_pos.load(.monotonic);

        // 使用位运算计算环形队列大小
        return (write -% read) & self.capacity_mask;
    }

    /// 检查队列是否为空
    pub fn isEmpty(self: *RingQueue) bool {
        const read = self.read_pos.load(.monotonic);
        const write = self.write_pos.load(.monotonic);
        return read == write;
    }
};

/// 内存分配策略
pub const AllocationStrategy = enum {
    /// 动态分配（适用于服务器，内存充足）
    dynamic,

    /// 零分配（推荐用于 ARM/嵌入式，低功耗）
    zero_alloc,

    /// 自动检测（根据平台特性选择）
    auto,
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

    /// 内存分配策略（零分配模式推荐用于 ARM 设备）
    allocation_strategy: AllocationStrategy = .auto,

    /// 线程局部格式化缓冲区大小（零分配模式）
    tls_format_buffer_size: usize = 4096,

    /// 工作线程文件缓冲区大小（零分配模式）
    worker_file_buffer_size: usize = 32768, // ARM 设备可用更小值节省内存
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

    // 文件输出相关
    log_file: ?fs.File,
    log_file_path: ?[]const u8,
    // ARMv6 兼容性: ARMv6 不支持 64 位原子操作,使用 Mutex 保护
    // 其他平台继续使用高性能原子操作
    current_file_size: if (supportsAtomicU64()) std.atomic.Value(u64) else u64,
    current_file_size_mutex: if (!supportsAtomicU64()) compat.Mutex else void,
    output_target: ConfigOutputTarget,
    drop_rate_warning_threshold: f32,
    max_file_size: u64,
    max_backup_files: u32,

    // 文件轮转保护
    rotation_mutex: compat.Mutex,
    is_rotating: std.atomic.Value(bool),

    // 零分配模式:工作线程预分配缓冲区
    worker_format_buffer: []u8,
    worker_utf16_buffer: []u16,
    worker_file_buffer_data: []u8,
    worker_file_buffer_len: std.atomic.Value(usize),
    // ARMv6 兼容性: ARMv6 不支持 64 位原子操作,使用 Mutex 保护
    last_flush_time: if (supportsAtomicI64()) std.atomic.Value(i64) else i64,
    last_flush_time_mutex: if (!supportsAtomicI64()) compat.Mutex else void,

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

        // 初始化基础日志器
        const logger = try init(allocator, logger_config);

        // 设置文件输出相关配置
        logger.output_target = file_config.output_target;
        logger.drop_rate_warning_threshold = file_config.drop_rate_warning_threshold;
        logger.max_file_size = file_config.max_file_size;
        logger.max_backup_files = file_config.max_backup_files;

        // 如果需要文件输出，打开日志文件
        if (file_config.output_target == .file or file_config.output_target == .both) {
            logger.log_file_path = try allocator.dupe(u8, file_config.log_file_path);
            try logger.openLogFile();
        }

        return logger;
    }

    pub fn init(allocator: std.mem.Allocator, config: AsyncLoggerConfig) !*AsyncLogger {
        // 决定分配策略
        const strategy = if (config.allocation_strategy == .auto)
            detectOptimalStrategy()
        else
            config.allocation_strategy;

        const self = try allocator.create(AsyncLogger);
        errdefer allocator.destroy(self);

        // 预分配工作线程缓冲区（零分配模式或 auto 检测到 ARM）
        const worker_format_buffer = if (strategy == .zero_alloc)
            try allocator.alloc(u8, config.tls_format_buffer_size)
        else
            try allocator.alloc(u8, 0); // 动态模式不预分配
        errdefer allocator.free(worker_format_buffer);

        const worker_utf16_buffer = if (strategy == .zero_alloc)
            try allocator.alloc(u16, 2048) // Windows UTF-16 转换
        else
            try allocator.alloc(u16, 0);
        errdefer allocator.free(worker_utf16_buffer);

        const worker_file_buffer_data = if (strategy == .zero_alloc)
            try allocator.alloc(u8, config.worker_file_buffer_size)
        else
            try allocator.alloc(u8, 0);
        errdefer allocator.free(worker_file_buffer_data);

        // 初始化结构体
        self.* = .{
            .queue = try RingQueue.init(allocator, config.queue_capacity),
            .worker_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .dropped_count = std.atomic.Value(usize).init(0),
            .processed_count = std.atomic.Value(usize).init(0),
            .config = config,
            .allocator = allocator,
            .log_file = null,
            .log_file_path = null,
            .current_file_size = undefined,
            .current_file_size_mutex = if (comptime !supportsAtomicU64()) compat.Mutex{} else undefined,
            .output_target = .console,
            .drop_rate_warning_threshold = 10.0,
            .max_file_size = 100 * 1024 * 1024,
            .max_backup_files = 5,
            .rotation_mutex = .{},
            .is_rotating = std.atomic.Value(bool).init(false),
            .worker_format_buffer = worker_format_buffer,
            .worker_utf16_buffer = worker_utf16_buffer,
            .worker_file_buffer_data = worker_file_buffer_data,
            .worker_file_buffer_len = std.atomic.Value(usize).init(0),
            .last_flush_time = undefined,
            .last_flush_time_mutex = if (comptime !supportsAtomicI64()) compat.Mutex{} else undefined,
        };

        // 根据平台初始化原子字段
        if (comptime supportsAtomicU64()) {
            self.current_file_size = std.atomic.Value(u64).init(0);
        } else {
            self.current_file_size = 0;
        }

        if (comptime supportsAtomicI64()) {
            self.last_flush_time = std.atomic.Value(i64).init(compat.milliTimestamp());
        } else {
            self.last_flush_time = compat.milliTimestamp();
        }

        // 启动后台工作线程
        self.worker_thread = try std.Thread.spawn(.{}, workerLoop, .{self});

        return self;
    }

    /// 自动检测最优分配策略
    fn detectOptimalStrategy() AllocationStrategy {
        // 检测 CPU 架构
        switch (builtin.cpu.arch) {
            .arm, .armeb, .aarch64, .aarch64_be => {
                // ARM 架构，推荐零分配
                return .zero_alloc;
            },
            .mips, .mipsel, .mips64, .mips64el => {
                // MIPS 架构（常见于路由器），推荐零分配
                return .zero_alloc;
            },
            .riscv32, .riscv64 => {
                // RISC-V 嵌入式，推荐零分配
                return .zero_alloc;
            },
            else => {},
        }

        // 检测操作系统（嵌入式）
        switch (builtin.os.tag) {
            .freestanding, .uefi => {
                // 裸机或 UEFI 环境，必须零分配
                return .zero_alloc;
            },
            else => {},
        }

        // x86/x64 服务器，使用动态分配
        return .dynamic;
    }

    // ===== ARMv6 兼容性: 封装原子操作函数 =====

    /// 获取当前文件大小 (跨平台兼容)
    fn getCurrentFileSize(self: *const AsyncLogger) u64 {
        if (comptime supportsAtomicU64()) {
            return self.current_file_size.load(.acquire);
        } else {
            // ARMv6: 无需锁保护,只读操作
            return self.current_file_size;
        }
    }

    /// 设置当前文件大小 (跨平台兼容)
    fn setCurrentFileSize(self: *AsyncLogger, size: u64) void {
        if (comptime supportsAtomicU64()) {
            self.current_file_size.store(size, .release);
        } else {
            // ARMv6: 加锁保护
            self.current_file_size_mutex.lock();
            defer self.current_file_size_mutex.unlock();
            self.current_file_size = size;
        }
    }

    /// 增加文件大小 (跨平台兼容)
    fn addCurrentFileSize(self: *AsyncLogger, delta: u64) void {
        if (comptime supportsAtomicU64()) {
            _ = self.current_file_size.fetchAdd(delta, .monotonic);
        } else {
            // ARMv6: 加锁保护
            self.current_file_size_mutex.lock();
            defer self.current_file_size_mutex.unlock();
            self.current_file_size += delta;
        }
    }

    /// 获取上次刷新时间 (跨平台兼容)
    fn getLastFlushTime(self: *const AsyncLogger) i64 {
        if (comptime supportsAtomicI64()) {
            return self.last_flush_time.load(.acquire);
        } else {
            // ARMv6: 无需锁保护,只读操作
            return self.last_flush_time;
        }
    }

    /// 设置上次刷新时间 (跨平台兼容)
    fn setLastFlushTime(self: *AsyncLogger, timestamp: i64) void {
        if (comptime supportsAtomicI64()) {
            self.last_flush_time.store(timestamp, .release);
        } else {
            // ARMv6: 加锁保护
            self.last_flush_time_mutex.lock();
            defer self.last_flush_time_mutex.unlock();
            self.last_flush_time = timestamp;
        }
    }

    pub fn deinit(self: *AsyncLogger) void {
        // 标记停止
        self.should_stop.store(true, .release);

        // 等待工作线程结束
        if (self.worker_thread) |thread| {
            thread.join();
        }

        // 刷新剩余文件缓冲
        self.flushFileBuffer() catch {};

        // 关闭日志文件
        if (self.log_file) |file| {
            file.close();
        }

        // 释放文件路径
        if (self.log_file_path) |path| {
            self.allocator.free(path);
        }

        // 释放零分配模式的预分配缓冲区
        if (self.worker_format_buffer.len > 0) {
            self.allocator.free(self.worker_format_buffer);
        }
        if (self.worker_utf16_buffer.len > 0) {
            self.allocator.free(self.worker_utf16_buffer);
        }
        if (self.worker_file_buffer_data.len > 0) {
            self.allocator.free(self.worker_file_buffer_data);
        }

        // 清理资源
        self.queue.deinit();
        self.allocator.destroy(self);
    }

    /// 后台工作线程主循环
    fn workerLoop(self: *AsyncLogger) void {
        var last_warning_time: i128 = 0;
        const warning_interval_ns: i128 = 10 * std.time.ns_per_s; // 每 10 秒最多警告一次

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
                compat.sleep(self.config.idle_sleep_us * std.time.ns_per_us);
            }

            // 定期检查丢弃率并告警
            if (self.config.enable_drop_counter) {
                const now = compat.nanoTimestamp();
                if (now - last_warning_time >= warning_interval_ns) {
                    const stats = self.getStats();
                    if (stats.drop_rate >= self.drop_rate_warning_threshold) {
                        std.debug.print("⚠️  [日志告警] 丢弃率: {d:.2}% (阈值: {d:.1}%), 已丢弃: {d}, 已处理: {d}\n", .{
                            stats.drop_rate,
                            self.drop_rate_warning_threshold,
                            stats.dropped_count,
                            stats.processed_count,
                        });
                        last_warning_time = now;
                    }
                }
            }
        }

        // 优雅关闭：清空剩余消息
        while (self.queue.tryPop()) |msg| {
            self.writeLog(msg);
            _ = self.processed_count.fetchAdd(1, .monotonic);
        }
    }

    /// 打开日志文件
    fn openLogFile(self: *AsyncLogger) !void {
        if (self.log_file_path) |path| {
            // 确保目录存在
            if (fs.path.dirname(path)) |dir| {
                fs.cwd().makePath(dir) catch |make_err| {
                    if (make_err != error.PathAlreadyExists) return make_err;
                };
            }

            // 打开或创建日志文件（追加模式）
            self.log_file = try fs.cwd().createFile(path, .{
                .read = true,
                .truncate = false,
            });

            // 获取当前文件大小
            const stat = try self.log_file.?.stat();
            self.setCurrentFileSize(stat.size);

            // 定位到文件末尾
            try self.log_file.?.seekFromEnd(0);

            std.debug.print("📝 日志文件已打开: {s} (当前大小: {d} bytes)\n", .{ path, stat.size });
        }
    }

    /// 检查是否需要轮转日志文件
    ///
    /// 使用原子标志和互斥锁防止并发轮转竞态条件
    fn checkRotation(self: *AsyncLogger) !void {
        if (self.max_file_size == 0) return; // 0 表示不限制

        const current_size = self.getCurrentFileSize();
        if (current_size < self.max_file_size) return;

        // 原子检查并设置轮转标志(防止多线程同时轮转)
        const was_rotating = self.is_rotating.swap(true, .acq_rel);
        if (was_rotating) return; // 已有线程在轮转,退出

        defer self.is_rotating.store(false, .release);

        // 二次确认(Double-Check),避免误触发
        if (self.getCurrentFileSize() < self.max_file_size) {
            return;
        }

        // 加锁执行轮转操作
        self.rotation_mutex.lock();
        defer self.rotation_mutex.unlock();

        try self.rotateLogFile();
    }

    /// 轮转日志文件
    fn rotateLogFile(self: *AsyncLogger) !void {
        if (self.log_file_path == null) return;
        const path = self.log_file_path.?;

        // 关闭当前文件
        if (self.log_file) |file| {
            file.close();
            self.log_file = null;
        }

        std.debug.print("🔄 开始日志轮转: {s}\n", .{path});

        // 删除最老的备份文件（如果超过保留数量）
        if (self.max_backup_files > 0) {
            const oldest_backup = try std.fmt.allocPrint(
                self.allocator,
                "{s}.{d}",
                .{ path, self.max_backup_files },
            );
            defer self.allocator.free(oldest_backup);

            fs.cwd().deleteFile(oldest_backup) catch |del_err| {
                if (del_err != error.FileNotFound) {
                    std.debug.print("⚠️  删除旧备份失败: {}\n", .{del_err});
                }
            };
        }

        // 重命名现有备份文件（递增编号）
        var i: u32 = self.max_backup_files;
        while (i > 1) : (i -= 1) {
            const old_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}.{d}",
                .{ path, i - 1 },
            );
            defer self.allocator.free(old_name);

            const new_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}.{d}",
                .{ path, i },
            );
            defer self.allocator.free(new_name);

            fs.cwd().rename(old_name, new_name) catch |rename_err| {
                if (rename_err != error.FileNotFound) {
                    std.debug.print("⚠️  重命名备份失败: {s} -> {s}\n", .{ old_name, new_name });
                }
            };
        }

        // 重命名当前日志文件为 .1
        if (self.max_backup_files > 0) {
            const backup_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}.1",
                .{path},
            );
            defer self.allocator.free(backup_name);

            try fs.cwd().rename(path, backup_name);
            std.debug.print("✅ 已备份: {s} -> {s}\n", .{ path, backup_name });
        } else {
            // 如果不保留备份，直接删除
            try fs.cwd().deleteFile(path);
        }

        // 重新打开新文件
        try self.openLogFile();
    }

    /// 将纳秒时间戳转换为可读格式 YYYY-MM-DD HH:MM:SS.mmm
    ///
    /// 时区固定为 UTC+8（中国标准时间）。buf 长度至少需要 23 字节。
    /// 使用 Howard Hinnant 公历算法（公共领域）将天数转换为年月日。
    fn formatTimestampReadable(ns: i128, buf: []u8) []const u8 {
        const offset_ns: i128 = 8 * 3600 * std.time.ns_per_s; // UTC+8
        const total_ns = ns + offset_ns;
        const total_secs: i64 = @intCast(@divFloor(total_ns, std.time.ns_per_s));
        const ms_part: u32 = @intCast(@mod(@divFloor(total_ns, std.time.ns_per_ms), 1000));

        // 当天内时分秒
        const day_secs: u32 = @intCast(@mod(total_secs, 86_400));
        const hh: u32 = day_secs / 3600;
        const mn: u32 = (day_secs % 3600) / 60;
        const ss: u32 = day_secs % 60;

        // Howard Hinnant 公历算法：Unix 天数 → 年月日
        var z: i32 = @intCast(@divFloor(total_secs, 86_400));
        z += 719_468;
        const era: i32 = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
        const doe: u32 = @intCast(z - era * 146_097);
        const yoe: u32 = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        const y: i32 = @as(i32, @intCast(yoe)) + era * 400;
        const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
        const mp: u32 = (5 * doy + 2) / 153;
        const d: u32 = doy - (153 * mp + 2) / 5 + 1;
        const m: u32 = if (mp < 10) mp + 3 else mp - 9;
        const yr: u32 = @intCast(if (m <= 2) y + 1 else y); // 转 u32 避免有符号整数格式化歧义

        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
            yr, m, d, hh, mn, ss, ms_part,
        }) catch "????-??-?? ??:??:??.???";
    }

    /// 实际写入日志（在后台线程执行）
    fn writeLog(self: *AsyncLogger, msg: LogMessage) void {
        const color_code = msg.level.color();
        const reset_code = "\x1b[0m";
        const kind = msg.level.kindChar();
        // 线程 ID 取低 4 位显示，避免过长
        const tid: u32 = @intCast(msg.thread_id % 10000);

        // 转换为可读时间戳 YYYY-MM-DD HH:MM:SS.mmm
        var ts_buf: [32]u8 = undefined; // 32 字节余量足够大，实际输出 23 字节
        const ts = formatTimestampReadable(msg.timestamp, &ts_buf);

        // 零分配模式：使用预分配缓冲区
        if (self.worker_format_buffer.len > 0) {
            self.writeLogZeroAlloc(msg, ts, tid, kind, color_code, reset_code);
        } else {
            self.writeLogDynamic(msg, ts, tid, kind, color_code, reset_code);
        }
    }

    /// 零分配写入路径
    fn writeLogZeroAlloc(self: *AsyncLogger, msg: LogMessage, ts: []const u8, tid: u32, kind: u8, color_code: []const u8, reset_code: []const u8) void {
        // 格式：{color}{ts} {tid:0>4} {kind}{reset} {message}
        const formatted = std.fmt.bufPrint(
            self.worker_format_buffer,
            "{s}{s} {d:0>4} {c}{s} {s}\n",
            .{
                color_code,
                ts,
                tid,
                kind,
                reset_code,
                msg.message[0..msg.len],
            },
        ) catch return;

        switch (self.output_target) {
            .console => {
                self.printUtf8ZeroAlloc(formatted);
            },
            .file => {
                self.writeToFileZeroAlloc(formatted) catch {};
            },
            .both => {
                self.printUtf8ZeroAlloc(formatted);
                self.writeToFileZeroAlloc(formatted) catch {};
            },
        }
    }

    /// 动态分配写入路径（兼容旧行为）
    fn writeLogDynamic(self: *AsyncLogger, msg: LogMessage, ts: []const u8, tid: u32, kind: u8, color_code: []const u8, reset_code: []const u8) void {
        switch (self.output_target) {
            .console => {
                const formatted = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "{s}{s} {d:0>4} {c}{s} {s}\n",
                    .{
                        color_code,
                        ts,
                        tid,
                        kind,
                        reset_code,
                        msg.message[0..msg.len],
                    },
                ) catch return;
                defer std.heap.page_allocator.free(formatted);
                printUtf8(formatted);
            },
            .file => {
                self.writeToFile(msg, ts, tid, kind) catch |write_err| {
                    std.debug.print("❌ 写入日志文件失败: {}\n", .{write_err});
                };
            },
            .both => {
                const formatted = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "{s}{s} {d:0>4} {c}{s} {s}\n",
                    .{
                        color_code,
                        ts,
                        tid,
                        kind,
                        reset_code,
                        msg.message[0..msg.len],
                    },
                ) catch return;
                defer std.heap.page_allocator.free(formatted);
                printUtf8(formatted);
                self.writeToFile(msg, ts, tid, kind) catch |write_err| {
                    std.debug.print("❌ 写入日志文件失败: {}\n", .{write_err});
                };
            },
        }
    }

    /// 写入日志到文件
    fn writeToFile(self: *AsyncLogger, msg: LogMessage, ts: []const u8, tid: u32, kind: u8) !void {
        if (self.log_file) |file| {
            // 检查是否需要轮转
            try self.checkRotation();

            // 文件格式：无 ANSI 颜色，纯文本
            // 格式：{ts} {tid:0>4} {kind} {message}
            const formatted = try std.fmt.allocPrint(
                self.allocator,
                "{s} {d:0>4} {c} {s}\n",
                .{
                    ts,
                    tid,
                    kind,
                    msg.message[0..msg.len],
                },
            );
            defer self.allocator.free(formatted);

            // 写入文件
            try file.writeAll(formatted);

            // 更新文件大小
            const written_size: u64 = formatted.len;
            self.addCurrentFileSize(written_size);
        }
    }

    /// 零分配文件写入（批量刷盘）
    fn writeToFileZeroAlloc(self: *AsyncLogger, formatted: []const u8) !void {
        if (self.log_file == null) return;

        // 检查是否需要轮转
        try self.checkRotation();

        // 追加到缓冲区
        const current_len = self.worker_file_buffer_len.load(.acquire);
        const new_len = current_len + formatted.len;

        if (new_len <= self.worker_file_buffer_data.len) {
            // 缓冲区足够，追加
            @memcpy(self.worker_file_buffer_data[current_len..new_len], formatted);
            self.worker_file_buffer_len.store(new_len, .release);
        } else {
            // 缓冲区不足，先刷盘
            try self.flushFileBuffer();

            // 再次尝试追加
            if (formatted.len <= self.worker_file_buffer_data.len) {
                @memcpy(self.worker_file_buffer_data[0..formatted.len], formatted);
                self.worker_file_buffer_len.store(formatted.len, .release);
            } else {
                // 单条日志超过缓冲区，直接写入
                try self.log_file.?.writeAll(formatted);
                self.addCurrentFileSize(formatted.len);
            }
        }

        // 条件刷盘（缓冲区超过 80% 或超时）
        const buffer_threshold = self.worker_file_buffer_data.len * 4 / 5;
        const now = compat.milliTimestamp();
        const last_flush = self.getLastFlushTime();

        if (new_len > buffer_threshold or (now - last_flush) > 100) { // 100ms 超时
            // 捕获错误,避免刷盘失败导致数据丢失
            self.flushFileBuffer() catch |flush_err| {
                std.debug.print("⚠️  文件刷新失败: {}\n", .{flush_err});
                // 注意: 缓冲区数据仍保留,稍后可重试
            };
        }
    }

    /// 刷新文件缓冲区到磁盘
    fn flushFileBuffer(self: *AsyncLogger) !void {
        const len = self.worker_file_buffer_len.load(.acquire);
        if (len == 0) return;

        if (self.log_file) |file| {
            try file.writeAll(self.worker_file_buffer_data[0..len]);
            self.addCurrentFileSize(len);
            self.worker_file_buffer_len.store(0, .release);
            self.setLastFlushTime(compat.milliTimestamp());
        }
    }

    /// 零分配 UTF-8 打印（Windows 使用预分配 UTF-16 缓冲区）
    fn printUtf8ZeroAlloc(self: *AsyncLogger, text: []const u8) void {
        if (builtin.os.tag != .windows) {
            std.debug.print("{s}", .{text});
            return;
        }

        const w = std.os.windows;
        const h = compat.windows.getStdHandle(compat.windows.STD_OUTPUT_HANDLE);
        if (h == null or h == w.INVALID_HANDLE_VALUE) {
            std.debug.print("{s}", .{text});
            return;
        }

        // 手动 UTF-8 → UTF-16 转换（避免分配）
        var utf16_len: usize = 0;
        var utf8_index: usize = 0;
        var truncated = false;

        // 预留空间给代理对(Surrogate Pair),避免越界
        while (utf8_index < text.len and utf16_len + 2 <= self.worker_utf16_buffer.len) {
            const first_byte = text[utf8_index];

            // ASCII 快速路径：日志文本(含 ANSI 色彩码)绝大多数为 ASCII，
            // 直接零扩展为 u16，跳过 utf8ByteSequenceLength + utf8Decode 开销
            if (first_byte < 0x80) {
                self.worker_utf16_buffer[utf16_len] = first_byte;
                utf16_len += 1;
                utf8_index += 1;
                continue;
            }

            const char_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
            if (utf8_index + char_len > text.len) break;

            const codepoint = std.unicode.utf8Decode(text[utf8_index..][0..char_len]) catch break;

            if (codepoint < 0x10000) {
                // BMP 字符(基本多文种平面)
                if (utf16_len >= self.worker_utf16_buffer.len) {
                    truncated = true;
                    break;
                }
                self.worker_utf16_buffer[utf16_len] = @intCast(codepoint);
                utf16_len += 1;
            } else {
                // 补充平面字符,需要代理对
                if (utf16_len + 2 > self.worker_utf16_buffer.len) {
                    truncated = true;
                    break;
                }
                const adjusted = codepoint - 0x10000;
                self.worker_utf16_buffer[utf16_len] = @intCast(0xD800 + (adjusted >> 10));
                self.worker_utf16_buffer[utf16_len + 1] = @intCast(0xDC00 + (adjusted & 0x3FF));
                utf16_len += 2;
            }

            utf8_index += char_len;
        }

        // 如果发生截断,追加省略号
        if (truncated and utf8_index < text.len) {
            const ellipsis = [_]u16{ '.', '.', '.' };
            const remain = self.worker_utf16_buffer.len - utf16_len;
            if (remain >= ellipsis.len) {
                @memcpy(self.worker_utf16_buffer[utf16_len..][0..ellipsis.len], &ellipsis);
                utf16_len += ellipsis.len;
            }
        }

        var written: w.DWORD = 0;
        _ = compat.windows.writeConsoleW(h.?, self.worker_utf16_buffer[0..utf16_len], &written);
    }

    /// 异步记录日志
    pub fn log(self: *AsyncLogger, level: Level, comptime fmt: []const u8, args: anytype) void {
        // 级别过滤
        if (@intFromEnum(level) < @intFromEnum(self.config.global_level)) {
            return;
        }

        // 零分配模式：使用线程局部缓冲区
        if (self.config.allocation_strategy == .zero_alloc or
            (self.config.allocation_strategy == .auto and self.worker_format_buffer.len > 0))
        {
            logZeroAlloc(self, level, fmt, args);
        } else {
            logDynamic(self, level, fmt, args);
        }
    }

    /// 零分配路径：使用线程局部缓冲区
    fn logZeroAlloc(self: *AsyncLogger, level: Level, comptime fmt: []const u8, args: anytype) void {
        // 线程局部缓冲区（每线程一个，零初始化避免未定义行为）
        const TLS = struct {
            threadlocal var format_buffer: [4096]u8 = [_]u8{0} ** 4096;
            threadlocal var is_formatting: bool = false; // 防止递归
        };

        // 防止递归（极端情况：日志格式化中触发日志）
        if (TLS.is_formatting) {
            _ = self.dropped_count.fetchAdd(1, .monotonic);
            return;
        }

        TLS.is_formatting = true;
        defer TLS.is_formatting = false;

        // 零分配格式化
        const formatted = std.fmt.bufPrint(&TLS.format_buffer, fmt, args) catch blk: {
            // 缓冲区不足，截断
            const truncated = "...[TRUNCATED]";
            const max_len = TLS.format_buffer.len - truncated.len;
            _ = std.fmt.bufPrint(TLS.format_buffer[0..max_len], fmt, args) catch TLS.format_buffer[0..max_len];
            @memcpy(TLS.format_buffer[max_len .. max_len + truncated.len], truncated);
            break :blk TLS.format_buffer[0 .. max_len + truncated.len];
        };

        // 创建日志消息（在调用线程捕获线程 ID）
        const msg = LogMessage.init(level, compat.nanoTimestamp(), std.Thread.getCurrentId(), formatted);

        // 尝试推入队列
        if (!self.queue.tryPush(msg)) {
            if (self.config.enable_drop_counter) {
                _ = self.dropped_count.fetchAdd(1, .monotonic);
            }
        }
    }

    /// 动态分配路径（兼容旧行为）
    fn logDynamic(self: *AsyncLogger, level: Level, comptime fmt: []const u8, args: anytype) void {
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
        const msg = LogMessage.init(level, compat.nanoTimestamp(), std.Thread.getCurrentId(), formatted);

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
        drop_rate: f32,
    };

    /// 获取统计信息
    pub fn getStats(self: *AsyncLogger) Stats {
        const processed = self.getProcessedCount();
        const dropped = self.getDroppedCount();
        const total = processed + dropped;
        const drop_rate: f32 = if (total > 0)
            @as(f32, @floatFromInt(dropped)) / @as(f32, @floatFromInt(total)) * 100.0
        else
            0.0;

        return Stats{
            .processed_count = processed,
            .dropped_count = dropped,
            .queue_size = self.getQueueSize(),
            .drop_rate = drop_rate,
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
    const h = compat.windows.getStdHandle(compat.windows.STD_OUTPUT_HANDLE);
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
    _ = compat.windows.writeConsoleW(h.?, utf16, &written);
}
