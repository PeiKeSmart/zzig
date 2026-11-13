//! 日志级别与行格式的**单一来源**（对齐 DH.NCore `LogLevel` / `Setting.LogLineFormat`）。
//!
//! 为什么单独一个文件：`logger.zig`（同步门面）与 `text_file_log.zig`（文件输出）
//! 都需要同一套级别定义与配色规则。若让它们互相 `@import` 会形成循环依赖，
//! 所以把这块下沉到这里，两边各自引用 —— 一份定义，不会漂移。

const std = @import("std");

/// 日志级别。对齐 DH.NCore `NewLife.Log.LogLevel`：
/// `All = 0, Debug, Info, Warn, Error, Fatal, Off = 0xFF`。
///
/// Zig 里 `error` 是关键字，成员写作 `err`；对外字符串由 `asStr()` / `pascalName()` 给出。
pub const Level = enum(u8) {
    all = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,
    off = 6,

    /// 大写规范名（`ALL`/`DEBUG`/…），对应 DH.RustBase `LogLevel::as_str()`。
    pub fn asStr(self: Level) []const u8 {
        return switch (self) {
            .all => "ALL",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
            .off => "OFF",
        };
    }

    /// C# 枚举名（PascalCase）。
    ///
    /// DH.NCore 的行格式含 `Level` 时输出 `[{Level}]`，而 `Level` 是枚举，
    /// `ToString()` 得到 `[Info]` —— 与大写的 `asStr()` 不同，两者不能混用。
    pub fn pascalName(self: Level) []const u8 {
        return switch (self) {
            .all => "All",
            .debug => "Debug",
            .info => "Info",
            .warn => "Warn",
            .err => "Error",
            .fatal => "Fatal",
            .off => "Off",
        };
    }

    /// 解析级别名（不区分大小写），对齐 DH.NCore `LogLevel::parse`。
    ///
    /// 容忍常见别名：`trace`→debug、`warning`→warn、`error`→err、`none`/`silent`→off。
    /// 非法值返回 `null`，由调用方决定保持原级别还是回退默认值。
    pub fn parse(name: []const u8) ?Level {
        const eq = std.ascii.eqlIgnoreCase;
        const t = std.mem.trim(u8, name, " \t\r\n");
        if (eq(t, "all")) return .all;
        if (eq(t, "debug") or eq(t, "trace")) return .debug;
        if (eq(t, "info")) return .info;
        if (eq(t, "warn") or eq(t, "warning")) return .warn;
        if (eq(t, "err") or eq(t, "error")) return .err;
        if (eq(t, "fatal")) return .fatal;
        if (eq(t, "off") or eq(t, "none") or eq(t, "silent")) return .off;
        return null;
    }

    /// 同 `pascalName()`；保留旧名以兼容既有调用（文件日志早期用 `label()`）。
    pub fn label(self: Level) []const u8 {
        return self.pascalName();
    }
};

/// 日志行格式（对齐 DH.NCore `Setting.LogLineFormat`，默认 `Time|ThreadId|Kind|Name|Message`）。
pub const LineFormat = enum {
    /// `HH:MM:SS.mmm ThreadId Kind Name Message`（C# 默认：日期在文件名与 `#Date` 里）
    ncore,
    /// `HH:MM:SS.mmm ThreadId Kind Name [Level] Message`
    ncore_level,
    /// `yyyy-MM-dd HH:MM:SS.mmm ThreadId Kind Name Message`
    ///
    /// C# 默认不带日期，但多天日志合起来看、或日志被转发到集中收集时，
    /// 只有时间无法定位是哪一天。需要时把格式写成含 `DateTime` 即可，不用改代码。
    ncore_datetime,
    /// `yyyy-MM-dd HH:MM:SS.mmm ThreadId Kind Name [Level] Message`
    ncore_datetime_level,
    /// `[YYYY-MM-DD HH:MM:SS.nnnnnnnnn] [LEVEL] message`（zzig 旧格式）
    legacy,
};

/// 解析 `Setting.LogLineFormat` 的文本值（`Time|ThreadId|Kind|Name|Message` 这类竖线分隔串）。
///
/// 只区分两个维度：
/// - **是否含完整日期**：含 `DateTime`、或同时含 `Date` 与 `Time` → 用带日期的变体；
/// - **是否含级别**：含 `Level` → 用带 `[Level]` 的变体。
/// 其余列名（`ThreadId`/`Kind`/`Name`/`Message`）顺序以实际拼接为准（与 C# 一致：固定列序）。
/// 无法识别时返回 `null`（调用方保持当前格式并给出提示）。
pub fn parseLineFormat(text: []const u8) ?LineFormat {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "legacy")) return .legacy;

    var has_level = false;
    var has_datetime = false;
    var has_date = false;
    var has_time = false;
    var it = std.mem.splitScalar(u8, t, '|');
    while (it.next()) |raw| {
        const field = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(field, "Level")) has_level = true;
        if (std.ascii.eqlIgnoreCase(field, "DateTime")) has_datetime = true;
        if (std.ascii.eqlIgnoreCase(field, "Date")) has_date = true;
        if (std.ascii.eqlIgnoreCase(field, "Time")) has_time = true;
    }

    const with_date = has_datetime or (has_date and has_time);
    if (with_date) return if (has_level) .ncore_datetime_level else .ncore_datetime;
    return if (has_level) .ncore_level else .ncore;
}

