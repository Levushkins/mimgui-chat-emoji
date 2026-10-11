#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_release.py - собирает архив для GitHub Releases и форума.

    python tools/make_release.py            -> dist/chat_emoji-<версия>.zip

Версия берётся из emoji.VERSION в moonloader/lib/chat_emoji.lua. В архиве
папка moonloader, которую можно копировать в игру как есть, и примеры
отдельно: MoonLoader запускает все .lua из своей папки, а класть нужно один.
"""

import os
import re
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

EXAMPLES = [
    ("chat_emoji_showcase.lua", "всё новое в 3.2: /emjnew, автотур /emjtour"),
    ("chat_emoji_minimal.lua", "самый короткий пример: /sm"),
    ("chat_emoji_demo.lua", "панель выбора и витрина размеров: /emj"),
    ("chat_emoji_dialogs.lua", "конструктор диалогов SA-MP: /emjd"),
]

README = r"""chat_emoji {version} - смайлы и иконки чата Arizona RP для MoonLoader

УСТАНОВКА
1. Содержимое папки moonloader из архива скопируйте в папку moonloader игры
   (обычно ...\Arizona Games Launcher\bin\arizona\moonloader).
   Папка игры часто защищена от записи - копируйте с правами администратора.
2. Из папки examples возьмите ОДИН пример и положите его в moonloader:
{examples}
3. Зайдите в игру.

Обновление с 3.1: замените lib\chat_emoji.lua и всю папку resource\chat_emoji.
Старые скрипты продолжат работать.

Документация, исходники и пересборка атласа под свою версию плагина:
https://github.com/Levushkins/mimgui-chat-emoji
"""


def version():
    src = open(os.path.join(ROOT, "moonloader", "lib", "chat_emoji.lua"),
               encoding="utf-8").read()
    return re.search(r"emoji\.VERSION = '([^']+)'", src).group(1)


def main():
    ver = version()
    top = "chat_emoji-" + ver
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    out = os.path.join(ROOT, "dist", top + ".zip")

    files = [("moonloader/lib/chat_emoji.lua", "moonloader/lib/chat_emoji.lua")]
    res = os.path.join(ROOT, "moonloader", "resource", "chat_emoji")
    for f in sorted(os.listdir(res)):
        files.append(("moonloader/resource/chat_emoji/" + f,
                      "moonloader/resource/chat_emoji/" + f))
    for f, _ in EXAMPLES:
        files.append(("moonloader/" + f, "examples/" + f))
    files += [("CHANGELOG.md", "CHANGELOG.md"), ("LICENSE", "LICENSE")]

    examples = "\n".join("     %-26s - %s" % (f, d) for f, d in EXAMPLES)
    text = README.format(version=ver, examples=examples).replace("\n", "\r\n")

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for src, dst in files:
            z.write(os.path.join(ROOT, src), top + "/" + dst)
        # BOM - чтобы блокнот точно открыл файл как UTF-8
        z.writestr(top + "/УСТАНОВКА.txt", "﻿" + text)

    print("%s  %d КБ" % (out, os.path.getsize(out) // 1024))
    for info in zipfile.ZipFile(out).infolist():
        print("  %-62s %9d" % (info.filename, info.file_size))


if __name__ == "__main__":
    main()
