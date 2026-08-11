-- chat_emoji_minimal.lua — самый короткий рабочий пример.
-- Команда /sm открывает окно mimgui со смайлами.
--
-- Файлы:
--   moonloader/chat_emoji_minimal.lua              <- этот файл
--   moonloader/lib/chat_emoji.lua
--   moonloader/resource/chat_emoji/chat_emoji.png
--   moonloader/resource/chat_emoji/chat_emoji_atlas.lua
--
-- ВАЖНО про кодировку: этот файл сохранён в UTF-8, а ImGui как раз ждёт
-- UTF-8, поэтому русские строки передаются в него как есть, без u8().
-- Оборачивать в u8() надо наоборот — файлы в cp1251. А вот SA-MP работает
-- в cp1251, поэтому текст для sampSendChat / sampAddChatMessage переводим
-- обратно через u8:decode().

script_name('Emoji Minimal')

local imgui = require 'mimgui'
local emoji = require 'chat_emoji'

local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local window = imgui.new.bool(false)

function main()
    while not isSampAvailable() do wait(0) end
    sampRegisterChatCommand('sm', function() window[0] = not window[0] end)
    sampAddChatMessage('Emoji: /sm', 0x8ACC47)
    wait(-1)
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil

    -- грузим атлас смайлов; если что-то не так — напишет в чат
    local ok, err = emoji.load()
    if not ok then sampAddChatMessage('Emoji: ' .. tostring(err), 0xFF4444) end
end)

imgui.OnFrame(
    function() return window[0] end,
    function()
        imgui.SetNextWindowSize(imgui.ImVec2(420, 380), imgui.Cond.FirstUseEver)
        if imgui.Begin('Emoji', window) then

            -- 1. просто нарисовать смайл
            emoji.image('smiley', 32)
            imgui.SameLine()
            emoji.image('joy', 32)
            imgui.SameLine()
            emoji.image('arz', 32)          -- серверная иконка Arizona

            -- 2. смайл как кнопка
            if emoji.button('fire', 32) then
                sampAddChatMessage('fire pressed', 0xFFFFFF)
            end

            -- 3. текст со смайлами внутри
            emoji.text('hello :u1f603: how are you :u1f44b:')

            imgui.Separator()

            -- 4. панель выбора: клик отправляет смайл в чат.
            --    Токен :uXXXX: состоит из цифр и латиницы, так что
            --    перекодировать его не нужно.
            local picked = emoji.picker('grid', 24, 220)
            if picked then
                sampSendChat(emoji.encode(picked))
            end
        end
        imgui.End()
    end
)

function onScriptTerminate(scr, quitGame)
    if scr == thisScript() and not quitGame then emoji.unload() end
end
