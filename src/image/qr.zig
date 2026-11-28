//! 二维码生成（QR Code Model 2，**字节模式**，版本 1–10，纠错等级 L/M/Q/H）。
//!
//! 口径：
//! - 输入按 UTF-8 字节直接写入字节模式（中文/emoji 都按字节存，主流扫码器按 UTF-8 解读）；
//! - 自动选择**能装下的最小版本**；掩码按标准罚分（Penalty）自动择优，也可强制指定（测试用）；
//! - 输出 SVG（矢量、无外部依赖），页面与 `/api/qrcode.svg` 共用同一个渲染函数。
//!
//! 参考工程 `GongJu/Controllers/Api/QRCodeController.cs` **整文件被注释**（不可用），
//! 所以本模块是**新增能力**而不是移植；矩阵逐格与 `segno`（MIT，纯 Python）对拍，
//! 参考数据由 `tools/gen-qr-vectors.py` 生成（仅开发期依赖，不随包发布）。
//!
//! 算法结构对齐 Nayuki QR Code generator（MIT）的公开做法：功能图形 → 数据放置（之字形）→
//! 8 种掩码逐一算罚分取最优 → 写入格式信息/版本信息。

const std = @import("std");

/// 纠错等级（与 C# QRCoder 的 `ECCLevel` 同名）。
pub const Level = enum { l, m, q, h };

/// 生成的二维码矩阵（行优先，`true` = 深色模块）。
pub const Matrix = struct {
    size: usize,
    version: u8,
    mask: u3,
    modules: []bool,

    pub fn deinit(self: *Matrix, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
        self.modules = &.{};
    }

    /// 该模块是否为深色（越界返回 false）。
    pub fn isDark(self: *const Matrix, x: usize, y: usize) bool {
        if (x >= self.size or y >= self.size) return false;
        return self.modules[y * self.size + x];
    }
};

pub const Error = error{ Empty, TooLong, OutOfMemory };

/// 支持的最大版本：10（57×57，字节模式 L 级最多 271 字节）——
/// 工具站场景（网址/文本/联系方式）足够，再大就该用短链了。
pub const MAX_VERSION: u8 = 10;

// ————— 纠错分块表（来源：ISO/IEC 18004，经 segno 的 `consts.ECC` 导出核对） —————

const EcBlock = struct { blocks: u8, total: u8, data: u8 };
const EcGroup = struct { a: EcBlock, b: ?EcBlock = null };

/// `[version-1][L,M,Q,H]`；`total` 与 `data` 是**每块**的码字数，两者之差就是每块的纠错码字数。
const ECC_TABLE: [10][4]EcGroup = .{
    .{ .{ .a = .{ .blocks = 1, .total = 26, .data = 19 } }, .{ .a = .{ .blocks = 1, .total = 26, .data = 16 } }, .{ .a = .{ .blocks = 1, .total = 26, .data = 13 } }, .{ .a = .{ .blocks = 1, .total = 26, .data = 9 } } },
    .{ .{ .a = .{ .blocks = 1, .total = 44, .data = 34 } }, .{ .a = .{ .blocks = 1, .total = 44, .data = 28 } }, .{ .a = .{ .blocks = 1, .total = 44, .data = 22 } }, .{ .a = .{ .blocks = 1, .total = 44, .data = 16 } } },
    .{ .{ .a = .{ .blocks = 1, .total = 70, .data = 55 } }, .{ .a = .{ .blocks = 1, .total = 70, .data = 44 } }, .{ .a = .{ .blocks = 2, .total = 35, .data = 17 } }, .{ .a = .{ .blocks = 2, .total = 35, .data = 13 } } },
    .{ .{ .a = .{ .blocks = 1, .total = 100, .data = 80 } }, .{ .a = .{ .blocks = 2, .total = 50, .data = 32 } }, .{ .a = .{ .blocks = 2, .total = 50, .data = 24 } }, .{ .a = .{ .blocks = 4, .total = 25, .data = 9 } } },
    .{ .{ .a = .{ .blocks = 1, .total = 134, .data = 108 } }, .{ .a = .{ .blocks = 2, .total = 67, .data = 43 } }, .{ .a = .{ .blocks = 2, .total = 33, .data = 15 }, .b = .{ .blocks = 2, .total = 34, .data = 16 } }, .{ .a = .{ .blocks = 2, .total = 33, .data = 11 }, .b = .{ .blocks = 2, .total = 34, .data = 12 } } },
    .{ .{ .a = .{ .blocks = 2, .total = 86, .data = 68 } }, .{ .a = .{ .blocks = 4, .total = 43, .data = 27 } }, .{ .a = .{ .blocks = 4, .total = 43, .data = 19 } }, .{ .a = .{ .blocks = 4, .total = 43, .data = 15 } } },
    .{ .{ .a = .{ .blocks = 2, .total = 98, .data = 78 } }, .{ .a = .{ .blocks = 4, .total = 49, .data = 31 } }, .{ .a = .{ .blocks = 2, .total = 32, .data = 14 }, .b = .{ .blocks = 4, .total = 33, .data = 15 } }, .{ .a = .{ .blocks = 4, .total = 39, .data = 13 }, .b = .{ .blocks = 1, .total = 40, .data = 14 } } },
    .{ .{ .a = .{ .blocks = 2, .total = 121, .data = 97 } }, .{ .a = .{ .blocks = 2, .total = 60, .data = 38 }, .b = .{ .blocks = 2, .total = 61, .data = 39 } }, .{ .a = .{ .blocks = 4, .total = 40, .data = 18 }, .b = .{ .blocks = 2, .total = 41, .data = 19 } }, .{ .a = .{ .blocks = 4, .total = 40, .data = 14 }, .b = .{ .blocks = 2, .total = 41, .data = 15 } } },
    .{ .{ .a = .{ .blocks = 2, .total = 146, .data = 116 } }, .{ .a = .{ .blocks = 3, .total = 58, .data = 36 }, .b = .{ .blocks = 2, .total = 59, .data = 37 } }, .{ .a = .{ .blocks = 4, .total = 36, .data = 16 }, .b = .{ .blocks = 4, .total = 37, .data = 17 } }, .{ .a = .{ .blocks = 4, .total = 36, .data = 12 }, .b = .{ .blocks = 4, .total = 37, .data = 13 } } },
    .{ .{ .a = .{ .blocks = 2, .total = 86, .data = 68 }, .b = .{ .blocks = 2, .total = 87, .data = 69 } }, .{ .a = .{ .blocks = 4, .total = 69, .data = 43 }, .b = .{ .blocks = 1, .total = 70, .data = 44 } }, .{ .a = .{ .blocks = 6, .total = 43, .data = 19 }, .b = .{ .blocks = 2, .total = 44, .data = 20 } }, .{ .a = .{ .blocks = 6, .total = 43, .data = 15 }, .b = .{ .blocks = 2, .total = 44, .data = 16 } } },
};

