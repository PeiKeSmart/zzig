//! RSA 公钥加密（`RSAES-OAEP` + SHA1），只为 MySQL `caching_sha2_password` 的**完整鉴权**服务。
//!
//! 为什么自己写：0.17 的 std 没有 RSA，而 `caching_sha2` 在明文连接下要求
//! 「请求服务端公钥 → 用公钥加密 (密码 XOR scramble) → 发送密文」。
//! C# 绿色版 `DH.MySql/Authentication.cs`（`PerformFullAuthenticationAsync`）就是这么做的，
//! 本模块与之对齐，避免「MySQL 8 默认用户连不上」。
//!
//! 只做**加密**（不做解密/签名/密钥生成），因此不需要私钥运算。
//!
//! 实现要点：
//! - DER/PEM 解析只认 `SubjectPublicKeyInfo`（`-----BEGIN PUBLIC KEY-----`），
//!   即 MySQL 服务端 `perform_full_authentication` 返回的格式；
//! - 填充固定 `RSAES-OAEP`：`lHash = SHA1("")`、`MGF1-SHA1`、空 label（与 OpenSSL
//!   `RSA_PKCS1_OAEP_PADDING` 一致）；
//! - 模幂用「平方-乘」逐位扫描指数，公开指数是 65537，代价可忽略（每次连接一次）。

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const Managed = std.math.big.int.Managed;

pub const hLen: usize = 20; // SHA1 摘要长度
const mgf1_max: usize = hLen * (1 << 24);

pub const Error = error{
    PemFormat,
    DerFormat,
    NotRsaKey,
    MessageTooLong,
    NoPublicKey,
    Overflow,
};

pub const PublicKey = struct {
    n: Managed,
    e: Managed,
    /// 模长（字节），即 RSA 的 k
    size: usize,

    pub fn deinit(self: *PublicKey) void {
        self.n.deinit();
        self.e.deinit();
    }
};

/// 解析 PEM（`-----BEGIN PUBLIC KEY-----`）或裸 DER。
pub fn parsePublicKey(gpa: std.mem.Allocator, input: []const u8) !PublicKey {
    const der_owned: ?[]u8 = try pemToDer(gpa, input);
    defer if (der_owned) |d| gpa.free(d);
    const der = der_owned orelse input;
    return parsePublicKeyDer(gpa, der);
}

fn pemToDer(gpa: std.mem.Allocator, input: []const u8) !?[]u8 {
    const begin = std.mem.indexOf(u8, input, "-----BEGIN PUBLIC KEY-----") orelse return null;
    const after = begin + "-----BEGIN PUBLIC KEY-----".len;
    const end = std.mem.indexOfPos(u8, input, after, "-----END PUBLIC KEY-----") orelse return error.PemFormat;
    const body = input[after..end];

    // 去掉换行/空白（标准 base64 解码器不容忍换行）
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa);
    for (body) |c| {
        if (c == '\r' or c == '\n' or c == ' ' or c == '\t') continue;
        try clean.append(gpa, c);
    }
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(clean.items) catch return error.PemFormat;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    dec.decode(out, clean.items) catch return error.PemFormat;
    return out;
}

const Tlv = struct { tag: u8, body: []const u8 };

const DerReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn read(self: *DerReader) !Tlv {
        if (self.pos + 2 > self.buf.len) return error.DerFormat;
        const tag = self.buf[self.pos];
        self.pos += 1;
        var len: usize = self.buf[self.pos];
        self.pos += 1;
        if (len & 0x80 != 0) {
            const cnt = len & 0x7f;
            if (cnt == 0 or cnt > 4) return error.DerFormat;
            len = 0;
            var i: usize = 0;
            while (i < cnt) : (i += 1) {
                if (self.pos >= self.buf.len) return error.DerFormat;
                len = (len << 8) | self.buf[self.pos];
                self.pos += 1;
            }
        }
        if (self.pos + len > self.buf.len) return error.DerFormat;
        const body = self.buf[self.pos..][0..len];
        self.pos += len;
        return .{ .tag = tag, .body = body };
    }
};

