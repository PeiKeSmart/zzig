//! PostgreSQL 执行驱动（协议 3.0，纯 wire protocol，不依赖 libpq）。
//!
//! 对应 C# `DH.NCode.PostgreSQL` / Rust `Pek.RCode/src/postgres.rs` 的**执行**部分；
//! 方言（引用符 `"x"`、占位符 `$N`、分页 `LIMIT/OFFSET`、类型映射）在上层 `dialect` 里。
//!
//! ## 支持范围（实测口径，不猜）
//!
//! | 能力 | 状态 |
//! |---|---|
//! | 启动握手 v3（user / database / client_encoding=UTF8） | ✅ |
//! | 鉴权：**Trust / Cleartext / MD5 / SCRAM-SHA-256** | ✅ |
//! | 简单查询（`Q`，无参数，可多语句） | ✅ |
//! | 扩展查询（`P`/`B`/`E`/`S`，参数全按 **text 格式**绑定） | ✅ |
//! | 结果集文本解码（bool/int/float/numeric/date/timestamp/bytea/text） | ✅ |
//! | 影响行数（`CommandComplete` 末位数字） | ✅ |
//! | TLS（`SSLRequest`） | ⛔ 未做：需要先加 TLS 客户端，见 `README` 的生态说明 |
//! | 二进制结果格式 / 游标 / COPY 协议 | ⛔ 未做 |
//! | `lastInsertId` | ⚠️ PG 没有「自增 id 回写」概念（序列由 `RETURNING` 取），恒返回 0 |
//!
//! ## 为什么参数全走 text 格式
//!
//! PG 的 text 格式对**所有**类型都成立（服务端按推断出的参数类型解析），
//! 而二进制格式每种类型都有自己的线序（int2 大端、numeric 自定义、timestamp 自 2000-01-01 起）。
//! 走 text 的代价是一次服务端解析，收益是「一套实现覆盖全部类型」，且与我们已有
//! `Value → 文本` 的格式化逻辑完全复用。真到了 COPY 级别的批量导入再单开二进制路径。
//!
//! ## SCRAM-SHA-256
//!
//! 按 RFC 5802 / RFC 7677 实现（PG 10+ 的默认鉴权）。核心公式：
//!
//! ```text
//! SaltedPassword = PBKDF2-HMAC-SHA256(password, salt, iterations, 32)
//! ClientKey      = HMAC-SHA256(SaltedPassword, "Client Key")
//! StoredKey      = SHA256(ClientKey)
//! AuthMessage    = client-first-bare + "," + server-first + "," + client-final-without-proof
//! ClientProof    = ClientKey XOR HMAC-SHA256(StoredKey, AuthMessage)
//! ```
//!
//! 单测用 **RFC 7677 §3 官方测试向量**校验（`user`/`pencil`/固定 nonce），
//! 与真库无关，保证算法本身正确。

