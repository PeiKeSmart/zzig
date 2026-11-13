const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const levels = @import("level.zig");
const text_log = @import("text_file_log.zig");

/// 文件日志实现（按天滚动 + 大小拆分 + 备份清理），供需要直接使用的场景。
pub const TextFileLog = text_log.TextFileLog;

/// 日志级别（**单一来源**：`logs/level.zig`，对齐 DH.NCore `LogLevel`）。
///
/// 定义与配色规则都在 `level.zig`；这里只是转出，供既有调用方沿用 `logger.Level` 路径。
pub const Level = levels.Level;
pub const LineFormat = levels.LineFormat;
pub const parseLineFormat = levels.parseLineFormat;

const kind_normal = levels.kind_normal;
const kind_worker = levels.kind_worker;
const currentKind = levels.currentKind;
const currentThreadName = levels.currentThreadName;
const name_placeholder = levels.name_placeholder;
const colorCode = levels.colorCode;
const currentThreadId = levels.currentThreadId;

/// 当前行格式（默认对齐 DH.NCore：`Time ThreadId Kind Name Message`）
///
/// **原子存**：热加载线程可能随时改写，日志线程同时读取，普通全局变量属数据竞争。
var line_format_store = std.atomic.Value(u8).init(@backingInt(LineFormat.ncore));

/// 设置日志行格式。
pub fn setLineFormat(f: LineFormat) void {
    line_format_store.store(@backingInt(f), .release);
}

/// 取当前行格式。
pub fn getLineFormat() LineFormat {
    return @fromBackingInt(@intCast(line_format_store.load(.acquire)));
}

// ============ 输出目标（控制台 / 文件，可同时开）============

/// 控制台输出开关（默认开）
///
/// **原子存**：热加载线程按 `LogConsole` 改写，worker 线程同时读取。
var console_enabled_store = std.atomic.Value(bool).init(true);

/// 非原子镜像：仅用于“热加载中”的块状引用，保持代码可读（读取请用 [`consoleEnabled`]）
fn consoleEnabledRaw() bool {
    return console_enabled_store.load(.acquire);
}

/// 文件输出（为 null 表示只写控制台）。按天滚动 + 大小拆分 + 备份清理由 `TextFileLog` 负责。
var file_sink: ?text_log.TextFileLog = null;

/// 文件输出的互斥锁：`log()` 可能被多线程并发调用，而 `TextFileLog` 自身只在 `log()` 路径上持锁，
/// 我们走的是 `writeRawLine`，所以在这里串行化。
var file_mutex: compat.Mutex = .{};

/// 打开/关闭控制台输出。
pub fn setConsole(on: bool) void {
    console_enabled_store.store(on, .release);
}

/// 是否启用控制台输出。
pub fn consoleEnabled() bool {
    return console_enabled_store.load(.acquire);
}

// ============ 异步写入（业务线程零 IO）============
//
// 性能设计（对齐 DH.NCore / DH.RustBase 的「队列 + 写线程」模型）：
// 1. `log()` 只做「格式化 + 入队」，**不碰任何 IO** —— 业务线程不会被磁盘/控制台拖住；
// 2. 队列无锁（`MPMCQueue`）、容量固定（默认 1024，对齐 DH.NCore `MAX_QUEUE`）；
// 3. 队列满时**丢弃新日志并计数**，既不让业务线程阻塞，也不让内存无界增长；
// 4. 写线程一次取批、逐条落盘；空闲时睡 1ms，不空转烧 CPU；
// 5. 退出前必须 `shutdown()`（或 `flush()`），否则队列里的日志会随进程消失。

const mpmc = @import("mpmc_queue.zig");

/// 一条待写日志：整行已格式化（不含换行），由写线程负责释放 `text`。
const PendingLine = struct {
    level: Level,
    thread_id: u64,
    text: []u8,
};

const default_queue_capacity: usize = 65536;

/// 队列（null = 未启用异步，走同步路径）
var pending: ?*mpmc.MPMCQueue(PendingLine) = null;
var worker: ?std.Thread = null;
var worker_stop = std.atomic.Value(bool).init(true);
var queue_alloc: std.mem.Allocator = std.heap.smp_allocator;
/// 启动时的队列容量（便于查询/日志）
var queue_capacity: usize = 0;
/// 因队列满被丢弃的日志条数（只计数不刷日志，避免形成二次拥塞）
pub var dropped = std.atomic.Value(u64).init(0);

/// 启用异步写入（**建议在 `main` 开头调用**）。
///
/// - `capacity` 是队列长度上限；满了丢弃新日志并计入 `dropped()`；
/// - 重复调用是安全的（已启动则只更新容量请求被忽略，返回当前容量）。
///
/// 退出前务必 `shutdown()`。
pub fn startAsync(capacity: usize) !usize {
    if (pending != null) return queueCapacity();
    if (!build_options.async_available) return error.AsyncUnsupported;

    const cap = if (capacity == 0) default_queue_capacity else capacity;
    const q = try queue_alloc.create(mpmc.MPMCQueue(PendingLine));
    errdefer queue_alloc.destroy(q);
    q.* = try mpmc.MPMCQueue(PendingLine).init(queue_alloc, cap);

    worker_stop.store(false, .release);
    const t = std.Thread.spawn(.{ .stack_size = 128 * 1024 }, workerLoop, .{q}) catch |e| {
        q.deinit(queue_alloc);
        queue_alloc.destroy(q);
        return e;
    };
    pending = q;
    worker = t;
    queue_capacity = cap;
    return queue_capacity;
}

/// 当前队列容量（未启用异步时为 0）。
pub fn queueCapacity() usize {
    if (pending != null) return queue_capacity;
    return 0;
}

/// 队列当前积压条数（用于健康检查/自监控）。
pub fn queueSize() usize {
    if (pending) |q| return q.size();
    return 0;
}

/// 被丢弃的日志条数（队列满时）。
pub fn droppedCount() u64 {
    return dropped.load(.acquire);
}

/// 把队列里已排队的日志**同步**写完（不停止写线程，可随时调用）。
///
/// 用途：关键节点（配置重载前、升级重启前）确保日志落盘。
pub fn flush() void {
    if (pending == null) return;
    // 给写线程一点时间排空；上限约 2 秒，避免异常情况卡死退出流程。
    var spins: usize = 0;
    while (queueSize() > 0 and spins < 2000) : (spins += 1) {
        compat.sleep(1 * std.time.ns_per_ms);
    }
}

/// **安全退出**：记录退出日志 → 排空队列 → 停写线程 → 关闭文件。**幂等**。
///
/// 每个 Zig 应用都应当在 `main` 里挂上：
/// ```zig
/// pub fn main(init: std.process.Init) !void {
///     defer zzig.Logger.shutdown();
///     ...
/// }
/// ```
/// 少了这一步，队列中尚未落盘的日志会随进程一起消失（异步日志的固有代价）。
pub fn shutdown() void {
    // 先记一条退出日志（会入队，随后被排空写入）
    if (pending != null) {
        const left = queueSize();
        info("进程退出：开始刷写日志（队列积压 {d} 条，累计丢弃 {d} 条）", .{ left, droppedCount() });
    }

    if (pending) |q| {
        worker_stop.store(true, .release);
        if (worker) |t| {
            t.join();
            worker = null;
        }
        // worker 已退出，理论上队列已空；兜底清掉残留（不丢文本引用）
        while (q.tryPop()) |item| queue_alloc.free(item.text);
        q.deinit(queue_alloc);
        queue_alloc.destroy(q);
        pending = null;
    }
    // 先停热加载线程，再释放配置源：否则线程可能正在 `reloadIfChanged` 里
    // 使用 `config_source`（停在前、关在后，二者无并发）
    stopAutoReload();
    // 配置源也在这里释放：否则 `FileText` 持有的 path/text 会随进程一起泄漏
    closeConfigSource();
    closeFile();
}

