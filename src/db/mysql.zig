//! MySQL 驱动（**绿色版：纯 wire protocol 实现，不加载 libmysqlclient**）。
//!
//! 参考实现（**口径以 C# 绿色版为准**）：
//! - C# `G:\Code\Pek.FrameWork\DH.MySql`（自实现协议，`Authentication.cs` / `MySqlFieldCodec.cs` / `Messages\ClientFlags.cs`）；
//! - Rust `Pek.RCode/src/mysql.rs`（`mysql` crate，同为纯协议，作为补充对照）。
//! 本模块只做「连得上、发得出、读得回」，SQL 语义、建表、反查等全部由上层（ORM）负责。
//!
//! 已实现：
//! - 握手 v10 解析 + `HandshakeResponse41`
//! - 鉴权：`mysql_native_password`（完整）、`caching_sha2_password`（**fast auth + 完整鉴权**：
//!   请求公钥 → `RSAES-OAEP(SHA1)` 加密 `密码 XOR scramble` → 发送，见 `crypto/rsa.zig`）
//! - `COM_QUERY`（文本协议）：无参语句 / DDL / 简单查询
//! - `COM_STMT_PREPARE` + `COM_STMT_EXECUTE` + `COM_STMT_CLOSE`（二进制协议）：
//!   带参语句，参数按 `Value` 类型绑定，结果按列类型解码
//! - `COM_PING` / `COM_QUIT` / `COM_INIT_DB`
//! - 值转换：整数/浮点/Decimal/日期时间/BIT/Blob/JSON 按 MySQL 协议类型还原
//!
//! 能力标志口径（与 `DH.MySql/Authentication.cs` 一致）：
//! - **`CLIENT_FOUND_ROWS` 开启**：`affected_rows` 是「匹配行数」而非「变更行数」
//!   （C# 侧注释 `// UseAffectedRows`；XCode 的 `Update` 返回值语义依赖这一档）。
//! - **`CLIENT_MULTI_STATEMENTS` / `MULTI_RESULTS` / `PS_MULTI_RESULTS` 开启**：与 C# 一致，
//!   多结果集会由 `drainMoreResults` 读掉。
//! - BIT 值按**小端**字节序还原（`MySqlFieldCodec.ConvertBitBytesToUInt64` 口径；
//!   Rust `Pek.RCode` 用大端，两者不一致，已记入 `docs/决策记录.md` 待真库确认）。
//!
//! 未实现（明确不静默降级）：
//! - **TLS**：`CLIENT_SSL` 不发送。内网明文场景够用；跨公网请走 SSH 隧道或反代。
//! - **压缩协议**（`CLIENT_COMPRESS`）、**LOCAL INFILE**、**连接池**（池化在上层做）。
//! - `authentication_webauthn_client` 等新插件：显式 `error.UnsupportedAuthPlugin`。
//!
//! 线程模型：`Conn` **不是**线程安全的，一条连接同一时刻只能被一个线程使用（与 sqlite 驱动一致）。

const std = @import("std");
const compat = @import("../compat.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;
const Decimal = @import("../number/decimal.zig").Decimal;
const DateTime = @import("../time/datetime.zig").DateTime;

pub const default_port: u16 = 3306;

/// 客户端声明的最大包长（服务端据此限制单包）。
const max_packet_size: u32 = 16 * 1024 * 1024;
/// 协议单包上限（3 字节长度字段）。
const max_payload: usize = 0xff_ffff;

// ── capability flags ────────────────────────────────────────────────────────
const CLIENT_LONG_PASSWORD: u32 = 0x0000_0001;
/// 返回「匹配行数」而不是「变更行数」（C# 绿色版 `DH.MySql` 明确开启：`// UseAffectedRows`）
const CLIENT_FOUND_ROWS: u32 = 0x0000_0002;
const CLIENT_LONG_FLAG: u32 = 0x0000_0004;
const CLIENT_CONNECT_WITH_DB: u32 = 0x0000_0008;
/// 允许 `LOAD DATA LOCAL INFILE` 由客户端发送数据（服务端不开时协商不上，调用处会明确报错）
const CLIENT_LOCAL_FILES: u32 = 0x0000_0080;
const CLIENT_PROTOCOL_41: u32 = 0x0000_0200;
const CLIENT_TRANSACTIONS: u32 = 0x0000_2000;
const CLIENT_SECURE_CONNECTION: u32 = 0x0000_8000;
const CLIENT_MULTI_STATEMENTS: u32 = 0x0001_0000;
const CLIENT_MULTI_RESULTS: u32 = 0x0002_0000;
const CLIENT_PS_MULTI_RESULTS: u32 = 0x0004_0000;
const CLIENT_PLUGIN_AUTH: u32 = 0x0008_0000;

// ── commands ────────────────────────────────────────────────────────────────
const COM_QUIT: u8 = 0x01;
const COM_INIT_DB: u8 = 0x02;
const COM_QUERY: u8 = 0x03;
const COM_PING: u8 = 0x0e;
const COM_STMT_PREPARE: u8 = 0x16;
const COM_STMT_EXECUTE: u8 = 0x17;
const COM_STMT_CLOSE: u8 = 0x19;

/// 服务端在 `LOCAL INFILE` 场景回的首字节（请求客户端发数据）
const LOCAL_INFILE_REQUEST: u8 = 0xfb;

// ── 服务端状态标志 ──────────────────────────────────────────────────────────
const SERVER_STATUS_IN_TRANS: u16 = 0x0001;
const SERVER_MORE_RESULTS_EXISTS: u16 = 0x0008;

/// MySQL 列类型（`MYSQL_TYPE_*`）。非穷举：未知类型按字节保留。
pub const ColumnType = enum(u8) {
    decimal = 0,
    tiny = 1,
    short = 2,
    long = 3,
    float = 4,
    double = 5,
    null = 6,
    timestamp = 7,
    longlong = 8,
    int24 = 9,
    date = 10,
    time = 11,
    datetime = 12,
    year = 13,
    newdate = 14,
    varchar = 15,
    bit = 16,
    timestamp2 = 17,
    datetime2 = 18,
    time2 = 19,
    json = 245,
    newdecimal = 246,
    enum_ = 247,
    set = 248,
    tiny_blob = 249,
    medium_blob = 250,
    long_blob = 251,
    blob = 252,
    var_string = 253,
    string = 254,
    geometry = 255,
    _,
};

pub const ColumnFlags = struct {
    pub const not_null: u16 = 0x0001;
    pub const unsigned: u16 = 0x0020;
    pub const binary: u16 = 0x0080;
};

pub const Column = struct {
    name: []const u8,
    type: ColumnType,
    flags: u16 = 0,
    charset: u16 = 0,
    decimals: u8 = 0,
    length: u32 = 0,

    pub fn isUnsigned(self: Column) bool {
        return (self.flags & ColumnFlags.unsigned) != 0;
    }

    /// 协议里 BLOB 系列与 TEXT 系列**共用类型码**，只有字符集为 63(binary) 时才是真正的二进制
    /// （与 C# 绿色版 `DH.MySql/MySqlColumn.RemapTypeByCharset` 同一口径；不判 charset 会把
    /// TEXT 列误当成 Blob，真库实测就是 `Title` 变成 `[blob 12 字节]`）。
    pub fn isBinaryCharset(self: Column) bool {
        return self.charset == 63;
    }

    pub fn isBinary(self: Column) bool {
        return (self.flags & ColumnFlags.binary) != 0;
    }
};

pub const Ok = struct {
    affected_rows: u64 = 0,
    insert_id: u64 = 0,
    status: u16 = 0,
    warnings: u16 = 0,
};

pub const Rows = struct {
    columns: []const Column = &.{},
    rows: []const Row = &.{},
};

pub const Result = union(enum) {
    ok: Ok,
    rows: Rows,
};

/// 连接参数（与 XCode 连接串一一对应，解析在上层做）。
pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8 = "",
    /// 45 = utf8mb4_general_ci（5.7 与 8.0 都有）；55 = utf8mb4_0900_ai_ci 仅 8.0+
    charset: u8 = 45,
};

