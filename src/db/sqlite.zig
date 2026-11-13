//! SQLite 驱动：**动态加载** `sqlite3.dll` / `winsqlite3.dll`，不链 libc、不引 UCRT。
//!
//! 加载顺序（与「Win7 也要能跑」的部署约束一致）：
//! 1. 环境变量 `PEK_ZCODE_SQLITE`（完整路径，便于随包附带 Win7 兼容的 sqlite3.dll）
//! 2. 程序所在目录 `sqlite3.dll`（覆盖替换即可升级，无需重新链接）
//! 3. 系统 `sqlite3.dll`（PATH / System32）
//! 4. `winsqlite3.dll`（Windows 10/11 自带；版本 3.53.4 实测可用）
//!
//! 绑定策略：文本/二进制一律 `SQLITE_STATIC` 语义（destructor = null）——参数缓冲在
//! `step()` 期间始终存活，无需 SQLite 复制，省一次内存分配。

const std = @import("std");
const Value = @import("value.zig").Value;

pub const sqlite_ok: c_int = 0;
/// 当前可执行文件所在目录（0.17 已移除 `std.fs.selfExeDirPathAlloc`，这里直接问 Win32）。
/// 非 Windows 平台返回 `error.NotFound`，由调用方跳过该候选路径。
fn exeDirAlloc(gpa: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.NotFound;
    const k32 = struct {
        extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(.winapi) u32;
    };
    var buf: [1024]u8 = undefined;
    const n = k32.GetModuleFileNameA(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NotFound;
    const dir = std.fs.path.dirname(buf[0..n]) orelse return error.NotFound;
    return gpa.dupe(u8, dir);
}

pub const sqlite_row: c_int = 100;
pub const sqlite_done: c_int = 101;

/// `SQLITE_TRANSIENT`（(void*)-1）：告诉 sqlite 立刻复制绑定内容。
const sqlite_transient: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const sqlite_open_readwrite: c_int = 0x00000002;
const sqlite_open_readonly: c_int = 0x00000001;
const sqlite_open_create: c_int = 0x00000004;
const sqlite_open_fullmutex: c_int = 0x00010000;

const sqlite_integer: c_int = 1;
const sqlite_float: c_int = 2;
const sqlite_text: c_int = 3;
const sqlite_blob: c_int = 4;
const sqlite_null: c_int = 5;

/// Win32 动态加载（Zig 0.17 的 `std.DynLib` **不支持 Windows**，只有 linux/mac/BSD 分支）。
const win = struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: ?*anyopaque) callconv(.winapi) i32;
};

const ModuleHandle = struct {
    handle: ?*anyopaque,

    pub fn lookup(self: ModuleHandle, comptime T: type, name: [:0]const u8) ?T {
        const proc = win.GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrFromInt(@intFromPtr(proc));
    }
};

fn loadModule(path: []const u8) ?ModuleHandle {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return null;
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    const handle = win.LoadLibraryA(path_z) orelse return null;
    return .{ .handle = handle };
}

fn closeModule(m: ModuleHandle) void {
    if (m.handle) |h| _ = win.FreeLibrary(h);
}

