//! SQL Server（TDS 7.4）驱动的**回环端到端**用例：脚本化假服务端 + 真实客户端走完整协议。
//!
//! 为什么不用真库：本机没有 SQL Server 实例（`127.0.0.1:1433` 不可连、无 `MSSQL*` 服务、无 docker），
//! 按「不能猜」的规矩，凡是没有真库验证的部分一律不写进文档当结论。这里覆盖的是**客户端状态机**：
//! PRELOGIN 协商、LOGIN7 字段组装（含密码混淆）、SQL 批处理的 UTF-16LE 编码、
//! RPC `sp_executesql` 的参数编码（INTN / NVARCHAR PLP / NULL）、
//! COLMETADATA / ROW / DONE / ERROR 令牌解析、`SCOPE_IDENTITY()` 回写。
//!
//! 假服务端是**确定性**的：同样的输入永远给同样的输出，断言写死具体值。
//! 服务端侧的类型编码（PLP / 定长 / 长度前缀）是**独立按协议手写**的，不复用驱动里的函数，
//! 因此「客户端解出来的值对不对」不是自证。

const std = @import("std");
const tds = @import("tds.zig");

const user = "sa";
const password = "P@ssw0rd";
const database = "ZCodeTest";

const Ctx = struct {
    io: std.Io,
    server: std.Io.net.Server,
    /// 实际监听到的端口（`startServer` 写入）
    port: u16 = 0,
    ok: bool = false,
    /// 只回 PRELOGIN（用于验证「服务端要求 TLS → 客户端明确报错」）
    prelogin_only: bool = false,
    /// 服务端 PRELOGIN 应答里给的 ENCRYPTION 档位
    prelogin_encryption: u8 = 0,

    // 抓到并解出来的 LOGIN7 字段
    login_tds_version: u32 = 0,
    login_packet_size: u32 = 0,
    login_option_flags1: u8 = 0,
    login_user: [32]u8 = undefined,
    login_user_len: usize = 0,
    login_password: [64]u8 = undefined,
    login_password_len: usize = 0,
    login_database: [64]u8 = undefined,
    login_database_len: usize = 0,

    // 抓到的 SQL 批处理文本
    batch_sql: [512]u8 = undefined,
    batch_sql_len: usize = 0,

    // 抓到的 RPC 参数
    rpc_sql: [512]u8 = undefined,
    rpc_sql_len: usize = 0,
    rpc_decl: [256]u8 = undefined,
    rpc_decl_len: usize = 0,
    rpc_param_count: usize = 0,
    rpc_int: i64 = 0,
    rpc_text: [64]u8 = undefined,
    rpc_text_len: usize = 0,
    rpc_null_seen: bool = false,

    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    fn fail(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch "假服务端失败";
        self.err_len = text.len;
    }

    fn errText(self: *const Ctx) []const u8 {
        return self.err_buf[0..self.err_len];
    }
};

fn serverMain(ctx: *Ctx) void {
    runServer(ctx) catch |e| {
        if (ctx.err_len == 0) ctx.fail("假服务端异常：{s}", .{@errorName(e)});
        return;
    };
    ctx.ok = true;
}

// ── 收发辅助 ────────────────────────────────────────────────────────────────

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

fn writeAll(stream: std.Io.net.Stream, io: std.Io, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        var slices = [_][]const u8{bytes[sent..]};
        const r = try io.operate(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &slices,
        } });
        const n = try r.net_write;
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
}

const Msg = struct { type: u8, len: usize };

/// 读一条 TDS 消息（可能由多个包拼成），载荷写进 `buf`。
fn readMessage(stream: std.Io.net.Stream, io: std.Io, buf: []u8) !Msg {
    var total: usize = 0;
    var msg_type: u8 = 0;
    while (true) {
        var hdr: [8]u8 = undefined;
        try readExact(stream, io, &hdr);
        const len = std.mem.readInt(u16, hdr[2..4], .big);
        if (len < 8 or total + (len - 8) > buf.len) return error.Protocol;
        msg_type = hdr[0];
        const body_len = @as(usize, len) - 8;
        if (body_len > 0) try readExact(stream, io, buf[total..][0..body_len]);
        total += body_len;
        if ((hdr[1] & 0x01) != 0) break;
    }
    return .{ .type = msg_type, .len = total };
}

