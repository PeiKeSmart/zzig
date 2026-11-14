//! DuckDB 驱动（**嵌入式**，动态加载 `duckdb.dll` / `libduckdb.so`，只走官方 C API）。
//!
//! DuckDB 没有网络协议（进程内嵌），因此只有两种接入方式：链接 C 库，或**动态加载 C 库**。
//! 本仓选后者，理由与 SQLite 驱动一致：不链 libc、不把 20MB 的库塞进产物，
//! 现场放一个 `duckdb.dll` 到 exe 同目录即可用，换版本只是换文件。
//!
//! ## ABI 约定（**别改字段顺序**）
//! `duckdb_result` 是**按值返回**的 C 结构体，字段布局必须与 `duckdb.h` 一致：
//!
//! ```c
//! typedef struct {
//!   idx_t deprecated_column_count;
//!   idx_t deprecated_row_count;
//!   idx_t deprecated_rows_changed;
//!   duckdb_column* deprecated_columns;
//!   char* deprecated_error_message;
//!   void* internal_data;
//! } duckdb_result;
//! ```
//!
//! 上表的 `idx_t` 是 `uint64_t`；这几个字段虽标 deprecated，但**仍然存在于 0.9 ~ 1.x 的结构体里**
//! （官方只是不建议直接读，改用 `duckdb_row_count()` 等函数）。驱动只用函数取值，不直接读字段。
//!
//! ## 参数绑定
//! 走 `duckdb_prepare` + `duckdb_bind_*` 需要在 ABI 上再多一套结构体；
//! 这里与 TDengine / ClickHouse 一致，用**客户端内联**（`inline.zig`，跳过字符串/注释里的 `?`），
//! 代价是失去服务端预编译缓存（嵌入式库本来就省掉了网络往返，影响可忽略）。
//!
//! ## 已知边界
//! - 只做单连接（DuckDB 本身是单进程写、多线程读；连接池意义不大，`supportsPooling` 返回 false）；
//! - 无自增列回写（`lastInsertId` 恒 0，DuckDB 用 `RETURNING` 或 `currval` 请走 `queryAlloc`）；
//! - 本机没有 `duckdb.dll` 时 `Lib.load` 返回 `error.DuckDbNotAvailable`（**不是 panic**），
//!   真库验证待有条件时补。

