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
-- Использование:
--   local emoji = require 'chat_emoji'
--   imgui.OnInitialize(function() emoji.load() end)
--   ...
--   emoji.image('smiley', 24)
--   emoji.text('привет :u1f603: как дела')
--   local picked = emoji.picker('emj', 24)
--   if picked then sampSendChat(emoji.encode(picked)) end

local ffi = require 'ffi'
local imgui = require 'mimgui'

local emoji = {}

emoji.loaded = false
emoji.texture = nil
emoji.atlas = nil
emoji.list = {}          -- массив записей в порядке из чата
emoji.byName = {}        -- name -> запись
emoji.byCp = {}          -- codepoint -> запись
emoji.categories = {}    -- { { name = 'Смайлы', items = { ... } }, ... }

-- Токен смайла в тексте чата: :u1f603: (шестнадцатеричная кодовая точка).
emoji.PATTERN = ':u(%x+):'

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

--- Загружает описание атласа и текстуру. Вызывать из imgui.OnInitialize.
-- @param dir каталог с chat_emoji_atlas.lua и chat_emoji.png (необязательно)
-- @return true либо false, текст ошибки
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

function emoji.load(dir)
    if emoji.loaded then return true end

    local okApi, apiErr = checkImgui()
    if not okApi then return false, apiErr end

    dir = dir or defaultDir()

    local descPath = dir .. 'chat_emoji_atlas.lua'
    local chunk, err = loadfile(descPath)
    if not chunk then return false, 'cannot read ' .. descPath .. ': ' .. tostring(err) end
    local ok, atlas = pcall(chunk)
    if not ok or type(atlas) ~= 'table' then
        return false, 'malformed ' .. descPath
    end

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
            uv0 = imgui.ImVec2(col * atlas.cell / atlas.width,
                               line * atlas.cell / atlas.height),
            uv1 = imgui.ImVec2((col + cells) * atlas.cell / atlas.width,
                               (line + 1) * atlas.cell / atlas.height),
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

    emoji.loaded = true
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
    size = size or imgui.GetFontSize()
    return e and size * e.cells or size
end

--- Кнопка со смайлом.
--- Сделана на InvisibleButton + draw list, а не на ImageButton: у всех кнопок
--- одна и та же текстура, а ImageButton берёт ID именно из неё, поэтому вся
--- сетка слиплась бы в один элемент. Заодно код не зависит от того, какая
--- сигнатура ImageButton в конкретной сборке mimgui.
function emoji.button(key, size, id)
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
