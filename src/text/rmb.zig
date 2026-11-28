//! 人民币金额转大写（财税口径，与银行 / 发票写法一致）。
//!
//! 来源：`Pek.ZTools/src/rmb_tool.zig`（对齐 C# `WordsHelper.ToChineseRMB`），**从工具站下沉**——
//! 中文大写金额是标准规则（有唯一正确答案），合同、发票、报销、对账任何项目都要用，
//! 各项目各写一份只会把「零」的规则写错。
//!
//! **不用浮点**：把输入按字符串解析成**整数分**（`1234.56` → `123456` 分），全程整数运算；
//! `0.1 + 0.2` 这类浮点误差不会出现，任意合法输入结果都可复现。
//!
//! 支持的输入：
//! - `1234.56`（最多两位小数，超出直接报 `BadFormat` 而不是悄悄四舍五入）；
//! - 千分位逗号（`1,234.56`）；
//! - 前导 `+` 与负号（负数输出「负…」）；
//! - 上限 9999 亿（`999999999999.99`），够覆盖所有真实票据场景。
//!
//! 零的规则（缺一条都会读错金额）：
//! - 连续零合并成一个「零」，节尾零省略；
//! - 万 / 亿 节内全零时保留一个「零」承接（`100000001` → 壹亿零壹元整）；
//! - 上一节千位为零也要补「零」（`100010001` → 壹亿零壹万零壹元整）；
//! - 角为零、分不为零 → 必须补「零」（`100.05` → 壹佰元零伍分）；
//! - 没有小数或小数两位全零 → 结尾加「整」。

const std = @import("std");

/// 失败原因（**不含文案**：给用户看的中文提示由调用方决定）。
pub const Error = error{
    /// 输入为空（或只有空白）。
    Empty,
    /// 格式不合法：非数字、多个小数点、超过两位小数、溢出上限。
    BadFormat,
    /// 金额超出上限（`MAX_CENTS`）。
    TooLarge,
    OutOfMemory,
};

/// 允许的最大金额：999,999,999,999.99 元（9999 亿元）。
pub const MAX_CENTS: i64 = 999_999_999_999_99;

const digits = [_][]const u8{ "零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖" };
const units_in_section = [_][]const u8{ "", "拾", "佰", "仟" };
const section_units = [_][]const u8{ "", "万", "亿", "万亿" };

/// 金额文本（如 `1,234.56`）→ 人民币大写（如 `壹仟贰佰叁拾肆元伍角陆分`）。
///
/// 返回的切片由 `allocator` 拥有，调用方释放。
pub fn toChineseRmb(allocator: std.mem.Allocator, text: []const u8) Error![]const u8 {
    const cents = try parseCents(text);
    return formatCentsAlloc(allocator, cents);
}

/// 整数分 → 人民币大写。负数输出「负…」。
pub fn formatCentsAlloc(allocator: std.mem.Allocator, cents: i64) Error![]const u8 {
    if (cents > MAX_CENTS or cents < -MAX_CENTS) return error.TooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (cents < 0) try out.appendSlice(allocator, "负");
    // 注意 `@abs` 返回无符号（u64），后面按 i64 运算，这里显式取绝对值
    const total: i64 = if (cents < 0) -cents else cents;
    const yuan = @divTrunc(total, 100);
    const jiao: u8 = @intCast(@divTrunc(@mod(total, 100), 10));
    const fen: u8 = @intCast(@mod(total, 10));

    if (yuan > 0) {
        try integerToChinese(&out, allocator, yuan);
        try out.appendSlice(allocator, "元");
    } else {
        try out.appendSlice(allocator, "零元");
    }

    if (jiao == 0 and fen == 0) {
        try out.appendSlice(allocator, "整");
    } else {
        if (jiao == 0) {
            // 有分无角：必须补一个「零」，否则「壹佰元伍分」会被读成「壹佰零伍元」的歧义
            try out.appendSlice(allocator, "零");
        } else {
            try out.appendSlice(allocator, digits[jiao]);
            try out.appendSlice(allocator, "角");
        }
        if (fen > 0) {
            try out.appendSlice(allocator, digits[fen]);
            try out.appendSlice(allocator, "分");
        } else {
            try out.appendSlice(allocator, "整");
        }
    }

    return out.toOwnedSlice(allocator);
}