/// 写一条 TDS 消息（单包；假服务端的响应都很小）。
fn writeMessage(stream: std.Io.net.Stream, io: std.Io, pkt_type: u8, payload: []const u8) !void {
    var hdr: [8]u8 = undefined;
    hdr[0] = pkt_type;
    hdr[1] = 0x01; // EOM
    std.mem.writeInt(u16, hdr[2..4], @intCast(8 + payload.len), .big);
    std.mem.writeInt(u16, hdr[4..6], 0, .big);
    hdr[6] = 1;
    hdr[7] = 0;
    try writeAll(stream, io, &hdr);
    if (payload.len > 0) try writeAll(stream, io, payload);
}

// ── 编解码辅助（独立于驱动实现）─────────────────────────────────────────────

fn deobfuscate(b: u8) u8 {
    const x = b ^ 0xA5;
    return ((x << 4) & 0xF0) | ((x >> 4) & 0x0F);
}

fn utf16ToBuf(dst: []u8, raw: []const u8) !usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        const u = std.mem.readInt(u16, raw[i..][0..2], .little);
        if (u < 0x80) {
            if (out + 1 > dst.len) return error.NoSpace;
            dst[out] = @intCast(u);
            out += 1;
        } else if (u < 0x800) {
            if (out + 2 > dst.len) return error.NoSpace;
            dst[out] = @intCast(0xC0 | (u >> 6));
            dst[out + 1] = @intCast(0x80 | (u & 0x3F));
            out += 2;
        } else {
            if (out + 3 > dst.len) return error.NoSpace;
            dst[out] = @intCast(0xE0 | (u >> 12));
            dst[out + 1] = @intCast(0x80 | ((u >> 6) & 0x3F));
            dst[out + 2] = @intCast(0x80 | (u & 0x3F));
            out += 3;
        }
    }
    return out;
}

const Out = struct {
    list: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn deinit(self: *Out) void {
        self.list.deinit(self.a);
    }
    fn u8v(self: *Out, v: u8) !void {
        try self.list.append(self.a, v);
    }
    fn u16v(self: *Out, v: u16) !void {
        try self.u8v(@truncate(v));
        try self.u8v(@truncate(v >> 8));
    }
    fn u32v(self: *Out, v: u32) !void {
        try self.u16v(@truncate(v));
        try self.u16v(@truncate(v >> 16));
    }
    fn u64v(self: *Out, v: u64) !void {
        try self.u32v(@truncate(v));
        try self.u32v(@truncate(v >> 32));
    }
    fn bytes(self: *Out, b: []const u8) !void {
        try self.list.appendSlice(self.a, b);
    }
    /// B_VARCHAR（1 字节字符数 + UTF-16LE）
    fn bVarChar(self: *Out, text: []const u8) !void {
        const units = try std.unicode.utf8ToUtf16LeAlloc(self.a, text);
        defer self.a.free(units);
        try self.u8v(@intCast(units.len));
        for (units) |u| try self.u16v(u);
    }
    /// PLP 编码（NVARCHAR(max) / VARBINARY(max) 的值）：总长 + 块 + 0 结束块
    fn plp(self: *Out, data: []const u8) !void {
        try self.u64v(data.len);
        if (data.len > 0) {
            try self.u32v(@intCast(data.len));
            try self.bytes(data);
        }
        try self.u32v(0);
    }
    /// PLP 编码的 NVARCHAR（输入 UTF-8，输出 UTF-16LE 字节）
    fn plpUtf16(self: *Out, text: []const u8) !void {
        const units = try std.unicode.utf8ToUtf16LeAlloc(self.a, text);
        defer self.a.free(units);
        const byte_len: u64 = @as(u64, units.len) * 2;
        try self.u64v(byte_len);
        if (byte_len > 0) {
            try self.u32v(@intCast(byte_len));
            for (units) |u| try self.u16v(u);
        }
        try self.u32v(0);
    }
    /// DATETIME2(7) 的值：**时间 5 字节在前、日期 3 字节在后**
    fn datetime2(self: *Out, seconds_of_day: u64, date_days: u32) !void {
        const units = seconds_of_day * 10_000_000;
        var i: usize = 0;
        while (i < 5) : (i += 1) try self.u8v(@truncate((units >> @intCast(i * 8)) & 0xFF));
        i = 0;
        while (i < 3) : (i += 1) try self.u8v(@truncate((date_days >> @intCast(i * 8)) & 0xFF));
    }
};

