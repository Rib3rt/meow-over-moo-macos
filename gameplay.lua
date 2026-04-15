local gameplay = {}
local os = require("os")

--------------------------------------------------
-- REQUIRE MODULES
--------------------------------------------------
local PlayGridClass = require("playGridClass")
local uiClass = require("uiClass")
local GameRulerClass = require("gameRuler")
local AiClass = require("ai")
local ConfirmDialog = require("confirmDialog")
local GameLogViewer = require("gameLogViewer")
local steamRuntime = require("steam_runtime")
local glicko2 = require("glicko2_rating")
local onlineRatingStore = require("online_rating_store")
local aiInfluence = require("ai_influence")
local logger = require("logger")
local perfMetrics = require("perf_metrics")
local resumeStore = require("resume_store")
local soundCache = require("soundCache")
local audioRuntime = require("audio_runtime")
local achievementRuntime = require("achievement_runtime")
local achievementDefs = require("achievement_defs")
local uiTheme = require("uiTheme")
local unitsInfo = require("unitsInfo")
local fontCache = require("fontCache")

local MONOGRAM_FONT_PATH = "assets/fonts/monogram-extended.ttf"

local function getMonogramFont(size)
    return fontCache.get(MONOGRAM_FONT_PATH, size)
end

--------------------------------------------------
-- LOCAL VARIABLES
--------------------------------------------------
local stateMachineRef = nil
local debugText = false
local mousePos = { x = 0, y = 0 }
local grid = {}
local ui = {}
local gameRuler = {}
local gameMode = GAME.MODE.SINGLE_PLAYER
local aiPlayer = {}
local onlineSession = nil
local onlineLockstep = nil
local onlineReconnectNotified = false
local onlineHeartbeatElapsed = 0
local onlineEloApplied = false
local onlineEloSummaryVisible = false
local onlineEloCloseButtonBounds = nil
local matchObjectiveModalVisible = false
local matchObjectiveCloseButtonBounds = nil
local unitCodexVisible = false
local unitCodexCloseButtonBounds = nil
local unitCodexToggleButtonBounds = nil
local unitCodexOpenButtonBounds = nil
local unitCodexDisplayFaction = nil
local unitCodexFocusedButton = "close"
local unitCodexTransitionElapsed = 0
local unitCodexTransitionDirection = 0
local unitCodexTransitionFromFaction = nil
local unitCodexMouseHover = {
    open = false,
    toggle = false,
    close = false
}
local onlineTurnTelemetryKey = nil
local onlineMatchTrafficGraceUntil = nil
local localPreviewSelectionKey = nil
local remotePreviewSelectionKey = nil
local remotePreviewActive = false
local onlineMatchSessionClosed = false
local ONLINE_GAMEPLAY_RECONNECT_TIMEOUT_SEC = 3.0
local ONLINE_TRAFFIC_STALE_SEC = tonumber((((SETTINGS or {}).STEAM_ONLINE or {}).PEER_TRAFFIC_STALE_SEC)) or 3.0
local ONLINE_TRAFFIC_STALE_GRACE_SEC = tonumber((((SETTINGS or {}).STEAM_ONLINE or {}).PEER_TRAFFIC_STALE_GRACE_SEC)) or math.max(ONLINE_TRAFFIC_STALE_SEC * 2, 6.0)
-- SCENARIO ISOLATION RULE:
-- Fields prefixed by matchObjective/scenarioOutcome below are for scenario mode flows.
-- Changes here must not alter behavior in non-scenario modes.
local onlineAutoAdvanceState = {
    candidateKey = nil,
    candidateSince = nil,
    issuedKey = nil,
    matchObjectiveModalState = nil,
    scenarioOutcomeModalShown = false,
    matchObjectiveSecondaryButtonBounds = nil,
    matchObjectiveFocusedButton = "primary",
    matchObjectiveHoveredButton = nil
}
-- Don't initialize with default value, always use GAME.CURRENT values
-- AI always plays optimally - no difficulty levels

-- Mode tracking
local buildingPlacementMode = false  -- New variable to track if we're placing a building

-- Confirmation dialog variables
local lastSetupHighlightKey = nil
local lastResumePhase = nil
local resumeSnapshotDirty = false
local resumeSnapshotReason = nil
local lastResumeWriteAt = 0
local RESUME_MIN_WRITE_INTERVAL_SEC = 0.35
local manualNoSaveExitRequested = false
local sendOnlinePreviewClearIfNeeded = function() end
local MATCH_OBJECTIVE_TITLE = "WIN CONDITIONS"
local MATCH_OBJECTIVE_BODY = "Defeat the enemy Commandant or all enemy units."
local MATCH_OBJECTIVE_CTA = "Orders Received"
local objectiveTitleFont = nil
local objectiveBodyFont = nil
local objectiveButtonFont = nil
local ONLINE_REACTION_COOLDOWN_SEC = 15.0
local UNIT_CODEX_TITLE = "UNIT CODEX"
local UNIT_CODEX_OPEN_LABEL = "UNIT CODEX"
local UNIT_CODEX_TOGGLE_KEY = "c"
local UNIT_CODEX_UNIT_ORDER = {"Commandant", "Wingstalker", "Crusher", "Bastion", "Cloudstriker", "Earthstalker", "Healer", "Artillery"}
local unitCodexTitleFont = nil
local unitCodexBadgeFont = nil
local UNIT_CODEX_TRANSITION_SEC = 0.18
local unitCodexGridCaches = {}
local drawUnitCodexCountBadge
local canCurrentInputIssueActions
local isCurrentTurnLocallyControlled
local isOnlineModeActive
local isRemotePlayLocalMode
local enteredFromResumeSnapshot = false
local matchCompletionAchievementsRecorded = false


-- Mouse visibility is now handled globally in stateMachine.lua

