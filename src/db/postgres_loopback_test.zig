//! PostgreSQL 驱动的**回环端到端**用例：起一个「脚本化假服务端」，让真实客户端走完整协议。
//!
//! 为什么不用真库：本机不一定有 PostgreSQL。这里覆盖的是**客户端状态机**——
//! 启动握手、鉴权（Trust / MD5 / SCRAM-SHA-256 三种都跑）、简单查询与扩展查询的
//! 消息编排、RowDescription / DataRow 解析、CommandComplete 影响行数、参数文本编码。
//! SQL 语义（类型映射、DDL）由方言单测与真库验证覆盖，不在本文件范围。
//!
//! 假服务端是**确定性**的：同样的输入永远给同样的输出，因此断言可以写死具体值。

const std = @import("std");
const postgres = @import("postgres.zig");

const user = "zcode";
const password = "secret";
const database = "zcode_db";

const ServerCtx = struct {
    server: std.Io.net.Server,
    io: std.Io,
    /// 鉴权方式：0 = Trust，5 = MD5，10 = SCRAM-SHA-256
    auth_mode: u32 = 0,
    ok: bool = false,
    /// 客户端发来的最后一个 Bind 参数（文本），用于校验编码
    last_params: [4][64]u8 = undefined,
    last_param_lens: [4]usize = .{ 0, 0, 0, 0 },
    last_param_count: usize = 0,
    err_buf: [200]u8 = undefined,
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

// ── 假服务端实现 ────────────────────────────────────────────────────────────

fn runServer(ctx: *ServerCtx) !void {
    var stream = try ctx.server.accept(ctx.io);
    defer stream.close(ctx.io);
    const io = ctx.io;

    // 1) 启动消息：int32 长度 + int32 版本 + 键值对
    var head: [4]u8 = undefined;
    try readExact(stream, io, &head);
    const len = std.mem.readInt(u32, &head, .big);
    if (len < 8 or len > 4096) {
        ctx.fail("启动消息长度异常：{d}", .{len});
        return error.Protocol;
    }
    var body_buf: [4096]u8 = undefined;
    const body_len = len - 4;
    try readExact(stream, io, body_buf[0..body_len]);
    const proto = std.mem.readInt(u32, body_buf[0..4], .big);
    if (proto != 196608) {
        ctx.fail("协议版本不是 3.0：{d}", .{proto});
        return error.Protocol;
    }

    // 2) 鉴权
    switch (ctx.auth_mode) {
        0 => try writeAuthMsg(stream, io, &[_]u8{ 0, 0, 0, 0 }),
        5 => try authMd5(ctx, stream, io),
        10 => try authScram(ctx, stream, io),
        else => return error.Protocol,
    }

    // 3) ParameterStatus + BackendKeyData + ReadyForQuery
    try writeParamStatus(stream, io, "server_version", "16.2");
    try writeParamStatus(stream, io, "client_encoding", "UTF8");
    try writeMsg(stream, io, 'K', &[_]u8{ 0, 0, 0, 1, 0, 0, 0, 2 });
    try writeMsg(stream, io, 'Z', &[_]u8{'I'});

    // 4) 消息循环
    while (true) {
        var tag: [1]u8 = undefined;
        readExact(stream, io, &tag) catch return; // 客户端断开
        var len_buf: [4]u8 = undefined;
        try readExact(stream, io, &len_buf);
        const mlen = std.mem.readInt(u32, &len_buf, .big);
        if (mlen < 4 or mlen > 65536) {
            ctx.fail("消息长度异常：{d}", .{mlen});
            return error.Protocol;
        }
        var payload_buf: [65536]u8 = undefined;
        const plen: usize = mlen - 4;
        if (plen > 0) try readExact(stream, io, payload_buf[0..plen]);
        const payload = payload_buf[0..plen];

        switch (tag[0]) {
            'X' => return,
            'Q' => {
                const sql = std.mem.trimEnd(u8, payload, "\x00");
                try respondToQuery(ctx, stream, io, sql, false);
            },
            'P' => try writeMsg(stream, io, '1', &.{}), // ParseComplete
            'B' => {
                try captureBindParams(ctx, payload);
                try writeMsg(stream, io, '2', &.{}); // BindComplete
            },
            'D' => {
                // Describe：有结果集就回 RowDescription，否则 NoData
                if (ctx.last_param_count > 0) {
                    try writeRowDescription(stream, io);
                } else {
                    try writeMsg(stream, io, 'n', &.{});
                }
            },
            'E' => {
                // Execute：回两行数据（回显 bind 的参数），再 CommandComplete
                try writeDataRow2(stream, io, "1", ctx);
                try writeDataRow2(stream, io, "2", ctx);
                try writeCommandComplete(stream, io, "SELECT 2");
            },
            'S' => try writeMsg(stream, io, 'Z', &[_]u8{'I'}), // Sync → ReadyForQuery
            else => {
                ctx.fail("未预期的客户端消息类型：{c}（0x{x}）", .{ tag[0], tag[0] });
                return error.Protocol;
            },
        }
    }
}

fn respondToQuery(ctx: *ServerCtx, stream: std.Io.net.Stream, io: std.Io, sql: []const u8, extended: bool) !void {
    _ = ctx;
    _ = extended;
    const upper_start = sql.len;
    _ = upper_start;

    if (startsWithIgnoreCase(sql, "SELECT")) {
        try writeRowDescription(stream, io);
        try writeMsg(stream, io, 'D', &dataRowPayload2("7", "abc"));
        try writeCommandComplete(stream, io, "SELECT 1");
    } else if (startsWithIgnoreCase(sql, "UPDATE")) {
        try writeCommandComplete(stream, io, "UPDATE 3");
    } else if (startsWithIgnoreCase(sql, "INSERT")) {
        try writeCommandComplete(stream, io, "INSERT 0 1");
    } else {
        try writeCommandComplete(stream, io, "CREATE TABLE");
    }
    try writeMsg(stream, io, 'Z', &[_]u8{'I'});
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn payloadInt2(buf: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], v, .big);
}

