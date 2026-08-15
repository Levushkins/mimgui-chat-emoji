-- test_chat_emoji.lua - проверка логики chat_emoji.lua без игры.
-- Подменяет mimgui и API MoonLoader, поэтому запускается где угодно:
--
--     cd chat-emoji && luajit tools/test_chat_emoji.lua

package.path = 'moonloader/lib/?.lua;' .. package.path

-- минимальная заглушка mimgui: модулю на этом этапе нужен только ImVec2
local fakeImgui = {
    ImVec2 = function(x, y) return { x = x, y = y } end,
}
fakeImgui.new = setmetatable({}, {
    __index = function() return setmetatable({}, {
        __index = function() return function() return {} end end,
        __call = function() return {} end,
    }) end,
})
package.loaded['mimgui'] = fakeImgui

_G.getWorkingDirectory = function() return 'moonloader' end
_G.getD3DDevicePtr = function() return 0 end
_G.u8 = function(s) return s end

local emoji = require 'chat_emoji'

local failed = 0
local function check(cond, msg)
    if cond then return end
    failed = failed + 1
    io.write('  ПРОВАЛ: ', msg, '\n')
end

-- --------------------------------------------------------------------------
-- заглушка mimgui почти пустая, поэтому load() обязан внятно сообщить,
-- каких функций ImGui не хватает, а не падать посреди отрисовки
local okLoad, loadErr = emoji.load()
check(okLoad == false, 'load() на пустой заглушке mimgui должен вернуть false')
check(type(loadErr) == 'string' and loadErr:find('mimgui'),
      'load() должен объяснить, чего не хватает, получено: ' .. tostring(loadErr))
print('проверка API: ' .. tostring(loadErr))