/// 调色板（顺序对齐 DH.NCore `ConsoleLog.colors`，以 ANSI 亮色/标准色近似）
pub const palette = [10][]const u8{ "92", "96", "95", "97", "93", "32", "36", "35", "31", "33" };

/// 按线程号取日志行颜色码（对齐 DH.NCore `ConsoleLog`）：
/// 警告黄、错误/严重错误红，其余级别按线程号取自 10 色调色板，1 号线程灰白。
///
/// 返回**不含** `\x1b[` 前缀与 `m` 后缀的色号。
pub fn colorCode(level: Level, thread_id: u64) []const u8 {
    return switch (level) {
        .warn => "33",
        .err, .fatal => "31",
        else => if (isMainThread()) "37" else palette[thread_id % palette.len],
    };
}

/// 线程类别（**逐字对齐** DH.NCore `WriteLogEventArgs`：`Kind` 只有三个值）。
///
/// C# 源码：`sb.Append(IsPool ? (IsWeb ? 'W' : 'Y') : 'N')`
/// - `IsPool = thread.IsThreadPoolThread`（.NET 线程池成员判定）
/// - `IsWeb`：C# 里这行是注释掉的（`//IsWeb = HttpContext.Current != null`），
///   所以 `W` 在 .NET 侧实际不会出现；Zig 侧我们**真的实现了** Web 上下文，所以 `W` 可用。
///
/// 注意：`P`/`IO`/`L` 不在这里 —— 它们是 **`Name` 列**的取值（线程名映射），见 `currentThreadName()`。
pub const kind_pool = "Y";
pub const kind_web = "W";
pub const kind_normal = "N";

/// `Name` 列的特殊取值（C# `WriteLogEventArgs` 对线程名的三条映射）。
pub const name_pool_task = "P";
pub const name_io = "IO";
pub const name_long_task = "L";

/// Kind 上下文**栈**：支持嵌套（如 Web 请求内部再提交池任务）。
const kind_stack_max = 8;
threadlocal var kind_stack: [kind_stack_max]u8 = undefined;
threadlocal var kind_depth: usize = 0;
threadlocal var kind_buf: [1]u8 = undefined;

/// 进入一个场景（如 Web 请求）。必须与 `popKind()` 配对（用 `defer`）。
pub fn pushKind(kind: u8) void {
    if (kind_depth < kind_stack_max) {
        kind_stack[kind_depth] = kind;
        kind_depth += 1;
    }
}

/// 退出当前场景，恢复上一层。
pub fn popKind() void {
    if (kind_depth > 0) kind_depth -= 1;
}

/// 直接设定当前线程类别（清空已有栈）。传 `0` 表示清除。
pub fn setThreadKind(kind: u8) void {
    kind_depth = 0;
    if (kind != 0) pushKind(kind);
}

/// 当前线程由线程池托管（`threading/pool.zig` 的 worker 会置位）。
///
/// 这是 `Kind = Y` 的**真实来源**：不是“非主线程就猜成池线程”，
/// 而是“确实跑在线程池 worker 上”。
threadlocal var in_pool_worker: bool = false;

/// **仅供线程池内部**：标记/取消当前线程为池 worker。
pub fn setPoolWorker(on: bool) void {
    in_pool_worker = on;
}

/// 当前线程是否为线程池 worker。
pub fn isPoolWorker() bool {
    return in_pool_worker;
}

/// `Name` 列占位。C# `WriteLogEventArgs` 在线程名为空且无 TaskID 时同样输出 `-`。
pub const name_placeholder = "-";

/// 主线程 id（首次取线程 id 的那个线程视为进程主线程）。
var main_thread_id = std.atomic.Value(u64).init(0);

/// 当前线程的**真实**线程 id（`std.Thread.getCurrentId()`，不是自增序号）。
///
/// 之前为了"两位列宽好看"用了自增序号，但那是**编造的数据** ——
/// 日志里的 ThreadId 必须能与调试器/系统工具对上，否则排障时毫无价值。
pub fn currentThreadId() u64 {
    const raw: u64 = @intCast(std.Thread.getCurrentId());
    // 第一个取到 id 的线程即主线程（main 在起任何 worker 之前就会写日志）
    _ = main_thread_id.cmpxchgStrong(0, raw, .acq_rel, .acquire);
    return raw;
}

/// 当前线程是否为进程主线程。
pub fn isMainThread() bool {
    const main = main_thread_id.load(.acquire);
    return main == 0 or main == @as(u64, @intCast(std.Thread.getCurrentId()));
}

