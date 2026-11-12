//! SQL Server 执行驱动（**TDS 7.4 纯 wire protocol**，不加载 ODBC / sqlncli / msodbcsql）。
//!
//! 对应 C# `DH.NCode.SqlServer`（走 `System.Data.SqlClient`）与 Rust `Pek.RCode/src/mssql.rs`
//! （走 `tiberius`，同为零依赖纯协议）的**执行**部分；方言（`[x]` 引用符、`@pN` 占位符、
//! `OFFSET/FETCH` 分页、类型映射）在上层 `dialect` 里，本模块只管「连得上、发得出、读得回」。
//!
//! ## 支持范围（实测口径，不猜）
//!
//! | 能力 | 状态 |
//! |---|---|
//! | PRELOGIN（VERSION / ENCRYPTION / INSTOPT / THREADID / MARS） | ✅ |
//! | LOGIN7 + **SQL 认证**（密码 nibble-swap + XOR 0xA5 混淆） | ✅ |
//! | SQL 批处理（包类型 `0x01`，UTF-16LE 文本） | ✅ |
//! | 带参语句：RPC `sp_executesql`（包类型 `0x03`），参数按键名 `@p0..@pN` 绑定 | ✅ |
//! | 结果集：COLMETADATA / ROW / NBCROW / DONE* / ERROR / INFO / ENVCHANGE / LOGINACK / RETURNSTATUS / RETURNVALUE | ✅ |
//! | 类型解码：int1/2/4/8、INTN、bit/bitn、float4/8、FLTN、money/money4/moneyn、decimal/numeric、datetime/smalldatetime、date/time/datetime2/datetimeoffset、uniqueidentifier、varchar/nvarchar/char/nchar（含 PLP）、varbinary/image（含 PLP）、xml | ✅ |
//! | `lastInsertId`：插入后自动 `SELECT SCOPE_IDENTITY()`（与 `dialect.lastIdentitySql` 同口径） | ✅ |
//! | TLS（`ENCRYPTION=ON` / `REQUIRED`） | ⛔ 未做：服务端要求加密时**明确报错**，绝不静默降级成明文 |
//! | 集成认证（Windows/SSPI）、MARS 多结果集并发、TEXT/NTEXT/IMAGE、sql_variant、UDT | ⛔ 未做（`error.UnsupportedType`） |
//!
//! ## 为什么参数走 `sp_executesql` 而不是文本拼接
//!
//! 拼接会引入注入面，还把「十进制/时间」交给服务端的方言设置去猜。RPC 方式参数**带类型**
//! 传过去（`INTN` / `FLTN` / `DECIMALN` / `DATETIME2` / `NVARCHAR(max)` PLP / `VARBINARY(max)` PLP），
//! 服务端按声明类型解析，与 C# 驱动把 `SqlParameter` 交给 `sp_executesql` 的形态一致。
//!
//! ## 线程模型
//!
//! `Conn` **不是**线程安全的，一条连接同一时刻只能被一个线程使用（与 sqlite / mysql / postgres 驱动一致）。