--------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------
local function transformMousePosition(x, y)
    return (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE,
           (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE
end

local function getOnlineNowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    if os and os.time then
        return os.time()
    end
    return 0
end

onlineAutoAdvanceState.resetCandidate = function()
    onlineAutoAdvanceState.candidateKey = nil
    onlineAutoAdvanceState.candidateSince = nil
end

onlineAutoAdvanceState.buildKey = function(actionType, phaseInfo)
    phaseInfo = phaseInfo or {}
    return table.concat({
        tostring(actionType or "-"),
        tostring(phaseInfo.currentTurn or "-"),
        tostring(phaseInfo.currentPhase or "-"),
        tostring(phaseInfo.turnPhaseName or "-"),
        tostring(phaseInfo.currentPlayer or "-")
    }, "|")
end

onlineAutoAdvanceState.getRequest = function(gameplayBlocked)
    if gameplayBlocked
        or not isOnlineModeActive()
        or not gameRuler
        or onlineEloSummaryVisible
        or matchObjectiveModalVisible
        or unitCodexVisible
        or (ConfirmDialog and type(ConfirmDialog.isActive) == "function" and ConfirmDialog.isActive())
        or (GameLogViewer and type(GameLogViewer.isActive) == "function" and GameLogViewer.isActive()) then
        return nil
    end

    local phaseInfo = gameRuler:getCurrentPhaseInfo() or {}
    local currentPhase = tostring(phaseInfo.currentPhase or "")
    local currentTurnPhase = tostring(phaseInfo.turnPhaseName or "")

    if currentPhase == "setup" then
        local role = (onlineSession and onlineSession.role) or (GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.role) or "host"
        if role ~= "host" then
            return nil
        end
        if gameRuler.neutralBuildingPlacementInProgress or gameRuler:isAnimationInProgress() then
            return nil
        end
        return {
            actionType = "placeAllNeutralBuildings",
            source = "auto_setup_rocks",
            key = onlineAutoAdvanceState.buildKey("placeAllNeutralBuildings", phaseInfo)
        }
    end

    if currentPhase == "deploy1_units" or currentPhase == "deploy2_units" then
        if not isCurrentTurnLocallyControlled() or not canCurrentInputIssueActions() then
            return nil
        end
        if not gameRuler:isInitialDeploymentComplete() or gameRuler:isAnimationInProgress() then
            return nil
        end
        return {
            actionType = "confirmDeployment",
            source = "auto_deployment_complete",
            key = onlineAutoAdvanceState.buildKey("confirmDeployment", phaseInfo)
        }
    end

    if currentPhase == "turn"
        and currentTurnPhase == "actions"
        and isCurrentTurnLocallyControlled()
        and canCurrentInputIssueActions()
        and gameRuler:areActionsComplete()
        and not gameRuler:isAnimationInProgress() then
        return {
            actionType = "end_turn",
            source = "auto_actions_complete",
            key = onlineAutoAdvanceState.buildKey("end_turn", phaseInfo)
        }
    end

    return nil
end

local function recordAchievementEvent(eventName, payload)
    local ok, reason = achievementRuntime.record(eventName, payload)
    if ok ~= true and reason ~= "no_handler" then
        print(string.format("[Achievements] event=%s failed reason=%s", tostring(eventName), tostring(reason)))
        return false
    end

    local flushed, flushReason = achievementRuntime.flush()
    if flushed ~= true and flushReason ~= "noop" then
        print(string.format("[Achievements] flush failed after %s reason=%s", tostring(eventName), tostring(flushReason)))
    end

    return true
end

local function incrementSteamStatValue(statId, delta)
    if not statId then
        return nil, "stat_id_missing"
    end
    local value, reason = steamRuntime.incrementStatInt(statId, delta or 1)
    if value == nil then
        print(string.format("[Stats] increment failed stat=%s reason=%s", tostring(statId), tostring(reason)))
        return nil, reason or "increment_failed"
    end
    return math.floor(tonumber(value) or 0)
end

local function incrementSteamStat(statId, delta)
    local value = incrementSteamStatValue(statId, delta)
    return value ~= nil
end

local function setSteamStat(statId, value)
    if not statId then
        return false
    end
    local ok, reason = steamRuntime.setStatInt(statId, value)
    if ok ~= true then
        print(string.format("[Stats] set failed stat=%s reason=%s", tostring(statId), tostring(reason)))
        return false
    end
    return true
end

local function storeSteamStats()
    local ok, reason = steamRuntime.storeUserStats()
    if ok ~= true then
        print(string.format("[Stats] store failed reason=%s", tostring(reason)))
        return false, reason or "store_failed"
    end
    return true
end

local function syncOnlineRatingProgress(profile)
    profile = type(profile) == "table" and profile or nil
    if not profile then
        return false
    end

    local rating = math.floor((tonumber(profile.rating) or 0) + 0.5)
    local stats = achievementDefs.STATS or {}
    local changed = false

    changed = setSteamStat(stats.CURRENT_RATING, rating) or changed

    local highest = steamRuntime.getStatInt(stats.HIGHEST_RATING)
    if highest == nil or rating > tonumber(highest or 0) then
        changed = setSteamStat(stats.HIGHEST_RATING, rating) or changed
    end

    recordAchievementEvent("rating_updated", {
        rating = rating
    })

    return changed
end

local function showRatingProfileRepairNoticeIfNeeded()
    if not onlineRatingStore or type(onlineRatingStore.consumeRepairNotice) ~= "function" then
        return false
    end
    local repairNotice = onlineRatingStore.consumeRepairNotice()
    if not repairNotice then
        return false
    end
    if ConfirmDialog and type(ConfirmDialog.showMessage) == "function" and type(ConfirmDialog.isActive) == "function" and not ConfirmDialog.isActive() then
        ConfirmDialog.showMessage(repairNotice.text, nil, {
            title = repairNotice.title,
            confirmText = "OK"
        })
        return true
    end
    return false
end

local function buildMatchAchievementPayload()
    if not gameRuler or gameRuler.currentPhase ~= "gameOver" then
        return nil
    end

    local mode = gameMode
    local winnerFaction = tonumber(gameRuler.winner)
    local localFaction = GAME.getLocalFactionId()
    local winnerController = winnerFaction and GAME.getControllerForFaction(winnerFaction) or nil
    local opponentFaction = nil
    local localUserWon = false

    if mode == GAME.MODE.MULTYPLAYER_NET then
        localUserWon = winnerFaction ~= nil and winnerFaction ~= 0 and winnerFaction == localFaction
        if localFaction then
            opponentFaction = localFaction == 1 and 2 or 1
        end
    else
        localUserWon = winnerFaction ~= nil and winnerFaction ~= 0 and winnerController ~= nil and winnerController.type ~= "ai"
        if winnerFaction and winnerFaction ~= 0 then
            opponentFaction = winnerFaction == 1 and 2 or 1
        end
    end

    local opponentController = opponentFaction and GAME.getControllerForFaction(opponentFaction) or nil
    return {
        mode = mode,
        winnerFaction = winnerFaction,
        localFaction = localFaction,
        localUserWon = localUserWon,
        opponentControllerType = opponentController and opponentController.type or nil,
        opponentControllerNickname = opponentController and opponentController.nickname or nil,
        victoryReason = gameRuler.lastVictoryReason,
        resultCode = GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.resultCode or nil
    }
end

local function processMatchCompletionAchievementsIfNeeded()
    if matchCompletionAchievementsRecorded or not gameRuler or gameRuler.currentPhase ~= "gameOver" then
        return
    end

    matchCompletionAchievementsRecorded = true
    local payload = buildMatchAchievementPayload()
    recordAchievementEvent("match_completed", payload)

    if payload and payload.localUserWon and payload.mode == GAME.MODE.SINGLE_PLAYER and payload.opponentControllerType == "ai" then
        local stats = achievementDefs.STATS or {}
        if incrementSteamStat(stats.AI_MATCHES_WON, 1) then
            storeSteamStats()
        end
    end
end

local function focusSupplyPanel(panelIndex)
    if not ui then
        return false
    end

    if ui.navigationMode ~= "ui" then
        ui.navigationMode = "ui"
    end
    ui.uIkeyboardNavigationActive = true

    ui:initializeUIElements()
    ui.currentNavPanel = panelIndex
    ui.currentNavRow = 1
    ui.currentNavCol = 1
    ui.lastSupplyKey = nil

    if grid then
        grid.mouseHoverCell = nil
        if grid.hideHoverIndicator then
            grid:hideHoverIndicator()
        end
        grid.uiNavigationActive = false
    end

    if ui.gameRuler and ui.gameRuler.currentGrid then
        ui.gameRuler.currentGrid.keyboardSelectedCell = { row = 1, col = 1 }
        ui.gameRuler.currentGrid.uiNavigationActive = false
    end

    HOVER_INDICATOR_STATE.IS_HIDDEN = true

    local targetIndex = ui:findUIElementByPosition(panelIndex, 1, 1)
    if targetIndex then
        ui.currentUIElementIndex = targetIndex
        ui.activeUIElement = ui.uiElements[targetIndex]
        ui:syncKeyboardAndMouseFocus()
    end

    return true
end

local function handleSupplyPanelShortcutKey(key)
    if key ~= "q" and key ~= "e" then
        return false
    end

    if gameMode == GAME.MODE.AI_VS_AI or gameMode == GAME.MODE.SCENARIO then
        return true
    end

    if isRemotePlayLocalMode() and not canCurrentInputIssueActions() then
        return true
    end

    if key == "q" then
        return focusSupplyPanel(1)
    end

    return focusSupplyPanel(2)
end

local function getAnimationDelta(dt)
    local maxDt = (GAME and GAME.CONSTANTS and GAME.CONSTANTS.MAX_ANIMATION_FRAME_DT) or (1 / 30)
    if dt <= maxDt then
        return dt
    end
    return maxDt
end

local function hasActiveUnitSelection()
    if gameRuler and gameRuler.currentActionPreview and gameRuler.currentActionPreview.selectedUnit then
        return true
    end

    if gameRuler and gameRuler.actionsPhaseSupplySelection ~= nil then
        return true
    end

    if gameRuler and gameRuler.initialDeployment and gameRuler.initialDeployment.selectedUnitIndex ~= nil then
        return true
    end

    if grid and grid.selectedGridUnit then
        return true
    end

    if ui and ui.selectedUnit then
        return true
    end

    return false
end

local function clearActiveUnitSelection()
    sendOnlinePreviewClearIfNeeded("clear_selection")

    if grid then
        if grid.clearForcedHighlightedCells then
            grid:clearForcedHighlightedCells()
        end
        if grid.clearActionHighlights then
            grid:clearActionHighlights()
        end
        if grid.clearSelectedGridUnit then
            grid:clearSelectedGridUnit()
        end
    end

    if gameRuler then
        gameRuler.currentActionPreview = nil
        gameRuler.actionsPhaseSupplySelection = nil
        if gameRuler.initialDeployment then
            gameRuler.initialDeployment.selectedUnitIndex = nil
        end
    end

    if ui then
        if ui.clearSupplySelection then
            ui:clearSupplySelection()
        else
            ui.selectedUnit = nil
            ui.selectedUnitIndex = nil
            ui.selectedUnitPlayer = nil
            ui.selectedUnitCoordOnPanel = nil
        end
        if ui.setContent then
            ui:setContent(nil)
        end
    end
end

local applyOnlineEloUpdateIfNeeded

isOnlineModeActive = function()
    return gameMode == GAME.MODE.MULTYPLAYER_NET and onlineSession ~= nil and onlineLockstep ~= nil
end

isRemotePlayLocalMode = function()
    return gameMode == GAME.MODE.MULTYPLAYER_LOCAL and tostring((GAME.CURRENT and GAME.CURRENT.LOCAL_MATCH_VARIANT) or "couch") == "remote_play"
end

local function showRemotePlayAudioMutedWarning()
    if not isRemotePlayLocalMode() then
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

local function isResumeSupportedMode()
    if isRemotePlayLocalMode() then
        return false
    end
    return gameMode == GAME.MODE.SINGLE_PLAYER or gameMode == GAME.MODE.MULTYPLAYER_LOCAL
end

local function cloneShallowTable(source)
    local out = {}
    for key, value in pairs(source or {}) do
        out[key] = value
    end
    return out
end

local function cloneSequence(source)
    local out = {}
    for index, value in ipairs(source or {}) do
        out[index] = value
    end
    return out
end

local function buildResumeEnvelope()
    if not gameRuler or type(gameRuler.buildResumeSnapshot) ~= "function" then
        return nil
    end

    local serializedControllers = {}
    for controllerId, controller in pairs(GAME.CURRENT.CONTROLLERS or {}) do
        if type(controller) == "table" and type(controller.serialize) == "function" then
            serializedControllers[controllerId] = controller:serialize()
        elseif type(controller) == "table" then
            serializedControllers[controllerId] = {
                id = controller.id,
                nickname = controller.nickname,
                type = controller.type,
                isLocal = controller.isLocal,
                metadata = cloneShallowTable(controller.metadata)
            }
        end
    end

    return {
        version = 4,
        mode = gameMode,
        timestamp = (os and os.time and os.time()) or 0,
        seed = GAME.CURRENT.SEED,
        controllers = serializedControllers,
        controllerSequence = cloneSequence(GAME.CURRENT.CONTROLLER_SEQUENCE),
        factionAssignments = cloneShallowTable(GAME.CURRENT.FACTION_ASSIGNMENTS),
        snapshot = gameRuler:buildResumeSnapshot()
    }
end

local function clearResumeSnapshot(reason)
    resumeSnapshotDirty = false
    resumeSnapshotReason = nil
    lastResumeWriteAt = 0

    local ok, err = resumeStore.clear(reason)
    if not ok then
        print(string.format("[Resume] clear failed (%s): %s", tostring(reason), tostring(err)))
        return false
    end
    return true
end

local function isResumeStateStable()
    if not isResumeSupportedMode() or not gameRuler then
        return false
    end

    if type(gameRuler.isAnimationInProgress) == "function" and gameRuler:isAnimationInProgress() then
        return false
    end

    if type(gameRuler.hasActiveAnimations) == "function" and gameRuler:hasActiveAnimations() then
        return false
    end

    if type(gameRuler.scheduledActions) == "table" and #gameRuler.scheduledActions > 0 then
        return false
    end

    if grid and type(grid.movingUnits) == "table" and #grid.movingUnits > 0 then
        return false
    end

    return true
end

local function markResumeDirty(reason)
    if not isResumeSupportedMode() then
        return
    end

    resumeSnapshotDirty = true
    if reason then
        resumeSnapshotReason = reason
    end
end

local function saveResumeSnapshot(reason)
    if not isResumeSupportedMode() then
        return false
    end

    if not gameRuler or gameRuler.currentPhase == "gameOver" then
        return false
    end

    local envelope = buildResumeEnvelope()
    if not envelope then
        return false
    end

    local ok, err = resumeStore.save(envelope)
    if not ok then
        print(string.format("[Resume] save failed (%s): %s", tostring(reason), tostring(err)))
        return false
    end

    lastResumePhase = gameRuler.currentPhase
    return true
end

local function flushResumeSnapshotIfStable(reason, options)
    options = options or {}
    if not resumeSnapshotDirty then
        return false
    end

    if not isResumeStateStable() then
        return false
    end

    local now = getOnlineNowSeconds()
    local bypassInterval = options.forceInterval == true
    if (not bypassInterval) and lastResumeWriteAt > 0 and (now - lastResumeWriteAt) < RESUME_MIN_WRITE_INTERVAL_SEC then
        return false
    end

    local ok = saveResumeSnapshot(reason or resumeSnapshotReason or "stable_flush")
    if ok then
        resumeSnapshotDirty = false
        resumeSnapshotReason = nil
        lastResumeWriteAt = now
    end
    return ok
end

local function clearOnlineRuntimeState(reasonCode)
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    local online = GAME.CURRENT.ONLINE
    online.active = false
    online.role = nil
    online.factionRole = nil
    online.session = nil
    online.lockstep = nil
    online.autoJoinLobbyId = nil
    online.pendingLobbyEvents = {}
    online.eloSummary = nil
    online.resultCode = reasonCode or online.resultCode
    onlineMatchTrafficGraceUntil = nil
    onlineEloSummaryVisible = false
    onlineEloCloseButtonBounds = nil
end

local function queueMainMenuOneShotNotice(title, message)
    GAME.CURRENT = GAME.CURRENT or {}
    GAME.CURRENT.MAIN_MENU_ONE_SHOT_NOTICE = {
        title = tostring(title or "Notice"),
        message = tostring(message or "")
    }
end

local function returnBrokenOnlineMatchToMainMenu(reasonCode)
    local resolvedReason = tostring(reasonCode or "connection_lost")
    print(string.format("[OnlineGameplay] FAILSAFE_MAIN_MENU reason=%s", resolvedReason))

    if onlineSession and type(onlineSession.leave) == "function" then
        onlineSession:leave()
        onlineMatchSessionClosed = true
    end

    clearOnlineRuntimeState(resolvedReason)
    queueMainMenuOneShotNotice("Connection Lost", "Online match connection was lost. Returning to main menu.")

    if stateMachineRef then
        stateMachineRef.changeState("mainMenu")
    end
    return true
end

local function resolveTimeoutForfeitWinnerFaction()
    if not gameRuler then
        return nil
    end

    local localFaction = GAME.getLocalFactionId() or gameRuler.currentPlayer or 1
    local opponentFaction = (localFaction == 1) and 2 or 1
    if not onlineSession then
        return nil
    end

    local reason = tostring(onlineSession.disconnectReason or "")
    if reason == "local_missing_from_lobby" then
        return opponentFaction
    end
    if reason == "peer_missing_from_lobby" then
        return localFaction
    end

    if onlineSession.localPresentInLobby == false then
        return opponentFaction
    end
    if onlineSession.localPresentInLobby == true then
        return localFaction
    end

    return nil
end

local function finalizeOnlineMatchEnd(reasonCode, options)
    options = options or {}

    local setGameOver = options.setGameOver == true
    local winnerFaction = options.winnerFaction
    local logLine = options.logLine

    if gameRuler and setGameOver and gameRuler.currentPhase ~= "gameOver" then
        gameRuler.winner = winnerFaction
        gameRuler.lastVictoryReason = (winnerFaction == 0) and "draw" or tostring(options.victoryReason or "online_result")
        gameRuler.drawGame = (winnerFaction == 0)
        if logLine and logLine ~= "" then
            gameRuler:addLogEntryString(logLine)
        end
        gameRuler:setPhase("gameOver")
    elseif gameRuler and logLine and logLine ~= "" and gameRuler.currentPhase ~= "gameOver" then
        gameRuler:addLogEntryString(logLine)
    end

    if GAME.CURRENT.ONLINE then
        GAME.CURRENT.ONLINE.resultCode = reasonCode
    end

    if options.applyElo == true then
        applyOnlineEloUpdateIfNeeded()
    end

    if options.leaveSession == true and onlineSession then
        onlineSession:leave()
        onlineMatchSessionClosed = true
    end

    onlineReconnectNotified = false
    onlineHeartbeatElapsed = 0
    onlineMatchTrafficGraceUntil = nil
end

local function preserveCompletedOnlineMatchStateAfterDisconnect(reasonCode)
    if not gameRuler or gameRuler.currentPhase ~= "gameOver" then
        return false
    end

    if isOnlineModeActive() then
        applyOnlineEloUpdateIfNeeded()
    end

    local resolvedReason = tostring(reasonCode or (GAME.CURRENT and GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.resultCode) or "completed_match_disconnect")
    print(string.format("[OnlineGameplay] POST_GAME_DISCONNECT_PRESERVE reason=%s", resolvedReason))

    if onlineSession and type(onlineSession.leave) == "function" and not onlineMatchSessionClosed then
        onlineSession:leave()
        onlineMatchSessionClosed = true
    end

    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    local online = GAME.CURRENT.ONLINE
    online.active = false
    online.session = nil
    online.lockstep = nil
    online.pendingLobbyEvents = {}
    online.resultCode = online.resultCode or resolvedReason
    onlineReconnectNotified = false
    onlineHeartbeatElapsed = 0
    onlineMatchTrafficGraceUntil = nil
    onlineSession = nil
    onlineLockstep = nil
    return true
end

local function finalizeBrokenOnlineMatchIfPossible(source, fallbackReason)
    local reason = tostring(fallbackReason or (onlineSession and onlineSession.disconnectReason) or "connection_lost")

    if gameRuler and gameRuler.currentPhase ~= "gameOver" then
        local winnerFaction = resolveTimeoutForfeitWinnerFaction()
        if winnerFaction then
            local localFaction = GAME.getLocalFactionId() or gameRuler.currentPlayer or 1
            local localWon = winnerFaction == localFaction
            local logLine = localWon
                and "ONLINE FORFEIT WIN: opponent disconnected"
                or "ONLINE FORFEIT LOSS: connection lost"
            print(string.format(
                "[OnlineGameplay] DISCONNECT_FINALIZE source=%s reason=%s winnerFaction=%s",
                tostring(source or "unknown"),
                reason,
                tostring(winnerFaction)
            ))
            finalizeOnlineMatchEnd("timeout_forfeit", {
                setGameOver = true,
                winnerFaction = winnerFaction,
                logLine = logLine,
                applyElo = true,
                leaveSession = true
            })
            return true
        end

        if reason ~= "" then
            print(string.format(
                "[OnlineGameplay] DISCONNECT_ABORT source=%s reason=%s",
                tostring(source or "unknown"),
                reason
            ))
            finalizeOnlineMatchEnd("aborted_disconnect", {
                setGameOver = true,
                winnerFaction = nil,
                logLine = "ONLINE MATCH ABORTED: " .. reason,
                applyElo = false,
                leaveSession = true
            })
            return true
        end
    end

    return false
end

local function consumePendingOnlineGameplayLobbyEvents()
    if not GAME or not GAME.CURRENT or not GAME.CURRENT.ONLINE then
        return false
    end

    local online = GAME.CURRENT.ONLINE
    local queue = online.pendingLobbyEvents
    if type(queue) ~= "table" or #queue == 0 or not onlineSession or type(onlineSession.handleLobbyEvent) ~= "function" then
        return false
    end

    local consumedAny = false
    while #queue > 0 do
        local event = table.remove(queue, 1)
        local handled = onlineSession:handleLobbyEvent(event)
        if handled then
            consumedAny = true
            print(string.format("[OnlineGameplay] LOBBY_EVENT handled=%s", tostring(handled)))

            local disconnectReason = tostring(onlineSession.disconnectReason or "")
            if disconnectReason == "peer_missing_from_lobby" or disconnectReason == "local_missing_from_lobby" then
                if gameRuler and gameRuler.currentPhase == "gameOver" then
                    preserveCompletedOnlineMatchStateAfterDisconnect(disconnectReason)
                    return true
                end
                if not finalizeBrokenOnlineMatchIfPossible("lobby_event_" .. disconnectReason, disconnectReason) then
                    return returnBrokenOnlineMatchToMainMenu(disconnectReason)
                end
                return true
            end
        end
    end

    return consumedAny
end

local function isOnlineGameplaySessionUnhealthy()
    if not isOnlineModeActive() then
        return false
    end
    if not onlineSession or not onlineLockstep then
        return true
    end
    if onlineSession.active ~= true then
        return true
    end
    if gameRuler and gameRuler.currentPhase ~= "gameOver" and onlineSession.matchStarted then
        local peerUserId = tostring(onlineSession.peerUserId or "")
        if peerUserId == "" or peerUserId == tostring(onlineSession.localUserId or "") then
            return true
        end
    end
    return false
end

local function canOfferOnlineConcede()
    if not isOnlineModeActive() or not onlineSession or not onlineLockstep or not gameRuler then
        return false
    end
    if gameRuler.currentPhase == "gameOver" then
        return false
    end
    if onlineSession.active ~= true or onlineSession.connected ~= true then
        return false
    end
    if tostring(onlineSession.peerUserId or "") == "" then
        return false
    end
    if tostring(onlineSession.disconnectReason or "") ~= "" then
        return false
    end
    return true
end

local function closeOnlineSessionAfterGameOverIfNeeded(source)
    if onlineMatchSessionClosed then
        return
    end
    if not isOnlineModeActive() or not onlineSession or not gameRuler then
        return
    end
    if gameRuler.currentPhase ~= "gameOver" then
        return
    end

    applyOnlineEloUpdateIfNeeded()
    if onlineSession.active then
        print(string.format("[OnlineGameplay] Closing online lobby after match end (%s)", tostring(source or "game_over")))
        onlineSession:leave()
    end
    onlineMatchSessionClosed = true
    onlineReconnectNotified = false
    onlineHeartbeatElapsed = 0
    onlineMatchTrafficGraceUntil = nil
end

isCurrentTurnLocallyControlled = function()
    if not gameRuler then
        return true
    end

    if isOnlineModeActive() then
        return GAME.isFactionControlledLocally(gameRuler.currentPlayer)
    end

    if gameMode == GAME.MODE.SINGLE_PLAYER or gameMode == GAME.MODE.SCENARIO then
        return gameRuler.currentPlayer ~= gameRuler.aiPlayerNumber
    end

    return true
end

local function getCurrentInputSourceContext()
    if stateMachineRef and type(stateMachineRef.getCurrentInputSourceContext) == "function" then
        local context = stateMachineRef.getCurrentInputSourceContext()
        if type(context) == "table" then
            return context
        end
    end
    return {
        kind = "unknown",
        isRemote = false,
        sessionId = nil
    }
end

local function resolvePlayerTwoControllerId()
    local controllers = GAME.CURRENT and GAME.CURRENT.CONTROLLERS
    if type(controllers) == "table" then
        for controllerKey, controller in pairs(controllers) do
            local metadata = controller and controller.metadata
            if tonumber(metadata and metadata.slot) == 2 then
                local resolvedId = controller and controller.id or controllerKey
                if resolvedId ~= nil and tostring(resolvedId) ~= "" then
                    return tostring(resolvedId)
                end
            end
        end

        if controllers.preset_player_2 then
            return "preset_player_2"
        end
    end

    local sequence = GAME.CURRENT and GAME.CURRENT.CONTROLLER_SEQUENCE
    if type(sequence) == "table" then
        local controllerId = sequence[2]
        if controllerId ~= nil and tostring(controllerId) ~= "" then
            return tostring(controllerId)
        end
    end
    return nil
end

local function isCurrentTurnOwnedByPlayerTwoController()
    if not gameRuler or not GAME or not GAME.CURRENT then
        return false
    end

    local playerTwoControllerId = resolvePlayerTwoControllerId()
    if not playerTwoControllerId then
        return false
    end

    local assignments = GAME.CURRENT.FACTION_ASSIGNMENTS or {}
    local currentFactionControllerId = assignments[gameRuler.currentPlayer]
    if currentFactionControllerId == nil then
        return false
    end

    return tostring(currentFactionControllerId) == playerTwoControllerId
end

local function isRemoteGuestInputSource()
    local context = getCurrentInputSourceContext()
    return context.isRemote == true or tostring(context.kind or "") == "remote_play_direct_input"
end

canCurrentInputIssueActions = function()
    if not gameRuler then
        return true
    end

    if isOnlineModeActive() then
        return isCurrentTurnLocallyControlled()
    end

    if isRemotePlayLocalMode() then
        local p2Turn = isCurrentTurnOwnedByPlayerTwoController()
        local remoteInput = isRemoteGuestInputSource()
        if p2Turn then
            return remoteInput
        end
        return not remoteInput
    end

    return isCurrentTurnLocallyControlled()
end

local function isCurrentInputReadOnlyBlocked()
    if not gameRuler then
        return false
    end

    if isOnlineModeActive() then
        return not isCurrentTurnLocallyControlled()
    end

    if isRemotePlayLocalMode() then
        return not canCurrentInputIssueActions()
    end

    return false
end

local function isReadOnlyUiControlName(name)
    local text = tostring(name or "")
    if text == "surrenderButton" or text == "gameLogPanel" or text == "unitCodexButton" then
        return true
    end
    return text:match("^reactionButton_") ~= nil
end

local function buildPreviewContext()
    if not gameRuler or type(gameRuler.getCurrentPhaseInfo) ~= "function" then
        return {
            turn = nil,
            phase = nil,
            turnPhase = nil
        }
    end

    local phaseInfo = gameRuler:getCurrentPhaseInfo() or {}
    return {
        turn = phaseInfo.currentTurn,
        phase = phaseInfo.currentPhase,
        turnPhase = phaseInfo.turnPhaseName
    }
end

local function isTurnActionsContext(context)
    if not context then
        return false
    end
    return context.phase == "turn" and context.turnPhase == "actions"
end

local function clearRemotePreviewVisual(reason)
    if not remotePreviewActive and not remotePreviewSelectionKey then
        return
    end

    if grid then
        if grid.clearForcedHighlightedCells then
            grid:clearForcedHighlightedCells()
        end
        if grid.clearActionHighlights then
            grid:clearActionHighlights()
        end
        if grid.clearSelectedGridUnit then
            grid:clearSelectedGridUnit()
        end
    end

    if gameRuler then
        gameRuler.currentActionPreview = nil
    end

    remotePreviewActive = false
    remotePreviewSelectionKey = nil

    if reason then
        print(string.format("[OnlineGameplay] PREVIEW_CLEAR_APPLY reason=%s", tostring(reason)))
    end
end

local function sendOnlinePreviewSelectIfNeeded(row, col)
    if not isOnlineModeActive() or not onlineLockstep then
        return
    end
    if not isCurrentTurnLocallyControlled() then
        return
    end

    local context = buildPreviewContext()
    if not isTurnActionsContext(context) then
        return
    end

    local key = table.concat({
        tostring(context.turn or "-"),
        tostring(context.phase or "-"),
        tostring(context.turnPhase or "-"),
        tostring(row or "?"),
        tostring(col or "?")
    }, "|")

    if key == localPreviewSelectionKey then
        return
    end

    local ok, err = onlineLockstep:sendPreviewSelect({
        row = row,
        col = col,
        turn = context.turn,
        phase = context.phase,
        turnPhase = context.turnPhase
    })

    if ok then
        localPreviewSelectionKey = key
    else
        print(string.format("[OnlineGameplay] PREVIEW_SELECT_SEND_FAILED reason=%s", tostring(err)))
    end
end

sendOnlinePreviewClearIfNeeded = function(reason)
    if not localPreviewSelectionKey then
        return
    end

    localPreviewSelectionKey = nil

    if not isOnlineModeActive() or not onlineLockstep then
        return
    end

    local context = buildPreviewContext()
    local ok, err = onlineLockstep:sendPreviewClear({
        turn = context.turn,
        phase = context.phase,
        turnPhase = context.turnPhase
    })

    if not ok then
        print(string.format("[OnlineGameplay] PREVIEW_CLEAR_SEND_FAILED reason=%s cause=%s", tostring(err), tostring(reason or "unspecified")))
    end
end

local function contextMatchesCurrentState(context)
    if not context then
        return true
    end

    local current = buildPreviewContext()
    if context.phase and current.phase and context.phase ~= current.phase then
        return false
    end
    if context.turnPhase and current.turnPhase and context.turnPhase ~= current.turnPhase then
        return false
    end
    if context.turn and current.turn and tonumber(context.turn) ~= tonumber(current.turn) then
        return false
    end

    return true
end

local function applyRemotePreviewSelect(payload)
    if not isOnlineModeActive() then
        return
    end
    if not payload then
        return
    end
    if isCurrentTurnLocallyControlled() then
        return
    end

    local context = {
        turn = payload.turn,
        phase = payload.phase,
        turnPhase = payload.turnPhase
    }

    if not contextMatchesCurrentState(context) then
        return
    end

    if not isTurnActionsContext(buildPreviewContext()) then
        return
    end

    local row = tonumber(payload.row)
    local col = tonumber(payload.col)
    if not row or not col then
        return
    end

    local key = table.concat({
        tostring(context.turn or "-"),
        tostring(context.phase or "-"),
        tostring(context.turnPhase or "-"),
        tostring(row),
        tostring(col)
    }, "|")

    if key == remotePreviewSelectionKey then
        return
    end

    if not grid or not gameRuler then
        return
    end

    local unit = grid:getUnitAt(row, col)
    if not unit or unit.player ~= gameRuler.currentPlayer or unit.hasActed or unit.name == "Commandant" then
        clearRemotePreviewVisual("invalid_remote_unit")
        return
    end

    if not gameRuler:unitHasLegalActions(row, col) then
        clearRemotePreviewVisual("remote_unit_no_legal_actions")
        return
    end

    if grid.clearForcedHighlightedCells then
        grid:clearForcedHighlightedCells()
    end
    if grid.clearActionHighlights then
        grid:clearActionHighlights()
    end
    if grid.clearSelectedGridUnit then
        grid:clearSelectedGridUnit()
    end

    if grid.selectUnit then
        grid:selectUnit(row, col)
    end
    gameRuler:previewUnitMovement(row, col)
    gameRuler:previewUnitAttack(row, col)
    gameRuler:previewUnitRepair(row, col)

    remotePreviewSelectionKey = key
    remotePreviewActive = true
end

local function executeLocalCommand(commandPayload)
    if type(commandPayload) ~= "table" then
        return false
    end

    local actionType = commandPayload.actionType
    if actionType == "move" then
        return gameRuler:executeUnitMovement(
            commandPayload.fromRow,
            commandPayload.fromCol,
            commandPayload.toRow,
            commandPayload.toCol
        )
    elseif actionType == "attack" then
        return gameRuler:executeUnitAttack(
            commandPayload.fromRow,
            commandPayload.fromCol,
            commandPayload.toRow,
            commandPayload.toCol
        )
    elseif actionType == "repair" then
        return gameRuler:executeUnitRepair(
            commandPayload.fromRow,
            commandPayload.fromCol,
            commandPayload.toRow,
            commandPayload.toCol
        )
    elseif actionType == "end_turn" then
        if not gameRuler or type(gameRuler.nextTurn) ~= "function" then
            return false
        end
        gameRuler:nextTurn()
        return true
    elseif actionType == "surrender" then
        local surrenderingPlayer = tonumber(commandPayload.params and commandPayload.params.surrenderingPlayer) or gameRuler.currentPlayer
        if surrenderingPlayer ~= 1 and surrenderingPlayer ~= 2 then
            return false
        end

        local winner = surrenderingPlayer == 1 and 2 or 1
        gameRuler:addLogEntryString("P" .. tostring(surrenderingPlayer) .. " call M.O.M. P" .. tostring(winner) .. " wins!")
        gameRuler.winner = winner
        gameRuler.lastVictoryReason = "surrender"
        gameRuler:setPhase("gameOver")

        if GAME.CURRENT.ONLINE then
            GAME.CURRENT.ONLINE.resultCode = "surrender_forfeit"
        end

        return true
    elseif actionType and actionType ~= "" then
        return gameRuler:performAction(actionType, commandPayload.params or {})
    end
    return false
end

local function applyOnlineCommand(commandPayload)
    if type(commandPayload) ~= "table" then
        return false
    end
    return executeLocalCommand(commandPayload)
end

local function proposeOnlineCommand(commandPayload)
    if not isOnlineModeActive() then
        return false, "online_not_active"
    end

    local phaseInfo = gameRuler and gameRuler:getCurrentPhaseInfo() or {}
    local ok, result = onlineLockstep:proposeAction(commandPayload, {
        turn = phaseInfo.currentTurn,
        phase = phaseInfo.currentPhase,
        turnPhase = phaseInfo.turnPhaseName,
        player = phaseInfo.currentPlayer
    })

    local actionType = commandPayload and commandPayload.actionType or "unknown"
    if ok then
        print(string.format("[OnlineGameplay] ACTION_PROPOSE action=%s seq=%s", tostring(actionType), tostring(result)))
    else
        print(string.format("[OnlineGameplay] ACTION_PROPOSE_FAILED action=%s reason=%s", tostring(actionType), tostring(result)))
        local shouldFailSafe = result == "peer_missing"
            or result == "send_failed"
            or result == "send_bridge_call_failed"
            or result == "lockstep_aborted"
            or (not onlineSession)
            or (onlineSession and onlineSession.active ~= true)
        if shouldFailSafe then
            returnBrokenOnlineMatchToMainMenu(tostring(result or "command_propose_failed"))
        end
    end

    return ok, result
end

local function isResumeCheckpointAction(actionType)
    if not actionType then
        return false
    end
    return actionType == "end_turn"
        or actionType == "confirmCommandHub"
        or actionType == "confirmDeployment"
        or actionType == "placeAllNeutralBuildings"
end

local function executeOrQueueCommand(commandPayload)
    if isOnlineModeActive() and type(commandPayload) == "table" then
        local actionType = tostring(commandPayload.actionType or "")
        if actionType ~= "" then
            sendOnlinePreviewClearIfNeeded("command_" .. actionType)
        end
    end

    if isOnlineModeActive() then
        return proposeOnlineCommand(commandPayload)
    end
    local ok = executeLocalCommand(commandPayload)
    if ok and isResumeSupportedMode() then
        if gameRuler and gameRuler.currentPhase == "gameOver" then
            clearResumeSnapshot("game_over")
        else
            local actionType = commandPayload and commandPayload.actionType or nil
            local checkpoint = isResumeCheckpointAction(actionType)
            markResumeDirty(checkpoint and ("checkpoint_" .. tostring(actionType)) or "local_action")
            if checkpoint then
                flushResumeSnapshotIfStable("checkpoint_" .. tostring(actionType), { forceInterval = true })
            end
        end
    end
    return ok, ok and nil or "local_command_failed"
end

local function requestSurrenderFromUi()
    if not gameRuler then
        return false
    end

    local surrenderingPlayer = GAME.getLocalFactionId() or gameRuler.currentPlayer or 1

    if isOnlineModeActive() then
        local ok, err = executeOrQueueCommand({
            actionType = "surrender",
            params = {
                surrenderingPlayer = surrenderingPlayer
            }
        })

        if ok then
            clearActiveUnitSelection()
            return true
        end

        print(string.format("[OnlineGameplay] SURRENDER_REQUEST_FAILED reason=%s", tostring(err)))
        if isOnlineGameplaySessionUnhealthy() or tostring(err or "") == "peer_missing" or tostring(err or "") == "send_failed" then
            if not finalizeBrokenOnlineMatchIfPossible("surrender_failed", tostring(err or "surrender_failed")) then
                returnBrokenOnlineMatchToMainMenu(tostring(err or "surrender_failed"))
            end
        end
        return false
    end

    local winner = gameRuler:getOpponentPlayer()
    gameRuler:addLogEntryString("P" .. tostring(surrenderingPlayer) .. " call M.O.M. P" .. tostring(winner) .. " wins!")
    gameRuler.winner = winner
    gameRuler.lastVictoryReason = "surrender"
    gameRuler:setPhase("gameOver")
    return true
end

local function requestOnlineReactionFromUi(reactionId)
    if not isOnlineModeActive() or not onlineLockstep or not gameRuler then
        return false
    end

    local phaseInfo = type(gameRuler.getCurrentPhaseInfo) == "function" and gameRuler:getCurrentPhaseInfo() or nil
    if not phaseInfo or phaseInfo.currentPhase ~= "turn" or phaseInfo.turnPhaseName ~= "actions" then
        return false
    end

    if isCurrentTurnLocallyControlled() then
        return false
    end

    local reactionKey = tostring(reactionId or "")
    if reactionKey == "" then
        return false
    end

    local senderFaction = GAME.getLocalFactionId and GAME.getLocalFactionId() or nil
    if senderFaction ~= 1 and senderFaction ~= 2 then
        for factionId = 1, 2 do
            if GAME.isFactionControlledLocally and GAME.isFactionControlledLocally(factionId) then
                senderFaction = factionId
                break
            end
        end
    end
    if senderFaction ~= 1 and senderFaction ~= 2 then
        return false
    end

    local senderName = GAME.getFactionControllerNickname and GAME.getFactionControllerNickname(senderFaction) or nil
    local ok, err = onlineLockstep:sendReactionSignal({
        reactionId = reactionKey,
        senderFaction = senderFaction,
        senderName = senderName,
        senderUserId = onlineSession and onlineSession.localUserId or nil
    })

    if not ok then
        print(string.format("[OnlineGameplay] REACTION_SEND_FAILED reaction=%s reason=%s", tostring(reactionKey), tostring(err)))
        return false
    end

    if ui and ui.setOnlineReactionCooldown then
        ui:setOnlineReactionCooldown(ONLINE_REACTION_COOLDOWN_SEC)
    end

    if ui and ui.showOnlineReactionNotification then
        ui:showOnlineReactionNotification({
            reactionId = reactionKey,
            senderFaction = senderFaction,
            senderName = senderName,
            senderUserId = onlineSession and onlineSession.localUserId or nil
        })
    end

    print(string.format("[OnlineGameplay] REACTION_SENT reaction=%s senderFaction=%s", tostring(reactionKey), tostring(senderFaction)))
    return true
end

local function emitOnlineTurnTelemetry(onlinePaused)
    if not isOnlineModeActive() or not gameRuler or not onlineSession then
        return
    end

    local key = table.concat({
        tostring(gameRuler.currentPlayer),
        tostring(isCurrentTurnLocallyControlled()),
        tostring(onlineSession.connected == true),
        tostring(onlinePaused == true),
        tostring(gameRuler.currentPhase or "-")
    }, "|")

    if key ~= onlineTurnTelemetryKey then
        onlineTurnTelemetryKey = key
        print(string.format(
            "[OnlineGameplay] TURN_OWNER player=%s localTurn=%s connected=%s paused=%s phase=%s",
            tostring(gameRuler.currentPlayer),
            tostring(isCurrentTurnLocallyControlled()),
            tostring(onlineSession.connected == true),
            tostring(onlinePaused == true),
            tostring(gameRuler.currentPhase or "-")
        ))
    end
end

local function processOnlineLockstepEvents(dt)
    if not isOnlineModeActive() or not gameRuler then
        return
    end

    local consumedLobbyEvents = consumePendingOnlineGameplayLobbyEvents()
    if not isOnlineModeActive() or not gameRuler then
        return
    end

    if consumedLobbyEvents and gameRuler.currentPhase == "gameOver" then
        return
    end

    if gameRuler.currentPhase ~= "gameOver" and isOnlineGameplaySessionUnhealthy() then
        if not finalizeBrokenOnlineMatchIfPossible("session_sanity_guard", "session_invalid") then
            returnBrokenOnlineMatchToMainMenu("session_invalid")
        end
        return
    end

    local gameOverPhase = gameRuler.currentPhase == "gameOver"

    if remotePreviewActive then
        local context = buildPreviewContext()
        if gameOverPhase or isCurrentTurnLocallyControlled() or not isTurnActionsContext(context) then
            clearRemotePreviewVisual("context_changed")
        end
    end

    if not gameOverPhase then
        local usesSnapshotAuthority = onlineSession.lobbyId and not onlineSession.matchStarted
        if usesSnapshotAuthority then
            local snapshot = steamRuntime.getLobbySnapshot(onlineSession.lobbyId)
            if snapshot then
                local wasConnected = onlineSession.connected
                onlineSession:applyLobbySnapshot(snapshot)
                if wasConnected and not onlineSession.connected then
                    onlineSession:markDisconnected("peer_transport_lost")
                    onlineReconnectNotified = false
                elseif (not wasConnected) and onlineSession.connected then
                    onlineSession:markReconnected(onlineSession.peerUserId)
                    onlineReconnectNotified = false
                end
            end
        elseif onlineSession.matchStarted and onlineSession.connected and onlineSession.isPeerTrafficStale then
            local now = getOnlineNowSeconds()
            local staleAllowed = (onlineMatchTrafficGraceUntil == nil) or (now >= onlineMatchTrafficGraceUntil)
            if staleAllowed and onlineSession:isPeerTrafficStale(ONLINE_TRAFFIC_STALE_SEC) then
                onlineSession:markDisconnected("peer_traffic_stale")
                onlineReconnectNotified = false
                print(string.format("[OnlineGameplay] Peer traffic stale for %.2fs; entering reconnect window", ONLINE_TRAFFIC_STALE_SEC))
            end
        end

        local timeoutStatus = onlineSession:update()
        if timeoutStatus == "timeout" then
            local winnerFaction = resolveTimeoutForfeitWinnerFaction()
            if winnerFaction then
                local localFaction = GAME.getLocalFactionId() or gameRuler.currentPlayer or 1
                local localWon = winnerFaction == localFaction
                print(string.format(
                    "[OnlineGameplay] Reconnect timeout resolved: winnerFaction=%s localFaction=%s",
                    tostring(winnerFaction),
                    tostring(localFaction)
                ))
                local timeoutMessage = localWon
                    and "ONLINE FORFEIT WIN: opponent disconnected (timeout)"
                    or "ONLINE FORFEIT LOSS: local disconnected (timeout)"
                finalizeOnlineMatchEnd("timeout_forfeit", {
                    setGameOver = true,
                    winnerFaction = winnerFaction,
                    logLine = timeoutMessage,
                    applyElo = true,
                    leaveSession = true
                })
            else
                print("[OnlineGameplay] Reconnect timeout resolved without deterministic winner; aborting match")
                finalizeOnlineMatchEnd("aborted_disconnect", {
                    setGameOver = true,
                    winnerFaction = nil,
                    logLine = "ONLINE MATCH ABORTED: reconnect timeout",
                    applyElo = false,
                    leaveSession = true
                })
            end
            return
        end

        onlineHeartbeatElapsed = onlineHeartbeatElapsed + (dt or 0)
        if onlineHeartbeatElapsed >= (SETTINGS.STEAM_ONLINE.HEARTBEAT_SEC or 1) then
            onlineHeartbeatElapsed = 0
            onlineLockstep:sendPacket({
                kind = "HEARTBEAT",
                timestamp = love.timer.getTime()
            }, SETTINGS.STEAM_ONLINE.PACKET_CHANNEL_CONTROL or 2)
        end
    end

    onlineLockstep:update()

    while true do
        local event = onlineLockstep:pollEvent()
        if not event then
            break
        end

        if event.kind == "apply_command" then
            if remotePreviewActive then
                clearRemotePreviewVisual("command_apply")
            end
            local payload = event.payload or {}
            local command = payload.command
            local commandAction = command and command.actionType or "unknown"
            local beforePlayer = gameRuler and gameRuler.currentPlayer or nil
            local success, applyResult = applyOnlineCommand(command)
            print(string.format(
                "[OnlineGameplay] ACTION_APPLY commandId=%s proposer=%s seq=%s source=%s action=%s success=%s",
                tostring(payload.commandId),
                tostring(payload.proposerId),
                tostring(payload.seq),
                tostring(payload.source),
                tostring(commandAction),
                tostring(success == true)
            ))

            if payload.commandId or payload.seq then
                local signature = gameRuler and gameRuler:getDeterministicStateSignature() or nil
                if signature then
                    onlineLockstep:reportLocalStateHash(payload.commandId or payload.seq, signature)
                end
            end

            if success then
                if commandAction == "end_turn" then
                    local afterPlayer = gameRuler and gameRuler.currentPlayer or nil
                    print(string.format(
                        "[OnlineGameplay] TURN_HANDOFF prev=%s next=%s localTurn=%s",
                        tostring(beforePlayer),
                        tostring(afterPlayer),
                        tostring(isCurrentTurnLocallyControlled())
                    ))
                end
            else
                local commandParams = (command and type(command.params) == "table") and command.params or {}
                print(string.format(
                    "[OnlineGameplay] ACTION_APPLY_REJECTED commandId=%s proposer=%s seq=%s action=%s reason=%s row=%s col=%s unitIndex=%s",
                    tostring(payload.commandId),
                    tostring(payload.proposerId),
                    tostring(payload.seq),
                    tostring(commandAction),
                    tostring(applyResult),
                    tostring(commandParams.row),
                    tostring(commandParams.col),
                    tostring(commandParams.unitIndex)
                ))
            end
        elseif event.kind == "action_rejected" then
            if isOnlineModeActive() then
                onlineAutoAdvanceState.issuedKey = nil
                onlineAutoAdvanceState.candidateSince = getOnlineNowSeconds()
            end
            print(string.format(
                "[OnlineGameplay] ACTION_REJECTED seq=%s reason=%s",
                tostring(event.payload and event.payload.seq),
                tostring(event.payload and event.payload.reason)
            ))
        elseif event.kind == "draw_proposed" then
            ConfirmDialog.show(
                "Remote player offered a draw. Accept?",
                function()
                    onlineLockstep:voteDraw(true)
                    return true
                end,
                function()
                    onlineLockstep:voteDraw(false)
                    return false
                end
            )
        elseif event.kind == "draw_accepted" then
            gameRuler.winner = 0
            gameRuler.lastVictoryReason = "draw"
            gameRuler.drawGame = true
            gameRuler:addLogEntryString("ONLINE DRAW ACCEPTED")
            gameRuler:setPhase("gameOver")
            GAME.CURRENT.ONLINE.resultCode = "draw_agreed"
        elseif event.kind == "draw_rejected" then
            gameRuler:addLogEntryString("ONLINE DRAW REJECTED")
        elseif event.kind == "aborted" then
            local abortReason = tostring(event.payload and event.payload.reason or "unknown")
            gameRuler.winner = nil
            gameRuler.lastVictoryReason = nil
            gameRuler.drawGame = false
            gameRuler:addLogEntryString("ONLINE MATCH ABORTED: " .. abortReason)
            gameRuler:setPhase("gameOver")

            if abortReason == "command_apply_failed" then
                GAME.CURRENT.ONLINE.resultCode = "aborted_command_apply_failed"
            else
                GAME.CURRENT.ONLINE.resultCode = "aborted_desync"
            end
        elseif event.kind == "preview_select" then
            applyRemotePreviewSelect(event.payload)
        elseif event.kind == "preview_clear" then
            clearRemotePreviewVisual("remote_clear")
        elseif event.kind == "reaction_received" then
            if ui and ui.showOnlineReactionNotification then
                ui:showOnlineReactionNotification(event.payload)
            end
        elseif event.kind == "peer_rejoin_requested" then
            onlineSession:markReconnected(onlineSession.peerUserId)
        end
    end

    if gameRuler:consumeOnlineDrawOfferPending() and onlineSession.role == "host" then
        ConfirmDialog.show(
            "Stalemate detected. Offer draw to opponent?",
            function()
                onlineLockstep:proposeDraw(gameRuler.currentTurn)
                return true
            end,
            function()
                return false
            end
        )
    end

    closeOnlineSessionAfterGameOverIfNeeded("gameplay_game_over")

    local onlinePaused = isOnlineModeActive() and onlineSession and (not onlineSession.connected) and gameRuler and gameRuler.currentPhase ~= "gameOver"
    emitOnlineTurnTelemetry(onlinePaused)
end

local function clampNumber(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function resolveOnlineRatingContext()
    local context = (onlineSession and onlineSession.preMatchRatingContext)
        or (GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.preMatchRatingContext)
        or nil
    return type(context) == "table" and context or nil
end

local function resolveLocalAndOpponentRatingProfiles()
    local context = resolveOnlineRatingContext()
    local role = (onlineSession and onlineSession.role) or (GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.role) or "host"
    local localProfile, opponentProfile = glicko2.resolveLocalAndOpponentProfiles(context, role)
    local defaultRating = (((SETTINGS.RATING or SETTINGS.ELO) or {}).DEFAULT_RATING) or 1200

    if not localProfile then
        localProfile = glicko2.newProfile(defaultRating)
    end
    if not opponentProfile then
        opponentProfile = glicko2.newProfile(defaultRating)
    end

    return localProfile, opponentProfile, context
end

local function resolveOnlineResultScore()
    local resultCode = GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.resultCode or nil
    local localFaction = GAME.getLocalFactionId() or 1

    if resultCode == "aborted_desync" or resultCode == "aborted_disconnect" or resultCode == "aborted_command_apply_failed" then
        return nil, nil, resultCode
    end

    if gameRuler.winner == nil then
        return nil, nil, resultCode or "aborted_no_winner"
    end

    if gameRuler.winner == 0 then
        return 0.5, 0.5, resultCode or "draw"
    end

    if gameRuler.winner == localFaction then
        return 1.0, 0.0, resultCode or "win"
    end

    return 0.0, 1.0, resultCode or "loss"
end

applyOnlineEloUpdateIfNeeded = function()
    if onlineEloApplied then
        return
    end

    if not isOnlineModeActive() or not gameRuler or gameRuler.currentPhase ~= "gameOver" then
        return
    end

    local localScore, opponentScore, resultCode = resolveOnlineResultScore()
    local localOldProfile, opponentOldProfile, ratingContext = resolveLocalAndOpponentRatingProfiles()
    local role = (onlineSession and onlineSession.role) or (GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.role) or "host"
    local localGuard = ratingContext and ((role == "guest" and ratingContext.guestGuard) or ratingContext.hostGuard) or nil
    local opponentGuard = ratingContext and ((role == "guest" and ratingContext.hostGuard) or ratingContext.guestGuard) or nil
    local matchDay = (ratingContext and tonumber(ratingContext.matchDay)) or glicko2.currentDay()

    local summary = {
        resultCode = resultCode or "unknown",
        localOld = math.floor((tonumber(localOldProfile.rating) or 0) + 0.5),
        opponentOld = math.floor((tonumber(opponentOldProfile.rating) or 0) + 0.5),
        localNew = math.floor((tonumber(localOldProfile.rating) or 0) + 0.5),
        opponentNew = math.floor((tonumber(opponentOldProfile.rating) or 0) + 0.5),
        localDelta = 0,
        opponentDelta = 0,
        localRdOld = math.floor((tonumber(localOldProfile.rd) or 0) + 0.5),
        localRdNew = math.floor((tonumber(localOldProfile.rd) or 0) + 0.5),
        opponentRdOld = math.floor((tonumber(opponentOldProfile.rd) or 0) + 0.5),
        opponentRdNew = math.floor((tonumber(opponentOldProfile.rd) or 0) + 0.5),
        uploaded = false,
        ranked = ratingContext and ratingContext.ranked ~= false or true,
        ratingReason = ratingContext and tostring(ratingContext.reason or "ranked") or "ranked"
    }

    local canResolveMatchResult = localScore ~= nil and opponentScore ~= nil
    local shouldUpdateRating = canResolveMatchResult and summary.ranked ~= false
    local ratingSettings = ((SETTINGS.RATING or SETTINGS.ELO) or {})
    if resultCode == "draw" and ratingSettings.UPDATE_ON_DRAW == false then
        shouldUpdateRating = false
    elseif resultCode == "aborted_desync" and ratingSettings.UPDATE_ON_DESYNC_ABORT == false then
        shouldUpdateRating = false
    elseif resultCode == "timeout_forfeit" and ratingSettings.UPDATE_ON_TIMEOUT_FORFEIT == false then
        shouldUpdateRating = false
    end

    local shouldPersistGuardOnly = canResolveMatchResult and shouldUpdateRating == false and resultCode ~= "aborted_desync" and resultCode ~= "aborted_disconnect" and resultCode ~= "aborted_command_apply_failed"
    local peerUserId = onlineSession and onlineSession.peerUserId or nil
    local localUserId = onlineSession and onlineSession.localUserId or (steamRuntime.getLocalUserId and steamRuntime.getLocalUserId()) or nil

    if shouldUpdateRating then
        local updatedLocal, localResult = glicko2.computeNextProfile(localOldProfile, opponentOldProfile, localScore, {
            ranked = true,
            reason = summary.ratingReason,
            currentDay = matchDay,
            opponentId = peerUserId,
            opponentHash = localGuard and localGuard.opponentHash or nil,
            countGame = false
        })
        local updatedOpponent, opponentResult = glicko2.computeNextProfile(opponentOldProfile, localOldProfile, opponentScore, {
            ranked = true,
            reason = summary.ratingReason,
            currentDay = matchDay,
            opponentId = localUserId,
            opponentHash = opponentGuard and opponentGuard.opponentHash or nil,
            countGame = false
        })

        summary.localNew = localResult.localNew
        summary.opponentNew = opponentResult.localNew
        summary.localDelta = localResult.localDelta
        summary.opponentDelta = opponentResult.localDelta
        summary.localRdNew = localResult.localRdNew
        summary.opponentRdNew = opponentResult.localRdNew

        local stats = achievementDefs.STATS or {}
        local statsChanged = false
        if localScore == 1.0 then
            local winsValue = incrementSteamStatValue(stats.ONLINE_MATCHES_WON, 1)
            if winsValue ~= nil then
                statsChanged = true
            end
        end

        statsChanged = syncOnlineRatingProgress(updatedLocal) or statsChanged

        local saveOk = onlineRatingStore.saveProfile(updatedLocal)
        if saveOk ~= true then
            print("[Rating] failed to persist updated online rating profile")
        end

        if statsChanged then
            storeSteamStats()
        end

        local leaderboardName = (((SETTINGS.RATING or SETTINGS.ELO) or {}).LEADERBOARD_NAME) or "global_glicko2_v1"
        steamRuntime.findOrCreateLeaderboard(leaderboardName, "descending", "numeric")
        summary.uploaded = steamRuntime.uploadLeaderboardScore(
            leaderboardName,
            tonumber(localResult.displayScore) or summary.localNew,
            {
                result = summary.resultCode,
                delta = summary.localDelta,
                rd = summary.localRdNew,
                ranked = 1
            },
            true
        )
    elseif shouldPersistGuardOnly then
        local updatedLocal = select(1, glicko2.computeNextProfile(localOldProfile, opponentOldProfile, localScore, {
            ranked = false,
            reason = summary.ratingReason,
            currentDay = matchDay,
            opponentId = peerUserId,
            opponentHash = localGuard and localGuard.opponentHash or nil,
            countGame = false
        }))
        local saveOk = onlineRatingStore.saveProfile(updatedLocal)
        if saveOk ~= true then
            print("[Rating] failed to persist unrated online guard update")
        end
    end

    GAME.CURRENT.ONLINE.eloSummary = summary
    GAME.CURRENT.ONLINE.preMatchRatingContext = ratingContext
    onlineEloSummaryVisible = true
    onlineEloCloseButtonBounds = nil
    if stateMachineRef and stateMachineRef.resetTransientInputs then
        stateMachineRef.resetTransientInputs("online_elo_summary_show")
    end
    onlineEloApplied = true
end

local function hasVisibleOnlineEloSummary()
    if onlineEloSummaryVisible ~= true then
        return false
    end

    local online = GAME.CURRENT and GAME.CURRENT.ONLINE or nil
    return online ~= nil and online.eloSummary ~= nil
end


local function ensureGameOverUIFocus(panelVisible)
    if not ui or not gameRuler or gameRuler.currentPhase ~= "gameOver" or not ui.gameOverPanel then
        return false
    end

    local resultsVisible = panelVisible
    if resultsVisible == nil then
        resultsVisible = ui.gameOverPanel.visible ~= false
    end

    local validNames = {}
    if resultsVisible then
        validNames.mainMenuButton = true
        validNames.toggleButton = true
    else
        validNames.returnButton = true
        validNames.gameLogPanel = true
    end

    ui.navigationMode = "ui"
    ui.uIkeyboardNavigationActive = true
    ui.keyboardNavInitiated = false

    local activeName = ui.activeUIElement and ui.activeUIElement.name or nil
    if activeName and validNames[activeName] then
        if ui.syncKeyboardAndMouseFocus then
            ui:syncKeyboardAndMouseFocus()
        end
        return false
    end

    if ui.initializeUIElements then
        ui:initializeUIElements()
    end

    local preferredName = resultsVisible and "mainMenuButton" or "returnButton"
    local fallbackName = resultsVisible and "toggleButton" or "gameLogPanel"

    local selectedIndex = nil
    local selectedElement = nil
    for index, element in ipairs(ui.uiElements or {}) do
        if element and element.name == preferredName then
            selectedIndex = index
            selectedElement = element
            break
        end
    end
    if not selectedIndex then
        for index, element in ipairs(ui.uiElements or {}) do
            if element and element.name == fallbackName then
                selectedIndex = index
                selectedElement = element
                break
            end
        end
    end

    if not selectedIndex then
        return false
    end

    ui.currentUIElementIndex = selectedIndex
    ui.activeUIElement = selectedElement
    if ui.syncKeyboardAndMouseFocus then
        ui:syncKeyboardAndMouseFocus()
    end
    return true
end

local function dismissOnlineEloSummary(reason)
    if not hasVisibleOnlineEloSummary() then
        return false
    end
    onlineEloSummaryVisible = false
    onlineEloCloseButtonBounds = nil
    ensureGameOverUIFocus(true)
    print(string.format("[OnlineGameplay] rating summary dismissed (%s)", tostring(reason or "unknown")))
    return true
end

local function isEloSummaryCloseKey(key)
    return key == "escape" or key == "return" or key == "space"
end

local function drawOnlineEloSummary()
    if gameMode ~= GAME.MODE.MULTYPLAYER_NET or not gameRuler or gameRuler.currentPhase ~= "gameOver" then
        return
    end

    local summary = GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.eloSummary or nil
    if not summary then
        onlineEloSummaryVisible = false
        onlineEloCloseButtonBounds = nil
        return
    end

    if onlineEloSummaryVisible ~= true then
        onlineEloCloseButtonBounds = nil
        return
    end

    local panelWidth = 560
    local panelHeight = 214
    local x = (SETTINGS.DISPLAY.WIDTH - panelWidth) / 2
    local y = (SETTINGS.DISPLAY.HEIGHT - panelHeight) / 2

    love.graphics.setColor(0.08, 0.08, 0.1, 0.86)
    love.graphics.rectangle("fill", x, y, panelWidth, panelHeight, 8, 8)
    love.graphics.setColor(0.95, 0.9, 0.75, 0.95)
    love.graphics.rectangle("line", x, y, panelWidth, panelHeight, 8, 8)
    love.graphics.printf("ONLINE RATING UPDATE", x, y + 16, panelWidth, "center")

    local modeText = summary.ranked == false
        and string.format("Mode: Unranked (%s)", tostring(summary.ratingReason or "policy"))
        or "Mode: Ranked"
    local detailsText = string.format(
        "Result: %s\n%s\nYou: %d -> %d (%+d) | RD %d -> %d\nOpponent: %d -> %d (%+d) | RD %d -> %d",
        tostring(summary.resultCode or "n/a"),
        modeText,
        tonumber(summary.localOld or 0),
        tonumber(summary.localNew or 0),
        tonumber(summary.localDelta or 0),
        tonumber(summary.localRdOld or 0),
        tonumber(summary.localRdNew or 0),
        tonumber(summary.opponentOld or 0),
        tonumber(summary.opponentNew or 0),
        tonumber(summary.opponentDelta or 0),
        tonumber(summary.opponentRdOld or 0),
        tonumber(summary.opponentRdNew or 0)
    )
    love.graphics.setColor(0.95, 0.9, 0.75, 0.95)
    love.graphics.printf(detailsText, x + 12, y + 52, panelWidth - 24, "center")

    local closeWidth = 140
    local closeHeight = 36
    local closeX = x + (panelWidth - closeWidth) / 2
    local closeY = y + panelHeight - closeHeight - 14
    onlineEloCloseButtonBounds = {
        x = closeX,
        y = closeY,
        width = closeWidth,
        height = closeHeight
    }

    local mouseX, mouseY = love.mouse.getPosition()
    local transformedMouseX, transformedMouseY = transformMousePosition(mouseX, mouseY)
    local hovered = transformedMouseX >= closeX and transformedMouseX <= closeX + closeWidth and
        transformedMouseY >= closeY and transformedMouseY <= closeY + closeHeight
    local focused = true -- Rating modal is strict: this is always the active control.

    if hovered then
        love.graphics.setColor(0.32, 0.32, 0.38, 0.97)
    elseif focused then
        love.graphics.setColor(0.27, 0.27, 0.33, 0.94)
    else
        love.graphics.setColor(0.2, 0.2, 0.24, 0.9)
    end
    love.graphics.rectangle("fill", closeX, closeY, closeWidth, closeHeight, 6, 6)
    if focused then
        love.graphics.setColor(0.98, 0.92, 0.72, 1)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", closeX, closeY, closeWidth, closeHeight, 6, 6)
        love.graphics.setLineWidth(1)
    else
        love.graphics.setColor(0.95, 0.9, 0.75, 0.95)
        love.graphics.rectangle("line", closeX, closeY, closeWidth, closeHeight, 6, 6)
    end
    love.graphics.setColor(0.95, 0.9, 0.75, 0.95)
    love.graphics.printf("Close", closeX, closeY + 10, closeWidth, "center")
end

local function handleOnlineEloSummaryClick(transformedX, transformedY)
    if not hasVisibleOnlineEloSummary() then
        return false
    end
    local button = onlineEloCloseButtonBounds
    if button and transformedX >= button.x and transformedX <= button.x + button.width and
       transformedY >= button.y and transformedY <= button.y + button.height then
        dismissOnlineEloSummary("mouse_close")
        return true
    end
    -- Keep this modal while visible to avoid accidental actions below it.
    return true
end

local function isUnitCodexToggleKey(key)
    return key == UNIT_CODEX_TOGGLE_KEY
end

local function canShowUnitCodexOverlay()
    return gameRuler ~= nil and gameRuler.currentPhase ~= "gameOver"
end

local function hasVisibleUnitCodexOverlay()
    return unitCodexVisible == true and canShowUnitCodexOverlay()
end

local getUnitCodexBaseFaction

local function closeUnitCodexOverlay(reason)
    unitCodexVisible = false
    unitCodexCloseButtonBounds = nil
    unitCodexToggleButtonBounds = nil
    unitCodexDisplayFaction = nil
    unitCodexTransitionElapsed = UNIT_CODEX_TRANSITION_SEC
    unitCodexTransitionDirection = 0
    unitCodexTransitionFromFaction = nil
    unitCodexMouseHover.open = false
    unitCodexMouseHover.toggle = false
    unitCodexMouseHover.close = false
    enteredFromResumeSnapshot = false
    matchCompletionAchievementsRecorded = false
    unitCodexFocusedButton = "close"
    if stateMachineRef and stateMachineRef.resetTransientInputs then
        stateMachineRef.resetTransientInputs("unit_codex_close")
    end
    if not canShowUnitCodexOverlay() then
        return false
    end
    return true
end

local function toggleUnitCodexOverlay(reason)
    if hasVisibleUnitCodexOverlay() then
        return closeUnitCodexOverlay(reason or "toggle_close")
    end
    if not canShowUnitCodexOverlay() then
        return false
    end
    unitCodexVisible = true
    unitCodexCloseButtonBounds = nil
    unitCodexToggleButtonBounds = nil
    unitCodexDisplayFaction = getUnitCodexBaseFaction()
    unitCodexTransitionElapsed = UNIT_CODEX_TRANSITION_SEC
    unitCodexTransitionDirection = 0
    unitCodexTransitionFromFaction = nil
    unitCodexMouseHover.open = false
    unitCodexMouseHover.toggle = false
    unitCodexMouseHover.close = false
    unitCodexFocusedButton = "close"
    if stateMachineRef and stateMachineRef.resetTransientInputs then
        stateMachineRef.resetTransientInputs("unit_codex_open")
    end
    return true
end

getUnitCodexBaseFaction = function()
    if gameMode == GAME.MODE.MULTYPLAYER_NET then
        local localFaction = GAME.getLocalFactionId and GAME.getLocalFactionId() or nil
        if localFaction == 1 or localFaction == 2 then
            return localFaction
        end
    elseif gameMode == GAME.MODE.SINGLE_PLAYER or gameMode == GAME.MODE.SCENARIO then
        local localFaction = GAME.getLocalFactionId and GAME.getLocalFactionId() or nil
        if localFaction == 1 or localFaction == 2 then
            return localFaction
        end
    end

    if gameRuler and (gameRuler.currentPlayer == 1 or gameRuler.currentPlayer == 2) then
        return gameRuler.currentPlayer
    end

    return 1
end

local function getUnitCodexDisplayFaction()
    if unitCodexDisplayFaction == 1 or unitCodexDisplayFaction == 2 then
        return unitCodexDisplayFaction
    end
    return getUnitCodexBaseFaction()
end

local function getUnitCodexFactionName(factionId)
    return factionId == 2 and "RED" or "BLUE"
end

local function getUnitCodexToggleButtonLabel()
    return "SHOW OTHER FACTION"
end

local function setUnitCodexFocusedButton(buttonName)
    if buttonName == "toggleFaction" or buttonName == "close" then
        unitCodexFocusedButton = buttonName
    end
end

local function moveUnitCodexFocusedButton(direction)
    local previousFocus = unitCodexFocusedButton
    if direction == "up" then
        setUnitCodexFocusedButton("toggleFaction")
    elseif direction == "down" then
        setUnitCodexFocusedButton("close")
    else
        return false
    end

    if previousFocus ~= unitCodexFocusedButton and ui and ui.playButtonBeep then
        ui:playButtonBeep()
    end
    return true
end

local function switchUnitCodexFaction(reason)
    if not hasVisibleUnitCodexOverlay() then
        return false
    end
    local currentFaction = getUnitCodexDisplayFaction()
    local nextFaction = currentFaction == 1 and 2 or 1
    unitCodexTransitionFromFaction = currentFaction
    unitCodexDisplayFaction = nextFaction
    unitCodexTransitionElapsed = 0
    unitCodexTransitionDirection = nextFaction == 1 and -1 or 1
    setUnitCodexFocusedButton("toggleFaction")
    if stateMachineRef and stateMachineRef.resetTransientInputs then
        stateMachineRef.resetTransientInputs("unit_codex_switch_faction")
    end
    return true
end

local function buildUnitCodexCounts(factionId)
    local counts = {}
    for _, unitName in ipairs(UNIT_CODEX_UNIT_ORDER) do
        counts[unitName] = 0
    end

    if not gameRuler then
        return counts
    end

    factionId = factionId or getUnitCodexDisplayFaction()
    local supplies = (gameRuler.playerSupplies and gameRuler.playerSupplies[factionId]) or {}
    local supplyHasCommandant = false
    for _, unit in ipairs(supplies) do
        local unitName = unit and unit.name or nil
        if unitName and counts[unitName] ~= nil then
            counts[unitName] = counts[unitName] + 1
            if unitName == "Commandant" then
                supplyHasCommandant = true
            end
        end
    end

    local cells = grid and grid.cells or nil
    if type(cells) == "table" then
        for _, rowCells in pairs(cells) do
            if type(rowCells) == "table" then
                for _, cell in pairs(rowCells) do
                    local unit = cell and cell.unit or nil
                    local unitName = unit and unit.name or nil
                    if unitName and counts[unitName] ~= nil and tonumber(unit.player) == factionId then
                        counts[unitName] = counts[unitName] + 1
                    end
                end
            end
        end
    end

    local tempHub = gameRuler.tempCommandHubPosition and gameRuler.tempCommandHubPosition[factionId] or nil
    if tempHub and supplyHasCommandant and counts.Commandant and counts.Commandant > 0 then
        counts.Commandant = counts.Commandant - 1
    end

    return counts
end

local function ensureUnitCodexFonts()
    if unitCodexTitleFont and unitCodexBadgeFont then
        return
    end
    local defaultFont = love.graphics.getFont()
    local defaultSize = tonumber((SETTINGS.FONT and SETTINGS.FONT.DEFAULT_SIZE) or 20) or 20
    local titleSize = math.max(defaultSize + 14, 34)
    local badgeSize = math.max(defaultSize, 18)
    local fontPath = "assets/fonts/monogram-extended.ttf"

    local okTitle, loadedTitle = pcall(love.graphics.newFont, fontPath, titleSize)
    unitCodexTitleFont = okTitle and loadedTitle or defaultFont
    local okBadge, loadedBadge = pcall(love.graphics.newFont, fontPath, badgeSize)
    unitCodexBadgeFont = okBadge and loadedBadge or defaultFont
end

local function invalidateUnitCodexGridCaches()
    unitCodexGridCaches = {}
    unitCodexTransitionFromFaction = nil
end

local function buildUnitCodexCountsSignature(counts)
    local parts = {}
    for _, unitName in ipairs(UNIT_CODEX_UNIT_ORDER) do
        parts[#parts + 1] = unitName .. ":" .. tostring(counts[unitName] or 0)
    end
    return table.concat(parts, "|")
end

local function getUnitCodexLayoutMetrics()
    local baseWidth = tonumber(SETTINGS.DISPLAY.WIDTH) or 1280
    local baseHeight = tonumber(SETTINGS.DISPLAY.HEIGHT) or 800
    local screenWidth = baseWidth
    local screenHeight = baseHeight
    local scale = tonumber(SETTINGS.DISPLAY.SCALE) or 1
    if love and love.graphics and love.graphics.getDimensions and scale > 0 then
        local windowWidth, windowHeight = love.graphics.getDimensions()
        screenWidth = math.max(baseWidth, math.floor((windowWidth / scale) + 0.5))
        screenHeight = math.max(baseHeight, math.floor((windowHeight / scale) + 0.5))
    end
    local gap = 18
    local horizontalMargin = 90
    local topMargin = 72
    local buttonStackReserve = 122
    local previewCardWidth = (ui and ui.panelWidth) or 220
    local previewCardHeight = ((ui and ui.panelHeight) or 340) - 54
    local availableWidth = math.max(1, screenWidth - horizontalMargin * 2 - gap * 3)
    local availableHeight = math.max(1, screenHeight - topMargin - buttonStackReserve - gap)
    local cardScale = math.min(1.0, availableWidth / (previewCardWidth * 4), availableHeight / (previewCardHeight * 2))
    local cardWidth = math.max(1, math.floor(previewCardWidth * cardScale))
    local cardHeight = math.max(1, math.floor(previewCardHeight * cardScale))
    local totalGridWidth = cardWidth * 4 + gap * 3
    local totalGridHeight = cardHeight * 2 + gap
    local startX = math.floor((screenWidth - totalGridWidth) / 2)
    local startY = topMargin

    return {
        screenWidth = screenWidth,
        screenHeight = screenHeight,
        gap = gap,
        previewCardWidth = previewCardWidth,
        previewCardHeight = previewCardHeight,
        cardScale = cardScale,
        cardWidth = cardWidth,
        cardHeight = cardHeight,
        totalGridWidth = totalGridWidth,
        totalGridHeight = totalGridHeight,
        startX = startX,
        startY = startY
    }
end

local function buildUnitCodexGridCache(factionId, layout, counts)
    if not love or not love.graphics or not love.graphics.newCanvas or not ui or not ui.drawInfoPanelWithCard then
        return nil
    end

    local canvas = love.graphics.newCanvas(layout.totalGridWidth, layout.totalGridHeight)
    local cards = {}

    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)

    for index, unitName in ipairs(UNIT_CODEX_UNIT_ORDER) do
        local col = (index - 1) % 4
        local row = math.floor((index - 1) / 4)
        local localX = col * (layout.cardWidth + layout.gap)
        local localY = row * (layout.cardHeight + layout.gap)
        local unitInfo = unitsInfo:getUnitInfo(unitName)
        if unitInfo then
            local cardContent = setmetatable({
                glossKey = "unitCodex_" .. tostring(factionId) .. "_" .. tostring(unitName),
                glossGroup = "unitCodexFaction_" .. tostring(factionId),
                disableGloss = true
            }, { __index = unitInfo })

            love.graphics.push()
            love.graphics.translate(localX, localY)
            love.graphics.scale(layout.cardScale, layout.cardScale)
            ui:drawInfoPanelWithCard(0, 0, layout.previewCardWidth, layout.previewCardHeight, string.upper(unitName), unitInfo, factionId, cardContent)
            love.graphics.pop()

            drawUnitCodexCountBadge(localX + layout.cardWidth, localY, counts[unitName] or 0, layout.cardScale)

            cards[#cards + 1] = {
                unitName = unitName,
                x = localX,
                y = localY,
                width = layout.cardWidth,
                height = layout.cardHeight,
                glossKey = cardContent.glossKey,
                glossGroup = cardContent.glossGroup
            }
        end
    end

    love.graphics.setCanvas()
    love.graphics.pop()

    return {
        factionId = factionId,
        signature = tostring(factionId) .. "|" .. buildUnitCodexCountsSignature(counts),
        canvas = canvas,
        layout = layout,
        cards = cards
    }
end

local function ensureUnitCodexGridCache(factionId)
    local layout = getUnitCodexLayoutMetrics()
    local counts = buildUnitCodexCounts(factionId)
    local signature = tostring(factionId) .. "|" .. buildUnitCodexCountsSignature(counts) ..
        string.format("|%d|%d|%d|%d|%d|%d|%d|%d|%.4f",
            layout.screenWidth,
            layout.screenHeight,
            layout.previewCardWidth,
            layout.previewCardHeight,
            layout.cardWidth,
            layout.cardHeight,
            layout.startX,
            layout.startY,
            layout.cardScale)

    local current = unitCodexGridCaches[factionId]
    if current and current.signature == signature and current.canvas and
        current.layout and current.layout.totalGridWidth == layout.totalGridWidth and
        current.layout.totalGridHeight == layout.totalGridHeight and
        current.layout.screenWidth == layout.screenWidth and
        current.layout.screenHeight == layout.screenHeight and
        current.layout.startX == layout.startX and
        current.layout.startY == layout.startY then
        return current
    end

    local rebuilt = buildUnitCodexGridCache(factionId, layout, counts)
    if rebuilt then
        rebuilt.signature = signature
        unitCodexGridCaches[factionId] = rebuilt
    end
    return rebuilt
end

local function drawUnitCodexGlossLayer(cache, offsetX)
    if not cache or not cache.cards or not ui or not ui.drawInfoCardGlossOverlay then
        return
    end

    for _, card in ipairs(cache.cards) do
        ui:drawInfoCardGlossOverlay(
            cache.layout.startX + card.x + (offsetX or 0),
            cache.layout.startY + card.y,
            card.width,
            card.height,
            {
                glossKey = card.glossKey,
                glossGroup = card.glossGroup
            }
        )
    end
end

local function getUnitCodexOpenButtonBounds()
    local button = ui and ui.unitCodexButton or nil
    if button then
        return {
            x = button.x,
            y = button.y,
            width = button.width,
            height = button.height
        }
    end
    return {
        x = 30,
        y = 320,
        width = 220,
        height = 34
    }
end

local function drawUnitCodexOpenButton()
    if not canShowUnitCodexOverlay() then
        unitCodexOpenButtonBounds = nil
        unitCodexMouseHover.open = false
        return
    end

    local button = getUnitCodexOpenButtonBounds()
    unitCodexOpenButtonBounds = button

    local mouseX, mouseY = love.mouse.getPosition()
    local transformedMouseX, transformedMouseY = transformMousePosition(mouseX, mouseY)
    local hovered = transformedMouseX >= button.x and transformedMouseX <= button.x + button.width and
        transformedMouseY >= button.y and transformedMouseY <= button.y + button.height
    if hasVisibleUnitCodexOverlay() then
        hovered = false
    end
    if hovered and not unitCodexMouseHover.open and ui and ui.playButtonBeep then
        ui:playButtonBeep()
    end
    unitCodexMouseHover.open = hovered

    local isFocused = ui and ui.uIkeyboardNavigationActive and ui.activeUIElement and ui.activeUIElement.name == "unitCodexButton"
    local focusVisible = isFocused and not hasVisibleUnitCodexOverlay()
    local active = hovered or focusVisible
    local colors = {
        background = {46/255, 38/255, 32/255, 0.9},
        border = active and {203/255, 183/255, 158/255, 0.9} or {108/255, 88/255, 66/255, 1},
        inner = {79/255, 62/255, 46/255, 0.9},
        text = active and {255/255, 240/255, 220/255, 1.0} or {203/255, 183/255, 158/255, 0.95}
    }

    love.graphics.setColor(colors.background)
    love.graphics.rectangle("fill", button.x, button.y, button.width, button.height)

    love.graphics.setColor(colors.border)
    love.graphics.setLineWidth(active and 3 or 2)
    love.graphics.rectangle("line", button.x, button.y, button.width, button.height)
    love.graphics.setLineWidth(1)

    love.graphics.setColor(colors.inner)
    love.graphics.rectangle("line", button.x + 3, button.y + 3, button.width - 6, button.height - 6)

    local defaultFont = love.graphics.getFont()
    local titleFont = getMonogramFont(SETTINGS.FONT.TITLE_SIZE)
    love.graphics.setFont(titleFont)
    love.graphics.setColor(colors.text)
    local textY = button.y + math.floor((button.height - titleFont:getHeight()) / 2) - 1
    love.graphics.printf(UNIT_CODEX_OPEN_LABEL, button.x, textY, button.width, "center")
    love.graphics.setFont(defaultFont)
end

drawUnitCodexCountBadge = function(x, y, count, scale)
    ensureUnitCodexFonts()
    local badgeScale = math.max(0.85, tonumber(scale) or 1)
    local badgeWidth = math.floor(44 * badgeScale)
    local badgeHeight = math.floor(24 * badgeScale)
    local badgeX = x - badgeWidth - math.floor(6 * badgeScale)
    local badgeY = y + math.floor(8 * badgeScale)
    love.graphics.setColor(0.1, 0.1, 0.12, 0.92)
    love.graphics.rectangle("fill", badgeX, badgeY, badgeWidth, badgeHeight, 6, 6)
    love.graphics.setColor(0.95, 0.9, 0.75, 0.95)
    love.graphics.rectangle("line", badgeX, badgeY, badgeWidth, badgeHeight, 6, 6)
    local defaultFont = love.graphics.getFont()
    love.graphics.setFont(unitCodexBadgeFont)
    local label = tostring((count or 0) > 99 and "99+" or (count or 0))
    local textY = badgeY + math.floor((badgeHeight - unitCodexBadgeFont:getHeight()) / 2) - 1
    love.graphics.printf(label, badgeX, textY, badgeWidth, "center")
    love.graphics.setFont(defaultFont)
end

local function drawUnitCodexOverlay()
    if not hasVisibleUnitCodexOverlay() or not ui or not ui.drawInfoPanelWithCard then
        unitCodexCloseButtonBounds = nil
        unitCodexToggleButtonBounds = nil
        unitCodexMouseHover.toggle = false
        unitCodexMouseHover.close = false
        return
    end

    ensureUnitCodexFonts()
    local defaultFont = love.graphics.getFont()
    local displayFaction = getUnitCodexDisplayFaction()
    local currentCache = ensureUnitCodexGridCache(displayFaction)
    local layout = (currentCache and currentCache.layout) or getUnitCodexLayoutMetrics()
    local screenWidth = layout.screenWidth
    local screenHeight = layout.screenHeight
    local totalGridWidth = layout.totalGridWidth
    local totalGridHeight = layout.totalGridHeight
    local startX = layout.startX
    local startY = layout.startY

    love.graphics.setColor(0, 0, 0, 0.58)
    love.graphics.rectangle("fill", 0, 0, screenWidth, screenHeight)
    love.graphics.setFont(unitCodexTitleFont)
    love.graphics.setColor(0.08, 0.07, 0.06, 0.9)
    love.graphics.printf(UNIT_CODEX_TITLE, 0, 24, screenWidth, "center")
    love.graphics.setColor(0.97, 0.92, 0.78, 0.98)
    love.graphics.printf(UNIT_CODEX_TITLE, 0, 20, screenWidth, "center")
    love.graphics.setFont(defaultFont)

    local factionColor = displayFaction == 2 and uiTheme.COLORS.redTeam or uiTheme.COLORS.blueTeam

    local progress = math.min(1, unitCodexTransitionElapsed / UNIT_CODEX_TRANSITION_SEC)
    local slideOffset = 0
    if progress < 1 then
        slideOffset = unitCodexTransitionDirection * (1 - progress) * 28
        love.graphics.setColor(factionColor[1], factionColor[2], factionColor[3], 0.09 * (1 - progress))
        love.graphics.rectangle("fill", startX - 12, startY - 12, totalGridWidth + 24, totalGridHeight + 24, 12, 12)
    end

    local transitionCache = nil
    if unitCodexTransitionFromFaction and unitCodexTransitionFromFaction ~= displayFaction then
        transitionCache = ensureUnitCodexGridCache(unitCodexTransitionFromFaction)
    end

    if transitionCache and progress < 1 then
        local outgoingOffset = slideOffset - (unitCodexTransitionDirection * 28)
        love.graphics.setColor(1, 1, 1, math.max(0, 1 - progress))
        love.graphics.draw(transitionCache.canvas, transitionCache.layout.startX + outgoingOffset, transitionCache.layout.startY)
        drawUnitCodexGlossLayer(transitionCache, outgoingOffset)
    end

    if currentCache and currentCache.canvas then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(currentCache.canvas, currentCache.layout.startX + slideOffset, currentCache.layout.startY)
        drawUnitCodexGlossLayer(currentCache, slideOffset)
    end

    local toggleButton = {
        x = math.floor((screenWidth - 260) / 2),
        y = screenHeight - 108,
        width = 260,
        height = 38
    }
    local closeButton = {
        x = math.floor((screenWidth - 160) / 2),
        y = screenHeight - 58,
        width = 160,
        height = 38
    }
    unitCodexToggleButtonBounds = toggleButton
    unitCodexCloseButtonBounds = closeButton

    local mouseX, mouseY = love.mouse.getPosition()
    local transformedMouseX, transformedMouseY = transformMousePosition(mouseX, mouseY)
    local toggleHovered = transformedMouseX >= toggleButton.x and transformedMouseX <= toggleButton.x + toggleButton.width and
        transformedMouseY >= toggleButton.y and transformedMouseY <= toggleButton.y + toggleButton.height
    local closeHovered = transformedMouseX >= closeButton.x and transformedMouseX <= closeButton.x + closeButton.width and
        transformedMouseY >= closeButton.y and transformedMouseY <= closeButton.y + closeButton.height
    if toggleHovered and not unitCodexMouseHover.toggle and ui and ui.playButtonBeep then
        ui:playButtonBeep()
    end
    if closeHovered and not unitCodexMouseHover.close and ui and ui.playButtonBeep then
        ui:playButtonBeep()
    end
    unitCodexMouseHover.toggle = toggleHovered
    unitCodexMouseHover.close = closeHovered

    if toggleHovered then
        setUnitCodexFocusedButton("toggleFaction")
    elseif closeHovered then
        setUnitCodexFocusedButton("close")
    end

    local toggleStyle = {
        x = toggleButton.x,
        y = toggleButton.y,
        width = toggleButton.width,
        height = toggleButton.height,
        text = getUnitCodexToggleButtonLabel(),
        centerText = true,
        focused = unitCodexFocusedButton == "toggleFaction"
    }
    uiTheme.applyButtonVariant(toggleStyle, "default")
    local toggleActive = toggleHovered or unitCodexFocusedButton == "toggleFaction"
    toggleStyle.currentColor = toggleActive and {toggleStyle.hoverColor[1], toggleStyle.hoverColor[2], toggleStyle.hoverColor[3], toggleStyle.hoverColor[4]} or {toggleStyle.baseColor[1], toggleStyle.baseColor[2], toggleStyle.baseColor[3], toggleStyle.baseColor[4]}
    uiTheme.drawButton(toggleStyle)

    local closeStyle = {
        x = closeButton.x,
        y = closeButton.y,
        width = closeButton.width,
        height = closeButton.height,
        text = "Close",
        centerText = true,
        focused = unitCodexFocusedButton == "close"
    }
    uiTheme.applyButtonVariant(closeStyle, "default")
    local closeActive = closeHovered or unitCodexFocusedButton == "close"
    closeStyle.currentColor = closeActive and {closeStyle.hoverColor[1], closeStyle.hoverColor[2], closeStyle.hoverColor[3], closeStyle.hoverColor[4]} or {closeStyle.baseColor[1], closeStyle.baseColor[2], closeStyle.baseColor[3], closeStyle.baseColor[4]}
    uiTheme.drawButton(closeStyle)
    love.graphics.setFont(defaultFont)
end

local function handleUnitCodexOpenButtonClick(transformedX, transformedY)
    if hasVisibleUnitCodexOverlay() or not canShowUnitCodexOverlay() then
        return false
    end
    local button = unitCodexOpenButtonBounds or getUnitCodexOpenButtonBounds()
    if button and transformedX >= button.x and transformedX <= button.x + button.width and
       transformedY >= button.y and transformedY <= button.y + button.height then
        if ui and ui.playButtonBeep then
            ui:playButtonBeep()
        end
        toggleUnitCodexOverlay("mouse_open")
        return true
    end
    return false
end

local function handleUnitCodexOverlayClick(transformedX, transformedY)
    if not hasVisibleUnitCodexOverlay() then
        return false
    end
    local toggleButton = unitCodexToggleButtonBounds
    if toggleButton and transformedX >= toggleButton.x and transformedX <= toggleButton.x + toggleButton.width and
       transformedY >= toggleButton.y and transformedY <= toggleButton.y + toggleButton.height then
        setUnitCodexFocusedButton("toggleFaction")
        if ui and ui.playButtonBeep then
            ui:playButtonBeep()
        end
        switchUnitCodexFaction("mouse_toggle")
        return true
    end
    local closeButton = unitCodexCloseButtonBounds
    if closeButton and transformedX >= closeButton.x and transformedX <= closeButton.x + closeButton.width and
       transformedY >= closeButton.y and transformedY <= closeButton.y + closeButton.height then
        setUnitCodexFocusedButton("close")
        if ui and ui.playButtonBeep then
            ui:playButtonBeep()
        end
        closeUnitCodexOverlay("mouse_close")
        return true
    end
    return true
end

local function hasVisibleMatchObjectiveModal()
    if not gameRuler or matchObjectiveModalVisible ~= true then
        return false
    end
    if gameRuler.currentPhase == "gameOver" then
        return onlineAutoAdvanceState.matchObjectiveModalState ~= nil and onlineAutoAdvanceState.matchObjectiveModalState.allowDuringGameOver == true
    end
    return true
end

onlineAutoAdvanceState.showMatchObjectiveModal = function(config)
    local modalConfig = type(config) == "table" and config or {}
    local ctaSecondary = nil
    if type(modalConfig.ctaSecondary) == "string" and modalConfig.ctaSecondary ~= "" then
        ctaSecondary = modalConfig.ctaSecondary
    end
    onlineAutoAdvanceState.matchObjectiveModalState = {
        title = type(modalConfig.title) == "string" and modalConfig.title or nil,
        body = type(modalConfig.body) == "string" and modalConfig.body or nil,
        cta = type(modalConfig.cta) == "string" and modalConfig.cta or nil,
        ctaSecondary = ctaSecondary,
        allowDuringGameOver = modalConfig.allowDuringGameOver == true,
        onDismiss = type(modalConfig.onDismiss) == "function" and modalConfig.onDismiss or nil,
        onDismissSecondary = type(modalConfig.onDismissSecondary) == "function" and modalConfig.onDismissSecondary or nil
    }
    matchObjectiveModalVisible = true
    matchObjectiveCloseButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveHoveredButton = nil
    if ctaSecondary and modalConfig.initialFocus == "secondary" then
        onlineAutoAdvanceState.matchObjectiveFocusedButton = "secondary"
    else
        onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
    end
end

onlineAutoAdvanceState.getScenarioReturnState = function()
    local configured = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO_RETURN_STATE or nil
    if type(configured) == "string" and configured ~= "" then
        return configured
    end
    return "scenarioSelect"
end

onlineAutoAdvanceState.getScenarioReturnCta = function()
    if onlineAutoAdvanceState.getScenarioReturnState() == "scenarioEditor" then
        return "Back to Editor"
    end
    return "Back to Scenario List"
end

-- SCENARIO-ONLY: restarts the same loaded scenario snapshot and increments attempts.
onlineAutoAdvanceState.restartCurrentScenarioAttempt = function()
    if not (GAME and GAME.CURRENT) then
        return
    end

    local scenarioState = GAME.CURRENT.SCENARIO
    if type(scenarioState) ~= "table" or type(scenarioState.snapshot) ~= "table" then
        if stateMachineRef and stateMachineRef.changeState then
            stateMachineRef.changeState(onlineAutoAdvanceState.getScenarioReturnState())
        end
        return
    end

    local nextAttempts = math.max(0, tonumber(scenarioState.attempts) or 0) + 1
    scenarioState.attempts = nextAttempts
    scenarioState.solved = false

    GAME.CURRENT.SCENARIO_RESULT = nil
    GAME.CURRENT.SCENARIO_REQUESTED_MODE = GAME.MODE.SCENARIO
    GAME.CURRENT.MODE = GAME.MODE.SCENARIO
    GAME.CURRENT.PENDING_RESUME_SNAPSHOT = nil
    GAME.CURRENT.RESUME_RESTART_NOTICE = nil

    if stateMachineRef and stateMachineRef.changeState then
        stateMachineRef.changeState("scenarioGameplay")
    end
end

-- SCENARIO-ONLY: shows solved/failed modal and routes back/retry behavior.
onlineAutoAdvanceState.maybeShowScenarioOutcomeModal = function()
    if gameMode ~= GAME.MODE.SCENARIO or not gameRuler or gameRuler.currentPhase ~= "gameOver" then
        return
    end
    if onlineAutoAdvanceState.scenarioOutcomeModalShown then
        return
    end

    onlineAutoAdvanceState.scenarioOutcomeModalShown = true
    local scenarioState = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    local scenarioId = scenarioState and scenarioState.id or nil
    local attempts = scenarioState and tonumber(scenarioState.attempts) or nil
    attempts = math.max(1, math.floor(attempts or 1))

    local reason = tostring(gameRuler.lastVictoryReason or "")
    local solved = tonumber(gameRuler.winner) == 1 or reason == "scenario_red_commandant_destroyed"
    local title = solved and "SOLVED" or "FAILED ATTEMPT"
    local body = solved and ("Congratulation scenario solved in " .. tostring(attempts) .. " attempts") or "Allowed turn exeeded"
    if not solved and reason == "scenario_blue_units_eliminated" then
        body = "You lost all units!"
    end

    if GAME and GAME.CURRENT then
        GAME.CURRENT.SCENARIO_RESULT = {
            id = scenarioId,
            solved = solved,
            attempts = attempts,
            reason = reason
        }
    end

    local modalConfig = {
        title = title,
        body = body,
        cta = onlineAutoAdvanceState.getScenarioReturnCta(),
        allowDuringGameOver = true,
        onDismiss = function()
            if stateMachineRef and stateMachineRef.changeState then
                stateMachineRef.changeState(onlineAutoAdvanceState.getScenarioReturnState())
            end
        end
    }
    if not solved then
        modalConfig.ctaSecondary = "Retry"
        modalConfig.onDismissSecondary = function()
            onlineAutoAdvanceState.restartCurrentScenarioAttempt()
        end
        modalConfig.initialFocus = "secondary"
    end
    onlineAutoAdvanceState.showMatchObjectiveModal(modalConfig)

    if solved then
        if ui and ui.gameOverPanel then
            ui.gameOverPanel.currentY = ui.gameOverPanel.targetY
        end
        if ui and ui.spawnConfettiBurst then
            ui:spawnConfettiBurst()
        end
    else
        if ui and ui.playUISound then
            ui:playUISound("assets/audio/SciFiNotification3.wav", SETTINGS.AUDIO.SFX_VOLUME)
        elseif SETTINGS.AUDIO.SFX then
            soundCache.play("assets/audio/SciFiNotification3.wav", {
                clone = true,
                volume = SETTINGS.AUDIO.SFX_VOLUME,
                category = "sfx"
            })
        end
    end
end

local function dismissMatchObjectiveModal(reason, action)
    if not hasVisibleMatchObjectiveModal() then
        return false
    end
    local modalState = onlineAutoAdvanceState.matchObjectiveModalState or {}
    local onDismiss = modalState.onDismiss
    local onDismissSecondary = modalState.onDismissSecondary
    matchObjectiveModalVisible = false
    matchObjectiveCloseButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
    onlineAutoAdvanceState.matchObjectiveHoveredButton = nil
    onlineAutoAdvanceState.matchObjectiveModalState = nil
    local dismissAction = action == "secondary" and "secondary" or "primary"
    print(string.format("[Gameplay] Match objective modal dismissed (%s, action=%s)", tostring(reason or "unknown"), dismissAction))
    local callback = dismissAction == "secondary" and onDismissSecondary or onDismiss
    if callback then
        local ok, dismissErr = pcall(callback, reason, dismissAction)
        if not ok then
            print(string.format("[Gameplay] Match objective dismiss callback failed: %s", tostring(dismissErr)))
        end
    end
    return true
end

local function isMatchObjectiveCloseKey(key)
    return key == "escape"
end

local function ensureObjectiveModalFonts()
    if objectiveTitleFont and objectiveBodyFont and objectiveButtonFont then
        return
    end

    local defaultFont = love.graphics.getFont()
    local defaultSize = tonumber((SETTINGS.FONT and SETTINGS.FONT.DEFAULT_SIZE) or 20) or 20
    local titleSize = math.max(tonumber((SETTINGS.FONT and SETTINGS.FONT.BIG_SIZE) or 32) or 32, defaultSize + 12)
    local bodySize = math.max(defaultSize + 4, 24)
    local buttonSize = math.max(defaultSize + 2, 22)
    local fontPath = "assets/fonts/monogram-extended.ttf"

    local okTitle, loadedTitle = pcall(love.graphics.newFont, fontPath, titleSize)
    objectiveTitleFont = okTitle and loadedTitle or defaultFont
    local okBody, loadedBody = pcall(love.graphics.newFont, fontPath, bodySize)
    objectiveBodyFont = okBody and loadedBody or defaultFont
    local okButton, loadedButton = pcall(love.graphics.newFont, fontPath, buttonSize)
    objectiveButtonFont = okButton and loadedButton or defaultFont
end

local function drawMatchObjectiveModal()
    if not hasVisibleMatchObjectiveModal() then
        matchObjectiveCloseButtonBounds = nil
        onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = nil
        return
    end

    ensureObjectiveModalFonts()
    local defaultFont = love.graphics.getFont()
    local modalState = onlineAutoAdvanceState.matchObjectiveModalState or {}

    local titleText = modalState.title or MATCH_OBJECTIVE_TITLE
    local ctaText = modalState.cta or MATCH_OBJECTIVE_CTA
    local ctaSecondaryText = nil
    if type(modalState.ctaSecondary) == "string" and modalState.ctaSecondary ~= "" then
        ctaSecondaryText = modalState.ctaSecondary
    end
    local bodyText = modalState.body or MATCH_OBJECTIVE_BODY
    if isRemotePlayLocalMode() then
        bodyText = bodyText .. "\nRemote Play Together match: online rating is not affected."
    end

    local bodyLineCount = 1
    for _ in string.gmatch(bodyText, "\n") do
        bodyLineCount = bodyLineCount + 1
    end

    local panelWidth = 620
    local panelHeight = math.max(210, 166 + (bodyLineCount * 28))
    local x = (SETTINGS.DISPLAY.WIDTH - panelWidth) / 2
    local y = (SETTINGS.DISPLAY.HEIGHT - panelHeight) / 2

    love.graphics.setColor(0.08, 0.08, 0.1, 0.9)
    love.graphics.rectangle("fill", x, y, panelWidth, panelHeight, 8, 8)
    love.graphics.setColor(0.95, 0.9, 0.75, 0.95)
    love.graphics.rectangle("line", x, y, panelWidth, panelHeight, 8, 8)
    love.graphics.setFont(objectiveTitleFont)
    love.graphics.printf(titleText, x, y + 16, panelWidth, "center")
    love.graphics.setFont(objectiveBodyFont)
    love.graphics.printf(bodyText, x + 20, y + 72, panelWidth - 40, "center")

    local closeHeight = 40
    local closeY = y + panelHeight - closeHeight - 16

    local mouseX, mouseY = love.mouse.getPosition()
    local transformedMouseX, transformedMouseY = transformMousePosition(mouseX, mouseY)
    local hoveredButtonName = nil
    local function drawModalButton(bounds, label, hovered, focused)
        if hovered or focused then
            love.graphics.setColor(0.32, 0.32, 0.38, 0.97)
        else
            love.graphics.setColor(0.2, 0.2, 0.24, 0.9)
        end
        love.graphics.rectangle("fill", bounds.x, bounds.y, bounds.width, bounds.height, 6, 6)
        love.graphics.setColor(0.98, 0.92, 0.72, 1)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", bounds.x, bounds.y, bounds.width, bounds.height, 6, 6)
        love.graphics.setLineWidth(1)
        love.graphics.setColor(0.95, 0.9, 0.75, 0.95)
        love.graphics.setFont(objectiveButtonFont)
        love.graphics.printf(label, bounds.x, bounds.y + 9, bounds.width, "center")
    end

    if ctaSecondaryText then
        local buttonWidth = 220
        local buttonGap = 16
        local totalWidth = (buttonWidth * 2) + buttonGap
        local primaryX = x + (panelWidth - totalWidth) / 2
        local secondaryX = primaryX + buttonWidth + buttonGap

        matchObjectiveCloseButtonBounds = {
            x = primaryX,
            y = closeY,
            width = buttonWidth,
            height = closeHeight
        }
        onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = {
            x = secondaryX,
            y = closeY,
            width = buttonWidth,
            height = closeHeight
        }

        local primaryHovered = transformedMouseX >= matchObjectiveCloseButtonBounds.x
            and transformedMouseX <= matchObjectiveCloseButtonBounds.x + matchObjectiveCloseButtonBounds.width
            and transformedMouseY >= matchObjectiveCloseButtonBounds.y
            and transformedMouseY <= matchObjectiveCloseButtonBounds.y + matchObjectiveCloseButtonBounds.height
        local secondaryHovered = transformedMouseX >= onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds.x
            and transformedMouseX <= onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds.x + onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds.width
            and transformedMouseY >= onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds.y
            and transformedMouseY <= onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds.y + onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds.height

        if primaryHovered then
            hoveredButtonName = "primary"
        elseif secondaryHovered then
            hoveredButtonName = "secondary"
        end

        drawModalButton(
            matchObjectiveCloseButtonBounds,
            ctaText,
            primaryHovered,
            onlineAutoAdvanceState.matchObjectiveFocusedButton ~= "secondary"
        )
        drawModalButton(
            onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds,
            ctaSecondaryText,
            secondaryHovered,
            onlineAutoAdvanceState.matchObjectiveFocusedButton == "secondary"
        )
    else
        local closeWidth = 190
        local closeX = x + (panelWidth - closeWidth) / 2
        matchObjectiveCloseButtonBounds = {
            x = closeX,
            y = closeY,
            width = closeWidth,
            height = closeHeight
        }
        onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = nil

        local hovered = transformedMouseX >= closeX and transformedMouseX <= closeX + closeWidth and
            transformedMouseY >= closeY and transformedMouseY <= closeY + closeHeight
        if hovered then
            hoveredButtonName = "primary"
        end
        drawModalButton(matchObjectiveCloseButtonBounds, ctaText, hovered, not hovered)
    end

    if hoveredButtonName ~= onlineAutoAdvanceState.matchObjectiveHoveredButton then
        if hoveredButtonName and ui and ui.playButtonBeep then
            ui:playButtonBeep()
        end
        onlineAutoAdvanceState.matchObjectiveHoveredButton = hoveredButtonName
    end

    love.graphics.setFont(defaultFont)
end

local function handleMatchObjectiveModalClick(transformedX, transformedY)
    if not hasVisibleMatchObjectiveModal() then
        return false
    end

    local secondaryButton = onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds
    if secondaryButton
       and transformedX >= secondaryButton.x and transformedX <= secondaryButton.x + secondaryButton.width
       and transformedY >= secondaryButton.y and transformedY <= secondaryButton.y + secondaryButton.height then
        onlineAutoAdvanceState.matchObjectiveFocusedButton = "secondary"
        dismissMatchObjectiveModal("mouse_close", "secondary")
        return true
    end

    local button = matchObjectiveCloseButtonBounds
    if button and transformedX >= button.x and transformedX <= button.x + button.width and
       transformedY >= button.y and transformedY <= button.y + button.height then
        onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
        dismissMatchObjectiveModal("mouse_close", "primary")
        return true
    end
    return true
end

function gameplay.gamepadpressed(joystick, button)
    if ConfirmDialog.isActive() then
        local handled = ConfirmDialog.gamepadpressed(joystick, button)
        if handled then
            return true
        end
    end

    if hasVisibleMatchObjectiveModal() then
        local modalState = onlineAutoAdvanceState.matchObjectiveModalState or {}
        local hasSecondary = type(modalState.ctaSecondary) == "string" and modalState.ctaSecondary ~= ""
        if hasSecondary then
            local previousFocus = onlineAutoAdvanceState.matchObjectiveFocusedButton
            if button == "dpleft" or button == "leftshoulder" then
                onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
                if previousFocus ~= onlineAutoAdvanceState.matchObjectiveFocusedButton and ui and ui.playButtonBeep then
                    ui:playButtonBeep()
                end
                return true
            elseif button == "dpright" or button == "rightshoulder" then
                onlineAutoAdvanceState.matchObjectiveFocusedButton = "secondary"
                if previousFocus ~= onlineAutoAdvanceState.matchObjectiveFocusedButton and ui and ui.playButtonBeep then
                    ui:playButtonBeep()
                end
                return true
            end
        end
        if button == "a" then
            local dismissAction = (hasSecondary and onlineAutoAdvanceState.matchObjectiveFocusedButton == "secondary") and "secondary" or "primary"
            dismissMatchObjectiveModal("gamepad_a_close", dismissAction)
            return true
        elseif button == "b" or button == "back" then
            dismissMatchObjectiveModal("gamepad_cancel_close", "primary")
            return true
        end
        -- Keep objective modal focus locked until closed.
        return true
    end

    if gameMode == GAME.MODE.SCENARIO and gameRuler and gameRuler.currentPhase == "gameOver" then
        onlineAutoAdvanceState.maybeShowScenarioOutcomeModal()
        return true
    end

    if hasVisibleOnlineEloSummary() then
        if button == "a" then
            dismissOnlineEloSummary("gamepad_a_close")
            return true
        elseif button == "b" or button == "back" then
            dismissOnlineEloSummary("gamepad_cancel_close")
            return true
        elseif button == "guide" then
            steamRuntime.onGuideButtonPressed()
            return true
        end
        -- Keep rating modal focus locked until closed.
        return true
    end

    if hasVisibleUnitCodexOverlay() then
        if button == "a" then
            if ui and ui.playButtonBeep then
                ui:playButtonBeep()
            end
            if unitCodexFocusedButton == "toggleFaction" then
                switchUnitCodexFaction("gamepad_confirm")
            else
                closeUnitCodexOverlay("gamepad_close")
            end
            return true
        elseif button == "start" or button == "b" or button == "back" then
            closeUnitCodexOverlay("gamepad_close")
            return true
        elseif button == "guide" then
            steamRuntime.onGuideButtonPressed()
            return true
        end
    end

    if GameLogViewer.isActive() then
        if button == "a" then
            return GameLogViewer.keypressed("return")
        elseif button == "b" or button == "back" then
            return GameLogViewer.keypressed("escape")
        elseif button == "leftshoulder" or button == "rightshoulder" then
            -- Shoulder buttons are reserved for panel/tab switching outside the log modal.
            -- Consume while log is open so input does not bleed into gameplay panels.
            return true
        end
    end

    if button == "start" then
        if toggleUnitCodexOverlay("gamepad_start") then
            return true
        end
    end

    if button == "a" then
        gameplay.keypressed("return", "return", false)
        return true
    elseif button == "b" or button == "back" then
        gameplay.keypressed("escape", "escape", false)
        return true
    elseif button == "guide" then
        -- Reserved mapping: on Steam builds, open overlay if available.
        steamRuntime.onGuideButtonPressed()
        return true
    elseif button == "leftshoulder" then
        -- Block in AI vs AI and scenario modes
        if gameMode == GAME.MODE.AI_VS_AI or gameMode == GAME.MODE.SCENARIO then
            return true
        end
        if isRemotePlayLocalMode() and not canCurrentInputIssueActions() then
            return true
        end
        if focusSupplyPanel(1) then
            return true
        end
    elseif button == "rightshoulder" then
        -- Block in AI vs AI and scenario modes
        if gameMode == GAME.MODE.AI_VS_AI or gameMode == GAME.MODE.SCENARIO then
            return true
        end
        if isRemotePlayLocalMode() and not canCurrentInputIssueActions() then
            return true
        end
        if focusSupplyPanel(2) then
            return true
        end
    end

    return false
end

local function initializeMousePosition()
    local x, y = love.mouse.getPosition()
    mousePos.x, mousePos.y = transformMousePosition(x, y)
end

local function optimizeMemoryWithStats()
    local memBefore = collectgarbage("count")
    collectgarbage("collect")
    local memAfter = collectgarbage("count")
    local freed = memBefore - memAfter
end

local function drawDebugInfo()
    -- Draw tech-styled debug panel background
    local panelX = 10
    local panelY = 10
    local panelWidth = 200
    local panelHeight = 190
    
    -- Panel background
    love.graphics.setColor(46/255, 38/255, 32/255, 0.9)  -- Dark brown background
    love.graphics.rectangle("fill", panelX, panelY, panelWidth, panelHeight, 8)
    
    -- Panel border
    love.graphics.setColor(108/255, 88/255, 66/255, 1)  -- Medium brown border
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", panelX, panelY, panelWidth, panelHeight, 8)
    love.graphics.setLineWidth(1)
    
    -- Inner border for tech style
    love.graphics.setColor(79/255, 62/255, 46/255, 0.9)  -- Highlight brown
    love.graphics.rectangle("line", panelX + 3, panelY + 3, panelWidth - 6, panelHeight - 6, 6)
    
    -- Tech-style header
    love.graphics.setColor(78/255, 61/255, 46/255, 0.9)
    love.graphics.rectangle("fill", panelX + 10, panelY + 10, panelWidth - 20, 24, 4)
    
    -- Header text
    love.graphics.setColor(203/255, 183/255, 158/255, 0.95)  -- Light tan text
    love.graphics.printf("DEBUG INFO", panelX, panelY + 15, panelWidth, "center")
    
    -- Debug content with tech-styled text
    love.graphics.setColor(203/255, 183/255, 158/255, 0.95)  -- Light tan text
    local contentY = panelY + 40
    local padding = 15
    
    -- Display FPS and mouse position with consistent styling
    love.graphics.print("FPS: " .. love.timer.getFPS(), panelX + padding, contentY)
    love.graphics.print("Mouse: X:" .. math.floor(mousePos.x) .. ", Y:" .. math.floor(mousePos.y), panelX + padding, contentY + 20)

    -- Memory usage
    local memoryUsage = collectgarbage("count")
    love.graphics.print("Memory: " .. string.format("%.2f", memoryUsage / 1024) .. " MB", panelX + padding, contentY + 40)

    -- Add game state info if available
    if gameRuler then
        local phaseInfo = gameRuler:getCurrentPhaseInfo()
        if phaseInfo then
            love.graphics.print("Phase: " .. phaseInfo.currentPhase, panelX + padding, contentY + 60)
            if phaseInfo.turnPhaseName then
                love.graphics.print("Turn Phase: " .. phaseInfo.turnPhaseName, panelX + padding, contentY + 80)
            end
            love.graphics.print("Player: " .. phaseInfo.currentPlayer, panelX + padding, contentY + 100)

            -- Add info about controller assignments
            for factionId = 1, 2 do
                local nickname = GAME.getFactionControllerNickname(factionId) or "Unknown"
                local label = string.format("Faction %d: %s", factionId, nickname)
                love.graphics.print(label, panelX + padding, contentY + 100 + factionId * 20)
            end
        end
    end

    -- Show current mode with tech-styled highlight if in placement mode
    if buildingPlacementMode then
        -- Draw highlight bar for important info
        love.graphics.setColor(108/255, 88/255, 66/255, 0.6)
        love.graphics.rectangle("fill", panelX + 5, contentY + 160, panelWidth - 10, 22, 4)
        
        -- Mode text with brighter color for emphasis
        love.graphics.setColor(255/255, 240/255, 220/255, 0.95)
        love.graphics.printf("PLACING ROCKS", panelX, contentY + 164, panelWidth, "center")
    end

    -- Reset color
    love.graphics.setColor(1, 1, 1)
end

--------------------------------------------------
-- INITIALIZATION
--------------------------------------------------
local function initializeComponents()

    GAME.CURRENT.TURN = 1

    -- Always use the CURRENT values to ensure we respect faction selection
    gameMode = GAME.CURRENT.MODE
    -- AI always plays optimally - no difficulty levels

    -- Initialize game ruler first
    gameRuler = GameRulerClass.new()

    gameRuler.startAutonomousAiSelection = false

    -- Initialize grid and connect to gameRuler
    grid = PlayGridClass.new({
        gameRuler = gameRuler
    })

    -- Connect the grid to the gameRuler
    gameRuler.currentGrid = grid

    -- Initialize UI and connect to game ruler
    ui = uiClass.new({
        stateMachine = stateMachineRef,
        hideSupplyPanels = (gameMode == GAME.MODE.SCENARIO),
        suppressGameOverPanel = (gameMode == GAME.MODE.SCENARIO),
        onScenarioBackRequested = function()
            if stateMachineRef and stateMachineRef.changeState then
                stateMachineRef.changeState(onlineAutoAdvanceState.getScenarioReturnState())
                return true
            end
            return false
        end,
        onScenarioRetryRequested = function()
            onlineAutoAdvanceState.restartCurrentScenarioAttempt()
            return true
        end
    })
    ui.gameRuler = gameRuler
    if gameMode == GAME.MODE.SCENARIO and ui.gameOverPanel then
        ui.gameOverPanel.visible = false
    end
    ui.onSurrenderRequested = requestSurrenderFromUi
    ui.onOnlineReactionRequested = requestOnlineReactionFromUi
    ui.onUnitCodexRequested = function()
        if ui and ui.playButtonBeep then
            ui:playButtonBeep()
        end
        return toggleUnitCodexOverlay("ui_button")
    end
    
    -- Set UI reference in global GAME object for access from other modules
    GAME.CURRENT.UI = ui


    -- Initialize AI if in single player or AI vs AI mode
    aiPlayer = nil
    if gameMode == GAME.MODE.SINGLE_PLAYER or gameMode == GAME.MODE.AI_VS_AI or gameMode == GAME.MODE.SCENARIO then
        local aiFaction = GAME.getAIFactionId()
        
        aiPlayer = AiClass.new({
            factionId = aiFaction
        })

        local controller = GAME.getControllerForFaction(aiFaction)
        local resolvedReference = aiPlayer:resolveAiReferenceForController(controller)
        aiPlayer:setAiReference(resolvedReference, "initialize_components")

        logger.debug("GAMEPLAY", "AI initialized - Faction:", aiFaction, "Profile:", aiPlayer.aiReference, "Locked:", not aiPlayer.canChangeProfile)
    end

    onlineSession = nil
    onlineLockstep = nil
    onlineReconnectNotified = false
    onlineHeartbeatElapsed = 0
    onlineEloApplied = false
    onlineEloSummaryVisible = false
    onlineEloCloseButtonBounds = nil
    onlineTurnTelemetryKey = nil
    lastResumePhase = nil
    onlineMatchTrafficGraceUntil = nil
    localPreviewSelectionKey = nil
    remotePreviewSelectionKey = nil
    remotePreviewActive = false
    onlineAutoAdvanceState.candidateKey = nil
    onlineAutoAdvanceState.candidateSince = nil
    onlineAutoAdvanceState.issuedKey = nil
    matchObjectiveModalVisible = false
    matchObjectiveCloseButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
    onlineAutoAdvanceState.matchObjectiveHoveredButton = nil
    onlineAutoAdvanceState.matchObjectiveModalState = nil
    onlineAutoAdvanceState.scenarioOutcomeModalShown = false
    onlineMatchSessionClosed = false
    if gameMode == GAME.MODE.MULTYPLAYER_NET then
        GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
        local onlineState = GAME.CURRENT.ONLINE
        onlineSession = onlineState.session
        if onlineSession then
            onlineSession.reconnectTimeoutSec = ONLINE_GAMEPLAY_RECONNECT_TIMEOUT_SEC
            if onlineSession.connected == false and onlineSession.reconnectDeadline then
                onlineSession.reconnectDeadline = getOnlineNowSeconds() + ONLINE_GAMEPLAY_RECONNECT_TIMEOUT_SEC
            end
        end
        onlineLockstep = onlineState.lockstep
        if onlineLockstep then
            onlineLockstep.session = onlineSession
            onlineMatchTrafficGraceUntil = getOnlineNowSeconds() + ONLINE_TRAFFIC_STALE_GRACE_SEC
            onlineLockstep.validateCommand = function(command)
                if type(command) ~= "table" then
                    return false
                end

                local actionType = command.actionType
                local params = type(command.params) == "table" and command.params or {}

                if actionType == "move" or actionType == "attack" or actionType == "repair" then
                    return command.fromRow and command.fromCol and command.toRow and command.toCol
                end

                if actionType == "end_turn" or actionType == "endActions" or actionType == "confirmEndTurn" then
                    return true
                end

                if actionType == "surrender" then
                    local surrenderingPlayer = tonumber(params.surrenderingPlayer)
                    return surrenderingPlayer == 1 or surrenderingPlayer == 2
                end

                if actionType == "placeAllNeutralBuildings" or actionType == "confirmCommandHub" or actionType == "confirmDeployment" then
                    return true
                end

                if actionType == "placeNeutralBuilding" or actionType == "placeCommandHub" then
                    return params.row and params.col
                end

                if actionType == "deployUnitNearHub" then
                    local hasLegacySelection = gameRuler and gameRuler.initialDeployment and gameRuler.initialDeployment.selectedUnitIndex ~= nil
                    return params.row and params.col and (params.unitIndex ~= nil or hasLegacySelection)
                end

                if actionType == "selectSupplyUnit" then
                    return params.unitIndex ~= nil
                end

                if actionType == "deployUnit" then
                    return params.unitIndex ~= nil and params.row and params.col
                end

                return false
            end
        end
    end

    local restoredFromResumeSnapshot = false
    local restoredFromScenarioSnapshot = false
    -- SCENARIO-ONLY snapshot boot path. Other modes keep existing startup flow.
    if gameMode == GAME.MODE.SCENARIO then
        local scenarioState = GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
        local scenarioSnapshot = scenarioState and scenarioState.snapshot or nil
        if type(scenarioSnapshot) ~= "table" then
            queueMainMenuOneShotNotice("Scenario Error", "Scenario data missing. Return to menu.")
            if stateMachineRef and stateMachineRef.changeState then
                stateMachineRef.changeState("mainMenu")
                return
            end
        else
            local restored, restoreErr = gameRuler:loadResumeSnapshot(scenarioSnapshot)
            if not restored then
                queueMainMenuOneShotNotice(
                    "Scenario Error",
                    "Scenario could not be loaded (" .. tostring(restoreErr or "unknown") .. ")."
                )
                if stateMachineRef and stateMachineRef.changeState then
                    stateMachineRef.changeState("mainMenu")
                    return
                end
            else
                restoredFromScenarioSnapshot = true
                GAME.CURRENT.TURN = gameRuler.currentTurn or GAME.CURRENT.TURN
            end
        end
    end

    local pendingResumeSnapshot = GAME.CURRENT.PENDING_RESUME_SNAPSHOT
    if pendingResumeSnapshot and isResumeSupportedMode() and gameRuler and type(gameRuler.loadResumeSnapshot) == "function" then
        local restored, restoreErr = gameRuler:loadResumeSnapshot(pendingResumeSnapshot)
        if not restored then
            local restoreReason = tostring(restoreErr or "unknown")
            print("[Resume] restore failed: " .. restoreReason)
            clearResumeSnapshot("restore_failed")
            GAME.CURRENT.PENDING_RESUME_SNAPSHOT = nil
            GAME.CURRENT.RESUME_RESTART_NOTICE = {
                mode = gameMode,
                reason = restoreReason
            }
            if stateMachineRef and stateMachineRef.changeState then
                stateMachineRef.changeState("mainMenu")
                return
            end
        else
            restoredFromResumeSnapshot = true
            GAME.CURRENT.TURN = gameRuler.currentTurn or GAME.CURRENT.TURN
            GAME.CURRENT.PENDING_RESUME_SNAPSHOT = nil
        end
    end

    matchObjectiveModalVisible = false
    enteredFromResumeSnapshot = restoredFromResumeSnapshot
    matchObjectiveCloseButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
    onlineAutoAdvanceState.matchObjectiveHoveredButton = nil
    onlineAutoAdvanceState.matchObjectiveModalState = nil
    onlineAutoAdvanceState.scenarioOutcomeModalShown = false
    if gameMode == GAME.MODE.SCENARIO then
        local scenarioState = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
        local customObjective = scenarioState and (scenarioState.objectiveMessage or scenarioState.objectiveText) or nil
        local turnsTarget = scenarioState and tonumber(scenarioState.turnsTarget) or nil
        local turnsText = turnsTarget and turnsTarget > 0 and tostring(math.floor(turnsTarget)) or "N#"
        local objectiveBody = (type(customObjective) == "string" and customObjective ~= "")
            and customObjective
            or ("Blu to move, destroy enemy commandant in " .. turnsText .. " turns.")
        onlineAutoAdvanceState.showMatchObjectiveModal({
            title = "WIN CONDITIONS",
            body = objectiveBody,
            cta = "Play Scenario"
        })
    elseif (not restoredFromResumeSnapshot) and (not restoredFromScenarioSnapshot) then
        onlineAutoAdvanceState.showMatchObjectiveModal({})
    end
    unitCodexVisible = false
    unitCodexCloseButtonBounds = nil
    unitCodexToggleButtonBounds = nil
    unitCodexOpenButtonBounds = nil
    unitCodexDisplayFaction = nil
    unitCodexFocusedButton = "close"
    unitCodexTransitionElapsed = UNIT_CODEX_TRANSITION_SEC
    unitCodexTransitionDirection = 0
    unitCodexTransitionFromFaction = nil
    unitCodexGridCaches = {}
    if isRemotePlayLocalMode() then
        audioRuntime.resumeAudioOutput("remote_play_match_start")
        audioRuntime.resetRemotePlayWindow("remote_play_match_start")
        showRemotePlayAudioMutedWarning()
        audioRuntime.logRemotePlayWindowSummary("remote_play_match_start")
    end

    -- Update supply data
    if ui.updateSupplyFromGameRuler then
        ui:updateSupplyFromGameRuler()
    end

    -- Reset placement mode
    buildingPlacementMode = false
    lastSetupHighlightKey = nil
    lastResumePhase = gameRuler and gameRuler.currentPhase or nil
    resumeSnapshotDirty = false
    resumeSnapshotReason = nil
    lastResumeWriteAt = 0
    matchCompletionAchievementsRecorded = false
end

--------------------------------------------------
-- PHASE-SPECIFIC HANDLERS
--------------------------------------------------
local function handleGridSetupHighlighting()
    if not gameRuler or not grid then
        return
    end

    -- Get current phase info
    local phaseInfo = gameRuler:getCurrentPhaseInfo()
    if not phaseInfo then
        return
    end

    local key
    local phase = tostring(phaseInfo.currentPhase or "")
    local turnPhase = tostring(phaseInfo.turnPhaseName or "")
    local player = tostring(phaseInfo.currentPlayer or "")
    local placementMode = buildingPlacementMode and "1" or "0"

    -- Handle highlights based on current phase
    if phaseInfo.currentPhase == "deploy1" or phaseInfo.currentPhase == "deploy2" then
        local validRows = gameRuler.commandHubsValidPositions[phaseInfo.currentPlayer]
        local hasHighlights = grid.highlightedCells and next(grid.highlightedCells) ~= nil
        key = table.concat({
            "deploy",
            phase,
            turnPhase,
            player,
            placementMode,
            tostring(validRows and validRows.min or ""),
            tostring(validRows and validRows.max or "")
        }, "|")
        if key == lastSetupHighlightKey and hasHighlights then
            return
        end
        lastSetupHighlightKey = key
        if grid.highlightValidCells then
            grid:highlightValidCells(validRows)
        end
    elseif buildingPlacementMode and phaseInfo.currentPhase == "setup" then
        local hasHighlights = grid.highlightedCells and next(grid.highlightedCells) ~= nil
        key = table.concat({"setup_build", phase, turnPhase, player, placementMode}, "|")
        if key == lastSetupHighlightKey and hasHighlights then
            return
        end
        lastSetupHighlightKey = key
        -- When in building placement mode, highlight empty cells
        if grid.highlightEmptyCells then
            grid:highlightEmptyCells({r=0.2, g=0.8, b=0.2, a=0.3})
        end
    else
        key = table.concat({"none", phase, turnPhase, player, placementMode}, "|")
        if key == lastSetupHighlightKey then
            return
        end
        lastSetupHighlightKey = key
        -- Clear highlights for other phases when not in placement mode
        if grid.clearHighlightedCells then
            grid:clearHighlightedCells()
        end
    end
end

local function handleCommandHubDeployPhaseClick(transformedX, transformedY)
    local phaseInfo = gameRuler:getCurrentPhaseInfo()
    local validZone = gameRuler.commandHubsValidPositions[phaseInfo.currentPlayer]
    local clickedRow, clickedCol = grid:screenToGridCoordinates(transformedX, transformedY)

    if clickedRow >= validZone.min and clickedRow <= validZone.max then
        local success = executeOrQueueCommand({
            actionType = "placeCommandHub",
            params = {
                row = clickedRow,
                col = clickedCol
            }
        })
    end
end

-- Coordinate conversion function
function gameplay:gridToChessNotation(row, col)
    local columns = "ABCDEFGH"
    local column = string.sub(columns, col, col)
    return column .. row
end

local function handleReadOnlyGridInspect(clickedRow, clickedCol)
    if not clickedRow or not clickedCol or not grid or not ui then
        return true
    end

    local unit = grid:getUnitAt(clickedRow, clickedCol)
    if unit then
        local unitInfo = ui:createUnitInfoFromUnit(unit, unit.player)
        ui:setContent(unitInfo, ui.playerThemes[unit.player])
        ui.infoPanel.title = string.upper(unit.name or "Unit")
        return true
    end

    if grid:isCellEmpty(clickedRow, clickedCol) then
        ui:setContent({
            name = "Empty Cell",
            status = "Empty Cell",
            position = gameplay:gridToChessNotation(clickedRow, clickedCol)
        })
    end

    return true
end

local function handleGridClick(transformedX, transformedY)
    local phaseInfo = gameRuler:getCurrentPhaseInfo()
    local clickedRow, clickedCol = grid:screenToGridCoordinates(transformedX, transformedY)

    ui:clearHoveredInfo()
    grid:clearActionHighlights()

    if not canCurrentInputIssueActions() then
        return handleReadOnlyGridInspect(clickedRow, clickedCol)
    end

    -- Handle Commandant placement phase
    if phaseInfo.currentPhase == "deploy1" or phaseInfo.currentPhase == "deploy2" then
        -- Handle Commandant placement
        handleCommandHubDeployPhaseClick(transformedX, transformedY)

    -- Handle initial unit deployment phase
    elseif phaseInfo.currentPhase == "deploy1_units" or phaseInfo.currentPhase == "deploy2_units" then
        -- Handle initial unit deployment around Commandant
        if clickedRow and clickedCol then
            -- First check if there's a unit at the clicked position we can display info for
            local existingUnit = grid:getUnitAt(clickedRow, clickedCol)
            if existingUnit then
                -- Display info about the clicked unit
                local unitInfo = ui:createUnitInfoFromUnit(existingUnit, existingUnit.player)
                ui:setContent(unitInfo, ui.playerThemes[existingUnit.player])
                --clear selection if the clicked cell is empty
                gameRuler.initialDeployment.selectedUnitIndex = nil
                --Reset highlighted cells
                grid:clearForcedHighlightedCells()
                return true
            end

            -- If no unit, check if the clicked cell is valid for deployment
            if gameRuler:isPositionInAvailableCells(clickedRow, clickedCol, gameRuler.initialDeployment.availableCells) then
                local selection = ui:getSelectedUnitInfo()
                local selectionIndex = selection.index or (gameRuler and gameRuler.initialDeployment and gameRuler.initialDeployment.selectedUnitIndex)

                if not selection.unit and selectionIndex then
                    local supplyPlayer = selection.player or (gameRuler and gameRuler.currentPlayer)
                    local supplyList = gameRuler and gameRuler:getCurrentPlayerSupply(supplyPlayer)
                    if supplyList and supplyList[selectionIndex] then
                        selection.unit = supplyList[selectionIndex]
                        selection.player = supplyPlayer
                        -- Rehydrate UI selection so subsequent calls have the unit reference
                        ui.selectedUnit = ui.selectedUnit or selection.unit
                        ui.selectedUnitPlayer = ui.selectedUnitPlayer or selection.player
                    end
                end

                local debugAttemptInfo
                if DEBUG and DEBUG.UI then
                    debugAttemptInfo = string.format(
                        "selectedIndex=%s rulerIndex=%s row=%s col=%s unit=%s",
                        tostring(selectionIndex),
                        tostring(gameRuler and gameRuler.initialDeployment and gameRuler.initialDeployment.selectedUnitIndex),
                        tostring(clickedRow),
                        tostring(clickedCol),
                        selection.unit and (selection.unit.name or "<no-name>") or "nil"
                    )
                end

                -- Try to deploy the unit at the clicked position as long as we have an index
                if selectionIndex then
                    local success = executeOrQueueCommand({
                        actionType = "deployUnitNearHub",
                        params = {
                            row = clickedRow,
                            col = clickedCol,
                            unitIndex = selectionIndex
                        }
                    })

                    if success then
                        -- Reset UI selection after successful deployment
                        if ui.clearSupplySelection then
                            ui:clearSupplySelection()
                        else
                            ui.selectedUnit = nil
                            ui.selectedUnitIndex = nil
                            ui.selectedUnitPlayer = nil
                            ui.selectedUnitPosition = nil
                        end
                        ui:setContent(nil)
                        -- Update supply display
                        ui:updateSupplyFromGameRuler()
                        grid:clearActionHighlights()
                    elseif DEBUG and DEBUG.UI then
                    end
                elseif DEBUG and DEBUG.UI then
                end
            else
                if grid:isCellEmpty(clickedRow, clickedCol) then
                    if ui then
                        if ui.clearSupplySelection then
                            ui:clearSupplySelection()
                        else
                            ui.selectedUnit = nil
                            ui.selectedUnitIndex = nil
                            ui.selectedUnitPlayer = nil
                            ui.selectedUnitCoordOnPanel = nil
                        end
                    end

                    ui:setContent({
                        name = "Empty Cell",
                        status = "Empty Cell",
                        position = gameplay:gridToChessNotation(clickedRow, clickedCol)
                    })
                    gameRuler.initialDeployment.selectedUnitIndex = nil
                    grid:clearForcedHighlightedCells()
                end
            end
        end

    -- Handle setup phase building placement
    elseif phaseInfo.currentPhase == "setup" and buildingPlacementMode then
        -- Only place buildings if in building placement mode (after button click)
        local success = executeOrQueueCommand({
            actionType = "placeNeutralBuilding",
            params = {
                row = clickedRow,
                col = clickedCol
            }
        })

        -- Exit placement mode after placing or attempting to place
        buildingPlacementMode = false

    -- Handle actions phase (UPDATED with deployment support)
    elseif phaseInfo.currentPhase == "turn" and phaseInfo.turnPhaseName == "actions" then
        if clickedRow and clickedCol then
            -- **Check if we have a selected supply unit for deployment**
            if gameRuler.actionsPhaseSupplySelection or ui.selectedUnit then
                -- Get the unit index - prioritize gameRuler selection, fallback to UI selection
                local unitIndex = gameRuler.actionsPhaseSupplySelection or ui.selectedUnitIndex
                
                -- Try to deploy the selected unit
                local success = executeOrQueueCommand({
                    actionType = "deployUnit",
                    params = {
                        unitIndex = unitIndex,
                        row = clickedRow,
                        col = clickedCol
                    }
                })
                if success then
                    -- Only clear selection if deployment was successful
                    grid:clearForcedHighlightedCells()
                    gameRuler.actionsPhaseSupplySelection = nil

                    -- Update UI
                    ui:updateSupplyFromGameRuler()

                    -- Clear UI selection only on successful deployment
                    ui.selectedUnit = nil
                    ui.selectedUnitIndex = nil
                    ui.selectedUnitPlayer = nil
                    ui.selectedUnitCoordOnPanel = nil
                    ui:setContent(nil)

                    return true
                else
                    -- If clicked on a unit (occupied cell), let the unit click handler deal with it
                    local clickedUnit = grid:getUnitAt(clickedRow, clickedCol)
                    if clickedUnit then
                        -- DON'T return true here - let the unit click handler run
                    else
                        -- If it's an empty cell, handle the deployment failure
                        if grid:isCellEmpty(clickedRow, clickedCol) then
                            -- Check if this empty cell is a valid deployment position
                            local isValidDeployPosition = false
                            if gameRuler.currentGrid and gameRuler.currentGrid.forcedHighlightedCells then
                                for _, highlightedCell in ipairs(gameRuler.currentGrid.forcedHighlightedCells) do
                                    if highlightedCell.row == clickedRow and highlightedCell.col == clickedCol then
                                        isValidDeployPosition = true
                                        break
                                    end
                                end
                            end

                            -- If clicked on empty cell that's NOT a valid deployment position, clear selection
                            if not isValidDeployPosition then
                                grid:clearForcedHighlightedCells()
                                gameRuler.actionsPhaseSupplySelection = nil

                                -- Clear UI selection when clicking invalid deployment position
                                if ui.clearSupplySelection then
                                    ui:clearSupplySelection()
                                else
                                    ui.selectedUnit = nil
                                    ui.selectedUnitIndex = nil
                                    ui.selectedUnitPlayer = nil
                                    ui.selectedUnitCoordOnPanel = nil
                                end

                                -- Show empty cell info
                                ui:setContent({
                                    name = "Empty Cell",
                                    status = "Empty Cell",
                                    position = gameplay:gridToChessNotation(clickedRow, clickedCol)
                                })

                                return true
                            end
                        end

                        -- Keep the selection active for valid deployment positions
                        return true
                    end
                end
            end

            -- Check if there's a unit at the clicked position
            local clickedUnit = grid:getUnitAt(clickedRow, clickedCol)

            -- Check if it's a valid action cell
            if gameRuler.currentActionPreview then
                -- First check what type of highlighted cell was clicked
                local actionType = nil
                local isHighlightedCell = false

                -- Check if it's an attack cell
                if not actionType and gameRuler.currentActionPreview.attackCells then
                    for _, cell in ipairs(gameRuler.currentActionPreview.attackCells) do
                        if cell.row == clickedRow and cell.col == clickedCol then
                            actionType = "attack"
                            isHighlightedCell = true
                            break
                        end
                    end
                end

                -- Check if it's a repair cell
                if not actionType and gameRuler.currentActionPreview.repairCells then
                    for _, cell in ipairs(gameRuler.currentActionPreview.repairCells) do
                        if cell.row == clickedRow and cell.col == clickedCol then
                            actionType = "repair"
                            isHighlightedCell = true
                            break
                        end
                    end
                end

                -- Check if it's a movement cell
                if not actionType and gameRuler.currentActionPreview.moveCells and #gameRuler.currentActionPreview.moveCells > 0 then
                    for _, cell in ipairs(gameRuler.currentActionPreview.moveCells) do
                        if cell.row == clickedRow and cell.col == clickedCol then
                            actionType = "move"
                            isHighlightedCell = true
                            break
                        end
                    end
                end

                -- Now execute the appropriate action based on the cell type
                if isHighlightedCell then
                    local isActionTaken = false
                    local unitRow = gameRuler.currentActionPreview.selectedUnit.row
                    local unitCol = gameRuler.currentActionPreview.selectedUnit.col

                    local ok = false
                    ok = executeOrQueueCommand({
                        actionType = actionType,
                        fromRow = unitRow,
                        fromCol = unitCol,
                        toRow = clickedRow,
                        toCol = clickedCol
                    })
                    isActionTaken = ok == true

                    -- If an action was taken, clear highlights
                    if isActionTaken then
                        grid:clearForcedHighlightedCells()
                        gameRuler.currentActionPreview = nil
                        sendOnlinePreviewClearIfNeeded("action_taken")
                        return true
                    end
                end
            end

            if clickedUnit then
                -- Check if we have a supply unit selected for deployment
                if gameRuler.actionsPhaseSupplySelection then
                    -- Clear supply selection since we can't deploy on occupied cells
                    grid:clearForcedHighlightedCells()
                    gameRuler.actionsPhaseSupplySelection = nil

                    -- Clear UI selection
                    ui.selectedUnit = nil
                    ui.selectedUnitIndex = nil
                    ui.selectedUnitPlayer = nil
                    ui.selectedUnitCoordOnPanel = nil
                end

                -- Only show action previews if it's the current player's unit that can act AND has legal actions
                if clickedUnit.player == phaseInfo.currentPlayer and not clickedUnit.hasActed and not gameRuler:areActionsComplete() and clickedUnit.name ~= "Commandant" then

                    -- Check if unit has legal actions before allowing selection
                    local hasLegalActions = gameRuler:unitHasLegalActions(clickedRow, clickedCol)
                    if hasLegalActions then
                        -- Clear previous highlights first (redundant but safe)
                        grid:clearForcedHighlightedCells()

                        -- SET THE SELECTED UNIT IN THE GRID
                        grid:selectUnit(clickedRow, clickedCol)

                        -- Show action previews for the current player's unit
                        gameRuler:previewUnitMovement(clickedRow, clickedCol)
                        gameRuler:previewUnitAttack(clickedRow, clickedCol)
                        gameRuler:previewUnitRepair(clickedRow, clickedCol)
                        sendOnlinePreviewSelectIfNeeded(clickedRow, clickedCol)

                        -- Show unit info in the info panel
                        local unitInfo = ui:createUnitInfoFromUnit(clickedUnit, clickedUnit.player)
                        ui:setContent(unitInfo, ui.playerThemes[clickedUnit.player])
                        ui.infoPanel.title = string.upper(clickedUnit.name or "Unit")
                    else
                        -- Unit has no legal actions, treat like non-actionable unit
                        grid:clearForcedHighlightedCells()
                        grid:clearSelectedGridUnit()
                        gameRuler.currentActionPreview = nil
                        sendOnlinePreviewClearIfNeeded("unit_no_legal_actions")

                        -- Show unit info but don't allow selection
                        local unitInfo = ui:createUnitInfoFromUnit(clickedUnit, clickedUnit.player)
                        ui:setContent(unitInfo, ui.playerThemes[clickedUnit.player])
                        ui.infoPanel.title = string.upper(clickedUnit.name or "Unit")
                    end
                else
                    -- For units that can't act (enemy units, already acted, Commandant, etc.)
                    -- Clear any previous highlights and show unit info
                    grid:clearForcedHighlightedCells()
                    grid:clearSelectedGridUnit()
                    gameRuler.currentActionPreview = nil
                    sendOnlinePreviewClearIfNeeded("non_actionable_unit")

                    -- Show unit info even for non-actionable units
                    local unitInfo = ui:createUnitInfoFromUnit(clickedUnit, clickedUnit.player)
                    ui:setContent(unitInfo, ui.playerThemes[clickedUnit.player])
                    ui.infoPanel.title = string.upper(clickedUnit.name or "Unit")
                end

                return true
            end

            -- **UPDATED: If clicked on an empty cell, check if it's a valid deployment position**
            if grid:isCellEmpty(clickedRow, clickedCol) then
                -- Check if we have a supply unit selected
                if gameRuler.actionsPhaseSupplySelection or ui.selectedUnit then
                    -- Check if this empty cell is a valid deployment position
                    local isValidDeployPosition = false
                    if gameRuler.currentGrid and gameRuler.currentGrid.forcedHighlightedCells then
                        for _, highlightedCell in ipairs(gameRuler.currentGrid.forcedHighlightedCells) do
                            if highlightedCell.row == clickedRow and highlightedCell.col == clickedCol then
                                isValidDeployPosition = true
                                break
                            end
                        end
                    end
                    
                    -- If clicked on empty cell that's NOT a valid deployment position, clear selection
                    if not isValidDeployPosition then
                        grid:clearForcedHighlightedCells()
                        gameRuler.actionsPhaseSupplySelection = nil
                        
                        -- Clear UI selection when clicking invalid deployment position
                        ui.selectedUnit = nil
                        ui.selectedUnitIndex = nil
                        ui.selectedUnitPlayer = nil
                        ui.selectedUnitCoordOnPanel = nil
                    end
                end
                
                -- Clear grid highlights and unit selection
                grid:clearForcedHighlightedCells()
                grid:clearSelectedGridUnit()
                gameRuler.currentActionPreview = nil
                sendOnlinePreviewClearIfNeeded("empty_cell")

                -- Show empty cell info
                ui:setContent({
                    name = "Empty Cell",
                    status = "Empty Cell",
                    position = gameplay:gridToChessNotation(clickedRow, clickedCol)
                })

                return true
            end
        end

    else
        -- Handle gameplay clicks for other phases
        if grid.handleCellClick then
            grid:handleCellClick(transformedX, transformedY, ui, phaseInfo.currentPlayer, phaseInfo.isInSetupPhase)
        end
    end
end

--------------------------------------------------
-- LÖVE CALLBACK FUNCTIONS
--------------------------------------------------
function gameplay.enter(stateMachine, prevState, params)
    stateMachineRef = stateMachine
    manualNoSaveExitRequested = false
    perfMetrics.startSession("gameplay")

    -- Initialize all game components
    initializeComponents()

    recordAchievementEvent("gameplay_started", {
        mode = gameMode,
        resumed = enteredFromResumeSnapshot
    })

    if not enteredFromResumeSnapshot then
        local stats = achievementDefs.STATS or {}
        local statsChanged = false
        if gameMode == GAME.MODE.MULTYPLAYER_LOCAL then
            statsChanged = incrementSteamStat(stats.LOCAL_MATCHES_PLAYED, 1) or statsChanged
        elseif gameMode == GAME.MODE.MULTYPLAYER_NET then
            local profile = select(1, onlineRatingStore.ensureLocalProfile())
            if profile then
                local playedValue = incrementSteamStatValue(stats.ONLINE_MATCHES_PLAYED, 1)
                if playedValue ~= nil then
                    profile.games = math.max(0, math.floor(playedValue))
                    statsChanged = true
                end
                statsChanged = syncOnlineRatingProgress(profile) or statsChanged
                local saveOk = onlineRatingStore.saveProfile(profile)
                if saveOk ~= true then
                    print("[Rating] failed to persist online profile during gameplay enter")
                end
            end
            showRatingProfileRepairNoticeIfNeeded()
        end
        if statsChanged then
            storeSteamStats()
        end
    end

    -- Initialize components
    -- Remote Play uses hidden-by-default OS cursor policy.
    if isRemotePlayLocalMode() then
        love.mouse.setVisible(false)
        MOUSE_STATE.IS_HIDDEN = true
    elseif not MOUSE_STATE.IS_HIDDEN then
        love.mouse.setVisible(true)
    end
    
    initializeMousePosition()

    if grid then
        grid:enter()
    end

    if (gameMode == GAME.MODE.SINGLE_PLAYER or gameMode == GAME.MODE.AI_VS_AI or gameMode == GAME.MODE.SCENARIO) and aiPlayer then
        aiPlayer:enter(gameRuler, grid)
    end

    -- Set mouse position to center of screen when starting gameplay
    love.mouse.setPosition(SETTINGS.DISPLAY.WIDTH / 2, SETTINGS.DISPLAY.HEIGHT / 2)
    
    -- Force initial check for hovered cell
    if gameRuler and grid then
        local mouseX, mouseY = love.mouse.getPosition()
        local gridX = (SETTINGS.DISPLAY.WIDTH - (GAME.CONSTANTS.TILE_SIZE * GAME.CONSTANTS.GRID_SIZE)) / 2
        local gridY = (SETTINGS.DISPLAY.HEIGHT - (GAME.CONSTANTS.TILE_SIZE * GAME.CONSTANTS.GRID_SIZE)) / 2
        
        -- Calculate grid coordinates from mouse position
        local col = math.floor((mouseX - gridX) / GAME.CONSTANTS.TILE_SIZE) + 1
        local row = math.floor((mouseY - gridY) / GAME.CONSTANTS.TILE_SIZE) + 1
        
        -- Update mouseHoverCell if within grid boundaries
        if row >= 1 and row <= GAME.CONSTANTS.GRID_SIZE and 
           col >= 1 and col <= GAME.CONSTANTS.GRID_SIZE then
            gameRuler.currentGrid.mouseHoverCell = gameRuler.currentGrid:getCell(row, col)
        end
    end
end

function gameplay.update(dt)
    perfMetrics.beginFrame(dt)
    perfMetrics.beginSection("update")

    local animationDt = getAnimationDelta(dt)
    processOnlineLockstepEvents(dt)
    local onlinePaused = isOnlineModeActive() and onlineSession and (not onlineSession.connected) and gameRuler and gameRuler.currentPhase ~= "gameOver"
    local objectiveModalVisible = hasVisibleMatchObjectiveModal()
    local gameplayBlocked = onlinePaused or objectiveModalVisible

    if gameRuler and not gameplayBlocked then
        gameRuler:updateScheduledActions(animationDt)
    end
    

    if grid and not gameplayBlocked then
        grid:update(animationDt)
    end

    if ui and ui.update and not objectiveModalVisible then
        ui:update(dt)
    end

    if unitCodexTransitionElapsed < UNIT_CODEX_TRANSITION_SEC then
        unitCodexTransitionElapsed = math.min(UNIT_CODEX_TRANSITION_SEC, unitCodexTransitionElapsed + dt)
        if unitCodexTransitionElapsed >= UNIT_CODEX_TRANSITION_SEC then
            unitCodexTransitionFromFaction = nil
            unitCodexTransitionDirection = 0
        end
    end

    -- Update confirmation dialog if active
    if ConfirmDialog and ConfirmDialog.update then
        ConfirmDialog.update(dt)
    end

    -- Update game log viewer if present (handles scrollbar flash, etc.)
    if GameLogViewer and GameLogViewer.update then
        GameLogViewer.update(dt)
    end

    -- Update gameRuler if available
    if gameRuler and gameRuler.update and not gameplayBlocked then
        gameRuler:update(dt)
    end

    -- Handle phase-specific flow
    if not gameplayBlocked then
        handleGridSetupHighlighting()
    end

    -- If game phase changes, reset placement mode
    if gameRuler and gameRuler.getCurrentPhaseInfo and not gameplayBlocked then
        local phaseInfo = gameRuler:getCurrentPhaseInfo()
        if phaseInfo.currentPhase ~= "setup" and buildingPlacementMode then
            buildingPlacementMode = false
        end
    end

    if isResumeSupportedMode() and gameRuler and not objectiveModalVisible then
        local currentPhase = gameRuler.currentPhase
        if lastResumePhase ~= currentPhase then
            if currentPhase == "gameOver" then
                clearResumeSnapshot("game_over_phase")
            else
                markResumeDirty("phase_change")
            end
            lastResumePhase = currentPhase
        end

        flushResumeSnapshotIfStable("update")
    end

    -- Handle AI turn if it's AI's turn and no animations are in progress
    if aiPlayer and gameRuler and not gameplayBlocked then
        local phaseInfo = gameRuler:getCurrentPhaseInfo()

        -- Handle AI turns for both single player and AI vs AI modes
        local shouldProcessAI = false
        
        if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
            -- In AI vs AI mode, always process AI turns (both players are AI)
            shouldProcessAI = not gameRuler:isAnimationInProgress()
            -- Update AI faction to current player for AI vs AI mode (only if changed)
            if aiPlayer.factionId ~= phaseInfo.currentPlayer then
                logger.debug("GAMEPLAY", "AI vs AI: Switching AI from faction", aiPlayer.factionId, "to faction", phaseInfo.currentPlayer)
                logger.debug("GAMEPLAY", "Phase:", phaseInfo.currentPhase, "Turn phase:", phaseInfo.turnPhaseName)
                aiPlayer.factionId = phaseInfo.currentPlayer
                
                local controller = GAME.getControllerForFaction(phaseInfo.currentPlayer)
                local resolvedReference = aiPlayer:resolveAiReferenceForController(controller)
                aiPlayer:setAiReference(resolvedReference, "ai_vs_ai_turn_switch")
                if controller and controller.nickname then
                    logger.debug("GAMEPLAY", "AI vs AI: Set profile to", aiPlayer.aiReference, "for", controller.nickname)
                end
                
                -- Reset AI state when switching players
                aiPlayer.actionsPhaseStarted = false
                aiPlayer.hasDeployedThisTurn = false
            end
        elseif GAME.CURRENT.MODE == GAME.MODE.SINGLE_PLAYER or GAME.CURRENT.MODE == GAME.MODE.SCENARIO then
            -- In single player mode, only process when it's the AI player's turn
            shouldProcessAI = (phaseInfo.currentPlayer == gameRuler.aiPlayerNumber)
                and not gameRuler:isAnimationInProgress()
        end
        
        if shouldProcessAI then
            -- Don't process AI during game over phase
            if phaseInfo.currentPhase ~= "gameOver" then
                -- Process AI turn based on current game phase
                logger.debug("GAMEPLAY", "Processing AI turn - Faction:", aiPlayer.factionId, "Phase:", phaseInfo.currentPhase)
                perfMetrics.beginSection("ai_turn")
                aiPlayer:handleAITurn(phaseInfo, grid)
                perfMetrics.endSection("ai_turn")
            end
        end
    elseif gameMode == GAME.MODE.SINGLE_PLAYER or gameMode == GAME.MODE.AI_VS_AI or gameMode == GAME.MODE.SCENARIO then
        if not aiPlayer then
            logger.error("GAMEPLAY", "ERROR: aiPlayer is nil!")
        end
        if not gameRuler then
            logger.error("GAMEPLAY", "ERROR: gameRuler is nil!")
        end
    end

    if grid and not gameplayBlocked then
        grid:updateAnimations(animationDt)
    end

    local onlineAutoAdvanceRequest = onlineAutoAdvanceState.getRequest(gameplayBlocked)
    if onlineAutoAdvanceRequest then
        local advanceKey = onlineAutoAdvanceRequest.key

        if onlineAutoAdvanceState.issuedKey and onlineAutoAdvanceState.issuedKey ~= advanceKey then
            onlineAutoAdvanceState.issuedKey = nil
        end

        if onlineAutoAdvanceState.issuedKey ~= advanceKey then
            local now = getOnlineNowSeconds()
            if onlineAutoAdvanceState.candidateKey ~= advanceKey then
                onlineAutoAdvanceState.candidateKey = advanceKey
                onlineAutoAdvanceState.candidateSince = now
            elseif (now - tonumber(onlineAutoAdvanceState.candidateSince or now)) >= 0.2 then
                local ok, err = executeOrQueueCommand({ actionType = onlineAutoAdvanceRequest.actionType })
                if ok then
                    clearActiveUnitSelection()
                    onlineAutoAdvanceState.issuedKey = advanceKey
                    onlineAutoAdvanceState.resetCandidate()
                    print(string.format(
                        "[OnlineGameplay] AUTO_ADVANCE_REQUEST source=%s action=%s key=%s",
                        tostring(onlineAutoAdvanceRequest.source),
                        tostring(onlineAutoAdvanceRequest.actionType),
                        tostring(advanceKey)
                    ))
                else
                    onlineAutoAdvanceState.candidateSince = now
                    print(string.format(
                        "[OnlineGameplay] AUTO_ADVANCE_REQUEST_FAILED source=%s action=%s reason=%s",
                        tostring(onlineAutoAdvanceRequest.source),
                        tostring(onlineAutoAdvanceRequest.actionType),
                        tostring(err)
                    ))
                end
            end
        end
    else
        onlineAutoAdvanceState.resetCandidate()
        if not isOnlineModeActive() then
            onlineAutoAdvanceState.issuedKey = nil
        end
    end

    -- SCENARIO-ONLY auto checks (outcome modal + auto pass turn if no legal actions).
    if gameMode == GAME.MODE.SCENARIO then
        onlineAutoAdvanceState.maybeShowScenarioOutcomeModal()
    end

    if gameMode == GAME.MODE.SCENARIO
        and not gameplayBlocked
        and gameRuler
        and gameRuler.currentPhase == "turn"
        and gameRuler.currentTurnPhase == "actions"
        and gameRuler.currentPhase ~= "gameOver"
        and not matchObjectiveModalVisible
        and not unitCodexVisible
        and not onlineEloSummaryVisible
        and (not ConfirmDialog or type(ConfirmDialog.isActive) ~= "function" or not ConfirmDialog.isActive())
        and (not GameLogViewer or type(GameLogViewer.isActive) ~= "function" or not GameLogViewer.isActive())
        and not gameRuler:isAnimationInProgress() then
        gameRuler:checkForStalledUnits()
        if gameRuler:areActionsComplete() then
            local ok = executeOrQueueCommand({ actionType = "end_turn" })
            if ok then
                clearActiveUnitSelection()
            end
        end
    end

    applyOnlineEloUpdateIfNeeded()
    processMatchCompletionAchievementsIfNeeded()

    perfMetrics.endSection("update")
end

function gameplay.draw()
    perfMetrics.beginSection("draw")

    love.graphics.push()
    love.graphics.translate(SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY)
    love.graphics.scale(SETTINGS.DISPLAY.SCALE)

    -- Apply screen shake offset if active (affects entire screen)
    local screenShakeWasActive = grid and grid.screenShake and grid.screenShake.active
    if screenShakeWasActive then
        love.graphics.push()
        love.graphics.translate(grid.screenShake.offsetX, grid.screenShake.offsetY)
    end

    -- Draw grid if available
    if grid and grid.movingUnits and #grid.movingUnits > 0 then
        perfMetrics.beginSection("grid_draw")
        -- Temporarily disable hover indicators during animations
        local tempHoverCell = grid.mouseHoverCell
        grid.mouseHoverCell = nil

        -- Draw grid and other elements
        grid:draw()

        -- Restore hover state for when animation ends
        grid.mouseHoverCell = tempHoverCell
        perfMetrics.endSection("grid_draw")
    else
        perfMetrics.beginSection("grid_draw")
        grid:draw()
        perfMetrics.endSection("grid_draw")
    end

    -- Draw influence heatmap if enabled (above grid, below UI)
    -- Must be drawn BEFORE UI and BEFORE screen shake pop
    if grid then
        -- Use exact grid constants for perfect alignment
        local cellSize = GAME.CONSTANTS.TILE_SIZE
        local offsetX = GAME.CONSTANTS.GRID_ORIGIN_X
        local offsetY = GAME.CONSTANTS.GRID_ORIGIN_Y
        aiInfluence:drawHeatmap(cellSize, offsetX, offsetY)
    end

    
    -- Draw UI if available
    if ui and ui.draw then
        ui.overlayInputBlocked = ConfirmDialog.isActive()
            or hasVisibleMatchObjectiveModal()
            or hasVisibleUnitCodexOverlay()
            or hasVisibleOnlineEloSummary()
            or (GameLogViewer and GameLogViewer.isActive and GameLogViewer.isActive())
        perfMetrics.beginSection("ui_draw")
        ui:draw(gameRuler)  -- Pass gameRuler to UI draw method
        perfMetrics.endSection("ui_draw")
    end

    drawUnitCodexOpenButton()
    drawUnitCodexOverlay()
    drawOnlineEloSummary()
    if gameMode == GAME.MODE.SCENARIO and gameRuler and gameRuler.currentPhase == "gameOver" and ui and ui.drawConfetti then
        ui:drawConfetti()
    end

    -- Reset screen shake transform
    if screenShakeWasActive then
        love.graphics.pop()
    end

    -- Draw game log viewer if active (above game and UI, below confirm dialog)
    if GameLogViewer and GameLogViewer.draw and GameLogViewer.isActive and GameLogViewer.isActive() then
        GameLogViewer.draw()
    end

    drawMatchObjectiveModal()

    -- Draw debug info if enabled
    if debugText then
        drawDebugInfo()
    end

    -- Draw confirmation dialog if active (above everything else)
    if ConfirmDialog and ConfirmDialog.draw then
        ConfirmDialog.draw()
    end

    love.graphics.pop()

    perfMetrics.endSection("draw")
    perfMetrics.drawOverlay()
    perfMetrics.endFrame()
end

function gameplay.resize(w, h)
    if grid and grid.onDisplayResized then
        grid:onDisplayResized()
    end
    if ui and ui.onDisplayResized then
        ui:onDisplayResized()
    end
    invalidateUnitCodexGridCaches()
    unitCodexOpenButtonBounds = nil
    unitCodexCloseButtonBounds = nil
    unitCodexToggleButtonBounds = nil
end

function gameplay.exit()
    stateMachineRef = nil
    love.graphics.setColor(1, 1, 1)

    if isResumeSupportedMode() and gameRuler then
        if gameRuler.currentPhase == "gameOver" then
            clearResumeSnapshot("gameplay_exit_game_over")
        elseif manualNoSaveExitRequested then
            clearResumeSnapshot("manual_exit_no_save")
        else
            markResumeDirty("gameplay_exit")
            local saved = flushResumeSnapshotIfStable("gameplay_exit", { forceInterval = true })
            if not saved then
                print("[Resume] gameplay_exit skipped unstable flush; preserving last stable snapshot")
                resumeSnapshotDirty = false
                resumeSnapshotReason = nil
            end
        end
    end

    local perfReport = perfMetrics.endSession()
    if perfReport then
        logger.info("PERF", string.format(
            "Session frame metrics: frames=%d median=%.2fms p95=%.2fms",
            perfReport.frameCount or 0,
            (perfReport.snapshot and perfReport.snapshot.frame and perfReport.snapshot.frame.medianMs) or 0,
            (perfReport.snapshot and perfReport.snapshot.frame and perfReport.snapshot.frame.p95Ms) or 0
        ))
    end

    if onlineSession and type(onlineSession.leave) == "function" and onlineSession.active then
        onlineSession:leave()
    end
    clearOnlineRuntimeState("gameplay_exit")

    if grid then grid = nil end
    if gameRuler then gameRuler = nil end
    GAME.CURRENT.PENDING_RESUME_SNAPSHOT = nil
    if aiPlayer then aiPlayer = nil end
    onlineSession = nil
    onlineLockstep = nil
    onlineEloApplied = false
    onlineEloSummaryVisible = false
    onlineEloCloseButtonBounds = nil
    matchObjectiveModalVisible = false
    matchObjectiveCloseButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveSecondaryButtonBounds = nil
    onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
    onlineAutoAdvanceState.matchObjectiveHoveredButton = nil
    onlineAutoAdvanceState.matchObjectiveModalState = nil
    unitCodexVisible = false
    unitCodexCloseButtonBounds = nil
    unitCodexToggleButtonBounds = nil
    unitCodexOpenButtonBounds = nil
    unitCodexDisplayFaction = nil
    unitCodexFocusedButton = "close"
    unitCodexTransitionElapsed = UNIT_CODEX_TRANSITION_SEC
    unitCodexTransitionDirection = 0
    unitCodexTransitionFromFaction = nil
    unitCodexGridCaches = {}
    onlineReconnectNotified = false
    onlineTurnTelemetryKey = nil
    lastResumePhase = nil
    resumeSnapshotDirty = false
    resumeSnapshotReason = nil
    lastResumeWriteAt = 0
    manualNoSaveExitRequested = false
    onlineMatchSessionClosed = false
    onlineAutoAdvanceState.candidateKey = nil
    onlineAutoAdvanceState.candidateSince = nil
    onlineAutoAdvanceState.issuedKey = nil
    onlineAutoAdvanceState.scenarioOutcomeModalShown = false

    -- Remove this line that was resetting AI player number
    -- GAME.CURRENT.AI_PLAYER_NUMBER = 2

    if debugText then
        optimizeMemoryWithStats()
    else
        collectgarbage("collect")
    end
end

--------------------------------------------------
-- INPUT HANDLERS
--------------------------------------------------
function gameplay.mousemoved(x, y, dx, dy, istouch)

    if ConfirmDialog.isActive() then
        ConfirmDialog.mousemoved(x, y)
        return true
    end

    if hasVisibleMatchObjectiveModal() then
        mousePos.x, mousePos.y = transformMousePosition(x, y)
        return true
    end

    if hasVisibleUnitCodexOverlay() then
        mousePos.x, mousePos.y = transformMousePosition(x, y)
        return true
    end

    if GameLogViewer.isActive() then
        GameLogViewer.mousemoved(x, y)
        return true
    end

    mousePos.x, mousePos.y = transformMousePosition(x, y)

    -- In AI vs AI mode, block all mouse hover except on the Back to Menu button
    if gameMode == GAME.MODE.AI_VS_AI then
        if grid then
            grid.mouseHoverCell = nil
            grid.uiNavigationActive = true
        end
        -- Still allow hover on the phase button for visual feedback
        -- The button handles its own hover state in drawBackToMenuButton
        return true
    end

    local uiHovered = false
    if ui and ui.handleMouseMovement then
        uiHovered = ui:handleMouseMovement(mousePos.x, mousePos.y)
    end

    if ui.navigationMode == "ui" and ui.uIkeyboardNavigationActive then
        -- Switch to mouse navigation
        ui.navigationMode = "ui"
        ui.uIkeyboardNavigationActive = false
        ui:handleMouseMovement(mousePos.x, mousePos.y)
        HOVER_INDICATOR_STATE.IS_HIDDEN = false
    end

    local suppressGridHover = false
    if gameRuler and gameRuler.currentPhase == "gameOver" then
        suppressGridHover = true
    end

    if grid and grid.updateHoverState then
        if suppressGridHover then
            grid.mouseHoverCell = nil
            grid.uiNavigationActive = true
        else
            -- Set uiNavigationActive to true when UI is hovered
            grid.uiNavigationActive = uiHovered
            grid:updateHoverState(mousePos.x, mousePos.y)
        end
    end
end

function gameplay.mousepressed(x, y, button, istouch, presses)
    if button ~= 1 then return end

    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousepressed(x, y, button)
    end

    -- Transform coordinates
    local transformedX, transformedY = transformMousePosition(x, y)

    if handleMatchObjectiveModalClick(transformedX, transformedY) then
        return true
    end

    if handleUnitCodexOverlayClick(transformedX, transformedY) then
        return true
    end

    -- Check if game log viewer is active
    if GameLogViewer.isActive() then
        return GameLogViewer.mousepressed(x, y, button)
    end

    if handleOnlineEloSummaryClick(transformedX, transformedY) then
        return true
    end

    if handleUnitCodexOpenButtonClick(transformedX, transformedY) then
        return true
    end

    local phaseInfo = gameRuler:getCurrentPhaseInfo()

    if phaseInfo and phaseInfo.currentPhase == "gameOver" then
        if gameMode == GAME.MODE.SCENARIO then
            onlineAutoAdvanceState.maybeShowScenarioOutcomeModal()
            return true
        end

        -- Track if the UI handled the click
        local handled = false
        if ui and ui.handleClickOnUI then
            handled = ui:handleClickOnUI(transformedX, transformedY)
        end

        if handled then
            return true
        end
    end

    -- In AI vs AI mode, only allow clicking the phase button (Back to Menu)
    if gameMode == GAME.MODE.AI_VS_AI then
        -- Only check phase button click
        if ui and ui.phaseButton then
            local btn = ui.phaseButton
            if transformedX >= btn.x and transformedX <= btn.x + btn.width and
               transformedY >= btn.y and transformedY <= btn.y + btn.height then
                ui:handlePhaseButtonClick(transformedX, transformedY)
                return true
            end
        end
        -- Block all other clicks
        return true
    end

    local localTurnControl = isCurrentTurnLocallyControlled()
    local actionInputAllowed = canCurrentInputIssueActions()
    local readOnlyBlocked = isCurrentInputReadOnlyBlocked()

    if isOnlineModeActive() and actionInputAllowed and ui and ui.phaseButton then
        local btn = ui.phaseButton
        local actionType = btn.actionType
        local isPhaseButtonHit = transformedX >= btn.x and transformedX <= btn.x + btn.width and
            transformedY >= btn.y and transformedY <= btn.y + btn.height
        if isPhaseButtonHit and actionType and actionType ~= "" and actionType ~= "ReturnToMainMenu" then
            local normalizedAction = actionType
            if actionType == "endActions" or actionType == "confirmEndTurn" then
                normalizedAction = "end_turn"
            end
            local ok
            if normalizedAction == "end_turn" then
                local phaseInfo = gameRuler:getCurrentPhaseInfo() or {}
                local advanceKey = onlineAutoAdvanceState.buildKey("end_turn", phaseInfo)
                ok = executeOrQueueCommand({ actionType = "end_turn" })
                if ok then
                    onlineAutoAdvanceState.issuedKey = advanceKey
                    onlineAutoAdvanceState.resetCandidate()
                    print(string.format(
                        "[OnlineGameplay] END_TURN_REQUEST source=%s key=%s",
                        "phase_button_mouse",
                        tostring(advanceKey)
                    ))
                end
            else
                ok = executeOrQueueCommand({ actionType = normalizedAction })
            end
            if ok then
                clearActiveUnitSelection()
            end
            return true
        end
    end

    -- First check if UI handled the click.
    if ui and ui.handleClickOnUI then
        local handled = false
        if actionInputAllowed then
            handled = ui:handleClickOnUI(transformedX, transformedY)
        elseif ui.handleOnlineNonLocalClick then
            handled = ui:handleOnlineNonLocalClick(transformedX, transformedY)
        end

        if handled then
            -- UI handled the click, so do not process further input
            return true
        end
    end

    -- Block grid/game input when the active faction is not locally controlled.
    if phaseInfo and readOnlyBlocked then
        if grid and grid.isPointInGrid and grid:isPointInGrid(transformedX, transformedY) then
            local row, col = grid:screenToGridCoordinates(transformedX, transformedY)
            return handleReadOnlyGridInspect(row, col)
        end
        return true
    end

    -- If UI didn't handle the click, check if it's on the grid
    if grid and grid.isPointInGrid and grid:isPointInGrid(transformedX, transformedY) then
        handleGridClick(transformedX, transformedY)
    end
end

function gameplay.mousereleased(x, y, button, istouch, presses)
    -- Check if confirmation dialog is active first
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousereleased(x, y, button)
    end
    
    -- Check if game log viewer is active
    if GameLogViewer.isActive() then
        return GameLogViewer.mousereleased(x, y, button)
    end
    
    -- Add any other mouse release handling here if needed in the future
end

function gameplay.touchpressed(id, x, y, dx, dy, pressure)
    -- Mouse emulation for touch is handled centrally in stateMachine.touchpressed.
    return true
end

function gameplay.touchreleased(id, x, y, dx, dy, pressure)
    -- Mouse emulation for touch is handled centrally in stateMachine.touchreleased.
    return true
end

function gameplay.wheelmoved(x, y)
    if hasVisibleUnitCodexOverlay() then
        return true
    end
    -- Route mouse wheel to game log viewer if active
    if GameLogViewer.isActive() then
        return GameLogViewer.wheelmoved(x, y)
    end
end

function gameplay.keypressed(key, scancode, isrepeat)
    -- Check for confirmation dialog first
    if ConfirmDialog.isActive() then
        ConfirmDialog.keypressed(key)
        return true
    end

    if hasVisibleMatchObjectiveModal() then
        local modalState = onlineAutoAdvanceState.matchObjectiveModalState or {}
        local hasSecondary = type(modalState.ctaSecondary) == "string" and modalState.ctaSecondary ~= ""
        if hasSecondary then
            local previousFocus = onlineAutoAdvanceState.matchObjectiveFocusedButton
            if key == "left" or key == "a" or key == "up" or key == "w" then
                onlineAutoAdvanceState.matchObjectiveFocusedButton = "primary"
                if previousFocus ~= onlineAutoAdvanceState.matchObjectiveFocusedButton and ui and ui.playButtonBeep then
                    ui:playButtonBeep()
                end
                return true
            elseif key == "right" or key == "d" or key == "down" or key == "s" or key == "tab" then
                onlineAutoAdvanceState.matchObjectiveFocusedButton = "secondary"
                if previousFocus ~= onlineAutoAdvanceState.matchObjectiveFocusedButton and ui and ui.playButtonBeep then
                    ui:playButtonBeep()
                end
                return true
            end
        end
        if key == "return" or key == "space" then
            local dismissAction = (hasSecondary and onlineAutoAdvanceState.matchObjectiveFocusedButton == "secondary") and "secondary" or "primary"
            dismissMatchObjectiveModal("key_close", dismissAction)
            return true
        end
        if isMatchObjectiveCloseKey(key) then
            dismissMatchObjectiveModal("key_cancel_close", "primary")
            return true
        end
        -- Keep objective modal focus locked until closed.
        return true
    end

    if hasVisibleUnitCodexOverlay() then
        if key == "w" or key == "up" then
            moveUnitCodexFocusedButton("up")
            return true
        elseif key == "s" or key == "down" then
            moveUnitCodexFocusedButton("down")
            return true
        elseif key == "return" or key == "space" then
            if ui and ui.playButtonBeep then
                ui:playButtonBeep()
            end
            if unitCodexFocusedButton == "toggleFaction" then
                switchUnitCodexFaction("key_confirm")
            else
                closeUnitCodexOverlay("key_close")
            end
            return true
        elseif key == "escape" or (isUnitCodexToggleKey(key) and not isrepeat) then
            closeUnitCodexOverlay("key_close")
            return true
        end
        return true
    end

    -- Route keys to game log viewer if active
    if GameLogViewer.isActive() then
        return GameLogViewer.keypressed(key)
    end

    if hasVisibleOnlineEloSummary() then
        if isEloSummaryCloseKey(key) then
            dismissOnlineEloSummary("key_close")
            return true
        end
        -- Keep rating modal focus locked until closed.
        return true
    end

    if not isrepeat and isUnitCodexToggleKey(key) and canShowUnitCodexOverlay() then
        toggleUnitCodexOverlay("key_toggle")
        return true
    end

    if handleSupplyPanelShortcutKey(key) then
        return true
    end
    
    -- In AI vs AI mode, any key press activates the Back to Menu button
    if gameMode == GAME.MODE.AI_VS_AI then
        -- ESC directly triggers the confirmation dialog
        if key == "escape" then
            if ui and ui.phaseButton then
                ui:handlePhaseButtonClick(ui.phaseButton.x + ui.phaseButton.width/2, ui.phaseButton.y + ui.phaseButton.height/2)
            end
            return true
        end
        
        -- Return/Space activates the button if it's focused
        if key == "return" or key == "space" then
            if ui and ui.phaseButton then
                ui:handlePhaseButtonClick(ui.phaseButton.x + ui.phaseButton.width/2, ui.phaseButton.y + ui.phaseButton.height/2)
            end
            return true
        end
        
        -- Any other key focuses the Back to Menu button
        if ui and ui.phaseButton then
            ui.navigationMode = "ui"
            ui.uIkeyboardNavigationActive = true
            ui.keyboardNavInitiated = true
            HOVER_INDICATOR_STATE.IS_HIDDEN = true
            
            -- Find and focus the phase button
            for i, element in ipairs(ui.uiElements) do
                if element.name == "phaseButton" then
                    ui.currentUIElementIndex = i
                    ui.activeUIElement = element
                    ui:syncKeyboardAndMouseFocus()
                    return true
                end
            end
        end
        return true
    end

    -- Handle game over screen - this is the only place that should handle game over keyboard input
    if gameRuler and gameRuler.currentPhase == "gameOver" then
        if gameMode == GAME.MODE.SCENARIO then
            onlineAutoAdvanceState.maybeShowScenarioOutcomeModal()
            return true
        end

        -- ESC key goes to main menu with confirmation
        if key == "escape" then
            ConfirmDialog.show(
                "Return to main menu?",
                function()
                    -- Confirmed - return to main menu
                    if stateMachineRef then
                        stateMachineRef.changeState("mainMenu")
                    end
                end,
                function() end
            )
            return true
        end

        local panelVisible = true
        if ui and ui.gameOverPanel then
            panelVisible = ui.gameOverPanel.visible ~= false
        end

        ensureGameOverUIFocus(panelVisible)

        if not panelVisible then
            local hasUIFocus = ui and ui.uIkeyboardNavigationActive and ui.activeUIElement
            local isNavKey = (key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d")

            if hasUIFocus then
                if isNavKey then
                    ui.keyboardNavInitiated = false
                    ui:navigateUI(key)
                    return true
                elseif key == "return" or key == "space" then
                    local elementName = ui.activeUIElement.name or ""

                    if elementName == "returnButton" then
                        ui.gameOverPanel.visible = true
                        if ui.drawReturnToResultsButton then
                            ui:drawReturnToResultsButton()
                        end
                        ui:initializeUIElements()
                        return true
                    elseif elementName == "gameLogPanel" then
                        if ui.activeUIElement.action then
                            local handled = ui.activeUIElement.action()
                            if handled == true then
                                return true
                            end
                        end
                        if GameLogViewer and GameLogViewer.show then
                            GameLogViewer.show(gameRuler)
                        end
                        return true
                    elseif ui.activeUIElement.action then
                        local handled = ui.activeUIElement.action()
                        if handled == true then
                            return true
                        end
                    end
                end
            else
                if ui then
                    ui.navigationMode = "grid"
                    ui.uIkeyboardNavigationActive = false
                    ui.keyboardNavInitiated = false
                    ui.activeUIElement = nil
                    ui.currentUIElementIndex = nil
                end
                if HOVER_INDICATOR_STATE then
                    HOVER_INDICATOR_STATE.IS_HIDDEN = false
                end
            end

            if key == "return" or key == "space" then
                if ui and ui.gameOverPanel then
                    ui.gameOverPanel.visible = true
                    if ui.drawReturnToResultsButton then
                        ui:drawReturnToResultsButton()
                    end
                    ui:initializeUIElements()
                end
                return true
            end

            -- Allow remaining keys (like grid navigation) to fall through
        else
            -- Ensure UI is set up for keyboard navigation while results panel is visible
            if ui then
                -- Ensure grid hover indicator is hidden
                HOVER_INDICATOR_STATE.IS_HIDDEN = true

                -- Force UI into keyboard navigation mode
                ui.navigationMode = "ui"
                ui.uIkeyboardNavigationActive = true
                ui.keyboardNavInitiated = false

                -- Handle directional keys for navigation
                if key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d" then
                    ui.keyboardNavInitiated = false
                    local result = ui:navigateUI(key)
                    return true
                elseif key == "return" or key == "space" then
                    ui.keyboardNavInitiated = false
                    -- Execute button action directly
                    if ui.activeUIElement then
                        local elementName = ui.activeUIElement.name or ""

                        if elementName == "mainMenuButton" then
                            -- Show confirmation dialog
                            ConfirmDialog.show(
                                "Return to main menu?",
                                function()
                                    if stateMachineRef then
                                        stateMachineRef.changeState("mainMenu")
                                    end
                                end,
                                function() end
                            )
                        elseif elementName == "toggleButton" then
                            -- Show battlefield without dialog
                            ui.gameOverPanel.visible = false
                            ui:drawReturnToResultsButton()
                            ui:initializeUIElements()

                            -- Set focus to return button
                            for i, element in ipairs(ui.uiElements) do
                                if element.name == "returnButton" then
                                    ui.currentUIElementIndex = i
                                    ui.activeUIElement = element
                                    ui.navigationMode = "ui"
                                    ui.uIkeyboardNavigationActive = true
                                    HOVER_INDICATOR_STATE.IS_HIDDEN = true
                                    ui:syncKeyboardAndMouseFocus()
                                    return true
                                end
                            end
                        elseif elementName == "returnButton" then
                            -- Go back to game over screen
                            ui.gameOverPanel.visible = true
                            ui:initializeUIElements()

                            -- Set focus to toggle button
                            for i, element in ipairs(ui.uiElements) do
                                if element.name == "toggleButton" then
                                    ui.currentUIElementIndex = i
                                    ui.activeUIElement = element
                                    ui.navigationMode = "ui"
                                    ui.uIkeyboardNavigationActive = true
                                    ui:syncKeyboardAndMouseFocus()
                                    return true
                                end
                            end
                        elseif elementName == "gameLogPanel" then
                            -- Open Game Log viewer from Battlefield view (results hidden)
                            if ui.activeUIElement.action then
                                local handled = ui.activeUIElement.action()
                                if handled == true then return true end
                            end
                            if GameLogViewer and GameLogViewer.show then
                                GameLogViewer.show(gameRuler)
                            end
                            return true
                        end
                    end
                    return true
                end

                if key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d" then
                    -- Let UI handle navigation keys
                    ui.keyboardNavInitiated = false
                    ui:navigateUI(key)

                    -- Get fresh reference to the active element based on the current index
                    if ui.activeUIElement.name == "returnButton" then
                        -- Highlight active button
                        ui.gameOverPanel.returnButton.currentColor = ui.gameOverPanel.returnButton.hoverColor
                        -- Reset others to normal
                        ui.gameOverPanel.toggleButton.currentColor = {10/255, 70/255, 150/255} -- Darker blue
                        ui.gameOverPanel.button.currentColor = {10/255, 70/255, 150/255} -- Darker blue
                    end

                    if ui.activeUIElement.name == "toggleButton" then
                        -- Highlight active button
                        ui.gameOverPanel.toggleButton.currentColor = ui.gameOverPanel.toggleButton.hoverColor
                        -- Reset others to normal
                        ui.gameOverPanel.returnButton.currentColor = {120/255, 30/255, 30/255} -- Darker red
                        ui.gameOverPanel.button.currentColor = {10/255, 70/255, 150/255} -- Darker blue
                    end

                    if ui.activeUIElement.name == "mainMenuButton" then
                        -- Highlight active button
                        ui.gameOverPanel.button.currentColor = ui.gameOverPanel.button.hoverColor
                        -- Reset others to normal
                        ui.gameOverPanel.returnButton.currentColor = {120/255, 30/255, 30/255} -- Darker red
                        ui.gameOverPanel.toggleButton.currentColor = {10/255, 70/255, 150/255} -- Darker blue
                    end

                    return true
                end
            end

            -- Block ALL other keyboard input in game over mode while panel is visible
            return true
        end
    end

    -- Check if mouse is over UI element but keyboard navigation isn't active
    if (key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d" or key == "return" or key == "space") and
       ui and grid and grid.uiNavigationActive then
        -- Mouse was over UI but keyboard key was pressed - ensure we're in UI keyboard navigation mode
        ui.navigationMode = "ui"
        ui.uIkeyboardNavigationActive = true
        ui.keyboardNavInitiated = false
        HOVER_INDICATOR_STATE.IS_HIDDEN = true
        
        -- Initialize UI elements if needed
        if #ui.uiElements == 0 then
            ui:initializeUIElements()
        end
        
        -- Find the UI element under the mouse position
        local foundElement = false
        for i, element in ipairs(ui.uiElements) do
            if mousePos.x >= element.x and mousePos.x <= element.x + element.width and
               mousePos.y >= element.y and mousePos.y <= element.y + element.height then
                ui.currentUIElementIndex = i
                ui.activeUIElement = ui.uiElements[i]
                foundElement = true
                ui:syncKeyboardAndMouseFocus()
                break
            end
        end
        
        -- If no element found directly under mouse, find closest one
        if not foundElement then
            local closestIndex = 1
            local closestDistance = math.huge
            
            for i, element in ipairs(ui.uiElements) do
                if element.type == "supplyUnit" then
                    local centerX = element.x + element.width/2
                    local centerY = element.y + element.height/2
                    local distance = math.sqrt((mousePos.x - centerX)^2 + (mousePos.y - centerY)^2)
                    
                    if distance < closestDistance then
                        closestDistance = distance
                        closestIndex = i
                    end
                end
            end
            
            ui.currentUIElementIndex = closestIndex
            ui.activeUIElement = ui.uiElements[closestIndex]
            ui:syncKeyboardAndMouseFocus()
        end
    end

    -- Handle key presses
    if key == "escape" then
        if isOnlineModeActive() and gameRuler and gameRuler.currentPhase ~= "gameOver" then
            if not canOfferOnlineConcede() then
                if not finalizeBrokenOnlineMatchIfPossible("escape_broken_session", tostring(onlineSession and onlineSession.disconnectReason or "connection_lost")) then
                    returnBrokenOnlineMatchToMainMenu(tostring(onlineSession and onlineSession.disconnectReason or "connection_lost"))
                end
                return true
            end
            ConfirmDialog.show(
                "Concede match? This will count as a forfeit.",
                function()
                    requestSurrenderFromUi()
                end,
                function() end,
                {
                    title = "Concede Match",
                    confirmText = "Concede",
                    cancelText = "Cancel",
                    defaultFocus = "cancel"
                }
            )
            return true
        end

        if buildingPlacementMode then
            -- Cancel placement mode if active
            buildingPlacementMode = false
        elseif hasActiveUnitSelection() then
            -- Cancel selected unit/action preview first; only open menu when nothing is selected.
            clearActiveUnitSelection()
            return true
        else
            -- Show confirmation dialog for returning to main menu
            ConfirmDialog.show(
                "Return to main menu? Progress will be lost and not saved.",
                function()
                    -- Confirmed - return to main menu
                    manualNoSaveExitRequested = isResumeSupportedMode() and gameRuler and gameRuler.currentPhase ~= "gameOver"
                    if stateMachineRef then
                        stateMachineRef.changeState("mainMenu")
                    end
                end,
                function()
                    -- Canceled - continue game
                    manualNoSaveExitRequested = false
                end
            )
            return true
        end
    elseif key == "1" or key == "kp1" then
        -- Block in AI vs AI mode
        if gameMode == GAME.MODE.AI_VS_AI then
            return true
        end
        if isRemotePlayLocalMode() and not canCurrentInputIssueActions() then
            return true
        end
        focusSupplyPanel(1)
        return true
    elseif key == "2" or key == "kp2" then
        -- Block in AI vs AI mode
        if gameMode == GAME.MODE.AI_VS_AI then
            return true
        end
        if isRemotePlayLocalMode() and not canCurrentInputIssueActions() then
            return true
        end
        focusSupplyPanel(2)
        return true
    elseif key == "up" or key == "down" or key == "left" or key == "right" or key == "w" or key == "s" or key == "a" or key == "d" then
        local actionInputAllowed = canCurrentInputIssueActions()
        local allowReadOnlyTurn = isCurrentInputReadOnlyBlocked()

        -- IMPORTANT: If in UI mode with mouse navigation, switch to keyboard navigation
        if ui and ui.navigationMode == "ui" and not ui.uIkeyboardNavigationActive and not allowReadOnlyTurn then
            -- Activate keyboard navigation
            ui.uIkeyboardNavigationActive = true
            ui.navigationMode = "ui"
            HOVER_INDICATOR_STATE.IS_HIDDEN = true

            -- Initialize UI elements if needed
            if #ui.uiElements == 0 then
                ui:initializeUIElements()
            end

            -- Find closest UI element to current mouse position
            local closestIndex = 1
            local closestDistance = math.huge

            for i, element in ipairs(ui.uiElements) do
                if element.type == "supplyUnit" then
                    local centerX = element.x + element.width/2
                    local centerY = element.y + element.height/2
                    local distance = math.sqrt((mousePos.x - centerX)^2 + (mousePos.y - centerY)^2)

                    if distance < closestDistance then
                        closestDistance = distance
                        closestIndex = i
                    end
                end
            end

            -- Set active UI element
            ui.currentUIElementIndex = closestIndex
            ui.activeUIElement = ui.uiElements[closestIndex]

            -- Sync focus and call now to ensure UI state is properly updated
            ui:syncKeyboardAndMouseFocus()
            -- Continue with normal UI navigation after setup
        end

        if allowReadOnlyTurn and ui and ui.navigationMode == "ui" and ui.uIkeyboardNavigationActive then
            local activeName = ui.activeUIElement and ui.activeUIElement.name or nil
            if not isReadOnlyUiControlName(activeName) then
                ui.navigationMode = "grid"
                ui.uIkeyboardNavigationActive = false
                ui.currentUIElementIndex = nil
                ui.activeUIElement = nil
                if ui.clearGameLogPanelHover then
                    ui:clearGameLogPanelHover()
                end
                HOVER_INDICATOR_STATE.IS_HIDDEN = false
            end
        end

        -- Check if we're navigating the UI or the grid
        -- print("DEBUG: gameplay.lua - key:", key, "ui exists:", ui ~= nil, "navigationMode:", ui and ui.navigationMode, "uIkeyboardNavigationActive:", ui and ui.uIkeyboardNavigationActive)
        if ui and ui.navigationMode == "ui" and ui.uIkeyboardNavigationActive then
            -- print("DEBUG: gameplay.lua - calling ui:navigateUI")
            -- Let the UI handle navigation
            local handled = ui:navigateUI(key)
            -- print("DEBUG: gameplay.lua - ui:navigateUI returned:", handled)
            if handled then
                return true
            end
        else
            -- Handle grid navigation with arrow keys
            if grid and gameRuler then
                -- Block keyboard input during AI turns or animations
                if ((not actionInputAllowed) and (not allowReadOnlyTurn)) or
                   gameMode == GAME.MODE.AI_VS_AI or
                   gameRuler:isAnimationInProgress() then
                    return true
                end

                -- Update the keyboardSelectedCell position
                local currentCell = grid.keyboardSelectedCell
                local newRow = currentCell.row
                local newCol = currentCell.col

                if key == "up" or key == "w" then
                    newRow = math.max(1, newRow - 1)
                elseif key == "down" or key == "s" then
                    newRow = math.min(GAME.CONSTANTS.GRID_SIZE, newRow + 1)
                elseif key == "left" or key == "a" then
                    if newCol == 1 then
                        -- Check if we're in rows 4,5,6,7,8 - if so, go to game log panel
                        if newRow >= 4 and newRow <= 8 then
                            -- Navigate to game log panel
                            ui.navigationMode = "ui"
                            ui.uIkeyboardNavigationActive = true
                            HOVER_INDICATOR_STATE.IS_HIDDEN = true

                            if grid then
                                grid.mouseHoverCell = nil
                            end

                            -- First ensure UI elements are initialized
                            ui:initializeUIElements()

                            -- Find game log panel
                            for i, element in ipairs(ui.uiElements) do
                                if element.name == "unitCodexButton" then
                                    ui.currentUIElementIndex = i
                                    ui.activeUIElement = ui.uiElements[i]
                                    ui:syncKeyboardAndMouseFocus()
                                    return true
                                elseif element.name == "gameLogPanel" then
                                    ui.currentUIElementIndex = i
                                    ui.activeUIElement = ui.uiElements[i]
                                    ui:syncKeyboardAndMouseFocus()
                                    return true
                                end
                            end
                        elseif allowReadOnlyTurn then
                            -- Non-local online turn stays read-only on the board;
                            -- only game log (rows 4-8) is reachable from grid left edge.
                            HOVER_INDICATOR_STATE.IS_HIDDEN = false
                            newCol = 1
                        else
                            -- At left border, wrap to supply panel 1
                            ui.navigationMode = "ui"
                            ui.uIkeyboardNavigationActive = true
                            HOVER_INDICATOR_STATE.IS_HIDDEN = true

                            if grid then
                                grid.mouseHoverCell = nil
                            end

                            -- Map grid rows to supply panel positions
                            local supplyPanelRow = 1
                            local supplyPanelCol = 4  -- Always go to rightmost column of left panel

                            if newRow == 1 then
                                supplyPanelRow = 1  -- Grid row 1 → Supply panel row 1
                            elseif newRow == 2 then
                                supplyPanelRow = 2  -- Grid row 2 → Supply panel row 2
                            else
                                supplyPanelRow = 4  -- Grid rows 3-8 → Supply panel row 4
                            end
                            
                            -- First ensure UI elements are initialized
                            ui:initializeUIElements()

                            ui.currentNavPanel = 1
                            ui.currentNavRow = supplyPanelRow
                            ui.currentNavCol = supplyPanelCol
                            
                            -- Clear sound tracking to ensure sound plays on first supply panel highlight
                            ui.lastSupplyKey = nil
                            ui.lastMouseSupplyKey = nil
                            
                            -- Find the target element in the left panel
                            local targetIndex = ((supplyPanelRow - 1) * 4) + 4  -- Column 4
                            local count = 0
                            local foundElement = false
                            
                            for i, element in ipairs(ui.uiElements) do
                                if element.type == "supplyUnit" and element.unitData and element.unitData.panelPlayer == 1 then
                                    count = count + 1
                                    if count == targetIndex then
                                        ui.currentUIElementIndex = i
                                        ui.activeUIElement = ui.uiElements[ui.currentUIElementIndex]
                                        foundElement = true
                                        ui:syncKeyboardAndMouseFocus()
                                        return true 
                                    end
                                end
                            end

                            -- Fallback if specific cell not found - find any cell in left panel
                            if not foundElement then
                                for i, element in ipairs(ui.uiElements) do
                                    if element.type == "supplyUnit" and element.unitData and element.unitData.panelPlayer == 1 then
                                        ui.currentUIElementIndex = i
                                        ui.activeUIElement = ui.uiElements[ui.currentUIElementIndex]
                                        ui:syncKeyboardAndMouseFocus()
                                        return true
                                    end
                                end
                            end
                        end
                    else
                        HOVER_INDICATOR_STATE.IS_HIDDEN = false
                        newCol = math.max(1, newCol - 1)
                    end
                elseif key == "right" or key == "d" then
                    if newCol == GAME.CONSTANTS.GRID_SIZE then
                        if gameMode == GAME.MODE.SCENARIO and ui then
                            ui:initializeUIElements()
                            local scenarioTargetName = (newRow >= 5) and "scenarioRetryButton" or "scenarioBackButton"
                            local scenarioTargetIndex = nil

                            for i, element in ipairs(ui.uiElements) do
                                if element.type == "button" and element.name == scenarioTargetName then
                                    scenarioTargetIndex = i
                                    break
                                end
                            end

                            if not scenarioTargetIndex then
                                for i, element in ipairs(ui.uiElements) do
                                    if element.type == "button" and (element.name == "scenarioBackButton" or element.name == "scenarioRetryButton") then
                                        scenarioTargetIndex = i
                                        break
                                    end
                                end
                            end

                            if scenarioTargetIndex then
                                ui.navigationMode = "ui"
                                ui.uIkeyboardNavigationActive = true
                                HOVER_INDICATOR_STATE.IS_HIDDEN = true
                                ui.currentUIElementIndex = scenarioTargetIndex
                                ui.activeUIElement = ui.uiElements[scenarioTargetIndex]
                                ui:clearHoveredInfo()
                                ui:setContent(nil)
                                ui:syncKeyboardAndMouseFocus()
                                return true
                            end

                            HOVER_INDICATOR_STATE.IS_HIDDEN = false
                            newCol = GAME.CONSTANTS.GRID_SIZE
                        elseif allowReadOnlyTurn then
                            -- Non-local online turn: keep board read-only and optionally
                            -- allow quick access to surrender from lower-right area.
                            if newRow >= 5 and newRow <= 8 and ui then
                                ui:initializeUIElements()
                                for i, element in ipairs(ui.uiElements) do
                                    if element.type == "button" and element.name == "surrenderButton" and
                                       element.visible ~= false and element.active ~= false then
                                        ui.navigationMode = "ui"
                                        ui.uIkeyboardNavigationActive = true
                                        HOVER_INDICATOR_STATE.IS_HIDDEN = true
                                        ui.currentUIElementIndex = i
                                        ui.activeUIElement = element
                                        ui:clearHoveredInfo()
                                        ui:setContent(nil)
                                        ui:syncKeyboardAndMouseFocus()
                                        return true
                                    end
                                end
                            end
                            HOVER_INDICATOR_STATE.IS_HIDDEN = false
                            newCol = GAME.CONSTANTS.GRID_SIZE
                        else
                        -- At right border, check row position
                        if newRow <= 4 then
                            -- Rows 1-4: Wrap to supply panel 2 as before
                            ui.navigationMode = "ui"
                            ui.uIkeyboardNavigationActive = true
                            HOVER_INDICATOR_STATE.IS_HIDDEN = true

                            if grid then
                                grid.mouseHoverCell = nil -- Hide the mouse hover indicator
                            end

                            -- Map grid rows to supply panel positions
                            local supplyPanelRow = 1
                            local supplyPanelCol = 1  -- Always go to leftmost column of right panel

                            if newRow == 1 then
                                supplyPanelRow = 1  -- Grid row 1 → Supply panel row 1
                            elseif newRow == 2 then
                                supplyPanelRow = 2  -- Grid row 2 → Supply panel row 2
                            else
                                supplyPanelRow = 4  -- Grid rows 3-4 → Supply panel row 4
                            end

                            -- First ensure UI elements are initialized
                            ui:initializeUIElements()

                            ui.currentNavPanel = 2
                            ui.currentNavRow = supplyPanelRow
                            ui.currentNavCol = supplyPanelCol

                            -- Clear sound tracking to ensure sound plays on first supply panel highlight
                            ui.lastSupplyKey = nil
                            ui.lastMouseSupplyKey = nil

                            -- Find the target element in the right panel
                            local targetIndex = ((supplyPanelRow - 1) * 4) + 1  -- Column 1
                            local count = 0
                            local foundElement = false

                            for i, element in ipairs(ui.uiElements) do
                                if element.type == "supplyUnit" and element.unitData and element.unitData.panelPlayer == 2 then
                                    count = count + 1
                                    if count == targetIndex then
                                        ui.currentUIElementIndex = i
                                        ui.activeUIElement = ui.uiElements[ui.currentUIElementIndex]
                                        foundElement = true
                                        ui:syncKeyboardAndMouseFocus()
                                        return true
                                    end
                                end
                            end

                            -- Fallback if specific cell not found - find any cell in right panel or phase button
                            if not foundElement then
                                -- First check for phase button
                                for i, element in ipairs(ui.uiElements) do
                                    if element.type == "button" and element.name == "phaseButton" then
                                        ui.currentUIElementIndex = i
                                        ui.activeUIElement = ui.uiElements[ui.currentUIElementIndex]
                                        ui:syncKeyboardAndMouseFocus()
                                        return true
                                    end
                                end

                                -- If no phase button, try any right panel cell
                                for i, element in ipairs(ui.uiElements) do
                                    if element.type == "supplyUnit" and element.unitData and element.unitData.panelPlayer == 2 then
                                        ui.currentUIElementIndex = i
                                        ui.activeUIElement = ui.uiElements[ui.currentUIElementIndex]
                                        ui:syncKeyboardAndMouseFocus()
                                        return true
                                    end
                                end
                            end
                        else
                            -- Rows 5-8: Check if phase button is active
                            local phaseButtonFound = false

                            -- First ensure UI elements are initialized
                            ui:initializeUIElements()

                            -- Look for phase button
                            for i, element in ipairs(ui.uiElements) do
                                if element.type == "button" and element.name == "phaseButton" and 
                                   element.visible ~= false and element.active ~= false then
                                    -- Phase button is active and visible, focus on it
                                    ui.navigationMode = "ui"
                                    ui.uIkeyboardNavigationActive = true
                                    HOVER_INDICATOR_STATE.IS_HIDDEN = true
                                    ui.currentUIElementIndex = i
                                    ui.activeUIElement = element
                                    phaseButtonFound = true

                                    ui:clearHoveredInfo()
                                    -- Now set content to nil
                                    ui:setContent(nil)
                                    ui:syncKeyboardAndMouseFocus()
                                    return true
                                end
                            end

                            -- If no active phase button found, use default fallback (stay at column 8)
                            if not phaseButtonFound then
                                HOVER_INDICATOR_STATE.IS_HIDDEN = false
                                newCol = GAME.CONSTANTS.GRID_SIZE  -- Stay at rightmost column
                            end
                        end
                        end
                    else
                        HOVER_INDICATOR_STATE.IS_HIDDEN = false
                        newCol = math.min(GAME.CONSTANTS.GRID_SIZE, newCol + 1)
                    end
                end

                -- Update the selection
                grid.keyboardSelectedCell = {row = newRow, col = newCol}

                -- Play keyboard navigation sound directly if SFX is enabled
                if SETTINGS.AUDIO.SFX then
                    soundCache.play("assets/audio/GenericButton14.wav", {
                        clone = false,
                        volume = SETTINGS.AUDIO.SFX_VOLUME,
                        category = "sfx"
                    })
                end

                -- Update the mouse hover cell to match keyboard selection for visual feedback
                local cell = grid:getCell(newRow, newCol)
                if cell then
                    grid.mouseHoverCell = cell

                    -- Update indicator color based on selection and possible actions
                    grid:showHoverIndicator(cell)
                end
            end
        end
    elseif key == "return" or key == "space" then
        local actionInputAllowed = canCurrentInputIssueActions()
        local readOnlyBlocked = isCurrentInputReadOnlyBlocked()
        -- Check if we're in UI navigation mode
        if ui and ui.navigationMode == "ui" and ui.uIkeyboardNavigationActive then
            if isOnlineModeActive() and actionInputAllowed and ui.activeUIElement and ui.activeUIElement.name == "phaseButton" and ui.phaseButton then
                local actionType = ui.phaseButton.actionType
                if actionType and actionType ~= "" and actionType ~= "ReturnToMainMenu" then
                    local normalizedAction = actionType
                    if actionType == "endActions" or actionType == "confirmEndTurn" then
                        normalizedAction = "end_turn"
                    end
                    local ok
                    if normalizedAction == "end_turn" then
                        local phaseInfo = gameRuler:getCurrentPhaseInfo() or {}
                        local advanceKey = onlineAutoAdvanceState.buildKey("end_turn", phaseInfo)
                        ok = executeOrQueueCommand({ actionType = "end_turn" })
                        if ok then
                            onlineAutoAdvanceState.issuedKey = advanceKey
                            onlineAutoAdvanceState.resetCandidate()
                            print(string.format(
                                "[OnlineGameplay] END_TURN_REQUEST source=%s key=%s",
                                "phase_button_keyboard",
                                tostring(advanceKey)
                            ))
                        end
                    else
                        ok = executeOrQueueCommand({ actionType = normalizedAction })
                    end
                    if ok then
                        clearActiveUnitSelection()
                    end
                    return true
                end
            end

            if readOnlyBlocked then
                local activeName = ui.activeUIElement and ui.activeUIElement.name or nil
                if not isReadOnlyUiControlName(activeName) then
                    return true
                end
            end

            -- Let the UI handle the action
            local handled = ui:navigateUI(key)
            if handled then
                return true
            end
        else
            if not actionInputAllowed then
                return true
            end

            -- Handle Enter key press for grid - simulate mouse click at the selected cell
            if grid and grid.keyboardSelectedCell then
                local row = grid.keyboardSelectedCell.row
                local col = grid.keyboardSelectedCell.col
                local cell = grid:getCell(row, col)

                if cell then
                    -- Convert grid coordinates to screen coordinates
                    local screenX = cell.x + GAME.CONSTANTS.TILE_SIZE / 2
                    local screenY = cell.y + GAME.CONSTANTS.TILE_SIZE / 2
                    handleGridClick(screenX, screenY)
                end
            end
        end
    end
end

function gameplay.keyreleased(key, scancode)
    -- Route key releases to game log viewer to stop hold-to-scroll
    if GameLogViewer and GameLogViewer.isActive and GameLogViewer.isActive() and GameLogViewer.keyreleased then
        local handled = GameLogViewer.keyreleased(key)
        if handled then return true end
    end
end

--------------------------------------------------
function gameplay.shouldShowRemotePlayCursor()
    if not isRemotePlayLocalMode() then
        return false
    end
    return canCurrentInputIssueActions()
end

return gameplay
