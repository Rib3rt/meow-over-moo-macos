local factionSelect = {}

local stateMachineRef = {}
local ConfirmDialog = require("confirmDialog") -- Add the confirmation dialog module
local randomGen = require('randomGenerator')
local uiTheme = require("uiTheme")
local soundCache = require("soundCache")
local steamRuntime = require("steam_runtime")
local onlineRatingStore = require("online_rating_store")
local glicko2 = require("glicko2_rating")
local Factions = require("factions")
local Controller = require("controller")
local fontCache = require("fontCache")
local audioRuntime = require("audio_runtime")

local MONOGRAM_FONT_PATH = "assets/fonts/monogram-extended.ttf"

local function getMonogramFont(size)
    return fontCache.get(MONOGRAM_FONT_PATH, size)
end

-- Card assets for unified appearance with gameplay
local cardAssets = {
    cardTemplate = nil,
    cardBackgroundGrass = nil,
    bluFactionImage = nil,
    redFactionImage = nil
}

-- Background shader for visual consistency with gameplay
local backgroundShader = nil
local UI_COLORS = uiTheme.COLORS
local lightenColor = uiTheme.lighten
local darkenColor = uiTheme.darken
local desaturateColor = uiTheme.desaturate
-- Per-faction animation smoothing state
local ANIM_STATE = {
    [1] = {tilt=0, vel=0, angle=0, angleV=0, sweep=0, sweepV=0},
    [2] = {tilt=0, vel=0, angle=0, angleV=0, sweep=0, sweepV=0}
}
-- Game state
local GAME_STATE = {
    initialized = false
}
local onlineReadyState = { hostReady = false, guestReady = false, revision = 0 }
local onlineSetupRevision = 0
local lastAppliedSetupRevision = 0
local prematchTransportReady = false
local prematchHelloNonce = 0
local awaitingPrematchAckNonce = 0
local lastPrematchHelloSentAt = 0
local PREMATCH_HELLO_INTERVAL_SEC = 0.5
local pendingSetupSnapshot = false
local pendingReadyState = false
local lastSetupSnapshotFlushAt = 0
local lastReadyStateFlushAt = 0
local BROADCAST_FLUSH_INTERVAL_SEC = 0.15
local pendingGuestReady = nil
local pendingGuestReadySince = nil
local PENDING_READY_TIMEOUT_SEC = 5.0
local lastReadyTelemetryKey = nil
local disconnectDialogShown = false
local remotePlayNoInputWarned = false
local localOnlineRatingProfile = nil
local peerOnlineRatingProfile = nil
local lastRemotePlayGuestCount = 0
local REMOTE_PLAY_INPUT_WARN_AFTER_SEC = 8.0
local buildOnlineSetupPayload = nil
local uiElements = {}
local navState = {
    selectedSection = 1,  -- 1 = blue faction, 2 = red faction, 3 = buttons
    selectedSectionItem = 1, -- For factions: 1 = left arrow, 2 = right arrow; For buttons: 1 = back, 2 = random, 3 = start
    sections = { "blueFaction", "redFaction", "buttons" }
}
local isButtonInteractableByKey

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return (os and os.time and os.time()) or 0
end

local function shouldLogFactionDebug()
    return (((SETTINGS or {}).STEAM or {}).DEBUG_LOGS == true) or (((DEBUG or {}).UI) == true)
end

local function logFactionDebug(...)
    if shouldLogFactionDebug() then
        print(...)
    end
end

local function isOnlineMode()
    return GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET
end

local function isRemotePlayLocalVariant()
    return GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL and tostring((GAME.CURRENT and GAME.CURRENT.LOCAL_MATCH_VARIANT) or "couch") == "remote_play"
end

local function getRemotePlayGuestCount()
    if not isRemotePlayLocalVariant() then
        return 0
    end
    if steamRuntime.isOnlineReady() ~= true or type(steamRuntime.getRemotePlaySessionCount) ~= "function" then
        return 0
    end
    return math.max(0, tonumber(steamRuntime.getRemotePlaySessionCount()) or 0)
end

local function canStartLocalMatch()
    if not isRemotePlayLocalVariant() then
        return true
    end
    return getRemotePlayGuestCount() >= 1
end

local function showRemotePlayAudioMutedWarning()
    if not isRemotePlayLocalVariant() then
        return
    end
    if not audioRuntime.consumeRemotePlayMutedWarning() then
        return
    end
    ConfirmDialog.showMessage(
        "Remote Play Audio",
        "Host audio is disabled or muted. Remote Play guests will hear no game audio until host audio is re-enabled.",
        { title = "Remote Play Audio", confirmText = "OK", defaultFocus = "confirm" }
    )
end

local function getOnlineSession()
    return GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.session or nil
end

local function resolveStoredOnlineRatingSeed(defaultRating)
    local fallback = tonumber(defaultRating) or 1200
    if onlineRatingStore and type(onlineRatingStore.loadProfile) == "function" then
        local profile = onlineRatingStore.loadProfile()
        if type(profile) == "table" and tonumber(profile.rating) ~= nil then
            return math.floor((tonumber(profile.rating) or fallback) + 0.5)
        end
    end
    return fallback
end


local function resolveOnlineRatingLeaderboardSeed()
    local leaderboardName = ((SETTINGS.RATING or SETTINGS.ELO) and (SETTINGS.RATING or SETTINGS.ELO).LEADERBOARD_NAME) or "global_glicko2_v1"
    local defaultRating = ((SETTINGS.RATING or SETTINGS.ELO) and (SETTINGS.RATING or SETTINGS.ELO).DEFAULT_RATING) or 1200
    local storedSeed = resolveStoredOnlineRatingSeed(defaultRating)
    local localUserId = steamRuntime.getLocalUserId and steamRuntime.getLocalUserId() or nil
    if localUserId and steamRuntime.ensureLocalLeaderboardPresence then
        steamRuntime.ensureLocalLeaderboardPresence(leaderboardName, storedSeed)
    end
    if not localUserId or type(steamRuntime.downloadLeaderboardEntriesForUsers) ~= "function" then
        return storedSeed
    end
    local entries = steamRuntime.downloadLeaderboardEntriesForUsers(leaderboardName, {localUserId}) or {}
    local entry = entries[1]
    if entry and tonumber(entry.score) then
        return tonumber(entry.score)
    end
    return storedSeed
end

local function ensureLocalOnlineRatingProfileLoaded()
    if not isOnlineMode() then
        return nil
    end
    if localOnlineRatingProfile then
        return localOnlineRatingProfile
    end
    local seedScore = resolveOnlineRatingLeaderboardSeed()
    local profile, source = onlineRatingStore.ensureLocalProfile(seedScore)
    localOnlineRatingProfile = glicko2.prepareProfileForMatch(profile)
    logFactionDebug(string.format(
        "[OnlineFactionSelect] Rating profile ready source=%s rating=%s rd=%s games=%s",
        tostring(source or "unknown"),
        tostring(math.floor((localOnlineRatingProfile.rating or 0) + 0.5)),
        tostring(math.floor((localOnlineRatingProfile.rd or 0) + 0.5)),
        tostring(localOnlineRatingProfile.games or 0)
    ))
    local repairNotice = onlineRatingStore.consumeRepairNotice and onlineRatingStore.consumeRepairNotice() or nil
    if repairNotice and ConfirmDialog and type(ConfirmDialog.showMessage) == "function" and type(ConfirmDialog.isActive) == "function" and not ConfirmDialog.isActive() then
        ConfirmDialog.showMessage(repairNotice.text, nil, {
            title = repairNotice.title,
            confirmText = "OK"
        })
    end
    return localOnlineRatingProfile
end

local function capturePeerOnlineRatingProfile(profile)
    if type(profile) ~= "table" then
        return false
    end
    peerOnlineRatingProfile = glicko2.prepareProfileForMatch(profile)
    return true
end

local function getOnlineLockstep()
    return GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.lockstep or nil
end

