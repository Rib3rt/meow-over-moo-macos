package.path = package.path .. ";./?.lua"

local results = {}
local unpackFn = table.unpack or unpack

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = {name = name, ok = ok, err = err}
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function resetSteamRuntimeModules()
    package.loaded["steam_runtime"] = nil
    package.loaded["integrations.steam.bridge"] = nil
    package.loaded["steam_bridge_native"] = nil
end

local function withSteamPreload(factory, fn)
    local previous = package.preload["steam_bridge_native"]
    package.preload["steam_bridge_native"] = factory
    local ok, err = pcall(fn)
    package.preload["steam_bridge_native"] = previous
    if not ok then
        error(err, 0)
    end
end

local function newRuntime(config)
    SETTINGS = SETTINGS or {}
    SETTINGS.STEAM = config
    resetSteamRuntimeModules()
    return require("steam_runtime")
end

local function withLoveFilesystemMock(mockFilesystem, fn)
    local previousLove = rawget(_G, "love")
    local previousSettings = rawget(_G, "SETTINGS")
    _G.love = {
        filesystem = mockFilesystem,
        timer = {
            getTime = function()
                return 123.45
            end
        }
    }

    local ok, err = pcall(fn)
    _G.love = previousLove
    _G.SETTINGS = previousSettings
    if not ok then
        error(err, 0)
    end
end