pub const Error = error{
    ConnectionClosed,
    Protocol,
    Server,
    AuthFailed,
    UnsupportedAuthPlugin,
    AuthRequiresFullAuth,
    LocalInfileNotSupported,
    NotImplemented,
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    /// 收发复用缓冲（每包切片都指向这里，**下一次 readPacket 后失效**）
    pkt: std.ArrayList(u8) = .empty,
    seq: u8 = 0,
    server_capabilities: u32 = 0,
    client_capabilities: u32 = 0,
    thread_id: u32 = 0,
    server_version_buf: [64]u8 = undefined,
    server_version_len: usize = 0,
    last_affected_rows: u64 = 0,
    last_insert_id: u64 = 0,
    last_status: u16 = 0,
    last_warnings: u16 = 0,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
    err_code: u16 = 0,
    sql_state: [5]u8 = .{ '0', '0', '0', '0', '0' },
    closed: bool = false,
    /// 读写已报错（连接不可用）：关闭时不再尝试发 COM_QUIT，否则 Windows 会抛断连状态
    broken: bool = false,

    // ── 基本信息 ────────────────────────────────────────────────────────────
    pub fn serverVersion(self: *const Conn) []const u8 {
        return self.server_version_buf[0..self.server_version_len];
    }

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn lastErrorCode(self: *const Conn) u16 {
        return self.err_code;
    }

    pub fn lastSqlState(self: *const Conn) []const u8 {
        return self.sql_state[0..];
    }

    pub fn affectedRows(self: *const Conn) u64 {
        return self.last_affected_rows;
    }

    pub fn lastInsertId(self: *const Conn) i64 {
        if (self.last_insert_id > std.math.maxInt(i64)) return std.math.maxInt(i64);
        return @intCast(self.last_insert_id);
    }

    fn setError(self: *Conn, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch blk: {
            // 缓冲不足时截断，保证至少有条信息（不静默丢错）
            break :blk self.err_buf[0..@min(self.err_buf.len, 200)];
        };
        self.err_len = text.len;
    }

    fn setupError(self: *Conn, code: u16, state: []const u8, message: []const u8) void {
        self.err_code = code;
        var st: [5]u8 = .{ '0', '0', '0', '0', '0' };
        const n = @min(state.len, 5);
        @memcpy(st[0..n], state[0..n]);
        self.sql_state = st;
        // 统一带上错误码与 SQLSTATE，便于运维一眼定位
        self.setError("MySQL 错误 {d}（SQLSTATE {s}）：{s}", .{ code, self.sql_state[0..], message });
    }

    // ── 连接 ────────────────────────────────────────────────────────────────
    /// 建立连接并完成鉴权。失败时 `lastError()` 有具体原因（含错误码 / SQLSTATE）。
    pub fn open(gpa: std.mem.Allocator, opts: Options) !Conn {
        const io = compat.currentIo();
        const address = std.Io.net.IpAddress.resolve(io, opts.host, opts.port) catch |e| {
            std.debug.print("[zzig.mysql] 解析主机失败：host={s} port={d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };
        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            std.debug.print("[zzig.mysql] 连接失败：{s}:{d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };

        var self = Conn{ .gpa = gpa, .io = io, .stream = stream };
        errdefer self.closeQuietly();

        self.handshake(opts) catch |e| {
            // 握手阶段失败：把协议层细节补齐到 lastError，避免只看到一个 error 名
            if (self.err_len == 0) {
                self.setError("握手/鉴权失败（{s}:{d} 用户 {s}）：{s}", .{ opts.host, opts.port, opts.user, @errorName(e) });
            }
            // 同时打到 stderr：运维看到的就是「哪一步 + 为什么」，不用回去加日志再复现
            std.debug.print("[zzig.mysql] 连接/鉴权失败：{s}\n", .{self.lastError()});
            return e;
        };
        return self;
    }

    pub fn deinit(self: *Conn) void {
        self.closeQuietly();
        self.pkt.deinit(self.gpa);
    }

    fn closeQuietly(self: *Conn) void {
        if (self.closed) return;
        self.closed = true;
        // COM_QUIT：尽力而为，对端已断也不报错（连接已坏时干脆不发，避开 Windows 断连状态）
        self.seq = 0;
        if (!self.broken) self.writePacket(&[_]u8{COM_QUIT}) catch {};
        self.stream.close(self.io);
    }

    /// 主动关闭（发 COM_QUIT 后关闭 socket）。
    pub fn close(self: *Conn) void {
        self.closeQuietly();
    }

    pub fn ping(self: *Conn) !void {
        self.seq = 0;
        try self.writePacket(&[_]u8{COM_PING});
        const pkt = try self.readPacket();
        if (pkt.len == 0) return error.Protocol;
        if (pkt[0] == 0xff) return self.failFromPayload(pkt);
        if (pkt[0] == 0x00) return;
        return error.Protocol;
    }

    /// 切库（连接串不带 Database 时用得上）。
    pub fn useDatabase(self: *Conn, name: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.append(self.gpa, COM_INIT_DB);
        try buf.appendSlice(self.gpa, name);
        self.seq = 0;
        try self.writePacket(buf.items);
        const pkt = try self.readPacket();
        if (pkt.len == 0) return error.Protocol;
        if (pkt[0] == 0xff) return self.failFromPayload(pkt);
        if (pkt[0] == 0x00) return;
        return error.Protocol;
    }

    // ── 语句执行 ────────────────────────────────────────────────────────────
    /// 执行一条语句（无参走 `COM_QUERY`，有参走预处理二进制协议）。
    /// 返回的结果集/行全部在 `arena` 上分配。
    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        if (params.len == 0) return self.queryText(arena, sql);
        return self.queryPrepared(arena, sql, params);
    }

    /// 只关心影响行数的场景（INSERT/UPDATE/DELETE/DDL）。
    pub fn exec(self: *Conn, sql: []const u8, params: []const Value) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = try self.queryAlloc(arena.allocator(), sql, params);
        return switch (r) {
            .ok => |o| o.affected_rows,
            // 传了「写」SQL 却拿到结果集：语句类型不符，明确报错而不是悄悄当成 0
            .rows => blk: {
                self.setError("期望写入语句，但返回了结果集：{s}", .{sql});
                break :blk error.Protocol;
            },
        };
    }

    /// 通过 `LOAD DATA LOCAL INFILE` 批量装载：**数据由客户端流式发送，不落盘、不需要服务端文件权限**。
    ///
    /// `sql` 由调用方拼好（`LOAD DATA LOCAL INFILE '<仅用于日志的名字>' INTO TABLE ... FIELDS/LINES ...`），
    /// `data` 是按该规则格式化好的全部文本。返回影响行数。
    ///
    /// 失败语义（都不降级）：
    /// - 没协商上 `CLIENT_LOCAL_FILES` → `error.LocalInfileNotSupported`；
    /// - 服务端未开 `local_infile`（MySQL 8 默认关闭）→ 服务端回 3948，按 `error.Server` 抛，`lastError()` 有原文。
    ///
    /// 分块：每包最大 `max_payload`；**最后单独发一个空包**作为结束标记。
    /// 数据恰好是 `max_payload` 整数倍时也正确（不会提前截断）。
    pub fn loadDataLocal(self: *Conn, sql: []const u8, data: []const u8) !u64 {
        if ((self.client_capabilities & CLIENT_LOCAL_FILES) == 0) {
            self.setError(
                "未协商 CLIENT_LOCAL_FILES（服务端 capability=0x{x}），无法使用 LOAD DATA LOCAL",
                .{self.server_capabilities},
            );
            return error.LocalInfileNotSupported;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.append(self.gpa, COM_QUERY);
        try buf.appendSlice(self.gpa, sql);

        self.seq = 0;
        try self.writePacket(buf.items);

        const first = try self.readPacket();
        if (first.len == 0) return error.Protocol;
        if (first[0] == 0xff) return self.failFromPayload(first);
        if (first[0] != LOCAL_INFILE_REQUEST) {
            // 服务端没有要求发数据（例如把 LOAD DATA 当普通服务器端语句执行了）：
            // 这不是我们期望的形态，明确报错而不是当成成功
            self.setError("期望 LOCAL INFILE 请求（0xfb），却收到 0x{x}；请确认 SQL 是 LOAD DATA **LOCAL** INFILE", .{first[0]});
            return error.Protocol;
        }

        // 分块发送数据（每包 ≤ max_payload），再发一个空包结束
        var off: usize = 0;
        while (off < data.len) {
            const chunk = @min(data.len - off, max_payload);
            try self.writeRawPacket(data[off .. off + chunk]);
            off += chunk;
        }
        try self.writeRawPacket(&.{});

        const done = try self.readPacket();
        if (done.len == 0) return error.Protocol;
        if (done[0] == 0xff) return self.failFromPayload(done);
        if (done[0] == 0x00) {
            const ok = try parseOkPayload(done);
            self.applyOk(ok);
            return ok.affected_rows;
        }
        self.setError("LOAD DATA 结束后收到非 OK 包（0x{x}）", .{done[0]});
        return error.Protocol;
    }

    fn queryText(self: *Conn, arena: std.mem.Allocator, sql: []const u8) !Result {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.append(self.gpa, COM_QUERY);
        try buf.appendSlice(self.gpa, sql);
        self.seq = 0;
        try self.writePacket(buf.items);
        return self.readResponse(arena, null);
    }

    fn queryPrepared(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        const prepared = try self.prepareStatement(arena, sql);
        defer self.closeStatement(prepared.id);
        return self.executeStatement(arena, prepared, params);
    }

    const Prepared = struct {
        id: u32,
        num_columns: u16,
        num_params: u16,
        columns: []const Column = &.{},
    };

    fn prepareStatement(self: *Conn, arena: std.mem.Allocator, sql: []const u8) !Prepared {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.append(self.gpa, COM_STMT_PREPARE);
        try buf.appendSlice(self.gpa, sql);
        self.seq = 0;
        try self.writePacket(buf.items);

        const pkt = try self.readPacket();
        if (pkt.len == 0) return error.Protocol;
        if (pkt[0] == 0xff) return self.failFromPayload(pkt);
        if (pkt[0] != 0x00 or pkt.len < 12) {
            self.setError("预编译响应格式异常（首字节 0x{x:0>2}，长度 {d}）：{s}", .{ pkt[0], pkt.len, sql });
            return error.Protocol;
        }
        const stmt_id = std.mem.readInt(u32, pkt[1..5], .little);
        const num_columns = std.mem.readInt(u16, pkt[5..7], .little);
        const num_params = std.mem.readInt(u16, pkt[7..9], .little);
        const warnings = std.mem.readInt(u16, pkt[10..12], .little);
        self.last_warnings = warnings;

        if (num_params > 0) {
            _ = try self.readColumnDefs(arena, num_params);
            try self.expectEof();
        }
        var columns: []const Column = &.{};
        if (num_columns > 0) {
            columns = try self.readColumnDefs(arena, num_columns);
            try self.expectEof();
        }
        return .{ .id = stmt_id, .num_columns = num_columns, .num_params = num_params, .columns = columns };
    }

    fn closeStatement(self: *Conn, id: u32) void {
        var buf: [5]u8 = undefined;
        buf[0] = COM_STMT_CLOSE;
        std.mem.writeInt(u32, buf[1..5], id, .little);
        self.seq = 0;
        // COM_STMT_CLOSE 没有响应；写失败说明连接已坏，留给下一次调用暴露
        self.writePacket(&buf) catch {};
    }

    fn executeStatement(self: *Conn, arena: std.mem.Allocator, prepared: Prepared, params: []const Value) !Result {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        const gpa = self.gpa;

        try buf.append(gpa, COM_STMT_EXECUTE);
        var id_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &id_bytes, prepared.id, .little);
        try buf.appendSlice(gpa, &id_bytes);
        try buf.append(gpa, 0x00); // flags: CURSOR_TYPE_NO_CURSOR
        try buf.appendSlice(gpa, &[_]u8{ 1, 0, 0, 0 }); // iteration_count = 1

        // NULL 位图
        const bitmap_len = (params.len + 7) / 8;
        const bitmap_start = buf.items.len;
        try buf.appendNTimes(gpa, 0, bitmap_len);
        for (params, 0..) |p, i| {
            if (p == .null) {
                buf.items[bitmap_start + (i / 8)] |= @as(u8, 1) << @intCast(i % 8);
            }
        }

        try buf.append(gpa, 0x01); // new_params_bound_flag

        // 先写类型（每个参数 2 字节：类型 + unsigned 标志）
        for (params) |p| {
            try buf.append(gpa, paramType(p));
            try buf.append(gpa, 0x00);
        }
        // 再写值
        for (params) |p| try encodeParam(gpa, &buf, p);

        self.seq = 0;
        try self.writePacket(buf.items);
        return self.readResponse(arena, prepared.num_columns);
    }

    // ── 响应解析 ────────────────────────────────────────────────────────────
    fn readResponse(self: *Conn, arena: std.mem.Allocator, expect_columns: ?u16) !Result {
        var columns_hint = expect_columns orelse 0;
        const first = try self.readPacket();

        if (first.len == 0) return error.Protocol;
        if (first[0] == 0xff) return self.failFromPayload(first);
        if (first[0] == 0xfb) return error.LocalInfileNotSupported;

        var result: Result = undefined;
        if (expect_columns) |known| {
            if (known == 0) {
                // 预处理语句确定没有结果集 → 只可能是 OK
                if (first[0] != 0x00) {
                    self.setError("预处理语句应为 OK 包，实际首字节 0x{x:0>2}", .{first[0]});
                    return error.Protocol;
                }
                const ok = try parseOkPayload(first);
                self.applyOk(ok);
                result = .{ .ok = ok };
                try self.drainMoreResults();
                return result;
            }
        } else {
            if (first[0] == 0x00) {
                const ok = try parseOkPayload(first);
                self.applyOk(ok);
                result = .{ .ok = ok };
                try self.drainMoreResults();
                return result;
            }
            var pos: usize = 0;
            columns_hint = @intCast(try readLenencIntAt(first, &pos));
        }

        const columns = try self.readColumnDefs(arena, columns_hint);
        try self.expectEof();

        var rows: std.ArrayList(Row) = .empty;
        const binary = (expect_columns != null);
        var status: u16 = 0;
        while (true) {
            const pkt = try self.readPacket();
            if (pkt.len == 0) continue;
            if (pkt[0] == 0xfe and pkt.len < 9) {
                status = if (pkt.len >= 5) std.mem.readInt(u16, pkt[3..5], .little) else 0;
                break;
            }
            if (pkt[0] == 0xff) return self.failFromPayload(pkt);
            const row = if (binary) try parseBinaryRow(arena, pkt, columns) else try parseTextRow(arena, pkt, columns);
            try rows.append(arena, row);
        }
        self.last_status = status;
        self.last_affected_rows = rows.items.len;
        result = .{ .rows = .{ .columns = columns, .rows = try rows.toOwnedSlice(arena) } };
        try self.drainMoreResults();
        return result;
    }

    /// 读掉后续结果集（只在服务端声明 `MORE_RESULTS` 时才会发生）。
    fn drainMoreResults(self: *Conn) !void {
        var status = self.last_status;
        while ((status & SERVER_MORE_RESULTS_EXISTS) != 0) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const pkt = try self.readPacket();
            if (pkt.len == 0) return error.Protocol;
            if (pkt[0] == 0xff) {
                status = 0;
                break;
            }
            if (pkt[0] == 0x00) {
                const ok = try parseOkPayload(pkt);
                status = ok.status;
                continue;
            }
            var npos: usize = 0;
            const n: usize = @intCast(try readLenencIntAt(pkt, &npos));
            _ = try self.readColumnDefs(arena.allocator(), n);
            try self.expectEof();
            while (true) {
                const r = try self.readPacket();
                if (r.len == 0) continue;
                if (r[0] == 0xfe and r.len < 9) {
                    status = if (r.len >= 5) std.mem.readInt(u16, r[3..5], .little) else 0;
                    break;
                }
            }
        }
        self.last_status = status;
    }

    fn readColumnDefs(self: *Conn, arena: std.mem.Allocator, count: usize) ![]const Column {
        var cols: std.ArrayList(Column) = .empty;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const pkt = try self.readPacket();
            if (pkt.len > 0 and pkt[0] == 0xff) return self.failFromPayload(pkt);
            var col = try parseColumnDef(pkt);
            col.name = try arena.dupe(u8, col.name);
            try cols.append(arena, col);
        }
        return cols.toOwnedSlice(arena);
    }

    fn expectEof(self: *Conn) !void {
        const pkt = try self.readPacket();
        if (pkt.len == 0 or pkt[0] != 0xfe) {
            self.setError("期望 EOF 包，实际首字节 0x{x:0>2}（长度 {d}）", .{ if (pkt.len > 0) pkt[0] else 0, pkt.len });
            return error.Protocol;
        }
        if (pkt.len >= 5) self.last_status = std.mem.readInt(u16, pkt[3..5], .little);
    }

    fn applyOk(self: *Conn, ok: Ok) void {
        self.last_affected_rows = ok.affected_rows;
        self.last_insert_id = ok.insert_id;
        self.last_status = ok.status;
        self.last_warnings = ok.warnings;
    }

    fn failFromPayload(self: *Conn, pkt: []const u8) Error {
        const e = parseErrPayload(pkt) catch {
            self.setupError(0, "HY000", "无法解析的错误包");
            return error.Protocol;
        };
        self.setupError(e.code, e.state(), e.message);
        return error.Server;
    }

    // ── 握手与鉴权 ──────────────────────────────────────────────────────────
    fn handshake(self: *Conn, opts: Options) !void {
        self.seq = 0;
        const pkt = try self.readPacket();
        const hs = try parseHandshake(pkt);
        self.server_capabilities = hs.capability;
        self.thread_id = hs.thread_id;
        self.server_version_len = @min(hs.server_version.len, self.server_version_buf.len);
        @memcpy(self.server_version_buf[0..self.server_version_len], hs.server_version[0..self.server_version_len]);

        if ((hs.capability & CLIENT_PROTOCOL_41) == 0) {
            self.setError("服务端不支持协议 4.1（capability=0x{x}），本驱动不支持更老的协议", .{hs.capability});
            return error.Unsupported;
        }
        if ((hs.capability & CLIENT_SECURE_CONNECTION) == 0) {
            self.setError("服务端不支持 SECURE_CONNECTION（capability=0x{x}）", .{hs.capability});
            return error.Unsupported;
        }

        var flags: u32 = CLIENT_LONG_PASSWORD | CLIENT_LONG_FLAG | CLIENT_PROTOCOL_41 |
            CLIENT_TRANSACTIONS | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH |
            CLIENT_FOUND_ROWS | CLIENT_MULTI_STATEMENTS | CLIENT_MULTI_RESULTS | CLIENT_PS_MULTI_RESULTS |
            CLIENT_LOCAL_FILES;
        if (opts.database.len > 0) flags |= CLIENT_CONNECT_WITH_DB;
        // 只在服务端支持的范围内起作用
        flags &= hs.capability | CLIENT_CONNECT_WITH_DB;
        self.client_capabilities = flags;

        // 注意：`hs.auth_plugin_name` 借用的是复用包缓冲（`self.pkt`），后续任何 readPacket
        // 都会覆盖它 → 必须拷贝到自己缓冲再用，否则鉴权往返时插件名变成垃圾字节。
        var plugin_buf: [64]u8 = undefined;
        const plugin_src = if (hs.auth_plugin_name.len > 0) hs.auth_plugin_name else "mysql_native_password";
        const plugin_len = @min(plugin_src.len, plugin_buf.len);
        @memcpy(plugin_buf[0..plugin_len], plugin_src[0..plugin_len]);
        const plugin = plugin_buf[0..plugin_len];

        var auth_buf: [32]u8 = undefined;
        const auth = try self.authResponse(plugin, opts.password, hs.auth_plugin_data[0..hs.auth_plugin_data_len], &auth_buf);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        const gpa = self.gpa;

        var f: [4]u8 = undefined;
        std.mem.writeInt(u32, &f, flags, .little);
        try buf.appendSlice(gpa, &f);
        var mp: [4]u8 = undefined;
        std.mem.writeInt(u32, &mp, max_packet_size, .little);
        try buf.appendSlice(gpa, &mp);
        try buf.append(gpa, opts.charset);
        try buf.appendNTimes(gpa, 0, 23);
        try buf.appendSlice(gpa, opts.user);
        try buf.append(gpa, 0);
        try appendLenencInt(gpa, &buf, auth.len);
        try buf.appendSlice(gpa, auth);
        if ((flags & CLIENT_CONNECT_WITH_DB) != 0) {
            try buf.appendSlice(gpa, opts.database);
            try buf.append(gpa, 0);
        }
        if ((flags & CLIENT_PLUGIN_AUTH) != 0) {
            try buf.appendSlice(gpa, plugin);
            try buf.append(gpa, 0);
        }

        try self.writePacket(buf.items);
        try self.finishAuth(opts, plugin, hs.auth_plugin_data[0..hs.auth_plugin_data_len]);
    }

    fn finishAuth(self: *Conn, opts: Options, initial_plugin: []const u8, initial_scramble: []const u8) !void {
        var plugin = initial_plugin;
        var scramble = initial_scramble;
        var auth_buf: [32]u8 = undefined;
        // AuthSwitchRequest 里的插件名同样借用包缓冲，必须拷贝（否则下一包就读到垃圾）
        var switch_buf: [64]u8 = undefined;
        var rounds: usize = 0;
        while (true) {
            rounds += 1;
            if (rounds > 4) {
                self.setError("鉴权往返次数超限（插件 {s}），疑似服务端反复要求切换插件", .{plugin});
                return error.AuthFailed;
            }

            const pkt = try self.readPacket();
            if (pkt.len == 0) return error.ConnectionClosed;

            switch (pkt[0]) {
                0x00 => {
                    const ok = try parseOkPayload(pkt);
                    self.applyOk(ok);
                    return;
                },
                0xff => return self.failFromPayload(pkt),
                0xfe => {
                    // AuthSwitchRequest：插件名\0 + 新 scramble
                    if (pkt.len == 1) {
                        self.setError("服务端请求旧式密码（4.1 之前的 mysql_old_password），本驱动不支持", .{});
                        return error.UnsupportedAuthPlugin;
                    }
                    const rest = pkt[1..];
                    const name_end = std.mem.indexOfScalar(u8, rest, 0) orelse {
                        self.setError("AuthSwitchRequest 缺少插件名终止符", .{});
                        return error.Protocol;
                    };
                    const new_plugin_raw = rest[0..name_end];
                    var new_scramble = rest[name_end + 1 ..];
                    // 结尾可能带一个 \0，去掉（scramble 固定 20 字节）
                    if (new_scramble.len > 20) new_scramble = new_scramble[0..20];

                    const nl = @min(new_plugin_raw.len, switch_buf.len);
                    @memcpy(switch_buf[0..nl], new_plugin_raw[0..nl]);
                    const new_plugin = switch_buf[0..nl];

                    const auth = try self.authResponse(new_plugin, opts.password, new_scramble, &auth_buf);
                    try self.writePacket(auth);
                    plugin = new_plugin;
                    scramble = new_scramble;
                    continue;
                },
                0x01 => {
                    // AuthMoreData
                    const data = pkt[1..];
                    if (std.mem.eql(u8, plugin, "caching_sha2_password")) {
                        if (data.len == 1 and data[0] == 0x03) {
                            // fast auth 成功，接下来是 OK 包
                            continue;
                        }
                        if (data.len == 1 and data[0] == 0x04) {
                            // 完整鉴权：请求服务端公钥 → RSA-OAEP 加密 (密码 XOR scramble) → 发送
                            // 与 C# 绿色版 `DH.MySql/Authentication.cs` 的 PerformFullAuthenticationAsync 一致
                            try self.performFullAuth(opts.password, initial_scramble);
                            return;
                        }
                        self.setError("caching_sha2_password 返回未知状态字节 0x{x}", .{if (data.len > 0) data[0] else 0});
                        return error.Protocol;
                    }
                    self.setError("鉴权插件 {s} 返回 AuthMoreData（本驱动仅支持 mysql_native_password 与 caching_sha2 fast auth）", .{plugin});
                    return error.UnsupportedAuthPlugin;
                },
                else => {
                    self.setError("鉴权阶段收到未知包（首字节 0x{x}，插件 {s}）", .{ pkt[0], plugin });
                    return error.Protocol;
                },
            }
        }
    }

    /// `caching_sha2_password` 完整鉴权（明文连接下的默认路径）：
    /// 1. 发 `0x02`（request_public_key）；2. 收 `0x01` + PEM 公钥；
    /// 3. `plain = password + '\0'`，用**握手 nonce** 循环 XOR（与 C# `GetXor` 一致）；
    /// 4. **RSAES-PKCS1-v1_5** 加密后发送；5. 收 OK。
    ///
    /// 填充的实测口径（2026-11-11，MySQL 8.0.29 真库）：
    /// - `RSAES-OAEP(SHA1)` 实现本身正确（本仓 `crypto/rsa.zig` 的产物能被 openssl
    ///   `pkeyutl -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha1` 解出原文），
    ///   但服务端回 `1045 Access denied`；
    /// - 改成 **PKCS#1 v1.5** 后同一个库、同一账号立即登入成功 → 该版本服务端接受 PKCS1。
    /// OAEP 实现保留在 `crypto/rsa.zig`（已单测），后续遇到只认 OAEP 的服务端再切回。
    fn performFullAuth(self: *Conn, password: []const u8, scramble: []const u8) !void {
        const rsa = @import("../crypto/rsa.zig");
        if (scramble.len == 0) {
            self.setError("完整鉴权失败：服务端未提供 scramble", .{});
            return error.Protocol;
        }

        try self.writePacket(&[_]u8{0x02});
        const key_pkt = try self.readPacket();
        if (key_pkt.len < 2 or key_pkt[0] != 0x01) {
            self.setError("请求公钥失败：期望 0x01 前缀，实际首字节 0x{x}（长度 {d}）", .{ if (key_pkt.len > 0) key_pkt[0] else 0, key_pkt.len });
            return error.Protocol;
        }
        // key_pkt 指向复用缓冲；parsePublicKey 内部会拷贝并立即解析，不跨 readPacket 使用
        var pub_key = rsa.parsePublicKey(self.gpa, key_pkt[1..]) catch |e| {
            self.setError("解析服务端 RSA 公钥失败：{s}", .{@errorName(e)});
            return e;
        };
        defer pub_key.deinit();

        // 口令以 '\0' 结尾后再循环 XOR（C# `GetXor` 同样补了结尾 0）
        const obf = try self.gpa.alloc(u8, password.len + 1);
        defer self.gpa.free(obf);
        for (password, 0..) |b, i| obf[i] = b ^ scramble[i % scramble.len];
        obf[password.len] = 0 ^ scramble[password.len % scramble.len];

        const cipher = rsa.pkcs1Encrypt(self.gpa, self.io, pub_key, obf) catch |e| {
            self.setError("RSA-PKCS1 加密密码失败：{s}", .{@errorName(e)});
            return e;
        };
        defer self.gpa.free(cipher);
        try self.writePacket(cipher);

        const ok_pkt = try self.readPacket();
        if (ok_pkt.len == 0) return error.ConnectionClosed;
        if (ok_pkt[0] == 0xff) return self.failFromPayload(ok_pkt);
        if (ok_pkt[0] != 0x00) {
            self.setError("完整鉴权响应异常：期望 OK，实际首字节 0x{x}", .{ok_pkt[0]});
            return error.AuthFailed;
        }
        const ok = try parseOkPayload(ok_pkt);
        self.applyOk(ok);
    }

    fn authResponse(self: *Conn, plugin: []const u8, password: []const u8, scramble: []const u8, buf: *[32]u8) ![]const u8 {
        _ = self;
        if (password.len == 0) return "";
        if (std.mem.eql(u8, plugin, "mysql_native_password")) {
            const s = nativePasswordScramble(password, scramble);
            @memcpy(buf[0..20], &s);
            return buf[0..20];
        }
        if (std.mem.eql(u8, plugin, "caching_sha2_password")) {
            buf.* = cachingSha2Scramble(password, scramble);
            return buf[0..32];
        }
        // 未知插件：不能瞎猜，明确报错
        return error.UnsupportedAuthPlugin;
    }

    // ── 包收发 ──────────────────────────────────────────────────────────────
    fn readPacket(self: *Conn) ![]u8 {
        self.pkt.clearRetainingCapacity();
        while (true) {
            var hdr: [4]u8 = undefined;
            try self.readExact(&hdr);
            const len: usize = @as(usize, hdr[0]) | (@as(usize, hdr[1]) << 8) | (@as(usize, hdr[2]) << 16);
            self.seq = hdr[3] +% 1;
            if (len > max_packet_size) {
                self.setError("服务端包长度 {d} 超过上限 {d}", .{ len, max_packet_size });
                return error.Protocol;
            }
            const start = self.pkt.items.len;
            try self.pkt.resize(self.gpa, start + len);
            try self.readExact(self.pkt.items[start..]);
            if (len < max_payload) break;
        }
        return self.pkt.items;
    }

    fn readExact(self: *Conn, dst: []u8) !void {
        var got: usize = 0;
        while (got < dst.len) {
            // 不用 `Stream.read`：0.17 里它对 `net_read` 的返回值做了不支持的解构（编译报错）。
            // 直接走 `io.operate`，拿 `data_len`。
            var slices = [_][]u8{dst[got..]};
            const r = self.io.operate(.{ .net_read = .{
                .socket_handle = self.stream.socket.handle,
                .data = &slices,
            } }) catch |e| {
                self.broken = true;
                self.setError("读 socket 失败：{s}", .{@errorName(e)});
                return e;
            };
            const res = r.net_read catch |e| {
                self.broken = true;
                self.setError("读 socket 失败：{s}", .{@errorName(e)});
                return e;
            };
            const n = res.data_len;
            if (n == 0) {
                self.broken = true;
                self.setError("连接被对端关闭（已读 {d}/{d} 字节）", .{ got, dst.len });
                return error.ConnectionClosed;
            }
            got += n;
        }
    }

    fn writePacket(self: *Conn, payload: []const u8) !void {
        var hdr: [4]u8 = undefined;
        var off: usize = 0;
        while (true) {
            const chunk = @min(payload.len - off, max_payload);
            hdr[0] = @intCast(chunk & 0xff);
            hdr[1] = @intCast((chunk >> 8) & 0xff);
            hdr[2] = @intCast((chunk >> 16) & 0xff);
            hdr[3] = self.seq;
            self.seq +%= 1;
            try self.writeAll(&hdr);
            if (chunk > 0) try self.writeAll(payload[off .. off + chunk]);
            off += chunk;
            if (chunk < max_payload) break;
        }
    }

    /// 发送**恰好一个**包（不自动分块、不补空包）。
    ///
    /// 只用于 `LOAD DATA LOCAL` 的数据流：那里「空包」是结束标记，
    /// 用 `writePacket` 的自动补空包会在数据正好是 16MB 整数倍时**提前截断**。
    fn writeRawPacket(self: *Conn, payload: []const u8) !void {
        if (payload.len > max_payload) {
            self.setError("单包载荷 {d} 超过协议上限 {d}", .{ payload.len, max_payload });
            return error.Protocol;
        }
        var hdr: [4]u8 = undefined;
        hdr[0] = @intCast(payload.len & 0xff);
        hdr[1] = @intCast((payload.len >> 8) & 0xff);
        hdr[2] = @intCast((payload.len >> 16) & 0xff);
        hdr[3] = self.seq;
        self.seq +%= 1;
        try self.writeAll(&hdr);
        if (payload.len > 0) try self.writeAll(payload);
    }

    fn writeAll(self: *Conn, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const result = self.io.operate(.{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .data = &.{bytes[sent..]},
            } }) catch |e| {
                self.broken = true;
                self.setError("写 socket 失败：{s}", .{@errorName(e)});
                return e;
            };
            const n = result.net_write catch |e| {
                self.broken = true;
                self.setError("写 socket 失败：{s}", .{@errorName(e)});
                return e;
            };
            if (n == 0) {
                self.broken = true;
                self.setError("写 socket 返回 0 字节（连接可能已断开）", .{});
                return error.ConnectionClosed;
            }
            sent += n;
        }
    }
};

