//! TDengine / InfluxDB 驱动的**回环端到端**用例：起一个「脚本化 HTTP 假服务端」，
//! 让真实驱动走完整 HTTP 往返。
//!
//! 为什么不用真库：本机/CI 不一定装了 TDengine 或 InfluxDB。这里覆盖的是**线上协议**——
//! 请求方法/路径/查询串、`Authorization` 头、请求体（SQL 或 Line Protocol）、
//! 响应解析（TDengine 的 code/column_meta/data、InfluxDB 的注解 CSV 与 v1 JSON）。
//! SQL 语义正确性由真库用例覆盖，不在本文件范围内。

const std = @import("std");
const http_server = @import("../http/server.zig");
const tdengine = @import("tdengine.zig");
const influxdb = @import("influxdb.zig");
const clickhouse = @import("clickhouse.zig");

const Reply = http_server.Reply;

/// 假服务端：记录最后一次请求，并回放预置响应。
const Ctx = struct {
    path: [256]u8 = undefined,
    path_len: usize = 0,
    query: [512]u8 = undefined,
    query_len: usize = 0,
    body: [4096]u8 = undefined,
    body_len: usize = 0,
    auth: [256]u8 = undefined,
    auth_len: usize = 0,
    /// ClickHouse 用 `X-ClickHouse-User` / `X-ClickHouse-Key` 头鉴权
    ch_user: [128]u8 = undefined,
    ch_user_len: usize = 0,
    ch_key: [128]u8 = undefined,
    ch_key_len: usize = 0,
    method: std.http.Method = .GET,
    reply_body: []const u8 = "{}",
    status: std.http.Status = .ok,
    requests: usize = 0,

    fn pathText(self: *const Ctx) []const u8 {
        return self.path[0..self.path_len];
    }
    fn queryText(self: *const Ctx) []const u8 {
        return self.query[0..self.query_len];
    }
    fn bodyText(self: *const Ctx) []const u8 {
        return self.body[0..self.body_len];
    }
    fn authText(self: *const Ctx) []const u8 {
        return self.auth[0..self.auth_len];
    }

    fn handle(raw: *anyopaque, req: http_server.RequestView, arena: std.mem.Allocator) anyerror!Reply {
        _ = arena;
        const self: *Ctx = @ptrCast(@alignCast(raw));
        self.requests += 1;
        self.method = req.method;
        copyInto(&self.path, &self.path_len, req.path);
        copyInto(&self.query, &self.query_len, req.query);
        copyInto(&self.body, &self.body_len, req.body);
        for (req.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                copyInto(&self.auth, &self.auth_len, h.value);
            } else if (std.ascii.eqlIgnoreCase(h.name, "x-clickhouse-user")) {
                copyInto(&self.ch_user, &self.ch_user_len, h.value);
            } else if (std.ascii.eqlIgnoreCase(h.name, "x-clickhouse-key")) {
                copyInto(&self.ch_key, &self.ch_key_len, h.value);
            }
        }
        return .{ .status = self.status, .body = self.reply_body };
    }
};

fn copyInto(dst: []u8, len_out: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    len_out.* = n;
}

const Listener = struct {
    server: *http_server.Server,
    listener: *std.Io.net.Server,
    io: std.Io,
    /// 要处理多少个请求（每个请求一条连接）
    count: usize,

    fn run(self: *Listener) void {
        for (0..self.count) |_| {
            const stream = self.listener.accept(self.io) catch return;
            self.server.serveOne(stream) catch {};
            stream.close(self.io);
        }
    }
};

/// 找一个能绑的端口（本机可能被占，全占则返回 null → 用例显式 SKIP）。
fn listenAny(io: std.Io, start_port: u16) ?struct { port: u16, listener: std.Io.net.Server } {
    var port = start_port;
    while (port < start_port + 20) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        const l = addr.listen(io, .{ .reuse_address = true }) catch continue;
        return .{ .port = port, .listener = l };
    }
    return null;
}

