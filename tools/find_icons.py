#!/usr/bin/env python3
"""find_icons.py - в каком файле сборки лежат нужные иконки.

Arizona вырезала часть иконок из `_chat.asi`, но в игре они по-прежнему
рисуются. Значит артворк переехал в другой файл сборки. Этот скрипт
обходит папку, вытаскивает шрифты отовсюду, где они могут лежать, и
говорит, в каком файле нашлись искомые кодовые точки.

Где ищет шрифты:
  * отдельные .ttf / .otf / .ttc;
  * ресурсы PE-файлов (.asi / .dll / .exe), в том числе сжатые
    stb_compress, как в самом _chat.asi;
  * сырые sfnt-врезки где угодно внутри файла - так шрифты лежат
    в паках и архивах без сжатия.

Зависимостей нет, только стандартная библиотека.

    python3 tools/find_icons.py "C:/Games/Arizona Games Launcher/bin/arizona"
    python3 tools/find_icons.py <папка> --cp F240 F241 1FC39
    python3 tools/find_icons.py <папка> --from-atlas   (искать все legacy)
"""

import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from extract_chat_emoji import (PE, is_stb_compressed, stb_decompress,  # noqa: E402
                               font_codepoints, font_family)

SFNT_MAGIC = (b"\x00\x01\x00\x00", b"OTTO", b"true", b"ttcf")

# Иконки, выкинутые из icons.ttf в сборке 31.10.2026: 56 убранных из cmap
# плюс 13, у которых код остался, а глиф выпотрошен.
DEFAULT_TARGETS = (
    list(range(0xF230, 0xF23D)) + list(range(0xF240, 0xF24F))
    + [0xF260, 0xF261] + list(range(0xF265, 0xF26B))
    + list(range(0x1FC24, 0x1FC29)) + [0x1FC2C, 0x1FC2E, 0x1FC33]
    + list(range(0x1FC29, 0x1FC2C)) + [0x1FC2D]
    + list(range(0x1FC2F, 0x1FC33)) + list(range(0x1FC36, 0x1FC39))
    + list(range(0x1FC39, 0x1FC47))
)


def num_glyphs(ttf):
    """Сколько глифов в шрифте по таблице maxp. Вырезанный шрифт видно
    именно по этому числу: cmap может остаться, а глифы опустеть."""
    try:
        num_tables = struct.unpack_from(">H", ttf, 4)[0]
        for i in range(num_tables):
            off = 12 + i * 16
            if ttf[off:off + 4] == b"maxp":
                t = struct.unpack_from(">I", ttf, off + 8)[0]
                return struct.unpack_from(">H", ttf, t + 4)[0]
    except Exception:
        pass
    return 0


def sane_sfnt(blob, off):
    """Похоже ли на настоящий sfnt: разумное число таблиц и есть cmap."""
    try:
        num = struct.unpack_from(">H", blob, off + 4)[0]
        if not (1 <= num <= 64):
            return False
        if off + 12 + num * 16 > len(blob):
            return False
        for i in range(num):
            tag = blob[off + 12 + i * 16: off + 16 + i * 16]
            if tag == b"cmap":
                return True
    except Exception:
        pass
    return False


def fonts_in(blob, label):
    """Отдаёт пары (как нашли, байты шрифта)."""
    out = []

    if blob[:4] in SFNT_MAGIC:
        out.append(("файл целиком", blob))

    # ресурсы PE
    try:
        pe = PE(blob)
        for path, res in pe.resources():
            data = res
            how = "ресурс %s" % (path,)
            if is_stb_compressed(res):
                try:
                    data = stb_decompress(res)
                    how += " (stb)"
                except Exception:
                    continue
            if data[:4] in SFNT_MAGIC:
                out.append((how, data))
    except Exception:
        pass

    # сырые врезки
    if not out:
        for magic in SFNT_MAGIC:
            start = 0
            while True:
                i = blob.find(magic, start)
                if i < 0:
                    break
                start = i + 4
                if sane_sfnt(blob, i):
                    out.append(("врезка со смещения 0x%X" % i, blob[i:]))
                    if len(out) > 8:
                        break
    return out


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", help="папка сборки, например bin/arizona")
    ap.add_argument("--cp", nargs="*", default=None,
                    help="кодовые точки в hex, например F240 1FC39")
    ap.add_argument("--max-mb", type=float, default=200.0,
                    help="не трогать файлы больше этого размера")
    ap.add_argument("--all", action="store_true",
                    help="печатать и файлы без совпадений")
    args = ap.parse_args()

    if args.cp:
        targets = set(int(c, 16) for c in args.cp)
    else:
        targets = set(DEFAULT_TARGETS)
    print("ищу %d кодовых точек в %s" % (len(targets), args.root))
    print()

    limit = int(args.max_mb * 1024 * 1024)
    found_any = False
    scanned = 0

    for dirpath, _dirnames, filenames in os.walk(args.root):
        for fn in sorted(filenames):
            path = os.path.join(dirpath, fn)
            try:
                if os.path.getsize(path) > limit:
                    continue
                blob = open(path, "rb").read()
            except Exception:
                continue
            scanned += 1

            for how, ttf in fonts_in(blob, fn):
                try:
                    cps = font_codepoints(ttf)
                except Exception:
                    continue
                hit = targets & cps
                rel = os.path.relpath(path, args.root)
                if hit:
                    found_any = True
                    fam = font_family(ttf) or "?"
                    print("НАЙДЕНО  %s" % rel)
                    print("    %s, семейство %s, в cmap %d, глифов %d"
                          % (how, fam, len(cps), num_glyphs(ttf)))
                    print("    совпало %d из %d: %s"
                          % (len(hit), len(targets),
                             " ".join("U+%05X" % c for c in sorted(hit)[:12])
                             + (" ..." if len(hit) > 12 else "")))
                    print()
                elif args.all:
                    print("пусто    %s (%s, cmap %d)" % (rel, how, len(cps)))

    print("просмотрено файлов: %d" % scanned)
    if not found_any:
        print()
        print("Ни в одном файле сборки искомых иконок нет.")
        print("Значит их рисует не шрифт: либо сервер шлёт картинки сам,")
        print("либо плагин подтягивает их по сети во время игры.")
    return 0 if found_any else 1


if __name__ == "__main__":
    raise SystemExit(main())