/// 写线程：批量取、逐条落盘；无数据时睡 1ms（不空转）。
/// 写线程：**批量取 + 批量落盘**（对齐 DH.NCore / DH.RustBase 的队列写法）。
///
/// 为什么必须批量：逐条写时每条日志至少 1 次控制台系统调用 + 1 次文件写入，
/// 几万条突发就会把队列撑满导致丢弃。批量后一次取 `batch_*` 条、文件只写一次，
/// 吞吐差一个数量级。
const worker_batch: usize = 256;

fn workerLoop(q: *mpmc.MPMCQueue(PendingLine)) void {
    var idle: usize = 0;
    var batch_buf: [worker_batch]PendingLine = undefined;

    while (true) {
        var n: usize = 0;
        while (n < worker_batch) {
            const item = q.tryPop() orelse break;
            batch_buf[n] = item;
            n += 1;
        }

        if (n > 0) {
            emitBatch(batch_buf[0..n]);
            for (batch_buf[0..n]) |item| queue_alloc.free(item.text);
            idle = 0;
            if (worker_stop.load(.acquire) and q.isEmpty()) return;
            continue;
        }

        if (worker_stop.load(.acquire) and q.isEmpty()) return;
        idle += 1;
        if (idle < 50) {
            std.Thread.yield() catch {};
        } else {
            // 空闲 1ms 后休眠：不空转烧 CPU，但响应仍然及时
            compat.sleep(1 * std.time.ns_per_ms);
        }
    }
}

/// 批量输出：文件一次写、控制台一次写（各行颜色转义内联，终端会逐行生效）。
fn emitBatch(items: []const PendingLine) void {
    // ---------- 文件：拼成一块，一次系统调用 ----------
    file_mutex.lock();
    if (file_sink) |*sink| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(queue_alloc);
        for (items) |item| {
            buf.appendSlice(queue_alloc, item.text) catch break;
            buf.append(queue_alloc, '\n') catch break;
        }
        sink.writeRawBlock(buf.items);
    }
    file_mutex.unlock();

    if (!consoleEnabledRaw()) return;

    // ---------- 控制台：同样拼成一块（含颜色），一次写出 ----------
    var out: std.Io.Writer.Allocating = .init(queue_alloc);
    defer out.deinit();
    for (items) |item| {
        out.writer.print("\x1b[{s}m{s}\n\x1b[0m", .{
            colorCode(item.level, item.thread_id), item.text,
        }) catch break;
    }

    if (builtin.os.tag != .windows) {
        std.debug.print("{s}", .{out.written()});
        return;
    }
    // Windows：批量已在堆上，直接走一次 UTF-16 转换 + WriteConsoleW
    printUtf8(queue_alloc, out.written());
}

// ============ 文件输出 ============

/// 打开文件日志（与控制台**同时**输出，除非 `opts.use_console = false`）。
///
/// 目录、按天滚动、单文件上限与备份数量都在 `TextFileLog.Options` 里，
/// 字段含义对齐 DH.NCore `Setting`：`LogPath` / `LogFileMaxBytes` / `LogFileBackups`。
///
/// **热加载安全**：先把新 sink 建好，再在 `file_mutex` 内一次性换指针，
/// 旧的等解锁后再释放 —— 写入方只能在锁内拿到 `file_sink`，
/// 所以不会出现「一边 closeFile、一边还在写」的 use-after-free。
pub fn useFile(io: std.Io, gpa: std.mem.Allocator, opts: text_log.Options) !void {
    // **头与数据必须同源**：`Options.line_format` 决定文件头 `#Fields`，
    // 若不同步到全局行格式，就会出现「表头写着 Level 列、正文却没有」这种自相矛盾的日志。
    // 直接调用 `useFile` 而没走 `applyConfig` 时，这里保证两者一致。
    if (parseLineFormat(opts.line_format)) |f| setLineFormat(f);

    const owned_dir = try gpa.dupe(u8, opts.dir);
    errdefer gpa.free(owned_dir);

    var o = opts;
    o.dir = owned_dir;
    const new_sink = try text_log.TextFileLog.init(io, gpa, getLevel(), o);

    file_mutex.lock();
    const old_sink = file_sink;
    const old_dir = file_dir;
    const old_gpa = file_gpa;
    file_sink = new_sink;
    file_dir = owned_dir;
    file_gpa = gpa;
    file_mutex.unlock();

    // 此时已无人能再拿到旧指针，可以安全释放
    if (old_sink) |sink_copy| {
        var s = sink_copy;
        s.deinit();
    }
    if (old_dir) |d| {
        if (old_gpa) |g| g.free(d);
    }
}

/// 关闭文件输出并释放资源（幂等、线程安全）。
pub fn closeFile() void {
    file_mutex.lock();
    const old_sink = file_sink;
    const old_dir = file_dir;
    const old_gpa = file_gpa;
    file_sink = null;
    file_dir = null;
    file_gpa = null;
    file_mutex.unlock();

    // 写入方只在锁内取 `file_sink`，所以解锁后释放是安全的
    if (old_sink) |sink_copy| {
        var s = sink_copy;
        s.deinit();
    }
    if (old_dir) |d| {
        if (old_gpa) |g| g.free(d);
    }
}

/// 是否已打开文件输出。
pub fn fileEnabled() bool {
    file_mutex.lock();
    defer file_mutex.unlock();
    return file_sink != null;
}

var file_dir: ?[]u8 = null;
var file_gpa: ?std.mem.Allocator = null;

// ============ 配置文件与热加载 ============
//
// 目标：**改配置不用改代码、不用重启**。
// 安全设计（对齐 DH.NCore `Config` 语义）：
// 1. 读：`FileText.reloadIfChanged` 用 mtime+size 版本戳，未变则零开销返回；
// 2. 写：`FileText.save` 走 `writeFileAtomic`（临时文件 + rename），不会出现半截文件；
// 3. 坏文件：解析失败**自动备份**为 `<名>.bad.<时间戳>`，保留现场供排查，
//    且**继续使用内存中上一份好配置**（绝不让一次手误把服务打成默认值）；
// 4. 缺文件：按模板自动生成（含注释），运维照着改即可。

const config_file = @import("../config/file.zig");
const toml_config = @import("../config/toml.zig");
const fsio = @import("../file/fsio.zig");

/// 日志配置项。
///
/// 字段名**按 DH.NCore `Setting` 的 PascalCase 命名**，让 C# / Rust / Zig 三端
/// 能共用同一份配置文件、同一套含义。
pub const Config = struct {
    /// 只输出 >= 该级别的日志。`All/Debug/Info/Warn/Error/Fatal/Off`，默认 Info
    ///
    /// **「要不要输出」由它决定，「输出到哪」由 `LogPath` / `LogConsole` 决定**。
    LogLevel: []const u8 = "Info",
    /// 日志目录，默认 `Log`（按 DH 约定）。
    ///
    /// 默认**控制台 + 文件同时输出**；只想控制台就把这里留空 `""`。
    /// 相对路径基于进程工作目录；目录不存在会自动创建。
    LogPath: []const u8 = "Log",
    /// 单文件上限（字节），超限拆分为 `_2`、`_3`…；0 表示不限制
    LogFileMaxBytes: u64 = 10 * 1024 * 1024,
    /// 保留份数，超出后删除最旧；0 表示不限制
    LogFileBackups: usize = 200,
    /// 行格式：`Time|ThreadId|Kind|Name|Message`（含 `Level` 则追加级别列）
    LogLineFormat: []const u8 = "Time|ThreadId|Kind|Name|Message",
    /// 是否输出到控制台
    LogConsole: bool = true,
    /// 异步队列容量（满了丢弃新日志并计数，不会阻塞业务线程）
    LogAsyncQueue: usize = default_queue_capacity,
};

