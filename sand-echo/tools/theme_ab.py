# -*- coding: utf-8 -*-
"""按 on/off 切换 project.godot 的全局主题，供 A/B 测量使用。

根因（v2/v3 的 0.8 MB 差值不可信就是这个）：project.godot 里的实际行是
    theme/custom="res://assets/ui/ui_theme.tres"
位于 [gui] 段下，**行首没有 gui/ 前缀**。此前 A/B 脚本的目标串写成
'gui/theme/custom="..."'，永远匹配不上（出现 0 次），于是「无字体」对照组
其实也加载了字体 —— 两边都加载，差值自然趋近 0。

所以这里用「整行精确匹配 + 跑完回读自检」，不匹配就报错退出而不是静默取数。
"""
import io
import os
import sys

PG = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "project.godot")
LINE_ON = 'theme/custom="res://assets/ui/ui_theme.tres"'
LINE_OFF = 'theme/custom=""'


def current_line(text):
    for line in text.split("\n"):
        if line.strip().startswith("theme/custom"):
            return line.strip()
    return None


def apply(on):
    text = io.open(PG, encoding="utf-8").read()
    before = current_line(text)
    if on:
        if before == LINE_OFF:
            text = text.replace(LINE_OFF, LINE_ON)
        elif before != LINE_ON:
            raise SystemExit("theme/custom 行不是预期形态：%r" % before)
    else:
        if before == LINE_ON:
            text = text.replace(LINE_ON, LINE_OFF)
        elif before != LINE_OFF:
            raise SystemExit("theme/custom 行不是预期形态：%r" % before)
    io.open(PG, "w", encoding="utf-8").write(text)
    # 回读自检：写完必须与预期一致，否则下面的测量就是假对照
    after = current_line(io.open(PG, encoding="utf-8").read())
    want = LINE_ON if on else LINE_OFF
    if after != want:
        raise SystemExit("写入后回读不一致：期望 %r，实得 %r" % (want, after))
    return before, after


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "on"
    b, a = apply(mode == "on")
    print("theme/custom: %r -> %r" % (b, a))