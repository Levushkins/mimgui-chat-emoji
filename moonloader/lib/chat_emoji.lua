-- chat_emoji.lua - смайлы из _chat.asi (Arizona Games) для mimgui.
--
-- Почему через текстуру, а не через шрифт:
--   mimgui собран со stb_truetype и 16-битным ImWchar. stb_truetype не умеет
--   цветные глифы (COLR/CPAL и SVG - а именно так устроены Segoe UI Emoji и
--   icons.ttf из _chat.asi), а 16-битный ImWchar физически не может хранить
--   кодовые точки выше U+FFFF, где и живут почти все смайлы (U+1F300+).
--   Поэтому смайлы заранее растеризуются в один PNG-атлас
--   (tools/build_emoji_atlas.py), а здесь он грузится как текстура D3D9
--   и рисуется через imgui.Image с нужными UV.
--
-- Установка:
--   moonloader/lib/chat_emoji.lua
--   moonloader/resource/chat_emoji/chat_emoji.png
--   moonloader/resource/chat_emoji/chat_emoji_atlas.lua
--
-- Использование в mimgui:
--   local emoji = require 'chat_emoji'
--   imgui.OnInitialize(function() emoji.load() end)
--   ...
--   emoji.image('smiley', 24)
--   emoji.text('привет :u1f603: как дела')
--   local picked = emoji.picker('emj', 24)
--   if picked then sampSendChat(emoji.encode(picked)) end
--
-- Использование в диалогах SA-MP (смайлы рисует сам плагин, см. ниже):
--   local emoji = require 'chat_emoji'
--   emoji.loadTable()                      -- ни текстуры, ни mimgui не надо
--   emoji.dialog(1234, 'Меню ' .. emoji.tok('arz'),
--                emoji.tok('trophy') .. ' Рекорды\n' ..
--                emoji.tok('lock')   .. ' Закрыто',
--                'Выбрать', 'Отмена', 2)

local ffi = require 'ffi'

-- mimgui нужен только для отрисовки. Работа с токенами и диалогами от него
-- не зависит, поэтому требуем его мягко: скрипт, которому нужны только
-- диалоги, не должен падать из-за отсутствующей библиотеки интерфейса.
local okImgui, imgui = pcall(require, 'mimgui')
if not okImgui then imgui = nil end

local emoji = {}

emoji.ready = false      -- таблицы построены (хватает для чата и диалогов)
emoji.loaded = false     -- то же плюс текстура: можно рисовать в mimgui
emoji.texture = nil
emoji.atlas = nil
emoji.list = {}          -- массив записей в порядке из чата
emoji.byName = {}        -- name -> запись
emoji.byCp = {}          -- codepoint -> запись
emoji.categories = {}    -- { { name = 'Смайлы', items = { ... } }, ... }

-- Токен смайла в тексте чата: :u1f603: (шестнадцатеричная кодовая точка).
emoji.PATTERN = ':u(%x+):'
-- То же без захвата - для gsub и подсчётов.
emoji.TOKEN = ':u%x+:'

-- Подписи панели. Специально латиницей: тогда файл модуля целиком в ASCII,
-- и его невозможно испортить пересохранением в другой кодировке (блокнот
-- по умолчанию пишет cp1251, а ImGui ждёт UTF-8 - отсюда «??» вместо текста).
-- Нужны русские надписи - задайте их у себя, файл при этом сохраните в UTF-8:
--     emoji.strings.search = 'Поиск...'
-- Названия категорий приходят из описания атласа и уже экранированы, поэтому
-- на них кодировка файла не влияет.
emoji.strings = {
    search = 'Search...',
    notLoaded = 'emoji atlas is not loaded',
}

--------------------------------------------------------------------------
-- Загрузка текстуры через D3DX
--------------------------------------------------------------------------

ffi.cdef [[
    long __stdcall D3DXCreateTextureFromFileInMemoryEx(
        void* pDevice, const void* pSrcData, unsigned int SrcDataSize,
        unsigned int Width, unsigned int Height, unsigned int MipLevels,
        unsigned long Usage, unsigned int Format, unsigned int Pool,
        unsigned long Filter, unsigned long MipFilter, unsigned long ColorKey,
        void* pSrcInfo, void* pPalette, void** ppTexture);
]]