local function consumePendingOnlineLobbyEvents(maxEvents)
    local online = GAME.CURRENT.ONLINE or {}
    local queue = online.pendingLobbyEvents
    if type(queue) ~= "table" or #queue == 0 then
        return {}
    end

    local limit = maxEvents or #queue
    if limit < 1 then
        limit = #queue
    end

    local out = {}
    local count = math.min(limit, #queue)
    for i = 1, count do
        out[#out + 1] = table.remove(queue, 1)
    end
    return out
end

local function resolveOnlineRole(sessionOverride)
    if not isOnlineMode() then
        return nil
    end

    local online = GAME.CURRENT.ONLINE or {}

    -- Faction role is frozen by onlineLobby at transition time to prevent stale host defaults.
    local lockedRole = online.factionRole
    if lockedRole == "host" or lockedRole == "guest" then
        return lockedRole
    end

    local session = sessionOverride or online.session
    if session then
        local localId = session.localUserId and tostring(session.localUserId) or nil
        local hostId = session.hostUserId and tostring(session.hostUserId) or nil
        if localId and hostId and localId ~= "" and hostId ~= "" then
            if localId == hostId then
                return "host"
            end
            return "guest"
        end
    end

    if online.role == "host" or online.role == "guest" then
        return online.role
    end

    return nil
end

local function syncResolvedOnlineRole(sessionOverride)
    local resolvedRole = resolveOnlineRole(sessionOverride)
    if not resolvedRole then
        return nil
    end

    local session = sessionOverride or getOnlineSession()
    if session then
        session.role = resolvedRole
    end

    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    GAME.CURRENT.ONLINE.role = resolvedRole
    GAME.CURRENT.ONLINE.factionRole = resolvedRole
    return resolvedRole
end

local function isOnlineGuestMode()
    if not isOnlineMode() then
        return false
    end

    local role = syncResolvedOnlineRole()
    if role == "guest" then
        return true
    end
    if role == "host" then
        return false
    end

    -- Fail-safe: if role cannot be resolved yet, default to guest restrictions.
    return true
end

local function canEditOnlineSetup()
    return not isOnlineGuestMode()
end

local function getOnlineLocalReady()
    local role = syncResolvedOnlineRole()
    if role == "host" then
        return onlineReadyState.hostReady == true
    end
    if role == "guest" then
        return onlineReadyState.guestReady == true
    end
    return false
end

local function canToggleOnlineReady()
    if not isOnlineMode() then
        return false
    end
    local session = getOnlineSession()
    local lockstep = getOnlineLockstep()
    if session == nil or lockstep == nil then
        return false
    end
    if session.connected ~= true then
        return false
    end
    if not session.peerUserId or tostring(session.peerUserId) == tostring(session.localUserId) then
        return false
    end
    if prematchTransportReady ~= true then
        return false
    end
    if not ensureLocalOnlineRatingProfileLoaded() or not peerOnlineRatingProfile then
        return false
    end
    if syncResolvedOnlineRole(session) == "guest" and pendingGuestReady ~= nil then
        return false
    end
    return true
end

local function canStartOnlineMatch()
    if not isOnlineMode() then
        return true
    end

    local session = getOnlineSession()
    local role = syncResolvedOnlineRole(session)
    if not session or role ~= "host" then
        return false
    end

    return session.connected == true
        and prematchTransportReady == true
        and onlineReadyState.hostReady == true
        and onlineReadyState.guestReady == true
        and ensureLocalOnlineRatingProfileLoaded() ~= nil
        and peerOnlineRatingProfile ~= nil
end

local function clearPendingGuestReady(reason)
    if pendingGuestReady ~= nil then
        logFactionDebug("[OnlineFactionSelect] Clearing pending guest ready: " .. tostring(reason or "unspecified"))
    end
    pendingGuestReady = nil
    pendingGuestReadySince = nil
end

local function clearOnlineRuntimeState(reasonCode)
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    local online = GAME.CURRENT.ONLINE
    online.active = false
    online.role = nil
    online.session = nil
    online.lockstep = nil
    online.autoJoinLobbyId = nil
    online.pendingLobbyEvents = {}
    online.eloSummary = nil
    if reasonCode then
        online.resultCode = reasonCode
    end
end

local function terminateOnlineFactionAndReturnToMainMenu(reasonCode)
    local session = getOnlineSession()
    local lockstep = getOnlineLockstep()

    if lockstep and session and session.connected and session.sessionId then
        lockstep:sendPacket({
            kind = "MATCH_ABORT",
            sessionId = session.sessionId,
            reason = reasonCode or "faction_exit"
        })
    end

    if session then
        session:leave()
    end

    clearPendingGuestReady(reasonCode or "faction_exit")
    clearOnlineRuntimeState(reasonCode or "faction_exit")
    disconnectDialogShown = false
    remotePlayNoInputWarned = false
    if stateMachineRef and stateMachineRef.changeState then
        stateMachineRef.changeState("mainMenu")
    end
end

local function showFactionDisconnectDialogAndExit(reasonCode)
    if disconnectDialogShown then
        return
    end
    disconnectDialogShown = true
    print("[OnlineFactionSelect] Opponent disconnected in faction screen: " .. tostring(reasonCode or "unknown"))
    ConfirmDialog.showMessage(
        "Opponent disconnected. Returning to main menu.",
        function()
            disconnectDialogShown = false
            terminateOnlineFactionAndReturnToMainMenu(reasonCode or "peer_disconnect")
        end,
        {
            title = "Opponent Disconnected",
            confirmText = "OK"
        }
    )
end

local function resetPrematchTransportState(reason)
    prematchTransportReady = false
    prematchHelloNonce = 0
    awaitingPrematchAckNonce = 0
    lastPrematchHelloSentAt = 0
    peerOnlineRatingProfile = nil
    if reason then
        logFactionDebug("[OnlineFactionSelect] Prematch transport reset: " .. tostring(reason))
    end
end

local function queuePendingReadyStateBroadcast()
    pendingReadyState = true
end

local function queuePendingSetupSnapshot()
    pendingSetupSnapshot = true
end

local function flushPendingHostBroadcasts(forceSend)
    if not isOnlineMode() then
        return
    end

    local session = getOnlineSession()
    local lockstep = getOnlineLockstep()
    if not session or not lockstep or session.role ~= "host" then
        return
    end

    local now = nowSeconds()
    local allowSetup = forceSend or (now - (lastSetupSnapshotFlushAt or 0)) >= BROADCAST_FLUSH_INTERVAL_SEC
    local allowReady = forceSend or (now - (lastReadyStateFlushAt or 0)) >= BROADCAST_FLUSH_INTERVAL_SEC

    if pendingSetupSnapshot and allowSetup then
        local setupPayload = buildOnlineSetupPayload and buildOnlineSetupPayload() or nil
        if setupPayload then
            local sent, sendErr = lockstep:sendPacket({
                kind = "SETUP_SNAPSHOT",
                sessionId = session.sessionId,
                setup = setupPayload
            })
            if sent then
                pendingSetupSnapshot = false
                lastSetupSnapshotFlushAt = now
                logFactionDebug(string.format(
                    "[OnlineFactionSelect] Setup snapshot sent rev=%s peer=%s",
                    tostring(setupPayload.setupRevision),
                    tostring(session.peerUserId)
                ))
            else
                print(string.format(
                    "[OnlineFactionSelect] Setup snapshot send failed rev=%s peer=%s reason=%s",
                    tostring(setupPayload.setupRevision),
                    tostring(session.peerUserId),
                    tostring(sendErr)
                ))
            end
        end
    end

    if pendingReadyState and allowReady then
        local sent, sendErr = lockstep:sendReadyState(
            onlineReadyState.hostReady,
            onlineReadyState.guestReady,
            onlineReadyState.revision,
            onlineSetupRevision
        )
        if sent then
            pendingReadyState = false
            lastReadyStateFlushAt = now
        else
            print("[OnlineFactionSelect] Failed to broadcast ready state: " .. tostring(sendErr))
        end
    end
end

local function logReadyTelemetryState(context)
    if not isOnlineMode() then
        return
    end

    local session = getOnlineSession()
    local role = session and tostring(session.role or "-") or "-"
    local connected = session and (session.connected == true) or false
    local hostReady = onlineReadyState.hostReady == true
    local guestReady = onlineReadyState.guestReady == true
    local pending = pendingGuestReady
    local revision = tonumber(onlineReadyState.revision) or 0
    local setupRevision = tonumber(onlineSetupRevision) or 0
    local transportReady = prematchTransportReady == true

    local key = string.format("r=%s|c=%s|h=%s|g=%s|p=%s|rev=%d|srev=%d|tx=%s", role, tostring(connected), tostring(hostReady), tostring(guestReady), tostring(pending), revision, setupRevision, tostring(transportReady))
    if key == lastReadyTelemetryKey then
        return
    end

    lastReadyTelemetryKey = key
    logFactionDebug(string.format(
        "[OnlineFactionSelect] Ready telemetry (%s): role=%s connected=%s transportReady=%s hostReady=%s guestReady=%s pendingGuest=%s rev=%d setupRev=%d",
        tostring(context or "state_change"),
        role,
        tostring(connected),
        tostring(transportReady),
        tostring(hostReady),
        tostring(guestReady),
        tostring(pending),
        revision,
        setupRevision
    ))
end

local function broadcastOnlineReadyState()
    if not isOnlineMode() then
        return
    end

    local session = getOnlineSession()
    if not session or session.role ~= "host" then
        return
    end
    queuePendingReadyStateBroadcast()
    flushPendingHostBroadcasts(false)
end

local function markOnlineSetupChanged()
    if not isOnlineMode() then
        return
    end

    local session = getOnlineSession()
    if not session or session.role ~= "host" then
        return
    end

    onlineSetupRevision = (tonumber(onlineSetupRevision) or 0) + 1
    resetPrematchTransportState("setup_changed")
end

local function hostResetOnlineReadyState()
    if not isOnlineMode() then
        return
    end

    local session = getOnlineSession()
    if not session or session.role ~= "host" then
        return
    end

    if (tonumber(onlineSetupRevision) or 0) < 1 then
        onlineSetupRevision = 1
    end
    onlineReadyState.hostReady = false
    onlineReadyState.guestReady = false
    onlineReadyState.revision = (onlineReadyState.revision or 0) + 1
    clearPendingGuestReady("host_reset")
    broadcastOnlineReadyState()
    logReadyTelemetryState("host_reset")
end

local function toggleOnlineReady()
    if not canToggleOnlineReady() then
        return false
    end

    local session = getOnlineSession()
    local lockstep = getOnlineLockstep()
    if not session or not lockstep then
        return false
    end

    if syncResolvedOnlineRole(session) == "host" then
        onlineReadyState.hostReady = not onlineReadyState.hostReady
        onlineReadyState.revision = (onlineReadyState.revision or 0) + 1
        broadcastOnlineReadyState()
        logReadyTelemetryState("host_toggle")
        return true
    end

    if pendingGuestReady ~= nil then
        logFactionDebug("[OnlineFactionSelect] Guest ready toggle ignored while pending confirmation")
        return false
    end

    local desiredReady = not onlineReadyState.guestReady
    local sent, sendErr = lockstep:sendReadyRequest(desiredReady, onlineSetupRevision)
    if not sent then
        print("[OnlineFactionSelect] Guest ready request send failed: " .. tostring(sendErr))
        clearPendingGuestReady("send_failed")
        return false
    end

    pendingGuestReady = desiredReady
    pendingGuestReadySince = nowSeconds()
    logFactionDebug(string.format(
        "[OnlineFactionSelect] Guest ready request sent; pending confirmation=%s setupRev=%s",
        tostring(desiredReady),
        tostring(onlineSetupRevision)
    ))
    logReadyTelemetryState("guest_toggle_pending")
    return true
end

local BUTTON_VISIBILITY_ORDER = {"back", "random", "ready", "start"}
local FACTION_UI_PROFILE = {
    SINGLE_LOCAL = "single_local",
    ONLINE_HOST = "online_host",
    ONLINE_GUEST = "online_guest"
}

local PROFILE_VISIBLE_BUTTON_KEYS = {
    [FACTION_UI_PROFILE.SINGLE_LOCAL] = {"back", "random", "start"},
    [FACTION_UI_PROFILE.ONLINE_HOST] = {"back", "random", "ready", "start"},
    [FACTION_UI_PROFILE.ONLINE_GUEST] = {"back", "ready"}
}

local BUTTON_LAYOUT = {
    width = 120,
    height = 50,
    gap = 14,
    y = 550
}

local BUTTON_STYLE_COLORS = {
    normal = uiTheme.BUTTON_VARIANTS.default.base,
    normalHover = uiTheme.BUTTON_VARIANTS.default.hover,
    normalPressed = uiTheme.BUTTON_VARIANTS.default.pressed,
    normalBorder = uiTheme.BUTTON_VARIANTS.default.border,
    normalText = uiTheme.BUTTON_VARIANTS.default.text,
    ready = uiTheme.BUTTON_VARIANTS.success.base,
    readyHover = uiTheme.BUTTON_VARIANTS.success.hover,
    readyPressed = uiTheme.BUTTON_VARIANTS.success.pressed,
    readyBorder = uiTheme.BUTTON_VARIANTS.success.border,
    readyText = uiTheme.BUTTON_VARIANTS.success.text,
    disabled = uiTheme.BUTTON_VARIANTS.disabled.base,
    disabledHover = uiTheme.BUTTON_VARIANTS.disabled.hover,
    disabledPressed = uiTheme.BUTTON_VARIANTS.disabled.pressed,
    disabledBorder = uiTheme.BUTTON_VARIANTS.disabled.border,
    disabledText = uiTheme.BUTTON_VARIANTS.disabled.text
}

local START_DISABLED_STYLE = {
    base = {0.14, 0.14, 0.14, 0.94},
    hover = {0.14, 0.14, 0.14, 0.94},
    pressed = {0.14, 0.14, 0.14, 0.94},
    border = {0.3, 0.3, 0.3, 0.96},
    textColor = {0.62, 0.62, 0.62, 0.96}
}

local function resolveButtonVisualState(buttonKey)
    if buttonKey == "ready" and isOnlineMode() then
        local isGuestPending = pendingGuestReady ~= nil and syncResolvedOnlineRole(getOnlineSession()) == "guest"
        local readyActive = getOnlineLocalReady() or isGuestPending
        if readyActive then
            return {
                base = BUTTON_STYLE_COLORS.ready,
                hover = BUTTON_STYLE_COLORS.readyHover,
                pressed = BUTTON_STYLE_COLORS.readyPressed,
                border = BUTTON_STYLE_COLORS.readyBorder,
                textColor = BUTTON_STYLE_COLORS.readyText,
                text = "Ready"
            }
        end
        return {
            base = BUTTON_STYLE_COLORS.normal,
            hover = BUTTON_STYLE_COLORS.normalHover,
            pressed = BUTTON_STYLE_COLORS.normalPressed,
            border = BUTTON_STYLE_COLORS.normalBorder,
            textColor = BUTTON_STYLE_COLORS.normalText,
            text = "Ready"
        }
    end

    if buttonKey == "start" then
        local isDisabled = false
        if isOnlineMode() then
            isDisabled = not canStartOnlineMatch()
        elseif isRemotePlayLocalVariant() then
            isDisabled = not canStartLocalMatch()
        end
        if isDisabled then
            return {
                base = START_DISABLED_STYLE.base,
                hover = START_DISABLED_STYLE.hover,
                pressed = START_DISABLED_STYLE.pressed,
                border = START_DISABLED_STYLE.border,
                textColor = START_DISABLED_STYLE.textColor,
                disabled = true,
                text = "Start Game"
            }
        end
        return {
            base = BUTTON_STYLE_COLORS.normal,
            hover = BUTTON_STYLE_COLORS.normalHover,
            pressed = BUTTON_STYLE_COLORS.normalPressed,
            border = BUTTON_STYLE_COLORS.normalBorder,
            textColor = BUTTON_STYLE_COLORS.normalText,
            text = "Start Game"
        }
    end

    if buttonKey == "random" then
        return {
            base = BUTTON_STYLE_COLORS.normal,
            hover = BUTTON_STYLE_COLORS.normalHover,
            pressed = BUTTON_STYLE_COLORS.normalPressed,
            border = BUTTON_STYLE_COLORS.normalBorder,
            textColor = BUTTON_STYLE_COLORS.normalText,
            text = "Random"
        }
    end

    if buttonKey == "back" then
        return {
            base = BUTTON_STYLE_COLORS.normal,
            hover = BUTTON_STYLE_COLORS.normalHover,
            pressed = BUTTON_STYLE_COLORS.normalPressed,
            border = BUTTON_STYLE_COLORS.normalBorder,
            textColor = BUTTON_STYLE_COLORS.normalText,
            text = "Back"
        }
    end

    return {
        base = BUTTON_STYLE_COLORS.normal,
        hover = BUTTON_STYLE_COLORS.normalHover,
        pressed = BUTTON_STYLE_COLORS.normalPressed,
        border = BUTTON_STYLE_COLORS.normalBorder,
        textColor = BUTTON_STYLE_COLORS.normalText,
        text = nil
    }
end

local function applyButtonVisualState(buttonDef, buttonKey, preserveCurrentColor)
    if type(buttonDef) ~= "table" then
        return
    end

    local visual = resolveButtonVisualState(buttonKey)
    buttonDef.baseColor = visual.base
    buttonDef.hoverColor = visual.hover
    buttonDef.pressedColor = visual.pressed
    buttonDef.borderColor = visual.border or BUTTON_STYLE_COLORS.normalBorder
    buttonDef.textColor = visual.textColor or BUTTON_STYLE_COLORS.normalText
    buttonDef.disabledVisual = visual.disabled == true

    if visual.text ~= nil then
        buttonDef.text = visual.text
    end

    if preserveCurrentColor and buttonDef.currentColor == buttonDef.hoverColor then
        return
    end

    if preserveCurrentColor and buttonDef.pressed == true then
        buttonDef.currentColor = buttonDef.pressedColor
        return
    end

    buttonDef.currentColor = buttonDef.baseColor
end

local lastFactionUiButtonSignature = nil

local function makeDefaultButtonDef(buttonKey)
    local defaultsByKey = {
        back = {
            x = SETTINGS.DISPLAY.WIDTH / 2 - 315,
            y = BUTTON_LAYOUT.y,
            width = BUTTON_LAYOUT.width,
            height = BUTTON_LAYOUT.height,
            text = "Back"
        },
        random = {
            x = SETTINGS.DISPLAY.WIDTH / 2 - 145,
            y = BUTTON_LAYOUT.y,
            width = BUTTON_LAYOUT.width,
            height = BUTTON_LAYOUT.height,
            text = "Random"
        },
        ready = {
            x = SETTINGS.DISPLAY.WIDTH / 2 + 25,
            y = BUTTON_LAYOUT.y,
            width = BUTTON_LAYOUT.width,
            height = BUTTON_LAYOUT.height,
            text = "Ready"
        },
        start = {
            x = SETTINGS.DISPLAY.WIDTH / 2 + 195,
            y = BUTTON_LAYOUT.y,
            width = BUTTON_LAYOUT.width,
            height = BUTTON_LAYOUT.height,
            text = "Start Game"
        }
    }
    local source = defaultsByKey[buttonKey] or defaultsByKey.back
    return {
        x = source.x,
        y = source.y,
        width = source.width,
        height = source.height,
        text = source.text,
        currentColor = UI_COLORS.button,
        hoverColor = UI_COLORS.buttonHover,
        pressedColor = UI_COLORS.buttonPressed,
        pressed = false,
        pressTimer = 0
    }
end

local function ensureButtonDefinitions()
    if type(uiElements) ~= "table" then
        return false
    end

    if type(uiElements.buttons) ~= "table" then
        uiElements.buttons = {}
    end
    local buttons = uiElements.buttons

    local defaults = {
        back = makeDefaultButtonDef("back"),
        random = makeDefaultButtonDef("random"),
        ready = makeDefaultButtonDef("ready"),
        start = makeDefaultButtonDef("start")
    }

    for key, defaultsForKey in pairs(defaults) do
        if type(buttons[key]) ~= "table" then
            buttons[key] = {}
        end
        local button = buttons[key]
        for prop, value in pairs(defaultsForKey) do
            if button[prop] == nil then
                button[prop] = value
            end
        end
    end

    return true
end

local function resolveFactionUiProfile()
    if isOnlineMode() then
        if isOnlineGuestMode() then
            return FACTION_UI_PROFILE.ONLINE_GUEST
        end
        return FACTION_UI_PROFILE.ONLINE_HOST
    end
    return FACTION_UI_PROFILE.SINGLE_LOCAL
end

local function getVisibleButtonKeysForProfile(profile)
    local source = PROFILE_VISIBLE_BUTTON_KEYS[profile]
    if type(source) ~= "table" or #source == 0 then
        source = PROFILE_VISIBLE_BUTTON_KEYS[FACTION_UI_PROFILE.SINGLE_LOCAL]
    end
    local keys = {}
    for i, key in ipairs(source) do
        keys[i] = key
    end
    return keys
end

local function logFactionUiProfileButtons()
    local profile = resolveFactionUiProfile()
    local keys = getVisibleButtonKeysForProfile(profile)
    if #keys == 0 then
        keys = getVisibleButtonKeysForProfile(FACTION_UI_PROFILE.SINGLE_LOCAL)
    end
    local signature = tostring(profile) .. "|" .. table.concat(keys, ",")
    if signature ~= lastFactionUiButtonSignature then
        logFactionDebug(string.format("[FactionUI] profile=%s visibleButtons=%s", tostring(profile), table.concat(keys, ",")))
        lastFactionUiButtonSignature = signature
    end
end

local function getVisibleButtonKeys()
    return getVisibleButtonKeysForProfile(resolveFactionUiProfile())
end

local function isButtonVisible(buttonKey)
    if not buttonKey then
        return false
    end
    for _, key in ipairs(getVisibleButtonKeys()) do
        if key == buttonKey then
            return true
        end
    end
    return false
end

local function getVisibleButtons()
    local buttons = {}
    if not uiElements then
        return buttons
    end
    ensureButtonDefinitions()
    if type(uiElements.buttons) ~= "table" then
        return buttons
    end

    local visibleLookup = {}
    local visibleKeys = getVisibleButtonKeys()
    if #visibleKeys == 0 then
        visibleKeys = getVisibleButtonKeysForProfile(FACTION_UI_PROFILE.SINGLE_LOCAL)
    end
    for _, key in ipairs(visibleKeys) do
        visibleLookup[key] = true
    end

    for _, key in ipairs(BUTTON_VISIBILITY_ORDER) do
        local button = uiElements.buttons[key]
        if type(button) ~= "table" then
            button = makeDefaultButtonDef(key)
            uiElements.buttons[key] = button
        end
        if button then
            local isVisible = visibleLookup[key] == true
            button.visible = isVisible
            button.__key = key
            applyButtonVisualState(button, key, true)
            if not isVisible then
                button.pressed = false
                button.pressTimer = 0
                button.currentColor = button.baseColor or BUTTON_STYLE_COLORS.normal
                button.focused = false
            end
        end
    end

    for _, key in ipairs(visibleKeys) do
        local button = uiElements.buttons[key]
        if button then
            buttons[#buttons + 1] = button
        end
    end

    if #buttons == 0 then
        -- Safety fallback: never render a buttonless faction screen.
        for _, key in ipairs(getVisibleButtonKeysForProfile(FACTION_UI_PROFILE.SINGLE_LOCAL)) do
            local button = uiElements.buttons[key]
            if type(button) ~= "table" then
                button = makeDefaultButtonDef(key)
                uiElements.buttons[key] = button
            end
            if button then
                button.visible = true
                button.__key = key
                applyButtonVisualState(button, key, false)
                buttons[#buttons + 1] = button
            end
        end
        if #buttons > 0 then
            logFactionDebug("[FactionUI] recovered missing button definitions via fallback")
        end
    end

    return buttons
end

local function refreshButtonLayout()
    logFactionUiProfileButtons()
    local buttons = getVisibleButtons()
    if #buttons == 0 then
        return
    end

    local buttonWidth = BUTTON_LAYOUT.width
    local buttonHeight = BUTTON_LAYOUT.height
    local gap = BUTTON_LAYOUT.gap
    local totalWidth = #buttons * buttonWidth + (#buttons - 1) * gap
    local startX = math.floor((SETTINGS.DISPLAY.WIDTH - totalWidth) / 2)
    local y = BUTTON_LAYOUT.y

    for i, button in ipairs(buttons) do
        button.x = startX + (i - 1) * (buttonWidth + gap)
        button.y = y
        button.width = buttonWidth
        button.height = buttonHeight
    end
end

local function getButtonNavCount()
    local count = 0
    for _, button in ipairs(getVisibleButtons()) do
        if button and button.__key and isButtonInteractableByKey(button.__key) then
            count = count + 1
        end
    end
    return count
end

local function getButtonByNavIndex(index)
    local currentIndex = 0
    for _, button in ipairs(getVisibleButtons()) do
        if button and button.__key and isButtonInteractableByKey(button.__key) then
            currentIndex = currentIndex + 1
            if currentIndex == index then
                return button
            end
        end
    end
    return nil
end

isButtonInteractableByKey = function(buttonKey)
    if buttonKey == "back" then
        return true
    end
    if not isOnlineMode() then
        if buttonKey == "random" then
            return true
        end
        if buttonKey == "start" then
            return canStartLocalMatch()
        end
        return false
    end
    if buttonKey == "random" then
        return canEditOnlineSetup()
    end
    if buttonKey == "ready" then
        return isOnlineMode() and canToggleOnlineReady()
    end
    if buttonKey == "start" then
        return canStartOnlineMatch()
    end
    return false
end

local function triggerFactionButtonAction(buttonKey)
    if buttonKey == "back" then
        ConfirmDialog.show(
            "Are you sure you want to return to the main menu?",
            function()
                if isOnlineMode() then
                    terminateOnlineFactionAndReturnToMainMenu("faction_back")
                elseif stateMachineRef and stateMachineRef.changeState then
                    stateMachineRef.changeState("mainMenu")
                end
            end,
            function()
            end
        )
        return
    end

    if buttonKey == "random" then
        if canEditOnlineSetup() then
            factionSelect.randomizeFactions()
        end
        return
    end

    if buttonKey == "ready" then
        if isOnlineMode() then
            toggleOnlineReady()
        end
        return
    end

    if buttonKey == "start" then
        if not isOnlineMode() then
            if canStartLocalMatch() then
                factionSelect.startGame()
            end
            return
        end
        if canStartOnlineMatch() then
            factionSelect.startGame()
        end
    end
end

-- Initialize card assets and shader
local function initializeAssets()
    -- Load card template
    local success, image = pcall(love.graphics.newImage, "assets/sprites/CardTemplateFront.png")
    if success then
        cardAssets.cardTemplate = image
        -- Cache dimensions to avoid linter warnings on getWidth/getHeight
        cardAssets.cardTemplateW = image:getWidth()
        cardAssets.cardTemplateH = image:getHeight()
    else
        return false
    end
    -- Load card background grass
    success, image = pcall(love.graphics.newImage, "assets/sprites/CardBackgroundGrass.png")
    if success then
        cardAssets.cardBackgroundGrass = image
    else
        return false
    end
    -- Load faction images
    success, image = pcall(love.graphics.newImage, "assets/sprites/Blu_Simple.png")
    if success then
        cardAssets.bluFactionImage = image
    else
        return false
    end
    success, image = pcall(love.graphics.newImage, "assets/sprites/Red_Simple.png")
    if success then
        cardAssets.redFactionImage = image
    else
        return false
    end
    -- Create the same background shader used during gameplay for visual consistency
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

            // Lava-lamp blobs drifting across the screen
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

            // Blend in lava lamp colors for a playful motion effect
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

            return vec4(finalColor, 1.0);
        }
    ]])

    if success then
        backgroundShader = shader

        -- Precompute static uniforms shared with gameplay shader
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
    else
        backgroundShader = nil
    end

