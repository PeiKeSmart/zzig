//! Data Matrix（ECC200）编码器 —— 工业标识最常用的二维条码。
//!
//! 为什么加它：制造业零件标识、电子元件、DPM（直接在零件上打标）、小尺寸标签
//! 基本都用 Data Matrix 而不是 QR —— 同样数据量下更小、无静区也能扫、对低对比度更耐受。
//!
//! 实现范围（够工具站用，且每条都有测试守着）：
//! - **ANSI/AIM ECC200 正方形符号** 10×10 … 144×144（24 种，见 `SYMBOLS`）；
//! - **ASCII 模式**：数字对压缩（`00`~`99` → 130…229）、单字节（`c+1`）、
//!   上移模式（≥128 的字节写成 `235, c-127`）；
//! - 文本含非 ASCII 时自动加 **ECI 000026（UTF-8）** 前缀（`241, 26`），
//!   这样扫码器会按 UTF-8 解码中文，而不是当成 Latin-1 出乱码；
//! - Reed-Solomon 纠错走 **GF(256) / 本原多项式 0x12D**（注意：**与 QR 的 0x11D 不是同一个域**），
//!   52×52 以上按标准**分块 + 交错**（`block_data` / `block_ecc`）；
//! - 输出直接复用 `qr_tool.Matrix`，SVG 渲染那一套（形状/颜色/投影）零改动。
//!
//! 不在范围内（需要时再加）：矩形符号、C40/Text/Base256 压缩、结构化追加、Micro QR 等。
//!
//! 摆放算法是 ISO/IEC 16022 Annex M.1 的「Default Placement」：
//! ① 在**虚拟数据区**（只有数据模块）里沿 Utah 形路径铺码字，遇 4 个特殊角换成 corner1..4；
//! ② 再把虚拟数据区嵌进物理矩阵，逐区域补 L 形实线边与深浅交替的时钟轨。

const std = @import("std");
const qr = @import("qr.zig");

pub const Matrix = qr.Matrix;

pub const Error = error{ Empty, TooLong, OutOfMemory };

/// ECC200 正方形符号规格（ISO/IEC 16022 表 7）。
pub const Symbol = struct {
    /// 含 L 形定位边与时钟轨的总边长
    size: usize,
    /// 数据码字数
    data: usize,
    /// 纠错码字数
    ecc: usize,
    /// 每边的区域个数（1 / 2 / 4 / 6，正方形布局）
    regions: usize,
    /// 单个区域的数据边长（不含定位边与时钟轨）
    region_size: usize,
    /// 单个 RS 块的数据码字数
    block_data: usize,
    /// 单个 RS 块的纠错码字数（`ecc / block_ecc` 就是块数）
    block_ecc: usize,
};

