//! ODBC 驱动（**动态加载 `odbc32.dll` / `libodbc.so`，不链 odbc32.lib**）。
//!
//! ## 一家驱动覆盖 7 个方言
//!
//! `hana` / `firebird` / `db2` / `dameng`（达梦）/ `iris` / `access` / `sqlce` 在 C# 侧
//! （`DH.NCode.{Hana,Firebird,DB2,DaMeng,IRIS,Access,SqlCe}`）**都是走 OLE DB / ODBC 桥**，
//! 没有公开的自有线上协议可自实现（与 Oracle 的处境不同：ODBC 是公开标准）。
//! 所以这里只做一个 ODBC 驱动，按连接串选驱动即可覆盖上面全部方言 —— 与 MySQL/PG/TDS 一样是
//! 「一个协议多个方言」，方言层的 SQL 生成仍由 `dialect.zig` 按 `Provider` 决定。
//!
//! ## 为什么是 UTF-16（W 变体）
//!
//! ODBC 的 A 变体按**系统 ANSI 代码页**（本机 936/GBK）解释字符串，中文列值/表名会随机器变形。
//! 这里统一走 `SQLDriverConnectW` / `SQLExecDirectW` / `SQLDescribeColW` + `SQL_C_WCHAR`，
//! 进出各做一次 UTF-8 ↔ UTF-16LE 转换（`std.unicode`），中文与任何非 ANSI 字符都不会被改写。
//!
//! ## 取值口径
//!
//! - **所有列按 `SQL_C_WCHAR` 取成文本**（与 Oracle 的 `SQLT_STR`、DuckDB 的 varchar 同口径），
//!   值类型统一 `Value.text`，由 ORM 按模型列类型再转；
//! - 列缓冲区按 `SQLDescribeCol` 的 `ColumnSize` 估算并夹在 `[64, 32767]` 字符：
//!   **超过会被截断**（CLOB/LONG 请改用 `SUBSTR` 分段取），截断时打一条日志（不静默）；
//! - 参数不走 `SQLBindParameter`，用客户端内联（`inline.zig`，跳过字符串/注释里的 `?`）。
//!
//! ## 事务
//!
//! ODBC 的默认是 **autocommit ON**（每条语句立即提交）。我们按 ORM 语义处理：
//! `begin()` 把 `SQL_ATTR_AUTOCOMMIT` 关掉 → `commit()`/`rollback()` 走 `SQLEndTran` 后**再打开**，
//! 这样「不在事务里的单条写入」仍然是立即落库的（不会因为忘记提交而静默丢数据）。
//!
//! ## 已知边界
//! - `lastInsertId` 恒 0：ODBC 没有统一的「自增回写」入口（各家要用 `SELECT @@IDENTITY` /
//!   `IDENT_CURRENT` / `SCOPE_IDENTITY()`，由方言层按需生成 SQL）；
//! - 没有连接池（ODBC 自己的连接池由驱动管理器负责，`SQL_ATTR_CONNECTION_POOLING` 不在这里开）；
//! - `serverVersionAlloc` 返回空串（`SQLGetInfo` 的 `SQL_DBMS_NAME`/`SQL_DBMS_VER` 要再绑两个函数，
//!   而版本探测对本类没有能力分支，不值当）。