const In = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(self: *In) !u8 {
        if (self.pos >= self.buf.len) return error.Protocol;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }
    fn take(self: *In, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return error.Protocol;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn skip(self: *In, n: usize) !void {
        _ = try self.take(n);
    }
    fn u16le(self: *In) !u16 {
        const b = try self.take(2);
        return std.mem.readInt(u16, b[0..2], .little);
    }
    fn u32le(self: *In) !u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }
    fn u64le(self: *In) !u64 {
        const b = try self.take(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }
};

// ── 假服务端 ────────────────────────────────────────────────────────────────

fn runServer(ctx: *Ctx) !void {
    var stream = try ctx.server.accept(ctx.io);
    defer stream.close(ctx.io);
    const io = ctx.io;

    var buf: [8192]u8 = undefined;

    // 1) PRELOGIN
    const pre = try readMessage(stream, io, &buf);
    if (pre.type != 0x12) {
        ctx.fail("期望 PRELOGIN(0x12)，收到 0x{X:0>2}", .{pre.type});
        return error.Protocol;
    }
    {
        var o = Out{ .a = std.heap.page_allocator };
        defer o.deinit();
        // 选项表：VERSION(6) / ENCRYPTION(1) / TERMINATOR（偏移与长度按大端）
        const table_len = 2 * 5 + 1;
        try o.bytes(&[_]u8{ 0x00, 0, table_len, 0, 6 }); // VERSION
        try o.bytes(&[_]u8{ 0x01, 0, table_len + 6, 0, 1 }); // ENCRYPTION
        try o.u8v(0xFF);
        try o.bytes(&[_]u8{ 0, 0, 0, 0, 0, 0 }); // VERSION: 15.0.2000
        try o.u8v(ctx.prelogin_encryption);
        try writeMessage(stream, io, 0x04, o.list.items);
    }
    if (ctx.prelogin_only) return;

    // 2) LOGIN7
    const login = try readMessage(stream, io, &buf);
    if (login.type != 0x10) {
        ctx.fail("期望 LOGIN7(0x10)，收到 0x{X:0>2}", .{login.type});
        return error.Protocol;
    }
    try captureLogin(ctx, buf[0..login.len]);

    {
        var o = Out{ .a = std.heap.page_allocator };
        defer o.deinit();
        // LOGINACK
        try o.u8v(0xAD);
        const ack_len_slot = o.list.items.len;
        try o.u16v(0); // 长度占位
        const ack_start = o.list.items.len;
        try o.u8v(1); // Interface
        try o.bytes(&[_]u8{ 0x74, 0x00, 0x00, 0x04 }); // TDSVersion 7.4（大端）
        try o.bVarChar("Microsoft SQL Server");
        try o.bytes(&[_]u8{ 15, 0, 0x07, 0xD0 }); // ProgVersion
        const ack_len: u16 = @intCast(o.list.items.len - ack_start);
        std.mem.writeInt(u16, o.list.items[ack_len_slot..][0..2], ack_len, .little);

        // ENVCHANGE（切库）：长度字段包含「类型 + 新值 + 旧值」
        try o.u8v(0xE3);
        const env_len_slot = o.list.items.len;
        try o.u16v(0);
        const env_start = o.list.items.len;
        try o.u8v(1); // 类型 1 = Database
        try o.bVarChar(database); // NewValue
        try o.bVarChar(""); // OldValue
        const env_len: u16 = @intCast(o.list.items.len - env_start);
        std.mem.writeInt(u16, o.list.items[env_len_slot..][0..2], env_len, .little);

        try writeDone(&o, 0x00, 0); // 登录结束
        try writeMessage(stream, io, 0x04, o.list.items);
    }

    // 3) 命令循环
    while (true) {
        const msg = readMessage(stream, io, &buf) catch |e| switch (e) {
            error.ConnectionClosed, error.ReadFailed => return,
            else => return e,
        };
        switch (msg.type) {
            0x01 => try handleBatch(ctx, stream, io, buf[0..msg.len]),
            0x03 => try handleRpc(ctx, stream, io, buf[0..msg.len]),
            else => {
                ctx.fail("未预期的包类型 0x{X:0>2}", .{msg.type});
                return error.Protocol;
            },
        }
    }
}

