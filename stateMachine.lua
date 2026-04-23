local stateMachine = {}

local states = {
    initialize = require("initialize"),         -- require the initialize.lua file
    mainMenu = require("mainMenu"),             -- require the mainMenu.lua file
    gameplay = require("gameplay"),             -- require the gameplay.lua file
    factionSelect = require("factionSelect"),   -- require the factionSelect.lua file
    onlineLobby = require("onlineLobby"),       -- require the onlineLobby.lua file
    onlineLeaderboard = require("onlineLeaderboard"), -- require the onlineLeaderboard.lua file
}
if SETTINGS and SETTINGS.FEATURES and SETTINGS.FEATURES.SCENARIO_MODE then
    states.scenarioSelect = require("scenarioSelect")
    states.scenarioEditor = require("scenarioEditor")
end
local inputBindings = require("input_bindings")
local steamRuntime = require("steam_runtime")
local ConfirmDialog = require("confirmDialog")
local inputBackend = require("input_backend")
local audioRuntime = require("audio_runtime")

local currentState = nil
local currentStateName = nil

local GAMEPAD_BUTTON_TO_ACTION = (((inputBindings or {}).gamepad or {}).buttonToAction) or {}
local GAMEPAD_AXIS_TO_ACTIONS = (((inputBindings or {}).gamepad or {}).axisToActions) or {}
local GAMEPAD_TRIGGER_AXES_TO_ACTION = (((inputBindings or {}).gamepad or {}).triggerAxesToAction) or {}
local GAMEPAD_IGNORED_AXES = (((inputBindings or {}).gamepad or {}).ignoredAxes) or {}
local JOYSTICK_BUTTON_TO_ACTION = (((inputBindings or {}).joystick or {}).buttonToAction) or {}
local JOYSTICK_AXIS_TO_ACTIONS = (((inputBindings or {}).joystick or {}).axisToActions) or {}
local STEAM_INPUT_CONFIG = (inputBindings and inputBindings.steamInput) or {}
local STEAM_INPUT_DIGITAL_TO_ACTION = STEAM_INPUT_CONFIG.digitalActionToAction or {}
local STEAM_INPUT_ANALOG_TO_NAVIGATION = STEAM_INPUT_CONFIG.analogActionToNavigation or {}
local STEAM_INPUT_ACTION_SET = tostring(STEAM_INPUT_CONFIG.actionSet or "global_controls")
local STEAM_INPUT_MANIFEST_FILE = tostring(STEAM_INPUT_CONFIG.manifestFile or "steam_input_manifest.vdf")
local ACTION_TO_KEY = (inputBindings and inputBindings.actionToKey) or {}

local repeatConfig = (inputBindings and inputBindings.repeatConfig) or {}
local inputSettings = (SETTINGS and SETTINGS.INPUT) or {}
local GAMEPAD_AXIS_THRESHOLD = inputSettings.GAMEPAD_AXIS_THRESHOLD or repeatConfig.axisThreshold or 0.5
local GAMEPAD_AXIS_RELEASE_THRESHOLD = inputSettings.GAMEPAD_AXIS_RELEASE_THRESHOLD or repeatConfig.axisReleaseThreshold or 0.4
local GAMEPAD_AXIS_INITIAL_REPEAT_DELAY = inputSettings.GAMEPAD_AXIS_INITIAL_REPEAT_DELAY or repeatConfig.axisInitialDelay or 0.25
local GAMEPAD_AXIS_REPEAT_INTERVAL = inputSettings.GAMEPAD_AXIS_REPEAT_INTERVAL or repeatConfig.axisRepeatInterval or 0.08
local GAMEPAD_BUTTON_INITIAL_REPEAT_DELAY = inputSettings.GAMEPAD_BUTTON_INITIAL_REPEAT_DELAY or repeatConfig.buttonInitialDelay or 0.25
local GAMEPAD_BUTTON_REPEAT_INTERVAL = inputSettings.GAMEPAD_BUTTON_REPEAT_INTERVAL or repeatConfig.buttonRepeatInterval or 0.08

local activeAxisDirections = {}
local activeButtonRepeats = {}
local activeTriggerAxes = {}
local activeJoystickHats = {}
local transientSuppressedInputs = {}
local latchedOneShotInputs = {}
local activeTouches = {}
local primaryTouchId = nil
local remotePlayDirectInputActive = false
local remotePlayMouse = {x = 0, y = 0}
local remotePlayDirectInputLastError = nil
local remotePlayCursorVisibleSessions = {}
local remotePlayCursorInputModeBySession = {}
local steamInputBackendActive = false
local steamInputLastControllerCount = 0
local steamInputConfigError = nil
local steamInputHandleStates = {}
local remotePlayJoystickSourceCache = {
    hostJoystickId = nil,
    remoteJoystickIds = {}
}
local currentInputSource = {
    kind = "unknown",
    isRemote = false,
    sessionId = nil
}

local clearDeviceTransientState

local REPEATABLE_ACTIONS = {
    NAV_UP = true,
    NAV_DOWN = true,
    NAV_LEFT = true,
    NAV_RIGHT = true,
    PAGE_UP = true,
    PAGE_DOWN = true
}

local function isRepeatableAction(actionId)
    return REPEATABLE_ACTIONS[tostring(actionId or "")] == true
end

local function getDeviceInputTable(root, deviceKey)
    root[deviceKey] = root[deviceKey] or {}
    return root[deviceKey]
end

local function suppressHeldInput(deviceKey, inputKey)
    getDeviceInputTable(transientSuppressedInputs, deviceKey)[tostring(inputKey)] = true
end

local function isHeldInputSuppressed(deviceKey, inputKey)
    local deviceTable = transientSuppressedInputs[deviceKey]
    return deviceTable ~= nil and deviceTable[tostring(inputKey)] == true
end

local function clearHeldInputSuppression(deviceKey, inputKey)
    local deviceTable = transientSuppressedInputs[deviceKey]
    if not deviceTable then
        return
    end
    deviceTable[tostring(inputKey)] = nil
    if next(deviceTable) == nil then
        transientSuppressedInputs[deviceKey] = nil
    end
end

local function getOneShotLatch(deviceKey, inputKey)
    local deviceTable = latchedOneShotInputs[deviceKey]
    return deviceTable and deviceTable[tostring(inputKey)] or nil
end

local function latchOneShotInput(deviceKey, inputKey, actionId, source)
    getDeviceInputTable(latchedOneShotInputs, deviceKey)[tostring(inputKey)] = {
        actionId = actionId,
        source = source
    }
end

local function releaseLatchedOneShotInput(deviceKey, inputKey, source)
    local deviceTable = latchedOneShotInputs[deviceKey]
    if not deviceTable then
        return false
    end

    local normalizedKey = tostring(inputKey)
    local entry = deviceTable[normalizedKey]
    if not entry then
        return false
    end

    deviceTable[normalizedKey] = nil
    if next(deviceTable) == nil then
        latchedOneShotInputs[deviceKey] = nil
    end

    stateMachine.dispatchAction(entry.actionId, "released", false, source or entry.source)
    return true
end

local function buildInputSource(kind, sessionId)
    local normalizedKind = tostring(kind or "unknown")
    local normalizedSessionId = sessionId ~= nil and tostring(sessionId) or nil
    local isRemote = normalizedKind == "remote_play_direct_input" or normalizedKind == "steam_input_remote_play"
    return {
        kind = normalizedKind,
        isRemote = isRemote,
        sessionId = normalizedSessionId
    }
end

local function withInputSource(source, fn)
    local previous = currentInputSource
    currentInputSource = source or buildInputSource("unknown")
    local ok, resultA, resultB, resultC = pcall(fn)
    currentInputSource = previous
    if not ok then
        error(resultA, 0)
    end
    return resultA, resultB, resultC
end

local function hostKeyboardMouseSource()
    return buildInputSource("host_local_keyboard_mouse")
end

local function hostControllerSource()
    return buildInputSource("host_local_controller")
end

local function remoteDirectInputSource(sessionId)
    return buildInputSource("remote_play_direct_input", sessionId)
end

local function steamInputHostSource(handleId)
    return buildInputSource("steam_input_host_local", handleId)
end

local function steamInputRemoteSource(sessionId)
    return buildInputSource("steam_input_remote_play", sessionId)
end

local function resolveMappedKey(actionId)
    if not actionId then
        return nil
    end
    return ACTION_TO_KEY[actionId]
end

local function touchPrimaryOnlyEnabled()
    local inputSettings = (SETTINGS and SETTINGS.INPUT) or {}
    return inputSettings.TOUCH_PRIMARY_ONLY ~= false