const std = @import("std");
const compat = @import("../compat.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;
const Decimal = @import("../number/decimal.zig").Decimal;
const DateTime = @import("../time/datetime.zig").DateTime;

/// 导出一份，供回环用例构造参数（驱动本身只用内部别名）。
pub const ValueIn = Value;

pub const default_port: u16 = 1433;
/// 客户端声明的包长（服务端可在 ENVCHANGE 里给更大的值，我们不必跟随）
pub const default_packet_size: u16 = 4096;

/// TDS 7.4（MS-TDS 2.2.6.4：该字段在线上按**大端**写，抓到的是 `74 00 00 04`）
const tds_version_74: u32 = 0x7400_0004;

// ── 包类型（MS-TDS 2.2.3.1）─────────────────────────────────────────────────
const PKT_SQL_BATCH: u8 = 0x01;
const PKT_RPC: u8 = 0x03;
const PKT_RESPONSE: u8 = 0x04;
pub const PKT_LOGIN7: u8 = 0x10;
pub const PKT_PRELOGIN: u8 = 0x12;

/// 包状态位：0x01 = 本消息最后一包（EOM）
const STATUS_EOM: u8 = 0x01;

// ── PRELOGIN 选项 ───────────────────────────────────────────────────────────
const PRE_VERSION: u8 = 0x00;
const PRE_ENCRYPTION: u8 = 0x01;
const PRE_INSTOPT: u8 = 0x02;
const PRE_THREADID: u8 = 0x03;
const PRE_MARS: u8 = 0x04;
const PRE_TERMINATOR: u8 = 0xFF;

/// 加密档位（服务端 PRELOGIN 应答里的取值）
const ENCRYPT_OFF: u8 = 0x00;
const ENCRYPT_ON: u8 = 0x01;
const ENCRYPT_NOT_SUP: u8 = 0x02;
const ENCRYPT_REQ: u8 = 0x03;

// ── 令牌（MS-TDS 2.2.5）─────────────────────────────────────────────────────
const TOK_COLMETADATA: u8 = 0x81;
const TOK_ERROR: u8 = 0xAA;
const TOK_INFO: u8 = 0xAB;
const TOK_LOGINACK: u8 = 0xAD;
const TOK_ROW: u8 = 0xD1;
const TOK_NBCROW: u8 = 0xD2;
const TOK_ENVCHANGE: u8 = 0xE3;
const TOK_DONE: u8 = 0xFD;
const TOK_DONEPROC: u8 = 0xFE;
const TOK_DONEINPROC: u8 = 0xFF;
const TOK_RETURNSTATUS: u8 = 0x79;
const TOK_RETURNVALUE: u8 = 0xAC;

/// DONE 状态位
const DONE_MORE: u16 = 0x0001;
const DONE_ERROR: u16 = 0x0002;
const DONE_COUNT: u16 = 0x0010;

/// `sp_executesql` 的系统存储过程 ID（MS-TDS 2.2.6.6：ProcID 用系统 proc 编号）
const PROC_SP_EXECUTESQL: u16 = 10;

/// `SQL_Latin1_General_CP1_CI_AS` 的 5 字节 collation（参数侧用它即可：
/// 列与参数比较时以**列**的 collation 为准）
const default_collation = [5]u8{ 0x09, 0x04, 0xD0, 0x00, 0x34 };

pub const Ok = struct {
    /// 影响行数（DONE 包里的 RowCount；DML 才有）
    affected_rows: u64 = 0,
};

pub const Rows = struct {
    /// 列名（所有行共用一份，分配在结果 arena 上）
    names: []const []const u8 = &.{},
    rows: []const Row = &.{},
};

pub const Result = union(enum) {
    ok: Ok,
    rows: Rows,
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8 = "",
    /// 连接串里的 `Application Name`（出现在 `sys.dm_exec_sessions.program_name`，排查连接来源用）
    app_name: []const u8 = "pek-zcode",
    /// 客户端包长（服务端通常接受 4096）
    packet_size: u16 = default_packet_size,
};

pub const Error = error{
    ConnectionClosed,
    Protocol,
    Server,
    AuthFailed,
    /// 服务端要求加密（`ENCRYPTION=ON/REQ`），本驱动未实现 TLS
    TlsRequired,
    /// 列类型不在支持范围内（TEXT / NTEXT / IMAGE / sql_variant / UDT 等）
    UnsupportedType,
};

/// 单列的长度前缀方式。
const LenKind = enum {
    /// 定长，无长度前缀
    none,
    /// 1 字节长度（`0xFF` = NULL）
    byte,
    /// 2 字节长度（`0xFFFF` = NULL）
    ushort_len,
    /// PLP（Partially Length-Prefixed）：8 字节总长 + 分块 + 0 结束
    plp,
};

const TypeInfo = struct {
    type: u8,
    len_kind: LenKind = .none,
    /// `none` 时的定长字节数
    fixed_len: usize = 0,
    max_len: u32 = 0,
    precision: u8 = 0,
    scale: u8 = 0,

    fn typeName(self: TypeInfo) []const u8 {
        return switch (self.type) {
            0x1F => "null",
            0x30 => "tinyint",
            0x32 => "bit",
            0x34 => "smallint",
            0x38 => "int",
            0x3A => "smalldatetime",
            0x3B => "real",
            0x3C => "money",
            0x3D => "datetime",
            0x3E => "float",
            0x7A => "smallmoney",
            0x7F => "bigint",
            0x24 => "uniqueidentifier",
            0x26 => "intn",
            0x68 => "bitn",
            0x6A => "decimal",
            0x6C => "numeric",
            0x6D => "floatn",
            0x6E => "moneyn",
            0x6F => "datetimen",
            0x28 => "date",
            0x29 => "time",
            0x2A => "datetime2",
            0x2B => "datetimeoffset",
            0xA5 => "varbinary",
            0xA7 => "varchar",
            0xAD => "binary",
            0xAF => "char",
            0xE7 => "nvarchar",
            0xEF => "nchar",
            0xF1 => "xml",
            0xF0 => "udt",
            0x63 => "ntext",
            0x23 => "text",
            0x22 => "image",
            0x62 => "sql_variant",
            else => "unknown",
        };
    }
};

/// 载荷读取器（越界一律 `error.Protocol`，绝不让切片操作 panic）。
const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn remaining(self: Reader) usize {
        return self.buf.len - self.pos;
    }

    fn need(self: Reader, n: usize) !void {
        if (self.pos + n > self.buf.len) return error.Protocol;
    }

    fn byte(self: *Reader) !u8 {
        try self.need(1);
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    fn take(self: *Reader, n: usize) ![]const u8 {
        try self.need(n);
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn skip(self: *Reader, n: usize) !void {
        _ = try self.take(n);
    }

    fn u16le(self: *Reader) !u16 {
        const b = try self.take(2);
        return std.mem.readInt(u16, b[0..2], .little);
    }

    fn u32le(self: *Reader) !u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn u32be(self: *Reader) !u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .big);
    }

    fn u64le(self: *Reader) !u64 {
        const b = try self.take(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }

    /// B_VARCHAR：1 字节**字符数** + UTF-16LE
    fn bVarChar(self: *Reader) ![]const u8 {
        const n = try self.byte();
        return self.take(@as(usize, n) * 2);
    }

    /// US_VARCHAR：2 字节字符数 + UTF-16LE
    fn usVarChar(self: *Reader) ![]const u8 {
        const n = try self.u16le();
        return self.take(@as(usize, n) * 2);
    }
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    /// 一条**消息**（可能由多个包拼成）的载荷；每次 `readMessage` 后失效
    rx: std.ArrayList(u8) = .empty,
    /// 发送缓冲（整条消息拼好后一次发）
    tx: std.ArrayList(u8) = .empty,
    packet_size: usize = default_packet_size,
    packet_id: u8 = 0,
    server_version_buf: [64]u8 = undefined,
    server_version_len: usize = 0,
    last_affected_rows: u64 = 0,
    last_insert_id: i64 = 0,
    err_buf: [768]u8 = undefined,
    err_len: usize = 0,
    err_code: u32 = 0,
    /// `ERROR` 令牌里的 State / Class（SQL Server 没有 5 位 SQLSTATE，保留原始字段）
    err_state: u8 = 0,
    err_class: u8 = 0,
    closed: bool = false,
    /// 登录是否收到 LOGINACK（`readResponse` 在 parse 到该令牌时置位）
    last_login_ack: bool = false,
    /// 正在取 `SCOPE_IDENTITY()`（防止 `exec` → `captureIdentity` 递归）
    in_identity: bool = false,

    // ── 基本信息 ────────────────────────────────────────────────────────────

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn lastErrorCode(self: *const Conn) u32 {
        return self.err_code;
    }

    pub fn lastErrorState(self: *const Conn) u8 {
        return self.err_state;
    }

    pub fn lastErrorClass(self: *const Conn) u8 {
        return self.err_class;
    }

    pub fn affectedRows(self: *const Conn) u64 {
        return self.last_affected_rows;
    }

    pub fn lastInsertId(self: *const Conn) i64 {
        return self.last_insert_id;
    }

    pub fn serverVersion(self: *const Conn) []const u8 {
        return self.server_version_buf[0..self.server_version_len];
    }

    fn setError(self: *Conn, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch blk: {
            break :blk self.err_buf[0..@min(self.err_buf.len, 200)];
        };
        self.err_len = text.len;
    }

    // ── 连接与登录 ──────────────────────────────────────────────────────────

    pub fn open(gpa: std.mem.Allocator, opts: Options) !Conn {
        const io = compat.currentIo();
        const address = std.Io.net.IpAddress.resolve(io, opts.host, opts.port) catch |e| {
            std.debug.print("[zzig.tds] 解析主机失败：host={s} port={d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };
        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            std.debug.print("[zzig.tds] 连接失败：{s}:{d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };

        var self = Conn{ .gpa = gpa, .io = io, .stream = stream, .packet_size = opts.packet_size };
        // 登录失败时 `Conn` 不会交给调用方，收发缓冲必须在这里自己释放（否则每次连不上都漏一块）
        errdefer {
            self.closeQuietly();
            self.rx.deinit(gpa);
            self.tx.deinit(gpa);
        }

        self.handshake(opts) catch |e| {
            if (self.err_len == 0) {
                self.setError("登录失败（{s}:{d} 用户 {s} 库 {s}）：{s}", .{
                    opts.host, opts.port, opts.user, opts.database, @errorName(e),
                });
            }
            std.debug.print("[zzig.tds] 连接/登录失败：{s}\n", .{self.lastError()});
            return e;
        };
        return self;
    }

    pub fn deinit(self: *Conn) void {
        self.closeQuietly();
        self.rx.deinit(self.gpa);
        self.tx.deinit(self.gpa);
    }

    fn closeQuietly(self: *Conn) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close(self.io);
    }

    pub fn close(self: *Conn) void {
        self.closeQuietly();
    }

    pub fn ping(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = try self.run("SELECT 1", &.{}, arena.allocator(), true);
        switch (r) {
            .rows => |rows| if (rows.rows.len == 0) return error.Protocol,
            .ok => return error.Protocol,
        }
    }

    /// 切库（`USE [name]`）。连接串里已带 `Database` 时不需要再调。
    pub fn useDatabase(self: *Conn, name: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.gpa, "USE [{s}]", .{name});
        defer self.gpa.free(sql);
        _ = try self.exec(sql, &.{});
    }

    fn handshake(self: *Conn, opts: Options) !void {
        try self.prelogin();
        try self.login7(opts);
    }

    // ── PRELOGIN ────────────────────────────────────────────────────────────

    fn prelogin(self: *Conn) !void {
        const table_len = 4 * 5 + 1; // 5 个选项 × {token, offset, len} + 0xFF
        const values_len = 6 + 1 + 1 + 4 + 1; // VERSION / ENCRYPTION / INSTOPT / THREADID / MARS
        var payload: [table_len + values_len]u8 = undefined;
        @memset(&payload, 0);

        var off: usize = table_len;
        var i: usize = 0;

        // VERSION：UL_VERSION(4) + US_SUBBUILD(2)，全 0 表示「客户端不关心」
        i = writePreloginEntry(&payload, i, PRE_VERSION, off, 6);
        off += 6;

        // ENCRYPTION：0 = 只接受明文（本驱动未实现 TLS）
        i = writePreloginEntry(&payload, i, PRE_ENCRYPTION, off, 1);
        payload[off] = ENCRYPT_OFF;
        off += 1;

        i = writePreloginEntry(&payload, i, PRE_INSTOPT, off, 1);
        payload[off] = 0;
        off += 1;

        i = writePreloginEntry(&payload, i, PRE_THREADID, off, 4);
        off += 4;

        // MARS：0 = 不启用（多结果集并发读需要它，本驱动不做）
        i = writePreloginEntry(&payload, i, PRE_MARS, off, 1);
        payload[off] = 0;
        off += 1;

        payload[i] = PRE_TERMINATOR;

        try self.writeMessage(PKT_PRELOGIN, payload[0..off]);

        const msg = try self.readMessage();
        if (msg.type != PKT_RESPONSE) {
            self.setError("PRELOGIN 应答包类型异常：0x{X:0>2}（期望 0x04）", .{msg.type});
            return error.Protocol;
        }
        const enc = try parsePreloginEncryption(msg.payload);
        switch (enc) {
            ENCRYPT_OFF, ENCRYPT_NOT_SUP => {},
            ENCRYPT_ON, ENCRYPT_REQ => {
                self.setError(
                    "服务端要求 TLS 加密（PRELOGIN ENCRYPTION=0x{X:0>2}），本驱动未实现 TDS over TLS；" ++
                        "请在服务端关闭强制加密，或改用支持 TLS 的驱动",
                    .{enc},
                );
                return error.TlsRequired;
            },
            else => {
                self.setError("PRELOGIN 应答里的 ENCRYPTION 取值未知：0x{X:0>2}", .{enc});
                return error.Protocol;
            },
        }
    }

    /// 写一条 PRELOGIN 选项表项（token + 2 字节大端偏移 + 2 字节大端长度），返回下一项的位置。
    fn writePreloginEntry(payload: []u8, pos: usize, token: u8, offset: usize, len: usize) usize {
        payload[pos] = token;
        std.mem.writeInt(u16, payload[pos + 1 ..][0..2], @intCast(offset), .big);
        std.mem.writeInt(u16, payload[pos + 3 ..][0..2], @intCast(len), .big);
        return pos + 5;
    }

    /// 解析服务端 PRELOGIN 应答，返回 ENCRYPTION 取值（缺项按「不支持」处理）。
    pub fn parsePreloginEncryption(payload: []const u8) !u8 {
        var p = Reader{ .buf = payload };
        var encryption: ?u8 = null;
        while (p.remaining() > 0) {
            const token = try p.byte();
            if (token == PRE_TERMINATOR) break;
            const raw_off = try p.take(2);
            const raw_len = try p.take(2);
            const offset = std.mem.readInt(u16, raw_off[0..2], .big);
            const len = std.mem.readInt(u16, raw_len[0..2], .big);
            if (@as(usize, offset) + @as(usize, len) > payload.len) return error.Protocol;
            if (token == PRE_ENCRYPTION and len >= 1) encryption = payload[offset];
        }
        return encryption orelse ENCRYPT_NOT_SUP;
    }

    // ── LOGIN7 ──────────────────────────────────────────────────────────────

    fn login7(self: *Conn, opts: Options) !void {
        const payload = try buildLogin7(self.gpa, opts, @intCast(self.packet_size));
        defer self.gpa.free(payload);

        try self.writeMessage(PKT_LOGIN7, payload);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = try self.readResponse(arena.allocator(), false);
        if (!self.last_login_ack) {
            if (self.err_len == 0) self.setError("LOGIN7 未收到 LOGINACK（服务端未完成登录）", .{});
            return error.AuthFailed;
        }
    }

    // ── 查询 / 执行 ─────────────────────────────────────────────────────────

    /// 执行带参/无参语句并收集结果集（行与字符串分配在 `arena` 上）。
    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        return self.run(sql, params, arena, true) catch |e| {
            if (self.err_len == 0) self.setError("查询失败（{s}）：SQL={s}", .{ @errorName(e), sql });
            return e;
        };
    }

    /// 执行语句，返回影响行数（不收集结果集）。
    /// 若语句是 `INSERT`，随后自动取 `SCOPE_IDENTITY()` 供 `lastInsertId()` 使用。
    pub fn exec(self: *Conn, sql: []const u8, params: []const Value) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        const r = self.run(sql, params, arena.allocator(), false) catch |e| {
            if (self.err_len == 0) self.setError("执行失败（{s}）：SQL={s}", .{ @errorName(e), sql });
            return e;
        };
        const n: u64 = switch (r) {
            .ok => |o| o.affected_rows,
            .rows => |rows| @intCast(rows.rows.len),
        };
        self.last_affected_rows = n;

        if (startsWithInsert(sql)) self.captureIdentity();
        return n;
    }

    /// 取 `SCOPE_IDENTITY()`（与 `dialect.lastIdentitySql` 的 SQL Server 分支一致）。
    /// 失败不报错：非自增表本来就没有 identity（结果就是 NULL）。
    fn captureIdentity(self: *Conn) void {
        if (self.in_identity) return;
        self.in_identity = true;
        defer self.in_identity = false;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = self.run("SELECT SCOPE_IDENTITY()", &.{}, arena.allocator(), true) catch |e| {
            std.debug.print("[zzig.tds] 取 SCOPE_IDENTITY() 失败（不影响写入）：{s}；{s}\n", .{ @errorName(e), self.lastError() });
            return;
        };
        switch (r) {
            .rows => |rows| {
                if (rows.rows.len == 0 or rows.rows[0].values.len == 0) return;
                if (rows.rows[0].values[0].asI64()) |id| self.last_insert_id = id;
            },
            .ok => {},
        }
    }

    fn run(self: *Conn, sql: []const u8, params: []const Value, arena: std.mem.Allocator, collect: bool) !Result {
        if (params.len == 0) {
            try self.sendBatch(sql);
        } else {
            try self.sendRpc(sql, params);
        }
        return self.readResponse(arena, collect);
    }

    fn sendBatch(self: *Conn, sql: []const u8) !void {
        self.tx.clearRetainingCapacity();
        const units = try std.unicode.utf8ToUtf16LeAlloc(self.gpa, sql);
        defer self.gpa.free(units);
        try self.tx.ensureUnusedCapacity(self.gpa, units.len * 2);
        for (units) |u| {
            self.tx.appendAssumeCapacity(@truncate(u));
            self.tx.appendAssumeCapacity(@truncate(u >> 8));
        }
        try self.writeMessage(PKT_SQL_BATCH, self.tx.items);
    }

    fn sendRpc(self: *Conn, sql: []const u8, params: []const Value) !void {
        self.tx.clearRetainingCapacity();
        // AllHeaders：4 字节长度（0 = 无头部）
        try self.tx.appendSlice(self.gpa, &[_]u8{ 0, 0, 0, 0 });
        // ProcID（系统存储过程编号）+ OptionFlags
        try appendU16le(self.gpa, &self.tx, PROC_SP_EXECUTESQL);
        try appendU16le(self.gpa, &self.tx, 0);

        // @stmt / @params 用「无名参数」（与 go-mssqldb / FreeTDS 同口径）
        try appendParam(self.gpa, &self.tx, "", .{ .text = sql });

        const decl = try buildParamDecls(self.gpa, params);
        defer self.gpa.free(decl);
        try appendParam(self.gpa, &self.tx, "", .{ .text = decl });

        for (params, 0..) |v, i| {
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "@p{d}", .{i}) catch unreachable;
            try appendParam(self.gpa, &self.tx, name, v);
        }

        try self.writeMessage(PKT_RPC, self.tx.items);
    }

    // ── 收发 ────────────────────────────────────────────────────────────────

    const Message = struct {
        type: u8,
        payload: []const u8,
    };

    fn writeMessage(self: *Conn, pkt_type: u8, payload: []const u8) !void {
        self.packet_id = 1;
        const max_chunk = self.packet_size - 8;
        var off: usize = 0;
        while (true) {
            const chunk = @min(payload.len - off, max_chunk);
            const is_last = off + chunk >= payload.len;
            var hdr: [8]u8 = undefined;
            hdr[0] = pkt_type;
            hdr[1] = if (is_last) STATUS_EOM else 0;
            std.mem.writeInt(u16, hdr[2..4], @intCast(8 + chunk), .big);
            std.mem.writeInt(u16, hdr[4..6], 0, .big);
            hdr[6] = self.packet_id;
            hdr[7] = 0;
            try self.writeRaw(&hdr);
            if (chunk > 0) try self.writeRaw(payload[off..][0..chunk]);
            self.packet_id +%= 1;
            off += chunk;
            if (is_last) break;
        }
    }

    fn readMessage(self: *Conn) !Message {
        self.rx.clearRetainingCapacity();
        var msg_type: u8 = PKT_RESPONSE;
        while (true) {
            var hdr: [8]u8 = undefined;
            try self.readExact(&hdr);
            const len = std.mem.readInt(u16, hdr[2..4], .big);
            if (len < 8 or len > self.packet_size) {
                self.setError("TDS 包头长度异常：{d}（包长上限 {d}）", .{ len, self.packet_size });
                return error.Protocol;
            }
            msg_type = hdr[0];
            const body_len = @as(usize, len) - 8;
            const start = self.rx.items.len;
            try self.rx.resize(self.gpa, start + body_len);
            if (body_len > 0) try self.readExact(self.rx.items[start..][0..body_len]);
            if ((hdr[1] & STATUS_EOM) != 0) break;
        }
        return .{ .type = msg_type, .payload = self.rx.items };
    }

    fn readExact(self: *Conn, dst: []u8) !void {
        var got: usize = 0;
        while (got < dst.len) {
            const n = try self.readSome(dst[got..]);
            if (n == 0) {
                self.closed = true;
                self.setError("连接被对端关闭（已读 {d}/{d} 字节）", .{ got, dst.len });
                return error.ConnectionClosed;
            }
            got += n;
        }
    }

    fn readSome(self: *Conn, dst: []u8) !usize {
        var slices = [_][]u8{dst};
        const r = self.io.operate(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = &slices,
        } }) catch |e| {
            self.setError("读 socket 失败：{s}", .{@errorName(e)});
            return e;
        };
        const res = r.net_read catch |e| {
            self.setError("读 socket 失败：{s}", .{@errorName(e)});
            return e;
        };
        return res.data_len;
    }

    fn writeRaw(self: *Conn, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            var slices = [_][]const u8{bytes[sent..]};
            const r = self.io.operate(.{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .data = &slices,
            } }) catch |e| {
                self.setError("写 socket 失败：{s}", .{@errorName(e)});
                self.closed = true;
                return e;
            };
            const n = r.net_write catch |e| {
                self.setError("写 socket 失败：{s}", .{@errorName(e)});
                self.closed = true;
                return e;
            };
            if (n == 0) {
                self.closed = true;
                return error.ConnectionClosed;
            }
            sent += n;
        }
    }

    // ── 令牌流解析 ──────────────────────────────────────────────────────────

    const Response = struct {
        rows: std.ArrayList(Row) = .empty,
        names: []const []const u8 = &.{},
    };

    fn readResponse(self: *Conn, arena: std.mem.Allocator, collect: bool) !Result {
        const msg = try self.readMessage();
        if (msg.type != PKT_RESPONSE) {
            self.setError("响应包类型异常：0x{X:0>2}（期望 0x04 RESPONSE）", .{msg.type});
            return error.Protocol;
        }

        var resp = Response{};
        var p = Reader{ .buf = msg.payload };
        var columns: []const TypeInfo = &.{};
        var saw_error = false;
        var saw_rows = false;
        var done_count: u64 = 0;

        while (p.remaining() > 0) {
            const tok = try p.byte();
            switch (tok) {
                TOK_COLMETADATA => {
                    const raw = try p.take(2);
                    const count = std.mem.readInt(u16, raw[0..2], .little);
                    if (count == 0xFFFF) {
                        columns = &.{};
                        continue;
                    }
                    const tis = try arena.alloc(TypeInfo, count);
                    const names = try arena.alloc([]const u8, count);
                    for (0..count) |ci| {
                        _ = try p.u32le(); // UserType
                        _ = try p.u16le(); // Flags
                        tis[ci] = try readTypeInfo(&p);
                        const raw_name = try p.bVarChar();
                        names[ci] = try utf16ToUtf8(arena, raw_name);
                    }
                    columns = tis;
                    resp.names = names;
                },
                TOK_ROW, TOK_NBCROW => {
                    if (columns.len == 0) {
                        self.setError("收到 ROW 令牌但没有 COLMETADATA（协议错误）", .{});
                        return error.Protocol;
                    }
                    var null_bitmap: []const u8 = &.{};
                    if (tok == TOK_NBCROW) null_bitmap = try p.take((columns.len + 7) / 8);

                    const values = try arena.alloc(Value, columns.len);
                    for (columns, 0..) |ti, ci| {
                        if (null_bitmap.len > 0 and (null_bitmap[ci / 8] & (@as(u8, 1) << @intCast(ci % 8))) != 0) {
                            values[ci] = .null;
                            continue;
                        }
                        values[ci] = try readCell(arena, ti, &p);
                    }
                    saw_rows = true;
                    if (collect) try resp.rows.append(arena, .{ .names = resp.names, .values = values });
                },
                TOK_DONE, TOK_DONEPROC, TOK_DONEINPROC => {
                    const status = try p.u16le();
                    _ = try p.u16le(); // CurCmd
                    const row_count = try p.u64le();
                    if ((status & DONE_ERROR) != 0) saw_error = true;
                    if ((status & DONE_COUNT) != 0) done_count = row_count;
                },
                TOK_ERROR, TOK_INFO => {
                    const detail = try parseErrorToken(&p);
                    if (tok == TOK_ERROR) {
                        saw_error = true;
                        self.err_code = detail.number;
                        self.err_state = detail.state;
                        self.err_class = detail.class;
                        self.setError(
                            "SQL Server 错误 {d}（State {d}，Class {d}，第 {d} 行）：{s}",
                            .{ detail.number, detail.state, detail.class, detail.line, detail.message },
                        );
                    } else {
                        std.debug.print("[zzig.tds] 服务端 INFO {d}：{s}\n", .{ detail.number, detail.message });
                    }
                },
                TOK_ENVCHANGE => {
                    const len = try p.u16le();
                    try p.skip(len);
                },
                TOK_LOGINACK => {
                    const len = try p.u16le();
                    const end = p.pos + len;
                    _ = try p.byte(); // Interface
                    const ver = try p.u32be(); // TDSVersion
                    const prog = try p.bVarChar();
                    _ = try p.take(4); // ProgVersion（major/minor/buildhi/buildlow）
                    self.last_login_ack = true;
                    self.server_version_len = @min(prog.len, self.server_version_buf.len);
                    @memcpy(self.server_version_buf[0..self.server_version_len], prog[0..self.server_version_len]);
                    if (p.pos > end) return error.Protocol;
                    if (p.pos < end) try p.skip(end - p.pos);
                    if (ver != tds_version_74 and (ver & 0xFF) != 0x74) {
                        std.debug.print("[zzig.tds] 服务端 TDSVersion=0x{X:0>8}（本驱动按 7.4 解析）\n", .{ver});
                    }
                },
                TOK_RETURNSTATUS => {
                    _ = try p.u32le();
                },
                TOK_RETURNVALUE => {
                    _ = try p.u16le(); // Ordinal
                    _ = try p.bVarChar(); // Name
                    _ = try p.byte(); // Status
                    _ = try p.u32le(); // UserType
                    _ = try p.u16le(); // Flags
                    const ti = try readTypeInfo(&p);
                    _ = try readCell(arena, ti, &p);
                },
                else => {
                    self.setError(
                        "未识别的 TDS 令牌 0x{X:0>2}（偏移 {d}/{d}）——拒绝猜测后续格式",
                        .{ tok, p.pos - 1, p.buf.len },
                    );
                    return error.Protocol;
                },
            }
        }

        if (saw_error) {
            if (self.err_len == 0) self.setError("SQL Server 返回错误（未带 ERROR 令牌文本）", .{});
            return error.Server;
        }

        self.last_affected_rows = done_count;
        if (collect and saw_rows) {
            return .{ .rows = .{ .names = resp.names, .rows = try resp.rows.toOwnedSlice(arena) } };
        }
        return .{ .ok = .{ .affected_rows = done_count } };
    }
};

