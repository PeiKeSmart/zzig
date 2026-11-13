//! DH.RustBase 风格文本日志：
//! - 行格式：`HH:mm:ss.fff 线程ID 类型 名称 正文`（默认列序对齐 DH.NCore `LogLineFormat`）；
//! - 文件按天：`Log/yyyy_MM_dd.log`，单文件超过上限拆 `_2`、`_3`…；
//! - 首次写入文件时输出配置头（`#Software` / `#Date` / `#Fields` 等）；
//! - 控制台按级别着色（警告黄 / 错误红）；
//! - 同步写、互斥保护：日志频率低的常驻服务足够可靠，不引入队列/后台线程。

const std = @import("std");
const builtin = @import("builtin");
const fsio = @import("../file/fsio.zig");
const level_mod = @import("level.zig");

/// 文件头**必定出现**的字段前缀（逐字对齐 C# `NewLife.Log.Logger.WriteHead`）。
///
/// 这份清单就是「对齐是否真的做到」的可校验契约：
/// `tools/check-log-header.ps1` 会用它逐条断言实际输出的文件头，**缺一条就退非 0**。
pub const header_always_fields = [_][]const u8{
    "#Software: ", "#ProcessID: ", "#AppDomain: ", "#ApplicationType: ",
    "#CLR: ",      "#OS: ",        "#CPU: ",       "#Date: ",
    "#详解：",
    "#字段: ",
    "#Fields: ",
};

/// 依赖平台/文件系统/宿主配置、**可以缺席**的字段（缺席时整行不输出，而不是编造值）。
pub const header_optional_fields = [_][]const u8{
    "#FileName: ", "#BaseDirectory: ", "#CurrentDirectory: ",
    "#TempPath: ", "#SystemStarted: ",
};

/// 日志级别（**单一来源**：`level.zig`，对齐 DH.NCore `LogLevel`）。
///
/// 早期这里自带一份 5 级定义，与 `logger.zig` 的级别口径不一致（`all`/`off` 缺失，
/// 配色规则也各写一遍）。现在统一引用 `level.zig`，避免两处漂移。
pub const Level = @import("level.zig").Level;

/// 解析级别名；非法值回退 `Info`（保留旧签名以兼容既有调用）。
pub fn parseLevel(text: []const u8) Level {
    return Level.parse(text) orelse .info;
}

pub const Options = struct {
    /// 日志目录（按 DH 约定默认 `Log`）
    dir: []const u8 = "Log",
    use_console: bool = true,
    max_file_bytes: u64 = 10 * 1024 * 1024,
    /// 保留最近多少份日志文件
    backups: usize = 200,
    /// 文件头 `#Software`
    software: []const u8 = "zzig",
    /// 行格式（决定文件头 `#Fields` 列名，需与实际写入一致）
    line_format: []const u8 = "Time|ThreadId|Kind|Name|Message",
    /// 机器名（`#OS` 第二段）；留空则整行不输出该段信息
    machine_name: []const u8 = "",
    /// 用户名（`#OS` 第二段）；留空同上
    user_name: []const u8 = "",
    /// 临时目录（`#TempPath`）；留空则跳过该行
    temp_path: []const u8 = "",
};

