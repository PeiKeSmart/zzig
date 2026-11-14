//! Oracle 驱动（**OCI 动态加载**，不链 `libclntsh` / `oci.dll`）。
//!
//! ## 为什么走 OCI 而不是自实现 TNS/TTC
//!
//! Oracle 的线上协议是无公开规范的私有协议（TNS 包 + TTC 消息 + O5LOGON 认证），
//! 自实现要几千行，且**本机没有实例、也没有抓包**，写出来只能"看着像能跑"——
//! 真连必然失败，且将来排查极难。OCI 相反：句柄全是**不透明指针**（无结构体 ABI 风险），
//! 只绑 18 个函数，值统一按 `SQLT_STR` 走字符串（不碰 `OCIDate` / `OCINumber` 的编解码），
//! 一旦目标机放了 Instant Client 就能真正跑 SQL。
//!
//! 代价（写清楚，不藏）：**目标机需要一份 Oracle Instant Client**（免费，Basic 包即可）。
//! 缺库时 `Lib.load` 返回 `error.OracleNotAvailable`（**不是 panic**），并打印 dll 该放哪。
//!
//! ## OCI 常量来源
//!
//! 句柄类型 / 描述符类型 / 属性号**不是猜的**，取自 oci.h（与 ODPI-C 的 `dpiImpl.h` 中
//! `DPI_OCI_*` 定义逐项核对过）：`HTYPE_*` 1..10、`DTYPE_PARAM=53`、`ATTR_DATA_SIZE=1`、
//! `ATTR_DATA_TYPE=2`、`ATTR_NAME=4`、`ATTR_ENV=5`、`ATTR_SERVER=6`、`ATTR_SESSION=7`、
//! `ATTR_ROW_COUNT=9`、`ATTR_PREFETCH_ROWS=11`、`ATTR_PARAM_COUNT=18`。
//!
//! ## 取值口径
//!
//! - **所有列按 `SQLT_STR` 取**：Oracle 负责把 NUMBER/DATE/RAW 转成文本，值类型统一成
//!   `Value.text`，由 ORM 按模型列类型再转（与 TDengine/ClickHouse/DuckDB 的文本口径一致）。
//!   为避免会话 NLS 影响解析，`open` 时尽力把 `NLS_DATE_FORMAT` / `NLS_TIMESTAMP_FORMAT`
//!   设成 `YYYY-MM-DD HH24:MI:SS[.FF6]`（设不上只告警，不阻断）。
//! - 列缓冲区大小按 `OCI_ATTR_DATA_SIZE * 4` 估算并夹在 `[64, 32767]`：
//!   `32767` 是 `SQLT_STR` 单列上限，**超过会被截断**（CLOB/LONG 请改用 `DBMS_LOB.SUBSTR` 分段取）。
//! - 参数**不走 `OCIBindByPos`**，而是客户端内联（`inline.zig`，跳过字符串/注释里的 `?`）——
//!   少一整套 bind 结构体 ABI，代价是失去服务端游标复用（每次仍会 `OCIStmtPrepare`）。
//!
//! ## 已知边界
//! - `lastInsertId` 恒 0：Oracle 没有自增列，XCode 侧用 `SEQ_{表名}.CURRVAL` 或 `RETURNING`
//!   （`sqlbuild` 已按 Oracle 方言生成序列表达式）；
//! - 每条 SQL 都新建/释放语句句柄（**不做语句缓存**）：OCI 的语句句柄绑定了会话上下文，
//!   缓存收益远小于 MySQL/PG 的 wire 级预处理复用，先按简单可靠来；
//! - 二进制大对象按文本取（会走 `SQLT_STR` 转换），超大 BLOB 请走 `DBMS_LOB` 分段。

