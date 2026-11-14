//! MongoDB 驱动（**线协议 OP_MSG**，不依赖 libmongoc / MongoDB.Driver）。
//!
//! MongoDB **不是 SQL 库**：它没有表结构、没有 JOIN、没有 SQL；操作单位是「命令 + 文档」。
//! 因此本驱动暴露的是**文档级 API**（`insert` / `findAlloc` / `update` / `delete` / `count` /
//! `runCommandAlloc`），与 C# 侧口径一致（`Database/MongoDB.cs` 注释写明：
//! 「MongoDB 不使用 SQL，大部分 SQL 操作方法会抛出 NotSupportedException，通过驱动直接操作集合和文档」）。
//!
//! ## 协议要点
//! - 消息头 16 字节：`messageLength(i32) requestID(i32) responseTo(i32) opCode(i32)`；
//! - **OP_MSG(2013)**：`flagBits(u32)` + 段（kind 0x00 = 单个 BSON 文档；kind 0x01 = 文档序列，本驱动发送只用 kind 0）；
//! - 命令就是一个文档：`{ "<cmd>": <集合名或 1>, "$db": "<库>", <参数...> }`；
//! - 读回：先读 16 字节头，再读 `messageLength-16` 字节；逐段解析，取第一个 kind 0 文档；
//! - 成败看 `ok`（double 1.0 / int 1）与 `errmsg` / `code`。
//!
//! ## 鉴权：SCRAM-SHA-256（MongoDB 4.0+ 默认）
//! RFC 5802/7677 流程：`saslStart`（client-first）→ 服务端 `r/s/i` → `saslContinue`（client-final + proof）
//! → 校验服务端签名 `v=`。只依赖 Zig 标准库（`HmacSha256` / `Sha256` / `pbkdf2` / base64）。
//! 服务端只报 SCRAM-SHA-1 时**明确报 `error.UnsupportedMechanism`**（不静默降级到弱机制）。
//!
//! ## 已知边界
//! - 只实现 OP_MSG（MongoDB 3.6+）；更老的 OP_QUERY 不实现；
//! - 不走 TLS（需要时前面套反代/隧道，或后续补 `tls_client`）；
//! - `find` 只取首批（`firstBatch`），不做 getMore 翻页；大批量导出请用 `batchSize` + 自建 getMore。

const std = @import("std");
const compat = @import("../compat.zig");
const bson = @import("bson.zig");
const Value = @import("value.zig").Value;
const Row = @import("row.zig").Row;
const DateTime = @import("../time/datetime.zig").DateTime;

pub const default_port: u16 = 27017;

const op_msg: i32 = 2013;
const max_message_size: usize = 48 * 1024 * 1024;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    user: []const u8 = "",
    password: []const u8 = "",
    /// 默认库（命令里的 `$db`）
    database: []const u8 = "test",
    /// 鉴权库（空 = 用 `database`；MongoDB 惯例是 `admin`）
    auth_source: []const u8 = "",
    /// 握手里上报的应用名（运维在 `db.currentOp()` 里能看到）
    app_name: []const u8 = "zzig",
};

