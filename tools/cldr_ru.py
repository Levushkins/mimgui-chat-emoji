#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cldr_ru.py - собирает русские ключевые слова смайлов из Unicode CLDR
в компактный data/cldr_ru.json, по которому работает поиск по-русски
(«сердце», «огонь», «смех»).

Нужны два файла из репозитория CLDR (github.com/unicode-org/cldr):
    common/annotations/ru.xml
    common/annotationsDerived/ru.xml

    python3 tools/cldr_ru.py annotations/ru.xml annotationsDerived/ru.xml \
        -o data/cldr_ru.json

Данные CLDR распространяются по лицензии Unicode License v3
(https://www.unicode.org/license.txt), поэтому готовый словарь можно
класть в репозиторий вместе с этим уведомлением.

Зависимостей нет, только стандартная библиотека.
"""

import argparse
import json
import xml.etree.ElementTree as ET

VS16 = "️"


def read(path, out):
    root = ET.parse(path).getroot()
    for node in root.iter("annotation"):
        cp = (node.get("cp") or "").replace(VS16, "")
        # В атласе только одиночные кодовые точки: флаги, семьи и прочие
        # последовательности с ZWJ чат Arizona рисует по частям.
        if len(cp) != 1:
            continue
        entry = out.setdefault(ord(cp), {"tts": [], "kw": []})
        # Основное имя (type="tts", «огонь» у 🔥) идёт первым: поиск ставит
        # выше смайлы, у которых запрос совпал с началом списка слов.
        words = entry["tts"] if node.get("type") == "tts" else entry["kw"]
        text = (node.text or "").lower().replace("ё", "е")
        for part in text.split("|"):
            for w in part.split():
                w = w.strip(" ,.:;«»\"'()")
                if len(w) > 1 and w not in words:
                    words.append(w)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xml", nargs="+", help="annotations/ru.xml и annotationsDerived/ru.xml")
    ap.add_argument("-o", "--out", default="cldr_ru.json")
    args = ap.parse_args()

    words = {}
    for path in args.xml:
        read(path, words)

    data = {}
    for cp, entry in sorted(words.items()):
        ws = list(entry["tts"])
        ws += [w for w in entry["kw"] if w not in ws]
        if ws:
            data["%X" % cp] = " ".join(ws)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("{\n")
        f.write(",\n".join(' "%s": %s' % (k, json.dumps(v, ensure_ascii=False))
                           for k, v in data.items()))
        f.write("\n}\n")
    print("кодовых точек с русскими словами: %d -> %s" % (len(data), args.out))


if __name__ == "__main__":
    main()