/// 当前线程的 `Kind` 字符：主线程 `N`，其余 `Y`。
/// 当前线程的 `Kind`：宿主标注优先，否则主线程 `N` / 其它线程 `Y`。
/// 当前线程的 `Kind`：显式场景栈 > 线程池成员 > 默认 `N`。
///
/// 与 C# 的对应关系：`Y` ≡ `IsPool`、`W` ≡ `IsPool && IsWeb`、`N` ≡ 其余。
pub fn currentKind() []const u8 {
    if (kind_depth > 0) {
        kind_buf[0] = kind_stack[kind_depth - 1];
        return kind_buf[0..1];
    }
    return if (in_pool_worker) kind_pool else kind_normal;
}

threadlocal var thread_name: ?[]const u8 = null;

/// 设置当前线程在日志 `Name` 列里的名字（可选）。
///
/// Zig 没有读取"系统线程名"的跨平台 API，所以由调用方显式给出；
/// 不设置时输出 `-`（与 C# 在无线程名且无 TaskID 时的行为一致）。
pub fn setThreadName(name: []const u8) void {
    thread_name = name;
}

/// 当前线程的 `Name` 列取值。
/// 当前线程的 `Name` 列取值。
///
/// 完全对垒 C# `WriteLogEventArgs` 的三条特判：
/// - 线程名以 `Threadpool` / `.NET ThreadPool` / `.NET TP` / `Thread Pool` 开头 → `P`；
/// - `IO Threadpool worker` → `IO`；
/// - `.NET Long Running Task` → `L`；
/// - 其余用线程名原文；未设置 → `-`（与 C# 无线程名且无 TaskID 时一致）。
pub fn currentThreadName() []const u8 {
    const raw = thread_name orelse return name_placeholder;
    if (startsWithIgnoreCase(raw, "Threadpool") or
        startsWithIgnoreCase(raw, ".NET ThreadPool") or
        startsWithIgnoreCase(raw, ".NET TP") or
        startsWithIgnoreCase(raw, "Thread Pool")) return name_pool_task;
    if (std.ascii.eqlIgnoreCase(raw, "IO Threadpool worker")) return name_io;
    if (std.ascii.eqlIgnoreCase(raw, ".NET Long Running Task")) return name_long_task;
    return raw;
}

/// 大小写不敏感的前缀判定（Zig std 无直接函数，这里补齐；C# 侧用 `StartsWithIgnoreCase`）。
fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "level：7 级顺序对齐 C# LogLevel（All=0 … Off 最大）" {
    try testing.expectEqual(@as(u8, 0), @backingInt(Level.all));
    try testing.expect(@backingInt(Level.debug) < @backingInt(Level.info));
    try testing.expect(@backingInt(Level.info) < @backingInt(Level.warn));
    try testing.expect(@backingInt(Level.warn) < @backingInt(Level.err));
    try testing.expect(@backingInt(Level.err) < @backingInt(Level.fatal));
    try testing.expect(@backingInt(Level.fatal) < @backingInt(Level.off));
}

test "level：asStr 大写、pascalName 为 C# 枚举名" {
    try testing.expectEqualStrings("INFO", Level.info.asStr());
    try testing.expectEqualStrings("Info", Level.info.pascalName());
    try testing.expectEqualStrings("Error", Level.err.pascalName());
    try testing.expectEqualStrings("Error", Level.err.label()); // 旧名兼容
}

test "level：parse 容忍大小写与别名" {
    try testing.expectEqual(Level.debug, Level.parse("TRACE").?);
    try testing.expectEqual(Level.warn, Level.parse(" warning ").?);
    try testing.expectEqual(Level.err, Level.parse("error").?);
    try testing.expectEqual(Level.off, Level.parse("silent").?);
    try testing.expectEqual(@as(?Level, null), Level.parse("verbose"));
}

test "level：LineFormat 文本解析（含 Level 才用 ncore_level）" {
    try testing.expectEqual(LineFormat.ncore, parseLineFormat("Time|ThreadId|Kind|Name|Message").?);
    try testing.expectEqual(LineFormat.ncore_level, parseLineFormat("Time|ThreadId|Kind|Name|Level|Message").?);
    try testing.expectEqual(LineFormat.legacy, parseLineFormat("legacy").?);
    try testing.expectEqual(@as(?LineFormat, null), parseLineFormat("   "));
}

test "level：配色对齐 C#（warn 黄 / error 红 / 主线程灰白）" {
    try testing.expectEqualStrings("33", colorCode(.warn, 5));
    try testing.expectEqualStrings("31", colorCode(.err, 5));
    try testing.expectEqualStrings("31", colorCode(.fatal, 5));
    // 当前线程即主线程（测试在主线程跑）→ 非 warn/err 用灰白
    try testing.expect(isMainThread());
    try testing.expectEqualStrings("37", colorCode(.info, 5));
}

test "level：ThreadId 为真实线程 id；Kind 区分主/工作线程；Name 默认 - 可设置" {
    const id = currentThreadId();
    try testing.expect(id != 0); // 真实 OS 线程 id 不可能为 0
    try testing.expectEqualStrings("N", currentKind()); // 测试跑在主线程
    try testing.expectEqualStrings("-", currentThreadName());

    setThreadName("main-loop");
    try testing.expectEqualStrings("main-loop", currentThreadName());
}