// ── 令牌辅助 ────────────────────────────────────────────────────────────────

const ErrorDetail = struct {
    number: u32 = 0,
    state: u8 = 0,
    class: u8 = 0,
    message: []const u8 = "",
    line: u32 = 0,
};

threadlocal var err_msg_buf: [512]u8 = undefined;

/// ERROR / INFO 令牌（MS-TDS 2.2.7.10 / 2.2.7.5）。
/// 文本是 UTF-16LE，这里转进一个线程局部缓冲（只为日志与 `lastError` 使用）。
fn parseErrorToken(p: *Reader) !ErrorDetail {
    const len = try p.u16le();
    const end = p.pos + len;
    var d = ErrorDetail{};
    d.number = try p.u32le();
    d.state = try p.byte();
    d.class = try p.byte();
    d.message = utf16ToUtf8Static(&err_msg_buf, try p.usVarChar());
    _ = try p.bVarChar(); // ServerName
    _ = try p.bVarChar(); // ProcName
    d.line = try p.u32le(); // TDS 7.2+ 是 4 字节行号
    if (p.pos > end) return error.Protocol;
    if (p.pos < end) try p.skip(end - p.pos);
    return d;
}

/// UTF-16LE → UTF-8（分配在 `arena` 上）。
fn utf16ToUtf8(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return "";
    const units = try arena.alloc(u16, raw.len / 2);
    for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
    return std.unicode.utf16LeToUtf8Alloc(arena, units);
}

