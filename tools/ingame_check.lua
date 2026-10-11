-- ingame_check.lua - проверка chat_emoji в живой игре, для разработки.
--
-- Положить в moonloader\ рядом с библиотекой и запустить игру (можно
-- одиночную, без SA-MP). Скрипт сам:
--   * грузит атлас и смотрит, что получилось: размеры текстур, малый
--     атлас, общая ли текстура, свежий ли атлас для этого _chat.asi;
--   * вшивает смайлы в шрифт ImGui и меряет, сколько это заняло;
--   * перегружает текстуры в DXT5 и обратно;
--   * рисует окно, где одни и те же смайлы нарисованы текстурой и глифами
--     шрифта: цвета должны совпасть (если красный стал синим - поменять
--     emoji.GLYPH_SWAP_RB);
--   * пишет отчёт в moonloader\chat_emoji_check.txt.
--
-- F10 прячет и показывает окно.

script_name('chat_emoji check')
script_author('chat_emoji')

local imgui = require 'mimgui'
local emoji = require 'chat_emoji'
local ffi = require 'ffi'
local vkeys = require 'vkeys'

local show = imgui.new.bool(true)
local report = {}
local stage = 'init'
local frames = 0
local glyphsOk = false

local function log(fmt, ...)
    local line = select('#', ...) > 0 and fmt:format(...) or fmt
    report[#report + 1] = line
end

local function flush()
    local f = io.open(getWorkingDirectory() .. '\\chat_emoji_check.txt', 'w')
    if not f then return end
    f:write(table.concat(report, '\n'), '\n')
    f:close()
end

local function dumpInfo(title)
    local i = emoji.info()
    log('[%s] version=%s loaded=%s shared=%s small=%s format=%s glyphs=%d stale=%s',
        title, i.version, tostring(i.loaded), tostring(i.shared), tostring(i.small),
        tostring(i.format), i.glyphs, tostring(i.stale))
    if i.atlas then
        log('[%s] atlas %dx%d cell %d, real texture %sx%s', title, i.atlas.width,
            i.atlas.height, i.atlas.cell, tostring(i.atlas.texWidth or 'same'),
            tostring(i.atlas.texHeight or 'same'))
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    log('chat_emoji check, %s', os.date('%Y-%m-%d %H:%M:%S'))
    local t = os.clock()
    local ok, err = emoji.load()
    log('load: %s %s (%.1f ms)', tostring(ok), tostring(err or ''), (os.clock() - t) * 1000)
    dumpInfo('argb')

    t = os.clock()
    local gok, n = emoji.fontGlyphs()
    glyphsOk = gok
    log('fontGlyphs: %s %s (register %.1f ms)', tostring(gok), tostring(n), (os.clock() - t) * 1000)

    local same, why = emoji.checkSource()
    log('checkSource: %s %s', tostring(same), tostring(why or ''))

    local _, problems = emoji.selfTest()
    local real = {}
    for _, p in ipairs(problems) do
        if not p:find('^note:') then real[#real + 1] = p end
    end
    log('selfTest: %d problems%s', #real, #real > 0 and (': ' .. real[1]) or '')
    log('weapon(24)=%s crown(3)=%s find(огонь)[1]=%s',
        tostring(emoji.weapon(24) and emoji.weapon(24).name),
        tostring(emoji.crown(3) and emoji.crown(3).name),
        tostring(emoji.find('огонь', 1)[1] and emoji.find('огонь', 1)[1].name))
    flush()
end)

-- Пиксели глифов кладутся после всех OnInitialize: замеряем это отдельно.
imgui.OnInitialize(function()
    log('font atlas built: %s', tostring(imgui.GetIO().Fonts:IsBuilt()))
end)

local function row(label, tokens, size)
    imgui.TextDisabled(label)
    for i, tk in ipairs(tokens) do
        emoji.image(tk, size)
        imgui.SameLine()
    end
    imgui.NewLine()
end

local SAMPLE = { 'fire', '<3', 'gem', 'joy', 'arz', 'moneybag', 'trophy' }

imgui.OnFrame(function() return show[0] end, function()
    frames = frames + 1
    if frames == 3 and stage == 'init' then
        local fonts = imgui.GetIO().Fonts
        log('font atlas texture %dx%d', fonts.TexWidth, fonts.TexHeight)
        stage = 'argb'
        flush()
    elseif frames == 120 and stage == 'argb' then
        -- DXT5: перегружаем текстуры сжатыми
        emoji.unload()
        emoji.FORMAT = 'dxt5'
        local t = os.clock()
        local ok, err = emoji.load()
        log('reload as dxt5: %s %s (%.1f ms)', tostring(ok), tostring(err or ''),
            (os.clock() - t) * 1000)
        dumpInfo('dxt5')
        stage = 'dxt5'
        flush()
    elseif frames == 240 and stage == 'dxt5' then
        emoji.unload()
        emoji.FORMAT = 'argb'
        local ok = emoji.load()
        log('back to argb: %s', tostring(ok))
        dumpInfo('argb2')
        stage = 'done'
        log('done after %d frames', frames)
        flush()
    end

    imgui.SetNextWindowPos(imgui.ImVec2(680, 120), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(520, 470), imgui.Cond.Always)
    imgui.Begin('chat_emoji check##check', show)
    imgui.Text(('stage: %s, format: %s, small: %s'):format(stage, emoji.FORMAT,
               tostring(emoji.textureSmall ~= nil)))
    row('texture, 40 px (big atlas)', SAMPLE, 40)
    row('texture, 20 px (small atlas)', SAMPLE, 20)
    row('texture, 16 px (small atlas)', SAMPLE, 16)
    emoji.SMALL_BELOW = 0
    row('texture, 16 px (big atlas, for comparison)', SAMPLE, 16)
    emoji.SMALL_BELOW = 20
    imgui.TextDisabled('font glyphs (same icons, colours must match):')
    if glyphsOk then
        local s = ''
        for _, n in ipairs(SAMPLE) do s = s .. emoji.glyph(n) .. ' ' end
        imgui.Text(s)
        imgui.Button(emoji.toGlyphs(':u1f3c6: Button'))
        imgui.SameLine()
        imgui.TextDisabled(emoji.toGlyphs('TextDisabled :u1f525:'))
    else
        imgui.Text('fontGlyphs failed')
    end
    emoji.text('emoji.text: hello :u1f603: {FF4040}red :u2764:', 22, { color = true })
    imgui.Text(('wide: %s'):format(emoji.get('vip') and 'vip' or '-'))
    for _, e in ipairs(emoji.category('hidden_ribbons') or {}) do
        if e.cells >= 3 then
            emoji.image(e, 22)
            break
        end
    end
    imgui.End()
end)

function main()
    while true do
        wait(0)
        if isKeyJustPressed(vkeys.VK_F10) then show[0] = not show[0] end
    end
end