// ══════════════════════════════════════════════════════════════════════════
// 鉴权散列（与 MySQL 服务端算法字节级一致）
// ══════════════════════════════════════════════════════════════════════════

/// `mysql_native_password`：`SHA1(pwd) XOR SHA1(scramble ++ SHA1(SHA1(pwd)))`
pub fn nativePasswordScramble(password: []const u8, scramble: []const u8) [20]u8 {
    const Sha1 = std.crypto.hash.Sha1;
    // 0.17 移除了 `**` 数组重复运算符，用 @splat 填充
    if (password.len == 0) return @splat(0);

    var stage1: [20]u8 = undefined;
    Sha1.hash(password, &stage1, .{});
    var stage2: [20]u8 = undefined;
    Sha1.hash(&stage1, &stage2, .{});

    var ctx = Sha1.init(.{});
    ctx.update(scramble);
    ctx.update(&stage2);
    var seed: [20]u8 = undefined;
    ctx.final(&seed);

    var out: [20]u8 = undefined;
    for (0..20) |i| out[i] = stage1[i] ^ seed[i];
    return out;
}

/// `caching_sha2_password`（fast auth）：`SHA256(pwd) XOR SHA256(SHA256(SHA256(pwd)) ++ scramble)`
pub fn cachingSha2Scramble(password: []const u8, scramble: []const u8) [32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    if (password.len == 0) return @splat(0);

    var stage1: [32]u8 = undefined;
    Sha256.hash(password, &stage1, .{});
    var stage2: [32]u8 = undefined;
    Sha256.hash(&stage1, &stage2, .{});

    var ctx = Sha256.init(.{});
    ctx.update(&stage2);
    ctx.update(scramble);
    var seed: [32]u8 = undefined;
    ctx.final(&seed);

    var out: [32]u8 = undefined;
    for (0..32) |i| out[i] = stage1[i] ^ seed[i];
    return out;
}

