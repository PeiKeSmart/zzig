//! TDengine 驱动（**REST 接口** `/rest/sql`，不需要 taos 原生客户端库）。
//!
//! 为什么走 REST：TDengine 的 C 客户端（`libtaos`）要额外分发/安装，而 REST 只需要
//! HTTP（默认端口 **6041**），与 C# 侧 `XCode.TDengine` 的口径一致（`Database/TDengine.cs` 里
//! 端口缺省 6041、注释写明「HTTP 模式不再需要加载 native dll」）。
//!
//! ## 协议要点
//! - 请求：`POST /rest/sql`（或 `/rest/sql/<db>`），body 是**纯文本 SQL**，
//!   头部 `Authorization: Basic base64(user:password)`；
//! - 响应（3.x）：`{"code":0,"column_meta":[["ts","TIMESTAMP",8]],"data":[[...]],"rows":n}`；
//! - 响应（2.x）：`{"status":"succ","head":["ts"],"column_meta":[["ts",9,8]],"data":[[...]]}`；
//! - 出错：`{"code":534,"desc":"..."}` 或 `{"status":"error","code":534,"desc":"..."}`。
//!
//! ## 参数绑定
//! REST 通道**没有**预处理语句，服务端不接受 `?`。所以这里做**客户端内联**：
//! `?` 按出现顺序替换成 SQL 字面量（字符串单引号转义、时间格式化），
//! 与 C# `RemoteDbSession` 走 HTTP 时的做法一致。扫描时跳过 `'...'` / `"..."` /
//! `` `...` `` / `--` 行注释 / `/* */` 块注释里的 `?`。
//!
//! ## 已知边界（写清楚，不要靠猜）
//! - 无自增列语义 → `lastInsertId()` 恒 0（与 C# 一致：时序库用时间戳当主键）；
//! - 事务：TDengine 不支持多语句事务 → `begin/commit/rollback` 一律 `error.Unsupported`；
//! - 大结果集会整段读进内存（REST 无游标），批量导出请分页。

const std = @import("std");
const http = @import("../http/http.zig");
const compat = @import("../compat.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;
const DateTime = @import("../time/datetime.zig").DateTime;

pub const default_port: u16 = 6041;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    user: []const u8 = "root",
    password: []const u8 = "taosdata",
    /// 库名（非空时走 `/rest/sql/<db>`，等价于先 `USE <db>`）
    database: []const u8 = "",
    /// 走 https（REST over TLS）
    tls: bool = false,
    /// 请求超时（毫秒；0 = 不限）
    timeout_ms: u64 = 30_000,
    /// 自定义 base URL（优先级最高，形如 `http://host:6041`；非空时忽略 host/port/tls）
    base_url: []const u8 = "",
};

pub const Error = error{
    /// HTTP 层失败（连不上 / 非 2xx）
    HttpFailed,
    /// 响应不是预期 JSON
    Protocol,
    /// 服务端返回了非 0 的 code / `status=error`
    Server,
    /// 该动作 TDengine 不支持（事务等）
    Unsupported,
};

pub const Ok = struct {
    affected_rows: u64 = 0,
};

pub const Rows = struct {
    rows: []const Row,
};

