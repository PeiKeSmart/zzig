//! InfluxDB 驱动（**HTTP API**：v1 `/write`+`/query`、v2 `/api/v2/write`+`/api/v2/query`）。
//!
//! 与 C# 侧口径一致（`DataAccessLayer/Database/InfluxDB.cs`）：
//! - **写入用 Line Protocol**（C# `InfluxDBSession.Insert` 走 `BuildLineProtocol` 后 `Execute`）；
//! - **查询**：v2 用 Flux（`Query(flux)`），v1 用 InfluxQL；
//! - 时序库**没有自增 ID**（`InsertAndGetIdentity` 恒 0），`Upsert` 等价于 `Insert`
//!   （相同 measurement + tags + timestamp 会覆盖旧点）。
//!
//! ## 写入口径
//! - v2（配了 `token` + `org` + `bucket`）：`POST {url}/api/v2/write?org=..&bucket=..&precision=ns`
//! - v1（只配了 `database`）：`POST {url}/write?db=..&precision=ns`
//! - 成功是 **204 No Content**（没有任何响应体），所以「状态码 2xx」即成功。
//!
//! ## 查入口径
//! - `queryAlloc` 根据语句自动分派：含 `|>` 或以 `from(` 开头 → **Flux**（v2）；
//!   否则 → **InfluxQL**（v1 `/query?db=..&q=..`）。两条路都返回统一 `Rows`。
//! - Flux 响应是**带注解的 CSV**（`#datatype` / `#group` / `#default`），按 `#datatype` 还原类型；
//! - InfluxQL 响应是 JSON（`results[].series[].columns/values`），按 JSON 原样取值。
//!
//! ## 已知边界
//! - 不实现 Flux 的客户端拼装（调用方给完整 Flux 文本）；
//! - 没有事务、没有 DDL（`create/drop` 由运维用 CLI 或 API 做，与 C# 的 `NotSupportedException` 一致）；
//! - REST 没有预处理语句：`exec` 的 `params` 只支持 Line Protocol 文本（不需要占位符）。