/// UTF-16LE → UTF-8（写进固定缓冲；超长截断）。仅用于错误文本。
fn utf16ToUtf8Static(buf: []u8, raw: []const u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        const u = std.mem.readInt(u16, raw[i..][0..2], .little);
        if (u < 0x80) {
            if (out + 1 >= buf.len) break;
            buf[out] = @intCast(u);
            out += 1;
        } else if (u < 0x800) {
            if (out + 2 >= buf.len) break;
            buf[out] = @intCast(0xC0 | (u >> 6));
            buf[out + 1] = @intCast(0x80 | (u & 0x3F));
            out += 2;
        } else {
            if (out + 3 >= buf.len) break;
            buf[out] = @intCast(0xE0 | (u >> 12));
            buf[out + 1] = @intCast(0x80 | ((u >> 6) & 0x3F));
            buf[out + 2] = @intCast(0x80 | (u & 0x3F));
            out += 3;
        }
    }
    return buf[0..out];
}

/// TypeInfo（COLMETADATA / RETURNVALUE / RPC 参数共用同一套编码）。
fn readTypeInfo(p: *Reader) !TypeInfo {
    const t = try p.byte();
    var ti = TypeInfo{ .type = t };
    switch (t) {
        0x1F => ti.fixed_len = 0, // NULLTYPE
        0x30, 0x32 => ti.fixed_len = 1, // INT1 / BIT
        0x34 => ti.fixed_len = 2, // INT2
        0x38, 0x3A, 0x3B, 0x7A => ti.fixed_len = 4, // INT4 / DATETIM4 / FLT4 / MONEY4
        0x3C, 0x3D, 0x3E, 0x7F => ti.fixed_len = 8, // MONEY / DATETIME / FLT8 / INT8
        0x24, 0x26, 0x68, 0x6D, 0x6E, 0x6F => { // GUID / INTN / BITN / FLTN / MONEYN / DATETIMN
            ti.len_kind = .byte;
            ti.max_len = try p.byte();
        },
        0x6A, 0x6C => { // DECIMALN / NUMERICN
            ti.len_kind = .byte;
            ti.max_len = try p.byte();
            ti.precision = try p.byte();
            ti.scale = try p.byte();
        },
        0x28 => ti.fixed_len = 3, // DATE
        0x29 => { // TIME
            ti.scale = try p.byte();
            ti.fixed_len = timeBytesForScale(ti.scale);
        },
        0x2A => { // DATETIME2
            ti.scale = try p.byte();
            ti.fixed_len = timeBytesForScale(ti.scale) + 3;
        },
        0x2B => { // DATETIMEOFFSET
            ti.scale = try p.byte();
            ti.fixed_len = timeBytesForScale(ti.scale) + 5;
        },
        0xA5, 0xAD, 0xA7, 0xAF, 0xE7, 0xEF => {
            ti.max_len = try p.u16le();
            if (t == 0xA7 or t == 0xAF or t == 0xE7 or t == 0xEF) try p.skip(5); // Collation
            ti.len_kind = if (ti.max_len == 0xFFFF) .plp else .ushort_len;
        },
        0xF1 => { // XML：1 字节 schema 标志（带 schema 时有三个 B_VARCHAR）
            const has_schema = try p.byte();
            if (has_schema == 1) {
                _ = try p.bVarChar();
                _ = try p.bVarChar();
                _ = try p.bVarChar();
            }
            ti.len_kind = .plp;
        },
        0xF0 => { // UDT：2 字节 maxlen + 四个 B_VARCHAR 名字 + PLP
            _ = try p.u16le();
            _ = try p.bVarChar();
            _ = try p.bVarChar();
            _ = try p.bVarChar();
            _ = try p.bVarChar();
            ti.len_kind = .plp;
        },
        0x63, 0x23, 0x22 => { // NTEXT / TEXT / IMAGE：4 字节 maxlen + collation + 表名
            _ = try p.u32le();
            if (t != 0x22) try p.skip(5);
            _ = try p.usVarChar();
            return error.UnsupportedType;
        },
        0x62 => { // sql_variant
            _ = try p.u32le();
            return error.UnsupportedType;
        },
        else => return error.UnsupportedType,
    }
    return ti;
}