/// 对齐图形中心坐标（下标 = 版本 - 1；v1 无对齐图形）。
const ALIGNMENT_POS: [MAX_VERSION][]const u8 = .{
    &.{}, // v1
    &.{ 6, 18 },
    &.{ 6, 22 },
    &.{ 6, 26 },
    &.{ 6, 30 },
    &.{ 6, 34 },
    &.{ 6, 22, 38 },
    &.{ 6, 24, 42 },
    &.{ 6, 26, 46 },
    &.{ 6, 28, 50 },
};

fn levelIndex(level: Level) usize {
    return switch (level) {
        .l => 0,
        .m => 1,
        .q => 2,
        .h => 3,
    };
}

fn dataCodewords(version: u8, level: Level) usize {
    const group = ECC_TABLE[version - 1][levelIndex(level)];
    var total: usize = @as(usize, group.a.blocks) * group.a.data;
    if (group.b) |b| total += @as(usize, b.blocks) * b.data;
    return total;
}

fn charCountBits(version: u8) usize {
    return if (version <= 9) 8 else 16;
}

/// 该版本 + 等级下字节模式的**最大内容字节数**。
pub fn capacityBytes(version: u8, level: Level) usize {
    const bits = dataCodewords(version, level) * 8;
    const overhead = 4 + charCountBits(version);
    if (bits <= overhead) return 0;
    return (bits - overhead) / 8;
}

/// 编码（自动选最小版本 + 自动选掩码）。
pub fn encode(allocator: std.mem.Allocator, text: []const u8, level: Level) Error!Matrix {
    if (text.len == 0) return error.Empty;
    var version: u8 = 1;
    while (version <= MAX_VERSION) : (version += 1) {
        if (text.len <= capacityBytes(version, level)) break;
    } else {
        return error.TooLong;
    }
    return encodeVersionMask(allocator, text, level, version, null);
}

/// 编码到指定版本/掩码（`mask = null` 表示自动择优；测试用固定 mask 与参考实现逐格对拍）。
pub fn encodeVersionMask(
    allocator: std.mem.Allocator,
    text: []const u8,
    level: Level,
    version: u8,
    forced_mask: ?u3,
) Error!Matrix {
    if (text.len == 0) return error.Empty;
    if (version < 1 or version > MAX_VERSION) return error.TooLong;
    if (text.len > capacityBytes(version, level)) return error.TooLong;

    const codewords = try buildCodewords(allocator, text, level, version);
    defer allocator.free(codewords);

    return buildMatrix(allocator, version, level, codewords, forced_mask);
}

/// 生成最终码字（数据 + 纠错 + 交错）。公开是为了让单测/对拍脚本能逐字节核对。
pub fn buildCodewords(
    allocator: std.mem.Allocator,
    text: []const u8,
    level: Level,
    version: u8,
) Error![]u8 {
    var buffer = BitBuffer{};
    defer buffer.bytes.deinit(allocator);
    const data_cw = dataCodewords(version, level);
    const capacity_bits = data_cw * 8;

    try buffer.appendBits(allocator, 0b0100, 4); // 字节模式
    try buffer.appendBits(allocator, @intCast(text.len), @intCast(charCountBits(version)));
    for (text) |byte| try buffer.appendBits(allocator, byte, 8);

    const remaining = capacity_bits - buffer.bit_len;
    const terminator = @min(@as(usize, 4), remaining);
    try buffer.appendBits(allocator, 0, @intCast(terminator));
    const pad_bits = (8 - (buffer.bit_len % 8)) % 8;
    if (pad_bits != 0) try buffer.appendBits(allocator, 0, @intCast(pad_bits));

    var pad_even = false;
    while (buffer.bytes.items.len < data_cw) {
        try buffer.appendBits(allocator, if (pad_even) 0x11 else 0xEC, 8);
        pad_even = !pad_even;
    }

    return interleave(allocator, buffer.bytes.items, version, level);
}