const std = @import("std");
const dyn = @import("../dyn.zig");
const sql_inline = @import("inline.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;
const DateTime = @import("../time/datetime.zig").DateTime;
const Decimal = @import("../number/decimal.zig").Decimal;

/// C API 的 `idx_t`（= `uint64_t`）
pub const idx_t = u64;

/// `duckdb_state`：0 = 成功，1 = 失败
const duckdb_success: c_int = 0;

/// `duckdb_result`（按值返回；**字段顺序必须与 duckdb.h 一致**，见文件头注释）
pub const CDuckDbResult = extern struct {
    deprecated_column_count: idx_t = 0,
    deprecated_row_count: idx_t = 0,
    deprecated_rows_changed: idx_t = 0,
    deprecated_columns: ?*anyopaque = null,
    deprecated_error_message: ?[*:0]const u8 = null,
    internal_data: ?*anyopaque = null,
};

/// `duckdb_blob`（按值返回）
pub const CBlob = extern struct {
    data: ?[*]u8 = null,
    size: idx_t = 0,
};

/// `duckdb_type`（枚举值取自 duckdb.h；未列出的按「未知 → 走 varchar 文本」处理）
pub const ColumnType = enum(u8) {
    invalid = 0,
    boolean = 1,
    tinyint = 2,
    smallint = 3,
    integer = 4,
    bigint = 5,
    utinyint = 6,
    usmallint = 7,
    uinteger = 8,
    ubigint = 9,
    float = 10,
    double = 11,
    timestamp = 12,
    date = 13,
    time = 14,
    interval = 15,
    hugeint = 16,
    uhugeint = 17,
    varchar = 18,
    blob = 19,
    decimal = 20,
    timestamp_s = 21,
    timestamp_ms = 22,
    timestamp_ns = 23,
    enum_ = 24,
    list = 25,
    struct_ = 26,
    map = 27,
    array = 28,
    uuid = 29,
    union_ = 30,
    bit = 31,
    time_tz = 32,
    timestamp_tz = 33,
    varint = 34,
    sqlnull = 35,
    _,

    /// 是否整数族（含 hugeint/varint：它们都按十进制文本回）
    pub fn isIntegral(self: ColumnType) bool {
        return switch (self) {
            .tinyint, .smallint, .integer, .bigint, .utinyint, .usmallint, .uinteger, .ubigint, .hugeint, .uhugeint, .varint => true,
            else => false,
        };
    }

    pub fn isFloat(self: ColumnType) bool {
        return self == .float or self == .double;
    }

    pub fn isDateTime(self: ColumnType) bool {
        return switch (self) {
            .timestamp, .date, .time, .timestamp_s, .timestamp_ms, .timestamp_ns, .timestamp_tz, .time_tz => true,
            else => false,
        };
    }
};

pub const Error = error{
    /// 找不到 duckdb 动态库（把 `duckdb.dll` 放到 exe 同目录即可）
    DuckDbNotAvailable,
    /// 打开数据库 / 建立连接失败
    OpenFailed,
    /// 执行 SQL 失败（原因在 `lastError()`）
    QueryFailed,
    /// 结果集里取到了无法解释的类型
    Protocol,
};

/// 动态加载得到的 C API 函数表。
pub const Lib = struct {
    module: dyn.Module,
    source: []const u8,

    open: *const fn ([*:0]const u8, *?*anyopaque) callconv(.c) c_int,
    close: *const fn (*?*anyopaque) callconv(.c) void,
    connect: *const fn (?*anyopaque, *?*anyopaque) callconv(.c) c_int,
    disconnect: *const fn (*?*anyopaque) callconv(.c) void,
    query: *const fn (?*anyopaque, [*:0]const u8, *CDuckDbResult) callconv(.c) c_int,
    destroy_result: *const fn (*CDuckDbResult) callconv(.c) void,
    result_error: *const fn (*CDuckDbResult) callconv(.c) ?[*:0]const u8,
    row_count: *const fn (*CDuckDbResult) callconv(.c) idx_t,
    column_count: *const fn (*CDuckDbResult) callconv(.c) idx_t,
    column_name: *const fn (*CDuckDbResult, idx_t) callconv(.c) ?[*:0]const u8,
    column_type: *const fn (*CDuckDbResult, idx_t) callconv(.c) u8,
    value_is_null: *const fn (*CDuckDbResult, idx_t, idx_t) callconv(.c) bool,
    value_varchar: *const fn (*CDuckDbResult, idx_t, idx_t) callconv(.c) ?[*:0]u8,
    value_blob: *const fn (*CDuckDbResult, idx_t, idx_t) callconv(.c) CBlob,
    rows_changed: *const fn (*CDuckDbResult) callconv(.c) idx_t,
    free_mem: *const fn (?*anyopaque) callconv(.c) void,
    libversion: *const fn () callconv(.c) [*:0]const u8,

    /// 按「exe 目录 → 当前目录 → 裸名字」找库；全部失败返回 `error.DuckDbNotAvailable`。
    pub fn load(gpa: std.mem.Allocator) !Lib {
        const builtin = @import("builtin");
        const names: []const []const u8 = if (builtin.os.tag == .windows)
            &.{ "duckdb.dll" }
        else if (builtin.os.tag == .macos)
            &.{ "libduckdb.dylib", "duckdb.dylib" }
        else
            &.{ "libduckdb.so", "libduckdb.so.1", "duckdb.so" };

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
            "[zzig.duckdb] 未找到 DuckDB 动态库（尝试过：{s}）；请把 duckdb.dll 放到 exe 同目录或 PATH\n",
            .{if (builtin.os.tag == .windows) "duckdb.dll" else "libduckdb.so"},
        );
        return Error.DuckDbNotAvailable;
    }

    fn tryFrom(gpa: std.mem.Allocator, path: []const u8) ?Lib {
        const module = dyn.load(gpa, path) orelse return null;
        // 任何一个符号缺失就整体判失败（缺符号的库调起来只会崩在别处）
        const lib: Lib = .{
            .module = module,
            .source = path,
            .open = module.lookup(@TypeOf(@as(Lib, undefined).open), "duckdb_open") orelse return fail(gpa, module),
            .close = module.lookup(@TypeOf(@as(Lib, undefined).close), "duckdb_close") orelse return fail(gpa, module),
            .connect = module.lookup(@TypeOf(@as(Lib, undefined).connect), "duckdb_connect") orelse return fail(gpa, module),
            .disconnect = module.lookup(@TypeOf(@as(Lib, undefined).disconnect), "duckdb_disconnect") orelse return fail(gpa, module),
            .query = module.lookup(@TypeOf(@as(Lib, undefined).query), "duckdb_query") orelse return fail(gpa, module),
            .destroy_result = module.lookup(@TypeOf(@as(Lib, undefined).destroy_result), "duckdb_destroy_result") orelse return fail(gpa, module),
            .result_error = module.lookup(@TypeOf(@as(Lib, undefined).result_error), "duckdb_result_error") orelse return fail(gpa, module),
            .row_count = module.lookup(@TypeOf(@as(Lib, undefined).row_count), "duckdb_row_count") orelse return fail(gpa, module),
            .column_count = module.lookup(@TypeOf(@as(Lib, undefined).column_count), "duckdb_column_count") orelse return fail(gpa, module),
            .column_name = module.lookup(@TypeOf(@as(Lib, undefined).column_name), "duckdb_column_name") orelse return fail(gpa, module),
            .column_type = module.lookup(@TypeOf(@as(Lib, undefined).column_type), "duckdb_column_type") orelse return fail(gpa, module),
            .value_is_null = module.lookup(@TypeOf(@as(Lib, undefined).value_is_null), "duckdb_value_is_null") orelse return fail(gpa, module),
            .value_varchar = module.lookup(@TypeOf(@as(Lib, undefined).value_varchar), "duckdb_value_varchar") orelse return fail(gpa, module),
            .value_blob = module.lookup(@TypeOf(@as(Lib, undefined).value_blob), "duckdb_value_blob") orelse return fail(gpa, module),
            .rows_changed = module.lookup(@TypeOf(@as(Lib, undefined).rows_changed), "duckdb_rows_changed") orelse return fail(gpa, module),
            .free_mem = module.lookup(@TypeOf(@as(Lib, undefined).free_mem), "duckdb_free") orelse return fail(gpa, module),
            .libversion = module.lookup(@TypeOf(@as(Lib, undefined).libversion), "duckdb_library_version") orelse return fail(gpa, module),
        };
        return lib;
    }

    fn fail(gpa: std.mem.Allocator, module: dyn.Module) ?Lib {
        module.close(gpa);
        return null;
    }
};