const std = @import("std");
const compat = @import("../compat.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;

pub const default_port: u16 = 5432;

/// 一次执行的结果（与 MySQL 驱动同构，便于上层复用）。
pub const Ok = struct {
    /// 影响行数（CommandComplete 末位数字；DDL 为 0）
    affected_rows: u64 = 0,
    /// 命令标签（`SELECT 3` / `INSERT 0 1` / `UPDATE 2` / `CREATE TABLE`）
    tag: []const u8 = "",
};

pub const Rows = struct {
    rows: []const Row,
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
    /// 应用名（服务端 `pg_stat_activity` 里可见，排查连接来源用）
    application_name: []const u8 = "pek-zcode",
};

pub const Error = error{
    ConnectionClosed,
    Protocol,
    Server,
    AuthFailed,
    UnsupportedAuthMechanism,
    UnsupportedQuery,
};

/// PostgreSQL 前端消息类型（我们发出的）。
const MSG_STARTUP: u8 = 0; // 无类型字节，单列出来仅作说明
const MSG_QUERY: u8 = 'Q';
const MSG_PARSE: u8 = 'P';
const MSG_BIND: u8 = 'B';
const MSG_DESCRIBE: u8 = 'D';
const MSG_EXECUTE: u8 = 'E';
const MSG_CLOSE: u8 = 'C';
const MSG_SYNC: u8 = 'S';
const MSG_TERMINATE: u8 = 'X';
const MSG_PASSWORD: u8 = 'p';

/// 后端消息类型。
const BE_AUTH: u8 = 'R';
const BE_PARAM_STATUS: u8 = 'S';
const BE_BACKEND_KEY: u8 = 'K';
const BE_READY: u8 = 'Z';
const BE_ERROR: u8 = 'E';
const BE_NOTICE: u8 = 'N';
const BE_ROW_DESCRIPTION: u8 = 'T';
const BE_DATA_ROW: u8 = 'D';
const BE_COMMAND_COMPLETE: u8 = 'C';
const BE_PARSE_COMPLETE: u8 = '1';
const BE_BIND_COMPLETE: u8 = '2';
const BE_NO_DATA: u8 = 'n';
const BE_EMPTY_QUERY: u8 = 'I';
/// `Describe(statement)` 会先回参数描述（'t'）再回 RowDescription（'T'）
const BE_PARAMETER_DESCRIPTION: u8 = 't';

/// 鉴权子类型。
const AUTH_OK: u32 = 0;
const AUTH_CLEARTEXT: u32 = 3;
const AUTH_MD5: u32 = 5;
const AUTH_SASL: u32 = 10;
const AUTH_SASL_CONTINUE: u32 = 11;
const AUTH_SASL_FINAL: u32 = 12;

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    /// 收包复用缓冲（`readMessage` 的 payload 指向这里，下一次读取即失效）
    rx: std.ArrayList(u8) = .empty,
    /// 发包复用缓冲
    tx: std.ArrayList(u8) = .empty,
    /// 服务端版本与参数（`server_version`、`client_encoding` 等）
    server_version_buf: [64]u8 = undefined,
    server_version_len: usize = 0,
    last_affected_rows: u64 = 0,
    err_buf: [768]u8 = undefined,
    err_len: usize = 0,
    err_code: u32 = 0,
    sql_state: [5]u8 = .{ '0', '0', '0', '0', '0' },
    closed: bool = false,
    /// 命名预处理语句缓存（按 SQL 文本；连接私有）
    stmt_cache: std.ArrayListUnmanaged(StmtEntry) = .empty,
    /// 上限，`0` = 关闭复用（同进程 A/B 对比用）
    stmt_cache_limit: usize = 32,
    stmt_seq: u32 = 0,
    stmt_hits: usize = 0,
    stmt_misses: usize = 0,

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn lastErrorCode(self: *const Conn) u32 {
        return self.err_code;
    }

    pub fn lastSqlState(self: *const Conn) []const u8 {
        return self.sql_state[0..];
    }

    pub fn affectedRows(self: *const Conn) u64 {
        return self.last_affected_rows;
    }

    /// PG 没有自增 id 回写（用 `RETURNING` 取），保持 0 以免上层误用。
    pub fn lastInsertId(self: *const Conn) i64 {
        _ = self;
        return 0;
    }

    pub fn serverVersion(self: *const Conn) []const u8 {
        return self.server_version_buf[0..self.server_version_len];
    }

    fn setError(self: *Conn, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch self.err_buf[0..200];
        self.err_len = text.len;
    }

    // ── 连接与鉴权 ──────────────────────────────────────────────────────────

    pub fn open(gpa: std.mem.Allocator, opts: Options) !Conn {
        const io = compat.currentIo();
        const address = std.Io.net.IpAddress.resolve(io, opts.host, opts.port) catch |e| {
            std.debug.print("[zzig.postgres] 解析主机失败：host={s} port={d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };
        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            std.debug.print("[zzig.postgres] 连接失败：{s}:{d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };

        var self = Conn{ .gpa = gpa, .io = io, .stream = stream };
        errdefer self.closeQuietly();

        self.startup(opts) catch |e| {
            if (self.err_len == 0) {
                self.setError("启动/鉴权失败（{s}:{d} 用户 {s} 库 {s}）：{s}", .{ opts.host, opts.port, opts.user, opts.database, @errorName(e) });
            }
            std.debug.print("[zzig.postgres] 连接/鉴权失败：{s}\n", .{self.lastError()});
            return e;
        };
        return self;
    }

    pub fn deinit(self: *Conn) void {
        // 先逐条 Close 再 TERMINATE（都要在连接还活着时做）
        self.clearStmtCache();
        self.stmt_cache.deinit(self.gpa);
        self.closeQuietly();
        self.rx.deinit(self.gpa);
        self.tx.deinit(self.gpa);
    }

    fn closeQuietly(self: *Conn) void {
        if (self.closed) return;
        self.closed = true;
        self.writeMsg(MSG_TERMINATE, &.{}) catch {};
        self.stream.close(self.io);
    }

    pub fn close(self: *Conn) void {
        self.closeQuietly();
    }

    pub fn ping(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = try self.queryAlloc(arena.allocator(), "SELECT 1", &.{});
        switch (r) {
            .rows => return,
            .ok => return error.Protocol,
        }
    }

    fn startup(self: *Conn, opts: Options) !void {
        // StartupMessage：int32 len + int32 196608 + (key\0value\0)* + \0
        self.tx.clearRetainingCapacity();
        try self.tx.appendSlice(self.gpa, &[_]u8{ 0, 0, 0, 0 }); // 长度占位
        try self.appendI32(&self.tx, 196608);
        try self.appendCString(&self.tx, "user");
        try self.appendCString(&self.tx, opts.user);
        if (opts.database.len > 0) {
            try self.appendCString(&self.tx, "database");
            try self.appendCString(&self.tx, opts.database);
        }
        try self.appendCString(&self.tx, "client_encoding");
        try self.appendCString(&self.tx, "UTF8");
        if (opts.application_name.len > 0) {
            try self.appendCString(&self.tx, "application_name");
            try self.appendCString(&self.tx, opts.application_name);
        }
        try self.tx.append(self.gpa, 0);
        std.mem.writeInt(u32, self.tx.items[0..4], @intCast(self.tx.items.len), .big);
        try self.writeRaw(self.tx.items);

        // 鉴权循环
        while (true) {
            const msg = try self.readMessage();
            switch (msg.tag) {
                BE_AUTH => {
                    if (msg.payload.len < 4) return error.Protocol;
                    const kind = std.mem.readInt(u32, msg.payload[0..4], .big);
                    switch (kind) {
                        AUTH_OK => {},
                        AUTH_CLEARTEXT => {
                            var pwd_buf: [256]u8 = undefined;
                            if (opts.password.len >= pwd_buf.len) return error.Protocol;
                            @memcpy(pwd_buf[0..opts.password.len], opts.password);
                            pwd_buf[opts.password.len] = 0;
                            try self.writeMsg(MSG_PASSWORD, pwd_buf[0 .. opts.password.len + 1]);
                        },
                        AUTH_MD5 => {
                            if (msg.payload.len < 8) return error.Protocol;
                            const salt = msg.payload[4..8];
                            try self.sendMd5Password(opts.user, opts.password, salt);
                        },
                        AUTH_SASL => try self.saslAuth(opts, msg.payload[4..]),
                        AUTH_SASL_CONTINUE, AUTH_SASL_FINAL => return error.Protocol,
                        else => {
                            self.setError("不支持的 PostgreSQL 鉴权方式：{d}", .{kind});
                            return error.UnsupportedAuthMechanism;
                        },
                    }
                    // 注意：`msg.payload` 指向复用缓冲，后续 readMessage 会覆盖；
                    // 上面所有用到 payload 的地方都必须在下方再次读取之前完成。
                },
                BE_PARAM_STATUS => try self.onParameterStatus(msg.payload),
                BE_BACKEND_KEY => {},
                BE_ERROR => return self.failFromError(msg.payload),
                BE_NOTICE => {},
                BE_READY => return, // Z：鉴权完成
                else => return error.Protocol,
            }
            // 注意：`msg.payload` 指向复用缓冲，下一轮 readMessage 会覆盖；
            // 所有用到它的地方都已在本轮内完成拷贝/解析。
        }
    }

    fn onParameterStatus(self: *Conn, payload: []const u8) !void {
        // key\0value\0
        const k_end = std.mem.indexOfScalar(u8, payload, 0) orelse return;
        const key = payload[0..k_end];
        const rest = payload[k_end + 1 ..];
        const v_end = std.mem.indexOfScalar(u8, rest, 0) orelse return;
        const value = rest[0..v_end];
        if (std.mem.eql(u8, key, "server_version")) {
            const n = @min(value.len, self.server_version_buf.len);
            @memcpy(self.server_version_buf[0..n], value[0..n]);
            self.server_version_len = n;
        }
    }

    /// MD5 鉴权：`md5(md5(password + user) + salt)`，结果前加 `"md5"`。
    fn sendMd5Password(self: *Conn, user: []const u8, password: []const u8, salt: []const u8) !void {
        var inner: [16]u8 = undefined;
        var h1 = std.crypto.hash.Md5.init(.{});
        h1.update(password);
        h1.update(user);
        h1.final(&inner);
        const inner_hex = std.fmt.bytesToHex(inner, .lower);

        var h2 = std.crypto.hash.Md5.init(.{});
        h2.update(&inner_hex);
        h2.update(salt);
        var outer: [16]u8 = undefined;
        h2.final(&outer);

        var out: [35]u8 = undefined;
        @memcpy(out[0..3], "md5");
        const outer_hex = std.fmt.bytesToHex(outer, .lower);
        @memcpy(out[3..], &outer_hex);
        try self.writeMsg(MSG_PASSWORD, &out);
    }

    /// SCRAM-SHA-256 鉴权（PG 10+ 默认）。
    fn saslAuth(self: *Conn, opts: Options, mechanisms: []const u8) !void {
        // 机制列表：若干个 \0 结尾的字符串，最后再一个 \0
        var has_scram = false;
        var it = std.mem.splitScalar(u8, mechanisms, 0);
        while (it.next()) |m| {
            if (std.mem.eql(u8, m, "SCRAM-SHA-256")) has_scram = true;
        }
        if (!has_scram) {
            self.setError("服务端只提供了不支持的 SASL 机制：{s}", .{mechanisms});
            return error.UnsupportedAuthMechanism;
        }

        // client nonce：18 字节随机数（0.17 的 `std.crypto.random` 已移除，走 `io.random`）
        var nonce_raw: [18]u8 = undefined;
        self.io.random(&nonce_raw);
        var nonce_b64: [24]u8 = undefined;
        const nonce = std.base64.standard.Encoder.encode(&nonce_b64, &nonce_raw);

        // 用户名按 SCRAM 要求在 client-first 里置空（PG 从 StartupMessage 取用户）
        var first_buf: [128]u8 = undefined;
        const client_first_bare = try std.fmt.bufPrint(&first_buf, "n=,r={s}", .{nonce});
        var initial_buf: [160]u8 = undefined;
        const initial = try std.fmt.bufPrint(&initial_buf, "n,,{s}", .{client_first_bare});

        // SASLInitialResponse: 机制名\0 + int32 长度 + 载荷
        self.tx.clearRetainingCapacity();
        try self.appendCString(&self.tx, "SCRAM-SHA-256");
        try self.appendI32(&self.tx, @intCast(initial.len));
        try self.tx.appendSlice(self.gpa, initial);
        try self.writeMsg(MSG_PASSWORD, self.tx.items);

        var msg = try self.readMessage();
        if (msg.tag == BE_ERROR) return self.failFromError(msg.payload);
        if (msg.tag != BE_AUTH or msg.payload.len < 4) return error.Protocol;
        if (std.mem.readInt(u32, msg.payload[0..4], .big) != AUTH_SASL_CONTINUE) return error.Protocol;

        // server-first-message 在复用缓冲里，**先拷出来**再发下一包
        const server_first = try self.gpa.dupe(u8, msg.payload[4..]);
        defer self.gpa.free(server_first);

        var salt_b64: []const u8 = "";
        var iterations: u32 = 4096;
        var server_nonce: []const u8 = "";
        var pit = std.mem.splitScalar(u8, server_first, ',');
        while (pit.next()) |part| {
            if (part.len < 2) continue;
            const key = part[0];
            const val = part[2..];
            switch (key) {
                'r' => server_nonce = val,
                's' => salt_b64 = val,
                'i' => iterations = std.fmt.parseInt(u32, val, 10) catch return error.Protocol,
                else => {},
            }
        }
        if (server_nonce.len == 0 or salt_b64.len == 0) return error.Protocol;
        if (!std.mem.startsWith(u8, server_nonce, nonce)) {
            self.setError("SCRAM：服务端 nonce 未以客户端 nonce 开头（可能的中间人或协议错误）", .{});
            return error.AuthFailed;
        }

        // 解 salt（base64）
        var salt_buf: [128]u8 = undefined;
        const salt_len = (try base64Decode(&salt_buf, salt_b64)) orelse {
            self.setError("SCRAM：salt base64 解码失败（{s}）", .{salt_b64});
            return error.Protocol;
        };
        const salt = salt_buf[0..salt_len];

        // client-final-message-without-proof：`c=biws,r=<nonce>`（biws = base64("n,,")）
        var final_buf: [256]u8 = undefined;
        const final_wo_proof = try std.fmt.bufPrint(&final_buf, "c=biws,r={s}", .{server_nonce});

        var proof: [32]u8 = undefined;
        scramProof(opts.password, salt, iterations, client_first_bare, server_first, final_wo_proof, &proof) catch {
            self.setError("SCRAM：计算 client proof 失败", .{});
            return error.AuthFailed;
        };

        var proof_b64_buf: [64]u8 = undefined;
        const proof_b64 = std.base64.standard.Encoder.encode(&proof_b64_buf, &proof);

        self.tx.clearRetainingCapacity();
        try self.tx.appendSlice(self.gpa, final_wo_proof);
        try self.tx.appendSlice(self.gpa, ",p=");
        try self.tx.appendSlice(self.gpa, proof_b64);
        try self.writeMsg(MSG_PASSWORD, self.tx.items);

        // SASLFinal（v=ServerSignature，可选校验）
        msg = try self.readMessage();
        if (msg.tag == BE_ERROR) return self.failFromError(msg.payload);
        if (msg.tag != BE_AUTH or msg.payload.len < 4) return error.Protocol;
        if (std.mem.readInt(u32, msg.payload[0..4], .big) != AUTH_SASL_FINAL) return error.Protocol;
        // 服务端签名校验：`v=<b64>`；不匹配说明服务端不知道密码（必须报错，不能放过）
        if (msg.payload.len > 8 and std.mem.startsWith(u8, msg.payload[4..], "v=")) {
            var expect: [32]u8 = undefined;
            scramServerSignature(opts.password, salt, iterations, client_first_bare, server_first, final_wo_proof, &expect) catch return error.AuthFailed;
            var expect_b64: [64]u8 = undefined;
            const expect_text = std.base64.standard.Encoder.encode(&expect_b64, &expect);
            if (!std.mem.eql(u8, expect_text, msg.payload[6..])) {
                self.setError("SCRAM：服务端签名校验失败（服务端可能不知道该密码）", .{});
                return error.AuthFailed;
            }
        }
    }

    // ── 查询执行 ────────────────────────────────────────────────────────────

    /// 执行一条语句；有参数走扩展协议，无参数走简单查询（可多语句）。
    /// 结果集与行都分配在 `arena` 上。
    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        self.err_len = 0;
        self.err_code = 0;
        if (params.len == 0) return self.querySimple(arena, sql);
        return self.queryExtended(arena, sql, params);
    }

    pub fn exec(self: *Conn, sql: []const u8, params: []const Value) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = try self.queryAlloc(arena.allocator(), sql, params);
        return switch (r) {
            .ok => |o| o.affected_rows,
            .rows => blk: {
                self.setError("期望写入语句，但返回了结果集：{s}", .{sql});
                break :blk error.Protocol;
            },
        };
    }

    fn querySimple(self: *Conn, arena: std.mem.Allocator, sql: []const u8) !Result {
        self.tx.clearRetainingCapacity();
        try self.appendCString(&self.tx, sql);
        try self.writeMsg(MSG_QUERY, self.tx.items);

        var rows: std.ArrayList(Row) = .empty;
        var row_names: []const []const u8 = &.{};
        var affected: u64 = 0;
        var tag_buf: []const u8 = "";

        while (true) {
            const msg = try self.readMessage();
            switch (msg.tag) {
                BE_ROW_DESCRIPTION => row_names = try parseRowDescription(arena, msg.payload),
                BE_DATA_ROW => {
                    const row = try parseDataRow(arena, msg.payload, row_names);
                    try rows.append(arena, row);
                },
                BE_COMMAND_COMPLETE => {
                    const tag = try arena.dupe(u8, std.mem.trimEnd(u8, msg.payload, "\x00"));
                    tag_buf = tag;
                    affected = parseAffected(tag);
                    self.last_affected_rows = affected;
                },
                BE_EMPTY_QUERY => {},
                BE_NOTICE => {},
                BE_ERROR => {
                    const err = self.failFromError(msg.payload);
                    // **必须把 ReadyForQuery 读掉**：PG 在 ErrorResponse 之后一定会补一条
                    // ReadyForQuery；不消费它，下一条语句就读到残留消息 → 协议错位
                    // （实测：错一次之后整条连接上所有查询都失败）。
                    try self.drainUntilReady();
                    return err;
                },
                BE_READY => break,
                // 简单查询下不应出现扩展协议消息；忽略以保持向前兼容
                BE_PARSE_COMPLETE, BE_BIND_COMPLETE, BE_NO_DATA => {},
                else => {},
            }
        }

        if (rows.items.len > 0) {
            return .{ .rows = .{ .rows = try rows.toOwnedSlice(arena) } };
        }
        return .{ .ok = .{ .affected_rows = affected, .tag = tag_buf } };
    }

    /// 扩展查询（带参）。**带预处理语句复用**：同一 SQL 第二次起只发 `Bind + Execute + Sync`，
    /// 省掉 `Parse`（服务端解析 + 规划）与 `Describe`（列描述）。
    ///
    /// 为什么值得做：MySQL 侧同款复用实测 1.64×；PG 每次 `Parse` 都要服务端重新解析与规划，
    /// 而 ORM 热路径恰恰是「同一条带参 SQL 反复执行」（点查 / 单行更新）。
    /// 预处理语句是**连接私有**的，所以缓存挂在 `Conn` 上、重连自然失效。
    fn queryExtended(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        if (self.lookupStmt(sql)) |entry| {
            self.stmt_hits += 1;
            return self.runExtended(arena, sql, params, entry) catch |e| {
                // 缓存语句可能因 DDL / `SET` 等失效（PG 报 0A000 `cached plan must not change
                // result type`、26000 `prepared statement ... does not exist`）。
                // 丢掉它并按「首次」路径重试一次；连接已断则不重试。
                if (self.closed) return e;
                std.debug.print(
                    "[zzig.postgres] 预处理语句失效，丢弃后重试一次（原因 {s}；{s}）\n",
                    .{ @errorName(e), self.lastError() },
                );
                self.dropStmt(entry.name);
                return self.runExtended(arena, sql, params, null);
            };
        }
        self.stmt_misses += 1;
        return self.runExtended(arena, sql, params, null);
    }

    /// 真正发协议：`cached == null` 时额外发 `Parse` + `Describe(statement)`。
    fn runExtended(
        self: *Conn,
        arena: std.mem.Allocator,
        sql: []const u8,
        params: []const Value,
        cached: ?*const StmtEntry,
    ) !Result {
        var name_buf: [32]u8 = undefined;
        const stmt_name: []const u8 = if (cached) |e| e.name else blk: {
            const n = self.stmt_seq;
            self.stmt_seq +%= 1;
            break :blk std.fmt.bufPrint(&name_buf, "zcode_p{d}", .{n}) catch return error.Protocol;
        };

        // 首次：Parse（`0` = 让服务端推断参数类型）+ Describe statement（拿列名，空结果也有结构）
        if (cached == null) {
            self.tx.clearRetainingCapacity();
            try self.appendCString(&self.tx, stmt_name);
            try self.appendCString(&self.tx, sql);
            try self.appendI16(&self.tx, 0);
            try self.writeMsg(MSG_PARSE, self.tx.items);

            self.tx.clearRetainingCapacity();
            try self.tx.append(self.gpa, 'S'); // Describe 目标：语句（不是 portal）
            try self.appendCString(&self.tx, stmt_name);
            try self.writeMsg(MSG_DESCRIBE, self.tx.items);
        }

        // Bind（无名 portal；全部 text 格式；NULL 用 -1 长度）
        self.tx.clearRetainingCapacity();
        try self.appendCString(&self.tx, ""); // 无名 portal
        try self.appendCString(&self.tx, stmt_name); // 目标语句（首次为刚 Parse 的命名语句）
        try self.appendI16(&self.tx, 0); // 参数格式：全 text
        try self.appendI16(&self.tx, @intCast(params.len));
        var val_buf: [512]u8 = undefined;
        for (params) |p| {
            if (p.isNull()) {
                try self.appendI32(&self.tx, -1);
                continue;
            }
            const text = try formatParam(&val_buf, p);
            try self.appendI32(&self.tx, @intCast(text.len));
            try self.tx.appendSlice(self.gpa, text);
        }
        try self.appendI16(&self.tx, 0); // 结果格式：全 text
        try self.writeMsg(MSG_BIND, self.tx.items);

        // Execute + Sync
        self.tx.clearRetainingCapacity();
        try self.appendCString(&self.tx, "");
        try self.appendI32(&self.tx, 0); // 不限行数
        try self.writeMsg(MSG_EXECUTE, self.tx.items);
        try self.writeMsg(MSG_SYNC, &.{});

        var rows: std.ArrayList(Row) = .empty;
        // 命中缓存时列名直接复用（省掉 Describe 的往返内容）；首次则从 RowDescription 取
        var row_names: []const []const u8 = if (cached) |e| e.columns else &.{};
        var affected: u64 = 0;
        var tag_buf: []const u8 = "";

        while (true) {
            const msg = try self.readMessage();
            switch (msg.tag) {
                BE_ROW_DESCRIPTION => {
                    if (cached == null) row_names = try parseRowDescription(arena, msg.payload);
                },
                BE_DATA_ROW => {
                    const row = try parseDataRow(arena, msg.payload, row_names);
                    try rows.append(arena, row);
                },
                BE_COMMAND_COMPLETE => {
                    const tag = try arena.dupe(u8, std.mem.trimEnd(u8, msg.payload, "\x00"));
                    tag_buf = tag;
                    affected = parseAffected(tag);
                    self.last_affected_rows = affected;
                },
                // `Describe(statement)` 会先回一条 ParameterDescription（'t'）再回 RowDescription
                BE_PARSE_COMPLETE, BE_BIND_COMPLETE, BE_NO_DATA, BE_PARAMETER_DESCRIPTION => {},
                BE_NOTICE => {},
                BE_ERROR => {
                    const err = self.failFromError(msg.payload);
                    // 同 `querySimple`：错误后必须消费到 ReadyForQuery，否则连接错位。
                    try self.drainUntilReady();
                    return err;
                },
                BE_READY => break,
                else => {},
            }
        }

        // 首次执行**成功**后才入缓存（失败的错误路径已在上面 return）
        if (cached == null) {
            self.putStmt(sql, stmt_name, row_names) catch |e| {
                std.debug.print(
                    "[zzig.postgres] 预处理语句入缓存失败（不影响本次结果）：{s}\n",
                    .{@errorName(e)},
                );
            };
        }

        if (rows.items.len > 0) {
            return .{ .rows = .{ .rows = try rows.toOwnedSlice(arena) } };
        }
        return .{ .ok = .{ .affected_rows = affected, .tag = tag_buf } };
    }

    // ── 预处理语句缓存 ──────────────────────────────────────────────────────

    /// 一条命名预处理语句。字符串统一在自带 arena 里，释放只需一次 `deinit`。
    ///
    /// `arena` 用**堆指针**而不是内联值：`ArrayList` 扩容会按字节移动元素，
    /// 内联 Arena 一旦被移动，之前取出的 `allocator()`（其 ptr 指向 `&state`）就悬垂。
    const StmtEntry = struct {
        arena: *std.heap.ArenaAllocator,
        sql: []const u8 = "",
        name: []const u8 = "",
        /// 列名（首次执行时从 RowDescription 拷一份；无结果集的语句为空）
        columns: []const []const u8 = &.{},
    };

    fn lookupStmt(self: *Conn, sql: []const u8) ?*const StmtEntry {
        if (self.stmt_cache_limit == 0) return null;
        for (self.stmt_cache.items) |*e| {
            if (std.mem.eql(u8, e.sql, sql)) return e;
        }
        return null;
    }

    fn putStmt(self: *Conn, sql: []const u8, name: []const u8, columns: []const []const u8) !void {
        if (self.stmt_cache_limit == 0) return;
        while (self.stmt_cache.items.len >= self.stmt_cache_limit) self.evictOldest();

        const arena = try self.gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.gpa);
        errdefer {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        const a = arena.allocator();

        var entry = StmtEntry{ .arena = arena };
        entry.sql = try a.dupe(u8, sql);
        entry.name = try a.dupe(u8, name);
        if (columns.len > 0) {
            const cols = try a.alloc([]const u8, columns.len);
            for (columns, 0..) |c, i| cols[i] = try a.dupe(u8, c);
            entry.columns = cols;
        }
        try self.stmt_cache.append(self.gpa, entry);
    }

    /// 淘汰最旧一条（FIFO；热点语句很快稳定，LRU 的收益不值得复杂度），
    /// 并从服务端 `Close` 掉，避免命名语句在会话里无限累积。
    fn evictOldest(self: *Conn) void {
        if (self.stmt_cache.items.len == 0) return;
        const entry = self.stmt_cache.orderedRemove(0);
        self.closeStmtQuietly(entry.name);
        entry.arena.deinit();
        self.gpa.destroy(entry.arena);
    }

    /// 按名字丢弃一条（给「失效重试」用）。
    fn dropStmt(self: *Conn, name: []const u8) void {
        for (self.stmt_cache.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            const entry = self.stmt_cache.orderedRemove(i);
            self.closeStmtQuietly(entry.name);
            entry.arena.deinit();
            self.gpa.destroy(entry.arena);
            return;
        }
    }

    /// 服务端 `Close(statement)` + `Sync`；失败只标记连接状态，不让调用方失败。
    fn closeStmtQuietly(self: *Conn, name: []const u8) void {
        if (self.closed) return;
        self.tx.clearRetainingCapacity();
        self.tx.append(self.gpa, 'S') catch return;
        self.appendCString(&self.tx, name) catch return;
        self.writeMsg(MSG_CLOSE, self.tx.items) catch return;
        self.writeMsg(MSG_SYNC, &.{}) catch return;
        self.drainUntilReady() catch {
            self.closed = true;
        };
    }

    /// 清空缓存（逐条向服务端 `Close`）。
    pub fn clearStmtCache(self: *Conn) void {
        while (self.stmt_cache.items.len > 0) self.evictOldest();
    }

    /// `0` = 关闭复用（用于同进程 A/B 对比）。
    pub fn setStmtCacheLimit(self: *Conn, limit: usize) void {
        if (limit == 0) self.clearStmtCache();
        self.stmt_cache_limit = limit;
    }

    pub fn stmtCacheStats(self: *const Conn) struct { hits: usize, misses: usize, size: usize } {
        return .{ .hits = self.stmt_hits, .misses = self.stmt_misses, .size = self.stmt_cache.items.len };
    }

    /// 读到 `ReadyForQuery` 为止（错误后的协议状态清理）。
    ///
    /// 注意：`failFromError` 已把错误文本/状态码拷进自己的缓冲，所以这里可以放心继续读包
    /// （`readMessage` 会复用 `rx`）。连接已断时标记 `closed`，避免后续调用继续往坏连接写。
    fn drainUntilReady(self: *Conn) !void {
        while (true) {
            const msg = self.readMessage() catch |e| {
                self.closed = true;
                return e;
            };
            switch (msg.tag) {
                BE_READY => return,
                // 可能有多条错误（同一批次里多条语句），继续读到 Ready 为准
                BE_ERROR => {},
                else => {},
            }
        }
    }

    /// CommandComplete 的末位数字即影响行数：`INSERT 0 3` / `UPDATE 2` / `DELETE 5` / `SELECT 7`。
    fn parseAffected(tag: []const u8) u64 {
        var end = tag.len;
        while (end > 0 and (tag[end - 1] == ' ' or tag[end - 1] == 0)) end -= 1;
        var start = end;
        while (start > 0 and tag[start - 1] >= '0' and tag[start - 1] <= '9') start -= 1;
        if (start == end) return 0;
        return std.fmt.parseInt(u64, tag[start..end], 10) catch 0;
    }

    fn failFromError(self: *Conn, payload: []const u8) error{ Server, Protocol } {
        // ErrorResponse: 若干 (字段类型 u8 + 字符串\0)，最后 \0
        var state: []const u8 = "00000";
        var message: []const u8 = "";
        var i: usize = 0;
        while (i < payload.len) {
            const field = payload[i];
            if (field == 0) break;
            const start = i + 1;
            const end = std.mem.indexOfScalarPos(u8, payload, start, 0) orelse payload.len;
            const value = payload[start..end];
            switch (field) {
                'C' => state = value,
                'M' => message = value,
                'S' => {},
                'V' => {},
                else => {},
            }
            i = if (end < payload.len) end + 1 else payload.len;
        }
        self.err_code = 0;
        const n = @min(state.len, 5);
        @memcpy(self.sql_state[0..n], state[0..n]);
        self.setError("PostgreSQL 错误（SQLSTATE {s}）：{s}", .{ state, message });
        return error.Server;
    }

    // ── 收发包 ──────────────────────────────────────────────────────────────

    const Message = struct { tag: u8, payload: []u8 };

    fn readMessage(self: *Conn) !Message {
        var head: [5]u8 = undefined;
        try self.readExact(&head);
        const len = std.mem.readInt(u32, head[1..5], .big);
        if (len < 4) return error.Protocol;
        const body_len = len - 4;

        self.rx.clearRetainingCapacity();
        try self.rx.resize(self.gpa, body_len);
        if (body_len > 0) try self.readExact(self.rx.items[0..body_len]);
        return .{ .tag = head[0], .payload = self.rx.items[0..body_len] };
    }

    fn writeMsg(self: *Conn, tag: u8, payload: []const u8) !void {
        return self.writeMsgInto(tag, payload);
    }

    /// 发送消息：类型字节 + int32 长度（含自身 4 字节）+ 载荷。
    /// 注意：调用方给 `payload` 可能是 `self.tx.items` 本身，因此这里**先算长度再写**，
    /// 不重新分配缓冲（否则会与入参别名冲突）。
    fn writeMsgInto(self: *Conn, tag: u8, payload: []const u8) !void {
        var head: [5]u8 = undefined;
        head[0] = tag;
        std.mem.writeInt(u32, head[1..5], @intCast(payload.len + 4), .big);
        try self.writeRaw(&head);
        if (payload.len > 0) try self.writeRaw(payload);
    }

    fn writeRaw(self: *Conn, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const result = self.io.operate(.{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .data = &.{bytes[sent..]},
            } }) catch |e| {
                self.setError("写 socket 失败：{s}", .{@errorName(e)});
                self.closed = true;
                return e;
            };
            const n = result.net_write catch |e| {
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

    fn readExact(self: *Conn, dst: []u8) !void {
        var got: usize = 0;
        while (got < dst.len) {
            var slices = [_][]u8{dst[got..]};
            const r = self.io.operate(.{ .net_read = .{
                .socket_handle = self.stream.socket.handle,
                .data = &slices,
            } }) catch |e| {
                self.setError("读 socket 失败：{s}", .{@errorName(e)});
                self.closed = true;
                return e;
            };
            const res = r.net_read catch |e| {
                self.setError("读 socket 失败：{s}", .{@errorName(e)});
                self.closed = true;
                return e;
            };
            const n = res.data_len;
            if (n == 0) {
                self.closed = true;
                return error.ConnectionClosed;
            }
            got += n;
        }
    }

    fn appendI16(self: *Conn, list: *std.ArrayList(u8), v: i16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .big);
        try list.appendSlice(self.gpa, &b);
    }

    fn appendI32(self: *Conn, list: *std.ArrayList(u8), v: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .big);
        try list.appendSlice(self.gpa, &b);
    }

    fn appendCString(self: *Conn, list: *std.ArrayList(u8), s: []const u8) !void {
        try list.appendSlice(self.gpa, s);
        try list.append(self.gpa, 0);
    }
};