pub const Result = union(enum) {
    ok: Ok,
    rows: Rows,
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    port: u16 = default_port,
    tls: bool = false,
    timeout_ms: u64 = 30_000,
    /// 自持的字符串副本（`Options` 里的切片通常来自连接串解析的临时内存）
    host: []u8 = &.{},
    user: []u8 = &.{},
    password: []u8 = &.{},
    database: []u8 = &.{},
    base_url: []u8 = &.{},
    client: std.http.Client,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
    /// 最近一次查询返回的行数（诊断用）
    last_rows: u64 = 0,

    pub fn open(gpa: std.mem.Allocator, opts: Options) !Conn {
        var self = Conn{
            .gpa = gpa,
            .port = opts.port,
            .tls = opts.tls,
            .timeout_ms = opts.timeout_ms,
            .client = .{ .allocator = gpa, .io = compat.currentIo() },
        };
        errdefer self.client.deinit();

        self.host = try gpa.dupe(u8, opts.host);
        errdefer gpa.free(self.host);
        self.user = try gpa.dupe(u8, opts.user);
        errdefer gpa.free(self.user);
        self.password = try gpa.dupe(u8, opts.password);
        errdefer gpa.free(self.password);
        self.database = try gpa.dupe(u8, opts.database);
        errdefer gpa.free(self.database);
        self.base_url = try gpa.dupe(u8, opts.base_url);
        return self;
    }

    fn freeStrings(self: *Conn) void {
        if (self.host.len > 0) self.gpa.free(self.host);
        if (self.user.len > 0) self.gpa.free(self.user);
        if (self.password.len > 0) self.gpa.free(self.password);
        if (self.database.len > 0) self.gpa.free(self.database);
        if (self.base_url.len > 0) self.gpa.free(self.base_url);
        self.host = &.{};
        self.user = &.{};
        self.password = &.{};
        self.database = &.{};
        self.base_url = &.{};
    }

    pub fn deinit(self: *Conn) void {
        self.client.deinit();
        self.freeStrings();
    }

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// TDengine 没有自增列：恒 0（时序库用时间戳当主键）。
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

    fn urlAlloc(self: *const Conn, a: std.mem.Allocator) ![]u8 {
        if (self.base_url.len > 0) {
            const base = std.mem.trimEnd(u8, self.base_url, "/");
            if (self.database.len > 0) return std.fmt.allocPrint(a, "{s}/rest/sql/{s}", .{ base, self.database });
            return std.fmt.allocPrint(a, "{s}/rest/sql", .{base});
        }
        const scheme: []const u8 = if (self.tls) "https" else "http";
        if (self.database.len > 0) {
            return std.fmt.allocPrint(a, "{s}://{s}:{d}/rest/sql/{s}", .{ scheme, self.host, self.port, self.database });
        }
        return std.fmt.allocPrint(a, "{s}://{s}:{d}/rest/sql", .{ scheme, self.host, self.port });
    }

    fn authHeaderAlloc(self: *const Conn, a: std.mem.Allocator) ![]u8 {
        var raw: std.ArrayListUnmanaged(u8) = .empty;
        defer raw.deinit(a);
        try raw.appendSlice(a, self.user);
        try raw.append(a, ':');
        try raw.appendSlice(a, self.password);

        const enc = std.base64.standard.Encoder;
        const out_len = enc.calcSize(raw.items.len);
        var out = try a.alloc(u8, out_len + "Basic ".len);
        @memcpy(out[0..6], "Basic ");
        _ = enc.encode(out[6..], raw.items);
        return out;
    }

    /// 发一条 SQL 到 REST 口，返回响应体（分配在 `a`）。
    fn postAlloc(self: *Conn, a: std.mem.Allocator, sql: []const u8) ![]u8 {
        const url = try self.urlAlloc(a);
        const auth = try self.authHeaderAlloc(a);

        const resp = http.fetchBytesWithTimeout(a, &self.client, .{
            .url = url,
            .method = .POST,
            .payload = sql,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            },
        }, self.timeout_ms, 20) catch |e| {
            self.setError("TDengine 请求失败（{s}）：{s}", .{ url, @errorName(e) });
            std.debug.print("[zzig.tdengine] {s}\n", .{self.lastError()});
            return e;
        };

        if (@backingInt(resp.status) < 200 or @backingInt(resp.status) >= 300) {
            self.setError("TDengine 返回 HTTP {d}（{s}）：{s}", .{
                @backingInt(resp.status),
                url,
                truncate(resp.body, 300),
            });
            std.debug.print("[zzig.tdengine] {s}\n", .{self.lastError()});
            return Error.HttpFailed;
        }
        return a.dupe(u8, resp.body) catch |e| e;
    }

    /// 执行写语句，返回影响行数（TDengine 3.x 的 `affected_rows`；没有该字段时为 0）。
    pub fn exec(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !u64 {
        const text = try inlineParamsAlloc(arena, sql, params);
        const body = try self.postAlloc(arena, text);
        const r = try parseRoot(self, arena, body);
        return switch (r) {
            .ok => |o| o.affected_rows,
            .rows => 0,
        };
    }

    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        const text = try inlineParamsAlloc(arena, sql, params);
        const body = try self.postAlloc(arena, text);
        return parseRoot(self, arena, body);
    }

    /// 探活：`SELECT SERVER_VERSION()` 能跑通即认为连接可用。
    pub fn ping(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = try self.queryAlloc(arena.allocator(), "SELECT SERVER_VERSION()", &.{});
    }

    /// 服务端版本（失败返回空串；诊断用）。
    pub fn serverVersionAlloc(self: *Conn, a: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = self.queryAlloc(arena.allocator(), "SELECT SERVER_VERSION()", &.{}) catch return a.dupe(u8, "");
        switch (r) {
            .rows => |rows| {
                if (rows.rows.len > 0 and rows.rows[0].values.len > 0) {
                    if (rows.rows[0].values[0].asText()) |t| return a.dupe(u8, t);
                }
                return a.dupe(u8, "");
            },
            .ok => return a.dupe(u8, ""),
        }
    }
};

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    // 别切开 UTF-8 多字节序列
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ── 响应解析 ────────────────────────────────────────────────────────────────