fn timeBytesForScale(scale: u8) usize {
    if (scale <= 2) return 3;
    if (scale <= 4) return 4;
    return 5;
}

/// 读一个 PLP 值（总长 + 若干块 + 0 结束块）；返回的字节分配在 `arena` 上。
///
/// 注意：**不能按「总长」直接 take** —— 线上是 `总长(8) + [块长(4) + 块]* + 0(4)`，
/// 已知总长也要逐块读（本轮实测：直接 take 会把 `块长` 当成正文，整条令牌流错位）。
fn readPlp(p: *Reader, arena: std.mem.Allocator) !?[]const u8 {
    const total = try p.u64le();
    if (total == 0xFFFF_FFFF_FFFF_FFFF) return null; // NULL
    const unknown_len = total == 0xFFFF_FFFF_FFFF_FFFE;

    var list: std.ArrayList(u8) = .empty;
    if (!unknown_len) try list.ensureTotalCapacity(arena, @intCast(total));
    while (true) {
        const n = try p.u32le();
        if (n == 0) break; // 结束块
        try list.appendSlice(arena, try p.take(n));
    }
    return list.items;
}

/// 读一个单元格并按类型还原成 `Value`。
fn readCell(arena: std.mem.Allocator, ti: TypeInfo, p: *Reader) !Value {
    const raw: ?[]const u8 = switch (ti.len_kind) {
        .none => if (ti.fixed_len == 0) null else try p.take(ti.fixed_len),
        .byte => blk: {
            const n = try p.byte();
            if (n == 0xFF) break :blk null;
            break :blk try p.take(n);
        },
        .ushort_len => blk: {
            const n = try p.u16le();
            if (n == 0xFFFF) break :blk null;
            break :blk try p.take(n);
        },
        .plp => try readPlp(p, arena),
    };
    const b = raw orelse return .null;
    if (b.len == 0 and isNumericType(ti.type)) return .null;

    switch (ti.type) {
        0x1F => return .null,
        0x30 => return .{ .int = b[0] },
        0x32 => return .{ .boolean = b[0] != 0 },
        0x34 => return .{ .int = @as(i16, @bitCast(std.mem.readInt(u16, b[0..2], .little))) },
        0x38 => return .{ .int = @as(i32, @bitCast(std.mem.readInt(u32, b[0..4], .little))) },
        0x7F => return .{ .int = std.mem.readInt(i64, b[0..8], .little) },
        0x3B => return .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .little))) },
        0x3E => return .{ .float = @as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little))) },
        0x26 => {
            switch (b.len) {
                1 => return .{ .int = b[0] },
                2 => return .{ .int = @as(i16, @bitCast(std.mem.readInt(u16, b[0..2], .little))) },
                4 => return .{ .int = @as(i32, @bitCast(std.mem.readInt(u32, b[0..4], .little))) },
                8 => return .{ .int = std.mem.readInt(i64, b[0..8], .little) },
                else => return error.Protocol,
            }
        },
        0x68 => return .{ .boolean = b[0] != 0 },
        0x6D => {
            switch (b.len) {
                4 => return .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .little))) },
                8 => return .{ .float = @as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little))) },
                else => return error.Protocol,
            }
        },
        0x3C => {
            if (b.len != 8) return error.Protocol;
            return .{ .decimal = .{ .mantissa = std.mem.readInt(i64, b[0..8], .little), .scale = 4 } };
        },
        0x7A => {
            if (b.len != 4) return error.Protocol;
            const v = @as(i32, @bitCast(std.mem.readInt(u32, b[0..4], .little)));
            return .{ .decimal = .{ .mantissa = v, .scale = 4 } };
        },
        0x6E => {
            switch (b.len) {
                4 => return .{ .decimal = .{ .mantissa = @as(i32, @bitCast(std.mem.readInt(u32, b[0..4], .little))), .scale = 4 } },
                8 => return .{ .decimal = .{ .mantissa = std.mem.readInt(i64, b[0..8], .little), .scale = 4 } },
                else => return error.Protocol,
            }
        },
        0x6A, 0x6C => return decodeDecimalN(b, ti.scale),
        0x3A => return decodeSmallDateTime(b),
        0x3D => return decodeDateTime(b),
        0x6F => {
            switch (b.len) {
                4 => return decodeSmallDateTime(b),
                8 => return decodeDateTime(b),
                else => return error.Protocol,
            }
        },
        0x28 => return decodeDate(b),
        0x29 => return decodeTime(b, ti.scale),
        0x2A => return decodeDateTime2(b, ti.scale),
        0x2B => return decodeDateTimeOffset(b, ti.scale),
        0x24 => return decodeGuid(b, arena),
        0xE7, 0xEF, 0xF1 => return .{ .text = try utf16ToUtf8(arena, b) },
        0xA7, 0xAF => return .{ .text = try arena.dupe(u8, b) },
        0xA5, 0xAD => return .{ .blob = try arena.dupe(u8, b) },
        else => return error.UnsupportedType,
    }
}

fn isNumericType(t: u8) bool {
    return switch (t) {
        0x30, 0x32, 0x34, 0x38, 0x7F, 0x3B, 0x3E, 0x26, 0x68, 0x6A, 0x6C, 0x6D, 0x6E, 0x6F, 0x3A, 0x3C, 0x3D, 0x7A => true,
        else => false,
    };
}

fn decodeDecimalN(b: []const u8, scale: u8) !Value {
    if (b.len < 2 or b.len > 17) return error.Protocol;
    const negative = b[0] == 0;
    const mag = b[1..];
    var value: u128 = 0;
    var i: usize = mag.len;
    while (i > 0) {
        i -= 1;
        value = (value << 8) | mag[i];
    }
    var mantissa: i128 = @intCast(value);
    if (negative) mantissa = -mantissa;
    return .{ .decimal = .{ .mantissa = mantissa, .scale = scale } };
}