pub const Error = error{
    ConnectionClosed,
    Protocol,
    /// 服务端返回 `ok: 0`（原因在 `lastError()`）
    Server,
    /// 鉴权失败（口令错 / 用户不存在 / 不支持该机制）
    AuthFailed,
    /// 服务端不支持 SCRAM-SHA-256（只给了 SCRAM-SHA-1 等弱机制）
    UnsupportedMechanism,
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    /// 自持字符串（Options 里的切片可能来自连接串解析的临时内存）
    host: []u8 = &.{},
    user: []u8 = &.{},
    password: []u8 = &.{},
    database: []u8 = &.{},
    auth_source: []u8 = &.{},
    app_name: []u8 = &.{},
    request_id: i32 = 1,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
    server_version: [32]u8 = undefined,
    server_version_len: usize = 0,
    closed: bool = false,

    // ── 连接 ────────────────────────────────────────────────────────────

    pub fn open(gpa: std.mem.Allocator, opts: Options) !Conn {
        const io = compat.currentIo();
        const address = std.Io.net.IpAddress.resolve(io, opts.host, opts.port) catch |e| {
            std.debug.print("[zzig.mongodb] 解析主机失败：host={s} port={d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };
        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            std.debug.print("[zzig.mongodb] 连接失败：{s}:{d} 原因={s}\n", .{ opts.host, opts.port, @errorName(e) });
            return e;
        };

        var self = Conn{ .gpa = gpa, .io = io, .stream = stream };
        errdefer {
            stream.close(io);
            self.freeStrings();
        }

        self.host = try gpa.dupe(u8, opts.host);
        errdefer gpa.free(self.host);
        self.user = try gpa.dupe(u8, opts.user);
        errdefer gpa.free(self.user);
        self.password = try gpa.dupe(u8, opts.password);
        errdefer gpa.free(self.password);
        self.database = try gpa.dupe(u8, if (opts.database.len > 0) opts.database else "test");
        errdefer gpa.free(self.database);
        self.auth_source = try gpa.dupe(u8, opts.auth_source);
        errdefer gpa.free(self.auth_source);
        self.app_name = try gpa.dupe(u8, if (opts.app_name.len > 0) opts.app_name else "zzig");

        try self.handshake();
        if (self.user.len > 0) try self.authenticateScram256();
        return self;
    }

    fn freeStrings(self: *Conn) void {
        if (self.host.len > 0) self.gpa.free(self.host);
        if (self.user.len > 0) self.gpa.free(self.user);
        if (self.password.len > 0) self.gpa.free(self.password);
        if (self.database.len > 0) self.gpa.free(self.database);
        if (self.auth_source.len > 0) self.gpa.free(self.auth_source);
        if (self.app_name.len > 0) self.gpa.free(self.app_name);
        self.host = &.{};
        self.user = &.{};
        self.password = &.{};
        self.database = &.{};
        self.auth_source = &.{};
        self.app_name = &.{};
    }

    pub fn deinit(self: *Conn) void {
        if (!self.closed) {
            self.stream.close(self.io);
            self.closed = true;
        }
        self.freeStrings();
    }

    pub fn lastError(self: *const Conn) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn serverVersion(self: *const Conn) []const u8 {
        return self.server_version[0..self.server_version_len];
    }

    fn setError(self: *Conn, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch {
            self.err_len = @min(self.err_buf.len, 200);
            return;
        };
        self.err_len = text.len;
    }

    fn authDb(self: *const Conn) []const u8 {
        return if (self.auth_source.len > 0) self.auth_source else self.database;
    }

    // ── 传输 ────────────────────────────────────────────────────────────

    fn writeAll(self: *Conn, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const result = self.io.operate(.{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .data = &.{bytes[sent..]},
            } }) catch |e| {
                self.setError("写 socket 失败：{s}", .{@errorName(e)});
                return e;
            };
            const n = result.net_write catch |e| {
                self.setError("写 socket 失败：{s}", .{@errorName(e)});
                return e;
            };
            if (n == 0) {
                self.setError("写 socket 返回 0（对端已关闭）", .{});
                return Error.ConnectionClosed;
            }
            sent += n;
        }
    }

    fn readSome(self: *Conn, dst: []u8) !usize {
        var slices = [_][]u8{dst};
        const r = self.io.operate(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = &slices,
        } }) catch |e| {
            self.setError("读 socket 失败：{s}", .{@errorName(e)});
            return e;
        };
        const res = r.net_read catch |e| {
            self.setError("读 socket 失败：{s}", .{@errorName(e)});
            return e;
        };
        return res.data_len;
    }

    fn readExact(self: *Conn, dst: []u8) !void {
        var got: usize = 0;
        while (got < dst.len) {
            const n = try self.readSome(dst[got..]);
            if (n == 0) {
                self.setError("连接被对端关闭（已读 {d}/{d} 字节）", .{ got, dst.len });
                return Error.ConnectionClosed;
            }
            got += n;
        }
    }

    /// 发一个 OP_MSG（单个 kind-0 文档），并把响应里第一个 kind-0 文档解析出来。
    ///
    /// 返回的文档分配在 `arena`。
    pub fn runCommandAlloc(self: *Conn, arena: std.mem.Allocator, db: []const u8, cmd: []const bson.Field) ![]const bson.Field {
        // 1. 组命令文档：`$db` 必须在（OP_MSG 没有别的地方放库名）
        var fields: std.ArrayListUnmanaged(bson.Field) = .empty;
        defer fields.deinit(arena);
        try fields.appendSlice(arena, cmd);
        try fields.append(arena, .{ .name = "$db", .value = .{ .string = db } });

        const doc = try bson.encodeAlloc(arena, fields.items);

        // 2. 组消息：16 字节头 + flagBits + kind + 文档
        const total: usize = 16 + 4 + 1 + doc.len;
        if (total > max_message_size) {
            self.setError("命令消息 {d} 字节超过上限 {d}", .{ total, max_message_size });
            return Error.Protocol;
        }
        const msg = try arena.alloc(u8, total);
        const rid = self.request_id;
        self.request_id +%= 1;

        std.mem.writeInt(i32, msg[0..4], @intCast(total), .little);
        std.mem.writeInt(i32, msg[4..8], rid, .little);
        std.mem.writeInt(i32, msg[8..12], 0, .little);
        std.mem.writeInt(i32, msg[12..16], op_msg, .little);
        std.mem.writeInt(u32, msg[16..20], 0, .little); // flagBits
        msg[20] = 0x00; // section kind 0
        @memcpy(msg[21..], doc);

        try self.writeAll(msg);

        // 3. 读响应
        var hdr: [16]u8 = undefined;
        try self.readExact(&hdr);
        const len = std.mem.readInt(i32, hdr[0..4], .little);
        if (len < 16 + 5 or @as(usize, @intCast(len)) > max_message_size) {
            self.setError("响应长度异常：{d} 字节", .{len});
            return Error.Protocol;
        }
        const op = std.mem.readInt(i32, hdr[12..16], .little);
        if (op != op_msg) {
            self.setError("不支持的响应操作码 {d}（只实现 OP_MSG {d}）", .{ op, op_msg });
            return Error.Protocol;
        }
        const body = try arena.alloc(u8, @intCast(len - 16));
        try self.readExact(body);

        // 逐段找 kind 0（kind 1 是文档序列，按长度跳过）
        var pos: usize = 4; // 跳过 flagBits
        while (pos < body.len) {
            const kind = body[pos];
            pos += 1;
            if (kind == 0x00) {
                var consumed: usize = 0;
                const reply = bson.parseOneAlloc(arena, body[pos..], &consumed) catch |e| {
                    self.setError("响应 BSON 解析失败：{s}", .{@errorName(e)});
                    return Error.Protocol;
                };
                try self.checkOk(reply);
                return reply;
            }
            if (kind == 0x01) {
                if (pos + 4 > body.len) break;
                const sec_len = std.mem.readInt(i32, body[pos..][0..4], .little);
                if (sec_len <= 0) break;
                pos += @intCast(sec_len);
                continue;
            }
            // 未知段：无法确定长度，停止（已拿到的 kind 0 已处理）
            break;
        }
        self.setError("响应里没有 kind 0 文档（{d} 字节）", .{body.len});
        return Error.Protocol;
    }

    fn checkOk(self: *Conn, reply: []const bson.Field) !void {
        const ok_val = bson.get(reply, "ok") orelse {
            // 没有 ok 字段：某些老命令（如 isMaster）也一定有，缺了说明不是正常响应
            self.setError("响应缺少 ok 字段", .{});
            return Error.Protocol;
        };
        const ok = switch (ok_val) {
            .double => |f| f == 1.0,
            .int32 => |i| i == 1,
            .int64 => |i| i == 1,
            .boolean => |b| b,
            else => false,
        };
        if (ok) return;

        const code = bson.getI64(reply, "code") orelse 0;
        const msg = bson.getStr(reply, "errmsg") orelse "（无 errmsg）";
        self.setError("MongoDB 命令失败（code={d}）：{s}", .{ code, msg });
        std.debug.print("[zzig.mongodb] {s}\n", .{self.lastError()});
        return Error.Server;
    }

    // ── 握手与鉴权 ──────────────────────────────────────────────────────

    fn handshake(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var client_meta: std.ArrayListUnmanaged(bson.Field) = .empty;
        try client_meta.append(a, .{ .name = "driver", .value = .{ .doc = &[_]bson.Field{
            .{ .name = "name", .value = .{ .string = "zzig" } },
            .{ .name = "version", .value = .{ .string = "0.1" } },
        } } });
        try client_meta.append(a, .{ .name = "application", .value = .{ .doc = &[_]bson.Field{
            .{ .name = "name", .value = .{ .string = self.app_name } },
        } } });

        const reply = try self.runCommandAlloc(a, "admin", &[_]bson.Field{
            .{ .name = "hello", .value = .{ .int32 = 1 } },
            .{ .name = "client", .value = .{ .doc = client_meta.items } },
        });

        if (bson.getStr(reply, "maxWireVersion") == null) {
            if (bson.getI64(reply, "maxWireVersion")) |v| {
                if (v < 6) {
                    self.setError("服务端 maxWireVersion={d} 过低（OP_MSG 需要 6+，即 MongoDB 3.6+）", .{v});
                    return Error.Protocol;
                }
            }
        } else if (bson.getI64(reply, "maxWireVersion")) |v| {
            if (v < 6) {
                self.setError("服务端 maxWireVersion={d} 过低（OP_MSG 需要 6+，即 MongoDB 3.6+）", .{v});
                return Error.Protocol;
            }
        }

        if (bson.getStr(reply, "version")) |ver| {
            const n = @min(ver.len, self.server_version.len);
            @memcpy(self.server_version[0..n], ver[0..n]);
            self.server_version_len = n;
        }
    }

    /// SCRAM-SHA-256 鉴权（RFC 5802 + RFC 7677）。
    fn authenticateScram256(self: *Conn) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const db = self.authDb();

        // 1. client-first
        const nonce = try makeNonce(a);
        const client_first_bare = try std.fmt.allocPrint(a, "n={s},r={s}", .{ self.user, nonce });
        const client_first = try std.fmt.allocPrint(a, "n,,{s}", .{client_first_bare});

        var reply = self.runCommandAlloc(a, db, &[_]bson.Field{
            .{ .name = "saslStart", .value = .{ .int32 = 1 } },
            .{ .name = "mechanism", .value = .{ .string = "SCRAM-SHA-256" } },
            .{ .name = "payload", .value = .{ .binary = client_first } },
            .{ .name = "autoAuthorize", .value = .{ .int32 = 1 } },
        }) catch |e| {
            if (e == Error.Server) {
                const msg = self.lastError();
                if (std.mem.indexOf(u8, msg, "mechanism") != null or std.mem.indexOf(u8, msg, "Mechanism") != null) {
                    std.debug.print(
                        "[zzig.mongodb] 服务端不支持 SCRAM-SHA-256（只实现这一种强机制，不做静默降级）：{s}\n",
                        .{msg},
                    );
                    return Error.UnsupportedMechanism;
                }
                return Error.AuthFailed;
            }
            return e;
        };

        const conversation_id = bson.getI64(reply, "conversationId") orelse 1;
        const server_first = try payloadText(a, reply);

        // 2. 解析 server-first：r=<nonce>,s=<salt b64>,i=<iterations>
        const r_attr = attrOf(server_first, "r") orelse {
            self.setError("SCRAM 服务端响应缺少 r=：{s}", .{server_first});
            return Error.AuthFailed;
        };
        const s_attr = attrOf(server_first, "s") orelse {
            self.setError("SCRAM 服务端响应缺少 s=：{s}", .{server_first});
            return Error.AuthFailed;
        };
        const i_attr = attrOf(server_first, "i") orelse {
            self.setError("SCRAM 服务端响应缺少 i=：{s}", .{server_first});
            return Error.AuthFailed;
        };
        if (!std.mem.startsWith(u8, r_attr, nonce)) {
            // 服务端必须回「客户端 nonce + 自己的随机串」，否则可能是中间人重放
            self.setError("SCRAM nonce 不匹配（客户端 {s}，服务端 {s}）", .{ nonce, r_attr });
            return Error.AuthFailed;
        }
        const iterations = std.fmt.parseInt(u32, i_attr, 10) catch {
            self.setError("SCRAM 迭代次数无法解析：{s}", .{i_attr});
            return Error.AuthFailed;
        };
        const salt = try base64DecodeAlloc(a, s_attr);

        // 3. 计算 proof
        const client_final_without_proof = try std.fmt.allocPrint(a, "c=biws,r={s}", .{r_attr});
        const auth_message = try std.fmt.allocPrint(a, "{s},{s},{s}", .{ client_first_bare, server_first, client_final_without_proof });

        var salted: [32]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&salted, self.password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256) catch |e| {
            self.setError("SCRAM PBKDF2 失败：{s}", .{@errorName(e)});
            return Error.AuthFailed;
        };

        var client_key: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&client_key, "Client Key", &salted);

        var stored_key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&client_key, &stored_key, .{});

        var client_sig: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&client_sig, auth_message, &stored_key);

        var proof: [32]u8 = undefined;
        for (0..32) |i| proof[i] = client_key[i] ^ client_sig[i];

        var server_key: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&server_key, "Server Key", &salted);
        var server_sig: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&server_sig, auth_message, &server_key);

        const proof_b64 = try base64EncodeAlloc(a, &proof);
        const client_final = try std.fmt.allocPrint(a, "{s},p={s}", .{ client_final_without_proof, proof_b64 });

        reply = self.runCommandAlloc(a, db, &[_]bson.Field{
            .{ .name = "saslContinue", .value = .{ .int32 = 1 } },
            .{ .name = "conversationId", .value = .{ .int32 = @intCast(conversation_id) } },
            .{ .name = "payload", .value = .{ .binary = client_final } },
        }) catch |e| {
            if (e == Error.Server) {
                std.debug.print("[zzig.mongodb] SCRAM 鉴权失败（口令错或无权限）：{s}\n", .{self.lastError()});
                return Error.AuthFailed;
            }
            return e;
        };

        // 4. 校验服务端签名（防伪造服务端）
        const server_final = try payloadText(a, reply);
        const v_attr = attrOf(server_final, "v") orelse {
            self.setError("SCRAM 服务端响应缺少 v=（{s}）", .{server_final});
            return Error.AuthFailed;
        };
        const want_v = try base64EncodeAlloc(a, &server_sig);
        if (!std.mem.eql(u8, v_attr, want_v)) {
            self.setError("SCRAM 服务端签名不匹配（期望 {s}，收到 {s}）", .{ want_v, v_attr });
            return Error.AuthFailed;
        }
    }

    // ── 命令 ────────────────────────────────────────────────────────────

    /// 插入文档；返回服务端回的 `n`。
    pub fn insert(self: *Conn, arena: std.mem.Allocator, coll: []const u8, docs: []const []const bson.Field) !u64 {
        if (docs.len == 0) return 0;
        // `documents` 是数组，每个元素是一份文档
        const items = try arena.alloc(bson.Value, docs.len);
        for (docs, 0..) |d, i| items[i] = .{ .doc = d };

        const reply = try self.runCommandAlloc(arena, self.database, &[_]bson.Field{
            .{ .name = "insert", .value = .{ .string = coll } },
            .{ .name = "documents", .value = .{ .array = items } },
            .{ .name = "ordered", .value = .{ .boolean = true } },
        });
        return @intCast(bson.getI64(reply, "n") orelse 0);
    }

    /// 更新文档；返回 `n`（匹配数，取决于 `multi`/`upsert`）。
    pub fn update(
        self: *Conn,
        arena: std.mem.Allocator,
        coll: []const u8,
        filter: []const bson.Field,
        update_doc: []const bson.Field,
        multi: bool,
        upsert: bool,
    ) !u64 {
        const one = [_]bson.Field{
            .{ .name = "q", .value = .{ .doc = filter } },
            .{ .name = "u", .value = .{ .doc = update_doc } },
            .{ .name = "multi", .value = .{ .boolean = multi } },
            .{ .name = "upsert", .value = .{ .boolean = upsert } },
        };
        const updates = [_]bson.Value{.{ .doc = &one }};

        const reply = try self.runCommandAlloc(arena, self.database, &[_]bson.Field{
            .{ .name = "update", .value = .{ .string = coll } },
            .{ .name = "updates", .value = .{ .array = &updates } },
        });
        return @intCast(bson.getI64(reply, "n") orelse 0);
    }

    /// 删除文档；返回 `n`。
    pub fn delete(
        self: *Conn,
        arena: std.mem.Allocator,
        coll: []const u8,
        filter: []const bson.Field,
        limit: ?usize,
    ) !u64 {
        const one = [_]bson.Field{
            .{ .name = "q", .value = .{ .doc = filter } },
            .{ .name = "limit", .value = .{ .int32 = if (limit) |l| @intCast(l) else 0 } },
        };
        const deletes = [_]bson.Value{.{ .doc = &one }};

        const reply = try self.runCommandAlloc(arena, self.database, &[_]bson.Field{
            .{ .name = "delete", .value = .{ .string = coll } },
            .{ .name = "deletes", .value = .{ .array = &deletes } },
        });
        return @intCast(bson.getI64(reply, "n") orelse 0);
    }

    /// 计数（`count` 命令，MongoDB 4.0+ 仍可用）。
    pub fn count(self: *Conn, arena: std.mem.Allocator, coll: []const u8, filter: []const bson.Field) !u64 {
        const reply = try self.runCommandAlloc(arena, self.database, &[_]bson.Field{
            .{ .name = "count", .value = .{ .string = coll } },
            .{ .name = "query", .value = .{ .doc = filter } },
        });
        return @intCast(bson.getI64(reply, "n") orelse 0);
    }

    /// 查询：返回 `cursor.firstBatch` 里的文档（每条文档转成一行 `Row`）。
    ///
    /// 列名取该文档的顶层字段；不同类型按 `bsonToValue` 映射（子文档/数组转成 JSON 文本）。
    pub fn findAlloc(
        self: *Conn,
        arena: std.mem.Allocator,
        coll: []const u8,
        filter: []const bson.Field,
        limit: u32,
        batch_size: u32,
    ) ![]const Row {
        var cmd: std.ArrayListUnmanaged(bson.Field) = .empty;
        try cmd.append(arena, .{ .name = "find", .value = .{ .string = coll } });
        try cmd.append(arena, .{ .name = "filter", .value = .{ .doc = filter } });
        if (limit > 0) try cmd.append(arena, .{ .name = "limit", .value = .{ .int64 = limit } });
        if (batch_size > 0) try cmd.append(arena, .{ .name = "batchSize", .value = .{ .int64 = batch_size } });

        const reply = try self.runCommandAlloc(arena, self.database, cmd.items);

        const cursor = bson.getDoc(reply, "cursor") orelse {
            self.setError("find 响应缺少 cursor 字段", .{});
            return Error.Protocol;
        };
        const first = bson.getArray(cursor, "firstBatch") orelse return &.{};

        var rows: std.ArrayListUnmanaged(Row) = .empty;
        for (first) |item| {
            const doc = switch (item) {
                .doc => |d| d,
                else => continue,
            };
            const values = try arena.alloc(Value, doc.len);
            const names = try arena.alloc([]const u8, doc.len);
            for (doc, 0..) |f, i| {
                names[i] = f.name;
                values[i] = try bsonToValue(arena, f.value);
            }
            try rows.append(arena, .{ .names = names, .values = values });
        }
        return rows.toOwnedSlice(arena);
    }
};

