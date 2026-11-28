"""用 EzPinyin dump 出的拼音文本生成 Zig 数据表 `src/text/pinyin_data.zig`。

用法（两步，可复现）：
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/pinyin/dump-pinyin.ps1
    python tools/pinyin/gen-pinyin-data.py

数据来源：EzPinyin 1.1.2（BSD-3.0）对 CJK 基本区 **U+4E00..U+9FA5** 的
**首选读音**（小写、无声调），共 20902 字 / 424 个独立读音。

生成物头部会保留 EzPinyin 的版权与许可全文（BSD-3.0 条件 1/2 要求）。
**不要手改** `pinyin_data.zig`：改了就跑一遍这两步重新生成。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
RAW = os.path.join(HERE, "pinyin_raw.txt")
LICENSE = os.path.join(
    os.environ["USERPROFILE"], ".nuget", "packages", "ezpinyin", "1.1.2", "LICENSE"
)
OUT = os.path.join(PROJECT, "src", "text", "pinyin_data.zig")

if not os.path.exists(RAW):
    sys.exit("missing %s — run tools/pinyin/dump-pinyin.ps1 first" % RAW)

lines = io.open(RAW, "r", encoding="utf-8", newline="").read().splitlines()
vals = []
for ln in lines:
    code, py = ln.split("\t")
    assert int(code, 16) == 0x4E00 + len(vals), ln
    assert py.isalpha() and py.islower(), ln
    vals.append(py)
assert len(vals) == 20902, len(vals)

# 读音按字典序排列（生成物稳定，diff 可读）
words = sorted(set(vals))
word_index = {w: i for i, w in enumerate(words)}
assert len(words) <= 65535

blob = "\0".join(words).encode("utf-8") + b"\0"
offsets = []
pos = 0
for w in words:
    offsets.append(pos)
    pos += len(w.encode("utf-8")) + 1
assert pos == len(blob)
assert max(offsets) < 65536, max(offsets)

idx = [word_index[v] for v in vals]

lic = io.open(LICENSE, "r", encoding="utf-8-sig", newline="").read().strip()
# Zig 注释里不允许 Tab 字节（`comment contains invalid byte: '\t'`），统一换成 4 空格；
# 许可正文内容不变。
lic_lines = "\n".join(
    ("//! " + l.replace("\t", "    ")) if l.strip() else "//!" for l in lic.splitlines()
)


def chunk_seq(items, per_line, indent="    ", fmt=str):
    out = []
    for i in range(0, len(items), per_line):
        out.append(indent + ", ".join(fmt(x) for x in items[i : i + per_line]) + ",")
    return "\n".join(out)


# blob 每行约 84 字节切分（按词边界切，可读性更好）
blob_parts = []
cur = []
cur_len = 0
for w in words:
    piece = w + "\\x00"
    if cur_len + len(piece) > 84 and cur:
        blob_parts.append("".join(cur))
        cur = []
        cur_len = 0
    cur.append(piece)
    cur_len += len(piece)
if cur:
    blob_parts.append("".join(cur))
# Zig 没有 C 那种相邻字面量自动拼接，用 `++`（comptime 求值，零运行时开销）
blob_src = "\n        ++ ".join('"%s"' % p for p in blob_parts)

header = '''//! 汉字拼音数据表（自动生成，不要手改）。
//!
//! 生成方式（可复现）：用 EzPinyin 1.1.2 对 CJK 基本区整段取 `PinyinHelper.GetArray`，
//! 得到每个字的**首选读音**（小写、无声调），再按本文件的紧凑格式落盘。
//! 重新生成见 `tools/pinyin/dump-pinyin.ps1` + `tools/pinyin/gen-pinyin-data.py`。
//!
//! 覆盖范围：U+4E00 .. U+9FA5（20902 字，CJK 统一表意文字基本区）。表外的码位一律原样输出。
//! 多音字只存首选读音（与 C# 站点 `PinYinController` → `PinyinHelper` 的**单字**行为一致；
//! 但 C# 版另有词组词典能消歧，本实现没有：`重庆` → `zhong qing`、`银行` → `yin xing`）。
//!
//! ---- 数据来源与许可（BSD-3.0，条件 1/2 要求保留）----
%s
//! ----------------------------------------------------

'''

body = []
body.append(header % lic_lines)
body.append("pub const FIRST_CODE: u21 = 0x4E00;")
body.append("pub const LAST_CODE: u21 = 0x9FA5;")
body.append("pub const CHAR_COUNT: usize = %d;" % len(vals))
body.append("pub const WORD_COUNT: usize = %d;" % len(words))
body.append("")
body.append("/// 全部读音（NUL 分隔，`WORD_OFFSET[i]` 指向第 i 个读音的起始字节）。")
body.append("pub const WORD_BLOB: []const u8 =")
body.append(blob_src + ";")
body.append("")
body.append("/// 每个读音在 `WORD_BLOB` 里的起始偏移。")
body.append("pub const WORD_OFFSET: [WORD_COUNT]u16 = .{")
body.append(chunk_seq(offsets, 16))
body.append("};")
body.append("")
body.append("/// 每个字的读音下标（`code - FIRST_CODE`）。")
body.append("pub const CHAR_INDEX: [CHAR_COUNT]u16 = .{")
rows = []
for i in range(0, len(idx), 16):
    rows.append("    // U+%04X" % (0x4E00 + i))
    rows.append(chunk_seq(idx[i : i + 16], 16))
body.append("\n".join(rows))
body.append("};")
body.append("")

text = "\n".join(body)
io.open(OUT, "w", encoding="utf-8", newline="\n").write(text)
print("wrote %s (%d bytes); words=%d blob=%d" % (OUT, len(text), len(words), len(blob)))
