local steamRuntime = {}

local DEFAULT_BRIDGE_MODULE = "integrations.steam.bridge"

local state = {
    enabled = false,
    initialized = false,
    initAttempted = false,
    lastInitAttemptAt = 0,
    mode = "disabled",
    appId = nil,
    bridgeModule = nil,
    bridge = nil,
    lastError = nil,
    lastOfflineLog = nil,
    lastLoggedError = nil,
    lastErrorLogPath = nil,
    logPathPrinted = false,
    logWriteFailurePrinted = false,
    seededLeaderboards = {},
    remotePlayDirectInputEnabled = false,
    remotePlayLastInputAt = nil,
    remotePlayInputSources = {},
    steamInputConfigured = false,
    steamInputManifestPath = nil,
    steamInputActionSet = nil,
    steamInputLastPollAt = nil,
    steamInputLastError = nil,
    steamInputControllers = {},
    userStatsLastError = nil,
    userStatsLastStoreAt = nil
}

local INIT_RETRY_COOLDOWN_SEC = 2.0
local ERROR_LOG_FILE = "SteamRuntimeError.log"

local function steamConfig()
    local settings = SETTINGS or {}
    return settings.STEAM or {}
end

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function timestampNow()
    if type(os) == "table" and type(os.date) == "function" then
        local ok, value = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if ok and type(value) == "string" then
            return value
        end
    end
    return "time_unavailable"
end

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:gsub("\\", "/")
end

local function joinPath(base, leaf)
    base = normalizePath(base)
    if not base then
        return leaf
    end
    if base:sub(-1) == "/" then
        return base .. leaf
    end
    return base .. "/" .. leaf
end

local function fileExists(path)
    path = normalizePath(path)
    if not path then
        return false
    end

    local file = io.open(path, "rb")
    if not file then
        return false
    end

    file:close()
    return true
end

local function getFilesystemPathInfo()
    local info = {
        source = nil,
        sourceBaseDir = nil,
        workingDir = nil
    }

    if love and love.filesystem then
        if type(love.filesystem.getSource) == "function" then
            local okSource, source = pcall(love.filesystem.getSource)
            if okSource and type(source) == "string" and source ~= "" then
                info.source = normalizePath(source)
            end
        end

        if type(love.filesystem.getSourceBaseDirectory) == "function" then
            local okBase, sourceBase = pcall(love.filesystem.getSourceBaseDirectory)
            if okBase and type(sourceBase) == "string" and sourceBase ~= "" then
                info.sourceBaseDir = normalizePath(sourceBase)
            end
        end

        if type(love.filesystem.getWorkingDirectory) == "function" then
            local okWorking, workingDir = pcall(love.filesystem.getWorkingDirectory)
            if okWorking and type(workingDir) == "string" and workingDir ~= "" then
                info.workingDir = normalizePath(workingDir)
            end
        end
    end

    return info
end

local function resolveSourceRoot()
    local info = getFilesystemPathInfo()
    if info.sourceBaseDir then
        return info.sourceBaseDir
    end
    if info.workingDir then
        return info.workingDir
    end
    return normalizePath(".")
end