pub fn parsePublicKeyDer(gpa: std.mem.Allocator, der: []const u8) !PublicKey {
    var top = DerReader{ .buf = der };
    const seq = try top.read();
    if (seq.tag != 0x30) return error.DerFormat;

    var outer = DerReader{ .buf = seq.body };
    const alg = try outer.read();
    if (alg.tag != 0x30) return error.DerFormat; // AlgorithmIdentifier
    const bits = try outer.read();
    if (bits.tag != 0x03) return error.DerFormat; // BIT STRING
    if (bits.body.len < 1 or bits.body[0] != 0) return error.DerFormat; // 0 个未用位

    var inner = DerReader{ .buf = bits.body[1..] };
    const rsa_seq = try inner.read();
    if (rsa_seq.tag != 0x30) return error.DerFormat;

    var rsa = DerReader{ .buf = rsa_seq.body };
    const n_int = try rsa.read();
    const e_int = try rsa.read();
    if (n_int.tag != 0x02 or e_int.tag != 0x02) return error.NotRsaKey;

    var key = PublicKey{
        .n = try intFromBytes(gpa, n_int.body),
        .e = try intFromBytes(gpa, e_int.body),
        .size = 0,
    };
    errdefer key.deinit();

    key.size = (key.n.bitCountAbs() + 7) / 8;
    if (key.size < 2 * hLen + 2) return error.NotRsaKey; // 太短的模长放不下 OAEP
    return key;
}

/// DER INTEGER（大端、可能带前导 0）→ 大整数
fn intFromBytes(gpa: std.mem.Allocator, bytes: []const u8) !Managed {
    var i: usize = 0;
    while (i + 1 < bytes.len and bytes[i] == 0) i += 1;
    const src = bytes[i..];

    const hex_chars = "0123456789abcdef";
    const hex = try gpa.alloc(u8, src.len * 2);
    defer gpa.free(hex);
    for (src, 0..) |b, k| {
        hex[k * 2] = hex_chars[b >> 4];
        hex[k * 2 + 1] = hex_chars[b & 0x0f];
    }
    var v = try Managed.init(gpa);
    errdefer v.deinit();
    try v.setString(16, hex);
    return v;
}

fn bytesToInt(gpa: std.mem.Allocator, bytes: []const u8) !Managed {
    return intFromBytes(gpa, bytes);
}

/// `a * b mod n`
fn mulMod(gpa: std.mem.Allocator, a: *const Managed, b: *const Managed, n: *const Managed) !Managed {
    var prod = try Managed.init(gpa);
    defer prod.deinit();
    try prod.mul(a, b);

    var q = try Managed.init(gpa);
    defer q.deinit();
    var r = try Managed.init(gpa);
    errdefer r.deinit();
    try q.divTrunc(&r, &prod, n);
    return r;
}

/// `base ^ exp mod n`（平方-乘，按指数位数扫描）
fn modPow(gpa: std.mem.Allocator, base_in: *const Managed, exp: *const Managed, n: *const Managed) !Managed {
    var result = try Managed.initSet(gpa, 1);
    errdefer result.deinit();

    var base = try Managed.init(gpa);
    defer base.deinit();
    try base.copy(base_in.toConst());

    var e = try Managed.init(gpa);
    defer e.deinit();
    try e.copy(exp.toConst());

    var two = try Managed.initSet(gpa, 2);
    defer two.deinit();
    var q = try Managed.init(gpa);
    defer q.deinit();
    var r = try Managed.init(gpa);
    defer r.deinit();

    const bits = exp.bitCountAbs();
    var i: usize = 0;
    while (i < bits) : (i += 1) {
        try q.divTrunc(&r, &e, &two);
        const odd = r.bitCountAbs() != 0; // 余数为 1 → 该位为 1
        if (odd) {
            var t = try mulMod(gpa, &result, &base, n);
            defer t.deinit();
            result.swap(&t);
        }
        e.swap(&q);
        var sq = try mulMod(gpa, &base, &base, n);
        defer sq.deinit();
        base.swap(&sq);
    }
    return result;
}

/// MGF1（SHA1）
fn mgf1(seed: []const u8, out: []u8) void {
    var counter: u32 = 0;
    var off: usize = 0;
    while (off < out.len) : (counter += 1) {
        var h = Sha1.init(.{});
        h.update(seed);
        var c: [4]u8 = .{
            @intCast((counter >> 24) & 0xff),
            @intCast((counter >> 16) & 0xff),
            @intCast((counter >> 8) & 0xff),
            @intCast(counter & 0xff),
        };
        h.update(&c);
        var digest: [hLen]u8 = undefined;
        h.final(&digest);
        const n = @min(hLen, out.len - off);
        @memcpy(out[off..][0..n], digest[0..n]);
        off += n;
    }
}