local function buildMockNativeBridge()
    local state = {
        initialized = false,
        localUserId = "76561198000000001",
        localPersona = "MockUser",
        nextLobbyId = 900000000000001,
        lobbies = {},
        lobbyEvents = {},
        netQueue = {},
        boardScores = {},
        achievements = {},
        stats = {},
        badges = {
            ["1:false"] = 2,
            ["1:true"] = 1
        },
        playerSteamLevel = 12,
        steamInputConfigured = false,
        steamInputManifestPath = nil
    }

    local function pushLobbyEvent(event)
        state.lobbyEvents[#state.lobbyEvents + 1] = event
    end

    local function popEvents(limit)
        local out = {}
        local count = math.min(limit or #state.lobbyEvents, #state.lobbyEvents)
        for i = 1, count do
            out[#out + 1] = table.remove(state.lobbyEvents, 1)
        end
        return out
    end

    local function getLobby(lobbyId)
        return state.lobbies[tostring(lobbyId)]
    end

    local bridge = {}

    function bridge.init(opts)
        state.initialized = true
        return true
    end

    function bridge.runCallbacks(dt)
        return true
    end

    function bridge.shutdown()
        state.initialized = false
        return true
    end

    function bridge.activateOverlay(target)
        return true
    end

    function bridge.setRichPresence(key, value)
        return true
    end

    function bridge.clearRichPresence()
        return true
    end

    function bridge.showRemotePlayTogetherUI()
        return true
    end

    function bridge.getRemotePlaySessionCount()
        return true, 1
    end

    function bridge.listRemotePlaySessions()
        return true, {
            {
                sessionId = 101,
                userId = "76561198000000099",
                personaName = "RemoteMock",
                clientName = "Steam Deck"
            }
        }
    end

    function bridge.setRemotePlayDirectInputEnabled(enabled)
        state.remotePlayDirectInputEnabled = enabled == true
        return true
    end

    function bridge.setRemotePlayMouseVisibility(sessionId, visible)
        state.remotePlayMouseVisibility = state.remotePlayMouseVisibility or {}
        state.remotePlayMouseVisibility[tostring(sessionId)] = visible == true
        return true
    end

    function bridge.setRemotePlayMouseCursor(sessionId, cursorKind)
        state.remotePlayMouseCursor = state.remotePlayMouseCursor or {}
        state.remotePlayMouseCursor[tostring(sessionId)] = tostring(cursorKind or "hidden")
        return true
    end

    function bridge.setRemotePlayMousePosition(sessionId, normalizedX, normalizedY)
        state.remotePlayMousePosition = state.remotePlayMousePosition or {}
        state.remotePlayMousePosition[tostring(sessionId)] = {
            x = tonumber(normalizedX) or 0,
            y = tonumber(normalizedY) or 0
        }
        return true
    end

    function bridge.pollRemotePlayInput(maxEvents)
        if state.remotePlayDirectInputEnabled ~= true then
            return true, {}
        end
        return true, {
            {
                sessionId = 101,
                type = "key_down",
                keyScancode = 40
            }
        }
    end

    function bridge.configureSteamInput(opts)
        local request = opts or {}
        state.steamInputConfigured = true
        state.steamInputManifestPath = request.manifestPath
        state.steamInputActionSet = request.actionSet
        state.steamInputDigitalActions = request.digitalActions or {}
        state.steamInputAnalogActions = request.analogActions or {}
        return true
    end

    function bridge.shutdownSteamInput()
        state.steamInputConfigured = false
        state.steamInputManifestPath = nil
        state.steamInputActionSet = nil
        state.steamInputDigitalActions = nil
        state.steamInputAnalogActions = nil
        return true
    end

    function bridge.listSteamInputControllers()
        if state.steamInputConfigured ~= true then
            return false, {}, "steam_input_not_configured"
        end

        return true, {
            {
                handleId = "1001",
                remotePlaySessionId = 0,
                gamepadIndex = 0,
                inputType = "xboxone"
            },
            {
                handleId = "1002",
                remotePlaySessionId = 101,
                gamepadIndex = 1,
                inputType = "xboxone"
            }
        }
    end

    function bridge.pollSteamInput()
        if state.steamInputConfigured ~= true then
            return false, {}, "steam_input_not_configured"
        end

        return true, {
            {
                controller = {
                    handleId = "1001",
                    remotePlaySessionId = 0,
                    gamepadIndex = 0,
                    inputType = "xboxone"
                },
                digitalActions = {
                    {name = "confirm", state = true, active = true},
                    {name = "cancel", state = false, active = true}
                },
                analogActions = {
                    {name = "navigate", x = 1, y = 0, active = true, mode = "joystick_move"}
                }
            },
            {
                controller = {
                    handleId = "1002",
                    remotePlaySessionId = 101,
                    gamepadIndex = 1,
                    inputType = "xboxone"
                },
                digitalActions = {
                    {name = "confirm", state = false, active = true},
                    {name = "cancel", state = true, active = true}
                },
                analogActions = {
                    {name = "page_scroll", x = 0, y = -1, active = true, mode = "joystick_move"}
                }
            }
        }
    end

    function bridge.showSteamInputBindingPanel(handleId)
        return tostring(handleId or "") == "1001"
    end

    function bridge.getAchievement(achievementId)
        return true, state.achievements[tostring(achievementId)] == true
    end

    function bridge.setAchievement(achievementId)
        state.achievements[tostring(achievementId)] = true
        return true
    end

    function bridge.clearAchievement(achievementId)
        state.achievements[tostring(achievementId)] = nil
        return true
    end

    function bridge.storeUserStats()
        state.lastStatsStoredAt = os.time()
        return true
    end

    function bridge.getStatInt(statId)
        return true, tonumber(state.stats[tostring(statId)] or 0)
    end

    function bridge.setStatInt(statId, value)
        state.stats[tostring(statId)] = math.floor(tonumber(value) or 0)
        return true
    end

    function bridge.incrementStatInt(statId, delta)
        local key = tostring(statId)
        local nextValue = math.floor(tonumber(state.stats[key] or 0) + tonumber(delta or 0))
        state.stats[key] = nextValue
        return true, nextValue
    end

    function bridge.getGameBadgeLevel(series, foil)
        local key = string.format("%d:%s", math.floor(tonumber(series) or 0), tostring(foil == true))
        return true, math.floor(tonumber(state.badges[key] or 0) or 0)
    end

    function bridge.getPlayerSteamLevel()
        return true, math.floor(tonumber(state.playerSteamLevel or 0) or 0)
    end

    function bridge.getLocalUserId()
        return true, state.localUserId
    end

    function bridge.getPersonaName()
        return true, state.localPersona
    end

    function bridge.getPersonaNameForUser(userId)
        local normalized = tostring(userId or "")
        if normalized == state.localUserId then
            return true, state.localPersona
        end
        if normalized == "76561198000000099" then
            return true, "RemoteMock"
        end
        return false, "persona_name_unavailable"
    end

    function bridge.createFriendsLobby(maxMembers)
        local lobbyId = tostring(state.nextLobbyId)
        state.nextLobbyId = state.nextLobbyId + 1
        state.lobbies[lobbyId] = {
            ownerId = state.localUserId,
            members = {state.localUserId},
            data = {}
        }

        pushLobbyEvent({
            type = "lobby_created",
            lobbyId = lobbyId,
            ownerId = state.localUserId,
            result = "ok"
        })

        return true, {
            lobbyId = lobbyId,
            ownerId = state.localUserId
        }
    end

    function bridge.joinLobby(lobbyId)
        local lobby = getLobby(lobbyId)
        if not lobby then
            return false, "lobby_not_found"
        end

        local guestId = "76561198000000099"
        lobby.members[#lobby.members + 1] = guestId

        pushLobbyEvent({
            type = "lobby_joined",
            lobbyId = tostring(lobbyId),
            ownerId = lobby.ownerId,
            memberId = guestId,
            result = "ok"
        })

        return true, {
            lobbyId = tostring(lobbyId),
            enterResponse = 1
        }
    end

    function bridge.leaveLobby(lobbyId)
        state.lobbies[tostring(lobbyId)] = nil
        pushLobbyEvent({
            type = "lobby_left",
            lobbyId = tostring(lobbyId),
            result = "ok"
        })
        return true
    end

    function bridge.inviteFriend(lobbyId, friendId)
        pushLobbyEvent({
            type = "lobby_invite_requested",
            lobbyId = tostring(lobbyId),
            memberId = tostring(friendId),
            result = "ok"
        })
        return true
    end

    function bridge.pollLobbyEvents(maxEvents)
        return true, popEvents(maxEvents or 64)
    end

    function bridge.getLobbySnapshot(lobbyId)
        local lobby = getLobby(lobbyId)
        if not lobby then
            return false, "lobby_not_found"
        end

        return true, {
            lobbyId = tostring(lobbyId),
            ownerId = lobby.ownerId,
            members = {unpackFn(lobby.members)},
            sessionId = lobby.data.session_id,
            protocolVersion = lobby.data.protocol_version
        }
    end

    function bridge.listJoinableLobbies(opts)
        local request = opts or {}
        local maxResults = tonumber(request.maxResults) or 20
        local protocolVersion = request.protocolVersion and tostring(request.protocolVersion) or ""

        local rows = {
            {
                lobbyId = "900000000000010",
                ownerId = state.localUserId,
                ownerName = state.localPersona,
                memberCount = 1,
                memberLimit = 2,
                sessionId = "session-alpha",
                protocolVersion = protocolVersion ~= "" and protocolVersion or "1",
                relation = "friend",
                joinable = true
            },
            {
                id = "900000000000011",
                owner = "76561198000000123",
                ownerName = "FallbackHost",
                members = "1",
                maxMembers = "2",
                sessionId = "session-beta",
                protocolVersion = "",
                relation = "friend_of_friend",
                joinable = false
            }
        }

        local out = {}
        for i = 1, math.min(#rows, math.max(1, math.floor(maxResults))) do
            out[#out + 1] = rows[i]
        end
        return true, out
    end

    function bridge.setLobbyData(lobbyId, key, value)
        local lobby = getLobby(lobbyId)
        if not lobby then
            return false, "lobby_not_found"
        end
        lobby.data[key] = value
        return true
    end

    function bridge.getLobbyData(lobbyId, key)
        local lobby = getLobby(lobbyId)
        if not lobby then
            return false, "lobby_not_found"
        end
        return true, lobby.data[key]
    end

    function bridge.getSteamIdFromLobbyMember(lobbyId, index)
        local lobby = getLobby(lobbyId)
        if not lobby then
            return false, "lobby_not_found"
        end
        local member = lobby.members[index]
        if not member then
            return false, "member_missing"
        end
        return true, member
    end

    function bridge.sendNet(peerId, payload, channel, sendType)
        state.netQueue[#state.netQueue + 1] = {
            peerId = tostring(peerId),
            channel = tonumber(channel) or 0,
            payload = payload,
            recvTs = os.time()
        }
        return true
    end

    function bridge.pollNet(maxPackets)
        local out = {}
        local count = math.min(maxPackets or #state.netQueue, #state.netQueue)
        for i = 1, count do
            out[#out + 1] = table.remove(state.netQueue, 1)
        end
        return true, out
    end

    function bridge.findOrCreateLeaderboard(name, sortMethod, displayType)
        state.boardScores[name] = state.boardScores[name] or {}
        return true, {name = name, handle = "mock:" .. tostring(name)}
    end

    function bridge.uploadLeaderboardScore(name, score, details, forceUpdate)
        state.boardScores[name] = state.boardScores[name] or {}
        state.boardScores[name][state.localUserId] = {
            score = tonumber(score) or 0,
            rank = 1,
            details = details or {}
        }
        return true
    end

    function bridge.downloadLeaderboardEntriesForUsers(name, userIds)
        local board = state.boardScores[name] or {}
        local entries = {}
        for _, userId in ipairs(userIds or {}) do
            local row = board[tostring(userId)]
            if row then
                entries[#entries + 1] = {
                    userId = tostring(userId),
                    score = row.score,
                    rank = row.rank,
                    details = row.details
                }
            end
        end
        return true, entries
    end

    function bridge.downloadLeaderboardAroundUser(name, rangeStart, rangeEnd)
        local board = state.boardScores[name] or {}
        local entries = {}
        for userId, row in pairs(board) do
            entries[#entries + 1] = {
                userId = tostring(userId),
                score = row.score,
                rank = row.rank,
                details = row.details
            }
        end
        return true, entries
    end

    function bridge.downloadLeaderboardTop(name, startRank, maxEntries)
        local start = tonumber(startRank) or 1
        local count = tonumber(maxEntries) or 100
        if start < 1 then
            start = 1
        end
        if count < 1 then
            count = 1
        end
        if count > 100 then
            count = 100
        end

        local entries = {}
        for i = 0, count - 1 do
            local rank = start + i
            entries[#entries + 1] = {
                userId = tostring(76561198010000000 + rank),
                score = 1600 - rank,
                rank = rank,
                details = {}
            }
        end
        return true, entries
    end

    return bridge
end

runTest("native_bridge_loads_when_binary_present", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        local initialized = runtime.init()
        assertTrue(initialized == true, "runtime should initialize with mock native bridge")
        assertTrue(runtime.getMode() == "online", "mode must be online")

        runtime.shutdown()
    end)
end)

runTest("native_bridge_graceful_fallback_when_missing", function()
    withSteamPreload(function()
        error("mock native missing", 0)
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        local initialized = runtime.init()
        assertTrue(initialized == false, "runtime init should fail without native bridge")
        assertTrue(runtime.getMode() == "offline", "mode must degrade to offline")
        assertTrue(type(runtime.getLastError()) == "string", "fallback should provide reason")

        runtime.shutdown()
    end)
end)

runTest("runtime_remote_play_methods_exist", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(type(runtime.showRemotePlayTogetherUI) == "function", "showRemotePlayTogetherUI missing")
        assertTrue(type(runtime.getRemotePlaySessionCount) == "function", "getRemotePlaySessionCount missing")
        assertTrue(type(runtime.listRemotePlaySessions) == "function", "listRemotePlaySessions missing")
        assertTrue(type(runtime.setRemotePlayDirectInputEnabled) == "function", "setRemotePlayDirectInputEnabled missing")
        assertTrue(type(runtime.pollRemotePlayInput) == "function", "pollRemotePlayInput missing")
        assertTrue(type(runtime.setRemotePlayMouseVisibility) == "function", "setRemotePlayMouseVisibility missing")
        assertTrue(type(runtime.setRemotePlayMouseCursor) == "function", "setRemotePlayMouseCursor missing")
        assertTrue(type(runtime.setRemotePlayMousePosition) == "function", "setRemotePlayMousePosition missing")
        assertTrue(type(runtime.getRemotePlayInputDiagnostics) == "function", "getRemotePlayInputDiagnostics missing")
        assertTrue(type(runtime.configureSteamInput) == "function", "configureSteamInput missing")
        assertTrue(type(runtime.shutdownSteamInput) == "function", "shutdownSteamInput missing")
        assertTrue(type(runtime.listSteamInputControllers) == "function", "listSteamInputControllers missing")
        assertTrue(type(runtime.pollSteamInputActions) == "function", "pollSteamInputActions missing")
        assertTrue(type(runtime.getSteamInputDiagnostics) == "function", "getSteamInputDiagnostics missing")
        assertTrue(type(runtime.showSteamInputBindingPanel) == "function", "showSteamInputBindingPanel missing")
        runtime.shutdown()
    end)
end)

runTest("runtime_show_remote_play_ui_fallback_safe", function()
    withSteamPreload(function()
        error("mock native missing", 0)
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        runtime.init()
        local ok = runtime.showRemotePlayTogetherUI()
        assertTrue(ok == false, "fallback remote play UI call should fail safely")
        runtime.shutdown()
    end)
end)

runTest("runtime_remote_play_session_count_returns_integer", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        local count = runtime.getRemotePlaySessionCount()
        assertTrue(type(count) == "number", "remote play session count must be number")
        assertTrue(count == 1, "remote play session count mismatch")
        runtime.shutdown()
    end)
end)

runTest("runtime_remote_play_sessions_shape_normalized", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        local sessions = runtime.listRemotePlaySessions()
        assertTrue(type(sessions) == "table", "remote play sessions should be table")
        assertTrue(#sessions == 1, "expected one normalized remote play session")
        local entry = sessions[1]
        assertTrue(type(entry.sessionId) == "number", "sessionId should be number")
        assertTrue(type(entry.userId) == "string", "userId should be string")
        assertTrue(type(entry.personaName) == "string", "personaName should be string")
        assertTrue(type(entry.clientName) == "string", "clientName should be string")
        runtime.shutdown()
    end)
end)

runTest("remote_play_direct_input_enable_disable_methods_exist", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(runtime.setRemotePlayDirectInputEnabled(true) == true, "direct input enable should succeed")
        assertTrue(runtime.setRemotePlayDirectInputEnabled(false) == true, "direct input disable should succeed")
        runtime.shutdown()
    end)
end)

runTest("remote_play_cursor_methods_exist_and_normalize", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(runtime.setRemotePlayDirectInputEnabled(true) == true, "direct input enable should succeed")
        assertTrue(runtime.setRemotePlayMouseVisibility(101, true) == true, "remote play mouse visibility should succeed")
        assertTrue(runtime.setRemotePlayMouseCursor(101, "default_light") == true, "remote play mouse cursor should succeed")
        assertTrue(runtime.setRemotePlayMousePosition(101, 1.25, -0.25) == true, "remote play mouse position should succeed")
        runtime.shutdown()
    end)
end)

runTest("remote_play_poll_input_returns_table_safe_on_fallback", function()
    withSteamPreload(function()
        error("mock native missing", 0)
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        runtime.init()
        local events = runtime.pollRemotePlayInput(32)
        assertTrue(type(events) == "table", "pollRemotePlayInput should return table")
        runtime.shutdown()
    end)
end)

runTest("remote_play_poll_input_event_shape_normalized", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(runtime.setRemotePlayDirectInputEnabled(true) == true, "direct input enable should succeed")
        local events = runtime.pollRemotePlayInput(16)
        assertTrue(type(events) == "table", "remote play input events should be table")
        assertTrue(#events >= 1, "expected at least one mocked remote play input event")
        local first = events[1]
        assertTrue(type(first.type) == "string", "event type should normalize to string")
        assertTrue(type(first.sessionId) == "number", "event sessionId should normalize to number")
        local diagnostics = runtime.getRemotePlayInputDiagnostics()
        assertTrue(type(diagnostics) == "table", "diagnostics should be table")
        assertTrue(type(diagnostics.inputSources) == "table", "diagnostics inputSources should be table")
        runtime.shutdown()
    end)
end)

runTest("steam_input_manifest_contains_desktop_and_deck_controller_configs", function()
    local content = readFile("steam_input_manifest.vdf")
    assertTrue(type(content) == "string", "steam_input_manifest.vdf not readable")
    for _, controllerId in ipairs({
        "controller_xboxone",
        "controller_xbox360",
        "controller_xboxelite",
        "controller_ps4",
        "controller_ps5",
        "controller_switch_pro",
        "controller_generic",
        "controller_neptune",
        "controller_steamcontroller_gordon"
    }) do
        assertTrue(content:find(controllerId, 1, true) ~= nil, "manifest missing controller config: " .. controllerId)
    end
end)

runTest("steam_input_methods_exist", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(type(runtime.configureSteamInput) == "function", "configureSteamInput missing")
        assertTrue(type(runtime.shutdownSteamInput) == "function", "shutdownSteamInput missing")
        assertTrue(type(runtime.listSteamInputControllers) == "function", "listSteamInputControllers missing")
        assertTrue(type(runtime.pollSteamInputActions) == "function", "pollSteamInputActions missing")
        assertTrue(type(runtime.getSteamInputDiagnostics) == "function", "getSteamInputDiagnostics missing")
        assertTrue(type(runtime.showSteamInputBindingPanel) == "function", "showSteamInputBindingPanel missing")
        runtime.shutdown()
    end)
end)

runTest("steam_input_configure_and_poll_normalized", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(runtime.configureSteamInput({
            manifestPath = "/tmp/steam_input_manifest.vdf",
            actionSet = "global_controls",
            digitalActions = {"confirm", "cancel"},
            analogActions = {"navigate", "page_scroll"}
        }) == true, "steam input configure should succeed")

        local controllers = runtime.listSteamInputControllers()
        assertTrue(type(controllers) == "table" and #controllers == 2, "expected two steam input controllers")
        assertTrue(type(controllers[1].handleId) == "string", "controller handleId should normalize to string")
        assertTrue(controllers[2].remotePlaySessionId == 101, "remote controller session id should normalize")

        local snapshots = runtime.pollSteamInputActions()
        assertTrue(type(snapshots) == "table" and #snapshots == 2, "expected two steam input snapshots")
        assertTrue(snapshots[1].controller.remotePlaySessionId == 0, "first controller should remain host-local")
        assertTrue(snapshots[2].controller.remotePlaySessionId == 101, "second controller should remain remote")
        assertTrue(snapshots[1].digitalActions[1].name == "confirm", "digital action name should normalize")
        assertTrue(type(snapshots[2].analogActions[1].y) == "number", "analog action y should normalize")

        local diagnostics = runtime.getSteamInputDiagnostics()
        assertTrue(diagnostics.configured == true, "steam input diagnostics should report configured state")
        assertTrue(diagnostics.controllerCount == 2, "steam input diagnostics should track controller count")
        assertTrue(diagnostics.remoteControllerCount == 1, "steam input diagnostics should track remote controller count")
        assertTrue(runtime.showSteamInputBindingPanel("1001") == true, "binding panel helper should pass through")
        assertTrue(runtime.shutdownSteamInput() == true, "steam input shutdown should succeed")
        runtime.shutdown()
    end)
end)

runTest("achievement_and_stat_methods_exist", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(type(runtime.getAchievement) == "function", "getAchievement missing")
        assertTrue(type(runtime.setAchievement) == "function", "setAchievement missing")
        assertTrue(type(runtime.clearAchievement) == "function", "clearAchievement missing")
        assertTrue(type(runtime.storeUserStats) == "function", "storeUserStats missing")
        assertTrue(type(runtime.getStatInt) == "function", "getStatInt missing")
        assertTrue(type(runtime.setStatInt) == "function", "setStatInt missing")
        assertTrue(type(runtime.incrementStatInt) == "function", "incrementStatInt missing")
        runtime.shutdown()
    end)
end)

runTest("collectible_card_profile_methods_exist", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(type(runtime.getGameBadgeLevel) == "function", "getGameBadgeLevel missing")
        assertTrue(type(runtime.getPlayerSteamLevel) == "function", "getPlayerSteamLevel missing")
        runtime.shutdown()
    end)
end)

runTest("collectible_card_profile_wrappers_roundtrip_normalized", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(runtime.getGameBadgeLevel(1, false) == 2, "standard badge level should normalize")
        assertTrue(runtime.getGameBadgeLevel(1, true) == 1, "foil badge level should normalize")
        assertTrue(runtime.getPlayerSteamLevel() == 12, "player steam level should normalize")

        package.loaded["steam_collectibles_runtime"] = nil
        package.loaded["steam_collectibles_defs"] = nil
        local collectiblesRuntime = require("steam_collectibles_runtime")
        local summary = collectiblesRuntime.getSummary()
        assertTrue(summary.standardBadgeLevel == 2, "collectibles runtime should report standard badge level")
        assertTrue(summary.foilBadgeLevel == 1, "collectibles runtime should report foil badge level")
        assertTrue(summary.steamLevel == 12, "collectibles runtime should report player steam level")
        runtime.shutdown()
    end)
end)