fn captureLogin(ctx: *Ctx, payload: []const u8) !void {
    if (payload.len < 94) {
        ctx.fail("LOGIN7 载荷太短：{d}", .{payload.len});
        return error.Protocol;
    }
    ctx.login_tds_version = std.mem.readInt(u32, payload[4..8], .big);
    ctx.login_packet_size = std.mem.readInt(u32, payload[8..12], .little);
    ctx.login_option_flags1 = payload[24];

    // UserName（偏移/长度对在 40..44）
    const user_off: usize = std.mem.readInt(u16, payload[40..42], .little);
    const user_len: usize = std.mem.readInt(u16, payload[42..44], .little);
    if (user_off + user_len * 2 > payload.len) return error.Protocol;
    ctx.login_user_len = try utf16ToBuf(&ctx.login_user, payload[user_off..][0 .. user_len * 2]);

    // Password（44..48）：先解混淆再转码
    const pw_off: usize = std.mem.readInt(u16, payload[44..46], .little);
    const pw_len: usize = std.mem.readInt(u16, payload[46..48], .little);
    if (pw_off + pw_len * 2 > payload.len) return error.Protocol;
    var plain_buf: [128]u8 = undefined;
    if (pw_len * 2 > plain_buf.len) return error.Protocol;
    for (0..pw_len * 2) |i| plain_buf[i] = deobfuscate(payload[pw_off + i]);
    ctx.login_password_len = try utf16ToBuf(&ctx.login_password, plain_buf[0 .. pw_len * 2]);

    // Database（72..76）
    const db_off: usize = std.mem.readInt(u16, payload[72..74], .little);
    const db_len: usize = std.mem.readInt(u16, payload[74..76], .little);
    if (db_off + db_len * 2 > payload.len) return error.Protocol;
    ctx.login_database_len = try utf16ToBuf(&ctx.login_database, payload[db_off..][0 .. db_len * 2]);
}

/// DONE / DONEPROC / DONEINPROC：状态(2) + CurCmd(2) + RowCount(8)
fn writeDone(o: *Out, status: u16, row_count: u64) !void {
    try o.u8v(0xFD);
    try o.u16v(status);
    try o.u16v(0);
    try o.u64v(row_count);
}

fn writeErrorToken(o: *Out, number: u32, msg: []const u8) !void {
    try o.u8v(0xAA);
    const len_slot = o.list.items.len;
    try o.u16v(0);
    const start = o.list.items.len;
    try o.u32v(number);
    try o.u8v(1); // State
    try o.u8v(16); // Class
    const units = try std.unicode.utf8ToUtf16LeAlloc(o.a, msg);
    defer o.a.free(units);
    try o.u16v(@intCast(units.len));
    for (units) |u| try o.u16v(u);
    try o.bVarChar("fake-sql"); // ServerName
    try o.bVarChar(""); // ProcName
    try o.u32v(17); // LineNumber
    const len: u16 = @intCast(o.list.items.len - start);
    std.mem.writeInt(u16, o.list.items[len_slot..][0..2], len, .little);
}