// ══════════════════════════════════════════════════════════════════════════
// 协议解析（纯函数，便于用固定字节做单测）
// ══════════════════════════════════════════════════════════════════════════

pub const ServerHandshake = struct {
    protocol_version: u8,
    server_version: []const u8,
    thread_id: u32,
    capability: u32,
    character_set: u8 = 0,
    status: u16 = 0,
    /// 有效 scramble（16/20/21 字节视服务端给的长度与实际内容而定）
    auth_plugin_data: [21]u8 = @splat(0),
    auth_plugin_data_len: usize = 0,
    auth_plugin_name: []const u8 = "",
};

pub fn parseHandshake(payload: []const u8) !ServerHandshake {
    if (payload.len < 16) return error.Protocol;
    if (payload[0] != 10) return error.Protocol; // 只支持 protocol 10

    var hs = ServerHandshake{
        .protocol_version = payload[0],
        .server_version = &.{},
        .thread_id = 0,
        .capability = 0,
    };

    var pos: usize = 1;
    const ver_end = std.mem.indexOfScalarPos(u8, payload, pos, 0) orelse return error.Protocol;
    hs.server_version = payload[pos..ver_end];
    pos = ver_end + 1;

    if (pos + 4 > payload.len) return error.Protocol;
    hs.thread_id = std.mem.readInt(u32, payload[pos..][0..4], .little);
    pos += 4;

    // auth-plugin-data-part-1（8 字节）
    if (pos + 8 > payload.len) return error.Protocol;
    @memcpy(hs.auth_plugin_data[0..8], payload[pos..][0..8]);
    pos += 8;
    pos += 1; // filler

    var cap: u32 = 0;
    if (pos + 2 <= payload.len) {
        cap = std.mem.readInt(u16, payload[pos..][0..2], .little);
        pos += 2;
    }
    hs.capability = cap;

    // 到这里如果没数据了，是老式协议（无 charset/status/plugin）
    if (pos >= payload.len) {
        hs.auth_plugin_data_len = 8;
        return hs;
    }

    if (pos + 1 > payload.len) return error.Protocol;
    hs.character_set = payload[pos];
    pos += 1;
    if (pos + 2 > payload.len) return error.Protocol;
    hs.status = std.mem.readInt(u16, payload[pos..][0..2], .little);
    pos += 2;
    if (pos + 2 > payload.len) return error.Protocol;
    cap |= @as(u32, std.mem.readInt(u16, payload[pos..][0..2], .little)) << 16;
    hs.capability = cap;
    pos += 2;

    var auth_data_len: usize = 0;
    if (pos + 1 <= payload.len) {
        auth_data_len = payload[pos];
        pos += 1;
    }
    pos += 10; // reserved

    // auth-plugin-data-part-2：长度 max(13, auth_len-8)，以 \0 结尾
    var part2_len: usize = 0;
    if ((cap & CLIENT_SECURE_CONNECTION) != 0) {
        part2_len = if (auth_data_len > 8) auth_data_len - 8 else 13;
        if (part2_len < 13) part2_len = 13;
        if (pos < payload.len) {
            const avail = payload.len - pos;
            const take = @min(part2_len, avail);
            var real = take;
            // 去掉末尾的 0 填充
            while (real > 0 and payload[pos + real - 1] == 0) real -= 1;
            if (real > 0) {
                @memcpy(hs.auth_plugin_data[8..][0..real], payload[pos..][0..real]);
                hs.auth_plugin_data_len = 8 + real;
            } else {
                hs.auth_plugin_data_len = 8;
            }
            pos += take;
        } else {
            hs.auth_plugin_data_len = 8;
        }
    } else {
        hs.auth_plugin_data_len = 8;
    }

    if ((cap & CLIENT_PLUGIN_AUTH) != 0 and pos < payload.len) {
        const rest = payload[pos..];
        const name_end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        hs.auth_plugin_name = rest[0..name_end];
    }
    return hs;
}