const std = @import("std");
const dyn = @import("../dyn.zig");
const sql_inline = @import("inline.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;

// ── 句柄类型（sql.h `SQL_HANDLE_*`）──────────────────────────────────────────
const SQL_HANDLE_ENV: i16 = 1;
const SQL_HANDLE_DBC: i16 = 2;
const SQL_HANDLE_STMT: i16 = 3;

// ── 返回码（sql.h）──────────────────────────────────────────────────────────
const SQL_SUCCESS: i16 = 0;
const SQL_SUCCESS_WITH_INFO: i16 = 1;
const SQL_NO_DATA: i16 = 100;
const SQL_ERROR: i16 = -1;
const SQL_INVALID_HANDLE: i16 = -2;

// ── 环境/连接属性（sql.h）───────────────────────────────────────────────────
/// 必须设成 ODBC 3.x，否则 `SQLDriverConnect` 直接报 IM008
const SQL_ATTR_ODBC_VERSION: i32 = 200;
const SQL_OV_ODBC3: usize = 3;
/// 登录超时（秒）
const SQL_ATTR_LOGIN_TIMEOUT: i32 = 103;
/// autocommit 开关；Value 直接是指针大小的整数
const SQL_ATTR_AUTOCOMMIT: i32 = 102;
const SQL_AUTOCOMMIT_OFF: usize = 0;
const SQL_AUTOCOMMIT_ON: usize = 1;

// ── 连接/事务 ───────────────────────────────────────────────────────────────
/// `SQLDriverConnect` 的完成方式：不弹窗（服务/守护进程里弹窗＝卡死）
const SQL_DRIVER_NOPROMPT: u16 = 0;
const SQL_COMMIT: i16 = 0;
const SQL_ROLLBACK: i16 = 1;

// ── 取值类型 ────────────────────────────────────────────────────────────────
/// 目标缓冲是 UTF-16LE（`wchar_t`）
const SQL_C_WCHAR: i16 = -8;
/// `SQLGetData` 的 `StrLen_or_IndPtr`：该列为 NULL
const SQL_NULL_DATA: isize = -1;
/// 长度未知（长数据）
const SQL_NO_TOTAL: isize = -4;

pub const Error = error{
    /// 找不到 ODBC 驱动管理器（`odbc32.dll` / `libodbc.so`）
    OdbcNotAvailable,
    /// 环境/连接/语句句柄分配失败
    HandleFailed,
    /// `SQLDriverConnect` 失败（DSN 不存在 / 驱动没装 / 口令错）
    ConnectFailed,
    /// SQL 执行或取行失败（SQLSTATE + 驱动消息在 `lastError()`）
    QueryFailed,
    /// 结果集解析遇到无法解释的形态
    Protocol,
};

/// SQLRETURN / SQLSMALLINT
const SqlRet = i16;
/// SQLLEN / SQLULEN 是「指针大小整数」（64 位平台 = i64/usize）
const SqlLen = isize;

/// 动态加载得到的 ODBC 函数表（只含本驱动用到的 16 个入口）。
///
/// 注意符号名：Windows 的 `odbc32.dll` **只有 A/W 变体**（没有裸 `SQLDriverConnect`），
/// unixODBC 则是裸名，所以字符串类入口按「W → 裸名」顺序找。
pub const Lib = struct {
    module: dyn.Module,
    source: []const u8,

    alloc_handle: *const fn (i16, ?*anyopaque, *?*anyopaque) callconv(.c) SqlRet,
    free_handle: *const fn (i16, ?*anyopaque) callconv(.c) SqlRet,
    set_env_attr: *const fn (?*anyopaque, i32, ?*anyopaque, i32) callconv(.c) SqlRet,
    set_connect_attr: *const fn (?*anyopaque, i32, ?*anyopaque, i32) callconv(.c) SqlRet,
    driver_connect: *const fn (?*anyopaque, ?*anyopaque, [*]const u16, i16, ?[*]u16, i16, ?*i16, u16) callconv(.c) SqlRet,
    disconnect: *const fn (?*anyopaque) callconv(.c) SqlRet,
    end_tran: *const fn (i16, ?*anyopaque, i16) callconv(.c) SqlRet,
    exec_direct: *const fn (?*anyopaque, [*]const u16, i32) callconv(.c) SqlRet,
    num_result_cols: *const fn (?*anyopaque, *i16) callconv(.c) SqlRet,
    describe_col: *const fn (?*anyopaque, u16, ?[*]u16, i16, ?*i16, ?*i16, ?*usize, ?*i16, ?*i16) callconv(.c) SqlRet,
    fetch: *const fn (?*anyopaque) callconv(.c) SqlRet,
    get_data: *const fn (?*anyopaque, u16, i16, ?*anyopaque, SqlLen, *SqlLen) callconv(.c) SqlRet,
    row_count: *const fn (?*anyopaque, *SqlLen) callconv(.c) SqlRet,
    close_cursor: *const fn (?*anyopaque) callconv(.c) SqlRet,
    get_diag_rec: *const fn (i16, ?*anyopaque, i16, ?[*]u16, ?*i32, ?[*]u16, i16, ?*i16) callconv(.c) SqlRet,

    /// 按「exe 目录 → 裸名字」加载；全失败返回 `error.OdbcNotAvailable`。
    pub fn load(gpa: std.mem.Allocator) !Lib {
        const builtin = @import("builtin");
        const names: []const []const u8 = if (builtin.os.tag == .windows)
            &.{"odbc32.dll"}
        else if (builtin.os.tag == .macos)
            &.{ "libodbc.dylib", "libiodbc.dylib" }
        else
            &.{ "libodbc.so", "libodbc.so.2" };

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
            "[zzig.odbc] 未找到 ODBC 驱动管理器（{s}）；Windows 自带 odbc32.dll，" ++
                "Linux 请装 unixODBC（libodbc.so）并配置 /etc/odbcinst.ini\n",
            .{if (builtin.os.tag == .windows) "odbc32.dll" else "libodbc.so"},
        );
        return Error.OdbcNotAvailable;
    }

    fn tryFrom(gpa: std.mem.Allocator, path: []const u8) ?Lib {
        const module = dyn.load(gpa, path) orelse return null;
        const lib: Lib = .{
            .module = module,
            .source = path,
            .alloc_handle = module.lookup(@TypeOf(@as(Lib, undefined).alloc_handle), "SQLAllocHandle") orelse return fail(gpa, module),
            .free_handle = module.lookup(@TypeOf(@as(Lib, undefined).free_handle), "SQLFreeHandle") orelse return fail(gpa, module),
            .set_env_attr = module.lookup(@TypeOf(@as(Lib, undefined).set_env_attr), "SQLSetEnvAttr") orelse return fail(gpa, module),
            .set_connect_attr = module.lookup(@TypeOf(@as(Lib, undefined).set_connect_attr), "SQLSetConnectAttrW") orelse
                module.lookup(@TypeOf(@as(Lib, undefined).set_connect_attr), "SQLSetConnectAttr") orelse return fail(gpa, module),
            .driver_connect = module.lookup(@TypeOf(@as(Lib, undefined).driver_connect), "SQLDriverConnectW") orelse
                module.lookup(@TypeOf(@as(Lib, undefined).driver_connect), "SQLDriverConnect") orelse return fail(gpa, module),
            .disconnect = module.lookup(@TypeOf(@as(Lib, undefined).disconnect), "SQLDisconnect") orelse return fail(gpa, module),
            .end_tran = module.lookup(@TypeOf(@as(Lib, undefined).end_tran), "SQLEndTran") orelse return fail(gpa, module),
            .exec_direct = module.lookup(@TypeOf(@as(Lib, undefined).exec_direct), "SQLExecDirectW") orelse
                module.lookup(@TypeOf(@as(Lib, undefined).exec_direct), "SQLExecDirect") orelse return fail(gpa, module),
            .num_result_cols = module.lookup(@TypeOf(@as(Lib, undefined).num_result_cols), "SQLNumResultCols") orelse return fail(gpa, module),
            .describe_col = module.lookup(@TypeOf(@as(Lib, undefined).describe_col), "SQLDescribeColW") orelse
                module.lookup(@TypeOf(@as(Lib, undefined).describe_col), "SQLDescribeCol") orelse return fail(gpa, module),
            .fetch = module.lookup(@TypeOf(@as(Lib, undefined).fetch), "SQLFetch") orelse return fail(gpa, module),
            .get_data = module.lookup(@TypeOf(@as(Lib, undefined).get_data), "SQLGetData") orelse return fail(gpa, module),
            .row_count = module.lookup(@TypeOf(@as(Lib, undefined).row_count), "SQLRowCount") orelse return fail(gpa, module),
            .close_cursor = module.lookup(@TypeOf(@as(Lib, undefined).close_cursor), "SQLCloseCursor") orelse return fail(gpa, module),
            .get_diag_rec = module.lookup(@TypeOf(@as(Lib, undefined).get_diag_rec), "SQLGetDiagRecW") orelse
                module.lookup(@TypeOf(@as(Lib, undefined).get_diag_rec), "SQLGetDiagRec") orelse return fail(gpa, module),
        };
        return lib;
    }

    fn fail(gpa: std.mem.Allocator, module: dyn.Module) ?Lib {
        module.close(gpa);
        return null;
    }
};