// ── 辅助 ────────────────────────────────────────────────────────────────────

fn bsonToValue(a: std.mem.Allocator, v: bson.Value) !Value {
    return switch (v) {
        .null => .null,
        .boolean => |b| .{ .boolean = b },
        .int32 => |i| .{ .int = i },
        .int64 => |i| .{ .int = i },
        .double => |f| .{ .float = f },
        .string => |s| .{ .text = try a.dupe(u8, s) },
        .binary => |b| .{ .blob = try a.dupe(u8, b) },
        .objectid => |id| blk: {
            const hex = try a.alloc(u8, 24);
            const digits = "0123456789abcdef";
            for (id, 0..) |byte, i| {
                hex[i * 2] = digits[byte >> 4];
                hex[i * 2 + 1] = digits[byte & 0x0F];
            }
            break :blk .{ .text = hex };
        },
        .datetime_ms => |ms| blk: {
            var dt = DateTime.fromUnixSeconds(@divFloor(ms, 1000));
            dt.nanos = @intCast(@mod(ms, 1000) * std.time.ns_per_ms);
            break :blk .{ .datetime = dt };
        },
        .regex => |r| .{ .text = try std.fmt.allocPrint(a, "/{s}/{s}", .{ r.pattern, r.options }) },
        .timestamp => |ts| .{ .int = @intCast(ts & 0x7FFF_FFFF_FFFF_FFFF) },
        .doc, .array => .{ .text = try bsonJsonAlloc(a, v) },
        .raw => |r| .{ .blob = try a.dupe(u8, r.bytes) },
    };
}

