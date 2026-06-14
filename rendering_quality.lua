local renderingQuality = {}

local DEFAULT_FILTER = { "nearest", "nearest" }
local APPLE_FILTER = DEFAULT_FILTER

local cachedOS = nil

local function currentOS()
    if cachedOS ~= nil then
        return cachedOS
    end

    if love and love.system and love.system.getOS then
        cachedOS = love.system.getOS()
    else
        cachedOS = false
    end

    return cachedOS
end

function renderingQuality.isApplePlatform(osName)
    osName = osName or currentOS()
    return osName == "iOS" or osName == "OS X"
end

function renderingQuality.prepareWindowSettings(osName)
    if renderingQuality.isApplePlatform(osName) then
        SETTINGS.DISPLAY.HIGHDPI = true
    end
end

function renderingQuality.configureGraphics(osName)
    local isApple = renderingQuality.isApplePlatform(osName)
    local filter = isApple and APPLE_FILTER or DEFAULT_FILTER

    if love.graphics.setDefaultFilter then
        local ok = pcall(love.graphics.setDefaultFilter, filter[1], filter[2], isApple and 4 or 1)
        if not ok then
            love.graphics.setDefaultFilter(filter[1], filter[2])
        end
    end

    if isApple and love.graphics.setLineStyle then
        love.graphics.setLineStyle("smooth")
    end
end

function renderingQuality.newFont(path, size)
    if path then
        local ok, font = pcall(love.graphics.newFont, path, size)
        if ok and font then
            return font
        end
    end

    return love.graphics.newFont(size)
end

function renderingQuality.fontCachePath(path)
    return path
end

function renderingQuality.applyCanvasFilter(canvas)
    if renderingQuality.isApplePlatform() and canvas and canvas.setFilter then
        canvas:setFilter("nearest", "nearest")
    end
end

function renderingQuality.roundToPhysicalPixel(value)
    local dpiScale = 1
    if love and love.graphics and love.graphics.getDPIScale then
        dpiScale = love.graphics.getDPIScale() or 1
    end

    if dpiScale <= 1 then
        return math.floor(value + 0.5)
    end

    return math.floor(value * dpiScale + 0.5) / dpiScale
end

return renderingQuality
