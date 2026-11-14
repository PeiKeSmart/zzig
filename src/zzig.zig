const std = @import("std");

/// 进程工具（外部命令执行、输出读取）
pub const Process = @import("process/process.zig");

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

/// HTTP、表单编码与压缩响应辅助
pub const Http = @import("http/http.zig");

/// HTTP 增强工具（重试机制、表单处理、网络错误处理）
pub const HttpEnhanced = @import("http/enhanced.zig");

/// 极简 HTTP/1.1 服务端（监听+线程+上限；鉴权/限流在业务层）
pub const http_server = @import("http/server.zig");

/// Web 应用栈（对齐 ASP.NET Core / DH.RustBase 的 MVC 约定）
///
/// - `web.App`：装配路由 + 控制器 + 视图 + 静态资源，并桥接 `http_server`；
/// - `web.Controller`：动作分发 `/{prefix}/{action}` + 参数绑定（路由→查询→表单→JSON）；
/// - `web.view`：Razor 子集视图引擎（`Views/{Controller}/{Action}.cshtml`、`Areas/{Area}/Views`、
///   布局/分区/Partial、模板缓存）；
/// - `web.static_files`：`wwwroot` 静态资源（MIME / 默认文档 / ETag 304 / 目录穿越防护 /
///   区域多根 / 嵌入资源 / SPA 回退）；
/// - `web.Value`：视图模型值（对象/列表/标量 + JSON 解析/序列化 + C# 口径文本化）。
///
/// 用法：
/// ```zig
/// var app = try zzig.web.App.init(allocator, io, .{});
/// defer app.deinit();
///
/// var home = try zzig.web.Controller.init(allocator, io, "home");
/// defer home.deinit();
/// try home.get("index", HomeController.index);
/// try app.mountController(&home);
///
/// try app.run("127.0.0.1", 8080, .{});
/// ```
pub const web = struct {
    pub const router = @import("http/router.zig");
    pub const controller = @import("http/controller.zig");
    pub const view = @import("http/view.zig");
    pub const static_files = @import("http/static_files.zig");
    pub const value = @import("http/value.zig");
    pub const App = @import("http/web.zig").App;
    pub const Options = @import("http/web.zig").Options;

    pub const Value = @import("http/value.zig").Value;
    pub const Field = @import("http/value.zig").Field;
    pub const ObjectBuilder = @import("http/value.zig").ObjectBuilder;
    pub const Ctx = @import("http/router.zig").Ctx;
    pub const Request = @import("http/router.zig").Request;
    pub const Response = @import("http/router.zig").Response;
    pub const Handler = @import("http/router.zig").Handler;
    pub const handler = @import("http/router.zig").handler;
    pub const middleware = @import("http/router.zig").middleware;

    pub const Controller = @import("http/controller.zig").Controller;
    pub const ActionResult = @import("http/controller.zig").ActionResult;
    pub const arg = @import("http/controller.zig").arg;
    pub const argInt = @import("http/controller.zig").argInt;
    pub const argBool = @import("http/controller.zig").argBool;
    pub const jsonResult = @import("http/controller.zig").jsonResult;
    pub const viewResult = @import("http/controller.zig").viewResult;
    pub const viewNamed = @import("http/controller.zig").viewNamed;

    pub const ViewRenderer = @import("http/view.zig").ViewRenderer;
    pub const ComponentRegistry = @import("http/view.zig").ComponentRegistry;
    pub const ComponentContext = @import("http/view.zig").ComponentContext;
    pub const ComponentResult = @import("http/view.zig").ComponentResult;
    pub const ComponentFn = @import("http/view.zig").ComponentFn;
    pub const StaticFiles = @import("http/static_files.zig").StaticFiles;
};

/// 网络工具（CIDR 解析、IP 处理、接口检测）
pub const Net = @import("net/net.zig");

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

/// Zig 版本兼容辅助
pub const compat = @import("compat.zig");

/// 显式 io 文件工具（多线程/服务端场景，不走进程级 currentIo）
pub const fsio = @import("file/fsio.zig");

/// 路径安全与 glob 匹配（排除规则通用）
pub const glob = @import("file/glob.zig");

/// URL 查询串编解码
pub const url = @import("net/url.zig");

/// 哈希小工具（SHA-256 十六进制、常量时间比较）
pub const hash = @import("crypto/hash_util.zig");

/// 线程相关：定时器、弹性线程池、Cron
pub const threading = struct {
    pub const timer = @import("threading/timer.zig");
    /// 定时器调度器（多分组）：`start` / `startNamed` / `createNamed` / `get` / `shutdownAll`
    pub const Scheduler = timer.Scheduler;
    pub const Timer = timer.Timer;
    pub const TimerTracer = timer.Tracer;
    pub const createScheduler = timer.createNamed;
    pub const getScheduler = timer.get;
    pub const shutdownSchedulers = timer.shutdownAll;
    /// 轻量级 Cron 表达式（秒 分 时 日 月 周，周支持 #n / #Ln）
    pub const cron = @import("threading/cron.zig");
    pub const Cron = cron.Cron;
    /// 弹性线程池：**短任务**才走池；长连接/流式请用独立线程 + `markAsLongTask()`
    pub const pool = @import("threading/pool.zig");
    pub const Pool = pool.Pool;
    pub const PoolOptions = pool.Options;
    pub const markAsLongTask = pool.markAsLongTask;
};