end

-- Match the UI colors with the main menu
-- Keyboard navigation variables
navState = {
    selectedSection = 1,  -- 1 = blue faction, 2 = red faction, 3 = buttons
    selectedSectionItem = 1, -- For factions: 1 = left arrow, 2 = right arrow; For buttons: 1 = back, 2 = random, 3 = start
    sections = { "blueFaction", "redFaction", "buttons" }
}

local factionData = (function()
    local cats = Factions.getById(1) or {}
    local cows = Factions.getById(2) or {}
    return {
        {
            id = 1,
            name = cats.name or "Meow Alliance",
            description = cats.description or "Blue faction will make the first move",
            color = cats.color or UI_COLORS.blueTeam,
            accentColor = cats.accentColor or UI_COLORS.blueTeam,
            supplyTitle = cats.supplyPanelTitle or "CAT SUPPLY"
        },
        {
            id = 2,
            name = cows.name or "Moo Dominion",
            description = cows.description or "",
            color = cows.color or UI_COLORS.redTeam,
            accentColor = cows.accentColor or UI_COLORS.redTeam,
            supplyTitle = cows.supplyPanelTitle or "COW SUPPLY"
        }
    }
end)()

uiElements = {}

local function updateTitleForMode()
    if not uiElements or not uiElements.title then
        return
    end

    if GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER then
        uiElements.title.text = "SELECT FACTIONS"
    elseif GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL or GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET then
        uiElements.title.text = "SET PLAYER ORDER"
    elseif GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
        uiElements.title.text = "WATCH AI MATCHUP"
    else
        uiElements.title.text = "SELECT FACTIONS"
    end
end

local function cloneTable(src)
    if not src then
        return nil
    end
    local copy = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            copy[k] = cloneTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

local CONTROLLER_TEMPLATES = {
    player1 = {
        id = "preset_player_1",
        nickname = "Player 1",
        type = Controller.TYPES.HUMAN,
        isLocal = true,
        metadata = { slot = 1 }
    },
    player2 = {
        id = "preset_player_2",
        nickname = "Player 2",
        type = Controller.TYPES.HUMAN,
        isLocal = true,
        metadata = { slot = 2 }
    },
    ai1 = {
        id = "preset_ai_1",
        nickname = "Maggie (AI)",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 1 }
    },
    ai2 = {
        id = "preset_ai_2",
        nickname = "Burt (AI)",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 2 }
    },
    ai3 = {
        id = "preset_ai_3",
        nickname = "Marge (AI)",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 3 }
    },
    ai4 = {
        id = "preset_ai_4",
        nickname = "Homer (AI)",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 4 }
    },
    ai5 = {
        id = "preset_ai_5",
        nickname = "Lisa (AI)",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 5 }
    },
    ai6 = {
        id = "preset_ai_6",
        nickname = "Burns (AI)",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 6 }
    }
}

local function instantiateController(template)
    return Controller.new({
        id = template.id,
        nickname = template.nickname,
        type = template.type,
        isLocal = template.isLocal,
        metadata = cloneTable(template.metadata)
    })
end

local function applyMatchupPreset(preset)
    if not preset then
        return
    end

    if preset.mode then
        GAME.CURRENT.MODE = preset.mode
    end

    local controllers = {}
    for _, template in ipairs(preset.controllers) do
        local controller = instantiateController(template)
        controllers[controller.id] = controller
    end

    GAME.setControllers(controllers)

    if preset.controllerSequence then
        GAME.setControllerSequence(cloneTable(preset.controllerSequence))
    else
        GAME.setControllerSequence({ preset.assignments[1], preset.assignments[2] })
    end

    GAME.assignControllerToFaction(preset.assignments[1], 1)
    GAME.assignControllerToFaction(preset.assignments[2], 2)

    if preset.onApply then
        preset.onApply()
    end

    updateTitleForMode()
end

local function getMatchupOptionsForMode(mode)
    if mode == GAME.MODE.MULTYPLAYER_LOCAL or mode == GAME.MODE.MULTYPLAYER_NET then
        return {
            {
                id = "p1_vs_p2",
                label = "Player 1 vs Player 2",
                mode = mode,
                controllers = {
                    CONTROLLER_TEMPLATES.player1,
                    CONTROLLER_TEMPLATES.player2,
                },
                assignments = {
                    CONTROLLER_TEMPLATES.player1.id,
                    CONTROLLER_TEMPLATES.player2.id,
                },
                controllerSequence = {
                    CONTROLLER_TEMPLATES.player1.id,
                    CONTROLLER_TEMPLATES.player2.id,
                }
            },
            {
                id = "p2_vs_p1",
                label = "Player 2 vs Player 1",
                mode = mode,
                controllers = {
                    CONTROLLER_TEMPLATES.player2,
                    CONTROLLER_TEMPLATES.player1,
                },
                assignments = {
                    CONTROLLER_TEMPLATES.player2.id,
                    CONTROLLER_TEMPLATES.player1.id,
                },
                controllerSequence = {
                    CONTROLLER_TEMPLATES.player2.id,
                    CONTROLLER_TEMPLATES.player1.id,
                }
            }
        }
    end

    local singleMode = GAME.MODE.SINGLE_PLAYER
    return {
        {
            id = "player_vs_ai",
            label = "Player vs AI",
            mode = singleMode,
            controllers = {
                CONTROLLER_TEMPLATES.player1,
                CONTROLLER_TEMPLATES.ai2,
            },
            assignments = {
                CONTROLLER_TEMPLATES.player1.id,
                CONTROLLER_TEMPLATES.ai2.id,
            },
        },
        {
            id = "ai_vs_player",
            label = "AI vs Player",
            mode = singleMode,
            controllers = {
                CONTROLLER_TEMPLATES.ai1,
                CONTROLLER_TEMPLATES.player2,
            },
            assignments = {
                CONTROLLER_TEMPLATES.ai1.id,
                CONTROLLER_TEMPLATES.player2.id,
            },
        },
        {
            id = "ai_vs_ai",
            label = "AI vs AI",
            mode = GAME.MODE.AI_VS_AI,
            controllers = {
                CONTROLLER_TEMPLATES.ai1,
                CONTROLLER_TEMPLATES.ai2,
            },
            assignments = {
                CONTROLLER_TEMPLATES.ai1.id,
                CONTROLLER_TEMPLATES.ai2.id,
            },
        }
    }
end

-- Build controller options for a single faction selector
local function getOnlineSeatDisplayNames()
    local hostName = "Player"
    local guestName = "Player"

    local session = getOnlineSession()
    if not session then
        return hostName, guestName
    end

    if session.hostUserId and tostring(session.hostUserId) ~= "" then
        hostName = "Player " .. tostring(session.hostUserId):sub(-6)
    end
    if session.guestUserId and tostring(session.guestUserId) ~= "" then
        guestName = "Player " .. tostring(session.guestUserId):sub(-6)
    end

    if session.hostPersonaName and session.hostPersonaName ~= "" then
        hostName = session.hostPersonaName
    end
    if session.guestPersonaName and session.guestPersonaName ~= "" then
        guestName = session.guestPersonaName
    end

    if session.role == "host" then
        if session.localPersonaName and session.localPersonaName ~= "" then
            hostName = session.localPersonaName
        end
        if session.peerPersonaName and session.peerPersonaName ~= "" then
            guestName = session.peerPersonaName
        end
    elseif session.role == "guest" then
        if session.localPersonaName and session.localPersonaName ~= "" then
            guestName = session.localPersonaName
        end
        if session.peerPersonaName and session.peerPersonaName ~= "" then
            hostName = session.peerPersonaName
        end
    end

    return hostName, guestName
end

local function getSeatRoleFromOption(option)
    if type(option) ~= "table" then
        return nil
    end

    if option.seatRole == "host" or option.seatRole == "guest" then
        return option.seatRole
    end

    local optionId = option.id and tostring(option.id) or ""
    if optionId == "seat_host" then
        return "host"
    elseif optionId == "seat_guest" then
        return "guest"
    end

    local templateRole = option.template and option.template.metadata and option.template.metadata.role
    if templateRole == "host" or templateRole == "guest" then
        return templateRole
    end

    local session = getOnlineSession()
    if session then
        if optionId == "steam_local_human" then
            return session.role
        elseif optionId == "steam_remote_human" then
            if session.role == "host" then
                return "guest"
            elseif session.role == "guest" then
                return "host"
            end
        end
    end

    return nil
end

local function resolveOnlineControllerBySeatRole(seatRole)
    if seatRole ~= "host" and seatRole ~= "guest" then
        return nil
    end

    local controllers = GAME.CURRENT.CONTROLLERS or {}

    for _, controller in pairs(controllers) do
        local role = controller and controller.metadata and controller.metadata.role
        if role == seatRole then
            return controller
        end
    end

    local session = getOnlineSession()
    if session and session.role then
        local localSeat = session.role
        local wantLocal = (seatRole == localSeat)
        for _, controller in pairs(controllers) do
            if controller and ((controller.isLocal ~= false) == wantLocal) then
                return controller
            end
        end
    end

    return nil
end

