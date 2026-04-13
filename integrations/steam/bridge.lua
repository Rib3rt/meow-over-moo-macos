local bridge = {}

local NATIVE_MODULE_NAME = "steam_bridge_native"

local nativeImpl = nil
local nativeLoadError = nil
local cpathConfigured = false
local dependencyPreloadAttempted = false
local dependencyPreloadSummary = nil

local function normalizePath(path)
    if type(path) ~= "string" then
        return nil
    end
    if path == "" then
        return nil
    end
    return path:gsub("\\", "/")
end

local function appendPackageCPath(pattern)
    if type(pattern) ~= "string" or pattern == "" then
        return
    end
    if package.cpath:find(pattern, 1, true) then
        return
    end
    package.cpath = package.cpath .. ";" .. pattern
end

local function resolveSourceRoot()
    if love and love.filesystem and type(love.filesystem.getSourceBaseDirectory) == "function" then
        local okBase, base = pcall(love.filesystem.getSourceBaseDirectory)
        if okBase and type(base) == "string" and base ~= "" then
            return normalizePath(base)
        end
    end

    local okPwd, pwd = pcall(function()
        if love and love.filesystem and love.filesystem.getWorkingDirectory then
            return love.filesystem.getWorkingDirectory()
        end
        return nil
    end)
    if okPwd and type(pwd) == "string" and pwd ~= "" then
        return normalizePath(pwd)
    end

    return nil
end

local function fileExists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    local file = io.open(path, "rb")
    if not file then
        return false
    end

    file:close()
    return true
end

local function getRedistributableRoot(opts)
    if type(opts) == "table" and type(opts.redistributableRoot) == "string" and opts.redistributableRoot ~= "" then
        return opts.redistributableRoot
    end
    return "integrations/steam/redist"
end

local function detectPlatform()
    if love and love.system and type(love.system.getOS) == "function" then
        local okOs, osName = pcall(love.system.getOS)
        if okOs and type(osName) == "string" and osName ~= "" then
            if osName == "OS X" or osName == "macOS" then
                return "macOS"
            end
            return osName
        end
    end

    local pathSep = package and package.config and package.config:sub(1, 1) or "/"
    if pathSep == "\\" then
        return "Windows"
    end
    return "Linux"
end