/// 解析 REST 响应。**所有结果都分配在 `a`**（调用方通常是 `Session` 的 arena）。
fn parseRoot(self: *Conn, a_in: std.mem.Allocator, body: []const u8) !Result {
    var parsed = std.json.parseFromSlice(std.json.Value, a_in, body, .{}) catch {
        self.setError("TDengine 响应不是合法 JSON：{s}", .{truncate(body, 200)});
        std.debug.print("[zzig.tdengine] {s}\n", .{self.lastError()});
        return Error.Protocol;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            self.setError("TDengine 响应不是 JSON 对象：{s}", .{truncate(body, 200)});
            return Error.Protocol;
        },
    };

    // 错误优先：3.x 用 code，2.x 用 status + code
    const code: i64 = if (root.get("code")) |c| switch (c) {
        .integer => |v| v,
        else => 0,
    } else 0;
    const status_err = if (root.get("status")) |s| switch (s) {
        .string => |t| std.ascii.eqlIgnoreCase(t, "error"),
        else => false,
    } else false;

    if (code != 0 or status_err) {
        const desc: []const u8 = if (root.get("desc")) |d| switch (d) {
            .string => |t| t,
            else => "",
        } else "";
        self.setError("TDengine 错误 {d}：{s}", .{ code, desc });
        std.debug.print("[zzig.tdengine] {s}\n", .{self.lastError()});
        return Error.Server;
    }

    const data_val = root.get("data");
    if (data_val == null) {
        const affected: u64 = if (root.get("affected_rows")) |v| switch (v) {
            .integer => |i| @intCast(@max(i, 0)),
            else => 0,
        } else 0;
        return .{ .ok = .{ .affected_rows = affected } };
    }
    if (data_val.? != .array) return .{ .ok = .{} };

    const data_rows = data_val.?.array.items;
    if (data_rows.len == 0) return .{ .rows = .{ .rows = &.{} } };

    // 列名 + 类型：3.x 的 column_meta = [[name, "TIMESTAMP", 8], ...]
    //              2.x 的 column_meta = [[name, 9, 8], ...]，列名也可能在 `head`
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(a_in);
    var types: std.ArrayListUnmanaged(TDType) = .empty;
    defer types.deinit(a_in);

    if (root.get("column_meta")) |cm| {
        if (cm == .array) {
            for (cm.array.items) |item| {
                switch (item) {
                    .array => |pair| {
                        if (pair.items.len == 0) continue;
                        const name: []const u8 = if (pair.items[0] == .string) pair.items[0].string else "";
                        try names.append(a_in, try a_in.dupe(u8, name));
                        try types.append(a_in, if (pair.items.len > 1) typeOfJson(pair.items[1]) else .unknown);
                    },
                    else => {},
                }
            }
        }
    } else if (root.get("head")) |head| {
        if (head == .array) {
            for (head.array.items) |item| {
                try names.append(a_in, try a_in.dupe(u8, if (item == .string) item.string else ""));
                try types.append(a_in, .unknown);
            }
        }
    }

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    // 列名切片要独立一份：`names` 是临时 ArrayList，出作用域就释放，
    // 直接塞 `names.items` 会让每一行都指向已释放内存（实测：读 names 时崩）。
    const cols = try a_in.alloc([]const u8, names.items.len);
    @memcpy(cols, names.items);

    for (data_rows) |r| {
        const arr = switch (r) {
            .array => |arr| arr.items,
            else => continue,
        };
        const values = try a_in.alloc(Value, arr.len);
        for (arr, 0..) |cell, i| {
            const ty: TDType = if (i < types.items.len) types.items[i] else .unknown;
            values[i] = try jsonToValue(a_in, cell, ty);
        }
        try rows.append(a_in, .{ .names = cols, .values = values });
    }

    self.last_rows = rows.items.len;
    return .{ .rows = .{ .rows = try rows.toOwnedSlice(a_in) } };
}

/// TDengine 列类型（只区分「需要转 datetime」和「需要转文本」这两类，其余按 JSON 原样）。
const TDType = enum {
    unknown,
    timestamp,
    binary,
    number,
    boolean,
};

