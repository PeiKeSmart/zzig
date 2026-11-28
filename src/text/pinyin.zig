//! 汉字转拼音（显示 / URL 口径，**EzPinyin 兼容**；对齐 C# 工具站的 `PinYinController`）。
//!
//! 与 **`Pek.ZCode` 的 `pinyin.zig` 是两件不同的事，不要互相替代**（2026-11-28 实测：
//! 对 U+4E00..U+9FA5 共 20,902 字逐一比对，**14,279 字结果不同**，其中绝大多数是 ZCode 表
//! 只覆盖 GB2312 子集、对扩展字返回空）：
//!
//! | 模块 | 口径 | 数据 | 用途 |
//! |---|---|---|---|
//! | `Pek.ZCode.pinyin` | C# `DH.NCore PinYin` 字节级兼容：**PascalCase 单字**（`Zhong`），只认 GB2312 区 | `pinyin_table.bin`（GB2312 派生） | 生成拼音码 / 与 C# 对拍 |
//! | **本模块** | **EzPinyin 兼容：小写词组消歧**（`重庆` → `chong qing`），覆盖 CJK 基本区整段 | `pinyin_data.zig`（单字首选读音）+ `pinyin_phrase_data.zig`（词组） | 显示、URL slug、检索 |
//!
//! 数据表见 `pinyin_data.zig`（U+4E00..U+9FA5 的首选读音，20902 字）与
//! `pinyin_phrase_data.zig`（词组消歧表，逐词读音取自**同一个** EzPinyin）。
//! 行为逐条对齐实测的 EzPinyin：
//! - **词组优先**（最长匹配 4→2 字）：`重庆` → `chong qing`、`银行` → `yin hang`、
//!   `音乐` → `yin yue` —— C# 站点用的是 EzPinyin 内置词典，本表逐词 dump 自同一库；
//! - 词组未命中时按单字首选读音；
//! - 连续非汉字（字母 / 数字 / 标点 / 空白 / emoji）**原样保留**，不拆不加空格；
//! - 追加拼音时，若已输出内容的末字节是 ASCII 字母，先补一个空格
//!   （`A中B` → `A zhong B`；`你好，世界！` → `ni hao，shi jie！`——标点后不补空格）；
//! - 表外码位（扩展 A/B 区等）原样输出，不报错。
//!
//! 数据来源：EzPinyin 1.1.2（BSD-3.0，许可全文保留在 `pinyin_data.zig` 头部）。
//! 重新生成见 `tools/pinyin/` 下的 6 个脚本（先 dump 再 gen，顺序写在各脚本开头）。

const std = @import("std");
const data = @import("pinyin_data.zig");
const phrase_data = @import("pinyin_phrase_data.zig");

/// 失败原因（**不含文案**：给用户看的中文提示由调用方决定）。
pub const Error = error{
    /// 输入为空（或只有空白）。
    Empty,
    /// 一个汉字都没转换出来（纯 ASCII / 全是表外码位）。
    NoChinese,
    OutOfMemory,
};

pub const Style = enum {
    /// 全拼小写（C# `bType = 0`）
    full,
    /// 全拼大写（C# `bType = 1`，对**整个结果**做 `ToUpper`，原样的 ASCII 也会变大写）
    full_upper,
    /// 首字母小写（扩展）
    initial,
    /// 首字母大写（扩展）
    initial_upper,

    /// C# 的 `bType` 口径（其它值当全拼小写）。
    pub fn fromBType(btype: i32) Style {
        return switch (btype) {
            1 => .full_upper,
            2 => .initial,
            3 => .initial_upper,
            else => .full,
        };
    }

    fn upper(self: Style) bool {
        return self == .full_upper or self == .initial_upper;
    }

    fn initialsOnly(self: Style) bool {
        return self == .initial or self == .initial_upper;
    }
};

