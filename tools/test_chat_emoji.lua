-- test_chat_emoji.lua - проверка логики chat_emoji.lua без игры.
-- Подменяет mimgui и API MoonLoader, поэтому запускается где угодно:
--
--     cd chat_emoji && luajit tools/test_chat_emoji.lua

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
-- путь по умолчанию собирается через '\', как в Windows; для Linux
-- (CI на GitHub Actions) каталог атласа задаём явно
emoji.dir = 'moonloader/resource/chat_emoji/'

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

-- ==========================================================================
-- 3.2
-- ==========================================================================
local ffi = require 'ffi'

-- версия
check(emoji.atLeast('3.2') and emoji.atLeast('3') and emoji.atLeast('2.9.9'),
      'atLeast отказал на подходящей версии')
check(not emoji.atLeast('3.3') and not emoji.atLeast('4.0'),
      'atLeast согласился на версию новее')

-- описание атласа версии 3
check(atlas.version >= 3, 'описание атласа старее версии 3')
check(type(atlas.hash) == 'string' and #atlas.hash == 8, 'нет хеша атласа')
check(type(atlas.small) == 'table' and atlas.small.width * 2 == atlas.width
      and atlas.small.height * 2 == atlas.height,
      'малый атлас не вдвое меньше основного')
check(atlas.height % 8 == 0, 'высота атласа не кратна 8 (нужно для DXT5)')
check(atlas.height < 2048, 'атлас снова округлён до степени двойки')
check(type(atlas.source) == 'table' and atlas.source.size and atlas.source.stamp,
      'нет отпечатка _chat.asi')

-- категории по коротким именам
check(#(emoji.category('hidden_weapons') or {}) == 65, 'category(hidden_weapons)')
check(#(emoji.category('hidden_brands') or {}) == 14, 'нет 14 новых иконок биржи')
check(emoji.category('smileys') == emoji.categories[1].items,
      'category по id и по номеру разошлись')
for _, c in ipairs(emoji.categories) do
    check(type(c.id) == 'string' and not c.id:find('[^%w_]'),
          'у категории нет ASCII-имени: ' .. tostring(c.id))
end

-- сентябрьское обновление плагина: новые иконки и переезд имени apple
for _, n in ipairs({ 'telegram', 'vk', 'tesla', 'nvidia', 'sp500' }) do
    check(emoji.get(n) ~= nil, 'нет новой иконки ' .. n)
end
check(emoji.get('apple') and emoji.get('apple').cp == 0x1FC3D,
      'apple должен быть логотипом U+1FC3D')
check(emoji.get('red_apple') and emoji.get('red_apple').cp == 0x1F34E,
      'red_apple должен находить яблоко')
check(emoji.get('face_with_tears_of_joy') and emoji.get('face_with_tears_of_joy').cp == 0x1F602,
      'нет синонима из базы Unicode')

-- оружие, короны, крылья
local function cpOf(e) return e and e.cp end
check(cpOf(emoji.weapon(0)) == 0xF300, 'weapon(0) - кулак')
check(cpOf(emoji.weapon(18)) == 0xF312, 'weapon(18) - молотов')
check(emoji.weapon(19) == nil and emoji.weapon(21) == nil, 'weapon(19..21) пустые')
check(cpOf(emoji.weapon(22)) == 0xF313, 'weapon(22) - кольт')
check(cpOf(emoji.weapon(24)) == 0xF315, 'weapon(24) - дигл')
check(cpOf(emoji.weapon(31)) == 0xF31C, 'weapon(31) - M4')
check(cpOf(emoji.weapon(42)) == 0xF327, 'weapon(42) - огнетушитель')
check(emoji.weapon(43) == nil, 'weapon(43): камеры в шрифте нет')
check(cpOf(emoji.weapon(44)) == 0xF329 and cpOf(emoji.weapon(45)) == 0xF329, 'weapon(44, 45) - очки')
check(cpOf(emoji.weapon(46)) == 0xF32A, 'weapon(46) - парашют')
check(emoji.weapon(47) == nil and emoji.weapon(-1) == nil and emoji.weapon(1.5) == nil,
      'weapon вне диапазона')
check(cpOf(emoji.crown(1)) == 0xF245 and cpOf(emoji.crown(10)) == 0xF24E, 'crown(1..10)')
check(cpOf(emoji.wings(1)) == 0xF250 and cpOf(emoji.wings(10)) == 0xF259, 'wings(1..10)')
check(emoji.crown(0) == nil and emoji.crown(11) == nil, 'crown вне диапазона')

-- поиск: английский, русский, раскладка, регистр, ё
local function found(query, cp)
    for _, e in ipairs(emoji.find(query)) do
        if e.cp == cp then return true end
    end
    return false
end
check(found('fire', 0x1F525), 'find(fire)')
check(found('огонь', 0x1F525), 'find(огонь) - русский поиск')
check(found('ОГОНЬ', 0x1F525), 'find(ОГОНЬ) - регистр')
check(found('jujym', 0x1F525), 'find(jujym) - раскладка')
check(found('ашку', 0x1F525), 'find(ашку) - обратная раскладка')
check(found('сердце', 0x2764), 'find(сердце)')
check(found('дигл', 0xF315), 'find(дигл) - русские подписи оружия')
check(found('телеграм', 0x1FC39), 'find(телеграм)')
check(found('ёлка', 0x1F384) == found('елка', 0x1F384), 'ё и е ищутся одинаково')
check(#emoji.find('оружие') >= 65, 'поиск по названию категории')
check(#emoji.find('') == #emoji.list, 'пустой запрос вернёт всё')
check(#emoji.find('fire', 1) == 1, 'limit в find')
check(#emoji.find('zzzzqqqq') == 0, 'бессмыслица ничего не нашла')

-- Unicode: в Telegram и обратно
local U = emoji.utf8char
check(U(0x1F525) == '\240\159\148\165', 'utf8char 4 байта')
check(U(0x2764) == '\226\157\164', 'utf8char 3 байта')
check(emoji.toUnicode('gg :u1f525:') == 'gg \240\159\148\165', 'toUnicode 🔥')
check(emoji.toUnicode(':u2764:') == '\226\157\164\239\184\143', 'toUnicode ❤ + FE0F')
check(emoji.toUnicode(':u1fc08:') == ':arz:', 'toUnicode иконки Arizona -> :имя:')
check(emoji.toUnicode(':u1fc08:', { unknown = 'strip' }) == '', 'toUnicode strip')
check(emoji.toUnicode(':u1fc08:', { unknown = 'keep' }) == ':u1fc08:', 'toUnicode keep')
check(emoji.toUnicode(':u1fc11:') == '1\239\184\143\226\131\163', 'toUnicode цифра -> 1️⃣')
check(emoji.toUnicode(':u1f1e6::u1f1f7:') == 'AR', 'toUnicode буквы не склеиваются во флаг')
check(emoji.toUnicode('без токенов') == 'без токенов', 'toUnicode не трогает текст')

check(emoji.fromUnicode('gg \240\159\148\165') == 'gg :u1f525:', 'fromUnicode 🔥')
check(emoji.fromUnicode('\226\157\164\239\184\143') == ':u2764:', 'fromUnicode ❤️ без FE0F')
check(emoji.fromUnicode('\240\159\145\141\240\159\143\187') == ':u1f44d:',
      'fromUnicode 👍🏻 без оттенка кожи')
check(emoji.fromUnicode('1\239\184\143\226\131\163') == ':u1fc11:', 'fromUnicode 1️⃣')
check(emoji.fromUnicode('привет, 12:30') == 'привет, 12:30', 'fromUnicode не трогает текст')
check(emoji.fromUnicode(emoji.toUnicode('a :u1f525: b')) == 'a :u1f525: b',
      'toUnicode/fromUnicode туда и обратно')

-- canRender / serverSupports / fit
emoji.plugin = true
_G.sampGetCurrentServerName = function() return 'Arizona Role Play | Phoenix' end
check(emoji.serverSupports() == true, 'Arizona не опознана по названию')
check(emoji.fit('a :u1f603: b', 'server') == 'a :u1f603: b', 'fit server на Arizona')
_G.sampGetCurrentServerName = function() return 'Some Other RP' end
check(emoji.serverSupports() == false, 'чужой сервер принят за Arizona')
check(emoji.fit('a :u1f603: b', 'server') == 'a b', 'fit server на чужом сервере')
check(emoji.fit('a :u1f603: b') == 'a :u1f603: b', 'fit local при плагине')
emoji.server = true
check(emoji.serverSupports() == true, 'ручной emoji.server = true')
emoji.server = nil
_G.sampGetCurrentServerName = nil
check(emoji.serverSupports() == emoji.canRender(), 'без названия сервера - как canRender')
check(emoji.detect() == emoji.canRender(), 'detect - синоним canRender')

-- sendChat: первая часть сразу, остальные в потоке с паузой
local sent, waits = {}, {}
_G.sampSendChat = function(s) sent[#sent + 1] = s end
_G.wait = function(ms) waits[#waits + 1] = ms end
_G.lua_thread = { create = function(fn) fn() end }
_G.sampGetCurrentServerName = function() return 'Arizona RP | Mesa' end
local long = string.rep('слово ', 50) .. emoji.tok('fire')
local n = emoji.sendChat(long, { limit = 100, delay = 1234 })
check(n == #sent and n > 1, 'sendChat разбил сообщение: ' .. n)
check(#waits == n - 1 and waits[1] == 1234, 'sendChat не ждал между частями')
for _, s in ipairs(sent) do check(#s <= 100, 'кусок длиннее лимита') end
check(table.concat(sent, ' '):find(':u1f525:', 1, true), 'токен потерялся при разбиении')
sent, waits = {}, {}
check(emoji.sendChat('коротко', 100) == 1 and #waits == 0, 'sendChat(text, limit) как в 3.1')
_G.sampGetCurrentServerName = function() return 'Other' end
sent = {}
emoji.sendChat('a ' .. emoji.tok('fire'))
check(sent[1] == 'a', 'sendChat на чужом сервере не убрал токен: ' .. tostring(sent[1]))
_G.sampGetCurrentServerName, _G.lua_thread, _G.wait = nil, nil, nil
emoji.plugin = nil

-- split, stylize, decode, measure
for _, part in ipairs(emoji.split(string.rep(emoji.tok('fire'), 40), 20)) do
    check(#part <= 20 or part == emoji.tok('fire'), 'split превысил лимит')
    check(not part:find(':u1f5$') and not part:find('^25:'), 'split разорвал токен')
end
check(emoji.decode('a :u1f3c6:') == 'a :trophy:', 'decode')
check(emoji.stylize('AZ 1'):find(':u1f1e6:', 1, true) and
      emoji.stylize('AZ 1'):find(':u1fc11:', 1, true), 'stylize')
check(emoji.measure('я :u1f525:').chars == 3, 'measure.chars с кириллицей')

-- проверка _chat.asi: свежий и обновлённый
local function fakeAsi(path, size, stamp)
    local head = { 'MZ', string.rep('\0', 0x3C - 2), '\64\0\0\0',
                   string.rep('\0', 0x40 - 0x40), 'PE\0\0', '\76\1', '\3\0',
                   string.char(stamp % 256, math.floor(stamp / 256) % 256,
                               math.floor(stamp / 65536) % 256,
                               math.floor(stamp / 16777216) % 256) }
    local data = table.concat(head)
    local f = assert(io.open(path, 'wb'))
    f:write(data, string.rep('\0', size - #data))
    f:close()
end
local tmp = os.tmpname()
if tmp:sub(1, 1) == '\\' then tmp = (os.getenv('TEMP') or '.') .. tmp end
fakeAsi(tmp, atlas.source.size, atlas.source.stamp)
check(emoji.checkSource(tmp) == true, 'checkSource не узнал свой _chat.asi')
fakeAsi(tmp, atlas.source.size, atlas.source.stamp + 1)
local same, why = emoji.checkSource(tmp)
check(same == false and tostring(why):find('rebuild'), 'checkSource не заметил новую сборку')
check(emoji.stale == true, 'emoji.stale не выставлен')
fakeAsi(tmp, atlas.source.size + 4, atlas.source.stamp)
check(emoji.checkSource(tmp) == false, 'checkSource не заметил новый размер')
os.remove(tmp)
check(emoji.checkSource(tmp) == nil, 'checkSource без файла должен вернуть nil')

-- раскладка текста: перенос и кеш
local calcCalls = 0
fakeImgui.CalcTextSize = function(s) calcCalls = calcCalls + 1 return { x = #s * 8, y = 16 } end
fakeImgui.GetTextLineHeight = function() return 16 end
fakeImgui.GetFontSize = function() return 14 end
fakeImgui.GetFont = function() return 'font1' end
emoji.loaded = true
local w1, h1 = emoji.calcTextSize('one two three', 14)
check(w1 == #'one two three' * 8 and h1 == 16, 'calcTextSize одной строкой: ' .. w1)
local _, h2 = emoji.calcTextSize('one two three', 14, 70)
check(h2 == 32, 'перенос по ширине: высота ' .. tostring(h2))
local w3 = emoji.calcTextSize('a :u1f525: b', 20)
check(w3 == 8 * 2 + 20 + 8 * 2 - 8 * 0, 'ширина строки со смайлом: ' .. w3)
local _, h4 = emoji.calcTextSize('a\nb', 14)
check(h4 == 32, 'перевод строки')
local wTag = emoji.calcTextSize('{FF0000}red', 14, { color = true })
check(wTag == 3 * 8, 'цветовой тег не должен занимать место')
calcCalls = 0
emoji.calcTextSize('one two three', 14, 70)
check(calcCalls == 0, 'раскладка не взялась из кеша')
emoji.clearLayoutCache()
emoji.calcTextSize('one two three', 14, 70)
check(calcCalls > 0, 'clearLayoutCache не сбросил кеш')
emoji.loaded = false

-- глифы шрифта: преобразование строк
local fire = emoji.get('fire')
emoji.glyphs[fire.cp] = emoji.GLYPH_BASE + fire.index - 1
emoji.glyphCp[emoji.GLYPH_BASE + fire.index - 1] = fire.cp
local g = emoji.glyph('fire')
check(#g == 3 and g:byte(1) == 0xEE, 'glyph - три байта UTF-8 в Private Use')
check(emoji.toGlyphs('a :u1f525: :u1f603:') == 'a ' .. g .. ' :u1f603:',
      'toGlyphs: незашитые смайлы остаются токенами')
check(emoji.fromGlyphs('a ' .. g .. ' b') == 'a :u1f525: b', 'fromGlyphs')
check(emoji.fromGlyphs('привет') == 'привет', 'fromGlyphs не трогает кириллицу')
emoji.glyphs, emoji.glyphCp = {}, {}
check(emoji.GLYPH_BASE + #emoji.list - 1 <= 0xF8FF, 'глифы вылезают из Private Use')

-- уменьшение блока для шрифта: красный непрозрачный 4x4 -> 2x2
local src = ffi.new('uint8_t[?]', 4 * 4 * 4)
for i = 0, 15 do src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3] = 0, 0, 255, 255 end
-- левый верхний пиксель прозрачный: цвет у края не должен темнеть
src[0], src[1], src[2], src[3] = 0, 0, 0, 0
local dst = ffi.new('uint8_t[?]', 2 * 2 * 4)
emoji._internal.blitGlyph(src, 16, 0, 0, 4, 4, dst, 2, 0, 0, 2, 2)
check(dst[2] == 255 and dst[0] == 0 and dst[1] == 0, 'blitGlyph: цвет испорчен прозрачными пикселями')
check(dst[3] < 255 and dst[3] > 150, 'blitGlyph: альфа не усреднена: ' .. dst[3])
check(dst[4 * 3 + 3] == 255, 'blitGlyph: непрозрачный угол')

-- функции mimgui - это C-функции (cdata), их нельзя считать отсутствующими
check(emoji._internal.callable(function() end), 'callable: Lua-функция')
check(emoji._internal.callable(ffi.cast('int(*)(int)', function(x) return x end)),
      'callable: C-функция (cdata) - в 3.1 из-за этого не работали drawText и draw3D')
check(not emoji._internal.callable(nil) and not emoji._internal.callable({}),
      'callable: nil и таблица')

-- общая текстура: ссылки и слот (только Windows, там есть переменные окружения)
if ffi.os == 'Windows' then
    local I = emoji._internal
    ffi.cdef [[ typedef struct { void** vtbl; } chat_emoji_fake_com; ]]
    local refs = {}
    local addRef = ffi.cast('unsigned long(__stdcall*)(void*)', function(self)
        local k = tonumber(ffi.cast('uintptr_t', self))
        refs[k] = refs[k] + 1
        return refs[k]
    end)
    local release = ffi.cast('unsigned long(__stdcall*)(void*)', function(self)
        local k = tonumber(ffi.cast('uintptr_t', self))
        refs[k] = refs[k] - 1
        return refs[k]
    end)
    local vtbl = ffi.new('void*[3]')
    vtbl[1], vtbl[2] = ffi.cast('void*', addRef), ffi.cast('void*', release)
    local keep = {}
    local function fakeTex()
        local obj = ffi.new('chat_emoji_fake_com')
        obj.vtbl = vtbl
        keep[#keep + 1] = obj
        local p = ffi.cast('void*', obj)
        refs[tonumber(ffi.cast('uintptr_t', p))] = 1
        return p
    end
    local function refsOf(p) return refs[tonumber(ffi.cast('uintptr_t', p))] end
    local SLOT = 'CHAT_EMOJI_TEST_SLOT'

    local a = fakeTex()
    I.publishShared(SLOT, 'k1', a)
    local b = I.takeShared(SLOT, 'k1')
    check(b ~= nil and refsOf(a) == 2, 'takeShared не взял текстуру по ключу')
    check(I.takeShared(SLOT, 'k2') == nil, 'takeShared взял текстуру с чужим ключом')
    I.releaseTexture(SLOT, a)
    check(refsOf(a) == 1 and I.slotRead(SLOT) ~= '' and I.slotRead(SLOT) ~= nil,
          'слот стёрт, пока текстура ещё нужна')
    I.releaseTexture(SLOT, b)
    check(refsOf(a) == 0 and (I.slotRead(SLOT) or '') == '', 'слот не стёрт после последней ссылки')

    -- после пересборки в слоте новая текстура: последний держатель старой
    -- не должен её стереть
    local old = fakeTex()
    I.publishShared(SLOT, 'old', old)
    local new = fakeTex()
    I.publishShared(SLOT, 'new', new)
    I.releaseTexture(SLOT, old)
    check((I.slotRead(SLOT) or ''):find('|new$'), 'старая текстура стёрла слот новой')
    I.releaseTexture(SLOT, new)
    I.slotWrite(SLOT, '')
end

-- самопроверка атласа: кроме заметок о повторяющихся именах проблем нет
local okSelf, problems = emoji.selfTest()
for _, p in ipairs(problems) do
    check(p:find('^note:'), 'selfTest: ' .. p)
end

print(#emoji.list .. ' смайлов, ' .. (failed == 0 and 'ВСЁ ОК' or failed .. ' ОШИБОК'))
os.exit(failed == 0 and 0 or 1)