pub const SYMBOLS = [_]Symbol{
    .{ .size = 10, .data = 3, .ecc = 5, .regions = 1, .region_size = 8, .block_data = 3, .block_ecc = 5 },
    .{ .size = 12, .data = 5, .ecc = 7, .regions = 1, .region_size = 10, .block_data = 5, .block_ecc = 7 },
    .{ .size = 14, .data = 8, .ecc = 10, .regions = 1, .region_size = 12, .block_data = 8, .block_ecc = 10 },
    .{ .size = 16, .data = 12, .ecc = 12, .regions = 1, .region_size = 14, .block_data = 12, .block_ecc = 12 },
    .{ .size = 18, .data = 18, .ecc = 14, .regions = 1, .region_size = 16, .block_data = 18, .block_ecc = 14 },
    .{ .size = 20, .data = 22, .ecc = 18, .regions = 1, .region_size = 18, .block_data = 22, .block_ecc = 18 },
    .{ .size = 22, .data = 30, .ecc = 20, .regions = 1, .region_size = 20, .block_data = 30, .block_ecc = 20 },
    .{ .size = 24, .data = 36, .ecc = 24, .regions = 1, .region_size = 22, .block_data = 36, .block_ecc = 24 },
    .{ .size = 26, .data = 44, .ecc = 28, .regions = 1, .region_size = 24, .block_data = 44, .block_ecc = 28 },
    .{ .size = 32, .data = 62, .ecc = 36, .regions = 2, .region_size = 14, .block_data = 62, .block_ecc = 36 },
    .{ .size = 36, .data = 86, .ecc = 42, .regions = 2, .region_size = 16, .block_data = 86, .block_ecc = 42 },
    .{ .size = 40, .data = 114, .ecc = 48, .regions = 2, .region_size = 18, .block_data = 114, .block_ecc = 48 },
    .{ .size = 44, .data = 144, .ecc = 56, .regions = 2, .region_size = 20, .block_data = 144, .block_ecc = 56 },
    .{ .size = 48, .data = 174, .ecc = 68, .regions = 2, .region_size = 22, .block_data = 174, .block_ecc = 68 },
    .{ .size = 52, .data = 204, .ecc = 84, .regions = 2, .region_size = 24, .block_data = 102, .block_ecc = 42 },
    .{ .size = 64, .data = 280, .ecc = 112, .regions = 4, .region_size = 14, .block_data = 140, .block_ecc = 56 },
    .{ .size = 72, .data = 368, .ecc = 144, .regions = 4, .region_size = 16, .block_data = 92, .block_ecc = 36 },
    .{ .size = 80, .data = 456, .ecc = 192, .regions = 4, .region_size = 18, .block_data = 114, .block_ecc = 48 },
    .{ .size = 88, .data = 576, .ecc = 224, .regions = 4, .region_size = 20, .block_data = 144, .block_ecc = 56 },
    .{ .size = 96, .data = 696, .ecc = 272, .regions = 4, .region_size = 22, .block_data = 174, .block_ecc = 68 },
    .{ .size = 104, .data = 816, .ecc = 336, .regions = 4, .region_size = 24, .block_data = 136, .block_ecc = 56 },
    .{ .size = 120, .data = 1050, .ecc = 408, .regions = 6, .region_size = 18, .block_data = 175, .block_ecc = 68 },
    .{ .size = 132, .data = 1304, .ecc = 496, .regions = 6, .region_size = 20, .block_data = 163, .block_ecc = 62 },
    // 144×144 是特例：10 个块，前 8 块 156 个数据码字、后 2 块 155 个（见 `blockDataLen`）
    .{ .size = 144, .data = 1558, .ecc = 620, .regions = 6, .region_size = 22, .block_data = 156, .block_ecc = 62 },
};

/// ECI（扩展信道解释）标记：ASCII 模式下的固定前缀。
const ECI = 241;
/// ECI 000026 = UTF-8。标准规定「码字 = ECI 号 + 1」，所以 UTF-8 要写 27。
/// （写 26 会被解码器当成 ECI 25 → 中文全是乱码，2026-11-23 踩过。）
const ECI_UTF8 = 26;
const ECI_UTF8_CODEWORD = ECI_UTF8 + 1;
/// 上移（Upper Shift）：≥128 的字节写 `UPPER_SHIFT, c-127`。
const UPPER_SHIFT = 235;
/// 填充用的起始码字（后续填充按 149 步进取模）。
const PAD = 129;
const PAD_RANDOMIZER = 149;

/// 把文本编码成 ECC200 矩阵（自动选能装下的最小符号）。
pub fn encode(allocator: std.mem.Allocator, text: []const u8) Error!Matrix {
    if (text.len == 0) return error.Empty;

    // ① 先按 ASCII 模式算出码字流（数字对会压缩，所以不能只看字节数）
    var codewords: std.ArrayList(u8) = .empty;
    defer codewords.deinit(allocator);
    try encodeAscii(allocator, &codewords, text);
    const used = codewords.items.len;

    // ② 选最小符号并补齐填充字（填充从「实际用掉的码字数」开始，不是从容量开始）
    const symbol = pickSymbol(used) orelse return error.TooLong;
    try codewords.resize(allocator, symbol.data + symbol.ecc);
    @memset(codewords.items[symbol.data..], 0);
    fillPad(codewords.items[0..symbol.data], used);

    // ③ Reed-Solomon 纠错（52×52 以上分块交错）
    try rsEncodeAll(allocator, codewords.items[0..symbol.data], codewords.items[symbol.data..], symbol);

    // ④ 摆放成矩阵
    return place(allocator, codewords.items, symbol);
}

