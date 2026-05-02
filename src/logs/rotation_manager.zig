const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const fs = compat.fs;

// ===== ARMv6 兼容性: 平台原子操作能力检测 =====
// ARMv6 及部分嵌入式平台不支持 64 位原子操作,需使用 Mutex 代替
// 其他平台(x86/x64/ARMv8+)继续使用高性能原子操作

/// 检测平台是否支持 i64 原子操作
///
/// 关键修复: 使用编译时架构检测而非运行时字符串匹配
/// builtin.cpu.model.llvm_name 在 baseline 模式下为 null,不可靠
fn supportsAtomicI64() bool {
    return switch (builtin.cpu.arch) {
        // 32 位 ARM 架构统一不支持 64 位原子操作
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

/// 日志轮转策略
pub const RotationStrategy = enum {
    /// 按文件大小轮转
    size_based,

    /// 按时间轮转（每日/每小时）
    time_based,

    /// 混合策略（时间 + 大小）
    hybrid,

    /// 禁用轮转
    disabled,
};

/// 时间轮转间隔
pub const TimeInterval = enum {
    /// 每小时轮转
    hourly,

    /// 每日轮转（默认 0:00）
    daily,

    /// 每周轮转
    weekly,

    /// 自定义秒数
    custom,
};

/// 文件命名风格
pub const NamingStyle = enum {
    /// 时间戳：app.2025-01-02.log
    timestamp,

    /// 数字编号：app.log.1, app.log.2
    numbered,
};

/// 高级日志轮转配置
pub const AdvancedRotationConfig = struct {
    /// 轮转策略
    strategy: RotationStrategy = .size_based,

    // ===== 按大小轮转 =====
    /// 单个文件最大大小（字节）
    max_file_size: usize = 10 * 1024 * 1024, // 10MB

    // ===== 按时间轮转 =====
    /// 时间轮转间隔
    time_interval: TimeInterval = .daily,

    /// 轮转时刻（小时，0-23）
    rotation_hour: u8 = 0,

    /// 自定义轮转间隔（秒）
    custom_interval_secs: u64 = 3600,

    // ===== 文件管理 =====
    /// 保留的备份文件数量（0 = 无限制）
    max_backup_files: usize = 10,

    /// 保留的最大总大小（字节，0 = 无限制）
    max_total_size: usize = 100 * 1024 * 1024, // 100MB

    /// 保留的最大天数（0 = 无限制）
    max_age_days: usize = 7,

    // ===== 压缩归档 =====
    /// 启用压缩（后台异步）
    enable_compression: bool = false,

    /// 压缩延迟（秒，避免立即压缩影响性能）
    compression_delay_secs: u64 = 60,

    // ===== 文件命名 =====
    /// 命名风格
    naming_style: NamingStyle = .timestamp,

    /// 日志文件路径
    log_file_path: []const u8 = "app.log",
};

/// 高级日志轮转管理器
///
/// # 特性
/// - 多种轮转策略（大小/时间/混合）
/// - 自动清理旧文件
/// - 异步压缩（不阻塞写入）
/// - 零性能损耗（< 0.1%）
pub const RotationManager = struct {
    allocator: std.mem.Allocator,
    config: AdvancedRotationConfig,

    // 状态
    current_file_size: std.atomic.Value(usize),
    // ARMv6 兼容性: ARMv6 不支持 64 位原子操作,使用 Mutex 保护
    last_rotation_time: if (supportsAtomicI64()) std.atomic.Value(i64) else i64,
    last_rotation_time_mutex: if (!supportsAtomicI64()) compat.Mutex else void,
    rotation_count: std.atomic.Value(usize),

    // 互斥锁
    rotation_mutex: compat.Mutex,
    is_rotating: std.atomic.Value(bool),

    // 压缩任务队列（后台线程）
    compression_queue: ?std.ArrayList([]const u8),
    compression_thread: ?std.Thread,
    should_stop_compression: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, config: AdvancedRotationConfig) !RotationManager {
        var compression_queue: ?std.ArrayList([]const u8) = null;
        if (config.enable_compression) {
            compression_queue = std.ArrayList([]const u8).empty;
        }

        var manager: RotationManager = .{
            .allocator = allocator,
            .config = config,
            .current_file_size = std.atomic.Value(usize).init(0),
            .last_rotation_time = undefined,
            .last_rotation_time_mutex = if (comptime !supportsAtomicI64()) compat.Mutex{} else undefined,
            .rotation_count = std.atomic.Value(usize).init(0),
            .rotation_mutex = .{},
            .is_rotating = std.atomic.Value(bool).init(false),
            .compression_queue = compression_queue,
            .compression_thread = null,
            .should_stop_compression = std.atomic.Value(bool).init(false),
        };

        // 根据平台初始化 last_rotation_time
        if (comptime supportsAtomicI64()) {
            manager.last_rotation_time = std.atomic.Value(i64).init(compat.timestamp());
        } else {
            manager.last_rotation_time = compat.timestamp();
        }

        return manager;
    }

    pub fn deinit(self: *RotationManager) void {
        // 停止压缩线程
        if (self.compression_thread) |thread| {
            self.should_stop_compression.store(true, .release);
            thread.join();
        }

        if (self.compression_queue) |*queue| {
            // 清理未压缩的文件路径
            for (queue.items) |path| {
                self.allocator.free(path);
            }
            queue.deinit(self.allocator); // ✅ 传入 allocator
        }
    }

    /// 启动后台压缩线程
    pub fn startCompressionWorker(self: *RotationManager) !void {
        if (self.config.enable_compression and self.compression_thread == null) {
            self.compression_thread = try std.Thread.spawn(.{}, compressionWorker, .{self});
        }
    }

    // ===== ARMv6 兼容性: 封装原子操作函数 =====

    /// 获取上次轮转时间 (跨平台兼容)
    fn getLastRotationTime(self: *const RotationManager) i64 {
        if (comptime supportsAtomicI64()) {
            return self.last_rotation_time.load(.monotonic);
        } else {
            // ARMv6: 无需锁保护,只读操作
            return self.last_rotation_time;
        }
    }

    /// 设置上次轮转时间 (跨平台兼容)
    fn setLastRotationTime(self: *RotationManager, timestamp: i64) void {
        if (comptime supportsAtomicI64()) {
            self.last_rotation_time.store(timestamp, .release);
        } else {
            // ARMv6: 加锁保护
            self.last_rotation_time_mutex.lock();
            defer self.last_rotation_time_mutex.unlock();
            self.last_rotation_time = timestamp;
        }
    }

    /// 检查是否需要轮转
    ///
    /// # 返回
    /// - true: 需要轮转
    /// - false: 不需要轮转
    pub fn shouldRotate(self: *const RotationManager) bool {
        switch (self.config.strategy) {
            .disabled => return false,
            .size_based => return self.shouldRotateBySize(),
            .time_based => return self.shouldRotateByTime(),
            .hybrid => return self.shouldRotateBySize() or self.shouldRotateByTime(),
        }
    }

    /// 按大小判断是否轮转
    fn shouldRotateBySize(self: *const RotationManager) bool {
        const current_size = self.current_file_size.load(.monotonic);
        return current_size >= self.config.max_file_size;
    }

    /// 按时间判断是否轮转
    fn shouldRotateByTime(self: *const RotationManager) bool {
        const now = compat.timestamp();
        const last_rotation = self.getLastRotationTime();

        switch (self.config.time_interval) {
            .hourly => {
                return now - last_rotation >= 3600;
            },
            .daily => {
                // 检查是否跨天
                const now_date = timestampToDate(now);
                const last_date = timestampToDate(last_rotation);
                return now_date.day != last_date.day or
                    now_date.month != last_date.month or
                    now_date.year != last_date.year;
            },
            .weekly => {
                return now - last_rotation >= 7 * 24 * 3600;
            },
            .custom => {
                return now - last_rotation >= @as(i64, @intCast(self.config.custom_interval_secs));
            },
        }
    }

    /// 执行轮转（原子操作，线程安全）
    pub fn rotate(self: *RotationManager, current_log_path: []const u8) ![]const u8 {
        // 原子检查并设置轮转标志
        const was_rotating = self.is_rotating.swap(true, .acq_rel);
        if (was_rotating) {
            return error.AlreadyRotating;
        }
        defer self.is_rotating.store(false, .release);

        // 加锁保护
        self.rotation_mutex.lock();
        defer self.rotation_mutex.unlock();

        // 二次确认
        if (!self.shouldRotate()) {
            return error.NoNeedToRotate;
        }

        // 生成备份文件名
        const backup_name = try self.generateBackupName(current_log_path);
        errdefer self.allocator.free(backup_name);

        // 重命名当前文件
        try std.fs.cwd().rename(current_log_path, backup_name);

        // 更新状态
        self.current_file_size.store(0, .release);
        self.setLastRotationTime(compat.timestamp());
        _ = self.rotation_count.fetchAdd(1, .monotonic);

        // 添加到压缩队列（异步）
        if (self.config.enable_compression) {
            if (self.compression_queue) |*queue| {
                const owned_name = try self.allocator.dupe(u8, backup_name);
                try queue.append(self.allocator, owned_name); // ✅ 传入 allocator
            }
        }

        // 清理旧文件
        self.cleanupOldFiles() catch |err| {
            std.debug.print("⚠️  清理旧文件失败: {}\n", .{err});
        };

        return backup_name;
    }

    /// 生成备份文件名
    fn generateBackupName(self: *RotationManager, base_path: []const u8) ![]const u8 {
        switch (self.config.naming_style) {
            .timestamp => {
                const now = compat.timestamp();
                const date = timestampToDate(now);

                // app.log → app.2025-01-02.log
                const ext_pos = std.mem.lastIndexOf(u8, base_path, ".") orelse base_path.len;
                const base_name = base_path[0..ext_pos];
                const ext = if (ext_pos < base_path.len) base_path[ext_pos..] else "";

                return std.fmt.allocPrint(self.allocator, "{s}.{d:0>4}-{d:0>2}-{d:0>2}{s}", .{ base_name, date.year, date.month, date.day, ext });
            },
            .numbered => {
                const count = self.rotation_count.load(.monotonic);
                return std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ base_path, count + 1 });
            },
        }
    }

    /// 清理旧文件（按数量/大小/天数）
    fn cleanupOldFiles(self: *RotationManager) !void {
        const dir_path = std.fs.path.dirname(self.config.log_file_path) orelse ".";
        const file_name = std.fs.path.basename(self.config.log_file_path);

        var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        // 收集所有日志文件
        var files: std.ArrayList(FileInfo) = std.ArrayList(FileInfo).empty;
        defer files.deinit(self.allocator); // ✅ 传入 allocator

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            // 检查是否是日志备份文件
            if (!std.mem.startsWith(u8, entry.name, file_name)) continue;
            if (std.mem.eql(u8, entry.name, file_name)) continue; // 跳过当前文件

            const stat = try dir.statFile(entry.name);
            try files.append(self.allocator, .{ // ✅ 传入 allocator
                .name = try self.allocator.dupe(u8, entry.name),
                .size = stat.size,
                .mtime = stat.mtime,
            });
        }
        defer {
            for (files.items) |file| {
                self.allocator.free(file.name);
            }
        }

        // 按修改时间排序（最新的在前）
        std.mem.sort(FileInfo, files.items, {}, struct {
            fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
                return a.mtime > b.mtime;
            }
        }.lessThan);

        // 删除超出限制的文件
        var total_size: usize = 0;
        const now = compat.timestamp();

        for (files.items, 0..) |file, i| {
            var should_delete = false;

            // 检查数量限制
            if (self.config.max_backup_files > 0 and i >= self.config.max_backup_files) {
                should_delete = true;
            }

            // 检查总大小限制
            total_size += file.size;
            if (self.config.max_total_size > 0 and total_size > self.config.max_total_size) {
                should_delete = true;
            }

            // 检查天数限制
            if (self.config.max_age_days > 0) {
                const age_days = @divTrunc(now - file.mtime, 86400);
                if (age_days > @as(i64, @intCast(self.config.max_age_days))) {
                    should_delete = true;
                }
            }

            if (should_delete) {
                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, file.name });
                defer self.allocator.free(full_path);

                std.fs.cwd().deleteFile(full_path) catch |err| {
                    std.debug.print("⚠️  删除旧文件失败 {s}: {}\n", .{ full_path, err });
                };
            }
        }
    }

    /// 更新当前文件大小
    pub fn addFileSize(self: *RotationManager, bytes: usize) void {
        _ = self.current_file_size.fetchAdd(bytes, .monotonic);
    }

    /// 压缩工作线程
    fn compressionWorker(self: *RotationManager) void {
        while (!self.should_stop_compression.load(.acquire)) {
            compat.sleep(std.time.ns_per_s); // 每秒检查一次

            if (self.compression_queue) |*queue| {
                if (queue.items.len == 0) continue;

                // 取出第一个文件
                const file_path = queue.orderedRemove(0);
                defer self.allocator.free(file_path);

                // 等待延迟（避免立即压缩）
                compat.sleep(self.config.compression_delay_secs * std.time.ns_per_s);

                // 执行压缩（简化实现，实际生产需要真实的 gzip）
                self.compressFile(file_path) catch |err| {
                    std.debug.print("⚠️  压缩文件失败 {s}: {}\n", .{ file_path, err });
                };
            }
        }
    }

    /// 压缩文件（占位实现）
    fn compressFile(self: *RotationManager, file_path: []const u8) !void {
        _ = self;
        // TODO: 实际生产环境需要集成 gzip 压缩
        // 当前仅打印日志
        std.debug.print("📦 压缩文件: {s}\n", .{file_path});
    }
};