// ───────────────────────── 参数与结果解码 ─────────────────────────

/// 把参数值格式化成 PG 的 text 格式。
fn formatParam(buf: []u8, v: Value) ![]const u8 {
    return switch (v) {
        .null => "NULL",
        .boolean => |b| if (b) "t" else "f",
        .int => |n| std.fmt.bufPrint(buf, "{d}", .{n}),
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}),
        .decimal => |d| d.formatBuf(buf),
        .datetime => |dt| dt.formatBuf(buf),
        .text => |t| t,
        .blob => |bytes| blk: {
            // bytea 的 text 格式：`\x` + 十六进制
            if (bytes.len * 2 + 2 > buf.len) return error.NoSpaceLeft;
            const hex = "0123456789abcdef";
            buf[0] = '\\';
            buf[1] = 'x';
            for (bytes, 0..) |b, idx| {
                buf[2 + idx * 2] = hex[b >> 4];
                buf[3 + idx * 2] = hex[b & 0x0F];
            }
            break :blk buf[0 .. 2 + bytes.len * 2];
        },
    };
}

/// 解析 RowDescription：int16 列数 + 每列（名字\0 + 表oid + 列号 + 类型oid + 长度 + 修饰 + 格式）。
fn parseRowDescription(arena: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
    if (payload.len < 2) return error.Protocol;
    const count = std.mem.readInt(u16, payload[0..2], .big);
    var names = try arena.alloc([]const u8, count);
    var i: usize = 2;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        const end = std.mem.indexOfScalarPos(u8, payload, i, 0) orelse return error.Protocol;
        names[n] = try arena.dupe(u8, payload[i..end]);
        // 名字\0 + 18 字节固定字段
        i = end + 1 + 18;
        if (i > payload.len) return error.Protocol;
    }
    return names;
}