const std = @import("std");
const http = @import("../http/http.zig");
const compat = @import("../compat.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;
const DateTime = @import("../time/datetime.zig").DateTime;

pub const default_port: u16 = 8086;

pub const Options = struct {
    /// 完整 base URL（缺省按 host/port/tls 拼）；形如 `http://127.0.0.1:8086`
    url: []const u8 = "",
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    tls: bool = false,
    /// v2 令牌（`Authorization: Token xxx`）
    token: []const u8 = "",
    /// v2 组织
    org: []const u8 = "",
    /// v2 桶
    bucket: []const u8 = "",
    /// v1 库名（与 `bucket` 二选一；配了 `bucket` 就走 v2）
    database: []const u8 = "",
    /// 写入精度（`ns`/`us`/`ms`/`s`）；Line Protocol 里的时间戳按它解释
    precision: []const u8 = "ns",
    timeout_ms: u64 = 30_000,
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
    url: []u8 = &.{},
    host: []u8 = &.{},
    token: []u8 = &.{},
    org: []u8 = &.{},
    bucket: []u8 = &.{},
    database: []u8 = &.{},
    precision: []u8 = &.{},
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

        self.url = try gpa.dupe(u8, opts.url);
        errdefer gpa.free(self.url);
        self.host = try gpa.dupe(u8, opts.host);
        errdefer gpa.free(self.host);
        self.token = try gpa.dupe(u8, opts.token);
        errdefer gpa.free(self.token);
        self.org = try gpa.dupe(u8, opts.org);
        errdefer gpa.free(self.org);
        self.bucket = try gpa.dupe(u8, opts.bucket);
        errdefer gpa.free(self.bucket);
        self.database = try gpa.dupe(u8, opts.database);
        errdefer gpa.free(self.database);
        self.precision = try gpa.dupe(u8, if (opts.precision.len > 0) opts.precision else "ns");
        return self;
    }

    fn freeStrings(self: *Conn) void {
        for ([_][]u8{ self.url, self.host, self.token, self.org, self.bucket, self.database, self.precision }) |s| {
            if (s.len > 0) self.gpa.free(s);
        }
        self.url = &.{};
        self.host = &.{};
        self.token = &.{};
        self.org = &.{};
        self.bucket = &.{};
        self.database = &.{};
        self.precision = &.{};
    }

    pub fn deinit(self: *Conn) void {
        self.client.deinit();
        self.freeStrings();
    }

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// 时序库无自增列：恒 0（与 C# `InfluxDBSession.InsertAndGetIdentity` 一致）。
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

    /// 是否走 v2 API（有 bucket 就按 v2；否则走 v1 的 `db`）。
    pub fn isV2(self: *const Conn) bool {
        return self.bucket.len > 0;
    }

    fn baseAlloc(self: *const Conn, a: std.mem.Allocator) ![]u8 {
        if (self.url.len > 0) return a.dupe(u8, std.mem.trimEnd(u8, self.url, "/"));
        const scheme: []const u8 = if (self.tls) "https" else "http";
        return std.fmt.allocPrint(a, "{s}://{s}:{d}", .{ scheme, self.host, self.port });
    }

    /// 发请求；`Ok` 判定为 2xx。
    fn sendAlloc(self: *Conn, a: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, extra: []const std.http.Header) ![]u8 {
        var auth_buf: [512]u8 = undefined;
        var headers_buf: [4]std.http.Header = undefined;
        var n: usize = 0;
        if (self.token.len > 0) {
            const value = std.fmt.bufPrint(&auth_buf, "Token {s}", .{self.token}) catch {
                self.setError("InfluxDB 令牌过长（{d} 字节）", .{self.token.len});
                return Error.Server;
            };
            headers_buf[n] = .{ .name = "Authorization", .value = value };
            n += 1;
        }
        for (extra) |h| {
            if (n >= headers_buf.len) break;
            headers_buf[n] = h;
            n += 1;
        }

        const resp = http.fetchBytesWithTimeout(a, &self.client, .{
            .url = url,
            .method = method,
            .payload = payload,
            .extra_headers = headers_buf[0..n],
        }, self.timeout_ms, 20) catch |e| {
            self.setError("InfluxDB 请求失败（{s}）：{s}", .{ url, @errorName(e) });
            std.debug.print("[zzig.influxdb] {s}\n", .{self.lastError()});
            return e;
        };

        const code = @backingInt(resp.status);
        if (code < 200 or code >= 300) {
            self.setError("InfluxDB 返回 HTTP {d}（{s}）：{s}", .{ code, url, truncate(resp.body, 300) });
            std.debug.print("[zzig.influxdb] {s}\n", .{self.lastError()});
            return Error.HttpFailed;
        }
        return a.dupe(u8, resp.body) catch |e| e;
    }

    /// 写入 Line Protocol 文本（一个或多个换行分隔的点）。
    pub fn write(self: *Conn, arena: std.mem.Allocator, line_protocol: []const u8) !void {
        // URL 直接分配在调用方 arena，随会话结果一起回收
        const base = try self.baseAlloc(arena);
        const prec = if (self.precision.len > 0) self.precision else "ns";
        const url = if (self.isV2())
            try std.fmt.allocPrint(arena, "{s}/api/v2/write?org={s}&bucket={s}&precision={s}", .{
                base, try encAlloc(arena, self.org), try encAlloc(arena, self.bucket), prec,
            })
        else
            try std.fmt.allocPrint(arena, "{s}/write?db={s}&precision={s}", .{ base, try encAlloc(arena, self.database), prec });

        _ = try self.sendAlloc(arena, .POST, url, line_protocol, &.{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
        });
    }

    /// 查询：含 `|>` / 以 `from(` 开头 → Flux（v2）；其余按 InfluxQL（v1）。
    pub fn queryAlloc(self: *Conn, arena: std.mem.Allocator, text: []const u8, params: []const Value) !Result {
        _ = params; // 两条查询通道都没有占位符
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const looks_flux = std.mem.indexOf(u8, trimmed, "|>") != null or
            std.ascii.startsWithIgnoreCase(trimmed, "from(");

        if (looks_flux) return self.queryFluxAlloc(arena, trimmed);
        return self.queryInfluxQlAlloc(arena, trimmed);
    }

    pub fn queryFluxAlloc(self: *Conn, arena: std.mem.Allocator, flux: []const u8) !Result {
        const base = try self.baseAlloc(arena);
        const url = try std.fmt.allocPrint(arena, "{s}/api/v2/query?org={s}", .{ base, try encAlloc(arena, self.org) });
        const body = try self.sendAlloc(arena, .POST, url, flux, &.{
            .{ .name = "Content-Type", .value = "application/vnd.flux" },
            .{ .name = "Accept", .value = "application/csv" },
        });
        return parseAnnotatedCsv(arena, body);
    }

    pub fn queryInfluxQlAlloc(self: *Conn, arena: std.mem.Allocator, q: []const u8) !Result {
        const base = try self.baseAlloc(arena);
        const url = try std.fmt.allocPrint(arena, "{s}/query?db={s}&q={s}", .{ base, try encAlloc(arena, self.database), try encAlloc(arena, q) });
        const body = try self.sendAlloc(arena, .GET, url, null, &.{});
        return parseInfluxQlJson(arena, body);
    }

    /// 探活：`GET /ping`（v1/v2 都支持，返回 204）。
    pub fn ping(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const base = try self.baseAlloc(arena.allocator());
        const url = try std.fmt.allocPrint(arena.allocator(), "{s}/ping", .{base});
        _ = try self.sendAlloc(arena.allocator(), .GET, url, null, &.{});
    }
};

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// 查询串值编码（RFC3986；空格用 `%20`，与 Influx 文档一致）。
fn encAlloc(a: std.mem.Allocator, s: []const u8) ![]u8 {
    return http.percentEncodeFormComponent(a, s);
}