/// ASCII 模式编码（含数字对压缩、上移、按需加 UTF-8 ECI）。
fn encodeAscii(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) Error!void {
    // 非 ASCII 文本加 ECI 000026，扫码器才知道这是 UTF-8
    var has_non_ascii = false;
    for (text) |ch| {
        if (ch >= 128) {
            has_non_ascii = true;
            break;
        }
    }
    if (has_non_ascii) {
        try out.append(allocator, ECI);
        try out.append(allocator, ECI_UTF8_CODEWORD);
    }

    var i: usize = 0;
    while (i < text.len) {
        // 两位数字 → 130 + 数值（压缩 2 字节为 1 码字）
        if (i + 1 < text.len and isDigit(text[i]) and isDigit(text[i + 1])) {
            const value: u8 = (text[i] - '0') * 10 + (text[i + 1] - '0');
            try out.append(allocator, 130 + value);
            i += 2;
            continue;
        }
        const c = text[i];
        if (c < 128) {
            try out.append(allocator, c + 1);
        } else {
            try out.append(allocator, UPPER_SHIFT);
            try out.append(allocator, c - 127);
        }
        i += 1;
    }
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// 选能装下 `count` 个数据码字的最小符号。
fn pickSymbol(count: usize) ?Symbol {
    for (SYMBOLS) |symbol| {
        if (symbol.data >= count) return symbol;
    }
    return null;
}

/// 填充剩余数据码字：第一个填充固定 129，之后是 `(149 × 位置) % 253 + 130` 的伪随机值
/// （位置是 **1 基** 的码字序号，写第 `i` 个（0 基）码字时取 `i + 1`）。
///
/// 这是标准的「随机化填充」，作用是让空白区域看起来不像固定图案，减少大面积空白造成的误读。
fn fillPad(buf: []u8, from: usize) void {
    if (from >= buf.len) return;
    buf[from] = PAD;
    var pos = from + 1;
    while (pos < buf.len) : (pos += 1) {
        const position: u32 = @intCast(pos + 1);
        const pseudo: u32 = (PAD_RANDOMIZER * position) % 253 + 1 + PAD;
        buf[pos] = if (pseudo <= 254) @intCast(pseudo) else @intCast(pseudo - 254);
    }
}

// ————— Reed-Solomon（GF(256) / 0x12D，与 QR 的 0x11D 不同域） —————

const GF_PRIMITIVE: u16 = 0x12D;

const Gf = struct {
    exp: [512]u8 = undefined,
    log: [256]u8 = undefined,

    fn init() Gf {
        var self: Gf = .{};
        var x: u16 = 1;
        var i: usize = 0;
        while (i < 255) : (i += 1) {
            self.exp[i] = @intCast(x);
            self.exp[i + 255] = @intCast(x);
            self.log[@as(u8, @intCast(x))] = @intCast(i);
            x <<= 1;
            if (x & 0x100 != 0) x ^= GF_PRIMITIVE;
        }
        self.log[0] = 0;
        return self;
    }

    fn mul(self: *const Gf, a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        const s: usize = @as(usize, self.log[a]) + self.log[b];
        return self.exp[s % 255];
    }
};

const gf = Gf.init();

/// 计算 `data` 的 RS 校验码，写入 `ecc`（长度即纠错码字数）。
fn rsEncode(allocator: std.mem.Allocator, data: []const u8, ecc: []u8) !void {
    if (ecc.len == 0) return;
    // 生成多项式 g(x) = ∏(x + α^i)，i = 1..ecc；`g[0]` 是最高次项（恒为 1）。
    // 乘法按「高次在前」就地推进：g(x)·(x+α) → g[k+1] ^= g[k]·α，从高次往低次算。
    const g = try allocator.alloc(u8, ecc.len + 1);
    defer allocator.free(g);
    @memset(g, 0);
    g[0] = 1;
    var deg: usize = 0;
    while (deg < ecc.len) : (deg += 1) {
        const root = gf.exp[(deg + 1) % 255];
        var k: usize = deg + 1;
        while (k > 0) : (k -= 1) {
            g[k] ^= gf.mul(g[k - 1], root);
        }
    }

    @memset(ecc, 0);
    for (data) |byte| {
        const factor = byte ^ ecc[0];
        var k: usize = 0;
        while (k + 1 < ecc.len) : (k += 1) {
            ecc[k] = ecc[k + 1] ^ gf.mul(g[k + 1], factor);
        }
        ecc[ecc.len - 1] = gf.mul(g[ecc.len], factor);
    }
}

/// 单个 RS 块的数据码字数（144×144 的最后两块少 1 个）。
fn blockDataLen(symbol: Symbol, block: usize) usize {
    if (symbol.size == 144 and block >= 8) return 155;
    return symbol.block_data;
}

/// 按标准分块交错计算纠错码字：块 `b` 取数据码字 `b, b+块数, b+2×块数…`，
/// 结果按同样步长交错写回（52×52 及以上是多块符号）。
fn rsEncodeAll(allocator: std.mem.Allocator, data: []const u8, ecc: []u8, symbol: Symbol) !void {
    const blocks = symbol.ecc / symbol.block_ecc;
    if (blocks <= 1) return rsEncode(allocator, data, ecc);

    const scratch = try allocator.alloc(u8, symbol.block_data);
    defer allocator.free(scratch);
    const out = try allocator.alloc(u8, symbol.block_ecc);
    defer allocator.free(out);

    var block: usize = 0;
    while (block < blocks) : (block += 1) {
        const blen = blockDataLen(symbol, block);
        var j: usize = 0;
        while (j < blen) : (j += 1) {
            scratch[j] = data[block + j * blocks];
        }
        try rsEncode(allocator, scratch[0..blen], out);

        j = 0;
        while (j < symbol.block_ecc) : (j += 1) {
            ecc[block + j * blocks] = out[j];
        }
    }
}

// ————— 矩阵摆放（ISO/IEC 16022 Annex M.1：Default Placement） —————
//
// 虚拟坐标 `row 0 = 最顶`、`col 0 = 最左`，宽高都是 `区域个数 × 区域数据边长`。

/// 虚拟数据区里的「还没写过」标记。
const UNSET: u8 = 2;

const Placement = struct {
    bits: []u8,
    ncols: usize,
    nrows: usize,
    codewords: []const u8,
    total_bits: usize,

    fn inRange(self: *const Placement, col: isize, row: isize) bool {
        return col >= 0 and row >= 0 and
            col < @as(isize, @intCast(self.ncols)) and
            row < @as(isize, @intCast(self.nrows));
    }

    /// 该格是否「还没被写过」。
    fn noBit(self: *const Placement, col: isize, row: isize) bool {
        if (!self.inRange(col, row)) return false;
        return self.bits[@as(usize, @intCast(row)) * self.ncols + @as(usize, @intCast(col))] == UNSET;
    }

    fn setBit(self: *Placement, col: isize, row: isize, dark: bool) void {
        if (!self.inRange(col, row)) return;
        self.bits[@as(usize, @intCast(row)) * self.ncols + @as(usize, @intCast(col))] = if (dark) 1 else 0;
    }

    /// 写一个模块。**负坐标要环绕到另一端**（标准如此定义）：
    /// 少了这一步，数据区会留下大片空白，图案看着像 Data Matrix 却扫不出来。
    fn module(self: *Placement, row_in: isize, col_in: isize, pos: usize, bit: usize) void {
        var row = row_in;
        var col = col_in;
        const nrows: isize = @intCast(self.nrows);
        const ncols: isize = @intCast(self.ncols);
        if (row < 0) {
            row += nrows;
            col += 4 - @mod(nrows + 4, 8);
        }
        if (col < 0) {
            col += ncols;
            row += 4 - @mod(ncols + 4, 8);
        }
        // 第 pos 个码字的第 bit 位（bit 1 = 最高位）
        const bit_idx = pos * 8 + (bit - 1);
        const dark = if (bit_idx < self.total_bits) blk: {
            const byte = self.codewords[bit_idx / 8];
            const shift: u3 = @intCast(7 - (bit_idx % 8));
            break :blk (byte >> shift) & 1 == 1;
        } else false;
        self.setBit(col, row, dark);
    }

    /// Utah 形：8 个模块一个码字（最常用的一种形状）。
    fn utah(self: *Placement, row: isize, col: isize, pos: usize) void {
        self.module(row - 2, col - 2, pos, 1);
        self.module(row - 2, col - 1, pos, 2);
        self.module(row - 1, col - 2, pos, 3);
        self.module(row - 1, col - 1, pos, 4);
        self.module(row - 1, col, pos, 5);
        self.module(row, col - 2, pos, 6);
        self.module(row, col - 1, pos, 7);
        self.module(row, col, pos, 8);
    }

    fn corner1(self: *Placement, nrows: isize, ncols: isize, pos: usize) void {
        self.module(nrows - 1, 0, pos, 1);
        self.module(nrows - 1, 1, pos, 2);
        self.module(nrows - 1, 2, pos, 3);
        self.module(0, ncols - 2, pos, 4);
        self.module(0, ncols - 1, pos, 5);
        self.module(1, ncols - 1, pos, 6);
        self.module(2, ncols - 1, pos, 7);
        self.module(3, ncols - 1, pos, 8);
    }

    fn corner2(self: *Placement, nrows: isize, ncols: isize, pos: usize) void {
        self.module(nrows - 3, 0, pos, 1);
        self.module(nrows - 2, 0, pos, 2);
        self.module(nrows - 1, 0, pos, 3);
        self.module(0, ncols - 4, pos, 4);
        self.module(0, ncols - 3, pos, 5);
        self.module(0, ncols - 2, pos, 6);
        self.module(0, ncols - 1, pos, 7);
        self.module(1, ncols - 1, pos, 8);
    }

    fn corner3(self: *Placement, nrows: isize, ncols: isize, pos: usize) void {
        self.module(nrows - 3, 0, pos, 1);
        self.module(nrows - 2, 0, pos, 2);
        self.module(nrows - 1, 0, pos, 3);
        self.module(0, ncols - 2, pos, 4);
        self.module(0, ncols - 1, pos, 5);
        self.module(1, ncols - 1, pos, 6);
        self.module(2, ncols - 1, pos, 7);
        self.module(3, ncols - 1, pos, 8);
    }

    fn corner4(self: *Placement, nrows: isize, ncols: isize, pos: usize) void {
        self.module(nrows - 1, 0, pos, 1);
        self.module(nrows - 1, ncols - 1, pos, 2);
        self.module(0, ncols - 3, pos, 3);
        self.module(0, ncols - 2, pos, 4);
        self.module(0, ncols - 1, pos, 5);
        self.module(1, ncols - 3, pos, 6);
        self.module(1, ncols - 2, pos, 7);
        self.module(1, ncols - 1, pos, 8);
    }

    /// 沿对角线来回扫，把码字按 Utah 形铺满整个数据区。
    fn placeAll(self: *Placement) void {
        const nr: isize = @intCast(self.nrows);
        const nc: isize = @intCast(self.ncols);
        var pos: usize = 0;
        var row: isize = 4;
        var col: isize = 0;

        while (true) {
            // 每轮先处理 4 个特殊角
            if (row == nr and col == 0) {
                self.corner1(nr, nc, pos);
                pos += 1;
            }
            if (row == nr - 2 and col == 0 and @mod(nc, 4) != 0) {
                self.corner2(nr, nc, pos);
                pos += 1;
            }
            if (row == nr - 2 and col == 0 and @mod(nc, 8) == 4) {
                self.corner3(nr, nc, pos);
                pos += 1;
            }
            if (row == nr + 4 and col == 2 and @mod(nc, 8) == 0) {
                self.corner4(nr, nc, pos);
                pos += 1;
            }

            // 向上对角扫（do/while：即使入口已越界也要走一次步进）
            while (true) {
                if (row < nr and col >= 0 and self.noBit(col, row)) {
                    self.utah(row, col, pos);
                    pos += 1;
                }
                row -= 2;
                col += 2;
                if (!(row >= 0 and col < nc)) break;
            }
            row += 1;
            col += 3;

            // 向下对角扫
            while (true) {
                if (row >= 0 and col < nc and self.noBit(col, row)) {
                    self.utah(row, col, pos);
                    pos += 1;
                }
                row += 2;
                col -= 2;
                if (!(row < nr and col >= 0)) break;
            }
            row += 3;
            col += 1;

            if (!(row < nr or col < nc)) break;
        }

        // 右下角若还没被占用，补标准固定图案（两个深色模块）
        if (self.noBit(nc - 1, nr - 1)) {
            self.setBit(nc - 1, nr - 1, true);
            self.setBit(nc - 2, nr - 2, true);
        }
    }
};

/// 把码字流摆进矩阵：先做虚拟摆放，再嵌进带定位边/时钟轨的物理矩阵。
fn place(allocator: std.mem.Allocator, codewords: []const u8, symbol: Symbol) Error!Matrix {
    const ncols = symbol.regions * symbol.region_size;
    const nrows = ncols;

    const bits = try allocator.alloc(u8, ncols * nrows);
    defer allocator.free(bits);
    @memset(bits, UNSET);

    var p: Placement = .{
        .bits = bits,
        .ncols = ncols,
        .nrows = nrows,
        .codewords = codewords,
        .total_bits = codewords.len * 8,
    };
    p.placeAll();

    // 物理矩阵：每个区域四周补「左右各 1 列 + 上下各 1 行」
    const size = symbol.size;
    const road = symbol.region_size;
    const modules = try allocator.alloc(bool, size * size);
    errdefer allocator.free(modules);
    @memset(modules, false);

    var my: usize = 0; // 物理行
    var y: usize = 0; // 虚拟行（0 = 最顶）
    while (y < nrows) : (y += 1) {
        // 区域顶边的时钟轨：整行深浅交替，最左为深
        if (@mod(y, road) == 0) {
            var x: usize = 0;
            while (x < size) : (x += 1) modules[my * size + x] = @mod(x, 2) == 0;
            my += 1;
        }

        var mx: usize = 0;
        var x: usize = 0;
        while (x < ncols) : (x += 1) {
            // 区域左边：整列实线（L 形的竖边）
            if (@mod(x, road) == 0) {
                modules[my * size + mx] = true;
                mx += 1;
            }
            modules[my * size + mx] = p.bits[y * ncols + x] == 1;
            mx += 1;
            // 区域右边：时钟轨，深浅交替（相位跟虚拟行号走）
            if (@mod(x, road) == road - 1) {
                modules[my * size + mx] = @mod(y, 2) == 0;
                mx += 1;
            }
        }
        my += 1;

        // 区域底边：整行实线（L 形的横边）
        if (@mod(y, road) == road - 1) {
            var k: usize = 0;
            while (k < size) : (k += 1) modules[my * size + k] = true;
            my += 1;
        }
    }

    return .{ .size = size, .version = 0, .mask = 0, .modules = modules };
}

// ————— 测试 —————

const testing = std.testing;

test "zzig.datamatrix：ASCII 模式的数据码字（数字对压缩）" {
    // 三位数字对 → 142, 164, 186；10×10 符号的数据容量正好 3 个码字。
    var cw: std.ArrayList(u8) = .empty;
    defer cw.deinit(testing.allocator);
    try encodeAscii(testing.allocator, &cw, "123456");
    try testing.expectEqualSlices(u8, &.{ 142, 164, 186 }, cw.items);
}

test "zzig.datamatrix：ASCII 模式含上移与数字对压缩" {
    var cw: std.ArrayList(u8) = .empty;
    defer cw.deinit(testing.allocator);
    // "AB12" → 'A'+1=66, 'B'+1=67, 数字对 12 → 142
    try encodeAscii(testing.allocator, &cw, "AB12");
    try testing.expectEqualSlices(u8, &.{ 66, 67, 142 }, cw.items);

    // 非 ASCII 文本先给 ECI 000026（UTF-8）
    cw.clearRetainingCapacity();
    try encodeAscii(testing.allocator, &cw, "中");
    try testing.expectEqual(@as(u8, ECI), cw.items[0]);
    try testing.expectEqual(@as(u8, ECI_UTF8_CODEWORD), cw.items[1]);
}

test "zzig.datamatrix：按容量选最小符号" {
    try testing.expectEqual(@as(usize, 10), pickSymbol(3).?.size);
    try testing.expectEqual(@as(usize, 12), pickSymbol(4).?.size);
    try testing.expectEqual(@as(usize, 14), pickSymbol(6).?.size);
    try testing.expect(pickSymbol(99999) == null);
}

test "zzig.datamatrix：填充码字首位 129，其余按 149 步进随机化" {
    // "A" 只占 1 个码字（66），10×10 容量 3 → 补 2 个：
    // 第 3 个码字（1 基位置 3）→ (149×3) % 253 + 130 = 324 → 324-254 = 70
    var buf: [3]u8 = undefined;
    buf[0] = 66;
    fillPad(&buf, 1);
    try testing.expectEqualSlices(u8, &.{ 66, 129, 70 }, &buf);
}

test "zzig.datamatrix：RS 纠错值（GF(256) / 0x12D）" {
    // ISO/IEC 16022 的样例：数据 142,164,186（"123456"）→ 纠错 114,25,5,88,102
    var ecc: [5]u8 = undefined;
    try rsEncode(testing.allocator, &[_]u8{ 142, 164, 186 }, &ecc);
    try testing.expectEqualSlices(u8, &.{ 114, 25, 5, 88, 102 }, &ecc);
}

/// 参考矩阵（用 zxing-cpp 的 `create_barcode("123456", DataMatrix)` 生成，逐格记下来当金标准）。
const GOLDEN_123456 =
    \\#.#.#.#.#.
    \\##..#.##.#
    \\##.....#..
    \\##...###.#
    \\##....#...
    \\#.....####
    \\###.##....
    \\####.##..#
    \\#..###.#..
    \\##########
;

test "zzig.datamatrix：10×10 与参考矩阵逐格一致" {
    const m = try encode(testing.allocator, "123456");
    defer {
        var mm = m;
        mm.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 10), m.size);

    var lines = std.mem.splitScalar(u8, GOLDEN_123456, '\n');
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) {
        try testing.expectEqual(m.size, line.len);
        for (line, 0..) |ch, col| {
            const want = ch == '#';
            const got = m.isDark(col, row);
            if (want != got) {
                std.debug.print("\n[dm] 第 {d} 行第 {d} 列不一致：期望 {s}，实际 {s}\n", .{
                    row, col,
                    if (want) "深" else "浅",
                    if (got) "深" else "浅",
                });
                return error.MatrixMismatch;
            }
        }
    }
}