fn payloadInt4(buf: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], v, .big);
}

fn writeRowDescription(stream: std.Io.net.Stream, io: std.Io) !void {
    var buf: [4][64]u8 = undefined;
    var fbs = FixedBuf.init(std.mem.asBytes(&buf));
    fbs.putI16(2);
    fbs.cstr("id");
    fbs.putI32(0); // 表 oid
    fbs.putI16(0); // 列号
    fbs.putI32(23); // int4
    fbs.putI16(4);
    fbs.putI32(-1);
    fbs.putI16(0);
    fbs.cstr("name");
    fbs.putI32(0);
    fbs.putI16(0);
    fbs.putI32(25); // text
    fbs.putI16(-1);
    fbs.putI32(-1);
    fbs.putI16(0);
    try writeMsg(stream, io, 'T', fbs.slice());
}

fn dataRowPayload2(id: []const u8, name: []const u8) [64]u8 {
    var buf: [64]u8 = @splat(0);
    payloadInt2(&buf, 0, 2);
    payloadInt4(&buf, 2, @intCast(id.len));
    @memcpy(buf[6 .. 6 + id.len], id);
    const p2 = 6 + id.len;
    payloadInt4(&buf, p2, @intCast(name.len));
    @memcpy(buf[p2 + 4 .. p2 + 4 + name.len], name);
    return buf;
}

fn writeDataRow2(stream: std.Io.net.Stream, io: std.Io, which: []const u8, ctx: *ServerCtx) !void {
    // 有参数时回显第一个参数，便于校验文本编码
    const first = if (ctx.last_param_count > 0) ctx.last_params[0][0..ctx.last_param_lens[0]] else "x";
    const p = dataRowPayload2(which, first);
    try writeMsg(stream, io, 'D', &p);
}

fn writeCommandComplete(stream: std.Io.net.Stream, io: std.Io, tag: []const u8) !void {
    var buf: [64]u8 = @splat(0);
    @memcpy(buf[0..tag.len], tag);
    try writeMsg(stream, io, 'C', buf[0..tag.len]);
}

fn writeParamStatus(stream: std.Io.net.Stream, io: std.Io, key: []const u8, value: []const u8) !void {
    // 协议要求 `key\0value\0`（**结尾的 \0 不能省**，客户端按两个 NUL 解析）
    var buf: [128]u8 = @splat(0);
    @memcpy(buf[0..key.len], key);
    @memcpy(buf[key.len + 1 .. key.len + 1 + value.len], value);
    try writeMsg(stream, io, 'S', buf[0 .. key.len + 1 + value.len + 1]);
}