/// 配置文件的**唯一布局来源**（注释与顺序都写在这里）。
///
/// 两种用途共用同一份文案，避免「模板有注释、重写没注释」这类漂移：
/// 1. 编译期由 `Config` 的默认值渲染成 [`default_config_template`]（文件缺失时生成）；
/// 2. 运行期由 [`renderConfigText`] 用**实际生效值**渲染（文件缺注释/缺键时自愈重写）。
const config_template_layout =
    \\# zzig 日志配置（字段名与含义对齐 DH.NCore Setting，C# / Rust / Zig 三端共用）
    \\#
    \\# 级别：All / Debug / Info / Warn / Error / Fatal / Off
    \\#        也接受别名：trace→Debug、warning→Warn、error→Error、none|silent→Off
    \\#        默认 Info；排障时临时改 Debug 即可看到逐条明细（一条日志都没删）
    \\LogLevel = "{s}"
    \\
    \\# 日志目录。默认 Log（按 DH 约定）；留空 = 只输出到控制台，不落文件
    \\# 相对路径基于进程工作目录；目录不存在会自动创建
    \\LogPath = "{s}"
    \\
    \\# 单文件上限（字节）。超过就拆分为 xxx_2.log、xxx_3.log …；0 = 不限制
    \\LogFileMaxBytes = {d}
    \\
    \\# 保留份数。超出后删除最旧的一份；0 = 不限制
    \\LogFileBackups = {d}
    \\
    \\# 行格式。可用列：Time / DateTime / ThreadId / Kind / Name / Message / Level
    \\# 例：LogLineFormat = "DateTime|ThreadId|Kind|Name|Message|Level"
    \\LogLineFormat = "{s}"
    \\
    \\# 是否输出到控制台。false 时只写文件
    \\LogConsole = {}
    \\
    \\# 异步队列容量。队列满时丢弃新日志并计数（`dropped`），不会阻塞业务线程
    \\LogAsyncQueue = {d}
    \\
;

/// `Config` 的默认值实例（编译期常量，供模板渲染用）。
const config_defaults: Config = .{};

/// 把 `Config` 展开成模板所需的参数元组（渲染口径唯一，避免两处参数顺序不一致）。
fn configTemplateArgs(cfg: Config) struct {
    []const u8,
    []const u8,
    u64,
    usize,
    []const u8,
    bool,
    usize,
} {
    return .{
        cfg.LogLevel,
        cfg.LogPath,
        cfg.LogFileMaxBytes,
        cfg.LogFileBackups,
        cfg.LogLineFormat,
        cfg.LogConsole,
        cfg.LogAsyncQueue,
    };
}

const default_config_template_arr = blk: {
    @setEvalBranchQuota(20000);
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(
        &buf,
        config_template_layout,
        configTemplateArgs(config_defaults),
    ) catch @compileError("日志配置模板渲染失败：布局占位符与 Config 字段不匹配");
    break :blk s[0..s.len].*;
};

/// 配置文件缺失时自动生成的内容（**带注释**，运维可直接改）。
///
/// 由 [`config_template_layout`] + `Config` 默认值在**编译期**渲染，
/// 所以不会再出现「模板写着 8192、代码默认 65536」这种漂移
/// （历史 bug：新生成的配置文件反而把队列改小了 8 倍）。
pub const default_config_template: []const u8 = &default_config_template_arr;

/// 用**给定值**渲染一份带完整注释的配置文本（自愈重写用）。
pub fn renderConfigText(gpa: std.mem.Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(gpa, config_template_layout, configTemplateArgs(cfg));
}

/// 配置来源（`loadConfigFile` 成功后非 null，供 `reloadIfChanged` 做增量检测）。
const ConfigSource = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    file: config_file.FileText,
};

var config_source: ?ConfigSource = null;
/// 坏配置只备份一次，避免每次 reload 都堆一个新 `.bad` 文件
var bad_config_backed: bool = false;
/// 配置重载/关闭的互斥：`reloadNow()` 与热加载线程可能并发
var reload_mutex: compat.Mutex = .{};

/// 应用一份配置（不涉及文件），顺序：级别 → 行格式 → 控制台 → 队列 → 文件。
///
/// 任何一项值非法都**保持原值并告警**，不会因为一个字段配错就整体回退。
pub fn applyConfig(io: std.Io, gpa: std.mem.Allocator, cfg: Config) !void {
    if (Level.parse(cfg.LogLevel)) |lv| {
        setLevel(lv);
    } else {
        err("日志配置 LogLevel=\"{s}\" 非法（应为 All/Debug/Info/Warn/Error/Fatal/Off），保持 {s}", .{ cfg.LogLevel, getLevel().asStr() });
    }

    if (parseLineFormat(cfg.LogLineFormat)) |f| {
        setLineFormat(f);
    } else {
        err("日志配置 LogLineFormat=\"{s}\" 无法识别，保持当前行格式", .{cfg.LogLineFormat});
    }

    setConsole(cfg.LogConsole);

    if (pending == null) {
        _ = startAsync(cfg.LogAsyncQueue) catch |e| {
            err("日志异步队列启动失败（{s}），退回同步写入（会阻塞调用线程）", .{@errorName(e)});
        };
    }

    if (cfg.LogPath.len == 0) {
        closeFile();
    } else {
        try useFile(io, gpa, .{
            .dir = cfg.LogPath,
            .use_console = false, // 控制台由 console_enabled 统一控制，避免重复输出
            .max_file_bytes = cfg.LogFileMaxBytes,
            .backups = cfg.LogFileBackups,
        });
    }
}