test "zzig.datamatrix：定位边与时钟轨齐全" {
    const m = try encode(testing.allocator, "123456");
    defer {
        var mm = m;
        mm.deinit(testing.allocator);
    }
    // 最下面一行全是实线（L 形定位边的横边）；最左一列全是实线（竖边）
    var i: usize = 0;
    while (i < m.size) : (i += 1) {
        try testing.expect(m.isDark(i, m.size - 1));
        try testing.expect(m.isDark(0, i));
    }
    // 最上面一行是时钟轨：偶数位深、奇数位浅
    var x: usize = 0;
    while (x < m.size) : (x += 1) {
        try testing.expectEqual(@mod(x, 2) == 0, m.isDark(x, 0));
    }
}

test "zzig.datamatrix：多区域符号（32×32）的结构" {
    // 60 个 ASCII 字符 → 60 个码字 → 32×32（2×2 区域，每区 14×14 数据）
    var text: [60]u8 = undefined;
    @memset(&text, 'a');
    const m = try encode(testing.allocator, &text);
    defer {
        var mm = m;
        mm.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 32), m.size);

    // 每带底行（第 15、31 行）整行实线
    var x: usize = 0;
    while (x < m.size) : (x += 1) {
        try testing.expect(m.isDark(x, 15));
        try testing.expect(m.isDark(x, 31));
    }
    // 每个区域带的最左列（第 0、16 列）整列实线
    var y: usize = 0;
    while (y < m.size) : (y += 1) {
        try testing.expect(m.isDark(0, y));
        try testing.expect(m.isDark(16, y));
    }
}
