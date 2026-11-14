//! ClickHouse 驱动（**HTTP 接口**，默认端口 8123，不依赖 clickhouse-cpp）。
//!
//! 与 C# 侧 `XCode.ClickHouse` 走 HTTP 的模式一致：一条 SQL 一个 HTTP 请求，
//! 服务端把结果序列化成 JSON 回给我们。
//!
//! ## 协议要点（都按官方 HTTP 接口文档）
//! - 请求：`POST http://host:8123/?database=<db>&default_format=JSONCompact`，body 是**纯文本 SQL**；
//!   鉴权用 `X-ClickHouse-User` / `X-ClickHouse-Key` 头（不把口令放 URL，避免落到代理日志）。
//! - `default_format=JSONCompact`：**查询**自动回 JSON，`INSERT` / `DDL` 不受影响，
//!   所以不需要「先猜这条语句是不是 SELECT 再拼 FORMAT」（拼错 FORMAT 会让 DDL 变语法错）。
//! - 响应（查询）：`{"meta":[{"name":"x","type":"UInt64"}],"data":[[1]],"rows":1}`；
//! - 响应（写入/DDL）：2xx + 空 body；
//! - 出错：非 2xx，body 是 `Code: 62. DB::Exception: Syntax error ...` 这样的文本。
//!
//! ## 两个容易踩的点
//! 1. **没有预处理语句**：`?` 一律客户端内联（`inline.zig`，与 TDengine 共用同一实现）；
//! 2. **64 位整数默认按字符串回**（`output_format_json_quote_64bit_integers=1`），
//!    所以 `Int64/UInt64` 的 `"123"` 必须按类型解析回整数，不能一律当文本。
//!
//! ## 已知边界
//! - 无自增列语义 → `lastInsertId()` 恒 0；
//! - 事务：ClickHouse 没有跨语句事务 → 上层 `Session.beginTransaction` 对其报 `error.Unsupported`。

const std = @import("std");
const http = @import("../http/http.zig");
const compat = @import("../compat.zig");
const sql_inline = @import("inline.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;
const DateTime = @import("../time/datetime.zig").DateTime;
const Decimal = @import("../number/decimal.zig").Decimal;

pub const default_port: u16 = 8123;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    /// ClickHouse 默认账号就是 `default`（空口令）
    user: []const u8 = "default",
    password: []const u8 = "",
    database: []const u8 = "",
    tls: bool = false,
    timeout_ms: u64 = 30_000,
    /// 自定义 base URL（形如 `http://host:8123`；非空时忽略 host/port/tls）
    base_url: []const u8 = "",
};

