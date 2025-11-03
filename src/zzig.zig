/// 字符串处理
pub const Strings = @import("string/strings.zig");

/// 结构化日志处理（支持多级别、时间戳、跨平台）
pub const Logger = @import("logs/logger.zig");

/// 异步日志处理（高性能、无阻塞、适用于高并发场景）
pub const AsyncLogger = @import("logs/async_logger.zig");

/// 异步日志配置文件支持
pub const AsyncLoggerConfig = @import("logs/async_logger_config.zig");

/// 随机数处理
pub const Randoms = @import("random/randoms.zig");

/// 文件及文件夹处理
pub const File = @import("file/file.zig");

/// 控制台工具（UTF-8 编码、ANSI 颜色支持、跨平台兼容）
pub const Console = @import("console/console.zig");

/// MPMC 队列（多生产者多消费者无锁队列）
pub const MPMCQueue = @import("logs/mpmc_queue.zig").MPMCQueue;

/// 结构化日志（JSON 格式）
pub const StructuredLog = @import("logs/structured_log.zig");

/// 性能剖析器（零开销、采样模式、热点识别）
pub const profiler = struct {
    pub const Profiler = @import("profiler/profiler.zig").Profiler;
    pub const ProfilerConfig = @import("profiler/profiler.zig").ProfilerConfig;
    pub const Metrics = @import("profiler/profiler.zig").Metrics;
};

/// 动态队列（自动扩容的 SPSC 队列）
pub const logs = struct {
    pub const DynamicQueue = @import("logs/dynamic_queue.zig").DynamicQueue;
    pub const DynamicQueueConfig = @import("logs/dynamic_queue.zig").DynamicQueueConfig;

    /// 日志轮转管理器（多策略轮转 + 异步压缩）
    pub const RotationManager = @import("logs/rotation_manager.zig").RotationManager;
    pub const AdvancedRotationConfig = @import("logs/rotation_manager.zig").AdvancedRotationConfig;
    pub const RotationStrategy = @import("logs/rotation_manager.zig").RotationStrategy;
};