end

local function touchToScreen(x, y)
    local windowWidth, windowHeight = love.graphics.getDimensions()
    return x * windowWidth, y * windowHeight
end

local function touchDeltaToScreen(dx, dy)
    local windowWidth, windowHeight = love.graphics.getDimensions()
    return dx * windowWidth, dy * windowHeight
end

local function getJoystickId(joystick)
    if joystick and joystick.getID then
        return joystick:getID()
    end
    return tostring(joystick)
end

local function joystickIsGamepad(joystick)
    if joystick and joystick.isGamepad then
        local ok, result = pcall(joystick.isGamepad, joystick)
        if ok then
            return result == true
        end
    end
    return false
end

local function getAxisActionMapping(mappingTable, axisKey)
    if not mappingTable then
        return nil
    end
    local mapping = mappingTable[axisKey]
    if mapping then
        return mapping
    end
    local numericKey = tonumber(axisKey)
    if numericKey then
        mapping = mappingTable[numericKey]
        if mapping then
            return mapping
        end
    end
    return mappingTable[tostring(axisKey)]
end

local function isRemotePlayLocalVariantActive()
    if not GAME or not GAME.CURRENT then
        return false
    end
    if GAME.CURRENT.MODE ~= GAME.MODE.MULTYPLAYER_LOCAL then
        return false
    end
    return tostring(GAME.CURRENT.LOCAL_MATCH_VARIANT or "couch") == "remote_play"
end

local function isRemotePlayInputStateName(stateName)
    return stateName == "factionSelect" or stateName == "gameplay"
end

local hideAllRemotePlayCursors

local function applyRemotePlayCursorPolicyForState(stateName)
    if not isRemotePlayInputStateName(stateName) then
        return
    end
    if not isRemotePlayLocalVariantActive() then
        return
    end
    if not (love and love.mouse and love.mouse.setVisible) then
        return
    end
    love.mouse.setVisible(false)
    if MOUSE_STATE then
        MOUSE_STATE.IS_HIDDEN = true
    end
    hideAllRemotePlayCursors()
end

local function normalizeRemotePlaySessionId(sessionId)
    local numeric = tonumber(sessionId)
    if not numeric or numeric <= 0 then
        return nil
    end
    return tostring(math.floor(numeric))
end

local function setRemotePlayCursorVisibility(sessionId, visible)
    local normalized = normalizeRemotePlaySessionId(sessionId)
    if not normalized or type(steamRuntime.setRemotePlayMouseVisibility) ~= "function" then
        return false
    end
    local ok = steamRuntime.setRemotePlayMouseVisibility(normalized, visible == true)
    if ok == true then
        if visible == true then
            remotePlayCursorVisibleSessions[normalized] = true
        else
            remotePlayCursorVisibleSessions[normalized] = nil
        end
        return true
    end
    return false
end

local function setRemotePlayCursorKind(sessionId, cursorKind)
    local normalized = normalizeRemotePlaySessionId(sessionId)
    if not normalized or type(steamRuntime.setRemotePlayMouseCursor) ~= "function" then
        return false
    end
    return steamRuntime.setRemotePlayMouseCursor(normalized, cursorKind)
end

local function setRemotePlayCursorPosition(sessionId, normalizedX, normalizedY)
    local normalized = normalizeRemotePlaySessionId(sessionId)
    if not normalized or type(steamRuntime.setRemotePlayMousePosition) ~= "function" then
        return false
    end
    return steamRuntime.setRemotePlayMousePosition(normalized, normalizedX, normalizedY)
end

hideAllRemotePlayCursors = function()
    if type(steamRuntime.listRemotePlaySessions) ~= "function" then
        remotePlayCursorVisibleSessions = {}
        remotePlayCursorInputModeBySession = {}
        return
    end
    for _, entry in ipairs(steamRuntime.listRemotePlaySessions() or {}) do
        setRemotePlayCursorVisibility(entry.sessionId, false)
        setRemotePlayCursorKind(entry.sessionId, "hidden")
    end
    remotePlayCursorVisibleSessions = {}
    remotePlayCursorInputModeBySession = {}
end

local function shouldShowRemotePlayCursorForSession(sessionId)
    local normalized = normalizeRemotePlaySessionId(sessionId)
    if not normalized then
        return false
    end
    if not isRemotePlayLocalVariantActive() or not isRemotePlayInputStateName(currentStateName) then
        return false
    end
    return remotePlayCursorInputModeBySession[normalized] == "mouse"
end

local function syncRemotePlayCursorForMouseInput(sessionId, normalizedX, normalizedY)
    local normalized = normalizeRemotePlaySessionId(sessionId)
    if not normalized then
        return
    end
    remotePlayCursorInputModeBySession[normalized] = "mouse"
    if shouldShowRemotePlayCursorForSession(normalized) then
        setRemotePlayCursorKind(normalized, "default_light")
        setRemotePlayCursorVisibility(normalized, true)
        if normalizedX ~= nil and normalizedY ~= nil then
            setRemotePlayCursorPosition(normalized, normalizedX, normalizedY)
        end
    else
        setRemotePlayCursorVisibility(normalized, false)
    end
end

local function noteRemotePlayNonMouseInput(sessionId)
    local normalized = normalizeRemotePlaySessionId(sessionId)
    if not normalized then
        return
    end
    remotePlayCursorInputModeBySession[normalized] = "non_mouse"
    setRemotePlayCursorKind(normalized, "hidden")
    setRemotePlayCursorVisibility(normalized, false)
end

local function hasActiveRemotePlaySession()
    if not steamRuntime or type(steamRuntime.isOnlineReady) ~= "function" or steamRuntime.isOnlineReady() ~= true then
        return false
    end
    if type(steamRuntime.getRemotePlaySessionCount) ~= "function" then
        return false
    end
    local count = tonumber(steamRuntime.getRemotePlaySessionCount()) or 0
    return count >= 1
end

local function queueRemotePlayExitPrompt()
    if not GAME or not GAME.CURRENT then
        return
    end
    GAME.CURRENT.REMOTE_PLAY_EXIT_PROMPT_PENDING = true
end