// ── Flux（带注解 CSV）解析 ──────────────────────────────────────────────────

/// 解析 InfluxDB v2 的带注解 CSV：
/// ```text
/// #datatype,string,long,dateTime:RFC3339,double
/// #group,false,false,true,false
/// #default,_result,,,
/// ,result,table,_time,_value
/// ,,0,2024-01-01T00:00:00Z,1.5
/// ```
/// 首个空列是注解标记列，一律跳过。
pub fn parseAnnotatedCsv(a: std.mem.Allocator, csv: []const u8) !Result {
    var datatypes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer datatypes.deinit(a);

    var names: []const []const u8 = &.{};
    var names_owned = false;

    var rows: std.ArrayListUnmanaged(Row) = .empty;

    var lines = std.mem.splitScalar(u8, csv, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;

        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "#datatype")) {
                var it = std.mem.splitScalar(u8, line, ',');
                _ = it.next(); // `#datatype`
                datatypes.clearRetainingCapacity();
                while (it.next()) |t| try datatypes.append(a, std.mem.trim(u8, t, " \t"));
            }
            // `#group` / `#default` 不参与取值
            continue;
        }

        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        defer fields.deinit(a);
        try splitCsvLine(a, line, &fields);
        if (fields.items.len == 0) continue;

        if (!names_owned) {
            // 表头：第一列（注解标记）为空，跳过
            const skip: usize = if (fields.items.len > 0 and fields.items[0].len == 0) 1 else 0;
            const cols = try a.alloc([]const u8, fields.items.len - skip);
            for (fields.items[skip..], 0..) |f, i| cols[i] = try a.dupe(u8, f);
            names = cols;
            names_owned = true;
            continue;
        }

        // 数据行：第一个空列同样是标记列
        if (fields.items.len > 0 and fields.items[0].len == 0 and fields.items.len > names.len) {
            _ = fields.orderedRemove(0);
        }
        if (fields.items.len < names.len) continue;

        const values = try a.alloc(Value, names.len);
        for (0..names.len) |i| {
            const cell = std.mem.trim(u8, fields.items[i], " \t");
            const ty: []const u8 = if (i < datatypes.items.len) datatypes.items[i] else "";
            values[i] = try csvCellToValue(a, cell, ty);
        }
        try rows.append(a, .{ .names = names, .values = values });
    }

    return .{ .rows = .{ .rows = try rows.toOwnedSlice(a) } };
}

fn splitCsvLine(a: std.mem.Allocator, line: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var i: usize = 0;
    while (true) {
        var field: std.ArrayListUnmanaged(u8) = .empty;
        if (i < line.len and line[i] == '"') {
            i += 1;
            while (i < line.len) {
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        try field.append(a, '"');
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                try field.append(a, line[i]);
                i += 1;
            }
            // 跳过闭合引号到下一个分隔符之间的残留
            while (i < line.len and line[i] != ',') : (i += 1) try field.append(a, line[i]);
        } else {
            while (i < line.len and line[i] != ',') : (i += 1) try field.append(a, line[i]);
        }
        try out.append(a, try field.toOwnedSlice(a));
        if (i >= line.len) break;
        i += 1; // 跳过 ','
        if (i > line.len) break;
    }
}