pub const Options = struct {
    /// 完整 ODBC 连接串（`DSN=x;UID=u;PWD=p` 或 `DRIVER={...};DBQ=...`）
    conn_str: []const u8 = "",
    /// 登录超时（秒；0 = 不设）
    login_timeout_s: u32 = 0,
    /// 打开时是否保留 ODBC 的 autocommit（默认 false：由 `begin()/commit()/rollback()` 显式管理；
    /// 不在事务里时驱动仍会立即提交，见文件头「事务」）
    keep_autocommit: bool = false,
};

/// 拼连接串：给了完整串就直接用；否则 `DSN={dsn};UID=..;PWD=..`。
pub fn buildConnStrAlloc(a: std.mem.Allocator, dsn: []const u8, user: []const u8, password: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, dsn, '=') != null and std.mem.indexOfScalar(u8, dsn, ';') != null) {
        return a.dupe(u8, dsn);
    }
    if (user.len == 0 and password.len == 0) return std.fmt.allocPrint(a, "DSN={s}", .{dsn});
    return std.fmt.allocPrint(a, "DSN={s};UID={s};PWD={s}", .{ dsn, user, password });
}

/// Access（`.mdb` / `.accdb`）的连接串：`DRIVER={...};DBQ=<文件>`。
/// 选哪个驱动名取决于装了 32 位还是 64 位 Office/ACE 引擎，两者都试不了（连接串只能给一个），
/// 所以按「先 ACE 后 Jet」的顺序返回两个候选，由调用方依次尝试。
pub fn accessConnStrAlloc(a: std.mem.Allocator, file: []const u8, ace: bool) ![]u8 {
    const driver = if (ace)
        "{Microsoft Access Driver (*.mdb, *.accdb)}"
    else
        "{Microsoft Access Driver (*.mdb)}";
    return std.fmt.allocPrint(a, "DRIVER={s};DBQ={s}", .{ driver, file });
}