fn handleBatch(ctx: *Ctx, stream: std.Io.net.Stream, io: std.Io, payload: []const u8) !void {
    ctx.batch_sql_len = try utf16ToBuf(&ctx.batch_sql, payload);
    const sql = ctx.batch_sql[0..ctx.batch_sql_len];

    var o = Out{ .a = std.heap.page_allocator };
    defer o.deinit();

    if (std.mem.startsWith(u8, sql, "SELECT SCOPE_IDENTITY()")) {
        // 单列 decimal(38,0)，值 7
        try o.u8v(0x81);
        try o.u16v(1);
        try o.u32v(0); // UserType
        try o.u16v(0); // Flags
        try o.bytes(&[_]u8{ 0x6A, 0x11, 0x26, 0x00 }); // DECIMALN(38,0)
        try o.bVarChar("");
        try o.u8v(0xD1);
        try o.u8v(2); // 值长度 = 符号 + 1 字节尾数
        try o.u8v(1); // 正
        try o.u8v(7);
        try writeDone(&o, 0x10, 1); // DONE_COUNT
    } else if (std.mem.startsWith(u8, sql, "INSERT")) {
        try writeDone(&o, 0x10, 1);
    } else if (std.mem.startsWith(u8, sql, "FAILME")) {
        try writeErrorToken(&o, 50000, "模拟的 SQL Server 错误");
        try writeDone(&o, 0x02, 0); // DONE_ERROR
    } else if (std.mem.startsWith(u8, sql, "SELECT")) {
        try writeSampleResult(&o);
    } else {
        try writeDone(&o, 0x00, 0);
    }
    try writeMessage(stream, io, 0x04, o.list.items);
}

/// 6 列两行的结果集：INTN / NVARCHAR(PLP) / BITN / DECIMALN(38,2) / DATETIME2(7) / INTN(NULL)
fn writeSampleResult(o: *Out) !void {
    try o.u8v(0x81); // COLMETADATA
    try o.u16v(6);

    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0x26, 0x04 }); // INTN(4)
    try o.bVarChar("Id");

    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0xE7, 0xFF, 0xFF, 0x09, 0x04, 0xD0, 0x00, 0x34 }); // NVARCHAR(max) PLP
    try o.bVarChar("Name");

    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0x68, 0x01 }); // BITN
    try o.bVarChar("Flag");

    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0x6A, 0x11, 0x26, 0x02 }); // DECIMALN(38,2)
    try o.bVarChar("Amount");

    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0x2A, 0x07 }); // DATETIME2(7)
    try o.bVarChar("Created");

    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0x26, 0x04 }); // INTN(4)
    try o.bVarChar("Missing");

    // 第 1 行：42 / "中abc" / true / 12.34 / 2024-01-01 08:30:15 / NULL
    try o.u8v(0xD1);
    try o.u8v(4);
    try o.u32v(42);
    // "中abc" 的 UTF-16LE：2D 4E 61 00 62 00 63 00
    try o.plp(&[_]u8{ 0x2D, 0x4E, 0x61, 0x00, 0x62, 0x00, 0x63, 0x00 });
    try o.u8v(1);
    try o.u8v(1);
    try o.u8v(3); // decimal 值长度 = 符号 1 字节 + 尾数 2 字节
    try o.u8v(1); // 正
    try o.u8v(0xD2); // 12.34 → 尾数 1234 = 0x04D2，小端
    try o.u8v(0x04);
    // 2024-01-01 = 距公元 1 年 1 月 1 日 738885 天 = 0x0B4645 → 小端 45 46 0B
    try o.datetime2(8 * 3600 + 30 * 60 + 15, 738885);
    try o.u8v(0); // INTN 长度 0 = NULL

    // 第 2 行：43 / NULL / false / -2.51 / 1900-01-01 00:00:00 / 7
    try o.u8v(0xD1);
    try o.u8v(4);
    try o.u32v(43);
    try o.u64v(0xFFFF_FFFF_FFFF_FFFF); // PLP NULL
    try o.u8v(1);
    try o.u8v(0);
    try o.u8v(2); // 符号 + 1 字节尾数
    try o.u8v(0); // 负
    try o.u8v(0xFB); // 251 → -2.51
    try o.datetime2(0, 693595); // 1900-01-01
    try o.u8v(4);
    try o.u32v(7);

    try writeDone(o, 0x10, 2);
}