pub const Error = error{
    HttpFailed,
    Protocol,
    Server,
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
    host: []u8 = &.{},
    user: []u8 = &.{},
    password: []u8 = &.{},
    database: []u8 = &.{},
    base_url: []u8 = &.{},
    client: std.http.Client,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
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

    /// ClickHouse 没有自增列：恒 0。
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
        const base = if (self.base_url.len > 0)
            std.mem.trimEnd(u8, self.base_url, "/")
        else if (self.tls)
            try std.fmt.allocPrint(a, "https://{s}:{d}", .{ self.host, self.port })
        else
            try std.fmt.allocPrint(a, "http://{s}:{d}", .{ self.host, self.port });

        if (self.database.len > 0) {
            const db = try http.percentEncodeFormComponent(a, self.database);
            return std.fmt.allocPrint(a, "{s}/?database={s}&default_format=JSONCompact", .{ base, db });
        }
        return std.fmt.allocPrint(a, "{s}/?default_format=JSONCompact", .{base});
    }

    fn postAlloc(self: *Conn, a: std.mem.Allocator, sql: []const u8) ![]u8 {
        const url = try self.urlAlloc(a);

        const resp = http.fetchBytesWithTimeout(a, &self.client, .{
            .url = url,
            .method = .POST,
            .payload = sql,
            .extra_headers = &.{
                .{ .name = "X-ClickHouse-User", .value = self.user },
                .{ .name = "X-ClickHouse-Key", .value = self.password },
            },
        }, self.timeout_ms, 20) catch |e| {
            self.setError("ClickHouse 请求失败（{s}）：{s}", .{ url, @errorName(e) });
            std.debug.print("[zzig.clickhouse] {s}\n", .{self.lastError()});
            return e;
        };

        const code = @intFromEnum(resp.status);
        if (code < 200 or code >= 300) {
            self.setError("ClickHouse 返回 HTTP {d}：{s}", .{ code, truncate(resp.body, 400) });
            std.debug.print("[zzig.clickhouse] {s}\n", .{self.lastError()});
            return Error.HttpFailed;
        }
        return a.dupe(u8, resp.body) catch |e| e;
    }

    /// 执行写语句 / DDL，返回影响行数。
    ///
    /// ClickHouse 的 HTTP 接口把「写入了多少行」放在 `X-ClickHouse-Summary` **响应头**里，
    /// 而不是响应体；本驱动只读响应体 → 这里恒返回 0。需要精确计数请自行查 `system.parts` /
    /// `system.mutations`，不要拿这个 0 当「没写进去」。
    pub fn exec(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !u64 {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        const body = try self.postAlloc(arena, text);
        // 写入/DDL 的 body 通常为空；万一带了 JSON（`INSERT ... SELECT` 之类）也照样解析，不吃亏
        if (body.len > 0 and body[0] == '{') {
            const r = try parseRoot(self, arena, body);
            return switch (r) {
                .ok => |o| o.affected_rows,
                .rows => 0,
            };
        }
        return 0;
    }

    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !Result {
        const text = try sql_inline.inlineParamsAlloc(arena, sql, params);
        const body = try self.postAlloc(arena, text);
        if (body.len == 0) return .{ .ok = .{} };
        return parseRoot(self, arena, body);
    }

    /// 探活：`GET /ping` 回 `Ok.`（无论带不带库）。
    pub fn ping(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const base = if (self.base_url.len > 0)
            std.mem.trimEnd(u8, self.base_url, "/")
        else if (self.tls)
            try std.fmt.allocPrint(a, "https://{s}:{d}", .{ self.host, self.port })
        else
            try std.fmt.allocPrint(a, "http://{s}:{d}", .{ self.host, self.port });
        const url = try std.fmt.allocPrint(a, "{s}/ping", .{base});

        const resp = http.fetchBytesWithTimeout(a, &self.client, .{ .url = url, .method = .GET }, self.timeout_ms, 20) catch |e| {
            self.setError("ClickHouse 探活失败（{s}）：{s}", .{ url, @errorName(e) });
            return e;
        };
        if (@intFromEnum(resp.status) != 200) {
            self.setError("ClickHouse 探活返回 HTTP {d}：{s}", .{ @intFromEnum(resp.status), truncate(resp.body, 200) });
            return Error.HttpFailed;
        }
    }

    /// 服务端版本（`SELECT version()`）。
    pub fn serverVersionAlloc(self: *Conn, a: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const r = self.queryAlloc(arena.allocator(), "SELECT version()", &.{}) catch return a.dupe(u8, "");
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
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ── 响应解析 ────────────────────────────────────────────────────────────────

/// 解析 `default_format=JSONCompact` 的响应（`meta`/`data`/`rows`）。
fn parseRoot(self: *Conn, a_in: std.mem.Allocator, body: []const u8) !Result {
    var parsed = std.json.parseFromSlice(std.json.Value, a_in, body, .{}) catch {
        self.setError("ClickHouse 响应不是合法 JSON：{s}", .{truncate(body, 200)});
        std.debug.print("[zzig.clickhouse] {s}\n", .{self.lastError()});
        return Error.Protocol;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            self.setError("ClickHouse 响应不是 JSON 对象：{s}", .{truncate(body, 200)});
            return Error.Protocol;
        },
    };

    // 有些代理/旧版本会用 `{"exception": "..."}`
    if (root.get("exception")) |e| {
        if (e == .string) {
            self.setError("ClickHouse 异常：{s}", .{truncate(e.string, 400)});
            std.debug.print("[zzig.clickhouse] {s}\n", .{self.lastError()});
            return Error.Server;
        }
    }

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(a_in);
    var types: std.ArrayListUnmanaged([]const u8) = .empty;
    defer types.deinit(a_in);

    if (root.get("meta")) |meta| {
        if (meta == .array) {
            for (meta.array.items) |m| {
                switch (m) {
                    .object => |o| {
                        const nm: []const u8 = if (o.get("name")) |n| switch (n) {
                            .string => |s| s,
                            else => "",
                        } else "";
                        const ty: []const u8 = if (o.get("type")) |t| switch (t) {
                            .string => |s| s,
                            else => "",
                        } else "";
                        try names.append(a_in, try a_in.dupe(u8, nm));
                        try types.append(a_in, try a_in.dupe(u8, ty));
                    },
                    else => {},
                }
            }
        }
    }

    const data = root.get("data") orelse return .{ .ok = .{} };
    if (data != .array) return .{ .ok = .{} };

    const cols = try a_in.alloc([]const u8, names.items.len);
    @memcpy(cols, names.items);

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (data.array.items) |r| {
        const cells = switch (r) {
            .array => |arr| arr.items,
            else => continue,
        };
        const values = try a_in.alloc(Value, cells.len);
        for (cells, 0..) |cell, i| {
            const ty: []const u8 = if (i < types.items.len) types.items[i] else "";
            values[i] = try cellToValue(a_in, cell, ty);
        }
        try rows.append(a_in, .{ .names = cols, .values = values });
    }

    self.last_rows = rows.items.len;
    return .{ .rows = .{ .rows = try rows.toOwnedSlice(a_in) } };
}

/// 去掉 `Nullable(...)` / `LowCardinality(...)` 外壳（可能嵌套）。
fn unwrapType(ty: []const u8) []const u8 {
    var t = std.mem.trim(u8, ty, " ");
    while (t.len > 0 and t[t.len - 1] == ')') {
        const open = std.mem.indexOfScalar(u8, t, '(') orelse break;
        const inner = std.mem.trim(u8, t[open + 1 .. t.len - 1], " ");
        const wrapper = std.mem.trim(u8, t[0..open], " ");
        const is_wrapper = std.ascii.eqlIgnoreCase(wrapper, "Nullable") or
            std.ascii.eqlIgnoreCase(wrapper, "LowCardinality") or
            std.ascii.eqlIgnoreCase(wrapper, "SimpleAggregateFunction");
        if (!is_wrapper) break;
        // `SimpleAggregateFunction(sum, UInt64)`：取最后一个逗号后的部分
        if (std.ascii.eqlIgnoreCase(wrapper, "SimpleAggregateFunction")) {
            if (std.mem.lastIndexOfScalar(u8, inner, ',')) |comma| {
                t = std.mem.trim(u8, inner[comma + 1 ..], " ");
                continue;
            }
        }
        t = inner;
    }
    return t;
}

fn typeIsInt(ty: []const u8) bool {
    return startsWithAnyIgnoreCase(ty, &.{ "Int8", "Int16", "Int32", "Int64", "Int128", "Int256", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256" });
}

fn typeIsFloat(ty: []const u8) bool {
    return startsWithAnyIgnoreCase(ty, &.{ "Float32", "Float64", "BFloat16" });
}

fn typeIsDecimal(ty: []const u8) bool {
    return startsWithAnyIgnoreCase(ty, &.{ "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256" });
}

fn typeIsDateTime(ty: []const u8) bool {
    return startsWithAnyIgnoreCase(ty, &.{ "DateTime64", "DateTime", "Date32", "Date" });
}

fn startsWithAnyIgnoreCase(text: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.ascii.startsWithIgnoreCase(text, o)) return true;
    }
    return false;
}

fn cellToValue(a: std.mem.Allocator, v: std.json.Value, ty_raw: []const u8) !Value {
    const ty = unwrapType(ty_raw);
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        // 64 位整数默认被引号包起来（output_format_json_quote_64bit_integers），按类型解析回去
        .string => |s| blk: {
            if (typeIsInt(ty)) {
                if (std.fmt.parseInt(i64, s, 10) catch null) |i| break :blk .{ .int = i };
            }
            if (typeIsFloat(ty)) {
                if (std.fmt.parseFloat(f64, s) catch null) |f| break :blk .{ .float = f };
            }
            if (typeIsDecimal(ty)) {
                if (Decimal.parse(s) catch null) |d| break :blk .{ .decimal = d };
            }
            if (typeIsDateTime(ty)) {
                if (DateTime.parse(s) catch null) |dt| break :blk .{ .datetime = dt };
            }
            break :blk .{ .text = try a.dupe(u8, s) };
        },
        .integer => |i| if (typeIsDateTime(ty)) .{ .datetime = DateTime.fromUnixSeconds(i) } else .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .text = try a.dupe(u8, s) },
        // Array / Tuple / Map / Nested：原样序列化成 JSON 文本（业务侧自己解析）
        .array, .object => .{ .text = try stringifyAlloc(a, v) },
    };
}

