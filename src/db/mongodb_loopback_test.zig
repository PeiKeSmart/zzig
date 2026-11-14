//! MongoDB 驱动的**回环端到端**用例：起一个「脚本化假服务端」，按 OP_MSG 收发。
//!
//! 覆盖的是**线协议**：16 字节消息头、OP_MSG 的 flagBits + kind 0 段、
//! 命令文档（`hello` / `insert` / `find` 与 `$db`）、响应解析（`ok` / `n` / `cursor.firstBatch`）。
//! 鉴权算法本身由 `mongodb.zig` 里的 RFC 7677 向量单测守住（不需要服务端参与）。

const std = @import("std");
const compat = @import("../compat.zig");
const bson = @import("bson.zig");
const mongodb = @import("mongodb.zig");

const op_msg: i32 = 2013;

const Ctx = struct {
    io: std.Io,
    listener: *std.Io.net.Server,
    /// 要处理多少个请求（每个请求一条消息）
    count: usize,
    /// 收到的命令名（第一个字段名），按顺序记录
    names: [8][32]u8 = undefined,
    name_lens: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    /// 收到的 `$db` 值
    db: [32]u8 = undefined,
    db_len: usize = 0,
    /// 收到的 insert 文档数
    docs_seen: usize = 0,
    requests: usize = 0,
    fail: [256]u8 = undefined,
    fail_len: usize = 0,

    fn failMsg(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.fail, fmt, args) catch "假服务端失败";
        self.fail_len = text.len;
    }

    fn failText(self: *Ctx) []const u8 {
        return self.fail[0..self.fail_len];
    }
};

fn readExact(ctx: *Ctx, stream: std.Io.net.Stream, dst: []u8) !void {
    var got: usize = 0;
    while (got < dst.len) {
        var slices = [_][]u8{dst[got..]};
        const r = try ctx.io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &slices } });
        const res = try r.net_read;
        if (res.data_len == 0) return error.EndOfStream;
        got += res.data_len;
    }
}

fn writeAll(ctx: *Ctx, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const r = try ctx.io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &.{bytes[sent..]} } });
        const n = try r.net_write;
        if (n == 0) return error.BrokenPipe;
        sent += n;
    }
}

fn runServer(ctx: *Ctx) void {
    serve(ctx) catch |e| {
        if (ctx.fail_len == 0) ctx.failMsg("假服务端异常：{s}", .{@errorName(e)});
    };
}

fn serve(ctx: *Ctx) !void {
    const stream = try ctx.listener.accept(ctx.io);
    defer stream.close(ctx.io);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    for (0..ctx.count) |_| {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();

        var hdr: [16]u8 = undefined;
        try readExact(ctx, stream, &hdr);
        const len = std.mem.readInt(i32, hdr[0..4], .little);
        const rid = std.mem.readInt(i32, hdr[4..8], .little);
        const op = std.mem.readInt(i32, hdr[12..16], .little);
        if (op != op_msg) {
            ctx.failMsg("请求操作码 {d} 不是 OP_MSG", .{op});
            return error.BadOpcode;
        }
        const body = try a.alloc(u8, @intCast(len - 16));
        try readExact(ctx, stream, body);

        // 跳过 flagBits(4)，kind 必须是 0
        if (body[4] != 0x00) {
            ctx.failMsg("请求段类型 {d} 不是 kind 0", .{body[4]});
            return error.BadSection;
        }
        const cmd = try bson.parseAlloc(a, body[5..]);

        // 记录命令名与 $db
        if (cmd.len > 0 and ctx.requests < ctx.names.len) {
            const name = cmd[0].name;
            const n = @min(name.len, ctx.names[0].len);
            @memcpy(ctx.names[ctx.requests][0..n], name[0..n]);
            ctx.name_lens[ctx.requests] = n;
        }
        if (bson.getStr(cmd, "$db")) |db| {
            const n = @min(db.len, ctx.db.len);
            @memcpy(ctx.db[0..n], db[0..n]);
            ctx.db_len = n;
        }
        if (bson.getArray(cmd, "documents")) |docs| ctx.docs_seen = docs.len;
        ctx.requests += 1;

        // 按命令名回响应
        const reply_fields: []const bson.Field = if (std.mem.eql(u8, cmd[0].name, "hello"))
            &[_]bson.Field{
                .{ .name = "ok", .value = .{ .double = 1.0 } },
                .{ .name = "maxWireVersion", .value = .{ .int32 = 17 } },
                .{ .name = "version", .value = .{ .string = "7.0.0" } },
            }
        else if (std.mem.eql(u8, cmd[0].name, "insert"))
            &[_]bson.Field{
                .{ .name = "ok", .value = .{ .double = 1.0 } },
                .{ .name = "n", .value = .{ .int32 = 1 } },
            }
        else
            &[_]bson.Field{
                .{ .name = "ok", .value = .{ .double = 1.0 } },
                .{ .name = "cursor", .value = .{ .doc = &[_]bson.Field{
                    .{ .name = "id", .value = .{ .int64 = 0 } },
                    .{ .name = "ns", .value = .{ .string = "t.users" } },
                    .{ .name = "firstBatch", .value = .{ .array = &[_]bson.Value{
                        .{ .doc = &[_]bson.Field{
                            .{ .name = "name", .value = .{ .string = "甲" } },
                            .{ .name = "age", .value = .{ .int32 = 30 } },
                        } },
                    } } },
                } } },
            };

        const doc = try bson.encodeAlloc(a, reply_fields);
        const total: usize = 16 + 4 + 1 + doc.len;
        const msg = try a.alloc(u8, total);
        std.mem.writeInt(i32, msg[0..4], @intCast(total), .little);
        std.mem.writeInt(i32, msg[4..8], 900 + @as(i32, @intCast(ctx.requests)), .little);
        std.mem.writeInt(i32, msg[8..12], rid, .little);
        std.mem.writeInt(i32, msg[12..16], op_msg, .little);
        std.mem.writeInt(u32, msg[16..20], 0, .little);
        msg[20] = 0x00;
        @memcpy(msg[21..], doc);
        try writeAll(ctx, stream, msg);
    }
}