// ————— 位缓冲 —————

const BitBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_len: usize = 0,

    fn appendBits(self: *BitBuffer, allocator: std.mem.Allocator, value: u32, count: u5) !void {
        var left: u5 = count;
        while (left > 0) {
            left -= 1;
            const bit = (value >> left) & 1;
            const byte_index = self.bit_len / 8;
            if (byte_index == self.bytes.items.len) try self.bytes.append(allocator, 0);
            if (bit != 0) {
                const shift: u3 = @intCast(7 - (self.bit_len % 8));
                self.bytes.items[byte_index] |= @as(u8, 1) << shift;
            }
            self.bit_len += 1;
        }
    }
};

// ————— Reed–Solomon（GF(256)，本原多项式 0x11D） —————

const GF_EXP: [512]u8 = blk: {
    var exp: [512]u8 = undefined;
    var value: u16 = 1;
    for (0..255) |i| {
        exp[i] = @intCast(value);
        value <<= 1;
        if (value >= 0x100) value ^= 0x11D;
    }
    for (255..512) |i| exp[i] = exp[i - 255];
    break :blk exp;
};

const GF_LOG: [256]u8 = blk: {
    var log: [256]u8 = undefined;
    var value: u16 = 1;
    for (0..255) |i| {
        log[value] = @intCast(i);
        value <<= 1;
        if (value >= 0x100) value ^= 0x11D;
    }
    log[0] = 0; // 未使用（乘法里单独处理 0）
    break :blk log;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    const sum = @as(usize, GF_LOG[a]) + @as(usize, GF_LOG[b]);
    return GF_EXP[sum];
}

/// 计算 `degree` 次的生成多项式（返回 `degree` 个系数，首项 1 省略）。
fn rsDivisor(degree: usize) [256]u8 {
    var result: [256]u8 = @splat(0);
    result[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            result[j] = gfMul(result[j], root);
            if (j + 1 < degree) result[j] ^= result[j + 1];
        }
        root = gfMul(root, 2);
    }
    return result;
}

fn rsRemainder(data: []const u8, divisor: []const u8, out: []u8) void {
    @memset(out, 0);
    for (data) |byte| {
        const factor = byte ^ out[0];
        if (out.len > 1) std.mem.copyForwards(u8, out[0 .. out.len - 1], out[1..]);
        out[out.len - 1] = 0;
        for (divisor, 0..) |coeff, i| out[i] ^= gfMul(coeff, factor);
    }
}

/// 分块 + 计算纠错 + 交错，返回总码字（数据码字 + 纠错码字）。
fn interleave(allocator: std.mem.Allocator, data: []const u8, version: u8, level: Level) ![]u8 {
    const group = ECC_TABLE[version - 1][levelIndex(level)];
    const first_count: usize = group.a.blocks;
    const second_count: usize = if (group.b) |b| b.blocks else 0;
    const block_count = first_count + second_count;
    const ec_len: usize = @as(usize, group.a.total) - group.a.data;

    var data_sizes: [64]usize = undefined;
    var index: usize = 0;
    for (0..first_count) |_| {
        data_sizes[index] = group.a.data;
        index += 1;
    }
    if (group.b) |b| {
        for (0..second_count) |_| {
            data_sizes[index] = b.data;
            index += 1;
        }
    }

    const divisor_storage = rsDivisor(ec_len);
    const divisor = divisor_storage[0..ec_len];

    const blocks = try allocator.alloc([]u8, block_count);
    defer allocator.free(blocks);
    var created: usize = 0;
    defer for (blocks[0..created]) |block| allocator.free(block);

    var offset: usize = 0;
    for (0..block_count) |i| {
        const size = data_sizes[i];
        const block = try allocator.alloc(u8, size + ec_len);
        created += 1;
        @memcpy(block[0..size], data[offset .. offset + size]);
        offset += size;
        rsRemainder(block[0..size], divisor, block[size..]);
        blocks[i] = block;
    }

    const total: usize = dataCodewords(version, level) + ec_len * block_count;
    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    var max_data: usize = 0;
    for (data_sizes[0..block_count]) |size| max_data = @max(max_data, size);
    for (0..max_data) |column| {
        for (blocks, 0..) |block, i| {
            if (column < data_sizes[i]) {
                out[pos] = block[column];
                pos += 1;
            }
        }
    }
    for (0..ec_len) |column| {
        for (blocks, 0..) |block, i| {
            out[pos] = block[data_sizes[i] + column];
            pos += 1;
        }
    }
    std.debug.assert(pos == total);
    return out;
}

// ————— 矩阵构建 —————

