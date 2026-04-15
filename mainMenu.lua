local mainMenu = {}

local stateMachineRef = nil
--------------------------------------------------
-- DECLARE LOCAL VARIABLES AND FUNCTIONS BELOW
--------------------------------------------------
local ConfirmDialog = require("confirmDialog")
local os = require("os")
local uiTheme = require("uiTheme")
local soundCache = require("soundCache")
local steamRuntime = require("steam_runtime")
local resumeStore = require("resume_store")
local Controller = require("controller")

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

-- Match the UI colors with the faction select and gameplay screens
local UI_COLORS = uiTheme.COLORS
local backgroundShader = nil
local DISABLED_BUTTON_COLOR = uiTheme.BUTTON_VARIANTS.disabled.base
local SCENARIO_FEATURE_ENABLED = SETTINGS and SETTINGS.FEATURES and SETTINGS.FEATURES.SCENARIO_MODE == true

local function ensureBackgroundShader()
    if backgroundShader then
        return
    end

    local success, shader = pcall(love.graphics.newShader, [[
        float hash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
        }

        float noise(vec2 p) {
            vec2 i = floor(p);
            vec2 f = fract(p);
            f = f * f * (2.0 - f);

            float a = hash(i);
            float b = hash(i + vec2(1.0, 0.0));
            float c = hash(i + vec2(0.0, 1.0));
            float d = hash(i + vec2(1.0, 1.0));

            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }

        uniform float time;
        uniform vec2 resolution;
        uniform vec2 gridCenter;
        uniform float gridSize;
        uniform float displayScale;
        uniform vec2 displayOffset;
        uniform float factionCycle;
        uniform vec3 factionColorA;
        uniform vec3 factionColorB;

        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
            vec2 uv = screen_coords / resolution;

            float slowTime = time * 0.12;
            float mediumTime = time * 0.25;
            float fastTime = time * 0.4;

            vec2 drift1 = vec2(sin(slowTime * 0.7) * 0.4, cos(slowTime * 0.5) * 0.3);
            vec2 drift2 = vec2(cos(mediumTime * 0.3) * 0.2, sin(mediumTime * 0.4) * 0.25);
            vec2 p = uv * 18.0 + drift1 + drift2;

            float n1 = noise(p + vec2(slowTime * 0.2, slowTime * 0.15));
            float n2 = noise(p * 2.5 + vec2(1.7 + mediumTime * 0.1, 2.3 + mediumTime * 0.08));
            float n3 = noise(p * 5.2 + vec2(5.1 + fastTime * 0.05, 1.9 + fastTime * 0.06));
            float n4 = noise(p * 10.8 + vec2(3.2 + fastTime * 0.03, 4.8 + fastTime * 0.04));

            float weight1 = 0.35 + sin(slowTime * 0.6) * 0.05;
            float weight2 = 0.25 + cos(mediumTime * 0.4) * 0.03;
            float combined = n1 * weight1 + n2 * weight2 + n3 * 0.25 + n4 * 0.15;

            float grainPulse = 1.0 + sin(mediumTime * 1.2) * 0.3;
            float grain = sin(p.x * 1.5 + combined * 5.0 + slowTime * 0.5) * 0.15 * grainPulse;
            combined += grain;

            float swirl1 = sin(p.x * 0.4 + p.y * 0.6 + combined * 3.0 + slowTime * 1.2) * 0.12;
            float swirl2 = sin(p.x * 0.7 - p.y * 0.3 + combined * 2.5 + mediumTime * 0.8) * 0.1;
            float swirl3 = cos(p.x * 0.3 + p.y * 0.8 + combined * 4.0 + fastTime * 0.6) * 0.08;
            combined += swirl1 + swirl2 + swirl3;

            vec2 centeredUv = (uv - 0.5) * 2.0;
            float rotationAngle = slowTime * 0.3;
            mat2 rot = mat2(cos(rotationAngle), -sin(rotationAngle), sin(rotationAngle), cos(rotationAngle));
            vec2 rotatedUv = rot * centeredUv;

            vec2 blobOffset1 = vec2(sin(slowTime * 0.6) * 0.35, cos(slowTime * 0.5) * 0.28);
            vec2 blobOffset2 = vec2(cos(mediumTime * 0.7) * 0.25, sin(mediumTime * 0.6) * 0.32);
            vec2 blobOffset3 = vec2(sin((slowTime + mediumTime) * 0.4) * 0.3, sin((slowTime - mediumTime) * 0.5) * 0.3);

            float blob1 = smoothstep(0.58, 0.18, length(rotatedUv - blobOffset1));
            float blob2 = smoothstep(0.62, 0.16, length(rotatedUv - blobOffset2));
            float blob3 = smoothstep(0.6, 0.2, length(rotatedUv - blobOffset3));

            float lavaMask = clamp((blob1 + blob2 + blob3) / 2.4, 0.0, 1.0);
            float lavaPulse = 0.55 + 0.45 * sin(slowTime * 1.7 + uv.y * 4.5 + blob1 * 2.0);
            lavaMask = pow(lavaMask * lavaPulse, 1.05);

            float factionWave = sin(factionCycle);
            float factionBlend = smoothstep(-0.25, 0.25, factionWave);
            vec3 cycleBaseColor = mix(factionColorA, factionColorB, factionBlend);
            vec3 lavaDeep = mix(vec3(0.16, 0.11, 0.07), cycleBaseColor, 0.55);
            vec3 lavaBright = mix(cycleBaseColor, vec3(1.0, 0.95, 0.86), 0.35);
            vec3 lavaColor = mix(lavaDeep, lavaBright, lavaMask);

            combined = clamp(combined, 0.0, 1.0);
            combined = pow(combined, 0.6);

            vec3 darkBrown = vec3(0.58, 0.48, 0.32);
            vec3 mediumBrown = vec3(0.72, 0.62, 0.45);
            vec3 lightBrown = vec3(0.82, 0.74, 0.58);
            vec3 tan = vec3(0.88, 0.82, 0.68);
            vec3 lightTan = vec3(0.94, 0.90, 0.80);

            vec3 finalColor;
            if (combined < 0.2) {
                finalColor = mix(darkBrown, mediumBrown, combined / 0.2);
            } else if (combined < 0.4) {
                finalColor = mix(mediumBrown, lightBrown, (combined - 0.2) / 0.2);
            } else if (combined < 0.7) {
                finalColor = mix(lightBrown, tan, (combined - 0.4) / 0.3);
            } else {
                finalColor = mix(tan, lightTan, (combined - 0.7) / 0.3);
            }

            float surface = noise(p * 24.0) * 0.04;
            finalColor += surface;

            float warmth = noise(p * 6.0 + vec2(slowTime * 0.1, mediumTime * 0.08)) * 0.025;
            float breathing1 = sin(slowTime * 1.4) * 0.03;
            float breathing2 = cos(mediumTime * 0.8) * 0.02;
            float pulse = sin(fastTime * 0.5) * 0.015;

            finalColor.r += warmth + (breathing1 + pulse) * 1.3;
            finalColor.g += warmth * 0.9 + (breathing1 + breathing2) * 1.0;
            finalColor.b += (breathing2 + pulse) * 0.2;

            finalColor = mix(finalColor, lavaColor, lavaMask * 0.55);
            finalColor += lavaColor * lavaMask * 0.08;

            vec2 windowCoords = screen_coords;
            vec2 transformedCoords = (windowCoords - displayOffset) / displayScale;
            float distFromGridCenter = distance(transformedCoords, gridCenter);
            float vignetteRadius = gridSize * 0.9;
            float vignette = 1.0 - smoothstep(vignetteRadius * 0.55, vignetteRadius * 1.05, distFromGridCenter);
            vignette = pow(vignette, 0.7);

            finalColor *= mix(0.65, 1.0, vignette);
            finalColor = clamp(finalColor, 0.0, 1.0);

            return vec4(finalColor, 1.0) * color;
        }
    ]])

    if success and shader then
        backgroundShader = shader

        local gridCenterX = GAME.CONSTANTS.GRID_ORIGIN_X + GAME.CONSTANTS.GRID_WIDTH / 2
        local gridCenterY = GAME.CONSTANTS.GRID_ORIGIN_Y + GAME.CONSTANTS.GRID_HEIGHT / 2
        backgroundShader:send("gridCenter", {gridCenterX, gridCenterY})
        backgroundShader:send("gridSize", GAME.CONSTANTS.GRID_WIDTH)
        backgroundShader:send("displayScale", SETTINGS.DISPLAY.SCALE)
        backgroundShader:send("displayOffset", {SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY})

        local blue = UI_COLORS.blueTeam
        local red = UI_COLORS.redTeam
        backgroundShader:send("factionColorA", {blue[1], blue[2], blue[3]})
        backgroundShader:send("factionColorB", {red[1], red[2], red[3]})

        backgroundShader:send("resolution", {SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT})

    else
        backgroundShader = nil
    end