/// 企业微信机器人 Webhook 推送
pub const wecom = @import("wecom/wecom.zig");

/// 配置：TOML 子集解析 + 文本热加载（版本戳 / 原子写 / 缺失生成）
pub const config = struct {
    pub const toml = @import("config/toml.zig");
    pub const FileText = @import("config/file.zig").FileText;
    pub const FileOptions = @import("config/file.zig").Options;
    pub const getStamp = @import("config/file.zig").getStamp;
};

/// 动态队列（自动扩容的 SPSC 队列）
pub const logs = struct {
    /// 日志级别与行格式的**单一来源**（对齐 DH.NCore `LogLevel` / `Setting.LogLineFormat`）
    pub const level = @import("logs/level.zig");

    pub const DynamicQueue = @import("logs/dynamic_queue.zig").DynamicQueue;
    pub const DynamicQueueConfig = @import("logs/dynamic_queue.zig").DynamicQueueConfig;

    /// 日志轮转管理器（多策略轮转 + 异步压缩）
    pub const RotationManager = @import("logs/rotation_manager.zig").RotationManager;
    pub const AdvancedRotationConfig = @import("logs/rotation_manager.zig").AdvancedRotationConfig;
    pub const RotationStrategy = @import("logs/rotation_manager.zig").RotationStrategy;

    /// DH.RustBase 风格文本日志（按天文件 + 行格式 + 控制台着色）
    pub const TextFileLog = @import("logs/text_file_log.zig").TextFileLog;
    pub const TextLogOptions = @import("logs/text_file_log.zig").Options;
    pub const formatLine = @import("logs/text_file_log.zig").formatLine;
    pub const parseLevel = @import("logs/text_file_log.zig").parseLevel;
};