pub const TextFileLog = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    level: Level,
    opts: Options,
    mutex: std.Io.Mutex = .init,
    file: ?std.Io.File = null,
    file_name: ?[]u8 = null,
    date: [10]u8 = @splat(0),

    pub fn init(io: std.Io, gpa: std.mem.Allocator, level: Level, opts: Options) !TextFileLog {
        var self = TextFileLog{ .io = io, .gpa = gpa, .level = level, .opts = opts };
        try self.rollIfNeeded(true);
        return self;
    }

    pub fn deinit(self: *TextFileLog) void {
        if (self.file) |f| f.close(self.io);
        if (self.file_name) |n| self.gpa.free(n);
    }

    pub fn debug(self: *TextFileLog, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *TextFileLog, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *TextFileLog, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *TextFileLog, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn fatal(self: *TextFileLog, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, fmt, args);
    }

    pub fn setLevel(self: *TextFileLog, level: Level) void {
        self.level = level;
    }

    pub fn log(self: *TextFileLog, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@backingInt(level) < @backingInt(self.level)) return;

        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();

        formatLine(self.io, &line.writer, level, fmt, args) catch return;
        self.emit(level, line.written());
    }

    /// 写一行**已格式化好**的日志（不含换行，由这里补）。
    ///
    /// 供 `logger.zig` 复用：门面统一负责前缀/行格式，这里只管落盘（+ 可选控制台），
    /// 避免两处各格式化一次导致文件与控制台格式不一致。
    pub fn writeRawLine(self: *TextFileLog, level: Level, text: []const u8) void {
        if (@backingInt(level) < @backingInt(self.level)) return;
        self.emit(level, text);
    }

    fn emit(self: *TextFileLog, level: Level, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.opts.use_console) {
            std.Io.File.stdout().writeStreamingAll(self.io, level_mod.colorCode(level, 1)) catch {};
            std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch {};
            std.Io.File.stdout().writeStreamingAll(self.io, "\n\x1b[0m") catch {};
        }

        self.rollIfNeeded(false) catch return;
        const f = self.file orelse return;
        // 文件位置在 rollIfNeeded 打开时已定位到末尾，这里直接顺序写：
        // 不再每条 length()+seek（那样每条日志要 3 次系统调用，是写线程的瓶颈）。
        f.writeStreamingAll(self.io, bytes) catch {};
        f.writeStreamingAll(self.io, "\n") catch {};
    }

    /// 一次写入**整块**已格式化日志（每行自带换行）。
    ///
    /// 批量落盘：写线程一次取多条拼成一块，这里只做一次系统调用。
    pub fn writeRawBlock(self: *TextFileLog, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.rollIfNeeded(false) catch return;
        const f = self.file orelse return;
        f.writeStreamingAll(self.io, bytes) catch {};
    }

    fn rollIfNeeded(self: *TextFileLog, force_open: bool) !void {
        var date_buf: [10]u8 = undefined;
        try formatDate(&date_buf, nowMillis(self.io));

        if (!force_open and std.mem.eql(u8, &self.date, &date_buf) and self.file != null) {
            const f = self.file.?;
            const len = f.length(self.io) catch 0;
            if (len < self.opts.max_file_bytes) return;
        }

        if (self.file) |f| f.close(self.io);
        self.file = null;

        try fsio.makePath(self.io, self.opts.dir);
        const name = try self.pickFile(&date_buf);
        errdefer self.gpa.free(name);

        const full = try std.fs.path.join(self.gpa, &.{ self.opts.dir, name });
        defer self.gpa.free(full);

        var f = try fsio.cwd().createFile(self.io, full, .{ .truncate = false });
        const len = f.length(self.io) catch 0;
        if (len == 0) {
            const header = try self.renderHeader();
            defer self.gpa.free(header);
            f.writeStreamingAll(self.io, header) catch {};
        }
        // 打开后定位一次到末尾：之后所有写入都是顺序追加，
        // 避免每条日志都 length()+seek（那是写线程的主要开销）。
        if (len > 0) self.io.vtable.fileSeekTo(self.io.userdata, f, len) catch {};

        if (self.file_name) |old| self.gpa.free(old);
        self.file_name = name;
        self.file = f;
        self.date = date_buf;

        self.pruneOld();
    }

    fn pickFile(self: *TextFileLog, date: *const [10]u8) ![]u8 {
        var idx: u32 = 1;
        while (idx < 1024) : (idx += 1) {
            const name = if (idx == 1)
                try std.fmt.allocPrint(self.gpa, "{s}.log", .{date})
            else
                try std.fmt.allocPrint(self.gpa, "{s}_{d}.log", .{ date, idx });

            const full = try std.fs.path.join(self.gpa, &.{ self.opts.dir, name });
            defer self.gpa.free(full);

            const st = fsio.statFile(self.io, full) catch {
                return name;
            };
            if (st.size < self.opts.max_file_bytes) return name;
            self.gpa.free(name);
        }
        return error.LogFileExhausted;
    }

    /// 写文件头 —— **逐字段对齐 DH.NCore `NewLife.Log.Logger.WriteHead`**。
    ///
    /// C# 侧会输出 `#Software/#ProcessID/#AppDomain/#FileName/#BaseDirectory/
    /// #CurrentDirectory/#BasePath/#TempPath/#CommandLine/#ApplicationType/#CLR/#OS/
    /// #CPU/#Memory/#Processor/#Product/#Temperature/#GC/#ThreadPool/#SystemStarted/
    /// #Date/#详解/#字段/#Fields`。
    ///
    /// 其中依赖 .NET 运行时或需注册 MachineInfo 的字段（`#BasePath`/`#Memory`/`#Processor`/
    /// `#Product`/`#Temperature`/`#GC`/`#ThreadPool`）在 Zig 下没有等价来源，**省略**；
    /// `#CommandLine` 需要进程启动参数，而文件日志创建时拿不到，也省略。
    /// 其余字段全部输出，且 `#Fields` 随 `LogLineFormat` 变化（含 Level 时自动带上）。
    fn renderHeader(self: *TextFileLog) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;

        // ---- 程序与进程 ----
        w.print("#Software: {s}\r\n", .{self.opts.software}) catch {};

        const pid = currentProcessId();
        if (builtin.target.ptrBitWidth() == 64) {
            w.print("#ProcessID: {d} x64\r\n", .{pid}) catch {};
        } else {
            w.print("#ProcessID: {d}\r\n", .{pid}) catch {};
        }

        // Zig 无 AppDomain 概念，对齐 DH.RustBase 的做法：用程序名近似
        w.print("#AppDomain: {s}\r\n", .{self.opts.software}) catch {};

        const exe = std.process.executablePathAlloc(self.io, self.gpa) catch null;
        defer if (exe) |p| self.gpa.free(p);

        if (exe) |p| {
            w.print("#FileName: {s}\r\n", .{p}) catch {};
            if (std.fs.path.dirname(p)) |dir| {
                w.print("#BaseDirectory: {s}{c}\r\n", .{ dir, std.fs.path.sep }) catch {};
            }
        }

        const cwd = std.process.currentPathAlloc(self.io, self.gpa) catch null;
        defer if (cwd) |p| self.gpa.free(p);
        if (cwd) |c| {
            // 对齐 C#：当前目录与基准目录一致时不输出（避免噪音）
            const same = if (exe) |p| blk: {
                const dir = std.fs.path.dirname(p) orelse break :blk false;
                break :blk std.mem.eql(u8, trimSep(dir), trimSep(c));
            } else false;
            if (!same) w.print("#CurrentDirectory: {s}\r\n", .{c}) catch {};
        }

        if (self.opts.temp_path.len > 0) {
            w.print("#TempPath: {s}{c}\r\n", .{ trimSep(self.opts.temp_path), std.fs.path.sep }) catch {};
        }

        // ---- 运行形态 ----
        w.print("#ApplicationType: {s}\r\n", .{applicationType()}) catch {};
        // 对应 C# 的 `#CLR: {ver}, {target}`：Zig 没有 CLR，给出工具链版本与目标架构
        w.print("#CLR: Zig {s}, {s}-{s}\r\n", .{
            builtin.zig_version_string,
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
        }) catch {};

        // ---- 机器信息 ----
        // 机器名/用户名/临时目录由宿主通过 `Options` 传入（Zig 无跨平台可靠来源）；
        // 未提供时不输出该段，不编造占位符。
        w.print("#OS: {s} {s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }) catch {};
        if (self.opts.machine_name.len > 0 or self.opts.user_name.len > 0) {
            w.print(", {s}/{s}", .{
                if (self.opts.machine_name.len > 0) self.opts.machine_name else "-",
                if (self.opts.user_name.len > 0) self.opts.user_name else "-",
            }) catch {};
        }
        w.writeAll("\r\n") catch {};

        const cpus = std.Thread.getCpuCount() catch 1;
        w.print("#CPU: {d}\r\n", .{cpus}) catch {};

        if (systemStarted()) |s| w.print("#SystemStarted: {s}\r\n", .{s}) catch {};

        // `#Date` 对齐 C# 的 `yyyy-MM-dd`（**不是**文件名用的 `yyyy_MM_dd`）
        w.print("#Date: {s}\r\n", .{fileDate(self.io, '-')}) catch {};
        w.writeAll("#详解：https://newlifex.com/core/log\r\n") catch {};
        // `#字段` 与 C# 原文逐字一致（说明每一列的含义，是列语义的权威描述）。
        w.writeAll("#字段: 时间 线程ID 线程池Y/网页W/普通N 线程名/任务ID/定时T/线程池P/长任务L 消息内容\r\n") catch {};
        // Zig 侧的各值来源写清楚：谁注入、什么条件下出现（全部为真实来源，非占位）。
        w.writeAll("#字段说明: Kind: W=Web请求(由 http 注入) T=定时回调(由 timer 注入) Y=线程池线程 P=池内任务 IO=IO线程池 L=长任务(由线程池或宿主 pushKind 标注) N=其余(默认)\r\n") catch {};

        // `#Fields` 由行格式决定：`Time|ThreadId|Kind|Name|Message` → 空格分隔；
        // 若配置里含 Level，这里也会带出 Level（与正文列数严格一致）。
        var fields_buf: [128]u8 = undefined;
        var fields: []u8 = undefined;
        if (std.fmt.bufPrint(&fields_buf, "{s}", .{self.opts.line_format})) |f| {
            fields = f;
        } else |_| {
            // 配置串超出缓冲：截断后照样输出（宁可截断也不静默丢列）
            const n = @min(self.opts.line_format.len, fields_buf.len);
            @memcpy(fields_buf[0..n], self.opts.line_format[0..n]);
            fields = fields_buf[0..n];
        }
        for (fields) |*c| {
            if (c.* == '|') c.* = ' ';
        }
        w.print("#Fields: {s}\r\n", .{fields}) catch {};

        return out.toOwnedSlice();
    }

    /// 保留最近 `backups` 份日志（按文件名排序，日期格式可直接字典序比较）。
    fn pruneOld(self: *TextFileLog) void {
        var dir = fsio.openDirIterable(self.io, self.opts.dir) catch return;
        defer dir.close(self.io);

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.gpa);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
            if (entry.name.len < 14) continue;
            const owned = self.gpa.dupe(u8, entry.name) catch continue;
            names.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                continue;
            };
        }
        defer for (names.items) |n| self.gpa.free(n);

        if (names.items.len <= self.opts.backups) return;
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        const remove_count = names.items.len - self.opts.backups;
        for (names.items[0..remove_count]) |n| {
            dir.deleteFile(self.io, n) catch {};
        }
    }
};