local function collectSortedKeys(source)
    local out = {}
    local seen = {}
    for key, value in pairs(source or {}) do
        local normalized = tostring(key or "")
        if normalized ~= "" and value ~= nil and not seen[normalized] then
            seen[normalized] = true
            out[#out + 1] = normalized
        end
    end
    table.sort(out)
    return out
end

local STEAM_INPUT_DIGITAL_ACTION_NAMES = collectSortedKeys(STEAM_INPUT_DIGITAL_TO_ACTION)
local STEAM_INPUT_ANALOG_ACTION_NAMES = collectSortedKeys(STEAM_INPUT_ANALOG_TO_NAVIGATION)

local function releaseSyntheticButtonRepeat(deviceKey, buttonKey, actionId, source)
    if activeButtonRepeats[deviceKey] and activeButtonRepeats[deviceKey][buttonKey] then
        activeButtonRepeats[deviceKey][buttonKey] = nil
        stateMachine.dispatchAction(actionId, "released", false, source)
        if next(activeButtonRepeats[deviceKey]) == nil then
            activeButtonRepeats[deviceKey] = nil
        end
    end
end

local function pressSyntheticButtonRepeat(deviceKey, buttonKey, actionId, source)
    if isHeldInputSuppressed(deviceKey, buttonKey) then
        return false
    end
    activeButtonRepeats[deviceKey] = activeButtonRepeats[deviceKey] or {}
    local current = activeButtonRepeats[deviceKey][buttonKey]
    if current then
        current.source = source
        return false
    end
    activeButtonRepeats[deviceKey][buttonKey] = {
        elapsed = 0,
        repeating = false,
        actionId = actionId,
        source = source
    }
    stateMachine.dispatchAction(actionId, "pressed", false, source)
    return true
end

local function handleButtonActionPressed(deviceKey, buttonKey, actionId, source)
    if not actionId or isHeldInputSuppressed(deviceKey, buttonKey) then
        return false
    end

    if isRepeatableAction(actionId) then
        return pressSyntheticButtonRepeat(deviceKey, buttonKey, actionId, source)
    end

    local current = getOneShotLatch(deviceKey, buttonKey)
    if current then
        current.source = source
        return false
    end

    latchOneShotInput(deviceKey, buttonKey, actionId, source)
    stateMachine.dispatchAction(actionId, "pressed", false, source)
    return true
end

local function handleButtonActionReleased(deviceKey, buttonKey, actionId, source)
    clearHeldInputSuppression(deviceKey, buttonKey)

    if isRepeatableAction(actionId) then
        local deviceRepeats = activeButtonRepeats[deviceKey]
        if deviceRepeats and deviceRepeats[buttonKey] then
            releaseSyntheticButtonRepeat(deviceKey, buttonKey, actionId, source)
            return true
        end
        return false
    end

    return releaseLatchedOneShotInput(deviceKey, buttonKey, source)
end

local function markTransientButtonSuppression(deviceKey, buttonKey)
    if deviceKey == nil or buttonKey == nil then
        return
    end
    suppressHeldInput(deviceKey, buttonKey)
end

local function markTransientAxisSuppression(deviceKey, axisKey)
    if deviceKey == nil or axisKey == nil then
        return
    end
    suppressHeldInput(deviceKey, axisKey)
end

local function isTransientAxisSuppressed(deviceKey, axisKey)
    return isHeldInputSuppressed(deviceKey, axisKey)
end

local function clearTransientAxisSuppression(deviceKey, axisKey)
    clearHeldInputSuppression(deviceKey, axisKey)
end

local function resetTransientInputState()
    for deviceKey, buttonStates in pairs(activeButtonRepeats) do
        for buttonKey, state in pairs(buttonStates) do
            if state and state.actionId then
                markTransientButtonSuppression(deviceKey, buttonKey)
            end
        end
    end
    activeButtonRepeats = {}

    for joystickId, axisState in pairs(activeAxisDirections) do
        for stateKey, state in pairs(axisState) do
            if state and state.actionId then
                markTransientAxisSuppression(joystickId, "axis:" .. tostring(stateKey))
            end
        end
    end
    activeAxisDirections = {}

    for joystickId, triggerStates in pairs(activeTriggerAxes) do
        for axisName, axisState in pairs(triggerStates) do
            if axisState and axisState.actionId then
                markTransientButtonSuppression(joystickId, "trigger:" .. tostring(axisName))
            end
        end
    end
    activeTriggerAxes = {}

    for deviceKey, latchedStates in pairs(latchedOneShotInputs) do
        for buttonKey in pairs(latchedStates) do
            markTransientButtonSuppression(deviceKey, buttonKey)
        end
    end
    latchedOneShotInputs = {}

    for handleId, state in pairs(steamInputHandleStates) do
        local deviceKey = "steam:" .. tostring(handleId)
        for actionName, actionState in pairs(state.digital or {}) do
            if actionState and actionState.pressed == true then
                markTransientButtonSuppression(deviceKey, "digital:" .. tostring(actionName))
            end
        end
        for axisStateKey, axisState in pairs(state.analog or {}) do
            if axisState and axisState.actionId then
                markTransientAxisSuppression(deviceKey, "analog:" .. tostring(axisStateKey))
            end
        end
        state.digital = {}
        state.analog = {}
    end
end

local function clearSteamInputHandleState(handleId)
    local state = steamInputHandleStates[handleId]
    if not state then
        return
    end

    local deviceKey = "steam:" .. tostring(handleId)
    for actionName, actionState in pairs(state.digital or {}) do
        if actionState and actionState.pressed and actionState.actionId then
            handleButtonActionReleased(deviceKey, "digital:" .. tostring(actionName), actionState.actionId, actionState.source)
        end
    end

    for axisKey, axisState in pairs(state.analog or {}) do
        if axisState and axisState.pressed and axisState.actionId then
            releaseSyntheticButtonRepeat(deviceKey, "analog:" .. tostring(axisKey), axisState.actionId, axisState.source)
        end
    end

    steamInputHandleStates[handleId] = nil
    clearDeviceTransientState(deviceKey)
end

local function resetSteamInputBackendState()
    for handleId in pairs(steamInputHandleStates) do
        clearSteamInputHandleState(handleId)
    end
    steamInputHandleStates = {}
    steamInputBackendActive = false
    steamInputLastControllerCount = 0
    steamInputConfigError = nil
end

local function shouldUseSteamInputBackend()
    return inputBackend.shouldUseSteamInputBackend(currentStateName, steamRuntime)
end

local function shouldSuppressLoveControllerCallbacks()
    return shouldUseSteamInputBackend() and steamInputBackendActive and steamInputLastControllerCount > 0
end

local function resetRemotePlayJoystickSourceCache()
    remotePlayJoystickSourceCache.hostJoystickId = nil
    remotePlayJoystickSourceCache.remoteJoystickIds = {}
end

clearDeviceTransientState = function(deviceKey)
    transientSuppressedInputs[deviceKey] = nil
    latchedOneShotInputs[deviceKey] = nil
end

local function buildConnectedJoystickIds(joysticks)
    local connected = {}
    for _, listedJoystick in ipairs(joysticks or {}) do
        connected[tostring(getJoystickId(listedJoystick))] = true
    end
    return connected
end

local function chooseDeterministicHostJoystickId(joysticks)
    local hostId = nil
    local hostIdNumeric = nil
    local fallbackHostId = nil
    for index, listedJoystick in ipairs(joysticks or {}) do
        local listedId = tostring(getJoystickId(listedJoystick))
        if index == 1 then
            fallbackHostId = listedId
        end
        local listedNumeric = tonumber(listedId)
        if listedNumeric then
            if not hostIdNumeric or listedNumeric < hostIdNumeric then
                hostIdNumeric = listedNumeric
                hostId = listedId
            end
        end
    end
    return hostId or fallbackHostId
end

local function resolveControllerSourceForJoystick(joystick)
    if not joystick then
        return hostControllerSource()
    end
    if not isRemotePlayLocalVariantActive() or not hasActiveRemotePlaySession() then
        resetRemotePlayJoystickSourceCache()
        return hostControllerSource()
    end

    local currentJoystickId = tostring(getJoystickId(joystick))
    local joysticks = {}
    if love and love.joystick and love.joystick.getJoysticks then
        joysticks = love.joystick.getJoysticks() or {}
    end

    if #joysticks <= 1 then
        remotePlayJoystickSourceCache.hostJoystickId = currentJoystickId
        remotePlayJoystickSourceCache.remoteJoystickIds = {}
        return hostControllerSource()
    end

    local connectedIds = buildConnectedJoystickIds(joysticks)
    local hostId = remotePlayJoystickSourceCache.hostJoystickId
    if hostId == nil or connectedIds[tostring(hostId)] ~= true then
        hostId = chooseDeterministicHostJoystickId(joysticks)
        remotePlayJoystickSourceCache.hostJoystickId = hostId
    end

    local remoteIds = {}
    for _, listedJoystick in ipairs(joysticks) do
        local listedId = tostring(getJoystickId(listedJoystick))
        if hostId == nil or listedId ~= tostring(hostId) then
            remoteIds[listedId] = true
        end
    end
    remotePlayJoystickSourceCache.remoteJoystickIds = remoteIds

    if hostId and currentJoystickId == tostring(hostId) then
        return hostControllerSource()
    end
    if remoteIds[currentJoystickId] == true then
        return remoteDirectInputSource("joy:" .. currentJoystickId)
    end
    return hostControllerSource()
end

function stateMachine.dispatchAction(actionId, phase, isrepeat, source)
    local mappedKey = resolveMappedKey(actionId)
    if not mappedKey then
        return false
    end

    if phase == "released" then
        stateMachine.keyreleased(mappedKey, mappedKey, source)
        return true
    end

    stateMachine.keypressed(mappedKey, mappedKey, isrepeat == true, source)
    return true
end

local function updateButtonRepeatTimers(dt)
    for joystickId, buttonState in pairs(activeButtonRepeats) do
        for button, state in pairs(buttonState) do
            if state and state.actionId then
                state.elapsed = state.elapsed + dt
                if state.repeating then
                    if state.elapsed >= GAMEPAD_BUTTON_REPEAT_INTERVAL then
                        state.elapsed = state.elapsed - GAMEPAD_BUTTON_REPEAT_INTERVAL
                        stateMachine.dispatchAction(state.actionId, "repeat", true, state.source)
                    end
                else
                    if state.elapsed >= GAMEPAD_BUTTON_INITIAL_REPEAT_DELAY then
                        state.elapsed = state.elapsed - GAMEPAD_BUTTON_INITIAL_REPEAT_DELAY
                        state.repeating = true
                        stateMachine.dispatchAction(state.actionId, "repeat", true, state.source)
                    end
                end
            end
        end
    end
end

local function ensureAxisStateTable(joystickId)
    if not activeAxisDirections[joystickId] then
        activeAxisDirections[joystickId] = {}
    end
    return activeAxisDirections[joystickId]
end

local function releaseAxisState(joystickId)
    local axisState = activeAxisDirections[joystickId]
    if not axisState then
        return
    end

    for stateKey, axisEntry in pairs(axisState) do
        local axisKey, directionKey = stateKey:match("^(.-):(%a+)$")
        if axisKey and directionKey then
            local mapping = getAxisActionMapping(GAMEPAD_AXIS_TO_ACTIONS, axisKey) or
                getAxisActionMapping(JOYSTICK_AXIS_TO_ACTIONS, axisKey)
            if mapping then
                local actionId = mapping[directionKey]
                stateMachine.dispatchAction(actionId, "released", false, axisEntry and axisEntry.source)
            end
        end
    end

    activeAxisDirections[joystickId] = nil
end

local function releaseTriggerState(joystickId)
    if not activeTriggerAxes[joystickId] then
        return
    end

    for axisName, axisState in pairs(activeTriggerAxes[joystickId]) do
        if axisState and axisState.pressed and axisState.actionId then
            stateMachine.dispatchAction(axisState.actionId, "released", false, axisState.source)
        end
        activeTriggerAxes[joystickId][axisName] = nil
    end
end

function stateMachine.joystickremoved(joystick)
    local joystickId = getJoystickId(joystick)
    releaseAxisState(joystickId)
    releaseTriggerState(joystickId)
    activeButtonRepeats[joystickId] = nil
    activeJoystickHats[joystickId] = nil
    clearDeviceTransientState(joystickId)

    if currentState and currentState.joystickremoved then
        currentState.joystickremoved(joystick)
    end
end

-- Updates the scaling and offsets
local function updateScaling()
    local currentWindowWidth, currentWindowHeight = love.graphics.getDimensions()

    -- Calc the scale
    local scaleX = currentWindowWidth / SETTINGS.DISPLAY.WIDTH
    local scaleY = currentWindowHeight / SETTINGS.DISPLAY.HEIGHT

    -- Use smaller scale value to maintain the aspect ratio (letterboxing)
    SETTINGS.DISPLAY.SCALE = math.min(scaleX, scaleY)

    -- Calc the offsets to center the game on screen
    SETTINGS.DISPLAY.OFFSETX = (currentWindowWidth - SETTINGS.DISPLAY.WIDTH * SETTINGS.DISPLAY.SCALE) / 2
    SETTINGS.DISPLAY.OFFSETY = (currentWindowHeight - SETTINGS.DISPLAY.HEIGHT * SETTINGS.DISPLAY.SCALE) / 2

end

local function handleAxisDirection(deviceKey, axisState, axisKey, value, directionKey, actionId, mappingTable, source)
    local stateKey = axisKey .. ":" .. directionKey
    local suppressionKey = "axis:" .. stateKey
    local stateEntry = axisState[stateKey]

    if isTransientAxisSuppressed(deviceKey, suppressionKey) then
        if directionKey == "negative" then
            if value > -GAMEPAD_AXIS_RELEASE_THRESHOLD then
                clearTransientAxisSuppression(deviceKey, suppressionKey)
            end
        else
            if value < GAMEPAD_AXIS_RELEASE_THRESHOLD then
                clearTransientAxisSuppression(deviceKey, suppressionKey)
            end
        end
        return
    end

    local function startDirection()
        local oppositeKey = axisKey .. ":" .. (directionKey == "negative" and "positive" or "negative")
        local oppositeMapping = getAxisActionMapping(mappingTable, axisKey)
        if axisState[oppositeKey] then
            axisState[oppositeKey] = nil
            if oppositeMapping then
                local oppositeActionId = oppositeMapping[directionKey == "negative" and "positive" or "negative"]
                if oppositeActionId then
                    stateMachine.dispatchAction(oppositeActionId, "released", false, source)
                end
            end
        end

        axisState[stateKey] = {
            active = true,
            elapsed = 0,
            repeating = false,
            actionId = actionId,
            source = source
        }
        stateMachine.dispatchAction(actionId, "pressed", false, source)
    end
    
    if directionKey == "negative" then
        if value <= -GAMEPAD_AXIS_THRESHOLD then
            if not stateEntry then
                startDirection()
            end
        elseif stateEntry and stateEntry.active and value > -GAMEPAD_AXIS_RELEASE_THRESHOLD then
            axisState[stateKey] = nil
            stateMachine.dispatchAction(actionId, "released", false, stateEntry.source or source)
        end
    else -- positive direction
        if value >= GAMEPAD_AXIS_THRESHOLD then
            if not stateEntry then
                startDirection()
            end
        elseif stateEntry and stateEntry.active and value < GAMEPAD_AXIS_RELEASE_THRESHOLD then
            axisState[stateKey] = nil
            stateMachine.dispatchAction(actionId, "released", false, stateEntry.source or source)
        end
    end
end

function stateMachine.gamepadpressed(joystick, button)
    if shouldSuppressLoveControllerCallbacks() then
        return
    end
    local source = resolveControllerSourceForJoystick(joystick)
    return withInputSource(source, function()
        if currentState and currentState.gamepadpressed then
            local handled = currentState.gamepadpressed(joystick, button)
            if handled then
                return
            end
        end

        local actionId = GAMEPAD_BUTTON_TO_ACTION[button]
        if actionId then
            local joystickId = getJoystickId(joystick)
            handleButtonActionPressed(joystickId, "button:" .. tostring(button), actionId, source)
        end
    end)
end

function stateMachine.gamepadreleased(joystick, button)
    if shouldSuppressLoveControllerCallbacks() then
        return
    end
    local source = resolveControllerSourceForJoystick(joystick)
    return withInputSource(source, function()
        if currentState and currentState.gamepadreleased then
            local handled = currentState.gamepadreleased(joystick, button)
            if handled then
                return
            end
        end

        local actionId = GAMEPAD_BUTTON_TO_ACTION[button]
        if actionId then
            local joystickId = getJoystickId(joystick)
            handleButtonActionReleased(joystickId, "button:" .. tostring(button), actionId, source)
        end
    end)
end

function stateMachine.gamepadaxis(joystick, axis, value)
    if shouldSuppressLoveControllerCallbacks() then
        return
    end
    local source = resolveControllerSourceForJoystick(joystick)
    return withInputSource(source, function()
    local triggerActionId = GAMEPAD_TRIGGER_AXES_TO_ACTION[axis]
    if triggerActionId then
        local joystickId = getJoystickId(joystick)
        activeTriggerAxes[joystickId] = activeTriggerAxes[joystickId] or {}
        local axisState = activeTriggerAxes[joystickId][axis] or {
            pressed = false,
            actionId = triggerActionId,
            source = source
        }
        axisState.source = source

        if value >= GAMEPAD_AXIS_THRESHOLD then
            if not axisState.pressed then
                axisState.pressed = true
                handleButtonActionPressed(joystickId, "trigger:" .. tostring(axis), triggerActionId, source)
            end
        elseif axisState.pressed and value <= GAMEPAD_AXIS_RELEASE_THRESHOLD then
            axisState.pressed = false
            handleButtonActionReleased(joystickId, "trigger:" .. tostring(axis), triggerActionId, source)
        end

        activeTriggerAxes[joystickId][axis] = axisState

        if currentState and currentState.gamepadaxis then
            currentState.gamepadaxis(joystick, axis, value)
        end
        return
    end

    if GAMEPAD_IGNORED_AXES[axis] then
        return
    end

    local mapping = GAMEPAD_AXIS_TO_ACTIONS[axis]
    if not mapping then
        if currentState and currentState.gamepadaxis then
            currentState.gamepadaxis(joystick, axis, value)
        end
        return
    end

    local joystickId = getJoystickId(joystick)
    local axisState = ensureAxisStateTable(joystickId)

    if mapping.negative then
        handleAxisDirection(joystickId, axisState, axis, value, "negative", mapping.negative, GAMEPAD_AXIS_TO_ACTIONS, source)
    end

    if mapping.positive then
        handleAxisDirection(joystickId, axisState, axis, value, "positive", mapping.positive, GAMEPAD_AXIS_TO_ACTIONS, source)
    end

    if currentState and currentState.gamepadaxis then
        currentState.gamepadaxis(joystick, axis, value)
    end
    end)
end

function stateMachine.joystickpressed(joystick, button)
    if shouldSuppressLoveControllerCallbacks() then
        return
    end
    local source = resolveControllerSourceForJoystick(joystick)
    return withInputSource(source, function()
        if joystickIsGamepad(joystick) then
            return
        end

        if currentState and currentState.joystickpressed then
            local handled = currentState.joystickpressed(joystick, button)
            if handled then
                return
            end
        end

        local actionId = JOYSTICK_BUTTON_TO_ACTION[button] or JOYSTICK_BUTTON_TO_ACTION[tostring(button)]
        if actionId then
            local joystickId = getJoystickId(joystick)
            handleButtonActionPressed(joystickId, "button:" .. tostring(button), actionId, source)
        end
    end)
end

function stateMachine.joystickreleased(joystick, button)
    if shouldSuppressLoveControllerCallbacks() then
        return
    end
    local source = resolveControllerSourceForJoystick(joystick)
    return withInputSource(source, function()
        if joystickIsGamepad(joystick) then
            return
        end

        if currentState and currentState.joystickreleased then
            local handled = currentState.joystickreleased(joystick, button)
            if handled then
                return
            end
        end

        local actionId = JOYSTICK_BUTTON_TO_ACTION[button] or JOYSTICK_BUTTON_TO_ACTION[tostring(button)]
        if actionId then
            local joystickId = getJoystickId(joystick)
            handleButtonActionReleased(joystickId, "button:" .. tostring(button), actionId, source)
        end
    end)
end

function stateMachine.joystickaxis(joystick, axis, value)
    if shouldSuppressLoveControllerCallbacks() then
        return
    end
    local source = resolveControllerSourceForJoystick(joystick)
    return withInputSource(source, function()
        if joystickIsGamepad(joystick) then
            return
        end

        if currentState and currentState.joystickaxis then
            local handled = currentState.joystickaxis(joystick, axis, value)
            if handled then
                return
            end
        end

        local axisKey = tostring(math.floor(tonumber(axis) or 0))
        local mapping = getAxisActionMapping(JOYSTICK_AXIS_TO_ACTIONS, axisKey)
        if not mapping then
            return
        end

        local joystickId = getJoystickId(joystick)
        local axisState = ensureAxisStateTable(joystickId)
        if mapping.negative then
            handleAxisDirection(joystickId, axisState, axisKey, value, "negative", mapping.negative, JOYSTICK_AXIS_TO_ACTIONS, source)
        end
        if mapping.positive then
            handleAxisDirection(joystickId, axisState, axisKey, value, "positive", mapping.positive, JOYSTICK_AXIS_TO_ACTIONS, source)
        end
    end)
end

function stateMachine.joystickhat(joystick, hat, direction)
    if shouldSuppressLoveControllerCallbacks() then
        return
    end
    local source = resolveControllerSourceForJoystick(joystick)
    return withInputSource(source, function()
        if joystickIsGamepad(joystick) then
            return
        end

        if currentState and currentState.joystickhat then
            local handled = currentState.joystickhat(joystick, hat, direction)
            if handled then
                return
            end
        end

        local joystickId = getJoystickId(joystick)
        local previous = activeJoystickHats[joystickId] or {up = false, down = false, left = false, right = false}
        local dir = tostring(direction or "c")
        local current = {
            up = (dir:find("u", 1, true) ~= nil),
            down = (dir:find("d", 1, true) ~= nil),
            left = (dir:find("l", 1, true) ~= nil),
            right = (dir:find("r", 1, true) ~= nil)
        }

        local actionByDirection = {
            up = "NAV_UP",
            down = "NAV_DOWN",
            left = "NAV_LEFT",
            right = "NAV_RIGHT"
        }

        for key, actionId in pairs(actionByDirection) do
            if current[key] and not previous[key] then
                stateMachine.dispatchAction(actionId, "pressed", false, source)
            elseif previous[key] and not current[key] then
                stateMachine.dispatchAction(actionId, "released", false, source)
            end
        end

        activeJoystickHats[joystickId] = current
    end)
end

local function updateAxisRepeatTimers(dt)
    for joystickId, axisState in pairs(activeAxisDirections) do
        for stateKey, state in pairs(axisState) do
            if type(state) == "table" and state.active and state.actionId then
                state.elapsed = state.elapsed + dt
                if state.repeating then
                    if state.elapsed >= GAMEPAD_AXIS_REPEAT_INTERVAL then
                        state.elapsed = state.elapsed - GAMEPAD_AXIS_REPEAT_INTERVAL
                        stateMachine.dispatchAction(state.actionId, "repeat", true)
                    end
                else
                    if state.elapsed >= GAMEPAD_AXIS_INITIAL_REPEAT_DELAY then
                        state.elapsed = state.elapsed - GAMEPAD_AXIS_INITIAL_REPEAT_DELAY
                        state.repeating = true
                        stateMachine.dispatchAction(state.actionId, "repeat", true)
                    end
                end
            end
        end
    end
end

local REMOTE_PLAY_SCANCODE_TO_ACTION = {
    [4] = "NAV_LEFT",   -- A
    [7] = "NAV_RIGHT",  -- D
    [22] = "NAV_DOWN",  -- S
    [26] = "NAV_UP",    -- W
    [79] = "NAV_RIGHT", -- Right Arrow
    [80] = "NAV_LEFT",  -- Left Arrow
    [81] = "NAV_DOWN",  -- Down Arrow
    [82] = "NAV_UP",    -- Up Arrow
    [20] = "TAB_LEFT",  -- Q
    [8] = "TAB_RIGHT",  -- E
    [40] = "CONFIRM",   -- Return
    [41] = "CANCEL",    -- Escape
    [44] = "ALT_CONFIRM", -- Space
    [75] = "PAGE_UP",   -- PageUp
    [78] = "PAGE_DOWN"  -- PageDown
}

local REMOTE_PLAY_KEYCODE_TO_ACTION = {
    [65] = "NAV_LEFT",   -- A
    [68] = "NAV_RIGHT",  -- D
    [83] = "NAV_DOWN",   -- S
    [87] = "NAV_UP",     -- W
    [37] = "NAV_LEFT",   -- Left Arrow
    [39] = "NAV_RIGHT",  -- Right Arrow
    [40] = "NAV_DOWN",   -- Down Arrow
    [38] = "NAV_UP",     -- Up Arrow
    [81] = "TAB_LEFT",   -- Q
    [69] = "TAB_RIGHT",  -- E
    [13] = "CONFIRM",    -- Return
    [27] = "CANCEL",     -- Escape
    [32] = "ALT_CONFIRM",-- Space
    [33] = "PAGE_UP",    -- PageUp
    [34] = "PAGE_DOWN"   -- PageDown
}

local function remotePlayButtonMaskToMouseButton(mask)
    if mask == 1 then
        return 1
    end
    if mask == 2 then
        return 2
    end
    if mask == 4 then
        return 3
    end
    return nil
end

local function processRemotePlayMouseMotion(event)
    local windowWidth, windowHeight = love.graphics.getDimensions()
    local targetX, targetY, deltaX, deltaY

    if event.mouseAbsolute == true then
        targetX = math.max(0, math.min(windowWidth, (event.mouseNormalizedX or 0) * windowWidth))
        targetY = math.max(0, math.min(windowHeight, (event.mouseNormalizedY or 0) * windowHeight))
        deltaX = targetX - remotePlayMouse.x
        deltaY = targetY - remotePlayMouse.y
    else
        deltaX = tonumber(event.mouseDeltaX) or 0
        deltaY = tonumber(event.mouseDeltaY) or 0
        targetX = math.max(0, math.min(windowWidth, remotePlayMouse.x + deltaX))
        targetY = math.max(0, math.min(windowHeight, remotePlayMouse.y + deltaY))
    end

    remotePlayMouse.x = targetX
    remotePlayMouse.y = targetY
    syncRemotePlayCursorForMouseInput(
        event.sessionId,
        windowWidth > 0 and (targetX / windowWidth) or 0,
        windowHeight > 0 and (targetY / windowHeight) or 0
    )
    local source = remoteDirectInputSource(event.sessionId)
    stateMachine.mousemoved(targetX, targetY, deltaX, deltaY, false, source)
end

local function processRemotePlayMouseButton(event, isPressed)
    local button = remotePlayButtonMaskToMouseButton(tonumber(event.mouseButton) or 0)
    if not button then
        return
    end
    local windowWidth, windowHeight = love.graphics.getDimensions()
    syncRemotePlayCursorForMouseInput(
        event.sessionId,
        windowWidth > 0 and (remotePlayMouse.x / windowWidth) or 0,
        windowHeight > 0 and (remotePlayMouse.y / windowHeight) or 0
    )
    local source = remoteDirectInputSource(event.sessionId)
    if isPressed then
        stateMachine.mousepressed(remotePlayMouse.x, remotePlayMouse.y, button, false, 1, source)
    else
        stateMachine.mousereleased(remotePlayMouse.x, remotePlayMouse.y, button, false, 1, source)
    end
end

local function processRemotePlayKeyEvent(event, isPressed)
    local scancode = tonumber(event.keyScancode) or 0
    local actionId = REMOTE_PLAY_SCANCODE_TO_ACTION[scancode]
    if not actionId then
        local keycode = tonumber(event.keyCode) or 0
        actionId = REMOTE_PLAY_KEYCODE_TO_ACTION[keycode]
    end
    if not actionId then
        return
    end
    noteRemotePlayNonMouseInput(event.sessionId)
    local source = remoteDirectInputSource(event.sessionId)
    if isPressed then
        stateMachine.dispatchAction(actionId, "pressed", false, source)
    else
        stateMachine.dispatchAction(actionId, "released", false, source)
    end
end

local function processRemotePlayDirectInputEvent(event)
    if type(event) ~= "table" then
        return
    end
    local eventType = tostring(event.type or "")
    if eventType == "mouse_motion" then
        processRemotePlayMouseMotion(event)
        return
    end
    if eventType == "mouse_button_down" then
        processRemotePlayMouseButton(event, true)
        return
    end
    if eventType == "mouse_button_up" then
        processRemotePlayMouseButton(event, false)
        return
    end
    if eventType == "key_down" then
        processRemotePlayKeyEvent(event, true)
        return
    end
    if eventType == "key_up" then
        processRemotePlayKeyEvent(event, false)
        return
    end
end

local function setRemotePlayDirectInputActive(enabled)
    if type(steamRuntime.setRemotePlayDirectInputEnabled) ~= "function" then
        remotePlayDirectInputActive = false
        if enabled ~= true then
            resetRemotePlayJoystickSourceCache()
        end
        return
    end

    local ok, reason = steamRuntime.setRemotePlayDirectInputEnabled(enabled)
    if ok == true then
        remotePlayDirectInputActive = enabled == true
        if enabled ~= true then
            resetRemotePlayJoystickSourceCache()
        end
        remotePlayDirectInputLastError = nil
        return
    end

    remotePlayDirectInputActive = false
    if enabled ~= true then
        resetRemotePlayJoystickSourceCache()
    end
    local errText = tostring(reason or "remote_play_direct_input_failed")
    if remotePlayDirectInputLastError ~= errText then
        remotePlayDirectInputLastError = errText
        print("[RemotePlay] Direct input toggle failed: " .. errText)
    end
end

local function ensureSteamInputBackendConfigured()
    if not shouldUseSteamInputBackend() then
        if steamInputBackendActive then
            if steamRuntime and type(steamRuntime.shutdownSteamInput) == "function" then
                steamRuntime.shutdownSteamInput()
            end
            resetSteamInputBackendState()
        end
        return false
    end

    if steamInputBackendActive then
        return true
    end

    local ok, reason = steamRuntime.configureSteamInput({
        manifestFile = STEAM_INPUT_MANIFEST_FILE,
        actionSet = STEAM_INPUT_ACTION_SET,
        digitalActions = STEAM_INPUT_DIGITAL_ACTION_NAMES,
        analogActions = STEAM_INPUT_ANALOG_ACTION_NAMES,
        digitalActionToAction = STEAM_INPUT_DIGITAL_TO_ACTION,
        analogActionToNavigation = STEAM_INPUT_ANALOG_TO_NAVIGATION
    })

    if ok == true then
        steamInputBackendActive = true
        steamInputConfigError = nil
        return true
    end

    steamInputBackendActive = false
    local errText = tostring(reason or "steam_input_configure_failed")
    if steamInputConfigError ~= errText then
        steamInputConfigError = errText
        print("[SteamInput] Configuration failed: " .. errText)
    end
    return false
end

local function resolveSteamInputSource(controller)
    local sessionId = tonumber(controller and controller.remotePlaySessionId) or 0
    if sessionId > 0 then
        return steamInputRemoteSource(sessionId)
    end
    local handleId = controller and controller.handleId or nil
    return steamInputHostSource(handleId)
end

local function updateSteamInputAnalogDirection(state, deviceKey, axisKey, value, directionKey, actionId, source)
    if not actionId then
        return
    end

    local stateKey = axisKey .. ":" .. directionKey
    local suppressionKey = "analog:" .. stateKey
    local existing = state[stateKey]

    if isTransientAxisSuppressed(deviceKey, suppressionKey) then
        if directionKey == "negative" then
            if value > -GAMEPAD_AXIS_RELEASE_THRESHOLD then
                clearTransientAxisSuppression(deviceKey, suppressionKey)
            end
        else
            if value < GAMEPAD_AXIS_RELEASE_THRESHOLD then
                clearTransientAxisSuppression(deviceKey, suppressionKey)
            end
        end
        return
    end

    local function releaseCurrent(entry)
        if entry and entry.actionId then
            releaseSyntheticButtonRepeat(deviceKey, "analog:" .. stateKey, entry.actionId, entry.source or source)
        end
        state[stateKey] = nil
    end

    local function startCurrent()
        local oppositeKey = axisKey .. ":" .. (directionKey == "negative" and "positive" or "negative")
        if state[oppositeKey] then
            local opposite = state[oppositeKey]
            if opposite and opposite.actionId then
                releaseSyntheticButtonRepeat(deviceKey, "analog:" .. oppositeKey, opposite.actionId, opposite.source or source)
            end
            state[oppositeKey] = nil
        end

        state[stateKey] = {
            pressed = true,
            actionId = actionId,
            source = source
        }
        pressSyntheticButtonRepeat(deviceKey, "analog:" .. stateKey, actionId, source)
    end

    if directionKey == "negative" then
        if value <= -GAMEPAD_AXIS_THRESHOLD then
            if not existing then
                startCurrent()
            else
                existing.source = source
            end
        elseif existing and value > -GAMEPAD_AXIS_RELEASE_THRESHOLD then
            releaseCurrent(existing)
        end
    else
        if value >= GAMEPAD_AXIS_THRESHOLD then
            if not existing then
                startCurrent()
            else
                existing.source = source
            end
        elseif existing and value < GAMEPAD_AXIS_RELEASE_THRESHOLD then
            releaseCurrent(existing)
        end
    end
end

local function processSteamInputSnapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.controller) ~= "table" then
        return
    end

    local controller = snapshot.controller
    local handleId = tostring(controller.handleId or "")
    if handleId == "" then
        return
    end

    local source = resolveSteamInputSource(controller)
    local remoteSessionId = normalizeRemotePlaySessionId(controller.remotePlaySessionId)
    if remoteSessionId then
        local sawRemoteControllerInput = false
        for _, digital in ipairs(snapshot.digitalActions or {}) do
            if digital.active == true and digital.state == true then
                sawRemoteControllerInput = true
                break
            end
        end
        if not sawRemoteControllerInput then
            for _, analog in ipairs(snapshot.analogActions or {}) do
                local x = math.abs(tonumber(analog.x) or 0)
                local y = math.abs(tonumber(analog.y) or 0)
                if analog.active == true and (x >= GAMEPAD_AXIS_THRESHOLD or y >= GAMEPAD_AXIS_THRESHOLD) then
                    sawRemoteControllerInput = true
                    break
                end
            end
        end
        if sawRemoteControllerInput then
            noteRemotePlayNonMouseInput(remoteSessionId)
        end
    end
    local deviceKey = "steam:" .. handleId
    local handleState = steamInputHandleStates[handleId]
    if not handleState then
        handleState = {
            digital = {},
            analog = {}
        }
        steamInputHandleStates[handleId] = handleState
    end

    local seenDigital = {}
    for _, digital in ipairs(snapshot.digitalActions or {}) do
        local actionName = tostring(digital.name or "")
        local actionId = STEAM_INPUT_DIGITAL_TO_ACTION[actionName]
        if actionId then
            seenDigital[actionName] = true
            local pressed = digital.active == true and digital.state == true
            local digitalState = handleState.digital[actionName]
            if pressed then
                if not digitalState or digitalState.pressed ~= true then
                    handleState.digital[actionName] = {
                        pressed = true,
                        actionId = actionId,
                        source = source
                    }
                    handleButtonActionPressed(deviceKey, "digital:" .. actionName, actionId, source)
                else
                    digitalState.source = source
                end
            elseif (digitalState and digitalState.pressed == true)
                or isHeldInputSuppressed(deviceKey, "digital:" .. actionName)
                or getOneShotLatch(deviceKey, "digital:" .. actionName) then
                handleButtonActionReleased(deviceKey, "digital:" .. actionName, actionId, digitalState and (digitalState.source or source) or source)
                handleState.digital[actionName] = nil
            end
        end
    end

    for actionName, digitalState in pairs(handleState.digital) do
        if seenDigital[actionName] ~= true and ((digitalState and digitalState.pressed == true)
            or isHeldInputSuppressed(deviceKey, "digital:" .. actionName)
            or getOneShotLatch(deviceKey, "digital:" .. actionName)) then
            handleButtonActionReleased(deviceKey, "digital:" .. actionName, digitalState and digitalState.actionId or STEAM_INPUT_DIGITAL_TO_ACTION[actionName], digitalState and (digitalState.source or source) or source)
            handleState.digital[actionName] = nil
        end
    end

    for _, actionName in ipairs(STEAM_INPUT_DIGITAL_ACTION_NAMES) do
        if seenDigital[actionName] ~= true and handleState.digital[actionName] == nil and
            (isHeldInputSuppressed(deviceKey, "digital:" .. actionName) or getOneShotLatch(deviceKey, "digital:" .. actionName)) then
            handleButtonActionReleased(deviceKey, "digital:" .. actionName, STEAM_INPUT_DIGITAL_TO_ACTION[actionName], source)
        end
    end

    local seenAnalogPrefixes = {}
    for _, analog in ipairs(snapshot.analogActions or {}) do
        local actionName = tostring(analog.name or "")
        local mapping = STEAM_INPUT_ANALOG_TO_NAVIGATION[actionName]
        if mapping then
            seenAnalogPrefixes[actionName] = true
            if analog.active == true then
                if mapping.x then
                    if mapping.x.negative then
                        updateSteamInputAnalogDirection(handleState.analog, deviceKey, actionName .. ":x", tonumber(analog.x) or 0, "negative", mapping.x.negative, source)
                    end
                    if mapping.x.positive then
                        updateSteamInputAnalogDirection(handleState.analog, deviceKey, actionName .. ":x", tonumber(analog.x) or 0, "positive", mapping.x.positive, source)
                    end
                end
                if mapping.y then
                    if mapping.y.negative then
                        updateSteamInputAnalogDirection(handleState.analog, deviceKey, actionName .. ":y", tonumber(analog.y) or 0, "negative", mapping.y.negative, source)
                    end
                    if mapping.y.positive then
                        updateSteamInputAnalogDirection(handleState.analog, deviceKey, actionName .. ":y", tonumber(analog.y) or 0, "positive", mapping.y.positive, source)
                    end
                end
            else
                for _, suffix in ipairs({"x:negative", "x:positive", "y:negative", "y:positive"}) do
                    local axisStateKey = actionName .. ":" .. suffix
                    local axisState = handleState.analog[axisStateKey]
                    if axisState and axisState.actionId then
                        releaseSyntheticButtonRepeat(deviceKey, "analog:" .. axisStateKey, axisState.actionId, axisState.source or source)
                    end
                    handleState.analog[axisStateKey] = nil
                end
            end
        end
    end

    for axisStateKey, axisState in pairs(handleState.analog) do
        local actionName = axisStateKey:match("^(.-):[xy]:")
        if actionName and seenAnalogPrefixes[actionName] ~= true and axisState and axisState.actionId then
            releaseSyntheticButtonRepeat(deviceKey, "analog:" .. axisStateKey, axisState.actionId, axisState.source or source)
            handleState.analog[axisStateKey] = nil
        end
    end