end

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

local function drawTechPanel(x, y, width, height)
    uiTheme.drawTechPanel(x, y, width, height)
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

-- Draw a tech-styled title with glow
local function drawTitle(text, x, y, width)
    uiTheme.drawTitle(text, x, y, width)
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
    
    -- Initialize menu buttons with proper styling
    local buttonX = SETTINGS.DISPLAY.WIDTH / 2 - 100
    local nextButtonY = 180
    local function allocButtonY()
        local current = nextButtonY
        nextButtonY = nextButtonY + 70
        return current
    end
    local function createButton(buttonId, textValue, enabledValue)
        return {
            id = buttonId,
            x = buttonX,
            y = allocButtonY(),
            width = 200,
            height = 50,
            text = textValue,
            enabled = enabledValue ~= false,
            currentColor = UI_COLORS.button,
            hoverColor = UI_COLORS.buttonHover,
            pressedColor = UI_COLORS.buttonPressed
        }
    end

    uiButtons = {}
    if SCENARIO_FEATURE_ENABLED then
        uiButtons.playScenario = createButton("playScenario", "PLAY SCENARIO", true)
    end
    uiButtons.playSingle = createButton("playSingle", "Single Player", true)
    uiButtons.playLocal = createButton("playLocal", "Local Multiplayer", true)
    uiButtons.playOnline = createButton("playOnline", "Online Multiplayer", false)
    uiButtons.playLeaderboard = createButton("playLeaderboard", "Leaderboard", false)
    uiButtons.quit = createButton("quit", "Quit", true)

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

    ensureBackgroundShader()