-- --------------------------------------------------------------------------
local atlas = dofile('moonloader/resource/chat_emoji/chat_emoji_atlas.lua')
print(('атлас %dx%d, ячейка %d, колонок %d, записей %d')
    :format(atlas.width, atlas.height, atlas.cell, atlas.cols, #atlas.emoji))

check(#atlas.emoji == atlas.count, 'count не совпадает с длиной списка')
check(atlas.cols == math.floor(atlas.width / atlas.cell), 'cols посчитан неверно')
local rows = math.ceil(#atlas.emoji / atlas.cols)
check(rows * atlas.cell <= atlas.height,
      'атлас ниже, чем нужно: ' .. rows * atlas.cell .. ' > ' .. atlas.height)

local function slotColumn(e) return e.slot % atlas.cols end

-- строим таблицы тем же кодом, что и в игре
emoji.build(atlas)
emoji.texture = 'FAKE'

print('категорий:', #emoji.categories)
for _, c in ipairs(emoji.categories) do
    io.write(('  %-22s %d\n'):format(c.name, #c.items))
end

-- --------------------------------------------------------------------------
-- UV не выходят за текстуру и соответствуют числу занятых ячеек
local wide = 0
for _, e in ipairs(emoji.list) do
    check(e.uv0.x >= 0 and e.uv1.x <= 1 and e.uv0.y >= 0 and e.uv1.y <= 1,
          'UV вне диапазона у ' .. e.name)
    check(e.uv1.x > e.uv0.x and e.uv1.y > e.uv0.y, 'вырожденный UV у ' .. e.name)
    check(e.cells and e.cells >= 1, 'нет cells у ' .. e.name)
    if e.cells > 1 then wide = wide + 1 end
    -- ширина UV обязана равняться cells ячейкам
    local uvw = (e.uv1.x - e.uv0.x) * atlas.width
    check(math.abs(uvw - e.cells * atlas.cell) < 0.01,
          ('UV шире/уже cells у %s: %.2f вместо %d'):format(
              e.name, uvw, e.cells * atlas.cell))
    -- глиф не должен вылезать за правый край атласа
    check(slotColumn(e) + e.cells <= atlas.cols,
          'глиф вылезает за край ряда: ' .. e.name)
end
-- широкие слоты обязаны существовать: серверные баннеры в одну ячейку
-- не помещаются. Точное число зависит от общего масштаба, поэтому порог
-- держим с запасом.
check(wide > 50, 'широких глифов подозрительно мало: ' .. wide)
print('широких (несколько ячеек):', wide)

-- поиск по имени, коду и токену
local s = emoji.get('smiley')
check(s ~= nil and s.cp == 0x1F603, 'get по имени')
check(emoji.get(0x1F603) == s, 'get по кодовой точке')
check(emoji.get(':u1f603:') == s, 'get по токену')
check(emoji.encode('smiley') == ':u1f603:', 'encode -> ' .. emoji.encode('smiley'))
check(emoji.get('нет такого') == nil, 'get несуществующего')

-- серверные иконки Arizona должны были попасть в атлас из icons.ttf
for _, n in ipairs({ 'arz', 'redcode', 'buy', 'sell', 'cash', 'btc', 'yt', 'vc' }) do
    check(emoji.get(n) ~= nil, 'нет серверной иконки ' .. n)
end

-- синонимы из таблицы шорткатов тоже должны находиться
check(emoji.get(':)') ~= nil and emoji.get(':)').cp == 0x1F642, 'синоним :)')
check(emoji.get('<3') ~= nil and emoji.get('<3').cp == 0x2764, 'синоним <3')

-- порядок обязан совпадать с панелью чата: первые шесть - как в Arizona
local head = { 0x1F600, 0x1F601, 0x1F602, 0x1F923, 0x1F603, 0x1F604 }
for i, cp in ipairs(head) do
    check(emoji.list[i] and emoji.list[i].cp == cp,
          ('порядок: #%d ожидался U+%05X, получен %s')
              :format(i, cp, emoji.list[i] and ('U+%05X'):format(emoji.list[i].cp) or 'nil'))
end

-- смайлы, которых не было в старой выборке из таблицы имён
for _, cp in ipairs({ 0x1F60E, 0x1F494, 0x1F49B, 0x1F648, 0x1F649, 0x1F64A, 0x1FAC1 }) do
    check(emoji.get(cp) ~= nil, ('нет U+%05X'):format(cp))
end

-- скрытые иконки Arizona: интерфейс, VIP-короны, крылья-уровни, оружие,
-- недвижимость. В панели чата их нет, но токеном они работают.
for _, cp in ipairs({ 0xF013, 0xF241, 0xF24E, 0xF250, 0xF259, 0xF260,
                      0xF300, 0xF341, 0x1FC1E, 0x1FC1F, 0x1FC21 }) do
    check(emoji.get(cp) ~= nil, ('нет скрытой иконки U+%05X'):format(cp))
end

-- вкладки панели чата обязаны идти первыми, скрытые - после них
local firstHidden, lastPanel = nil, nil
for i, c in ipairs(emoji.categories) do
    if c.name:find('^\208\161\208\186\209\128\209\139') then
        firstHidden = firstHidden or i
    elseif firstHidden == nil then
        lastPanel = i
    end
end
check(firstHidden ~= nil, 'нет ни одной скрытой группы')
check(lastPanel ~= nil and firstHidden > lastPanel,
      'скрытые группы перемешались с панельными')

-- --------------------------------------------------------------------------
-- разбор строки
local function render(str)
    local acc = {}
    for _, p in ipairs(emoji.parse(str)) do
        acc[#acc + 1] = p.emoji and ('<' .. p.emoji.name .. '>') or p.text
    end
    return table.concat(acc)
end

check(render('просто текст') == 'просто текст', 'текст без смайлов')
check(render(':u1f603:') == '<smiley>', 'строка из одного смайла')
check(render('a :u1f603: b') == 'a <smiley> b', 'смайл в середине')
check(render(':u1f603::u1fc08:') == '<smiley><arz>', 'два смайла подряд')
-- нераспознанный токен остаётся текстом и не съедает то, что было до него
check(render('a :u9ffffff: b :u1f603: c') == 'a :u9ffffff: b <smiley> c',
      'потерян текст перед нераспознанным токеном')
check(render('двоеточия :: и :u: без кода') == 'двоеточия :: и :u: без кода',
      'ложные срабатывания на двоеточиях')

-- --------------------------------------------------------------------------
-- диалоги SA-MP: сборка токенов и обработка текста
check(emoji.tok('trophy') == ':u1f3c6:', 'tok по имени')
check(emoji.tok('arz') == ':u1fc08:', 'tok по серверному имени')
check(emoji.tok('такого нет') == '', 'tok у неизвестного имени возвращает пусто')

-- токен обязан быть чистым ASCII: он проходит через sampShowDialog как есть,
-- и cp1251 не должен его портить
for _, e in ipairs(emoji.list) do
    check(not e.token:find('[\128-\255]'), 'токен не ASCII у ' .. e.name)
end

check(emoji.strip('привет :u1f603: как дела') == 'привет как дела',
      'strip не съел лишний пробел')
check(emoji.strip('без токенов') == 'без токенов', 'strip не трогает чистый текст')
check(emoji.strip(':u1f603:') == '', 'strip строки из одного токена')
check(emoji.strip('в конце строки :u1f603:') == 'в конце строки',
      'strip оставил хвостовой пробел')
check(emoji.strip('a :u1f603:\nb') == 'a\nb', 'strip перед переводом строки')
check(emoji.strip('время 12:30 и :u1f603: тут') == 'время 12:30 и тут',
      'strip задел обычное двоеточие')

check(emoji.expand(':trophy: рекорд') == ':u1f3c6: рекорд', 'expand по имени')
check(emoji.expand('итого: 12:30') == 'итого: 12:30',
      'expand тронул текст, не являющийся токеном')
check(emoji.expand(':неизвестное_имя:') == ':неизвестное_имя:',
      'expand заменил незнакомое имя')

local m = emoji.measure('a :u1f603: b :u1fc08:')
check(m.tokens == 2, 'measure посчитал токены: ' .. m.tokens)
check(m.tokenBytes == #':u1f603:' + #':u1fc08:', 'measure посчитал байты токенов')
check(m.bytes == #'a :u1f603: b :u1fc08:', 'measure посчитал длину строки')
check(m.visible == m.bytes - m.tokenBytes + m.tokens, 'measure: visible')

-- detect() без winapi обязан честно сказать «нет», а не упасть
emoji.plugin = nil
local detected = emoji.detect()
check(type(detected) == 'boolean', 'detect вернул не булево: ' .. tostring(detected))

-- fit() при отсутствии плагина обязан убрать токены, при наличии - оставить
emoji.plugin = false
check(emoji.fit('a :u1f603: b') == 'a b', 'fit без плагина не убрал токен')
emoji.plugin = true
check(emoji.fit('a :u1f603: b') == 'a :u1f603: b', 'fit с плагином испортил текст')

-- dialog() не должен молча отправлять текст сверх лимита
local shown = nil
_G.sampShowDialog = function(id, cap, text, b1, b2, style)
    shown = { id = id, cap = cap, text = text, b1 = b1, b2 = b2, style = style }
end
check(emoji.dialog(7, 'Заголовок ' .. emoji.tok('arz'), 'строка', 'ОК', '', 0),
      'dialog вернул false на нормальном тексте')
check(shown ~= nil and shown.id == 7, 'dialog не вызвал sampShowDialog')
check(shown.cap:find(':u1fc08:', 1, true) ~= nil, 'токен пропал из заголовка')

shown = nil
local okBig, whyBig = emoji.dialog(7, 'c', string.rep('x', emoji.DIALOG_LIMIT + 1))
check(okBig == false, 'dialog пропустил текст сверх лимита')
check(type(whyBig) == 'string' and whyBig:find('limit'), 'dialog не объяснил отказ')
check(shown == nil, 'dialog всё-таки показал слишком длинный текст')
emoji.plugin = nil

print(#emoji.list .. ' смайлов, ' .. (failed == 0 and 'ВСЁ ОК' or failed .. ' ОШИБОК'))
os.exit(failed == 0 and 0 or 1)