/// 解析 DataRow：int16 列数 + 每列（int32 长度 + 内容；-1 = NULL）。
fn parseDataRow(arena: std.mem.Allocator, payload: []const u8, names: []const []const u8) !Row {
    if (payload.len < 2) return error.Protocol;
    const count = std.mem.readInt(u16, payload[0..2], .big);
    var values = try arena.alloc(Value, count);
    var i: usize = 2;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        if (i + 4 > payload.len) return error.Protocol;
        const len = std.mem.readInt(i32, payload[i..][0..4], .big);
        i += 4;
        if (len < 0) {
            values[n] = .null;
            continue;
        }
        const l: usize = @intCast(len);
        if (i + l > payload.len) return error.Protocol;
        const text = payload[i .. i + l];
        values[n] = decodeText(arena, text) catch .{ .text = try arena.dupe(u8, text) };
        i += l;
    }
    return .{ .names = names, .values = values };
}

/// 文本值 → 统一值。PG 的 text 格式对所有类型都成立，这里按**内容**推断：
/// 布尔只有 `t`/`f`；纯整数字面量 → int；`\x` 前缀 → blob；`YYYY-MM-DD[ HH:MM:SS]` → datetime；
/// 其余保持 text（含 numeric，避免把精度改掉——需要数值时上层用 `asDecimal()`）。
fn decodeText(arena: std.mem.Allocator, text: []const u8) !Value {
    if (text.len == 0) return .{ .text = "" };

    if (text.len == 1 and (text[0] == 't' or text[0] == 'f')) {
        return .{ .boolean = text[0] == 't' };
    }
    if (std.mem.startsWith(u8, text, "\\x")) {
        const hex = text[2..];
        if (hex.len % 2 != 0) return .{ .text = try arena.dupe(u8, text) };
        const out = try arena.alloc(u8, hex.len / 2);
        _ = std.fmt.hexToBytes(out, hex) catch return .{ .text = try arena.dupe(u8, text) };
        return .{ .blob = out };
    }
    // 整数（含负号）
    if (looksLikeInt(text)) {
        if (std.fmt.parseInt(i64, text, 10)) |n| {
            return .{ .int = n };
        } else |_| {}
    }
    // 时间：`2024-05-06` / `2024-05-06 07:08:09[.123456]`
    if (text.len >= 10 and text[4] == '-' and text[7] == '-') {
        const dt = @import("../time/datetime.zig").DateTime.parse(text) catch null;
        if (dt) |d| return .{ .datetime = d };
    }
    return .{ .text = try arena.dupe(u8, text) };
}

