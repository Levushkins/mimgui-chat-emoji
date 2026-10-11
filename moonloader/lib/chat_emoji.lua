-- chat_emoji.lua v3.2 - смайлы из _chat.asi (Arizona Games) для mimgui.
--
-- Почему через текстуру, а не через шрифт:
--   mimgui собран со stb_truetype и 16-битным ImWchar. stb_truetype не умеет
--   цветные глифы (COLR/CPAL и SVG - а именно так устроены Segoe UI Emoji и
--   icons.ttf из _chat.asi), а 16-битный ImWchar физически не может хранить
--   кодовые точки выше U+FFFF, где и живут почти все смайлы (U+1F300+).
--   Поэтому смайлы заранее растеризуются в один PNG-атлас
--   (tools/build_emoji_atlas.py), а здесь он грузится как текстура D3D9
--   и рисуется через draw list с нужными UV.
--
-- Установка:
--   moonloader/lib/chat_emoji.lua
--   moonloader/resource/chat_emoji/chat_emoji.png
--   moonloader/resource/chat_emoji/chat_emoji_atlas.lua
--   moonloader/resource/chat_emoji/chat_emoji_small.png    (необязательно)
--   moonloader/resource/chat_emoji/chat_emoji_search.lua   (необязательно)
--
-- Отрисовка в mimgui:
--   local emoji = require 'chat_emoji'
--   imgui.OnInitialize(function() emoji.load() end)
--   ...
--   emoji.image('smiley', 24)
--   emoji.text('привет :u1f603: как дела')
--   emoji.text(chatLine, 18, { color = true, wrap = 400 })
--   local picked = emoji.picker('emj', { size = 24, height = 320 })
--   if picked then sampSendChat(emoji.encode(picked)) end
--
-- Диалоги SA-MP (смайлы рисует сам плагин, см. раздел «Диалоги»):
--   local emoji = require 'chat_emoji'
--   emoji.loadTable()                      -- ни текстуры, ни mimgui не надо
--   emoji.dialog(1234, 'Меню ' .. emoji.tok('arz'),
--                emoji.tok('trophy') .. ' Рекорды\n' ..
--                emoji.tok('lock')   .. ' Закрыто',
--                'Выбрать', 'Отмена', 2)
--
-- Что где лежит:
--   Загрузка      load, loadTable, reload, build, unload, atLeast
--   Поиск         get, encode, tok, find, category, random
--   Иконки игры   weapon, crown, wings
--   Буквы         letter, digit, number, stylize
--   Текст         strip, fit, expand, decode, measure, split
--   Unicode       toUnicode, fromUnicode
--   Сервер        canRender, serverSupports, detect, dialog, sendChat,
--                 addChatMessage, insertToChatInput
--   Отрисовка     image, width, button, parse, text, textWrapped,
--                 richText, calcTextSize
--   Поверх игры   drawText, drawImage, draw3D
--   Виджеты       textButton, selectable, tooltipText
--   Шрифт ImGui   fontGlyphs, glyph, toGlyphs, fromGlyphs
--   Панель        picker, pickerPopup, pickerButton, inputText,
--                 setPickerQuery
--   Избранное     favorite, isFavorite, pushRecent, loadState, saveState
--   Проверка      info, selfTest, checkSource
--
-- Что нового в 3.2:
--   * 14 новых иконок из обновления плагина (Telegram, VK, логотипы биржи);
--     имя 'apple' теперь у логотипа, яблоко ищется как 'red_apple';
--   * атлас без пустой половины: 11 МБ видеопамяти вместо 16, плюс малый
--     атлас для смайлов до 20 px - они больше не рябят;
--   * emoji.FORMAT = 'dxt5' сжимает текстуры ещё вчетверо;
--   * поиск по-русски («сердце», «огонь») и с неправильной раскладкой;
--   * emoji.fontGlyphs() вшивает смайлы в шрифт ImGui: они работают
--     в обычных imgui.Text, Button, InputText, меню и вкладках;
--   * toUnicode/fromUnicode: мост с Telegram, VK и Discord;
--   * weapon(id), crown(n), wings(n) - иконки оружия GTA, корон и крыльев;
--   * sendChat делает паузу между частями и не ловит антифлуд;
--   * fit() различает «вижу я» и «видят все»: на чужом сервере токены
--     не уходят другим игрокам мусором;
--   * reload() после пересборки берёт новую текстуру, а не старую общую;
--   * библиотека замечает, что Arizona обновила _chat.asi, и пишет об этом
--     в moonloader.log.
--
-- Куда ещё можно ставить смайлы, кроме окон и диалогов:
--   emoji.drawText(x, y, str, opts)      поверх игры, окно не нужно
--   emoji.draw3D(x, y, z, str, opts)     метка над точкой в мире
--   emoji.insertToChatInput('smiley')    в строку ввода игрового чата
--   emoji.addChatMessage('привет :u1f603:')  локальная строка чата
--   emoji.textButton('Купить :u1f3c6:')  кнопка со смайлом в подписи
--   emoji.selectable('Часы :u23f0:')     строка списка
--   emoji.tooltipText('Осталось :u23f3:')  всплывающая подсказка
--
-- Что нового в 3.0 и 3.1 по сравнению с 2.x:
--   * emoji.text() понимает переносы строк, перенос по ширине и цветовые
--     теги вида {FDCF28}; рисует всё одним проходом по draw list;
--   * emoji.calcTextSize() меряет строку со смайлами, не рисуя её;
--   * панель выбора кеширует раскладку и рисует только видимые ряды,
--     умеет избранное, недавние и всплывающий вариант;
--   * emoji.split() режет сообщение под лимит чата, не разрывая токены;
--   * emoji.stylize() собирает надпись из «квадратных» букв и цифр;
--   * текстура освобождается сама, если скрипт забыл вызвать unload().

local ffi = require 'ffi'

-- mimgui нужен только для отрисовки. Работа с токенами и диалогами от него
-- не зависит, поэтому требуем его мягко: скрипт, которому нужны только
-- диалоги, не должен падать из-за отсутствующей библиотеки интерфейса.
local okImgui, imgui = pcall(require, 'mimgui')
if not okImgui then imgui = nil end

--- Можно ли вызвать. Функции mimgui - это C-функции из cimgui, и type()
--- у них 'cdata', а не 'function'. Проверка на 'function' молча считала
--- их отсутствующими: в 3.1 из-за этого drawText, drawImage и draw3D
--- ничего не рисовали, а tooltipText показывал токены текстом.
local function callable(v)
    local t = type(v)
    return t == 'function' or t == 'cdata'
end

--- Функция mimgui по имени либо nil. Через pcall: в части сборок обращение
--- к отсутствующему имени падает внутри биндинга, а не возвращает nil.
local imguiFnCache = {}
local function imguiFn(name)
    if not imgui then return nil end
    local cached = imguiFnCache[name]
    if cached ~= nil then return cached or nil end
    local ok, v = pcall(function() return imgui[name] end)
    v = (ok and callable(v)) and v or false
    imguiFnCache[name] = v
    return v or nil
end

---@class ChatEmoji запись атласа
---@field name string имя из таблицы плагина (или 'u1f603', если имени нет)
---@field cp integer кодовая точка
---@field token string токен для чата: ':u1f603:'
---@field cat string название категории
---@field catId string|nil короткое ASCII-имя категории
---@field slot integer номер ячейки в атласе
---@field index integer номер по порядку панели
---@field cells integer ширина в высотах (широкие плашки - до 8)
---@field aliases string[]|nil синонимы

---@class ChatEmojiTextOpts
---@field wrap? number|boolean ширина переноса; true - доступная ширина
---@field color? boolean понимать теги {RRGGBB}
---@field tint? integer цвет текста по умолчанию (ABGR)
---@field align? 'left'|'center'|'right'
---@field alpha? number от 0 до 1

local emoji = {}

emoji.VERSION = '3.2'

emoji.ready = false      -- таблицы построены (хватает для чата и диалогов)
emoji.loaded = false     -- то же плюс текстура: можно рисовать в mimgui
emoji.texture = nil
emoji.textureSmall = nil -- атлас вдвое меньше для смайлов до SMALL_BELOW px
emoji.sharedTexture = false
emoji.atlas = nil
emoji.stale = nil        -- true: атлас собран для другой версии _chat.asi
emoji.list = {}          -- массив записей в порядке из чата
emoji.byName = {}        -- name -> запись
emoji.byCp = {}          -- codepoint -> запись
emoji.categories = {}    -- { { name = 'Смайлы', items = { ... } }, ... }

-- Токен смайла в тексте чата: :u1f603: (шестнадцатеричная кодовая точка).
emoji.PATTERN = ':u(%x+):'
-- То же без захвата - для gsub и подсчётов.
emoji.TOKEN = ':u%x+:'
-- Цветовой тег SA-MP и Arizona: {FDCF28}.
emoji.COLOR_PATTERN = '{(%x%x%x%x%x%x)}'

-- Подписи панели. Специально латиницей: строковые литералы модуля тогда
-- целиком в ASCII, и пересохранение файла в другой кодировке их не портит
-- (блокнот по умолчанию пишет cp1251, а ImGui ждёт UTF-8 - отсюда «??»
-- вместо текста). Нужны русские надписи - задайте их у себя, а свой файл
-- сохраните в UTF-8:
--     emoji.strings.search = 'Поиск...'
-- Названия категорий приходят из описания атласа уже экранированными,
-- поэтому на них кодировка файла не влияет.
emoji.strings = {
    search = 'Search...',
    notLoaded = 'emoji atlas is not loaded',
    favorites = 'Favorites',
    recent = 'Recent',
    nothingFound = 'nothing found',
    pickerHint = 'RMB - add to favorites',
    found = 'Found',
}

