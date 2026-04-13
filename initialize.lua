local initialize = {}

require("globals")
local osLib = require("os")

local function isSteamDeckHardware(currentOS)
    if currentOS == "SteamOS" then
        return true
    end

    local steamDeckEnv = osLib.getenv("SteamDeck")
    if steamDeckEnv == "1" or steamDeckEnv == "true" or steamDeckEnv == "TRUE" then
        return true
    end

    local steamDeckFlag = osLib.getenv("STEAM_DECK")
    if steamDeckFlag == "1" or steamDeckFlag == "true" or steamDeckFlag == "TRUE" then
        return true
    end

    return false
end

function initialize.enter(stateMachine)

    -- Detect the operating system
    local currentOS = love.system.getOS()
    local isSteamDeck = isSteamDeckHardware(currentOS)

    -- On mobile
    if currentOS == 'iOS' or currentOS == 'Android' then

        -- Fullscreen on mobile
        SETTINGS.DISPLAY.FULLSCREEN = true
        SETTINGS.DISPLAY.RESIZABLE = false
        SETTINGS.DISPLAY.BORDERLESS = true
    elseif isSteamDeck then
        SETTINGS.DISPLAY.FULLSCREEN = true
        SETTINGS.DISPLAY.RESIZABLE = false
        SETTINGS.DISPLAY.BORDERLESS = true
    -- On desktop
    else
        SETTINGS.DISPLAY.FULLSCREEN = false
        SETTINGS.DISPLAY.RESIZABLE = true
        SETTINGS.DISPLAY.BORDERLESS = false
    end

    -- Reduce logging overhead on Steam Deck hardware to improve frame pacing.
    if isSteamDeck then
        DEBUG.AI = false
        DEBUG.UI = false
        DEBUG.RENDER = false
        DEBUG.AUDIO = false
        local aiInfluence = require("ai_influence")
        if aiInfluence and aiInfluence.CONFIG then
            aiInfluence.CONFIG.DEBUG_ENABLED = false
            aiInfluence.CONFIG.DEBUG_SHOW_MAP = false
        end
    end

    -- Check DPI
    if love.graphics.getDPIScale() > 1 then
        SETTINGS.DISPLAY.HIGHDPI = true
    end

    -- Set the window mode
    love.window.setMode(SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT, {
        fullscreen = SETTINGS.DISPLAY.FULLSCREEN,
        resizable = SETTINGS.DISPLAY.RESIZABLE,
        borderless = SETTINGS.DISPLAY.BORDERLESS,
        vsync = SETTINGS.DISPLAY.VSYNC,
        display = SETTINGS.DISPLAY.DISPLAY,
        minwidth = SETTINGS.DISPLAY.MINWIDTH,
        minheight = SETTINGS.DISPLAY.MINHEIGHT,
        highdpi = SETTINGS.DISPLAY.HIGHDPI
    })

    love.graphics.setDefaultFilter("nearest", "nearest")

    -- Load custom font
    local success, customFont = pcall(love.graphics.newFont, "assets/fonts/monogram-extended.ttf", SETTINGS.FONT.DEFAULT_SIZE)
    if success then
        love.graphics.setFont(customFont)
    else
        -- If the custom font fails to load, fall back to the default font
    end

    stateMachine.changeState("mainMenu")
end

function initialize.update(dt)

end

function initialize.draw()
    love.graphics.clear(0, 0, 0, 0)
end

function initialize.exit()
    -- no-op
end

return  initialize