test "TDengine 端到端（回环假服务端）：POST /rest/sql + Basic 头 + 结果集解析" {
    const a = std.testing.allocator;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    const bound = listenAny(sio, 39301) orelse {
        std.debug.print("[SKIP] 39301-39320 端口均不可用，跳过 TDengine 回环用例\n", .{});
        return;
    };
    var listener = bound.listener;
    defer listener.deinit(sio);

    var ctx = Ctx{
        .reply_body =
        \\{"code":0,"column_meta":[["ts","TIMESTAMP",8],["cur","FLOAT",4]],
        \\"data":[[1700000000000,1.25]],"rows":1}
        ,
    };
    var server = http_server.Server{
        .gpa = a,
        .io = sio,
        .ctx = @ptrCast(&ctx),
        .handler = Ctx.handle,
    };
    var lctx = Listener{ .server = &server, .listener = &listener, .io = sio, .count = 1 };
    const th = try std.Thread.spawn(.{}, Listener.run, .{&lctx});

    var conn = try tdengine.Conn.open(a, .{
        .host = "127.0.0.1",
        .port = bound.port,
        .user = "root",
        .password = "taosdata",
    });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const r = try conn.queryAlloc(arena.allocator(), "SELECT ts, cur FROM meters WHERE cur > ?", &.{.{ .float = 1.0 }});
    th.join();

    // 请求侧：路径、方法、鉴权、body（参数已内联）
    try std.testing.expectEqual(std.http.Method.POST, ctx.method);
    try std.testing.expectEqualStrings("/rest/sql", ctx.pathText());
    try std.testing.expect(std.mem.startsWith(u8, ctx.authText(), "Basic "));
    try std.testing.expectEqualStrings("SELECT ts, cur FROM meters WHERE cur > 1", ctx.bodyText());

    // 响应侧：行数 / 列名 / 时间戳转 datetime
    try std.testing.expectEqual(@as(usize, 1), r.rows.rows.len);
    try std.testing.expectEqualStrings("cur", r.rows.rows[0].names[1]);
    try std.testing.expectEqual(@as(f64, 1.25), r.rows.rows[0].values[1].asF64().?);
    try std.testing.expect(r.rows.rows[0].values[0] == .datetime);
}

test "TDengine 端到端：服务端错误码映射成 error.Server 且带原因" {
    const a = std.testing.allocator;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    const bound = listenAny(sio, 39331) orelse return;
    var listener = bound.listener;
    defer listener.deinit(sio);

    var ctx = Ctx{ .reply_body = "{\"code\":534,\"desc\":\"Table does not exist\"}" };
    var server = http_server.Server{ .gpa = a, .io = sio, .ctx = @ptrCast(&ctx), .handler = Ctx.handle };
    var lctx = Listener{ .server = &server, .listener = &listener, .io = sio, .count = 1 };
    const th = try std.Thread.spawn(.{}, Listener.run, .{&lctx});

    var conn = try tdengine.Conn.open(a, .{ .host = "127.0.0.1", .port = bound.port });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    try std.testing.expectError(error.Server, conn.queryAlloc(arena.allocator(), "SELECT * FROM nope", &.{}));
    th.join();
    try std.testing.expect(std.mem.indexOf(u8, conn.lastError(), "Table does not exist") != null);
}

test "InfluxDB 端到端：v2 写入走 /api/v2/write（Token + Line Protocol）" {
    const a = std.testing.allocator;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    const bound = listenAny(sio, 39361) orelse return;
    var listener = bound.listener;
    defer listener.deinit(sio);

    var ctx = Ctx{ .status = .no_content };
    var server = http_server.Server{ .gpa = a, .io = sio, .ctx = @ptrCast(&ctx), .handler = Ctx.handle };
    var lctx = Listener{ .server = &server, .listener = &listener, .io = sio, .count = 1 };
    const th = try std.Thread.spawn(.{}, Listener.run, .{&lctx});

    var conn = try influxdb.Conn.open(a, .{
        .host = "127.0.0.1",
        .port = bound.port,
        .token = "my-token",
        .org = "my-org",
        .bucket = "my-bucket",
    });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try conn.write(arena.allocator(), "weather,city=beijing temperature=21.5");
    th.join();

    try std.testing.expectEqual(std.http.Method.POST, ctx.method);
    try std.testing.expectEqualStrings("/api/v2/write", ctx.pathText());
    try std.testing.expect(std.mem.indexOf(u8, ctx.queryText(), "bucket=my-bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.queryText(), "precision=ns") != null);
    try std.testing.expectEqualStrings("Token my-token", ctx.authText());
    try std.testing.expectEqualStrings("weather,city=beijing temperature=21.5", ctx.bodyText());
}

test "InfluxDB 端到端：v1 InfluxQL 走 GET /query 并解析 JSON" {
    const a = std.testing.allocator;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    const bound = listenAny(sio, 39391) orelse return;
    var listener = bound.listener;
    defer listener.deinit(sio);

    var ctx = Ctx{
        .reply_body =
        \\{"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["time","value"],
        \\"values":[["2024-01-01T00:00:00Z",0.5]]}]}]}
        ,
    };
    var server = http_server.Server{ .gpa = a, .io = sio, .ctx = @ptrCast(&ctx), .handler = Ctx.handle };
    var lctx = Listener{ .server = &server, .listener = &listener, .io = sio, .count = 1 };
    const th = try std.Thread.spawn(.{}, Listener.run, .{&lctx});

    var conn = try influxdb.Conn.open(a, .{ .host = "127.0.0.1", .port = bound.port, .database = "mydb" });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const r = try conn.queryAlloc(arena.allocator(), "SELECT value FROM cpu", &.{});
    th.join();

    try std.testing.expectEqual(std.http.Method.GET, ctx.method);
    try std.testing.expectEqualStrings("/query", ctx.pathText());
    try std.testing.expect(std.mem.indexOf(u8, ctx.queryText(), "db=mydb") != null);
    // 查询串里的空格被编码成 %20（不是 +）
    try std.testing.expect(std.mem.indexOf(u8, ctx.queryText(), "q=SELECT%20value%20FROM%20cpu") != null);

    try std.testing.expectEqual(@as(usize, 1), r.rows.rows.len);
    try std.testing.expectEqual(@as(f64, 0.5), r.rows.rows[0].values[1].asF64().?);
}

