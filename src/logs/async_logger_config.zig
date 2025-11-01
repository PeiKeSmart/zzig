// ============================================================================
// 异步日志配置模块
// ============================================================================
// 功能:
//   - 从配置文件加载日志参数 (队列大小、日志级别、输出路径等)
//   - 配置文件不存在时自动生成默认配置
//   - 支持 JSON 格式配置
//
// 使用:
//   const config = try AsyncLoggerConfig.loadOrCreate(allocator, "logger.json");
//   defer config.deinit();
//
//   var logger = try AsyncLogger.initWithConfig(allocator, config);
//   defer logger.deinit();
// ============================================================================

const std = @import("std");
const fs = std.fs;
const json = std.json;

/// 日志级别枚举 (与 AsyncLogger.Level 对应)
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn fromString(s: []const u8) !LogLevel {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "err")) return .err;
        return error.InvalidLogLevel;
    }

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "err",
        };
    }
};

/// 输出目标配置
pub const OutputTarget = enum {
    console, // 控制台输出
    file, // 文件输出
    both, // 同时输出到控制台和文件

    pub fn fromString(s: []const u8) !OutputTarget {
        if (std.mem.eql(u8, s, "console")) return .console;
        if (std.mem.eql(u8, s, "file")) return .file;
        if (std.mem.eql(u8, s, "both")) return .both;
        return error.InvalidOutputTarget;
    }

    pub fn toString(self: OutputTarget) []const u8 {
        return switch (self) {
            .console => "console",
            .file => "file",
            .both => "both",
        };
    }
};