/// 金额文本 → **整数分**（`1,234.56` → `123456`；`-100` → `-10000`）。
///
/// 只做解析与范围校验，不产生文案 —— 想自定义提示的项目自己映射 `Error`。
pub fn parseCents(text_in: []const u8) Error!i64 {
    const raw = std.mem.trim(u8, text_in, " \t\r\n");
    if (raw.len == 0) return error.Empty;

    var text = raw;
    var negative = false;
    if (text[0] == '+' or text[0] == '-') {
        negative = text[0] == '-';
        text = text[1..];
    }
    if (text.len == 0) return error.BadFormat;

    // 去掉千分位逗号（宽松处理：整数部分 / 小数部分都直接剔除）
    var buf: [40]u8 = undefined;
    var n: usize = 0;
    var seen_dot = false;
    var decimals: usize = 0;
    for (text) |ch| {
        if (ch == ',') continue;
        if (ch == '.') {
            if (seen_dot) return error.BadFormat;
            seen_dot = true;
            continue;
        }
        if (ch < '0' or ch > '9') return error.BadFormat;
        if (seen_dot) {
            decimals += 1;
            if (decimals > 2) return error.BadFormat; // 超过两位小数：明确报错，不静默四舍五入
        }
        if (n >= buf.len) return error.BadFormat;
        buf[n] = ch;
        n += 1;
    }
    if (n == 0) return error.BadFormat;

    var cents: i64 = 0;
    for (buf[0..n]) |ch| {
        cents = cents * 10 + @as(i64, ch - '0');
        if (cents > MAX_CENTS) return error.TooLarge; // 防溢出
    }
    // 小数位不足两位时补零：`12.5` 已计入 `125`，需要的是 120 分 + 5 角 → 补一个 0
    if (decimals == 0) {
        cents *= 100;
    } else if (decimals == 1) {
        cents *= 10;
    }
    return if (negative) -cents else cents;
}

/// 整数部分转中文（不含「元」）。按 4 位一节从高位处理。
fn integerToChinese(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) Error!void {
    if (value == 0) {
        try out.appendSlice(allocator, "零");
        return;
    }

    // 拆成 4 位一节（低位在前）
    var sections: [4]i64 = .{ 0, 0, 0, 0 };
    var count: usize = 0;
    var rest = value;
    while (rest > 0 and count < sections.len) : (count += 1) {
        sections[count] = @mod(rest, 10000);
        rest = @divTrunc(rest, 10000);
    }
    if (rest > 0) return error.TooLarge;

    var need_zero = false;
    var prev_section: i64 = 0;
    var emitted = false;
    var index: usize = count;
    while (index > 0) {
        index -= 1;
        const section = sections[index];
        if (section == 0) {
            // 整节为零：只记住「欠一个零」，等后面真有非零节时再补
            need_zero = emitted;
            continue;
        }
        // 补「零」的两个条件（缺一个都会读错金额）：
        // ① 中间有整节为零：`100000001` → 壹亿**零**壹元整；
        // ② 上一节千位为零（上一节 < 1000）：`100010001` → 壹亿**零**壹万**零**壹元整。
        if (emitted and (need_zero or prev_section < 1000)) {
            try out.appendSlice(allocator, "零");
        }
        try sectionToChinese(out, allocator, section);
        try out.appendSlice(allocator, section_units[index]);
        prev_section = section;
        emitted = true;
        need_zero = false;
    }
}