/// RSAES-OAEP（SHA1，空 label）加密。`seed` 为 20 字节随机数（测试可注入固定值）。
pub fn oaepSha1EncryptWithSeed(
    gpa: std.mem.Allocator,
    key: PublicKey,
    msg: []const u8,
    seed: *const [hLen]u8,
) ![]u8 {
    const k = key.size;
    if (msg.len + 2 * hLen + 2 > k) return error.MessageTooLong;

    const db_len = k - hLen - 1;

    var lhash: [hLen]u8 = undefined;
    Sha1.hash("", &lhash, .{});

    const db = try gpa.alloc(u8, db_len);
    defer gpa.free(db);
    @memset(db, 0);
    @memcpy(db[0..hLen], &lhash);
    // PS（全 0）已由 memset 保证，0x01 分隔符与消息紧接在后
    const sep = db_len - msg.len - 1;
    db[sep] = 0x01;
    @memcpy(db[sep + 1 ..], msg);

    const db_mask = try gpa.alloc(u8, db_len);
    defer gpa.free(db_mask);
    mgf1(seed, db_mask);
    const masked_db = db; // 原地复用
    for (masked_db, 0..) |*b, idx| b.* ^= db_mask[idx];

    var seed_mask: [hLen]u8 = undefined;
    mgf1(masked_db, &seed_mask);
    var masked_seed: [hLen]u8 = undefined;
    for (0..hLen) |idx| masked_seed[idx] = seed[idx] ^ seed_mask[idx];

    // EM = 0x00 || maskedSeed || maskedDB
    const em = try gpa.alloc(u8, k);
    defer gpa.free(em);
    em[0] = 0x00;
    @memcpy(em[1..][0..hLen], &masked_seed);
    @memcpy(em[1 + hLen ..], masked_db);

    var m = try bytesToInt(gpa, em);
    defer m.deinit();
    var c = try modPow(gpa, &m, &key.e, &key.n);
    defer c.deinit();

    // I2OSP(c, k)：大端定长；值不足时左侧补 0
    const out = try gpa.alloc(u8, k);
    errdefer gpa.free(out);
    @memset(out, 0);
    const need = (c.bitCountAbs() + 7) / 8;
    if (need <= k) {
        c.toConst().writeTwosComplement(out[k - need ..], .big);
    }
    return out;
}

/// 生产入口：随机种子走 `io.random`（0.17 的 `std.crypto.random` 已移除）。
pub fn oaepSha1Encrypt(gpa: std.mem.Allocator, io: std.Io, key: PublicKey, msg: []const u8) ![]u8 {
    var seed: [hLen]u8 = undefined;
    io.random(&seed);
    return oaepSha1EncryptWithSeed(gpa, key, msg, &seed);
}

/// `RSAES-PKCS1-v1_5` 加密（EM = 0x00 0x02 || 非零随机 || 0x00 || M）。
/// 仅作为「服务端到底用哪种填充」的对照实验保留，生产路径默认走 OAEP。
pub fn pkcs1Encrypt(gpa: std.mem.Allocator, io: std.Io, key: PublicKey, msg: []const u8) ![]u8 {
    const k = key.size;
    if (msg.len + 11 > k) return error.MessageTooLong;

    const em = try gpa.alloc(u8, k);
    defer gpa.free(em);
    em[0] = 0x00;
    em[1] = 0x02;
    const ps_len = k - msg.len - 3;
    // PS 必须非零
    io.random(em[2..][0..ps_len]);
    for (em[2..][0..ps_len]) |*b| {
        if (b.* == 0) b.* = 0x01;
    }
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len ..], msg);

    var m = try bytesToInt(gpa, em);
    defer m.deinit();
    var c = try modPow(gpa, &m, &key.e, &key.n);
    defer c.deinit();

    const out = try gpa.alloc(u8, k);
    errdefer gpa.free(out);
    @memset(out, 0);
    const need = (c.bitCountAbs() + 7) / 8;
    c.toConst().writeTwosComplement(out[k - need ..], .big);
    return out;
}