/// 配置文本审计结果（用于「加载即自愈」）。
const ConfigAudit = struct {
    /// 缺少的已知配置项个数
    missing: usize = 0,
    /// 文本里是否有注释行（`#`）——没有说明是机器/手写裸键，应补注释
    has_comment: bool = false,
    /// 未知键名（属于 `table` 的键切片，仅在本次加载的 arena 生命周期内有效）
    unknown: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn isKnownConfigKey(name: []const u8) bool {
    inline for (@typeInfo(Config).@"struct".field_names) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

/// 审计配置文本：缺了哪些键、有没有注释、多出哪些未知键。
fn auditConfigText(a: std.mem.Allocator, text: []const u8, table: *toml_config.Table) ConfigAudit {
    var audit = ConfigAudit{};
    audit.has_comment = std.mem.indexOfScalar(u8, text, '#') != null;

    // 缺键：按 Config 字段逐个查（decode 会填默认值，但文件本身仍然缺，运维看不到）
    inline for (@typeInfo(Config).@"struct".field_names) |name| {
        if (table.get(name) == null) audit.missing += 1;
    }

    // 未知键：拼错/改名/别的程序的键都要报出来，避免「配了却不生效」
    var it = table.iterator();
    while (it.next()) |entry| {
        if (!isKnownConfigKey(entry.key_ptr.*)) {
            audit.unknown.append(a, entry.key_ptr.*) catch break;
        }
    }
    return audit;
}

/// 自愈：备份原文件 → 用**实际生效值** + 完整注释重写（未知键直接丢弃）。
fn repairConfigFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: *config_file.FileText,
    cfg: Config,
    audit: ConfigAudit,
) !void {
    // 先留现场：任何自愈都必须可回退
    const backup_path = try std.fmt.allocPrint(gpa, "{s}.old", .{file.path});
    defer gpa.free(backup_path);
    fsio.writeFileAtomic(io, gpa, backup_path, file.current()) catch |e| {
        warn("日志配置自愈前备份失败（{s}）：{s}，本次不自愈", .{ backup_path, @errorName(e) });
        return;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const head = try renderConfigText(gpa, cfg);
    defer gpa.free(head);
    try out.appendSlice(gpa, head);

    try file.save(out.items);

    warn(
        "日志配置已自愈：{s}（补齐 {d} 个缺省项，清理 {d} 个未知项，补全注释；原文件备份为 {s}）",
        .{ file.path, audit.missing, audit.unknown.items.len, backup_path },
    );
}

/// 从 TOML 配置文件加载并应用；同时记下来源以便 `reloadIfChanged`。
///
/// 文件不存在 → 按 `default_config_template` 自动生成（含注释）后加载。
/// 文件存在但**缺键 / 没有注释 / 有多余键** → 备份为 `<名>.old` 后按模板自愈重写：
/// 值一律取实际生效值，多余的键直接清理，保证配置文件永远自解释、不缺项。
pub fn loadConfigFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    closeConfigSource();
    // 热加载线程要用同一个 Io（`reloadIfChanged` 内部实际用 `config_source.io`，这里仅保持口径一致）
    reload_io = io;

    var file = try config_file.FileText.open(io, gpa, path, default_config_template, .{});
    errdefer file.deinit();

    // 配置解析用**专用 arena**：`toml.parse` 的裸键返回的是原文切片（非堆），
    // 手工 free 会 "free of invalid memory"；arena 一次释放既安全又快。
    // `applyConfig` 会把需长期保留的字段（如 LogPath）自己 dupe，cfg 用完即可丢。
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const table = toml_config.parse(aa, file.current()) catch |e| {
        // 首次加载就坏：备份现场后返回错误（调用方决定是否继续用默认值）。
        // 注意：清理交给上面的 `errdefer file.deinit()`，这里**不能再手动 deinit**，
        // 否则 errdefer 会二次释放 notes/text/path（曾经的段错误根因）。
        backupBadConfig(io, gpa, path, file.current(), @errorName(e));
        return e;
    };

    const audit = auditConfigText(aa, file.current(), table);
    if (audit.unknown.items.len > 0) {
        for (audit.unknown.items) |name| {
            warn("日志配置出现多余项 \"{s}\"（{s}）—— 拼写错误或已废弃，将随自愈一并清理", .{ name, path });
        }
    }

    const cfg = toml_config.decode(Config, aa, table) catch |e| {
        // 同上：清理由 `errdefer` 负责，避免重复释放
        backupBadConfig(io, gpa, path, file.current(), @errorName(e));
        return e;
    };

    try applyConfig(io, gpa, cfg);

    // 自愈：缺项 / 无注释 / 多余项都修掉（失败只告警，绝不影响已生效的配置）
    if (audit.missing > 0 or !audit.has_comment or audit.unknown.items.len > 0) {
        repairConfigFile(io, gpa, &file, cfg, audit) catch |e| {
            warn("日志配置自愈失败（{s}），继续使用当前生效配置：{s}", .{ path, @errorName(e) });
        };
    }

    config_source = .{ .io = io, .gpa = gpa, .file = file };
    bad_config_backed = false;

    // 关键：**自动开启热加载**。否则调用方忘了调 `reloadIfChanged`，
    // 手改配置文件就永远不会生效（这正是「改了配置却像没改」的根因）。
    startAutoReload(default_reload_interval_ms);
}

/// 配置文件有变更则重新应用；返回是否真的重载了。
///
/// 典型用法：在主循环 / 定时任务里每隔几秒调一次（未变更时只是一次 `stat`，开销极低）。
/// 解析失败时**保留当前生效配置**，并把坏文件备份成 `<名>.bad.<时间戳>`。
pub fn reloadIfChanged(io: std.Io) !bool {
    _ = io;
    // 允许 `reloadNow()` 与热加载线程并发调用：配置源、arena、自愈写入都不能重入
    reload_mutex.lock();
    defer reload_mutex.unlock();

    if (config_source == null) return false;
    const src = &config_source.?;

    const changed = try src.file.reloadIfChanged(.{});
    if (!changed) return false;

    var arena = std.heap.ArenaAllocator.init(src.gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const table = toml_config.parse(aa, src.file.current()) catch |e| {
        backupBadConfig(src.io, src.gpa, src.file.path, src.file.current(), @errorName(e));
        err("日志配置 {s} 解析失败（{s}），继续使用上一份生效配置", .{ src.file.path, @errorName(e) });
        return false;
    };
    const cfg = toml_config.decode(Config, aa, table) catch |e| {
        backupBadConfig(src.io, src.gpa, src.file.path, src.file.current(), @errorName(e));
        err("日志配置 {s} 字段解码失败（{s}），继续使用上一份生效配置", .{ src.file.path, @errorName(e) });
        return false;
    };

    try applyConfig(src.io, src.gpa, cfg);

    // 热加载同样自愈：外部编辑把键删了/拼错了/注释删了，也一并补齐
    // （`file.save` 会刷新版本戳，所以不会因为自己这次重写又触发下一轮重载）
    const audit = auditConfigText(aa, src.file.current(), table);
    if (audit.missing > 0 or !audit.has_comment or audit.unknown.items.len > 0) {
        repairConfigFile(src.io, src.gpa, &src.file, cfg, audit) catch |e| {
            warn("日志配置自愈失败（{s}），继续使用当前生效配置：{s}", .{ src.file.path, @errorName(e) });
        };
    }

    bad_config_backed = false;
    return true;
}

/// 关闭配置来源（不再热加载）。
pub fn closeConfigSource() void {
    reload_mutex.lock();
    defer reload_mutex.unlock();
    if (config_source) |*src| {
        src.file.deinit();
        config_source = null;
    }
}

// ============ 自动热加载（手改配置文件即生效，不用重启）============
//
// 为什么必须有：配置文件的价值就是「不改代码就能调」。
// 只提供 `reloadIfChanged` 而没人调用，等于手改配置永远不生效 ——
// 这与 DH.NCore `Config<T>` 用 `TimerX` 每秒检查一次文件的行为不一致。
//
// 线程安全：
// - `config_source` 只被本线程与 `closeConfigSource` 访问，而 `shutdown` 会**先停线程再关源**；
// - `file_sink` 的读写/交换/释放全部走 `file_mutex`（见 useFile/closeFile/emitText/emitBatch）。

/// 默认检查间隔：1000ms（未变更时只是一次 `stat`，开销可忽略）
pub const default_reload_interval_ms: usize = 1000;

var reload_thread: ?std.Thread = null;
var reload_stop = std.atomic.Value(bool).init(true);
/// 配置文件所在环境提供的 `Io`（`reloadIfChanged` 内部用 `config_source.io`，这里仅透传）
var reload_io: std.Io = undefined;

/// 启动自动热加载（已启动则忽略；没有加载过配置文件时不做任何事）。
pub fn startAutoReload(interval_ms: usize) void {
    if (reload_thread != null) return;
    if (config_source == null) return;

    const interval = if (interval_ms == 0) default_reload_interval_ms else interval_ms;
    reload_stop.store(false, .release);
    reload_thread = std.Thread.spawn(
        .{ .stack_size = 128 * 1024 },
        reloadLoop,
        .{interval},
    ) catch |e| {
        reload_stop.store(true, .release);
        reload_thread = null;
        warn(
            "日志配置热加载线程启动失败（{s}）：手改配置需调用 reloadNow() 或重启才生效",
            .{@errorName(e)},
        );
        return;
    };
}

/// 停止自动热加载（幂等）。
pub fn stopAutoReload() void {
    reload_stop.store(true, .release);
    if (reload_thread) |t| {
        t.join();
        reload_thread = null;
    }
}

/// 立即重载一次配置（返回是否真的变了）。热加载线程未启动时也可手动调。
pub fn reloadNow() !bool {
    if (config_source == null) return false;
    return reloadIfChanged(reload_io);
}

fn reloadLoop(interval_ms: usize) void {
    // 对齐 DH.NCore：`TimerScheduler` 名为 Default 时调度线程名就是 `T`，
    // 于是这些定时回调的日志 `Name` 列会显示 `T`。
    levels.setThreadName("T");

    // 分片睡眠：既控制检查频率，又让 `stopAutoReload()` 能快速返回（最多 100ms）
    const slice_ns: u64 = 100 * std.time.ns_per_ms;
    var elapsed_ms: usize = 0;
    while (!reload_stop.load(.acquire)) {
        compat.sleep(slice_ns);
        elapsed_ms += 100;
        if (elapsed_ms < interval_ms) continue;
        elapsed_ms = 0;
        if (reload_stop.load(.acquire)) return;

        _ = reloadIfChanged(reload_io) catch |e| {
            warn("日志配置热加载失败（{s}），继续使用当前生效配置", .{@errorName(e)});
        };
    }
}

/// **应用入口**：启用异步日志 → 可选加载配置文件。推荐每个 Zig 应用在 `main` 开头调用。
///
/// ```zig
/// pub fn main(init: std.process.Init) !void {
///     try zzig.Logger.init(init.io, init.gpa, "Config/logger.toml");
///     defer zzig.Logger.shutdown(); // 退出前刷写并关文件
///     zzig.Logger.info("服务启动", .{});
/// }
/// ```
///
/// - `config_path` 为 null 时用内置默认值（**控制台 + 文件**，目录 `Log`，`Info` 级别）；
/// - 配置文件缺失会**自动按模板生成**（带注释）；
/// - 配置读取失败不致命：退回默认值并记一条 error（服务照常启动，不至于因为一个日志配置打不开）。
pub fn init(io: std.Io, gpa: std.mem.Allocator, config_path: ?[]const u8) !void {
    _ = startAsync(default_queue_capacity) catch |e| {
        // 起不了线程就退化成同步写：功能不变，只是调用线程会等 IO
        std.debug.print("[zzig.logger] [ERROR] 异步写线程创建失败（{s}），退回同步写入\n", .{@errorName(e)});
    };

    if (config_path) |p| {
        loadConfigFile(io, gpa, p) catch |e| {
            err("加载日志配置 {s} 失败（{s}），使用内置默认配置", .{ p, @errorName(e) });
            applyConfig(io, gpa, .{}) catch {};
        };
    } else {
        applyConfig(io, gpa, .{}) catch {};
    }
}

/// 把坏配置另存为 `<path>.bad.<时间戳>`（只备份一次），保留现场供排查。
fn backupBadConfig(io: std.Io, gpa: std.mem.Allocator, path: []const u8, text: []const u8, reason: []const u8) void {
    if (bad_config_backed) return;
    bad_config_backed = true;

    const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const dst = std.fmt.allocPrint(gpa, "{s}.bad.{d}", .{ path, ms }) catch return;
    defer gpa.free(dst);

    fsio.writeFileAtomic(io, gpa, dst, text) catch |e| {
        err("坏配置备份失败（{s} → {s}）：{s}", .{ path, dst, @errorName(e) });
        return;
    };
    err("日志配置损坏（{s}），已备份为 {s}；当前继续使用上一份生效配置", .{ reason, dst });
}
// ============ 时间偏移支持 ============

/// 服务器时间偏移量（毫秒）
/// server_time = local_time + time_offset_ms
var time_offset_ms: i64 = 0;

/// 设置时间偏移量（毫秒）
/// 用于与服务器时间同步
pub fn setTimeOffset(offset_ms: i64) void {
    time_offset_ms = offset_ms;
}

/// 获取时间偏移量
pub fn getTimeOffset() i64 {
    return time_offset_ms;
}

/// 全局日志级别（对齐 DH.NCore：默认 `Info`，只输出 `>=` 该级别的日志）
///
/// **原子存**：热加载线程会改写，而 `enabled()` 在所有业务线程上被高频调用。
var global_level_store = std.atomic.Value(u8).init(@backingInt(Level.info));

/// 线程安全互斥锁
var log_mutex: compat.Mutex = .{};

/// 线程安全开关（默认关闭以保持性能）
var thread_safe_enabled: bool = false;

/// 启用线程安全模式
///
/// 在多线程环境中调用此函数以确保日志输出不会交错。
/// 注意：启用后会有轻微性能开销。
///
/// 示例：
/// ```zig
/// Logger.enableThreadSafe();
/// ```
pub fn enableThreadSafe() void {
    thread_safe_enabled = true;
}

/// 禁用线程安全模式（默认状态）
///
/// 在单线程环境或对性能要求极高的场景可以禁用。
pub fn disableThreadSafe() void {
    thread_safe_enabled = false;
}

/// 检查是否启用了线程安全模式
pub fn isThreadSafe() bool {
    return thread_safe_enabled;
}

/// 设置全局日志级别
pub fn setLevel(level: Level) void {
    global_level_store.store(@backingInt(level), .release);
}

/// 取当前全局日志级别
pub fn getLevel() Level {
    return @fromBackingInt(@intCast(global_level_store.load(.acquire)));
}

/// 当前设置下该级别是否会真正输出。
pub fn enabled(level: Level) bool {
    return @backingInt(level) >= global_level_store.load(.acquire);
}

/// 读环境变量 `ZZIG_LOG` 并应用级别（对应 DH.NCore / DH.RustBase 的 `RUST_LOG` 习惯）。
///
/// 不存在或值非法时保持当前级别；返回最终生效的级别。
pub fn applyEnv(environ_map: *const std.process.Environ.Map) Level {
    const raw = environ_map.get("ZZIG_LOG") orelse return getLevel();
    if (Level.parse(raw)) |lv| setLevel(lv);
    return getLevel();
}

/// 按线程号取日志行颜色（对齐 DH.NCore `ConsoleLog`）：
/// 警告黄、错误/严重错误红，其余级别按线程号取自 10 色调色板，1 号线程灰白。
/// 将时间戳格式化为 `HH:MM:SS.mmm`（对齐 DH.NCore 行首 `Time` 列，不含日期：日期已在文件名里）。
///
/// buf 至少 16 字节；返回写入的切片。
fn formatClock(buf: *[16]u8) []u8 {
    const nanos: i128 = compat.nanoTimestamp();
    const offset_nanos: i128 = @as(i128, time_offset_ms) * std.time.ns_per_ms;
    const adjusted_nanos: i128 = nanos + offset_nanos;

    const timestamp: i64 = @intCast(@divFloor(adjusted_nanos, std.time.ns_per_s));
    const nano_part: u32 = @intCast(@mod(adjusted_nanos, std.time.ns_per_s));
    const millis: u32 = nano_part / std.time.ns_per_ms;

    const local_offset: i64 = getLocalTimezoneOffset();
    const seconds_since_epoch: i64 = timestamp + local_offset;
    const seconds_today = @mod(seconds_since_epoch, 86400);

    const hour: u32 = @intCast(@divFloor(seconds_today, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(seconds_today, 3600), 60));
    const second: u32 = @intCast(@mod(seconds_today, 60));

    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hour, minute, second, millis }) catch buf[0..12];
}