local function collectSearchRoots(opts)
    local redistributableRoot = getRedistributableRoot(opts)
    local root = resolveSourceRoot()
    local roots = {}
    local seen = {}

    local function add(path)
        path = normalizePath(path)
        if not path or seen[path] then
            return
        end
        seen[path] = true
        roots[#roots + 1] = path
    end

    local relativeRoots = {
        ".",
        "./integrations/steam/redist",
        "./integrations/steam/redist/linux64",
        "./integrations/steam/redist/win64",
        "./integrations/steam/redist/macos",
        "./integrations/steam/native",
        "./" .. redistributableRoot,
        "./" .. redistributableRoot .. "/linux64",
        "./" .. redistributableRoot .. "/win64",
        "./" .. redistributableRoot .. "/macos",
        "./../Resources",
        "./../Resources/integrations/steam/redist",
        "./../Resources/integrations/steam/redist/macos",
        "./../Resources/" .. redistributableRoot,
        "./../Resources/" .. redistributableRoot .. "/macos"
    }

    for _, basePath in ipairs(relativeRoots) do
        add(basePath)
    end

    if root then
        local absoluteRoots = {
            root,
            root .. "/integrations/steam/redist",
            root .. "/integrations/steam/redist/linux64",
            root .. "/integrations/steam/redist/win64",
            root .. "/integrations/steam/redist/macos",
            root .. "/integrations/steam/native",
            root .. "/" .. redistributableRoot,
            root .. "/" .. redistributableRoot .. "/linux64",
            root .. "/" .. redistributableRoot .. "/win64",
            root .. "/" .. redistributableRoot .. "/macos"
        }

        for _, basePath in ipairs(absoluteRoots) do
            add(basePath)
        end

        if root:match("/Contents/MacOS/?$") then
            local resourceRoot = root:gsub("/Contents/MacOS/?$", "/Contents/Resources")
            add(resourceRoot)
            add(resourceRoot .. "/integrations/steam/redist")
            add(resourceRoot .. "/integrations/steam/redist/macos")
            add(resourceRoot .. "/" .. redistributableRoot)
            add(resourceRoot .. "/" .. redistributableRoot .. "/macos")
        end
    end

    return roots
end

local function collectDependencyCandidatePaths(opts, fileName)
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

    for _, basePath in ipairs(collectSearchRoots(opts)) do
        add(basePath .. "/" .. fileName)
    end

    return candidates
end

local function preloadDependencyFromCandidates(fileName, opts, globalMode)
    local okFfi, ffi = pcall(require, "ffi")
    if not okFfi or not ffi then
        dependencyPreloadSummary = "ffi_unavailable"
        return
    end

    local candidates = collectDependencyCandidatePaths(opts, fileName)
    for _, candidate in ipairs(candidates) do
        if fileExists(candidate) then
            local okLoad, loadResult
            if globalMode == true then
                okLoad, loadResult = pcall(ffi.load, candidate, true)
            else
                okLoad, loadResult = pcall(ffi.load, candidate)
            end
            if okLoad and loadResult then
                dependencyPreloadSummary = fileName .. "=" .. tostring(candidate)
                return
            end
            dependencyPreloadSummary = fileName .. " load failed: " .. tostring(loadResult)
            return
        end
    end

    dependencyPreloadSummary = fileName .. " not found in expected paths"
end

local function preloadWindowsDependencies(opts)
    preloadDependencyFromCandidates("steam_api64.dll", opts, false)
end

local function preloadLinuxDependencies(opts)
    preloadDependencyFromCandidates("libsteam_api.so", opts, true)
end

local function preloadMacDependencies(opts)
    preloadDependencyFromCandidates("libsteam_api.dylib", opts, true)
end

local function preloadPlatformDependencies(opts)
    if dependencyPreloadAttempted then
        return
    end
    dependencyPreloadAttempted = true

    local platform = detectPlatform()
    if platform == "Windows" then
        preloadWindowsDependencies(opts)
        return
    end
    if platform == "macOS" then
        preloadMacDependencies(opts)
        return
    end
    preloadLinuxDependencies(opts)
end

local function configureNativeSearchPath(opts)
    if cpathConfigured then
        return
    end
    cpathConfigured = true

    for _, basePath in ipairs(collectSearchRoots(opts)) do
        appendPackageCPath(basePath .. "/?.so")
        appendPackageCPath(basePath .. "/?.dll")
        appendPackageCPath(basePath .. "/?.dylib")
    end
end

local function classifyNativeLoadError(rawError)
    local full = tostring(rawError or "")
    local lower = full:lower()

    if full:find("module '" .. NATIVE_MODULE_NAME .. "' not found", 1, true) then
        return "module_not_found", full
    end

    if lower:find("specified procedure could not be found", 1, true)
        or lower:find("undefined symbol", 1, true)
        or lower:find("symbol not found", 1, true) then
        return "procedure_not_found", full
    end

    if lower:find("specified module could not be found", 1, true)
        or lower:find("cannot open shared object file", 1, true)
        or lower:find("image not found", 1, true) then
        return "dependency_missing", full
    end

    return "load_error", full
end

local function ensureNativeLoaded(opts)
    if nativeImpl then
        return true
    end

    configureNativeSearchPath(opts)
    preloadPlatformDependencies(opts)

    local ok, loaded = pcall(require, NATIVE_MODULE_NAME)
    if not ok then
        local code, rawMessage = classifyNativeLoadError(loaded)
        nativeLoadError = code

        local details = tostring(rawMessage or "")
        if details ~= "" then
            nativeLoadError = nativeLoadError .. ":" .. details
        end

        if dependencyPreloadSummary and dependencyPreloadSummary ~= "" then
            nativeLoadError = nativeLoadError .. " | dependency_hint=" .. tostring(dependencyPreloadSummary)
        end

        return false
    end

    if type(loaded) ~= "table" then
        nativeLoadError = "native module did not return a table"
        return false
    end

    nativeImpl = loaded
    nativeLoadError = nil
    return true
end

local function fallbackReason(action)
    local details = ""
    if nativeLoadError and nativeLoadError ~= "" then
        details = " (" .. nativeLoadError .. ")"
    end
    return action .. " unavailable: native module not loaded" .. details
end

local fallback = {}

function fallback.init(opts)
    return false, fallbackReason("init")
end

function fallback.runCallbacks(dt)
    return true
end

function fallback.shutdown()
    return true
end

function fallback.activateOverlay(target)
    return false, fallbackReason("activateOverlay")
end

function fallback.setRichPresence(key, value)
    return false, fallbackReason("setRichPresence")
end

function fallback.clearRichPresence()
    return false, fallbackReason("clearRichPresence")
end

function fallback.showRemotePlayTogetherUI()
    return false, fallbackReason("showRemotePlayTogetherUI")
end

function fallback.getRemotePlaySessionCount()
    return false, 0, fallbackReason("getRemotePlaySessionCount")
end

function fallback.listRemotePlaySessions()
    return false, {}, fallbackReason("listRemotePlaySessions")
end

function fallback.setRemotePlayDirectInputEnabled(enabled)
    return false, fallbackReason("setRemotePlayDirectInputEnabled")
end

function fallback.pollRemotePlayInput(maxEvents)
    return false, {}, fallbackReason("pollRemotePlayInput")
end

function fallback.setRemotePlayMouseVisibility(sessionId, visible)
    return false, fallbackReason("setRemotePlayMouseVisibility")
end

function fallback.setRemotePlayMouseCursor(sessionId, cursorKind)
    return false, fallbackReason("setRemotePlayMouseCursor")
end

function fallback.setRemotePlayMousePosition(sessionId, normalizedX, normalizedY)
    return false, fallbackReason("setRemotePlayMousePosition")
end

function fallback.configureSteamInput(opts)
    return false, fallbackReason("configureSteamInput")
end

function fallback.shutdownSteamInput()
    return true
end

function fallback.listSteamInputControllers()
    return false, {}, fallbackReason("listSteamInputControllers")
end

function fallback.pollSteamInput()
    return false, {}, fallbackReason("pollSteamInput")
end

function fallback.showSteamInputBindingPanel(handleId)
    return false, fallbackReason("showSteamInputBindingPanel")
end

function fallback.getAchievement(achievementId)
    return false, fallbackReason("getAchievement")
end

function fallback.setAchievement(achievementId)
    return false, fallbackReason("setAchievement")
end

function fallback.clearAchievement(achievementId)
    return false, fallbackReason("clearAchievement")
end

function fallback.storeUserStats()
    return false, fallbackReason("storeUserStats")
end

function fallback.getStatInt(statId)
    return false, fallbackReason("getStatInt")
end

function fallback.setStatInt(statId, value)
    return false, fallbackReason("setStatInt")
end

function fallback.incrementStatInt(statId, delta)
    return false, fallbackReason("incrementStatInt")
end

function fallback.getGameBadgeLevel(series, foil)
    return false, fallbackReason("getGameBadgeLevel")
end

function fallback.getPlayerSteamLevel()
    return false, fallbackReason("getPlayerSteamLevel")
end

function fallback.computeRatingProfileSignature(canonicalPayload, ownerSteamId, appId, mode)
    return false, fallbackReason("computeRatingProfileSignature")
end

function fallback.getLocalUserId()
    return nil, fallbackReason("getLocalUserId")
end

function fallback.getPersonaName()
    return nil, fallbackReason("getPersonaName")
end

function fallback.getPersonaNameForUser(userId)
    return nil, fallbackReason("getPersonaNameForUser")
end

function fallback.createFriendsLobby(maxMembers)
    return false, fallbackReason("createFriendsLobby")
end

function fallback.joinLobby(lobbyId)
    return false, fallbackReason("joinLobby")
end

function fallback.leaveLobby(lobbyId)
    return false, fallbackReason("leaveLobby")
end

function fallback.inviteFriend(lobbyId, friendId)
    return false, fallbackReason("inviteFriend")
end

function fallback.pollLobbyEvents(maxEvents)
    return {}
end

function fallback.getLobbySnapshot(lobbyId)
    return nil, fallbackReason("getLobbySnapshot")
end

function fallback.listJoinableLobbies(opts)
    return {}
end

function fallback.setLobbyData(lobbyId, key, value)
    return false, fallbackReason("setLobbyData")
end

function fallback.setLobbyVisibility(lobbyId, visibility)
    return false, fallbackReason("setLobbyVisibility")
end

function fallback.getLobbyData(lobbyId, key)
    return nil, fallbackReason("getLobbyData")
end

function fallback.getSteamIdFromLobbyMember(lobbyId, index)
    return nil, fallbackReason("getSteamIdFromLobbyMember")
end

function fallback.sendNet(peerId, payload, channel, sendType)
    return false, fallbackReason("sendNet")
end

function fallback.pollNet(maxPackets)
    return {}
end

function fallback.findOrCreateLeaderboard(name, sortMethod, displayType)
    return false, fallbackReason("findOrCreateLeaderboard")
end

function fallback.uploadLeaderboardScore(name, score, details, forceUpdate)
    return false, fallbackReason("uploadLeaderboardScore")
end

function fallback.downloadLeaderboardEntriesForUsers(name, userIds)
    return {}
end

function fallback.downloadLeaderboardAroundUser(name, rangeStart, rangeEnd)
    return {}
end

function fallback.downloadLeaderboardTop(name, startRank, maxEntries)
    return {}
end

local function callImpl(methodName, ...)
    local impl = nativeImpl or fallback
    local method = impl[methodName]
    if type(method) ~= "function" then
        method = fallback[methodName]
    end
    return method(...)
end

function bridge.init(opts)
    local loaded = ensureNativeLoaded(opts)
    if not loaded then
        return fallback.init(opts)
    end

    if type(nativeImpl.init) ~= "function" then
        nativeLoadError = "native module missing init"
        nativeImpl = nil
        return fallback.init(opts)
    end

    local ok, initialized, reason = pcall(nativeImpl.init, opts)
    if not ok then
        nativeLoadError = tostring(initialized)
        nativeImpl = nil
        return fallback.init(opts)
    end

    if initialized == true then
        return true
    end

    nativeLoadError = tostring(reason or "native bridge init declined")
    nativeImpl = nil
    return fallback.init(opts)
end

function bridge.runCallbacks(dt)
    return callImpl("runCallbacks", dt)
end

function bridge.shutdown()
    local resultA, resultB = callImpl("shutdown")
    nativeImpl = nil
    return resultA, resultB
end

function bridge.activateOverlay(target)
    return callImpl("activateOverlay", target)
end

function bridge.setRichPresence(key, value)
    return callImpl("setRichPresence", key, value)
end

function bridge.clearRichPresence()
    return callImpl("clearRichPresence")
end

function bridge.showRemotePlayTogetherUI()
    return callImpl("showRemotePlayTogetherUI")
end

function bridge.getRemotePlaySessionCount()
    return callImpl("getRemotePlaySessionCount")
end

function bridge.listRemotePlaySessions()
    return callImpl("listRemotePlaySessions")
end

function bridge.setRemotePlayDirectInputEnabled(enabled)
    return callImpl("setRemotePlayDirectInputEnabled", enabled)
end

function bridge.pollRemotePlayInput(maxEvents)
    return callImpl("pollRemotePlayInput", maxEvents)
end

function bridge.setRemotePlayMouseVisibility(sessionId, visible)
    return callImpl("setRemotePlayMouseVisibility", sessionId, visible)
end

function bridge.setRemotePlayMouseCursor(sessionId, cursorKind)
    return callImpl("setRemotePlayMouseCursor", sessionId, cursorKind)
end

function bridge.setRemotePlayMousePosition(sessionId, normalizedX, normalizedY)
    return callImpl("setRemotePlayMousePosition", sessionId, normalizedX, normalizedY)
end

function bridge.configureSteamInput(opts)
    return callImpl("configureSteamInput", opts)
end

function bridge.shutdownSteamInput()
    return callImpl("shutdownSteamInput")
end

function bridge.listSteamInputControllers()
    return callImpl("listSteamInputControllers")
end

function bridge.pollSteamInput()
    return callImpl("pollSteamInput")
end

function bridge.showSteamInputBindingPanel(handleId)
    return callImpl("showSteamInputBindingPanel", handleId)
end

function bridge.getAchievement(achievementId)
    return callImpl("getAchievement", achievementId)
end

function bridge.setAchievement(achievementId)
    return callImpl("setAchievement", achievementId)
end

function bridge.clearAchievement(achievementId)
    return callImpl("clearAchievement", achievementId)
end

function bridge.storeUserStats()
    return callImpl("storeUserStats")
end

function bridge.getStatInt(statId)
    return callImpl("getStatInt", statId)
end

function bridge.setStatInt(statId, value)
    return callImpl("setStatInt", statId, value)
end

function bridge.incrementStatInt(statId, delta)
    return callImpl("incrementStatInt", statId, delta)
end

function bridge.getGameBadgeLevel(series, foil)
    return callImpl("getGameBadgeLevel", series, foil)
end

function bridge.getPlayerSteamLevel()
    return callImpl("getPlayerSteamLevel")
end

function bridge.computeRatingProfileSignature(canonicalPayload, ownerSteamId, appId, mode)
    return callImpl("computeRatingProfileSignature", canonicalPayload, ownerSteamId, appId)
end

function bridge.getLocalUserId()
    return callImpl("getLocalUserId")
end

function bridge.getPersonaName()
    return callImpl("getPersonaName")
end

function bridge.getPersonaNameForUser(userId)
    return callImpl("getPersonaNameForUser", userId)
end

function bridge.createFriendsLobby(maxMembers)
    return callImpl("createFriendsLobby", maxMembers)
end

function bridge.joinLobby(lobbyId)
    return callImpl("joinLobby", lobbyId)
end

function bridge.leaveLobby(lobbyId)
    return callImpl("leaveLobby", lobbyId)
end

function bridge.inviteFriend(lobbyId, friendId)
    return callImpl("inviteFriend", lobbyId, friendId)
end

function bridge.pollLobbyEvents(maxEvents)
    return callImpl("pollLobbyEvents", maxEvents)
end

function bridge.getLobbySnapshot(lobbyId)
    return callImpl("getLobbySnapshot", lobbyId)
end

function bridge.listJoinableLobbies(opts)
    return callImpl("listJoinableLobbies", opts)
end

function bridge.setLobbyData(lobbyId, key, value)
    return callImpl("setLobbyData", lobbyId, key, value)
end

function bridge.setLobbyVisibility(lobbyId, visibility)
    return callImpl("setLobbyVisibility", lobbyId, visibility)
end

function bridge.getLobbyData(lobbyId, key)
    return callImpl("getLobbyData", lobbyId, key)
end

function bridge.getSteamIdFromLobbyMember(lobbyId, index)
    return callImpl("getSteamIdFromLobbyMember", lobbyId, index)
end

function bridge.sendNet(peerId, payload, channel, sendType)
    return callImpl("sendNet", peerId, payload, channel, sendType)
end

function bridge.pollNet(maxPackets)
    return callImpl("pollNet", maxPackets)
end

function bridge.findOrCreateLeaderboard(name, sortMethod, displayType)
    return callImpl("findOrCreateLeaderboard", name, sortMethod, displayType)
end

function bridge.uploadLeaderboardScore(name, score, details, forceUpdate)
    return callImpl("uploadLeaderboardScore", name, score, details, forceUpdate)
end

function bridge.downloadLeaderboardEntriesForUsers(name, userIds)
    return callImpl("downloadLeaderboardEntriesForUsers", name, userIds)
end

function bridge.downloadLeaderboardAroundUser(name, rangeStart, rangeEnd)
    return callImpl("downloadLeaderboardAroundUser", name, rangeStart, rangeEnd)
end

function bridge.downloadLeaderboardTop(name, startRank, maxEntries)
    return callImpl("downloadLeaderboardTop", name, startRank, maxEntries)
end

return bridge