local function hasLocalSteamAppIdOverrideFile()
    local info = getFilesystemPathInfo()
    local candidates = {}
    local seen = {}

    local function add(path)
        path = normalizePath(path)
        if not path or seen[path] then
            return
        end
        seen[path] = true
        candidates[#candidates + 1] = path
    end

    if info.sourceBaseDir then
        add(joinPath(info.sourceBaseDir, "steam_appid.txt"))
    end
    if info.workingDir then
        add(joinPath(info.workingDir, "steam_appid.txt"))
    end

    for _, candidate in ipairs(candidates) do
        if fileExists(candidate) then
            return true
        end
    end

    return false
end

local function collectErrorLogPaths()
    local paths = {}
    local seen = {}

    local function add(path)
        path = normalizePath(path)
        if not path or seen[path] then
            return
        end
        seen[path] = true
        paths[#paths + 1] = path
    end

    if love and love.filesystem and type(love.filesystem.getSaveDirectory) == "function" then
        local okSave, saveDir = pcall(love.filesystem.getSaveDirectory)
        if okSave and type(saveDir) == "string" and saveDir ~= "" then
            add(joinPath(saveDir, ERROR_LOG_FILE))
        end
    end

    local info = getFilesystemPathInfo()
    if info.sourceBaseDir then
        add(joinPath(info.sourceBaseDir, ERROR_LOG_FILE))
    end
    if info.workingDir then
        add(joinPath(info.workingDir, ERROR_LOG_FILE))
    end

    add(joinPath(".", ERROR_LOG_FILE))

    return paths
end

local function writeSteamLogLine(line)
    if type(line) ~= "string" or line == "" then
        return
    end

    local savePath = nil
    if love and love.filesystem and type(love.filesystem.getSaveDirectory) == "function" then
        local okSave, saveDir = pcall(love.filesystem.getSaveDirectory)
        if okSave and type(saveDir) == "string" and saveDir ~= "" then
            savePath = joinPath(saveDir, ERROR_LOG_FILE)
        end
    end

    if love and love.filesystem then
        if type(love.filesystem.append) == "function" then
            local okCall, okAppend = pcall(love.filesystem.append, ERROR_LOG_FILE, line .. "\n")
            if okCall and okAppend then
                state.lastErrorLogPath = savePath or ERROR_LOG_FILE
                state.logWriteFailurePrinted = false
                return
            end
        end

        if type(love.filesystem.write) == "function" and type(love.filesystem.read) == "function" then
            local current = ""
            local okRead, existing = pcall(love.filesystem.read, ERROR_LOG_FILE)
            if okRead and type(existing) == "string" then
                current = existing
            end

            local okWriteCall, okWrite = pcall(love.filesystem.write, ERROR_LOG_FILE, current .. line .. "\n")
            if okWriteCall and okWrite then
                state.lastErrorLogPath = savePath or ERROR_LOG_FILE
                state.logWriteFailurePrinted = false
                return
            end
        end
    end

    local paths = collectErrorLogPaths()
    for _, path in ipairs(paths) do
        local file = io.open(path, "a")
        if file then
            file:write(line .. "\n")
            file:close()
            state.lastErrorLogPath = path
            state.logWriteFailurePrinted = false
            return
        end
    end

    if not state.logWriteFailurePrinted then
        state.logWriteFailurePrinted = true
        print("[Steam] Failed to write " .. ERROR_LOG_FILE .. " in all candidate locations")
    end
end

local function shouldPrintSteamLog()
    return (((SETTINGS or {}).STEAM or {}).DEBUG_LOGS == true)
end

local function log(message)
    local text = tostring(message)
    if shouldPrintSteamLog() then
        print("[Steam] " .. text)
    end
    writeSteamLogLine(string.format("[%s] [INFO] %s", timestampNow(), text))
end

local function appendErrorLog(errorText)
    if type(errorText) ~= "string" or errorText == "" then
        return
    end

    if state.lastLoggedError == errorText then
        return
    end

    local line = string.format("[%s] [ERROR] %s", timestampNow(), errorText)
    writeSteamLogLine(line)
    state.lastLoggedError = errorText
end

local function buildNativeLoadHint(errorText)
    local text = tostring(errorText or "")
    local lower = text:lower()

    if lower:find("procedure_not_found", 1, true) or lower:find("specified procedure could not be found", 1, true) then
        return "Native module loaded but symbol resolution failed. Rebuild bridge against LOVE 11.5 lua51.dll ABI."
    end

    if lower:find("module_not_found", 1, true) then
        return "steam_bridge_native module not found. Verify redist path and package.cpath entries."
    end

    if lower:find("dependency_missing", 1, true) or lower:find("specified module could not be found", 1, true) then
        return "A dependent DLL is missing. Verify steam_api64.dll beside steam_bridge_native.dll and run from x64 LOVE."
    end

    if lower:find("steam_api_init_failed", 1, true) then
        local appId = tostring((SETTINGS and SETTINGS.STEAM and SETTINGS.STEAM.APP_ID) or "unknown")
        return "Steam API initialization failed. Ensure Steam client is running and AppID " .. appId .. " is active."
    end

    return nil
end

local function safeCall(label, fn, ...)
    local ok, resultA, resultB, resultC = pcall(fn, ...)
    if not ok then
        state.lastError = tostring(resultA)
        log(label .. " failed: " .. state.lastError)
        return false, nil, nil, nil
    end
    return true, resultA, resultB, resultC
end

local function bridgeCall(methodName, label, ...)
    if not state.initialized or not state.bridge then
        return false, "steam_runtime_not_initialized"
    end

    local fn = state.bridge[methodName]
    if type(fn) ~= "function" then
        return false, "bridge_method_missing:" .. tostring(methodName)
    end

    local ok, a, b, c = safeCall(label or methodName, fn, ...)
    if not ok then
        return false, state.lastError or "bridge_call_failed"
    end

    return true, a, b, c
end

local function loadBridge(moduleName)
    local ok, moduleOrError = pcall(require, moduleName)
    if not ok then
        return nil, tostring(moduleOrError)
    end
    if type(moduleOrError) ~= "table" then
        return nil, "bridge module did not return a table"
    end
    return moduleOrError, nil
end

local function buildInitOptions(config)
    local useLocalAppIdOverride = hasLocalSteamAppIdOverrideFile()
    local appIdForNative = useLocalAppIdOverride and config.APP_ID or ""
    return {
        appId = appIdForNative,
        autoRestartAppIfNeeded = config.AUTO_RESTART_APP_IF_NEEDED == true and appIdForNative ~= "",
        required = config.REQUIRED == true,
        debugLogs = config.DEBUG_LOGS == true,
        sdkRoot = config.SDK_ROOT,
        redistributableRoot = config.REDISTRIBUTABLE_ROOT
    }
end

local function normalizeSteamId(value)
    if value == nil then
        return nil
    end
    local asString = tostring(value)
    asString = asString:gsub("^%s+", ""):gsub("%s+$", "")
    if asString == "" or asString == "0" or asString == "0.0" then
        return nil
    end
    return asString
end

local function normalizeLobbyPayload(payload)
    if payload == nil then
        return nil
    end

    if type(payload) ~= "table" then
        return {
            lobbyId = normalizeSteamId(payload)
        }
    end

    local normalized = {
        lobbyId = normalizeSteamId(payload.lobbyId or payload.id or payload.lobbyID),
        ownerId = normalizeSteamId(payload.ownerId or payload.owner or payload.ownerSteamId),
        ownerName = payload.ownerName and tostring(payload.ownerName) or "",
        enterResponse = tonumber(payload.enterResponse or payload.chatRoomEnterResponse),
        sessionId = payload.sessionId or payload.session_id,
        protocolVersion = payload.protocolVersion or payload.protocol_version
    }

    if type(payload.members) == "table" then
        normalized.members = {}
        local dedupe = {}
        for _, member in ipairs(payload.members) do
            local memberId = normalizeSteamId(member)
            if memberId and not dedupe[memberId] then
                dedupe[memberId] = true
                normalized.members[#normalized.members + 1] = memberId
            end
        end
    end

    return normalized
end

local function normalizeLobbyListEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local relation = tostring(entry.relation or "other")
    if relation ~= "friend" and relation ~= "friend_of_friend" then
        relation = "other"
    end

    local visibility = tostring(entry.visibility or entry.lobbyVisibility or entry.mom_visibility or "public")
    if visibility ~= "friends" then
        visibility = "public"
    end

    local normalized = {
        lobbyId = normalizeSteamId(entry.lobbyId or entry.id),
        ownerId = normalizeSteamId(entry.ownerId or entry.owner or entry.ownerSteamId),
        ownerName = entry.ownerName and tostring(entry.ownerName) or "",
        memberCount = math.max(0, tonumber(entry.memberCount or entry.members) or 0),
        memberLimit = math.max(0, tonumber(entry.memberLimit or entry.maxMembers) or 0),
        sessionId = entry.sessionId and tostring(entry.sessionId) or "",
        protocolVersion = entry.protocolVersion and tostring(entry.protocolVersion) or "",
        relation = relation,
        visibility = visibility,
        joinable = entry.joinable ~= false
    }

    if not normalized.lobbyId then
        return nil
    end

    return normalized
end

local function normalizeLobbyList(entries)
    if type(entries) ~= "table" then
        return {}
    end

    local normalized = {}
    for _, entry in ipairs(entries) do
        local item = normalizeLobbyListEntry(entry)
        if item then
            normalized[#normalized + 1] = item
        end
    end
    return normalized
end

local function normalizeLobbyEvent(event)
    if type(event) ~= "table" then
        return nil
    end

    local normalized = {
        type = event.type or event.kind or "unknown",
        lobbyId = normalizeSteamId(event.lobbyId or event.lobby_id),
        ownerId = normalizeSteamId(event.ownerId or event.owner_id),
        memberId = normalizeSteamId(event.memberId or event.member_id),
        result = event.result,
        memberState = tonumber(event.memberState or event.member_state)
    }

    return normalized
end

local function normalizeLobbyEvents(events)
    if type(events) ~= "table" then
        return {}
    end

    local normalized = {}
    for _, event in ipairs(events) do
        local entry = normalizeLobbyEvent(event)
        if entry then
            normalized[#normalized + 1] = entry
        end
    end

    return normalized
end

local function normalizeNetPacket(packet)
    if type(packet) ~= "table" then
        return nil
    end

    local payload = packet.payload
    if type(payload) ~= "string" then
        payload = payload and tostring(payload) or ""
    end

    local normalized = {
        peerId = normalizeSteamId(packet.peerId or packet.steamId or packet.userId or packet.id),
        channel = tonumber(packet.channel) or 0,
        payload = payload,
        recvTs = tonumber(packet.recvTs or packet.recv_ts) or 0
    }

    return normalized
end

local function normalizeNetPackets(packets)
    if type(packets) ~= "table" then
        return {}
    end

    local normalized = {}
    for _, packet in ipairs(packets) do
        local entry = normalizeNetPacket(packet)
        if entry then
            normalized[#normalized + 1] = entry
        end
    end
    return normalized
end

local function normalizeLeaderboardEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local details = {}
    if type(entry.details) == "table" then
        for _, value in ipairs(entry.details) do
            details[#details + 1] = tonumber(value) or 0
        end
    end

    return {
        userId = normalizeSteamId(entry.userId or entry.steamId or entry.id),
        score = tonumber(entry.score) or 0,
        rank = tonumber(entry.rank or entry.globalRank) or 0,
        details = details
    }
end

local function normalizeLeaderboardEntries(entries)
    if type(entries) ~= "table" then
        return {}
    end

    local normalized = {}
    for _, entry in ipairs(entries) do
        local item = normalizeLeaderboardEntry(entry)
        if item then
            normalized[#normalized + 1] = item
        end
    end

    return normalized
end

local function normalizeLeaderboardPayload(payload, fallbackName)
    if type(payload) ~= "table" then
        return {
            name = fallbackName,
            handle = payload and tostring(payload) or nil
        }
    end

    return {
        name = payload.name or fallbackName,
        handle = payload.handle and tostring(payload.handle) or nil
    }
end

local function normalizeRemotePlaySessionEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end

    return {
        sessionId = tonumber(entry.sessionId or entry.id) or 0,
        userId = normalizeSteamId(entry.userId or entry.steamId or entry.memberId),
        personaName = entry.personaName and tostring(entry.personaName) or "",
        clientName = entry.clientName and tostring(entry.clientName) or ""
    }
end

local function normalizeRemotePlaySessionList(entries)
    if type(entries) ~= "table" then
        return {}
    end

    local normalized = {}
    for _, entry in ipairs(entries) do
        local item = normalizeRemotePlaySessionEntry(entry)
        if item then
            normalized[#normalized + 1] = item
        end
    end
    return normalized
end

local function normalizeRemotePlayInputEvent(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local eventType = entry.type
    if eventType ~= nil then
        eventType = tostring(eventType)
    end

    return {
        sessionId = tonumber(entry.sessionId or entry.id) or 0,
        type = eventType or "unknown",
        mouseAbsolute = entry.mouseAbsolute == true,
        mouseNormalizedX = tonumber(entry.mouseNormalizedX) or 0,
        mouseNormalizedY = tonumber(entry.mouseNormalizedY) or 0,
        mouseDeltaX = tonumber(entry.mouseDeltaX) or 0,
        mouseDeltaY = tonumber(entry.mouseDeltaY) or 0,
        mouseButton = tonumber(entry.mouseButton) or 0,
        wheelDirection = tonumber(entry.wheelDirection) or 0,
        wheelAmount = tonumber(entry.wheelAmount) or 0,
        keyScancode = tonumber(entry.keyScancode) or 0,
        keyModifiers = tonumber(entry.keyModifiers) or 0,
        keyCode = tonumber(entry.keyCode) or 0
    }
end

local function normalizeRemotePlayInputEvents(entries)
    if type(entries) ~= "table" then
        return {}
    end

    local out = {}
    for _, entry in ipairs(entries) do
        local item = normalizeRemotePlayInputEvent(entry)
        if item then
            out[#out + 1] = item
        end
    end
    return out
end

local function normalizeSteamInputDigitalAction(entry)
    if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
        return nil
    end

    return {
        name = tostring(entry.name),
        state = entry.state == true,
        active = entry.active == true
    }
end

local function normalizeSteamInputAnalogAction(entry)
    if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
        return nil
    end

    return {
        name = tostring(entry.name),
        x = tonumber(entry.x) or 0,
        y = tonumber(entry.y) or 0,
        active = entry.active == true,
        mode = entry.mode and tostring(entry.mode) or "unknown"
    }
end

local function normalizeSteamInputController(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local handleId = entry.handleId and tostring(entry.handleId) or ""
    if handleId == "" then
        return nil
    end

    return {
        handleId = handleId,
        remotePlaySessionId = math.max(0, tonumber(entry.remotePlaySessionId) or 0),
        gamepadIndex = tonumber(entry.gamepadIndex) or -1,
        inputType = entry.inputType and tostring(entry.inputType) or "unknown"
    }
end

local function normalizeSteamInputControllerList(entries)
    if type(entries) ~= "table" then
        return {}
    end

    local out = {}
    for _, entry in ipairs(entries) do
        local item = normalizeSteamInputController(entry)
        if item then
            out[#out + 1] = item
        end
    end
    return out
end

local function normalizeSteamInputControllerSnapshot(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local controller = normalizeSteamInputController(entry.controller or entry)
    if not controller then
        return nil
    end

    local digitalActions = {}
    for _, action in ipairs(entry.digitalActions or {}) do
        local normalizedAction = normalizeSteamInputDigitalAction(action)
        if normalizedAction then
            digitalActions[#digitalActions + 1] = normalizedAction
        end
    end

    local analogActions = {}
    for _, action in ipairs(entry.analogActions or {}) do
        local normalizedAction = normalizeSteamInputAnalogAction(action)
        if normalizedAction then
            analogActions[#analogActions + 1] = normalizedAction
        end
    end

    return {
        controller = controller,
        digitalActions = digitalActions,
        analogActions = analogActions
    }
end

local function normalizeSteamInputSnapshots(entries)
    if type(entries) ~= "table" then
        return {}
    end

    local out = {}
    for _, entry in ipairs(entries) do
        local item = normalizeSteamInputControllerSnapshot(entry)
        if item then
            out[#out + 1] = item
        end
    end
    return out
end

local function collectKeys(source)
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

local function resolveSteamInputManifestPath(options)
    if type(options) ~= "table" then
        return nil
    end

    local explicitPath = normalizePath(options.manifestPath)
    if explicitPath and explicitPath ~= "" then
        return explicitPath
    end

    local manifestFile = options.manifestFile
    if type(manifestFile) ~= "string" or manifestFile == "" then
        return nil
    end

    local sourceRoot = resolveSourceRoot()
    if sourceRoot then
        return joinPath(sourceRoot, manifestFile)
    end
    return normalizePath(manifestFile)
end

local function unwrapSuccessPayload(a, b)
    if type(a) == "boolean" then
        if a then
            return true, b
        end
        return false, b
    end

    if a == nil then
        return false, b
    end

    return true, a
end

function steamRuntime.init(forceRetry)
    if state.initialized then
        return true
    end

    local now = nowSeconds()
    if (not forceRetry) and state.initAttempted and (now - (state.lastInitAttemptAt or 0)) < INIT_RETRY_COOLDOWN_SEC then
        return false
    end

    local config = steamConfig()
    state.initAttempted = true
    state.lastInitAttemptAt = now
    state.enabled = config.ENABLED == true
    state.appId = config.APP_ID
    state.bridgeModule = config.BRIDGE_MODULE or DEFAULT_BRIDGE_MODULE
    state.lastError = nil

    if not state.enabled then
        state.mode = "disabled"
        return false
    end

    local bridge, loadError = loadBridge(state.bridgeModule)
    if not bridge then
        state.mode = "missing_bridge"
        state.lastError = loadError
        if config.DEBUG_LOGS ~= false then
            log("Bridge module missing (" .. state.bridgeModule .. "): " .. tostring(loadError))
        end
        return false
    end

    state.bridge = bridge
    if type(bridge.init) ~= "function" then
        state.mode = "invalid_bridge"
        state.lastError = "bridge.init missing"
        log("Bridge module is invalid (missing init function)")
        return false
    end

    local ok, initialized, reason = safeCall("init", bridge.init, buildInitOptions(config))
    if not ok then
        state.mode = "init_error"
        state.initialized = false
        return false
    end

    local initSuccess, initPayload = unwrapSuccessPayload(initialized, reason)
    state.initialized = initSuccess == true

    if state.initialized then
        state.mode = "online"
        state.lastOfflineLog = nil
        state.lastLoggedError = nil
        if config.DEBUG_LOGS == true then
            log("Initialized with bridge '" .. tostring(state.bridgeModule) .. "' (AppID=" .. tostring(state.appId) .. ")")
        end
        return true
    end

    state.mode = "offline"
    state.lastError = tostring(initPayload or "bridge declined initialization")
    appendErrorLog(state.lastError)

    local offlineLog = "Running without Steam runtime: " .. state.lastError
    if state.lastOfflineLog ~= offlineLog then
        log(offlineLog)
        state.lastOfflineLog = offlineLog

        local hint = buildNativeLoadHint(state.lastError)
        if hint then
            log("Diagnostics hint: " .. hint)
        end
    end

    if state.lastErrorLogPath and not state.logPathPrinted then
        log("Diagnostics log path: " .. tostring(state.lastErrorLogPath))
        state.logPathPrinted = true
    end

    return false
end

function steamRuntime.update(dt)
    if state.enabled and not state.initialized then
        steamRuntime.init(false)
    end

    if not state.initialized or not state.bridge then
        return
    end

    if type(state.bridge.runCallbacks) == "function" then
        safeCall("runCallbacks", state.bridge.runCallbacks, dt)
    elseif type(state.bridge.update) == "function" then
        safeCall("update", state.bridge.update, dt)
    end
end

function steamRuntime.shutdown()
    if state.bridge and type(state.bridge.shutdownSteamInput) == "function" and state.steamInputConfigured == true then
        safeCall("shutdownSteamInput", state.bridge.shutdownSteamInput)
    end
    if state.bridge and type(state.bridge.shutdown) == "function" then
        safeCall("shutdown", state.bridge.shutdown)
    end
    state.initialized = false
    state.initAttempted = false
    state.mode = state.enabled and "offline" or "disabled"
    state.lastOfflineLog = nil
    state.seededLeaderboards = {}
    state.remotePlayDirectInputEnabled = false
    state.remotePlayLastInputAt = nil
    state.remotePlayInputSources = {}
    state.steamInputConfigured = false
    state.steamInputManifestPath = nil
    state.steamInputActionSet = nil
    state.steamInputLastPollAt = nil
    state.steamInputLastError = nil
    state.steamInputControllers = {}
    state.userStatsLastError = nil
    state.userStatsLastStoreAt = nil
end

function steamRuntime.isEnabled()
    return state.enabled
end

function steamRuntime.isInitialized()
    return state.initialized
end

function steamRuntime.getMode()
    return state.mode
end

function steamRuntime.getLastError()
    return state.lastError
end

function steamRuntime.getErrorLogPath()
    return state.lastErrorLogPath
end

function steamRuntime.getStateSnapshot()
    return {
        enabled = state.enabled,
        initialized = state.initialized,
        mode = state.mode,
        appId = state.appId,
        bridgeModule = state.bridgeModule,
        lastError = state.lastError
    }
end

function steamRuntime.onGuideButtonPressed()
    if not state.initialized or not state.bridge then
        return false
    end

    local config = steamConfig()
    local target = config.GUIDE_BUTTON_OVERLAY or "Friends"

    local ok, a = bridgeCall("activateOverlay", "activateOverlay", target)
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a)
    return success == true
end

function steamRuntime.setRichPresence(key, value)
    local ok, a = bridgeCall("setRichPresence", "setRichPresence", key, value)
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a)
    return success == true
end

function steamRuntime.clearRichPresence()
    local ok, a = bridgeCall("clearRichPresence", "clearRichPresence")
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a)
    return success == true
end

function steamRuntime.showRemotePlayTogetherUI()
    local ok, a, b = bridgeCall("showRemotePlayTogetherUI", "showRemotePlayTogetherUI")
    if not ok then
        return false, b
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return false, payload or "remote_play_ui_unavailable"
    end

    return true
end

function steamRuntime.getRemotePlaySessionCount()
    local ok, a, b = bridgeCall("getRemotePlaySessionCount", "getRemotePlaySessionCount")
    if not ok then
        return 0
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return 0
    end

    return math.max(0, tonumber(payload) or 0)
end

function steamRuntime.listRemotePlaySessions()
    local ok, a, b = bridgeCall("listRemotePlaySessions", "listRemotePlaySessions")
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return {}
    end

    return normalizeRemotePlaySessionList(payload)
end

function steamRuntime.setRemotePlayDirectInputEnabled(enabled)
    local desired = enabled == true
    local ok, a, b = bridgeCall("setRemotePlayDirectInputEnabled", "setRemotePlayDirectInputEnabled", desired)
    if not ok then
        return false, b
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return false, payload or "remote_play_direct_input_unavailable"
    end

    state.remotePlayDirectInputEnabled = desired
    if not desired then
        state.remotePlayInputSources = {}
    end
    return true
end

function steamRuntime.pollRemotePlayInput(maxEvents)
    local limit = tonumber(maxEvents) or 64
    limit = math.max(1, math.min(math.floor(limit), 256))

    local ok, a, b = bridgeCall("pollRemotePlayInput", "pollRemotePlayInput", limit)
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return {}
    end

    local events = normalizeRemotePlayInputEvents(payload)
    if #events > 0 then
        state.remotePlayLastInputAt = nowSeconds()
        for _, event in ipairs(events) do
            local eventType = tostring(event.type or "unknown")
            state.remotePlayInputSources[eventType] = true
        end
    end
    return events
end

function steamRuntime.setRemotePlayMouseVisibility(sessionId, visible)
    local normalizedSessionId = tonumber(sessionId)
    if not normalizedSessionId or normalizedSessionId <= 0 then
        return false, "invalid_remote_play_session"
    end
    local ok, a, b = bridgeCall("setRemotePlayMouseVisibility", "setRemotePlayMouseVisibility", normalizedSessionId, visible == true)
    if not ok then
        return false, b
    end
    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return false, payload or "remote_play_mouse_visibility_failed"
    end
    return true
end

function steamRuntime.setRemotePlayMouseCursor(sessionId, cursorKind)
    local normalizedSessionId = tonumber(sessionId)
    if not normalizedSessionId or normalizedSessionId <= 0 then
        return false, "invalid_remote_play_session"
    end
    local normalizedCursorKind = tostring(cursorKind or "hidden")
    local ok, a, b = bridgeCall("setRemotePlayMouseCursor", "setRemotePlayMouseCursor", normalizedSessionId, normalizedCursorKind)
    if not ok then
        return false, b
    end
    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return false, payload or "remote_play_mouse_cursor_failed"
    end
    return true
end

function steamRuntime.setRemotePlayMousePosition(sessionId, normalizedX, normalizedY)
    local normalizedSessionId = tonumber(sessionId)
    if not normalizedSessionId or normalizedSessionId <= 0 then
        return false, "invalid_remote_play_session"
    end
    local x = math.max(0, math.min(1, tonumber(normalizedX) or 0))
    local y = math.max(0, math.min(1, tonumber(normalizedY) or 0))
    local ok, a, b = bridgeCall("setRemotePlayMousePosition", "setRemotePlayMousePosition", normalizedSessionId, x, y)
    if not ok then
        return false, b
    end
    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return false, payload or "remote_play_mouse_position_failed"
    end
    return true
end

function steamRuntime.getRemotePlayInputDiagnostics()
    local connectedSessions = steamRuntime.getRemotePlaySessionCount()
    local now = nowSeconds()
    local secondsSinceLastInput = nil
    if state.remotePlayLastInputAt then
        secondsSinceLastInput = math.max(0, now - tonumber(state.remotePlayLastInputAt))
    end

    local sources = {}
    for source, present in pairs(state.remotePlayInputSources or {}) do
        if present then
            sources[#sources + 1] = source
        end
    end
    table.sort(sources)

    return {
        connectedSessions = math.max(0, tonumber(connectedSessions) or 0),
        directInputEnabled = state.remotePlayDirectInputEnabled == true,
        lastInputAt = state.remotePlayLastInputAt,
        secondsSinceLastInput = secondsSinceLastInput,
        inputSources = sources
    }
end

function steamRuntime.configureSteamInput(options)
    local request = type(options) == "table" and options or {}
    local manifestPath = resolveSteamInputManifestPath(request)
    local actionSet = request.actionSet and tostring(request.actionSet) or "global_controls"
    local digitalActions = request.digitalActions
    if type(digitalActions) ~= "table" then
        digitalActions = collectKeys(request.digitalActionToAction)
    end
    local analogActions = request.analogActions
    if type(analogActions) ~= "table" then
        analogActions = collectKeys(request.analogActionToNavigation)
    end

    local ok, a, b = bridgeCall("configureSteamInput", "configureSteamInput", {
        manifestPath = manifestPath,
        actionSet = actionSet,
        digitalActions = digitalActions,
        analogActions = analogActions
    })
    if not ok then
        state.steamInputLastError = tostring(b or a or "steam_input_configure_failed")
        return false, state.steamInputLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.steamInputLastError = tostring(payload or "steam_input_configure_failed")
        return false, state.steamInputLastError
    end

    state.steamInputConfigured = true
    state.steamInputManifestPath = manifestPath
    state.steamInputActionSet = actionSet
    state.steamInputLastError = nil
    return true
end

function steamRuntime.shutdownSteamInput()
    if state.initialized ~= true or not state.bridge then
        state.steamInputConfigured = false
        state.steamInputManifestPath = nil
        state.steamInputActionSet = nil
        state.steamInputLastPollAt = nil
        state.steamInputLastError = nil
        state.steamInputControllers = {}
        return true
    end

    local ok, a, b = bridgeCall("shutdownSteamInput", "shutdownSteamInput")
    if not ok then
        state.steamInputLastError = tostring(b or a or "steam_input_shutdown_failed")
        return false, state.steamInputLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.steamInputLastError = tostring(payload or "steam_input_shutdown_failed")
        return false, state.steamInputLastError
    end

    state.steamInputConfigured = false
    state.steamInputManifestPath = nil
    state.steamInputActionSet = nil
    state.steamInputLastPollAt = nil
    state.steamInputLastError = nil
    state.steamInputControllers = {}
    state.userStatsLastError = nil
    state.userStatsLastStoreAt = nil
    return true
end

function steamRuntime.listSteamInputControllers()
    local ok, a, b = bridgeCall("listSteamInputControllers", "listSteamInputControllers")
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return {}
    end

    local controllers = normalizeSteamInputControllerList(payload)
    state.steamInputControllers = controllers
    return controllers
end

function steamRuntime.pollSteamInputActions()
    local ok, a, b = bridgeCall("pollSteamInput", "pollSteamInput")
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return {}
    end

    local snapshots = normalizeSteamInputSnapshots(payload)
    state.steamInputLastPollAt = nowSeconds()
    local controllers = {}
    for _, snapshot in ipairs(snapshots) do
        controllers[#controllers + 1] = snapshot.controller
    end
    state.steamInputControllers = controllers
    return snapshots
end

function steamRuntime.getPathDiagnostics(options)
    local request = type(options) == "table" and options or {}
    local manifestFile = request.manifestFile
    if type(manifestFile) ~= "string" or manifestFile == "" then
        manifestFile = "steam_input_manifest.vdf"
    end

    local info = getFilesystemPathInfo()
    local manifestPath = resolveSteamInputManifestPath({
        manifestPath = request.manifestPath,
        manifestFile = manifestFile
    })

    return {
        source = info.source,
        sourceBaseDir = info.sourceBaseDir,
        workingDir = info.workingDir,
        sourceRoot = resolveSourceRoot(),
        manifestPath = manifestPath,
        manifestExists = fileExists(manifestPath)
    }
end

function steamRuntime.getSteamInputDiagnostics()
    local controllerCount = 0
    local remoteControllers = 0
    for _, controller in ipairs(state.steamInputControllers or {}) do
        controllerCount = controllerCount + 1
        if (tonumber(controller.remotePlaySessionId) or 0) > 0 then
            remoteControllers = remoteControllers + 1
        end
    end

    local pathDiagnostics = steamRuntime.getPathDiagnostics({ manifestFile = "steam_input_manifest.vdf" })
    local manifestPath = state.steamInputManifestPath or pathDiagnostics.manifestPath

    return {
        configured = state.steamInputConfigured == true,
        manifestPath = manifestPath,
        resolvedManifestPath = pathDiagnostics.manifestPath,
        manifestExists = fileExists(manifestPath),
        actionSet = state.steamInputActionSet,
        lastPollAt = state.steamInputLastPollAt,
        lastError = state.steamInputLastError,
        controllerCount = controllerCount,
        remoteControllerCount = remoteControllers,
        controllers = state.steamInputControllers or {},
        source = pathDiagnostics.source,
        sourceBaseDir = pathDiagnostics.sourceBaseDir,
        workingDir = pathDiagnostics.workingDir,
        sourceRoot = pathDiagnostics.sourceRoot
    }
end

function steamRuntime.showSteamInputBindingPanel(handleId)
    local normalizedHandleId = handleId and tostring(handleId) or ""
    if normalizedHandleId == "" then
        return false, "invalid_steam_input_handle"
    end

    local ok, a, b = bridgeCall("showSteamInputBindingPanel", "showSteamInputBindingPanel", normalizedHandleId)
    if not ok then
        return false, b
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        return false, payload or "steam_input_binding_panel_failed"
    end

    return true
end

function steamRuntime.getAchievement(id)
    local achievementId = tostring(id or "")
    if achievementId == "" then
        return nil, "achievement_id_missing"
    end

    local ok, a, b = bridgeCall("getAchievement", "getAchievement", achievementId)
    if not ok then
        state.userStatsLastError = tostring(b or a or "get_achievement_failed")
        return nil, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "get_achievement_failed")
        return nil, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return payload == true
end

function steamRuntime.setAchievement(id)
    local achievementId = tostring(id or "")
    if achievementId == "" then
        return false, "achievement_id_missing"
    end

    local ok, a, b = bridgeCall("setAchievement", "setAchievement", achievementId)
    if not ok then
        state.userStatsLastError = tostring(b or a or "set_achievement_failed")
        return false, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "set_achievement_failed")
        return false, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return true
end

function steamRuntime.clearAchievement(id)
    local achievementId = tostring(id or "")
    if achievementId == "" then
        return false, "achievement_id_missing"
    end

    local ok, a, b = bridgeCall("clearAchievement", "clearAchievement", achievementId)
    if not ok then
        state.userStatsLastError = tostring(b or a or "clear_achievement_failed")
        return false, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "clear_achievement_failed")
        return false, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return true
end

function steamRuntime.storeUserStats()
    local ok, a, b = bridgeCall("storeUserStats", "storeUserStats")
    if not ok then
        state.userStatsLastError = tostring(b or a or "store_user_stats_failed")
        return false, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "store_user_stats_failed")
        return false, state.userStatsLastError
    end

    state.userStatsLastError = nil
    state.userStatsLastStoreAt = nowSeconds()
    return true
end

function steamRuntime.getStatInt(id)
    local statId = tostring(id or "")
    if statId == "" then
        return nil, "stat_id_missing"
    end

    local ok, a, b = bridgeCall("getStatInt", "getStatInt", statId)
    if not ok then
        state.userStatsLastError = tostring(b or a or "get_stat_failed")
        return nil, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "get_stat_failed")
        return nil, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return tonumber(payload) or 0
end

function steamRuntime.setStatInt(id, value)
    local statId = tostring(id or "")
    if statId == "" then
        return false, "stat_id_missing"
    end

    local normalizedValue = math.floor(tonumber(value) or 0)
    local ok, a, b = bridgeCall("setStatInt", "setStatInt", statId, normalizedValue)
    if not ok then
        state.userStatsLastError = tostring(b or a or "set_stat_failed")
        return false, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "set_stat_failed")
        return false, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return true
end

function steamRuntime.incrementStatInt(id, delta)
    local statId = tostring(id or "")
    if statId == "" then
        return nil, "stat_id_missing"
    end

    local normalizedDelta = math.floor(tonumber(delta) or 0)
    local ok, a, b = bridgeCall("incrementStatInt", "incrementStatInt", statId, normalizedDelta)
    if not ok then
        state.userStatsLastError = tostring(b or a or "increment_stat_failed")
        return nil, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "increment_stat_failed")
        return nil, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return tonumber(payload) or 0
end

function steamRuntime.getGameBadgeLevel(series, foil)
    local normalizedSeries = math.floor(tonumber(series) or 0)
    if normalizedSeries <= 0 then
        return nil, "badge_series_invalid"
    end

    local ok, a, b = bridgeCall("getGameBadgeLevel", "getGameBadgeLevel", normalizedSeries, foil == true)
    if not ok then
        state.userStatsLastError = tostring(b or a or "get_badge_level_failed")
        return nil, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "get_badge_level_failed")
        return nil, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return math.max(0, math.floor(tonumber(payload) or 0))
end

function steamRuntime.getPlayerSteamLevel()
    local ok, a, b = bridgeCall("getPlayerSteamLevel", "getPlayerSteamLevel")
    if not ok then
        state.userStatsLastError = tostring(b or a or "get_player_steam_level_failed")
        return nil, state.userStatsLastError
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if success ~= true then
        state.userStatsLastError = tostring(payload or "get_player_steam_level_failed")
        return nil, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return math.max(0, math.floor(tonumber(payload) or 0))
end

local function computeLuaRatingProfileSignatureToken(canonicalPayload, ownerSteamId, appId)
    local combined = table.concat({
        "MOM_RATING_PROFILE_V2",
        tostring(ownerSteamId or ""),
        tostring(appId or ""),
        tostring(canonicalPayload or "")
    }, "\n")

    local hashA = 1573941
    local hashB = 4511981
    for index = 1, #combined do
        local byte = combined:byte(index)
        hashA = ((hashA * 131) + byte + 17 + (index % 23)) % 2147483647
        hashB = ((hashB * 257) + byte + 29 + (index % 31)) % 2147483647
    end

    return string.format("L1:%08x%08x", hashA, hashB)
end

function steamRuntime.computeRatingProfileSignature(canonicalPayload, ownerSteamId, appId, mode)
    local payload = tostring(canonicalPayload or "")
    local normalizedOwner = normalizeSteamId(ownerSteamId) or tostring(ownerSteamId or "")
    local normalizedAppId = tostring(appId or "")
    local requestedMode = tostring(mode or "")

    if payload == "" then
        return nil, "rating_profile_payload_missing"
    end
    if normalizedOwner == "" then
        return nil, "rating_profile_owner_missing"
    end
    if normalizedAppId == "" then
        return nil, "rating_profile_appid_missing"
    end

    if requestedMode ~= "fallback_only" then
        local ok, a, b = bridgeCall("computeRatingProfileSignature", "computeRatingProfileSignature", payload, normalizedOwner, normalizedAppId)
        if ok then
            local success, signature = unwrapSuccessPayload(a, b)
            if success == true and type(signature) == "string" and signature ~= "" then
                state.userStatsLastError = nil
                return signature
            end
            if requestedMode == "native_only" then
                state.userStatsLastError = tostring(signature or "native_signature_failed")
                return nil, state.userStatsLastError
            end
        elseif requestedMode == "native_only" then
            state.userStatsLastError = tostring(a or b or "native_signature_unavailable")
            return nil, state.userStatsLastError
        end
    elseif requestedMode == "native_only" then
        state.userStatsLastError = "native_signature_unavailable"
        return nil, state.userStatsLastError
    end

    state.userStatsLastError = nil
    return computeLuaRatingProfileSignatureToken(payload, normalizedOwner, normalizedAppId)
end

function steamRuntime.getUserStatsDiagnostics()
    return {
        lastError = state.userStatsLastError,
        lastStoreAt = state.userStatsLastStoreAt
    }
end

function steamRuntime.isOnlineReady()
    return state.initialized == true and state.bridge ~= nil
end

function steamRuntime.getLocalUserId()
    local ok, a, b = bridgeCall("getLocalUserId", "getLocalUserId")
    if not ok then
        return nil
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return nil
    end

    return normalizeSteamId(payload)
end

function steamRuntime.getPersonaName()
    local ok, a, b = bridgeCall("getPersonaName", "getPersonaName")
    if not ok then
        return nil
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return nil
    end

    if payload == nil then
        return nil
    end
    return tostring(payload)
end

function steamRuntime.getPersonaNameForUser(userId)
    local normalizedUserId = normalizeSteamId(userId)
    if not normalizedUserId then
        return nil
    end

    local ok, a, b = bridgeCall("getPersonaNameForUser", "getPersonaNameForUser", normalizedUserId)
    if not ok then
        return nil
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return nil
    end

    if payload == nil then
        return nil
    end

    local name = tostring(payload)
    if name == "" then
        return nil
    end
    return name
end

function steamRuntime.createFriendsLobby(maxMembers)
    local ok, a, b = bridgeCall("createFriendsLobby", "createFriendsLobby", maxMembers)
    if not ok then
        return false, a
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return false, payload or "create_friends_lobby_failed"
    end

    return true, normalizeLobbyPayload(payload)
end

function steamRuntime.joinLobby(lobbyId)
    local ok, a, b = bridgeCall("joinLobby", "joinLobby", lobbyId)
    if not ok then
        return false, a
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return false, payload or "join_lobby_failed"
    end

    return true, normalizeLobbyPayload(payload)
end

function steamRuntime.leaveLobby(lobbyId)
    local ok, a, b = bridgeCall("leaveLobby", "leaveLobby", lobbyId)
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a, b)
    return success == true
end

function steamRuntime.inviteFriend(lobbyId, friendId)
    local ok, a, b = bridgeCall("inviteFriend", "inviteFriend", lobbyId, friendId)
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a, b)
    return success == true
end

function steamRuntime.pollLobbyEvents(maxEvents)
    local ok, a, b = bridgeCall("pollLobbyEvents", "pollLobbyEvents", maxEvents)
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return {}
    end

    return normalizeLobbyEvents(payload)
end

function steamRuntime.getLobbySnapshot(lobbyId)
    local ok, a, b = bridgeCall("getLobbySnapshot", "getLobbySnapshot", lobbyId)
    if not ok then
        return nil
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return nil
    end

    return normalizeLobbyPayload(payload)
end

function steamRuntime.listJoinableLobbies(opts)
    opts = opts or {}

    local maxResults = math.floor(tonumber(opts.maxResults) or 20)
    if maxResults < 1 then
        maxResults = 1
    end
    if maxResults > 100 then
        maxResults = 100
    end

    local protocolVersion = opts.protocolVersion
    if protocolVersion == nil then
        local online = (SETTINGS or {}).STEAM_ONLINE or {}
        protocolVersion = online.PROTOCOL_VERSION
    end

    local request = {
        maxResults = maxResults,
        protocolVersion = protocolVersion and tostring(protocolVersion) or ""
    }

    local ok, a, b = bridgeCall("listJoinableLobbies", "listJoinableLobbies", request)
    if not ok then
        appendErrorLog("list_joinable_lobbies_bridge_call_failed")
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        appendErrorLog("list_joinable_lobbies_failed:" .. tostring(payload or "unknown"))
        return {}
    end

    return normalizeLobbyList(payload)
end

function steamRuntime.setLobbyData(lobbyId, key, value)
    local ok, a, b = bridgeCall("setLobbyData", "setLobbyData", lobbyId, key, value)
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a, b)
    return success == true
end

function steamRuntime.setLobbyVisibility(lobbyId, visibility)
    local mode = tostring(visibility or "public")
    if mode ~= "public" and mode ~= "friends" then
        mode = "public"
    end

    local ok, a, b = bridgeCall("setLobbyVisibility", "setLobbyVisibility", lobbyId, mode)
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a, b)
    return success == true
end

function steamRuntime.getLobbyData(lobbyId, key)
    local ok, a, b = bridgeCall("getLobbyData", "getLobbyData", lobbyId, key)
    if not ok then
        return nil
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return nil
    end

    return payload ~= nil and tostring(payload) or nil
end

function steamRuntime.getSteamIdFromLobbyMember(lobbyId, index)
    local ok, a, b = bridgeCall("getSteamIdFromLobbyMember", "getSteamIdFromLobbyMember", lobbyId, index)
    if not ok then
        return nil
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return nil
    end

    return normalizeSteamId(payload)
end

function steamRuntime.sendNet(peerId, payload, channel, sendType)
    local ok, a, b = bridgeCall("sendNet", "sendNet", peerId, payload, channel, sendType)
    if not ok then
        return false, b or state.lastError or "send_bridge_call_failed"
    end

    local success, reason = unwrapSuccessPayload(a, b)
    if success == true then
        return true
    end
    return false, reason or "send_failed"
end

function steamRuntime.pollNet(maxPackets)
    local ok, a, b = bridgeCall("pollNet", "pollNet", maxPackets)
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return {}
    end

    return normalizeNetPackets(payload)
end

function steamRuntime.ensureLocalLeaderboardPresence(name, defaultScore)
    if not steamRuntime.isOnlineReady() then
        return false, "steam_unavailable"
    end

    local leaderboardName = tostring(name or ((((SETTINGS.RATING or SETTINGS.ELO) or {}).LEADERBOARD_NAME) or "global_glicko2_v1"))
    local localUserId = steamRuntime.getLocalUserId()
    if not localUserId then
        return false, "local_user_missing"
    end

    local cacheKey = leaderboardName .. "::" .. tostring(localUserId)
    state.seededLeaderboards = state.seededLeaderboards or {}
    if state.seededLeaderboards[cacheKey] then
        return true, "cached"
    end

    local okFind = steamRuntime.findOrCreateLeaderboard(leaderboardName, "descending", "numeric")
    if not okFind then
        appendErrorLog("ensure_presence_find_failed:" .. leaderboardName)
        return false, "leaderboard_unavailable"
    end

    local existing = steamRuntime.downloadLeaderboardEntriesForUsers(leaderboardName, {localUserId}) or {}
    for _, entry in ipairs(existing) do
        if tostring(entry.userId or "") == tostring(localUserId) then
            state.seededLeaderboards[cacheKey] = true
            return true, "exists"
        end
    end

    local fallback = tonumber(defaultScore) or ((((SETTINGS.RATING or SETTINGS.ELO) or {}).DEFAULT_RATING) or 1200)
    local initialScore = math.floor(fallback + 0.5)
    local uploaded = steamRuntime.uploadLeaderboardScore(leaderboardName, initialScore, {0, 0, 0}, true)
    if not uploaded then
        appendErrorLog("ensure_presence_upload_failed:" .. leaderboardName)
        return false, "upload_failed"
    end

    state.seededLeaderboards[cacheKey] = true
    log(string.format("Leaderboard presence initialized for local user on '%s' with score %d", leaderboardName, initialScore))
    return true, "seeded"
end

function steamRuntime.findOrCreateLeaderboard(name, sortMethod, displayType)
    local ok, a, b = bridgeCall("findOrCreateLeaderboard", "findOrCreateLeaderboard", name, sortMethod, displayType)
    if not ok then
        return false, a
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return false, payload or "leaderboard_find_or_create_failed"
    end

    return true, normalizeLeaderboardPayload(payload, name)
end

function steamRuntime.uploadLeaderboardScore(name, score, details, forceUpdate)
    local ok, a, b = bridgeCall("uploadLeaderboardScore", "uploadLeaderboardScore", name, score, details, forceUpdate)
    if not ok then
        return false
    end

    local success = unwrapSuccessPayload(a, b)
    return success == true
end

function steamRuntime.downloadLeaderboardEntriesForUsers(name, userIds)
    local ok, a, b = bridgeCall("downloadLeaderboardEntriesForUsers", "downloadLeaderboardEntriesForUsers", name, userIds)
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return {}
    end

    return normalizeLeaderboardEntries(payload)
end

function steamRuntime.downloadLeaderboardAroundUser(name, rangeStart, rangeEnd)
    local ok, a, b = bridgeCall("downloadLeaderboardAroundUser", "downloadLeaderboardAroundUser", name, rangeStart, rangeEnd)
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return {}
    end

    return normalizeLeaderboardEntries(payload)
end

function steamRuntime.downloadLeaderboardTop(name, startRank, maxEntries)
    local normalizedStart = math.floor(tonumber(startRank) or 1)
    if normalizedStart < 1 then
        normalizedStart = 1
    end

    local normalizedCount = math.floor(tonumber(maxEntries) or 100)
    if normalizedCount < 1 then
        normalizedCount = 1
    elseif normalizedCount > 100 then
        normalizedCount = 100
    end

    local ok, a, b = bridgeCall("downloadLeaderboardTop", "downloadLeaderboardTop", name, normalizedStart, normalizedCount)
    if not ok then
        return {}
    end

    local success, payload = unwrapSuccessPayload(a, b)
    if not success then
        return {}
    end

    return normalizeLeaderboardEntries(payload)
end

return steamRuntime
