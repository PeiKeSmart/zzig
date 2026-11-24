//! SQLite **静态链接**函数表（把官方 amalgamation 的 `sqlite3.c` 编进最终可执行文件）。
//!
//! 用法（消费方）：
//! ```zig
//! zzig.db.sqlite.registerStatic(zzig.db.sqlite_static.lib());
//! ```
//! 并在自己的 `build.zig` 里把 `sqlite3.c` 加进可执行模块（`addCSourceFile` + `link_libc`）。
//!
//! 为什么需要它：`x86_64-linux-musl` 是**全静态**二进制，没有动态加载器，
//! `dlopen("libsqlite3.so")` 必然失败 → 驱动只能返回 `SqliteNotAvailable`，
//! 后台账号/密码/设置全部无法落盘（2026-11-24 线上实测：`Data/` 下永远没有 `.db`）。
//!
//! ⚠ 本文件里的 `extern fn` 只有在**确实链接了 `sqlite3.c`** 时才可引用；
//! 没链接却调用 `lib()` 会在链接期报未定义符号（故意的：配置错了就别启动）。

const sqlite = @import("sqlite.zig");

extern fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*anyopaque, flags: c_int, zVfs: ?[*:0]const u8) callconv(.c) c_int;
extern fn sqlite3_close_v2(db: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_errmsg(db: ?*anyopaque) callconv(.c) [*:0]const u8;
extern fn sqlite3_errcode(db: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_prepare_v2(db: ?*anyopaque, sql: [*:0]const u8, n: c_int, stmt: *?*anyopaque, tail: ?*?[*:0]const u8) callconv(.c) c_int;
extern fn sqlite3_finalize(stmt: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_step(stmt: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_reset(stmt: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_clear_bindings(stmt: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_bind_int64(stmt: ?*anyopaque, index: c_int, value: i64) callconv(.c) c_int;
extern fn sqlite3_bind_double(stmt: ?*anyopaque, index: c_int, value: f64) callconv(.c) c_int;
extern fn sqlite3_bind_text(stmt: ?*anyopaque, index: c_int, text: [*]const u8, len: c_int, destructor: ?*const anyopaque) callconv(.c) c_int;
extern fn sqlite3_bind_blob(stmt: ?*anyopaque, index: c_int, blob: [*]const u8, len: c_int, destructor: ?*const anyopaque) callconv(.c) c_int;
extern fn sqlite3_bind_null(stmt: ?*anyopaque, index: c_int) callconv(.c) c_int;
extern fn sqlite3_column_count(stmt: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_column_name(stmt: ?*anyopaque, index: c_int) callconv(.c) [*:0]const u8;
extern fn sqlite3_column_type(stmt: ?*anyopaque, index: c_int) callconv(.c) c_int;
extern fn sqlite3_column_int64(stmt: ?*anyopaque, index: c_int) callconv(.c) i64;
extern fn sqlite3_column_double(stmt: ?*anyopaque, index: c_int) callconv(.c) f64;
extern fn sqlite3_column_text(stmt: ?*anyopaque, index: c_int) callconv(.c) [*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*anyopaque, index: c_int) callconv(.c) c_int;
extern fn sqlite3_column_blob(stmt: ?*anyopaque, index: c_int) callconv(.c) ?[*]const u8;
extern fn sqlite3_changes(db: ?*anyopaque) callconv(.c) c_int;
extern fn sqlite3_last_insert_rowid(db: ?*anyopaque) callconv(.c) i64;
extern fn sqlite3_busy_timeout(db: ?*anyopaque, ms: c_int) callconv(.c) c_int;
extern fn sqlite3_libversion() callconv(.c) [*:0]const u8;

/// 构造静态链接版函数表（调用方随后 `sqlite.registerStatic(lib())`）。
pub fn lib() sqlite.Lib {
    return .{
        .dyn = sqlite.no_module,
        .source = "static",
        .open_v2 = &sqlite3_open_v2,
        .close_v2 = &sqlite3_close_v2,
        .errmsg = &sqlite3_errmsg,
        .errcode = &sqlite3_errcode,
        .prepare_v2 = &sqlite3_prepare_v2,
        .finalize = &sqlite3_finalize,
        .step = &sqlite3_step,
        .reset = &sqlite3_reset,
        .clear_bindings = &sqlite3_clear_bindings,
        .bind_int64 = &sqlite3_bind_int64,
        .bind_double = &sqlite3_bind_double,
        .bind_text = &sqlite3_bind_text,
        .bind_blob = &sqlite3_bind_blob,
        .bind_null = &sqlite3_bind_null,
        .column_count = &sqlite3_column_count,
        .column_name = &sqlite3_column_name,
        .column_type = &sqlite3_column_type,
        .column_int64 = &sqlite3_column_int64,
        .column_double = &sqlite3_column_double,
        .column_text = &sqlite3_column_text,
        .column_bytes = &sqlite3_column_bytes,
        .column_blob = &sqlite3_column_blob,
        .changes = &sqlite3_changes,
        .last_insert_rowid = &sqlite3_last_insert_rowid,
        .busy_timeout = &sqlite3_busy_timeout,
        .libversion = &sqlite3_libversion,
    };
}