fn writeAuthMsg(stream: std.Io.net.Stream, io: std.Io, payload: []const u8) !void {
    try writeMsg(stream, io, 'R', payload);
}

/// MD5 鉴权：发 salt，校验客户端回的 `md5` + hex(md5(hex(md5(pwd+user)) + salt))。
fn authMd5(ctx: *ServerCtx, stream: std.Io.net.Stream, io: std.Io) !void {
    const salt = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var payload: [8]u8 = undefined;
    payloadInt4(&payload, 0, 5);
    @memcpy(payload[4..8], &salt);
    try writeAuthMsg(stream, io, &payload);

    var tag: [1]u8 = undefined;
    try readExact(stream, io, &tag);
    if (tag[0] != 'p') {
        ctx.fail("MD5 鉴权：期望密码消息 'p'，收到 '{c}'", .{tag[0]});
        return error.Protocol;
    }
    var len_buf: [4]u8 = undefined;
    try readExact(stream, io, &len_buf);
    const mlen = std.mem.readInt(u32, &len_buf, .big);
    var buf: [128]u8 = undefined;
    try readExact(stream, io, buf[0 .. mlen - 4]);
    const got = buf[0 .. mlen - 4];

    // 期望值
    var inner: [16]u8 = undefined;
    var h1 = std.crypto.hash.Md5.init(.{});
    h1.update(password);
    h1.update(user);
    h1.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);

    var h2 = std.crypto.hash.Md5.init(.{});
    h2.update(&inner_hex);
    h2.update(&salt);
    var outer: [16]u8 = undefined;
    h2.final(&outer);
    var expect: [35]u8 = undefined;
    @memcpy(expect[0..3], "md5");
    const outer_hex = std.fmt.bytesToHex(outer, .lower);
    @memcpy(expect[3..], &outer_hex);

    if (!std.mem.eql(u8, got, &expect)) {
        ctx.fail("MD5 摘要不匹配：收到 {s}，期望 {s}", .{ got, expect });
        return error.AuthFailed;
    }
    try writeAuthMsg(stream, io, &[_]u8{ 0, 0, 0, 0 }); // AuthenticationOk
}