/// 子文档/数组转成 JSON 文本（让 SQL 风格的 `Row` 也能承载文档字段）。
fn bsonJsonAlloc(a: std.mem.Allocator, v: bson.Value) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try writeBsonJson(a, &out, v);
    return out.toOwnedSlice(a);
}

fn writeBsonJson(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: bson.Value) !void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int32 => |i| try appendNum(a, out, i),
        .int64 => |i| try appendNum(a, out, i),
        .double => |f| try appendNum(a, out, f),
        .string => |s| try writeJsonString(a, out, s),
        .array => |items| {
            try out.append(a, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try writeBsonJson(a, out, item);
            }
            try out.append(a, ']');
        },
        .doc => |fields| {
            try out.append(a, '{');
            for (fields, 0..) |f, i| {
                if (i > 0) try out.append(a, ',');
                try writeJsonString(a, out, f.name);
                try out.append(a, ':');
                try writeBsonJson(a, out, f.value);
            }
            try out.append(a, '}');
        },
        else => try writeJsonString(a, out, "<binary>"),
    }
}

fn appendNum(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: anytype) !void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    try out.appendSlice(a, s);
}

fn writeJsonString(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
}

fn makeNonce(a: std.mem.Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        std.mem.asBytes(&compat.nanoTimestamp()),
        &raw,
        .{},
    );
    return base64EncodeAlloc(a, &raw);
}