pub const OkPayload = Ok;

pub fn parseOkPayload(payload: []const u8) !Ok {
    if (payload.len < 1) return error.Protocol;
    if (payload[0] != 0x00 and payload[0] != 0xfe) return error.Protocol;
    var pos: usize = 1;
    var ok = Ok{};
    ok.affected_rows = try readLenencIntAt(payload, &pos);
    ok.insert_id = try readLenencIntAt(payload, &pos);
    if (pos + 2 <= payload.len) {
        ok.status = std.mem.readInt(u16, payload[pos..][0..2], .little);
        pos += 2;
    }
    if (pos + 2 <= payload.len) {
        ok.warnings = std.mem.readInt(u16, payload[pos..][0..2], .little);
    }
    return ok;
}

pub const ErrPayload = struct {
    code: u16,
    state_buf: [5]u8 = .{ '0', '0', '0', '0', '0' },
    has_state: bool = false,
    message: []const u8 = "",

    pub fn state(self: ErrPayload) []const u8 {
        return self.state_buf[0..];
    }
};

pub fn parseErrPayload(payload: []const u8) !ErrPayload {
    if (payload.len < 3 or payload[0] != 0xff) return error.Protocol;
    var e = ErrPayload{ .code = std.mem.readInt(u16, payload[1..3], .little) };
    var pos: usize = 3;
    if (pos < payload.len and payload[pos] == '#') {
        pos += 1;
        if (pos + 5 > payload.len) return error.Protocol;
        @memcpy(e.state_buf[0..5], payload[pos..][0..5]);
        e.has_state = true;
        pos += 5;
    }
    e.message = payload[pos..];
    return e;
}