test "MongoDB 端到端（回环假服务端）：hello 握手 + insert + find" {
    const a = std.testing.allocator;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    // 找一个能绑的端口（全占则显式 SKIP）
    var port: u16 = 39501;
    var bound: ?std.Io.net.Server = null;
    while (port < 39520) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    var listener = bound orelse {
        std.debug.print("[SKIP] 39501-39519 端口均不可用，跳过 MongoDB 回环用例\n", .{});
        return;
    };
    defer listener.deinit(sio);

    var ctx = Ctx{ .io = sio, .listener = &listener, .count = 3 };
    const th = try std.Thread.spawn(.{}, runServer, .{&ctx});

    var conn = mongodb.Conn.open(a, .{
        .host = "127.0.0.1",
        .port = port,
        .database = "t",
    }) catch |e| {
        th.join();
        std.debug.print("[FAIL] 连接假服务端失败：{s}；服务端：{s}\n", .{ @errorName(e), ctx.failText() });
        return e;
    };
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const docs = [_][]const bson.Field{
        &[_]bson.Field{
            .{ .name = "name", .value = .{ .string = "甲" } },
            .{ .name = "age", .value = .{ .int32 = 30 } },
        },
    };
    const n = try conn.insert(ar, "users", &docs);
    try std.testing.expectEqual(@as(u64, 1), n);

    const rows = try conn.findAlloc(ar, "users", &.{}, 10, 10);
    th.join();

    try std.testing.expectEqualStrings("", ctx.failText());
    try std.testing.expectEqual(@as(usize, 3), ctx.requests);
    // 命令顺序：hello → insert → find
    try std.testing.expectEqualStrings("hello", ctx.names[0][0..ctx.name_lens[0]]);
    try std.testing.expectEqualStrings("insert", ctx.names[1][0..ctx.name_lens[1]]);
    try std.testing.expectEqualStrings("find", ctx.names[2][0..ctx.name_lens[2]]);
    // `$db` 取的是连接上的库
    try std.testing.expectEqualStrings("t", ctx.db[0..ctx.db_len]);
    // insert 带了 1 份文档
    try std.testing.expectEqual(@as(usize, 1), ctx.docs_seen);

    // find 的响应被解析成一行（列名取文档字段）
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("甲", rows[0].get("name").?.asText().?);
    try std.testing.expectEqual(@as(i64, 30), rows[0].get("age").?.asI64().?);

    // 握手把服务端版本记下来了
    try std.testing.expectEqualStrings("7.0.0", conn.serverVersion());
}