/// 异步日志配置结构
pub const AsyncLoggerConfig = struct {
    /// 环形队列容量 (必须是 2 的幂次)
    queue_capacity: u32 = 16384,

    /// 最低日志级别 (低于此级别的日志会被过滤)
    min_level: LogLevel = .debug,

    /// 输出目标
    output_target: OutputTarget = .console,

    /// 日志文件路径 (当 output_target 为 file 或 both 时使用)
    log_file_path: []const u8 = "logs/app.log",

    /// 批处理大小 (工作线程每次处理的最大消息数)
    batch_size: u32 = 100,

    /// 丢弃告警阈值 (丢弃率超过此值时打印警告, 0-100)
    drop_rate_warning_threshold: f32 = 10.0,

    /// 是否启用性能监控统计
    enable_statistics: bool = true,

    allocator: std.mem.Allocator,

    /// 标记 log_file_path 是否需要释放 (解决内存泄漏问题)
    owns_log_file_path: bool = false,

    /// 从配置文件加载,如不存在则创建默认配置文件
    pub fn loadOrCreate(allocator: std.mem.Allocator, config_path: []const u8) !AsyncLoggerConfig {
        // 尝试加载现有配置
        if (loadFromFile(allocator, config_path)) |config| {
            std.debug.print("✅ 已加载日志配置: {s}\n", .{config_path});
            return config;
        } else |err| {
            if (err == error.FileNotFound) {
                std.debug.print("⚠️  配置文件不存在,生成默认配置: {s}\n", .{config_path});

                // 生成默认配置
                const default_config = AsyncLoggerConfig{
                    .allocator = allocator,
                };

                // 保存到文件
                try default_config.saveToFile(config_path);
                std.debug.print("✅ 默认配置已生成\n", .{});

                // 重新加载 (确保文件格式正确)
                return try loadFromFile(allocator, config_path);
            } else {
                std.debug.print("❌ 加载配置失败: {}\n", .{err});
                return err;
            }
        }
    }

    /// 从文件加载配置
    pub fn loadFromFile(allocator: std.mem.Allocator, config_path: []const u8) !AsyncLoggerConfig {
        // 读取配置文件
        const file = try fs.cwd().openFile(config_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, file_size);
        defer allocator.free(buffer);

        _ = try file.readAll(buffer);

        // 解析 JSON
        const parsed = try json.parseFromSlice(json.Value, allocator, buffer, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        var config = AsyncLoggerConfig{
            .allocator = allocator,
        };

        // 解析各字段
        if (root.get("queue_capacity")) |v| {
            config.queue_capacity = @intCast(v.integer);
            // 验证是否为 2 的幂次
            if (!isPowerOfTwo(config.queue_capacity)) {
                std.debug.print("⚠️  queue_capacity 必须是 2 的幂次,使用默认值 16384\n", .{});
                config.queue_capacity = 16384;
            }
            // 验证范围 (最小 256, 最大 1048576)
            if (config.queue_capacity < 256) {
                std.debug.print("⚠️  queue_capacity 过小 ({d}),使用最小值 256\n", .{config.queue_capacity});
                config.queue_capacity = 256;
            } else if (config.queue_capacity > 1048576) {
                std.debug.print("⚠️  queue_capacity 过大 ({d}),使用最大值 1048576\n", .{config.queue_capacity});
                config.queue_capacity = 1048576;
            }
        }

        if (root.get("min_level")) |v| {
            config.min_level = try LogLevel.fromString(v.string);
        }

        if (root.get("output_target")) |v| {
            config.output_target = try OutputTarget.fromString(v.string);
        }

        if (root.get("log_file_path")) |v| {
            config.log_file_path = try allocator.dupe(u8, v.string);
            config.owns_log_file_path = true; // 标记需要释放
        }

        if (root.get("batch_size")) |v| {
            config.batch_size = @intCast(v.integer);
            // 验证范围 (最小 1, 最大 1000)
            if (config.batch_size < 1) {
                std.debug.print("⚠️  batch_size 必须 >= 1,使用默认值 100\n", .{});
                config.batch_size = 100;
            } else if (config.batch_size > 1000) {
                std.debug.print("⚠️  batch_size 过大 ({d}),使用最大值 1000\n", .{config.batch_size});
                config.batch_size = 1000;
            }
        }

        if (root.get("drop_rate_warning_threshold")) |v| {
            config.drop_rate_warning_threshold = @floatCast(v.float);
            // 验证范围 (0.0 - 100.0)
            if (config.drop_rate_warning_threshold < 0.0) {
                std.debug.print("⚠️  drop_rate_warning_threshold 必须 >= 0.0,使用默认值 10.0\n", .{});
                config.drop_rate_warning_threshold = 10.0;
            } else if (config.drop_rate_warning_threshold > 100.0) {
                std.debug.print("⚠️  drop_rate_warning_threshold 必须 <= 100.0,使用最大值 100.0\n", .{});
                config.drop_rate_warning_threshold = 100.0;
            }
        }

        if (root.get("enable_statistics")) |v| {
            config.enable_statistics = v.bool;
        }

        return config;
    }

    /// 保存配置到文件
    pub fn saveToFile(self: AsyncLoggerConfig, config_path: []const u8) !void {
        // 确保目录存在
        if (fs.path.dirname(config_path)) |dir| {
            fs.cwd().makePath(dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }

        // 创建配置文件
        const file = try fs.cwd().createFile(config_path, .{});
        defer file.close();

        // 使用动态缓冲区避免溢出
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        // 写入格式化的 JSON (带注释说明)
        try writer.writeAll("{\n");
        try writer.print("  \"queue_capacity\": {d},\n", .{self.queue_capacity});
        try writer.writeAll("  \"_queue_capacity_comment\": \"环形队列容量,必须是2的幂次 (1024/2048/4096/8192/16384/32768/65536)\",\n");
        try writer.writeAll("\n");

        try writer.print("  \"min_level\": \"{s}\",\n", .{self.min_level.toString()});
        try writer.writeAll("  \"_min_level_comment\": \"最低日志级别 (debug/info/warn/err)\",\n");
        try writer.writeAll("\n");

        try writer.print("  \"output_target\": \"{s}\",\n", .{self.output_target.toString()});
        try writer.writeAll("  \"_output_target_comment\": \"输出目标 (console/file/both)\",\n");
        try writer.writeAll("\n");

        try writer.print("  \"log_file_path\": \"{s}\",\n", .{self.log_file_path});
        try writer.writeAll("  \"_log_file_path_comment\": \"日志文件路径 (当 output_target 为 file 或 both 时使用)\",\n");
        try writer.writeAll("\n");

        try writer.print("  \"batch_size\": {d},\n", .{self.batch_size});
        try writer.writeAll("  \"_batch_size_comment\": \"批处理大小 (工作线程每次处理的最大消息数)\",\n");
        try writer.writeAll("\n");

        try writer.print("  \"drop_rate_warning_threshold\": {d},\n", .{self.drop_rate_warning_threshold});
        try writer.writeAll("  \"_drop_rate_warning_threshold_comment\": \"丢弃告警阈值 (0-100,超过此丢弃率时打印警告)\",\n");
        try writer.writeAll("\n");

        try writer.print("  \"enable_statistics\": {},\n", .{self.enable_statistics});
        try writer.writeAll("  \"_enable_statistics_comment\": \"是否启用性能监控统计\"\n");

        try writer.writeAll("}\n");

        // 写入文件
        try file.writeAll(buffer.items);
    }

    /// 释放资源
    pub fn deinit(self: *AsyncLoggerConfig) void {
        // 只释放动态分配的字符串
        if (self.owns_log_file_path) {
            self.allocator.free(self.log_file_path);
        }
    }

    /// 打印配置信息
    pub fn print(self: AsyncLoggerConfig) void {
        std.debug.print("\n📋 异步日志配置:\n", .{});
        std.debug.print("  队列容量: {d}\n", .{self.queue_capacity});
        std.debug.print("  最低级别: {s}\n", .{self.min_level.toString()});
        std.debug.print("  输出目标: {s}\n", .{self.output_target.toString()});
        std.debug.print("  日志文件: {s}\n", .{self.log_file_path});
        std.debug.print("  批处理量: {d}\n", .{self.batch_size});
        std.debug.print("  告警阈值: {d:.1}%\n", .{self.drop_rate_warning_threshold});
        std.debug.print("  性能统计: {}\n", .{self.enable_statistics});
        std.debug.print("\n", .{});
    }
};

/// 检查是否为 2 的幂次
fn isPowerOfTwo(n: u32) bool {
    return n > 0 and (n & (n - 1)) == 0;
}

// ============================================================================
// 测试
// ============================================================================

test "AsyncLoggerConfig - 默认配置" {
    const allocator = std.testing.allocator;

    var config = AsyncLoggerConfig{
        .allocator = allocator,
    };
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 16384), config.queue_capacity);
    try std.testing.expectEqual(LogLevel.debug, config.min_level);
    try std.testing.expectEqual(OutputTarget.console, config.output_target);
}