fn looksLikeInt(text: []const u8) bool {
    if (text.len == 0 or text.len > 20) return false;
    var i: usize = 0;
    if (text[0] == '-' or text[0] == '+') i = 1;
    if (i >= text.len) return false;
    while (i < text.len) : (i += 1) {
        if (text[i] < '0' or text[i] > '9') return false;
    }
    return true;
}

/// base64 解码（返回实际长度；base64 库的 `decode` 只返回 void，需要自己截断）。
fn base64Decode(dest: []u8, source: []const u8) !?usize {
    std.base64.standard.Decoder.decode(dest, source) catch return null;
    // 去掉 padding 后的真实长度
    var len: usize = source.len / 4 * 3;
    if (source.len > 0 and source[source.len - 1] == '=') len -= 1;
    if (source.len > 1 and source[source.len - 2] == '=') len -= 1;
    return len;
}

// ───────────────────────── SCRAM 算法（可单测） ─────────────────────────

/// 计算 SCRAM-SHA-256 的 client proof（32 字节）。
pub fn scramProof(
    password: []const u8,
    salt: []const u8,
    iterations: u32,
    client_first_bare: []const u8,
    server_first: []const u8,
    client_final_wo_proof: []const u8,
    out: *[32]u8,
) !void {
    var salted: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256);

    var client_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_key, "Client Key", &salted);

    var stored_key: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&client_key, &stored_key, .{});

    var auth_msg_buf: [1024]u8 = undefined;
    const auth_msg = std.fmt.bufPrint(&auth_msg_buf, "{s},{s},{s}", .{ client_first_bare, server_first, client_final_wo_proof }) catch return error.Protocol;

    var client_sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_sig, auth_msg, &stored_key);

    for (0..32) |i| out[i] = client_key[i] ^ client_sig[i];
}

