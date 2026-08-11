#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_emoji_atlas.py — рендерит смайлы из emoji.json в один цветной атлас
(PNG) и генерирует Lua-описание с координатами.

Зачем атлас, а не шрифт: mimgui собран со stb_truetype и 16-битным ImWchar,
поэтому он не умеет ни цветные глифы (COLR/CPAL, SVG), ни кодовые точки
выше U+FFFF. Смайлы же живут в U+1F300…U+1FAFF. Единственный рабочий путь —
заранее растеризовать их в текстуру и рисовать через imgui.Image.

Смайлы берутся из двух шрифтов:
  * icons.ttf   — распакован из _chat.asi, содержит серверные иконки
                  (U+F2xx/U+F3xx, U+1FCxx) и буквы-плашки U+1F1Ex
  * Segoe UI Emoji (seguiemj.ttf) — стандартные смайлы U+1F300+,
                  именно его использует сам чат

    python3 build_emoji_atlas.py ../data/emoji.json \
        --icons ../data/icons.ttf \
        --emoji "C:/Windows/Fonts/seguiemj.ttf" \
        -o ../assets

Требуется Pillow (pip install pillow).
"""

import argparse
import math
import json
import os
import struct
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("нужен Pillow:  pip install pillow")


# --------------------------------------------------------------------------
# Разбор cmap — чтобы понять, какие кодовые точки есть в шрифте
# --------------------------------------------------------------------------

def font_codepoints(path):
    data = open(path, "rb").read()
    if data[:4] == b"ttcf":
        off = struct.unpack_from(">I", data, 12)[0]
    else:
        off = 0
    num_tables, = struct.unpack_from(">H", data, off + 4)
    cmap_off = None
    for i in range(num_tables):
        tag, _, toff, tlen = struct.unpack_from(">4sIII", data, off + 12 + i * 16)
        if tag == b"cmap":
            cmap_off = toff
            break
    if cmap_off is None:
        return set()

    n, = struct.unpack_from(">H", data, cmap_off + 2)
    subtables = []
    for i in range(n):
        pid, eid, sub = struct.unpack_from(">HHI", data, cmap_off + 4 + i * 8)
        subtables.append((pid, eid, cmap_off + sub))

    # (3,10) — полный Unicode, (3,1) — только BMP
    subtables.sort(key=lambda s: 0 if (s[0], s[1]) == (3, 10) else 1)
    out = set()
    for pid, eid, sub in subtables:
        fmt, = struct.unpack_from(">H", data, sub)
        if fmt == 12:
            ngroups, = struct.unpack_from(">I", data, sub + 12)
            for g in range(ngroups):
                start, end, _ = struct.unpack_from(">III", data, sub + 16 + g * 12)
                out.update(range(start, min(end, start + 0x10000) + 1))
        elif fmt == 4:
            segx2, = struct.unpack_from(">H", data, sub + 6)
            seg = segx2 // 2
            ends = struct.unpack_from(">%dH" % seg, data, sub + 14)
            starts = struct.unpack_from(">%dH" % seg, data, sub + 16 + segx2)
            for s, e in zip(starts, ends):
                if s == 0xFFFF:
                    continue
                out.update(range(s, e + 1))
        if out:
            break
    return out


# --------------------------------------------------------------------------
# Рендер
# --------------------------------------------------------------------------

def open_font(path, px):
    """Открывает шрифт; для битмап-шрифтов (Noto Color Emoji) подбирает
    ближайший доступный размер, вернув коэффициент масштаба."""
    try:
        return ImageFont.truetype(path, px), 1.0
    except OSError:
        for native in (109, 136, 128, 96, 64, 32):
            try:
                return ImageFont.truetype(path, native), px / float(native)
            except OSError:
                continue
        raise


# У цветных шрифтов (COLR/CPAL — Segoe UI Emoji, icons.ttf) базовый контур
# глифа часто пустой: всё изображение лежит в слоях COLR. Pillow берёт размер
# маски из контуров, поэтому строка из одного такого символа даёт маску
# нулевой высоты и на холст не попадает ничего.
#
# Обход: дорисовываем слева «распорку» — символ с непустым контуром. Он задаёт
# размер маски, а потом отрезается по своему авансу.
#
# Важно: маску задаёт именно КОНТУР распорки, а не картинка нужного символа.
# У .notdef в icons.ttf высота всего 0.62 em, а серверные баннеры («ВИП ЧАТ»,
# BUY/SELL) занимают целый em — из-за этого у них срезало низ. Поэтому
# распорка подбирается под конкретный шрифт: берутся самый «высокий» и самый
# «низкий» глифы, их объединённый контур накрывает любую картинку.
FALLBACK_SPACER = "\uE123"   # приватная область: почти всегда даёт .notdef


def _draw(text, font, canvas, origin):
    tmp = Image.new("RGBA", canvas, (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    try:
        d.text(origin, text, font=font, embedded_color=True)
    except Exception:
        return None
    return tmp


def _measure(font, cp, box):
    """Чернильная рамка одиночного символа относительно точки вставки."""
    canvas = (box * 8, box * 8)
    origin = (box * 2, box * 4)
    im = Image.new("RGBA", canvas, (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    try:
        d.text(origin, chr(cp), font=font, embedded_color=True)
        adv = font.getlength(chr(cp))
    except Exception:
        return None
    bb = im.getbbox()
    if bb is None:
        return None
    return {"cp": cp, "adv": adv,
            "top": bb[1] - origin[1], "bottom": bb[3] - origin[1],
            "right": bb[2] - origin[0]}


def pick_spacer(font, cps, box, limit=400):
    """Подбирает распорку под шрифт: строку, контур которой перекрывает по
    вертикали всё, что этот шрифт умеет рисовать.

    Возвращает (строка, суммарный аванс). Крайние по высоте глифы часто имеют
    чернила шире аванса, поэтому при необходимости в конец добавляется
    «прокладка» — чтобы линия обрезки прошла правее чернил распорки.
    """
    sample = sorted(c for c in cps if 0x20 < c <= 0x10FFFF)[:limit]
    stats = [s for s in (_measure(font, c, box) for c in sample) if s]
    if not stats:
        return FALLBACK_SPACER, font.getlength(FALLBACK_SPACER)

    highest = min(stats, key=lambda s: s["top"])
    deepest = max(stats, key=lambda s: s["bottom"])
    pads = [s for s in stats if s["adv"] > 0 and s["right"] <= s["adv"] + 1]
    pad = max(pads, key=lambda s: s["adv"] - s["right"]) if pads else None

    chosen = []
    for s in (highest, deepest):
        if all(c["cp"] != s["cp"] for c in chosen):
            chosen.append(s)

    for _ in range(8):
        adv = sum(s["adv"] for s in chosen)
        ink = max(s["right"] for s in chosen)
        if ink <= adv:
            break
        if pad is None:
            return FALLBACK_SPACER, font.getlength(FALLBACK_SPACER)
        chosen.append(pad)

    return ("".join(chr(s["cp"]) for s in chosen),
            sum(s["adv"] for s in chosen))


def render_glyph(ch, font, box, spacer=FALLBACK_SPACER, adv_spacer=None):
    """Рисует символ и возвращает обрезанное по содержимому RGBA-изображение."""
    try:
        adv = font.getlength(ch)
    except Exception:
        adv = 0
    if adv_spacer is None:
        try:
            adv_spacer = font.getlength(spacer)
        except Exception:
            adv_spacer = 0

    origin = (box * 2, box * 2)
    width = int(max(adv, box * 2) + adv_spacer) + box * 8
    canvas = (width, box * 6)

    tmp = _draw(ch, font, canvas, origin)
    if tmp is not None:
        bb = tmp.getbbox()
        if bb is not None and bb[3] - bb[1] >= box * 0.9:
            # маска нормальной высоты — символ нарисовался целиком
            return tmp.crop(bb)

    if not spacer:
        return tmp.crop(tmp.getbbox()) if (tmp and tmp.getbbox()) else None

    # Распорку отодвигаем вправо пробелами и режем по ним. Так символ не
    # ограничен ни справа (у части иконок чернила шире аванса), ни слева
    # (у иконок big_icons аванс нулевой, и рисуются они левее точки вставки).
    try:
        space_adv = font.getlength(" ")
    except Exception:
        space_adv = 0
    if space_adv > 0:
        gap = max(adv * 1.5, box * 2) + box
        n = int(gap / space_adv) + 1
        tmp = _draw(ch + " " * n + spacer, font, canvas, origin)
        if tmp is not None:
            cut = min(canvas[0], origin[0] + int(n * space_adv))
            tmp = tmp.crop((0, 0, cut, canvas[1]))
            bb = tmp.getbbox()
            if bb is not None:
                return tmp.crop(bb)

    # запасной путь: распорка перед символом, режем по её авансу
    if adv_spacer <= 0:
        return None
    tmp = _draw(spacer + ch, font, canvas, origin)
    if tmp is None:
        return None
    tmp = tmp.crop((origin[0] + int(round(adv_spacer)), 0, canvas[0], canvas[1]))
    bb = tmp.getbbox()
    return tmp.crop(bb) if bb else None


def cells_for(width, cell, pad, cap):
    """Сколько ячеек по горизонтали занимает глиф такой ширины."""
    return max(1, min(cap, int(math.ceil((width + pad * 2) / float(cell)))))


def place(img, size, box_w, box_h):
    """Кладёт глиф размера size в прямоугольник box_w x box_h по центру."""
    nw, nh = max(1, int(round(size[0]))), max(1, int(round(size[1])))
    img = img.resize((nw, nh), Image.LANCZOS)
    out = Image.new("RGBA", (box_w, box_h), (0, 0, 0, 0))
    out.paste(img, ((box_w - nw) // 2, (box_h - nh) // 2))
    return out


def lua_str(s):
    """Строка для Lua целиком в ASCII: не-ASCII байты уходят в \\ddd.

    Так сгенерированные файлы невозможно испортить пересохранением в другой
    кодировке — а именно на этом всё и спотыкается: ImGui ждёт UTF-8, а
    блокнот по умолчанию пишет cp1251.
    """
    out = []
    for b in s.encode("utf-8"):
        c = chr(b)
        if b < 0x20 or b >= 0x7F:
            out.append("\\%03d" % b)     # ровно три цифры: Lua дальше не читает
        elif c in ("'", "\\"):
            out.append("\\" + c)
        else:
            out.append(c)
    return "'" + "".join(out) + "'"


LUA_HEADER = """-- Автоматически сгенерировано build_emoji_atlas.py.
-- Не редактировать вручную.
--
-- Запись: { name, cp, cat, slot, cells, aliases }
--   slot  — номер ячейки, отсчёт слева направо, сверху вниз
--   cells — сколько ячеек по горизонтали занимает глиф. Широкие серверные
--           баннеры («ВИП ЧАТ», ленты) занимают несколько, иначе от них
--           оставалась бы нечитаемая полоска. Он же задаёт пропорции при
--           отрисовке: ширина = высота * cells.
--
-- UV-координаты считаются в chat_emoji.lua как:
--   u0 = (slot %% cols) * cell / width,  v0 = floor(slot / cols) * cell / height
--   u1 = u0 + cells * cell / width,      v1 = v0 + cell / height

