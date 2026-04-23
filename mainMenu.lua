local mainMenu = {}

local stateMachineRef = nil
--------------------------------------------------
-- DECLARE LOCAL VARIABLES AND FUNCTIONS BELOW
--------------------------------------------------
local ConfirmDialog = require("confirmDialog")
local os = require("os")
local uiTheme = require("uiTheme")
local menuBackground = require("menu_background")
local soundCache = require("soundCache")
local steamRuntime = require("steam_runtime")
local resumeStore = require("resume_store")
local Controller = require("controller")
local fontCache = require("fontCache")

local MONOGRAM_FONT_PATH = "assets/fonts/monogram-extended.ttf"

local function getMonogramFont(size)
    return fontCache.get(MONOGRAM_FONT_PATH, size)
end

--------------------------------------------------
-- Variables (Local to this module)
--------------------------------------------------
local uiButtons = nil
local selectedButtonIndex = 1  -- Track selected button index for keyboard/controller navigation.
local buttonOrder = {}  -- Array to store button references in navigation order
local navigationMode = "keyboard" -- "keyboard" or "mouse" for highlight logic
local pendingRemotePlayActivePrompt = false
local selectEnabledButton
local ensureValidButtonSelection
local triggerSelectedButton
local menuLayout = nil
local logoImage = nil
local logoLoadAttempted = false
local logoAnimation = {
    time = 0,
    introElapsed = 0,
    introDuration = 0.55
}

-- Match the UI colors with the faction select and gameplay screens
local UI_COLORS = uiTheme.COLORS
local DISABLED_BUTTON_COLOR = uiTheme.BUTTON_VARIANTS.disabled.base
local SCENARIO_FEATURE_ENABLED = SETTINGS and SETTINGS.FEATURES and SETTINGS.FEATURES.SCENARIO_MODE == true

--------------------------------------------------
-- Functions (Local to this module)
--------------------------------------------------
local function initializeRandomSeed()
    -- Use centralized random generator
    local randomGen = require('randomGenerator')
    randomGen.initialize()

    -- Store seed for compatibility
    GAME.CURRENT.SEED = randomGen.getSeed()
end

-- Helper function to check if the mouse is over an object
local function isMouseOverButton(button, x, y)
    return (x >= button.x and x <= button.x + button.width) and
           (y >= button.y and y <= button.y + button.height)
end

-- Draw a tech-styled button
local BUTTON_BEEP_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"

local function initAudio()
    soundCache.get(BUTTON_BEEP_SOUND_PATH)
    soundCache.get(BUTTON_CLICK_SOUND_PATH)
end

local function playHoverSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_BEEP_SOUND_PATH, { clone = false, volume = SETTINGS.AUDIO.SFX_VOLUME, category = "sfx" })
end

local function playClickSound()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_CLICK_SOUND_PATH, { clone = false, volume = SETTINGS.AUDIO.SFX_VOLUME, category = "sfx" })
end

local function drawButton(button)
    uiTheme.drawButton(button)
end

local function drawTitle(text, x, y, width)
    uiTheme.drawTitle(text, x, y, width)
end

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function loadLogoImageOnce()
    if logoLoadAttempted then
        return logoImage
    end

    logoLoadAttempted = true
    local ok, image = pcall(love.graphics.newImage, "assets/sprites/Logo.png")
    if ok and image then
        image:setFilter("linear", "linear")
        logoImage = image
    else
        logoImage = nil
    end
    return logoImage
end

