#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_emoji_atlas.py - рендерит смайлы из emoji.json в один цветной атлас
(PNG) и генерирует Lua-описание с координатами.

Зачем атлас, а не шрифт: mimgui собран со stb_truetype и 16-битным ImWchar,
поэтому он не умеет ни цветные глифы (COLR/CPAL, SVG), ни кодовые точки
выше U+FFFF. Смайлы же живут в U+1F300…U+1FAFF. Единственный рабочий путь -
заранее растеризовать их в текстуру и рисовать через imgui.Image.

Смайлы берутся из двух шрифтов:
  * icons.ttf   - распакован из _chat.asi, содержит серверные иконки
                  (U+F2xx/U+F3xx, U+1FCxx) и буквы-плашки U+1F1Ex
  * Segoe UI Emoji (seguiemj.ttf) - стандартные смайлы U+1F300+,
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
import unicodedata
import zlib

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("нужен Pillow:  pip install pillow")


# --------------------------------------------------------------------------
# Разбор cmap - чтобы понять, какие кодовые точки есть в шрифте
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

    # (3,10) - полный Unicode, (3,1) - только BMP
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


# У цветных шрифтов (COLR/CPAL - Segoe UI Emoji, icons.ttf) базовый контур
# глифа часто пустой: всё изображение лежит в слоях COLR. Pillow берёт размер
# маски из контуров, поэтому строка из одного такого символа даёт маску
# нулевой высоты и на холст не попадает ничего.
#
# Обход: дорисовываем слева «распорку» - символ с непустым контуром. Он задаёт
# размер маски, а потом отрезается по своему авансу.
#
# Важно: маску задаёт именно КОНТУР распорки, а не картинка нужного символа.
# У .notdef в icons.ttf высота всего 0.62 em, а серверные баннеры («ВИП ЧАТ»,
# BUY/SELL) занимают целый em - из-за этого у них срезало низ. Поэтому
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
    «прокладка» - чтобы линия обрезки прошла правее чернил распорки.
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
            # маска нормальной высоты - символ нарисовался целиком
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


def lua_bytes(raw):
    """Байты в Lua-строку целиком в ASCII: всё не-ASCII уходит в \\ddd."""
    out = []
    for b in raw:
        c = chr(b)
        if b < 0x20 or b >= 0x7F:
            out.append("\\%03d" % b)     # ровно три цифры: Lua дальше не читает
        elif c in ("'", "\\"):
            out.append("\\" + c)
        else:
            out.append(c)
    return "'" + "".join(out) + "'"


def lua_str(s):
    """Строка для Lua целиком в ASCII: не-ASCII байты уходят в \\ddd.

    Так сгенерированные файлы невозможно испортить пересохранением в другой
    кодировке - а именно на этом всё и спотыкается: ImGui ждёт UTF-8, а
    блокнот по умолчанию пишет cp1251.
    """
    return lua_bytes(s.encode("utf-8"))


def unicode_alias(cp):
    """Стабильное английское имя по базе Unicode: U+1F34E -> 'red_apple'.

    Имена из таблицы плагина Arizona иногда переезжают: в сентябре 2026 имя
    'apple' ушло от 🍎 к логотипу Apple. Имя из Unicode от плагина не
    зависит, поэтому emoji.get('red_apple') находит яблоко при любой версии.
    """
    try:
        name = unicodedata.name(chr(cp))
    except ValueError:
        return None
    alias = "".join(c if c.isalnum() else "_" for c in name.lower())
    while "__" in alias:
        alias = alias.replace("__", "_")
    return alias.strip("_") or None


# Русские слова для иконок Arizona, которых нет в Unicode и, значит, в CLDR.
# Оружие подписано по номерам GTA, порядок сверен по картинкам атласа.
EXTRA_RU = {
    0x1FC39: "телеграм телега тг", 0x1FC3A: "вконтакте вк",
    0x1FC3B: "алфавит гугл google", 0x1FC3C: "амазон",
    0x1FC3D: "эпл айфон", 0x1FC3E: "бмв бэха", 0x1FC3F: "мерседес мерс",
    0x1FC40: "майкрософт", 0x1FC41: "нвидиа видеокарта",
    0x1FC42: "индекс биржа акции", 0x1FC43: "спейсикс ракета",
    0x1FC44: "тесла", 0x1FC45: "тойота", 0x1FC46: "фольксваген",
}
WEAPONS_RU = [
    "кулак", "кастет", "клюшка гольф", "дубинка", "нож", "бита", "лопата",
    "кий", "катана", "бензопила", "дилдо", "дилдо", "вибратор", "вибратор",
    "цветы букет", "трость", "граната", "слезоточивый газ", "коктейль молотова",
    None, None, None,
    "кольт пистолет", "пистолет глушитель", "дигл deagle пистолет",
    "дробовик шотган", "обрез", "спас дробовик", "узи", "мп5 mp5",
    "калаш ак-47 автомат", "м4 m4 автомат", "тек-9", "винтовка",
    "снайперка снайперская винтовка", "рпг гранатомет", "ракетница",
    "огнемет", "миниган пулемет", "сумка взрывчатка", "детонатор",
    "баллончик краска", "огнетушитель", None, "очки ночного видения",
    "тепловизор", "парашют",
]


