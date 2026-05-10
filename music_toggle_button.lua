local musicToggleButton = {}

local audioRuntime = require("audio_runtime")
local soundCache = require("soundCache")

local ICON_ON_PATH = "assets/sprites/Icon_MusicOn.png"
local ICON_OFF_PATH = "assets/sprites/Icon_MusicOff.png"
local CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"

local imageOn = nil
local imageOff = nil
local loadAttempted = false
local hovered = false
local focused = false

local function clamp(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function audioSettings()
    SETTINGS = SETTINGS or {}
    SETTINGS.AUDIO = SETTINGS.AUDIO or {}
    return SETTINGS.AUDIO
end

local function loadImage(path)
    local ok, image = pcall(love.graphics.newImage, path)
    if ok and image then
        image:setFilter("nearest", "nearest")
        return image
    end
    return nil
end

local function loadImages()
    if loadAttempted then
        return
    end
    loadAttempted = true
    imageOn = loadImage(ICON_ON_PATH)
    imageOff = loadImage(ICON_OFF_PATH)
end

function musicToggleButton.isMusicEnabled()
    return audioSettings().MUSIC ~= false
end

function musicToggleButton.setMusicEnabled(enabled)
    local normalized = enabled ~= false
    audioSettings().MUSIC = normalized
    if audioRuntime and audioRuntime.setMusicEnabled then
        audioRuntime.setMusicEnabled(normalized)
    end
    return normalized
end

function musicToggleButton.toggle()
    local enabled = musicToggleButton.setMusicEnabled(not musicToggleButton.isMusicEnabled())
    if SETTINGS and SETTINGS.AUDIO and SETTINGS.AUDIO.SFX ~= false then
        soundCache.play(CLICK_SOUND_PATH, {
            clone = false,
            volume = SETTINGS.AUDIO.SFX_VOLUME or 0.4,
            category = "sfx"
        })
    end
    return enabled
end

function musicToggleButton.getBounds()
    local display = (SETTINGS and SETTINGS.DISPLAY) or {}
    local displayH = tonumber(display.HEIGHT) or 800
    local size = math.floor(clamp(displayH * 0.072, 52, 64))
    local margin = math.floor(clamp(displayH * 0.02, 14, 20))
    return {
        x = margin,
        y = displayH - size - margin,
        width = size,
        height = size
    }
end

function musicToggleButton.hitTest(x, y)
    local bounds = musicToggleButton.getBounds()
    return x >= bounds.x and x <= bounds.x + bounds.width
        and y >= bounds.y and y <= bounds.y + bounds.height
end

function musicToggleButton.mousemoved(x, y)
    hovered = musicToggleButton.hitTest(x, y)
    return hovered
end

function musicToggleButton.mousepressed(x, y, button)
    if button ~= 1 or not musicToggleButton.hitTest(x, y) then
        return false
    end
    hovered = true
    focused = true
    musicToggleButton.toggle()
    return true
end

function musicToggleButton.setFocused(value)
    focused = value == true
    return focused
end

function musicToggleButton.isFocused()
    return focused == true
end

local function drawFallbackIcon(bounds, enabled)
    local x, y = bounds.x, bounds.y
    local s = bounds.width
    local unit = math.max(2, math.floor(s / 16))
    local accent = enabled and {72 / 255, 150 / 255, 232 / 255, 1} or {236 / 255, 78 / 255, 68 / 255, 1}
    love.graphics.setColor(46 / 255, 38 / 255, 32 / 255, 0.96)
    love.graphics.rectangle("fill", x, y, s, s)
    love.graphics.setColor(accent)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x + unit, y + unit, s - unit * 2, s - unit * 2)
    love.graphics.setColor(203 / 255, 183 / 255, 158 / 255, enabled and 1 or 0.48)
    love.graphics.rectangle("fill", x + unit * 5, y + unit * 7, unit * 2, unit * 4)
    love.graphics.polygon(
        "fill",
        x + unit * 7, y + unit * 6,
        x + unit * 10, y + unit * 4,
        x + unit * 10, y + unit * 12,
        x + unit * 7, y + unit * 10
    )
    if enabled then
        love.graphics.setColor(accent)
        love.graphics.rectangle("fill", x + unit * 12, y + unit * 5, unit, unit * 6)
        love.graphics.rectangle("fill", x + unit * 14, y + unit * 4, unit, unit * 8)
    else
        love.graphics.setColor(accent)
        love.graphics.setLineWidth(unit * 2)
        love.graphics.line(x + unit * 11, y + unit * 4, x + unit * 15, y + unit * 12)
    end
    love.graphics.setLineWidth(1)
end

function musicToggleButton.draw()
    loadImages()

    local enabled = musicToggleButton.isMusicEnabled()
    local bounds = musicToggleButton.getBounds()
    local image = enabled and imageOn or imageOff

    if image then
        love.graphics.setColor(1, 1, 1, (hovered or focused) and 1 or 0.9)
        love.graphics.draw(
            image,
            bounds.x,
            bounds.y,
            0,
            bounds.width / image:getWidth(),
            bounds.height / image:getHeight()
        )
    else
        drawFallbackIcon(bounds, enabled)
    end

    if focused then
        love.graphics.setColor(0.52, 0.82, 1, 0.92)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", bounds.x - 2, bounds.y - 2, bounds.width + 4, bounds.height + 4)
        love.graphics.setLineWidth(1)
    end

    love.graphics.setColor(1, 1, 1, 1)
end

function musicToggleButton.resetHover()
    hovered = false
    focused = false
end

return musicToggleButton