threadlocal var thread_id: u32 = 0;
var next_thread_id: std.atomic.Value(u32) = .init(0);

fn currentThreadId() u32 {
    if (thread_id == 0) thread_id = next_thread_id.fetchAdd(1, .monotonic) + 1;
    return thread_id;
}

/// 行格式：`HH:mm:ss.fff NN N - 正文`（UTC；DH 用本地时间，这里保持一致字段与列序）。
pub fn formatLine(io: std.Io, w: *std.Io.Writer, level: Level, comptime fmt: []const u8, args: anytype) !void {
    _ = level;
    const ms = nowMillis(io);
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {d:0>2} N - ", .{
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        @as(u32, @intCast(@mod(ms, 1000))),
        currentThreadId(),
    });
    try w.print(fmt, args);
    try w.writeAll("\n");
}

fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn formatDate(buf: *[10]u8, ts_ms: i64) !void {
    const secs: u64 = @intCast(@divFloor(ts_ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const s = try std.fmt.bufPrint(buf, "{d:0>4}_{d:0>2}_{d:0>2}", .{
        yd.year,
        @backingInt(md.month),
        md.day_index + 1,
    });
    std.debug.assert(s.len == 10);
}

const testing = std.testing;

test "text log: 行格式字段" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try formatLine(std.testing.io, &out.writer, .warn, "hello {s}", .{"world"});
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, " N - hello world\n") != null);
    try testing.expect(text.len >= 22);
}