runTest("achievement_and_stat_wrappers_roundtrip_normalized", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        local initialAchievement = runtime.getAchievement("ACH_TEST")
        assertTrue(initialAchievement == false, "achievement should default false")
        assertTrue(runtime.setAchievement("ACH_TEST") == true, "setAchievement should succeed")
        assertTrue(runtime.getAchievement("ACH_TEST") == true, "achievement should read back true")
        assertTrue(runtime.clearAchievement("ACH_TEST") == true, "clearAchievement should succeed")
        assertTrue(runtime.getAchievement("ACH_TEST") == false, "achievement should clear back to false")

        assertTrue(runtime.getStatInt("STAT_MATCHES") == 0, "stat should default to zero")
        assertTrue(runtime.setStatInt("STAT_MATCHES", 4) == true, "setStatInt should succeed")
        assertTrue(runtime.getStatInt("STAT_MATCHES") == 4, "stat should read back assigned value")
        local nextValue = runtime.incrementStatInt("STAT_MATCHES", 3)
        assertTrue(nextValue == 7, "incrementStatInt should return new value")
        assertTrue(runtime.storeUserStats() == true, "storeUserStats should succeed")
        runtime.shutdown()
    end)
end)

runTest("lobby_create_join_leave_roundtrip", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")

        local created, lobby = runtime.createFriendsLobby(2)
        assertTrue(created == true, "createFriendsLobby failed")
        assertTrue(type(lobby) == "table" and lobby.lobbyId ~= nil, "invalid lobby payload")

        assertTrue(runtime.setLobbyData(lobby.lobbyId, "session_id", "s-1") == true, "setLobbyData failed")
        assertTrue(runtime.getLobbyData(lobby.lobbyId, "session_id") == "s-1", "getLobbyData mismatch")

        local joined, joinedPayload = runtime.joinLobby(lobby.lobbyId)
        assertTrue(joined == true, "joinLobby failed")
        assertTrue(joinedPayload.lobbyId == lobby.lobbyId, "join lobbyId mismatch")

        local snapshot = runtime.getLobbySnapshot(lobby.lobbyId)
        assertTrue(type(snapshot) == "table", "snapshot must be table")
        assertTrue(type(snapshot.members) == "table" and #snapshot.members == 2, "snapshot members mismatch")

        local member2 = runtime.getSteamIdFromLobbyMember(lobby.lobbyId, 2)
        assertTrue(member2 == "76561198000000099", "member lookup mismatch")

        assertTrue(runtime.leaveLobby(lobby.lobbyId) == true, "leaveLobby failed")

        local events = runtime.pollLobbyEvents(32)
        assertTrue(type(events) == "table" and #events >= 3, "expected lobby events queue")

        runtime.shutdown()
    end)
end)

runTest("list_joinable_lobbies_wrapper_returns_table", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")

        local rows = runtime.listJoinableLobbies({maxResults = 5, protocolVersion = "1"})
        assertTrue(type(rows) == "table", "listJoinableLobbies must return a table")
        assertTrue(#rows >= 1, "expected at least one lobby row")

        runtime.shutdown()
    end)
end)

runTest("persona_name_for_user_wrapper_safe_fallback", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")

        local known = runtime.getPersonaNameForUser("76561198000000099")
        assertTrue(known == "RemoteMock", "expected persona lookup from bridge")

        local missing = runtime.getPersonaNameForUser("76561198000000999")
        assertTrue(missing == nil, "missing persona should safely fallback to nil")

        runtime.shutdown()
    end)
end)