local function buildControllerOptions()
    local options = {}
    local mode = GAME.CURRENT.MODE

    -- In Single Player mode: allow Player 1 and all AI aliases
    if mode == GAME.MODE.SINGLE_PLAYER then
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.player1.id,
            label = CONTROLLER_TEMPLATES.player1.nickname,
            template = CONTROLLER_TEMPLATES.player1
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai1.id,
            label = CONTROLLER_TEMPLATES.ai1.nickname,
            template = CONTROLLER_TEMPLATES.ai1
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai2.id,
            label = CONTROLLER_TEMPLATES.ai2.nickname,
            template = CONTROLLER_TEMPLATES.ai2
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai3.id,
            label = CONTROLLER_TEMPLATES.ai3.nickname,
            template = CONTROLLER_TEMPLATES.ai3
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai4.id,
            label = CONTROLLER_TEMPLATES.ai4.nickname,
            template = CONTROLLER_TEMPLATES.ai4
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai5.id,
            label = CONTROLLER_TEMPLATES.ai5.nickname,
            template = CONTROLLER_TEMPLATES.ai5
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai6.id,
            label = CONTROLLER_TEMPLATES.ai6.nickname,
            template = CONTROLLER_TEMPLATES.ai6
        })
    -- In AI vs AI mode: allow all AI aliases
    elseif mode == GAME.MODE.AI_VS_AI then
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai1.id,
            label = CONTROLLER_TEMPLATES.ai1.nickname,
            template = CONTROLLER_TEMPLATES.ai1
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai2.id,
            label = CONTROLLER_TEMPLATES.ai2.nickname,
            template = CONTROLLER_TEMPLATES.ai2
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai3.id,
            label = CONTROLLER_TEMPLATES.ai3.nickname,
            template = CONTROLLER_TEMPLATES.ai3
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai4.id,
            label = CONTROLLER_TEMPLATES.ai4.nickname,
            template = CONTROLLER_TEMPLATES.ai4
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai5.id,
            label = CONTROLLER_TEMPLATES.ai5.nickname,
            template = CONTROLLER_TEMPLATES.ai5
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.ai6.id,
            label = CONTROLLER_TEMPLATES.ai6.nickname,
            template = CONTROLLER_TEMPLATES.ai6
        })
    -- In local multiplayer mode: only Player 1 and Player 2
    elseif mode == GAME.MODE.MULTYPLAYER_LOCAL then
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.player1.id,
            label = CONTROLLER_TEMPLATES.player1.nickname,
            template = CONTROLLER_TEMPLATES.player1
        })
        table.insert(options, {
            id = CONTROLLER_TEMPLATES.player2.id,
            label = CONTROLLER_TEMPLATES.player2.nickname,
            template = CONTROLLER_TEMPLATES.player2
        })
    elseif mode == GAME.MODE.MULTYPLAYER_NET then
        local hostName, guestName = getOnlineSeatDisplayNames()

        table.insert(options, {
            id = "seat_host",
            seatRole = "host",
            label = tostring(hostName),
            template = {
                id = "seat_host",
                nickname = tostring(hostName),
                type = Controller.TYPES.HUMAN,
                isLocal = false,
                metadata = { role = "host", seat = "host" }
            }
        })

        table.insert(options, {
            id = "seat_guest",
            seatRole = "guest",
            label = tostring(guestName),
            template = {
                id = "seat_guest",
                nickname = tostring(guestName),
                type = Controller.TYPES.HUMAN,
                isLocal = false,
                metadata = { role = "guest", seat = "guest" }
            }
        })
    end

    return options
end

local function shuffleArray(array)
    for i = #array, 2, -1 do
        local j = randomGen.randomInt(1, i)
        array[i], array[j] = array[j], array[i]
    end
end

-- Ensure both selectors have unique controller assignments
local function ensureUniqueSelectorAssignments(changedIndex)
    if not uiElements or not uiElements.selectors then
        return
    end
    
    local selector1 = uiElements.selectors[1]
    local selector2 = uiElements.selectors[2]
    
    if not selector1 or not selector2 then
        return
    end
    
    -- If both selectors have the same option selected, change the other one
    if selector1.currentOption == selector2.currentOption then
        local otherIndex = (changedIndex == 1) and 2 or 1
        local otherSelector = uiElements.selectors[otherIndex]
        
        -- Find a different option for the other selector
        local optionCount = #otherSelector.options
        if optionCount > 1 then
            otherSelector.currentOption = (otherSelector.currentOption % optionCount) + 1
            -- If still the same, try once more
            if selector1.currentOption == selector2.currentOption then
                otherSelector.currentOption = (otherSelector.currentOption % optionCount) + 1
            end
        end
    end
end

-- Apply controller assignments from both selectors to the game state
local function applyControllerAssignmentsFromSelectors()
    if not uiElements or not uiElements.selectors then
        print("ERROR: uiElements or selectors not available")
        return false
    end

    local selector1 = uiElements.selectors[1]
    local selector2 = uiElements.selectors[2]

    if not selector1 or not selector2 then
        print("ERROR: Selectors not found")
        return false
    end

    local option1 = selector1.options and selector1.options[selector1.currentOption]
    local option2 = selector2.options and selector2.options[selector2.currentOption]

    if not option1 or not option2 then
        print("ERROR: Options not found", option1, option2)
        return false
    end

    logFactionDebug("Applying controllers from selectors...")
    logFactionDebug("Option 1:", option1.label, "Template:", option1.template and option1.template.type or "nil")
    logFactionDebug("Option 2:", option2.label, "Template:", option2.template and option2.template.type or "nil")

    if isOnlineMode() then
        local seatRole1 = getSeatRoleFromOption(option1)
        local seatRole2 = getSeatRoleFromOption(option2)

        if not seatRole1 or not seatRole2 then
            print("ERROR: Unable to resolve seat roles from online selector options", tostring(option1.id), tostring(option2.id))
            return false
        end

        local controller1 = resolveOnlineControllerBySeatRole(seatRole1)
        local controller2 = resolveOnlineControllerBySeatRole(seatRole2)

        if not controller1 or not controller2 then
            print("ERROR: Unable to resolve online controllers for seats", tostring(seatRole1), tostring(seatRole2))
            return false
        end

        if controller1.id == controller2.id then
            print("ERROR: Invalid online faction assignment: both seats resolved to", tostring(controller1.id))
            return false
        end

        local controllers = {}
        controllers[controller1.id] = controller1
        controllers[controller2.id] = controller2

        GAME.CURRENT.MODE = GAME.MODE.MULTYPLAYER_NET
        GAME.setControllers(controllers)
        GAME.setControllerSequence({ controller1.id, controller2.id })
        GAME.assignControllerToFaction(controller1.id, 1)
        GAME.assignControllerToFaction(controller2.id, 2)

        logFactionDebug("Online seat assignment -> F1:", seatRole1, controller1.id, "| F2:", seatRole2, controller2.id)
        logFactionDebug("Final mode:", GAME.CURRENT.MODE)
        logFactionDebug("Final AI player:", GAME.CURRENT.AI_PLAYER_NUMBER)

        updateTitleForMode()
        return true
    end

    -- Create controller instances (offline modes)
    local controllers = {}
    local controller1 = instantiateController(option1.template)
    local controller2 = instantiateController(option2.template)

    logFactionDebug("Controller 1 type:", controller1.type, "ID:", controller1.id)
    logFactionDebug("Controller 2 type:", controller2.type, "ID:", controller2.id)

    controllers[controller1.id] = controller1
    controllers[controller2.id] = controller2

    -- Determine game mode based on controller types BEFORE setting controllers
    -- (because GAME.setControllers calls refreshDerivedAssignmentState which overwrites AI_PLAYER_NUMBER)
    local hasAI = (controller1.type == Controller.TYPES.AI or controller2.type == Controller.TYPES.AI)
    local allAI = (controller1.type == Controller.TYPES.AI and controller2.type == Controller.TYPES.AI)

    logFactionDebug("hasAI:", hasAI, "allAI:", allAI)
    logFactionDebug("Controller.TYPES.AI:", Controller.TYPES.AI)

    -- Set the mode first
    if allAI then
        logFactionDebug("Setting mode to AI_VS_AI")
        GAME.CURRENT.MODE = GAME.MODE.AI_VS_AI
    elseif hasAI then
        logFactionDebug("Setting mode to SINGLE_PLAYER")
        GAME.CURRENT.MODE = GAME.MODE.SINGLE_PLAYER
    else
        logFactionDebug("Setting mode to MULTIPLAYER")
        -- Keep existing multiplayer mode if already set
        if GAME.CURRENT.MODE ~= GAME.MODE.MULTYPLAYER_LOCAL and GAME.CURRENT.MODE ~= GAME.MODE.MULTYPLAYER_NET then
            GAME.CURRENT.MODE = GAME.MODE.MULTYPLAYER_LOCAL
        end
    end

    -- Now set controllers (this will call refreshDerivedAssignmentState which sets AI_PLAYER_NUMBER automatically)
    GAME.setControllers(controllers)
    GAME.setControllerSequence({ controller1.id, controller2.id })
    GAME.assignControllerToFaction(controller1.id, 1)
    GAME.assignControllerToFaction(controller2.id, 2)

    logFactionDebug("Final mode:", GAME.CURRENT.MODE)
    logFactionDebug("Final AI player:", GAME.CURRENT.AI_PLAYER_NUMBER)

    updateTitleForMode()
    return true
end

buildOnlineSetupPayload = function()
    if not uiElements or not uiElements.selectors then
        return nil
    end

    local selector1 = uiElements.selectors[1]
    local selector2 = uiElements.selectors[2]
    if not selector1 or not selector2 then
        return nil
    end

    local option1 = selector1.options and selector1.options[selector1.currentOption]
    local option2 = selector2.options and selector2.options[selector2.currentOption]
    if not option1 or not option2 then
        return nil
    end

    local seatRole1 = getSeatRoleFromOption(option1)
    local seatRole2 = getSeatRoleFromOption(option2)

    return {
        seatAssignment = {
            one = seatRole1,
            two = seatRole2
        },
        selectorOptions = {
            one = option1.id,
            two = option2.id
        },
        selectorIndex = {
            one = selector1.currentOption,
            two = selector2.currentOption
        },
        setupRevision = tonumber(onlineSetupRevision) or 0,
        gameMode = GAME.CURRENT.MODE
    }
end

local function applyOnlineSetupPayload(payload)
    if not payload or not uiElements or not uiElements.selectors then
        return false
    end

    local payloadRevision = tonumber(payload.setupRevision)
    local session = getOnlineSession()
    if session and session.role == "guest" and payloadRevision and payloadRevision > 0 then
        if payloadRevision <= (tonumber(lastAppliedSetupRevision) or 0) then
            return false
        end
    end

    local selector1 = uiElements.selectors[1]
    local selector2 = uiElements.selectors[2]
    if not selector1 or not selector2 then
        return false
    end

    local function setSelectorByOptionId(selector, optionId, fallbackIndex)
        if type(optionId) ~= "string" then
            selector.currentOption = fallbackIndex or selector.currentOption
            return false
        end
        for idx, option in ipairs(selector.options or {}) do
            if option.id == optionId then
                selector.currentOption = idx
                return true
            end
        end
        selector.currentOption = fallbackIndex or selector.currentOption
        return false
    end

    local function setSelectorBySeatRole(selector, seatRole, fallbackIndex)
        if seatRole ~= "host" and seatRole ~= "guest" then
            selector.currentOption = fallbackIndex or selector.currentOption
            return false
        end

        for idx, option in ipairs(selector.options or {}) do
            local optionSeatRole = getSeatRoleFromOption(option)
            if optionSeatRole == seatRole then
                selector.currentOption = idx
                return true
            end
        end

        selector.currentOption = fallbackIndex or selector.currentOption
        return false
    end

    local appliedBySeat = false
    if payload.seatAssignment then
        local oneOk = setSelectorBySeatRole(selector1, payload.seatAssignment.one, payload.selectorIndex and payload.selectorIndex.one)
        local twoOk = setSelectorBySeatRole(selector2, payload.seatAssignment.two, payload.selectorIndex and payload.selectorIndex.two)
        appliedBySeat = oneOk and twoOk
    end

    if not appliedBySeat then
        setSelectorByOptionId(selector1, payload.selectorOptions and payload.selectorOptions.one, payload.selectorIndex and payload.selectorIndex.one)
        setSelectorByOptionId(selector2, payload.selectorOptions and payload.selectorOptions.two, payload.selectorIndex and payload.selectorIndex.two)
    end

    ensureUniqueSelectorAssignments(1)
    local applied = applyControllerAssignmentsFromSelectors() == true
    if not applied then
        return false
    end

    if session and session.role == "guest" and payloadRevision and payloadRevision > 0 then
        local previousRevision = tonumber(onlineSetupRevision) or 0
        onlineSetupRevision = payloadRevision
        lastAppliedSetupRevision = payloadRevision
        if previousRevision ~= payloadRevision then
            onlineReadyState.hostReady = false
            onlineReadyState.guestReady = false
            clearPendingGuestReady("setup_snapshot")
            resetPrematchTransportState("setup_snapshot")
        end
    end

    return true
end

local function broadcastOnlineSetupSnapshot(forceSend)
    if not isOnlineMode() then
        return
    end
    local session = getOnlineSession()
    if not session or not session:canControlSetup() then
        return
    end

    queuePendingSetupSnapshot()
    flushPendingHostBroadcasts(forceSend == true)
end

-- Refresh both selector options
local function refreshSelectorOptionsFromGame()
    if not uiElements or not uiElements.selectors then
        return
    end

    local options = buildControllerOptions()
    
    -- Update both selectors with the same options
    for i = 1, 2 do
        local selector = uiElements.selectors[i]
        if selector then
            selector.options = options
            if not selector.currentOption or selector.currentOption < 1 then
                selector.currentOption = i -- Default: selector 1 gets option 1, selector 2 gets option 2
            elseif selector.currentOption > #options then
                selector.currentOption = #options
            end
        end
    end
    
    -- Ensure no duplicate selections
    ensureUniqueSelectorAssignments(1)
end

-- Change selector option and ensure uniqueness
local function changeSelectorOption(selectorIndex, delta)
    if not canEditOnlineSetup() then
        return false
    end

    if not uiElements or not uiElements.selectors then
        return false
    end
    local selector = uiElements.selectors[selectorIndex]
    if not selector or not selector.options then
        return false
    end
    local optionCount = #selector.options
    if optionCount <= 1 then
        return false
    end

    selector.currentOption = ((selector.currentOption or 1) - 1 + delta) % optionCount + 1
    selector.highlightTimer = 0.3
    
    -- Ensure the other selector doesn't have the same selection
    ensureUniqueSelectorAssignments(selectorIndex)
    
    -- Apply the controller assignments
    applyControllerAssignmentsFromSelectors()
    markOnlineSetupChanged()
    hostResetOnlineReadyState()
    broadcastOnlineSetupSnapshot()
    
    return true
end

-- Helper function to check if the mouse is over a button
local function isMouseOverButton(button, x, y)
    if not button or button.visible == false then return false end
    return (x >= button.x and x <= button.x + button.width) and
           (y >= button.y and y <= button.y + button.height)
end

local function normalizeColor4(color, fallback)
    local source = color or fallback or {1, 1, 1, 1}
    local r = source[1] or 1
    local g = source[2] or 1
    local b = source[3] or 1
    local a = source[4]
    if a == nil then
        a = 1
    end
    if r > 1 or g > 1 or b > 1 or a > 1 then
        r = r / 255
        g = g / 255
        b = b / 255
        a = a / 255
    end
    return r, g, b, a
end

-- Draw a tech-styled panel (same as main menu)
local function drawTechPanel(x, y, width, height)
    uiTheme.drawTechPanel(x, y, width, height)
end

local BUTTON_BEEP_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"
local ARROW_CLICK_SOUND_PATH = "assets/audio/SnappyButton2.wav"