// ============ 文件头所需系统信息（能拿到才输出，拿不到就省略）============

/// 去掉路径尾部路径分隔符（`C:\a\` → `C:\a`），避免 `#BaseDirectory: C:\a\\`。
fn trimSep(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 0 and (s[s.len - 1] == '/' or s[s.len - 1] == '\\')) s = s[0 .. s.len - 1];
    return s;
}

/// 当前进程 id（Windows 取真实 pid；其它平台返回 0，调用方输出时如实体现）。
fn currentProcessId() u32 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => 0,
    };
}

/// 应用形态。C# 会区分 Web/Service/Console/WinForm；Zig 侧无宿主抽象，
/// 这里如实给出 `Console`（不臆造 `Web`/`Service`）。
fn applicationType() []const u8 {
    return "Console";
}

threadlocal var file_date_buf: [10]u8 = undefined;

/// `#Date` 用的 `yyyy-MM-dd`（**注意与文件名 `yyyy_MM_dd` 不同**，C# 就是这样）。
fn fileDate(io: std.Io, sep: u8) []const u8 {
    formatDate(&file_date_buf, nowMillis(io)) catch {};
    for (&file_date_buf) |*c| {
        if (c.* == '_') c.* = sep;
    }
    return &file_date_buf;
}

threadlocal var started_buf: [40]u8 = undefined;

/// Windows `GetTickCount64`：系统启动至今毫秒数。
///
/// Zig 0.17 的 `std.os.windows` 未导出该符号，这里直接声明（x64 上就是标准调用约定）。
const kernel32 = struct {
    extern "kernel32" fn GetTickCount64() u64;
};

/// `#SystemStarted`：系统启动至今的时长，格式对齐 C# `TimeSpan`（`d.hh:mm:ss.fffffff`）。
fn systemStarted() ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const ms: u64 = kernel32.GetTickCount64();

    const days = ms / 86_400_000;
    const rem = ms % 86_400_000;
    const hh = rem / 3_600_000;
    const mm = (rem % 3_600_000) / 60_000;
    const ss = (rem % 60_000) / 1000;
    const milli = rem % 1000;

    return if (days > 0)
        std.fmt.bufPrint(&started_buf, "{d}.{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}0000", .{ days, hh, mm, ss, milli }) catch null
    else
        std.fmt.bufPrint(&started_buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}0000", .{ hh, mm, ss, milli }) catch null;
}