fn isAsciiLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// 码位 → 读音（`null` 表示不在表内）。
pub fn pinyinOf(cp: u21) ?[]const u8 {
    if (cp < data.FIRST_CODE or cp > data.LAST_CODE) return null;
    const slot = data.CHAR_INDEX[@as(usize, cp - data.FIRST_CODE)];
    if (slot >= data.WORD_COUNT) return null;
    const start = data.WORD_OFFSET[slot];
    const rest = data.WORD_BLOB[start..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    return rest[0..end];
}

const PhraseHit = struct { word: []const u8, pinyin: []const u8, char_count: usize };

/// 从 `at` 开始做**最长匹配**（4 → 2 字）：命中词组表就返回整词读音。
/// 只有连续汉字才参与匹配（词表全是 CJK 基本区，遇到其它字符立即停止）。
fn matchPhrase(text: []const u8, at: usize) ?PhraseHit {
    var lens: [4]usize = undefined;
    var n: usize = 0;
    var p = at;
    while (n < 4 and p < text.len) {
        const l = std.unicode.utf8ByteSequenceLength(text[p]) catch break;
        if (p + l > text.len) break;
        const cp = std.unicode.utf8Decode(text[p .. p + l]) catch break;
        if (pinyinOf(cp) == null) break;
        lens[n] = l;
        n += 1;
        p += l;
    }
    var want = n;
    while (want >= 2) : (want -= 1) {
        var total: usize = 0;
        for (lens[0..want]) |l| total += l;
        const word = text[at .. at + total];
        if (phrase_data.bucketOf(want)) |bucket| {
            if (phrase_data.lookup(bucket, word)) |py| {
                return .{ .word = word, .pinyin = py, .char_count = want };
            }
        }
    }
    return null;
}

/// 文本 → 拼音。空文本返回 `error.Empty`，一个汉字都没转出来返回 `error.NoChinese`。
pub fn convert(allocator: std.mem.Allocator, text: []const u8, style: Style) Error![]u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.Empty;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const lastIsLetter = struct {
        fn call(bucket: *std.ArrayList(u8)) bool {
            if (bucket.items.len == 0) return false;
            return isAsciiLetter(bucket.items[bucket.items.len - 1]);
        }
    }.call;

    var i: usize = 0;
    var converted: usize = 0;
    while (i < text.len) {
        // ① 词组优先（最长匹配 4→2 字）：`重庆` → chong qing、`银行` → yin hang。
        //    C# 站点用的 EzPinyin 本身就带词组词典，本表逐词取自同一个库（不做人工改写）。
        if (matchPhrase(text, i)) |ph| {
            if (style.initialsOnly()) {
                var sit = std.mem.tokenizeScalar(u8, ph.pinyin, ' ');
                while (sit.next()) |syl| try out.append(allocator, syl[0]);
            } else {
                if (lastIsLetter(&out)) try out.append(allocator, ' ');
                var sit = std.mem.tokenizeScalar(u8, ph.pinyin, ' ');
                var first = true;
                while (sit.next()) |syl| {
                    if (!first) try out.append(allocator, ' ');
                    try out.appendSlice(allocator, syl);
                    first = false;
                }
            }
            converted += ph.char_count;
            i += ph.word.len;
            continue;
        }

        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const in_range = i + cp_len <= text.len;
        const cp: ?u21 = if (in_range) (std.unicode.utf8Decode(text[i .. i + cp_len]) catch null) else null;
        const py: ?[]const u8 = if (cp) |c| pinyinOf(c) else null;

        if (py) |pinyin| {
            // 音节之间：末字节是 ASCII 字母才补空格（对齐 EzPinyin：标点/空白后不补）
            if (!style.initialsOnly() and lastIsLetter(&out)) try out.append(allocator, ' ');
            if (style.initialsOnly()) {
                try out.append(allocator, pinyin[0]);
            } else {
                try out.appendSlice(allocator, pinyin);
            }
            converted += 1;
            i += cp_len;
            continue;
        }

        // 非汉字：**整段**原样输出（`abc123` 不拆成 `a b c123`）。段首若是 ASCII 字母且前面
        // 刚输出过拼音/字母，补一个空格 —— 对齐 EzPinyin：`中国人abc123` → `zhong guo ren abc123`，
        // 而 `你好，世界！` 的标点前后不补空格。
        const seg_start = i;
        while (i < text.len) {
            const l2 = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + l2 > text.len) {
                i = text.len;
                break;
            }
            const c2 = std.unicode.utf8Decode(text[i .. i + l2]) catch {
                i += l2; // 非法 UTF-8 字节也算非汉字段的一部分
                continue;
            };
            if (pinyinOf(c2) != null) break;
            i += l2;
        }
        const seg = text[seg_start..i];
        // 首字母模式 EzPinyin 不加任何分隔（`中国人abc123` → `zgrabc123`）
        if (!style.initialsOnly() and isAsciiLetter(seg[0]) and lastIsLetter(&out)) {
            try out.append(allocator, ' ');
        }
        try out.appendSlice(allocator, seg);
    }

    if (converted == 0) return error.NoChinese;

    if (style.upper()) {
        for (out.items) |*b| {
            if (b.* >= 'a' and b.* <= 'z') b.* -= 32;
        }
    }

    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "zzig.pinyin：常用词与多音字首选读音" {
    const cases = [_][2][]const u8{
        .{ "中国", "zhong guo" },
        .{ "你好，世界！", "ni hao，shi jie！" }, // 全角标点后不补空格
        .{ "中国人abc123", "zhong guo ren abc123" },
        // 词组消歧：读音全部取自 EzPinyin（C# 站点同一个库），与词表一致
        .{ "银行ATM机", "yin hang ATM ji" },
        .{ "A中B", "A zhong B" },
        .{ "  中", "  zhong" },
        .{ "中国  ", "zhong guo  " },
        .{ "重庆", "chong qing" },
        .{ "音乐", "yin yue" },
        .{ "长城", "chang cheng" },
        .{ "藏族", "zang zu" },
        // 词表里没有的组合仍然逐字取首选读音
        .{ "长", "zhang" },
    };
    for (cases) |case| {
        const got = try convert(testing.allocator, case[0], .full);
        defer testing.allocator.free(got);
        if (!std.mem.eql(u8, got, case[1])) {
            std.debug.print("\n拼音 {s}: 期望「{s}」实际「{s}」\n", .{ case[0], case[1], got });
            return error.TestUnexpectedResult;
        }
    }
}