local function computeMainMenuLayout(buttonCount)
    local displayW = SETTINGS.DISPLAY.WIDTH
    local displayH = SETTINGS.DISPLAY.HEIGHT

    local contentTop = math.floor(displayH * 0.04)
    local footerY = displayH - 50
    local contentBottom = footerY - 24
    local contentHeight = contentBottom - contentTop

    local buttonHeight = math.floor(clamp(displayH * 0.07, 54, 60))
    local buttonGap = math.floor(clamp(displayH * 0.014, 10, 14))
    local buttonWidth = math.floor(clamp(displayW * 0.245, 240, 320))
    local buttonFontSize = math.floor(clamp(displayH * 0.033, 22, 28))
    local footerFontSize = math.floor(clamp(displayH * 0.022, 16, 20))
    local sectionGap = math.max(20, math.floor(displayH * 0.025))
    local buttonBlockHeight = (buttonCount * buttonHeight) + (math.max(0, buttonCount - 1) * buttonGap)

    local logoAspect = 16 / 9
    local image = loadLogoImageOnce()
    if image then
        logoAspect = image:getWidth() / math.max(1, image:getHeight())
    end

    local minLogoHeight = math.floor(displayH * 0.24)
    local maxLogoHeight = math.floor(displayH * 0.50)
    local logoHeight = clamp(contentHeight - buttonBlockHeight - sectionGap, minLogoHeight, maxLogoHeight)
    local minLogoWidth = math.floor(displayW * 0.36)
    local maxLogoWidth = math.floor(displayW * 0.78)
    local logoWidth = clamp(math.floor(logoHeight * logoAspect + 0.5), minLogoWidth, maxLogoWidth)
    logoHeight = math.floor(logoWidth / logoAspect + 0.5)

    local usedHeight = logoHeight + sectionGap + buttonBlockHeight
    if usedHeight > contentHeight then
        local fallbackLogoHeight = math.floor(contentHeight - buttonBlockHeight - sectionGap)
        logoHeight = clamp(fallbackLogoHeight, math.floor(displayH * 0.17), maxLogoHeight)
        logoWidth = clamp(math.floor(logoHeight * logoAspect + 0.5), minLogoWidth, maxLogoWidth)
        logoHeight = math.floor(logoWidth / logoAspect + 0.5)
        usedHeight = logoHeight + sectionGap + buttonBlockHeight
    end

    local verticalOffset = math.floor((contentHeight - usedHeight) / 2)
    if verticalOffset < 0 then
        verticalOffset = 0
    end

    local logoX = math.floor((displayW - logoWidth) / 2)
    local logoY = contentTop + verticalOffset
    local buttonX = math.floor((displayW - buttonWidth) / 2)
    local buttonStartY = logoY + logoHeight + sectionGap

    return {
        logoX = logoX,
        logoY = logoY,
        logoWidth = logoWidth,
        logoHeight = logoHeight,
        buttonX = buttonX,
        buttonY = buttonStartY,
        buttonWidth = buttonWidth,
        buttonHeight = buttonHeight,
        buttonGap = buttonGap,
        buttonFontSize = buttonFontSize,
        footerFontSize = footerFontSize
    }
end

local function isButtonEnabled(button)
    return button and button.enabled ~= false
end

local function getButtonBaseColor(button)
    if isButtonEnabled(button) then
        return UI_COLORS.button
    end
    return DISABLED_BUTTON_COLOR
end

local function getButtonHoverColor(button)
    if isButtonEnabled(button) then
        return button.hoverColor or UI_COLORS.buttonHover
    end
    return DISABLED_BUTTON_COLOR
end

local function getButtonIdentity(button)
    if not button then
        return nil
    end
    return button.id or button.text
end

local function findHoveredButton(x, y)
    for index, button in ipairs(buttonOrder) do
        if isMouseOverButton(button, x, y) then
            return button, index
        end
    end
    return nil, nil
end

local function updateOnlineButtonAvailability()
    if not uiButtons then
        return
    end

    local remotePlaySessions = 0
    if steamRuntime.isOnlineReady() == true and type(steamRuntime.getRemotePlaySessionCount) == "function" then
        remotePlaySessions = math.max(0, tonumber(steamRuntime.getRemotePlaySessionCount()) or 0)
    end
    local remotePlayActive = remotePlaySessions >= 1
    local onlineReady = steamRuntime.isOnlineReady() == true
    if uiButtons.playOnline then
        uiButtons.playOnline.enabled = onlineReady and not remotePlayActive
        uiButtons.playOnline.disabledReason = remotePlayActive and "remote_play_active" or nil
    end
    if uiButtons.playLeaderboard then
        uiButtons.playLeaderboard.enabled = onlineReady
    end
    if #buttonOrder > 0 then
        ensureValidButtonSelection()
    end
end

