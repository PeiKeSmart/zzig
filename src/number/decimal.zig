//! 十进制（对应 .NET `Decimal` / Rust `rust_decimal::Decimal` 的**值语义子集**）。
//!
//! 通用数值类型：任何需要「原样承载 + 精确比较 + 文本往返」又不需要算术的场景（ORM、
//! 配置解析、财务文本交换）都能用。表示法为 `mantissa × 10^-scale`（与 .NET `decimal`
//! 的 96 位尾数 + 缩放因子同构）：
//!
//! - `parse`：解析 `-12.3400`、`+7`、`1.2e3` 等文本（C# `decimal.Parse` 的常见形态）；
//! - `format`：按 scale 原样输出（**保留尾随零**，与 C# `decimal.ToString()` 一致：
//!   `12.3400m` → `"12.3400"`）；
//! - `eql`：按**数值**比较（`12.34` == `12.3400`）。
//!
//! 超出 28 位小数直接报错（.NET decimal 的上限），不做静默舍入——语义不明时宁可失败。

const std = @import("std");

pub const Decimal = struct {
    /// 尾数（对应 .NET decimal 的 96 位整数，这里用 i128 承载，范围更大）
    mantissa: i128,
    /// 小数位数（0..=28）
    scale: u8,

    /// .NET decimal 的最大小数位数。
    pub const max_scale: u8 = 28;

    pub fn init(mantissa: i128, scale: u8) !Decimal {
        if (scale > max_scale) return error.ScaleOverflow;
        return .{ .mantissa = mantissa, .scale = scale };
    }

    pub fn zero() Decimal {
        return .{ .mantissa = 0, .scale = 0 };
    }

    pub fn isZero(self: Decimal) bool {
        return self.mantissa == 0;
    }

    /// 解析文本（宽松：允许前后空白与 `+` 号、指数形式）。
    pub fn parse(text: []const u8) !Decimal {
        var s = std.mem.trim(u8, text, " \t\r\n");
        if (s.len == 0) return error.InvalidDecimal;

        var negative = false;
        if (s[0] == '+' or s[0] == '-') {
            negative = s[0] == '-';
            s = s[1..];
        }
        if (s.len == 0) return error.InvalidDecimal;

        var mantissa: i128 = 0;
        var digits: usize = 0;
        var scale: i32 = 0;
        var seen_point = false;
        var i: usize = 0;

        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c >= '0' and c <= '9') {
                const d: i128 = c - '0';
                mantissa = std.math.mul(i128, mantissa, 10) catch return error.DecimalOverflow;
                mantissa = std.math.add(i128, mantissa, d) catch return error.DecimalOverflow;
                if (seen_point) scale += 1;
                if (scale > max_scale) return error.ScaleOverflow;
                digits += 1;
            } else if (c == '.' and !seen_point) {
                seen_point = true;
            } else if (c == 'e' or c == 'E') {
                break;
            } else {
                return error.InvalidDecimal;
            }
        }

        if (digits == 0) return error.InvalidDecimal;

        // 指数部分：value = mantissa × 10^(exp - scale)
        var exponent: i32 = 0;
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            var exp_negative = false;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) {
                exp_negative = s[i] == '-';
                i += 1;
            }
            if (i >= s.len) return error.InvalidDecimal;
            var exp: i32 = 0;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                if (c < '0' or c > '9') return error.InvalidDecimal;
                exp = std.math.mul(i32, exp, 10) catch return error.DecimalOverflow;
                exp = exp + @as(i32, c - '0');
                if (exp > 1000) return error.DecimalOverflow;
            }
            exponent = if (exp_negative) -exp else exp;
            if (i != s.len) return error.InvalidDecimal;
        }

        const net: i32 = exponent - scale;
        if (net >= 0) {
            var k: i32 = 0;
            while (k < net) : (k += 1) {
                mantissa = std.math.mul(i128, mantissa, 10) catch return error.DecimalOverflow;
            }
            scale = 0;
        } else {
            const shift: i32 = -net;
            if (shift > max_scale) return error.ScaleOverflow;
            scale = @intCast(shift);
        }

        if (negative) mantissa = -mantissa;
        return .{ .mantissa = mantissa, .scale = @intCast(scale) };
    }

    /// 输出文本（保留 scale 位小数；与 C# `decimal.ToString()` 一致）。
    pub fn formatAlloc(self: Decimal, gpa: std.mem.Allocator) ![]u8 {
        var scratch: [48]u8 = undefined;
        const text = try self.formatBuf(&scratch);
        return gpa.dupe(u8, text);
    }

    /// 写入固定缓冲（无分配；`out` 至少 48 字节）。
    pub fn formatBuf(self: Decimal, out: []u8) ![]const u8 {
        const negative = self.mantissa < 0;
        // 注意：i128 的最小值取反会溢出，这里用无符号承载绝对值
        const abs: u128 = if (negative)
            @as(u128, @intCast(-(self.mantissa + 1))) + 1
        else
            @as(u128, @intCast(self.mantissa));

        var digits_buf: [40]u8 = undefined;
        const digits = try std.fmt.bufPrint(&digits_buf, "{d}", .{abs});

        var pos: usize = 0;
        if (negative) {
            out[pos] = '-';
            pos += 1;
        }

        if (self.scale == 0) {
            if (pos + digits.len > out.len) return error.NoSpaceLeft;
            @memcpy(out[pos..][0..digits.len], digits);
            return out[0 .. pos + digits.len];
        }

        const scale: usize = self.scale;
        if (digits.len <= scale) {
            // 0.00abc 形态：补前导零
            if (pos + 2 + (scale - digits.len) + digits.len > out.len) return error.NoSpaceLeft;
            out[pos] = '0';
            out[pos + 1] = '.';
            pos += 2;
            var pad = scale - digits.len;
            while (pad > 0) : (pad -= 1) {
                out[pos] = '0';
                pos += 1;
            }
            @memcpy(out[pos..][0..digits.len], digits);
            return out[0 .. pos + digits.len];
        }

        const int_len = digits.len - scale;
        if (pos + digits.len + 1 > out.len) return error.NoSpaceLeft;
        @memcpy(out[pos..][0..int_len], digits[0..int_len]);
        pos += int_len;
        out[pos] = '.';
        pos += 1;
        @memcpy(out[pos..][0..scale], digits[int_len..]);
        return out[0 .. pos + scale];
    }

    /// 去掉尾随零后的规范形式（用于数值比较）。
    fn normalized(self: Decimal) Decimal {
        var m = self.mantissa;
        var s = self.scale;
        while (s > 0 and @rem(m, 10) == 0) {
            m = @divTrunc(m, 10);
            s -= 1;
        }
        return .{ .mantissa = m, .scale = s };
    }

    /// 数值相等（`12.34` == `12.3400`）。
    pub fn eql(self: Decimal, other: Decimal) bool {
        const a = self.normalized();
        const b = other.normalized();
        return a.mantissa == b.mantissa and a.scale == b.scale;
    }

    /// 转 i64（截断小数部分；溢出返回 null）。
    pub fn toI64(self: Decimal) ?i64 {
        var m = self.mantissa;
        var s = self.scale;
        while (s > 0) : (s -= 1) m = @divTrunc(m, 10);
        if (m > std.math.maxInt(i64) or m < std.math.minInt(i64)) return null;
        return @intCast(m);
    }

    /// 转 f64（可能丢精度，仅用于展示/统计）。
    pub fn toF64(self: Decimal) f64 {
        const m: f64 = @floatFromInt(self.mantissa);
        return m / std.math.pow(f64, 10.0, @floatFromInt(self.scale));
    }
};