/// SCRAM-SHA-256 鉴权：完整三段交互，服务端用 RFC 公式校验客户端 proof。
fn authScram(ctx: *ServerCtx, stream: std.Io.net.Stream, io: std.Io) !void {
    // AuthenticationSASL + 机制列表
    var mech: [64]u8 = @splat(0);
    payloadInt4(&mech, 0, 10);
    @memcpy(mech[4..17], "SCRAM-SHA-256");
    try writeAuthMsg(stream, io, mech[0..18]);

    // SASLInitialResponse：机制名\0 + int32 长度 + client-first
    var tag: [1]u8 = undefined;
    try readExact(stream, io, &tag);
    if (tag[0] != 'p') {
        ctx.fail("SCRAM：期望 SASLInitialResponse 'p'，收到 '{c}'", .{tag[0]});
        return error.Protocol;
    }
    var len_buf: [4]u8 = undefined;
    try readExact(stream, io, &len_buf);
    const mlen = std.mem.readInt(u32, &len_buf, .big);
    var buf: [512]u8 = undefined;
    try readExact(stream, io, buf[0 .. mlen - 4]);
    const initial = buf[0 .. mlen - 4];

    const name_end = std.mem.indexOfScalar(u8, initial, 0) orelse return error.Protocol;
    const mech_name = initial[0..name_end];
    if (!std.mem.eql(u8, mech_name, "SCRAM-SHA-256")) {
        ctx.fail("SCRAM：机制不是 SCRAM-SHA-256（{s}）", .{mech_name});
        return error.Protocol;
    }
    const resp_len = std.mem.readInt(i32, initial[name_end + 1 ..][0..4], .big);
    const client_first = initial[name_end + 5 ..][0 .. @as(usize, @intCast(resp_len))];
    // client-first = "n,," + client-first-bare
    if (!std.mem.startsWith(u8, client_first, "n,,")) {
        ctx.fail("SCRAM：client-first 前缀不是 n,,（{s}）", .{client_first});
        return error.Protocol;
    }
    const client_first_bare = client_first[3..];

    // 取客户端 nonce
    var client_nonce: []const u8 = "";
    var it = std.mem.splitScalar(u8, client_first_bare, ',');
    while (it.next()) |part| {
        if (part.len > 2 and part[0] == 'r') client_nonce = part[2..];
    }
    if (client_nonce.len == 0) {
        ctx.fail("SCRAM：client-first 里没有 nonce（{s}）", .{client_first_bare});
        return error.Protocol;
    }

    // server-first：nonce 拼接固定后缀 + 固定 salt + iterations
    var server_first_buf: [256]u8 = undefined;
    const server_nonce_suffix = "SRVRNONCE123";
    const salt_b64 = "QSXCR+Q6sek8bf92";
    const server_first = std.fmt.bufPrint(
        &server_first_buf,
        "r={s}{s},s={s},i=4096",
        .{ client_nonce, server_nonce_suffix, salt_b64 },
    ) catch return error.Protocol;

    var continue_payload: [300]u8 = undefined;
    payloadInt4(&continue_payload, 0, 11);
    @memcpy(continue_payload[4 .. 4 + server_first.len], server_first);
    try writeAuthMsg(stream, io, continue_payload[0 .. 4 + server_first.len]);

    // client-final：`c=biws,r=<nonce>,p=<proof>`
    try readExact(stream, io, &tag);
    if (tag[0] != 'p') {
        ctx.fail("SCRAM：期望 client-final 'p'，收到 '{c}'", .{tag[0]});
        return error.Protocol;
    }
    try readExact(stream, io, &len_buf);
    const flen = std.mem.readInt(u32, &len_buf, .big);
    var final_buf: [512]u8 = undefined;
    try readExact(stream, io, final_buf[0 .. flen - 4]);
    const client_final = final_buf[0 .. flen - 4];

    const proof_at = std.mem.indexOf(u8, client_final, ",p=") orelse {
        ctx.fail("SCRAM：client-final 里没有 proof（{s}）", .{client_final});
        return error.Protocol;
    };
    const client_final_wo_proof = client_final[0..proof_at];

    // 服务端复算 proof 与签名
    var salt_buf: [64]u8 = undefined;
    const salt_len = (try base64Decode(&salt_buf, salt_b64)).?;
    const salt = salt_buf[0..salt_len];

    var expect_proof: [32]u8 = undefined;
    try postgres.scramProof(password, salt, 4096, client_first_bare, server_first, client_final_wo_proof, &expect_proof);
    var expect_b64: [64]u8 = undefined;
    const expect_text = std.base64.standard.Encoder.encode(&expect_b64, &expect_proof);
    const got_b64 = client_final[proof_at + 3 ..];
    if (!std.mem.eql(u8, expect_text, got_b64)) {
        ctx.fail("SCRAM proof 不匹配：收到 {s}，期望 {s}", .{ got_b64, expect_text });
        return error.AuthFailed;
    }

    var sig: [32]u8 = undefined;
    try postgres.scramServerSignature(password, salt, 4096, client_first_bare, server_first, client_final_wo_proof, &sig);
    var sig_b64: [64]u8 = undefined;
    const sig_text = std.base64.standard.Encoder.encode(&sig_b64, &sig);

    var final_payload: [128]u8 = undefined;
    payloadInt4(&final_payload, 0, 12);
    @memcpy(final_payload[4..6], "v=");
    @memcpy(final_payload[6 .. 6 + sig_text.len], sig_text);
    try writeAuthMsg(stream, io, final_payload[0 .. 6 + sig_text.len]);

    try writeAuthMsg(stream, io, &[_]u8{ 0, 0, 0, 0 }); // AuthenticationOk
}