end

-------------------------------------------
-- LOVE UPDATE FUNCTION
-------------------------------------------
function mainMenu.update(dt)
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

    ensureBackgroundShader()

    if backgroundShader then
        love.graphics.setShader(backgroundShader)
        local timeNow = love.timer.getTime()
        backgroundShader:send("time", timeNow)

        local windowW, windowH = love.graphics.getDimensions()
        backgroundShader:send("resolution", {SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT})

        local gridCenterX = GAME.CONSTANTS.GRID_ORIGIN_X + GAME.CONSTANTS.GRID_WIDTH / 2
        local gridCenterY = GAME.CONSTANTS.GRID_ORIGIN_Y + GAME.CONSTANTS.GRID_HEIGHT / 2
        backgroundShader:send("gridCenter", {gridCenterX, gridCenterY})
        backgroundShader:send("gridSize", GAME.CONSTANTS.GRID_WIDTH)
        backgroundShader:send("displayScale", SETTINGS.DISPLAY.SCALE)
        backgroundShader:send("displayOffset", {SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY})

        backgroundShader:send("resolution", {windowW, windowH})

        backgroundShader:send("factionCycle", timeNow * 0.9)
        local blue = UI_COLORS.blueTeam
        local red = UI_COLORS.redTeam
        backgroundShader:send("factionColorA", {blue[1] or 0.2, blue[2] or 0.4, blue[3] or 0.8})
        backgroundShader:send("factionColorB", {red[1] or 0.8, red[2] or 0.2, red[3] or 0.2})

        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
        love.graphics.setShader()
    else
        love.graphics.setColor(UI_COLORS.background)
        love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
    end

    love.graphics.setColor(UI_COLORS.border)
    love.graphics.setLineWidth(2)
    love.graphics.line(80, 100, 80, SETTINGS.DISPLAY.HEIGHT - 100)
    love.graphics.line(SETTINGS.DISPLAY.WIDTH - 80, 100, SETTINGS.DISPLAY.WIDTH - 80, SETTINGS.DISPLAY.HEIGHT - 100)
    love.graphics.line(120, SETTINGS.DISPLAY.HEIGHT - 80, SETTINGS.DISPLAY.WIDTH - 120, SETTINGS.DISPLAY.HEIGHT - 80)
    love.graphics.setLineWidth(1)

    drawTechPanel(SETTINGS.DISPLAY.WIDTH / 2 - 150, 40, 300, 60)
    drawTitle("MEOW OVER MOO!", 0, 60, SETTINGS.DISPLAY.WIDTH)

    if uiButtons then
        for _, button in ipairs(buttonOrder) do
            drawButton(button)
        end

        local footerText = "Copyright Flipped Cat - Version " .. tostring(VERSION)
        if PLATFORM_BUILD_LABEL and PLATFORM_BUILD_LABEL ~= "" then
            footerText = footerText .. " - " .. tostring(PLATFORM_BUILD_LABEL)
        end
        love.graphics.setColor(UI_COLORS.background)
        love.graphics.printf(footerText, 0, SETTINGS.DISPLAY.HEIGHT - 50, SETTINGS.DISPLAY.WIDTH, "center")
    end

    love.graphics.setLineWidth(1)

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
