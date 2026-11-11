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
    /// LOCAL INFILE 用例：期望收到的数据（客户端流式发送的内容）
    expect_data: []const u8 = "",
    /// LOCAL INFILE 用例：实际收到多少字节
    got_len: usize = 0,
    /// LOCAL INFILE 用例：实际内容是否逐字节一致
    data_matched: bool = false,

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
    try writePacket(stream, io, 2, buildColumnDef(&def_buf, "id", @backingInt(mysql.ColumnType.long)));
    try writePacket(stream, io, 3, buildColumnDef(&def_buf, "name", @backingInt(mysql.ColumnType.var_string)));
    // 列定义结束
    try writePacket(stream, io, 4, &[_]u8{ 0xfe, 0x00, 0x00, 0x02, 0x00 });
    // 一行：id=7，name='abc'
    try writePacket(stream, io, 5, &[_]u8{ 0x01, '7', 0x03, 'a', 'b', 'c' });
    // 行结束（status = 2，无更多结果集）
    try writePacket(stream, io, 6, &[_]u8{ 0xfe, 0x00, 0x00, 0x02, 0x00 });
}

fn buildHandshake(out: []u8) []u8 {
    return buildHandshakeWithPlugin(out, "mysql_native_password");
}

fn buildHandshakeWithPlugin(out: []u8, plugin: []const u8) []u8 {
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
    std.mem.writeInt(u16, out[i..][0..2], @truncate(mysql_caps_high() >> 16), .little);
    i += 2;
    out[i] = 21; // auth data len
    i += 1;
    @memset(out[i..][0..10], 0);
    i += 10;
    @memcpy(out[i..][0..12], salt[8..20]);
    i += 12;
    out[i] = 0;
    i += 1;
    @memcpy(out[i..][0..plugin.len], plugin);
    i += plugin.len;
    out[i] = 0;
    i += 1;
    return out[0..i];
}

