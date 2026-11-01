#!/usr/bin/env python3
"""diff_emoji.py - что изменилось в наборе иконок между версиями _chat.asi.

Arizona обновляет плагин чата, и в нём появляются новые иконки. Этот скрипт
отвечает на вопрос «что завезли» за одну команду: он берёт свежий
_chat.asi (или уже распакованный emoji.json), сравнивает со старым набором
и печатает, что добавилось, что пропало и у кого поменялись имена.

Зависимостей нет, только стандартная библиотека.

    python3 tools/diff_emoji.py НОВЫЙ_chat.asi
    python3 tools/diff_emoji.py НОВЫЙ_chat.asi --old data/emoji.json
    python3 tools/diff_emoji.py new/emoji.json --old data/emoji.json

Код возврата: 0 если набор не изменился, 1 если есть разница. Так его можно
звать из скрипта обновления.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load_set(path):
    """Читает набор иконок: либо готовый emoji.json, либо прямо из _chat.asi."""
    if path.lower().endswith('.json'):
        with open(path, encoding='utf-8') as f:
            return json.load(f), path

    # это .asi - распаковываем во временный каталог тем же извлекателем
    tmp = tempfile.mkdtemp(prefix='chat_emoji_diff_')
    cmd = [sys.executable, '-I', os.path.join(HERE, 'extract_chat_emoji.py'),
           path, '-o', tmp]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stdout + res.stderr)
        raise SystemExit('не удалось распаковать ' + path)
    out = os.path.join(tmp, 'emoji.json')
    with open(out, encoding='utf-8') as f:
        return json.load(f), out


def index(rows):
    return {r['cp']: r for r in rows}


def names_of(row):
    return tuple(row.get('names') or ())


def describe(row):
    nm = names_of(row)
    label = (':%s:' % nm[0]) if nm else ''
    return 'U+%05X  :u%s:  %-28s %s' % (
        row['cp'], ('%x' % row['cp']), row.get('cat', ''), label)


def main():
    ap = argparse.ArgumentParser(
        description='Сравнивает наборы иконок двух версий _chat.asi',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('new', help='новый _chat.asi либо его emoji.json')
    ap.add_argument('--old', default=os.path.join(ROOT, 'data', 'emoji.json'),
                    help='с чем сравнивать (по умолчанию data/emoji.json)')
    ap.add_argument('--quiet', action='store_true',
                    help='только сводка, без перечисления иконок')
    args = ap.parse_args()

    old_rows, old_src = load_set(args.old)
    new_rows, new_src = load_set(args.new)

    old, new = index(old_rows), index(new_rows)

    added = [new[c] for c in new if c not in old]
    removed = [old[c] for c in old if c not in new]
    renamed = []
    recat = []
    for c in new:
        if c not in old:
            continue
        if names_of(old[c]) != names_of(new[c]):
            renamed.append((old[c], new[c]))
        if old[c].get('cat') != new[c].get('cat'):
            recat.append((old[c], new[c]))

    # порядок в панели чата важен: по нему строится атлас
    old_order = [r['cp'] for r in old_rows]
    new_order = [r['cp'] for r in new_rows]
    common_old = [c for c in old_order if c in new]
    common_new = [c for c in new_order if c in old]
    order_changed = common_old != common_new

    print('старый набор: %-5d иконок   %s' % (len(old_rows), old_src))
    print('новый набор:  %-5d иконок   %s' % (len(new_rows), new_src))
    print()
    print('добавлено:          %d' % len(added))
    print('удалено:            %d' % len(removed))
    print('сменили имена:      %d' % len(renamed))
    print('сменили категорию:  %d' % len(recat))
    print('порядок панели:     %s' % ('ИЗМЕНИЛСЯ' if order_changed else 'тот же'))

    changed = bool(added or removed or renamed or recat or order_changed)

    if not args.quiet:
        def section(title, rows):
            if not rows:
                return
            print()
            print('=== %s (%d) ===' % (title, len(rows)))
            for r in sorted(rows, key=lambda x: x['cp']):
                print('  ' + describe(r))

        section('ДОБАВЛЕНЫ', added)
        section('УДАЛЕНЫ', removed)

        if renamed:
            print()
            print('=== СМЕНИЛИ ИМЕНА (%d) ===' % len(renamed))
            for a, b in sorted(renamed, key=lambda p: p[0]['cp']):
                print('  U+%05X  %s  ->  %s' % (
                    a['cp'], list(names_of(a)) or '-', list(names_of(b)) or '-'))

        if recat:
            print()
            print('=== СМЕНИЛИ КАТЕГОРИЮ (%d) ===' % len(recat))
            for a, b in sorted(recat, key=lambda p: p[0]['cp']):
                print('  U+%05X  %s  ->  %s' % (a['cp'], a.get('cat'), b.get('cat')))

        if added:
            print()
            print('=== токены новых иконок, строкой ===')
            print('  ' + ' '.join(':u%x:' % r['cp'] for r in sorted(added, key=lambda x: x['cp'])))

    print()
    if changed:
        print('НАБОР ИЗМЕНИЛСЯ: нужна пересборка атласа (rebuild.bat).')
    else:
        print('Набор не изменился, пересобирать нечего.')
    return 1 if changed else 0


if __name__ == '__main__':
    raise SystemExit(main())