def weapon_cp(wid):
    """Номер оружия GTA -> кодовая точка иконки Arizona (или None)."""
    if 0 <= wid <= 18:
        return 0xF300 + wid
    if 22 <= wid <= 42:
        return 0xF300 + wid - 3
    return {44: 0xF329, 45: 0xF329, 46: 0xF32A}.get(wid)


def russian_words(cldr, cp):
    words = []
    if cldr and ("%X" % cp) in cldr:
        words.append(cldr["%X" % cp])
    if cp in EXTRA_RU:
        words.append(EXTRA_RU[cp])
    for wid, ru in enumerate(WEAPONS_RU):
        if ru and weapon_cp(wid) == cp:
            words.append(ru)
    text = " ".join(words).lower().replace("ё", "е")
    seen, out = set(), []
    for w in text.split():
        if w not in seen:
            seen.add(w)
            out.append(w)
    return " ".join(out)


def crc32_file(path):
    with open(path, "rb") as f:
        return "%08x" % (zlib.crc32(f.read()) & 0xFFFFFFFF)


LUA_HEADER = """-- Автоматически сгенерировано build_emoji_atlas.py.
-- Не редактировать вручную.
--
-- Запись: { name, cp, cat, slot, cells, aliases }
--   slot  - номер ячейки, отсчёт слева направо, сверху вниз
--   cells - сколько ячеек по горизонтали занимает глиф. Широкие серверные
--           баннеры («ВИП ЧАТ», ленты) занимают несколько, иначе от них
--           оставалась бы нечитаемая полоска. Он же задаёт пропорции при
--           отрисовке: ширина = высота * cells.
--
-- UV-координаты считаются в chat_emoji.lua как:
--   u0 = (slot %% cols) * cell / width,  v0 = floor(slot / cols) * cell / height
--   u1 = u0 + cells * cell / width,      v1 = v0 + cell / height
--
-- Версия 3 добавила к версии 2 только поля верхнего уровня (hash, small,
-- source, categories), сами записи прежние: библиотека 3.1 и старше читает
-- этот файл без изменений.
--   hash       - CRC32 файла атласа; по нему скрипты делят одну текстуру
--   small      - тот же атлас вдвое меньше, для смайлов до 20 px
--   source     - размер и время сборки _chat.asi, из которого всё извлечено
--   categories - короткие ASCII-имена категорий

return {
  version = 3,
  file   = '%s',
  width  = %d,
  height = %d,
  cell   = %d,
  cols   = %d,
  count  = %d,
  hash   = '%s',
%s  emoji  = {
"""