/// 将时间戳格式化到调用者提供的栈缓冲区（零堆分配）
/// buf 至少 32 字节；格式固定为 YYYY-MM-DD HH:MM:SS.nnnnnnnnn（29 字节）
fn formatTimestamp(buf: *[32]u8) []u8 {
    // 获取纳秒级时间戳
    const nanos: i128 = compat.nanoTimestamp();

    // 应用时间偏移量（毫秒转纳秒）
    // server_time = local_time + time_offset_ms
    const offset_nanos: i128 = @as(i128, time_offset_ms) * std.time.ns_per_ms;
    const adjusted_nanos: i128 = nanos + offset_nanos;

    // 转换为秒和纳秒部分
    const timestamp: i64 = @intCast(@divFloor(adjusted_nanos, std.time.ns_per_s));
    const nano_part: u32 = @intCast(@mod(adjusted_nanos, std.time.ns_per_s));

    // 获取本地时区偏移（秒）
    const local_offset: i64 = getLocalTimezoneOffset();
    const seconds_since_epoch: i64 = timestamp + local_offset;

    // 转换为本地时间
    const days_since_epoch = @divFloor(seconds_since_epoch, 86400);
    const seconds_today = @mod(seconds_since_epoch, 86400);

    const hour: u32 = @intCast(@divFloor(seconds_today, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(seconds_today, 3600), 60));
    const second: u32 = @intCast(@mod(seconds_today, 60));

    // 准确的日期计算（考虑闰年）
    const date = epochDaysToDate(days_since_epoch);

    // 直接写入栈缓冲区，无堆分配
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{
        date.year, date.month, date.day, hour, minute, second, nano_part,
    }) catch buf[0..29]; // bufPrint 不会失败（buf 足够大），catch 仅供编译器满足
}