fn typeOfJson(v: std.json.Value) TDType {
    return switch (v) {
        .string => |t| blk: {
            if (eqAny(t, &.{ "TIMESTAMP", "timestamp" })) break :blk .timestamp;
            if (eqAny(t, &.{ "BINARY", "NCHAR", "VARCHAR", "JSON", "GEOMETRY" })) break :blk .binary;
            if (eqAny(t, &.{ "BOOL", "BOOLEAN" })) break :blk .boolean;
            break :blk .number;
        },
        // 2.x 用数字类型码：1=bool 8=binary 9=timestamp 10=nchar 11=json
        .integer => |code| switch (code) {
            1 => .boolean,
            8, 10, 11 => .binary,
            9 => .timestamp,
            else => .number,
        },
        else => .unknown,
    };
}

fn eqAny(text: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.ascii.eqlIgnoreCase(text, o)) return true;
    }
    return false;
}

fn jsonToValue(a: std.mem.Allocator, v: std.json.Value, ty: TDType) !Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| if (ty == .timestamp) .{ .datetime = fromMillis(i) } else .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .text = try a.dupe(u8, s) },
        .string => |s| blk: {
            if (ty == .timestamp) {
                if (std.fmt.parseInt(i64, s, 10) catch null) |ms| break :blk .{ .datetime = fromMillis(ms) };
                break :blk .{ .datetime = DateTime.parse(s) catch DateTime.fromUnixSeconds(0) };
            }
            break :blk .{ .text = try a.dupe(u8, s) };
        },
        else => .null,
    };
}

fn fromMillis(ms: i64) DateTime {
    var dt = DateTime.fromUnixSeconds(@divFloor(ms, 1000));
    dt.nanos = @intCast(@mod(ms, 1000) * std.time.ns_per_ms);
    return dt;
}

// ── 参数内联 ────────────────────────────────────────────────────────────────

/// 实现已下沉到 `inline.zig`（TDengine REST 与 ClickHouse HTTP 共用）：
/// 这两家通道都没有预处理语句，`?` 必须客户端内联成字面量。
pub const inlineParamsAlloc = @import("inline.zig").inlineParamsAlloc;

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "tdengine 参数内联：字符串转义与注释保护" {
    const a = testing.allocator;

    const got = try inlineParamsAlloc(a, "INSERT INTO t VALUES (?, 'a?b', ?, \"c?d\") -- e?\n", &.{
        .{ .int = 7 },
        .{ .text = "O'Reilly" },
    });
    defer a.free(got);

    // 字符串里的 ? 与注释里的 ? 都不能被替换
    try testing.expect(std.mem.indexOf(u8, got, "7, 'a?b', 'O''Reilly', \"c?d\"") != null);
}

test "tdengine 参数内联：无参数原样返回" {
    const a = testing.allocator;
    const got = try inlineParamsAlloc(a, "SELECT ?", &.{});
    defer a.free(got);
    try testing.expectEqualStrings("SELECT ?", got);
}

test "tdengine 响应解析（3.x column_meta 字符串类型 + 时间戳）" {
    const a = testing.allocator;
    var conn = Conn{ .gpa = a, .client = .{ .allocator = a, .io = compat.currentIo() } };
    defer conn.client.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const body =
        \\{"code":0,"column_meta":[["ts","TIMESTAMP",8],["cur","FLOAT",4],["name","NCHAR",16]],
        \\"data":[[1700000000000,1.5,"天气"]],"rows":1}
    ;
    const r = try parseRoot(&conn, arena.allocator(), body);
    const rows = r.rows.rows;
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(usize, 3), rows[0].values.len);
    try testing.expect(rows[0].values[0] == .datetime);
    try testing.expectEqual(@as(f64, 1.5), rows[0].values[1].asF64().?);
    try testing.expectEqualStrings("天气", rows[0].values[2].asText().?);
    try testing.expectEqualStrings("cur", rows[0].names[1]);
}

test "tdengine 响应解析（2.x status/head 与错误码）" {
    const a = testing.allocator;
    var conn = Conn{ .gpa = a, .client = .{ .allocator = a, .io = compat.currentIo() } };
    defer conn.client.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const ok_body =
        \\{"status":"succ","head":["ts","v"],"column_meta":[["ts",9,8],["v",4,4]],"data":[[1700000000000,42]]}
    ;
    const r = try parseRoot(&conn, ar, ok_body);
    try testing.expectEqual(@as(usize, 1), r.rows.rows.len);
    try testing.expectEqual(@as(i64, 42), r.rows.rows[0].values[1].asI64().?);

    try testing.expectError(Error.Server, parseRoot(&conn, ar, "{\"status\":\"error\",\"code\":534,\"desc\":\"Table does not exist\"}"));
    try testing.expect(std.mem.indexOf(u8, conn.lastError(), "Table does not exist") != null);
}