fn isOk(rc: SqlRet) bool {
    return rc == SQL_SUCCESS or rc == SQL_SUCCESS_WITH_INFO;
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
    dbc: ?*anyopaque = null,
    /// 当前 autocommit 状态（`begin()` 关、`commit()/rollback()` 开回来）
    autocommit: bool = true,
    err_buf: [768]u8 = undefined,
    err_len: usize = 0,

    pub fn open(gpa: std.mem.Allocator, lib: *Lib, opts: Options) !Conn {
        var self = Conn{ .gpa = gpa, .lib = lib };

        // 1) 环境句柄 + 版本（ODBC 3.x）
        if (!isOk(lib.alloc_handle(SQL_HANDLE_ENV, null, &self.env))) {
            self.setError("ODBC 分配环境句柄失败（SQLAllocHandle）", .{});
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            return Error.HandleFailed;
        }
        if (!isOk(lib.set_env_attr(self.env, SQL_ATTR_ODBC_VERSION, @ptrFromInt(SQL_OV_ODBC3), 0))) {
            self.setError("ODBC 设置 SQL_ATTR_ODBC_VERSION=ODBC3 失败", .{});
            self.appendDiag(SQL_HANDLE_ENV, self.env);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.HandleFailed;
        }

        // 2) 连接句柄 + 连接串（UTF-16）
        if (!isOk(lib.alloc_handle(SQL_HANDLE_DBC, self.env, &self.dbc))) {
            self.setError("ODBC 分配连接句柄失败（SQLAllocHandle）", .{});
            self.appendDiag(SQL_HANDLE_ENV, self.env);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.HandleFailed;
        }
        if (opts.login_timeout_s > 0) {
            _ = lib.set_connect_attr(self.dbc, SQL_ATTR_LOGIN_TIMEOUT, @ptrFromInt(@as(usize, opts.login_timeout_s)), 0);
        }

        const wide = std.unicode.utf8ToUtf16LeAlloc(gpa, opts.conn_str) catch {
            self.setError("ODBC 连接串含非法 UTF-8，无法转 UTF-16", .{});
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.ConnectFailed;
        };
        defer gpa.free(wide);

        if (wide.len > std.math.maxInt(i16)) {
            self.setError("ODBC 连接串过长（{d} 个 UTF-16 单元，上限 {d}）", .{ wide.len, std.math.maxInt(i16) });
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.ConnectFailed;
        }

        var out_buf: [1024]u16 = undefined;
        var out_len: i16 = 0;
        const rc = lib.driver_connect(
            self.dbc,
            null,
            wide.ptr,
            @intCast(wide.len),
            &out_buf,
            @intCast(out_buf.len),
            &out_len,
            SQL_DRIVER_NOPROMPT,
        );
        if (!isOk(rc)) {
            self.setError("ODBC 连接失败（连接串：{s}）", .{opts.conn_str});
            self.appendDiag(SQL_HANDLE_DBC, self.dbc);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            self.closeHandles();
            return Error.ConnectFailed;
        }

        // 3) autocommit：默认关掉，交给 begin/commit/rollback 管（见文件头「事务」）
        self.autocommit = true;
        if (!opts.keep_autocommit) {
            if (isOk(lib.set_connect_attr(self.dbc, SQL_ATTR_AUTOCOMMIT, @ptrFromInt(SQL_AUTOCOMMIT_OFF), 0))) {
                self.autocommit = false;
            } else {
                // 关不掉不影响可用性：退化为「每条语句立即提交」
                std.debug.print("[zzig.odbc] 关闭 autocommit 失败，退化为自动提交模式：{s}\n", .{opts.conn_str});
            }
        }
        return self;
    }

    pub fn deinit(self: *Conn) void {
        self.closeHandles();
    }

    fn closeHandles(self: *Conn) void {
        if (self.dbc != null) {
            _ = self.lib.disconnect(self.dbc);
            _ = self.lib.free_handle(SQL_HANDLE_DBC, self.dbc);
            self.dbc = null;
        }
        if (self.env != null) {
            _ = self.lib.free_handle(SQL_HANDLE_ENV, self.env);
            self.env = null;
        }
    }

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// ODBC 没有统一的自增回写：恒 0（要 ID 请由方言层生成 `SELECT @@IDENTITY` 之类）。
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

    /// 把 `SQLGetDiagRec` 的 SQLSTATE + 原生错误码 + 驱动消息追加到 `lastError()`。
    fn appendDiag(self: *Conn, handle_type: i16, handle: ?*anyopaque) void {
        if (handle == null) return;
        var state_w: [6]u16 = undefined;
        var native: i32 = 0;
        var msg_w: [500]u16 = undefined;
        var msg_len: i16 = 0;
        const rc = self.lib.get_diag_rec(handle_type, handle, 1, &state_w, &native, &msg_w, @intCast(msg_w.len), &msg_len);
        if (!isOk(rc)) return;

        var state_buf: [6]u8 = undefined;
        // `utf16LeToUtf8` 返回写入字节数（不是切片），要自己切
        const state_n = std.unicode.utf16LeToUtf8(&state_buf, std.mem.sliceTo(&state_w, 0)) catch 0;
        const state = state_buf[0..state_n];
        const n: usize = if (msg_len < 0) 0 else @min(@as(usize, @intCast(msg_len)), msg_w.len);
        var msg_buf: [1000]u8 = undefined;
        const msg_n = std.unicode.utf16LeToUtf8(&msg_buf, msg_w[0..n]) catch 0;
        const msg = msg_buf[0..msg_n];

        const add = std.fmt.bufPrint(self.err_buf[self.err_len..], "（SQLSTATE {s} / 原生码 {d}：{s}）", .{ state, native, msg }) catch return;
        self.err_len += add.len;
    }

    fn newStmt(self: *Conn) !?*anyopaque {
        var stmt: ?*anyopaque = null;
        if (!isOk(self.lib.alloc_handle(SQL_HANDLE_STMT, self.dbc, &stmt))) return Error.HandleFailed;
        return stmt;
    }

    /// 执行写语句，返回影响行数（驱动不报时返回 0）。
    pub fn exec(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !u64 {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        const stmt = try self.newStmt();
        defer _ = self.lib.free_handle(SQL_HANDLE_STMT, stmt);

        const wide = std.unicode.utf8ToUtf16LeAlloc(arena, text) catch return Error.QueryFailed;
        const rc = self.lib.exec_direct(stmt, wide.ptr, @intCast(wide.len));
        if (!isOk(rc)) {
            self.setError("ODBC 执行失败（{s}）", .{text[0..@min(text.len, 200)]});
            self.appendDiag(SQL_HANDLE_STMT, stmt);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }

        var rows: SqlLen = 0;
        if (!isOk(self.lib.row_count(stmt, &rows)) or rows < 0) return 0;
        return @intCast(rows);
    }

    /// 查询：所有列按 `SQL_C_WCHAR` 取成 UTF-8 文本。
    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        const stmt = try self.newStmt();
        defer {
            _ = self.lib.close_cursor(stmt);
            _ = self.lib.free_handle(SQL_HANDLE_STMT, stmt);
        }

        const wide = std.unicode.utf8ToUtf16LeAlloc(arena, text) catch return Error.QueryFailed;
        const rc = self.lib.exec_direct(stmt, wide.ptr, @intCast(wide.len));
        if (!isOk(rc)) {
            self.setError("ODBC 执行失败（{s}）", .{text[0..@min(text.len, 200)]});
            self.appendDiag(SQL_HANDLE_STMT, stmt);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }

        var col_count: i16 = 0;
        if (!isOk(self.lib.num_result_cols(stmt, &col_count))) {
            var rows: SqlLen = 0;
            if (self.lib.row_count(stmt, &rows) == SQL_SUCCESS and rows > 0) return .{ .ok = @intCast(rows) };
            return .{ .ok = 0 };
        }
        if (col_count <= 0) {
            var rows: SqlLen = 0;
            if (self.lib.row_count(stmt, &rows) == SQL_SUCCESS and rows > 0) return .{ .ok = @intCast(rows) };
            return .{ .ok = 0 };
        }

        const n: usize = @intCast(col_count);
        const names = try arena.alloc([]const u8, n);
        const cell_chars = try arena.alloc(usize, n);
        for (0..n) |i| {
            const info = try self.describeCol(arena, stmt, @intCast(i + 1));
            names[i] = info.name;
            // SQL_C_WCHAR 按字符计：ColumnSize 是「最大字符数」，夹到 [64, 32767]
            cell_chars[i] = @min(@max(info.size, 64), 32767);
        }

        var rows: std.ArrayList(Row) = .empty;
        var truncated_cols: usize = 0;
        while (true) {
            const frc = self.lib.fetch(stmt);
            if (frc == SQL_NO_DATA) break;
            if (!isOk(frc)) {
                self.setError("ODBC 取行失败（第 {d} 行）", .{rows.items.len + 1});
                self.appendDiag(SQL_HANDLE_STMT, stmt);
                std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
                return Error.QueryFailed;
            }

            const values = try arena.alloc(Value, n);
            for (0..n) |i| {
                const chars = cell_chars[i];
                const buf = try arena.alloc(u16, chars);
                var ind: SqlLen = 0;
                const grc = self.lib.get_data(stmt, @intCast(i + 1), SQL_C_WCHAR, buf.ptr, @intCast(chars * 2), &ind);
                if (ind == SQL_NULL_DATA) {
                    values[i] = .null;
                    continue;
                }
                if (grc != SQL_SUCCESS and grc != SQL_SUCCESS_WITH_INFO) {
                    if (!isOk(grc)) {
                        self.setError("ODBC 取第 {d} 列（{s}）失败", .{ i + 1, names[i] });
                        self.appendDiag(SQL_HANDLE_STMT, stmt);
                        std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
                        return Error.QueryFailed;
                    }
                }
                // ind 是「可用数据的字节数」；SQL_NO_TOTAL / 负数时按缓冲区算
                var used: usize = chars;
                if (ind >= 0) used = @min(@as(usize, @intCast(ind)) / 2, chars);
                if (grc == SQL_SUCCESS_WITH_INFO and (ind < 0 or @as(usize, @intCast(ind)) / 2 > chars)) {
                    truncated_cols += 1;
                    if (truncated_cols <= 3) {
                        std.debug.print(
                            "[zzig.odbc] 列 {s} 的值超过 {d} 字符被截断（CLOB/LONG 请用 SUBSTR 分段取）\n",
                            .{ names[i], chars },
                        );
                    }
                }
                values[i] = .{ .text = try utf16ToUtf8Alloc(arena, buf[0..used]) };
            }
            try rows.append(arena, .{ .names = names, .values = values });
        }

        if (truncated_cols > 3) {
            std.debug.print("[zzig.odbc] 本次结果共 {d} 个单元格被截断（只打印了前 3 条）\n", .{truncated_cols});
        }
        return .{ .rows = try rows.toOwnedSlice(arena) };
    }

    const ColInfo = struct { name: []const u8, size: usize };

    fn describeCol(self: *Conn, a: std.mem.Allocator, stmt: ?*anyopaque, pos: u16) !ColInfo {
        var name_w: [256]u16 = undefined;
        var name_len: i16 = 0;
        var data_type: i16 = 0;
        var size: usize = 0;
        var digits: i16 = 0;
        var nullable: i16 = 0;
        const rc = self.lib.describe_col(
            stmt,
            pos,
            &name_w,
            @intCast(name_w.len),
            &name_len,
            &data_type,
            &size,
            &digits,
            &nullable,
        );
        if (!isOk(rc)) return .{ .name = try std.fmt.allocPrint(a, "COL{d}", .{pos}), .size = 0 };
        const n: usize = if (name_len < 0) 0 else @min(@as(usize, @intCast(name_len)), name_w.len);
        const name = utf16ToUtf8Alloc(a, name_w[0..n]) catch try std.fmt.allocPrint(a, "COL{d}", .{pos});
        return .{ .name = name, .size = size };
    }

    /// 事务开始：关掉 autocommit（不在事务里的语句仍然会立即提交，见文件头）。
    pub fn begin(self: *Conn) !void {
        if (!self.autocommit) return;
        if (!isOk(self.lib.set_connect_attr(self.dbc, SQL_ATTR_AUTOCOMMIT, @ptrFromInt(SQL_AUTOCOMMIT_OFF), 0))) {
            self.setError("ODBC 开启事务失败（关闭 autocommit）", .{});
            self.appendDiag(SQL_HANDLE_DBC, self.dbc);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }
        self.autocommit = false;
    }

    pub fn commit(self: *Conn) !void {
        if (!isOk(self.lib.end_tran(SQL_HANDLE_DBC, self.dbc, SQL_COMMIT))) {
            self.setError("ODBC 提交失败（SQLEndTran COMMIT）", .{});
            self.appendDiag(SQL_HANDLE_DBC, self.dbc);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }
        self.restoreAutocommit();
    }

    pub fn rollback(self: *Conn) !void {
        if (!isOk(self.lib.end_tran(SQL_HANDLE_DBC, self.dbc, SQL_ROLLBACK))) {
            self.setError("ODBC 回滚失败（SQLEndTran ROLLBACK）", .{});
            self.appendDiag(SQL_HANDLE_DBC, self.dbc);
            std.debug.print("[zzig.odbc] {s}\n", .{self.lastError()});
            return Error.QueryFailed;
        }
        self.restoreAutocommit();
    }

    fn restoreAutocommit(self: *Conn) void {
        // 回到 ODBC 默认（每条语句立即提交），避免用户忘记提交时静默丢数据
        if (isOk(self.lib.set_connect_attr(self.dbc, SQL_ATTR_AUTOCOMMIT, @ptrFromInt(SQL_AUTOCOMMIT_ON), 0))) {
            self.autocommit = true;
        }
    }

    /// 探活：`SELECT 1` 能跑通即认为连接可用（Access/SQLite 系也支持无 FROM 的 SELECT）。
    pub fn ping(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = try self.queryAlloc(arena.allocator(), "SELECT 1", &.{});
    }

    /// ODBC 没有跨库统一的版本函数：返回空串（诊断用，不参与任何能力分支）。
    pub fn serverVersionAlloc(self: *Conn, a: std.mem.Allocator) ![]u8 {
        _ = self;
        return a.dupe(u8, "");
    }
};