local function initAudio()
    soundCache.get(BUTTON_BEEP_SOUND_PATH)
    soundCache.get(BUTTON_CLICK_SOUND_PATH)
    soundCache.get(ARROW_CLICK_SOUND_PATH)
end

local function playButtonBeep()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_BEEP_SOUND_PATH, { clone = false, volume = SETTINGS.AUDIO.SFX_VOLUME, category = "sfx" })
end

local function playButtonClick()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(BUTTON_CLICK_SOUND_PATH, { clone = false, volume = SETTINGS.AUDIO.SFX_VOLUME, category = "sfx" })
end

local function playArrowClick()
    if not SETTINGS.AUDIO.SFX then
        return
    end
    initAudio()
    soundCache.play(ARROW_CLICK_SOUND_PATH, { clone = false, volume = SETTINGS.AUDIO.SFX_VOLUME, category = "sfx" })
end

-- Draw a tech-styled button (same as main menu)
local function drawButton(button)
    if not button or button.visible == false then
        return
    end

    local r, g, b, a = normalizeColor4(button.currentColor, UI_COLORS.button)
    love.graphics.setColor(r, g, b, a)
    love.graphics.rectangle("fill", button.x, button.y, button.width, button.height, 8)

    local hovered = (button.currentColor == button.hoverColor) and (button.disabledVisual ~= true)
    local focused = button.focused == true and button.disabledVisual ~= true
    if hovered or focused then
        love.graphics.setColor(1, 0.94, 0.86, 0.9)
        love.graphics.setLineWidth(2.5)
    else
        local br, bg, bb, ba = normalizeColor4(button.borderColor, {0.45, 0.38, 0.31, 1})
        love.graphics.setColor(br, bg, bb, ba)
        love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", button.x, button.y, button.width, button.height, 8)
    love.graphics.setLineWidth(1)

    if button.disabledVisual == true then
        love.graphics.setColor(1, 1, 1, 0.06)
    else
        love.graphics.setColor(1, 1, 1, 0.18)
    end
    love.graphics.rectangle("line", button.x + 3, button.y + 3, button.width - 6, button.height - 6, 6)

    local tr, tg, tb, ta = normalizeColor4(button.textColor, {0.95, 0.88, 0.76, 1})
    love.graphics.setColor(tr, tg, tb, ta)
    love.graphics.printf(button.text or "", button.x, button.y + (button.textOffsetY or 15), button.width, "center")

end

local function drawTitle(text, x, y, width)
    uiTheme.drawTitle(text, x, y, width)
end

-- Draw faction card using card assets (similar to gameplay UI)
local function drawFactionCard(faction)
    if not cardAssets.cardTemplate then
        -- Fallback to old rectangular design if assets not loaded
        drawTechPanel(faction.x, faction.y, faction.width, faction.height)
        love.graphics.setColor(faction.color)
        love.graphics.printf(faction.name, faction.x, faction.y + 20, faction.width, "center")
        return
    end

    -- Responsive scaling using screen percentages (15% width, 40% height)
    local screenWidth = love.graphics.getWidth()
    local screenHeight = love.graphics.getHeight()
    local responsiveWidth = screenWidth * 0.15
    local responsiveHeight = screenHeight * 0.4

    local cardWidth = cardAssets.cardTemplateW or 1
    local cardHeight = cardAssets.cardTemplateH or 1
    local responsiveScale = math.min(responsiveWidth / cardWidth, responsiveHeight / cardHeight)
    local panelScale = math.min(faction.width / cardWidth, faction.height / cardHeight)
    local cardScale = math.min(responsiveScale, panelScale)

    -- Use faction panel coordinates (same as selectors and other UI elements)
    local cardX = faction.x + (faction.width - cardWidth * cardScale) / 2
    local cardY = faction.y + (faction.height - cardHeight * cardScale) / 2

    -- Compose the full card (background + template + faction image) into a Canvas
    local composedW = math.ceil(cardWidth * cardScale)
    local composedH = math.ceil(cardHeight * cardScale)

    local previousCanvas = love.graphics.getCanvas()
    local previousShader = love.graphics.getShader()
    love.graphics.push()
    love.graphics.origin()

    local cardCanvas = love.graphics.newCanvas(composedW, composedH)
    love.graphics.setCanvas(cardCanvas)
    love.graphics.clear(0, 0, 0, 0)

    -- Calculate scale to fit background/template exactly into the canvas
    -- Background art is authored at the same dimensions as the template, so cardScale works for both.
    local bgScale = cardScale
    local templateScale = cardScale

    -- Draw grass background into canvas
    if cardAssets.cardBackgroundGrass then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(cardAssets.cardBackgroundGrass, 0, 0, 0, bgScale, bgScale)
    end

    -- Draw card template into canvas
    love.graphics.setColor(faction.color[1], faction.color[2], faction.color[3], 0.8)
    love.graphics.draw(cardAssets.cardTemplate, 0, 0, 0, templateScale, templateScale)

    -- Draw faction-specific image into canvas
    local factionImage = nil
    if faction.factionIndex == 1 and cardAssets.bluFactionImage then
        factionImage = cardAssets.bluFactionImage
    elseif faction.factionIndex == 2 and cardAssets.redFactionImage then
        factionImage = cardAssets.redFactionImage
    end

    if factionImage then
        local imageScale = 0.22
        local imageWidth = factionImage:getWidth() * imageScale
        local imageHeight = factionImage:getHeight() * imageScale
        local imageX = (cardWidth * cardScale - imageWidth) / 2
        local imageY = (cardHeight * cardScale - imageHeight) / 2

        -- Per-faction offsets (fixed values tuned for original art)
        local blueOffsetX, blueOffsetY = 11, -4
        local redOffsetX, redOffsetY = 6, -4
        if faction.factionIndex == 1 then
            imageX = imageX + blueOffsetX
            imageY = imageY + blueOffsetY
        else
            imageX = imageX + redOffsetX
            imageY = imageY + redOffsetY
        end

        -- Draw shadow BEFORE the faction image (between template and unit)
        local shadowConfig = {
            widthScale = 0.36,
            heightScale = 0.28,
            offsetY = -14,
            intensity = 0.1
        }
        
        local shadowWidth = imageWidth * shadowConfig.widthScale
        local shadowHeight = shadowWidth * shadowConfig.heightScale
        local shadowX = imageX + imageWidth * 0.5
        local shadowY = imageY + imageHeight - shadowHeight + shadowConfig.offsetY
        
        -- Draw soft elliptical shadow with gradient
        love.graphics.push()
        love.graphics.translate(shadowX, shadowY)
        
        local segments = 24
        local layers = 8
        for i = layers, 1, -1 do
            local scale = i / layers
            local alpha = shadowConfig.intensity * (scale ^ 2.5) * (1 - scale * 0.3)
            love.graphics.setColor(0, 0, 0, alpha)
            love.graphics.ellipse("fill", 0, 0, shadowWidth * scale, shadowHeight * scale, segments)
        end
        
        love.graphics.pop()

        love.graphics.setColor(1, 1, 1, 1)
        -- Flip horizontally
        love.graphics.draw(factionImage, imageX + imageWidth, imageY, 0, -imageScale, imageScale)
    end

    -- Add animated light overlay (sheen) drawn into the canvas so it warps with the card
    do
        local t = love.timer.getTime()
        local phaseSheen = (faction.factionIndex == 1) and 0 or math.pi
        local bandWidth = 56

        -- Derive current tilt and perspective to align sheen with movement direction
        local ampTmp = 6
        local omega = 1.0
        local tiltNow = math.sin(t * omega + phaseSheen) * ampTmp
        local tiltVel = math.cos(t * omega + phaseSheen) * (omega * ampTmp)
        local persp = 0.06
        local topInset = composedW * persp
        local effectiveWidth = math.max(1, composedW - 2 * topInset)
        local targetAngle = math.atan(2 * tiltNow, effectiveWidth)

        -- Spring-damper smoothing so changes are not too quick
        local s = ANIM_STATE[faction.factionIndex]
        local dt = love.timer.getDelta()
        -- Smooth tilt and velocity (simple low-pass to reduce noise)
        local tiltAlpha  = 0.10
        local velAlpha   = 0.05
        s.tilt = s.tilt + (tiltNow - s.tilt) * tiltAlpha
        s.vel  = s.vel  + (tiltVel - s.vel) * velAlpha
        -- Angle smoothing via critically-damped spring
        do
            local k = 6.0    -- stiffness (lower = less snappy)
            local d = 8.5    -- damping  (higher = more resistance)
            local a = k * (targetAngle - s.angle) - d * s.angleV
            s.angleV = s.angleV + a * dt
            s.angle  = s.angle  + s.angleV * dt
        end
        
        -- Compute the exact mesh-based top-edge angle for perfect alignment
        local ampMesh = 6
        local phaseMesh = (faction.factionIndex == 1) and 0 or math.pi
        local tiltMesh = math.sin(love.timer.getTime() * 2.0 + phaseMesh) * ampMesh
        local topInsetMesh = composedW * 0.06 -- same persp used for mesh warp
        local effWidthMesh = math.max(1, composedW - 2 * topInsetMesh)
        local meshEdgeAngle = math.atan(2 * tiltMesh, effWidthMesh)

        -- Use additive blend for light
        local prevBlendMode, prevAlphaMode = love.graphics.getBlendMode()
        love.graphics.setBlendMode("add", "alphamultiply")

        -- Draw a soft diagonal sheen across the card: base diagonal + tilt contribution
        love.graphics.push()
        love.graphics.translate(composedW / 2, composedH / 2)
        local baseAngle = math.rad(35) -- anchor to diagonal
        -- Subtle deviation: clamp mesh influence and smooth with a rate limit
        do
            local s = ANIM_STATE[faction.factionIndex]
            -- Max deviation from base (in radians)
            local maxOffset = math.rad(8)
            -- Small influence factor from meshEdgeAngle
            local bias = math.max(-maxOffset, math.min(maxOffset, meshEdgeAngle)) * 0.3
            local targetSheen = baseAngle + bias

            -- Initialize smoothed sheen angle
            s.sheenAngle = s.sheenAngle or baseAngle

            -- Rate limit rotation speed (deg/sec -> rad/sec)
            local maxSpeed = math.rad(90) -- at most 90° per second
            local step = maxSpeed * dt
            local delta = targetSheen - s.sheenAngle
            if delta > step then delta = step end
            if delta < -step then delta = -step end
            s.sheenAngle = s.sheenAngle + delta

            love.graphics.rotate(s.sheenAngle)
        end
        -- Continuous sweep: move across the card, wrap around, faster with stronger tilt
        local normTiltMesh = tiltMesh / math.max(1, ampMesh)
        local dir = (normTiltMesh >= 0) and 1 or -1
        -- Pixels per second (base + bonus from tilt magnitude)
        local pxPerSec = (effWidthMesh * 0.35) + (effWidthMesh * 0.55) * math.abs(normTiltMesh)
        s.sweep = s.sweep + dir * pxPerSec * dt
        -- Wrap around so the sheen exits on one side and re-enters on the other
        local wrapSpan = effWidthMesh * 1.2
        if s.sweep >  wrapSpan then s.sweep = s.sweep - 2 * wrapSpan end
        if s.sweep < -wrapSpan then s.sweep = s.sweep + 2 * wrapSpan end
        local xOffset = s.sweep
        -- Two-band split highlight (simple): one wider, one slimmer
        local gap = 10
        local w1 = bandWidth                  -- primary wide band (slightly wider)
        local w2 = math.floor(bandWidth * 0.52) -- secondary band a bit wider for punch
        local x1 = xOffset - gap * 0.5
        local x2 = xOffset + gap * 0.5

        -- Primary band
        love.graphics.setColor(1, 1, 1, 0.065)
        love.graphics.rectangle("fill", x1 - w1/2 - composedW, -composedH, w1, composedH * 2)
        love.graphics.rectangle("fill", x1 - w1/2,             -composedH, w1, composedH * 2)
        love.graphics.rectangle("fill", x1 - w1/2 + composedW, -composedH, w1, composedH * 2)

        -- Secondary band
        love.graphics.setColor(1, 1, 1, 0.045)
        love.graphics.rectangle("fill", x2 - w2/2 - composedW, -composedH, w2, composedH * 2)
        love.graphics.rectangle("fill", x2 - w2/2,             -composedH, w2, composedH * 2)
        love.graphics.rectangle("fill", x2 - w2/2 + composedW, -composedH, w2, composedH * 2)
        love.graphics.pop()

        -- No extra top gloss bar for a simpler, cleaner look

        love.graphics.setBlendMode(prevBlendMode, prevAlphaMode)
    end

    love.graphics.setCanvas(previousCanvas)
    love.graphics.setShader(previousShader)
    love.graphics.pop()

    -- Create a 3D-like mesh warp for the composed card
    local t = love.timer.getTime()
    local amp = 6 -- pixels of tilt
    local phase = (faction.factionIndex == 1) and 0 or math.pi -- give the two cards opposite phase
    local tilt = math.sin(t * 2.0 + phase) * amp
    local persp = 0.06 -- horizontal perspective factor

    local w, h = composedW, composedH
    local topInset = w * persp
    local bottomInset = -w * (persp * 0.2)

    local vertices = {
        {0 + topInset,     0 + (-tilt),  0, 0, 1, 1, 1, 1}, -- top-left
        {w - topInset,     0 + ( tilt),  1, 0, 1, 1, 1, 1}, -- top-right
        {w - bottomInset,  h + ( tilt),  1, 1, 1, 1, 1, 1}, -- bottom-right
        {0 + bottomInset,  h + (-tilt),  0, 1, 1, 1, 1, 1}, -- bottom-left
    }

    local mesh = love.graphics.newMesh(vertices, "fan")
    mesh:setTexture(cardCanvas)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.push()
    love.graphics.translate(cardX, cardY)
    love.graphics.draw(mesh)
    love.graphics.pop()

    -- Draw faction name below the card
    love.graphics.setColor(faction.color)
    love.graphics.printf(faction.name, faction.x, faction.y + faction.height + 10, faction.width, "center")

    -- Draw faction description
    if faction.description and faction.description ~= "" then
        if faction.factionIndex == 1 then
            -- For BLUE faction, place description over the card with a subtle backdrop
            local pad = 8
            local overlayHeight = 26
            local overlayY = 112
            local overlayX = cardX + pad
            local overlayW = cardWidth * cardScale - pad * 2

            -- Description text centered inside the overlay
            love.graphics.setColor(UI_COLORS.background)
            love.graphics.printf(faction.description, overlayX + 6, overlayY + 4, overlayW - 12, "center")
        end
    end
end

local function formatOnlineReadyName(name, userId, fallbackLabel)
    if name and name ~= "" then
        return name
    end
    if userId then
        return "Player " .. tostring(userId):sub(-6)
    end
    return fallbackLabel
end