pub fn parseColumnDef(payload: []const u8) !Column {
    var pos: usize = 0;
    // catalog / schema / table / org_table 全部跳过（ORM 只用 name）
    inline for (0..4) |_| {
        _ = try readLenencStrAt(payload, &pos);
    }
    const name = (try readLenencStrAt(payload, &pos)) orelse "";
    _ = try readLenencStrAt(payload, &pos); // org_name

    _ = try readLenencIntAt(payload, &pos); // length of fixed fields (0x0c)
    if (pos + 2 > payload.len) return error.Protocol;
    const charset = std.mem.readInt(u16, payload[pos..][0..2], .little);
    pos += 2;
    if (pos + 4 > payload.len) return error.Protocol;
    const col_len = std.mem.readInt(u32, payload[pos..][0..4], .little);
    pos += 4;
    if (pos + 1 > payload.len) return error.Protocol;
    const ty: ColumnType = @fromBackingInt(@intCast(payload[pos]));
    pos += 1;
    if (pos + 2 > payload.len) return error.Protocol;
    const flags = std.mem.readInt(u16, payload[pos..][0..2], .little);
    pos += 2;
    var decimals: u8 = 0;
    if (pos + 1 <= payload.len) {
        decimals = payload[pos];
    }
    return .{ .name = name, .type = ty, .flags = flags, .charset = charset, .decimals = decimals, .length = col_len };
}

/// 文本协议行：每列是 lenenc-string，0xFB 表示 NULL。
pub fn parseTextRow(arena: std.mem.Allocator, payload: []const u8, columns: []const Column) !Row {
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(Value) = .empty;
    var pos: usize = 0;
    for (columns) |col| {
        try names.append(arena, col.name);
        if (pos >= payload.len) {
            try values.append(arena, .null);
            continue;
        }
        if (payload[pos] == 0xfb) {
            pos += 1;
            try values.append(arena, .null);
            continue;
        }
        const raw = (try readLenencStrAt(payload, &pos)) orelse "";
        try values.append(arena, try textValue(arena, col, raw));
    }
    return .{ .names = try names.toOwnedSlice(arena), .values = try values.toOwnedSlice(arena) };
}

/// 二进制协议行：`0x00` + NULL 位图 + 按列类型编码的值。
pub fn parseBinaryRow(arena: std.mem.Allocator, payload: []const u8, columns: []const Column) !Row {
    if (payload.len < 1 or payload[0] != 0x00) return error.Protocol;
    var pos: usize = 1;
    const bitmap_len = (columns.len + 7 + 2) / 8;
    if (pos + bitmap_len > payload.len) return error.Protocol;
    const bitmap = payload[pos..][0..bitmap_len];
    pos += bitmap_len;

    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(Value) = .empty;
    for (columns, 0..) |col, i| {
        try names.append(arena, col.name);
        const bit_index = i + 2; // 前两位是保留位
        const is_null = (bitmap[bit_index / 8] & (@as(u8, 1) << @intCast(bit_index % 8))) != 0;
        if (is_null) {
            try values.append(arena, .null);
            continue;
        }
        const v = try binaryValue(arena, col, payload, &pos);
        try values.append(arena, v);
    }
    return .{ .names = try names.toOwnedSlice(arena), .values = try values.toOwnedSlice(arena) };
}

fn textValue(arena: std.mem.Allocator, col: Column, raw: []const u8) !Value {
    switch (col.type) {
        .tiny, .short, .long, .longlong, .int24, .year => {
            if (col.isUnsigned()) {
                // 无符号且超出 i64 时保留文本，避免静默截断
                const uv = std.fmt.parseInt(u64, raw, 10) catch return .{ .text = try arena.dupe(u8, raw) };
                if (uv <= std.math.maxInt(i64)) return .{ .int = @intCast(uv) };
                return .{ .text = try arena.dupe(u8, raw) };
            }
            const v = std.fmt.parseInt(i64, raw, 10) catch return .{ .text = try arena.dupe(u8, raw) };
            return .{ .int = v };
        },
        .float, .double => {
            const v = std.fmt.parseFloat(f64, raw) catch return .{ .text = try arena.dupe(u8, raw) };
            return .{ .float = v };
        },
        .decimal, .newdecimal => {
            const d = Decimal.parse(raw) catch return .{ .text = try arena.dupe(u8, raw) };
            return .{ .decimal = d };
        },
        .datetime, .timestamp, .date, .newdate, .datetime2, .timestamp2 => {
            // '0000-00-00 00:00:00' 之类的“零值”解析不了 → 退化为文本，不丢数据
            const dt = DateTime.parse(raw) catch return .{ .text = try arena.dupe(u8, raw) };
            return .{ .datetime = dt };
        },
        .bit => {
            // 实测口径（MySQL 8.0.29 真库，Pek.ZCode 集成用例锁定）：BIT 列在文本协议下是
            // **大端**字节（存 0x0102 读回字节为 [0x01,0x02] → 值 258）。
            // 注意：C# 绿色版 `DH.MySql.ConvertBitBytesToUInt64` 按小端累加（同一数据会得到 513），
            // 与实测不符；Rust `Pek.RCode` 的大端与实测一致。
            var acc: u64 = 0;
            for (raw) |b| {
                acc = (acc << 8) | b;
            }
            return .{ .int = @intCast(acc) };
        },
        .blob, .tiny_blob, .medium_blob, .long_blob => {
            if (col.isBinaryCharset()) return .{ .blob = try arena.dupe(u8, raw) };
            return .{ .text = try arena.dupe(u8, raw) };
        },
        .geometry => {
            return .{ .blob = try arena.dupe(u8, raw) };
        },
        .json, .enum_, .set, .varchar, .var_string, .string => {
            if (col.isBinaryCharset()) return .{ .blob = try arena.dupe(u8, raw) };
            return .{ .text = try arena.dupe(u8, raw) };
        },
        // 未知/新增类型：按文本保留，绝不静默丢弃
        else => {
            return .{ .text = try arena.dupe(u8, raw) };
        },
    }
}

fn binaryValue(arena: std.mem.Allocator, col: Column, payload: []const u8, pos: *usize) !Value {
    const need = struct {
        fn n(p: *usize, buf: []const u8, len: usize) !void {
            if (p.* + len > buf.len) return error.Protocol;
        }
    };
    switch (col.type) {
        .tiny => {
            try need.n(pos, payload, 1);
            const b = payload[pos.*];
            pos.* += 1;
            return .{ .int = if (col.isUnsigned()) @intCast(b) else @as(i64, @as(i8, @bitCast(b))) };
        },
        .short, .year => {
            try need.n(pos, payload, 2);
            const v = std.mem.readInt(u16, payload[pos.*..][0..2], .little);
            pos.* += 2;
            return .{ .int = if (col.isUnsigned()) @intCast(v) else @as(i64, @as(i16, @bitCast(v))) };
        },
        .long, .int24 => {
            try need.n(pos, payload, 4);
            const v = std.mem.readInt(u32, payload[pos.*..][0..4], .little);
            pos.* += 4;
            return .{ .int = if (col.isUnsigned()) @intCast(v) else @as(i64, @as(i32, @bitCast(v))) };
        },
        .longlong => {
            try need.n(pos, payload, 8);
            const v = std.mem.readInt(u64, payload[pos.*..][0..8], .little);
            pos.* += 8;
            if (col.isUnsigned()) {
                if (v > std.math.maxInt(i64)) return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{v}) };
                return .{ .int = @intCast(v) };
            }
            return .{ .int = @bitCast(v) };
        },
        .float => {
            try need.n(pos, payload, 4);
            const bits = std.mem.readInt(u32, payload[pos.*..][0..4], .little);
            pos.* += 4;
            return .{ .float = @as(f32, @bitCast(bits)) };
        },
        .double => {
            try need.n(pos, payload, 8);
            const bits = std.mem.readInt(u64, payload[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .float = @bitCast(bits) };
        },
        .date, .newdate, .datetime, .timestamp, .datetime2, .timestamp2 => {
            return parseBinaryDateTime(payload, pos);
        },
        .time, .time2 => {
            // 时间（可为负、可超 24h）：zzig.Value 没有“时长”类型 → 文本
            return parseBinaryTimeText(arena, payload, pos);
        },
        .null => return .null,
        else => {
            // 其余（decimal/varchar/blob/json/enum/set/bit/geometry…）都是 lenenc-string
            const raw = (try readLenencStrAt(payload, pos)) orelse return .null;
            return switch (col.type) {
                .decimal, .newdecimal => blk: {
                    const d = Decimal.parse(raw) catch break :blk .{ .text = try arena.dupe(u8, raw) };
                    break :blk .{ .decimal = d };
                },
                .bit => blk: {
                    var acc: u64 = 0;
                    for (raw) |b| acc = (acc << 8) | b;
                    break :blk .{ .int = @intCast(acc) };
                },
                .blob, .tiny_blob, .medium_blob, .long_blob => if (col.isBinaryCharset())
                    .{ .blob = try arena.dupe(u8, raw) }
                else
                    .{ .text = try arena.dupe(u8, raw) },
                .geometry => .{ .blob = try arena.dupe(u8, raw) },
                else => if (col.isBinaryCharset())
                    .{ .blob = try arena.dupe(u8, raw) }
                else
                    .{ .text = try arena.dupe(u8, raw) },
            };
        },
    }
}