test "解析与格式化保留尾随零" {
    const a = try Decimal.parse("12.3400");
    try std.testing.expectEqual(@as(u8, 4), a.scale);
    try std.testing.expectEqual(@as(i128, 123400), a.mantissa);
    const s = try a.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("12.3400", s);
}

test "数值相等忽略尾随零" {
    try std.testing.expect((try Decimal.parse("12.34")).eql(try Decimal.parse("12.3400")));
    try std.testing.expect(!(try Decimal.parse("12.34")).eql(try Decimal.parse("12.35")));
}

test "整数与负数与零" {
    const i = try Decimal.parse("-42");
    try std.testing.expectEqual(@as(u8, 0), i.scale);
    const s = try i.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("-42", s);

    const z = try Decimal.parse("0.00");
    const zs = try z.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(zs);
    try std.testing.expectEqualStrings("0.00", zs);
}

test "指数形式" {
    const a = try Decimal.parse("1.2e3");
    try std.testing.expect(a.eql(try Decimal.parse("1200")));
    const b = try Decimal.parse("1e-3");
    try std.testing.expect(b.eql(try Decimal.parse("0.001")));
}

test "C# 典型精度文本往返" {
    const text = "1234567890.123456789";
    const d = try Decimal.parse(text);
    const s = try d.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(text, s);
}

test "非法输入" {
    try std.testing.expectError(error.InvalidDecimal, Decimal.parse(""));
    try std.testing.expectError(error.InvalidDecimal, Decimal.parse("abc"));
    try std.testing.expectError(error.InvalidDecimal, Decimal.parse("1.2.3"));
    try std.testing.expectError(error.InvalidDecimal, Decimal.parse("1e"));
}