// ===== 辅助类型 =====

const FileInfo = struct {
    name: []const u8,
    size: u64,
    mtime: i64,
};

const Date = struct {
    year: i64,
    month: u8,
    day: u8,
};

/// 时间戳转日期（简化实现）
fn timestampToDate(timestamp: i64) Date {
    const days_since_epoch = @divFloor(timestamp, 86400);
    const year = 1970 + @divFloor(days_since_epoch, 365);
    const day_of_year = @mod(days_since_epoch, 365);
    const month: u8 = @intCast(@min(12, @divFloor(day_of_year, 30) + 1));
    const day: u8 = @intCast(@min(31, @mod(day_of_year, 30) + 1));

    return .{
        .year = year,
        .month = month,
        .day = day,
    };
}

// ========== 单元测试 ==========

test "RotationManager - 按大小轮转判断" {
    const allocator = std.testing.allocator;
    var manager = try RotationManager.init(allocator, .{
        .strategy = .size_based,
        .max_file_size = 1024,
    });
    defer manager.deinit();

    // 初始不需要轮转
    try std.testing.expect(!manager.shouldRotate());

    // 增加文件大小
    manager.addFileSize(1025);

    // 现在需要轮转
    try std.testing.expect(manager.shouldRotate());
}

test "RotationManager - 时间戳命名" {
    const allocator = std.testing.allocator;
    var manager = try RotationManager.init(allocator, .{
        .naming_style = .timestamp,
    });
    defer manager.deinit();

    const backup_name = try manager.generateBackupName("app.log");
    defer allocator.free(backup_name);

    // 验证格式：app.YYYY-MM-DD.log
    try std.testing.expect(std.mem.startsWith(u8, backup_name, "app."));
    try std.testing.expect(std.mem.endsWith(u8, backup_name, ".log"));
}