pub const Options = struct {
    /// 数据库文件路径；`:memory:` 为内存库
    path: []const u8 = ":memory:",
};

pub const Db = struct {
    gpa: std.mem.Allocator,
    /// 借用的库函数表（生命周期由调用方保证 ≥ Db）
    lib: *Lib,
    database: ?*anyopaque = null,
    connection: ?*anyopaque = null,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,

    pub fn open(gpa: std.mem.Allocator, lib: *Lib, opts: Options) !Db {
        var self = Db{ .gpa = gpa, .lib = lib };

        var path_buf: [1024]u8 = undefined;
        if (opts.path.len >= path_buf.len) return Error.OpenFailed;
        @memcpy(path_buf[0..opts.path.len], opts.path);
        path_buf[opts.path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        if (lib.open(path_z, &self.database) != duckdb_success) {
            self.setError("DuckDB 打开数据库失败：{s}", .{opts.path});
            std.debug.print("[zzig.duckdb] {s}\n", .{self.lastError()});
            return Error.OpenFailed;
        }
        if (lib.connect(self.database, &self.connection) != duckdb_success) {
            self.setError("DuckDB 建立连接失败：{s}", .{opts.path});
            std.debug.print("[zzig.duckdb] {s}\n", .{self.lastError()});
            lib.close(&self.database);
            self.database = null;
            return Error.OpenFailed;
        }
        return self;
    }

    pub fn close(self: *Db) void {
        if (self.connection != null) {
            self.lib.disconnect(&self.connection);
            self.connection = null;
        }
        if (self.database != null) {
            self.lib.close(&self.database);
            self.database = null;
        }
    }

    pub fn lastError(self: *const Db) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// DuckDB 没有自增列回写：恒 0（要 ID 请用 `RETURNING` + `queryAlloc`）。
    pub fn lastInsertId(self: *const Db) i64 {
        _ = self;
        return 0;
    }

    pub fn version(self: *const Db) []const u8 {
        return std.mem.span(self.lib.libversion());
    }

    fn setError(self: *Db, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch {
            self.err_len = @min(self.err_buf.len, 200);
            return;
        };
        self.err_len = text.len;
    }

    fn runAlloc(self: *Db, a: std.mem.Allocator, sql: []const u8) !CDuckDbResult {
        // C 接口要 0 结尾字符串：复制一份（SQL 可能来自 arena，不能就地加 0）
        const sql_z = try a.allocSentinel(u8, sql.len, 0);
        @memcpy(sql_z[0..sql.len], sql);

        var result = CDuckDbResult{};
        const state = self.lib.query(self.connection, sql_z.ptr, &result);
        if (state != duckdb_success) {
            const msg: []const u8 = if (self.lib.result_error(&result)) |e| std.mem.span(e) else "（无错误信息）";
            self.setError("DuckDB 执行失败：{s}\n  SQL: {s}", .{ msg, sql[0..@min(sql.len, 200)] });
            std.debug.print("[zzig.duckdb] {s}\n", .{self.lastError()});
            self.lib.destroy_result(&result);
            return Error.QueryFailed;
        }
        return result;
    }

    /// 执行写语句 / DDL，返回受影响行数。
    pub fn exec(self: *Db, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !u64 {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        var result = try self.runAlloc(arena, text);
        defer self.lib.destroy_result(&result);
        return self.lib.rows_changed(&result);
    }

    /// 查询。列的文本形态由 `duckdb_value_varchar` 取回，再按**列类型**还原成 `Value`。
    pub fn queryAlloc(self: *Db, arena: std.mem.Allocator, sql: []const u8, params: []const Value) ![]const Row {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        var result = try self.runAlloc(arena, text);
        defer self.lib.destroy_result(&result);

        const cols = self.lib.column_count(&result);
        const total = self.lib.row_count(&result);
        if (cols == 0 or total == 0) return &.{};

        const names = try arena.alloc([]const u8, cols);
        const types = try arena.alloc(ColumnType, cols);
        for (0..cols) |i| {
            names[i] = if (self.lib.column_name(&result, i)) |n| try arena.dupe(u8, std.mem.span(n)) else "";
            types[i] = std.enums.fromInt(ColumnType, self.lib.column_type(&result, i)) orelse .invalid;
        }

        var rows: std.ArrayListUnmanaged(Row) = .empty;
        try rows.ensureTotalCapacity(arena, total);
        for (0..total) |r| {
            const values = try arena.alloc(Value, cols);
            for (0..cols) |c| {
                values[c] = try self.cellValue(arena, &result, c, r, types[c]);
            }
            rows.appendAssumeCapacity(.{ .names = names, .values = values });
        }
        return rows.toOwnedSlice(arena);
    }

    fn cellValue(self: *Db, a: std.mem.Allocator, result: *CDuckDbResult, col: idx_t, row: idx_t, ty: ColumnType) !Value {
        if (self.lib.value_is_null(result, col, row)) return .null;

        if (ty == .blob) {
            const blob = self.lib.value_blob(result, col, row);
            if (blob.size == 0 or blob.data == null) return .{ .blob = try a.dupe(u8, "") };
            const bytes = blob.data.?[0..@intCast(blob.size)];
            const out = try a.dupe(u8, bytes);
            self.lib.free_mem(blob.data);
            return .{ .blob = out };
        }

        // 其余类型统一走 varchar 文本，再按类型解析（DuckDB 的 cast 很全，文本是稳定表示）
        const raw = self.lib.value_varchar(result, col, row) orelse return .null;
        defer self.lib.free_mem(raw);
        const text = std.mem.span(raw);

        if (ty.isIntegral()) {
            if (std.fmt.parseInt(i64, text, 10) catch null) |i| return .{ .int = i };
            return .{ .text = try a.dupe(u8, text) }; // 超出 i64（hugeint/varint）保留文本，不截断
        }
        if (ty.isFloat()) {
            if (std.fmt.parseFloat(f64, text) catch null) |f| return .{ .float = f };
            return .{ .text = try a.dupe(u8, text) };
        }
        if (ty == .decimal) {
            if (Decimal.parse(text) catch null) |d| return .{ .decimal = d };
            return .{ .text = try a.dupe(u8, text) };
        }
        if (ty.isDateTime()) {
            if (DateTime.parse(text) catch null) |dt| return .{ .datetime = dt };
            return .{ .text = try a.dupe(u8, text) };
        }
        if (ty == .boolean) {
            return .{ .boolean = std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1") };
        }
        return .{ .text = try a.dupe(u8, text) };
    }
};

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "duckdb：缺库时明确报 DuckDbNotAvailable（不是 panic）" {
    var lib = Lib.load(testing.allocator) catch |e| {
        try testing.expectEqual(Error.DuckDbNotAvailable, e);
        return;
    };
    // 本机恰好装了 duckdb：至少把符号表摸一遍，然后释放
    defer lib.module.close(testing.allocator);
    try testing.expect(std.mem.span(lib.libversion()).len > 0);
}

test "duckdb：列类型分类（整数/浮点/时间/其余）" {
    try testing.expect(ColumnType.bigint.isIntegral());
    try testing.expect(ColumnType.hugeint.isIntegral());
    try testing.expect(!ColumnType.double.isIntegral());
    try testing.expect(ColumnType.double.isFloat());
    try testing.expect(ColumnType.timestamp_ns.isDateTime());
    try testing.expect(ColumnType.date.isDateTime());
    try testing.expect(!ColumnType.varchar.isDateTime());
    // 未列出的类型码落到 `_`（不 panic，且各分类判定都为 false）
    const unknown = std.enums.fromInt(ColumnType, 200).?;
    try testing.expect(!unknown.isIntegral());
    try testing.expect(!unknown.isFloat());
    try testing.expect(!unknown.isDateTime());
}