/// 动态加载得到的函数表。
pub const Lib = struct {
    dyn: ModuleHandle,
    source: []const u8,

    open_v2: *const fn ([*:0]const u8, *?*anyopaque, c_int, ?[*:0]const u8) callconv(.c) c_int,
    close_v2: *const fn (?*anyopaque) callconv(.c) c_int,
    errmsg: *const fn (?*anyopaque) callconv(.c) [*:0]const u8,
    errcode: *const fn (?*anyopaque) callconv(.c) c_int,
    prepare_v2: *const fn (?*anyopaque, [*:0]const u8, c_int, *?*anyopaque, ?*?[*:0]const u8) callconv(.c) c_int,
    finalize: *const fn (?*anyopaque) callconv(.c) c_int,
    step: *const fn (?*anyopaque) callconv(.c) c_int,
    reset: *const fn (?*anyopaque) callconv(.c) c_int,
    clear_bindings: *const fn (?*anyopaque) callconv(.c) c_int,
    bind_int64: *const fn (?*anyopaque, c_int, i64) callconv(.c) c_int,
    bind_double: *const fn (?*anyopaque, c_int, f64) callconv(.c) c_int,
    bind_text: *const fn (?*anyopaque, c_int, [*]const u8, c_int, ?*const anyopaque) callconv(.c) c_int,
    bind_blob: *const fn (?*anyopaque, c_int, [*]const u8, c_int, ?*const anyopaque) callconv(.c) c_int,
    bind_null: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    column_count: *const fn (?*anyopaque) callconv(.c) c_int,
    column_name: *const fn (?*anyopaque, c_int) callconv(.c) [*:0]const u8,
    column_type: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    column_int64: *const fn (?*anyopaque, c_int) callconv(.c) i64,
    column_double: *const fn (?*anyopaque, c_int) callconv(.c) f64,
    column_text: *const fn (?*anyopaque, c_int) callconv(.c) [*:0]const u8,
    column_bytes: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    column_blob: *const fn (?*anyopaque, c_int) callconv(.c) ?[*]const u8,
    changes: *const fn (?*anyopaque) callconv(.c) c_int,
    last_insert_rowid: *const fn (?*anyopaque) callconv(.c) i64,
    busy_timeout: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    libversion: *const fn () callconv(.c) [*:0]const u8,

    /// 按既定顺序加载；全部失败返回 `error.SqliteNotAvailable`。
    ///
    /// 顺序：程序目录 `sqlite3.dll` → 系统 `sqlite3.dll` → `winsqlite3.dll`。
    /// 想固定用某个版本，把 `sqlite3.dll` 放到 exe 同目录即可（覆盖替换即升级）。
    pub fn load(gpa: std.mem.Allocator) !Lib {
        var candidates: std.ArrayList([]const u8) = .empty;
        defer {
            for (candidates.items) |c| gpa.free(c);
            candidates.deinit(gpa);
        }

        // 程序目录 sqlite3.dll
        if (exeDirAlloc(gpa)) |dir| {
            defer gpa.free(dir);
            if (std.fs.path.join(gpa, &.{ dir, "sqlite3.dll" })) |path| {
                try candidates.append(gpa, path);
            } else |_| {}
        } else |_| {}

        // 独立进程（测试/工具）没有 exe 目录下的 dll 时回退当前目录
        try candidates.append(gpa, try std.fs.path.join(gpa, &.{ ".", "sqlite3.dll" }));
        try candidates.append(gpa, try gpa.dupe(u8, "sqlite3.dll"));
        try candidates.append(gpa, try gpa.dupe(u8, "winsqlite3.dll"));

        for (candidates.items) |path| {
            const dyn = loadModule(path) orelse continue;
            const lib = Lib{
                .dyn = dyn,
                .source = path,
                .open_v2 = dyn.lookup(@TypeOf(@as(Lib, undefined).open_v2), "sqlite3_open_v2") orelse continue,
                .close_v2 = dyn.lookup(@TypeOf(@as(Lib, undefined).close_v2), "sqlite3_close_v2") orelse continue,
                .errmsg = dyn.lookup(@TypeOf(@as(Lib, undefined).errmsg), "sqlite3_errmsg") orelse continue,
                .errcode = dyn.lookup(@TypeOf(@as(Lib, undefined).errcode), "sqlite3_errcode") orelse continue,
                .prepare_v2 = dyn.lookup(@TypeOf(@as(Lib, undefined).prepare_v2), "sqlite3_prepare_v2") orelse continue,
                .finalize = dyn.lookup(@TypeOf(@as(Lib, undefined).finalize), "sqlite3_finalize") orelse continue,
                .step = dyn.lookup(@TypeOf(@as(Lib, undefined).step), "sqlite3_step") orelse continue,
                .reset = dyn.lookup(@TypeOf(@as(Lib, undefined).reset), "sqlite3_reset") orelse continue,
                .clear_bindings = dyn.lookup(@TypeOf(@as(Lib, undefined).clear_bindings), "sqlite3_clear_bindings") orelse continue,
                .bind_int64 = dyn.lookup(@TypeOf(@as(Lib, undefined).bind_int64), "sqlite3_bind_int64") orelse continue,
                .bind_double = dyn.lookup(@TypeOf(@as(Lib, undefined).bind_double), "sqlite3_bind_double") orelse continue,
                .bind_text = dyn.lookup(@TypeOf(@as(Lib, undefined).bind_text), "sqlite3_bind_text") orelse continue,
                .bind_blob = dyn.lookup(@TypeOf(@as(Lib, undefined).bind_blob), "sqlite3_bind_blob") orelse continue,
                .bind_null = dyn.lookup(@TypeOf(@as(Lib, undefined).bind_null), "sqlite3_bind_null") orelse continue,
                .column_count = dyn.lookup(@TypeOf(@as(Lib, undefined).column_count), "sqlite3_column_count") orelse continue,
                .column_name = dyn.lookup(@TypeOf(@as(Lib, undefined).column_name), "sqlite3_column_name") orelse continue,
                .column_type = dyn.lookup(@TypeOf(@as(Lib, undefined).column_type), "sqlite3_column_type") orelse continue,
                .column_int64 = dyn.lookup(@TypeOf(@as(Lib, undefined).column_int64), "sqlite3_column_int64") orelse continue,
                .column_double = dyn.lookup(@TypeOf(@as(Lib, undefined).column_double), "sqlite3_column_double") orelse continue,
                .column_text = dyn.lookup(@TypeOf(@as(Lib, undefined).column_text), "sqlite3_column_text") orelse continue,
                .column_bytes = dyn.lookup(@TypeOf(@as(Lib, undefined).column_bytes), "sqlite3_column_bytes") orelse continue,
                .column_blob = dyn.lookup(@TypeOf(@as(Lib, undefined).column_blob), "sqlite3_column_blob") orelse continue,
                .changes = dyn.lookup(@TypeOf(@as(Lib, undefined).changes), "sqlite3_changes") orelse continue,
                .last_insert_rowid = dyn.lookup(@TypeOf(@as(Lib, undefined).last_insert_rowid), "sqlite3_last_insert_rowid") orelse continue,
                .busy_timeout = dyn.lookup(@TypeOf(@as(Lib, undefined).busy_timeout), "sqlite3_busy_timeout") orelse continue,
                .libversion = dyn.lookup(@TypeOf(@as(Lib, undefined).libversion), "sqlite3_libversion") orelse continue,
            };
            return lib;
        }
        return error.SqliteNotAvailable;
    }

    pub fn deinit(self: *Lib) void {
        closeModule(self.dyn);
    }

    pub fn version(self: *const Lib) []const u8 {
        return std.mem.span(self.libversion());
    }
};