end

local function processSteamInputBackend()
    if not ensureSteamInputBackendConfigured() then
        return
    end

    local snapshots = steamRuntime.pollSteamInputActions()
    if type(snapshots) ~= "table" then
        return
    end

    steamInputLastControllerCount = #snapshots

    local seenHandles = {}
    for _, snapshot in ipairs(snapshots) do
        local controller = type(snapshot) == "table" and snapshot.controller or nil
        local handleId = controller and tostring(controller.handleId or "") or ""
        if handleId ~= "" then
            seenHandles[handleId] = true
        end
        processSteamInputSnapshot(snapshot)
    end

    for handleId in pairs(steamInputHandleStates) do
        if seenHandles[handleId] ~= true then
            clearSteamInputHandleState(handleId)
        end
    end
end

local function processRemotePlayDirectInput()
    local inRemotePlayState = isRemotePlayInputStateName(currentStateName)
    local shouldEnable = inRemotePlayState and isRemotePlayLocalVariantActive() and
        steamRuntime.isOnlineReady and steamRuntime.isOnlineReady()

    if shouldEnable and not remotePlayDirectInputActive then
        setRemotePlayDirectInputActive(true)
    elseif (not shouldEnable) and remotePlayDirectInputActive then
        setRemotePlayDirectInputActive(false)
    end

    if not remotePlayDirectInputActive then
        return
    end
    if type(steamRuntime.pollRemotePlayInput) ~= "function" then
        return
    end

    local events = steamRuntime.pollRemotePlayInput(64)
    if type(events) ~= "table" or #events == 0 then
        return
    end

    for _, event in ipairs(events) do
        processRemotePlayDirectInputEvent(event)
    end