const Builder = struct {
    size: usize,
    modules: []bool,
    is_function: []bool,

    fn init(allocator: std.mem.Allocator, size: usize) !Builder {
        const modules = try allocator.alloc(bool, size * size);
        @memset(modules, false);
        const is_function = try allocator.alloc(bool, size * size);
        @memset(is_function, false);
        return .{ .size = size, .modules = modules, .is_function = is_function };
    }

    fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
        allocator.free(self.is_function);
    }

    fn setFunction(self: *Builder, x: usize, y: usize, dark: bool) void {
        if (x >= self.size or y >= self.size) return;
        self.modules[y * self.size + x] = dark;
        self.is_function[y * self.size + x] = true;
    }

    fn isReserved(self: *const Builder, x: usize, y: usize) bool {
        return self.is_function[y * self.size + x];
    }

    fn drawFinder(self: *Builder, cx: usize, cy: usize) void {
        var dy: isize = -4;
        while (dy <= 4) : (dy += 1) {
            var dx: isize = -4;
            while (dx <= 4) : (dx += 1) {
                const x = @as(isize, @intCast(cx)) + dx;
                const y = @as(isize, @intCast(cy)) + dy;
                if (x < 0 or y < 0) continue;
                const dist = @max(@abs(dx), @abs(dy));
                self.setFunction(@intCast(x), @intCast(y), dist != 2 and dist != 4);
            }
        }
    }

    fn drawAlignment(self: *Builder, cx: usize, cy: usize) void {
        var dy: isize = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: isize = -2;
            while (dx <= 2) : (dx += 1) {
                const x = @as(isize, @intCast(cx)) + dx;
                const y = @as(isize, @intCast(cy)) + dy;
                if (x < 0 or y < 0) continue;
                const dist = @max(@abs(dx), @abs(dy));
                self.setFunction(@intCast(x), @intCast(y), dist != 1);
            }
        }
    }

    fn drawFormat(self: *Builder, level: Level, mask: u3) void {
        const bits = formatBits(level, mask);
        // 第一份拷贝（左上角）
        for (0..6) |i| self.setFunction(8, i, bitAt(bits, @intCast(i)));
        self.setFunction(8, 7, bitAt(bits, 6));
        self.setFunction(8, 8, bitAt(bits, 7));
        self.setFunction(7, 8, bitAt(bits, 8));
        for (9..15) |i| self.setFunction(14 - i, 8, bitAt(bits, @intCast(i)));
        // 第二份拷贝（右上 + 左下）
        for (0..8) |i| self.setFunction(self.size - 1 - i, 8, bitAt(bits, @intCast(i)));
        for (8..15) |i| self.setFunction(8, self.size - 15 + i, bitAt(bits, @intCast(i)));
        self.setFunction(8, self.size - 8, true); // 恒深色模块
    }

    fn drawVersion(self: *Builder, version: u8) void {
        if (version < 7) return;
        const bits = versionBits(version);
        var i: usize = 0;
        while (i < 18) : (i += 1) {
            const dark = bitAt(bits, @intCast(i));
            const a = self.size - 11 + i % 3;
            const b = i / 3;
            self.setFunction(a, b, dark);
            self.setFunction(b, a, dark);
        }
    }
};

fn bitAt(value: anytype, index: u5) bool {
    const unsigned: u32 = @intCast(value);
    return (unsigned >> index) & 1 == 1;
}

/// 15 位格式信息：2 位等级 + 3 位掩码 + 10 位 BCH(0x537)，再异或 0x5412。
fn formatBits(level: Level, mask: u3) u15 {
    const level_bits: u15 = switch (level) {
        .l => 1,
        .m => 0,
        .q => 3,
        .h => 2,
    };
    const data: u15 = (level_bits << 3) | mask;
    var rem: u32 = @as(u32, data) << 10;
    var bit: u5 = 14;
    while (bit >= 10) : (bit -= 1) {
        if ((rem >> bit) & 1 == 1) rem ^= @as(u32, 0x537) << (bit - 10);
    }
    const bits: u32 = (@as(u32, data) << 10) | (rem & 0x3FF);
    return @intCast(bits ^ 0x5412);
}

/// 18 位版本信息（v7+）：6 位版本 + 12 位 BCH(0x1F25)。
fn versionBits(version: u8) u18 {
    var rem: u32 = version;
    for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return @intCast((@as(u32, version) << 12) | (rem & 0xFFF));
}

fn buildMatrix(
    allocator: std.mem.Allocator,
    version: u8,
    level: Level,
    codewords: []const u8,
    forced_mask: ?u3,
) !Matrix {
    const size: usize = 17 + 4 * @as(usize, version);

    var base = try Builder.init(allocator, size);
    defer base.deinit(allocator);

    // 定时图形：**必须先画**，随后由定位图形覆盖掉穿过「回」字的那些模块
    // （顺序反了会定时图形盖掉定位图形的边，整张码扫不出来；2026-11-23 对拍时踩过）
    drawFunctionPatterns(&base, version, level);

    // 数据放置（之字形，两列一组，跳过第 6 列）
    var bit_index: usize = 0;
    const total_bits = codewords.len * 8;
    var right: isize = @as(isize, @intCast(size)) - 1;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;
        var vert: usize = 0;
        while (vert < size) : (vert += 1) {
            for (0..2) |j| {
                const x: usize = @intCast(right - @as(isize, @intCast(j)));
                const upward = ((right + 1) & 2) == 0;
                const y: usize = if (upward) size - 1 - vert else vert;
                if (!base.isReserved(x, y) and bit_index < total_bits) {
                    const byte = codewords[bit_index / 8];
                    const shift: u3 = @intCast(7 - (bit_index % 8));
                    base.modules[y * size + x] = (byte >> shift) & 1 == 1;
                    bit_index += 1;
                }
            }
        }
    }

    // 选掩码：强制指定或按罚分择优
    const chosen = forced_mask orelse try pickBestMask(allocator, &base, level, version, size);

    // 用选定的掩码重建最终矩阵，再写入格式信息/版本信息（它们不参与掩码）
    const final_modules = try allocator.alloc(bool, size * size);
    @memcpy(final_modules, base.modules);
    var result = Matrix{ .size = size, .version = version, .mask = chosen, .modules = final_modules };
    applyMask(&result, &base, chosen);

    var finisher = try Builder.init(allocator, size);
    defer finisher.deinit(allocator);
    @memcpy(finisher.modules, result.modules);
    @memcpy(finisher.is_function, base.is_function);
    finisher.drawFormat(level, chosen);
    finisher.drawVersion(version);
    @memcpy(result.modules, finisher.modules);
    return result;
}

