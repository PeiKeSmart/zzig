//! MySQL 驱动的**回环端到端**用例：起一个「脚本化假服务端」，让真实客户端走完整协议。
//!
//! 为什么不用真库：本机/CI 不一定有 MySQL。这里覆盖的是**客户端状态机**——
//! 包分帧与序列号、握手解析、`mysql_native_password` 摘要按字节比对、OK 包、
//! `COM_QUERY` 请求 → 结果集（列定义 + 行 + EOF）解析、`COM_PING`、`COM_QUIT`。
//! SQL 语义（建表/类型映射）由真库验证，不在本文件范围内。

const std = @import("std");
const compat = @import("../compat.zig");
const mysql = @import("mysql.zig");

const salt = "12345678abcdefghijkl"; // 20 字节 scramble
const user = "root";
const password = "secret";

const error_port_unavailable = error.PortUnavailable;

const ServerCtx = struct {
    server: std.Io.net.Server,
    io: std.Io,
    ok: bool = false,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,

    fn fail(self: *ServerCtx, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch "假服务端失败";
        self.err_len = text.len;
    }

    fn errText(self: *const ServerCtx) []const u8 {
        return self.err_buf[0..self.err_len];
    }
};

fn serverMain(ctx: *ServerCtx) void {
    runServer(ctx) catch |e| {
        if (ctx.err_len == 0) ctx.fail("假服务端异常：{s}", .{@errorName(e)});
        return;
    };
    ctx.ok = true;
}

fn runServer(ctx: *ServerCtx) !void {
    var stream = try ctx.server.accept(ctx.io);
    defer stream.close(ctx.io);
    const io = ctx.io;

    // 1. 握手（seq 0）
    var hs_buf: [128]u8 = @splat(0);
    const hs = buildHandshake(&hs_buf);
    try writePacket(stream, io, 0, hs);

    // 2. 客户端 HandshakeResponse（seq 1）
    var in_buf: [2048]u8 = undefined;
    const resp = try readPacket(stream, io, &in_buf);

    // 固定头部 32 字节 + 用户名 + \0 + 授权长度 + 授权数据
    const user_off = 32;
    if (resp.len < user_off + user.len + 1) {
        ctx.fail("握手响应过短：{d} 字节", .{resp.len});
        return error.Protocol;
    }
    const got_user = std.mem.sliceTo(resp[user_off..], 0);
    if (!std.mem.eql(u8, got_user, user)) {
        ctx.fail("用户名不符：期望 {s} 实际 {s}", .{ user, got_user });
        return error.Protocol;
    }
    const auth_len_off = user_off + user.len + 1;
    if (resp[auth_len_off] != 20) {
        ctx.fail("授权摘要长度应为 20，实际 {d}", .{resp[auth_len_off]});
        return error.Protocol;
    }
    const got_auth = resp[auth_len_off + 1 ..][0..20];
    const want_auth = mysql.nativePasswordScramble(password, salt);
    if (!std.mem.eql(u8, got_auth, &want_auth)) {
        ctx.fail("授权摘要与服务端算法不一致（客户端加盐散列有问题）", .{});
        return error.AuthFailed;
    }

    // 3. OK（seq 2）
    try writePacket(stream, io, 2, &[_]u8{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 });

    // 4. 命令循环
    while (true) {
        const cmd = try readPacket(stream, io, &in_buf);
        if (cmd.len == 0) return;
        switch (cmd[0]) {
            0x01 => return, // COM_QUIT
            0x0e => try writePacket(stream, io, 1, &[_]u8{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }), // COM_PING
            0x03 => {
                // COM_QUERY：返回两列一行的结果集
                const sql = cmd[1..];
                if (!std.mem.startsWith(u8, sql, "SELECT")) {
                    ctx.fail("未预期的 SQL：{s}", .{sql});
                    return error.Protocol;
                }
                try sendResultSet(stream, io);
            },
            else => {
                ctx.fail("未预期命令字节 0x{x}", .{cmd[0]});
                return error.Protocol;
            },
        }
    }
}

fn sendResultSet(stream: std.Io.net.Stream, io: std.Io) !void {
    // 列数
    try writePacket(stream, io, 1, &[_]u8{0x02});
    // 列定义：id LONG / name VAR_STRING
    var def_buf: [96]u8 = undefined;
    try writePacket(stream, io, 2, buildColumnDef(&def_buf, "id", @intFromEnum(mysql.ColumnType.long)));
    try writePacket(stream, io, 3, buildColumnDef(&def_buf, "name", @intFromEnum(mysql.ColumnType.var_string)));
    // 列定义结束
    try writePacket(stream, io, 4, &[_]u8{ 0xfe, 0x00, 0x00, 0x02, 0x00 });
    // 一行：id=7，name='abc'
    try writePacket(stream, io, 5, &[_]u8{ 0x01, '7', 0x03, 'a', 'b', 'c' });
    // 行结束（status = 2，无更多结果集）
    try writePacket(stream, io, 6, &[_]u8{ 0xfe, 0x00, 0x00, 0x02, 0x00 });
}