-- Function to update UI elements based on keyboard navigation
local function updateKeyboardNavigation()
    local visibleButtons = getVisibleButtons()
    local visibleLookup = {}
    for _, button in ipairs(visibleButtons) do
        visibleLookup[button.__key] = true
        applyButtonVisualState(button, button.__key, false)
        button.currentColor = button.baseColor or BUTTON_STYLE_COLORS.normal
    end

    if uiElements.buttons then
        for _, key in ipairs(BUTTON_VISIBILITY_ORDER) do
            local button = uiElements.buttons[key]
            if button and not visibleLookup[key] then
                button.currentColor = button.baseColor or BUTTON_STYLE_COLORS.normal
                button.focused = false
            end
        end
    end

    if uiElements.arrowStates then
        uiElements.arrowStates[1].leftHover = false
        uiElements.arrowStates[1].rightHover = false
        uiElements.arrowStates[2].leftHover = false
        uiElements.arrowStates[2].rightHover = false
    end

    if not canEditOnlineSetup() and (navState.selectedSection == 1 or navState.selectedSection == 2) then
        navState.selectedSection = 3
        navState.selectedSectionItem = math.max(1, math.min(navState.selectedSectionItem or 1, getButtonNavCount()))
    end

    if canEditOnlineSetup() and navState.selectedSection == 1 then
        if navState.selectedSectionItem == 1 then
            uiElements.arrowStates[1].leftHover = true
        else
            uiElements.arrowStates[1].rightHover = true
        end
    elseif canEditOnlineSetup() and navState.selectedSection == 2 then
        if navState.selectedSectionItem == 1 then
            uiElements.arrowStates[2].leftHover = true
        else
            uiElements.arrowStates[2].rightHover = true
        end
    elseif navState.selectedSection == 3 then
        local targetButton = getButtonByNavIndex(navState.selectedSectionItem)
        if targetButton and targetButton.visible ~= false and isButtonInteractableByKey(targetButton.__key) then
            targetButton.currentColor = targetButton.hoverColor
        elseif targetButton and targetButton.visible ~= false then
            targetButton.currentColor = targetButton.baseColor or BUTTON_STYLE_COLORS.disabled
        end
    end
end