/// 画功能图形（定时 → 定位 → 对齐 → 格式/版本占位）。
///
/// 顺序很重要：**定时图形先画**，再由定位图形覆盖穿过「回」字的模块；
/// 反过来会定时盖掉定位边，整张码扫不出来（2026-11-23 对拍踩过）。
fn drawFunctionPatterns(b: *Builder, version: u8, level: Level) void {
    const size = b.size;
    for (0..size) |i| {
        b.setFunction(6, i, i % 2 == 0);
        b.setFunction(i, 6, i % 2 == 0);
    }
    b.drawFinder(3, 3);
    b.drawFinder(size - 4, 3);
    b.drawFinder(3, size - 4);

    const positions = ALIGNMENT_POS[version - 1];
    for (positions) |cx| {
        for (positions) |cy| {
            const overlaps_finder = (cx == 6 and cy == 6) or
                (cx == 6 and cy == size - 7) or
                (cx == size - 7 and cy == 6);
            if (overlaps_finder) continue;
            b.drawAlignment(cx, cy);
        }
    }

    // 格式区/版本区先占位（真正的位在掩码确定后再写）
    b.drawFormat(level, 0);
    b.drawVersion(version);
}

/// 调试/对拍用：返回功能模块占位图（`true` = 功能模块），行优先。
pub fn debugFunctionMap(allocator: std.mem.Allocator, version: u8) Error![]bool {
    const size: usize = 17 + 4 * @as(usize, version);
    var b = try Builder.init(allocator, size);
    defer b.deinit(allocator);
    drawFunctionPatterns(&b, version, .m);
    return allocator.dupe(bool, b.is_function);
}

/// 在 8 个掩码里按罚分挑一个（平局取编号小者）。
fn pickBestMask(
    allocator: std.mem.Allocator,
    base: *const Builder,
    level: Level,
    version: u8,
    size: usize,
) !u3 {
    var best: u3 = 0;
    var best_score: u32 = std.math.maxInt(u32);
    var mask: u3 = 0;
    while (true) {
        const modules = try allocator.alloc(bool, size * size);
        defer allocator.free(modules);
        @memcpy(modules, base.modules);
        var matrix = Matrix{ .size = size, .version = version, .mask = mask, .modules = modules };
        applyMask(&matrix, base, mask);
        // 罚分要在**带格式信息**的完整图上算（格式信息本身也影响连续色块）
        var trial = try Builder.init(allocator, size);
        defer trial.deinit(allocator);
        @memcpy(trial.modules, modules);
        @memcpy(trial.is_function, base.is_function);
        trial.drawFormat(level, mask);
        trial.drawVersion(version);
        const score = penalty(trial.modules, size);
        if (score < best_score) {
            best_score = score;
            best = mask;
        }
        if (mask == 7) break;
        mask += 1;
    }
    return best;
}

fn applyMask(matrix: *Matrix, base: *const Builder, mask: u3) void {
    const size = matrix.size;
    for (0..size) |y| {
        for (0..size) |x| {
            if (base.isReserved(x, y)) continue;
            const xi = @as(u32, @intCast(x));
            const yi = @as(u32, @intCast(y));
            const invert = switch (mask) {
                0 => (xi + yi) % 2 == 0,
                1 => yi % 2 == 0,
                2 => xi % 3 == 0,
                3 => (xi + yi) % 3 == 0,
                4 => (xi / 3 + yi / 2) % 2 == 0,
                5 => xi * yi % 2 + xi * yi % 3 == 0,
                6 => (xi * yi % 2 + xi * yi % 3) % 2 == 0,
                7 => ((xi + yi) % 2 + xi * yi % 3) % 2 == 0,
            };
            if (invert) matrix.modules[y * size + x] = !matrix.modules[y * size + x];
        }
    }
}

