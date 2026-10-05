# -*- coding: utf-8 -*-
"""推送前硬编码排查：只找**真实的机器/本地特定路径**，不把 res:// uid:// user:// 当命中。

上一版用 `[A-Z]:[\\/]` 太宽，把 `res://`（尾部 s://）和 `uid://`（d://）全吃进来了，
还扫了二进制文件产生乱码命中。这里：
  - 只扫文本文件（按后缀白名单），二进制一律跳过
  - 排除 Godot 的虚拟路径前缀 res:// user:// uid://
  - 盘符路径要求必须有真实目录名（C:\\Users\\... 、D:\\godot\\... 这类）
"""
import io
import os
import re
import subprocess
import sys

TEXT_EXT = {".gd", ".tscn", ".tres", ".godot", ".json", ".cfg", ".txt", ".md", ".py",
            ".ps1", ".import", ".svg", ".gitignore", ".uid", ".toml", ".yml", ".yaml"}

# 盘符路径：必须形如 X:\ 后面跟真实目录名，排除 res:// user:// uid://
DRIVE = re.compile(r"(?<![a-zA-Z0-9_])[A-Za-z]:[\\/](?:[^\s\"'<>|?*\r\n]{2,})")
UNIX = re.compile(r"(?<![a-zA-Z0-9_])/(?:Users|home|opt|usr/local|var|mnt|media)/[^\s\"'<>|\r\n]{2,}")
# 机器/账号特定线索
MACHINEY = re.compile(
    r"(?i)\b(?:wzx|D:\\godot|WorkBuddy|AppData[\\/]+Local[\\/]+Temp|"
    r"gh-proxy\.com|ghfast\.top|127\.0\.0\.1:7897|7897)\b")
# 可能的凭据/令牌
SECRET = re.compile(
    r"(?i)\b(?:api[_-]?key|secret|token|password|passwd|bearer|"
    r"ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{12,}|"
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----)\b")

VIRTUAL = ("res://", "user://", "uid://")


def is_texty(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in TEXT_EXT:
        return True
    return os.path.basename(path) in (".gitignore", "LICENSE", "README.md")


def looks_binary(path):
    try:
        with open(path, "rb") as fh:
            return b"\x00" in fh.read(4096)
    except OSError:
        return True


def main():
    root = os.getcwd()
    files = subprocess.check_output(["git", "ls-files"], text=True).split("\n")
    files = [f for f in files if f.strip()]

    drive_hits, unix_hits, machine_hits, secret_hits, binary_tracked = [], [], [], [], []

    for rel in files:
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            continue
        if not is_texty(rel):
            if rel.lower().endswith((".zip", ".exe", ".dll", ".png", ".jpg", ".ogg",
                                    ".ttf", ".pck", ".so")):
                binary_tracked.append((rel, os.path.getsize(full)))
            continue
        if looks_binary(full):
            binary_tracked.append((rel, os.path.getsize(full)))
            continue
        try:
            text = io.open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue

        for i, line in enumerate(text.split("\n"), 1):
            for m in DRIVE.finditer(line):
                v = m.group(0)
                if any(v.startswith(p) or v[2:3] in p[2:3] and p[1:3] == v[1:3]
                       for p in VIRTUAL if v[1:3].lower() == p[1:3].lower()):
                    continue
                # res:// → 匹配到的是 "s://..."，盘符字母是 s；user:// → r；uid:// → d
                if v[0].lower() in ("r", "u") and v[1:3].lower() in ("es", "id"):
                    continue
                drive_hits.append((rel, i, v.strip()))
            for m in UNIX.finditer(line):
                unix_hits.append((rel, i, m.group(0).strip()))
            for m in MACHINEY.finditer(line):
                machine_hits.append((rel, i, m.group(0).strip()))
            for m in SECRET.finditer(line):
                secret_hits.append((rel, i, m.group(0).strip()))

    def dump(title, rows, limit=40):
        print("=== %s：%d 处 ===" % (title, len(rows)))
        seen = set()
        shown = 0
        for rel, ln, val in rows:
            key = (rel, val)
            if key in seen:
                continue
            seen.add(key)
            if shown >= limit:
                print("   ... 其余 %d 处略" % (len(seen) - limit))
                break
            print("   %s:%d  ->  %s" % (rel, ln, val))
            shown += 1
        if not rows:
            print("   无")
        print()

    print("扫描 tracked 文件 %d 个\n" % len(files))
    dump("Windows 盘符绝对路径", drive_hits)
    dump("Unix 绝对路径", unix_hits)
    dump("机器/账号特定线索", machine_hits)
    dump("疑似凭据", secret_hits)

    print("=== 二进制/大文件也已入库：%d 个 ===" % len(binary_tracked))
    for rel, size in sorted(binary_tracked, key=lambda x: -x[1])[:20]:
        print("   %9.1f KB  %s" % (size / 1024.0, rel))
    if not binary_tracked:
        print("   无")
    return 0


if __name__ == "__main__":
    sys.exit(main())