fn mysql_caps_low() u32 {
    // 0x80 = CLIENT_LOCAL_FILES：LOCAL INFILE 用例要求服务端声明它，否则客户端会按规矩裁掉该位
    return 0x0000_0001 | 0x0000_0004 | 0x0000_0080 | 0x0000_0200 | 0x0000_2000 | 0x0000_8000;
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

// ── LOAD DATA LOCAL INFILE（客户端流式发送数据，不落盘） ─────────────────────

fn serverMainLocalInfile(ctx: *ServerCtx) void {
    runServerLocalInfile(ctx) catch |e| {
        if (ctx.err_len == 0) ctx.fail("假服务端（LOCAL INFILE）异常：{s}", .{@errorName(e)});
        return;
    };
    ctx.ok = true;
}

fn runServerLocalInfile(ctx: *ServerCtx) !void {
    var stream = try ctx.server.accept(ctx.io);
    defer stream.close(ctx.io);
    const io = ctx.io;

    var hs_buf: [128]u8 = @splat(0);
    try writePacket(stream, io, 0, buildHandshake(&hs_buf));

    var in_buf: [4096]u8 = undefined;
    const resp = try readPacket(stream, io, &in_buf);
    // capability 低 4 字节（小端）：必须带 CLIENT_LOCAL_FILES(0x80)
    const caps = std.mem.readInt(u32, resp[0..4], .little);
    if ((caps & 0x0080) == 0) {
        ctx.fail("客户端未声明 CLIENT_LOCAL_FILES（capability=0x{x}）", .{caps});
        return error.Protocol;
    }
    try writePacket(stream, io, 2, &[_]u8{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 });

    while (true) {
        const cmd = try readPacket(stream, io, &in_buf);
        if (cmd.len == 0) return;
        switch (cmd[0]) {
            0x01 => return, // COM_QUIT
            0x03 => {
                const sql = cmd[1..];
                if (!std.mem.startsWith(u8, sql, "LOAD DATA LOCAL INFILE")) {
                    ctx.fail("未预期 SQL：{s}", .{sql});
                    return error.Protocol;
                }
                // 0xfb + 文件名\0（文件名只用于服务端日志）
                var req: [32]u8 = @splat(0);
                req[0] = 0xfb;
                const name = "zcode_bulk.tsv";
                @memcpy(req[1 .. 1 + name.len], name);
                try writePacket(stream, io, 1, req[0 .. 1 + name.len + 1]);

                // 收数据包直到空包；seq 由 2 起递增
                var seq: u8 = 2;
                var total: usize = 0;
                var matched = true;
                while (true) {
                    const chunk = try readPacket(stream, io, &in_buf);
                    if (chunk.len == 0) break;
                    const end = total + chunk.len;
                    if (end <= ctx.expect_data.len) {
                        if (!std.mem.eql(u8, ctx.expect_data[total..end], chunk)) matched = false;
                    } else matched = false;
                    total = end;
                    seq +%= 1;
                }
                ctx.got_len = total;
                ctx.data_matched = matched and total == ctx.expect_data.len;
                // OK：affected_rows=3 / insert_id=0 / status=2 / warnings=0
                try writePacket(stream, io, seq, &[_]u8{ 0x00, 0x03, 0x00, 0x02, 0x00, 0x00, 0x00 });
            },
            else => {
                ctx.fail("未预期命令字节 0x{x}", .{cmd[0]});
                return error.Protocol;
            },
        }
    }
}

test "MySQL 端到端（回环假服务端）：LOAD DATA LOCAL INFILE 流式装载" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39141;
    var server: ?std.Io.net.Server = null;
    while (port < 39160) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        server = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    if (server == null) {
        std.debug.print("[SKIP] 39141-39159 端口均不可用，跳过 LOCAL INFILE 用例\n", .{});
        return;
    }

    const payload = "1\talpha\n2\tbeta\n3\t\\N\n"; // 含 NULL 的 TSV
    var ctx = ServerCtx{ .server = server.?, .io = sio, .expect_data = payload };
    defer ctx.server.deinit(sio);
    const th = try std.Thread.spawn(.{}, serverMainLocalInfile, .{&ctx});

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

        const sql = "LOAD DATA LOCAL INFILE 'zcode_bulk.tsv' INTO TABLE `t` FIELDS TERMINATED BY '\\t' " ++
            "ESCAPED BY '\\\\' LINES TERMINATED BY '\\n' (`id`,`name`)";
        const affected = try conn.loadDataLocal(sql, payload);
        try std.testing.expectEqual(@as(u64, 3), affected);
    }

    th.join();
    if (!ctx.ok) {
        std.debug.print("[FAIL] 假服务端断言失败：{s}\n", .{ctx.errText()});
        return error.FakeServerAssertion;
    }
    try std.testing.expectEqual(payload.len, ctx.got_len);
    try std.testing.expect(ctx.data_matched);
}

// ── caching_sha2_password 完整鉴权（RSA 公钥交换） ──────────────────────────

fn serverMainSha2(ctx: *ServerCtx) void {
    runServerSha2(ctx) catch |e| {
        if (ctx.err_len == 0) ctx.fail("假服务端（caching_sha2）异常：{s}", .{@errorName(e)});
        return;
    };
    ctx.ok = true;
}