/// 一个打开的数据库连接（后续 `Session` 直接持有它）。
pub const Db = struct {
    lib: *Lib,
    handle: ?*anyopaque,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,

    /// 打开连接时的并发相关设置（对应 SQLite 的 `PRAGMA`）。
    ///
    /// **默认全部不设置**（即 SQLite 原生：`journal_mode=delete` + `synchronous=full`）。
    /// 实测（Pek.ZCode `zig build bench`，Windows，单行一事务）：`WAL+NORMAL` 写吞吐约
    /// **慢 2×**（~170 µs/行 vs ~65 µs/行），且「写中并发读」两种档位都没被阻塞。
    /// 所以 WAL 不做默认值，而由调用方按场景显式选：
    /// - 长写事务（批量导入）同时要求别人一直能读 → `JournalMode=WAL;Synchronous=NORMAL`
    /// - 网络盘（SMB/NFS）**不要**用 WAL（共享内存文件不可靠）
    pub const Options = struct {
        journal_mode: ?[]const u8 = null,
        synchronous: ?[]const u8 = null,
        busy_timeout_ms: u32 = 5000,
        /// `PRAGMA cache_size`：负数是 KB（-64000 = 64MB），正数是页数；`null` 用库默认
        cache_size: ?i32 = null,
        /// 只读打开（`?mode=ro` 语义）：防止误写
        read_only: bool = false,
    };

    pub fn open(lib: *Lib, path: []const u8) !Db {
        return openWithOptions(lib, path, .{});
    }

    /// 带并发选项打开。任何一条 PRAGMA 失败都**不**中断打开（PRAGMA 是优化项，
    /// 例如某些构建不支持 WAL、或内存库忽略它），但会把错误留在 `lastError()`。
    pub fn openWithOptions(lib: *Lib, path: []const u8, opts: Options) !Db {
        var path_buf: [1024]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        var handle: ?*anyopaque = null;
        var flags = sqlite_open_readwrite | sqlite_open_create | sqlite_open_fullmutex;
        if (opts.read_only) flags = sqlite_open_readonly | sqlite_open_fullmutex;
        const rc = lib.open_v2(path_z, &handle, flags, null);
        if (rc != sqlite_ok) {
            if (handle) |h| _ = lib.close_v2(h);
            return error.Sqlite;
        }
        const db = Db{ .lib = lib, .handle = handle };
        _ = lib.busy_timeout(handle, @intCast(opts.busy_timeout_ms));

        // 外键约束按 XCode 默认行为（不强制开启）——保持与 C#/Rust 一致
        var db_mut = db;
        db_mut.applyPragma("journal_mode", opts.journal_mode);
        db_mut.applyPragma("synchronous", opts.synchronous);
        if (opts.cache_size) |n| {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch null;
            if (text) |t| db_mut.applyPragma("cache_size", t);
        }
        return db_mut;
    }

    /// 尽力执行一条 `PRAGMA x = y`（失败只记录，不抛）。
    fn applyPragma(self: *Db, name: []const u8, value: ?[]const u8) void {
        const v = value orelse return;
        if (v.len == 0) return;
        var buf: [96]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "PRAGMA {s}={s}", .{ name, v }) catch return;
        _ = self.exec(std.heap.page_allocator, sql) catch {
            // 留痕：某些构建/文件系统不支持 WAL，属可降级项
            std.debug.print("[sqlite] PRAGMA {s} 未生效（{s}），继续使用默认行为\n", .{ sql, self.lastError() });
        };
    }

    pub fn close(self: *Db) void {
        if (self.handle) |h| {
            _ = self.lib.close_v2(h);
            self.handle = null;
        }
    }

    fn setError(self: *Db, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }

    pub fn lastError(self: *const Db) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// 直接执行（单条语句/DDL），返回受影响行数。
    pub fn exec(self: *Db, gpa: std.mem.Allocator, sql: []const u8) !usize {
        const stmt = try self.prepare(gpa, sql);
        defer stmt.finalize();
        var rows: usize = 0;
        while (true) {
            const rc = self.lib.step(stmt.handle);
            if (rc == sqlite_row) {
                rows += 1;
                continue;
            }
            if (rc == sqlite_done) break;
            self.setError(std.mem.span(self.lib.errmsg(self.handle)));
            return error.Sqlite;
        }
        if (sql.len >= 6 and (std.ascii.startsWithIgnoreCase(sql, "insert") or std.ascii.startsWithIgnoreCase(sql, "update") or std.ascii.startsWithIgnoreCase(sql, "delete"))) {
            return @intCast(@max(self.lib.changes(self.handle), 0));
        }
        return rows;
    }

    /// 预处理一条语句（SQL 文本在返回前即可释放：sqlite 会复制 SQL）。
    pub fn prepare(self: *Db, gpa: std.mem.Allocator, sql: []const u8) !Stmt {
        // 0.17 移除了 Allocator.dupeZ，这里手工补 \0
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, sql);
        try buf.append(gpa, 0);
        const sql_z: [*:0]const u8 = @ptrCast(buf.items.ptr);

        var handle: ?*anyopaque = null;
        const rc = self.lib.prepare_v2(self.handle, sql_z, @intCast(sql.len), &handle, null);
        if (rc != sqlite_ok) {
            self.setError(std.mem.span(self.lib.errmsg(self.handle)));
            return error.Sqlite;
        }
        return .{ .db = self, .handle = handle };
    }

    pub fn changes(self: *Db) usize {
        return @intCast(@max(self.lib.changes(self.handle), 0));
    }

    pub fn lastInsertId(self: *Db) i64 {
        return self.lib.last_insert_rowid(self.handle);
    }
};