/// 日期结构
const Date = struct {
    year: u32,
    month: u32,
    day: u32,
};

/// 将 epoch 天数转换为日期（Howard Hinnant proleptic Gregorian 算法，O(1)）
/// 替代原来从 1970 年逐年迭代的 O(N) 实现
fn epochDaysToDate(days: i64) Date {
    // 将历元平移到公历 0000-03-01，使闰年处理更简洁
    const z: i64 = days + 719468;
    // 400 年周期（每周期 146097 天）
    const era: i64 = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097); // 周期内天数 [0, 146096]
    // 周期内年份（Hinnant 公式）
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // 年内天数 [0, 365]
    // 月份（以 3 月为第 0 月）
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1; // 日 [1, 31]
    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // 月 [1, 12]
    const yr: u32 = @intCast(y + @as(i64, if (m <= 2) 1 else 0));
    return Date{ .year = yr, .month = m, .day = d };
}

/// 获取本地时区偏移量（秒）
fn getLocalTimezoneOffset() i64 {
    if (builtin.os.tag == .windows) {
        // Windows: 直接调用 _get_timezone 或使用简化的 API
        // 使用 extern 声明 Windows API
        const LONG = i32;
        const WCHAR = u16;

        const SYSTEMTIME = extern struct {
            wYear: u16,
            wMonth: u16,
            wDayOfWeek: u16,
            wDay: u16,
            wHour: u16,
            wMinute: u16,
            wSecond: u16,
            wMilliseconds: u16,
        };

        const TIME_ZONE_INFORMATION = extern struct {
            Bias: LONG,
            StandardName: [32]WCHAR,
            StandardDate: SYSTEMTIME,
            StandardBias: LONG,
            DaylightName: [32]WCHAR,
            DaylightDate: SYSTEMTIME,
            DaylightBias: LONG,
        };

        const GetTimeZoneInformation = struct {
            extern "kernel32" fn GetTimeZoneInformation(lpTimeZoneInformation: *TIME_ZONE_INFORMATION) u32;
        }.GetTimeZoneInformation;

        var tzi: TIME_ZONE_INFORMATION = undefined;
        _ = GetTimeZoneInformation(&tzi);

        // Bias 是以分钟为单位的偏移，且是负值（例如 UTC+8 返回 -480）
        // 需要转换为秒并反转符号
        return -tzi.Bias * 60;
    } else {
        // Unix/Linux: 尝试读取 /etc/timezone 或使用环境变量
        // 简化处理：假设 UTC+8（中国标准时间）
        return 8 * 3600;
    }
}

/// 跨平台打印函数：Windows 使用 WriteConsoleW 确保中文正确显示
/// alloc 由调用方传入（复用外层 arena），避免 Windows 路径下的二次 arena 创建
fn printUtf8(alloc: std.mem.Allocator, text: []const u8) void {
    if (builtin.os.tag != .windows) {
        std.debug.print("{s}", .{text});
        return;
    }

    // Windows 平台：使用 WriteConsoleW 保证中文显示
    const w = std.os.windows;
    const h = compat.windows.getStdHandle(compat.windows.STD_OUTPUT_HANDLE);
    if (h == null or h == w.INVALID_HANDLE_VALUE) {
        // 降级到普通打印
        std.debug.print("{s}", .{text});
        return;
    }

    // 转换为 UTF-16LE，复用调用方的 arena，无额外年算层开销
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch {
        std.debug.print("{s}", .{text});
        return;
    };

    var written: w.DWORD = 0;
    _ = compat.windows.writeConsoleW(h.?, utf16, &written);
}

/// 生成日志行前缀（不含消息）。
///
/// `ncore` / `ncore_level` 走 DH.NCore 的 `Time ThreadId Kind Name [Level]` 形状；
/// `legacy` 保留 zzig 早期的 `[完整时间戳] [LEVEL] ` 形状。
fn buildPrefix(buf: *[96]u8, level: Level, thread_id: u64) []const u8 {
    switch (getLineFormat()) {
        .ncore => {
            var clock_buf: [16]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s} {d:0>2} {s} {s} ", .{
                formatClock(&clock_buf), thread_id, currentKind(), currentThreadName(),
            }) catch buf[0..0];
        },
        .ncore_level => {
            var clock_buf: [16]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s} {d:0>2} {s} {s} [{s}] ", .{
                formatClock(&clock_buf), thread_id, currentKind(), currentThreadName(), level.pascalName(),
            }) catch buf[0..0];
        },
        .ncore_datetime => {
            var dt_buf: [32]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s} {d:0>2} {s} {s} ", .{
                formatDateTimeMs(&dt_buf), thread_id, currentKind(), currentThreadName(),
            }) catch buf[0..0];
        },
        .ncore_datetime_level => {
            var dt_buf: [32]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s} {d:0>2} {s} {s} [{s}] ", .{
                formatDateTimeMs(&dt_buf), thread_id, currentKind(), currentThreadName(), level.pascalName(),
            }) catch buf[0..0];
        },
        .legacy => {
            var ts_buf: [32]u8 = undefined;
            return std.fmt.bufPrint(buf, "[{s}] [{s}] ", .{
                formatTimestamp(&ts_buf), level.asStr(),
            }) catch buf[0..0];
        },
    }
}

