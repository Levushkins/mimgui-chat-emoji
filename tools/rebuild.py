#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rebuild.py - полный цикл сборки набора смайлов.

  1. находит _chat.asi и распаковывает из него шрифты и списки смайлов
  2. находит цветной эмодзи-шрифт (Segoe UI Emoji)
  3. собирает атлас

Запускается двойным кликом по rebuild.bat либо напрямую:

    python tools/rebuild.py
    python tools/rebuild.py --asi "C:/.../bin/arizona/_chat.asi"
    python tools/rebuild.py --emoji "C:/Windows/Fonts/seguiemj.ttf"

Вся логика живёт здесь, а не в .bat, намеренно: cmd.exe читает батник в
кодировке консоли, и любой не-ASCII символ в нём ломает разбор команд.
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# где искать _chat.asi: рядом с собой и выше по дереву (игра обычно на
# пару уровней выше, если распаковать библиотеку внутрь её каталога)
ASI_DIRS = [ROOT, os.path.dirname(ROOT),
            os.path.dirname(os.path.dirname(ROOT)),
            os.path.dirname(os.path.dirname(os.path.dirname(ROOT)))]

# сам чат предпочитает свой fontcustom, если он лежит рядом с игрой
FONT_RELATIVE = [
    os.path.join("moonloader", "fontcustom", "seguiemj_1.45.ttf"),
    os.path.join("fontcustom", "seguiemj_1.45.ttf"),
]


def find_asi():
    for d in ASI_DIRS:
        p = os.path.join(d, "_chat.asi")
        if os.path.isfile(p):
            return p
    return None


def find_font():
    for d in ASI_DIRS:
        for rel in FONT_RELATIVE:
            p = os.path.join(d, rel)
            if os.path.isfile(p):
                return p
    system = os.path.join(os.environ.get("WINDIR", r"C:\Windows"),
                          "Fonts", "seguiemj.ttf")
    if os.path.isfile(system):
        return system
    return None


def run(args):
    print("    $ " + " ".join(os.path.basename(a) if os.path.sep in a else a
                              for a in args[1:]))
    code = subprocess.call(args)
    if code != 0:
        sys.exit("[!] шаг завершился с ошибкой (код %d)" % code)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--asi", help="путь к _chat.asi")
    ap.add_argument("--emoji", help="путь к цветному эмодзи-шрифту")
    ap.add_argument("--cell", type=int, default=40, help="размер ячейки, px")
    ap.add_argument("--width", type=int, default=2048, help="ширина атласа")
    args = ap.parse_args()

    os.chdir(ROOT)
    data = os.path.join(ROOT, "data")
    out = os.path.join(ROOT, "moonloader", "resource", "chat_emoji")

    try:
        import PIL  # noqa: F401
    except ImportError:
        sys.exit("[!] нужен Pillow:  python -m pip install pillow")

    # --- шаг 1: распаковка _chat.asi ---------------------------------------
    asi = args.asi or find_asi()
    if asi:
        print("[1/2] _chat.asi: %s" % asi)
        run([sys.executable, os.path.join("tools", "extract_chat_emoji.py"),
             asi, "-o", data])
    elif os.path.isfile(os.path.join(data, "emoji.json")):
        print("[1/2] _chat.asi не найден, беру готовый data/emoji.json")
    else:
        sys.exit("[!] не найден ни _chat.asi, ни data/emoji.json.\n"
                 '    Укажите путь:  rebuild.bat --asi "C:\\...\\_chat.asi"')

    # --- шаг 2: сборка атласа ----------------------------------------------
    font = args.emoji or find_font()
    if not font:
        sys.exit("[!] не найден эмодзи-шрифт.\n"
                 '    Укажите путь:  rebuild.bat --emoji '
                 '"C:\\Windows\\Fonts\\seguiemj.ttf"')
    print("[2/2] эмодзи-шрифт: %s" % font)

    cmd = [sys.executable, os.path.join("tools", "build_emoji_atlas.py"),
           os.path.join(data, "emoji.json"),
           "--icons", os.path.join(data, "icons.ttf"),
           "--emoji", font,
           "-o", out,
           "--cell", str(args.cell), "--width", str(args.width)]
    big = os.path.join(data, "big_icons.ttf")
    if os.path.isfile(big):
        cmd[cmd.index("--icons") + 2:cmd.index("--icons") + 2] = \
            ["--big-icons", big]
    run(cmd)

    print("\nГотово. Скопируйте в папку moonloader:")
    print("    moonloader/lib/chat_emoji.lua")
    print("    moonloader/resource/chat_emoji/chat_emoji.png")
    print("    moonloader/resource/chat_emoji/chat_emoji_atlas.lua")


if __name__ == "__main__":
    main()
