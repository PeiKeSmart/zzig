//! DH.RustBase 风格文本日志：
//! - 行格式：`HH:mm:ss.fff 线程ID 类型 名称 正文`（默认列序对齐 DH.NCore `LogLineFormat`）；
//! - 文件按天：`Log/yyyy_MM_dd.log`，单文件超过上限拆 `_2`、`_3`…；
//! - 首次写入文件时输出配置头（`#Software` / `#Date` / `#Fields` 等）；
//! - 控制台按级别着色（警告黄 / 错误红）；
//! - 同步写、互斥保护：日志频率低的常驻服务足够可靠，不引入队列/后台线程。

const std = @import("std");
const fsio = @import("../file/fsio.zig");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "Debug",
            .info => "Info",
            .warn => "Warn",
            .err => "Error",
            .fatal => "Fatal",
        };
    }

    fn color(self: Level) []const u8 {
        return switch (self) {
            .warn => "\x1b[33m",
            .err, .fatal => "\x1b[31m",
            .debug => "\x1b[90m",
            .info => "\x1b[37m",
        };
    }
};

pub fn parseLevel(text: []const u8) Level {
    if (std.ascii.eqlIgnoreCase(text, "debug") or std.ascii.eqlIgnoreCase(text, "all")) return .debug;
    if (std.ascii.eqlIgnoreCase(text, "warn") or std.ascii.eqlIgnoreCase(text, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(text, "err") or std.ascii.eqlIgnoreCase(text, "error")) return .err;
    if (std.ascii.eqlIgnoreCase(text, "fatal")) return .fatal;
    return .info;
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
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();

        formatLine(self.io, &line.writer, level, fmt, args) catch return;
        const bytes = line.written();

        if (self.opts.use_console) {
            std.Io.File.stdout().writeStreamingAll(self.io, level.color()) catch {};
            std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch {};
            std.Io.File.stdout().writeStreamingAll(self.io, "\x1b[0m") catch {};
        }

        self.rollIfNeeded(false) catch return;
        const f = self.file orelse return;
        const end = f.length(self.io) catch 0;
        self.io.vtable.fileSeekTo(self.io.userdata, f, end) catch {};
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

    fn renderHeader(self: *TextFileLog) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();

        var date_buf: [10]u8 = undefined;
        @memset(&date_buf, '0');
        formatDate(&date_buf, nowMillis(self.io)) catch {};

        out.writer.print("#Software: {s}\r\n", .{self.opts.software}) catch {};
        out.writer.print("#Date: {s}\r\n", .{date_buf}) catch {};
        out.writer.writeAll("#Fields: Time ThreadId Kind Name Message\r\n") catch {};
        out.writer.writeAll("#字段: 时间 线程ID 类型 名称 消息内容\r\n") catch {};
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
        @intFromEnum(md.month),
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