/// `yyyy-MM-dd HH:mm:ss.mmm`（23 字符）。
///
/// 用于 `LogLineFormat` 含 `DateTime` 的场景：C# 默认只有时间（日期看文件名），
/// 但多天日志合并分析、或日志转发到集中收集时，必须带上日期才能定位。
fn formatDateTimeMs(buf: *[32]u8) []const u8 {
    const nanos: i128 = compat.nanoTimestamp();
    const offset_nanos: i128 = @as(i128, time_offset_ms) * std.time.ns_per_ms;
    const adjusted: i128 = nanos + offset_nanos;

    const timestamp: i64 = @intCast(@divFloor(adjusted, std.time.ns_per_s));
    const nano_part: u32 = @intCast(@mod(adjusted, std.time.ns_per_s));
    const millis: u32 = nano_part / std.time.ns_per_ms;

    const local_offset: i64 = getLocalTimezoneOffset();
    const epoch_secs: i64 = timestamp + local_offset;
    const days = @divFloor(epoch_secs, 86400);
    const secs_today = @mod(epoch_secs, 86400);

    const hour: u32 = @intCast(@divFloor(secs_today, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(secs_today, 3600), 60));
    const second: u32 = @intCast(@mod(secs_today, 60));
    const date = epochDaysToDate(days);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        date.year, date.month, date.day, hour, minute, second, millis,
    }) catch buf[0..19];
}

/// 编译期能力开关。
///
/// **嵌入式 / 裸机**场景下这些能力可能根本不存在（无堆、无线程、无文件系统），
/// 所以同步路径做成**纯栈缓冲 + 零堆分配 + 不开线程**：不调 `init()`/`startAsync()`
/// 就自动是这套模式，开箱即可用于受限环境。
pub const build_options = struct {
    /// 单行最大字节数。同步模式用这么大一块栈缓冲，超长部分截断（宁可截断也不能分配）。
    pub const max_line_bytes: usize = 1024;
    /// 异步写入是否可用（单线程目标默认关闭：没有线程就不能起写线程）
    pub const async_available: bool = !@import("builtin").single_threaded;
};

/// 通用日志打印函数
/// Windows 控制台输出（**栈缓冲版**，零堆分配；超长自动截断）。
///
/// 与 `printUtf8` 的区别：不向调用方要 allocator。同步日志路径必须能在
/// 无堆环境（嵌入式 / 分配失败）下工作，所以统一走这里。
fn printUtf8Stack(text: []const u8) void {
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

    // UTF-16 每码元最多 3 字节 UTF-8 → 2 倍长度足够；再加终止余量
    var buf: [build_options.max_line_bytes * 2 + 64]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch {
        std.debug.print("{s}", .{text});
        return;
    };

    var written: w.DWORD = 0;
    _ = compat.windows.writeConsoleW(h.?, buf[0..n], &written);
}

/// 输出一行**已格式化**的日志（同步路径，worker 与「未启用异步」时共用）。
///
/// 约定：`text` 不含换行；控制台加颜色，**文件不加颜色**（否则日志文件里全是转义字符）。
fn emitText(level: Level, thread_id: u64, text: []const u8) void {
    // 文件：按天滚动 + 大小拆分 + 备份清理都交给 TextFileLog
    // 必须持锁：热加载可能正在换 sink / 关文件
    file_mutex.lock();
    if (file_sink) |*sink| sink.writeRawLine(level, text);
    file_mutex.unlock();

    if (!consoleEnabledRaw()) return;
    const code = colorCode(level, thread_id);

    if (builtin.os.tag != .windows) {
        std.debug.print("\x1b[{s}m{s}\n\x1b[0m", .{ code, text });
        return;
    }

    // Windows：整行一次 UTF-16 转换再 WriteConsoleW，避免逐段转换产生交错。
    // 用定长栈缓冲（不开 arena）：日志路径不该在堆上分配。
    var buf: [build_options.max_line_bytes + 32]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    fw.print("\x1b[{s}m", .{code}) catch {};
    fw.writeAll(text) catch {};
    fw.writeAll("\n\x1b[0m") catch {};
    printUtf8Stack(fw.buffered());
}

fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    // 级别过滤（对齐 DH.NCore：只输出 >= 配置级别）
    if (!enabled(level)) {
        return;
    }

    const thread_id = currentThreadId();
    var prefix_buf: [96]u8 = undefined;
    const prefix = buildPrefix(&prefix_buf, level, thread_id);

    // ---------- 异步路径：业务线程只做格式化 + 入队，绝不做 IO ----------
    if (pending) |q| {
        // 先格式化到**栈缓冲**，最后只做一次精确大小的 dupe 入队。
        // 不用 `Writer.Allocating`：那样每条日志至少 2 次堆分配（增长 + toOwnedSlice），
        // 实测 5 万条会慢到 9.7us/条，是生产端瓶颈。
        var tmp: [build_options.max_line_bytes]u8 = undefined;
        var w: std.Io.Writer = .fixed(&tmp);
        w.writeAll(prefix) catch return;
        w.print(fmt, args) catch {}; // 超长截断，不分配

        const owned = queue_alloc.dupe(u8, w.buffered()) catch return;
        if (!q.tryPush(.{ .level = level, .thread_id = thread_id, .text = owned })) {
            // 队列满（对端磁盘慢/控制台卡）：丢弃**新**日志而不是阻塞业务线程，
            // 也不让内存无界增长（对齐 DH.NCore `MAX_QUEUE` 的行为）。
            queue_alloc.free(owned);
            _ = dropped.fetchAdd(1, .monotonic);
        }
        return;
    }

    // ---------- 同步路径（默认；嵌入式直接用这条）：定长栈缓冲，零堆分配 ----------
    if (thread_safe_enabled) {
        log_mutex.lock();
        defer log_mutex.unlock();
    }
    var line_buf: [build_options.max_line_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    w.writeAll(prefix) catch {};
    // 超长时 writeAll/print 返回 NoSpaceLeft —— 保留已写入部分（截断而不是分配）
    w.print(fmt, args) catch {};
    emitText(level, thread_id, w.buffered());
}

/// 调试级别日志
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

/// 信息级别日志
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

/// 警告级别日志
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

/// 错误级别日志
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

/// 严重错误级别日志（对齐 DH.NCore `Fatal`：进程级不可恢复错误）
pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    log(.fatal, fmt, args);
}