fn base64EncodeAlloc(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const n = enc.calcSize(bytes.len);
    const out = try a.alloc(u8, n);
    _ = enc.encode(out, bytes);
    return out;
}

fn base64DecodeAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(text) catch return Error.AuthFailed;
    const out = try a.alloc(u8, n);
    dec.decode(out, text) catch return Error.AuthFailed;
    return out;
}

/// 取 `saslStart`/`saslContinue` 响应里 `payload` 的文本（SCRAM 载荷是 ASCII）。
fn payloadText(a: std.mem.Allocator, reply: []const bson.Field) ![]const u8 {
    const v = bson.get(reply, "payload") orelse return "";
    return switch (v) {
        .binary => |b| try a.dupe(u8, b),
        .string => |s| s,
        else => "",
    };
}

/// 从 SCRAM 属性串里取 `key=value`（属性之间用逗号分隔）。
fn attrOf(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        if (part.len < key.len + 1) continue;
        if (!std.mem.eql(u8, part[0..key.len], key)) continue;
        if (part[key.len] != '=') continue;
        return part[key.len + 1 ..];
    }
    return null;
}

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "SCRAM 属性解析" {
    const server_first = "r=abc123def,s=QSXCR+Q6sek8bf92,i=4096";
    try testing.expectEqualStrings("abc123def", attrOf(server_first, "r").?);
    try testing.expectEqualStrings("QSXCR+Q6sek8bf92", attrOf(server_first, "s").?);
    try testing.expectEqualStrings("4096", attrOf(server_first, "i").?);
    try testing.expect(attrOf(server_first, "v") == null);
    // 前缀相同但不是一个键（`i` vs `ii`）不能误匹配
    try testing.expect(attrOf("ii=5,i=6", "i") != null);
    try testing.expectEqualStrings("6", attrOf("ii=5,i=6", "i").?);
}