test "ClickHouse 端到端：POST /?database=&default_format=JSONCompact + 头鉴权" {
    const a = std.testing.allocator;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    const bound = listenAny(sio, 39421) orelse return;
    var listener = bound.listener;
    defer listener.deinit(sio);

    var ctx = Ctx{
        .reply_body =
        \\{"meta":[{"name":"n","type":"UInt64"},{"name":"name","type":"String"}],
        \\"data":[["3","天气"]],"rows":1}
        ,
    };
    var server = http_server.Server{ .gpa = a, .io = sio, .ctx = @ptrCast(&ctx), .handler = Ctx.handle };
    var lctx = Listener{ .server = &server, .listener = &listener, .io = sio, .count = 1 };
    const th = try std.Thread.spawn(.{}, Listener.run, .{&lctx});

    var conn = try clickhouse.Conn.open(a, .{
        .host = "127.0.0.1",
        .port = bound.port,
        .user = "default",
        .password = "s3cret",
        .database = "mydb",
    });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const r = try conn.queryAlloc(arena.allocator(), "SELECT count() AS n, name FROM t WHERE id = ?", &.{.{ .int = 7 }});
    th.join();

    // 请求侧：路径 + 查询串 + 头 + body（参数已内联）
    try std.testing.expectEqual(std.http.Method.POST, ctx.method);
    try std.testing.expectEqualStrings("/", ctx.pathText());
    try std.testing.expect(std.mem.indexOf(u8, ctx.queryText(), "database=mydb") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.queryText(), "default_format=JSONCompact") != null);
    try std.testing.expectEqualStrings("default", ctx.ch_user[0..ctx.ch_user_len]);
    try std.testing.expectEqualStrings("s3cret", ctx.ch_key[0..ctx.ch_key_len]);
    try std.testing.expectEqualStrings("SELECT count() AS n, name FROM t WHERE id = 7", ctx.bodyText());

    // 响应侧：UInt64 用字符串回 → 还原成整数
    try std.testing.expectEqual(@as(usize, 1), r.rows.rows.len);
    try std.testing.expectEqual(@as(i64, 3), r.rows.rows[0].values[0].asI64().?);
    try std.testing.expectEqualStrings("天气", r.rows.rows[0].values[1].asText().?);
    try std.testing.expectEqualStrings("n", r.rows.rows[0].names[0]);
}

test "ClickHouse 端到端：400 响应带 DB::Exception 文本 → error.HttpFailed + 原因" {
    const a = std.testing.allocator;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    const bound = listenAny(sio, 39451) orelse return;
    var listener = bound.listener;
    defer listener.deinit(sio);

    var ctx = Ctx{
        .status = .bad_request,
        .reply_body = "Code: 62. DB::Exception: Syntax error: failed at position 1",
    };
    var server = http_server.Server{ .gpa = a, .io = sio, .ctx = @ptrCast(&ctx), .handler = Ctx.handle };
    var lctx = Listener{ .server = &server, .listener = &listener, .io = sio, .count = 1 };
    const th = try std.Thread.spawn(.{}, Listener.run, .{&lctx});

    var conn = try clickhouse.Conn.open(a, .{ .host = "127.0.0.1", .port = bound.port });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    try std.testing.expectError(clickhouse.Error.HttpFailed, conn.queryAlloc(arena.allocator(), "SELEC 1", &.{}));
    th.join();
    try std.testing.expect(std.mem.indexOf(u8, conn.lastError(), "DB::Exception") != null);
}
