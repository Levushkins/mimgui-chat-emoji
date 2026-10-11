-- chat_emoji_showcase.lua - витрина chat_emoji 3.2.
--
-- Показывает всё новое в одном окне. Скрипт ничего не меняет в игре:
-- посмотрел, убедился, удалил.
--
-- Установка: moonloader\chat_emoji_showcase.lua (плюс сама библиотека).
-- Файл в UTF-8. Пересохранять блокнотом нельзя, он пишет cp1251.
--
-- Команды (на сервере):          Клавиши (только в одиночной игре:
--                                  в SA-MP F7-F9 заняты чатом,
--                                  скриншотом и килл-листом):
--   /emjnew   окно                   F7
--   /emjhud   HUD и метки в мире     F8
--   /emjtour  автотур                F9
--   /emjmsg   локальное сообщение
--   /emjtest  сводка и самопроверка
--   F3 при открытом чате вставляет смайл в строку ввода.
--
-- Автотур сам переключает вкладки, печатает запросы в поиске и
-- показывает HUD. Руками ничего трогать не нужно - удобно для записи
-- GIF. Запустить тур можно и снаружи, не трогая игру: создайте пустой
-- файл %TEMP%\chat_emoji_tour.flag, скрипт заметит его за секунду.
-- Удобно, когда запись ведёт другая программа, а игра запущена от
-- администратора и чужих нажатий клавиш не принимает.

script_name('Chat Emoji Showcase')
script_author('chat_emoji')
script_version('3.2')

local imgui = require 'mimgui'
local emoji = require 'chat_emoji'
local ffi = require 'ffi'
local vkeys = require 'vkeys'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

assert(emoji.atLeast('3.2'), 'chat_emoji 3.2 or newer is required')

-- Русский текст для SA-MP уходит в cp1251, в ImGui остаётся в UTF-8.
local function cp(s) return u8:decode(s) end
local TAG = '{6BAAE8}[emoji]{FFFFFF} '

-- В одиночной игре SA-MP нет вовсе, и функций SAMPFUNCS может не быть.
local function sampOk()
    return type(isSampLoaded) == 'function' and isSampLoaded()
       and type(isSampAvailable) == 'function' and isSampAvailable()
end

local function say(s)
    if sampOk() then sampAddChatMessage(TAG .. cp(s), -1) end
end

local win = imgui.new.bool(false)
local hud = imgui.new.bool(false)
local ready, loadError = false, nil
local glyphsOk = false

local fireOn = imgui.new.bool(true)
local comboItems = { ':u1f525: Огонь', ':u2764: Сердце', ':u1f3c6: Кубок', ':u1f48e: Алмаз' }
local comboCur = 1
local glyphBuf = imgui.new.char[256]()
local plainBuf = imgui.new.char[128]()
local selected = 1

-- Сообщения «из Telegram»: настоящие смайлы Unicode в UTF-8.
local INCOMING = {
    'Продал дом за 25кк \240\159\148\165\240\159\145\141\240\159\143\187',
    'Сбор у банка в 18:00 \226\157\164\239\184\143',
    'Код от сейфа: 1\239\184\143\226\131\163 2\239\184\143\226\131\163 7\239\184\143\226\131\163',
}

--- Подпись для обычного виджета ImGui: глифы шрифта, а если вшить их не
--- вышло - просто текст без токенов.
local function G(s)
    if glyphsOk then return emoji.toGlyphs(s) end
    return emoji.strip(s)
end

-- Подписи панели по-русски. Сам модуль держит их латиницей, чтобы его файл
-- оставался в ASCII; этот файл в UTF-8, ему можно.
emoji.strings.search = 'Поиск: огонь, сердце, дигл...'
emoji.strings.favorites = 'Избранное'
emoji.strings.recent = 'Недавние'
emoji.strings.found = 'Найдено'
emoji.strings.nothingFound = 'ничего не нашлось'
emoji.strings.pickerHint = 'ПКМ - в избранное'

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local ok, err = emoji.load()
    ready, loadError = ok, err
    if ok then
        -- Смайлы в шрифт по умолчанию: дальше они работают в любых
        -- виджетах ImGui. Пиксели лягут в атлас шрифта чуть позже,
        -- после всех обработчиков OnInitialize.
        local gok, gerr = emoji.fontGlyphs()
        glyphsOk = gok
        if not gok then print('fontGlyphs: ' .. tostring(gerr)) end
    end
end)

--------------------------------------------------------------------------
-- Автотур
--------------------------------------------------------------------------
local tour = { on = false, t0 = 0, tab = nil, typed = '' }

local TABS = { 'search', 'font', 'game', 'telegram', 'text' }