fn csvCellToValue(a: std.mem.Allocator, cell: []const u8, datatype: []const u8) !Value {
    if (cell.len == 0) return .null;
    if (std.ascii.eqlIgnoreCase(datatype, "long") or std.ascii.eqlIgnoreCase(datatype, "unsignedLong")) {
        if (std.fmt.parseInt(i64, cell, 10)) |v| return .{ .int = v } else |_| {}
    }
    if (std.ascii.eqlIgnoreCase(datatype, "double") or std.ascii.eqlIgnoreCase(datatype, "float")) {
        if (std.fmt.parseFloat(f64, cell)) |v| return .{ .float = v } else |_| {}
    }
    if (std.ascii.eqlIgnoreCase(datatype, "boolean")) {
        if (std.ascii.eqlIgnoreCase(cell, "true")) return .{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(cell, "false")) return .{ .boolean = false };
    }
    if (std.ascii.startsWithIgnoreCase(datatype, "dateTime")) {
        if (DateTime.parse(cell)) |v| return .{ .datetime = v } else |_| {}
    }
    return .{ .text = try a.dupe(u8, cell) };
}

// ── InfluxQL（v1 JSON）解析 ─────────────────────────────────────────────────

/// 解析 v1 JSON：`{"results":[{"series":[{"name":"t","columns":[...],"values":[[...]]}]}]}`。
pub fn parseInfluxQlJson(a: std.mem.Allocator, body: []const u8) !Result {
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return Error.Protocol;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return Error.Protocol,
    };
    // v1 的错误也是 200：`{"error":"..."}` 或 results[].error
    if (root.get("error")) |e| {
        if (e == .string) {
            std.debug.print("[zzig.influxdb] InfluxQL 错误：{s}\n", .{e.string});
            return Error.Server;
        }
    }

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    const results = root.get("results") orelse return .{ .rows = .{ .rows = &.{} } };
    if (results != .array) return .{ .rows = .{ .rows = &.{} } };

    for (results.array.items) |res| {
        const res_obj = switch (res) {
            .object => |o| o,
            else => continue,
        };
        if (res_obj.get("error")) |e| {
            if (e == .string) {
                std.debug.print("[zzig.influxdb] InfluxQL 错误：{s}\n", .{e.string});
                return Error.Server;
            }
        }
        const series = res_obj.get("series") orelse continue;
        if (series != .array) continue;
        for (series.array.items) |s| {
            const s_obj = switch (s) {
                .object => |o| o,
                else => continue,
            };
            var names: []const []const u8 = &.{};
            if (s_obj.get("columns")) |cols| {
                if (cols == .array) {
                    const names_slice = try a.alloc([]const u8, cols.array.items.len);
                    for (cols.array.items, 0..) |c, i| {
                        names_slice[i] = try a.dupe(u8, if (c == .string) c.string else "");
                    }
                    names = names_slice;
                }
            }
            const values = s_obj.get("values") orelse continue;
            if (values != .array) continue;
            for (values.array.items) |v| {
                const cells = switch (v) {
                    .array => |arr| arr.items,
                    else => continue,
                };
                const out = try a.alloc(Value, cells.len);
                for (cells, 0..) |cell, i| out[i] = try jsonCellToValue(a, cell);
                const n = @min(cells.len, names.len);
                try rows.append(a, .{ .names = names[0..n], .values = out });
            }
        }
    }

    return .{ .rows = .{ .rows = try rows.toOwnedSlice(a) } };
}

fn jsonCellToValue(a: std.mem.Allocator, v: std.json.Value) !Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .text = try a.dupe(u8, s) },
        .string => |s| .{ .text = try a.dupe(u8, s) },
        else => .null,
    };
}

// ── Line Protocol 生成（对应 C# `InfluxDBSession.BuildLineProtocol`）────────