end

local function ensureOnlineRuntimeState()
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    local online = GAME.CURRENT.ONLINE
    online.pendingLobbyEvents = online.pendingLobbyEvents or {}
    if online.pendingInvitePrompt == nil then
        online.pendingInvitePrompt = nil
    end
    if online.pendingInviteJoinLobbyId == nil then
        online.pendingInviteJoinLobbyId = nil
    end
    if online.lastInvitePromptKey == nil then
        online.lastInvitePromptKey = nil
    end
    if online.lastInvitePromptAt == nil then
        online.lastInvitePromptAt = 0
    end
    return online
end

local INVITE_PROMPT_DEDUPE_SEC = 2.0

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function resolveInvitePromptPayload(event)
    if type(event) ~= "table" or not event.lobbyId then
        return nil
    end

    local inviterId = event.memberId and tostring(event.memberId) or nil
    local inviterName = nil
    if inviterId and steamRuntime.getPersonaNameForUser then
        inviterName = steamRuntime.getPersonaNameForUser(inviterId)
    end
    if not inviterName or inviterName == "" then
        if inviterId and inviterId ~= "" then
            inviterName = "Player " .. inviterId:sub(-6)
        else
            inviterName = "a player"
        end
    end

    local lobbyId = tostring(event.lobbyId)
    local dedupeKey = lobbyId .. "|" .. tostring(inviterId or "")
    return {
        lobbyId = lobbyId,
        inviterId = inviterId,
        inviterName = inviterName,
        dedupeKey = dedupeKey
    }