/// 记录 Bind 里的参数（文本格式）供断言。
fn captureBindParams(ctx: *ServerCtx, payload: []const u8) !void {
    var i: usize = 0;
    // portal 名
    i = (std.mem.indexOfScalarPos(u8, payload, i, 0) orelse return error.Protocol) + 1;
    // 语句名
    i = (std.mem.indexOfScalarPos(u8, payload, i, 0) orelse return error.Protocol) + 1;
    // 参数格式数（应为 0）
    const fmt_count = std.mem.readInt(i16, payload[i..][0..2], .big);
    i += 2 + @as(usize, @intCast(fmt_count)) * 2;
    // 参数个数
    const count = std.mem.readInt(i16, payload[i..][0..2], .big);
    i += 2;
    ctx.last_param_count = 0;
    var n: usize = 0;
    while (n < @as(usize, @intCast(count)) and n < 4) : (n += 1) {
        const vlen = std.mem.readInt(i32, payload[i..][0..4], .big);
        i += 4;
        // **NULL 也计数**：`last_param_count` 表达的是「参数个数」，
        // 而 `last_param_lens[n] == 0` 才是「该参数为空」
        ctx.last_param_count = n + 1;
        if (vlen < 0) {
            ctx.last_param_lens[n] = 0;
            continue;
        }
        const l: usize = @intCast(vlen);
        const copy_len = @min(l, ctx.last_params[n].len);
        @memcpy(ctx.last_params[n][0..copy_len], payload[i .. i + copy_len]);
        ctx.last_param_lens[n] = copy_len;
        i += l;
    }
}

fn base64Decode(dest: []u8, source: []const u8) !?usize {
    std.base64.standard.Decoder.decode(dest, source) catch return null;
    var len: usize = source.len / 4 * 3;
    if (source.len > 0 and source[source.len - 1] == '=') len -= 1;
    if (source.len > 1 and source[source.len - 2] == '=') len -= 1;
    return len;
}

// ── 分帧工具 ────────────────────────────────────────────────────────────────

fn writeMsg(stream: std.Io.net.Stream, io: std.Io, tag: u8, payload: []const u8) !void {
    var head: [5]u8 = undefined;
    head[0] = tag;
    std.mem.writeInt(u32, head[1..5], @intCast(payload.len + 4), .big);
    try writeRaw(stream, io, &head);
    if (payload.len > 0) try writeRaw(stream, io, payload);
}

fn writeRaw(stream: std.Io.net.Stream, io: std.Io, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const r = io.operate(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &.{bytes[sent..]},
        } }) catch return error.WriteFailed;
        const n = r.net_write catch return error.WriteFailed;
        if (n == 0) return error.ConnectionClosed;
        sent += n;
    }
}

fn readExact(stream: std.Io.net.Stream, io: std.Io, dst: []u8) !void {
    var got: usize = 0;
    while (got < dst.len) {
        var slices = [_][]u8{dst[got..]};
        const r = io.operate(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &slices,
        } }) catch return error.ReadFailed;
        const res = r.net_read catch return error.ReadFailed;
        const n = res.data_len;
        if (n == 0) return error.ConnectionClosed;
        got += n;
    }
}

/// 定长缓冲的简单写入器（假服务端构造消息用）。
const FixedBuf = struct {
    buf: []u8,
    i: usize = 0,

    fn init(buf: []u8) FixedBuf {
        return .{ .buf = buf };
    }

    fn putI16(self: *FixedBuf, v: i16) void {
        std.mem.writeInt(i16, self.buf[self.i..][0..2], v, .big);
        self.i += 2;
    }

    fn putI32(self: *FixedBuf, v: i32) void {
        std.mem.writeInt(i32, self.buf[self.i..][0..4], v, .big);
        self.i += 4;
    }

    fn cstr(self: *FixedBuf, s: []const u8) void {
        @memcpy(self.buf[self.i .. self.i + s.len], s);
        self.i += s.len;
        self.buf[self.i] = 0;
        self.i += 1;
    }

    fn slice(self: *FixedBuf) []const u8 {
        return self.buf[0..self.i];
    }
};

// ── 测试 ────────────────────────────────────────────────────────────────────

fn runCase(auth_mode: u32, port_start: u16, comptime body: anytype) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = port_start;
    var server: ?std.Io.net.Server = null;
    while (port < port_start + 20) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        server = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    if (server == null) {
        std.debug.print("[SKIP] {d}-{d} 端口均不可用，跳过 PostgreSQL 回环用例\n", .{ port_start, port_start + 19 });
        return;
    }

    var ctx = ServerCtx{ .server = server.?, .io = sio, .auth_mode = auth_mode };
    defer ctx.server.deinit(sio);
    const th = try std.Thread.spawn(.{}, serverMain, .{&ctx});

    var conn = postgres.Conn.open(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .user = user,
        .password = password,
        .database = database,
    }) catch |e| {
        th.join();
        std.debug.print("[FAIL] 连接假服务端失败：{s}；服务端信息：{s}\n", .{ @errorName(e), ctx.errText() });
        return e;
    };
    defer conn.deinit();

    try body(&conn, &ctx);

    // **必须先关连接再 join**：假服务端在 `readExact` 上阻塞等下一帧，
    // 只有客户端发 Terminate 并断开才会让它退出；顺序反了会互相等待。
    conn.close();
    th.join();
    if (!ctx.ok) {
        std.debug.print("[FAIL] 假服务端未正常结束：{s}\n", .{ctx.errText()});
        return error.ServerFailed;
    }
}