local function hasActiveRemotePlaySession()
    if steamRuntime.isOnlineReady() ~= true then
        return false
    end
    if type(steamRuntime.getRemotePlaySessionCount) ~= "function" then
        return false
    end
    local count = math.max(0, tonumber(steamRuntime.getRemotePlaySessionCount()) or 0)
    return count >= 1
end

local function showRemotePlayActivePrompt()
    ConfirmDialog.showMessage(
        "Remote Play session is still active. End session from Steam Overlay.",
        function() end,
        {
            title = "Remote Play Active",
            confirmText = "OK"
        }
    )
end

local function consumeRemotePlayExitPrompt()
    if not GAME or not GAME.CURRENT or GAME.CURRENT.REMOTE_PLAY_EXIT_PROMPT_PENDING ~= true then
        return false
    end
    GAME.CURRENT.REMOTE_PLAY_EXIT_PROMPT_PENDING = false
    return true
end

local function consumeMainMenuOneShotNotice()
    if not GAME or not GAME.CURRENT or type(GAME.CURRENT.MAIN_MENU_ONE_SHOT_NOTICE) ~= "table" then
        return nil
    end
    local notice = GAME.CURRENT.MAIN_MENU_ONE_SHOT_NOTICE
    GAME.CURRENT.MAIN_MENU_ONE_SHOT_NOTICE = nil
    return notice
end

local function resetOnlineRuntimeForLocalModes()
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    local online = GAME.CURRENT.ONLINE
    online.active = false
    online.role = nil
    online.factionRole = nil
    online.session = nil
    online.lockstep = nil
    online.autoJoinLobbyId = nil
    online.pendingLobbyEvents = {}
end

local function startNewModeFlow(mode, localVariant)
    if not stateMachineRef then
        return
    end

    GAME.CURRENT.MODE = mode
    GAME.CURRENT.LOCAL_MATCH_VARIANT = localVariant or "couch"
    GAME.CURRENT.SCENARIO = nil
    GAME.CURRENT.SCENARIO_REQUESTED_MODE = nil
    GAME.CURRENT.PENDING_RESUME_SNAPSHOT = nil
    GAME.CURRENT.RESUME_RESTART_NOTICE = nil
    resetOnlineRuntimeForLocalModes()
    stateMachineRef.changeState("factionSelect")
end

local function showResumeUnavailableAndStartNew(mode, reason)
    local message = "Saved game could not be restored. A new game will start."
    local details = tostring(reason or "")
    if details ~= "" then
        print("[Resume] unavailable reason: " .. details)
    end

    ConfirmDialog.showMessage(
        message,
        function()
            startNewModeFlow(mode)
        end,
        {
            title = "Resume Unavailable",
            confirmText = "OK"
        }
    )
end

local function buildControllerFromSerialized(serialized, fallbackId)
    if type(serialized) ~= "table" then
        return nil
    end

    local controllerId = serialized.id or fallbackId
    if not controllerId or tostring(controllerId) == "" then
        return nil
    end

    return Controller.new({
        id = tostring(controllerId),
        nickname = tostring(serialized.nickname or "Player"),
        type = tostring(serialized.type or Controller.TYPES.HUMAN),
        isLocal = serialized.isLocal ~= false,
        metadata = type(serialized.metadata) == "table" and serialized.metadata or {}
    })
end