SEARCH_HEADER = """-- Автоматически сгенерировано build_emoji_atlas.py.
-- Русские ключевые слова для поиска. Источник - Unicode CLDR
-- (annotations/ru.xml, лицензия Unicode License v3,
-- https://www.unicode.org/license.txt) плюс подписи иконок Arizona.
--
-- Строки в cp1251 и записаны escape-последовательностями: так файл вдвое
-- меньше, чем в UTF-8, и не портится пересохранением. Библиотека читает его
-- только при первом поиске, скриптам без панели он не стоит ничего.

return {
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
    ap.add_argument("--pow2", action="store_true",
                    help="округлять высоту до степени двойки, как до 3.2 "
                         "(лишние ~5 МБ видеопамяти)")
    ap.add_argument("--no-small", action="store_true",
                    help="не собирать уменьшенный атлас для мелких смайлов")
    ap.add_argument("--source", help="source.json от extract_chat_emoji.py "
                                     "(по умолчанию рядом с emoji.json)")
    ap.add_argument("--keywords", help="cldr_ru.json от cldr_ru.py "
                                       "(по умолчанию рядом с emoji.json)")
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
    # и мелкий значок выходил одного размера с крупным баннером - пропорции
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
        # если упёрлись в лимит ячеек - ужимаем только этот глиф
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

    # Раньше высота округлялась до степени двойки: 34 ряда по 40 px давали
    # 1360 px, а текстура выходила 2048 - треть видеопамяти уходила на
    # пустоту. Библиотека создаёт текстуру с D3DX_DEFAULT_NONPOW2 и сверяет
    # реальный размер, так что округление больше не нужно. Высота кратна 8:
    # тогда и у малого атласа (ровно вдвое меньше) она кратна 4, а этого
    # требует сжатие DXT5 (emoji.FORMAT = 'dxt5').
    height = rows * args.cell
    if args.pow2:
        h2 = 1
        while h2 < height:
            h2 *= 2
        height = h2
    height = (height + 7) // 8 * 8
    atlas = Image.new("RGBA", (args.width, height), (0, 0, 0, 0))
    for _it, img, _n, slot in placed:
        x = (slot % cols) * args.cell
        y = (slot // cols) * args.cell
        atlas.paste(img, (x, y))

    png = os.path.join(args.out, args.name + ".png")
    atlas.save(png, optimize=True)
    wide = sum(1 for _i, _g, n, _s in placed if n > 1)
    print("атлас: %s  %dx%d, ячейка %d, %d смайлов (широких %d), %.1f МБ видеопамяти" %
          (png, args.width, height, args.cell, len(placed), wide,
           args.width * height * 4 / 1048576.0))
    if missing:
        print("не найдено в шрифтах (%d): %s" %
              (len(missing), ", ".join(m["name"] for m in missing[:20])))

    # Уменьшенная копия для мелких размеров. ImGui рисует атлас без
    # mip-уровней, и при 12-16 px из ячейки 40 картинка рябит. Раскладка
    # та же, ячейки ровно вдвое меньше - значит, и UV у записей те же самые,
    # библиотеке достаточно подменить текстуру. Каждый блок уменьшается
    # отдельно, иначе фильтр затягивал бы на край пиксели соседней ячейки.
    small_line = ""
    if not args.no_small and args.cell % 2 == 0 and args.width % 2 == 0:
        sc = args.cell // 2
        sw, sh = args.width // 2, height // 2
        small = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
        for _it, _img, n, slot in placed:
            x = (slot % cols) * args.cell
            y = (slot // cols) * args.cell
            block = atlas.crop((x, y, x + n * args.cell, y + args.cell))
            block = block.resize((n * sc, sc), Image.LANCZOS)
            small.paste(block, (x // 2, y // 2))
        spng = os.path.join(args.out, args.name + "_small.png")
        small.save(spng, optimize=True)
        print("малый атлас: %s  %dx%d, %.1f МБ видеопамяти" %
              (spng, sw, sh, sw * sh * 4 / 1048576.0))
        small_line = ("  small  = { file = '%s', width = %d, height = %d, "
                      "cell = %d, hash = '%s' },\n"
                      % (args.name + "_small.png", sw, sh, sc, crc32_file(spng)))

    base = os.path.dirname(os.path.abspath(args.json))
    source_path = args.source or os.path.join(base, "source.json")
    source_line = ""
    if os.path.isfile(source_path):
        src = json.load(open(source_path, encoding="utf-8"))
        source_line = ("  source = { file = %s, size = %d, stamp = 0x%08X },\n"
                       % (lua_str(src.get("file", "_chat.asi")),
                          src["size"], src["stamp"]))
    else:
        print("source.json не найден - библиотека не сможет заметить, "
              "что атлас устарел")

    cat_ids = []
    for it, _img, _n, _slot in placed:
        pair = (it["cat"], it.get("catId") or "")
        if pair not in cat_ids:
            cat_ids.append(pair)
    cats_line = "  categories = {\n%s  },\n" % "".join(
        "    { id = %s, name = %s },\n" % (lua_str(cid), lua_str(cat))
        for cat, cid in cat_ids if cid)

    lua = os.path.join(args.out, args.name + "_atlas.lua")
    used_names = set(n for it in items for n in (it.get("names") or []))
    with open(lua, "w", encoding="utf-8") as f:
        f.write(LUA_HEADER % (args.name + ".png", args.width, height,
                              args.cell, cols, len(placed), crc32_file(png),
                              small_line + source_line + cats_line))
        q = lua_str

        for it, _img, n, slot in placed:
            names = it.get("names") or []
            aliases = list(names[1:])    # синонимы: ':)', '<3' и подобные
            uni = unicode_alias(it["cp"])
            if uni and uni != it["name"] and uni not in names \
                    and uni not in used_names:
                aliases.append(uni)
            row = "    { %s, 0x%05X, %s, %d, %d" % (
                q(it["name"]), it["cp"], q(it["cat"]), slot, n)
            if aliases:
                row += ", { %s }" % ", ".join(q(a) for a in aliases)
            f.write(row + " },\n")
        f.write("  },\n}\n")
    print("описание: %s" % lua)

    # Русские слова - отдельным файлом, который грузится только при поиске.
    kw_path = args.keywords or os.path.join(base, "cldr_ru.json")
    cldr = json.load(open(kw_path, encoding="utf-8")) if os.path.isfile(kw_path) else None
    if cldr is None:
        print("cldr_ru.json не найден - русский поиск будет только по категориям")
    search = os.path.join(args.out, args.name + "_search.lua")
    count = 0
    with open(search, "w", encoding="utf-8") as f:
        f.write(SEARCH_HEADER)
        for it, _img, _n, _slot in placed:
            words = russian_words(cldr, it["cp"])
            if not words:
                continue
            raw = words.encode("cp1251", errors="ignore")
            f.write("  [0x%05X] = %s,\n" % (it["cp"], lua_bytes(raw)))
            count += 1
        f.write("}\n")
    print("русский поиск: %s (%d смайлов)" % (search, count))


if __name__ == "__main__":
    main()