fn buildHandshake(out: []u8) []u8 {
    var i: usize = 0;
    out[i] = 10;
    i += 1;
    const ver = "8.0.36-zcode";
    @memcpy(out[i..][0..ver.len], ver);
    i += ver.len;
    out[i] = 0;
    i += 1;
    std.mem.writeInt(u32, out[i..][0..4], 99, .little); // thread id
    i += 4;
    @memcpy(out[i..][0..8], salt[0..8]);
    i += 8;
    out[i] = 0;
    i += 1;

    const cap_low: u16 = @truncate(mysql_caps_low());
    std.mem.writeInt(u16, out[i..][0..2], cap_low, .little);
    i += 2;
    out[i] = 45; // utf8mb4_general_ci
    i += 1;
    std.mem.writeInt(u16, out[i..][0..2], 2, .little); // status
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], @truncate(mysql_caps_high()), .little);
    i += 2;
    out[i] = 21; // auth data len
    i += 1;
    @memset(out[i..][0..10], 0);
    i += 10;
    @memcpy(out[i..][0..12], salt[8..20]);
    i += 12;
    out[i] = 0;
    i += 1;
    const plugin = "mysql_native_password";
    @memcpy(out[i..][0..plugin.len], plugin);
    i += plugin.len;
    out[i] = 0;
    i += 1;
    return out[0..i];
}

fn mysql_caps_low() u32 {
    return 0x0000_0001 | 0x0000_0004 | 0x0000_0200 | 0x0000_2000 | 0x0000_8000;
}

fn mysql_caps_high() u32 {
    return 0x0008_0000; // CLIENT_PLUGIN_AUTH >> 16 = 0x0008
}

fn buildColumnDef(out: []u8, name: []const u8, ty: u8) []u8 {
    var i: usize = 0;
    const parts = [_][]const u8{ "def", "zcode", "t", "t", name, name };
    for (parts) |p| {
        out[i] = @intCast(p.len);
        i += 1;
        @memcpy(out[i..][0..p.len], p);
        i += p.len;
    }
    out[i] = 0x0c;
    i += 1;
    std.mem.writeInt(u16, out[i..][0..2], 45, .little); // charset
    i += 2;
    std.mem.writeInt(u32, out[i..][0..4], 255, .little); // display length
    i += 4;
    out[i] = ty;
    i += 1;
    std.mem.writeInt(u16, out[i..][0..2], 0, .little); // flags
    i += 2;
    out[i] = 0; // decimals
    i += 1;
    out[i] = 0;
    out[i + 1] = 0;
    i += 2;
    return out[0..i];
}

fn writePacket(stream: std.Io.net.Stream, io: std.Io, seq: u8, payload: []const u8) !void {
    var hdr: [4]u8 = undefined;
    hdr[0] = @intCast(payload.len & 0xff);
    hdr[1] = @intCast((payload.len >> 8) & 0xff);
    hdr[2] = @intCast((payload.len >> 16) & 0xff);
    hdr[3] = seq;
    try writeAll(stream, io, &hdr);
    if (payload.len > 0) try writeAll(stream, io, payload);
}

fn writeAll(stream: std.Io.net.Stream, io: std.Io, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const r = try io.operate(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &.{bytes[sent..]},
        } });
        const n = try r.net_write;
        if (n == 0) return error.ConnectionClosed;
        sent += n;
    }
}

fn readPacket(stream: std.Io.net.Stream, io: std.Io, buf: []u8) ![]u8 {
    var hdr: [4]u8 = undefined;
    try readExact(stream, io, &hdr);
    const len: usize = @as(usize, hdr[0]) | (@as(usize, hdr[1]) << 8) | (@as(usize, hdr[2]) << 16);
    if (len > buf.len) return error.Overflow;
    try readExact(stream, io, buf[0..len]);
    return buf[0..len];
}

fn readExact(stream: std.Io.net.Stream, io: std.Io, dst: []u8) !void {
    var got: usize = 0;
    while (got < dst.len) {
        // 不用 `Stream.read`：0.17 里它对 `net_read` 返回值做了不支持的解构
        var slices = [_][]u8{dst[got..]};
        const r = try io.operate(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &slices,
        } });
        const res = try r.net_read;
        if (res.data_len == 0) return error.ConnectionClosed;
        got += res.data_len;
    }
}

test "MySQL 端到端（回环假服务端）：握手/鉴权/COM_QUERY/结果集/PING/QUIT" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    // 端口从 39101 起找一个能绑的（本机可能被占，找不到就显式跳过，不静默通过）
    var port: u16 = 39101;
    var server: ?std.Io.net.Server = null;
    while (port < 39120) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        server = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    if (server == null) {
        std.debug.print("[SKIP] 39101-39119 端口均不可用，跳过 MySQL 回环用例\n", .{});
        return;
    }

    var ctx = ServerCtx{ .server = server.?, .io = sio };
    defer ctx.server.deinit(sio);
    const th = try std.Thread.spawn(.{}, serverMain, .{&ctx});

    {
        var conn = mysql.Conn.open(std.testing.allocator, .{
            .host = "127.0.0.1",
            .port = port,
            .user = user,
            .password = password,
        }) catch |e| {
            th.join();
            std.debug.print("[FAIL] 连接假服务端失败：{s}；服务端信息：{s}\n", .{ @errorName(e), ctx.errText() });
            return e;
        };
        defer conn.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const r = try conn.queryAlloc(arena.allocator(), "SELECT id, name FROM t", &.{});
        switch (r) {
            .rows => |rows| {
                try std.testing.expectEqual(@as(usize, 2), rows.columns.len);
                try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
                try std.testing.expectEqual(@as(i64, 7), rows.rows[0].get("id").?.int);
                try std.testing.expectEqualStrings("abc", rows.rows[0].get("name").?.text);
            },
            .ok => return error.ExpectedRows,
        }

        try conn.ping();
    }

    th.join();
    if (!ctx.ok) {
        std.debug.print("[FAIL] 假服务端断言失败：{s}\n", .{ctx.errText()});
        return error.FakeServerAssertion;
    }
}