/// 计算 SCRAM-SHA-256 的服务端签名（用于校验服务端身份）。
pub fn scramServerSignature(
    password: []const u8,
    salt: []const u8,
    iterations: u32,
    client_first_bare: []const u8,
    server_first: []const u8,
    client_final_wo_proof: []const u8,
    out: *[32]u8,
) !void {
    var salted: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256);

    var server_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&server_key, "Server Key", &salted);

    var auth_msg_buf: [1024]u8 = undefined;
    const auth_msg = std.fmt.bufPrint(&auth_msg_buf, "{s},{s},{s}", .{ client_first_bare, server_first, client_final_wo_proof }) catch return error.Protocol;

    std.crypto.auth.hmac.sha2.HmacSha256.create(out, auth_msg, &server_key);
}

// ───────────────────────────── 测试 ─────────────────────────────

test "SCRAM-SHA-256：RFC 7677 §3 官方测试向量" {
    // 向量：user / pencil，client nonce rOprNGfwEbeRWgbNEkqO，服务端拼上 %hvYDpWUa2RaTCAfuxFIlj)hNlF$k0
    const salt_b64 = "W22ZaJ0SNY7soEsUEjb6gQ==";
    var salt_buf: [64]u8 = undefined;
    const salt_len = (try base64Decode(&salt_buf, salt_b64)).?;
    const salt = salt_buf[0..salt_len];

    const client_first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO";
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const client_final_wo_proof = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";

    var proof: [32]u8 = undefined;
    try scramProof("pencil", salt, 4096, client_first_bare, server_first, client_final_wo_proof, &proof);

    var proof_b64: [64]u8 = undefined;
    const got = std.base64.standard.Encoder.encode(&proof_b64, &proof);
    try std.testing.expectEqualStrings("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", got);

    var sig: [32]u8 = undefined;
    try scramServerSignature("pencil", salt, 4096, client_first_bare, server_first, client_final_wo_proof, &sig);
    var sig_b64: [64]u8 = undefined;
    const got_sig = std.base64.standard.Encoder.encode(&sig_b64, &sig);
    try std.testing.expectEqualStrings("6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", got_sig);
}