/// 标准罚分（N1 连续色块 / N2 2×2 同色 / N3 定位样式 / N4 深色比例）。
fn penalty(modules: []const bool, size: usize) u32 {
    var score: u32 = 0;

    // N1：行、列连续同色 ≥ 5
    for (0..size) |y| {
        var run: usize = 1;
        for (1..size) |x| {
            if (modules[y * size + x] == modules[y * size + x - 1]) {
                run += 1;
            } else {
                if (run >= 5) score += 3 + @as(u32, @intCast(run - 5));
                run = 1;
            }
        }
        if (run >= 5) score += 3 + @as(u32, @intCast(run - 5));
    }
    for (0..size) |x| {
        var run: usize = 1;
        for (1..size) |y| {
            if (modules[y * size + x] == modules[(y - 1) * size + x]) {
                run += 1;
            } else {
                if (run >= 5) score += 3 + @as(u32, @intCast(run - 5));
                run = 1;
            }
        }
        if (run >= 5) score += 3 + @as(u32, @intCast(run - 5));
    }

    // N2：2×2 同色块
    for (0..size - 1) |y| {
        for (0..size - 1) |x| {
            const a = modules[y * size + x];
            if (a == modules[y * size + x + 1] and
                a == modules[(y + 1) * size + x] and
                a == modules[(y + 1) * size + x + 1])
            {
                score += 3;
            }
        }
    }

    // N3：1:1:3:1:1 定位样式（两侧带 4 个浅色）
    const pattern_a = [_]bool{ true, false, true, true, true, false, true, false, false, false, false };
    const pattern_b = [_]bool{ false, false, false, false, true, false, true, true, true, false, true };
    for (0..size) |y| {
        var x: usize = 0;
        while (x + 11 <= size) : (x += 1) {
            var match_a = true;
            var match_b = true;
            for (0..11) |k| {
                const value = modules[y * size + x + k];
                if (value != pattern_a[k]) match_a = false;
                if (value != pattern_b[k]) match_b = false;
            }
            if (match_a) score += 40;
            if (match_b) score += 40;
        }
    }
    for (0..size) |x| {
        var y: usize = 0;
        while (y + 11 <= size) : (y += 1) {
            var match_a = true;
            var match_b = true;
            for (0..11) |k| {
                const value = modules[(y + k) * size + x];
                if (value != pattern_a[k]) match_a = false;
                if (value != pattern_b[k]) match_b = false;
            }
            if (match_a) score += 40;
            if (match_b) score += 40;
        }
    }

    // N4：深色比例偏离 50%
    var dark: usize = 0;
    for (modules) |module| {
        if (module) dark += 1;
    }
    const total = size * size;
    const percent = (dark * 100) / total; // 0..100
    const deviation = if (percent > 50) percent - 50 else 50 - percent;
    score += @as(u32, @intCast(deviation / 5)) * 10;

    return score;
}

// ————— SVG 输出 —————

/// 深色模块的形状（「变形二维码」）。注意：**越偏离方块越难扫**，
/// 页面默认仍是方块；选圆点/圆角时建议把纠错等级提到 Q/H。
pub const Shape = enum { square, rounded, circle };

/// 前景色白名单（固定色板 —— 绝不把请求里的字符串拼进 SVG，避免注入）。
pub const Color = enum { black, blue, green, red, purple };

pub const Style = struct {
    shape: Shape = .square,
    fg: Color = .black,
    /// 是否给码体加投影（SVG `feDropShadow`；只影响观感，不影响模块本身）
    shadow: bool = false,
};

fn colorHex(color: Color) []const u8 {
    return switch (color) {
        .black => "#000000",
        .blue => "#1e3a8a",
        .green => "#065f46",
        .red => "#7f1d1d",
        .purple => "#5b21b6",
    };
}

/// 渲染为 SVG（默认样式：方块 + 黑色，向后兼容旧调用）。
pub fn renderSvg(
    allocator: std.mem.Allocator,
    matrix: *const Matrix,
    scale: u8,
    border: u8,
) ![]u8 {
    return renderSvgStyled(allocator, matrix, scale, border, .{});
}

/// 渲染为 SVG。坐标统一放大 2 倍（`viewBox` 单位），这样圆角/圆点都能用整数表达，
/// 不依赖浮点格式化。
pub fn renderSvgStyled(
    allocator: std.mem.Allocator,
    matrix: *const Matrix,
    scale: u8,
    border: u8,
    style: Style,
) ![]u8 {
    const dim = matrix.size + 2 * @as(usize, border);
    const pixels = dim * scale;
    const units = dim * 2;
    const fg = colorHex(style.fg);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" shape-rendering=\"geometricPrecision\" role=\"img\" aria-label=\"二维码\">",
        .{ pixels, pixels, units, units },
    );
    if (style.shadow) {
        try out.appendSlice(allocator, "<defs><filter id=\"qr-shadow\" x=\"-10%\" y=\"-10%\" width=\"130%\" height=\"130%\">" ++
            "<feDropShadow dx=\"0\" dy=\"4\" stdDeviation=\"4\" flood-color=\"#000000\" flood-opacity=\"0.30\"/>" ++
            "</filter></defs>");
    }
    try out.appendSlice(allocator, "<rect width=\"100%\" height=\"100%\" fill=\"#ffffff\"/>");
    if (style.shadow) {
        try out.appendSlice(allocator, "<g filter=\"url(#qr-shadow)\">");
    }
    try out.print(allocator, "<g fill=\"{s}\">", .{fg});

    switch (style.shape) {
        .square => try emitSquarePath(allocator, &out, matrix, border),
        .rounded, .circle => try emitStyledModules(allocator, &out, matrix, border, style.shape),
    }

    try out.appendSlice(allocator, "</g>");
    if (style.shadow) try out.appendSlice(allocator, "</g>");
    try out.appendSlice(allocator, "</svg>");
    return out.toOwnedSlice(allocator);
}