/// 强制输出日志（忽略全局日志级别,用于启动信息等关键日志）
pub fn always(comptime fmt: []const u8, args: anytype) void {
    // 线程安全保护
    if (thread_safe_enabled) {
        log_mutex.lock();
        defer log_mutex.unlock();
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 固定按 info 级别出前缀与配色（`always` 的语义是「不受级别过滤」）
    const thread_id = currentThreadId();
    var prefix_buf: [96]u8 = undefined;
    const prefix = buildPrefix(&prefix_buf, .info, thread_id);
    const color_code = colorCode(.info, thread_id);

    var buffer: std.ArrayList(u8) = .empty;
    var writer_allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    const writer = &writer_allocating.writer;

    writer.print("\x1b[{s}m", .{color_code}) catch return;
    writer.writeAll(prefix) catch return;
    writer.print(fmt, args) catch return;
    writer.writeAll("\n\x1b[0m") catch return;

    buffer = writer_allocating.toArrayList();
    printUtf8(allocator, buffer.items);
}

/// 不带时间戳和级别的简单打印（用于替换原有的简单打印场景）
pub fn print(comptime fmt: []const u8, args: anytype) void {
    // 线程安全保护
    if (thread_safe_enabled) {
        log_mutex.lock();
        defer log_mutex.unlock();
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    printUtf8(allocator, message);
}

// ============ 对齐 DH.NCore 的规则测试 ============

const testing = std.testing;

test "logger：默认级别为 info（对齐 DH.NCore 默认 LogLevel=Info）" {
    const saved = getLevel();
    defer setLevel(saved);
    setLevel(.info);
    try testing.expect(enabled(.info));
    try testing.expect(enabled(.warn));
    try testing.expect(enabled(.err));
    try testing.expect(enabled(.fatal));
    try testing.expect(!enabled(.debug)); // 明细默认看不到
    try testing.expect(!enabled(.all));
}

test "logger：7 级对齐 All/Debug/Info/Warn/Error/Fatal/Off 且门槛为 >=" {
    // 枚举顺序必须与 DH.NCore 一致（all < debug < info < warn < error < fatal < off）
    try testing.expect(@backingInt(Level.all) < @backingInt(Level.debug));
    try testing.expect(@backingInt(Level.debug) < @backingInt(Level.info));
    try testing.expect(@backingInt(Level.info) < @backingInt(Level.warn));
    try testing.expect(@backingInt(Level.warn) < @backingInt(Level.err));
    try testing.expect(@backingInt(Level.err) < @backingInt(Level.fatal));
    try testing.expect(@backingInt(Level.fatal) < @backingInt(Level.off));

    const saved = getLevel();
    defer setLevel(saved);

    setLevel(.all);
    try testing.expect(enabled(.debug));
    setLevel(.off);
    try testing.expect(!enabled(.fatal)); // off 关掉一切
}

test "logger：asStr 与 parse 对齐 C# LogLevel（含大小写与别名）" {
    try testing.expectEqualStrings("INFO", Level.info.asStr());
    try testing.expectEqualStrings("ERROR", Level.err.asStr());
    try testing.expectEqualStrings("FATAL", Level.fatal.asStr());
    try testing.expectEqualStrings("OFF", Level.off.asStr());

    try testing.expectEqual(Level.debug, Level.parse("DEBUG").?);
    try testing.expectEqual(Level.debug, Level.parse(" trace ").?);
    try testing.expectEqual(Level.warn, Level.parse("Warning").?);
    try testing.expectEqual(Level.err, Level.parse("error").?);
    try testing.expectEqual(Level.fatal, Level.parse("FATAL").?);
    try testing.expectEqual(Level.off, Level.parse("none").?);
    try testing.expectEqual(@as(?Level, null), Level.parse("乱写"));
}

test "logger：行格式默认为 NCore，可切换" {
    const saved = getLineFormat();
    defer setLineFormat(saved);
    try testing.expectEqual(LineFormat.ncore, getLineFormat());
    setLineFormat(.legacy);
    try testing.expectEqual(LineFormat.legacy, getLineFormat());
}

test "logger：applyEnv 读 ZZIG_LOG（不存在保持、非法保持）" {
    const saved = getLevel();
    defer setLevel(saved);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    setLevel(.info);
    try testing.expectEqual(Level.info, applyEnv(&env));

    try env.put("ZZIG_LOG", " warn ");
    try testing.expectEqual(Level.warn, applyEnv(&env));

    try env.put("ZZIG_LOG", "乱写");
    try testing.expectEqual(Level.warn, applyEnv(&env));
}

test "logger：clock 前缀形状为 HH:MM:SS.mmm" {
    var buf: [16]u8 = undefined;
    const s = formatClock(&buf);
    try testing.expectEqual(@as(usize, 12), s.len);
    try testing.expectEqual(@as(u8, ':'), s[2]);
    try testing.expectEqual(@as(u8, ':'), s[5]);
    try testing.expectEqual(@as(u8, '.'), s[8]);
}

test "logger：默认模板带注释，且与 Config 默认值逐项一致（防漂移）" {
    // 模板由 config_template_layout + Config 默认值编译期渲染，这里再解析回来比对
    try testing.expect(std.mem.indexOf(u8, default_config_template, "# zzig 日志配置") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const table = try toml_config.parse(aa, default_config_template);
    const cfg = try toml_config.decode(Config, aa, table);
    const def: Config = .{};

    try testing.expectEqualStrings(def.LogLevel, cfg.LogLevel);
    try testing.expectEqualStrings(def.LogPath, cfg.LogPath);
    try testing.expectEqual(def.LogFileMaxBytes, cfg.LogFileMaxBytes);
    try testing.expectEqual(def.LogFileBackups, cfg.LogFileBackups);
    try testing.expectEqualStrings(def.LogLineFormat, cfg.LogLineFormat);
    try testing.expectEqual(def.LogConsole, cfg.LogConsole);
    try testing.expectEqual(def.LogAsyncQueue, cfg.LogAsyncQueue);

    // 模板必须覆盖全部配置项，且每一项都不缺（audit 应报 0 缺键、有注释）
    const audit = auditConfigText(aa, default_config_template, table);
    try testing.expectEqual(@as(usize, 0), audit.missing);
    try testing.expectEqual(@as(usize, 0), audit.unknown.items.len);
    try testing.expect(audit.has_comment);
}

test "logger：配置自愈 —— 缺键补全、补注释、多余键清理、实际值保留" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const base = try dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "logger.toml" });
    defer testing.allocator.free(path);

    // 手写裸配置：只有一项、没有注释、还带一个拼错的键
    try fsio.writeFile(io, path, "LogLevel = \"Debug\"\nBogusKey = 1\n");

    var file = try config_file.FileText.open(io, testing.allocator, path, default_config_template, .{});
    defer file.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const table = try toml_config.parse(aa, file.current());

    const audit = auditConfigText(aa, file.current(), table);
    try testing.expect(audit.missing > 0); // 缺其它 6 项
    try testing.expect(!audit.has_comment); // 没有注释
    try testing.expectEqual(@as(usize, 1), audit.unknown.items.len); // BogusKey
    try testing.expectEqualStrings("BogusKey", audit.unknown.items[0]);

    const cfg = try toml_config.decode(Config, aa, table);
    try testing.expectEqualStrings("Debug", cfg.LogLevel); // 用户实际值

    try repairConfigFile(io, testing.allocator, &file, cfg, audit);

    const after = try fsio.readFileAlloc(io, testing.allocator, path, 1 << 20);
    defer testing.allocator.free(after);

    // 1) 补了注释
    try testing.expect(std.mem.indexOf(u8, after, "# zzig 日志配置") != null);
    // 2) 保留了用户实际值
    try testing.expect(std.mem.indexOf(u8, after, "LogLevel = \"Debug\"") != null);
    // 3) 缺的键都补齐了
    const after_table = try toml_config.parse(aa, after);
    const after_cfg = try toml_config.decode(Config, aa, after_table);
    try testing.expectEqualStrings("Debug", after_cfg.LogLevel);
    try testing.expectEqual((Config{}).LogAsyncQueue, after_cfg.LogAsyncQueue);
    // 4) 多余键被清理
    try testing.expect(std.mem.indexOf(u8, after, "BogusKey") == null);
    // 5) 自愈前留了现场
    const backup = try std.fmt.allocPrint(testing.allocator, "{s}.old", .{path});
    defer testing.allocator.free(backup);
    try testing.expect(config_file.getStamp(io, backup) != null);
}
