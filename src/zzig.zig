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

/// 菜单与输入读取工具（跨平台、支持默认值、零外部依赖）
pub const Menu = @import("menu/menu.zig");

/// 单键输入工具（跨平台、无需按 Enter、支持 Windows / Linux / macOS）
pub const Input = @import("input/input.zig");

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

/// JSON 解析器（JSMN-like，流式解析，紧凑格式，SIMD 优化）
pub const json = struct {
    /// 从 jsmn_zig 模块导入所有核心类型
    const jsmn = @import("json/jsmn_zig.zig");

    /// JSON 解析器主类型（根据配置生成）
    pub const Jsmn = jsmn.Jsmn;

    /// JSON 解析器配置结构
    pub const Config = jsmn.Config;

    /// 默认配置（紧凑格式，SIMD 优化，完整功能）
    pub const jsmn_default_config = jsmn.jsmn_default_config;

    /// JSON 解析器构建器（支持链式配置）
    pub const JsonParser = jsmn.Jsmn(jsmn.jsmn_default_config()).JsonParser;

    /// 便捷函数：使用默认配置创建解析器实例
    pub fn createParser() type {
        return Jsmn(jsmn_default_config());
    }

    /// 便捷函数：为嵌入式环境创建解析器（紧凑模式，无 SIMD）
    pub fn createEmbeddedParser() type {
        return Jsmn(.{
            .compact_tokens = true,
            .use_simd = false,
            .tiny_mode = true,
            .enable_helpers = false,
        });
    }

    /// 便捷函数：为桌面/服务器创建解析器（标准格式，SIMD 优化）
    pub fn createDesktopParser() type {
        return Jsmn(.{
            .compact_tokens = false,
            .use_simd = true,
            .tiny_mode = false,
            .enable_helpers = true,
        });
    }
};

/// XML 处理模块（解析 + 写入 + DOM，纯 Zig 实现，无外部依赖）
///
/// 三层 API：
///   1. 底层扫描器  xml.Scanner         — 无分配、字节级扫描，适合嵌入式
///   2. 流式读取器  xml.Reader          — 事件驱动，SAX 风格，适合大文件
///   3. DOM 树      xml.Dom             — 解析后可随机访问，适合一般用途
///
/// 便捷函数：
///   xml.parse(alloc, src)             — 内存切片 → DOM Document
///   xml.parseFile(alloc, path)        — 文件路径 → DOM Document
///   xml.createWriter(alloc, out, opt) — 创建 XML Writer
///   xml.writeToFile(doc, alloc, path, opt) — DOM→文件
///   xml.toString(doc, alloc, opt)     — DOM→字符串
pub const xml = @import("xml/xml.zig");