fn decodeDate(b: []const u8) !Value {
    if (b.len != 3) return error.Protocol;
    const days = @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
    return .{ .datetime = dateFromDaysSinceYear1(@intCast(days)) };
}

fn decodeTime(b: []const u8, scale: u8) !Value {
    var units: u64 = 0;
    for (b, 0..) |byte, i| units |= @as(u64, byte) << @intCast(i * 8);
    const t = splitTimeUnits(units, scale);
    return .{ .datetime = .{ .year = 1, .month = 1, .day = 1, .hour = t.hour, .minute = t.minute, .second = t.second, .nanos = t.nanos } };
}

fn decodeDateTime2(b: []const u8, scale: u8) !Value {
    const tlen = timeBytesForScale(scale);
    if (b.len != tlen + 3) return error.Protocol;
    var units: u64 = 0;
    for (b[0..tlen], 0..) |byte, i| units |= @as(u64, byte) << @intCast(i * 8);
    const days = @as(u32, b[tlen]) | (@as(u32, b[tlen + 1]) << 8) | (@as(u32, b[tlen + 2]) << 16);
    var dt = dateFromDaysSinceYear1(@intCast(days));
    const t = splitTimeUnits(units, scale);
    dt.hour = t.hour;
    dt.minute = t.minute;
    dt.second = t.second;
    dt.nanos = t.nanos;
    return .{ .datetime = dt };
}

/// `datetimeoffset`：**忽略时区偏移**，保留服务端给出的本地墙钟（与 C# 读 `.DateTime` 一致）。
fn decodeDateTimeOffset(b: []const u8, scale: u8) !Value {
    const tlen = timeBytesForScale(scale);
    if (b.len != tlen + 5) return error.Protocol;
    return decodeDateTime2(b[0 .. tlen + 3], scale);
}

fn decodeDateTime(b: []const u8) !Value {
    if (b.len != 8) return error.Protocol;
    const days = @as(i32, @bitCast(std.mem.readInt(u32, b[0..4], .little)));
    const ticks = std.mem.readInt(u32, b[4..8], .little); // 1/300 秒
    // 1900 纪元的天数**减去** 25567 才是 1970 纪元（1900 更早，同一日期的天数更大）
    var dt = dateFromDaysSince1970(@as(i64, days) - days_1900_to_1970);
    const secs: u64 = ticks / 300;
    const rem: u64 = ticks % 300;
    dt.hour = @intCast(secs / 3600);
    dt.minute = @intCast((secs % 3600) / 60);
    dt.second = @intCast(secs % 60);
    dt.nanos = @intCast(rem * 1_000_000_000 / 300);
    return .{ .datetime = dt };
}

fn decodeSmallDateTime(b: []const u8) !Value {
    if (b.len != 4) return error.Protocol;
    const days = std.mem.readInt(u16, b[0..2], .little);
    const minutes = std.mem.readInt(u16, b[2..4], .little);
    var dt = dateFromDaysSince1970(@as(i64, days) - days_1900_to_1970);
    dt.hour = @intCast(minutes / 60);
    dt.minute = @intCast(minutes % 60);
    return .{ .datetime = dt };
}

fn scaleUnitsToNanos(units: u64, scale: u8) u64 {
    var nanos = units;
    var s: u8 = scale;
    while (s < 9) : (s += 1) nanos *= 10;
    while (s > 9) : (s -= 1) nanos /= 10;
    return nanos;
}

const TimeParts = struct { hour: u8, minute: u8, second: u8, nanos: u32 };

/// 把「10^-scale 秒」的整数拆成时分秒 + 纳秒。
/// **必须拆**：`DateTime.nanos` 只装**秒以下**的纳秒，直接把整天的时间单位换成纳秒会溢出 u32
/// （本轮实测：scale=7 的 `08:30:15.1234567` → 3.06e13，u32 装不下当场 panic）。
fn splitTimeUnits(units: u64, scale: u8) TimeParts {
    const per_second: u64 = std.math.pow(u64, 10, scale);
    const total_secs = units / per_second;
    const frac = units % per_second;
    return .{
        .hour = @intCast((total_secs / 3600) % 24),
        .minute = @intCast((total_secs % 3600) / 60),
        .second = @intCast(total_secs % 60),
        .nanos = @intCast(scaleUnitsToNanos(frac, scale)),
    };
}

fn decodeGuid(b: []const u8, arena: std.mem.Allocator) !Value {
    if (b.len != 16) return error.Protocol;
    // SQL Server 的 GUID：前 3 组按小端，后 2 组按字节序
    const d1 = std.mem.readInt(u32, b[0..4], .little);
    const d2 = std.mem.readInt(u16, b[4..6], .little);
    const d3 = std.mem.readInt(u16, b[6..8], .little);
    const text = try std.fmt.allocPrint(arena, "{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
        d1,    d2,    d3,    b[8],  b[9],  b[10],
        b[11], b[12], b[13], b[14], b[15],
    });
    return .{ .text = text };
}

// ── 日期换算（Howard Hinnant 的 civil_from_days / days_from_civil）──────────

const Civil = struct { y: i64, m: i64, d: i64 };

/// 1970-01-01 起的天数 → 日历日期。
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;
    return .{ .y = y, .m = m, .d = d };
}

/// 日历日期 → 1970-01-01 起的天数。
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// 公元 1 年 1 月 1 日到 1970-01-01 的天数（SQL Server `date` 的纪元）。
const days_year1_to_1970: i64 = 719162;
/// 1900-01-01 到 1970-01-01 的天数（`datetime` / `smalldatetime` 的纪元）。
const days_1900_to_1970: i64 = 25567;

fn dateFromDaysSinceYear1(days: i64) DateTime {
    return dateFromDaysSince1970(days - days_year1_to_1970);
}

fn dateFromDaysSince1970(days: i64) DateTime {
    const c = civilFromDays(days);
    return .{
        .year = @intCast(c.y),
        .month = @intCast(c.m),
        .day = @intCast(c.d),
    };
}

// ── 参数编码 ────────────────────────────────────────────────────────────────

fn appendU16le(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.append(gpa, @truncate(v));
    try out.append(gpa, @truncate(v >> 8));
}

fn appendU32le(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.append(gpa, @truncate(v));
    try out.append(gpa, @truncate(v >> 8));
    try out.append(gpa, @truncate(v >> 16));
    try out.append(gpa, @truncate(v >> 24));
}

fn appendU64le(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u64) !void {
    try appendU32le(gpa, out, @truncate(v));
    try appendU32le(gpa, out, @truncate(v >> 32));
}

/// `@params` 声明串（与 `appendParam` 写出的 TypeInfo 严格对应）。
fn buildParamDecls(gpa: std.mem.Allocator, params: []const Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (params, 0..) |v, i| {
        if (i > 0) try list.append(gpa, ',');
        var num_buf: [32]u8 = undefined;
        const sql_type: []const u8 = switch (v) {
            .null, .int => "bigint",
            .boolean => "bit",
            .float => "float",
            .decimal => |d| std.fmt.bufPrint(&num_buf, "decimal(38,{d})", .{d.scale}) catch "decimal(38,0)",
            .datetime => "datetime2(7)",
            .text => "nvarchar(max)",
            .blob => "varbinary(max)",
        };
        var piece_buf: [48]u8 = undefined;
        const piece = std.fmt.bufPrint(&piece_buf, "@p{d} {s}", .{ i, sql_type }) catch unreachable;
        try list.appendSlice(gpa, piece);
    }
    return list.toOwnedSlice(gpa);
}