fn handleRpc(ctx: *Ctx, stream: std.Io.net.Stream, io: std.Io, payload: []const u8) !void {
    var p = In{ .buf = payload };
    try p.skip(4); // AllHeaders
    const proc_id = try p.u16le();
    _ = try p.u16le(); // OptionFlags
    if (proc_id != 10) {
        ctx.fail("RPC ProcID 不是 sp_executesql(10)：{d}", .{proc_id});
        return error.Protocol;
    }

    // @stmt / @params
    ctx.rpc_sql_len = try readRpcText(&p, &ctx.rpc_sql);
    ctx.rpc_decl_len = try readRpcText(&p, &ctx.rpc_decl);

    // 其余参数：按「我们只发 INTN / NVARCHAR PLP」这一已知形态解析
    while (p.pos < payload.len) {
        const name_len = try p.byte();
        try p.skip(@as(usize, name_len) * 2);
        _ = try p.byte(); // Status
        const t = try p.byte();
        switch (t) {
            0x26 => {
                _ = try p.byte(); // max len
                const vlen = try p.byte();
                if (vlen == 0) {
                    ctx.rpc_null_seen = true;
                } else {
                    if (vlen != 8) return error.Protocol;
                    const raw = try p.take(8);
                    ctx.rpc_int = std.mem.readInt(i64, raw[0..8], .little);
                }
            },
            0xE7 => {
                const max_len = try p.u16le();
                if (max_len != 0xFFFF) {
                    ctx.fail("NVARCHAR 参数不是 PLP（max_len={d}）", .{max_len});
                    return error.Protocol;
                }
                try p.skip(5); // collation
                const total = try p.u64le();
                if (total == 0xFFFF_FFFF_FFFF_FFFF) {
                    ctx.rpc_null_seen = true;
                } else {
                    const chunk_len = try p.u32le();
                    const chunk = try p.take(chunk_len);
                    const zero = try p.u32le();
                    if (zero != 0) return error.Protocol;
                    ctx.rpc_text_len = try utf16ToBuf(&ctx.rpc_text, chunk);
                }
            },
            else => {
                ctx.fail("未预期的参数类型 0x{X:0>2}（第 {d} 个参数，名字 {d} 字符）", .{ t, ctx.rpc_param_count, name_len });
                return error.Protocol;
            },
        }
        ctx.rpc_param_count += 1;
    }

    // DML（RPC 方式）只回 DONE + 行数；查询回两列一行的结果
    var o = Out{ .a = std.heap.page_allocator };
    defer o.deinit();
    const stmt = ctx.rpc_sql[0..ctx.rpc_sql_len];
    if (std.mem.startsWith(u8, stmt, "UPDATE") or std.mem.startsWith(u8, stmt, "DELETE")) {
        try writeDone(&o, 0x10, 0); // 影响行数 0（模拟没命中任何行）
        try writeMessage(stream, io, 0x04, o.list.items);
        return;
    }

    try o.u8v(0x81);
    try o.u16v(2);
    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0x26, 0x04 });
    try o.bVarChar("Id");
    try o.u32v(0);
    try o.u16v(0);
    try o.bytes(&[_]u8{ 0xE7, 0xFF, 0xFF, 0x09, 0x04, 0xD0, 0x00, 0x34 });
    try o.bVarChar("Name");
    try o.u8v(0xD1);
    try o.u8v(4);
    try o.u32v(@intCast(ctx.rpc_int));
    try o.plpUtf16(ctx.rpc_text[0..ctx.rpc_text_len]);
    try writeDone(&o, 0x10, 1);
    try writeMessage(stream, io, 0x04, o.list.items);
}

fn readRpcText(p: *In, dst: []u8) !usize {
    const name_len = try p.byte();
    try p.skip(@as(usize, name_len) * 2);
    _ = try p.byte(); // Status
    const t = try p.byte();
    if (t != 0xE7) return error.Protocol;
    const max_len = try p.u16le();
    if (max_len != 0xFFFF) return error.Protocol;
    try p.skip(5);
    const total = try p.u64le();
    if (total == 0xFFFF_FFFF_FFFF_FFFF) return error.Protocol;
    const chunk_len = try p.u32le();
    const chunk = try p.take(chunk_len);
    const zero = try p.u32le();
    if (zero != 0) return error.Protocol;
    return try utf16ToBuf(dst, chunk);
}