-- Расписание: { с какой секунды, что делать }
local SCRIPT = {
    { 0.0,  'tab', 'search' }, { 0.0, 'query', '' },
    { 1.0,  'type', 'огонь' }, { 4.0, 'type', 'сердце' },
    { 7.0,  'type', 'jujym' }, { 10.0, 'type', 'дигл' },
    { 12.5, 'tab', 'font' },
    { 13.0, 'glyph', 'fire' }, { 13.6, 'glyph', '<3' }, { 14.2, 'glyph', 'trophy' },
    { 14.8, 'glyph', 'joy' }, { 15.4, 'glyph', 'arz' },
    { 17.5, 'tab', 'game' },
    { 21.5, 'tab', 'telegram' },
    { 25.0, 'hud' },
    { 31.0, 'stop' },
}

local function utf8chars(s)
    local out = {}
    for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out + 1] = ch end
    return out
end

local function startTour()
    tour = { on = true, t0 = os.clock(), step = 1, typing = nil, tab = 'search' }
    win[0], hud[0] = true, false
    ffi.fill(glyphBuf, ffi.sizeof(glyphBuf), 0)
    ffi.copy(glyphBuf, 'Привет ')
    emoji.setPickerQuery('main', '')
end

local function tickTour()
    if not tour.on then return end
    local t = os.clock() - tour.t0
    while SCRIPT[tour.step] and SCRIPT[tour.step][1] <= t do
        local s = SCRIPT[tour.step]
        local what, arg = s[2], s[3]
        if what == 'tab' then
            tour.tab = arg
        elseif what == 'query' then
            emoji.setPickerQuery('main', arg)
        elseif what == 'type' then
            tour.typing = { chars = utf8chars(arg), at = t, n = 0 }
            emoji.setPickerQuery('main', '')
        elseif what == 'glyph' then
            local cur = ffi.string(glyphBuf)
            local add = emoji.glyph(arg)
            if add == '' then add = emoji.tok(arg) end
            ffi.copy(glyphBuf, cur .. add)
        elseif what == 'hud' then
            win[0], hud[0] = false, true
        elseif what == 'stop' then
            tour.on = false
            hud[0] = false
        end
        tour.step = tour.step + 1
    end
    -- печать запроса по букве
    local ty = tour.typing
    if ty and ty.n < #ty.chars then
        local n = math.min(#ty.chars, math.floor((t - ty.at) / 0.22) + 1)
        if n ~= ty.n then
            ty.n = n
            emoji.setPickerQuery('main', table.concat(ty.chars, '', 1, n))
        end
    end
end

--------------------------------------------------------------------------
-- Окно
--------------------------------------------------------------------------
local function tabItem(id, label)
    local flags = 0
    if tour.on and tour.tab == id and tour.shownTab ~= id then
        flags = 2   -- ImGuiTabItemFlags_SetSelected
    end
    local open = imgui.BeginTabItem(G(label) .. '##' .. id, nil, flags)
    if open and flags ~= 0 then tour.shownTab = id end
    return open
end

local function tabSearch()
    imgui.TextDisabled('Поиск по-русски, по-английски и с неправильной раскладкой.')
    imgui.TextDisabled('Попробуй: огонь, сердце, дигл, jujym. ПКМ - в избранное.')
    local picked = emoji.picker('main', { size = 26, height = 290 })
    if picked then
        emoji.addChatMessage(cp('Выбран ') .. picked.token .. ' ' .. picked.token)
    end
end

local function tabFont()
    imgui.TextDisabled('Смайлы вшиты в шрифт: это обычные виджеты ImGui.')
    if not glyphsOk then
        imgui.TextDisabled('fontGlyphs() не сработал, см. moonloader.log')
        return
    end
    imgui.Button(G(':u1f3c6: Купить'))
    imgui.SameLine()
    imgui.Button(G(':u2764: Нравится'))
    imgui.SameLine()
    imgui.Button(G(':u1f680:'))
    imgui.Checkbox(G(':u1f525: Обычный Checkbox'), fireOn)
    if imgui.BeginCombo('Combo', G(comboItems[comboCur])) then
        for i, item in ipairs(comboItems) do
            if imgui.Selectable(G(item), comboCur == i) then comboCur = i end
        end
        imgui.EndCombo()
    end
    if imgui.TreeNodeStr(G(':u1f4c1: TreeNode')) then
        imgui.Text(G(':u1f60e: обычный imgui.Text'))
        imgui.TreePop()
    end
    imgui.Spacing()
    imgui.TextDisabled('Поле ввода: смайлы видны прямо при наборе')
    emoji.inputText('##glyphinput', glyphBuf, { glyphs = true, hint = 'текст' })
    imgui.TextDisabled('в чат уйдёт: ' .. emoji.fromGlyphs(ffi.string(glyphBuf)))
end

local KILLS = {
    { 'Nick_Name', 24, 'Tony_Cruz' },
    { 'Alex_Ryder', 31, 'Nick_Name' },
    { 'Maria_Lopez', 34, 'Den_Brown' },
    { 'Den_Brown', 4, 'Alex_Ryder' },
    { 'Tony_Cruz', 38, 'Maria_Lopez' },
}

local function tabGame()
    imgui.TextDisabled('emoji.weapon(id): свой киллфид с иконками Arizona')
    for _, k in ipairs(KILLS) do
        local w = emoji.weapon(k[2])
        emoji.text(('{8FD3FF}%s  %s  {FF8080}%s'):format(k[1], w and w.token or '?', k[3]),
                   22, { color = true })
    end
    imgui.Spacing()
    imgui.TextDisabled('emoji.crown(1..10) и emoji.wings(1..10)')
    for n = 1, 10 do
        emoji.image(emoji.crown(n), 26)
        if n < 10 then imgui.SameLine() end
    end
    for n = 1, 10 do
        emoji.image(emoji.wings(n), 26)
        if n < 10 then imgui.SameLine() end
    end
    imgui.Spacing()
    imgui.TextDisabled('Новое в плагине: category(\'hidden_brands\')')
    for i, e in ipairs(emoji.category('hidden_brands') or {}) do
        emoji.image(e, 26)
        if i % 14 ~= 0 then imgui.SameLine() end
    end
    imgui.NewLine()
end

local function tabTelegram()
    imgui.TextDisabled('emoji.fromUnicode(): сообщения из Telegram/VK в игре')
    for _, msg in ipairs(INCOMING) do
        emoji.text('{AAAAAA}TG:{FFFFFF} ' .. emoji.fromUnicode(msg), 22, { color = true })
    end
    imgui.Spacing()
    imgui.TextDisabled('emoji.toUnicode(): обратно, из игры в Telegram')
    local line = 'Продал ' .. emoji.tok('trophy') .. ' ' .. emoji.tok('arz')
    emoji.text('{AAAAAA}игра:{FFFFFF} ' .. line, 22, { color = true })
    local out = emoji.toUnicode(line)
    imgui.TextDisabled(('в Telegram: %d байт UTF-8, иконка Arizona станет :arz:'):format(#out))
end

local function tabText()
    imgui.TextDisabled('richText: цвета сервера и переносы')
    emoji.richText('{FFFFFF}Аксессуар: {FDCF28}Часы ' .. emoji.tok('watch') ..
                   '{FFFFFF}\nВторая строка на месте, тегов не видно', 18)
    imgui.Separator()
    if emoji.textButton('Отправить ' .. emoji.tok('rocket'), { id = 'send', size = 18 }) then
        emoji.addChatMessage(cp('Кнопка нажата ') .. emoji.tok('rocket'))
    end
    imgui.SameLine()
    emoji.textButton('{FDCF28}Жёлтая ' .. emoji.tok('gem'), { id = 'yellow', size = 18, color = true })
    imgui.Separator()
    for i, name in ipairs({ 'smile', 'fire', 'gem' }) do
        if emoji.selectable(emoji.tok(name) .. ' строка списка ' .. i, selected == i,
                            { id = 'row' .. i, size = 18 }) then
            selected = i
        end
        if imgui.IsItemHovered() then
            emoji.tooltipText('{FDCF28}Подсказка ' .. emoji.tok(name) ..
                              '{FFFFFF}\nобычный SetTooltip так не умеет', { size = 16, color = true })
        end
    end
    imgui.Separator()
    emoji.inputText('Сообщение', plainBuf, { hint = 'токены, как в 3.1' })
    if imgui.Button('Отправить в чат') then
        emoji.sendChat(u8:decode(ffi.string(plainBuf)))
    end
end

imgui.OnFrame(function() return win[0] end, function()
    tickTour()
    local cond = tour.on and imgui.Cond.Always or imgui.Cond.FirstUseEver
    imgui.SetNextWindowPos(imgui.ImVec2(40, 120), cond)
    imgui.SetNextWindowSize(imgui.ImVec2(600, 470), cond)
    imgui.Begin(G(':u1f3a8: chat_emoji 3.2') .. '##showcase', win)

    if not ready then
        imgui.TextDisabled('load: ' .. tostring(loadError))
        imgui.End()
        return
    end

    if imgui.BeginTabBar('##tabs') then
        if tabItem('search', ':u1f50d: Поиск') then tabSearch() imgui.EndTabItem() end
        if tabItem('font', ':u1f524: Шрифт') then tabFont() imgui.EndTabItem() end
        if tabItem('game', ':u1f3ae: Игра') then tabGame() imgui.EndTabItem() end
        if tabItem('telegram', ':u1f4ac: Telegram') then tabTelegram() imgui.EndTabItem() end
        if tabItem('text', ':u270f: Текст') then tabText() imgui.EndTabItem() end
        imgui.EndTabBar()
    end

    local info = emoji.info()
    imgui.TextDisabled(('v%s, иконок %d, в шрифте %d, малый атлас: %s, текстура %s')
        :format(info.version, info.count, info.glyphs, info.small and 'да' or 'нет',
                info.shared and 'общая' or 'своя'))
    imgui.End()
end)

--------------------------------------------------------------------------
-- Поверх игры: HUD и метки в мире
--------------------------------------------------------------------------
imgui.OnFrame(function() return (hud[0] or tour.on) and ready end, function(self)
    self.HideCursor = true
    tickTour()
    if not hud[0] then return end

    -- ниже чата: верхние ~300 px экрана заняты им
    emoji.drawText(40, 340, '{FDCF28}HUD поверх игры ' .. emoji.tok('fire') ..
                            '{FFFFFF}\nокна тут нет', { size = 26, color = true })
    local w = emoji.weapon(getCurrentCharWeapon(PLAYER_PED))
    if w then
        emoji.drawText(40, 410, 'В руках: ' .. w.token, { size = 30 })
    end

    local x, y, z = getCharCoordinates(PLAYER_PED)
    emoji.draw3D(x, y, z + 1.1, emoji.tok('crown') .. ' это я', { size = 26 })
    emoji.draw3D(x + 4, y + 6, z, emoji.tok('moneybag') .. ' 6 метров', { size = 26 })
    emoji.draw3D(x - 8, y + 25, z, emoji.tok('trophy') .. ' 25 метров', { size = 26 })
end)

--------------------------------------------------------------------------
local FLAG = (os.getenv('TEMP') or getWorkingDirectory()) .. '\\chat_emoji_tour.flag'

function main()
    if type(isSampLoaded) == 'function' and isSampLoaded() then
        while not isSampAvailable() do wait(0) end
        sampRegisterChatCommand('emjnew', function() win[0] = not win[0] end)
        sampRegisterChatCommand('emjhud', function()
            hud[0] = not hud[0]
            say('HUD и метки в мире: ' .. (hud[0] and 'включены' or 'выключены'))
        end)
        sampRegisterChatCommand('emjtour', startTour)
        sampRegisterChatCommand('emjmsg', function()
            emoji.addChatMessage(cp('{FDCF28}Локальное сообщение ') .. emoji.tok('fire') ..
                                 cp('{FFFFFF} через addChatMessage'))
        end)
        sampRegisterChatCommand('emjtest', function()
            local info = emoji.info()
            say(('версия %s, иконок %d, в шрифте %d, малый атлас %s, плагин чата %s, сервер %s')
                :format(info.version, info.count, info.glyphs, tostring(info.small),
                        tostring(emoji.canRender()), tostring(emoji.serverSupports())))
            local ok, problems = emoji.selfTest()
            local real = 0
            for _, p in ipairs(problems) do if not p:find('^note:') then real = real + 1 end end
            say('самопроверка атласа: ' .. (real == 0 and 'без замечаний' or (real .. ' проблем')))
            local same, why = emoji.checkSource()
            say('_chat.asi: ' .. (same == true and 'атлас свежий' or tostring(why)))
        end)
        say('загружен. /emjnew /emjhud /emjtour /emjtest, F3 в чате')
    end

    -- F7-F9 в SA-MP заняты (чат, скриншот, килл-лист), там есть команды
    local singlePlayer = not (type(isSampLoaded) == 'function' and isSampLoaded())
    local lastFlagCheck = 0
    while true do
        wait(0)
        if singlePlayer then
            if isKeyJustPressed(vkeys.VK_F7) then win[0] = not win[0] end
            if isKeyJustPressed(vkeys.VK_F8) then hud[0] = not hud[0] end
            if isKeyJustPressed(vkeys.VK_F9) then startTour() end
        end
        if os.clock() - lastFlagCheck > 1 then
            lastFlagCheck = os.clock()
            if doesFileExist(FLAG) then
                os.remove(FLAG)
                startTour()
            end
        end
        if ready and sampOk() and sampIsChatInputActive()
           and isKeyJustPressed(vkeys.VK_F3) then
            local ok, why = emoji.insertToChatInput('fire')
            if not ok then say('вставка не удалась: ' .. tostring(why)) end
        end
    end
end