--- Не старее ли загруженная библиотека, чем нужно скрипту.
--- Файл библиотеки один на все скрипты, и рано или поздно кто-нибудь
--- положит поверх новой версии старую. Лучше внятная ошибка на старте,
--- чем nil вместо функции посреди отрисовки:
---     assert(emoji.atLeast('3.2'), 'нужен chat_emoji 3.2 или новее')
---@param need string версия вида '3.2' или '3.2.1'
---@return boolean
function emoji.atLeast(need)
    local function parts(v)
        local out = {}
        for n in tostring(v):gmatch('%d+') do out[#out + 1] = tonumber(n) end
        return out
    end
    local have, want = parts(emoji.VERSION), parts(need)
    for i = 1, math.max(#have, #want) do
        local a, b = have[i] or 0, want[i] or 0
        if a ~= b then return a > b end
    end
    return true
end

--------------------------------------------------------------------------
-- Загрузка текстуры через D3DX
--------------------------------------------------------------------------

-- Объявления осторожные, через pcall: эти функции расхожие, и их вполне
-- мог объявить кто-то ещё в той же Lua-машине. Повторное объявление
-- с другой сигнатурой роняет ffi.cdef, а нам годится и чужое.
pcall(ffi.cdef, [[
    long __stdcall D3DXCreateTextureFromFileInMemoryEx(
        void* pDevice, const void* pSrcData, unsigned int SrcDataSize,
        unsigned int Width, unsigned int Height, unsigned int MipLevels,
        unsigned long Usage, unsigned int Format, unsigned int Pool,
        unsigned long Filter, unsigned long MipFilter, unsigned long ColorKey,
        void* pSrcInfo, void* pPalette, void** ppTexture);
]])

-- Свои имена структур, чтобы не столкнуться с чужими объявлениями D3D9.
ffi.cdef [[
    typedef struct {
        unsigned int Format, Type;
        unsigned long Usage;
        unsigned int Pool, MultiSampleType;
        unsigned long MultiSampleQuality;
        unsigned int Width, Height;
    } chat_emoji_surface_desc;
    typedef struct { int Pitch; void* pBits; } chat_emoji_locked_rect;
]]

local D3DFMT_A8R8G8B8 = 21
local D3DFMT_DXT5 = 0x35545844  -- MAKEFOURCC('D', 'X', 'T', '5')
local D3DPOOL_MANAGED = 1   -- переживает device reset, ничего пересоздавать не надо
local D3DPOOL_SCRATCH = 3   -- только память процесса: читать пиксели для шрифта
local D3DX_FILTER_NONE = 1

-- Формат текстур. 'argb' - без потерь, 'dxt5' - вчетверо меньше видеопамяти
-- (около 3.4 МБ на оба атласа вместо 13.3), но мелкие детали чуть мылятся.
-- Задавать до emoji.load(). Если видеокарта DXT5 не умеет, библиотека
-- молча вернётся к 'argb'.
emoji.FORMAT = 'argb'

-- Малый атлас (ячейка 20 px) берётся для смайлов не крупнее этого размера.
-- ImGui рисует текстуры без mip-уровней, и сжатая втрое картинка из ячейки
-- 40 px рябит. emoji.SMALL = false отключает малый атлас совсем.
emoji.SMALL = true
emoji.SMALL_BELOW = 20

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

--- Создаёт текстуру из PNG в памяти.
-- @param fmt  'argb' | 'dxt5'
-- @param pool D3DPOOL_*, по умолчанию MANAGED
local function createTexture(pngData, fmt, pool)
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
        fmt == 'dxt5' and D3DFMT_DXT5 or D3DFMT_A8R8G8B8,
        pool or D3DPOOL_MANAGED,
        D3DX_FILTER_NONE,
        D3DX_FILTER_NONE,
        0,
        nil, nil, out)
    if hr ~= 0 or out[0] == nil then
        return nil, ('D3DXCreateTextureFromFileInMemoryEx: 0x%08X')
            :format(tonumber(hr) % 0x100000000)
    end
    return out[0]
end

-- IUnknown: AddRef это метод 1 в vtable, Release это метод 2.
-- IDirect3DTexture9: GetLevelDesc 17, LockRect 19, UnlockRect 20.
local function comCall(obj, index)
    local vtbl = ffi.cast('void***', obj)[0]
    return ffi.cast('unsigned long(__stdcall*)(void*)', vtbl[index])(obj)
end

--- Настоящий размер текстуры.
--- На видеокартах без поддержки произвольных размеров D3DX округляет
--- текстуру вверх до степени двойки и кладёт картинку в левый верхний
--- угол. UV тогда надо считать от реального размера, а не от описания,
--- иначе все смайлы съедут.
local function textureSize(tex)
    local ok, w, h = pcall(function()
        local desc = ffi.new('chat_emoji_surface_desc')
        local vtbl = ffi.cast('void***', tex)[0]
        local fn = ffi.cast('long(__stdcall*)(void*, unsigned int, chat_emoji_surface_desc*)',
                            vtbl[17])
        if fn(tex, 0, desc) ~= 0 then return nil end
        return tonumber(desc.Width), tonumber(desc.Height)
    end)
    if ok then return w, h end
    return nil
end

--- Читает пиксели текстуры из пула SCRATCH. Нужен для fontGlyphs().
-- @return указатель на BGRA, шаг строки, функция, которую надо вызвать
--         по окончании (отпускает блокировку и саму текстуру)
local function lockTexture(tex)
    local rect = ffi.new('chat_emoji_locked_rect')
    local vtbl = ffi.cast('void***', tex)[0]
    local lock = ffi.cast('long(__stdcall*)(void*, unsigned int, chat_emoji_locked_rect*, void*, unsigned long)',
                          vtbl[19])
    if lock(tex, 0, rect, nil, 0) ~= 0 then return nil end
    local function done()
        ffi.cast('long(__stdcall*)(void*, unsigned int)', vtbl[20])(tex, 0)
        comCall(tex, 2)
    end
    return ffi.cast('uint8_t*', rect.pBits), rect.Pitch, done
end

--------------------------------------------------------------------------
-- Общая текстура на все скрипты
--------------------------------------------------------------------------
-- MoonLoader запускает каждый скрипт в отдельной Lua-машине, поэтому три
-- скрипта с этой библиотекой создавали три копии одной и той же текстуры.
-- Машины разные, но процесс один, а значит указатель можно передать через
-- переменную окружения процесса.
--
-- Время жизни считает сам COM: кто нашёл готовую текстуру, делает AddRef,
-- при выгрузке каждый делает Release. Переменная стирается, когда Release
-- вернул ноль, и только если в ней всё ещё наш адрес: после пересборки
-- атласа в слоте уже лежит новая текстура, и стирать её последний
-- держатель старой не должен.
--
-- В ключе, кроме пути и числа записей, хеш атласа и формат. Раньше ключ
-- был только «путь#число», и reload() после пересборки с тем же числом
-- смайлов получал старую текстуру от соседнего скрипта.
--
-- Если общая текстура почему-то мешает, до вызова load() поставьте
-- emoji.SHARED = false, и скрипт создаст свою копию.

pcall(ffi.cdef, [[
    unsigned long __stdcall GetEnvironmentVariableA(const char* name,
                                                    char* buf,
                                                    unsigned long size);
    int __stdcall SetEnvironmentVariableA(const char* name, const char* value);
]])

-- Слоты отдельные от 3.1 и старше: старые версии стирали слот, не глядя,
-- чей там адрес, и выбивали бы из него новую текстуру.
local SLOT_MAIN = 'CHAT_EMOJI_TEXTURE_V3'
local SLOT_SMALL = 'CHAT_EMOJI_TEXTURE_V3_SMALL'

emoji.SHARED = true

local kernel32 = nil
local function winapi()
    if kernel32 == nil then
        local ok, lib = pcall(ffi.load, 'kernel32')
        kernel32 = ok and lib or false
    end
    return kernel32 or nil
end

local function slotRead(slot)
    local k = winapi()
    if not k then return nil end
    local ok, value = pcall(function()
        local buf = ffi.new('char[512]')
        local n = k.GetEnvironmentVariableA(slot, buf, 512)
        if n == 0 or n >= 512 then return nil end
        return ffi.string(buf, n)
    end)
    return ok and value or nil
end

local function slotWrite(slot, value)
    local k = winapi()
    if k then pcall(k.SetEnvironmentVariableA, slot, value) end
end

local function addressOf(tex)
    local ok, addr = pcall(function()
        return tonumber(ffi.cast('uint32_t', ffi.cast('uintptr_t', tex)))
    end)
    return ok and addr or nil
end

--- Берёт уже созданную кем-то текстуру того же атласа, если она есть.
local function takeShared(slot, key)
    local raw = slotRead(slot)
    if not raw then return nil end
    local addr, storedKey = raw:match('^(%x+)|(.*)$')
    if not addr or storedKey ~= key then return nil end
    local ok, tex = pcall(ffi.cast, 'void*', tonumber(addr, 16))
    if not ok or tex == nil then return nil end
    if not pcall(comCall, tex, 1) then return nil end     -- AddRef
    return tex
end

local function publishShared(slot, key, tex)
    local addr = addressOf(tex)
    if addr then slotWrite(slot, ('%08X|%s'):format(addr, key)) end
end

--- Отпускает текстуру. Слот стирается, только если отпустили последнюю
--- ссылку и в слоте лежит именно эта текстура.
local function releaseTexture(slot, tex)
    local addr = addressOf(tex)
    local ok, refs = pcall(comCall, tex, 2)              -- Release
    if ok and refs == 0 and addr then
        local stored = (slotRead(slot) or ''):match('^(%x+)|')
        if stored and tonumber(stored, 16) == addr then slotWrite(slot, '') end
    end
end

--- Находит общую текстуру или создаёт свою.
-- @return текстура, ширина, высота, взята ли общая; либо nil, ошибка
local function obtainTexture(slot, path, count, hash, fmt)
    local f = io.open(path, 'rb')
    if not f then return nil, 'not found: ' .. path end
    local size = f:seek('end')
    local key = ('%s#%s#%s#%s'):format(path:lower(), tostring(count),
                                       tostring(hash or size), fmt)
    if emoji.SHARED then
        local tex = takeShared(slot, key)
        if tex then
            f:close()
            local w, h = textureSize(tex)
            return tex, w, h, true
        end
    end
    f:seek('set', 0)
    local png = f:read('*a')
    f:close()
    if not png or #png == 0 then return nil, 'empty file: ' .. path end

    local tex, err = createTexture(png, fmt)
    if not tex and fmt == 'dxt5' then
        tex, err = createTexture(png, 'argb')
        key = key:gsub('#dxt5$', '#argb')
    end
    if not tex then return nil, err end
    if emoji.SHARED then publishShared(slot, key, tex) end
    local w, h = textureSize(tex)
    return tex, w, h, false
end

--------------------------------------------------------------------------
-- Автоматическая выгрузка
--------------------------------------------------------------------------
-- Раньше скрипт, который забыл вызвать unload() в onScriptTerminate,
-- навсегда оставлял в общем слоте адрес текстуры и лишнюю ссылку на неё.
-- Следующий скрипт брал этот адрес и работал с уже мёртвым объектом.
-- Поэтому обработчик вешаем сами, при первой удачной загрузке текстуры.
-- Свой обработчик в скрипте это не отменяет: unload() идемпотентен.
--
-- На выходе из игры (quitGame) текстуру не трогаем: устройство D3D к тому
-- моменту может быть уже разрушено, и Release упадёт на пустом месте.

local autoReleaseSet = false
local function armAutoRelease()
    if autoReleaseSet then return end
    autoReleaseSet = true
    pcall(function()
        addEventHandler('onScriptTerminate', function(scr, quitGame)
            if scr == thisScript() and not quitGame then emoji.unload() end
        end)
    end)
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
    'new', 'Col', 'ImVec2', 'Dummy', 'InvisibleButton', 'GetWindowDrawList',
    'IsItemHovered', 'IsMouseDown', 'IsMouseClicked', 'ColorConvertFloat4ToU32',
    'GetStyle', 'GetCursorScreenPos', 'GetFontSize', 'GetTextLineHeight',
    'CalcTextSize', 'TextDisabled', 'PushItemWidth', 'PopItemWidth',
    'InputTextWithHint', 'BeginChild', 'EndChild', 'GetContentRegionAvail',
    'GetWindowHeight', 'GetScrollY', 'GetCursorPosY', 'SetCursorPosY',
    'SameLine', 'Spacing', 'SetTooltip', 'Button', 'OpenPopup', 'BeginPopup',
    'EndPopup', 'CloseCurrentPopup', 'Image',
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

--- Проверяет описание атласа до того, как по нему начнут считать UV.
--- Пустой или обрезанный файл иначе давал бы деление на ноль и смайлы,
--- растянутые на всю текстуру, а причину пришлось бы искать глазами.
local function validateAtlas(a)
    if type(a) ~= 'table' then return false, 'atlas description is not a table' end
    if type(a.emoji) ~= 'table' or #a.emoji == 0 then
        return false, 'atlas.emoji is empty or missing'
    end
    if type(a.file) ~= 'string' or a.file == '' then
        return false, 'atlas.file is missing'
    end
    for _, k in ipairs({ 'width', 'height', 'cell', 'cols' }) do
        if type(a[k]) ~= 'number' or a[k] <= 0 then
            return false, 'atlas.' .. k .. ' is missing or not a positive number'
        end
    end
    return true
end

--------------------------------------------------------------------------
-- Устарел ли атлас
--------------------------------------------------------------------------
-- Arizona время от времени обновляет _chat.asi: в сентябре 2026 добавила
-- 14 иконок. Атлас, собранный по старой версии, о них не знает, а
-- токены для них в чате уже работают. Поэтому сборщик записывает в атлас
-- размер и время сборки плагина, а библиотека сверяет их с тем, что лежит
-- в папке игры.

-- Не писать предупреждение об устаревшем атласе в moonloader.log.
emoji.QUIET = false

local function gameDir()
    if type(getGameDirectory) == 'function' then
        local ok, dir = pcall(getGameDirectory)
        if ok and type(dir) == 'string' and dir ~= '' then return dir end
    end
    return getWorkingDirectory() .. '\\..'
end

local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

--- Сверяет атлас с _chat.asi в папке игры.
---@param path? string путь к _chat.asi, если он лежит не в папке игры
---@return boolean|nil same true - атлас свежий, false - устарел, nil - проверить нечем
---@return string? why  пояснение, если не true
function emoji.checkSource(path)
    local src = emoji.atlas and emoji.atlas.source
    if type(src) ~= 'table' or not src.size then
        return nil, 'atlas has no source info (built before 3.2)'
    end
    path = path or (gameDir() .. '\\' .. tostring(src.file or '_chat.asi'))
    local f = io.open(path, 'rb')
    if not f then return nil, 'not found: ' .. path end
    local head = f:read(4096) or ''
    local size = f:seek('end')
    f:close()

    -- Время сборки из COFF-заголовка: e_lfanew -> 'PE\0\0' -> Machine(2),
    -- NumberOfSections(2), TimeDateStamp(4).
    local stamp = nil
    if #head >= 0x40 then
        local pe = u32le(head, 0x3D)
        if pe + 12 <= #head and head:sub(pe + 1, pe + 4) == 'PE\0\0' then
            stamp = u32le(head, pe + 9)
        end
    end

    local same = size == src.size and (stamp == nil or src.stamp == nil
                                       or stamp == src.stamp)
    emoji.stale = not same
    if same then return true end
    return false, ('_chat.asi changed: %d bytes, build 0x%08X; atlas was made '
                   .. 'for %d bytes, build 0x%08X. Run rebuild.bat')
        :format(size, stamp or 0, src.size, src.stamp or 0)
end

local warnedStale = false
local function warnIfStale()
    if warnedStale then return end
    warnedStale = true
    local ok, same, why = pcall(emoji.checkSource)
    if ok and same == false and not emoji.QUIET then
        print('[chat_emoji] ' .. tostring(why))
    end
end

--------------------------------------------------------------------------
-- Загрузка и сборка таблиц
--------------------------------------------------------------------------

--- Читает только описание атласа: имена, кодовые точки, категории.
--- Ни текстуры, ни D3D, ни mimgui - этого достаточно, чтобы собирать
--- токены для чата и для диалогов SA-MP. Вызывать откуда угодно,
--- в том числе из main().
---@param dir? string каталог с chat_emoji_atlas.lua
---@return boolean ok
---@return string? err
function emoji.loadTable(dir)
    if emoji.ready then return true end
    dir = dir or defaultDir()
    local atlas, err = readAtlas(dir)
    if not atlas then return false, err end
    emoji.dir = dir
    local ok, berr = emoji.build(atlas)
    if ok then warnIfStale() end
    return ok, berr
end

--- Загружает описание атласа и текстуры. Вызывать из imgui.OnInitialize.
---@param dir? string каталог с chat_emoji_atlas.lua и PNG
---@return boolean ok
---@return string? err
function emoji.load(dir)
    if emoji.loaded then return true end

    if not imgui then return false, 'mimgui is not available' end
    local okApi, apiErr = checkImgui()
    if not okApi then return false, apiErr end

    dir = dir or defaultDir()

    local atlas, err = readAtlas(dir)
    if not atlas then return false, err end
    local okAtlas, atlasErr = validateAtlas(atlas)
    if not okAtlas then return false, atlasErr end

    local fmt = emoji.FORMAT == 'dxt5' and 'dxt5' or 'argb'
    local count = atlas.count or #atlas.emoji

    -- если этот же атлас уже загрузил другой скрипт, переиспользуем текстуру
    local tex, w, h, shared = obtainTexture(SLOT_MAIN, dir .. atlas.file,
                                            count, atlas.hash, fmt)
    if not tex then return false, w end
    emoji.texture = tex
    emoji.sharedTexture = shared
    armAutoRelease()

    -- UV считаются от реального размера: см. textureSize()
    w, h = w or atlas.width, h or atlas.height
    atlas.texWidth = w ~= atlas.width and w or nil
    atlas.texHeight = h ~= atlas.height and h or nil

    -- Малый атлас годится только когда раскладка совпадает один в один:
    -- ни одна из текстур не была округлена. Иначе UV у них разные, и
    -- проще обойтись без малого атласа, чем держать два набора координат.
    local s = atlas.small
    if emoji.SMALL ~= false and type(s) == 'table' and s.file then
        local stex, sw, sh = obtainTexture(SLOT_SMALL, dir .. s.file, count,
                                           s.hash, fmt)
        if stex then
            -- nil - размер узнать не удалось; считаем, что он как в описании
            if (sw == nil or sw == s.width) and (sh == nil or sh == s.height)
               and not atlas.texWidth and not atlas.texHeight then
                emoji.textureSmall = stex
            else
                releaseTexture(SLOT_SMALL, stex)
            end
        end
    end

    emoji.dir = dir
    local okBuild, buildErr = emoji.build(atlas)
    if not okBuild then
        emoji.unload()
        return false, buildErr
    end
    warnIfStale()
    return true
end

--- Перечитывает атлас с диска: и описание, и текстуры.
--- Нужно после пересборки атласа (rebuild.bat), чтобы не перезапускать
--- игру. Хеш атласа входит в ключ общей текстуры, поэтому новая картинка
--- не подменится старой из соседнего скрипта.
function emoji.reload(dir)
    emoji.unload()
    emoji.ready = false
    emoji.list, emoji.byName, emoji.byCp, emoji.categories = {}, {}, {}, {}
    warnedStale = false
    emoji.invalidate()
    return emoji.load(dir or emoji.dir)
end

--- Строит таблицы поиска и UV по описанию атласа.
--- Вынесено отдельно, чтобы это можно было прогнать без игры и без D3D
--- (см. tools/test_chat_emoji.lua).
---@return boolean ok
---@return string? err
function emoji.build(atlas)
    local ok, err = validateAtlas(atlas)
    if not ok then return false, err end

    emoji.atlas = atlas
    emoji.list, emoji.byName, emoji.byCp, emoji.categories = {}, {}, {}, {}
    emoji.keywordsLoaded = false

    -- Короткие ASCII-имена категорий (описание версии 3 и новее)
    local catIds = {}
    if type(atlas.categories) == 'table' then
        for _, c in ipairs(atlas.categories) do
            if c.name and c.id then catIds[c.name] = c.id end
        end
    end

    local texW = atlas.texWidth or atlas.width
    local texH = atlas.texHeight or atlas.height

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
        local u0 = col * atlas.cell / texW
        local v0 = line * atlas.cell / texH
        local u1 = (col + cells) * atlas.cell / texW
        local v1 = (line + 1) * atlas.cell / texH
        local e = {
            name = name,
            cp = cp,
            cat = cat,
            catId = catIds[cat],
            slot = slot,
            index = i,
            -- Ширина глифа в высотах: у обычного смайла 1, у серверного
            -- баннера («ВИП ЧАТ», ленты) до 4. Рисуем с этим соотношением,
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
        -- имена в таблице чата не уникальны (kkk/m, ng-цифра и ng-значок),
        -- первый выигрывает
        if not emoji.byName[name] then emoji.byName[name] = e end
        if not emoji.byCp[cp] then emoji.byCp[cp] = e end
        if aliases then
            e.aliases = aliases
            for _, a in ipairs(aliases) do
                if not emoji.byName[a] then emoji.byName[a] = e end
            end
        end

        -- Строка для поиска собирается один раз. Раньше панель на каждом
        -- кадре звала :lower() полторы тысячи раз, и на больших размерах
        -- сетки это было заметно. Русские слова добавляются позже и
        -- отдельно, при первом поиске кириллицей (см. «Поиск»).
        local searchable = name
        if aliases then searchable = searchable .. ' ' .. table.concat(aliases, ' ') end
        e.search = (searchable .. ' ' .. tostring(e.catId or '')):lower()

        local c = catIndex[cat]
        if not c then
            c = { name = cat, id = catIds[cat], items = {} }
            catIndex[cat] = c
            emoji.categories[#emoji.categories + 1] = c
        end
        c.items[#c.items + 1] = e
    end

    emoji.ready = true
    -- Рисовать можно только когда текстура действительно есть: loadTable()
    -- строит те же таблицы, но без неё.
    emoji.loaded = emoji.texture ~= nil
    emoji.invalidate()
    return true
end

--- Освобождает текстуры. Вызывать при выгрузке скрипта.
--- Вызывать повторно безопасно.
function emoji.unload()
    if emoji.texture ~= nil then
        releaseTexture(SLOT_MAIN, emoji.texture)
        emoji.texture = nil
    end
    if emoji.textureSmall ~= nil then
        releaseTexture(SLOT_SMALL, emoji.textureSmall)
        emoji.textureSmall = nil
    end
    emoji.sharedTexture = false
    emoji.loaded = false
    -- emoji.ready намеренно оставляем: таблицы имён и кодов никуда не делись,
    -- и токены для чата с диалогами собираются дальше без текстуры.
end

--- Текстура под размер: малый атлас для мелких смайлов, иначе основной.
local function texFor(size)
    if emoji.textureSmall ~= nil and size and size <= emoji.SMALL_BELOW then
        return emoji.textureSmall
    end
    return emoji.texture
end

--------------------------------------------------------------------------
-- Доступ к записям
--------------------------------------------------------------------------

--- Находит смайл по имени ('smiley'), кодовой точке (0x1F603),
--- токену (':u1f603:') или возвращает уже готовую запись.
---@param key string|integer|ChatEmoji имя, кодовая точка, токен или запись
---@return ChatEmoji|nil
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
---@param key string|integer|ChatEmoji
---@return string token
function emoji.encode(key)
    local e = emoji.get(key)
    return e and e.token or ''
end

--- Короткий синоним encode: emoji.tok('trophy') -> ':u1f3c6:'
---@param key string|integer|ChatEmoji
---@return string token
function emoji.tok(key)
    return emoji.encode(key)
end

--------------------------------------------------------------------------
-- Поиск
--------------------------------------------------------------------------
-- Ищем по трём источникам:
--   * английские имена и синонимы (из таблицы плагина и из базы Unicode);
--   * русские ключевые слова из Unicode CLDR («сердце», «огонь») и
--     названия категорий - они в chat_emoji_search.lua, который читается
--     только при первом поиске кириллицей;
--   * то же с неправильной раскладкой: 'jujym' найдёт «огонь»,
--     а 'ашку' найдёт fire.
-- Русские слова хранятся и сравниваются в cp1251: так файл вдвое меньше,
-- а строчные буквы получаются простой арифметикой над байтами. Литералы
-- ниже записаны escape-последовательностями, чтобы модуль оставался ASCII.

--- UTF-8 -> cp1251 в нижнем регистре, ё -> е. Всё, что не латиница и не
--- кириллица (смайлы, иероглифы), превращается в пробел.
local function toCp1251Lower(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 0x80 then
            if c >= 65 and c <= 90 then c = c + 32 end
            out[#out + 1] = string.char(c)
            i = i + 1
        elseif c >= 0xC0 and c < 0xE0 and i < n then
            local cp = (c % 0x20) * 64 + (s:byte(i + 1) % 64)
            if cp >= 0x410 and cp <= 0x42F then
                out[#out + 1] = string.char(cp - 0x410 + 0xE0)
            elseif cp >= 0x430 and cp <= 0x44F then
                out[#out + 1] = string.char(cp - 0x430 + 0xE0)
            elseif cp == 0x401 or cp == 0x451 then
                out[#out + 1] = '\229'                     -- ё -> е
            else
                out[#out + 1] = ' '
            end
            i = i + 2
        else
            out[#out + 1] = ' '
            i = i + (c >= 0xF0 and 4 or (c >= 0xE0 and 3 or 1))
        end
    end
    return table.concat(out)
end

emoji.toCp1251Lower = toCp1251Lower

-- Раскладка ЙЦУКЕН поверх QWERTY. Последняя пара - ` и ё, а ё ищем как е.
local LAYOUT_LAT = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`"
local LAYOUT_CYR = '\233\246\243\234\229\237\227\248\249\231\245\250' ..
                   '\244\251\226\224\239\240\238\235\228\230\253' ..
                   '\255\247\241\236\232\242\252\225\254\229'
local latToCyr, cyrToLat = {}, {}
for i = 1, #LAYOUT_LAT do
    local l, c = LAYOUT_LAT:sub(i, i), LAYOUT_CYR:sub(i, i)
    latToCyr[l] = c
    if not cyrToLat[c] then cyrToLat[c] = l end
end

emoji.keywordsLoaded = false

--- Подтягивает русские ключевые слова. Один раз на скрипт.
local function ensureKeywords()
    if emoji.keywordsLoaded then return end
    emoji.keywordsLoaded = true
    local words = {}
    local path = (emoji.dir or defaultDir()) .. 'chat_emoji_search.lua'
    local chunk = loadfile(path)
    if chunk then
        local ok, t = pcall(chunk)
        if ok and type(t) == 'table' then words = t end
    end
    -- Сначала собственные слова смайла (первое из них - основное имя),
    -- потом название категории: так совпадение с началом строки значит
    -- «это и есть то, что искали».
    for _, c in ipairs(emoji.categories) do
        local cname = toCp1251Lower(tostring(c.name))
        for _, e in ipairs(c.items) do
            local own = words[e.cp]
            e.kw = own and (own .. ' ' .. cname) or (' ' .. cname)
        end
    end
end

--- Собирает проверку под запрос. nil означает «подходит всё».
local function makeMatcher(query)
    local q = toCp1251Lower(tostring(query or ''))
    q = q:gsub('^%s+', ''):gsub('%s+$', '')
    if q == '' then return nil end

    local ascii, cyr
    if q:find('[\192-\255]') then
        cyr = q
        local lat = q:gsub('[\192-\255]', cyrToLat)
        if not lat:find('[\128-\255]') then ascii = lat end
    else
        ascii = q
        if #q >= 2 then cyr = q:gsub('.', latToCyr) end
    end
    if cyr then ensureKeywords() end

    -- Возвращает «насколько хорошо подходит»: 0 - точное имя, 1 - имя
    -- начинается с запроса, 2 - совпадение с начала слова, 3 - где-то внутри.
    -- nil - не подходит. Ноль в Lua истинен, так что проверка «if match(e)»
    -- работает как обычная.
    return function(e)
        if ascii then
            if e.name == ascii then return 0 end
            local s = e.search:find(ascii, 1, true)
            if s then
                if s == 1 then return 1 end
                return e.search:sub(s - 1, s - 1):find('[%s_]') and 2 or 3
            end
        end
        if cyr and e.kw then
            local s, f = e.kw:find(cyr, 1, true)
            if s then
                if s == 1 then
                    -- первое слово целиком - это основное имя смайла
                    local nxt = e.kw:sub(f + 1, f + 1)
                    return (nxt == ' ' or nxt == '') and 0 or 1
                end
                return e.kw:sub(s - 1, s - 1) == ' ' and 2 or 3
            end
        end
        return nil
    end
end

--- Поиск по имени, синонимам, русским словам и названию категории.
--- Запрос в UTF-8; регистр и раскладка клавиатуры не важны. Лучшие
--- совпадения идут первыми: точное имя, потом начало слова.
---@param query string подстрока; пустая строка вернёт всё
---@param limit? integer сколько записей вернуть максимум
---@return table[] записи
function emoji.find(query, limit)
    local match = makeMatcher(query)
    if not match then
        local out = {}
        for i, e in ipairs(emoji.list) do
            if limit and i > limit then break end
            out[i] = e
        end
        return out
    end
    local hits = {}
    for _, e in ipairs(emoji.list) do
        local score = match(e)
        if score then hits[#hits + 1] = { e = e, score = score } end
    end
    table.sort(hits, function(x, y)
        if x.score ~= y.score then return x.score < y.score end
        return x.e.index < y.e.index
    end)
    local out = {}
    for i, h in ipairs(hits) do
        if limit and i > limit then break end
        out[i] = h.e
    end
    return out
end

--- Записи одной категории по названию или короткому имени:
--- emoji.category('hidden_weapons').
---@param key string
---@return table[]|nil
function emoji.category(key)
    for _, c in ipairs(emoji.categories) do
        if c.name == key or c.id == key then return c.items end
    end
    return nil
end

--- Случайный смайл, при желании из конкретной категории.
---@param cat? string название или короткое имя категории
---@return ChatEmoji|nil
function emoji.random(cat)
    local pool = cat and emoji.category(cat) or emoji.list
    if not pool or #pool == 0 then return nil end
    return pool[math.random(#pool)]
end

--------------------------------------------------------------------------
-- Иконки игры: оружие, короны, крылья
--------------------------------------------------------------------------
-- Порядок сверен по картинкам атласа. Иконки оружия идут подряд по номерам
-- GTA, только номера 19-21 в игре пустые и в шрифте пропущены. Камеры (43)
-- в шрифте нет вовсе, у обоих видов очков (44, 45) одна картинка.
-- Дальше U+F32B идут собственные стволы Arizona, номеров GTA у них нет.

--- Иконка оружия по номеру GTA: 0 - кулак, 24 - Desert Eagle, 31 - M4.
--- Подходит для своего киллфида: getCurrentCharWeapon, onPlayerDeath.
---@param id integer
---@return table|nil
function emoji.weapon(id)
    id = tonumber(id)
    if not id or id % 1 ~= 0 then return nil end
    local cp
    if id >= 0 and id <= 18 then cp = 0xF300 + id
    elseif id >= 22 and id <= 42 then cp = 0xF300 + id - 3
    elseif id == 44 or id == 45 then cp = 0xF329
    elseif id == 46 then cp = 0xF32A end
    return cp and emoji.byCp[cp] or nil
end

local function numbered(base, n)
    n = tonumber(n)
    if not n or n < 1 or n > 10 or n % 1 ~= 0 then return nil end
    return emoji.byCp[base + n]
end

--- Корона с цифрой от 1 до 10 (U+F245..U+F24E).
---@param n integer от 1 до 10
---@return ChatEmoji|nil
function emoji.crown(n) return numbered(0xF244, n) end

--- Крылья с цифрой от 1 до 10 (U+F250..U+F259).
---@param n integer от 1 до 10
---@return ChatEmoji|nil
function emoji.wings(n) return numbered(0xF24F, n) end

--------------------------------------------------------------------------
-- Буквы и цифры
--------------------------------------------------------------------------
-- В таблице плагина есть два набора «плиточных» глифов: la..lz это латинские
-- буквы (кодовые точки U+1F1E6..U+1F1FF, стандартные региональные индикаторы),
-- na..nj это цифры в приватном диапазоне U+1FC10..U+1FC19.
--
-- Ищем их по кодовой точке, а не по имени, и вот почему: имя 'ng' занято
-- дважды. Сначала идёт значок 🆖 (U+1F196) из категории символов, и именно
-- он выигрывает в emoji.byName. Обращение по имени отдало бы вместо цифры
-- совсем другую картинку.
--
-- Порядок цифр (na это ноль) взят по аналогии с буквами. Если в очередной
-- версии плагина набор сместится, поправьте базу, а не логику:
--     emoji.DIGIT_BASE = 0x1FC10

emoji.LETTER_BASE = 0x1F1E6   -- 'a'
emoji.DIGIT_BASE = 0x1FC10    -- '0'

--- Плиточная буква по латинскому символу. Регистр не важен.
-- @return запись либо nil
---@param ch string одна латинская буква
---@return ChatEmoji|nil
function emoji.letter(ch)
    if type(ch) ~= 'string' or #ch ~= 1 then return nil end
    local c = ch:lower():byte()
    if c < 97 or c > 122 then return nil end
    return emoji.byCp[emoji.LETTER_BASE + (c - 97)]
end

--- Плиточная цифра по одному знаку или числу от 0 до 9.
-- @return запись либо nil
---@param d string|integer цифра от 0 до 9
---@return ChatEmoji|nil
function emoji.digit(d)
    if type(d) == 'string' then d = tonumber(d) end
    if type(d) ~= 'number' or d < 0 or d > 9 or d % 1 ~= 0 then return nil end
    return emoji.byCp[emoji.DIGIT_BASE + d]
end

--- Собирает число из плиточных цифр: emoji.number(120) -> три токена.
---@param n number
---@return string tokens
function emoji.number(n)
    local out = {}
    for ch in tostring(math.floor(tonumber(n) or 0)):gmatch('.') do
        local e = emoji.digit(ch)
        out[#out + 1] = e and e.token or ch
    end
    return table.concat(out)
end

--- Заменяет латинские буквы и цифры плиточными глифами.
--- Кириллица, пробелы и знаки препинания остаются как есть: своих плиток
--- для них в таблице плагина нет.
---     emoji.stylize('ARZ 3') -> ':u1f1e6::u1f1f7::u1f1ff: :u1fc13:'
---@param text string
---@return string
function emoji.stylize(text)
    if type(text) ~= 'string' then return text end
    -- Класс перечислен явно, а не через %w: %w в Lua смотрит на локаль,
    -- и в чужой локали под него могли бы попасть кириллические буквы,
    -- для которых плиток нет.
    return (text:gsub('[0-9A-Za-z]', function(ch)
        local e = emoji.letter(ch) or emoji.digit(ch)
        return e and e.token or nil     -- nil оставляет исходный знак
    end))
end

--------------------------------------------------------------------------
-- Диалоги SA-MP и чат
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

-- Строка чата в SA-MP не длиннее 128 байт вместе с командой.
emoji.CHAT_LIMIT = 128

-- GetModuleHandleA - функция расхожая, и её вполне мог объявить кто-то ещё
-- в этой же Lua-машине. Повторное объявление с другой сигнатурой роняет
-- ffi.cdef, поэтому объявляем осторожно: если не вышло, detect() просто
-- честно вернёт false, а не уронит скрипт на загрузке.
pcall(ffi.cdef, [[
    void* __stdcall GetModuleHandleA(const char* name);
]])

--- Загружен ли в процесс плагин чата, то есть увижу ли смайлы я сам:
--- в своих диалогах, в локальных сообщениях чата.
--- Результат запоминается; emoji.plugin = nil заставит проверить заново.
---@return boolean
function emoji.canRender()
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

--- Прежнее имя canRender(), оставлено для совместимости.
function emoji.detect()
    return emoji.canRender()
end

-- Подстроки в названии сервера (в нижнем регистре), по которым узнаём
-- Arizona. Можно дополнить своими.
emoji.serverPatterns = { 'arizona' }

-- nil - определять по названию сервера, true/false - решить вручную.
emoji.server = nil

--- Увидят ли смайлы другие игроки, то есть сервер ли это Arizona.
--- Это не то же самое, что canRender(): лаунчер Arizona грузит плагин чата
--- и на чужих серверах, и там токен, отправленный в чат, у всех остальных
--- превратится в ':u1f603:'. Если название сервера узнать нельзя (ещё не
--- подключились), решаем как раньше - по наличию плагина.
---@return boolean
function emoji.serverSupports()
    if emoji.server ~= nil then return emoji.server end
    local ok, name = pcall(sampGetCurrentServerName)
    if not ok or type(name) ~= 'string' or name == '' then
        return emoji.canRender()
    end
    name = name:lower()
    for _, p in ipairs(emoji.serverPatterns) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

--- Убирает токены из текста: строка станет читаемой там, где их некому
--- отрисовать. Вместе с токеном съедается один пробел за ним, иначе на
--- месте смайла оставались бы двойные пробелы.
---@param text string
---@return string
function emoji.strip(text)
    if type(text) ~= 'string' then return text end
    local out = text:gsub(emoji.TOKEN .. ' ?', '')
    out = out:gsub(' +\n', '\n'):gsub(' +$', '')
    return out
end

--- Текст под того, кто будет его читать: как есть, если смайлы
--- нарисуются, и без токенов, если нет.
---@param text string
---@param target? 'local'|'server' 'local' (по умолчанию) - увижу только я:
---       диалоги, локальные сообщения; 'server' - уйдёт другим игрокам
---@return string
function emoji.fit(text, target)
    local ok
    if target == 'server' then ok = emoji.serverSupports()
    else ok = emoji.canRender() end
    if ok then return text end
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
---@param text string
---@return string
function emoji.expand(text)
    if type(text) ~= 'string' then return text end
    return (text:gsub(':([%w_%-+]+):', function(name)
        local e = emoji.byName[name]
        return e and e.token or nil     -- nil оставляет исходный кусок
    end))
end

--- Обратная замена: ':u1f3c6:' -> ':trophy:'. Удобно показывать логи
--- и заготовки сообщений человеку, а не хранить в них коды.
--- Неизвестные токены остаются как были.
---@param text string
---@return string
function emoji.decode(text)
    if type(text) ~= 'string' then return text end
    return (text:gsub(emoji.PATTERN, function(hex)
        local e = emoji.byCp[tonumber(hex, 16)]
        return e and (':' .. e.name .. ':') or nil
    end))
end

--- Что строка будет стоить в диалоге: сколько байт занимает, сколько в ней
--- токенов и сколько байт из них съедено разметкой. visible - грубая оценка
--- длины «на глаз», где каждый токен считается за один знак; chars - то же,
--- но с поправкой на UTF-8, чтобы русские буквы не считались по два раза.
---@param text string
---@return {bytes: integer, tokens: integer, tokenBytes: integer, visible: integer, chars: integer}
function emoji.measure(text)
    text = tostring(text)
    local tokens, tokenBytes = 0, 0
    for tk in text:gmatch(emoji.TOKEN) do
        tokens = tokens + 1
        tokenBytes = tokenBytes + #tk
    end
    -- Продолжающие байты UTF-8 (10xxxxxx) не начинают новый символ.
    local plain = text:gsub(emoji.TOKEN, '')
    local utf8chars = select(2, plain:gsub('[^\128-\191]', ''))
    return {
        bytes = #text,
        tokens = tokens,
        tokenBytes = tokenBytes,
        visible = #text - tokenBytes + tokens,
        chars = utf8chars + tokens,
    }
end

--- Режет длинный текст на куски не длиннее limit байт.
--- Токен целиком остаётся в одном куске: разорванный ':u1f6' с одной
--- стороны и '03:' с другой в чате превратились бы в мусор.
--- Разрыв ставится по пробелу, если он есть в пределах куска.
-- @return массив строк
---@param text string
---@param limit? integer по умолчанию CHAT_LIMIT
---@return string[]
function emoji.split(text, limit)
    text = tostring(text or '')
    limit = math.floor(tonumber(limit) or emoji.CHAT_LIMIT)
    -- Ноль или отрицательный лимит зациклил бы разбор, поэтому приводим
    -- его к осмысленному минимуму.
    if limit < 1 then limit = 1 end
    if #text <= limit then return { text } end

    -- Атомы: токены неделимы, обычный текст делится по границам слов.
    local atoms, pos = {}, 1
    while pos <= #text do
        local s, e = text:find(emoji.TOKEN, pos)
        if not s then
            atoms[#atoms + 1] = text:sub(pos)
            break
        end
        if s > pos then atoms[#atoms + 1] = text:sub(pos, s - 1) end
        atoms[#atoms + 1] = { text:sub(s, e) }   -- в таблице значит «не резать»
        pos = e + 1
    end

    local out, cur = {}, ''
    local function flush()
        if cur ~= '' then out[#out + 1] = cur cur = '' end
    end
    for _, atom in ipairs(atoms) do
        if type(atom) == 'table' then
            local tk = atom[1]
            if #cur + #tk > limit then flush() end
            -- Токен длиннее лимита физически не разместить, но и терять
            -- его нельзя: отдаём отдельным куском и идём дальше.
            cur = cur .. tk
        else
            local rest = atom
            while #rest > 0 do
                local room = limit - #cur
                if room <= 0 then flush() room = limit end
                if #rest <= room then
                    cur = cur .. rest
                    rest = ''
                else
                    local chunk = rest:sub(1, room)
                    local cut = chunk:match('^.*() ')      -- позиция последнего пробела
                    if cut and cut > 1 then
                        chunk = rest:sub(1, cut - 1)
                        rest = rest:sub(cut + 1)
                    else
                        rest = rest:sub(#chunk + 1)
                    end
                    cur = cur .. chunk
                    flush()
                end
            end
        end
    end
    flush()
    return out
end

--- sampShowDialog с двумя удобствами: текст и заголовок проходят через
--- fit(), а слишком длинный текст не уходит молча.
--- Порядок аргументов тот же, что у sampShowDialog.
-- @return true либо false, причина
---@param id integer
---@param caption string
---@param text string
---@param button1? string
---@param button2? string
---@param style? integer DIALOG_STYLE_*
---@return boolean ok
---@return string? why
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

-- Пауза между частями длинного сообщения, мс. Сервер режет сообщения,
-- которые идут чаще раза в секунду («Не флудите»), и без паузы до игроков
-- доходила только первая часть.
emoji.CHAT_DELAY = 1100

--- Отправляет сообщение в чат. Токены убираются, если другие игроки их
--- не увидят (fit(text, 'server')), а слишком длинный текст уходит
--- несколькими строками с паузой между ними.
---@param text string текст в cp1251, как для sampSendChat
---@param opts? integer|{limit?: integer, delay?: integer} лимит числом
---       (как в 3.1) либо таблица настроек
---@return integer count сколько сообщений будет отправлено
function emoji.sendChat(text, opts)
    if type(opts) ~= 'table' then opts = { limit = opts } end
    local parts = {}
    for _, part in ipairs(emoji.split(emoji.fit(tostring(text or ''), 'server'),
                                      opts.limit)) do
        if part ~= '' then parts[#parts + 1] = part end
    end
    if #parts == 0 then return 0 end

    sampSendChat(parts[1])
    if #parts > 1 then
        local delay = opts.delay or emoji.CHAT_DELAY
        if type(lua_thread) == 'table' and type(lua_thread.create) == 'function' then
            lua_thread.create(function()
                for i = 2, #parts do
                    wait(delay)
                    sampSendChat(parts[i])
                end
            end)
        else
            -- вне MoonLoader потоков нет: отправляем сразу
            for i = 2, #parts do sampSendChat(parts[i]) end
        end
    end
    return #parts
end

--------------------------------------------------------------------------
-- Unicode: мост с Telegram, VK и Discord
--------------------------------------------------------------------------
-- Скрипты часто пересылают чат в Telegram или обратно. Токен ':u1f603:'
-- там выглядит мусором, а настоящий 😃 из Telegram в игре не нарисуется
-- (ImGui и SA-MP не умеют кодовые точки выше U+FFFF). Эти две функции
-- переводят одно в другое.
--
-- Иконки Arizona (оружие, плашки, логотипы) в Unicode не существуют:
-- для них toUnicode() по умолчанию подставляет ':имя:'.

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
end

emoji.utf8char = utf8char

--- Кодовая точка UTF-8 в позиции i: cp, длина в байтах.
local function utf8at(s, i)
    local c = s:byte(i)
    local n = #s
    if c >= 0xF0 and i + 3 <= n then
        return (c % 8) * 0x40000 + (s:byte(i + 1) % 64) * 0x1000
               + (s:byte(i + 2) % 64) * 0x40 + s:byte(i + 3) % 64, 4
    elseif c >= 0xE0 and i + 2 <= n then
        return (c % 16) * 0x1000 + (s:byte(i + 1) % 64) * 0x40
               + s:byte(i + 2) % 64, 3
    elseif c >= 0xC0 and i + 1 <= n then
        return (c % 32) * 0x40 + s:byte(i + 1) % 64, 2
    end
    return c, 1
end

--- Иконка Arizona, а не символ Unicode: приватные области.
local function isPrivate(cp)
    return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0x1FC00 and cp <= 0x1FFFF)
        or cp >= 0xF0000
end

local VS16 = utf8char(0xFE0F)
local KEYCAP = VS16 .. utf8char(0x20E3)

--- Токены -> настоящие смайлы Unicode (UTF-8).
---     emoji.toUnicode('Продал :u1f3c6:') -> 'Продал 🏆'
---@param text string строка в UTF-8; русский текст из игры сперва через u8()
---@param opts? {unknown?: 'name'|'strip'|'keep'} что делать с иконками
---       Arizona, которых нет в Unicode: ':имя:' (по умолчанию), убрать
---       или оставить токеном
---@return string
function emoji.toUnicode(text, opts)
    if type(text) ~= 'string' then return text end
    local mode = opts and opts.unknown or 'name'
    return (text:gsub(emoji.PATTERN, function(hex)
        local cp = tonumber(hex, 16)
        -- плиточные цифры Arizona -> 0️⃣..9️⃣
        if cp >= emoji.DIGIT_BASE and cp <= emoji.DIGIT_BASE + 9 then
            return tostring(cp - emoji.DIGIT_BASE) .. KEYCAP
        end
        -- Плиточные буквы - это региональные индикаторы. Две подряд
        -- мессенджер склеит во флаг (A и R дадут флаг Аргентины), поэтому
        -- отдаём обычную заглавную букву.
        if cp >= 0x1F1E6 and cp <= 0x1F1FF then
            return string.char(65 + cp - 0x1F1E6)
        end
        if not isPrivate(cp) then
            local s = utf8char(cp)
            -- символы из BMP без U+FE0F мессенджеры часто рисуют текстом
            if cp < 0x1F000 or (cp >= 0x1F170 and cp <= 0x1F251) then
                s = s .. VS16
            end
            return s
        end
        if mode == 'keep' then return nil end
        if mode == 'strip' then return '' end
        local e = emoji.byCp[cp]
        return e and (':' .. e.name .. ':') or nil
    end))
end

--- Настоящие смайлы Unicode -> токены. Для сообщений из Telegram, VK и
--- Discord, которые надо показать в игре. Остальной текст не трогается,
--- результат остаётся в UTF-8: русский текст для SA-MP переведите в cp1251
--- как обычно (токены - чистый ASCII, им это не повредит).
---     emoji.fromUnicode('gg 🔥') -> 'gg :u1f525:'
---@param text string строка в UTF-8
---@return string
function emoji.fromUnicode(text)
    if type(text) ~= 'string' then return text end
    local out, i, n = {}, 1, #text
    while i <= n do
        local cp, len = utf8at(text, i)
        local done = false
        -- keycap: цифра, (U+FE0F), U+20E3 -> плиточная цифра Arizona
        if cp >= 48 and cp <= 57 then
            local j = i + 1
            local nxt, l2 = 0, 0
            if j <= n then nxt, l2 = utf8at(text, j) end
            if nxt == 0xFE0F and j + l2 <= n then
                j = j + l2
                nxt, l2 = utf8at(text, j)
            end
            local d = nxt == 0x20E3 and emoji.digit(cp - 48) or nil
            if d then
                out[#out + 1] = d.token
                i = j + l2
                done = true
            end
        end
        if not done then
            if cp == 0xFE0F or cp == 0xFE0E or cp == 0x200D
               or (cp >= 0x1F3FB and cp <= 0x1F3FF) then
                -- селекторы, ZWJ и оттенки кожи чат Arizona не рисует
            elseif cp > 0x7F and emoji.byCp[cp] then
                out[#out + 1] = emoji.byCp[cp].token
            else
                out[#out + 1] = text:sub(i, i + len - 1)
            end
            i = i + len
        end
    end
    return table.concat(out)
end

--------------------------------------------------------------------------
-- Отрисовка
--------------------------------------------------------------------------

local WHITE = 0xFFFFFFFF
local BTN_PAD = 2

local function styleColor(col)
    return imgui.ColorConvertFloat4ToU32(imgui.GetStyle().Colors[col])
end

--- Цвет из тега {RRGGBB} в формат ImGui.
--- ImGui хранит цвет как ABGR (IM_COL32 собирает R | G<<8 | B<<16 | A<<24),
--- поэтому красная и синяя составляющие меняются местами.
local function hexToU32(hex)
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return 0xFF000000 + b * 0x10000 + g * 0x100 + r
end

emoji.hexToU32 = hexToU32

--- Рисует смайл как картинку.
-- @return true, если смайл найден и нарисован
---@param key string|integer|ChatEmoji
---@param size? number высота в пикселях
---@return boolean drawn
function emoji.image(key, size)
    if not imgui then return false end
    local e = emoji.get(key)
    size = size or imgui.GetFontSize()
    if not e or not emoji.loaded then
        -- место держим по фактической ширине записи, если она известна:
        -- иначе широкий баннер при незагруженной текстуре дёргал бы вёрстку
        local w = e and size * e.cells or size
        imgui.Dummy(imgui.ImVec2(w, size))
        return false
    end
    imgui.Image(texFor(size), imgui.ImVec2(size * e.cells, size), e.uv0, e.uv1)
    return true
end

--- Ширина смайла при заданной высоте. У широких серверных баннеров она
--- больше высоты в e.cells раз.
---@param key string|integer|ChatEmoji
---@param size? number
---@return number
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
---@param key string|integer|ChatEmoji
---@param size? number
---@param id? string
---@return boolean pressed
function emoji.button(key, size, id)
    if not imgui then return false end
    local e = emoji.get(key)
    size = size or imgui.GetFontSize()
    if not e or not emoji.loaded then
        local w = e and size * e.cells or size
        imgui.Dummy(imgui.ImVec2(w, size))
        return false
    end

    local w = size * e.cells + BTN_PAD * 2
    local h = size + BTN_PAD * 2
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
    dl:AddImage(texFor(size),
                imgui.ImVec2(p.x + BTN_PAD, p.y + BTN_PAD),
                imgui.ImVec2(p.x + w - BTN_PAD, p.y + h - BTN_PAD),
                e.uv0, e.uv1, WHITE)
    return pressed
end

--- Разбирает строку на куски текста и смайлы.
-- @return массив { { text = '...' } | { emoji = <запись> } }
---@param str string
---@return {text?: string, emoji?: ChatEmoji}[]
function emoji.parse(str)
    -- pos  - откуда искать следующий токен
    -- from - откуда начинается ещё не выданный кусок текста; двигается
    --        только когда токен реально распознан, иначе текст перед
    --        нераспознанным токеном потерялся бы
    local out, pos, from = {}, 1, 1
    str = tostring(str or '')
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

--------------------------------------------------------------------------
-- Раскладка строки со смайлами
--------------------------------------------------------------------------
-- Раньше text() рисовал каждый кусок отдельным виджетом и склеивал их
-- через SameLine(0, 0). Это работало ровно до первого перевода строки:
-- SameLine возвращал курсор на предыдущую строку, и вёрстка съезжала.
-- Плюс так нельзя было ни перенести длинную строку по ширине, ни узнать
-- её размер заранее.
--
-- Теперь строка сначала раскладывается в строки и элементы, а потом
-- рисуется одним проходом по draw list. Место в вёрстке занимает один
-- Dummy на весь блок.

local function textWidth(s)
    if s == '' then return 0 end
    return imgui.CalcTextSize(s).x
end

--- Ищет ближайшую «особую» позицию: токен смайла, цветовой тег или перевод
--- строки. Возвращает s, e, kind, value либо nil, если до конца строки
--- ничего такого нет.
local function nextSpecial(str, from, useColor)
    local best
    local s1, e1, hex1 = str:find(emoji.PATTERN, from)
    if s1 then best = { s = s1, e = e1, kind = 'emoji', value = hex1 } end
    if useColor then
        local s2, e2, hex2 = str:find(emoji.COLOR_PATTERN, from)
        if s2 and (not best or s2 < best.s) then
            best = { s = s2, e = e2, kind = 'color', value = hex2 }
        end
    end
    local s3 = str:find('\n', from, true)
    if s3 and (not best or s3 < best.s) then
        best = { s = s3, e = s3, kind = 'br' }
    end
    return best
end

--- Раскладывает строку. wrapWidth = nil означает «не переносить».
-- @return массив строк { items = { ... }, w = ширина, h = высота }
local function buildLayout(str, size, wrapWidth, useColor)
    local textH = imgui.GetTextLineHeight()
    local lineH = math.max(size, textH)

    local lines = {}
    local cur = { items = {}, w = 0, h = lineH }
    lines[1] = cur
    local color = nil

    local function newline()
        cur = { items = {}, w = 0, h = lineH }
        lines[#lines + 1] = cur
    end

    local function put(item)
        if wrapWidth and wrapWidth > 0 and cur.w > 0
           and cur.w + item.w > wrapWidth then
            newline()
        end
        item.x = cur.w
        cur.items[#cur.items + 1] = item
        cur.w = cur.w + item.w
    end

    local function putText(s)
        if s == '' then return end
        if not (wrapWidth and wrapWidth > 0) then
            put({ kind = 'text', s = s, w = textWidth(s), color = color })
            return
        end
        -- При переносе текст делится на слова. Хвостовые пробелы остаются
        -- при слове, поэтому перенос съедает их, как и положено.
        local pos = 1
        while pos <= #s do
            local a, b = s:find('%s*%S+%s*', pos)
            if not a then
                put({ kind = 'text', s = s:sub(pos), w = textWidth(s:sub(pos)),
                      color = color })
                break
            end
            local word = s:sub(a, b)
            put({ kind = 'text', s = word, w = textWidth(word), color = color })
            pos = b + 1
        end
    end

    local pos = 1
    while pos <= #str do
        local sp = nextSpecial(str, pos, useColor)
        if not sp then
            putText(str:sub(pos))
            break
        end
        if sp.s > pos then putText(str:sub(pos, sp.s - 1)) end
        if sp.kind == 'br' then
            newline()
        elseif sp.kind == 'color' then
            color = hexToU32(sp.value)
        else
            local rec = emoji.byCp[tonumber(sp.value, 16)]
            if rec and emoji.loaded then
                put({ kind = 'emoji', e = rec, w = size * rec.cells })
            else
                -- Нечего нарисовать: показываем токен текстом, чтобы строка
                -- не теряла кусок молча.
                local raw = str:sub(sp.s, sp.e)
                put({ kind = 'text', s = raw, w = textWidth(raw), color = color })
            end
        end
        pos = sp.e + 1
    end

    return lines, textH
end

-- Кеш раскладок. Раскладка зовёт CalcTextSize на каждое слово, и оверлей
-- чата на полсотни строк делал это каждый кадр. Строки на экране меняются
-- редко, поэтому готовую раскладку запоминаем. В ключе всё, от чего она
-- зависит: текст, размер смайлов, ширина переноса, цветовые теги, шрифт
-- и то, загружена ли текстура (без неё токены показываются текстом).
-- Кеш просто сбрасывается целиком, когда записей становится слишком много.
emoji.LAYOUT_CACHE = 512
local layoutCache, layoutCount = {}, 0

local function layoutString(str, size, wrapWidth, useColor)
    str = tostring(str or '')
    local getFont = imguiFn('GetFont')
    local font = getFont and getFont() or ''
    local key = table.concat({
        str, size, wrapWidth and math.floor(wrapWidth) or '',
        useColor and 1 or 0, tostring(font), imgui.GetFontSize(),
        emoji.loaded and 1 or 0,
    }, '\0')
    local hit = layoutCache[key]
    if hit then return hit[1], hit[2] end
    local lines, textH = buildLayout(str, size, wrapWidth, useColor)
    if layoutCount >= emoji.LAYOUT_CACHE then
        layoutCache, layoutCount = {}, 0
    end
    layoutCache[key] = { lines, textH }
    layoutCount = layoutCount + 1
    return lines, textH
end

--- Сбрасывает кеш раскладок (например, после смены шрифта).
function emoji.clearLayoutCache()
    layoutCache, layoutCount = {}, 0
end

--- Размер строки со смайлами, без отрисовки.
--- Настройки те же, что у text(), и передавать их надо те же: строка
--- с тегом {FF0000} при color = false шире, чем при color = true, потому
--- что тег в первом случае виден.
-- @param str   строка в UTF-8
-- @param size  высота смайла (по умолчанию высота шрифта)
-- @param opts  ширина переноса числом либо таблица настроек text()
-- @return ширина, высота
---@param str string
---@param size? number
---@param opts? number|ChatEmojiTextOpts
---@return number w
---@return number h
function emoji.calcTextSize(str, size, opts)
    if not imgui then return 0, 0 end
    if type(opts) ~= 'table' then opts = { wrap = opts } end
    size = size or imgui.GetFontSize()
    local wrap = opts.wrap
    if wrap == true then wrap = imgui.GetContentRegionAvail().x end
    local lines = layoutString(str, size, wrap, opts.color)
    local w, h = 0, 0
    for _, ln in ipairs(lines) do
        if ln.w > w then w = ln.w end
        h = h + ln.h
    end
    return w, h
end

--- Рисует строку, подставляя смайлы вместо токенов :uXXXX:.
--- Строка должна быть в UTF-8. Литералы из файла, сохранённого в UTF-8,
--- подходят как есть; строку из игры (cp1251) сперва пропустите через u8().
---
--- Умножает альфу цвета. Нужна для затухания далёких меток.
--- Считаем арифметикой, а не битовыми операциями: в LuaJIT они живут
--- в отдельной библиотеке bit, и лишняя зависимость тут ни к чему.
local function withAlpha(col, a)
    if not a or a >= 1 then return col end
    if a <= 0 then return col % 0x1000000 end
    local rgb = col % 0x1000000
    local alpha = math.floor((math.floor(col / 0x1000000) % 256) * a)
    return rgb + alpha * 0x1000000
end

--- Рисует готовую раскладку в произвольный draw list от точки (x, y).
--- Общая часть для окна, экранного слоя, кнопок и меток в мире.
-- @param boxWidth ширина, по которой равнять строки (по умолчанию самая
--                 длинная строка)
-- @return ширина, высота
local function renderLines(dl, x, y, lines, size, textH, base, align, alpha,
                           boxWidth)
    local total = 0
    for _, ln in ipairs(lines) do
        if ln.w > total then total = ln.w end
    end
    local box = (boxWidth and boxWidth > 0) and boxWidth or total

    local dy = 0
    for _, ln in ipairs(lines) do
        local shift = 0
        if align == 'center' then shift = (box - ln.w) / 2
        elseif align == 'right' then shift = box - ln.w end

        for _, it in ipairs(ln.items) do
            local px = x + shift + it.x
            local py = y + dy
            if it.kind == 'emoji' then
                local off = (ln.h - size) / 2
                dl:AddImage(texFor(size),
                            imgui.ImVec2(px, py + off),
                            imgui.ImVec2(px + it.w, py + off + size),
                            it.e.uv0, it.e.uv1, withAlpha(WHITE, alpha))
            else
                local off = (ln.h - textH) / 2
                dl:AddText(imgui.ImVec2(px, py + off),
                           withAlpha(it.color or base, alpha), it.s)
            end
        end
        dy = dy + ln.h
    end
    return box, dy
end

-- @param str  текст с токенами
-- @param size высота смайла (по умолчанию высота шрифта)
-- @param opts { wrap = ширина переноса или true для доступной ширины,
--              color = учитывать теги {RRGGBB},
--              tint = цвет текста по умолчанию,
--              align = 'left' | 'center' | 'right',
--              alpha = прозрачность от 0 до 1 }
-- @return ширина, высота нарисованного блока
---@param str string
---@param size? number
---@param opts? ChatEmojiTextOpts
---@return number w
---@return number h
function emoji.text(str, size, opts)
    if not imgui then return 0, 0 end
    opts = opts or {}
    size = size or imgui.GetFontSize()

    local wrap = opts.wrap
    if wrap == true then wrap = imgui.GetContentRegionAvail().x end

    local lines, textH = layoutString(str, size, wrap, opts.color)
    local base = opts.tint or styleColor(imgui.Col.Text)
    local origin = imgui.GetCursorScreenPos()

    local w, h = renderLines(imgui.GetWindowDrawList(), origin.x, origin.y,
                             lines, size, textH, base, opts.align, opts.alpha)

    imgui.Dummy(imgui.ImVec2(w, h))
    return w, h
end

--- То же, что text(), но с переносом по доступной ширине.
---@param str string
---@param size? number
---@param wrap? number
---@return number w
---@return number h
function emoji.textWrapped(str, size, wrap)
    return emoji.text(str, size, { wrap = wrap or true, color = false })
end

--- Строка с цветовыми тегами сервера и переносом: то, что нужно для
--- предпросмотра чата и описаний предметов.
---@param str string
---@param size? number
---@param wrap? number
---@return number w
---@return number h
function emoji.richText(str, size, wrap)
    return emoji.text(str, size, { wrap = wrap or true, color = true })
end

--------------------------------------------------------------------------
-- Смайлы поверх игры и в мире
--------------------------------------------------------------------------
-- text() рисует там, где стоит курсор ImGui, то есть внутри окна. Но
-- смайл часто нужен там, где окна нет: метка над машиной, счётчик в углу
-- экрана, подпись над головой игрока. Для этого ImGui держит два общих
-- слоя, доступных из любого места кадра:
--   background - поверх игры, но под окнами (обычный HUD);
--   foreground - поверх всего, включая окна.
-- Окно для них создавать не нужно, достаточно быть внутри imgui.OnFrame.

local function screenDrawList(layer)
    -- В старых сборках mimgui общих списков может не быть вовсе. Тогда
    -- честнее ничего не нарисовать, чем уронить скрипт на каждом кадре.
    local getter = imguiFn(layer == 'foreground' and 'GetForegroundDrawList'
                                                  or 'GetBackgroundDrawList')
                   or imguiFn('GetBackgroundDrawList')
                   or imguiFn('GetForegroundDrawList')
    if not getter then return nil end
    local ok, dl = pcall(getter)
    if not ok or dl == nil then return nil end
    return dl
end

--- Рисует строку со смайлами в любой точке экрана, без окна.
-- @param x, y точка привязки в пикселях
-- @param opts { size, wrap, color, tint, align, alpha, layer,
--               anchor = 'topleft' | 'top' | 'center' | 'bottom' }
-- @return ширина, высота
---@param x number
---@param y number
---@param str string
---@param opts? ChatEmojiTextOpts|{size?: number, layer?: 'background'|'foreground', anchor?: 'topleft'|'top'|'center'|'bottom'}
---@return number w
---@return number h
function emoji.drawText(x, y, str, opts)
    if not imgui then return 0, 0 end
    opts = opts or {}
    local dl = screenDrawList(opts.layer)
    if not dl then return 0, 0 end

    local size = opts.size or imgui.GetFontSize()
    local lines, textH = layoutString(str, size, opts.wrap, opts.color)
    -- Поверх игры цвет темы неуместен: там нет фона, под который её
    -- подбирали. По умолчанию рисуем белым, как весь остальной HUD.
    local base = opts.tint or WHITE

    -- Размеры нужны до отрисовки, иначе привязку к центру не посчитать.
    local w, h = 0, 0
    for _, ln in ipairs(lines) do
        if ln.w > w then w = ln.w end
        h = h + ln.h
    end

    local anchor = opts.anchor
    if anchor == 'top' or anchor == 'center' or anchor == 'bottom' then
        x = x - w / 2
    end
    if anchor == 'center' then y = y - h / 2
    elseif anchor == 'bottom' then y = y - h end

    return renderLines(dl, x, y, lines, size, textH, base,
                       opts.align, opts.alpha)
end

--- Одна иконка в любой точке экрана.
-- @return ширина, высота
---@param x number
---@param y number
---@param key string|integer|ChatEmoji
---@param size? number
---@param opts? table
---@return number w
---@return number h
function emoji.drawImage(x, y, key, size, opts)
    if not imgui or not emoji.loaded then return 0, 0 end
    opts = opts or {}
    local e = emoji.get(key)
    if not e then return 0, 0 end
    local dl = screenDrawList(opts.layer)
    if not dl then return 0, 0 end

    size = size or imgui.GetFontSize()
    local w = size * e.cells
    local anchor = opts.anchor
    if anchor == 'top' or anchor == 'center' or anchor == 'bottom' then
        x = x - w / 2
    end
    if anchor == 'center' then y = y - size / 2
    elseif anchor == 'bottom' then y = y - size end

    dl:AddImage(texFor(size), imgui.ImVec2(x, y),
                imgui.ImVec2(x + w, y + size), e.uv0, e.uv1,
                withAlpha(opts.tint or WHITE, opts.alpha))
    return w, size
end

--- Метка со смайлами над точкой в игровом мире.
--- Размер считается от расстояния до камеры, далёкие метки затухают
--- и пропадают совсем. Точки за спиной камеры отсекаются: без этой
--- проверки они рисуются зеркально, как будто висят спереди.
-- @param opts { size = высота на опорном расстоянии,
--               refDistance = опорное расстояние (по умолчанию 10 м),
--               minSize, maxSize = пределы размера,
--               maxDistance = дальше метка не рисуется (по умолчанию 60 м),
--               fadeFrom = с какого расстояния начинать затухание,
--               radius = радиус проверки видимости,
--               anchor = по умолчанию 'bottom', то есть текст над точкой,
--               плюс всё, что понимает drawText }
-- @return true, если метка нарисована
---@param x number
---@param y number
---@param z number
---@param str string
---@param opts? table
---@return boolean drawn
function emoji.draw3D(x, y, z, str, opts)
    if not imgui then return false end
    opts = opts or {}

    local radius = opts.radius or 0.6
    local okVis, visible = pcall(isPointOnScreen, x, y, z, radius)
    if not okVis or not visible then return false end

    local maxDist = opts.maxDistance or 60
    local dist = 0
    local okCam, cx, cy, cz = pcall(getActiveCameraCoordinates)
    if okCam then
        local okDist, d = pcall(getDistanceBetweenCoords3d, x, y, z, cx, cy, cz)
        if okDist then dist = d end
    end
    if dist > maxDist then return false end

    local base = opts.size or 24
    local ref = opts.refDistance or 10
    -- Ограничиваем расстояние, а не пропускаем масштабирование: иначе
    -- вплотную к метке размер скачком возвращался бы к базовому.
    local size = base * (ref / math.max(dist, 0.5))
    size = math.max(opts.minSize or 8, math.min(size, opts.maxSize or 64))

    local alpha = opts.alpha or 1
    local fade = opts.fadeFrom or (maxDist * 0.75)
    if dist > fade and maxDist > fade then
        alpha = alpha * (1 - (dist - fade) / (maxDist - fade))
    end
    if alpha <= 0.01 then return false end

    local sx, sy = convert3DCoordsToScreen(x, y, z)

    emoji.drawText(sx, sy + (opts.offset or 0), str, {
        size = size,
        color = opts.color,
        tint = opts.tint,
        wrap = opts.wrap,
        align = opts.align or 'center',
        anchor = opts.anchor or 'bottom',
        alpha = alpha,
        layer = opts.layer,
    })
    return true
end

--------------------------------------------------------------------------
-- Смайлы в игровом чате
--------------------------------------------------------------------------

--- Дописывает токен в строку ввода игрового чата, если она открыта.
--- Так панель выбора начинает работать с настоящим чатом, а не только
--- со своими окнами: открыл чат, нажал хоткей, выбрал смайл.
--- Позицию курсора внутри поля SA-MP наружу не отдаёт, поэтому токен
--- всегда уходит в конец.
-- @return true либо false, причина
---@param key string|integer|ChatEmoji
---@param limit? integer
---@return boolean ok
---@return string? why
function emoji.insertToChatInput(key, limit)
    local tok = emoji.encode(key)
    if tok == '' then return false, 'unknown emoji' end
    local okActive, active = pcall(sampIsChatInputActive)
    if not okActive or not active then return false, 'chat input is closed' end

    local okGet, cur = pcall(sampGetChatInputText)
    if not okGet then return false, 'cannot read the chat input' end
    cur = cur or ''

    limit = limit or emoji.CHAT_LIMIT
    if #cur + #tok > limit then
        return false, ('%d bytes over the limit'):format(#cur + #tok - limit)
    end

    pcall(sampSetChatInputText, cur .. tok)
    return true
end

--- Локальное сообщение в чат с проверкой на плагин.
--- Ровно sampAddChatMessage, только текст проходит через fit(), поэтому
--- на сервере без плагина в чате не окажется ":u1f603:".
---@param text string
---@param color? integer
function emoji.addChatMessage(text, color)
    pcall(sampAddChatMessage, emoji.fit(tostring(text or '')), color or -1)
end

--------------------------------------------------------------------------
-- Виджеты с эмодзи в подписи
--------------------------------------------------------------------------
-- Подпись обычной кнопки ImGui это строка, и картинку в неё не вставить.
-- Поэтому кнопка и строка списка собираются вручную: невидимая кнопка
-- задаёт размер и ловит клик, а поверх рисуется наша раскладка.

local function measureLines(lines)
    local w, h = 0, 0
    for _, ln in ipairs(lines) do
        if ln.w > w then w = ln.w end
        h = h + ln.h
    end
    return w, h
end

--- Кнопка, в подписи которой можно ставить смайлы и цветовые теги.
-- @param opts { size, id, width, color, tint, align, wrap, padX, padY }
-- @return true, если нажали
---@param str string
---@param opts? table
---@return boolean pressed
function emoji.textButton(str, opts)
    if not imgui then return false end
    opts = opts or {}
    local style = imgui.GetStyle()
    local size = opts.size or imgui.GetFontSize()
    local padX = opts.padX or style.FramePadding.x
    local padY = opts.padY or style.FramePadding.y

    local lines, textH = layoutString(str, size, opts.wrap, opts.color)
    local tw, th = measureLines(lines)
    local w = (opts.width and opts.width > 0) and opts.width or (tw + padX * 2)
    local h = th + padY * 2

    local p = imgui.GetCursorScreenPos()
    -- Идентификатор берём из opts.id, а не из подписи: две кнопки с одним
    -- смайлом иначе слиплись бы в один элемент.
    local pressed = imgui.InvisibleButton(tostring(opts.id or str),
                                          imgui.ImVec2(w, h))

    local col = imgui.Col.Button
    if imgui.IsItemHovered() then
        col = imgui.IsMouseDown(0) and imgui.Col.ButtonActive
                                    or imgui.Col.ButtonHovered
    end
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), styleColor(col),
                     opts.rounding or style.FrameRounding)
    renderLines(dl, p.x + padX, p.y + padY, lines, size, textH,
                opts.tint or styleColor(imgui.Col.Text),
                opts.align, opts.alpha, w - padX * 2)
    return pressed
end

--- Строка списка со смайлами: аналог imgui.Selectable.
-- @return true, если нажали
---@param str string
---@param selected? boolean
---@param opts? table
---@return boolean pressed
function emoji.selectable(str, selected, opts)
    if not imgui then return false end
    opts = opts or {}
    local style = imgui.GetStyle()
    local size = opts.size or imgui.GetFontSize()
    local padX = opts.padX or style.FramePadding.x
    local padY = opts.padY or (style.FramePadding.y / 2)

    local lines, textH = layoutString(str, size, opts.wrap, opts.color)
    local tw, th = measureLines(lines)
    local w = opts.width or imgui.GetContentRegionAvail().x
    if w <= 0 then w = tw + padX * 2 end
    local h = th + padY * 2

    local p = imgui.GetCursorScreenPos()
    local pressed = imgui.InvisibleButton(tostring(opts.id or str),
                                          imgui.ImVec2(w, h))

    local dl = imgui.GetWindowDrawList()
    local col = nil
    if imgui.IsItemHovered() then
        col = imgui.IsMouseDown(0) and imgui.Col.HeaderActive
                                    or imgui.Col.HeaderHovered
    elseif selected then
        col = imgui.Col.Header
    end
    if col then
        dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), styleColor(col),
                         opts.rounding or 0)
    end
    renderLines(dl, p.x + padX, p.y + padY, lines, size, textH,
                opts.tint or styleColor(imgui.Col.Text),
                opts.align, opts.alpha, w - padX * 2)
    return pressed
end

--- Всплывающая подсказка со смайлами. Вызывать после виджета,
--- обычно внутри проверки imgui.IsItemHovered().
---@param str string
---@param opts? ChatEmojiTextOpts
function emoji.tooltipText(str, opts)
    if not imgui then return end
    if not imguiFn('BeginTooltip') or not imguiFn('EndTooltip') then
        -- Сборка без BeginTooltip всё равно должна показать хоть что-то.
        imgui.SetTooltip(emoji.decode(tostring(str or '')))
        return
    end
    imgui.BeginTooltip()
    emoji.text(str, opts and opts.size, opts)
    imgui.EndTooltip()
end

--------------------------------------------------------------------------
-- Смайлы прямо в шрифте ImGui
--------------------------------------------------------------------------
-- Всё остальное в библиотеке рисует смайлы рядом с текстом: картинкой
-- поверх draw list. Поэтому их нельзя было поставить в обычные
-- imgui.Button, Combo, TreeNode, вкладки, меню - и в поле ввода, пока
-- человек печатает.
--
-- ImGui 1.74 из mimgui умеет «свои глифы»: прямоугольник в атласе шрифта,
-- привязанный к кодовой точке. Смайлы растеризуются туда из нашего атласа,
-- и для ImGui они становятся обычными буквами в области Private Use
-- (U+E700 и дальше: ImWchar у mimgui 16-битный, а этот участок свободен
-- от FontAwesome 4, 5 и 6). Дальше строка с такими буквами работает везде.
--
--     imgui.OnInitialize(function()
--         emoji.fontGlyphs()                   -- в шрифт по умолчанию
--     end)
--     imgui.Button(emoji.toGlyphs('Купить :u1f3c6:'))
--     imgui.InputText('##msg', buf, 128)   -- вставленные смайлы видны
--     sampSendChat(emoji.fromGlyphs(u8:decode(ffi.string(buf))))
--
-- Ограничения:
--   * вызывать из imgui.OnInitialize: пиксели кладутся в атлас шрифта до
--     того, как mimgui создаст из него текстуру;
--   * смайл окрашивается цветом текста: при белом тексте цвета родные,
--     в TextDisabled он тусклый. Так устроен рендер шрифтов ImGui 1.74;
--   * атлас шрифта у каждого скрипта свой, все 1598 смайлов при 14 px
--     добавляют к нему около 2 МБ. opts.filter позволяет взять только
--     нужные.

emoji.GLYPH_BASE = 0xE700
-- Порядок байтов в атласе шрифта. Бэкенд DX9 в mimgui копирует пиксели в
-- текстуру A8R8G8B8 без перестановки, поэтому пишем сразу в BGRA. Если
-- в какой-то сборке красный и синий поменяются местами, поставьте true.
emoji.GLYPH_SWAP_RB = false

emoji.glyphs = {}        -- кодовая точка смайла -> кодовая точка глифа
emoji.glyphCp = {}       -- обратно: глиф -> смайл

local glyphJobs = {}
local glyphFinisher = false

--- Размер шрифта по его конфигурации (FontSize заполняется только после
--- сборки атласа, а нам он нужен раньше).
local function fontPixelSize(atlas, font)
    local cfgs = atlas.ConfigData
    for i = 0, cfgs.Size - 1 do
        local cfg = cfgs.Data[i]
        if cfg.DstFont == font then return cfg.SizePixels end
    end
    return nil
end

--- Уменьшает блок атласа в прямоугольник w x h с усреднением и пишет
--- в атлас шрифта. Усреднение с учётом прозрачности: иначе края смайлов
--- темнели бы от чёрных прозрачных пикселей вокруг.
local function blitGlyph(src, pitch, sx0, sy0, sw, sh, dst, dstW, dx0, dy0, w, h)
    local rx, ry = sw / w, sh / h
    local swap = emoji.GLYPH_SWAP_RB
    for y = 0, h - 1 do
        local ya = math.floor(y * ry + 0.5)
        local yb = math.max(ya + 1, math.floor((y + 1) * ry + 0.5))
        for x = 0, w - 1 do
            local xa = math.floor(x * rx + 0.5)
            local xb = math.max(xa + 1, math.floor((x + 1) * rx + 0.5))
            local sa, sr, sg, sb, n = 0, 0, 0, 0, 0
            for yy = ya, yb - 1 do
                local row = (sy0 + yy) * pitch + sx0 * 4
                for xx = xa, xb - 1 do
                    local p = row + xx * 4
                    local a = src[p + 3]
                    sb = sb + src[p] * a
                    sg = sg + src[p + 1] * a
                    sr = sr + src[p + 2] * a
                    sa = sa + a
                    n = n + 1
                end
            end
            local o = ((dy0 + y) * dstW + dx0 + x) * 4
            if sa > 0 then
                local b, g, r = sb / sa, sg / sa, sr / sa
                if swap then r, b = b, r end
                dst[o] = b
                dst[o + 1] = g
                dst[o + 2] = r
                dst[o + 3] = sa / n
            end
        end
    end
end

--- Кладёт пиксели смайлов в собранный атлас шрифта. Запускается из
--- imgui.OnInitialize после всех остальных обработчиков, то есть когда
--- скрипт уже добавил все свои шрифты.
local function finishGlyphs()
    glyphFinisher = false
    local jobs = glyphJobs
    glyphJobs = {}
    if #jobs == 0 then return end

    local fonts = imgui.GetIO().Fonts
    local pixels = ffi.new('unsigned char*[1]')
    local tw, th = ffi.new('int[1]'), ffi.new('int[1]')
    fonts:GetTexDataAsRGBA32(pixels, tw, th, nil)
    local dst = pixels[0]
    if dst == nil then
        print('[chat_emoji] fontGlyphs: font atlas has no pixels')
        return
    end

    local a = emoji.atlas
    local f = io.open((emoji.dir or defaultDir()) .. a.file, 'rb')
    if not f then
        print('[chat_emoji] fontGlyphs: atlas image not found')
        return
    end
    local png = f:read('*a')
    f:close()
    local tex, err = createTexture(png, 'argb', D3DPOOL_SCRATCH)
    if not tex then
        print('[chat_emoji] fontGlyphs: ' .. tostring(err))
        return
    end
    local src, pitch, done = lockTexture(tex)
    if not src then
        comCall(tex, 2)
        print('[chat_emoji] fontGlyphs: cannot lock atlas texture')
        return
    end

    local ok, perr = pcall(function()
        for _, job in ipairs(jobs) do
            local r = fonts:GetCustomRectByIndex(job.rect)
            local e = job.e
            blitGlyph(src, pitch,
                      (e.slot % a.cols) * a.cell, math.floor(e.slot / a.cols) * a.cell,
                      e.cells * a.cell, a.cell,
                      dst, tw[0], r.X, r.Y, job.w, job.h)
        end
    end)
    done()
    if not ok then print('[chat_emoji] fontGlyphs: ' .. tostring(perr)) end
end

--- Вшивает смайлы в шрифт ImGui. Вызывать из imgui.OnInitialize, после
--- emoji.load() или emoji.loadTable().
---@param font? ffi.cdata* шрифт (ImFont*); по умолчанию шрифт mimgui
---@param opts? {size?: number, scale?: number, filter?: fun(e: table): boolean}
---       size - высота смайла в пикселях (по умолчанию размер шрифта),
---       scale - множитель к ней, filter - какие смайлы брать
---@return boolean ok
---@return string|integer countOrErr сколько смайлов добавлено либо ошибка
function emoji.fontGlyphs(font, opts)
    if not imgui then return false, 'mimgui is not available' end
    opts = opts or {}
    if not emoji.ready then
        local ok, err = emoji.loadTable(opts.dir)
        if not ok then return false, err end
    end

    local fonts = imgui.GetIO().Fonts
    if fonts:IsBuilt() then
        return false, 'font atlas is already built: call fontGlyphs() from imgui.OnInitialize'
    end
    if fonts.Fonts.Size == 0 then return false, 'no fonts in the atlas' end
    font = font or fonts.Fonts.Data[0]

    local fontSize = fontPixelSize(fonts, font) or imgui.GetFontSize()
    local h = math.max(4, math.floor((opts.size or fontSize) * (opts.scale or 1) + 0.5))
    local offY = (fontSize - h) / 2

    local count = 0
    for _, e in ipairs(emoji.list) do
        local pua = emoji.GLYPH_BASE + e.index - 1
        if pua > 0xF8FF then break end
        if not opts.filter or opts.filter(e) then
            local w = math.max(1, math.floor(h * e.cells + 0.5))
            local rect = fonts:AddCustomRectFontGlyph(font, pua, w, h, w + 1,
                                                      imgui.ImVec2(0, offY))
            glyphJobs[#glyphJobs + 1] = { rect = rect, e = e, w = w, h = h }
            emoji.glyphs[e.cp] = pua
            emoji.glyphCp[pua] = e.cp
            count = count + 1
        end
    end

    -- ImGui 1.74 выбирает ширину атласа шрифта по площади самих шрифтов,
    -- не считая своих глифов. Сотни смайлов тогда вытягивают атлас в узкую
    -- полосу 512 x 4096. Ширина 1024 держит его близким к квадрату.
    if count > 200 and fonts.TexDesiredWidth == 0 then
        fonts.TexDesiredWidth = 1024
    end

    -- Обработчик, добавленный изнутри OnInitialize, mimgui вызовет после
    -- всех уже зарегистрированных: к тому моменту скрипт добавит свои
    -- шрифты, и атлас соберётся один раз и окончательно.
    if not glyphFinisher and count > 0 then
        glyphFinisher = true
        imgui.OnInitialize(finishGlyphs)
    end
    return true, count
end

--- Буква-глиф смайла (UTF-8) либо пустая строка, если он не вшит.
---@param key string|integer|table
---@return string
function emoji.glyph(key)
    local e = emoji.get(key)
    local pua = e and emoji.glyphs[e.cp]
    return pua and utf8char(pua) or ''
end

--- Токены -> глифы шрифта. Токены смайлов, которых нет в шрифте,
--- остаются как были.
---@param str string
---@return string
function emoji.toGlyphs(str)
    if type(str) ~= 'string' then return str end
    return (str:gsub(emoji.PATTERN, function(hex)
        local pua = emoji.glyphs[tonumber(hex, 16)]
        return pua and utf8char(pua) or nil
    end))
end

--- Глифы шрифта -> токены: перед отправкой в чат или диалог.
---@param str string
---@return string
function emoji.fromGlyphs(str)
    if type(str) ~= 'string' then return str end
    return (str:gsub('[\238\239][\128-\191][\128-\191]', function(ch)
        local cp = utf8at(ch, 1)
        local src = emoji.glyphCp[cp]
        return src and (':u%x:'):format(src) or nil
    end))
end

--------------------------------------------------------------------------
-- Избранное и недавние
--------------------------------------------------------------------------
-- Храним кодовые точки, а не имена: имена в таблице плагина повторяются,
-- и после перезапуска ':ng:' мог бы вернуть не тот значок, который выбрали.

emoji.RECENT_LIMIT = 24
emoji.favorites = {}     -- массив кодовых точек
emoji.recent = {}        -- массив кодовых точек, свежие в начале
emoji.stateFile = nil    -- задайте свой путь до вызова loadState()
emoji.persist = true     -- false запретит библиотеке трогать диск

-- Счётчик правок: по нему панель понимает, что раскладку пора пересобрать.
local stateRev = 0

--- Сбрасывает кеш раскладки панели. Вызывается само при изменении данных.
function emoji.invalidate()
    stateRev = stateRev + 1
    emoji.clearLayoutCache()
end

local function defaultStateFile()
    return getWorkingDirectory() .. '\\config\\chat_emoji.json'
end

local function indexOf(list, cp)
    for i, v in ipairs(list) do
        if v == cp then return i end
    end
    return nil
end

--- Есть ли смайл в избранном.
---@param key string|integer|ChatEmoji
---@return boolean
function emoji.isFavorite(key)
    local e = emoji.get(key)
    return e ~= nil and indexOf(emoji.favorites, e.cp) ~= nil
end

--- Добавляет или убирает смайл из избранного.
-- @return true, если после вызова смайл в избранном
---@param key string|integer|ChatEmoji
---@return boolean nowFavorite
function emoji.favorite(key)
    local e = emoji.get(key)
    if not e then return false end
    local i = indexOf(emoji.favorites, e.cp)
    if i then
        table.remove(emoji.favorites, i)
    else
        emoji.favorites[#emoji.favorites + 1] = e.cp
    end
    emoji.invalidate()
    emoji.saveState()
    return i == nil
end

--- Отмечает смайл как недавно использованный.
---@param key string|integer|ChatEmoji
---@return boolean
function emoji.pushRecent(key)
    local e = emoji.get(key)
    if not e then return false end
    local i = indexOf(emoji.recent, e.cp)
    if i then table.remove(emoji.recent, i) end
    table.insert(emoji.recent, 1, e.cp)
    while #emoji.recent > emoji.RECENT_LIMIT do
        table.remove(emoji.recent)
    end
    emoji.invalidate()
    emoji.saveState()
    return true
end

--- Читает избранное и недавние с диска.
--- Молча ничего не делает, если файла нет или JSON в MoonLoader недоступен.
---@param path? string
---@return boolean
function emoji.loadState(path)
    path = path or emoji.stateFile or defaultStateFile()
    emoji.stateFile = path
    if not emoji.persist or type(decodeJson) ~= 'function' then return false end
    local f = io.open(path, 'rb')
    if not f then return false end
    local raw = f:read('*a')
    f:close()
    local ok, data = pcall(decodeJson, raw)
    if not ok or type(data) ~= 'table' then return false end
    emoji.favorites = type(data.favorites) == 'table' and data.favorites or {}
    emoji.recent = type(data.recent) == 'table' and data.recent or {}
    emoji.invalidate()
    return true
end

--- Пишет избранное и недавние на диск.
---@param path? string
---@return boolean
function emoji.saveState(path)
    path = path or emoji.stateFile or defaultStateFile()
    emoji.stateFile = path
    if not emoji.persist or type(encodeJson) ~= 'function' then return false end
    local dir = path:match('^(.*)[\\/][^\\/]*$')
    if dir then pcall(createDirectory, dir) end
    local ok, raw = pcall(encodeJson, {
        favorites = emoji.favorites,
        recent = emoji.recent,
    })
    if not ok then return false end
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(raw)
    f:close()
    return true
end

--------------------------------------------------------------------------
-- Панель выбора
--------------------------------------------------------------------------

-- Состояние у каждой панели своё: иначе две панели в одном скрипте делили
-- бы и строку поиска, и кеш раскладки.
local pickers = {}

-- Избранное подтягиваем при первом показе панели, а не при require:
-- скрипту, которому нужны только токены, файл настроек ни к чему.
local stateLoaded = false
local function ensureState()
    if stateLoaded then return end
    stateLoaded = true
    pcall(emoji.loadState)
end

local function pickerState(pid)
    local st = pickers[pid]
    if not st then
        st = { buf = imgui.new.char[64]() }
        pickers[pid] = st
    end
    return st
end

--- Собирает разделы панели: избранное, недавние, категории.
local function buildSections(query, opts)
    local sections = {}

    local function fromCps(list, title)
        if #list == 0 then return end
        local items = {}
        for _, cp in ipairs(list) do
            local e = emoji.byCp[cp]
            if e then items[#items + 1] = e end
        end
        if #items > 0 then sections[#sections + 1] = { title = title, items = items } end
    end

    -- При активном поиске избранное и недавние прячем: иначе одна и та же
    -- иконка показывалась бы в выдаче по два-три раза.
    if query == '' then
        if opts.favorites ~= false then
            fromCps(emoji.favorites, emoji.strings.favorites)
        end
        if opts.recent ~= false then
            fromCps(emoji.recent, emoji.strings.recent)
        end
    end

    local match = makeMatcher(query)
    local function wanted(cat)
        return not opts.onlyCategory or opts.onlyCategory == cat.name
            or opts.onlyCategory == cat.id
    end

    -- При поиске - один список, лучшие совпадения первыми. По категориям
    -- 🔥 на запрос «огонь» оказывался после бенгальского огня и фонарика.
    if match and opts.grouped ~= true then
        local hits = {}
        for _, cat in ipairs(emoji.categories) do
            if wanted(cat) then
                for _, e in ipairs(cat.items) do
                    local score = match(e)
                    if score and (not opts.filter or opts.filter(e)) then
                        hits[#hits + 1] = { e = e, score = score }
                    end
                end
            end
        end
        table.sort(hits, function(x, y)
            if x.score ~= y.score then return x.score < y.score end
            return x.e.index < y.e.index
        end)
        local items = {}
        for i, h in ipairs(hits) do items[i] = h.e end
        if #items > 0 then
            sections[#sections + 1] = { title = emoji.strings.found, items = items }
        end
        return sections
    end

    for _, cat in ipairs(emoji.categories) do
        if wanted(cat) then
            local items = {}
            for _, e in ipairs(cat.items) do
                if (not match or match(e))
                   and (not opts.filter or opts.filter(e)) then
                    items[#items + 1] = e
                end
            end
            if #items > 0 then
                sections[#sections + 1] = { title = cat.name, items = items }
            end
        end
    end

    return sections
end

--- Раскладывает разделы в ряды. Ряды нужны, чтобы рисовать только видимое:
--- полторы тысячи кнопок в одном списке ImGui переваривает, но каждый кадр
--- честно считает их геометрию, и на слабых машинах это заметно.
local function buildRows(sections, size, avail, spacing, headerH, rowH)
    local rows, y = {}, 0
    for secIndex, sec in ipairs(sections) do
        rows[#rows + 1] = { y = y, h = headerH, header = sec.title }
        y = y + headerH

        -- Номер раздела едет вместе с рядом и попадает в идентификатор
        -- кнопки. Без него избранный смайл и он же в своей категории
        -- получали бы один ID, а ImGui считал бы их одним элементом:
        -- подсветка и клик срабатывали бы сразу на обоих.
        local row = { y = y, h = rowH, sec = secIndex, items = {} }
        local x = 0
        for _, e in ipairs(sec.items) do
            local w = size * e.cells + BTN_PAD * 2
            local need = (x > 0) and (spacing + w) or w
            if x > 0 and x + need > avail then
                rows[#rows + 1] = row
                y = y + rowH
                row = { y = y, h = rowH, sec = secIndex, items = {} }
                x = 0
                need = w
            end
            row.items[#row.items + 1] = e
            x = x + need
        end
        if #row.items > 0 then
            rows[#rows + 1] = row
            y = y + rowH
        end
        y = y + spacing
    end
    return rows, y
end

--- Панель выбора смайла: поиск и сетка по категориям.
--- Совместима со старым вызовом emoji.picker(id, size, height).
-- @param id   уникальный идентификатор панели
-- @param a    размер смайла либо таблица настроек
-- @param b    высота области прокрутки, если размер передан числом
--
-- Настройки: size, height, search, favorites, recent, onlyCategory,
--            filter (функция от записи), tooltip, border, grouped (true -
--            при поиске оставить разбивку по категориям)
-- @return выбранная запись либо nil
---@param id string
---@param a? number|table размер либо таблица настроек
---@param b? number высота области
---@return ChatEmoji|nil picked
function emoji.picker(id, a, b)
    if not imgui then return nil end

    local opts
    if type(a) == 'table' then
        opts = a
    else
        opts = { size = a, height = b }
    end

    if not emoji.loaded then
        imgui.TextDisabled(emoji.strings.notLoaded)
        return nil
    end

    ensureState()

    local size = opts.size or 24
    local height = opts.height or 320
    local picked = nil

    -- Пространство имён делаем суффиксом в подписях, а не PushID: PushID в
    -- ImGui перегружена (int/str/ptr), и биндинг mimgui не отдаёт её под
    -- коротким именем - imgui.PushID там nil.
    local pid = tostring(id or 'chat_emoji_picker')
    local st = pickerState(pid)

    if opts.search ~= false then
        imgui.PushItemWidth(-1)
        imgui.InputTextWithHint('##search' .. pid, emoji.strings.search,
                                st.buf, ffi.sizeof(st.buf))
        imgui.PopItemWidth()
    end

    local query = ffi.string(st.buf):lower()
    local style = imgui.GetStyle()
    local spacing = style.ItemSpacing.x
    local headerH = imgui.GetTextLineHeight() + style.ItemSpacing.y
    local rowH = size + BTN_PAD * 2 + style.ItemSpacing.y

    imgui.BeginChild('##grid' .. pid, imgui.ImVec2(0, height),
                     opts.border ~= false)

    local avail = imgui.GetContentRegionAvail().x
    -- Ряды позиционируются вручную, поэтому за нулевую отметку берём
    -- текущее положение курсора, а не ноль окна: иначе первый ряд залезал
    -- бы на рамку, а последний не доходил бы до низа на высоту отступа.
    local originY = imgui.GetCursorPosY()

    -- Ключ кеша: всё, от чего зависит раскладка. Ширину округляем, иначе
    -- дрожание на десятые доли пикселя пересобирало бы её каждый кадр.
    local key = ('%s|%d|%d|%d|%s'):format(query, size, math.floor(avail),
                                          stateRev, tostring(opts.onlyCategory))
    if st.key ~= key then
        local sections = buildSections(query, opts)
        st.rows, st.total = buildRows(sections, size, avail, spacing,
                                      headerH, rowH)
        st.key = key
        st.empty = #sections == 0
    end

    if st.empty then
        imgui.TextDisabled(emoji.strings.nothingFound)
    else
        local scroll = imgui.GetScrollY()
        local view = imgui.GetWindowHeight()
        local top = scroll - originY - rowH
        local bottom = scroll - originY + view + rowH

        for _, row in ipairs(st.rows) do
            if row.y + row.h >= top and row.y <= bottom then
                imgui.SetCursorPosY(originY + row.y)
                if row.header then
                    imgui.TextDisabled(row.header)
                else
                    for i, e in ipairs(row.items) do
                        if i > 1 then imgui.SameLine() end
                        local btnId = ('%s_%d_%d'):format(pid, row.sec, e.slot)
                        if emoji.button(e, size, btnId) then
                            picked = e
                        end
                        if imgui.IsItemHovered() then
                            if opts.tooltip ~= false then
                                imgui.SetTooltip(('%s\n%s\n%s'):format(
                                    ':' .. e.name .. ':', e.token,
                                    emoji.strings.pickerHint))
                            end
                            if imgui.IsMouseClicked(1) then
                                emoji.favorite(e)
                            end
                        end
                    end
                end
            end
        end

        -- Ряды рисуются выборочно, поэтому высоту содержимого объявляем
        -- явно: без этого полоса прокрутки считала бы только видимое.
        imgui.SetCursorPosY(originY + st.total)
        imgui.Dummy(imgui.ImVec2(1, 1))
    end

    imgui.EndChild()

    if picked then emoji.pushRecent(picked) end
    return picked
end

--- Задаёт строку поиска панели снаружи: например, подставить слово,
--- которое человек уже набрал в чате после двоеточия.
---@param id string тот же id, что у picker()
---@param text string запрос в UTF-8
function emoji.setPickerQuery(id, text)
    if not imgui then return end
    local st = pickerState(tostring(id or 'chat_emoji_picker'))
    local size = ffi.sizeof(st.buf)
    local s = tostring(text or ''):sub(1, size - 1)
    ffi.fill(st.buf, size, 0)
    ffi.copy(st.buf, s, #s)
    st.key = nil
end

--- Панель во всплывающем окне. Открывать через imgui.OpenPopup(id)
--- либо через emoji.pickerButton().
---@param id string
---@param opts? table
---@return ChatEmoji|nil picked
function emoji.pickerPopup(id, opts)
    if not imgui then return nil end
    opts = opts or {}
    local pid = tostring(id or 'chat_emoji_popup')
    local picked = nil
    if imgui.BeginPopup(pid) then
        picked = emoji.picker(pid .. '_grid', opts)
        if picked and opts.closeOnPick ~= false then
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end
    return picked
end

--- Кнопка, открывающая панель выбора рядом с собой.
--- Готовый вариант для строки ввода: кнопка справа от поля, панель под ней.
-- @return выбранная запись либо nil
---@param label? string
---@param id? string
---@param opts? table
---@return ChatEmoji|nil picked
function emoji.pickerButton(label, id, opts)
    if not imgui then return nil end
    local pid = tostring(id or 'chat_emoji_popup')
    if imgui.Button(tostring(label or ':)') .. '##' .. pid) then
        imgui.OpenPopup(pid)
    end
    return emoji.pickerPopup(pid, opts)
end

--- Поле ввода со встроенной кнопкой смайлов.
--- Токен дописывается в конец строки: позицию курсора внутри InputText
--- ImGui наружу не отдаёт, и притворяться, что мы её знаем, честнее не
--- пытаться.
-- @param buf буфер imgui.new.char[N]
-- @return изменилось ли поле, выбранная запись либо nil
---@param label string
---@param buf ffi.cdata* imgui.new.char[N]
---@param opts? table
---@return boolean changed
---@return ChatEmoji|nil picked
function emoji.inputText(label, buf, opts)
    if not imgui then return false, nil end
    opts = opts or {}
    local pid = tostring(opts.id or label or 'chat_emoji_input')
    local btnW = imgui.CalcTextSize(':)').x + imgui.GetStyle().FramePadding.x * 2

    imgui.PushItemWidth(-(btnW + imgui.GetStyle().ItemSpacing.x))
    local changed = imgui.InputTextWithHint(tostring(label) .. '##' .. pid,
                                            opts.hint or '', buf,
                                            ffi.sizeof(buf))
    imgui.PopItemWidth()
    imgui.SameLine()

    local picked = emoji.pickerButton(':)', pid .. '_pick', opts)
    if picked then
        local cur = ffi.string(buf)
        -- opts.glyphs: вставлять глиф шрифта (виден прямо в поле, см.
        -- fontGlyphs), а не токен. Перед отправкой - emoji.fromGlyphs().
        local add = picked.token
        if opts.glyphs and emoji.glyphs[picked.cp] then add = emoji.glyph(picked) end
        if #cur + #add < ffi.sizeof(buf) then
            ffi.copy(buf, cur .. add)
            changed = true
        end
    end
    return changed, picked
end

--------------------------------------------------------------------------
-- Диагностика
--------------------------------------------------------------------------

--- Сводка о состоянии библиотеки. Удобно вывести в окно отладки.
---@return table
function emoji.info()
    local a = emoji.atlas
    local glyphs = 0
    for _ in pairs(emoji.glyphs) do glyphs = glyphs + 1 end
    return {
        version = emoji.VERSION,
        ready = emoji.ready,
        loaded = emoji.loaded,
        shared = emoji.sharedTexture,
        small = emoji.textureSmall ~= nil,
        format = emoji.FORMAT,
        plugin = emoji.plugin,
        stale = emoji.stale,
        count = #emoji.list,
        categories = #emoji.categories,
        favorites = #emoji.favorites,
        recent = #emoji.recent,
        glyphs = glyphs,
        atlas = a and {
            file = a.file, width = a.width, height = a.height,
            cell = a.cell, cols = a.cols, version = a.version,
            texWidth = a.texWidth, texHeight = a.texHeight,
        } or nil,
    }
end

--- Проверяет описание атласа на внутренние несостыковки: UV за границами
--- текстуры, дубли слотов, глиф, вылезающий за правый край ряда, битый
--- обратный поиск по токену. Пригодится после пересборки атласа.
-- @return true, если проблем нет; список описаний проблем
---@return boolean ok
---@return string[] problems
function emoji.selfTest()
    local bad = {}
    if not emoji.ready then
        return false, { 'atlas is not loaded' }
    end

    local a = emoji.atlas
    local seenSlot, seenName = {}, {}
    for _, e in ipairs(emoji.list) do
        if e.u0 < 0 or e.v0 < 0 or e.u1 > 1.0001 or e.v1 > 1.0001 then
            bad[#bad + 1] = ('%s: UV out of range'):format(e.name)
        end
        if (e.slot % a.cols) + e.cells > a.cols then
            bad[#bad + 1] = ('%s: glyph crosses the row edge'):format(e.name)
        end
        if seenSlot[e.slot] then
            bad[#bad + 1] = ('slot %d is used twice (%s, %s)')
                :format(e.slot, seenSlot[e.slot], e.name)
        end
        seenSlot[e.slot] = e.name
        if emoji.get(e.token) ~= e then
            bad[#bad + 1] = ('%s: token %s resolves elsewhere')
                :format(e.name, e.token)
        end
        -- Дубли имён это не поломка, а особенность таблицы плагина.
        -- Сообщаем о них отдельной формулировкой, чтобы не пугать, и сразу
        -- показываем, какой из глифов выигрывает поиск по имени.
        if seenName[e.name] then
            bad[#bad + 1] = ('note: name %s is shared by slots %d and %d, %d wins')
                :format(e.name, seenName[e.name], e.slot, seenName[e.name])
        else
            seenName[e.name] = e.slot
        end
    end

    if a.count and a.count ~= #emoji.list then
        bad[#bad + 1] = ('atlas.count is %d, actual %d')
            :format(a.count, #emoji.list)
    end

    -- Малый атлас обязан быть ровно вдвое меньше: UV у них общие.
    local s = a.small
    if type(s) == 'table' then
        if s.width * 2 ~= a.width or s.height * 2 ~= a.height
           or (s.cell and s.cell * 2 ~= a.cell) then
            bad[#bad + 1] = ('small atlas %dx%d is not half of %dx%d')
                :format(s.width, s.height, a.width, a.height)
        end
    end

    -- Иконки, на которые завязаны weapon(), crown() и wings()
    for _, id in ipairs({ 0, 24, 31, 46 }) do
        if not emoji.weapon(id) then
            bad[#bad + 1] = ('weapon(%d) is missing'):format(id)
        end
    end
    if not emoji.crown(1) or not emoji.wings(10) then
        bad[#bad + 1] = 'crown/wings icons are missing'
    end

    return #bad == 0, bad
end

-- Для tools/test_chat_emoji.lua: внутренности, которые иначе не проверить
-- без игры. Это не API: имена и поведение могут меняться без предупреждения.
emoji._internal = {
    takeShared = takeShared,
    publishShared = publishShared,
    releaseTexture = releaseTexture,
    slotRead = slotRead,
    slotWrite = slotWrite,
    blitGlyph = blitGlyph,
    callable = callable,
    utf8at = utf8at,
}

return emoji