local function applyResumeEnvelope(envelope)
    if type(envelope) ~= "table" then
        return false
    end

    local serializedControllers = envelope.controllers
    if type(serializedControllers) ~= "table" then
        return false
    end

    local controllers = {}
    for controllerId, serialized in pairs(serializedControllers) do
        local controller = buildControllerFromSerialized(serialized, controllerId)
        if controller then
            controllers[controller.id] = controller
        end
    end

    if next(controllers) == nil then
        return false
    end

    GAME.setControllers(controllers)

    local sequence = {}
    for _, controllerId in ipairs(envelope.controllerSequence or {}) do
        controllerId = tostring(controllerId)
        if controllers[controllerId] then
            sequence[#sequence + 1] = controllerId
        end
    end

    if #sequence == 0 then
        for controllerId, _ in pairs(controllers) do
            sequence[#sequence + 1] = controllerId
        end
        table.sort(sequence)
    end

    GAME.setControllerSequence(sequence)

    local assignments = envelope.factionAssignments or {}
    local faction1Id = assignments[1] or assignments["1"] or sequence[1]
    local faction2Id = assignments[2] or assignments["2"] or sequence[2] or faction1Id

    if not controllers[faction1Id] or not controllers[faction2Id] then
        return false
    end

    GAME.assignControllerToFaction(faction1Id, 1)
    GAME.assignControllerToFaction(faction2Id, 2)

    if envelope.seed then
        GAME.CURRENT.SEED = tonumber(envelope.seed) or GAME.CURRENT.SEED
    end

    return true
end

local function continueModeFromResume(mode)
    local envelope, loadReason = resumeStore.load()
    if not envelope or tostring(envelope.mode) ~= tostring(mode) or type(envelope.snapshot) ~= "table" then
        resumeStore.clear("invalid_resume_envelope")
        showResumeUnavailableAndStartNew(mode, loadReason or "invalid_resume_envelope")
        return
    end

    if not applyResumeEnvelope(envelope) then
        resumeStore.clear("invalid_resume_envelope")
        showResumeUnavailableAndStartNew(mode, "invalid_controller_or_assignment_state")
        return
    end

    if not stateMachineRef then
        return
    end

    GAME.CURRENT.MODE = mode
    GAME.CURRENT.LOCAL_MATCH_VARIANT = "couch"
    GAME.CURRENT.SCENARIO = nil
    GAME.CURRENT.SCENARIO_REQUESTED_MODE = nil
    GAME.CURRENT.PENDING_RESUME_SNAPSHOT = envelope.snapshot
    resetOnlineRuntimeForLocalModes()
    stateMachineRef.changeState("gameplay")
end

local function startModeWithResumePrompt(mode)
    if not stateMachineRef then
        return
    end

    if not resumeStore.hasMatchingMode(mode) then
        startNewModeFlow(mode)
        return
    end

    ConfirmDialog.show(
        "Continue your last unfinished match?",
        function()
            continueModeFromResume(mode)
        end,
        function()
            resumeStore.clear("new_game_selected")
            startNewModeFlow(mode)
        end,
        {
            title = "Resume Match",
            confirmText = "Continue",
            cancelText = "New Game",
            defaultFocus = "confirm"
        }
    )
end

local function startLocalMultiplayerFromMenu()
    if hasActiveRemotePlaySession() then
        resumeStore.clear("remote_play_overlay_session")
        GAME.CURRENT.PENDING_RESUME_SNAPSHOT = nil
        GAME.CURRENT.RESUME_RESTART_NOTICE = nil
        startNewModeFlow(GAME.MODE.MULTYPLAYER_LOCAL, "remote_play")
        return
    end

    startModeWithResumePrompt(GAME.MODE.MULTYPLAYER_LOCAL)
end

local function startScenarioModeFromMenu()
    if not stateMachineRef then
        return
    end
    stateMachineRef.changeState("scenarioSelect")
end

-- Add this function to update visual state of buttons based on keyboard selection
local function updateButtonSelection()
    -- Reset all button colors first
    for i, button in ipairs(buttonOrder) do
        local variant = isButtonEnabled(button) and "default" or "disabled"
        uiTheme.applyButtonVariant(button, variant)
        button.disabledVisual = not isButtonEnabled(button)
        button.focused = navigationMode == "keyboard" and i == selectedButtonIndex and isButtonEnabled(button)
        button.currentColor = button.focused and getButtonHoverColor(button) or getButtonBaseColor(button)
    end
end

selectEnabledButton = function(startIndex, delta)
    if #buttonOrder == 0 then
        return nil
    end

    local index = startIndex
    for _ = 1, #buttonOrder do
        if index < 1 then
            index = #buttonOrder
        elseif index > #buttonOrder then
            index = 1
        end
        if isButtonEnabled(buttonOrder[index]) then
            return index
        end
        index = index + delta
    end

    return nil
end

ensureValidButtonSelection = function()
    local resolved = selectEnabledButton(selectedButtonIndex, 1) or selectEnabledButton(1, 1)
    if resolved then
        selectedButtonIndex = resolved
    end
end

--------------------------------------------
-- LOVE LOAD FUNCTION
--------------------------------------------
function mainMenu.enter(stateMachine)
    stateMachineRef = stateMachine
    pendingRemotePlayActivePrompt = false
    local pendingMainMenuNotice = nil
    logoAnimation.time = 0
    logoAnimation.introElapsed = 0

    local buttonBlueprints = {}
    if SCENARIO_FEATURE_ENABLED then
        buttonBlueprints[#buttonBlueprints + 1] = { id = "playScenario", text = "Play Scenario", enabled = true }
    end
    buttonBlueprints[#buttonBlueprints + 1] = { id = "playSingle", text = "Single Player", enabled = true }
    buttonBlueprints[#buttonBlueprints + 1] = { id = "playLocal", text = "Local Multiplayer", enabled = true }
    buttonBlueprints[#buttonBlueprints + 1] = { id = "playOnline", text = "Online Multiplayer", enabled = false }
    buttonBlueprints[#buttonBlueprints + 1] = { id = "playLeaderboard", text = "Leaderboard", enabled = false }
    buttonBlueprints[#buttonBlueprints + 1] = { id = "quit", text = "Quit", enabled = true }

    menuLayout = computeMainMenuLayout(#buttonBlueprints)
    loadLogoImageOnce()

    local function createButton(definition, index)
        local y = menuLayout.buttonY + ((index - 1) * (menuLayout.buttonHeight + menuLayout.buttonGap))
        return {
            id = definition.id,
            x = menuLayout.buttonX,
            y = y,
            width = menuLayout.buttonWidth,
            height = menuLayout.buttonHeight,
            text = definition.text,
            enabled = definition.enabled ~= false,
            currentColor = UI_COLORS.button,
            hoverColor = UI_COLORS.buttonHover,
            pressedColor = UI_COLORS.buttonPressed,
            centerText = true
        }
    end

    uiButtons = {}
    for index, definition in ipairs(buttonBlueprints) do
        uiButtons[definition.id] = createButton(definition, index)
    end

    initializeRandomSeed()

    -- Initialize button order for keyboard navigation
    buttonOrder = {}
    if uiButtons.playScenario then
        buttonOrder[#buttonOrder + 1] = uiButtons.playScenario
    end
    buttonOrder[#buttonOrder + 1] = uiButtons.playSingle
    buttonOrder[#buttonOrder + 1] = uiButtons.playLocal
    buttonOrder[#buttonOrder + 1] = uiButtons.playOnline
    buttonOrder[#buttonOrder + 1] = uiButtons.playLeaderboard
    buttonOrder[#buttonOrder + 1] = uiButtons.quit
    navigationMode = "keyboard"

    updateOnlineButtonAvailability()
    
    -- Set initial selected button
    selectedButtonIndex = 1
    ensureValidButtonSelection()
    updateButtonSelection()

    -- Automatically position the cursor over the first menu button
    local initialButton = buttonOrder[1] or uiButtons.playSingle
    local buttonCenterX = (initialButton.x + initialButton.width / 2) * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETX
    local buttonCenterY = (initialButton.y + initialButton.height / 2) * SETTINGS.DISPLAY.SCALE + SETTINGS.DISPLAY.OFFSETY
    love.mouse.setPosition(buttonCenterX, buttonCenterY)

    -- Trigger the mousemoved handler to update hover state
    mainMenu.mousemoved(buttonCenterX, buttonCenterY, 0, 0, false)

    local resumeNotice = GAME.CURRENT and GAME.CURRENT.RESUME_RESTART_NOTICE or nil
    if type(resumeNotice) == "table" then
        GAME.CURRENT.RESUME_RESTART_NOTICE = nil
        local mode = resumeNotice.mode
        if mode == GAME.MODE.SINGLE_PLAYER or mode == GAME.MODE.MULTYPLAYER_LOCAL then
            showResumeUnavailableAndStartNew(mode, resumeNotice.reason)
        end
    end

    if consumeRemotePlayExitPrompt() then
        pendingRemotePlayActivePrompt = true
    end
    if pendingRemotePlayActivePrompt and not ConfirmDialog.isActive() then
        showRemotePlayActivePrompt()
        pendingRemotePlayActivePrompt = false
    end

    pendingMainMenuNotice = consumeMainMenuOneShotNotice()
    if pendingMainMenuNotice and not ConfirmDialog.isActive() then
        ConfirmDialog.showMessage(
            tostring(pendingMainMenuNotice.message or ""),
            function() end,
            {
                title = tostring(pendingMainMenuNotice.title or "Notice"),
                confirmText = "OK"
            }
        )
    elseif pendingMainMenuNotice then
        GAME.CURRENT.MAIN_MENU_ONE_SHOT_NOTICE = pendingMainMenuNotice
    end

end

-------------------------------------------
-- LOVE UPDATE FUNCTION
-------------------------------------------
function mainMenu.update(dt)
    logoAnimation.time = logoAnimation.time + dt
    if logoAnimation.introElapsed < logoAnimation.introDuration then
        logoAnimation.introElapsed = math.min(logoAnimation.introDuration, logoAnimation.introElapsed + dt)
    end

    local wasOnlineEnabled = nil
    if uiButtons and uiButtons.playOnline then
        wasOnlineEnabled = uiButtons.playOnline.enabled
    end

    updateOnlineButtonAvailability()
    if uiButtons and uiButtons.playOnline and wasOnlineEnabled ~= uiButtons.playOnline.enabled then
        updateButtonSelection()
    end

    if pendingRemotePlayActivePrompt and not ConfirmDialog.isActive() then
        showRemotePlayActivePrompt()
        pendingRemotePlayActivePrompt = false
    end

    local pendingMainMenuNotice = consumeMainMenuOneShotNotice()
    if pendingMainMenuNotice and not ConfirmDialog.isActive() then
        ConfirmDialog.showMessage(
            tostring(pendingMainMenuNotice.message or ""),
            function() end,
            {
                title = tostring(pendingMainMenuNotice.title or "Notice"),
                confirmText = "OK"
            }
        )
    elseif pendingMainMenuNotice then
        GAME.CURRENT.MAIN_MENU_ONE_SHOT_NOTICE = pendingMainMenuNotice
    end
    -------------------------------------------
    -- Code from here
    -------------------------------------------

    -- Example to check if a key is held down
    if love.keyboard.isDown("w") then end

    if love.keyboard.isDown("a") then end

    if love.keyboard.isDown("s") then end

    if love.keyboard.isDown("d") then end

    if love.keyboard.isDown("space") then end

end

-------------------------------------------
-- LOVE DRAW FUNCTION
-------------------------------------------
function mainMenu.draw()
    love.graphics.push()
    love.graphics.translate(SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY)
    love.graphics.scale(SETTINGS.DISPLAY.SCALE)
    local previousFont = love.graphics.getFont()

    menuBackground.draw()

    local currentLayout = menuLayout or computeMainMenuLayout(#buttonOrder)
    local logo = loadLogoImageOnce()
    if logo then
        local introProgress = clamp(logoAnimation.introElapsed / math.max(0.001, logoAnimation.introDuration), 0, 1)
        local introEase = 1 - ((1 - introProgress) * (1 - introProgress) * (1 - introProgress))
        local introOffsetY = (1 - introEase) * 22

        local floatOffsetY = math.sin(logoAnimation.time * 1.35) * 4.0
        local breatheScale = 1 + (math.sin(logoAnimation.time * 0.9) * 0.018)

        local targetLogoW = currentLayout.logoWidth * breatheScale
        local targetLogoH = currentLayout.logoHeight * breatheScale
        local logoX = currentLayout.logoX - ((targetLogoW - currentLayout.logoWidth) * 0.5)
        local logoY = currentLayout.logoY + introOffsetY + floatOffsetY - ((targetLogoH - currentLayout.logoHeight) * 0.5)

        local logoScaleX = targetLogoW / logo:getWidth()
        local logoScaleY = targetLogoH / logo:getHeight()
        local shadowAlpha = (0.24 + (math.sin(logoAnimation.time * 1.1) * 0.06)) * introEase
        local logoAlpha = introEase

        love.graphics.setColor(0, 0, 0, shadowAlpha)
        love.graphics.draw(logo, logoX + 3, logoY + 5, 0, logoScaleX, logoScaleY)
        love.graphics.setColor(1, 1, 1, logoAlpha)
        love.graphics.draw(logo, logoX, logoY, 0, logoScaleX, logoScaleY)
    else
        drawTitle("MEOW OVER MOO!", 0, 56, SETTINGS.DISPLAY.WIDTH)
    end

    if uiButtons then
        love.graphics.setFont(getMonogramFont(currentLayout.buttonFontSize))
        for _, button in ipairs(buttonOrder) do
            drawButton(button)
        end

        local footerText = "Copyright Flipped Cat - Version " .. tostring(VERSION)
        if PLATFORM_BUILD_LABEL and PLATFORM_BUILD_LABEL ~= "" then
            footerText = footerText .. " - " .. tostring(PLATFORM_BUILD_LABEL)
        end
        local footerFont = getMonogramFont(currentLayout.footerFontSize)
        local footerY = SETTINGS.DISPLAY.HEIGHT - footerFont:getHeight() - 14
        local footerMarginRight = 18
        local footerX = SETTINGS.DISPLAY.WIDTH - footerFont:getWidth(footerText) - footerMarginRight
        if footerX < 12 then
            footerX = 12
        end
        love.graphics.setFont(footerFont)
        love.graphics.setColor(0, 0, 0, 0.56)
        love.graphics.print(footerText, footerX + 1, footerY + 1)
        love.graphics.setColor(0.97, 0.95, 0.90, 0.9)
        love.graphics.print(footerText, footerX, footerY)
    end

    love.graphics.setLineWidth(1)

    love.graphics.setFont(previousFont)

    if ConfirmDialog and ConfirmDialog.draw then
        ConfirmDialog.draw()
    end

    love.graphics.pop()
end

-----------------------------------------------
-- EXIT FROM THIS MODULE, CLEAN UP EVERYTHING
-----------------------------------------------
function mainMenu.exit()
    stateMachineRef = nil
    pendingRemotePlayActivePrompt = false
    love.graphics.setColor(1, 1, 1) -- Reset color
    -------------------------------------------
    -- Code from here
    -------------------------------------------
    uiButtons = nil
    collectgarbage("collect")
end

-------------------------------------------
-- INPUT HANDLERS
-------------------------------------------

function mainMenu.mousemoved(x, y, dx, dy, istouch)
    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        ConfirmDialog.mousemoved(x, y)
        return -- Return early to prevent underlying screen from processing mouse movement
    end

    local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    if not uiButtons then
        return
    end

    navigationMode = "mouse"

    -- Track previous hover state for sound (before resetting colors)
    local previousHover = nil
    for _, candidate in ipairs(buttonOrder) do
        if isButtonEnabled(candidate) and candidate.currentColor == (candidate.hoverColor or UI_COLORS.buttonHover) then
            previousHover = getButtonIdentity(candidate)
            break
        end
    end

    for _, candidate in ipairs(buttonOrder) do
        candidate.currentColor = getButtonBaseColor(candidate)
    end

    local currentHover = nil
    local hoveredButton, hoveredIndex = findHoveredButton(transformedX, transformedY)
    if hoveredButton then
        selectedButtonIndex = hoveredIndex
        if isButtonEnabled(hoveredButton) then
            hoveredButton.currentColor = getButtonHoverColor(hoveredButton)
            currentHover = getButtonIdentity(hoveredButton)
        end
    else
        -- If mouse isn't over any button, maintain keyboard selection highlight only when in keyboard mode
        updateButtonSelection()
    end

    -- Play navigation sound only when hover state changes (not continuously)
    if previousHover ~= currentHover and currentHover ~= nil then
        playHoverSound()
    end
end

function mainMenu.mousepressed(x, y, button, istouch, presses)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousepressed(x, y, button)
    end

    if button == 1 then
        local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
        local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

        local buttons = uiButtons
        if not buttons then
            return
        end

        local hoveredButton = findHoveredButton(transformedX, transformedY)
        if hoveredButton then
            triggerSelectedButton(hoveredButton)
            return
        end

        for _, candidate in ipairs(buttonOrder) do
            candidate.currentColor = getButtonBaseColor(candidate)
        end
    end
end

function mainMenu.mousereleased(x, y, button, istouch, presses)
    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousereleased(x, y, button)
    end

    local transformedX = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local transformedY = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    local buttons = uiButtons
    if not buttons then
        return
    end

    local hoveredButton = findHoveredButton(transformedX, transformedY)
    if hoveredButton and isButtonEnabled(hoveredButton) then
        hoveredButton.currentColor = getButtonHoverColor(hoveredButton)
    end
end

triggerSelectedButton = function(selectedButton)
    if not selectedButton or not uiButtons then
        return false
    end

    local buttons = uiButtons

    if selectedButton == buttons.playOnline and not isButtonEnabled(buttons.playOnline) then
        if hasActiveRemotePlaySession() then
            showRemotePlayActivePrompt()
        end
        return true
    end

    if selectedButton == buttons.playLeaderboard and not isButtonEnabled(buttons.playLeaderboard) then
        return true
    end

    if not isButtonEnabled(selectedButton) then
        return true
    end

    playClickSound()
    selectedButton.currentColor = getButtonHoverColor(selectedButton)

    if buttons.playScenario and selectedButton == buttons.playScenario then
        startScenarioModeFromMenu()
    elseif selectedButton == buttons.playLocal then
        if stateMachineRef then
            startLocalMultiplayerFromMenu()
        end
    elseif selectedButton == buttons.playOnline then
        if stateMachineRef then
            GAME.CURRENT.MODE = GAME.MODE.MULTYPLAYER_NET
            stateMachineRef.changeState("onlineLobby")
        end
    elseif selectedButton == buttons.playLeaderboard then
        if stateMachineRef then
            stateMachineRef.changeState("onlineLeaderboard")
        end
    elseif selectedButton == buttons.playSingle then
        startModeWithResumePrompt(GAME.MODE.SINGLE_PLAYER)
    elseif selectedButton == buttons.quit then
        ConfirmDialog.show(
            "Quit the game?",
            function()
                love.event.quit()
            end,
            function() end
        )
    end

    return true
end

function mainMenu.keypressed(key, scancode, isrepeat)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.keypressed(key)
    end

    if not uiButtons then
        return
    end

    navigationMode = "keyboard"

    local function moveSelection(delta)
        if #buttonOrder == 0 then
            return
        end
        local attempts = 0
        repeat
            selectedButtonIndex = selectedButtonIndex + delta
            if selectedButtonIndex < 1 then
                selectedButtonIndex = #buttonOrder
            elseif selectedButtonIndex > #buttonOrder then
                selectedButtonIndex = 1
            end
            attempts = attempts + 1
        until attempts >= #buttonOrder or isButtonEnabled(buttonOrder[selectedButtonIndex])
    end

    if key == "up" or key == "w" then
        moveSelection(-1)
        ensureValidButtonSelection()
        updateButtonSelection()
        playHoverSound()
    elseif key == "down" or key == "s" then
        moveSelection(1)
        ensureValidButtonSelection()
        updateButtonSelection()
        playHoverSound()
    elseif key == "return" or key == "space" then
        triggerSelectedButton(buttonOrder[selectedButtonIndex])
    elseif key == "escape" then
        triggerSelectedButton(uiButtons.quit)
    end
end

function mainMenu.keyreleased(key, scancode)
    -- Reserved for future keyboard handling
end

function mainMenu.gamepadpressed(joystick, button)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.gamepadpressed(joystick, button)
    end

    if not uiButtons then
        return false
    end

    if button == "a" then
        mainMenu.keypressed("return", "return", false)
        return true
    elseif button == "b" or button == "back" then
        mainMenu.keypressed("escape", "escape", false)
        return true
    elseif button == "leftshoulder" then
        mainMenu.keypressed("up", "up", false)
        return true
    elseif button == "rightshoulder" then
        mainMenu.keypressed("down", "down", false)
        return true
    end

    return false
end

return mainMenu