/// 一个点（一行 Line Protocol）的三种角色，由**模型列**决定：
/// - `time`：时间列（列名 `Time` / `CreateTime` / `UpdateTime` 之一），写成行尾纳秒时间戳；
/// - `tag`：主键 / 主列（`primary_key`），写成 `key=value` 标签；
/// - `field`：其余列，写成 `key=value` 字段（字符串要加引号）。
pub const PointTag = struct {
    name: []const u8,
    value: []const u8,
};

pub const PointField = PointTag;

/// 生成一条 Line Protocol 行的 `measurement,tags fields timestamp` **主体**（不含换行）。
///
/// 转义口径（Line Protocol 规范）：
/// - measurement / tag key / tag value：空格、逗号、等号要反斜杠转义；
/// - field key：空格、逗号、等号要转义；
/// - field 字符串值：双引号包裹，内部 `"` 与 `\` 转义；
/// - 时间戳：纳秒（调用方保证）。
pub fn buildLineAlloc(
    a: std.mem.Allocator,
    measurement: []const u8,
    tags: []const PointTag,
    fields: []const PointField,
    timestamp_ns: ?i64,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);

    try appendEscaped(&out, a, measurement, " ,=");
    for (tags) |t| {
        try out.append(a, ',');
        try appendEscaped(&out, a, t.name, " ,=");
        try out.append(a, '=');
        try appendEscaped(&out, a, t.value, " ,=");
    }
    try out.append(a, ' ');
    for (fields, 0..) |f, i| {
        if (i > 0) try out.append(a, ',');
        try appendEscaped(&out, a, f.name, " ,=");
        try out.append(a, '=');
        // 字段值：调用方已按 Influx 语义格式化（数字原样、字符串带引号）
        try out.appendSlice(a, f.value);
    }
    if (timestamp_ns) |ts| {
        try out.append(a, ' ');
        var num: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&num, "{d}", .{ts}) catch "0";
        try out.appendSlice(a, text);
    }
    return out.toOwnedSlice(a);
}

fn appendEscaped(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8, chars: []const u8) !void {
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, chars, c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
}

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "influx line protocol：转义与时间戳" {
    const a = testing.allocator;
    const got = try buildLineAlloc(a, "weather, station", &.{
        .{ .name = "location", .value = "us-midwest 1" },
    }, &.{
        .{ .name = "temperature", .value = "82" },
        .{ .name = "note", .value = "\"a b\"" },
    }, 1_700_000_000_000_000_000);
    defer a.free(got);

    try testing.expectEqualStrings(
        "weather\\,\\ station,location=us-midwest\\ 1 temperature=82,note=\"a b\" 1700000000000000000",
        got,
    );
}

test "influx Flux 注解 CSV 解析" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const csv =
        "#datatype,string,long,dateTime:RFC3339,double\r\n" ++
        "#group,false,false,true,false\r\n" ++
        "#default,_result,,,\r\n" ++
        ",result,table,_time,_value\r\n" ++
        ",,0,2024-01-01T00:00:00Z,1.5\r\n" ++
        ",,0,2024-01-01T00:01:00Z,2.5\r\n";

    const r = try parseAnnotatedCsv(ar, csv);
    try testing.expectEqual(@as(usize, 2), r.rows.rows.len);
    try testing.expectEqualStrings("_value", r.rows.rows[0].names[3]);
    try testing.expectEqual(@as(f64, 1.5), r.rows.rows[0].values[3].asF64().?);
    try testing.expectEqual(@as(i64, 0), r.rows.rows[0].values[1].asI64().?);
    try testing.expectEqual(@as(usize, 4), r.rows.rows[1].values.len);
}

test "influx InfluxQL JSON 解析（含错误）" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const body =
        \\{"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["time","value"],
        \\"values":[["2024-01-01T00:00:00Z",0.64],["2024-01-01T00:01:00Z",0.7]]}]}]}
    ;
    const r = try parseInfluxQlJson(ar, body);
    try testing.expectEqual(@as(usize, 2), r.rows.rows.len);
    try testing.expectEqualStrings("value", r.rows.rows[0].names[1]);
    try testing.expectEqual(@as(f64, 0.64), r.rows.rows[0].values[1].asF64().?);

    try testing.expectError(Error.Server, parseInfluxQlJson(ar, "{\"error\":\"database not found\"}"));
}