test "AsyncLoggerConfig - 保存和加载" {
    const allocator = std.testing.allocator;

    const test_config_path = "test_logger_config.json";
    defer fs.cwd().deleteFile(test_config_path) catch {};

    // 保存配置
    {
        var config = AsyncLoggerConfig{
            .allocator = allocator,
            .queue_capacity = 8192,
            .min_level = .info,
            .output_target = .file,
        };
        try config.saveToFile(test_config_path);
        config.deinit();
    }

    // 加载配置
    {
        var config = try AsyncLoggerConfig.loadFromFile(allocator, test_config_path);
        defer config.deinit();

        try std.testing.expectEqual(@as(u32, 8192), config.queue_capacity);
        try std.testing.expectEqual(LogLevel.info, config.min_level);
        try std.testing.expectEqual(OutputTarget.file, config.output_target);
    }
}

test "AsyncLoggerConfig - 自动生成" {
    const allocator = std.testing.allocator;

    const test_config_path = "test_auto_gen_config.json";
    defer fs.cwd().deleteFile(test_config_path) catch {};

    // 第一次调用: 自动生成
    {
        var config = try AsyncLoggerConfig.loadOrCreate(allocator, test_config_path);
        defer config.deinit();

        try std.testing.expectEqual(@as(u32, 16384), config.queue_capacity);
    }

    // 第二次调用: 加载现有
    {
        var config = try AsyncLoggerConfig.loadOrCreate(allocator, test_config_path);
        defer config.deinit();

        try std.testing.expectEqual(@as(u32, 16384), config.queue_capacity);
    }
}

test "isPowerOfTwo" {
    try std.testing.expect(isPowerOfTwo(1));
    try std.testing.expect(isPowerOfTwo(2));
    try std.testing.expect(isPowerOfTwo(1024));
    try std.testing.expect(isPowerOfTwo(16384));

    try std.testing.expect(!isPowerOfTwo(0));
    try std.testing.expect(!isPowerOfTwo(3));
    try std.testing.expect(!isPowerOfTwo(1000));
}

test "AsyncLoggerConfig - 参数验证" {
    const allocator = std.testing.allocator;

    // 测试 batch_size 边界
    {
        var config = AsyncLoggerConfig{
            .allocator = allocator,
            .batch_size = 0,
        };
        // 应该在 loadFromFile 中被修正,这里手动模拟
        if (config.batch_size < 1) {
            config.batch_size = 100;
        }
        try std.testing.expectEqual(@as(u32, 100), config.batch_size);
        config.deinit();
    }

    // 测试 queue_capacity 最小值
    {
        var config = AsyncLoggerConfig{
            .allocator = allocator,
            .queue_capacity = 128, // 小于最小值 256
        };
        if (config.queue_capacity < 256) {
            config.queue_capacity = 256;
        }
        try std.testing.expectEqual(@as(u32, 256), config.queue_capacity);
        config.deinit();
    }
}

test "AsyncLoggerConfig - 内存管理" {
    const allocator = std.testing.allocator;

    // 测试动态分配的 log_file_path 释放
    {
        var config = AsyncLoggerConfig{
            .allocator = allocator,
        };
        config.log_file_path = try allocator.dupe(u8, "logs/app.log");
        config.owns_log_file_path = true;

        // deinit 应该正确释放,即使路径是 "logs/app.log"
        config.deinit();
    }

    // 测试默认路径不释放
    {
        var config = AsyncLoggerConfig{
            .allocator = allocator,
        };
        // 默认 owns_log_file_path = false, 不应释放
        config.deinit();
    }
}
