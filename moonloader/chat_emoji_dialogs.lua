-- chat_emoji_dialogs.lua - смайлы из _chat.asi в обычных диалогах SA-MP.
--
-- Команда /emjd открывает конструктор: выбираете стиль диалога, набираете
-- текст, кликом вставляете смайлы и сразу смотрите, как это выглядит
-- в настоящем диалоге SA-MP. Ответ на диалог показывается тут же.
--
-- Главное, что демонстрирует эта демка: в диалогах смайлы рисует сам
-- _chat.asi, а не библиотека. Плагин прогоняет текст диалоговых контролов
-- через тот же разборщик токенов, что и чат, поэтому от скрипта нужно
-- только вставить в строку ":u1f603:". Ни текстуры, ни отрисовки.
--
-- Установка:
--   moonloader/chat_emoji_dialogs.lua
--   moonloader/lib/chat_emoji.lua
--   moonloader/resource/chat_emoji/chat_emoji.png
--   moonloader/resource/chat_emoji/chat_emoji_atlas.lua
--
-- Про кодировку: в литералах здесь только латиница, поэтому файл можно
-- пересохранять в любой кодировке, ничего не сломается. Текст, набранный
-- в окне, приходит из ImGui в UTF-8 и уходит в SA-MP через u8:decode()
-- в cp1251 - ровно так и надо делать в своих скриптах. Сами токены
-- (":u1f603:") - чистый ASCII и переживают любую перекодировку.

script_name('Chat Emoji Dialogs')
script_author('extracted from _chat.asi')

local ffi = require 'ffi'
local imgui = require 'mimgui'
local emoji = require 'chat_emoji'

local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local DIALOG_ID = 31500

local STYLES = {
    { id = 0, name = 'MSGBOX' },
    { id = 1, name = 'INPUT' },
    { id = 2, name = 'LIST' },
    { id = 3, name = 'PASSWORD' },
    { id = 4, name = 'TABLIST' },
    { id = 5, name = 'TABLIST_HEADERS' },
}

local window = imgui.new.bool(false)
local caption = imgui.new.char[128]()
local body = imgui.new.char[2048]()
local btn1 = imgui.new.char[32]()
local btn2 = imgui.new.char[32]()
local style = imgui.new.int(2)

local loadError = nil
local lastAnswer = nil
local waiting = false

--------------------------------------------------------------------------
-- Работа с буферами
--------------------------------------------------------------------------