/// UTF-16LE → UTF-8（借 arena；空切片直接给空串）。
fn utf16ToUtf8Alloc(a: std.mem.Allocator, units: []const u16) ![]u8 {
    if (units.len == 0) return a.dupe(u8, "");
    return std.unicode.utf16LeToUtf8Alloc(a, units);
}

// ── 用例（不需要任何真实数据库）──────────────────────────────────────────────

test "ODBC - 连接串构建：完整串直传 / DSN+账号 / 纯 DSN" {
    const a = std.testing.allocator;

    const full = try buildConnStrAlloc(a, "DRIVER={IBM DB2 ODBC DRIVER};DATABASE=SAMPLE;HOSTNAME=db1", "u", "p");
    defer a.free(full);
    try std.testing.expectEqualStrings("DRIVER={IBM DB2 ODBC DRIVER};DATABASE=SAMPLE;HOSTNAME=db1", full);

    const dsn = try buildConnStrAlloc(a, "MyDsn", "scott", "tiger");
    defer a.free(dsn);
    try std.testing.expectEqualStrings("DSN=MyDsn;UID=scott;PWD=tiger", dsn);

    const bare = try buildConnStrAlloc(a, "MyDsn", "", "");
    defer a.free(bare);
    try std.testing.expectEqualStrings("DSN=MyDsn", bare);
}