const std = @import("std");
const dyn = @import("../dyn.zig");
const sql_inline = @import("inline.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;

pub const default_port: u16 = 1521;

// ── OCI 返回码 ──────────────────────────────────────────────────────────────
const OCI_SUCCESS: c_int = 0;
const OCI_SUCCESS_WITH_INFO: c_int = 1;
const OCI_NO_DATA: c_int = 100;
const OCI_ERROR: c_int = -1;
const OCI_INVALID_HANDLE: c_int = -2;

// ── 句柄类型（oci.h `OCI_HTYPE_*`）──────────────────────────────────────────
const OCI_HTYPE_ENV: u32 = 1;
const OCI_HTYPE_ERROR: u32 = 2;
const OCI_HTYPE_SVCCTX: u32 = 3;
const OCI_HTYPE_STMT: u32 = 4;
const OCI_HTYPE_DEFINE: u32 = 6;
const OCI_HTYPE_SERVER: u32 = 8;
const OCI_HTYPE_SESSION: u32 = 9;

/// 参数/列描述符类型（oci.h `OCI_DTYPE_PARAM`）
const OCI_DTYPE_PARAM: u32 = 53;

// ── 属性号（oci.h `OCI_ATTR_*`；分「参数空间」与「句柄空间」两套）───────────
const OCI_ATTR_DATA_SIZE: u32 = 1; // 参数空间：列定义的最大字节数
const OCI_ATTR_NAME: u32 = 4; // 参数空间：列名（OraText*）
const OCI_ATTR_SERVER: u32 = 6; // svcctx：绑服务器句柄
const OCI_ATTR_SESSION: u32 = 7; // svcctx：绑会话句柄
const OCI_ATTR_ROW_COUNT: u32 = 9; // stmt：影响行数
const OCI_ATTR_PREFETCH_ROWS: u32 = 11; // stmt：预取行数
const OCI_ATTR_PARAM_COUNT: u32 = 18; // stmt：结果列数
const OCI_ATTR_USERNAME: u32 = 22; // session：用户名
const OCI_ATTR_PASSWORD: u32 = 23; // session：口令

// ── 模式 / 数据类型 ─────────────────────────────────────────────────────────
const OCI_DEFAULT: u32 = 0;
const OCI_THREADED: u32 = 0x01;
const OCI_CRED_RDBMS: u32 = 1;
const OCI_NTV_SYNTAX: u32 = 1;
/// `OCIStmtFetch2` 的取行方向
const OCI_FETCH_NEXT: u16 = 2;
/// `SQLT_STR`：让 Oracle 把值转成 NUL 结尾文本（= 5）
const SQLT_STR: u16 = 5;

pub const Error = error{
    /// 找不到 `oci.dll` / `libclntsh.so`（把 Instant Client 放到 exe 同目录或 PATH）
    OracleNotAvailable,
    /// `OCIEnvCreate` / 句柄分配失败
    EnvFailed,
    /// `OCIServerAttach` 失败（网络 / service name / listener）
    ConnectFailed,
    /// 认证失败（用户 / 口令 / 权限）
    LogonFailed,
    /// SQL 执行失败（具体原因在 `lastError()`）
    QueryFailed,
    /// 结果集解析遇到无法解释的形态
    Protocol,
};

/// 动态加载得到的 OCI 函数表（只含本驱动用到的 18 个入口）。
pub const Lib = struct {
    module: dyn.Module,
    source: []const u8,

    env_create: *const fn (*?*anyopaque, u32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, usize, ?*?*anyopaque) callconv(.c) c_int,
    handle_alloc: *const fn (?*const anyopaque, *?*anyopaque, u32, usize, ?*?*anyopaque) callconv(.c) c_int,
    handle_free: *const fn (?*anyopaque, u32) callconv(.c) c_int,
    server_attach: *const fn (?*anyopaque, ?*anyopaque, ?[*]const u8, i32, u32) callconv(.c) c_int,
    server_detach: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) c_int,
    session_begin: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, u32, u32) callconv(.c) c_int,
    session_end: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, u32) callconv(.c) c_int,
    attr_set: *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, ?*anyopaque) callconv(.c) c_int,
    attr_get: *const fn (?*const anyopaque, u32, ?*anyopaque, ?*u32, u32, ?*anyopaque) callconv(.c) c_int,
    stmt_prepare: *const fn (?*anyopaque, ?*anyopaque, ?[*]const u8, u32, u32, u32) callconv(.c) c_int,
    stmt_execute: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, u32, u32, ?*const anyopaque, ?*anyopaque, u32) callconv(.c) c_int,
    stmt_fetch2: *const fn (?*anyopaque, ?*anyopaque, u32, u16, i32, u32) callconv(.c) c_int,
    define_by_pos: *const fn (?*anyopaque, *?*anyopaque, ?*anyopaque, u32, ?*anyopaque, i32, u16, ?*anyopaque, ?*u16, ?*u16, u32) callconv(.c) c_int,
    param_get: *const fn (?*const anyopaque, u32, ?*anyopaque, *?*anyopaque, u32) callconv(.c) c_int,
    descriptor_free: *const fn (?*anyopaque, u32) callconv(.c) c_int,
    error_get: *const fn (?*anyopaque, u32, ?[*]u8, ?*i32, [*]u8, u32, u32) callconv(.c) c_int,
    trans_commit: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) c_int,
    trans_rollback: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) c_int,

    /// 按「exe 目录 → 裸名字」找库；全部失败返回 `error.OracleNotAvailable`。
    pub fn load(gpa: std.mem.Allocator) !Lib {
        const builtin = @import("builtin");
        const names: []const []const u8 = if (builtin.os.tag == .windows)
            &.{"oci.dll"}
        else if (builtin.os.tag == .macos)
            &.{ "libclntsh.dylib", "libclntsh.dylib.1" }
        else
            &.{ "libclntsh.so", "libclntsh.so.21.1", "libclntsh.so.19.1", "libclntsh.so.12.1", "libclntsh.so.11.1" };

        const dir_buf: ?[]u8 = dyn.exeDirAlloc(gpa) catch null;
        defer if (dir_buf) |d| gpa.free(d);

        for (names) |name| {
            if (dir_buf) |dir| {
                if (std.fs.path.join(gpa, &.{ dir, name })) |full| {
                    defer gpa.free(full);
                    if (tryFrom(gpa, full)) |lib| return lib;
                } else |_| {}
            }
            if (tryFrom(gpa, name)) |lib| return lib;
        }
        std.debug.print(
            "[zzig.oracle] 未找到 Oracle 客户端库（尝试过：{s}）；" ++
                "请下载 Oracle Instant Client（Basic 包）并把 oci.dll 放到 exe 同目录或 PATH\n",
            .{if (builtin.os.tag == .windows) "oci.dll" else "libclntsh.so"},
        );
        return Error.OracleNotAvailable;
    }

    fn tryFrom(gpa: std.mem.Allocator, path: []const u8) ?Lib {
        const module = dyn.load(gpa, path) orelse return null;
        const lib: Lib = .{
            .module = module,
            .source = path,
            .env_create = module.lookup(@TypeOf(@as(Lib, undefined).env_create), "OCIEnvCreate") orelse return fail(gpa, module),
            .handle_alloc = module.lookup(@TypeOf(@as(Lib, undefined).handle_alloc), "OCIHandleAlloc") orelse return fail(gpa, module),
            .handle_free = module.lookup(@TypeOf(@as(Lib, undefined).handle_free), "OCIHandleFree") orelse return fail(gpa, module),
            .server_attach = module.lookup(@TypeOf(@as(Lib, undefined).server_attach), "OCIServerAttach") orelse return fail(gpa, module),
            .server_detach = module.lookup(@TypeOf(@as(Lib, undefined).server_detach), "OCIServerDetach") orelse return fail(gpa, module),
            .session_begin = module.lookup(@TypeOf(@as(Lib, undefined).session_begin), "OCISessionBegin") orelse return fail(gpa, module),
            .session_end = module.lookup(@TypeOf(@as(Lib, undefined).session_end), "OCISessionEnd") orelse return fail(gpa, module),
            .attr_set = module.lookup(@TypeOf(@as(Lib, undefined).attr_set), "OCIAttrSet") orelse return fail(gpa, module),
            .attr_get = module.lookup(@TypeOf(@as(Lib, undefined).attr_get), "OCIAttrGet") orelse return fail(gpa, module),
            .stmt_prepare = module.lookup(@TypeOf(@as(Lib, undefined).stmt_prepare), "OCIStmtPrepare") orelse return fail(gpa, module),
            .stmt_execute = module.lookup(@TypeOf(@as(Lib, undefined).stmt_execute), "OCIStmtExecute") orelse return fail(gpa, module),
            .stmt_fetch2 = module.lookup(@TypeOf(@as(Lib, undefined).stmt_fetch2), "OCIStmtFetch2") orelse return fail(gpa, module),
            .define_by_pos = module.lookup(@TypeOf(@as(Lib, undefined).define_by_pos), "OCIDefineByPos") orelse return fail(gpa, module),
            .param_get = module.lookup(@TypeOf(@as(Lib, undefined).param_get), "OCIParamGet") orelse return fail(gpa, module),
            .descriptor_free = module.lookup(@TypeOf(@as(Lib, undefined).descriptor_free), "OCIDescriptorFree") orelse return fail(gpa, module),
            .error_get = module.lookup(@TypeOf(@as(Lib, undefined).error_get), "OCIErrorGet") orelse return fail(gpa, module),
            .trans_commit = module.lookup(@TypeOf(@as(Lib, undefined).trans_commit), "OCITransCommit") orelse return fail(gpa, module),
            .trans_rollback = module.lookup(@TypeOf(@as(Lib, undefined).trans_rollback), "OCITransRollback") orelse return fail(gpa, module),
        };
        return lib;
    }

    fn fail(gpa: std.mem.Allocator, module: dyn.Module) ?Lib {
        module.close(gpa);
        return null;
    }
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    user: []const u8 = "",
    password: []const u8 = "",
    /// service name 或 SID（一般就是库名）
    service: []const u8 = "",
    /// 完整 DSN / TNS 描述符（非空时**优先**，形如 `host:port/svc`、
    /// `//host:port/svc`、`(DESCRIPTION=(ADDRESS=...)(CONNECT_DATA=...))`、或 tnsnames 里的别名）
    dsn: []const u8 = "",
    /// 预取行数（减少往返；0 = 不设）
    prefetch_rows: u32 = 100,
};

