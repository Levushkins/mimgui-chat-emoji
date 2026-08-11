-- chat_emoji_demo.lua — пример работы со смайлами из _chat.asi в mimgui.
--
-- Команда /emj открывает панель: сетка смайлов с поиском, предпросмотр
-- выбранной иконки в разных размерах и отправка сообщения в чат.
--
-- Установка:
--   moonloader/chat_emoji_demo.lua
--   moonloader/lib/chat_emoji.lua
--   moonloader/resource/chat_emoji/chat_emoji.png
--   moonloader/resource/chat_emoji/chat_emoji_atlas.lua
--
-- Про кодировку: в литералах здесь только латиница, поэтому файл можно
-- пересохранять в любой кодировке — ничего не сломается. Русский текст
-- в ImGui передавайте в UTF-8 (файл сохраняйте в UTF-8, без u8()), а для
-- SA-MP переводите обратно в cp1251 через u8:decode().

script_name('Chat Emoji Demo')
script_author('extracted from _chat.asi')

local ffi = require 'ffi'
local imgui = require 'mimgui'
local emoji = require 'chat_emoji'

local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local window = imgui.new.bool(false)
local message = imgui.new.char[144]()
local gridSize = imgui.new.int(24)
local customSize = imgui.new.int(48)
local loadError = nil
local selected = nil

-- размеры для витрины: одна и та же иконка рисуется каждым из них
local SIZES = { 12, 16, 24, 32, 48, 64, 96 }

function main()
    while not isSampAvailable() do wait(0) end
    sampRegisterChatCommand('emj', function() window[0] = not window[0] end)
    sampAddChatMessage('Chat Emoji: /emj - emoji panel', 0x8ACC47)
    wait(-1)
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil

    local ok, err = emoji.load()
    if not ok then
        loadError = err
        sampAddChatMessage('Chat Emoji: ' .. tostring(err), 0xFF4444)
    else
        selected = emoji.get('arz') or emoji.list[1]
    end
end)

--- Витрина: выбранная иконка в разных размерах.
-- Размер задаётся в пикселях по высоте и меняется на лету — это обычная
-- текстура, а не шрифт, так что фиксированного размера у неё нет.
local function drawShowcase()
    if not selected then
        imgui.TextDisabled('Click any emoji below')
        return
    end

    imgui.Text(('%s   %s   cells=%d')
        :format(selected.name, selected.token, selected.cells))

    imgui.BeginChild('##sizes', imgui.ImVec2(0, 130), true,
                     imgui.WindowFlags.HorizontalScrollbar)
    for i, sz in ipairs(SIZES) do
        if i > 1 then imgui.SameLine() end
        imgui.BeginGroup()
        -- подпись сверху, под ней сама иконка нужной высоты
        imgui.Text(tostring(sz))
        emoji.image(selected, sz)
        imgui.EndGroup()
    end
    imgui.EndChild()

    imgui.PushItemWidth(200)
    imgui.SliderInt('custom size', customSize, 8, 128)
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.TextDisabled(('%dx%d px')
        :format(emoji.width(selected, customSize[0]), customSize[0]))
    emoji.image(selected, customSize[0])
end

imgui.OnFrame(
    function() return window[0] end,
    function(self)
        self.HideCursor = false

        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2),
                               imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(720, 640), imgui.Cond.FirstUseEver)

        if imgui.Begin('Chat emoji', window) then
            if loadError then
                imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, 1), tostring(loadError))
                imgui.TextWrapped('Check that moonloader/resource/chat_emoji/ contains '
                    .. 'chat_emoji.png and chat_emoji_atlas.lua.')
                imgui.End()
                return
            end

            imgui.Text('Total: ' .. #emoji.list)
            imgui.SameLine()
            imgui.PushItemWidth(140)
            imgui.SliderInt('grid size', gridSize, 12, 64)
            imgui.PopItemWidth()

            imgui.Separator()
            drawShowcase()
            imgui.Separator()

            -- строка сообщения и предпросмотр с подставленными смайлами.
            -- InputText отдаёт UTF-8, поэтому в emoji.text идёт как есть.
            imgui.PushItemWidth(-1)
            imgui.InputTextWithHint('##msg', 'Message text...',
                                    message, ffi.sizeof(message))
            imgui.PopItemWidth()

            local text = ffi.string(message)
            if #text > 0 then
                emoji.text(text, imgui.GetFontSize())
            end

            if imgui.Button('Send to chat') and #text > 0 then
                sampSendChat(u8:decode(text))   -- UTF-8 -> cp1251 для SA-MP
                message[0] = 0
            end
            imgui.SameLine()
            if imgui.Button('Clear') then message[0] = 0 end
            imgui.SameLine()
            if imgui.Button('Append selected') and selected then
                local cur = ffi.string(message)
                if #cur + #selected.token < ffi.sizeof(message) then
                    ffi.copy(message, cur .. selected.token)
                end
            end

            imgui.Separator()

            -- клик по сетке выбирает иконку для витрины
            local picked = emoji.picker('grid', gridSize[0], 240)
            if picked then selected = picked end
        end
        imgui.End()
    end
)

function onScriptTerminate(scr, quitGame)
    if scr == thisScript() and not quitGame then
        emoji.unload()
    end
end