test "ODBC - Access 连接串（ACE / Jet 两个驱动名）" {
    const a = std.testing.allocator;
    const ace = try accessConnStrAlloc(a, "C:\\data\\x.accdb", true);
    defer a.free(ace);
    try std.testing.expectEqualStrings("DRIVER={Microsoft Access Driver (*.mdb, *.accdb)};DBQ=C:\\data\\x.accdb", ace);

    const jet = try accessConnStrAlloc(a, "C:\\data\\x.mdb", false);
    defer a.free(jet);
    try std.testing.expectEqualStrings("DRIVER={Microsoft Access Driver (*.mdb)};DBQ=C:\\data\\x.mdb", jet);
}

test "ODBC - 驱动管理器加载（Windows 自带 odbc32.dll，必须成功）" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return; // Unix 上没有 unixODBC 是正常的，跳过
    var lib = Lib.load(std.testing.allocator) catch |e| {
        // 理论上不该发生（odbc32.dll 是系统组件）；真失败就把它当明确错误报出来
        try std.testing.expectEqual(Error.OdbcNotAvailable, e);
        return;
    };
    lib.module.close(std.testing.allocator);
}

test "ODBC - 连一个不存在的 DSN：明确报 ConnectFailed 且带 SQLSTATE" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return;

    const a = std.testing.allocator;
    var lib = Lib.load(a) catch return;
    defer lib.module.close(a);

    var conn = Conn.open(a, &lib, .{ .conn_str = "DSN=zcode_no_such_dsn_xyz;UID=u;PWD=p" }) catch |e| {
        try std.testing.expectEqual(Error.ConnectFailed, e);
        return;
    };
    // 某些环境里驱动管理器会延迟到第一条语句才报错：那就靠 ping 把它逼出来
    defer conn.deinit();
    try std.testing.expectError(Error.QueryFailed, conn.ping());
}

test "ODBC - 常量与 sql.h 对齐（写死值防止手滑改错）" {
    try std.testing.expectEqual(@as(i16, 1), SQL_HANDLE_ENV);
    try std.testing.expectEqual(@as(i16, 2), SQL_HANDLE_DBC);
    try std.testing.expectEqual(@as(i16, 3), SQL_HANDLE_STMT);
    try std.testing.expectEqual(@as(i16, 100), SQL_NO_DATA);
    try std.testing.expectEqual(@as(i32, 200), SQL_ATTR_ODBC_VERSION);
    try std.testing.expectEqual(@as(i32, 102), SQL_ATTR_AUTOCOMMIT);
    try std.testing.expectEqual(@as(i16, -8), SQL_C_WCHAR);
    try std.testing.expectEqual(@as(isize, -1), SQL_NULL_DATA);
}