end

local function enqueueOnlineLobbyEvent(event)
    if type(event) ~= "table" then
        return
    end

    local online = ensureOnlineRuntimeState()
    local queue = online.pendingLobbyEvents
    queue[#queue + 1] = event

    local maxQueue = 128
    while #queue > maxQueue do
        table.remove(queue, 1)
    end
end

local function processGlobalOnlineLobbyEvents()
    if not steamRuntime or not steamRuntime.isOnlineReady or not steamRuntime.isOnlineReady() then
        return
    end

    local events = steamRuntime.pollLobbyEvents(32)
    if type(events) == "table" and #events > 0 then
        for _, event in ipairs(events) do
            local eventType = type(event) == "table" and tostring(event.type or "") or ""
            local isInviteReceived = eventType == "lobby_invite_received" and event and event.lobbyId
            local isInviteRequested = eventType == "lobby_invite_requested" and event and event.lobbyId and tostring(event.result or "") == "requested"

            if isInviteReceived or isInviteRequested then
                local online = ensureOnlineRuntimeState()
                local payload = resolveInvitePromptPayload(event)
                if payload then
                    local current = nowSeconds()
                    local pending = online.pendingInvitePrompt
                    local isDuplicateRecent = online.lastInvitePromptKey == payload.dedupeKey and
                        (current - (tonumber(online.lastInvitePromptAt) or 0)) < INVITE_PROMPT_DEDUPE_SEC
                    local isDuplicatePending = type(pending) == "table" and pending.dedupeKey == payload.dedupeKey

                    if not isDuplicateRecent and not isDuplicatePending then
                        online.pendingInvitePrompt = payload
                        online.lastInvitePromptKey = payload.dedupeKey
                        online.lastInvitePromptAt = current
                    end
                end
            else
                enqueueOnlineLobbyEvent(event)
            end
        end
    end

    local online = ensureOnlineRuntimeState()
    local invitePrompt = online.pendingInvitePrompt
    if invitePrompt and invitePrompt.lobbyId and ConfirmDialog and ConfirmDialog.isActive and not ConfirmDialog.isActive() then
        ConfirmDialog.show(
            "You are invited by " .. tostring(invitePrompt.inviterName or "a player") .. ". Join?",
            function()
                local runtimeOnline = ensureOnlineRuntimeState()
                runtimeOnline.pendingInviteJoinLobbyId = tostring(invitePrompt.lobbyId)
                runtimeOnline.pendingInvitePrompt = nil
                if currentStateName ~= "onlineLobby" and states.onlineLobby then
                    stateMachine.changeState("onlineLobby")
                end
            end,
            function()
                local runtimeOnline = ensureOnlineRuntimeState()
                runtimeOnline.pendingInvitePrompt = nil
            end,
            {
                title = "Game Invite",
                confirmText = "Join",
                cancelText = "Reject",
                defaultFocus = "confirm"
            }
        )
    end
end

function stateMachine.changeState(newState)
    local leavingRemotePlayInput = isRemotePlayInputStateName(currentStateName) and isRemotePlayLocalVariantActive() and
        (not isRemotePlayInputStateName(newState))
    local leavingSteamInputState = inputBackend.isSteamInputEligibleState(currentStateName) and
        not inputBackend.isSteamInputEligibleState(newState)

    if leavingRemotePlayInput then
        if remotePlayDirectInputActive then
            setRemotePlayDirectInputActive(false)
        end
        audioRuntime.logRemotePlayWindowSummary("remote_play_input_exit")
        hideAllRemotePlayCursors()
        if hasActiveRemotePlaySession() then
            queueRemotePlayExitPrompt()
        end
        resetRemotePlayJoystickSourceCache()
    elseif remotePlayDirectInputActive and not isRemotePlayInputStateName(newState) then
        setRemotePlayDirectInputActive(false)
        hideAllRemotePlayCursors()
    end

    if leavingSteamInputState and steamInputBackendActive and steamRuntime and type(steamRuntime.shutdownSteamInput) == "function" then
        steamRuntime.shutdownSteamInput()
        resetSteamInputBackendState()
    elseif leavingSteamInputState then
        resetSteamInputBackendState()
    end

    resetTransientInputState()

    if currentState and currentState.exit then
        currentState.exit()
    end

    currentState = states[newState]
    currentStateName = newState

    if GAME and GAME.CURRENT then
        GAME.CURRENT.STATE_MACHINE = stateMachine
    end

    if currentState and currentState.enter then
        currentState.enter(stateMachine)
    end

    applyRemotePlayCursorPolicyForState(currentStateName)
end

function stateMachine.resetTransientInputs(reason)
    resetTransientInputState()
end

function stateMachine.update(dt)
    updateAxisRepeatTimers(dt)
    updateButtonRepeatTimers(dt)
    processGlobalOnlineLobbyEvents()
    processRemotePlayDirectInput()
    processSteamInputBackend()
    if currentState and currentState.update then
        currentState.update(dt)
    end
end

function stateMachine.getCurrentStateName()
    return currentStateName
end

function stateMachine.getCurrentInputSourceContext()
    return {
        kind = currentInputSource and currentInputSource.kind or "unknown",
        isRemote = currentInputSource and currentInputSource.isRemote == true or false,
        sessionId = currentInputSource and currentInputSource.sessionId or nil
    }
end

function stateMachine.draw()
    if currentState and currentState.draw then
        currentState.draw()
    end
end

function stateMachine.resize(w, h)
    updateScaling()
    if currentState and currentState.resize then
        currentState.resize(w, h)
    end
end

-- Mouse input
function stateMachine.mousemoved(x, y, dx, dy, istouch, sourceOverride)
    local source = sourceOverride or hostKeyboardMouseSource()
    return withInputSource(source, function()
        local sourceKind = tostring(source and source.kind or "")
        local fromHostMouse = sourceKind == "host_local_keyboard_mouse"

        -- Show the host mouse cursor only for host-local mouse movement.
        if fromHostMouse and MOUSE_STATE.IS_HIDDEN and (math.abs(dx) > 0 or math.abs(dy) > 0) then
            love.mouse.setVisible(true)
            MOUSE_STATE.IS_HIDDEN = false
        end

        if currentState and currentState.mousemoved then
            return currentState.mousemoved(x, y, dx, dy, istouch)
        end
        return nil
    end)
end

function stateMachine.mousepressed(x, y, button, istouch, presses, sourceOverride)
    local source = sourceOverride or hostKeyboardMouseSource()
    return withInputSource(source, function()
        if currentState and currentState.mousepressed then
            return currentState.mousepressed(x, y, button, istouch, presses)
        end
        return nil
    end)
end

function stateMachine.mousereleased(x, y, button, istouch, presses, sourceOverride)
    local source = sourceOverride or hostKeyboardMouseSource()
    return withInputSource(source, function()
        if currentState and currentState.mousereleased then
            return currentState.mousereleased(x, y, button, istouch, presses)
        end
        return nil
    end)
end

function stateMachine.wheelmoved(x, y, sourceOverride)
    local source = sourceOverride or hostKeyboardMouseSource()
    return withInputSource(source, function()
        if currentState and currentState.wheelmoved then
            return currentState.wheelmoved(x, y)
        end
        return nil
    end)
end

-- Touch input
function stateMachine.touchpressed(id, x, y, dx, dy, pressure)
    if touchPrimaryOnlyEnabled() then
        if primaryTouchId == nil then
            primaryTouchId = id
        elseif primaryTouchId ~= id then
            return
        end
    end

    local screenX, screenY = touchToScreen(x, y)
    activeTouches[id] = { x = screenX, y = screenY }
    stateMachine.mousepressed(screenX, screenY, 1, true, 1, hostKeyboardMouseSource())
    return withInputSource(hostKeyboardMouseSource(), function()
        if currentState and currentState.touchpressed then
            return currentState.touchpressed(id, x, y, dx, dy, pressure)
        end
        return nil
    end)
end

function stateMachine.touchmoved(id, x, y, dx, dy, pressure)
    if touchPrimaryOnlyEnabled() and primaryTouchId ~= nil and primaryTouchId ~= id then
        return
    end

    local screenX, screenY = touchToScreen(x, y)
    local deltaX, deltaY = touchDeltaToScreen(dx or 0, dy or 0)
    stateMachine.mousemoved(screenX, screenY, deltaX, deltaY, true, hostKeyboardMouseSource())
    if activeTouches[id] then
        activeTouches[id].x = screenX
        activeTouches[id].y = screenY
    end
    return withInputSource(hostKeyboardMouseSource(), function()
        if currentState and currentState.touchmoved then
            return currentState.touchmoved(id, x, y, dx, dy, pressure)
        end
        return nil
    end)
end

function stateMachine.touchreleased(id, x, y, dx, dy, pressure)
    if touchPrimaryOnlyEnabled() and primaryTouchId ~= nil and primaryTouchId ~= id then
        activeTouches[id] = nil
        return
    end

    local screenX, screenY = touchToScreen(x, y)
    stateMachine.mousereleased(screenX, screenY, 1, true, 1, hostKeyboardMouseSource())
    activeTouches[id] = nil
    if id == primaryTouchId then
        primaryTouchId = nil
    end
    return withInputSource(hostKeyboardMouseSource(), function()
        if currentState and currentState.touchreleased then
            return currentState.touchreleased(id, x, y, dx, dy, pressure)
        end
        return nil
    end)
end

-- Keyboard input
function stateMachine.keyreleased(key, scancode, sourceOverride)
    local source = sourceOverride or hostKeyboardMouseSource()
    return withInputSource(source, function()
        if currentState and currentState.keyreleased then
            return currentState.keyreleased(key, scancode)
        end
        return nil
    end)
end

function stateMachine.keypressed(key, scancode, isrepeat, sourceOverride)
    local source = sourceOverride or hostKeyboardMouseSource()
    return withInputSource(source, function()
        local sourceKind = tostring(source and source.kind or "")
        local fromHostLocal = (
            sourceKind == "host_local_keyboard_mouse" or
            sourceKind == "host_local_controller" or
            sourceKind == "steam_input_host_local"
        )

        -- Hide the mouse cursor only for host-local control paths.
        if fromHostLocal and not MOUSE_STATE.IS_HIDDEN then
            love.mouse.setVisible(false)
            MOUSE_STATE.IS_HIDDEN = true
        end

        -- Pass the key event to the current state
        if currentState and currentState.keypressed then
            return currentState.keypressed(key, scancode, isrepeat)
        end
        return nil
    end)
end

return stateMachine