fn runServerSha2(ctx: *ServerCtx) !void {
    var stream = try ctx.server.accept(ctx.io);
    defer stream.close(ctx.io);
    const io = ctx.io;

    var hs_buf: [256]u8 = @splat(0);
    try writePacket(stream, io, 0, buildHandshakeWithPlugin(&hs_buf, "caching_sha2_password"));

    var in_buf: [4096]u8 = undefined;
    const resp = try readPacket(stream, io, &in_buf);
    const auth_len_off = 32 + user.len + 1;
    if (resp.len <= auth_len_off) {
        ctx.fail("握手响应过短：{d}", .{resp.len});
        return error.Protocol;
    }
    if (resp[auth_len_off] != 32) {
        ctx.fail("caching_sha2 初始摘要应为 32 字节，实际 {d}", .{resp[auth_len_off]});
        return error.Protocol;
    }
    const got = resp[auth_len_off + 1 ..][0..32];
    const want = mysql.cachingSha2Scramble(password, salt);
    if (!std.mem.eql(u8, got, &want)) {
        ctx.fail("caching_sha2 摘要与算法重算结果不一致", .{});
        return error.AuthFailed;
    }

    // 要求完整鉴权：AuthMoreData 0x01 0x04
    try writePacket(stream, io, 2, &[_]u8{ 0x01, 0x04 });

    const req = try readPacket(stream, io, &in_buf);
    if (req.len != 1 or req[0] != 0x02) {
        ctx.fail("客户端未请求公钥（首字节 0x{x}）", .{if (req.len > 0) req[0] else 0});
        return error.Protocol;
    }

    // 返回 PEM 公钥（48 字节模长，够放 OAEP 填充）
    var der_buf: [256]u8 = @splat(0);
    const der = buildRsaPublicKeyDer(&der_buf);
    var pem_buf: [512]u8 = @splat(0);
    const pem = buildPublicKeyPem(&pem_buf, der);

    var key_pkt: [640]u8 = undefined;
    key_pkt[0] = 0x01;
    @memcpy(key_pkt[1..][0..pem.len], pem);
    try writePacket(stream, io, 4, key_pkt[0 .. 1 + pem.len]);

    // 收 RSA 密文：长度必须等于模长，且不能全 0（全 0 说明 OAEP/模幂没跑）
    const cipher = try readPacket(stream, io, &in_buf);
    if (cipher.len != 48) {
        ctx.fail("RSA 密文长度应为 48，实际 {d}", .{cipher.len});
        return error.Protocol;
    }
    var all_zero = true;
    for (cipher) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        ctx.fail("RSA 密文全 0，加密未生效", .{});
        return error.Protocol;
    }

    try writePacket(stream, io, 6, &[_]u8{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 });

    while (true) {
        const cmd = try readPacket(stream, io, &in_buf);
        if (cmd.len == 0) return;
        switch (cmd[0]) {
            0x01 => return,
            0x0e => try writePacket(stream, io, 1, &[_]u8{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }),
            else => {
                ctx.fail("未预期命令字节 0x{x}", .{cmd[0]});
                return error.Protocol;
            },
        }
    }
}