return {
  version = 2,
  file   = '%s',
  width  = %d,
  height = %d,
  cell   = %d,
  cols   = %d,
  count  = %d,
  emoji  = {
"""


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("json", help="emoji.json от extract_chat_emoji.py")
    ap.add_argument("--icons", required=True, help="icons.ttf из _chat.asi")
    ap.add_argument("--big-icons", help="big_icons.ttf из _chat.asi")
    ap.add_argument("--emoji", help="цветной эмодзи-шрифт (seguiemj.ttf)")
    ap.add_argument("-o", "--out", default=".", help="каталог результата")
    ap.add_argument("--cell", type=int, default=40, help="размер ячейки, px")
    ap.add_argument("--max-cells", type=int, default=8,
                    help="сколько ячеек максимум занимает широкий глиф")
    ap.add_argument("--pad", type=int, default=2, help="отступ внутри ячейки")
    ap.add_argument("--width", type=int, default=2048, help="ширина атласа")
    ap.add_argument("--name", default="chat_emoji", help="имя выходных файлов")
    args = ap.parse_args()

    if not args.emoji:
        guess = os.path.join(os.environ.get("WINDIR", r"C:\Windows"),
                             "Fonts", "seguiemj.ttf")
        if os.path.exists(guess):
            args.emoji = guess
        else:
            sys.exit("укажите --emoji (путь к seguiemj.ttf или другому "
                     "цветному эмодзи-шрифту)")

    items = json.load(open(args.json, encoding="utf-8"))
    os.makedirs(args.out, exist_ok=True)

    icons_cps = font_codepoints(args.icons)
    big_cps = font_codepoints(args.big_icons) if args.big_icons else set()
    emoji_cps = font_codepoints(args.emoji)
    print("icons.ttf: %d кодовых точек, эмодзи-шрифт: %d" %
          (len(icons_cps), len(emoji_cps)))

    f_icons, s_icons = open_font(args.icons, args.cell)
    f_emoji, s_emoji = open_font(args.emoji, args.cell)
    f_big, s_big = (open_font(args.big_icons, args.cell)
                    if args.big_icons else (None, 1.0))

    # распорка подбирается под каждый шрифт отдельно: её контур задаёт высоту
    # маски, а значит и то, не срежет ли низ у крупных цветных картинок
    box_icons = int(args.cell / s_icons) if s_icons != 1.0 else args.cell
    box_emoji = int(args.cell / s_emoji) if s_emoji != 1.0 else args.cell
    sp_icons, spadv_icons = pick_spacer(f_icons, icons_cps, box_icons)
    if f_big is not None:
        box_big = int(args.cell / s_big) if s_big != 1.0 else args.cell
        sp_big, spadv_big = pick_spacer(f_big, big_cps, box_big)
    sp_emoji, spadv_emoji = pick_spacer(f_emoji, emoji_cps, box_emoji)
    print("распорка: icons %s, эмодзи %s" % (
        " ".join("U+%04X" % ord(c) for c in sp_icons) or "нет",
        " ".join("U+%04X" % ord(c) for c in sp_emoji) or "нет"))

    cols = args.width // args.cell
    raw = []
    missing = []
    for it in items:
        cp = it["cp"]
        ch = chr(cp)
        # серверные иконки есть только в icons.ttf, поэтому он в приоритете
        if cp in icons_cps:
            font, scale = f_icons, s_icons
            spacer, spadv = sp_icons, spadv_icons
        elif f_big is not None and cp in big_cps:
            font, scale = f_big, s_big
            spacer, spadv = sp_big, spadv_big
        elif cp in emoji_cps:
            font, scale = f_emoji, s_emoji
            spacer, spadv = sp_emoji, spadv_emoji
        else:
            missing.append(it)
            continue
        box = int(args.cell / scale) if scale != 1.0 else args.cell
        img = render_glyph(ch, font, box, spacer, spadv)
        if img is None:
            missing.append(it)
            continue
        # приводим к «пикселям ячейки»: шрифты открыты в разном масштабе
        raw.append((it, img, img.size[0] * scale, img.size[1] * scale))

    if not raw:
        sys.exit("не удалось отрисовать ни одного смайла")

    # Общий множитель на всех. Раньше каждый глиф растягивался на всю ячейку,
    # и мелкий значок выходил одного размера с крупным баннером — пропорции
    # между иконками терялись. Сам чат рисует их одним кеглем, поэтому и здесь
    # масштаб один: по самому высокому глифу, чтобы никто не вылез за ячейку.
    tallest = max(h for _it, _im, _w, h in raw)
    k = float(args.cell - args.pad * 2) / tallest
    print("общий масштаб %.3f (самый высокий глиф %.1f px)" % (k, tallest))

    rendered = []
    for it, img, w, h in raw:
        tw, th = w * k, h * k
        n = cells_for(tw, args.cell, args.pad, args.max_cells)
        n = min(n, cols)
        # если упёрлись в лимит ячеек — ужимаем только этот глиф
        fit = min(1.0, (n * args.cell - args.pad * 2) / tw) if tw > 0 else 1.0
        rendered.append((it, place(img, (tw * fit, th * fit),
                                   n * args.cell, args.cell), n))

    # раскладка: широкий глиф занимает несколько ячеек подряд и переносится
    # на следующий ряд целиком, не разрываясь на границе
    placed = []
    col = row = 0
    for it, img, n in rendered:
        if col + n > cols:
            col, row = 0, row + 1
        placed.append((it, img, n, row * cols + col))
        col += n
    rows = row + 1

    height = 1
    while height < rows * args.cell:
        height *= 2
    atlas = Image.new("RGBA", (args.width, height), (0, 0, 0, 0))
    for _it, img, _n, slot in placed:
        x = (slot % cols) * args.cell
        y = (slot // cols) * args.cell
        atlas.paste(img, (x, y))

    png = os.path.join(args.out, args.name + ".png")
    atlas.save(png, optimize=True)
    wide = sum(1 for _i, _g, n, _s in placed if n > 1)
    print("атлас: %s  %dx%d, ячейка %d, %d смайлов (широких %d)" %
          (png, args.width, height, args.cell, len(placed), wide))
    if missing:
        print("не найдено в шрифтах (%d): %s" %
              (len(missing), ", ".join(m["name"] for m in missing[:20])))

    lua = os.path.join(args.out, args.name + "_atlas.lua")
    with open(lua, "w", encoding="utf-8") as f:
        f.write(LUA_HEADER % (args.name + ".png", args.width, height,
                              args.cell, cols, len(placed)))
        q = lua_str

        for it, _img, n, slot in placed:
            names = it.get("names") or []
            row = "    { %s, 0x%05X, %s, %d, %d" % (
                q(it["name"]), it["cp"], q(it["cat"]), slot, n)
            if len(names) > 1:      # синонимы: ':)', '<3' и подобные
                row += ", { %s }" % ", ".join(q(a) for a in names[1:])
            f.write(row + " },\n")
        f.write("  },\n}\n")
    print("описание: %s" % lua)


if __name__ == "__main__":
    main()