// ══════════════════════════════════════════════════════════════════════════
// 单测（不需要私钥：验 DER 解析、模幂、OAEP 编码可逆）
// ══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "RSA - 解析 SubjectPublicKeyInfo（DER/PEM）" {
    const gpa = testing.allocator;

    // 手工构造：SEQ { SEQ { OID rsaEncryption, NULL }, BIT STRING { SEQ { INT n, INT e } } }
    // n 取 48 字节（必须 ≥ 2*hLen+2，否则放不下 OAEP 填充），e = 65537
    var n_bytes: [48]u8 = undefined;
    for (&n_bytes, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xff);
    n_bytes[0] = 0xc1; // 首位非 0
    const e_bytes = [_]u8{ 0x01, 0x00, 0x01 };
    const oid = [_]u8{ 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
    const null_tlv = [_]u8{ 0x05, 0x00 };

    var rsa_seq: std.ArrayList(u8) = .empty;
    defer rsa_seq.deinit(gpa);
    try rsa_seq.append(gpa, 0x02);
    try rsa_seq.append(gpa, n_bytes.len);
    try rsa_seq.appendSlice(gpa, &n_bytes);
    try rsa_seq.append(gpa, 0x02);
    try rsa_seq.append(gpa, e_bytes.len);
    try rsa_seq.appendSlice(gpa, &e_bytes);

    var bit_str: std.ArrayList(u8) = .empty;
    defer bit_str.deinit(gpa);
    try bit_str.append(gpa, 0x00); // unused bits
    try bit_str.append(gpa, 0x30);
    try bit_str.append(gpa, @intCast(rsa_seq.items.len));
    try bit_str.appendSlice(gpa, rsa_seq.items);

    var alg: std.ArrayList(u8) = .empty;
    defer alg.deinit(gpa);
    try alg.append(gpa, 0x30);
    try alg.append(gpa, @intCast(oid.len + null_tlv.len));
    try alg.appendSlice(gpa, &oid);
    try alg.appendSlice(gpa, &null_tlv);

    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(gpa);
    try inner.appendSlice(gpa, alg.items);
    try inner.append(gpa, 0x03);
    try inner.append(gpa, @intCast(bit_str.items.len));
    try inner.appendSlice(gpa, bit_str.items);

    var der: std.ArrayList(u8) = .empty;
    defer der.deinit(gpa);
    try der.append(gpa, 0x30);
    try der.append(gpa, @intCast(inner.items.len));
    try der.appendSlice(gpa, inner.items);

    var key = try parsePublicKeyDer(gpa, der.items);
    defer key.deinit();
    try testing.expectEqual(@as(usize, 48), key.size);

    const n_hex = try key.n.toString(gpa, 16, .lower);
    defer gpa.free(n_hex);
    const expect_hex = std.fmt.bytesToHex(n_bytes, .lower);
    try testing.expectEqualStrings(expect_hex[0..], n_hex);

    const e_hex = try key.e.toString(gpa, 16, .lower);
    defer gpa.free(e_hex);
    try testing.expectEqualStrings("10001", e_hex);
}

test "RSA - 模幂（小数值已知结果）" {
    const gpa = testing.allocator;
    var base = try Managed.initSet(gpa, 4);
    defer base.deinit();
    var exp = try Managed.initSet(gpa, 13);
    defer exp.deinit();
    var m = try Managed.initSet(gpa, 497);
    defer m.deinit();

    var r = try modPow(gpa, &base, &exp, &m);
    defer r.deinit();
    const s = try r.toString(gpa, 10, .lower);
    defer gpa.free(s);
    try testing.expectEqualStrings("445", s); // 4^13 mod 497 = 445
}

test "RSA - OAEP-SHA1 编码可逆（固定种子）" {
    const gpa = testing.allocator;

    // 只验证 OAEP 编码结构：用「伪 RSA」k = 128，跳过模幂，直接解掩码还原
    const k: usize = 128;
    const db_len = k - hLen - 1;
    const msg = "secret-password";

    const seed: [hLen]u8 = @splat(0x5a);
    var lhash: [hLen]u8 = undefined;
    Sha1.hash("", &lhash, .{});

    const db = try gpa.alloc(u8, db_len);
    defer gpa.free(db);
    @memset(db, 0);
    @memcpy(db[0..hLen], &lhash);
    const sep = db_len - msg.len - 1;
    db[sep] = 0x01;
    @memcpy(db[sep + 1 ..], msg);

    const mask = try gpa.alloc(u8, db_len);
    defer gpa.free(mask);
    mgf1(&seed, mask);
    for (db, 0..) |*b, i| b.* ^= mask[i];

    var seed_mask: [hLen]u8 = undefined;
    mgf1(db, &seed_mask);
    var masked_seed: [hLen]u8 = undefined;
    for (0..hLen) |i| masked_seed[i] = seed[i] ^ seed_mask[i];

    // 反解：先还原 seed，再还原 DB
    var back_seed: [hLen]u8 = undefined;
    mgf1(db, &seed_mask);
    for (0..hLen) |i| back_seed[i] = masked_seed[i] ^ seed_mask[i];
    try testing.expectEqualSlices(u8, &seed, &back_seed);

    const back_mask = try gpa.alloc(u8, db_len);
    defer gpa.free(back_mask);
    mgf1(&back_seed, back_mask);
    for (db, 0..) |*b, i| b.* ^= back_mask[i];

    try testing.expectEqualSlices(u8, &lhash, db[0..hLen]);
    // lHash 之后第一个非 0 字节必须是 0x01，且其后就是消息
    var idx: usize = hLen;
    while (idx < db_len and db[idx] == 0) idx += 1;
    try testing.expect(idx < db_len);
    try testing.expectEqual(@as(u8, 0x01), db[idx]);
    try testing.expectEqualStrings(msg, db[idx + 1 ..]);
}