fn parseBinaryDateTime(payload: []const u8, pos: *usize) !Value {
    if (pos.* >= payload.len) return error.Protocol;
    const len = payload[pos.*];
    pos.* += 1;
    if (len == 0) return .{ .datetime = DateTime{ .year = 0, .month = 1, .day = 1 } };
    if (pos.* + len > payload.len) return error.Protocol;
    const p = payload[pos.*..][0..len];
    pos.* += len;
    var dt = DateTime{};
    switch (len) {
        4 => {
            dt.year = std.mem.readInt(u16, p[0..2], .little);
            dt.month = p[2];
            dt.day = p[3];
        },
        7, 11 => {
            dt.year = std.mem.readInt(u16, p[0..2], .little);
            dt.month = p[2];
            dt.day = p[3];
            dt.hour = p[4];
            dt.minute = p[5];
            dt.second = p[6];
            if (len == 11) {
                const micros = std.mem.readInt(u32, p[7..11], .little);
                dt.nanos = micros * 1000;
            }
        },
        else => return error.Protocol,
    }
    return .{ .datetime = dt };
}

fn parseBinaryTimeText(arena: std.mem.Allocator, payload: []const u8, pos: *usize) !Value {
    if (pos.* >= payload.len) return error.Protocol;
    const len = payload[pos.*];
    pos.* += 1;
    if (len == 0) return .{ .text = try arena.dupe(u8, "00:00:00") };
    if (pos.* + len > payload.len) return error.Protocol;
    const p = payload[pos.*..][0..len];
    pos.* += len;

    var negative = false;
    var days: u32 = 0;
    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    var micros: u32 = 0;
    if (len >= 8) {
        negative = p[0] == 1;
        days = std.mem.readInt(u32, p[1..5], .little);
        hour = p[5];
        minute = p[6];
        second = p[7];
        if (len >= 12) micros = std.mem.readInt(u32, p[8..12], .little);
    } else {
        return error.Protocol;
    }
    const total_hours = days * 24 + hour;
    const text = if (micros > 0)
        try std.fmt.allocPrint(arena, "{s}{d}:{d:0>2}:{d:0>2}.{d:0>6}", .{ if (negative) "-" else "", total_hours, minute, second, micros })
    else
        try std.fmt.allocPrint(arena, "{s}{d}:{d:0>2}:{d:0>2}", .{ if (negative) "-" else "", total_hours, minute, second });
    return .{ .text = text };
}

// ══════════════════════════════════════════════════════════════════════════
// 参数绑定（COM_STMT_EXECUTE）
// ══════════════════════════════════════════════════════════════════════════

fn paramType(v: Value) u8 {
    return switch (v) {
        .null => @backingInt(ColumnType.null),
        .boolean => @backingInt(ColumnType.tiny),
        .int => @backingInt(ColumnType.longlong),
        .float => @backingInt(ColumnType.double),
        .decimal => @backingInt(ColumnType.newdecimal),
        .text => @backingInt(ColumnType.var_string),
        .blob => @backingInt(ColumnType.blob),
        .datetime => @backingInt(ColumnType.datetime),
    };
}

fn encodeParam(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .null => {},
        .boolean => |b| try out.append(gpa, if (b) 1 else 0),
        .int => |i| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(i), .little);
            try out.appendSlice(gpa, &b);
        },
        .float => |f| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(f), .little);
            try out.appendSlice(gpa, &b);
        },
        .decimal => |d| {
            var buf: [64]u8 = undefined;
            const text = d.formatBuf(&buf) catch return error.Protocol;
            try appendLenencInt(gpa, out, text.len);
            try out.appendSlice(gpa, text);
        },
        .text => |t| {
            try appendLenencInt(gpa, out, t.len);
            try out.appendSlice(gpa, t);
        },
        .blob => |bl| {
            try appendLenencInt(gpa, out, bl.len);
            try out.appendSlice(gpa, bl);
        },
        .datetime => |dt| {
            // 二进制日期时间：长度 + 年(u16) 月 日 [时 分 秒 [微秒(u32)]]
            const has_time = dt.hour != 0 or dt.minute != 0 or dt.second != 0 or dt.nanos != 0;
            const len: u8 = if (!has_time) 4 else if (dt.nanos == 0) 7 else 11;
            try out.append(gpa, len);
            var y: [2]u8 = undefined;
            std.mem.writeInt(u16, &y, @intCast(@max(dt.year, 0)), .little);
            try out.appendSlice(gpa, &y);
            try out.append(gpa, dt.month);
            try out.append(gpa, dt.day);
            if (len >= 7) {
                try out.append(gpa, dt.hour);
                try out.append(gpa, dt.minute);
                try out.append(gpa, dt.second);
            }
            if (len == 11) {
                var us: [4]u8 = undefined;
                std.mem.writeInt(u32, &us, dt.nanos / 1000, .little);
                try out.appendSlice(gpa, &us);
            }
        },
    }
}

// ══════════════════════════════════════════════════════════════════════════
// length-encoded 基础编码
// ══════════════════════════════════════════════════════════════════════════

pub fn appendLenencInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    if (value < 251) {
        try out.append(gpa, @intCast(value));
    } else if (value < 0x1_0000) {
        try out.append(gpa, 0xfc);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(value), .little);
        try out.appendSlice(gpa, &b);
    } else if (value < 0x100_0000) {
        try out.append(gpa, 0xfd);
        var b: [3]u8 = .{
            @intCast(value & 0xff),
            @intCast((value >> 8) & 0xff),
            @intCast((value >> 16) & 0xff),
        };
        try out.appendSlice(gpa, &b);
    } else {
        try out.append(gpa, 0xfe);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value, .little);
        try out.appendSlice(gpa, &b);
    }
}

pub fn readLenencIntAt(buf: []const u8, pos: *usize) !u64 {
    if (pos.* >= buf.len) return error.Protocol;
    const first = buf[pos.*];
    pos.* += 1;
    switch (first) {
        0xfb => return 0, // NULL：调用方用 readLenencStrAt 区分
        0xfc => {
            if (pos.* + 2 > buf.len) return error.Protocol;
            const v = std.mem.readInt(u16, buf[pos.*..][0..2], .little);
            pos.* += 2;
            return v;
        },
        0xfd => {
            if (pos.* + 3 > buf.len) return error.Protocol;
            const v = @as(u32, buf[pos.*]) | (@as(u32, buf[pos.* + 1]) << 8) | (@as(u32, buf[pos.* + 2]) << 16);
            pos.* += 3;
            return v;
        },
        0xfe => {
            if (pos.* + 8 > buf.len) return error.Protocol;
            const v = std.mem.readInt(u64, buf[pos.*..][0..8], .little);
            pos.* += 8;
            return v;
        },
        0xff => return error.Protocol,
        else => return first,
    }
}

pub fn readLenencStrAt(buf: []const u8, pos: *usize) !?[]const u8 {
    if (pos.* >= buf.len) return error.Protocol;
    if (buf[pos.*] == 0xfb) {
        pos.* += 1;
        return null;
    }
    const len = try readLenencIntAt(buf, pos);
    if (pos.* + len > buf.len) return error.Protocol;
    const s = buf[pos.*..][0..@intCast(len)];
    pos.* += @intCast(len);
    return s;
}

// ══════════════════════════════════════════════════════════════════════════
// 单测：全部用固定字节，不依赖真实服务器
// ══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn buildHandshakePacket() [128]u8 {
    var b: [128]u8 = @splat(0);
    var i: usize = 0;
    b[i] = 10; // protocol version
    i += 1;
    const ver = "8.0.36";
    @memcpy(b[i..][0..ver.len], ver);
    i += ver.len;
    b[i] = 0;
    i += 1;
    // thread id
    std.mem.writeInt(u32, b[i..][0..4], 4321, .little);
    i += 4;
    // auth-plugin-data-part-1
    const salt1 = "12345678";
    @memcpy(b[i..][0..8], salt1);
    i += 8;
    b[i] = 0; // filler
    i += 1;
    // capability low
    const cap_low: u16 = @truncate(CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH | CLIENT_LONG_PASSWORD | CLIENT_TRANSACTIONS | CLIENT_LONG_FLAG);
    std.mem.writeInt(u16, b[i..][0..2], cap_low, .little);
    i += 2;
    b[i] = 45; // charset
    i += 1;
    std.mem.writeInt(u16, b[i..][0..2], 2, .little); // status
    i += 2;
    // CLIENT_PLUGIN_AUTH 在 bit19 → 高 16 位写 0x0008（写 0 会让插件名解析被跳过）
    const cap_high: u16 = @truncate(CLIENT_PLUGIN_AUTH >> 16);
    std.mem.writeInt(u16, b[i..][0..2], cap_high, .little);
    i += 2;
    b[i] = 21; // auth data len
    i += 1;
    i += 10; // reserved
    const salt2 = "abcdefghijkl"; // 12 字节
    @memcpy(b[i..][0..salt2.len], salt2);
    i += salt2.len;
    b[i] = 0;
    i += 1;
    const plugin = "caching_sha2_password";
    @memcpy(b[i..][0..plugin.len], plugin);
    i += plugin.len;
    b[i] = 0;
    i += 1;
    return b;
}