// ── 用例 ────────────────────────────────────────────────────────────────────

fn startServer(ctx: *Ctx, port_start: u16) !?std.Thread {
    var port = port_start;
    while (port < port_start + 20) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        ctx.server = addr.listen(ctx.io, .{ .reuse_address = true }) catch continue;
        ctx.port = port;
        return try std.Thread.spawn(.{}, serverMain, .{ctx});
    }
    std.debug.print("[SKIP] {d}-{d} 端口均不可用，跳过 TDS 回环用例\n", .{ port_start, port_start + 19 });
    return null;
}

test "TDS 回环：登录字段 / SQL 批处理 / 结果集解码 / RPC 带参 / 影响行数 / SCOPE_IDENTITY / ERROR" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var ctx = Ctx{ .io = sio, .server = undefined };
    const th = (try startServer(&ctx, 14330)) orelse return;
    var joined = false;
    defer if (!joined) th.join();
    defer ctx.server.deinit(sio);

    const a = std.testing.allocator;
    var conn = tds.Conn.open(a, .{
        .host = "127.0.0.1",
        .port = ctx.port,
        .user = user,
        .password = password,
        .database = database,
        .app_name = "zcode-test",
    }) catch |e| {
        std.debug.print("[FAIL] 连接假 TDS 服务端失败：{s}；服务端信息：{s}\n", .{ @errorName(e), ctx.errText() });
        return e;
    };
    defer conn.deinit();

    // ① 登录字段（含密码解混淆）
    try std.testing.expectEqual(@as(u32, 0x7400_0004), ctx.login_tds_version);
    try std.testing.expectEqual(@as(u32, 4096), ctx.login_packet_size);
    try std.testing.expectEqual(@as(u8, 0x20), ctx.login_option_flags1); // fUseDB
    try std.testing.expectEqualStrings(user, ctx.login_user[0..ctx.login_user_len]);
    try std.testing.expectEqualStrings(password, ctx.login_password[0..ctx.login_password_len]);
    try std.testing.expectEqualStrings(database, ctx.login_database[0..ctx.login_database_len]);

    // ② SQL 批处理 + 多类型结果集
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const r = try conn.queryAlloc(arena.allocator(), "SELECT Id, Name, Flag, Amount, Created, Missing FROM dbo.T", &.{});
        const rows = r.rows.rows;
        try std.testing.expectEqual(@as(usize, 2), rows.len);

        try std.testing.expectEqualStrings("Id", rows[0].names[0]);
        try std.testing.expectEqual(@as(i64, 42), rows[0].values[0].int); // INTN(4)
        try std.testing.expectEqualStrings("中abc", rows[0].values[1].text); // NVARCHAR PLP
        try std.testing.expect(rows[0].values[2].boolean); // BITN
        try std.testing.expectEqual(@as(i128, 1234), rows[0].values[3].decimal.mantissa); // DECIMALN
        try std.testing.expectEqual(@as(u8, 2), rows[0].values[3].decimal.scale);
        try std.testing.expectEqual(@as(i32, 2024), rows[0].values[4].datetime.year); // DATETIME2(7)
        try std.testing.expectEqual(@as(u8, 1), rows[0].values[4].datetime.month);
        try std.testing.expectEqual(@as(u8, 1), rows[0].values[4].datetime.day);
        try std.testing.expectEqual(@as(u8, 8), rows[0].values[4].datetime.hour);
        try std.testing.expectEqual(@as(u8, 30), rows[0].values[4].datetime.minute);
        try std.testing.expectEqual(@as(u8, 15), rows[0].values[4].datetime.second);
        try std.testing.expect(rows[0].values[5].isNull()); // INTN 长度 0 = NULL

        // 第二行：Name 为 NULL、Amount 为负、日期回到 1900-01-01
        try std.testing.expectEqual(@as(i64, 43), rows[1].values[0].int);
        try std.testing.expect(rows[1].values[1].isNull());
        try std.testing.expect(!rows[1].values[2].boolean);
        try std.testing.expectEqual(@as(i128, -251), rows[1].values[3].decimal.mantissa);
        try std.testing.expectEqual(@as(i32, 1900), rows[1].values[4].datetime.year);
        try std.testing.expectEqual(@as(i64, 7), rows[1].values[5].int);
    }

    // ③ RPC sp_executesql：参数编码（BIGINT / NVARCHAR PLP / NULL）
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const params = [_]tds.ValueIn{
            .{ .int = 42 },
            .{ .text = "张三" },
            .null,
        };
        const r = try conn.queryAlloc(arena.allocator(), "SELECT * FROM dbo.T WHERE Id = @p0 AND Name = @p1 AND Note = @p2", &params);
        try std.testing.expectEqual(@as(usize, 1), r.rows.rows.len);
        try std.testing.expectEqual(@as(i64, 42), r.rows.rows[0].values[0].int);
        try std.testing.expectEqualStrings("张三", r.rows.rows[0].values[1].text);

        try std.testing.expectEqualStrings(
            "SELECT * FROM dbo.T WHERE Id = @p0 AND Name = @p1 AND Note = @p2",
            ctx.rpc_sql[0..ctx.rpc_sql_len],
        );
        try std.testing.expectEqualStrings("@p0 bigint,@p1 nvarchar(max),@p2 bigint", ctx.rpc_decl[0..ctx.rpc_decl_len]);
        try std.testing.expectEqual(@as(i64, 42), ctx.rpc_int);
        try std.testing.expectEqualStrings("张三", ctx.rpc_text[0..ctx.rpc_text_len]);
        try std.testing.expect(ctx.rpc_null_seen);
        try std.testing.expectEqual(@as(usize, 3), ctx.rpc_param_count);
    }

    // ④ INSERT → 影响行数 + SCOPE_IDENTITY 回写
    {
        const n = try conn.exec("INSERT INTO dbo.T (Name) VALUES (@p0)", &.{.{ .text = "x" }});
        try std.testing.expectEqual(@as(u64, 1), n);
        try std.testing.expectEqual(@as(i64, 7), conn.lastInsertId());
    }

    // ⑤ ERROR 令牌 → error.Server 且错误文本可读
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try std.testing.expectError(error.Server, conn.queryAlloc(arena.allocator(), "FAILME", &.{}));
        try std.testing.expectEqual(@as(u32, 50000), conn.lastErrorCode());
        try std.testing.expect(std.mem.indexOf(u8, conn.lastError(), "模拟的 SQL Server 错误") != null);
        try std.testing.expect(std.mem.indexOf(u8, conn.lastError(), "50000") != null);
    }

    // ⑥ 出错之后连接仍可复用（令牌流已完整读掉，没有残留字节）
    {
        const n = try conn.exec("UPDATE dbo.T SET Name = @p0", &.{.{ .text = "y" }});
        try std.testing.expectEqual(@as(u64, 0), n);
    }

    // 先关连接再 join：假服务端阻塞在读下一帧上，只有客户端断开才会退出
    conn.close();
    th.join();
    joined = true;
    if (!ctx.ok) {
        std.debug.print("[FAIL] 假服务端未正常结束：{s}\n", .{ctx.errText()});
        return error.TestServerFailed;
    }
}

test "TDS 服务端要求加密时明确报错（不静默降级）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var ctx = Ctx{ .io = sio, .server = undefined, .prelogin_only = true, .prelogin_encryption = 0x03 };
    const th = (try startServer(&ctx, 14360)) orelse return;
    var joined = false;
    defer if (!joined) th.join();
    defer ctx.server.deinit(sio);

    const a = std.testing.allocator;
    const result = tds.Conn.open(a, .{
        .host = "127.0.0.1",
        .port = ctx.port,
        .user = user,
        .password = password,
        .database = database,
    });
    try std.testing.expectError(error.TlsRequired, result);
    th.join();
    joined = true;
}
