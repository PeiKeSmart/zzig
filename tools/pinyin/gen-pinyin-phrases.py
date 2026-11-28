"""生成 Zig 词组消歧表 `src/text/pinyin_phrase_data.zig`。

输入（两步，可复现）：
    python tools/pinyin/gen-pinyin-candidates.py            # 候选词（pypinyin 多音词表，仅做候选）
    powershell -File tools/pinyin/check-pinyin-phrases.ps1  # 用 EzPinyin 取读音（C# 同源，最终口径）
    powershell -File tools/pinyin/dump-pinyin.ps1           # 单字首选读音（用于筛掉「无需消歧」的词）
    python tools/pinyin/gen-pinyin-phrases.py

产物只保留「整词读音 != 逐字首选读音拼接」的词 —— 其余走单字表即可，不必进表。
发音一律取 EzPinyin（C# 站点同一个库），不做任何人工改写。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
CHECKED = os.path.join(HERE, "pinyin_phrases_checked.txt")
RAW = os.path.join(HERE, "pinyin_raw.txt")
OUT = os.path.join(PROJECT, "src", "text", "pinyin_phrase_data.zig")

if not os.path.exists(CHECKED):
    sys.exit("missing %s — run tools/pinyin/check-pinyin-phrases.ps1 first" % CHECKED)
if not os.path.exists(RAW):
    sys.exit("missing %s — run tools/pinyin/dump-pinyin.ps1 first" % RAW)

# 单字首选读音（EzPinyin）
single = {}
for ln in io.open(RAW, "r", encoding="utf-8", newline="").read().splitlines():
    code, py = ln.split("\t")
    single[chr(int(code, 16))] = py
assert len(single) == 20902, len(single)

by_len = {2: [], 3: [], 4: []}
skipped_shape = 0
skipped_same = 0
for ln in io.open(CHECKED, "r", encoding="utf-8", newline="").read().splitlines():
    if not ln.strip():
        continue
    word, py = ln.split("\t")
    syllables = py.split(" ")
    # 音节数必须与字数一致（EzPinyin 对个别冷僻词会整段退化成单字/原样，丢弃）
    if len(syllables) != len(word):
        skipped_shape += 1
        continue
    if any(c not in single for c in word):
        skipped_shape += 1
        continue
    plain = "".join(single[c] for c in word)
    if "".join(syllables) == plain:
        # 逐字首选读音拼起来就是对的 → 不需要词组条目
        skipped_same += 1
        continue
    by_len[len(word)].append((word, py))

for n in by_len:
    by_len[n].sort()

total = sum(len(v) for v in by_len.values())
print("kept=%d (2:%d 3:%d 4:%d) skipped_same=%d skipped_shape=%d"
      % (total, len(by_len[2]), len(by_len[3]), len(by_len[4]), skipped_same, skipped_shape))

LINES = [
    "//! 拼音词组消歧表（自动生成，不要手改）。",
    "//!",
    "//! 生成方式（可复现）：",
    "//!   1. `python tools/pinyin/gen-pinyin-candidates.py` —— 从 pypinyin（MIT）的多音词表取候选；",
    "//!   2. `powershell -File tools/pinyin/check-pinyin-phrases.ps1` —— 用 **EzPinyin**（BSD-3.0，",
    "//!      C# 站点同一个库）取整词读音 —— 这是**最终口径**，本文件不做任何人工改写；",
    "//!   3. `powershell -File tools/pinyin/dump-pinyin.ps1` —— 单字首选读音，用来筛掉「无需消歧」的词；",
    "//!   4. `python tools/pinyin/gen-pinyin-phrases.py` —— 只保留「整词读音 != 逐字首选拼接」的词。",
    "//!",
    "//! 许可：EzPinyin 的数据随 `pinyin_data.zig` 一并保留 BSD-3.0 声明（见该文件头部）。",
    "//! 用法：`pinyin_tool` 在转换时做**最长匹配**（4 字 → 3 字 → 2 字），命中就用整词读音，",
    "//! 否则退回单字表 —— 这样 `重庆` → `chong qing`、`银行` → `yin hang`（与 C# 站点一致）。",
    "",
    "pub const Entry = struct {",
    "    word: []const u8,",
    "    /// 音节，空格分隔（如 `chong qing`）",
    "    pinyin: []const u8,",
    "};",
    "",
]

for n in (2, 3, 4):
    LINES.append("/// %d 字词（按词排序，供二分查找）" % n)
    LINES.append("pub const PHRASES_%d = [_]Entry{" % n)
    for word, py in by_len[n]:
        LINES.append('    .{ .word = "%s", .pinyin = "%s" },' % (word, py))
    LINES.append("};")
    LINES.append("")

LINES += [
    "/// 按字符数取桶（1 字没有词组条目）。",
    "pub fn bucketOf(char_count: usize) ?[]const Entry {",
    "    return switch (char_count) {",
    "        2 => &PHRASES_2,",
    "        3 => &PHRASES_3,",
    "        4 => &PHRASES_4,",
    "        else => null,",
    "    };",
    "}",
    "",
    "/// 在已按词排序的桶里二分查找（UTF-8 字节序，与 `std.mem.order` 一致）。",
    "pub fn lookup(bucket: []const Entry, word: []const u8) ?[]const u8 {",
    "    var lo: usize = 0;",
    "    var hi: usize = bucket.len;",
    "    while (lo < hi) {",
    "        const mid = lo + (hi - lo) / 2;",
    "        switch (std.mem.order(u8, bucket[mid].word, word)) {",
    "            .lt => lo = mid + 1,",
    "            .gt => hi = mid,",
    "            .eq => return bucket[mid].pinyin,",
    "        }",
    "    }",
    "    return null;",
    "}",
    "",
    "const std = @import(\"std\");",
    "",
    "test \"词组表：排序与二分查找\" {",
    "    const b = bucketOf(2).?;",
    "    try std.testing.expect(b.len > 0);",
    "    var prev: ?[]const u8 = null;",
    "    for (b) |e| {",
    "        if (prev) |p| try std.testing.expect(std.mem.order(u8, p, e.word) == .lt);",
    "        prev = e.word;",
    "    }",
    "    try std.testing.expect(lookup(b, \"重庆\") != null);",
    "    try std.testing.expect(lookup(b, \"不存在的词\") == null);",
    "}",
    "",
]

with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(LINES))

print("written %s (%d bytes)" % (OUT, os.path.getsize(OUT)))
