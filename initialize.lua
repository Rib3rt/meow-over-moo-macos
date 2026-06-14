local initialize = {}

require("globals")
local osLib = require("os")
local fontCache = require("fontCache")
local renderingQuality = require("rendering_quality")

local function isMobilePlatform(currentOS)
    return currentOS == "iOS" or currentOS == "Android"
end

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

local function applyWindowMode(currentOS, fullscreen)
    SETTINGS.DISPLAY.FULLSCREEN = fullscreen == true
    SETTINGS.DISPLAY.RESIZABLE = not SETTINGS.DISPLAY.FULLSCREEN and not isMobilePlatform(currentOS)
    SETTINGS.DISPLAY.BORDERLESS = SETTINGS.DISPLAY.FULLSCREEN

    return love.window.setMode(SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT, {
        fullscreen = SETTINGS.DISPLAY.FULLSCREEN,
        fullscreentype = SETTINGS.DISPLAY.FULLSCREEN_TYPE or "desktop",
        resizable = SETTINGS.DISPLAY.RESIZABLE,
        borderless = SETTINGS.DISPLAY.BORDERLESS,
        vsync = SETTINGS.DISPLAY.VSYNC,
        display = SETTINGS.DISPLAY.DISPLAY,
        minwidth = SETTINGS.DISPLAY.MINWIDTH,
        minheight = SETTINGS.DISPLAY.MINHEIGHT,
        highdpi = SETTINGS.DISPLAY.HIGHDPI
    })
end

local function applyPlatformStartupDisplayMode(currentOS, isSteamDeck)
    if isMobilePlatform(currentOS) or isSteamDeck or currentOS == "Linux" then
        return applyWindowMode(currentOS, true)
    end

    return applyWindowMode(currentOS, false)
end

function initialize.toggleDesktopDisplayMode(currentOS)
    currentOS = currentOS or (love and love.system and love.system.getOS and love.system.getOS()) or nil
    if isMobilePlatform(currentOS) then
        return false, "display_toggle_unsupported"
    end

    local nextFullscreen = not (SETTINGS.DISPLAY.FULLSCREEN == true)
    return applyWindowMode(currentOS, nextFullscreen)
end

function initialize.enter(stateMachine)

    -- Detect the operating system
    local currentOS = love.system.getOS()
    local isSteamDeck = isSteamDeckHardware(currentOS)
    renderingQuality.prepareWindowSettings(currentOS)

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
    if not renderingQuality.isApplePlatform(currentOS) and love.graphics.getDPIScale() > 1 then
        SETTINGS.DISPLAY.HIGHDPI = true
    end

    applyPlatformStartupDisplayMode(currentOS, isSteamDeck)

    renderingQuality.configureGraphics(currentOS)

    -- Load custom font
    local success, customFont = pcall(fontCache.get, "assets/fonts/monogram-extended.ttf", SETTINGS.FONT.DEFAULT_SIZE)
    if success then
        love.graphics.setFont(customFont)
    else
        -- If the custom font fails to load, fall back to the default font
    end

    local online = GAME and GAME.CURRENT and GAME.CURRENT.ONLINE or nil
    if online and online.pendingInviteJoinLobbyId then
        stateMachine.changeState("onlineLobby")
    else
        stateMachine.changeState("mainMenu")
    end
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