/// 拼 DSN：`dsn` 非空直接用；否则 `host:port/service`（service 为空则 `host:port`）。
pub fn buildDsnAlloc(a: std.mem.Allocator, opts: Options) ![]u8 {
    if (opts.dsn.len > 0) return a.dupe(u8, opts.dsn);
    if (opts.service.len > 0) {
        return std.fmt.allocPrint(a, "{s}:{d}/{s}", .{ opts.host, opts.port, opts.service });
    }
    return std.fmt.allocPrint(a, "{s}:{d}", .{ opts.host, opts.port });
}

/// OCI 返回码 → 语义（`OCI_SUCCESS_WITH_INFO` 按成功处理，与官方示例一致）。
fn isOk(status: c_int) bool {
    return status == OCI_SUCCESS or status == OCI_SUCCESS_WITH_INFO;
}

/// 查询结果：`ok` = 影响行数（非 SELECT），`rows` = 结果行。
pub const Result = union(enum) {
    ok: u64,
    rows: []const Row,
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    /// 借用的函数表（生命周期由调用方保证 ≥ Conn）
    lib: *Lib,
    env: ?*anyopaque = null,
    err: ?*anyopaque = null,
    srv: ?*anyopaque = null,
    svc: ?*anyopaque = null,
    auth: ?*anyopaque = null,
    /// 每条语句都设一次预取行数（0 = 不设）
    prefetch_rows: u32 = 0,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,

    pub fn open(gpa: std.mem.Allocator, lib: *Lib, opts: Options) !Conn {
        var self = Conn{ .gpa = gpa, .lib = lib };

        // 1) 环境句柄（多线程模式：连接会被多个线程使用）
        if (!isOk(lib.env_create(&self.env, OCI_THREADED, null, null, null, null, 0, null))) {
            self.setError("Oracle 创建 OCI 环境失败（OCIEnvCreate 返回错误）", .{});
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            return Error.EnvFailed;
        }
        std.debug.assert(self.env != null);

        // 2) 错误句柄（后面所有失败都要靠它取 ORA 文本）
        if (!isOk(lib.handle_alloc(self.env, &self.err, OCI_HTYPE_ERROR, 0, null))) {
            self.setError("Oracle 分配错误句柄失败", .{});
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.EnvFailed;
        }

        const dsn = try buildDsnAlloc(gpa, opts);
        defer gpa.free(dsn);

        // 3) 服务器句柄 + attach（真正的 TCP 连接在这里建立）
        if (!isOk(lib.handle_alloc(self.env, &self.srv, OCI_HTYPE_SERVER, 0, null))) {
            self.setError("Oracle 分配服务器句柄失败（DSN={s}）", .{dsn});
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.EnvFailed;
        }
        const attach = lib.server_attach(self.srv, self.err, dsn.ptr, @intCast(dsn.len), OCI_DEFAULT);
        if (!isOk(attach)) {
            self.setError("Oracle 连接失败（DSN={s}，可能是网络不通 / listener 未起 / service name 不对）", .{dsn});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.ConnectFailed;
        }

        // 4) 服务上下文 + 会话句柄
        if (!isOk(lib.handle_alloc(self.env, &self.svc, OCI_HTYPE_SVCCTX, 0, null)) or
            !isOk(lib.handle_alloc(self.env, &self.auth, OCI_HTYPE_SESSION, 0, null)))
        {
            self.setError("Oracle 分配服务/会话句柄失败", .{});
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.EnvFailed;
        }
        if (!isOk(lib.attr_set(self.svc, OCI_HTYPE_SVCCTX, self.srv, 0, OCI_ATTR_SERVER, self.err))) {
            self.setError("Oracle 把服务器句柄绑到服务上下文失败", .{});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.ConnectFailed;
        }

        if (opts.user.len > 0) {
            if (!isOk(lib.attr_set(self.auth, OCI_HTYPE_SESSION, @ptrCast(opts.user.ptr), @intCast(opts.user.len), OCI_ATTR_USERNAME, self.err)) or
                !isOk(lib.attr_set(self.auth, OCI_HTYPE_SESSION, @ptrCast(opts.password.ptr), @intCast(opts.password.len), OCI_ATTR_PASSWORD, self.err)))
            {
                self.setError("Oracle 设置用户名/口令失败（用户 {s}）", .{opts.user});
                self.appendOciError();
                std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
                self.closeHandles();
                return Error.LogonFailed;
            }
            const begin = lib.session_begin(self.svc, self.err, self.auth, OCI_CRED_RDBMS, OCI_DEFAULT);
            if (!isOk(begin)) {
                self.setError("Oracle 登录失败（用户 {s}，DSN={s}）", .{ opts.user, dsn });
                self.appendOciError();
                std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
                self.closeHandles();
                return Error.LogonFailed;
            }
            if (!isOk(lib.attr_set(self.svc, OCI_HTYPE_SVCCTX, self.auth, 0, OCI_ATTR_SESSION, self.err))) {
                self.setError("Oracle 把会话句柄绑到服务上下文失败（用户 {s}）", .{opts.user});
                self.appendOciError();
                std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
                self.closeHandles();
                return Error.LogonFailed;
            }
        }

        // 5) 会话级 NLS 日期格式（尽力而为：设不上只告警，因为只影响「日期转文本」的可读性）
        self.execRaw("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'") catch {
            std.debug.print("[zzig.oracle] 设置 NLS_DATE_FORMAT 失败（不影响连接，日期文本格式可能随服务端默认）：{s}\n", .{self.lastError()});
        };
        self.execRaw("ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF6'") catch {
            std.debug.print("[zzig.oracle] 设置 NLS_TIMESTAMP_FORMAT 失败（同上）：{s}\n", .{self.lastError()});
        };

        self.prefetch_rows = opts.prefetch_rows;
        return self;
    }

    pub fn deinit(self: *Conn) void {
        if (self.auth != null and self.svc != null) {
            _ = self.lib.session_end(self.svc, self.err, self.auth, OCI_DEFAULT);
        }
        self.closeHandles();
    }

    fn closeHandles(self: *Conn) void {
        if (self.srv != null) {
            _ = self.lib.server_detach(self.srv, self.err, OCI_DEFAULT);
            _ = self.lib.handle_free(self.srv, OCI_HTYPE_SERVER);
            self.srv = null;
        }
        if (self.auth != null) {
            _ = self.lib.handle_free(self.auth, OCI_HTYPE_SESSION);
            self.auth = null;
        }
        if (self.svc != null) {
            _ = self.lib.handle_free(self.svc, OCI_HTYPE_SVCCTX);
            self.svc = null;
        }
        if (self.err != null) {
            _ = self.lib.handle_free(self.err, OCI_HTYPE_ERROR);
            self.err = null;
        }
        if (self.env != null) {
            _ = self.lib.handle_free(self.env, OCI_HTYPE_ENV);
            self.env = null;
        }
    }

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// Oracle 没有自增列：恒 0（要回写 ID 用 `RETURNING ... INTO` 或序列 `CURRVAL`）。
    pub fn lastInsertId(self: *const Conn) i64 {
        _ = self;
        return 0;
    }

    fn setError(self: *Conn, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch {
            self.err_len = @min(self.err_buf.len, 200);
            return;
        };
        self.err_len = text.len;
    }

    /// 把最近一次 OCI 错误（ORA-xxxxx 文本）追加到 `lastError()` 后面。
    fn appendOciError(self: *Conn) void {
        if (self.err == null) return;
        var buf: [400]u8 = undefined;
        var code: i32 = 0;
        const rc = self.lib.error_get(self.err, 1, null, &code, &buf, @intCast(buf.len), OCI_HTYPE_ERROR);
        if (rc == OCI_NO_DATA or rc == OCI_INVALID_HANDLE) return;
        const msg = std.mem.sliceTo(&buf, 0);
        const add = std.fmt.bufPrint(self.err_buf[self.err_len..], "（ORA 详情：{s}）", .{msg}) catch return;
        self.err_len += add.len;
    }

    fn newStmt(self: *Conn) !?*anyopaque {
        var stmt: ?*anyopaque = null;
        if (!isOk(self.lib.handle_alloc(self.env, &stmt, OCI_HTYPE_STMT, 0, null))) return Error.EnvFailed;
        return stmt;
    }

    /// 执行一条**无参数**的 SQL，丢弃结果（`ALTER SESSION` 这类设置语句用）。
    fn execRaw(self: *Conn, sql: []const u8) !void {
        var buf: [1024]u8 = undefined;
        if (sql.len >= buf.len) return Error.Protocol;
        @memcpy(buf[0..sql.len], sql);
        const stmt = try self.newStmt();
        defer _ = self.lib.handle_free(stmt, OCI_HTYPE_STMT);
        if (!isOk(self.lib.stmt_prepare(stmt, self.err, &buf, @intCast(sql.len), OCI_NTV_SYNTAX, OCI_DEFAULT))) {
            self.setError("Oracle 预编译失败（{s}）", .{sql[0..@min(sql.len, 120)]});
            self.appendOciError();
            return Error.QueryFailed;
        }
        if (!isOk(self.lib.stmt_execute(self.svc, stmt, self.err, 1, 0, null, null, OCI_DEFAULT))) {
            self.setError("Oracle 执行失败（{s}）", .{sql[0..@min(sql.len, 120)]});
            self.appendOciError();
            return Error.QueryFailed;
        }
    }

    /// 执行写语句，返回影响行数。
    pub fn exec(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !u64 {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        const stmt = try self.newStmt();
        defer _ = self.lib.handle_free(stmt, OCI_HTYPE_STMT);

        if (!isOk(self.lib.stmt_prepare(stmt, self.err, text.ptr, @intCast(text.len), OCI_NTV_SYNTAX, OCI_DEFAULT))) {
            self.setError("Oracle 预编译失败（{s}）", .{text[0..@min(text.len, 200)]});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }
        if (!isOk(self.lib.stmt_execute(self.svc, stmt, self.err, 1, 0, null, null, OCI_DEFAULT))) {
            self.setError("Oracle 执行失败（{s}）", .{text[0..@min(text.len, 200)]});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }

        var rows: u32 = 0;
        var size: u32 = @sizeOf(u32);
        if (!isOk(self.lib.attr_get(stmt, OCI_HTYPE_STMT, @ptrCast(&rows), &size, OCI_ATTR_ROW_COUNT, self.err))) {
            // 影响行数取不到不算失败（DDL 本来就没有行数）
            return 0;
        }
        return rows;
    }

    /// 查询：所有列按 `SQLT_STR` 取成文本（见文件头「取值口径」）。
    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        const stmt = try self.newStmt();
        defer _ = self.lib.handle_free(stmt, OCI_HTYPE_STMT);

        if (!isOk(self.lib.stmt_prepare(stmt, self.err, text.ptr, @intCast(text.len), OCI_NTV_SYNTAX, OCI_DEFAULT))) {
            self.setError("Oracle 预编译失败（{s}）", .{text[0..@min(text.len, 200)]});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }
        // iters=0：进入「定义/取行」模式（SELECT 的标准用法）
        if (!isOk(self.lib.stmt_execute(self.svc, stmt, self.err, 0, 0, null, null, OCI_DEFAULT))) {
            self.setError("Oracle 执行失败（{s}）", .{text[0..@min(text.len, 200)]});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }

        // 预取只是性能开关，设失败不影响正确性（必须在 prepare 之后设）
        if (self.prefetch_rows > 0) {
            _ = self.lib.attr_set(stmt, OCI_HTYPE_STMT, @ptrCast(&self.prefetch_rows), @sizeOf(u32), OCI_ATTR_PREFETCH_ROWS, self.err);
        }

        var col_count: u32 = 0;
        var count_size: u32 = @sizeOf(u32);
        if (!isOk(self.lib.attr_get(stmt, OCI_HTYPE_STMT, @ptrCast(&col_count), &count_size, OCI_ATTR_PARAM_COUNT, self.err))) {
            // 没有结果列 = DML/DDL：返回影响行数
            var rows: u32 = 0;
            var sz: u32 = @sizeOf(u32);
            _ = self.lib.attr_get(stmt, OCI_HTYPE_STMT, @ptrCast(&rows), &sz, OCI_ATTR_ROW_COUNT, self.err);
            return .{ .ok = rows };
        }
        if (col_count == 0) return .{ .ok = 0 };

        const n: usize = col_count;
        const names = try arena.alloc([]const u8, n);
        const buffers = try arena.alloc([]u8, n);
        const buflens = try arena.alloc(usize, n);
        const inds = try arena.alloc(i16, n);
        const ilens = try arena.alloc(u16, n);
        const rcodes = try arena.alloc(u16, n);

        for (0..n) |i| {
            const pos: u32 = @intCast(i + 1);
            names[i] = try self.columnNameAlloc(arena, stmt, pos) orelse try std.fmt.allocPrint(arena, "COL{d}", .{i + 1});
            const data_size = self.columnDataSize(stmt, pos);
            // SQLT_STR 会把值转成文本，文本通常比二进制形式长 → 按 4 倍估算并夹在 [64, 32767]
            const want: usize = @min(@max(@as(usize, data_size) * 4, 64), 32767);
            buflens[i] = want;
            buffers[i] = try arena.alloc(u8, want);
            inds[i] = 0;
            ilens[i] = 0;
            rcodes[i] = 0;

            var defn: ?*anyopaque = null;
            const rc = self.lib.define_by_pos(
                stmt,
                &defn,
                self.err,
                pos,
                @ptrCast(buffers[i].ptr),
                @intCast(buflens[i]),
                SQLT_STR,
                @ptrCast(&inds[i]),
                @ptrCast(&ilens[i]),
                @ptrCast(&rcodes[i]),
                OCI_DEFAULT,
            );
            if (!isOk(rc)) {
                self.setError("Oracle 定义第 {d} 列（{s}）失败", .{ pos, names[i] });
                self.appendOciError();
                std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
                return Error.QueryFailed;
            }
        }

        var rows: std.ArrayList(Row) = .empty;
        while (true) {
            const frc = self.lib.stmt_fetch2(stmt, self.err, 1, OCI_FETCH_NEXT, 0, OCI_DEFAULT);
            if (frc == OCI_NO_DATA) break;
            if (!isOk(frc)) {
                self.setError("Oracle 取行失败（第 {d} 行）", .{rows.items.len + 1});
                self.appendOciError();
                std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
                return Error.QueryFailed;
            }

            const values = try arena.alloc(Value, n);
            for (0..n) |i| {
                if (inds[i] == -1) {
                    values[i] = .null;
                    continue;
                }
                const len: usize = @min(@as(usize, ilens[i]), buflens[i]);
                // SQLT_STR 的返回值可能不带 0（按 rlen 为准），这里只取 rlen 长度
                values[i] = .{ .text = try arena.dupe(u8, buffers[i][0..len]) };
            }
            try rows.append(arena, .{ .names = names, .values = values });
        }

        return .{ .rows = try rows.toOwnedSlice(arena) };
    }

    /// 列名（Oracle 返回大写；`Row.get` 是大小写不敏感的，不用改写）。
    fn columnNameAlloc(self: *Conn, a: std.mem.Allocator, stmt: ?*anyopaque, pos: u32) !?[]const u8 {
        var param: ?*anyopaque = null;
        if (!isOk(self.lib.param_get(stmt, OCI_HTYPE_STMT, self.err, &param, pos))) return null;
        defer _ = self.lib.descriptor_free(param, OCI_DTYPE_PARAM);

        var name_ptr: ?[*]u8 = null;
        var name_len: u32 = 0;
        if (!isOk(self.lib.attr_get(param, OCI_DTYPE_PARAM, @ptrCast(&name_ptr), &name_len, OCI_ATTR_NAME, self.err))) return null;
        const p = name_ptr orelse return null;
        if (name_len == 0) return null;
        return try a.dupe(u8, p[0..name_len]);
    }

    /// 列的「最大字节数」（没有就按 0，由调用方夹到最小值）。
    fn columnDataSize(self: *Conn, stmt: ?*anyopaque, pos: u32) u16 {
        var param: ?*anyopaque = null;
        if (!isOk(self.lib.param_get(stmt, OCI_HTYPE_STMT, self.err, &param, pos))) return 0;
        defer _ = self.lib.descriptor_free(param, OCI_DTYPE_PARAM);

        var size: u16 = 0;
        var sz: u32 = @sizeOf(u16);
        if (!isOk(self.lib.attr_get(param, OCI_DTYPE_PARAM, @ptrCast(&size), &sz, OCI_ATTR_DATA_SIZE, self.err))) return 0;
        return size;
    }

    /// 探活：`SELECT 1 FROM DUAL` 能跑通即认为连接可用。
    pub fn ping(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = try self.queryAlloc(arena.allocator(), "SELECT 1 FROM DUAL", &.{});
    }

    /// 服务端版本（失败返回空串；诊断用）。
    pub fn serverVersionAlloc(self: *Conn, a: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = self.queryAlloc(arena.allocator(), "SELECT banner FROM v$version WHERE ROWNUM = 1", &.{}) catch {
            return a.dupe(u8, "");
        };
        switch (r) {
            .rows => |rows| {
                if (rows.len > 0 and rows[0].values.len > 0) {
                    if (rows[0].values[0].asText()) |t| return a.dupe(u8, t);
                }
                return a.dupe(u8, "");
            },
            .ok => return a.dupe(u8, ""),
        }
    }

    /// 事务：OCI 也认 SQL 文本的 `COMMIT` / `ROLLBACK`，但原生调用更快且不占语句句柄。
    pub fn commit(self: *Conn) !void {
        if (!isOk(self.lib.trans_commit(self.svc, self.err, OCI_DEFAULT))) {
            self.setError("Oracle 提交失败", .{});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }
    }

    pub fn rollback(self: *Conn) !void {
        if (!isOk(self.lib.trans_rollback(self.svc, self.err, OCI_DEFAULT))) {
            self.setError("Oracle 回滚失败", .{});
            self.appendOciError();
            std.debug.print("[zzig.oracle] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }
    }
};

// ── 用例（都不需要真实 Oracle 实例）────────────────────────────────────────

test "Oracle - DSN 构建：dsn 优先 / host:port/service / 无 service" {
    const a = std.testing.allocator;

    const d1 = try buildDsnAlloc(a, .{ .dsn = "//10.0.0.5:1522/ORCLPDB1" });
    defer a.free(d1);
    try std.testing.expectEqualStrings("//10.0.0.5:1522/ORCLPDB1", d1);

    const d2 = try buildDsnAlloc(a, .{ .host = "db1", .port = 1521, .service = "ORCL" });
    defer a.free(d2);
    try std.testing.expectEqualStrings("db1:1521/ORCL", d2);

    const d3 = try buildDsnAlloc(a, .{ .host = "db1", .port = 1522 });
    defer a.free(d3);
    try std.testing.expectEqualStrings("db1:1522", d3);
}

test "Oracle - 缺客户端库时明确报 OracleNotAvailable（不是 panic）" {
    // 本机没有 oci.dll / libclntsh：必须得到明确错误；装了客户端的机器则应当能加载成功
    if (Lib.load(std.testing.allocator)) |lib| {
        var l = lib;
        l.module.close(std.testing.allocator);
    } else |e| {
        try std.testing.expectEqual(@as(anyerror, Error.OracleNotAvailable), e);
    }
}

test "Oracle - OCI 状态码映射" {
    try std.testing.expect(isOk(OCI_SUCCESS));
    try std.testing.expect(isOk(OCI_SUCCESS_WITH_INFO));
    try std.testing.expect(!isOk(OCI_ERROR));
    try std.testing.expect(!isOk(OCI_INVALID_HANDLE));
    try std.testing.expect(!isOk(OCI_NO_DATA));
}

test "Oracle - 常量与 oci.h 对齐（写死值防止手滑改错）" {
    try std.testing.expectEqual(@as(u32, 53), OCI_DTYPE_PARAM);
    try std.testing.expectEqual(@as(u32, 1), OCI_ATTR_DATA_SIZE);
    try std.testing.expectEqual(@as(u32, 4), OCI_ATTR_NAME);
    try std.testing.expectEqual(@as(u32, 6), OCI_ATTR_SERVER);
    try std.testing.expectEqual(@as(u32, 7), OCI_ATTR_SESSION);
    try std.testing.expectEqual(@as(u32, 9), OCI_ATTR_ROW_COUNT);
    try std.testing.expectEqual(@as(u32, 18), OCI_ATTR_PARAM_COUNT);
    try std.testing.expectEqual(@as(u32, 22), OCI_ATTR_USERNAME);
    try std.testing.expectEqual(@as(u32, 23), OCI_ATTR_PASSWORD);
    try std.testing.expectEqual(@as(u16, 5), SQLT_STR);
}