test "PostgreSQL 端到端（回环假服务端）：Trust 鉴权 + 简单查询 + 影响行数" {
    try runCase(0, 39201, struct {
        fn run(conn: *postgres.Conn, ctx: *ServerCtx) !void {
            _ = ctx;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();

            const r = try conn.queryAlloc(arena.allocator(), "SELECT id, name FROM t", &.{});
            switch (r) {
                .rows => |rows| {
                    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
                    try std.testing.expectEqual(@as(i64, 7), rows.rows[0].get("id").?.asI64().?);
                    try std.testing.expectEqualStrings("abc", rows.rows[0].get("name").?.asText().?);
                },
                .ok => return error.ExpectedRows,
            }

            // 影响行数：UPDATE 3 / CREATE TABLE 0
            try std.testing.expectEqual(@as(u64, 3), try conn.exec("UPDATE t SET a = 1", &.{}));
            try std.testing.expectEqual(@as(u64, 0), try conn.exec("CREATE TABLE t (a int)", &.{}));

            // 服务端版本已从 ParameterStatus 收到
            try std.testing.expectEqualStrings("16.2", conn.serverVersion());
        }
    }.run);
}

test "PostgreSQL 端到端（回环假服务端）：MD5 鉴权按 RFC 公式校验" {
    try runCase(5, 39221, struct {
        fn run(conn: *postgres.Conn, ctx: *ServerCtx) !void {
            _ = ctx;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const r = try conn.queryAlloc(arena.allocator(), "SELECT 1", &.{});
            switch (r) {
                .rows => |rows| try std.testing.expectEqual(@as(usize, 1), rows.rows.len),
                .ok => return error.ExpectedRows,
            }
        }
    }.run);
}

test "PostgreSQL 端到端（回环假服务端）：SCRAM-SHA-256 完整三段交互" {
    try runCase(10, 39241, struct {
        fn run(conn: *postgres.Conn, ctx: *ServerCtx) !void {
            _ = ctx;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const r = try conn.queryAlloc(arena.allocator(), "SELECT 1", &.{});
            switch (r) {
                .rows => |rows| try std.testing.expectEqual(@as(usize, 1), rows.rows.len),
                .ok => return error.ExpectedRows,
            }
        }
    }.run);
}

test "PostgreSQL 端到端（回环假服务端）：扩展协议文本参数编码" {
    try runCase(0, 39261, struct {
        fn run(conn: *postgres.Conn, ctx: *ServerCtx) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();

            const r = try conn.queryAlloc(arena.allocator(), "SELECT $1::text", &.{.{ .text = "你好 pg" }});
            switch (r) {
                .rows => |rows| try std.testing.expectEqual(@as(usize, 2), rows.rows.len),
                .ok => return error.ExpectedRows,
            }
            // 服务端收到的第一个参数必须是原文（UTF-8 原样透传）
            try std.testing.expectEqualStrings("你好 pg", ctx.last_params[0][0..ctx.last_param_lens[0]]);

            // 布尔按 PG 文本格式 `t`
            _ = try conn.queryAlloc(arena.allocator(), "SELECT $1::bool", &.{.{ .boolean = true }});
            try std.testing.expectEqualStrings("t", ctx.last_params[0][0..ctx.last_param_lens[0]]);

            // NULL 用 -1 长度传递：服务端看到 0 个参数值
            _ = try conn.queryAlloc(arena.allocator(), "SELECT $1::text", &.{.{ .null = {} }});
            try std.testing.expectEqual(@as(usize, 1), ctx.last_param_count);
            try std.testing.expectEqual(@as(usize, 0), ctx.last_param_lens[0]);
        }
    }.run);
}