test "SCRAM-SHA-256 计算：RFC 7677 官方向量" {
    // RFC 7677 §3 test vector：user=user / pass=pencil
    // client-first-bare: n=user,r=rOprNGfwEbeRWgbNEkqO
    // server-first:      r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096
    // expected proof:    dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=
    const a = testing.allocator;
    const client_first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO";
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const client_final_without_proof = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";

    const salt = try base64DecodeAlloc(a, "W22ZaJ0SNY7soEsUEjb6gQ==");
    defer a.free(salt);

    var salted: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted, "pencil", salt, 4096, std.crypto.auth.hmac.sha2.HmacSha256);

    var client_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_key, "Client Key", &salted);
    var stored_key: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&client_key, &stored_key, .{});

    const auth_message = try std.fmt.allocPrint(a, "{s},{s},{s}", .{ client_first_bare, server_first, client_final_without_proof });
    defer a.free(auth_message);

    var client_sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_sig, auth_message, &stored_key);

    var proof: [32]u8 = undefined;
    for (0..32) |i| proof[i] = client_key[i] ^ client_sig[i];

    const proof_b64 = try base64EncodeAlloc(a, &proof);
    defer a.free(proof_b64);
    try testing.expectEqualStrings("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", proof_b64);

    // 服务端签名同样要与 RFC 一致（v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=）
    var server_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&server_key, "Server Key", &salted);
    var server_sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&server_sig, auth_message, &server_key);
    const v_b64 = try base64EncodeAlloc(a, &server_sig);
    defer a.free(v_b64);
    try testing.expectEqualStrings("6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", v_b64);
}

test "BSON → Value 映射（含 ObjectId 十六进制与子文档 JSON）" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const id = [_]u8{ 0xAB, 0xCD, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const v_id = try bsonToValue(ar, .{ .objectid = id });
    try testing.expectEqualStrings("abcdef010203040506070809", v_id.asText().?);

    const sub = try bsonToValue(ar, .{ .doc = &[_]bson.Field{
        .{ .name = "k", .value = .{ .string = "v" } },
    } });
    try testing.expectEqualStrings("{\"k\":\"v\"}", sub.asText().?);

    const dt = try bsonToValue(ar, .{ .datetime_ms = 1_700_000_000_000 });
    try testing.expect(dt == .datetime);
}
