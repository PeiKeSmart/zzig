"""从 pypinyin 的多音词表提取**候选词**（只做候选，不作为最终拼音来源）。

流程（两步）：
    python tools/pinyin/gen-pinyin-candidates.py          # 候选 -> tools/pinyin_candidates.txt
    powershell -File tools/pinyin/check-pinyin-phrases.ps1 # 用 EzPinyin 逐个取拼音（C# 同源）
    python tools/pinyin/gen-pinyin-phrases.py              # 过滤 + 生成 src/text/pinyin_phrase_data.zig

为什么不用 pypinyin 的拼音：C# 站点用的是 EzPinyin，**最终读音一律以 EzPinyin 为准**。
pypinyin 在这里只提供「哪些词值得试」的候选集合。
pypinyin 是 MIT 许可；本脚本不把它的数据写进产物，产物只含经 EzPinyin 校验后的读音。
"""
import io
import os

from pypinyin import phrases_dict

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "pinyin_candidates.txt")


def is_hanzi(ch: str) -> bool:
    return "\u4e00" <= ch <= "\u9fa5"


def main() -> None:
    words = set()
    for w in phrases_dict.phrases_dict.keys():
        if 2 <= len(w) <= 4 and all(is_hanzi(c) for c in w):
            words.add(w)
    out = sorted(words)
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        for w in out:
            f.write(w + "\n")
    print("candidates=%d -> %s" % (len(out), OUT))


if __name__ == "__main__":
    main()