-- Random faction selection
function factionSelect.randomizeFactions()
    if not canEditOnlineSetup() then
        return
    end

    if not uiElements or not uiElements.selectors then
        return
    end

    local selector1 = uiElements.selectors[1]
    local selector2 = uiElements.selectors[2]
    local options = selector1 and selector1.options or {}
    
    if not selector1 or not selector2 or #options == 0 then
        return
    end

    -- Randomize both selectors
    selector1.currentOption = randomGen.randomInt(1, #options)
    selector1.highlightTimer = 0.3
    
    selector2.currentOption = randomGen.randomInt(1, #options)
    selector2.highlightTimer = 0.3
    
    -- Ensure they're different
    ensureUniqueSelectorAssignments(1)
    
    applyControllerAssignmentsFromSelectors()
    markOnlineSetupChanged()
    hostResetOnlineReadyState()
    broadcastOnlineSetupSnapshot()
    updateKeyboardNavigation()
end

-- Initialize the faction selection UI
function factionSelect.enter(stateMachine, prevState, params)
    -- Safety check
    if not stateMachine then
        return true
    end

    stateMachineRef = stateMachine
    GAME_STATE.initialized = true
    disconnectDialogShown = false

    if GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_LOCAL then
        if not GAME.CURRENT.LOCAL_MATCH_VARIANT or GAME.CURRENT.LOCAL_MATCH_VARIANT == "" then
            GAME.CURRENT.LOCAL_MATCH_VARIANT = "couch"
        end
    else
        GAME.CURRENT.LOCAL_MATCH_VARIANT = "couch"
    end
    
    -- Reset animation smoothing state
    ANIM_STATE[1] = {tilt=0, vel=0, angle=0, angleV=0, sweep=0, sweepV=0}
    ANIM_STATE[2] = {tilt=0, vel=0, angle=0, angleV=0, sweep=0, sweepV=0}
    
    -- Initialize card assets and shader
    initializeAssets()

    -- Create UI elements
    uiElements = {
        title = {
            text = (GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER and "SELECT PLAYERS FACTION") or "SELECT FACTION",
        },
        factions = {
            -- Faction 1 panel (Blue)
            {
                x = SETTINGS.DISPLAY.WIDTH / 2 - 250,
                y = 150,
                width = 200,
                height = 300,
                name = factionData[1].name,
                description = factionData[1].description,
                color = factionData[1].color,
                accentColor = factionData[1].accentColor,
                factionIndex = 1,
            },
            -- Faction 2 panel (Red)
            {
                x = SETTINGS.DISPLAY.WIDTH / 2 + 50,
                y = 150,
                width = 200,
                height = 300,
                name = factionData[2].name,
                description = factionData[2].description,
                color = factionData[2].color,
                accentColor = factionData[2].accentColor,
                factionIndex = 2,
            }
        },
        -- Player selector buttons (one for each faction)
        selectors = {
            -- Blue faction selector
            {
                x = SETTINGS.DISPLAY.WIDTH / 2 - 250,
                y = 460,
                width = 200,
                height = 40,
                options = {},
                currentOption = 1,
                highlightTimer = 0
            },
            -- Red faction selector
            {
                x = SETTINGS.DISPLAY.WIDTH / 2 + 50,
                y = 460,
                width = 200,
                height = 40,
                options = {},
                currentOption = 1,
                highlightTimer = 0
            }
        },
        buttons = {
            -- Back button (left)
            back = {
                x = SETTINGS.DISPLAY.WIDTH / 2 - 315,
                y = 550,
                width = 120,
                height = 50,
                text = "Back",
                currentColor = UI_COLORS.button,
                hoverColor = UI_COLORS.buttonHover,
                pressedColor = UI_COLORS.buttonPressed,
                pressed = false,
                pressTimer = 0
            },
            -- Random button
            random = {
                x = SETTINGS.DISPLAY.WIDTH / 2 - 145,
                y = 550,
                width = 120,
                height = 50,
                text = "Random",
                currentColor = UI_COLORS.button,
                hoverColor = UI_COLORS.buttonHover,
                pressedColor = UI_COLORS.buttonPressed,
                pressed = false,
                pressTimer = 0
            },
            -- Ready button (online mode)
            ready = {
                x = SETTINGS.DISPLAY.WIDTH / 2 + 25,
                y = 550,
                width = 120,
                height = 50,
                text = "Ready",
                currentColor = UI_COLORS.button,
                hoverColor = UI_COLORS.buttonHover,
                pressedColor = UI_COLORS.buttonPressed,
                pressed = false,
                pressTimer = 0
            },
            -- Start button
            start = {
                x = SETTINGS.DISPLAY.WIDTH / 2 + 195,
                y = 550,
                width = 120,
                height = 50,
                text = "Start Game",
                currentColor = UI_COLORS.button,
                hoverColor = UI_COLORS.buttonHover,
                pressedColor = UI_COLORS.buttonPressed,
                pressed = false,
                pressTimer = 0
            }
        },
        arrowStates = {
            -- Blue faction arrows
            {
                left = false,
                leftHover = false,
                leftTimer = 0,
                right = false,
                rightHover = false,
                rightTimer = 0
            },
            -- Red faction arrows
            {
                left = false,
                leftHover = false,
                leftTimer = 0,
                right = false,
                rightHover = false,
                rightTimer = 0
            }
        }
    }

    if isOnlineMode() then
        syncResolvedOnlineRole(getOnlineSession())
    end

    refreshSelectorOptionsFromGame()
    applyControllerAssignmentsFromSelectors()

    if isOnlineMode() then
        local session = getOnlineSession()
        syncResolvedOnlineRole(session)
        onlineReadyState.hostReady = false
        onlineReadyState.guestReady = false
        onlineReadyState.revision = 0
        onlineSetupRevision = 0
        lastAppliedSetupRevision = 0
        pendingSetupSnapshot = false
        pendingReadyState = false
        lastSetupSnapshotFlushAt = 0
        lastReadyStateFlushAt = 0
        resetPrematchTransportState("enter")
        clearPendingGuestReady("enter")
        lastReadyTelemetryKey = nil

        localOnlineRatingProfile = nil
        peerOnlineRatingProfile = nil
        ensureLocalOnlineRatingProfileLoaded()

        if session and session.matchSetup then
            applyOnlineSetupPayload(session.matchSetup)
        end

        if session and session.role == "host" then
            markOnlineSetupChanged()
            hostResetOnlineReadyState()
            broadcastOnlineSetupSnapshot()
        end
    end

    ensureButtonDefinitions()
    refreshButtonLayout()

    -- Initialize keyboard navigation
    navState.selectedSection = 3  -- Default to buttons
    local buttonCount = getButtonNavCount()
    if buttonCount <= 0 then
        navState.selectedSectionItem = 0
    else
        navState.selectedSectionItem = math.min(2, buttonCount)
    end
    updateKeyboardNavigation()

end

function factionSelect.mousepressed(x, y, button, istouch, presses)
    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousepressed(x, y, button)
    end

    -- Safety check
    if not GAME_STATE.initialized or not uiElements then return end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    if button == 1 then
        -- Handle both selectors (host/local only in online mode)
        if canEditOnlineSetup() then
            for i = 1, 2 do
                local selector = uiElements.selectors[i]
                local arrowState = uiElements.arrowStates[i]
                if selector and arrowState then
                    local arrowSize = 10
                    local arrowY = selector.y + selector.height / 2

                    local leftArrowX = selector.x + 20
                    local leftArrowArea = {
                        x = leftArrowX - arrowSize,
                        y = arrowY - arrowSize,
                        width = arrowSize * 2,
                        height = arrowSize * 2
                    }

                    local rightArrowX = selector.x + selector.width - 20
                    local rightArrowArea = {
                        x = rightArrowX - arrowSize,
                        y = arrowY - arrowSize,
                        width = arrowSize * 2,
                        height = arrowSize * 2
                    }

                    if isMouseOverButton(leftArrowArea, tx, ty) then
                        initAudio()
                        playArrowClick()

                        arrowState.left = true
                        arrowState.leftTimer = 0.25
                        changeSelectorOption(i, -1)
                        navState.selectedSection = i
                        navState.selectedSectionItem = 1
                        updateKeyboardNavigation()
                    elseif isMouseOverButton(rightArrowArea, tx, ty) then
                        initAudio()
                        playArrowClick()

                        arrowState.right = true
                        arrowState.rightTimer = 0.25
                        changeSelectorOption(i, 1)
                        navState.selectedSection = i
                        navState.selectedSectionItem = 2
                        updateKeyboardNavigation()
                    end
                end
            end
        end

        for _, buttonDef in ipairs(getVisibleButtons()) do
            if isMouseOverButton(buttonDef, tx, ty) then
                local buttonKey = buttonDef.__key
                if isButtonInteractableByKey(buttonKey) then
                    if buttonKey == "start" then
                        logFactionDebug("Start button clicked!")
                    end
                    buttonDef.currentColor = buttonDef.pressedColor
                    buttonDef.pressed = true
                    buttonDef.pressTimer = 0.1
                end
                break
            end
        end
    end
end

function factionSelect.mousereleased(x, y, button, istouch, presses)
    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousereleased(x, y, button)
    end

    -- Safety check
    if not GAME_STATE.initialized or not uiElements or not uiElements.buttons then return end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    for _, buttonDef in ipairs(getVisibleButtons()) do
        local buttonKey = buttonDef.__key
        local hovered = isMouseOverButton(buttonDef, tx, ty)
        if hovered and isButtonInteractableByKey(buttonKey) then
            initAudio()
            if SETTINGS.AUDIO.SFX then
                if buttonKey == "random" then
                    playArrowClick()
                else
                    playButtonClick()
                end
            end
            buttonDef.currentColor = buttonDef.hoverColor
        else
            applyButtonVisualState(buttonDef, buttonKey, false)
            buttonDef.currentColor = buttonDef.baseColor or BUTTON_STYLE_COLORS.normal
        end
    end
end

function factionSelect.mousemoved(x, y, dx, dy, istouch)
    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        ConfirmDialog.mousemoved(x, y)
        return true
    end

    -- Safety check
    if not GAME_STATE.initialized or not uiElements or not uiElements.buttons then return end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    local previousHovers = {}
    local visibleButtons = getVisibleButtons()
    for _, buttonDef in ipairs(visibleButtons) do
        previousHovers[buttonDef.__key] = (buttonDef.currentColor == buttonDef.hoverColor)
    end

    local currentHovers = {}
    for _, buttonDef in ipairs(visibleButtons) do
        local key = buttonDef.__key
        local isHovered = isMouseOverButton(buttonDef, tx, ty)
        if not isButtonInteractableByKey(key) then
            isHovered = false
            applyButtonVisualState(buttonDef, key, false)
            buttonDef.currentColor = buttonDef.baseColor or BUTTON_STYLE_COLORS.normal
        else
            applyButtonVisualState(buttonDef, key, true)
            buttonDef.currentColor = isHovered and buttonDef.hoverColor or UI_COLORS.button
            if not isHovered then
                buttonDef.currentColor = buttonDef.baseColor or BUTTON_STYLE_COLORS.normal
            end
        end
        currentHovers[key] = isHovered
    end

    for key, isHovered in pairs(currentHovers) do
        if not previousHovers[key] and isHovered then
            initAudio()
            playButtonBeep()
            break
        end
    end

    local previousArrowHovers = {}
    for i = 1, 2 do
        previousArrowHovers[i] = {
            left = uiElements.arrowStates[i].leftHover,
            right = uiElements.arrowStates[i].rightHover
        }
        uiElements.arrowStates[i].leftHover = false
        uiElements.arrowStates[i].rightHover = false
    end

    local anyArrowHovered = false
    local anyButtonHovered = false
    for _, isHovered in pairs(currentHovers) do
        if isHovered then
            anyButtonHovered = true
            break
        end
    end

    if not anyButtonHovered and canEditOnlineSetup() then
        for i = 1, 2 do
            local selector = uiElements.selectors[i]
            if selector then
                local arrowSize = 10
                local arrowY = selector.y + selector.height / 2

                local leftArrowX = selector.x + 20
                local leftArrowArea = {
                    x = leftArrowX - arrowSize,
                    y = arrowY - arrowSize,
                    width = arrowSize * 2,
                    height = arrowSize * 2
                }

                local rightArrowX = selector.x + selector.width - 20
                local rightArrowArea = {
                    x = rightArrowX - arrowSize,
                    y = arrowY - arrowSize,
                    width = arrowSize * 2,
                    height = arrowSize * 2
                }

                local leftHovered = isMouseOverButton(leftArrowArea, tx, ty) and (#selector.options > 1)
                local rightHovered = isMouseOverButton(rightArrowArea, tx, ty) and (#selector.options > 1)

                uiElements.arrowStates[i].leftHover = leftHovered
                uiElements.arrowStates[i].rightHover = rightHovered

                if leftHovered or rightHovered then
                    anyArrowHovered = true
                end

                if (not previousArrowHovers[i].left and leftHovered) or
                   (not previousArrowHovers[i].right and rightHovered) then
                    initAudio()
                    playButtonBeep()
                end
            end
        end
    end

    if anyButtonHovered or anyArrowHovered then
        navState.selectedSection = 0
        navState.selectedSectionItem = 0
    end
end

function factionSelect.startGame()
    if not GAME_STATE.initialized then 
        print("ERROR: GAME_STATE not initialized")
        return 
    end

    if isOnlineMode() and not canStartOnlineMatch() then
        return
    end

    logFactionDebug("=== Starting Game ===")
    applyControllerAssignmentsFromSelectors()
    broadcastOnlineSetupSnapshot(true)
    flushPendingHostBroadcasts(true)
    
    logFactionDebug("Game Mode:", GAME.CURRENT.MODE)
    logFactionDebug("AI Player Number:", GAME.CURRENT.AI_PLAYER_NUMBER)
    
    local controllers = GAME.CURRENT.CONTROLLERS
    if controllers then
        for id, controller in pairs(controllers) do
            logFactionDebug("Controller:", id, "Type:", controller.type, "Nickname:", controller.nickname)
        end
    else
        print("ERROR: No controllers set!")
    end
    
    local faction1Controller = GAME.getControllerForFaction(1)
    local faction2Controller = GAME.getControllerForFaction(2)
    logFactionDebug("Faction 1 Controller:", faction1Controller and faction1Controller.id or "NONE")
    logFactionDebug("Faction 2 Controller:", faction2Controller and faction2Controller.id or "NONE")

    if stateMachineRef and stateMachineRef.changeState then
        if isOnlineMode() then
            local session = getOnlineSession()
            local lockstep = getOnlineLockstep()
            if not session or not lockstep then
                print("ERROR: online session/lockstep not available")
                return
            end
            if not session.connected then
                logFactionDebug("[OnlineFactionSelect] Start blocked: remote player not connected")
                return
            end

            local setupPayload = buildOnlineSetupPayload()
            local ratingContext = glicko2.buildMatchContext(
                ensureLocalOnlineRatingProfileLoaded(),
                peerOnlineRatingProfile,
                session.hostUserId or session.localUserId,
                session.guestUserId or session.peerUserId,
                glicko2.currentDay()
            )
            session:setPreMatchRatingContext(ratingContext)
            session:setPreMatchRatings(
                math.floor((tonumber(ratingContext.host and ratingContext.host.rating) or 0) + 0.5),
                math.floor((tonumber(ratingContext.guest and ratingContext.guest.rating) or 0) + 0.5)
            )
            local fallbackSeed = 1
            if love and love.timer and love.timer.getTime then
                fallbackSeed = math.floor(love.timer.getTime() * 1000000)
            end
            local seed = GAME.CURRENT.SEED or randomGen.getSeed() or fallbackSeed
            local matchPayload = session:createMatchStartPayload(seed, setupPayload)

            lockstep:sendPacket({
                kind = "MATCH_START",
                sessionId = session.sessionId,
                payload = matchPayload
            })
            session:applyMatchStartPayload(matchPayload)
        end

        logFactionDebug("Changing state to gameplay...")
        stateMachineRef.changeState("gameplay")
    else
        print("ERROR: stateMachineRef not available")
    end
end

local function processOnlineFactionSelectSync()
    if not isOnlineMode() then
        return
    end

    local session = getOnlineSession()
    local lockstep = getOnlineLockstep()
    if not session or not lockstep then
        return
    end

    syncResolvedOnlineRole(session)

    local connectedBefore = session.connected == true

    local pendingEvents = consumePendingOnlineLobbyEvents(64)
    for _, lobbyEvent in ipairs(pendingEvents) do
        local handled = session:handleLobbyEvent(lobbyEvent)
        if handled then
            logFactionDebug("[OnlineFactionSelect] Lobby event handled: " .. tostring(handled))
        end
    end

    if session.lobbyId then
        local lobbySnapshot = steamRuntime.getLobbySnapshot(session.lobbyId)
        if lobbySnapshot then
            session:applyLobbySnapshot(lobbySnapshot)
        end
    end

    if connectedBefore ~= (session.connected == true) then
        logFactionDebug("[OnlineFactionSelect] Connection state changed: " .. tostring(connectedBefore) .. " -> " .. tostring(session.connected == true))
        if session.connected == true then
            resetPrematchTransportState("peer_connected")
        else
            resetPrematchTransportState("peer_disconnected")
        end
    end

    if session.connected ~= true then
        local disconnectReason = tostring(session.disconnectReason or "")
        if disconnectReason == "peer_missing_from_lobby" or disconnectReason == "peer_timeout_pre_match" then
            showFactionDisconnectDialogAndExit(disconnectReason)
            return "state_changed"
        end
    end

    local timeoutStatus = session:update()
    if timeoutStatus == "timeout" then
        print("[OnlineFactionSelect] Reconnect timeout in faction screen")
        showFactionDisconnectDialogAndExit("peer_timeout_pre_match")
        return "state_changed"
    end

    if session.connected == true and session.peerUserId and tostring(session.peerUserId) ~= tostring(session.localUserId) then
        if prematchTransportReady ~= true then
            local now = nowSeconds()
            if awaitingPrematchAckNonce == 0 then
                prematchHelloNonce = (tonumber(prematchHelloNonce) or 0) + 1
                awaitingPrematchAckNonce = prematchHelloNonce
                lastPrematchHelloSentAt = 0
            end
            if (now - (lastPrematchHelloSentAt or 0)) >= PREMATCH_HELLO_INTERVAL_SEC then
                local sent, sendErr = lockstep:sendPrematchHello(onlineSetupRevision, awaitingPrematchAckNonce, ensureLocalOnlineRatingProfileLoaded())
                if sent then
                    lastPrematchHelloSentAt = now
                else
                    print("[OnlineFactionSelect] PREMATCH_HELLO send failed: " .. tostring(sendErr))
                end
            end
        end
    end

    flushPendingHostBroadcasts(false)

    lockstep:update()
    while true do
        local event = lockstep:pollEvent()
        if not event then
            break
        end

        if event.kind == "prematch_hello" then
            local payload = event.payload or {}
            capturePeerOnlineRatingProfile(payload.ratingProfile)
            local ackSent, ackErr = lockstep:sendPrematchAck(payload.setupRevision or onlineSetupRevision, payload.nonce or 0, ensureLocalOnlineRatingProfileLoaded())
            if not ackSent then
                print("[OnlineFactionSelect] PREMATCH_ACK send failed: " .. tostring(ackErr))
            end
        elseif event.kind == "prematch_ack" then
            local payload = event.payload or {}
            capturePeerOnlineRatingProfile(payload.ratingProfile)
            local nonce = tonumber(payload.nonce) or 0
            if awaitingPrematchAckNonce ~= 0 and nonce == awaitingPrematchAckNonce then
                prematchTransportReady = true
                awaitingPrematchAckNonce = 0
                logFactionDebug("[OnlineFactionSelect] Prematch transport ready (nonce acked)")
            end
        elseif event.kind == "setup_snapshot" then
            if session.role == "host" then
                logFactionDebug("[OnlineFactionSelect] Ignoring remote setup snapshot (host authoritative setup)")
            else
                local setupPayload = event.payload and event.payload.setup
                if applyOnlineSetupPayload(setupPayload) then
                    logFactionDebug(string.format(
                        "[OnlineFactionSelect] Applied setup snapshot rev=%s",
                        tostring(setupPayload and setupPayload.setupRevision)
                    ))
                end
            end
        elseif event.kind == "ready_request" then
            if session.role == "host" then
                local payload = event.payload or {}
                local requestRevision = tonumber(payload.revision) or 0
                local currentRevision = tonumber(onlineSetupRevision) or 0
                if requestRevision == currentRevision then
                    onlineReadyState.guestReady = payload.ready == true
                    onlineReadyState.revision = (onlineReadyState.revision or 0) + 1
                else
                    logFactionDebug(string.format(
                        "[OnlineFactionSelect] Ignoring guest ready request due to setup revision mismatch req=%s current=%s",
                        tostring(requestRevision),
                        tostring(currentRevision)
                    ))
                end
                queuePendingReadyStateBroadcast()
            end
        elseif event.kind == "ready_state" then
            local payload = event.payload or {}
            onlineReadyState.hostReady = payload.hostReady == true
            onlineReadyState.guestReady = payload.guestReady == true
            onlineReadyState.revision = tonumber(payload.revision) or onlineReadyState.revision or 0
            if tonumber(payload.setupRevision) then
                onlineSetupRevision = tonumber(payload.setupRevision)
            end
            clearPendingGuestReady("ready_state")
            logReadyTelemetryState("ready_state")
        elseif event.kind == "match_start" then
            local payload = event.payload and event.payload.payload
            if payload then
                session:applyMatchStartPayload(payload)
                if payload.setup then
                    applyOnlineSetupPayload(payload.setup)
                end
                if payload.seed then
                    GAME.CURRENT.SEED = payload.seed
                end
            end
            clearPendingGuestReady("match_start")
            if stateMachineRef and stateMachineRef.changeState then
                stateMachineRef.changeState("gameplay")
            end
            return
        elseif event.kind == "aborted" then
            print("[OnlineFactionSelect] Match aborted before start: " .. tostring(event.payload and event.payload.reason or "unknown"))
            showFactionDisconnectDialogAndExit("peer_aborted_pre_match")
            return "state_changed"
        end
    end

    flushPendingHostBroadcasts(false)

    if pendingGuestReady ~= nil and pendingGuestReadySince ~= nil then
        local elapsed = nowSeconds() - pendingGuestReadySince
        if elapsed >= PENDING_READY_TIMEOUT_SEC then
            logFactionDebug("[OnlineFactionSelect] Guest ready confirmation timeout; clearing pending state")
            clearPendingGuestReady("pending_timeout")
            logReadyTelemetryState("pending_timeout")
        end
    end

    logReadyTelemetryState("sync_tick")
    return "continue"
end

function factionSelect.update(dt)
    -- Update confirmation dialog if active
    if ConfirmDialog.isActive() then
        ConfirmDialog.update(dt)
        return true
    end

    -- Safety check
    if not GAME_STATE.initialized or not uiElements then return end

    local onlineSyncState = processOnlineFactionSelectSync()
    if onlineSyncState == "state_changed" then
        return true
    end

    refreshButtonLayout()

    if isRemotePlayLocalVariant() and type(steamRuntime.getRemotePlayInputDiagnostics) == "function" then
        local diagnostics = steamRuntime.getRemotePlayInputDiagnostics() or {}
        local connectedSessions = math.max(0, tonumber(diagnostics.connectedSessions) or 0)
        local secondsSinceInput = tonumber(diagnostics.secondsSinceLastInput)

        if connectedSessions >= 1 and lastRemotePlayGuestCount < 1 then
            audioRuntime.resumeAudioOutput("remote_play_session_connected")
            audioRuntime.beginRemotePlaySession("remote_play_session_connected")
            showRemotePlayAudioMutedWarning()
            audioRuntime.logRemotePlayWindowSummary("remote_play_session_connected")
        end
        lastRemotePlayGuestCount = connectedSessions

        if connectedSessions >= 1 then
            if secondsSinceInput and secondsSinceInput > REMOTE_PLAY_INPUT_WARN_AFTER_SEC then
                if not remotePlayNoInputWarned then
                    remotePlayNoInputWarned = true
                    logFactionDebug(string.format("[RemotePlay] Guest connected but no input detected for %.1fs", secondsSinceInput))
                end
            elseif secondsSinceInput and secondsSinceInput <= REMOTE_PLAY_INPUT_WARN_AFTER_SEC then
                remotePlayNoInputWarned = false
            end
        else
            remotePlayNoInputWarned = false
        end
    else
        remotePlayNoInputWarned = false
        lastRemotePlayGuestCount = 0
    end

    -- Reset arrow press animations after a short time
    if type(uiElements.arrowStates) == "table" then
        for i, state in ipairs(uiElements.arrowStates) do
            if state.leftTimer and state.leftTimer > 0 then
                state.leftTimer = state.leftTimer - dt
                if state.leftTimer <= 0 then
                    state.left = false
                end
            end

            if state.rightTimer and state.rightTimer > 0 then
                state.rightTimer = state.rightTimer - dt
                if state.rightTimer <= 0 then
                    state.right = false
                end
            end
        end
    end

    -- Update selector name highlight timers
    if uiElements.selectors then
        for _, selector in ipairs(uiElements.selectors) do
            if selector.highlightTimer and selector.highlightTimer > 0 then
                selector.highlightTimer = selector.highlightTimer - dt
                if selector.highlightTimer < 0 then
                    selector.highlightTimer = 0
                end
            end
        end
    end

    -- Update button states if they're pressed
    for _, buttonDef in ipairs(getVisibleButtons()) do
        if buttonDef.visible ~= false and buttonDef.pressed then
            buttonDef.pressTimer = (buttonDef.pressTimer or 0) - dt
            if buttonDef.pressTimer <= 0 then
                buttonDef.pressed = false
                triggerFactionButtonAction(buttonDef.__key)
            end
        end
    end
end

function factionSelect.draw()
    -- Safety check
    if not GAME_STATE.initialized or not uiElements then return end

    refreshButtonLayout()

    love.graphics.push()
    love.graphics.translate(SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY)
    love.graphics.scale(SETTINGS.DISPLAY.SCALE)

    -- Background with shader
    if backgroundShader then
        love.graphics.setShader(backgroundShader)
        local timeNow = love.timer.getTime()
        backgroundShader:send("time", timeNow)

        -- Match gameplay shader uniforms for consistent visuals
        backgroundShader:send("resolution", {SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT})
        local gridCenterX = GAME.CONSTANTS.GRID_ORIGIN_X + GAME.CONSTANTS.GRID_WIDTH / 2
        local gridCenterY = GAME.CONSTANTS.GRID_ORIGIN_Y + GAME.CONSTANTS.GRID_HEIGHT / 2
        backgroundShader:send("gridCenter", {gridCenterX, gridCenterY})
        backgroundShader:send("gridSize", GAME.CONSTANTS.GRID_WIDTH)
        backgroundShader:send("displayScale", SETTINGS.DISPLAY.SCALE)
        backgroundShader:send("displayOffset", {SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY})

        local windowW, windowH = love.graphics.getDimensions()
        backgroundShader:send("resolution", { windowW, windowH })

        backgroundShader:send("factionCycle", timeNow * 0.9)

        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
        love.graphics.setShader() -- Reset shader
    else
        -- Fallback to solid color background if shader not available
        love.graphics.setColor(UI_COLORS.background)
        love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
    end

    -- Draw tech-style decorative elements (same as main menu)
    -- Left vertical accent line
    love.graphics.setColor(UI_COLORS.border)
    love.graphics.setLineWidth(2)
    love.graphics.line(80, 100, 80, SETTINGS.DISPLAY.HEIGHT - 100)

    -- Right vertical accent line
    love.graphics.line(SETTINGS.DISPLAY.WIDTH - 80, 100, SETTINGS.DISPLAY.WIDTH - 80, SETTINGS.DISPLAY.HEIGHT - 100)

    -- Horizontal accent line at the bottom
    love.graphics.line(120, SETTINGS.DISPLAY.HEIGHT - 80, SETTINGS.DISPLAY.WIDTH - 120, SETTINGS.DISPLAY.HEIGHT - 80)
    love.graphics.setLineWidth(1)

    -- Main title panel
    drawTechPanel(SETTINGS.DISPLAY.WIDTH / 2 - 150, 40, 300, 60)

    -- Title with glow effect
    drawTitle(uiElements.title.text, 0, 60, SETTINGS.DISPLAY.WIDTH)

    -- Draw faction cards instead of panels
    for i, faction in ipairs(uiElements.factions) do
        drawFactionCard(faction)
    end

    -- Draw selectors with polygon arrows
    local showSelectorArrows = canEditOnlineSetup()
    for i, selector in ipairs(uiElements.selectors) do
        -- Draw selector background themed to faction
        local factionBaseColor = (i == 1) and UI_COLORS.blueTeam or UI_COLORS.redTeam
        local factionColor = desaturateColor(factionBaseColor, 0.35)
        if type(factionColor) ~= "table" then
            factionColor = {factionBaseColor[1], factionBaseColor[2], factionBaseColor[3], factionBaseColor[4]}
        end
        local panelBackground = darkenColor(factionColor, 0.6)
        local panelBorderOuter = lightenColor(factionColor, 0.15)
        local panelBorderInner = lightenColor(factionColor, 0.35)

        love.graphics.setColor(panelBackground[1], panelBackground[2], panelBackground[3], panelBackground[4])
        love.graphics.rectangle("fill", selector.x, selector.y, selector.width, selector.height, 8)

        love.graphics.setLineWidth(2)
        love.graphics.setColor(panelBorderOuter[1], panelBorderOuter[2], panelBorderOuter[3], panelBorderOuter[4])
        love.graphics.rectangle("line", selector.x, selector.y, selector.width, selector.height, 8)

        love.graphics.setLineWidth(1)
        love.graphics.setColor(panelBorderInner[1], panelBorderInner[2], panelBorderInner[3], panelBorderInner[4])
        love.graphics.rectangle("line", selector.x + 3, selector.y + 3, selector.width - 6, selector.height - 6, 6)

        local fallbackColor = {1, 1, 1, 1}
        local baseColor = lightenColor(factionColor, 0.25) or fallbackColor
        local hoverColor = lightenColor(factionColor, 0.65) or fallbackColor
        local selectedColor = lightenColor(factionColor, 0.75) or fallbackColor
        local pressedColor = lightenColor(factionColor, 0.85) or fallbackColor
        local outlineColor = darkenColor(factionColor, 0.35) or fallbackColor

        if showSelectorArrows then
            -- Draw arrows as polygons
            local baseArrowSize = 10  -- Base size for the arrows
            local leftArrowX = selector.x + 20
            local rightArrowX = selector.x + selector.width - 20
            local arrowY = selector.y + selector.height / 2

            -- Get keyboard selection state for this faction
            local isLeftArrowSelected = (navState.selectedSection == i and navState.selectedSectionItem == 1)
            local isRightArrowSelected = (navState.selectedSection == i and navState.selectedSectionItem == 2)

            -- Left arrow arrow size calculation based on state
            local leftArrowSize = baseArrowSize
            if isLeftArrowSelected or uiElements.arrowStates[i].leftHover then
                local pulse = (math.sin(love.timer.getTime() * 5) + 1) / 2
                leftArrowSize = baseArrowSize * (1.1 + pulse * 0.2)
            elseif uiElements.arrowStates[i].left then
                leftArrowSize = baseArrowSize * 1.2
            end

            if isLeftArrowSelected then
                love.graphics.setColor(selectedColor[1], selectedColor[2], selectedColor[3], selectedColor[4])
            elseif uiElements.arrowStates[i].left then
                love.graphics.setColor(pressedColor[1], pressedColor[2], pressedColor[3], pressedColor[4])
            elseif uiElements.arrowStates[i].leftHover then
                love.graphics.setColor(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4])
            else
                love.graphics.setColor(baseColor[1], baseColor[2], baseColor[3], baseColor[4])
            end

            love.graphics.polygon("fill", 
                leftArrowX + leftArrowSize, arrowY - leftArrowSize,
                leftArrowX + leftArrowSize, arrowY + leftArrowSize,
                leftArrowX, arrowY
            )

            local rightArrowSize = baseArrowSize
            if isRightArrowSelected or uiElements.arrowStates[i].rightHover then
                local pulse = (math.sin(love.timer.getTime() * 5) + 1) / 2
                rightArrowSize = baseArrowSize * (1.1 + pulse * 0.2)
            elseif uiElements.arrowStates[i].right then
                rightArrowSize = baseArrowSize * 1.2
            end

            if isRightArrowSelected then
                love.graphics.setColor(selectedColor[1], selectedColor[2], selectedColor[3], selectedColor[4])
            elseif uiElements.arrowStates[i].right then
                love.graphics.setColor(pressedColor[1], pressedColor[2], pressedColor[3], pressedColor[4])
            elseif uiElements.arrowStates[i].rightHover then
                love.graphics.setColor(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4])
            else
                love.graphics.setColor(baseColor[1], baseColor[2], baseColor[3], baseColor[4])
            end

            love.graphics.polygon("fill",
                rightArrowX - rightArrowSize, arrowY - rightArrowSize,
                rightArrowX - rightArrowSize, arrowY + rightArrowSize,
                rightArrowX, arrowY
            )

            love.graphics.setLineWidth(1)
            love.graphics.setColor(outlineColor[1], outlineColor[2], outlineColor[3], outlineColor[4] or 1)
            love.graphics.polygon("line", 
                leftArrowX + leftArrowSize, arrowY - leftArrowSize,
                leftArrowX + leftArrowSize, arrowY + leftArrowSize,
                leftArrowX, arrowY
            )
            love.graphics.polygon("line",
                rightArrowX - rightArrowSize, arrowY - rightArrowSize,
                rightArrowX - rightArrowSize, arrowY + rightArrowSize,
                rightArrowX, arrowY
            )
            love.graphics.setLineWidth(1)
        end

        -- Draw current option text (highlight when randomized or interacted)
        local showingHighlight = uiElements.selectors[i].highlightTimer and uiElements.selectors[i].highlightTimer > 0
        if showingHighlight then
            love.graphics.setColor(255/255, 240/255, 220/255, 0.95)
        elseif showSelectorArrows and (uiElements.arrowStates[i].left or uiElements.arrowStates[i].right) then
            love.graphics.setColor(pressedColor[1], pressedColor[2], pressedColor[3], pressedColor[4])
        else
            love.graphics.setColor(baseColor[1], baseColor[2], baseColor[3], baseColor[4])
        end
        local displayText = ""
        if selector.options and selector.options[selector.currentOption] then
            local optionData = selector.options[selector.currentOption]
            displayText = optionData.label or tostring(optionData.id or "")
        else
            displayText = "No controllers"
        end
        local textInsetLeft = showSelectorArrows and 40 or 12
        local textInsetRight = showSelectorArrows and 40 or 12
        love.graphics.printf(displayText,
                             selector.x + textInsetLeft, selector.y + 12, selector.width - (textInsetLeft + textInsetRight), "center")
    end

    -- Draw action buttons from a single visible-source list
    local visibleButtons = getVisibleButtons()
    for _, buttonDef in ipairs(visibleButtons) do
        local buttonKey = buttonDef.__key
        applyButtonVisualState(buttonDef, buttonKey, true)
        if not isButtonInteractableByKey(buttonKey) and buttonDef.pressed ~= true then
            buttonDef.currentColor = buttonDef.baseColor or BUTTON_STYLE_COLORS.disabled
        end

        drawButton(buttonDef)
    end

    -- Add version info at bottom (like main menu)
    love.graphics.setColor(UI_COLORS.background)
    love.graphics.printf("Copyright Flipped Cat - Version " .. VERSION, 0, SETTINGS.DISPLAY.HEIGHT - 50, SETTINGS.DISPLAY.WIDTH, "center")

    -- Draw confirmation dialog if active (above everything else)
    if ConfirmDialog and ConfirmDialog.draw then
        ConfirmDialog.draw()
    end

    love.graphics.pop()
end

function factionSelect.exit()
    -- Mark as not initialized first to prevent callbacks accessing invalid data
    GAME_STATE.initialized = false
    clearPendingGuestReady("exit")
    pendingSetupSnapshot = false
    pendingReadyState = false
    resetPrematchTransportState("exit")
    lastReadyTelemetryKey = nil
    disconnectDialogShown = false
    remotePlayNoInputWarned = false
    lastRemotePlayGuestCount = 0

    -- Clean up card assets
    cardAssets.cardTemplate = nil
    cardAssets.cardBackgroundGrass = nil
    cardAssets.bluFactionImage = nil
    cardAssets.redFactionImage = nil
    
    -- Clean up shader
    backgroundShader = nil

    -- Clean up UI elements
    uiElements = {}
    collectgarbage("collect")
end

function factionSelect.keypressed(key, scancode, isrepeat)
    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        -- Let the dialog handle the key press
        local handled = ConfirmDialog.keypressed(key)
        -- Always return to prevent menu from handling keypresses when dialog is active
        return true
    end
    
    -- If no dialog is active, handle regular keyboard input
    if key == "escape" then
        -- Show confirmation dialog when Escape is pressed
        ConfirmDialog.show(
            "Are you sure you want to return to the main menu?",
            function()
                -- Confirmed - go back to main menu
                if isOnlineMode() then
                    terminateOnlineFactionAndReturnToMainMenu("faction_back")
                elseif stateMachineRef and stateMachineRef.changeState then
                    stateMachineRef.changeState("mainMenu")
                end
            end,
            function()
                -- Canceled - do nothing, stay in faction select
            end
        )
    elseif key == "up" or key == "w" then
        -- Restore keyboard navigation if mouse was controlling
        if navState.selectedSection == 0 then
            navState.selectedSection = 3
            navState.selectedSectionItem = math.max(1, math.min(2, getButtonNavCount()))
        elseif navState.selectedSection == 3 then
            if canEditOnlineSetup() then
                navState.selectedSection = 2
                navState.selectedSectionItem = 1
            else
                return
            end
        elseif navState.selectedSection == 1 or navState.selectedSection == 2 then
            -- When on arrows, UP does nothing
            return
        end
        -- Play navigation sound
        playButtonBeep()
        updateKeyboardNavigation()
    elseif key == "down" or key == "s" then
        -- Restore keyboard navigation if mouse was controlling
        if navState.selectedSection == 0 then
            navState.selectedSection = 3
            navState.selectedSectionItem = math.max(1, math.min(2, getButtonNavCount()))
        elseif navState.selectedSection == 1 or navState.selectedSection == 2 then
            -- When on arrows, DOWN goes to buttons
            navState.selectedSection = 3
            navState.selectedSectionItem = math.max(1, math.min(2, getButtonNavCount()))
        elseif navState.selectedSection == 3 then
            -- Already on buttons, do nothing
            return
        end
        -- Play navigation sound
        playButtonBeep()
        updateKeyboardNavigation()
    elseif key == "left" or key == "a" then
        -- Restore keyboard navigation if mouse was controlling
        if navState.selectedSection == 0 then
            navState.selectedSection = 3
            navState.selectedSectionItem = 2
        elseif navState.selectedSection == 1 then
            if not canEditOnlineSetup() then
                return
            end
            -- Faction 1 arrows
            if navState.selectedSectionItem == 1 then
                -- Left arrow of Faction 1: LEFT does nothing
                return
            elseif navState.selectedSectionItem == 2 then
                -- Right arrow of Faction 1: LEFT goes to left arrow of Faction 1
                navState.selectedSectionItem = 1
            end
        elseif navState.selectedSection == 2 then
            if not canEditOnlineSetup() then
                return
            end
            -- Faction 2 arrows
            if navState.selectedSectionItem == 1 then
                -- Left arrow of Faction 2: LEFT goes to right arrow of Faction 1
                navState.selectedSection = 1
                navState.selectedSectionItem = 2
            elseif navState.selectedSectionItem == 2 then
                -- Right arrow of Faction 2: LEFT goes to left arrow of Faction 2
                navState.selectedSectionItem = 1
            end
        elseif navState.selectedSection == 3 then
            navState.selectedSectionItem = navState.selectedSectionItem - 1
            if navState.selectedSectionItem < 1 then
                local buttonCount = getButtonNavCount()
                navState.selectedSectionItem = buttonCount > 0 and buttonCount or 1
            end
        end
        -- Play navigation sound
        playButtonBeep()
        updateKeyboardNavigation()
    elseif key == "right" or key == "d" then
        -- Restore keyboard navigation if mouse was controlling
        if navState.selectedSection == 0 then
            navState.selectedSection = 3
            navState.selectedSectionItem = 2
        elseif navState.selectedSection == 1 then
            if not canEditOnlineSetup() then
                return
            end
            -- Faction 1 arrows
            if navState.selectedSectionItem == 1 then
                -- Left arrow of Faction 1: RIGHT goes to right arrow of Faction 1
                navState.selectedSectionItem = 2
            elseif navState.selectedSectionItem == 2 then
                -- Right arrow of Faction 1: RIGHT goes to left arrow of Faction 2
                navState.selectedSection = 2
                navState.selectedSectionItem = 1
            end
        elseif navState.selectedSection == 2 then
            if not canEditOnlineSetup() then
                return
            end
            -- Faction 2 arrows
            if navState.selectedSectionItem == 1 then
                -- Left arrow of Faction 2: RIGHT goes to right arrow of Faction 2
                navState.selectedSectionItem = 2
            elseif navState.selectedSectionItem == 2 then
                -- Right arrow of Faction 2: RIGHT does nothing
                return
            end
        elseif navState.selectedSection == 3 then
            navState.selectedSectionItem = navState.selectedSectionItem + 1
            local buttonCount = getButtonNavCount()
            if buttonCount <= 0 then
                navState.selectedSectionItem = 1
            elseif navState.selectedSectionItem > buttonCount then
                navState.selectedSectionItem = 1
            end
        end
        -- Play navigation sound
        playButtonBeep()
        updateKeyboardNavigation()
    elseif key == "return" or key == "space" then
        -- Restore keyboard navigation if mouse was controlling
        if navState.selectedSection == 0 then
            navState.selectedSection = 3
            navState.selectedSectionItem = 2
        end
        initAudio()
        playButtonClick()

        if navState.selectedSection == 3 then
            local selectedButton = getButtonByNavIndex(navState.selectedSectionItem)
            if selectedButton and selectedButton.__key then
                triggerFactionButtonAction(selectedButton.__key)
            end
        elseif navState.selectedSection == 1 or navState.selectedSection == 2 then
            if not canEditOnlineSetup() then
                return
            end
            -- Faction selectors - change the selection based on which arrow is selected
            local selectorIndex = navState.selectedSection
            local delta = (navState.selectedSectionItem == 1) and -1 or 1
            initAudio()
            playArrowClick()

            changeSelectorOption(selectorIndex, delta)

            local arrowState = uiElements.arrowStates[selectorIndex]
            if delta < 0 then
                arrowState.left = true
                arrowState.leftTimer = 0.25
            else
                arrowState.right = true
                arrowState.rightTimer = 0.25
            end
        end
    end
end

function factionSelect.gamepadpressed(joystick, button)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.gamepadpressed(joystick, button)
    end

    if button == "a" then
        factionSelect.keypressed("return", "return", false)
        return true
    elseif button == "b" or button == "back" then
        factionSelect.keypressed("escape", "escape", false)
        return true
    elseif button == "leftshoulder" then
        factionSelect.keypressed("left", "left", false)
        return true
    elseif button == "rightshoulder" then
        factionSelect.keypressed("right", "right", false)
        return true
    end

    return false
end

return factionSelect