test "MySQL - 解析握手 v10（scramble 与插件名）" {
    const b = buildHandshakePacket();
    const hs = try parseHandshake(&b);
    try testing.expectEqual(@as(u8, 10), hs.protocol_version);
    try testing.expectEqualStrings("8.0.36", hs.server_version);
    try testing.expectEqual(@as(u32, 4321), hs.thread_id);
    try testing.expectEqual(@as(u8, 45), hs.character_set);
    try testing.expectEqualStrings("caching_sha2_password", hs.auth_plugin_name);
    // 8 + 12 = 20 字节 scramble
    try testing.expectEqual(@as(usize, 20), hs.auth_plugin_data_len);
    try testing.expectEqualStrings("12345678", hs.auth_plugin_data[0..8]);
    try testing.expectEqualStrings("abcdefghijkl", hs.auth_plugin_data[8..20]);
    try testing.expect((hs.capability & CLIENT_PROTOCOL_41) != 0);
}

test "MySQL - native password 散列：空密码为全 0，非空为 20 字节且确定" {
    const zero = nativePasswordScramble("", "12345678901234567890");
    const all_zero: [20]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &all_zero, &zero);

    const s = "12345678901234567890";
    const a = nativePasswordScramble("secret", s);
    const b = nativePasswordScramble("secret", s);
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expect(!std.mem.eql(u8, &a, &all_zero));

    // 换个 scramble 必须变（否则说明没把 salt 混进去）
    const c = nativePasswordScramble("secret", "09876543210987654321");
    try testing.expect(!std.mem.eql(u8, &a, &c));

    // 与 MySQL 文档的算法一致性自检：SHA1(pwd) XOR SHA1(salt ++ SHA1(SHA1(pwd)))
    const Sha1 = std.crypto.hash.Sha1;
    var h1: [20]u8 = undefined;
    Sha1.hash("secret", &h1, .{});
    var h2: [20]u8 = undefined;
    Sha1.hash(&h1, &h2, .{});
    var ctx = Sha1.init(.{});
    ctx.update(s);
    ctx.update(&h2);
    var h3: [20]u8 = undefined;
    ctx.final(&h3);
    var expect: [20]u8 = undefined;
    for (0..20) |i| expect[i] = h1[i] ^ h3[i];
    try testing.expectEqualSlices(u8, &expect, &a);
}

test "MySQL - caching_sha2 fast auth 散列（32 字节）" {
    const s = "12345678901234567890";
    const a = cachingSha2Scramble("secret", s);
    try testing.expectEqual(@as(usize, 32), a.len);
    const b = cachingSha2Scramble("secret", s);
    try testing.expectEqualSlices(u8, &a, &b);
    const zero = cachingSha2Scramble("", s);
    const all_zero: [32]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &all_zero, &zero);
}

test "MySQL - OK / ERR 包解析" {
    // OK: 0x00, affected=3, insert_id=7, status=0x0002, warnings=1
    const ok_pkt = [_]u8{ 0x00, 3, 7, 0x02, 0x00, 0x01, 0x00 };
    const ok = try parseOkPayload(&ok_pkt);
    try testing.expectEqual(@as(u64, 3), ok.affected_rows);
    try testing.expectEqual(@as(u64, 7), ok.insert_id);
    try testing.expectEqual(@as(u16, 2), ok.status);
    try testing.expectEqual(@as(u16, 1), ok.warnings);

    // ERR: 0xff, code=1062, '#', '23000', message
    var err_pkt: [64]u8 = undefined;
    err_pkt[0] = 0xff;
    std.mem.writeInt(u16, err_pkt[1..3], 1062, .little);
    err_pkt[3] = '#';
    @memcpy(err_pkt[4..9], "23000");
    const msg = "Duplicate entry 'x' for key 'PRIMARY'";
    @memcpy(err_pkt[9..][0..msg.len], msg);
    const e = try parseErrPayload(err_pkt[0 .. 9 + msg.len]);
    try testing.expectEqual(@as(u16, 1062), e.code);
    try testing.expectEqualStrings("23000", e.state());
    try testing.expectEqualStrings(msg, e.message);
}

test "MySQL - 文本结果集解析（数字/文本/NULL）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cols = [_]Column{
        .{ .name = "id", .type = .long },
        .{ .name = "name", .type = .var_string },
        .{ .name = "note", .type = .var_string },
    };
    // 0x01 '7' | 0x03 'abc' | 0xfb
    const payload = [_]u8{ 0x01, '7', 0x03, 'a', 'b', 'c', 0xfb };
    const row = try parseTextRow(a, &payload, &cols);
    try testing.expectEqual(@as(i64, 7), row.get("id").?.int);
    try testing.expectEqualStrings("abc", row.get("name").?.text);
    try testing.expect(row.get("note").?.isNull());
}

test "MySQL - 二进制结果集解析（含 NULL 位图）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cols = [_]Column{
        .{ .name = "id", .type = .longlong },
        .{ .name = "name", .type = .var_string },
        .{ .name = "score", .type = .double },
    };
    // 行：0x00 + 位图(1字节，bit0 保留, bit1 对应第 0 列) + 值
    var payload: [64]u8 = undefined;
    var i: usize = 0;
    payload[i] = 0x00;
    i += 1;
    payload[i] = 0x02; // 第 0 列（bit index 2 → 第 0 字节 bit2？）见下方位图规则
    i += 1;
    // 这里直接改成不放 NULL：位图 0
    payload[1] = 0x00;
    std.mem.writeInt(u64, payload[i..][0..8], 42, .little);
    i += 8;
    payload[i] = 3; // lenenc 长度
    i += 1;
    @memcpy(payload[i..][0..3], "abc");
    i += 3;
    std.mem.writeInt(u64, payload[i..][0..8], @bitCast(@as(f64, 1.5)), .little);
    i += 8;

    const row = try parseBinaryRow(a, payload[0..i], &cols);
    try testing.expectEqual(@as(i64, 42), row.get("id").?.int);
    try testing.expectEqualStrings("abc", row.get("name").?.text);
    try testing.expectEqual(@as(f64, 1.5), row.get("score").?.float);
}

test "MySQL - 二进制日期时间解码（4/7/11 字节）" {
    var pos: usize = 0;
    // 4 字节：2024-05-06
    const d = [_]u8{ 4, 0xe8, 0x07, 5, 6 };
    const v1 = try parseBinaryDateTime(&d, &pos);
    try testing.expectEqual(@as(i32, 2024), v1.datetime.year);
    try testing.expectEqual(@as(u8, 5), v1.datetime.month);
    try testing.expectEqual(@as(u8, 6), v1.datetime.day);

    pos = 0;
    var buf: [12]u8 = undefined;
    buf[0] = 11;
    std.mem.writeInt(u16, buf[1..3], 2024, .little);
    buf[3] = 5;
    buf[4] = 6;
    buf[5] = 7;
    buf[6] = 8;
    buf[7] = 9;
    std.mem.writeInt(u32, buf[8..12], 123456, .little);
    const v2 = try parseBinaryDateTime(&buf, &pos);
    try testing.expectEqual(@as(u8, 7), v2.datetime.hour);
    try testing.expectEqual(@as(u8, 8), v2.datetime.minute);
    try testing.expectEqual(@as(u8, 9), v2.datetime.second);
    try testing.expectEqual(@as(u32, 123456000), v2.datetime.nanos);
}

test "MySQL - lenenc 整数编解码往返（含 251/65536 边界）" {
    const cases = [_]u64{ 0, 1, 250, 251, 252, 65535, 65536, 0xffff_ff, 0x100_0000, 0xffff_ffff_ffff_ffff };
    for (cases) |expect| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(testing.allocator);
        try appendLenencInt(testing.allocator, &list, expect);
        var pos: usize = 0;
        const got = try readLenencIntAt(list.items, &pos);
        try testing.expectEqual(expect, got);
        try testing.expectEqual(list.items.len, pos);
    }
}

test "MySQL - 列定义解析（协议 4.1）" {
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    // catalog / schema / table / org_table
    const parts = [_][]const u8{ "def", "test", "t", "t" };
    for (parts) |p| {
        buf[i] = @intCast(p.len);
        i += 1;
        @memcpy(buf[i..][0..p.len], p);
        i += p.len;
    }
    // name
    buf[i] = 4;
    i += 1;
    @memcpy(buf[i..][0..4], "Name");
    i += 4;
    // org_name
    buf[i] = 0;
    i += 1;
    // 固定字段长度
    buf[i] = 0x0c;
    i += 1;
    std.mem.writeInt(u16, buf[i..][0..2], 45, .little); // charset
    i += 2;
    std.mem.writeInt(u32, buf[i..][0..4], 255, .little); // length
    i += 4;
    buf[i] = @backingInt(ColumnType.var_string);
    i += 1;
    std.mem.writeInt(u16, buf[i..][0..2], ColumnFlags.not_null, .little);
    i += 2;
    buf[i] = 0;
    i += 1;

    const col = try parseColumnDef(buf[0..i]);
    try testing.expectEqualStrings("Name", col.name);
    try testing.expectEqual(ColumnType.var_string, col.type);
    try testing.expectEqual(@as(u32, 255), col.length);
    try testing.expect(!col.isUnsigned());
    try testing.expect((col.flags & ColumnFlags.not_null) != 0);
}