local D3DFMT_A8R8G8B8 = 21
local D3DPOOL_MANAGED = 1   -- переживает device reset, ничего пересоздавать не надо
local D3DX_FILTER_NONE = 1

local d3dx = nil
local function loadD3DX()
    if d3dx then return d3dx end
    -- разные системы несут разные версии d3dx9_XX.dll
    for v = 43, 24, -1 do
        local ok, lib = pcall(ffi.load, 'd3dx9_' .. v)
        if ok then d3dx = lib return d3dx end
    end
    local ok, lib = pcall(ffi.load, 'd3dx9')
    if ok then d3dx = lib return d3dx end
    return nil
end

local function createTexture(pngData)
    local lib = loadD3DX()
    if not lib then
        return nil, 'd3dx9_xx.dll not found (install DirectX 9 runtime)'
    end
    local device = ffi.cast('void*', getD3DDevicePtr())
    if device == nil then return nil, 'getD3DDevicePtr() returned 0' end

    local out = ffi.new('void*[1]')
    local hr = lib.D3DXCreateTextureFromFileInMemoryEx(
        device, pngData, #pngData,
        0xFFFFFFFE,             -- D3DX_DEFAULT_NONPOW2: не менять размер
        0xFFFFFFFE,
        1,                      -- без mip-уровней
        0,
        D3DFMT_A8R8G8B8,
        D3DPOOL_MANAGED,
        D3DX_FILTER_NONE,
        D3DX_FILTER_NONE,
        0,
        nil, nil, out)
    if hr ~= 0 or out[0] == nil then
        return nil, ('D3DXCreateTextureFromFileInMemoryEx: 0x%08X'):format(hr)
    end
    return out[0]
end

--------------------------------------------------------------------------
-- Общая текстура на все скрипты
--------------------------------------------------------------------------
-- MoonLoader запускает каждый скрипт в отдельной Lua-машине, поэтому три
-- скрипта с этой библиотекой создавали три копии одной и той же текстуры,
-- по 16 МБ видеопамяти каждая. Машины разные, но процесс один, а значит
-- указатель можно передать через переменную окружения процесса.
--
-- Время жизни считает сам COM: кто нашёл готовую текстуру, делает AddRef,
-- при выгрузке каждый делает Release. Переменная стирается, когда Release
-- вернул ноль, то есть когда отпустил последний.

ffi.cdef [[
    unsigned long __stdcall GetEnvironmentVariableA(const char* name,
                                                    char* buf,
                                                    unsigned long size);
    int __stdcall SetEnvironmentVariableA(const char* name, const char* value);
]]

local SHARED_SLOT = 'CHAT_EMOJI_TEXTURE'

local kernel32 = nil
local function winapi()
    if kernel32 == nil then
        local ok, lib = pcall(ffi.load, 'kernel32')
        kernel32 = ok and lib or false
    end
    return kernel32 or nil
end

-- IUnknown: AddRef это метод 1 в vtable, Release это метод 2
local function comCall(obj, index)
    local vtbl = ffi.cast('void***', obj)[0]
    return ffi.cast('unsigned long(__stdcall*)(void*)', vtbl[index])(obj)
end

local function slotRead()
    local k = winapi()
    if not k then return nil end
    local buf = ffi.new('char[256]')
    local n = k.GetEnvironmentVariableA(SHARED_SLOT, buf, 256)
    if n == 0 or n >= 256 then return nil end
    return ffi.string(buf, n)
end

local function slotWrite(value)
    local k = winapi()
    if k then k.SetEnvironmentVariableA(SHARED_SLOT, value) end
end

--- Берёт уже созданную кем-то текстуру того же атласа, если она есть.
local function takeShared(key)
    local raw = slotRead()
    if not raw then return nil end
    local addr, storedKey = raw:match('^(%x+)|(.*)$')
    if not addr or storedKey ~= key then return nil end
    local ok, tex = pcall(ffi.cast, 'void*', tonumber(addr, 16))
    if not ok or tex == nil then return nil end
    if not pcall(comCall, tex, 1) then return nil end     -- AddRef
    return tex
end

local function publishShared(key, tex)
    local ok, addr = pcall(function()
        return tonumber(ffi.cast('uint32_t', ffi.cast('uintptr_t', tex)))
    end)
    if ok and addr then slotWrite(('%08X|%s'):format(addr, key)) end
end