fn buildRsaPublicKeyDer(out: []u8) []u8 {
    var n_bytes: [48]u8 = undefined;
    for (&n_bytes, 0..) |*b, i| b.* = @intCast((i * 11 + 5) & 0xff);
    n_bytes[0] = 0xd3;
    const e_bytes = [_]u8{ 0x01, 0x00, 0x01 };
    const oid = [_]u8{ 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

    // RSAPublicKey ::= SEQUENCE { n INTEGER, e INTEGER }
    var ints: [128]u8 = undefined;
    var r: usize = 0;
    ints[r] = 0x02;
    r += 1;
    ints[r] = n_bytes.len;
    r += 1;
    @memcpy(ints[r..][0..n_bytes.len], &n_bytes);
    r += n_bytes.len;
    ints[r] = 0x02;
    r += 1;
    ints[r] = e_bytes.len;
    r += 1;
    @memcpy(ints[r..][0..e_bytes.len], &e_bytes);
    r += e_bytes.len;

    // 外层 SEQUENCE（漏了这层会让 BIT STRING 里直接出现 0x02，解析必然失败）
    var rsa: [130]u8 = undefined;
    rsa[0] = 0x30;
    rsa[1] = @intCast(r);
    @memcpy(rsa[2..][0..r], ints[0..r]);
    const rsa_len = 2 + r;

    // SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }
    var inner: [256]u8 = undefined;
    var k: usize = 0;
    inner[k] = 0x30;
    k += 1;
    inner[k] = @intCast(oid.len + 2);
    k += 1;
    @memcpy(inner[k..][0..oid.len], &oid);
    k += oid.len;
    inner[k] = 0x05; // NULL
    k += 1;
    inner[k] = 0x00;
    k += 1;
    inner[k] = 0x03; // BIT STRING
    k += 1;
    inner[k] = @intCast(1 + rsa_len);
    k += 1;
    inner[k] = 0x00; // unused bits
    k += 1;
    @memcpy(inner[k..][0..rsa_len], rsa[0..rsa_len]);
    k += rsa_len;

    var i: usize = 0;
    out[i] = 0x30;
    i += 1;
    out[i] = @intCast(k);
    i += 1;
    @memcpy(out[i..][0..k], inner[0..k]);
    i += k;
    return out[0..i];
}

fn buildPublicKeyPem(out: []u8, der: []const u8) []u8 {
    const enc = std.base64.standard.Encoder;
    var b64: [256]u8 = undefined;
    const b64_len = enc.calcSize(der.len);
    const b64_slice = enc.encode(b64[0..b64_len], der);

    var i: usize = 0;
    const head = "-----BEGIN PUBLIC KEY-----\n";
    @memcpy(out[i..][0..head.len], head);
    i += head.len;

    var pos: usize = 0;
    while (pos < b64_slice.len) {
        const n = @min(64, b64_slice.len - pos);
        @memcpy(out[i..][0..n], b64_slice[pos..][0..n]);
        i += n;
        out[i] = '\n';
        i += 1;
        pos += n;
    }

    const tail = "-----END PUBLIC KEY-----\n";
    @memcpy(out[i..][0..tail.len], tail);
    i += tail.len;
    return out[0..i];
}

test "回环固件：假服务端 RSA 公钥（DER/PEM）可被驱动解析" {
    const rsa = @import("../crypto/rsa.zig");
    var der_buf: [256]u8 = @splat(0);
    const der = buildRsaPublicKeyDer(&der_buf);
    var pem_buf: [512]u8 = @splat(0);
    const pem = buildPublicKeyPem(&pem_buf, der);

    // 先直接解析 DER：定位是 DER 拼装错，还是 PEM/base64 环节错
    var k_der = rsa.parsePublicKeyDer(std.testing.allocator, der) catch |e| {
        std.debug.print("[DIAG] der parse failed {s}: len={d} hex={s}\n", .{ @errorName(e), der.len, std.fmt.bytesToHex(der[0..40], .lower) });
        return e;
    };
    k_der.deinit();

    var key = try rsa.parsePublicKey(std.testing.allocator, pem);
    defer key.deinit();
    try std.testing.expectEqual(@as(usize, 48), key.size);
}

test "MySQL 端到端（回环假服务端）：caching_sha2 完整鉴权（RSA 公钥交换）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39130;
    var server: ?std.Io.net.Server = null;
    while (port < 39150) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        server = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    if (server == null) {
        std.debug.print("[SKIP] 39130-39149 端口均不可用，跳过 caching_sha2 回环用例\n", .{});
        return;
    }

    var ctx = ServerCtx{ .server = server.?, .io = sio };
    defer ctx.server.deinit(sio);
    const th = try std.Thread.spawn(.{}, serverMainSha2, .{&ctx});

    {
        var conn = mysql.Conn.open(std.testing.allocator, .{
            .host = "127.0.0.1",
            .port = port,
            .user = user,
            .password = password,
        }) catch |e| {
            th.join();
            std.debug.print("[FAIL] caching_sha2 完整鉴权连接失败：{s}；服务端信息：{s}\n", .{ @errorName(e), ctx.errText() });
            return e;
        };
        defer conn.deinit();
        try conn.ping();
    }

    th.join();
    if (!ctx.ok) {
        std.debug.print("[FAIL] 假服务端（caching_sha2）断言失败：{s}\n", .{ctx.errText()});
        return error.FakeServerAssertion;
    }
}