runTest("list_joinable_lobbies_normalizes_entry_shape", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")

        local rows = runtime.listJoinableLobbies({maxResults = 5, protocolVersion = "1"})
        assertTrue(#rows >= 1, "expected normalized entries")

        local entry = rows[1]
        assertTrue(type(entry.lobbyId) == "string", "lobbyId should be normalized to string")
        assertTrue(type(entry.ownerId) == "string", "ownerId should be normalized to string")
        assertTrue(type(entry.ownerName) == "string", "ownerName should be normalized to string")
        assertTrue(type(entry.memberCount) == "number", "memberCount should be normalized to number")
        assertTrue(type(entry.memberLimit) == "number", "memberLimit should be normalized to number")
        assertTrue(type(entry.relation) == "string", "relation should be normalized to string")
        assertTrue(type(entry.visibility) == "string", "visibility should be normalized to string")
        assertTrue(type(entry.joinable) == "boolean", "joinable should be normalized to boolean")

        runtime.shutdown()
    end)
end)

runTest("bridge_fallback_list_joinable_lobbies_returns_empty_table", function()
    withSteamPreload(function()
        error("mock native missing", 0)
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        runtime.init()
        local rows = runtime.listJoinableLobbies({maxResults = 5, protocolVersion = "1"})
        assertTrue(type(rows) == "table", "fallback list must be a table")
        assertTrue(#rows == 0, "fallback list must be empty")

        runtime.shutdown()
    end)
end)

runTest("runtime_download_leaderboard_top_returns_table", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        local rows = runtime.downloadLeaderboardTop("global_glicko2_v1", 1, 100)
        assertTrue(type(rows) == "table", "downloadLeaderboardTop must return table")
        assertTrue(#rows == 100, "downloadLeaderboardTop should return requested rows")
        runtime.shutdown()
    end)
end)

runTest("runtime_download_leaderboard_top_normalizes_entry_shape", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        local rows = runtime.downloadLeaderboardTop("global_glicko2_v1", 1, 5)
        assertTrue(type(rows) == "table" and #rows == 5, "expected normalized top rows")
        local row = rows[1]
        assertTrue(type(row.userId) == "string", "top row userId should be string")
        assertTrue(type(row.score) == "number", "top row score should be number")
        assertTrue(type(row.rank) == "number", "top row rank should be number")
        assertTrue(type(row.details) == "table", "top row details should be table")
        runtime.shutdown()
    end)
end)

runTest("bridge_fallback_download_leaderboard_top_returns_empty_table", function()
    withSteamPreload(function()
        error("mock native missing", 0)
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        runtime.init()
        local rows = runtime.downloadLeaderboardTop("global_glicko2_v1", 1, 10)
        assertTrue(type(rows) == "table", "fallback top list must be a table")
        assertTrue(#rows == 0, "fallback top list must be empty")
        runtime.shutdown()
    end)
end)

runTest("p2p_send_poll_roundtrip", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")
        assertTrue(runtime.sendNet("76561198000000099", "hello", 2, "reliable") == true, "sendNet failed")

        local packets = runtime.pollNet(8)
        assertTrue(type(packets) == "table" and #packets == 1, "pollNet expected one packet")
        assertTrue(packets[1].payload == "hello", "packet payload mismatch")
        assertTrue(packets[1].channel == 2, "packet channel mismatch")

        runtime.shutdown()
    end)
end)

runTest("sendnet_propagates_native_reason", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")

        local bridge = require("integrations.steam.bridge")
        local originalSendNet = bridge.sendNet
        bridge.sendNet = function(peerId, payload, channel, sendType)
            return false, "send_failed:mock_reason"
        end

        local ok, reason = runtime.sendNet("76561198000000099", "hello", 2, "reliable")
        bridge.sendNet = originalSendNet

        assertTrue(ok == false, "sendNet should fail")
        assertTrue(tostring(reason):find("send_failed:mock_reason", 1, true) ~= nil, "sendNet should propagate reason")
        runtime.shutdown()
    end)
end)

runTest("leaderboard_find_upload_download_roundtrip", function()
    withSteamPreload(function()
        return buildMockNativeBridge()
    end, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        assertTrue(runtime.init() == true, "runtime init failed")

        local boardOk, board = runtime.findOrCreateLeaderboard("global_glicko2_v1", "descending", "numeric")
        assertTrue(boardOk == true, "findOrCreateLeaderboard failed")
        assertTrue(type(board) == "table" and board.name == "global_glicko2_v1", "leaderboard payload mismatch")

        assertTrue(runtime.uploadLeaderboardScore("global_glicko2_v1", 1234, {16, 1}, true) == true, "upload leaderboard failed")

        local userId = runtime.getLocalUserId()
        local entries = runtime.downloadLeaderboardEntriesForUsers("global_glicko2_v1", {userId})
        assertTrue(type(entries) == "table" and #entries == 1, "user leaderboard entries mismatch")
        assertTrue(entries[1].score == 1234, "leaderboard score mismatch")

        local around = runtime.downloadLeaderboardAroundUser("global_glicko2_v1", -5, 5)
        assertTrue(type(around) == "table" and #around >= 1, "around user leaderboard entries mismatch")

        runtime.shutdown()
    end)
end)

runTest("steam_input_path_diagnostics_prefer_source_base_directory_for_fused_builds", function()
    withLoveFilesystemMock({
        getSource = function()
            return "/games/MeowOverMoo/MOM.exe"
        end,
        getSourceBaseDirectory = function()
            return "/games/MeowOverMoo"
        end,
        getWorkingDirectory = function()
            return "/tmp/fallback-working-dir"
        end,
        getSaveDirectory = function()
            return "/tmp/mock-save"
        end
    }, function()
        local runtime = newRuntime({
            ENABLED = true,
            APP_ID = "480",
            BRIDGE_MODULE = "integrations.steam.bridge",
            DEBUG_LOGS = false,
            REQUIRED = false
        })

        local diagnostics = runtime.getPathDiagnostics()
        assertTrue(diagnostics.source == "/games/MeowOverMoo/MOM.exe", "source should report fused executable path")
        assertTrue(diagnostics.sourceBaseDir == "/games/MeowOverMoo", "source base dir should report executable folder")
        assertTrue(diagnostics.workingDir == "/tmp/fallback-working-dir", "working dir should report fallback directory")
        assertTrue(diagnostics.manifestPath == "/games/MeowOverMoo/steam_input_manifest.vdf", "manifest path should resolve from source base directory")
        assertTrue(not tostring(diagnostics.manifestPath):find("MOM%.exe/", 1), "manifest path should not append onto the executable path")
    end)
end)

runTest("steam_input_diagnostics_expose_path_and_controller_fields", function()
    local manifestDir = "/tmp/mom_runtime_smoke_manifest"
    os.execute("mkdir -p '" .. manifestDir .. "'")
    local manifestPath = manifestDir .. "/steam_input_manifest.vdf"
    local manifestFile = assert(io.open(manifestPath, "w"))
    manifestFile:write("mock manifest")
    manifestFile:close()

    withLoveFilesystemMock({
        getSource = function()
            return manifestDir .. "/MOM.exe"
        end,
        getSourceBaseDirectory = function()
            return manifestDir
        end,
        getWorkingDirectory = function()
            return "/tmp/mock-working-dir"
        end,
        getSaveDirectory = function()
            return "/tmp/mock-save"
        end
    }, function()
        withSteamPreload(function()
            return buildMockNativeBridge()
        end, function()
            local runtime = newRuntime({
                ENABLED = true,
                APP_ID = "480",
                BRIDGE_MODULE = "integrations.steam.bridge",
                DEBUG_LOGS = false,
                REQUIRED = false
            })

            assertTrue(runtime.init() == true, "runtime init failed")
            assertTrue(runtime.configureSteamInput({
                manifestFile = "steam_input_manifest.vdf",
                actionSet = "global_controls",
                digitalActions = {"confirm", "cancel"},
                analogActions = {"navigate", "page_scroll"}
            }) == true, "steam input configure should succeed")
            runtime.pollSteamInputActions()

            local diagnostics = runtime.getSteamInputDiagnostics()
            assertTrue(diagnostics.manifestPath == manifestPath, "steam input diagnostics should expose resolved manifest path")
            assertTrue(diagnostics.manifestExists == true, "steam input diagnostics should expose manifest existence")
            assertTrue(diagnostics.source == manifestDir .. "/MOM.exe", "steam input diagnostics should expose source path")
            assertTrue(diagnostics.sourceBaseDir == manifestDir, "steam input diagnostics should expose source base dir")
            assertTrue(diagnostics.workingDir == "/tmp/mock-working-dir", "steam input diagnostics should expose working dir")
            assertTrue(diagnostics.controllerCount == 2, "steam input diagnostics should expose controller count")
            assertTrue(not tostring(diagnostics.manifestPath):find("MOM%.exe/", 1), "configured manifest path should not append onto executable path")
            runtime.shutdown()
        end)
    end)
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
    end
end

print("# Steam Runtime Smoke Report")
print("")
print("- Passed: " .. tostring(passed))
print("- Failed: " .. tostring(#results - passed))
print("")
for _, result in ipairs(results) do
    local status = result.ok and "PASS" or "FAIL"
    print(string.format("- `%s` %s", status, result.name))
    if not result.ok then
        print("  - Error: " .. tostring(result.err))
    end
end

os.exit((failed == 0) and 0 or 1)