/// 方块样式：按行合并连续深色模块为一条路径（体积最小）。
fn emitSquarePath(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    matrix: *const Matrix,
    border: u8,
) !void {
    try out.appendSlice(allocator, "<path d=\"");
    for (0..matrix.size) |y| {
        var x: usize = 0;
        while (x < matrix.size) {
            if (!matrix.isDark(x, y)) {
                x += 1;
                continue;
            }
            var run: usize = 1;
            while (x + run < matrix.size and matrix.isDark(x + run, y)) run += 1;
            const px = (x + border) * 2;
            const py = (y + border) * 2;
            try out.print(allocator, "M{d} {d}h{d}v2h-{d}z", .{ px, py, run * 2, run * 2 });
            x += run;
        }
    }
    try out.appendSlice(allocator, "\"/>");
}

fn inFinderArea(size: usize, x: usize, y: usize) bool {
    const left = x < 7;
    const right = x >= size - 7;
    const top = y < 7;
    const bottom = y >= size - 7;
    return (left and top) or (right and top) or (left and bottom);
}

/// 圆角/圆点样式：数据模块逐个画，三个定位图形单独画成「圆角框 + 圆点」，
/// 这样即使模块变圆，「回」字结构依然清晰（扫码器主要靠它定位）。
fn emitStyledModules(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    matrix: *const Matrix,
    border: u8,
    shape: Shape,
) !void {
    const size = matrix.size;
    for (0..size) |y| {
        for (0..size) |x| {
            if (!matrix.isDark(x, y)) continue;
            if (inFinderArea(size, x, y)) continue;
            const px = (x + border) * 2;
            const py = (y + border) * 2;
            if (shape == .circle) {
                try out.print(allocator, "<circle cx=\"{d}\" cy=\"{d}\" r=\"1\"/>", .{ px + 1, py + 1 });
            } else {
                try out.print(allocator, "<rect x=\"{d}\" y=\"{d}\" width=\"2\" height=\"2\" rx=\"1\"/>", .{ px, py });
            }
        }
    }

    // 三个定位图形（外 7×7 + 内白 5×5 + 中心 3×3）
    const corners = [_][2]usize{
        .{ 0, 0 },
        .{ size - 7, 0 },
        .{ 0, size - 7 },
    };
    for (corners) |corner| {
        const cx = (corner[0] + border) * 2;
        const cy = (corner[1] + border) * 2;
        if (shape == .circle) {
            try out.print(allocator, "<circle cx=\"{d}\" cy=\"{d}\" r=\"7\"/>", .{ cx + 7, cy + 7 });
            try out.print(allocator, "<circle cx=\"{d}\" cy=\"{d}\" r=\"5\" fill=\"#ffffff\"/>", .{ cx + 7, cy + 7 });
            try out.print(allocator, "<circle cx=\"{d}\" cy=\"{d}\" r=\"3\"/>", .{ cx + 7, cy + 7 });
        } else {
            try out.print(allocator, "<rect x=\"{d}\" y=\"{d}\" width=\"14\" height=\"14\" rx=\"4\"/>", .{ cx, cy });
            try out.print(allocator, "<rect x=\"{d}\" y=\"{d}\" width=\"10\" height=\"10\" rx=\"3\" fill=\"#ffffff\"/>", .{ cx + 2, cy + 2 });
            try out.print(allocator, "<rect x=\"{d}\" y=\"{d}\" width=\"6\" height=\"6\" rx=\"2\"/>", .{ cx + 4, cy + 4 });
        }
    }
}

// ————— 单测 —————

const testing = std.testing;

test "zzig.qr：容量与版本选择（v1-L 17 字节、v10-L 271 字节）" {
    try testing.expectEqual(@as(usize, 17), capacityBytes(1, .l));
    try testing.expectEqual(@as(usize, 14), capacityBytes(1, .m));
    try testing.expectEqual(@as(usize, 7), capacityBytes(1, .h));
    try testing.expectEqual(@as(usize, 271), capacityBytes(10, .l));
    const long = try testing.allocator.alloc(u8, 272);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(error.TooLong, encode(testing.allocator, long, .l));
    try testing.expectError(error.Empty, encode(testing.allocator, "", .l));
}