pub const Stmt = struct {
    db: *Db,
    handle: ?*anyopaque,

    pub fn finalize(self: Stmt) void {
        _ = self.db.lib.finalize(self.handle);
    }

    pub fn reset(self: Stmt) void {
        _ = self.db.lib.reset(self.handle);
        _ = self.db.lib.clear_bindings(self.handle);
    }

    /// 绑定参数（索引从 1 开始）。
    ///
    /// 一律用 `SQLITE_TRANSIENT`（让 sqlite 立刻复制）：小数/时间在栈缓冲里格式化，
    /// 若用 `SQLITE_STATIC`（传 null destructor）则在 `step()` 时缓冲已失效，
    /// 会读到垃圾（实测："12.3400" 变成 "400"）。
    pub fn bindAll(self: Stmt, params: []const Value) !void {
        for (params, 0..) |param, i| {
            const idx: c_int = @intCast(i + 1);
            const rc: c_int = switch (param) {
                .null => self.db.lib.bind_null(self.handle, idx),
                .boolean => |v| self.db.lib.bind_int64(self.handle, idx, if (v) 1 else 0),
                .int => |v| self.db.lib.bind_int64(self.handle, idx, v),
                .float => |v| self.db.lib.bind_double(self.handle, idx, v),
                .decimal => |v| blk: {
                    var buf: [64]u8 = undefined;
                    const text = v.formatBuf(&buf) catch return error.Sqlite;
                    break :blk self.db.lib.bind_text(self.handle, idx, text.ptr, @intCast(text.len), sqlite_transient);
                },
                .text => |v| self.db.lib.bind_text(self.handle, idx, v.ptr, @intCast(v.len), sqlite_transient),
                .blob => |v| self.db.lib.bind_blob(self.handle, idx, v.ptr, @intCast(v.len), sqlite_transient),
                .datetime => |v| blk: {
                    var buf: [40]u8 = undefined;
                    const text = v.formatBuf(&buf) catch return error.Sqlite;
                    break :blk self.db.lib.bind_text(self.handle, idx, text.ptr, @intCast(text.len), sqlite_transient);
                },
            };
            if (rc != sqlite_ok) {
                self.db.setError(std.mem.span(self.db.lib.errmsg(self.db.handle)));
                return error.Sqlite;
            }
        }
    }

    /// 单步执行（无结果集）。
    pub fn run(self: Stmt) !void {
        const rc = self.db.lib.step(self.handle);
        if (rc == sqlite_done) return;
        if (rc == sqlite_row) return;
        self.db.setError(std.mem.span(self.db.lib.errmsg(self.db.handle)));
        return error.Sqlite;
    }

    /// 读一行（调用方需在 `arena` 上复制文本/二进制）。
    pub fn readRow(self: Stmt, arena: std.mem.Allocator) !Row {
        const count = self.db.lib.column_count(self.handle);
        var names: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList(Value) = .empty;

        var i: c_int = 0;
        while (i < count) : (i += 1) {
            const name_z = self.db.lib.column_name(self.handle, i);
            const name = std.mem.span(name_z);
            try names.append(arena, try arena.dupe(u8, name));

            const ctype = self.db.lib.column_type(self.handle, i);
            const value: Value = switch (ctype) {
                sqlite_integer => .{ .int = self.db.lib.column_int64(self.handle, i) },
                sqlite_float => .{ .float = self.db.lib.column_double(self.handle, i) },
                sqlite_text => blk: {
                    const text_z = self.db.lib.column_text(self.handle, i);
                    const len: usize = @intCast(@max(self.db.lib.column_bytes(self.handle, i), 0));
                    const src = text_z[0..len];
                    break :blk .{ .text = try arena.dupe(u8, src) };
                },
                sqlite_blob => blk: {
                    const len: usize = @intCast(@max(self.db.lib.column_bytes(self.handle, i), 0));
                    const raw = self.db.lib.column_blob(self.handle, i) orelse break :blk .null;
                    break :blk .{ .blob = try arena.dupe(u8, raw[0..len]) };
                },
                sqlite_null => .null,
                else => .null,
            };
            try values.append(arena, value);
        }
        return .{ .names = try names.toOwnedSlice(arena), .values = try values.toOwnedSlice(arena) };
    }
};

pub const Row = @import("row.zig").Row;

test "加载 SQLite 动态库并执行最小语句" {
    var lib = Lib.load(std.testing.allocator) catch |e| {
        // 本机没有可用 SQLite 时显式跳过（集成测试环境另行保证）
        std.debug.print("[SKIP] 无法加载 SQLite：{s}\n", .{@errorName(e)});
        return;
    };
    defer lib.deinit();
    try std.testing.expect(lib.version().len > 0);

    var db = try Db.open(&lib, ":memory:");
    defer db.close();
    _ = try db.exec(std.testing.allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)");
    _ = try db.exec(std.testing.allocator, "INSERT INTO t (name) VALUES ('a')");
    try std.testing.expectEqual(@as(usize, 1), db.changes());
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertId());

    const stmt = try db.prepare(std.testing.allocator, "SELECT COUNT(*) AS n FROM t");
    defer stmt.finalize();
    try stmt.bindAll(&.{});
    const rc = db.lib.step(stmt.handle);
    try std.testing.expectEqual(sqlite_row, rc);
    try std.testing.expectEqual(@as(i64, 1), db.lib.column_int64(stmt.handle, 0));
}
