local menuBackground = {}
local uiTheme = require("uiTheme")

local BACKGROUND_PATH = "assets/sprites/MenuBackground.png"
local cachedImage = nil
local loadAttempted = false

local function loadImageOnce()
    if loadAttempted then
        return cachedImage
    end

    loadAttempted = true
    local ok, image = pcall(love.graphics.newImage, BACKGROUND_PATH)
    if ok and image then
        image:setFilter("linear", "linear")
        cachedImage = image
    else
        cachedImage = nil
    end

    return cachedImage
end

function menuBackground.getImage()
    return loadImageOnce()
end

function menuBackground.draw()
    local image = loadImageOnce()
    if not image then
        local fallback = ((uiTheme and uiTheme.COLORS) and uiTheme.COLORS.background) or {0.12, 0.11, 0.10, 1}
        love.graphics.setColor(fallback)
        love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
        return
    end

    local targetW = SETTINGS.DISPLAY.WIDTH
    local targetH = SETTINGS.DISPLAY.HEIGHT
    local imageW = image:getWidth()
    local imageH = image:getHeight()
    local scale = math.max(targetW / imageW, targetH / imageH)
    local drawW = imageW * scale
    local drawH = imageH * scale
    local drawX = (targetW - drawW) * 0.5
    local drawY = (targetH - drawH) * 0.5

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(image, drawX, drawY, 0, scale, scale)
end

return menuBackground