test "文本解码：布尔/整数/时间/bytea/普通文本" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    try std.testing.expectEqual(true, (try decodeText(ar, "t")).asBool().?);
    try std.testing.expectEqual(false, (try decodeText(ar, "f")).asBool().?);
    try std.testing.expectEqual(@as(i64, -42), (try decodeText(ar, "-42")).asI64().?);
    try std.testing.expectEqual(@as(u8, 0x0A), (try decodeText(ar, "\\x0a")).asBlob().?[0]);

    const dt = (try decodeText(ar, "2024-05-06 07:08:09")).asDatetime().?;
    try std.testing.expectEqual(@as(i32, 2024), dt.year);
    try std.testing.expectEqual(@as(u8, 7), dt.hour);

    // 小数保持文本（避免把 numeric 的精度改掉）
    const dec_text = (try decodeText(ar, "12.3400")).asText().?;
    try std.testing.expectEqualStrings("12.3400", dec_text);
}

test "CommandComplete 影响行数解析" {
    try std.testing.expectEqual(@as(u64, 3), ConnLike.parseAffected("INSERT 0 3"));
    try std.testing.expectEqual(@as(u64, 2), ConnLike.parseAffected("UPDATE 2"));
    try std.testing.expectEqual(@as(u64, 0), ConnLike.parseAffected("CREATE TABLE"));
    try std.testing.expectEqual(@as(u64, 7), ConnLike.parseAffected("SELECT 7"));
}

/// 测试壳：复用 `Conn.parseAffected`（它是纯函数，但挂在 `Conn` 上）。
const ConnLike = struct {
    const parseAffected = Conn.parseAffected;
};

test "参数格式化：布尔 t/f、时间、NULL" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("t", try formatParam(&buf, .{ .boolean = true }));
    try std.testing.expectEqualStrings("f", try formatParam(&buf, .{ .boolean = false }));
    try std.testing.expectEqualStrings("123", try formatParam(&buf, .{ .int = 123 }));
    const dt = try formatParam(&buf, .{ .datetime = .{ .year = 2024, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5 } });
    try std.testing.expect(std.mem.startsWith(u8, dt, "2024-01-02 03:04:05"));
}