test "zzig.pinyin：大写、首字母与非法输入" {
    const a = testing.allocator;

    // 大写是对**整个结果**做 ToUpper，原样的 ASCII 也变大写（对齐 C#）
    const upper = try convert(a, "中国人abc123", .full_upper);
    defer a.free(upper);
    try testing.expectEqualStrings("ZHONG GUO REN ABC123", upper);

    const initial = try convert(a, "中国人abc123", .initial);
    defer a.free(initial);
    try testing.expectEqualStrings("zgrabc123", initial);

    const punct = try convert(a, "你好，世界！", .initial);
    defer a.free(punct);
    try testing.expectEqualStrings("nh，sj！", punct);

    const space = try convert(a, "中文 测试", .initial_upper);
    defer a.free(space);
    try testing.expectEqualStrings("ZW CS", space);

    // 表外码位原样保留；若一个汉字都没有则明确报错
    try testing.expectError(error.NoChinese, convert(a, "abc 123", .full));
    try testing.expectError(error.Empty, convert(a, "   ", .full));

    const mixed = try convert(a, "abc中", .full);
    defer a.free(mixed);
    try testing.expectEqualStrings("abc zhong", mixed);
}

test "zzig.pinyin：bType 映射" {
    try testing.expectEqual(Style.full, Style.fromBType(0));
    try testing.expectEqual(Style.full_upper, Style.fromBType(1));
    try testing.expectEqual(Style.initial, Style.fromBType(2));
    try testing.expectEqual(Style.initial_upper, Style.fromBType(3));
    try testing.expectEqual(Style.full, Style.fromBType(9));
}

test "zzig.pinyin：数据表自检（不越界，全部是小写字母）" {
    try testing.expectEqual(@as(u21, 0x4E00), data.FIRST_CODE);
    try testing.expectEqual(@as(usize, 20902), data.CHAR_COUNT);
    try testing.expectEqual(@as(usize, 0x9FA5 - 0x4E00 + 1), data.CHAR_COUNT);
    try testing.expectEqualStrings("yi", pinyinOf(0x4E00).?); // 一
    try testing.expectEqualStrings("guo", pinyinOf(0x56FD).?); // 国
    try testing.expectEqualStrings("wo", pinyinOf(0x6211).?); // 我

    // 表外码位一律 null（ASCII / 扩展 B 区 / 越界）
    try testing.expect(pinyinOf('a') == null);
    try testing.expect(pinyinOf(0x20000) == null);
    try testing.expect(pinyinOf(data.LAST_CODE + 1) == null);

    // 每个读音串必须非空且全是小写 ASCII 字母（生成的表若被手改坏，这里会红）
    var slot: usize = 0;
    while (slot < data.WORD_COUNT) : (slot += 1) {
        const start = data.WORD_OFFSET[slot];
        try testing.expect(start < data.WORD_BLOB.len);
        const rest = data.WORD_BLOB[start..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.TestUnexpectedResult;
        try testing.expect(end > 0);
        for (rest[0..end]) |c| try testing.expect(c >= 'a' and c <= 'z');
    }
}