/// 4 位以内的一节（`0..=9999`）转中文，节内不带节单位。
fn sectionToChinese(out: *std.ArrayList(u8), allocator: std.mem.Allocator, section: i64) Error!void {
    // ★ 前导零只看**本节**已写出的长度：用全局 `out.items.len` 会把上一节的内容也算进来，
    // 于是本节的三位前导零全被记成「欠一个零」，`100000001` 就输出成「壹亿零零壹」。
    const start = out.items.len;
    var zero_pending = false;
    var place: usize = 4;
    var value = section;
    while (place > 0) {
        place -= 1;
        const divisor = std.math.pow(i64, 10, @as(i64, @intCast(place)));
        const digit: usize = @intCast(@divTrunc(value, divisor));
        value = @mod(value, divisor);

        if (digit == 0) {
            // 节内零：只有本节前面已输出过数字时才需要标记（避免「零壹」开头）
            if (out.items.len > start) zero_pending = true;
            continue;
        }
        if (zero_pending) {
            try out.appendSlice(allocator, "零");
            zero_pending = false;
        }
        try out.appendSlice(allocator, digits[digit]);
        try out.appendSlice(allocator, units_in_section[place]);
    }
}

const testing = std.testing;

test "zzig.rmb：常用金额逐字比对" {
    const cases = [_][2][]const u8{
        .{ "0", "零元整" },
        .{ "1", "壹元整" },
        .{ "10", "壹拾元整" },
        .{ "100.5", "壹佰元伍角整" },
        .{ "100.05", "壹佰元零伍分" },
        .{ "1234.56", "壹仟贰佰叁拾肆元伍角陆分" },
        .{ "10001", "壹万零壹元整" },
        .{ "100000000", "壹亿元整" },
        .{ "100000001", "壹亿零壹元整" },
        // 节间零的两条规则各来一个：整节为零 / 上节千位为零（曾输出成「壹亿零零壹」「壹亿壹万零壹」）
        .{ "100010001", "壹亿零壹万零壹元整" },
        .{ "1000000001", "壹拾亿零壹元整" },
        .{ "1010000", "壹佰零壹万元整" },
        .{ "1000001", "壹佰万零壹元整" },
        .{ "12345678.9", "壹仟贰佰叁拾肆万伍仟陆佰柒拾捌元玖角整" },
        .{ "0.5", "零元伍角整" },
        .{ "1000000", "壹佰万元整" },
        .{ "10000000000", "壹佰亿元整" },
    };
    for (cases) |case| {
        const got = try toChineseRmb(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "zzig.rmb：千分位、负号" {
    const thousand = try toChineseRmb(testing.allocator, "1,234.56");
    defer testing.allocator.free(thousand);
    try testing.expectEqualStrings("壹仟贰佰叁拾肆元伍角陆分", thousand);

    const negative = try toChineseRmb(testing.allocator, "-100");
    defer testing.allocator.free(negative);
    try testing.expectEqualStrings("负壹佰元整", negative);
}

test "zzig.rmb：非法输入分类（不靠文案区分）" {
    try testing.expectError(error.Empty, toChineseRmb(testing.allocator, "   "));
    try testing.expectError(error.BadFormat, toChineseRmb(testing.allocator, "12.345"));
    try testing.expectError(error.BadFormat, toChineseRmb(testing.allocator, "abc"));
    try testing.expectError(error.BadFormat, toChineseRmb(testing.allocator, "1.2.3"));
    try testing.expectError(error.BadFormat, toChineseRmb(testing.allocator, "-"));
    try testing.expectError(error.TooLarge, toChineseRmb(testing.allocator, "10000000000000"));
}

test "zzig.rmb：parseCents 与 formatCentsAlloc 可分开用" {
    try testing.expectEqual(@as(i64, 123456), try parseCents("1,234.56"));
    try testing.expectEqual(@as(i64, -10000), try parseCents("-100"));
    try testing.expectEqual(@as(i64, 1250), try parseCents("12.5"));
    const text = try formatCentsAlloc(testing.allocator, 10005);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("壹佰元零伍分", text);
}