/// 追加一个 RPC 参数：`B_VARCHAR 名 + Status + TypeInfo + 值`。
fn appendParam(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, v: Value) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(gpa, name);
    defer gpa.free(units);
    try out.append(gpa, @intCast(units.len));
    for (units) |u| {
        try out.append(gpa, @truncate(u));
        try out.append(gpa, @truncate(u >> 8));
    }
    try out.append(gpa, 0); // Status：无 OUTPUT / 游标标志

    switch (v) {
        // 用「长度 0 的 INTN」表示 NULL：隐式转换到任何列类型都是 NULL
        .null => try out.appendSlice(gpa, &[_]u8{ 0x26, 8, 0 }),
        .int => |x| {
            try out.appendSlice(gpa, &[_]u8{ 0x26, 8, 8 });
            try appendU64le(gpa, out, @bitCast(x));
        },
        .boolean => |x| try out.appendSlice(gpa, &[_]u8{ 0x68, 1, 1, if (x) 1 else 0 }),
        .float => |x| {
            try out.appendSlice(gpa, &[_]u8{ 0x6D, 8, 8 });
            try appendU64le(gpa, out, @bitCast(x));
        },
        .decimal => |d| {
            try out.appendSlice(gpa, &[_]u8{ 0x6A, 17, 38, d.scale });
            try appendDecimalValue(gpa, out, d);
        },
        .datetime => |dt| {
            // DATETIME2(7)：定长 8 字节 = 5 字节时间 + 3 字节日期
            try out.appendSlice(gpa, &[_]u8{ 0x2A, 7 });
            try appendDateTime2(gpa, out, dt);
        },
        .text => |s| {
            try out.append(gpa, 0xE7); // NVARCHAR
            try appendU16le(gpa, out, 0xFFFF); // PLP
            try out.appendSlice(gpa, &default_collation);
            try appendPlpUtf16(gpa, out, s);
        },
        .blob => |bytes| {
            try out.append(gpa, 0xA5); // BIGVARBINARY
            try appendU16le(gpa, out, 0xFFFF); // PLP
            try appendPlpBytes(gpa, out, bytes);
        },
    }
}

fn appendDecimalValue(gpa: std.mem.Allocator, out: *std.ArrayList(u8), d: Decimal) !void {
    const negative = d.mantissa < 0;
    const mag: u128 = @intCast(if (negative) -d.mantissa else d.mantissa);
    const byte_len: usize = if (mag <= 0xFF) 1 else if (mag <= 0xFFFF) 2 else if (mag <= 0xFFFF_FFFF) 4 else if (mag <= 0xFFFF_FFFF_FFFF_FFFF) 8 else 16;
    try out.append(gpa, @intCast(1 + byte_len)); // 值长度 = 符号 1 字节 + magnitude
    try out.append(gpa, if (negative) 0 else 1); // Sign：1 = 正，0 = 负
    var rest = mag;
    var i: usize = 0;
    while (i < byte_len) : (i += 1) {
        try out.append(gpa, @truncate(rest & 0xFF));
        rest >>= 8;
    }
}

fn appendDateTime2(gpa: std.mem.Allocator, out: *std.ArrayList(u8), dt: DateTime) !void {
    const days = daysFromCivil(dt.year, dt.month, dt.day) + days_year1_to_1970;
    const units: u64 = (@as(u64, dt.hour) * 3600 + @as(u64, dt.minute) * 60 + dt.second) * 10_000_000 +
        dt.nanos / 100; // scale 7
    var i: usize = 0;
    while (i < 5) : (i += 1) try out.append(gpa, @truncate((units >> @intCast(i * 8)) & 0xFF));
    const d: u64 = @intCast(days);
    i = 0;
    while (i < 3) : (i += 1) try out.append(gpa, @truncate((d >> @intCast(i * 8)) & 0xFF));
}

fn appendPlpUtf16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(gpa, s);
    defer gpa.free(units);
    const byte_len: u64 = @as(u64, units.len) * 2;
    try appendU64le(gpa, out, byte_len);
    if (byte_len > 0) {
        try appendU32le(gpa, out, @intCast(byte_len));
        for (units) |u| {
            try out.append(gpa, @truncate(u));
            try out.append(gpa, @truncate(u >> 8));
        }
    }
    try appendU32le(gpa, out, 0); // 结束块
}

fn appendPlpBytes(gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try appendU64le(gpa, out, bytes.len);
    if (bytes.len > 0) {
        try appendU32le(gpa, out, @intCast(bytes.len));
        try out.appendSlice(gpa, bytes);
    }
    try appendU32le(gpa, out, 0);
}

// ── LOGIN7 组装 ────────────────────────────────────────────────────────────

/// 密码混淆：每字节先交换高低半字节，再 XOR 0xA5（MS-TDS 2.2.6.4 `Password`）。
fn obfuscatePasswordByte(b: u8) u8 {
    const swapped = ((b << 4) & 0xF0) | ((b >> 4) & 0x0F);
    return swapped ^ 0xA5;
}

/// 上面那个变换的**逆变换**：先 XOR 0xA5 再交换半字节。
/// 两个操作都是逐位（bit-permutation / 固定 XOR），所以「swap 后 XOR」的逆不是它自己 ——
/// `swap(0xA5) = 0x5A != 0xA5`，套两次不代表还原（本轮单测当场拍到）。
fn deobfuscatePasswordByte(b: u8) u8 {
    const x = b ^ 0xA5;
    return ((x << 4) & 0xF0) | ((x >> 4) & 0x0F);
}

/// 组装 LOGIN7 载荷（固定部分 94 字节 + 各字段的 UTF-16LE 文本）。
pub fn buildLogin7(gpa: std.mem.Allocator, opts: Options, packet_size: u16) ![]u8 {
    // 注意：Zig 0.17 已不接受 `[_]u8{0} ** 94` 这种数组重复写法（解析成两个 `*` 直接报错），
    // 统一用 `@memset` 清零（本轮实测）。
    var head: [94]u8 = undefined;
    @memset(&head, 0);
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);

    try appendLoginField(gpa, &head, &extra, 36, "pek-zcode", false); // HostName
    try appendLoginField(gpa, &head, &extra, 40, opts.user, false); // UserName
    try appendLoginField(gpa, &head, &extra, 44, opts.password, true); // Password
    try appendLoginField(gpa, &head, &extra, 48, opts.app_name, false); // AppName
    try appendLoginField(gpa, &head, &extra, 52, opts.host, false); // ServerName
    try appendLoginField(gpa, &head, &extra, 60, "", false); // Extension（空）
    try appendLoginField(gpa, &head, &extra, 64, "Zig-ZCode", false); // CltIntName
    try appendLoginField(gpa, &head, &extra, 68, "", false); // Language
    try appendLoginField(gpa, &head, &extra, 72, opts.database, false); // Database

    std.mem.writeInt(u32, head[4..8], tds_version_74, .big);
    std.mem.writeInt(u32, head[8..12], packet_size, .little);
    head[24] = 0x20; // OptionFlags1：fUseDB（要求服务端切到 Database 字段指定的库）
    head[25] = 0x00; // OptionFlags2：不走集成认证
    head[26] = 0x00; // TypeFlags：SQL 类型
    head[27] = 0x00; // OptionFlags3：无扩展、不改密码
    // ClientID（6 字节）留 0：仅用于服务端审计，不参与鉴权

    const total = head.len + extra.items.len;
    std.mem.writeInt(u32, head[0..4], @intCast(total), .little);

    const out = try gpa.alloc(u8, total);
    @memcpy(out[0..head.len], &head);
    if (extra.items.len > 0) @memcpy(out[head.len..], extra.items);
    return out;
}

/// 写入一个「偏移/长度」对（偏移是相对 LOGIN7 结构开头的**字节**偏移，
/// 长度是 **UTF-16 字符数**，与 MS-TDS 2.2.6.4 一致）。
fn appendLoginField(
    gpa: std.mem.Allocator,
    head: *[94]u8,
    extra: *std.ArrayList(u8),
    slot: usize,
    text: []const u8,
    obfuscate: bool,
) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(gpa, text);
    defer gpa.free(units);

    const offset: u16 = @intCast(head.len + extra.items.len);
    std.mem.writeInt(u16, head[slot..][0..2], offset, .little);
    std.mem.writeInt(u16, head[slot + 2 ..][0..2], @intCast(units.len), .little);

    for (units) |u| {
        var lo: u8 = @truncate(u);
        var hi: u8 = @truncate(u >> 8);
        if (obfuscate) {
            lo = obfuscatePasswordByte(lo);
            hi = obfuscatePasswordByte(hi);
        }
        try extra.append(gpa, lo);
        try extra.append(gpa, hi);
    }
}

fn startsWithInsert(sql: []const u8) bool {
    const s = std.mem.trimStart(u8, sql, " \t\r\n(");
    if (s.len < 6) return false;
    return std.ascii.eqlIgnoreCase(s[0..6], "insert");
}

// ── 单测（与真库无关，只验证编解码本身）────────────────────────────────────

test "TDS 密码混淆：swap→XOR 0xA5，逆变换是 XOR 0xA5→swap" {
    const plain = [_]u8{ 0x00, 0x41, 0x7F, 0xFF, 0x12 };
    for (plain) |b| {
        try std.testing.expectEqual(b, deobfuscatePasswordByte(obfuscatePasswordByte(b)));
    }
    // 'P' = 0x50 → 半字节交换 0x05 → XOR 0xA5 = 0xA0
    try std.testing.expectEqual(@as(u8, 0xA0), obfuscatePasswordByte('P'));
    // 's' = 0x73 → 0x37 ^ 0xA5 = 0x92（与抓包看到的 `sa` 密码字节一致）
    try std.testing.expectEqual(@as(u8, 0x92), obfuscatePasswordByte('s'));
}