local function setBuf(buf, size, str)
    ffi.fill(buf, size, 0)
    ffi.copy(buf, str, math.min(#str, size - 1))
end

local function getBuf(buf)
    return ffi.string(buf)
end

--- Дописывает кусок в конец буфера, если он туда влезает.
local function appendBuf(buf, size, str)
    local cur = ffi.string(buf)
    if #cur + #str >= size then return false end
    setBuf(buf, size, cur .. str)
    return true
end

--------------------------------------------------------------------------
-- Готовые примеры
--------------------------------------------------------------------------
-- Токены собираются по именам из атласа, а не вписаны хардкодом: если у вас
-- другая версия _chat.asi, имена всё равно разрешатся в актуальные коды.

local function t(name)
    local tok = emoji.tok(name)
    return tok ~= '' and tok or ''
end

local PRESETS = {
    {
        label = 'Menu',
        style = 2,
        caption = 'Main menu ' .. '%arz%',
        body = '%trophy% Statistics\n'
            .. '%moneybag% Balance\n'
            .. '%gear% Settings\n'
            .. '%lock% Admin panel\n'
            .. '%x% Close',
        btn1 = 'Select', btn2 = 'Cancel',
    },
    {
        label = 'Table',
        style = 5,
        caption = 'Players ' .. '%arz%',
        body = 'Nick\tLevel\tMoney\n'
            .. '%crown% Nick_Name\t12\t1.250.000 %cash%\n'
            .. '%gem% Other_Player\t8\t340.000 %cash%\n'
            .. '%skull% Third_One\t3\t12.400 %cash%',
        btn1 = 'Open', btn2 = 'Back',
    },
    {
        label = 'Message',
        style = 0,
        caption = 'Warning %warning%',
        body = '%warning% Your advert was rejected.\n\n'
            .. '%memo% Reason: forbidden wording\n'
            .. '%hourglass% Next try in 5 minutes\n\n'
            .. '%bulb% Read the rules before posting.',
        btn1 = 'Got it', btn2 = '',
    },
    {
        label = 'Input',
        style = 1,
        caption = 'Advert text %mega%',
        body = '%memo% Type the advert below.\n'
            .. '%true% Allowed: sell, buy, rent\n'
            .. '%x% Forbidden: insults, links',
        btn1 = 'Send', btn2 = 'Cancel',
    },
}

--- Подставляет в шаблон настоящие токены вместо %name%.
local function fill(template)
    return (template:gsub('%%([%w_%+%-]+)%%', function(name)
        return t(name)
    end))
end

local function applyPreset(p)
    style[0] = p.style
    setBuf(caption, ffi.sizeof(caption), fill(p.caption))
    setBuf(body, ffi.sizeof(body), fill(p.body))
    setBuf(btn1, ffi.sizeof(btn1), p.btn1)
    setBuf(btn2, ffi.sizeof(btn2), p.btn2)
end

--------------------------------------------------------------------------
-- Показ диалога
--------------------------------------------------------------------------

local function showDialog()
    -- ImGui отдаёт UTF-8, SA-MP ждёт cp1251. Токены при этом не трогаем -
    -- они ASCII и переживают перекодировку без потерь.
    local cap = u8:decode(getBuf(caption))
    local text = u8:decode(getBuf(body))
    local b1 = u8:decode(getBuf(btn1))
    local b2 = u8:decode(getBuf(btn2))

    local ok, why = emoji.dialog(DIALOG_ID, cap, text, b1, b2, style[0])
    if not ok then
        sampAddChatMessage('Chat Emoji: ' .. tostring(why), 0xFF6666)
        return
    end
    lastAnswer = nil
    waiting = true
    window[0] = false
end

function main()
    while not isSampAvailable() do wait(0) end

    -- Для диалогов текстура не нужна, но эта демка ещё и показывает панель
    -- выбора, поэтому грузим всё. Скрипту, которому нужны только диалоги,
    -- хватило бы emoji.loadTable().
    local okTable, tableErr = emoji.loadTable()
    if not okTable then loadError = tableErr end

    applyPreset(PRESETS[1])

    sampRegisterChatCommand('emjd', function() window[0] = not window[0] end)
    sampAddChatMessage('Chat Emoji Dialogs: /emjd - dialog builder', 0x8ACC47)

    while true do
        wait(0)
        if waiting then
            local answered, button, list, input = sampHasDialogRespond(DIALOG_ID)
            if answered then
                waiting = false
                lastAnswer = {
                    button = button,
                    list = list,
                    input = u8(input or ''),
                }
                window[0] = true
            end
        end
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local ok, err = emoji.load()
    if not ok then loadError = err end
end)

--------------------------------------------------------------------------
-- Окно
--------------------------------------------------------------------------

local function drawStatus()
    if emoji.detect() then
        imgui.TextColored(imgui.ImVec4(0.4, 0.85, 0.4, 1),
            'Chat plugin detected: tokens will be rendered by _chat.asi')
    else
        imgui.TextColored(imgui.ImVec4(1, 0.75, 0.3, 1),
            'Chat plugin NOT detected: emoji.fit() will strip tokens')
        imgui.TextWrapped('This is expected outside Arizona. The dialog will '
            .. 'still open, just without icons.')
    end
    if loadError then
        imgui.TextColored(imgui.ImVec4(1, 0.4, 0.4, 1), tostring(loadError))
    end
end

local function drawStyleRow()
    imgui.Text('Style:')
    for i, s in ipairs(STYLES) do
        imgui.SameLine()
        -- Активный стиль помечаем текстом, а не PushStyleColor: она
        -- перегружена, и в части сборок mimgui её под коротким именем нет.
        local label = (style[0] == s.id and '> ' or '  ') .. s.name
        if imgui.Button(label .. '##st' .. i) then style[0] = s.id end
    end
end

local function drawPresets()
    imgui.Text('Presets:')
    for i, p in ipairs(PRESETS) do
        imgui.SameLine()
        if imgui.Button(p.label .. '##pr' .. i) then applyPreset(p) end
    end
end

local function drawAnswer()
    if not lastAnswer then
        imgui.TextDisabled('No dialog answered yet')
        return
    end
    imgui.Text(('button = %d    listitem = %d')
        :format(lastAnswer.button, lastAnswer.list))
    if lastAnswer.input ~= '' then
        imgui.Text('input = ' .. lastAnswer.input)
    end
end

imgui.OnFrame(
    function() return window[0] end,
    function(self)
        imgui.SetNextWindowSize(imgui.ImVec2(720, 640), imgui.Cond.FirstUseEver)
        imgui.Begin('Chat Emoji: SA-MP dialogs', window)

        drawStatus()
        imgui.Separator()

        drawStyleRow()
        drawPresets()
        imgui.Separator()

        imgui.Text('Caption')
        imgui.PushItemWidth(-1)
        imgui.InputText('##cap', caption, ffi.sizeof(caption))
        imgui.PopItemWidth()

        imgui.Text('Text  (\\n is a new line, \\t is a column in TABLIST)')
        imgui.InputTextMultiline('##body', body, ffi.sizeof(body),
                                 imgui.ImVec2(-1, 130))

        imgui.Text('Buttons')
        imgui.PushItemWidth(150)
        imgui.InputText('##b1', btn1, ffi.sizeof(btn1))
        imgui.SameLine()
        imgui.InputText('##b2', btn2, ffi.sizeof(btn2))
        imgui.PopItemWidth()

        imgui.Spacing()
        if imgui.Button('Show dialog') then showDialog() end
        imgui.SameLine()
        if imgui.Button('Clear text') then
            setBuf(body, ffi.sizeof(body), '')
        end
        imgui.SameLine()
        local m = emoji.measure(getBuf(body))
        imgui.TextDisabled(('%d bytes, %d tokens (limit %d)')
            :format(m.bytes, m.tokens, emoji.DIALOG_LIMIT))

        imgui.Separator()
        imgui.Text('Last answer')
        drawAnswer()

        imgui.Separator()
        imgui.Text('Click an icon to append its token to the text')
        local picked = emoji.picker('emjd', 24, 200)
        if picked then
            appendBuf(body, ffi.sizeof(body), picked.token)
        end

        imgui.End()
    end
)

function onScriptTerminate(scr, quitGame)
    if scr == thisScript() and not quitGame then emoji.unload() end
end