--------------------------------------------------------------------------
-- Загрузка атласа
--------------------------------------------------------------------------

local function defaultDir()
    return getWorkingDirectory() .. '\\resource\\chat_emoji\\'
end

-- Функции ImGui, на которые опирается модуль. Сборки mimgui отличаются, и
-- перегруженные функции (PushID, например) в биндинге могут отсутствовать -
-- лучше сказать об этом сразу, чем упасть посреди отрисовки.
local REQUIRED_IMGUI = {
    'ImVec2', 'Dummy', 'Image', 'InvisibleButton', 'GetWindowDrawList',
    'IsItemHovered', 'IsMouseDown', 'ColorConvertFloat4ToU32', 'GetStyle',
    'GetCursorScreenPos', 'GetFontSize', 'TextUnformatted', 'GetTextLineHeight',
    'TextDisabled', 'PushItemWidth', 'PopItemWidth', 'InputTextWithHint',
    'BeginChild', 'EndChild', 'GetContentRegionAvail', 'SameLine', 'Spacing',
    'SetTooltip',
}

local function checkImgui()
    local missing = {}
    for _, name in ipairs(REQUIRED_IMGUI) do
        local ok, fn = pcall(function() return imgui[name] end)
        if not ok or fn == nil then missing[#missing + 1] = name end
    end
    if #missing > 0 then
        return false, 'missing in this mimgui build: ' .. table.concat(missing, ', ')
    end
    return true
end

local function readAtlas(dir)
    local descPath = dir .. 'chat_emoji_atlas.lua'
    local chunk, err = loadfile(descPath)
    if not chunk then return nil, 'cannot read ' .. descPath .. ': ' .. tostring(err) end
    local ok, atlas = pcall(chunk)
    if not ok or type(atlas) ~= 'table' then
        return nil, 'malformed ' .. descPath
    end
    return atlas
end

--- Читает только описание атласа: имена, кодовые точки, категории.
--- Ни текстуры, ни D3D, ни mimgui - этого достаточно, чтобы собирать
--- токены для чата и для диалогов SA-MP. Вызывать откуда угодно,
--- в том числе из main().
-- @return true либо false, текст ошибки
function emoji.loadTable(dir)
    if emoji.ready then return true end
    local atlas, err = readAtlas(dir or defaultDir())
    if not atlas then return false, err end
    emoji.build(atlas)
    return true
end

--- Загружает описание атласа и текстуру. Вызывать из imgui.OnInitialize.
-- @param dir каталог с chat_emoji_atlas.lua и chat_emoji.png (необязательно)
-- @return true либо false, текст ошибки
function emoji.load(dir)
    if emoji.loaded then return true end

    if not imgui then return false, 'mimgui is not available' end
    local okApi, apiErr = checkImgui()
    if not okApi then return false, apiErr end

    dir = dir or defaultDir()

    local atlas, err = readAtlas(dir)
    if not atlas then return false, err end

    local pngPath = dir .. atlas.file

    -- если этот же атлас уже загрузил другой скрипт, переиспользуем текстуру
    -- и не тратим ещё 16 МБ видеопамяти
    local key = pngPath:lower() .. '#' .. tostring(atlas.count)
    local tex = takeShared(key)
    emoji.sharedTexture = tex ~= nil

    if not tex then
        local f = io.open(pngPath, 'rb')
        if not f then return false, 'not found: ' .. pngPath end
        local png = f:read('*a')
        f:close()

        local terr
        tex, terr = createTexture(png)
        if not tex then return false, terr end
        publishShared(key, tex)
    end

    emoji.texture = tex
    emoji.build(atlas)
    return true
end

--- Строит таблицы поиска и UV по описанию атласа.
--- Вынесено отдельно, чтобы это можно было прогнать без игры и без D3D
--- (см. tools/test_chat_emoji.lua).
function emoji.build(atlas)
    emoji.atlas = atlas
    emoji.list, emoji.byName, emoji.byCp, emoji.categories = {}, {}, {}, {}

    local catIndex = {}
    for i, row in ipairs(atlas.emoji) do
        local name, cp, cat, slot = row[1], row[2], row[3], row[4]

        -- Пятое поле: в описании версии 2 это число ячеек, в первой версии
        -- сразу шли синонимы таблицей. Различаем по типу, чтобы старое
        -- описание тоже читалось.
        local cells, aliases = row[5], row[6]
        if type(cells) == 'table' then
            aliases, cells = cells, 1
        end
        cells = cells or 1

        local col = slot % atlas.cols
        local line = math.floor(slot / atlas.cols)
        local u0 = col * atlas.cell / atlas.width
        local v0 = line * atlas.cell / atlas.height
        local u1 = (col + cells) * atlas.cell / atlas.width
        local v1 = (line + 1) * atlas.cell / atlas.height
        local e = {
            name = name,
            cp = cp,
            cat = cat,
            slot = slot,
            index = i,
            -- Ширина глифа в высотах: у обычного смайла 1, у серверного
            -- баннера («ВИП ЧАТ», ленты) до 8. Рисуем с этим соотношением,
            -- иначе широкие иконки сплющивались бы в полоску.
            cells = cells,
            token = (':u%x:'):format(cp),
            -- Числами UV лежат всегда, а ImVec2 собираем только когда mimgui
            -- действительно есть: без него модуль остаётся пригодным для
            -- диалогов и чата.
            u0 = u0, v0 = v0, u1 = u1, v1 = v1,
            uv0 = imgui and imgui.ImVec2(u0, v0) or nil,
            uv1 = imgui and imgui.ImVec2(u1, v1) or nil,
        }
        emoji.list[i] = e
        -- имена в таблице чата не уникальны (kkk/m, kkkv/mv), первый выигрывает
        if not emoji.byName[name] then emoji.byName[name] = e end
        if not emoji.byCp[cp] then emoji.byCp[cp] = e end
        if aliases then
            e.aliases = aliases
            for _, a in ipairs(aliases) do
                if not emoji.byName[a] then emoji.byName[a] = e end
            end
        end

        local c = catIndex[cat]
        if not c then
            c = { name = cat, items = {} }
            catIndex[cat] = c
            emoji.categories[#emoji.categories + 1] = c
        end
        c.items[#c.items + 1] = e
    end

    emoji.ready = true
    -- Рисовать можно только когда текстура действительно есть: loadTable()
    -- строит те же таблицы, но без неё.
    emoji.loaded = emoji.texture ~= nil
    return true
end

--- Освобождает текстуру. Вызывать при выгрузке скрипта.
function emoji.unload()
    if emoji.texture ~= nil then
        -- Release возвращает оставшееся число ссылок. Ноль означает, что
        -- текстуру отпустил последний скрипт и общий слот пора освободить,
        -- иначе там останется адрес уже уничтоженного объекта.
        local ok, refs = pcall(comCall, emoji.texture, 2)
        if ok and refs == 0 then slotWrite('') end
        emoji.texture = nil
    end
    emoji.sharedTexture = false
    emoji.loaded = false
    -- emoji.ready намеренно оставляем: таблицы имён и кодов никуда не делись,
    -- и токены для чата с диалогами собираются дальше без текстуры.
end

--------------------------------------------------------------------------
-- Доступ к записям
--------------------------------------------------------------------------

--- Находит смайл по имени ('smiley'), кодовой точке (0x1F603),
--- токену (':u1f603:') или возвращает уже готовую запись.
function emoji.get(key)
    if type(key) == 'table' then return key end
    if type(key) == 'number' then return emoji.byCp[key] end
    if type(key) == 'string' then
        local hex = key:match('^' .. emoji.PATTERN .. '$')
        if hex then return emoji.byCp[tonumber(hex, 16)] end
        return emoji.byName[key]
    end
    return nil
end

--- Токен для вставки в чат: emoji.encode('smiley') -> ':u1f603:'
function emoji.encode(key)
    local e = emoji.get(key)
    return e and e.token or ''
end

--- Короткий синоним encode: emoji.tok('trophy') -> ':u1f3c6:'
function emoji.tok(key)
    return emoji.encode(key)
end

--------------------------------------------------------------------------
-- Диалоги SA-MP
--------------------------------------------------------------------------
-- Здесь библиотека ничего не рисует: в диалогах смайлы подставляет сам
-- _chat.asi. Плагин перехватывает GUI-классы SA-MP, из которых собран
-- диалог, и гонит их текст через тот же разборщик токенов, что и чат.
-- Видно это прямо в бинарнике: разборщик :токен: (memchr по ':' с разбором
-- того, что между двоеточиями) вызывается и из отрисовки чата, и из
-- перехваченных методов диалоговых контролов; разметка кешируется по
-- контролу и сбрасывается, когда контролу меняют текст.
--
-- Практические следствия, ради которых всё и написано:
--   * для диалогов не нужны ни текстура, ни mimgui - хватает loadTable();
--   * токен - чистый ASCII, поэтому cp1251 в sampShowDialog его не портит,
--     перекодировать надо только свой русский текст, как обычно;
--   * на сервере без плагина токен останется видимым мусором вида
--     ":u1f603:", поэтому есть fit().

-- Имена модулей, по которым узнаём плагин чата Arizona.
emoji.pluginModules = { '_chat.asi', 'chat.asi' }

-- nil - ещё не проверяли, true/false - результат. Можно выставить руками,
-- если проверка по имени модуля почему-то не подходит.
emoji.plugin = nil

-- Сколько байт текста диалога считаем безопасным. Это осознанно
-- консервативная величина, а не вычитанная из SA-MP константа: длинный
-- текст диалога обрезается молча, и ловить это в бою неприятно.
emoji.DIALOG_LIMIT = 4096

-- GetModuleHandleA - функция расхожая, и её вполне мог объявить кто-то ещё
-- в этой же Lua-машине. Повторное объявление с другой сигнатурой роняет
-- ffi.cdef, поэтому объявляем осторожно: если не вышло, detect() просто
-- честно вернёт false, а не уронит скрипт на загрузке.
pcall(ffi.cdef, [[
    void* __stdcall GetModuleHandleA(const char* name);
]])

--- Загружен ли в процесс плагин чата, то есть будут ли токены отрисованы.
--- Результат запоминается; emoji.plugin = nil заставит проверить заново.
function emoji.detect()
    if emoji.plugin ~= nil then return emoji.plugin end
    local k = winapi()
    if not k then return false end

    local queried = false
    for _, name in ipairs(emoji.pluginModules) do
        local ok, h = pcall(function() return k.GetModuleHandleA(name) end)
        if ok then
            queried = true
            if h ~= nil then
                emoji.plugin = true
                return true
            end
        end
    end

    -- Если спросить не удалось ни разу (например, cdef перехватил кто-то
    -- другой), ответ не запоминаем: иначе одна осечка ffi навсегда
    -- притворилась бы тем, что плагина нет, и молча съела бы все смайлы.
    if not queried then return false end

    emoji.plugin = false
    return false
end

--- Убирает токены из текста: строка станет читаемой там, где их некому
--- отрисовать. Вместе с токеном съедается один пробел за ним, иначе на
--- месте смайла оставались бы двойные пробелы.
function emoji.strip(text)
    if type(text) ~= 'string' then return text end
    local out = text:gsub(emoji.TOKEN .. ' ?', '')
    out = out:gsub(' +\n', '\n'):gsub(' +$', '')
    return out
end

--- Текст под текущий сервер: как есть, если плагин чата на месте,
--- и без токенов, если его нет.
function emoji.fit(text)
    if emoji.detect() then return text end
    return emoji.strip(text)
end

--- Приводит именные токены к каноническому виду: ':trophy:' -> ':u1f3c6:'.
--- Заменяются только имена, которые есть в атласе, всё остальное текст
--- не трогает. Отдельная функция, а не часть fit(), потому что двоеточия
--- встречаются и в обычном тексте ("итого: 12:30"), и решать, канонизировать
--- их или нет, должен автор скрипта.
---
--- Имена-смайлики из таблицы плагина (':)', '^_^', ':\\') специально
--- не разворачиваются: чтобы их поймать, пришлось бы хватать из текста
--- скобки и слеши, и обычная строка вида "время (:00)" ломалась бы.
--- Для них берите emoji.tok(':)') явно.
function emoji.expand(text)
    if type(text) ~= 'string' then return text end
    return (text:gsub(':([%w_%-+]+):', function(name)
        local e = emoji.byName[name]
        return e and e.token or nil     -- nil оставляет исходный кусок
    end))
end

--- Что строка будет стоить в диалоге: сколько байт занимает, сколько в ней
--- токенов и сколько байт из них съедено разметкой. visible - грубая оценка
--- длины «на глаз», где каждый токен считается за один знак.
function emoji.measure(text)
    text = tostring(text)
    local tokens, tokenBytes = 0, 0
    for tk in text:gmatch(emoji.TOKEN) do
        tokens = tokens + 1
        tokenBytes = tokenBytes + #tk
    end
    return {
        bytes = #text,
        tokens = tokens,
        tokenBytes = tokenBytes,
        visible = #text - tokenBytes + tokens,
    }
end

--- sampShowDialog с двумя удобствами: текст и заголовок проходят через
--- fit(), а слишком длинный текст не уходит молча.
--- Порядок аргументов тот же, что у sampShowDialog.
-- @return true либо false, причина
function emoji.dialog(id, caption, text, button1, button2, style)
    caption = emoji.fit(caption or '')
    text = emoji.fit(text or '')

    if #text > emoji.DIALOG_LIMIT then
        return false, ('dialog text is %d bytes, limit is %d')
            :format(#text, emoji.DIALOG_LIMIT)
    end

    sampShowDialog(id, caption, text, button1 or 'OK', button2 or '', style or 0)
    return true
end

--------------------------------------------------------------------------
-- Отрисовка
--------------------------------------------------------------------------

local WHITE = 0xFFFFFFFF

local function styleColor(col)
    return imgui.ColorConvertFloat4ToU32(imgui.GetStyle().Colors[col])
end

--- Рисует смайл как картинку.
-- @return true, если смайл найден и нарисован
function emoji.image(key, size)
    if not imgui then return false end
    local e = emoji.get(key)
    size = size or imgui.GetFontSize()
    if not e or not emoji.loaded then
        imgui.Dummy(imgui.ImVec2(size, size))
        return false
    end
    imgui.Image(emoji.texture, imgui.ImVec2(size * e.cells, size), e.uv0, e.uv1)
    return true
end

--- Ширина смайла при заданной высоте. У широких серверных баннеров она
--- больше высоты в e.cells раз.
function emoji.width(key, size)
    local e = emoji.get(key)
    size = size or (imgui and imgui.GetFontSize()) or 0
    return e and size * e.cells or size
end

--- Кнопка со смайлом.
--- Сделана на InvisibleButton + draw list, а не на ImageButton: у всех кнопок
--- одна и та же текстура, а ImageButton берёт ID именно из неё, поэтому вся
--- сетка слиплась бы в один элемент. Заодно код не зависит от того, какая
--- сигнатура ImageButton в конкретной сборке mimgui.
function emoji.button(key, size, id)
    if not imgui then return false end
    local e = emoji.get(key)
    size = size or imgui.GetFontSize()
    if not e or not emoji.loaded then
        imgui.Dummy(imgui.ImVec2(size, size))
        return false
    end

    local pad = 2
    local w = size * e.cells + pad * 2
    local h = size + pad * 2
    local p = imgui.GetCursorScreenPos()
    local pressed = imgui.InvisibleButton(tostring(id or e.slot),
                                          imgui.ImVec2(w, h))
    local dl = imgui.GetWindowDrawList()
    if imgui.IsItemHovered() then
        local col = imgui.IsMouseDown(0) and imgui.Col.ButtonActive
                                          or imgui.Col.ButtonHovered
        dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h),
                         styleColor(col), 4.0)
    end
    dl:AddImage(emoji.texture,
                imgui.ImVec2(p.x + pad, p.y + pad),
                imgui.ImVec2(p.x + w - pad, p.y + h - pad),
                e.uv0, e.uv1, WHITE)
    return pressed
end

--- Разбирает строку на куски текста и смайлы.
-- @return массив { { text = '...' } | { emoji = <запись> } }
function emoji.parse(str)
    -- pos  - откуда искать следующий токен
    -- from - откуда начинается ещё не выданный кусок текста; двигается
    --        только когда токен реально распознан, иначе текст перед
    --        нераспознанным токеном потерялся бы
    local out, pos, from = {}, 1, 1
    while true do
        local s, e2, hex = str:find(emoji.PATTERN, pos)
        if not s then break end
        local rec = emoji.byCp[tonumber(hex, 16)]
        if rec then
            if s > from then out[#out + 1] = { text = str:sub(from, s - 1) } end
            out[#out + 1] = { emoji = rec }
            pos = e2 + 1
            from = pos
        else
            -- неизвестный токен оставляем как обычный текст
            pos = s + 1
        end
    end
    if from <= #str then out[#out + 1] = { text = str:sub(from) } end
    return out
end

--- Рисует строку, подставляя смайлы вместо токенов :uXXXX:.
--- Строка должна быть в UTF-8. Литералы из файла, сохранённого в UTF-8,
--- подходят как есть; строку из игры (cp1251) сперва пропустите через u8().
function emoji.text(str, size)
    if not imgui then return end
    size = size or imgui.GetFontSize()
    local parts = emoji.parse(str)
    local first = true
    for _, p in ipairs(parts) do
        if not first then imgui.SameLine(0, 0) end
        first = false
        if p.emoji then
            -- Dummy держит место в раскладке (высотой со строку текста),
            -- а сам смайл рисуется через draw list с центровкой по вертикали
            local line = imgui.GetTextLineHeight()
            local pos = imgui.GetCursorScreenPos()
            local dy = (line - size) / 2
            local w = size * p.emoji.cells
            imgui.GetWindowDrawList():AddImage(
                emoji.texture,
                imgui.ImVec2(pos.x, pos.y + dy),
                imgui.ImVec2(pos.x + w, pos.y + dy + size),
                p.emoji.uv0, p.emoji.uv1, WHITE)
            imgui.Dummy(imgui.ImVec2(w, line))
        else
            imgui.TextUnformatted(p.text)
        end
    end
end

--------------------------------------------------------------------------
-- Панель выбора
--------------------------------------------------------------------------

-- Буфер поиска свой у каждой панели: иначе две панели в одном скрипте
-- делили бы одну строку поиска.
local searchBufs = {}
local function searchBuffer(pid)
    local b = searchBufs[pid]
    if not b then
        b = imgui.new.char[64]()
        searchBufs[pid] = b
    end
    return b
end

--- Панель выбора смайла: поиск + сетка по категориям.
-- @param id     уникальный идентификатор панели
-- @param size   размер смайла в сетке (по умолчанию 24)
-- @param height высота области прокрутки (по умолчанию 320)
-- @return выбранная запись либо nil
function emoji.picker(id, size, height)
    if not imgui then return nil end
    if not emoji.loaded then
        imgui.TextDisabled(emoji.strings.notLoaded)
        return nil
    end
    size = size or 24
    height = height or 320
    local picked = nil

    -- Пространство имён делаем суффиксом в подписях, а не PushID: PushID в
    -- ImGui перегружена (int/str/ptr), и биндинг mimgui не отдаёт её под
    -- коротким именем - imgui.PushID там nil.
    local pid = tostring(id or 'chat_emoji_picker')

    local searchBuf = searchBuffer(pid)
    imgui.PushItemWidth(-1)
    imgui.InputTextWithHint('##search' .. pid, emoji.strings.search,
                            searchBuf, ffi.sizeof(searchBuf))
    imgui.PopItemWidth()

    local query = ffi.string(searchBuf):lower()
    local spacing = imgui.GetStyle().ItemSpacing.x

    imgui.BeginChild('##grid' .. pid, imgui.ImVec2(0, height), true)
    local avail = imgui.GetContentRegionAvail().x

    local function matches(e)
        if query == '' then return true end
        if e.name:lower():find(query, 1, true) then return true end
        if e.aliases then
            for _, a in ipairs(e.aliases) do
                if a:lower():find(query, 1, true) then return true end
            end
        end
        return false
    end

    for _, cat in ipairs(emoji.categories) do
        local shown = {}
        for _, e in ipairs(cat.items) do
            if matches(e) then shown[#shown + 1] = e end
        end
        if #shown > 0 then
            imgui.TextDisabled(cat.name)
            -- кнопки разной ширины: широкий баннер занимает несколько мест,
            -- поэтому перенос строки считаем вручную, а не по числу в ряду
            local x = 0
            for _, e in ipairs(shown) do
                local w = size * e.cells + 4
                if x > 0 then
                    if x + spacing + w <= avail then
                        imgui.SameLine()
                        x = x + spacing
                    else
                        x = 0           -- не зовём SameLine - будет перенос
                    end
                end
                if emoji.button(e, size, pid .. '_' .. e.slot) then picked = e end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip((':%s:  %s'):format(e.name, e.token))
                end
                x = x + w
            end
            imgui.Spacing()
        end
    end
    imgui.EndChild()

    return picked
end

return emoji