test "TDS 日期换算：civil ↔ days 互逆，且纪元常量正确" {
    // 1970-01-01 距公元 1 年 1 月 1 日 719162 天（.NET DateTime 同口径）
    try std.testing.expectEqual(@as(i64, 719162), daysFromCivil(1970, 1, 1) - daysFromCivil(1, 1, 1));
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    // 2024-01-01：54 年 + 13 个闰日
    try std.testing.expectEqual(@as(i64, 19723), daysFromCivil(2024, 1, 1));
    // date 的 3 字节值 = 738885
    try std.testing.expectEqual(@as(i64, 738885), daysFromCivil(2024, 1, 1) + 719162);

    const cases = [_]Civil{
        .{ .y = 1, .m = 1, .d = 1 },
        .{ .y = 1900, .m = 1, .d = 1 },
        .{ .y = 1970, .m = 1, .d = 1 },
        .{ .y = 2024, .m = 2, .d = 29 },
        .{ .y = 2026, .m = 11, .d = 12 },
        .{ .y = 9999, .m = 12, .d = 31 },
    };
    for (cases) |c| {
        const days = daysFromCivil(c.y, c.m, c.d);
        const back = civilFromDays(days);
        try std.testing.expectEqual(c.y, back.y);
        try std.testing.expectEqual(c.m, back.m);
        try std.testing.expectEqual(c.d, back.d);
    }
}

test "TDS DECIMALN 解码：符号 + 小端 magnitude" {
    // numeric(10,2) = -12.34 → magnitude 1234 = 0x04D2，小端 0xD2 0x04
    const v = try decodeDecimalN(&[_]u8{ 0x00, 0xD2, 0x04 }, 2);
    try std.testing.expectEqual(@as(i128, -1234), v.decimal.mantissa);
    try std.testing.expectEqual(@as(u8, 2), v.decimal.scale);

    const pos = try decodeDecimalN(&[_]u8{ 0x01, 0x2A }, 0);
    try std.testing.expectEqual(@as(i128, 42), pos.decimal.mantissa);
}

test "TDS datetime / smalldatetime 解码" {
    // datetime：days=45290（2024-01-01 距 1900-01-01 = 19723 + 25567）、ticks=0
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 45290, .little);
    std.mem.writeInt(u32, buf[4..8], 0, .little);
    const dt = try decodeDateTime(&buf);
    try std.testing.expectEqual(@as(i32, 2024), dt.datetime.year);
    try std.testing.expectEqual(@as(u8, 1), dt.datetime.month);
    try std.testing.expectEqual(@as(u8, 1), dt.datetime.day);

    // smalldatetime：days=45290、minutes=13*60+45
    var sb: [4]u8 = undefined;
    std.mem.writeInt(u16, sb[0..2], 45290, .little);
    std.mem.writeInt(u16, sb[2..4], 13 * 60 + 45, .little);
    const sdt = try decodeSmallDateTime(&sb);
    try std.testing.expectEqual(@as(u8, 13), sdt.datetime.hour);
    try std.testing.expectEqual(@as(u8, 45), sdt.datetime.minute);
}

test "TDS datetime2 参数编码与解码互逆" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    const dt = DateTime{ .year = 2026, .month = 11, .day = 12, .hour = 8, .minute = 30, .second = 15, .nanos = 123_456_700 };
    try appendDateTime2(a, &out, dt);
    try std.testing.expectEqual(@as(usize, 8), out.items.len);

    const back = try decodeDateTime2(out.items, 7);
    try std.testing.expectEqual(dt.year, back.datetime.year);
    try std.testing.expectEqual(dt.month, back.datetime.month);
    try std.testing.expectEqual(dt.day, back.datetime.day);
    try std.testing.expectEqual(dt.hour, back.datetime.hour);
    try std.testing.expectEqual(dt.minute, back.datetime.minute);
    try std.testing.expectEqual(dt.second, back.datetime.second);
    try std.testing.expectEqual(@as(u32, 123_456_700), back.datetime.nanos);
}

test "TDS 参数声明串与 TypeInfo 一一对应" {
    const a = std.testing.allocator;
    const params = [_]Value{
        .{ .int = 7 },
        .{ .text = "abc" },
        .null,
        .{ .decimal = .{ .mantissa = 1234, .scale = 2 } },
    };
    const decl = try buildParamDecls(a, &params);
    defer a.free(decl);
    try std.testing.expectEqualStrings("@p0 bigint,@p1 nvarchar(max),@p2 bigint,@p3 decimal(38,2)", decl);
}

test "TDS GUID 按 SQL Server 的混合字节序格式化" {
    const a = std.testing.allocator;
    const bytes = [_]u8{ 0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const v = try decodeGuid(&bytes, a);
    try std.testing.expectEqualStrings("00112233-4455-6677-8899-AABBCCDDEEFF", v.text);
    a.free(v.text);
}

test "TDS TypeInfo：nvarchar(max) 走 PLP、varchar(50) 走 2 字节长度" {
    // 0xE7 + maxLen(0xFFFF) + collation(5B)
    const plp_bytes = [_]u8{ 0xE7, 0xFF, 0xFF, 0x09, 0x04, 0xD0, 0x00, 0x34 };
    var p1 = Reader{ .buf = &plp_bytes };
    const ti1 = try readTypeInfo(&p1);
    try std.testing.expectEqual(LenKind.plp, ti1.len_kind);
    try std.testing.expectEqual(@as(u32, 0xFFFF), ti1.max_len);

    // 0xA7 + maxLen(50) + collation(5B)
    const var_bytes = [_]u8{ 0xA7, 0x32, 0x00, 0x09, 0x04, 0xD0, 0x00, 0x34 };
    var p2 = Reader{ .buf = &var_bytes };
    const ti2 = try readTypeInfo(&p2);
    try std.testing.expectEqual(LenKind.ushort_len, ti2.len_kind);
    try std.testing.expectEqual(@as(u32, 50), ti2.max_len);

    // decimal(10,2)：0x6A + maxLen(5) + precision(10) + scale(2)
    const dec_bytes = [_]u8{ 0x6A, 0x05, 0x0A, 0x02 };
    var p3 = Reader{ .buf = &dec_bytes };
    const ti3 = try readTypeInfo(&p3);
    try std.testing.expectEqual(@as(u8, 10), ti3.precision);
    try std.testing.expectEqual(@as(u8, 2), ti3.scale);
}

test "TDS LOGIN7 载荷：长度、版本、字段偏移与密码混淆" {
    const a = std.testing.allocator;
    const payload = try buildLogin7(a, .{
        .host = "127.0.0.1",
        .user = "sa",
        .password = "P@ss",
        .database = "master",
        .app_name = "zcode",
    }, 4096);
    defer a.free(payload);

    try std.testing.expectEqual(@as(u32, @intCast(payload.len)), std.mem.readInt(u32, payload[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x7400_0004), std.mem.readInt(u32, payload[4..8], .big));
    try std.testing.expectEqual(@as(u32, 4096), std.mem.readInt(u32, payload[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0x20), payload[24]);

    // UserName：2 个字符，首个 UTF-16 码元是 's'
    const user_off: usize = std.mem.readInt(u16, payload[40..42], .little);
    const user_len: usize = std.mem.readInt(u16, payload[42..44], .little);
    try std.testing.expectEqual(@as(usize, 2), user_len);
    try std.testing.expectEqual(@as(u16, 's'), std.mem.readInt(u16, payload[user_off..][0..2], .little));

    // 密码解密后应等于原文
    const pw_off: usize = std.mem.readInt(u16, payload[44..46], .little);
    const pw_len: usize = std.mem.readInt(u16, payload[46..48], .little);
    try std.testing.expectEqual(@as(usize, 4), pw_len);
    const expect_text = "P@ss";
    for (0..pw_len) |i| {
        try std.testing.expectEqual(expect_text[i], deobfuscatePasswordByte(payload[pw_off + i * 2]));
    }

    const db_off: usize = std.mem.readInt(u16, payload[72..74], .little);
    const db_len: usize = std.mem.readInt(u16, payload[74..76], .little);
    try std.testing.expectEqual(@as(usize, 6), db_len);
    try std.testing.expectEqual(@as(u16, 'm'), std.mem.readInt(u16, payload[db_off..][0..2], .little));
}