/// JSON 解析器（JSMN-like，流式解析，紧凑格式，SIMD 优化）
pub const json = struct {
    /// 从 jsmn_zig 模块导入所有核心类型
    const jsmn = @import("json/jsmn_zig.zig");
    pub const Helpers = @import("json/helpers.zig");
    pub const Query = @import("json/query.zig");

    /// JSON 解析器主类型（根据配置生成）
    pub const Jsmn = jsmn.Jsmn;

    /// JSON 解析器配置结构
    pub const Config = jsmn.Config;

    /// 默认配置（紧凑格式，SIMD 优化，完整功能）
    pub const jsmn_default_config = jsmn.jsmn_default_config;

    /// JSON 解析器构建器（支持链式配置）
    pub const JsonParser = jsmn.Jsmn(jsmn.jsmn_default_config()).JsonParser;

    /// JSON 查询错误类型
    pub const QueryError = Query.Error;

    /// JSON 查询器类型
    pub const JsonQuery = Query.JsonQuery;

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

    /// 便捷函数：快速从 JSON 中提取字符串值
    pub fn quickGetString(allocator: std.mem.Allocator, json_str: []const u8, key: []const u8) Query.Error![]u8 {
        return Query.quickGetString(allocator, json_str, key);
    }

    /// 便捷函数：从 JSON 数组中查找并提取字符串值
    pub fn quickGetStringFromArray(
        allocator: std.mem.Allocator,
        json_str: []const u8,
        options: struct {
            array_key: []const u8 = "",
            match_key: []const u8,
            match_value: []const u8,
            target_key: []const u8,
        },
    ) Query.Error![]u8 {
        return Query.quickGetStringFromArray(allocator, json_str, .{
            .array_key = options.array_key,
            .match_key = options.match_key,
            .match_value = options.match_value,
            .target_key = options.target_key,
        });
    }

    /// 便捷函数：JSON 字符串转义反转
    pub fn unescapeJsonStringAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        return Helpers.unescapeJsonStringAlloc(allocator, s);
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
///   xml.createAllocatingWriter(alloc, out, opt) — 为 std.Io.Writer.Allocating 创建安全 XML Writer
///   xml.writeToFile(doc, alloc, path, opt) — DOM→文件
///   xml.writeToFileStreaming(doc, alloc, path, opt) — DOM→流式文件写出
///   xml.Dom.documentWriteToFileStreaming(doc, alloc, path, opt) — DOM 命名空间下的流式文件写出
///   xml.writeContentToFile(alloc, path, opt, ctx, fn) — callback 风格 XML→文件
///   xml.writeContentToFileStreaming(alloc, path, opt, ctx, fn) — callback 风格 XML→流式文件
///   xml.WriterImpl.writeToFileStreaming(...) — callback 风格 XML→流式文件写出
///   xml.toString(doc, alloc, opt)     — DOM→字符串
pub const xml = @import("xml/xml.zig");

/// 通用字符串缓冲（`std.Io.Writer.Allocating` 封装：零碎拼接少一次临时分配）
pub const Buf = @import("text/buf.zig").Buf;

/// 通用十进制（尾数 + 缩放因子；解析/格式化/精确比较，不含算术）
pub const Decimal = @import("number/decimal.zig").Decimal;

/// 通用日期时间（无时区；`YYYY-MM-DD HH:MM:SS.fffffff` 文本口径；含当前时间/Unix 换算）
pub const DateTime = @import("time/datetime.zig").DateTime;

/// 数据库通用层：值模型 + 驱动。与具体 ORM 无关，任何要读写数据库的项目都可复用。
pub const db = struct {
    /// 字段值模型（Null/Bool/Int/Float/Decimal/Text/Blob/DateTime + 跨类型取值 + SQL 字面量）
    pub const Value = @import("db/value.zig").Value;
    /// SQLite 驱动（动态加载 `sqlite3.dll` / `winsqlite3.dll`，不链 libc）
    pub const sqlite = @import("db/sqlite.zig");
    /// MySQL 驱动（纯 wire protocol，不依赖 libmysqlclient）
    pub const mysql = @import("db/mysql.zig");
    /// PostgreSQL 驱动（协议 3.0，纯 wire protocol，不依赖 libpq）
    pub const postgres = @import("db/postgres.zig");
    /// SQL Server 驱动（TDS 7.4，纯 wire protocol，不依赖 ODBC / sqlncli）
    pub const tds = @import("db/tds.zig");
    /// TDengine 驱动（REST `/rest/sql`，不依赖 libtaos）
    pub const tdengine = @import("db/tdengine.zig");
    /// InfluxDB 驱动（HTTP：Line Protocol 写入 + Flux/InfluxQL 查询）
    pub const influxdb = @import("db/influxdb.zig");
    /// ClickHouse 驱动（HTTP 8123，`default_format=JSONCompact`）
    pub const clickhouse = @import("db/clickhouse.zig");
    /// 结果集行（各驱动共用）
    pub const Row = @import("db/row.zig").Row;
};

/// 便捷别名：`zzig.sqlite` == `zzig.db.sqlite`
pub const sqlite = db.sqlite;
/// 便捷别名：`zzig.mysql` == `zzig.db.mysql`
pub const mysql = db.mysql;
/// 便捷别名：`zzig.postgres` == `zzig.db.postgres`
pub const postgres = db.postgres;
/// 便捷别名：`zzig.tds` == `zzig.db.tds`
pub const tds = db.tds;
/// 便捷别名：`zzig.tdengine` == `zzig.db.tdengine`
pub const tdengine = db.tdengine;
/// 便捷别名：`zzig.influxdb` == `zzig.db.influxdb`
pub const influxdb = db.influxdb;
/// 便捷别名：`zzig.clickhouse` == `zzig.db.clickhouse`
pub const clickhouse = db.clickhouse;

/// ZIP 归档（store / deflate 两种方法；写多条目 + 读回）
pub const zip = @import("archive/zip.zig");
// 跨模块 import（test.zig → zzig 模块）不会收集。build.zig 里 `zzig-module-tests`
// 以本文件为根，靠这里把它们拉进来，否则驱动单测形同虚设。
test {
    // 日志：级别/行格式/文件头（未在此列出的文件，其 test 块不会被收集）
    _ = @import("logs/level.zig");
    _ = @import("logs/logger.zig");

    _ = @import("db/value.zig");
    _ = @import("db/row.zig");
    _ = @import("db/sqlite.zig");
    _ = @import("db/mysql.zig");
    _ = @import("db/mysql_loopback_test.zig");
    _ = @import("db/postgres.zig");
    _ = @import("db/postgres_loopback_test.zig");
    _ = @import("db/tds.zig");
    _ = @import("db/tds_loopback_test.zig");
    _ = @import("db/tdengine.zig");
    _ = @import("db/influxdb.zig");
    _ = @import("db/clickhouse.zig");
    _ = @import("db/inline.zig");
    _ = @import("db/http_loopback_test.zig");
    _ = @import("archive/zip.zig");
    _ = @import("http/server.zig");
    _ = @import("http/value.zig");
    _ = @import("http/router.zig");
    _ = @import("http/static_files.zig");
    _ = @import("http/view.zig");
    _ = @import("http/controller.zig");
    _ = @import("http/web.zig");
    _ = @import("crypto/rsa.zig");
    _ = @import("crypto/hash_util.zig");
    _ = @import("file/glob.zig");
    _ = @import("file/fsio.zig");
    _ = @import("net/url.zig");
    _ = @import("config/toml.zig");
    _ = @import("config/file.zig");
    _ = @import("logs/text_file_log.zig");
    _ = @import("threading/pool.zig");
    _ = @import("threading/timer.zig");
    _ = @import("threading/cron.zig");
    _ = @import("wecom/wecom.zig");
    _ = @import("number/decimal.zig");
    _ = @import("time/datetime.zig");
}