test "zzig.qr：矩阵与参考实现逐格一致（固定 mask）" {
    const a = testing.allocator;
    const cases = [_]struct { text: []const u8, level: Level, version: u8, mask: u3, rows: []const []const u8 }{
        .{ .text = "HELLO WORLD", .level = .l, .version = 1, .mask = 0, .rows = &_qr_hello },
        .{ .text = "Hi 你好", .level = .q, .version = 2, .mask = 3, .rows = &_qr_hi_zh },
        .{ .text = "https://example.com/qr?x=1", .level = .m, .version = 3, .mask = 5, .rows = &_qr_url },
    };
    for (cases) |case| {
        var matrix = try encodeVersionMask(a, case.text, case.level, case.version, case.mask);
        defer matrix.deinit(a);
        try testing.expectEqual(case.rows.len, matrix.size);
        for (case.rows, 0..) |row, y| {
            try testing.expectEqual(case.rows.len, row.len);
            for (row, 0..) |ch, x| {
                const expected = ch == '1';
                if (matrix.isDark(x, y) != expected) {
                    std.debug.print("qr mismatch {s} row={d} col={d} expected={} got={}\n", .{
                        case.text, y, x, expected, matrix.isDark(x, y),
                    });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "zzig.qr：自动掩码结果可复现（auto 与显式同 mask 逐格一致）" {
    // 为什么不对拍「参考实现选的 mask」：segno 与 python-qrcode 的罚分实现细节互不相同
    // （segno 还会多写一个 0x00 填充码字），挑出的掩码本来就可能是 3/5/7 vs 3/4/0。
    // 这里保证的是：auto 选出的 mask 与显式指定同一 mask 时结果完全一致（可复现）。
    const a = testing.allocator;
    const cases = [_]struct { text: []const u8, level: Level, version: u8 }{
        .{ .text = "HELLO WORLD", .level = .l, .version = 1 },
        .{ .text = "Hi 你好", .level = .q, .version = 2 },
        .{ .text = "https://example.com/qr?x=1", .level = .m, .version = 3 },
    };
    for (cases) |case| {
        var auto = try encodeVersionMask(a, case.text, case.level, case.version, null);
        defer auto.deinit(a);
        var explicit = try encodeVersionMask(a, case.text, case.level, case.version, auto.mask);
        defer explicit.deinit(a);
        try testing.expectEqual(auto.size, explicit.size);
        try testing.expectEqualSlices(bool, auto.modules, explicit.modules);
    }
}

test "zzig.qr：SVG 结构完整（含 viewBox 与深色路径）" {
    const a = testing.allocator;
    var matrix = try encode(a, "test", .m);
    defer matrix.deinit(a);
    const svg = try renderSvg(a, &matrix, 6, 4);
    defer a.free(svg);
    try testing.expect(std.mem.startsWith(u8, svg, "<svg "));
    try testing.expect(std.mem.endsWith(u8, svg, "</svg>"));
    try testing.expect(std.mem.indexOf(u8, svg, "viewBox=") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "<g fill=\"#000000\"><path d=\"M") != null);
}

test "zzig.qr：圆形/圆角/阴影样式输出对应元素" {
    const a = testing.allocator;
    var matrix = try encode(a, "style", .q);
    defer matrix.deinit(a);

    const circle = try renderSvgStyled(a, &matrix, 8, 4, .{ .shape = .circle, .fg = .blue, .shadow = true });
    defer a.free(circle);
    try testing.expect(std.mem.indexOf(u8, circle, "<circle ") != null);
    try testing.expect(std.mem.indexOf(u8, circle, "feDropShadow") != null);
    try testing.expect(std.mem.indexOf(u8, circle, "#1e3a8a") != null);

    const rounded = try renderSvgStyled(a, &matrix, 8, 4, .{ .shape = .rounded });
    defer a.free(rounded);
    try testing.expect(std.mem.indexOf(u8, rounded, "rx=\"1\"") != null);
}

// 参考矩阵（由 `tools/gen-qr-vectors.py` 生成；矩阵来源 python-qrcode（BSD），
// ECC 分块表来源 segno（MIT）—— 两者都只用于开发期对拍）
// 'HELLO WORLD' level=L version=1 mask=0 size=21
const _qr_hello = [_][]const u8{
    "111111100101101111111",
    "100000100111001000001",
    "101110101101101011101",
    "101110100101001011101",
    "101110100010101011101",
    "100000100000101000001",
    "111111101010101111111",
    "000000001101100000000",
    "111011111111011000100",
    "100110000010001100010",
    "011111101010110111111",
    "111000010110000010010",
    "110110111010111110100",
    "000000001001010000110",
    "111111101011000110111",
    "100000101001100100001",
    "101110101001001010100",
    "101110100101001110110",
    "101110101000101010101",
    "100000101001000010010",
    "111111101001101100111",
};

// 'Hi 你好' level=Q version=2 mask=3 size=25
const _qr_hi_zh = [_][]const u8{
    "1111111001001111001111111",
    "1000001010000100101000001",
    "1011101010101000101011101",
    "1011101000010011001011101",
    "1011101001111010101011101",
    "1000001001101101101000001",
    "1111111010101010101111111",
    "0000000001110001100000000",
    "0111011001010101000000110",
    "0101110011100111001001000",
    "1010001001011100101110010",
    "0101010110001000101011010",
    "0000011110000011010111100",
    "0101010111001010110001011",
    "0111101110110011100000110",
    "1001110001101010111101101",
    "0010101100010101111111111",
    "0000000011100011100011000",
    "1111111000000101101010011",
    "1000001010110000100010100",
    "1011101000000000111110001",
    "1011101010010010001011001",
    "1011101010011010000000010",
    "1000001011100000111001000",
    "1111111000000010100101111",
};

// 'https://example.com/qr?x=1' level=M version=3 mask=5 size=29
const _qr_url = [_][]const u8{
    "11111110001000011000101111111",
    "10000010100001101100001000001",
    "10111010100001010001001011101",
    "10111010110000001100001011101",
    "10111010011010011101101011101",
    "10000010000100010010101000001",
    "11111110101010101010101111111",
    "00000000110100111010000000000",
    "10000010101010001110111001110",
    "11100101011111001101010110110",
    "00010110010011111000110110000",
    "11100100010001000001100101000",
    "11111110110011011010101100001",
    "00010001010010001001001110011",
    "01100111101110000010101111100",
    "01111101000000010000001010101",
    "00000110110000001011000001100",
    "10001101110011100111101110111",
    "11001110011110010001001111001",
    "10010000100111000111110000000",
    "10110010000010110001111110111",
    "00000000111000100010100011000",
    "11111110001000000011101011100",
    "10000010010100111001100010001",
    "10111010001001100111111111010",
    "10111010011110100101100101110",
    "10111010001110011100011111110",
    "10000010001110001110010111101",
    "11111110100010110001011110100",
};