fn stringifyAlloc(a: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(a, 128);
    errdefer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.write(v);
    return out.toOwnedSlice();
}

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testConn(a: std.mem.Allocator) Conn {
    return .{ .gpa = a, .client = .{ .allocator = a, .io = compat.currentIo() } };
}

test "clickhouse 响应解析：类型还原（含 64 位整数按字符串回）" {
    const a = testing.allocator;
    var conn = testConn(a);
    defer conn.client.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const body =
        \\{"meta":[{"name":"id","type":"UInt64"},{"name":"v","type":"Nullable(Float64)"},
        \\{"name":"name","type":"LowCardinality(String)"},{"name":"t","type":"DateTime"},
        \\{"name":"arr","type":"Array(UInt8)"}],
        \\"data":[["1844674407370955161","1.5","天气","2024-01-01 10:20:30","[1,2]"]],"rows":1}
    ;
    const r = try parseRoot(&conn, arena.allocator(), body);
    const rows = r.rows.rows;
    try testing.expectEqual(@as(usize, 1), rows.len);
    // 64 位整数以字符串回 → 按类型解析成整数
    try testing.expectEqual(@as(i64, 1844674407370955161), rows[0].values[0].asI64().?);
    try testing.expectEqual(@as(f64, 1.5), rows[0].values[1].asF64().?);
    try testing.expectEqualStrings("天气", rows[0].values[2].asText().?);
    try testing.expect(rows[0].values[3] == .datetime);
    try testing.expectEqualStrings("[1,2]", rows[0].values[4].asText().?);
    try testing.expectEqualStrings("v", rows[0].names[1]);
}

test "clickhouse 响应解析：空 data 与非 JSON 响应" {
    const a = testing.allocator;
    var conn = testConn(a);
    defer conn.client.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const ok = try parseRoot(&conn, ar, "{\"meta\":[],\"data\":[],\"rows\":0}");
    try testing.expectEqual(@as(usize, 0), ok.rows.rows.len);

    try testing.expectError(Error.Protocol, parseRoot(&conn, ar, "Ok."));
    try testing.expectError(Error.Server, parseRoot(&conn, ar, "{\"exception\":\"Code: 62. DB::Exception: Syntax error\"}"));
    try testing.expect(std.mem.indexOf(u8, conn.lastError(), "Syntax error") != null);
}

test "clickhouse 类型外壳剥离" {
    try testing.expectEqualStrings("String", unwrapType("LowCardinality(Nullable(String))"));
    try testing.expectEqualStrings("UInt64", unwrapType("SimpleAggregateFunction(sum, UInt64)"));
    try testing.expectEqualStrings("Array(UInt8)", unwrapType("Array(UInt8)"));
}
