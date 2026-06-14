local onlineLobby = {}

local ConfirmDialog = require("confirmDialog")
local uiTheme = require("uiTheme")
local menuBackground = require("menu_background")
local steamRuntime = require("steam_runtime")
local onlineRatingStore = require("online_rating_store")
local Controller = require("controller")
local SteamOnlineSession = require("steam_online_session")
local SteamLockstep = require("steam_lockstep")
local soundCache = require("soundCache")
local os = require("os")

local stateMachineRef = nil
local session = nil
local uiButtons = nil
local buttonOrder = {}
local selectedButtonIndex = 1
local listFocus = true
local ratingsFetchKey = nil
local switchedToFactionSelect = false
local statusBarText = "Ready"
local statusBarSeverity = "info"

local lobbyList = {}
local selectedLobbyIndex = 1
local scrollOffsetRows = 0
local lastLobbyRefreshAt = 0
local refreshInFlight = false
local joinInFlight = false
local createInFlight = false
local inviteJoinDirectFactionLobbyId = nil
local lastOnlineReady = nil
local consumeOnlineRatingRepairNotice = nil

local scrollbarDragging = false
local scrollbarDragAnchorY = 0
local scrollbarDragAnchorOffset = 0

local AUTO_LOBBY_REFRESH_SEC = 3
local ELO_REFRESH_INTERVAL_SEC = 5
local lobbyOwnerEloBySteamId = {}
local lastEloRefreshAt = 0

local function resolveStoredOnlineRatingSeed(defaultRating)
    local fallback = tonumber(defaultRating) or 1200
    if onlineRatingStore and type(onlineRatingStore.loadProfile) == "function" then
        local profile = onlineRatingStore.loadProfile()
        if consumeOnlineRatingRepairNotice then
            consumeOnlineRatingRepairNotice("rating_seed")
        end
        if type(profile) == "table" and tonumber(profile.rating) ~= nil then
            return math.floor((tonumber(profile.rating) or fallback) + 0.5)
        end
    end
    return fallback
end
local eloRefreshInFlight = false
local currentLobbySnapshot = nil
local lastTransitionGateSummary = nil
local lastTransitionGateLogAt = 0
local lastHoveredButtonIndex = nil
local lobbyEnterAt = 0
local ENTRY_ACTIVATION_GUARD_SEC = 0.18
local peerTransitionEligibleSince = nil
local updateButtonStates

local BUTTON_BEEP_SOUND_PATH = "assets/audio/GenericButton14.wav"
local BUTTON_CLICK_SOUND_PATH = "assets/audio/GenericButton6.wav"

local LAYOUT = {
    panelMarginX = 40,
    panelTop = 54,
    panelBottom = 152,
    headerHeight = 34,
    listPadding = 10,
    listColumnsHeaderHeight = 22,
    rowHeight = 34,
    scrollbarWidth = 12,
    buttonRowY = SETTINGS.DISPLAY.HEIGHT - 100,
    buttonWidth = 210,
    buttonHeight = 50,
    buttonGap = 14
}

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.time()
end

local function lobbyLog(message)
    print("[OnlineLobby] " .. tostring(message))
end

consumeOnlineRatingRepairNotice = function(context)
    if not onlineRatingStore or type(onlineRatingStore.consumeRepairNotice) ~= "function" then
        return
    end

    local repairNotice = onlineRatingStore.consumeRepairNotice()
    if repairNotice then
        lobbyLog(string.format(
            "Rating profile repaired during %s: %s",
            tostring(context or "online_lobby"),
            tostring(repairNotice.text or repairNotice.title or "repair_complete")
        ))
    end
end

local function setStatusBar(text, severity)
    statusBarText = tostring(text or "")
    statusBarSeverity = severity or "info"
end

local function getStatusBarColor()
    if statusBarSeverity == "error" then
        return 0.78, 0.34, 0.34, 0.95
    end
    if statusBarSeverity == "warn" then
        return 0.84, 0.72, 0.36, 0.95
    end
    if statusBarSeverity == "ok" then
        return 0.45, 0.75, 0.55, 0.95
    end
    return 0.72, 0.74, 0.78, 0.95
end

local function hasConnectedPeer()
    if not session then
        return false
    end
    if session.connected ~= true then
        return false
    end
    if not session.peerUserId then
        return false
    end
    return tostring(session.peerUserId) ~= tostring(session.localUserId)
end

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

local function ensureOnlineRuntimeState()
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    local online = GAME.CURRENT.ONLINE
    online.pendingLobbyEvents = online.pendingLobbyEvents or {}
    return online
end

local function clearOnlineRuntimeState(reasonCode)
    local online = ensureOnlineRuntimeState()
    online.active = false
    online.role = nil
    online.factionRole = nil
    online.session = nil
    online.lockstep = nil
    online.autoJoinLobbyId = nil
    online.pendingInviteJoinLobbyId = nil
    online.pendingInviteJoinDirectToFaction = nil
    online.pendingInvitePrompt = nil
    online.lastInvitePromptKey = nil
    online.lastInvitePromptAt = 0
    online.inviteWaitStartedAt = nil
    online.inviteWaitPromptShown = nil
    online.inviteArrivalNoticePending = nil
    online.inviteArrivalNoticeShown = nil
    online.pendingLobbyEvents = {}
    online.eloSummary = nil
    if reasonCode then
        online.resultCode = reasonCode
    end
end

local function clearOnlineInviteWaitPromptState()
    local online = ensureOnlineRuntimeState()
    online.inviteWaitStartedAt = nil
    online.inviteWaitPromptShown = nil
    online.inviteArrivalNoticePending = nil
    online.inviteArrivalNoticeShown = nil
end

local function armOnlineInviteWaitPrompt()
    local online = ensureOnlineRuntimeState()
    online.inviteWaitStartedAt = nowSeconds()
    online.inviteWaitPromptShown = false
    online.inviteArrivalNoticePending = true
    online.inviteArrivalNoticeShown = false
end

local function consumePendingLobbyEvents(maxEvents)
    local online = ensureOnlineRuntimeState()
    local queue = online.pendingLobbyEvents
    if type(queue) ~= "table" or #queue == 0 then
        return {}
    end

    local limit = maxEvents or #queue
    if limit < 1 then
        limit = #queue
    end

    local events = {}
    local count = math.min(limit, #queue)
    for i = 1, count do
        events[#events + 1] = table.remove(queue, 1)
    end
    return events
end

local function consumePendingInviteJoinLobbyId()
    local online = ensureOnlineRuntimeState()
    local lobbyId = online.pendingInviteJoinLobbyId
    local directToFaction = online.pendingInviteJoinDirectToFaction == true
    online.pendingInviteJoinLobbyId = nil
    online.pendingInviteJoinDirectToFaction = nil
    if lobbyId == nil then
        return nil, false
    end
    return tostring(lobbyId), directToFaction
end

local function getListRect()
    local x = LAYOUT.panelMarginX
    local y = LAYOUT.panelTop
    local width = SETTINGS.DISPLAY.WIDTH - (LAYOUT.panelMarginX * 2)
    local height = SETTINGS.DISPLAY.HEIGHT - LAYOUT.panelTop - LAYOUT.panelBottom
    return x, y, width, height
end

local function getListContentRect()
    local x, y, width, height = getListRect()
    local contentX = x + LAYOUT.listPadding
    local contentY = y + LAYOUT.headerHeight + LAYOUT.listPadding
    local contentWidth = width - (LAYOUT.listPadding * 2) - LAYOUT.scrollbarWidth - 4
    local contentHeight = height - LAYOUT.headerHeight - (LAYOUT.listPadding * 2)
    return contentX, contentY, contentWidth, contentHeight
end

local function visibleLobbyRows()
    local _, _, _, contentHeight = getListContentRect()
    local rowsHeight = math.max(0, contentHeight - LAYOUT.listColumnsHeaderHeight)
    return math.max(1, math.floor(rowsHeight / LAYOUT.rowHeight))
end

local function maxScrollOffsetRows()
    return math.max(0, #lobbyList - visibleLobbyRows())
end

local function clampSelectedLobbyIndex()
    if #lobbyList == 0 then
        selectedLobbyIndex = 1
        scrollOffsetRows = 0
        return
    end

    if selectedLobbyIndex < 1 then
        selectedLobbyIndex = 1
    elseif selectedLobbyIndex > #lobbyList then
        selectedLobbyIndex = #lobbyList
    end

    local visible = visibleLobbyRows()
    if selectedLobbyIndex <= scrollOffsetRows then
        scrollOffsetRows = selectedLobbyIndex - 1
    elseif selectedLobbyIndex > scrollOffsetRows + visible then
        scrollOffsetRows = selectedLobbyIndex - visible
    end

    local maxOffset = maxScrollOffsetRows()
    if scrollOffsetRows < 0 then
        scrollOffsetRows = 0
    elseif scrollOffsetRows > maxOffset then
        scrollOffsetRows = maxOffset
    end
end

local function setSelectedLobbyIndex(index)
    selectedLobbyIndex = index
    clampSelectedLobbyIndex()
end

local function selectedLobbyEntry()
    return lobbyList[selectedLobbyIndex]
end

local function setScrollOffsetRows(offset)
    local maxOffset = maxScrollOffsetRows()
    local nextOffset = math.floor(offset)
    if nextOffset < 0 then
        nextOffset = 0
    elseif nextOffset > maxOffset then
        nextOffset = maxOffset
    end

    scrollOffsetRows = nextOffset
    clampSelectedLobbyIndex()
end

local function scrollRows(delta)
    setScrollOffsetRows(scrollOffsetRows + delta)
end

local function getScrollbarGeometry()
    local x, y, width, height = getListRect()
    local trackX = x + width - LAYOUT.listPadding - LAYOUT.scrollbarWidth
    local trackY = y + LAYOUT.headerHeight + LAYOUT.listPadding + LAYOUT.listColumnsHeaderHeight
    local trackHeight = height - LAYOUT.headerHeight - (LAYOUT.listPadding * 2) - LAYOUT.listColumnsHeaderHeight

    local visible = visibleLobbyRows()
    local total = #lobbyList
    if total <= visible then
        return {
            visible = false,
            trackX = trackX,
            trackY = trackY,
            trackHeight = trackHeight,
            thumbY = trackY,
            thumbHeight = trackHeight
        }
    end

    local maxOffset = maxScrollOffsetRows()
    local thumbHeight = math.max(24, math.floor(trackHeight * (visible / total)))
    local thumbTravel = trackHeight - thumbHeight
    local ratio = maxOffset > 0 and (scrollOffsetRows / maxOffset) or 0
    local thumbY = trackY + math.floor(thumbTravel * ratio)

    return {
        visible = true,
        trackX = trackX,
        trackY = trackY,
        trackHeight = trackHeight,
        thumbY = thumbY,
        thumbHeight = thumbHeight,
        thumbTravel = thumbTravel,
        maxOffset = maxOffset
    }
end

local function formatRelationLabel(relation)
    if relation == "friend" then
        return "Friend"
    end
    if relation == "friend_of_friend" then
        return "FoF"
    end
    return "Other"
end

local function relationPriority(relation)
    if relation == "friend" then
        return 0
    end
    if relation == "friend_of_friend" then
        return 1
    end
    return 2
end

local function normalizeVisibility(value)
    if tostring(value) == "friends" then
        return "friends"
    end
    return "public"
end

local function formatVisibilityLabel(value)
    return normalizeVisibility(value) == "friends" and "Friends Only" or "Public"
end

local function isEntryJoinable(entry)
    return entry and entry.joinable ~= false
end

local function sortAndFilterAvailableLobbies(entries)
    local available = {}
    local localLobbyId = session and session.lobbyId and tostring(session.lobbyId) or nil

    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" and entry.lobbyId then
            local entryLobbyId = tostring(entry.lobbyId)
            local isLocalEntry = localLobbyId and entryLobbyId == localLobbyId
            entry.visibility = normalizeVisibility(entry.visibility)

            if isLocalEntry then
                available[#available + 1] = entry
            elseif isEntryJoinable(entry) then
                -- AppID 480 relation metadata is not always reliable; keep tagged rows visible.
                available[#available + 1] = entry
            end
        end
    end

    table.sort(available, function(a, b)
        local relationCmp = relationPriority(a.relation) - relationPriority(b.relation)
        if relationCmp ~= 0 then
            return relationCmp < 0
        end

        local joinCmp = (isEntryJoinable(a) and 0 or 1) - (isEntryJoinable(b) and 0 or 1)
        if joinCmp ~= 0 then
            return joinCmp < 0
        end

        local memberCmp = (tonumber(a.memberCount) or 0) - (tonumber(b.memberCount) or 0)
        if memberCmp ~= 0 then
            return memberCmp < 0
        end

        return tostring(a.lobbyId or "") < tostring(b.lobbyId or "")
    end)

    return available
end

local function defaultEloScore()
    return (((SETTINGS.RATING or SETTINGS.ELO) or {}).DEFAULT_RATING) or 1200
end

local function getOwnerEloInfo(ownerId)
    if not ownerId then
        return defaultEloScore(), "-"
    end

    local cached = lobbyOwnerEloBySteamId[tostring(ownerId)]
    if not cached then
        return defaultEloScore(), "-"
    end

    local score = tonumber(cached.score) or defaultEloScore()
    local rank = tonumber(cached.rank)
    return score, rank and tostring(rank) or "-"
end

local function buildLocalHostLobbyRow()
    if not session or not session.active or session.role ~= "host" or not session.lobbyId then
        return nil
    end

    local memberCount = 1
    if currentLobbySnapshot and type(currentLobbySnapshot.members) == "table" then
        memberCount = #currentLobbySnapshot.members
    elseif session.connected then
        memberCount = 2
    end

    return {
        lobbyId = tostring(session.lobbyId),
        ownerId = session.localUserId and tostring(session.localUserId) or nil,
        ownerName = session.localPersonaName or "You",
        memberCount = memberCount,
        memberLimit = 2,
        sessionId = session.sessionId or "",
        protocolVersion = tostring(((SETTINGS.STEAM_ONLINE or {}).PROTOCOL_VERSION) or 1),
        relation = "friend",
        visibility = normalizeVisibility(session.lobbyVisibility),
        joinable = false,
        isLocalHostRow = true
    }
end

local function applyLocalHostLobbyRow()
    lobbyList = sortAndFilterAvailableLobbies(lobbyList)

    local localRow = buildLocalHostLobbyRow()
    if not localRow then
        return
    end

    local filtered = {}
    for _, entry in ipairs(lobbyList) do
        local sameLobby = tostring(entry.lobbyId or "") == tostring(localRow.lobbyId or "")
        if not sameLobby then
            filtered[#filtered + 1] = entry
        end
    end

    table.insert(filtered, 1, localRow)
    lobbyList = filtered
end

local function collectLobbyOwnerIds()
    local ids = {}
    local dedupe = {}
    for _, entry in ipairs(lobbyList) do
        if entry and entry.ownerId then
            local normalized = tostring(entry.ownerId)
            if normalized ~= "" and not dedupe[normalized] then
                dedupe[normalized] = true
                ids[#ids + 1] = normalized
            end
        end
    end
    return ids
end

local function refreshLobbyOwnerEloCache(source, force)
    if eloRefreshInFlight then
        return
    end

    if not steamRuntime.isOnlineReady() then
        return
    end

    local ownerIds = collectLobbyOwnerIds()
    if #ownerIds == 0 then
        return
    end

    local now = nowSeconds()
    if not force and (now - (lastEloRefreshAt or 0)) < ELO_REFRESH_INTERVAL_SEC then
        return
    end

    eloRefreshInFlight = true
    local leaderboardName = (((SETTINGS.RATING or SETTINGS.ELO) or {}).LEADERBOARD_NAME) or "global_glicko2_v1"
    steamRuntime.findOrCreateLeaderboard(leaderboardName, "descending", "numeric")

    local entries = steamRuntime.downloadLeaderboardEntriesForUsers(leaderboardName, ownerIds) or {}
    local byOwner = {}
    for _, entry in ipairs(entries) do
        local userId = entry.userId or entry.steamId or entry.id
        if userId then
            byOwner[tostring(userId)] = {
                score = tonumber(entry.score),
                rank = tonumber(entry.rank),
                fetchedAt = now
            }
        end
    end

    for _, ownerId in ipairs(ownerIds) do
        local info = byOwner[ownerId]
        if info then
            lobbyOwnerEloBySteamId[ownerId] = info
        else
            lobbyOwnerEloBySteamId[ownerId] = {
                score = defaultEloScore(),
                rank = nil,
                fetchedAt = now
            }
        end
    end

    lastEloRefreshAt = now
    eloRefreshInFlight = false
    lobbyLog(string.format("Lobby rating refresh (%s): %d owners", tostring(source or "auto"), #ownerIds))
end

local function buildLobbyRowFields(entry)
    local ownerName = entry.ownerName
    if not ownerName or ownerName == "" then
        ownerName = entry.ownerId and ("Player " .. tostring(entry.ownerId):sub(-6)) or "Unknown"
    end
    if entry.isLocalHostRow then
        ownerName = "Your Lobby - " .. ownerName
    end

    local members = tonumber(entry.memberCount) or 0
    local limit = tonumber(entry.memberLimit) or 0
    if limit <= 0 then
        limit = 2
    end

    local visibilityField = formatVisibilityLabel(entry.visibility)

    local eloScore, eloRank = getOwnerEloInfo(entry.ownerId)
    local eloField = string.format("RATING %d (#%s)", tonumber(eloScore) or defaultEloScore(), tostring(eloRank or "-"))
    local lobbyTail = tostring(entry.lobbyId or "-"):sub(-6)

    return {
        ownerName = ownerName,
        eloField = eloField,
        slotField = string.format("%d/%d", members, limit),
        visibilityField = visibilityField,
        lobbyField = "#" .. lobbyTail
    }
end

local function formatLobbyRow(entry)
    local fields = buildLobbyRowFields(entry)
    return string.format("%s | %s | %s | %s | %s", fields.ownerName, fields.eloField, fields.slotField, fields.visibilityField, fields.lobbyField)
end

local function hydrateLobbyOwnerIdentity(entry)
    if type(entry) ~= "table" or not entry.lobbyId then
        return
    end

    if (not entry.ownerId or entry.ownerId == "") and steamRuntime.getLobbyData then
        local ownerId = steamRuntime.getLobbyData(entry.lobbyId, "owner_id")
        if ownerId and ownerId ~= "" then
            entry.ownerId = tostring(ownerId)
        end
    end

    if (not entry.ownerName or entry.ownerName == "") and steamRuntime.getLobbyData then
        local ownerName = steamRuntime.getLobbyData(entry.lobbyId, "owner_name")
        if ownerName and ownerName ~= "" then
            entry.ownerName = tostring(ownerName)
        end
    end

    if (not entry.ownerName or entry.ownerName == "") and entry.ownerId and steamRuntime.getPersonaNameForUser then
        local persona = steamRuntime.getPersonaNameForUser(entry.ownerId)
        if persona and persona ~= "" then
            entry.ownerName = persona
        end
    end

    if steamRuntime.getLobbyData then
        local visibility = steamRuntime.getLobbyData(entry.lobbyId, "mom_visibility")
        entry.visibility = normalizeVisibility(visibility or entry.visibility)
    else
        entry.visibility = normalizeVisibility(entry.visibility)
    end
end

local function getLobbyIndexAtPosition(x, y)
    local contentX, contentY, contentWidth, contentHeight = getListContentRect()
    local rowsTopY = contentY + LAYOUT.listColumnsHeaderHeight
    local rowsBottomY = contentY + contentHeight
    if x < contentX or x > contentX + contentWidth then
        return nil
    end
    if y < rowsTopY or y > rowsBottomY then
        return nil
    end

    local row = math.floor((y - rowsTopY) / LAYOUT.rowHeight) + 1
    local index = scrollOffsetRows + row
    if index < 1 or index > #lobbyList then
        return nil
    end
    return index
end

local function isMouseOverButton(button, x, y)
    if not button then
        return false
    end
    return x >= button.x and x <= button.x + button.width and y >= button.y and y <= button.y + button.height
end

local function resolvePeerDisplayName()
    if not session then
        return "Player"
    end

    local name = session.peerPersonaName
    if name and name ~= "" then
        return name
    end

    local peerId = session.peerUserId and tostring(session.peerUserId) or ""
    if peerId ~= "" then
        return "Player " .. peerId:sub(-6)
    end

    return "Player"
end

local function resolveSessionRole()
    if not session then
        return nil
    end

    local localId = session.localUserId and tostring(session.localUserId) or nil
    local hostId = session.hostUserId and tostring(session.hostUserId) or nil
    if localId and hostId and localId ~= "" and hostId ~= "" then
        if localId == hostId then
            return "host"
        end
        return "guest"
    end

    if session.role == "host" or session.role == "guest" then
        return session.role
    end

    local onlineRole = GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.role or nil
    if onlineRole == "host" or onlineRole == "guest" then
        return onlineRole
    end

    return nil
end

local function syncSessionRole()
    local role = resolveSessionRole()
    if role then
        session.role = role
        GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
        GAME.CURRENT.ONLINE.role = role
    end
    return role
end

local function updateButtonVisuals()
    for i, button in ipairs(buttonOrder) do
        local variant = button.enabled and "default" or "disabled"
        uiTheme.applyButtonVariant(button, variant)
        button.disabledVisual = not button.enabled
        button.focused = (i == selectedButtonIndex and not listFocus and button.enabled)
        if button.focused then
            button.currentColor = button.hoverColor
        else
            button.currentColor = button.baseColor
        end
    end
end

local function selectEnabledLobbyButton(startIndex, delta)
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
        if buttonOrder[index] and buttonOrder[index].enabled then
            return index
        end
        index = index + delta
    end

    return nil
end

local function ensureValidLobbyButtonSelection()
    local resolved = selectEnabledLobbyButton(selectedButtonIndex, 1) or selectEnabledLobbyButton(1, 1)
    if resolved then
        selectedButtonIndex = resolved
        return true
    end
    return false
end

local function focusLobbyButtons()
    listFocus = false
    ensureValidLobbyButtonSelection()
    updateButtonStates()
end

updateButtonStates = function()
    local onlineReady = steamRuntime.isOnlineReady()
    local isActive = session and session.active
    local selectedEntry = selectedLobbyEntry()
    syncSessionRole()

    uiButtons.host.enabled = onlineReady and (not isActive) and (not createInFlight) and (not joinInFlight)
    uiButtons.join.enabled = onlineReady and (not isActive) and (not createInFlight) and (not joinInFlight) and selectedEntry ~= nil and selectedEntry.joinable ~= false
    uiButtons.refresh.enabled = onlineReady and (not isActive) and (not refreshInFlight) and (not createInFlight) and (not joinInFlight)
    uiButtons.invite.enabled = onlineReady and (not createInFlight) and (not joinInFlight)
    uiButtons.back.enabled = true

    if #lobbyList == 0 then
        listFocus = false
    end
    if not listFocus then
        ensureValidLobbyButtonSelection()
    end

    updateButtonVisuals()
end

local function refreshLobbyList(source)
    if refreshInFlight then
        return
    end

    if not steamRuntime.isOnlineReady() then
        lobbyList = {}
        selectedLobbyIndex = 1
        scrollOffsetRows = 0
        lastLobbyRefreshAt = nowSeconds()
        setStatusBar("Steam unavailable. Online mode disabled.", "warn")
        return
    end

    if session and session.active then
        return
    end

    refreshInFlight = true

    local protocolVersion = ((SETTINGS.STEAM_ONLINE or {}).PROTOCOL_VERSION)
    local entries = steamRuntime.listJoinableLobbies({
        maxResults = 40,
        protocolVersion = protocolVersion
    })

    local rawEntries = entries or {}
    for _, entry in ipairs(rawEntries) do
        hydrateLobbyOwnerIdentity(entry)
    end

    lobbyList = sortAndFilterAvailableLobbies(rawEntries)
    if #lobbyList == 0 then
        selectedLobbyIndex = 1
        scrollOffsetRows = 0
    else
        clampSelectedLobbyIndex()
    end

    lastLobbyRefreshAt = nowSeconds()
    refreshInFlight = false
    refreshLobbyOwnerEloCache("lobby_list", true)

    if #lobbyList > 0 then
        setStatusBar(string.format("Lobby list updated: %d lobbies found.", #lobbyList), "ok")
    else
        setStatusBar("No available lobbies right now.", "info")
    end

    lobbyLog(string.format("Lobby list refresh (%s): %d entries", tostring(source or "manual"), #lobbyList))
end

local function initializeButtons()
    local y = LAYOUT.buttonRowY
    local buttonWidth = LAYOUT.buttonWidth
    local gap = LAYOUT.buttonGap
    local count = 5
    local totalWidth = count * buttonWidth + (count - 1) * gap
    local startX = math.floor((SETTINGS.DISPLAY.WIDTH - totalWidth) / 2)

    uiButtons = {
        host = {
            x = startX,
            y = y,
            width = buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Host Lobby",
            enabled = true,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        },
        join = {
            x = startX + (buttonWidth + gap),
            y = y,
            width = buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Join Selected",
            enabled = false,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        },
        refresh = {
            x = startX + (buttonWidth + gap) * 2,
            y = y,
            width = buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Refresh",
            enabled = true,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        },
        invite = {
            x = startX + (buttonWidth + gap) * 3,
            y = y,
            width = buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Invite Friend",
            enabled = false,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        },
        back = {
            x = startX + (buttonWidth + gap) * 4,
            y = y,
            width = buttonWidth,
            height = LAYOUT.buttonHeight,
            text = "Back",
            enabled = true,
            currentColor = uiTheme.COLORS.button,
            hoverColor = uiTheme.COLORS.buttonHover,
            pressedColor = uiTheme.COLORS.buttonPressed
        }
    }

    buttonOrder = {uiButtons.host, uiButtons.join, uiButtons.refresh, uiButtons.invite, uiButtons.back}
    for _, button in ipairs(buttonOrder) do
        uiTheme.applyButtonVariant(button, "default")
    end
end

local function controllerFromSession(role)
    local localController = Controller.new({
        id = "steam_local_human",
        nickname = session.localPersonaName or "You",
        type = Controller.TYPES.HUMAN,
        isLocal = true,
        metadata = {
            source = "steam_online",
            role = role,
            steamId = session.localUserId
        }
    })

    local remoteController = Controller.new({
        id = "steam_remote_human",
        nickname = resolvePeerDisplayName(),
        type = Controller.TYPES.REMOTE,
        isLocal = false,
        metadata = {
            source = "steam_online",
            role = role == "host" and "guest" or "host",
            steamId = session.peerUserId
        }
    })

    if role == "host" then
        return localController, remoteController
    end

    return remoteController, localController
end

local function enterFactionSelectOnline()
    if switchedToFactionSelect then
        return
    end

    local role = syncSessionRole() or "guest"
    local faction1Controller, faction2Controller = controllerFromSession(role)

    local controllers = {
        [faction1Controller.id] = faction1Controller,
        [faction2Controller.id] = faction2Controller
    }

    GAME.setControllers(controllers)
    GAME.setControllerSequence({ faction1Controller.id, faction2Controller.id })
    GAME.assignControllerToFaction(faction1Controller.id, 1)
    GAME.assignControllerToFaction(faction2Controller.id, 2)

    GAME.CURRENT.MODE = GAME.MODE.MULTYPLAYER_NET
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    GAME.CURRENT.ONLINE.active = true
    GAME.CURRENT.ONLINE.role = role
    GAME.CURRENT.ONLINE.factionRole = role
    GAME.CURRENT.ONLINE.session = session
    GAME.CURRENT.ONLINE.lockstep = SteamLockstep.new({
        session = session
    })

    switchedToFactionSelect = true
    stateMachineRef.changeState("factionSelect")
end

local function tryEnterFactionSelectFromInviteAccept(reason)
    if not inviteJoinDirectFactionLobbyId then
        return false
    end
    if not session or not session.active or session.role ~= "guest" then
        return false
    end
    if session.lobbyId and tostring(session.lobbyId) ~= tostring(inviteJoinDirectFactionLobbyId) then
        inviteJoinDirectFactionLobbyId = nil
        return false
    end
    if not hasConnectedPeer() then
        return false
    end

    lobbyLog("Invite accept direct faction transition: " .. tostring(reason or "ready"))
    inviteJoinDirectFactionLobbyId = nil
    setStatusBar("Invite accepted. Entering faction setup...", "ok")
    enterFactionSelectOnline()
    return true
end

local function refreshLobbyRatings()
    if not session or not session.active or not session.connected or not session.peerUserId then
        ratingsFetchKey = nil
        return
    end

    local fetchKey = tostring(session.localUserId) .. ":" .. tostring(session.peerUserId)
    if ratingsFetchKey == fetchKey then
        return
    end

    local leaderboardName = (((SETTINGS.RATING or SETTINGS.ELO) or {}).LEADERBOARD_NAME) or "global_glicko2_v1"
    local defaultRating = (((SETTINGS.RATING or SETTINGS.ELO) or {}).DEFAULT_RATING) or 1200
    local seedRating = resolveStoredOnlineRatingSeed(defaultRating)
    if steamRuntime.ensureLocalLeaderboardPresence then
        steamRuntime.ensureLocalLeaderboardPresence(leaderboardName, seedRating)
    end
    steamRuntime.findOrCreateLeaderboard(leaderboardName, "descending", "numeric")

    local entries = steamRuntime.downloadLeaderboardEntriesForUsers(leaderboardName, {
        session.localUserId,
        session.peerUserId
    })

    local entryByUser = {}
    for _, entry in ipairs(entries or {}) do
        local userId = entry.userId or entry.steamId or entry.id
        if userId then
            entryByUser[tostring(userId)] = tonumber(entry.score)
        end
    end

    local localRating = entryByUser[tostring(session.localUserId)] or defaultRating
    local peerRating = entryByUser[tostring(session.peerUserId)] or defaultRating

    if session.role == "host" then
        session:setPreMatchRatings(localRating, peerRating)
    else
        session:setPreMatchRatings(peerRating, localRating)
    end

    ratingsFetchKey = fetchKey
end

local function canEnterFactionSetup()
    if not session then
        return false, "session_missing"
    end

    if not session.active then
        return false, "session_inactive"
    end

    if not session.connected then
        return false, "peer_not_connected"
    end

    if not session.peerUserId or tostring(session.peerUserId) == tostring(session.localUserId) then
        return false, "peer_invalid"
    end

    if session.isPeerStable and not session:isPeerStable() then
        return false, "peer_stabilizing"
    end

    return true, "ready"
end

local function logTransitionGate(canTransition, reason)
    local now = nowSeconds()
    local summary = string.format("%s:%s", canTransition and "pass" or "block", tostring(reason))
    if summary ~= lastTransitionGateSummary or (now - (lastTransitionGateLogAt or 0)) >= 2.0 then
        lobbyLog("Faction transition gate " .. summary)
        lastTransitionGateSummary = summary
        lastTransitionGateLogAt = now
    end
end

local function terminateOnlineAndReturnToMenu(reasonCode)
    lobbyLog("Terminating online session: " .. tostring(reasonCode or "unknown"))
    if session then
        session:leave()
    end
    clearOnlineRuntimeState(reasonCode)
    session = nil
    if stateMachineRef then
        stateMachineRef.changeState("mainMenu")
    end
end

local function startHostLobbyWithVisibility(visibilityMode)
    if not session then
        return
    end

    local normalizedVisibility = visibilityMode == "friends" and "friends" or "public"
    lobbyLog("Host lobby requested (visibility=" .. tostring(normalizedVisibility) .. ")")
    setStatusBar("Creating lobby...", "info")
    createInFlight = true
    local ok, result = session:startHostLobby(2, normalizedVisibility)
    createInFlight = false

    if not ok then
        lobbyLog("Host lobby failed: " .. tostring(result))
        setStatusBar("Failed to create lobby.", "error")
        return
    end

    session:setPreMatchRatings(defaultEloScore(), defaultEloScore())
    session.connected = false
    joinInFlight = false

    lobbyLog("Host lobby created/started: " .. tostring(result))
    if normalizedVisibility == "friends" then
        setStatusBar("Friends-only lobby created. Waiting for an opponent...", "ok")
    else
        setStatusBar("Open lobby created. Waiting for an opponent...", "ok")
    end
end

local function onHostLobby()
    if not session then
        return
    end

    ConfirmDialog.show(
        "Choose lobby visibility.",
        function()
            startHostLobbyWithVisibility("friends")
        end,
        function()
            startHostLobbyWithVisibility("public")
        end,
        {
            title = "Lobby Visibility",
            confirmText = "Friends Only",
            cancelText = "Public",
            defaultFocus = "cancel"
        }
    )
end

local function onRefresh()
    refreshLobbyList("manual")
end

local function onJoinSelected()
    if not session or session.active then
        return
    end

    local entry = selectedLobbyEntry()
    if not entry or not entry.lobbyId then
        lobbyLog("Join selected requested without a selected lobby")
        setStatusBar("Select a valid lobby to join.", "warn")
        return
    end

    if entry.joinable == false then
        lobbyLog("Join selected blocked: lobby marked not joinable")
        setStatusBar("Selected lobby is not joinable.", "warn")
        return
    end

    lobbyLog("Joining selected lobby: " .. tostring(entry.lobbyId))
    setStatusBar("Joining lobby...", "info")
    joinInFlight = true
    local joined, joinErr = session:joinLobby(entry.lobbyId)
    if not joined then
        joinInFlight = false
        lobbyLog("Join selected failed: " .. tostring(joinErr))
        setStatusBar("Failed to join lobby.", "error")
        return
    end

    lobbyLog("Join selected started")
    setStatusBar("Join request sent. Waiting for lobby confirmation...", "info")
end

local function onInviteFriend()
    if not session then
        return
    end

    local function ensureFriendsInviteSession()
        if session.active and session.role == "host" and session.lobbyId and tostring(session.lobbyVisibility or "public") == "friends" then
            return true, "reuse_existing_friends_lobby"
        end

        if session.active then
            lobbyLog("Invite flow leaving current session before creating friends-only lobby")
            session:leave()
        end

        createInFlight = true
        local ok, result = session:startHostLobby(2, "friends")
        createInFlight = false
        if not ok then
            return false, result or "create_friends_lobby_failed"
        end

        session:setPreMatchRatings(defaultEloScore(), defaultEloScore())
        session.connected = false
        joinInFlight = false
        lobbyLog("Invite flow friends-only lobby ready: " .. tostring(result))
        applyLocalHostLobbyRow()
        refreshLobbyOwnerEloCache("invite_autohost", true)
        return true, "created_friends_lobby"
    end

    local ensured, ensureReason = ensureFriendsInviteSession()
    if not ensured then
        lobbyLog("Invite flow failed to ensure friends lobby: " .. tostring(ensureReason))
        setStatusBar("Failed to create friends-only lobby for invite.", "error")
        return
    end

    setStatusBar("Friends-only lobby ready. Opening invite overlay...", "info")
    local overlayOk = steamRuntime.onGuideButtonPressed()
    lobbyLog("Invite overlay trigger: " .. tostring(overlayOk))
    if overlayOk then
        armOnlineInviteWaitPrompt()
        setStatusBar("Invite overlay opened. Choose factions while waiting...", "ok")
        enterFactionSelectOnline()
    else
        setStatusBar("Unable to open invite overlay.", "warn")
        clearOnlineInviteWaitPromptState()
    end
end

local function onBack()
    terminateOnlineAndReturnToMenu("lobby_exit")
end

local function isEntryActivationGuardActive()
    return (nowSeconds() - (lobbyEnterAt or 0)) < ENTRY_ACTIVATION_GUARD_SEC
end

local function triggerSelectedButton(button)
    if not button or not button.enabled then
        return
    end

    if isEntryActivationGuardActive() then
        updateButtonStates()
        return
    end

    playClickSound()

    if button == uiButtons.host then
        onHostLobby()
    elseif button == uiButtons.join then
        onJoinSelected()
    elseif button == uiButtons.refresh then
        onRefresh()
    elseif button == uiButtons.invite then
        onInviteFriend()
    elseif button == uiButtons.back then
        onBack()
    end

    updateButtonStates()
end

function onlineLobby.enter(stateMachine)
    stateMachineRef = stateMachine

    GAME.CURRENT.MODE = GAME.MODE.MULTYPLAYER_NET

    initializeButtons()
    selectedButtonIndex = 1
    listFocus = true
    lobbyList = {}
    selectedLobbyIndex = 1
    scrollOffsetRows = 0
    ratingsFetchKey = nil
    switchedToFactionSelect = false
    refreshInFlight = false
    joinInFlight = false
    createInFlight = false
    inviteJoinDirectFactionLobbyId = nil
    lastLobbyRefreshAt = 0
    lastOnlineReady = nil
    scrollbarDragging = false
    statusBarText = "Ready"
    statusBarSeverity = "info"
    lobbyOwnerEloBySteamId = {}
    lastEloRefreshAt = 0
    eloRefreshInFlight = false
    currentLobbySnapshot = nil
    lastTransitionGateSummary = nil
    lastTransitionGateLogAt = 0
    lastHoveredButtonIndex = nil
    peerTransitionEligibleSince = nil
    lobbyEnterAt = nowSeconds()

    session = GAME.CURRENT.ONLINE and GAME.CURRENT.ONLINE.session or SteamOnlineSession.new()
    GAME.CURRENT.ONLINE = GAME.CURRENT.ONLINE or {}
    GAME.CURRENT.ONLINE.session = session
    GAME.CURRENT.ONLINE.role = syncSessionRole() or session.role
    ensureOnlineRuntimeState()

    lobbyLog("Entered online lobby")
    if steamRuntime.isOnlineReady() and not session.active then
        refreshLobbyList("enter")
    elseif session and session.active and session.role == "host" then
        applyLocalHostLobbyRow()
        refreshLobbyOwnerEloCache("host_enter", true)
        setStatusBar("Host lobby active. Waiting for an opponent...", "info")
    else
        setStatusBar("Ready", "info")
    end

    updateButtonStates()
end

function onlineLobby.exit()
    stateMachineRef = nil
    scrollbarDragging = false
end

function onlineLobby.update(dt)
    if ConfirmDialog.isActive() then
        ConfirmDialog.update(dt)
        return
    end

    local onlineReady = steamRuntime.isOnlineReady()
    if lastOnlineReady ~= onlineReady then
        lastOnlineReady = onlineReady
        lobbyLog("Steam online ready changed: " .. tostring(onlineReady))
        if not onlineReady then
            lobbyList = {}
            selectedLobbyIndex = 1
            scrollOffsetRows = 0
            joinInFlight = false
            createInFlight = false
            setStatusBar("Steam unavailable. Online disabled.", "warn")
        elseif session and not session.active then
            refreshLobbyList("ready_transition")
        else
            setStatusBar("Steam online ready.", "ok")
        end
    end

    if session then
        syncSessionRole()
        local pendingInviteLobbyId, directInviteToFaction
        if onlineReady then
            pendingInviteLobbyId, directInviteToFaction = consumePendingInviteJoinLobbyId()
        end
        if pendingInviteLobbyId then
            inviteJoinDirectFactionLobbyId = directInviteToFaction and tostring(pendingInviteLobbyId) or nil
            if session.active then
                lobbyLog("Invite accepted: leaving current lobby before joining invited lobby")
                session:leave()
            end
            lobbyLog("Invite accepted, joining lobby: " .. tostring(pendingInviteLobbyId))
            setStatusBar("Invite accepted: joining lobby...", "info")
            joinInFlight = true
            local joined, joinErr = session:joinLobby(pendingInviteLobbyId)
            if not joined then
                joinInFlight = false
                inviteJoinDirectFactionLobbyId = nil
                lobbyLog("Invite join failed: " .. tostring(joinErr))
                setStatusBar("Join from invite failed.", "error")
            else
                lobbyLog("Invite join started")
                if tryEnterFactionSelectFromInviteAccept("join_started") then
                    return
                end
            end
        end

        local lobbyEvents = consumePendingLobbyEvents(64)
        for _, event in ipairs(lobbyEvents) do
            local handled = session:handleLobbyEvent(event)
            if handled then
                lobbyLog("Lobby event handled: " .. tostring(handled))
                if handled == "lobby_join_failed" then
                    joinInFlight = false
                    inviteJoinDirectFactionLobbyId = nil
                    setStatusBar("Lobby join was rejected or failed.", "error")
                elseif handled == "lobby_joined" then
                    joinInFlight = false
                    setStatusBar("Lobby joined. Sync in progress...", "ok")
                    if tryEnterFactionSelectFromInviteAccept("lobby_joined") then
                        return
                    end
                elseif handled == "lobby_created" then
                    setStatusBar("Lobby created. Waiting for peer...", "ok")
                end
            end
        end

        if session.active and session.lobbyId then
            local snapshot = steamRuntime.getLobbySnapshot(session.lobbyId)
            if snapshot then
                session:applyLobbySnapshot(snapshot)
                currentLobbySnapshot = snapshot
                if tryEnterFactionSelectFromInviteAccept("snapshot") then
                    return
                end
            end

            refreshLobbyRatings()
            applyLocalHostLobbyRow()
            for _, entry in ipairs(lobbyList) do
                hydrateLobbyOwnerIdentity(entry)
            end
            refreshLobbyOwnerEloCache("active_lobby", false)

            if session.connected then
                joinInFlight = false
                createInFlight = false
            end

            local resolvedRole = syncSessionRole() or session.role
            local hasValidPeer = session.connected == true and session.peerUserId and tostring(session.peerUserId) ~= tostring(session.localUserId)
            if hasValidPeer then
                peerTransitionEligibleSince = peerTransitionEligibleSince or nowSeconds()
            else
                peerTransitionEligibleSince = nil
            end

            local canTransition, transitionReason = canEnterFactionSetup()
            logTransitionGate(canTransition, transitionReason)
            if canTransition then
                setStatusBar("Opponent connected. Entering faction setup...", "ok")
                enterFactionSelectOnline()
                return
            end

            if (not canTransition) and resolvedRole == "guest" and hasValidPeer and transitionReason == "peer_stabilizing" then
                local elapsed = nowSeconds() - (peerTransitionEligibleSince or nowSeconds())
                if elapsed >= 1.5 then
                    lobbyLog("Faction transition fallback: guest connected with valid peer, bypassing prolonged stabilizing gate")
                    setStatusBar("Connected. Entering faction setup...", "ok")
                    enterFactionSelectOnline()
                    return
                end
            end

            if resolvedRole == "host" then
                if session.connected then
                    local stableSeconds = session.getPeerStableSeconds and session:getPeerStableSeconds() or 0
                    setStatusBar(string.format("Opponent connected. Stabilizing link (%.1fs)...", stableSeconds), "info")
                else
                    setStatusBar("Lobby active: waiting for opponent to join.", "info")
                end
            else
                if session.connected then
                    setStatusBar("Connected. Waiting for setup transition...", "info")
                else
                    setStatusBar("Lobby connection in progress...", "info")
                end
            end

            local timeoutStatus = session:update()
            if timeoutStatus == "timeout" then
                if resolvedRole == "host" then
                    lobbyLog("Host pre-match timeout; clearing peer and waiting for new join")
                    if session.clearPeerForWaiting then
                        session:clearPeerForWaiting("peer_timeout_pre_match")
                    end
                    ratingsFetchKey = nil
                    joinInFlight = false
                    createInFlight = false
                    setStatusBar("Opponent disconnected. Waiting for another player...", "warn")
                else
                    setStatusBar("Reconnect timeout. Returning to menu.", "warn")
                    terminateOnlineAndReturnToMenu("timeout_forfeit")
                    return
                end
            end
        end
    end

    if onlineReady and session and (not session.active) then
        local elapsed = nowSeconds() - (lastLobbyRefreshAt or 0)
        if elapsed >= AUTO_LOBBY_REFRESH_SEC then
            refreshLobbyList("auto")
        end
        refreshLobbyOwnerEloCache("idle_refresh", false)
    end

    GAME.CURRENT.ONLINE.role = session and (syncSessionRole() or session.role) or nil
    clampSelectedLobbyIndex()
    updateButtonStates()
end

function onlineLobby.draw()
    love.graphics.push()
    love.graphics.translate(SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY)
    love.graphics.scale(SETTINGS.DISPLAY.SCALE)

    menuBackground.draw()

    local panelX, panelY, panelWidth, panelHeight = getListRect()
    uiTheme.drawTechPanel(panelX, panelY, panelWidth, panelHeight)

    love.graphics.setColor(0.90, 0.88, 0.82, 1)
    love.graphics.printf("Joinable Lobbies", panelX + 12, panelY + 8, panelWidth - 24, "left")

    local contentX, contentY, contentWidth, contentHeight = getListContentRect()
    local visible = visibleLobbyRows()
    local startIndex = scrollOffsetRows + 1
    local endIndex = math.min(#lobbyList, scrollOffsetRows + visible)
    local rowsTopY = contentY + LAYOUT.listColumnsHeaderHeight

    local colHost = math.floor(contentWidth * 0.42)
    local colElo = math.floor(contentWidth * 0.22)
    local colSlots = math.floor(contentWidth * 0.10)
    local colVisibility = math.floor(contentWidth * 0.14)
    local colLobby = contentWidth - (colHost + colElo + colSlots + colVisibility)

    love.graphics.setColor(0.15, 0.16, 0.18, 0.5)
    love.graphics.rectangle("fill", contentX, contentY, contentWidth, contentHeight)

    love.graphics.setColor(0.18, 0.20, 0.22, 0.9)
    love.graphics.rectangle("fill", contentX, contentY, contentWidth, LAYOUT.listColumnsHeaderHeight)
    love.graphics.setColor(0.76, 0.78, 0.82, 1)
    love.graphics.printf("Host", contentX + 8, contentY + 4, colHost - 10, "left")
    love.graphics.printf("RATING", contentX + colHost + 6, contentY + 4, colElo - 10, "left")
    love.graphics.printf("Slots", contentX + colHost + colElo + 6, contentY + 4, colSlots - 10, "left")
    love.graphics.printf("Visibility", contentX + colHost + colElo + colSlots + 6, contentY + 4, colVisibility - 10, "left")
    love.graphics.printf("Lobby", contentX + colHost + colElo + colSlots + colVisibility + 6, contentY + 4, colLobby - 10, "left")

    if #lobbyList == 0 then
        love.graphics.setColor(0.72, 0.70, 0.66, 1)
        love.graphics.printf("No joinable lobbies found.", contentX + 8, rowsTopY + 10, contentWidth - 16, "left")
    else
        for index = startIndex, endIndex do
            local row = index - scrollOffsetRows
            local rowY = rowsTopY + (row - 1) * LAYOUT.rowHeight
            local isSelected = index == selectedLobbyIndex

            if isSelected then
                if listFocus then
                    love.graphics.setColor(0.30, 0.44, 0.54, 0.9)
                else
                    love.graphics.setColor(0.24, 0.32, 0.38, 0.75)
                end
                love.graphics.rectangle("fill", contentX + 2, rowY + 1, contentWidth - 4, LAYOUT.rowHeight - 2)
            elseif row % 2 == 0 then
                love.graphics.setColor(1, 1, 1, 0.03)
                love.graphics.rectangle("fill", contentX + 2, rowY + 1, contentWidth - 4, LAYOUT.rowHeight - 2)
            end

            local entry = lobbyList[index]
            local fields = buildLobbyRowFields(entry)
            love.graphics.setColor(0.94, 0.92, 0.86, 1)
            if entry.isLocalHostRow then
                love.graphics.setColor(0.84, 0.93, 0.78, 1)
            end
            love.graphics.printf(fields.ownerName, contentX + 8, rowY + 8, colHost - 10, "left")
            love.graphics.printf(fields.eloField, contentX + colHost + 6, rowY + 8, colElo - 10, "left")
            love.graphics.printf(fields.slotField, contentX + colHost + colElo + 6, rowY + 8, colSlots - 10, "left")
            love.graphics.printf(fields.visibilityField, contentX + colHost + colElo + colSlots + 6, rowY + 8, colVisibility - 10, "left")
            love.graphics.printf(fields.lobbyField, contentX + colHost + colElo + colSlots + colVisibility + 6, rowY + 8, colLobby - 10, "left")

            love.graphics.setColor(1, 1, 1, 0.08)
            love.graphics.rectangle("fill", contentX + 2, rowY + LAYOUT.rowHeight - 1, contentWidth - 4, 1)
        end
    end

    local scrollbar = getScrollbarGeometry()
    love.graphics.setColor(0.24, 0.24, 0.24, 0.9)
    love.graphics.rectangle("fill", scrollbar.trackX, scrollbar.trackY, LAYOUT.scrollbarWidth, scrollbar.trackHeight, 4, 4)
    if scrollbar.visible then
        love.graphics.setColor(0.66, 0.67, 0.70, 0.95)
        love.graphics.rectangle("fill", scrollbar.trackX + 1, scrollbar.thumbY + 1, LAYOUT.scrollbarWidth - 2, scrollbar.thumbHeight - 2, 4, 4)
    end

    for _, button in ipairs(buttonOrder) do
        uiTheme.drawButton(button)
    end

    if ConfirmDialog and ConfirmDialog.draw then
        ConfirmDialog.draw()
    end

    love.graphics.pop()
end

function onlineLobby.mousemoved(x, y, dx, dy, istouch)
    if ConfirmDialog.isActive() then
        ConfirmDialog.mousemoved(x, y)
        return
    end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    if scrollbarDragging then
        local scrollbar = getScrollbarGeometry()
        if scrollbar.visible and scrollbar.thumbTravel > 0 and scrollbar.maxOffset > 0 then
            local deltaY = ty - scrollbarDragAnchorY
            local ratio = deltaY / scrollbar.thumbTravel
            local targetOffset = scrollbarDragAnchorOffset + ratio * scrollbar.maxOffset
            setScrollOffsetRows(targetOffset)
        end
        updateButtonStates()
        return
    end

    local hoveredIndex = nil
    for i, button in ipairs(buttonOrder) do
        if button.enabled and isMouseOverButton(button, tx, ty) then
            selectedButtonIndex = i
            listFocus = false
            hoveredIndex = i
        end
    end

    if hoveredIndex and hoveredIndex ~= lastHoveredButtonIndex then
        playHoverSound()
    end
    lastHoveredButtonIndex = hoveredIndex

    updateButtonStates()
end

function onlineLobby.mousepressed(x, y, button, istouch, presses)
    if button ~= 1 then
        return
    end

    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousepressed(x, y, button)
    end

    local tx = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE
    local ty = (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    local scrollbar = getScrollbarGeometry()
    if scrollbar.visible then
        local inTrack = tx >= scrollbar.trackX and tx <= scrollbar.trackX + LAYOUT.scrollbarWidth and ty >= scrollbar.trackY and ty <= scrollbar.trackY + scrollbar.trackHeight
        local inThumb = inTrack and ty >= scrollbar.thumbY and ty <= scrollbar.thumbY + scrollbar.thumbHeight

        if inThumb then
            scrollbarDragging = true
            scrollbarDragAnchorY = ty
            scrollbarDragAnchorOffset = scrollOffsetRows
            return
        elseif inTrack then
            if ty < scrollbar.thumbY then
                scrollRows(-visibleLobbyRows())
            elseif ty > scrollbar.thumbY + scrollbar.thumbHeight then
                scrollRows(visibleLobbyRows())
            end
            updateButtonStates()
            return
        end
    end

    local lobbyIndex = getLobbyIndexAtPosition(tx, ty)
    if lobbyIndex then
        if isEntryActivationGuardActive() then
            return
        end
        setSelectedLobbyIndex(lobbyIndex)
        listFocus = true
        updateButtonStates()
        return
    end

    for i, candidate in ipairs(buttonOrder) do
        if candidate.enabled and isMouseOverButton(candidate, tx, ty) then
            selectedButtonIndex = i
            listFocus = false
            triggerSelectedButton(candidate)
            lastHoveredButtonIndex = i
            return
        end
    end

    updateButtonStates()
end

function onlineLobby.mousereleased(x, y, button, istouch, presses)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.mousereleased(x, y, button)
    end
    if button == 1 then
        scrollbarDragging = false
    end
end

function onlineLobby.wheelmoved(dx, dy)
    if ConfirmDialog.isActive() then
        return
    end

    if dy ~= 0 then
        scrollRows(-dy)
        updateButtonStates()
    end
end

function onlineLobby.keypressed(key, scancode, isrepeat)
    if ConfirmDialog.isActive() then
        return ConfirmDialog.keypressed(key)
    end

    if key == "escape" then
        onBack()
        return true
    end

    if key == "tab" then
        listFocus = not listFocus
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "up" or key == "w" then
        if not listFocus then
            if #lobbyList > 0 then
                listFocus = true
                clampSelectedLobbyIndex()
                updateButtonStates()
                playHoverSound()
                return true
            end
            return false
        end

        if #lobbyList > 0 then
            local nextIndex = selectedLobbyIndex - 1
            if nextIndex < 1 then
                nextIndex = 1
            end
            if nextIndex ~= selectedLobbyIndex then
                setSelectedLobbyIndex(nextIndex)
                updateButtonStates()
                playHoverSound()
            end
            return true
        end
    end

    if key == "down" or key == "s" then
        if not listFocus then
            return true
        end

        if #lobbyList > 0 then
            local nextIndex = selectedLobbyIndex + 1
            if nextIndex > #lobbyList then
                focusLobbyButtons()
                playHoverSound()
                return true
            end
            setSelectedLobbyIndex(nextIndex)
            updateButtonStates()
            playHoverSound()
            return true
        end
    end

    if key == "pageup" then
        listFocus = true
        scrollRows(-visibleLobbyRows())
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "pagedown" then
        listFocus = true
        scrollRows(visibleLobbyRows())
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "left" or key == "a" or key == "q" then
        focusLobbyButtons()
        selectedButtonIndex = selectEnabledLobbyButton(selectedButtonIndex - 1, -1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "right" or key == "d" or key == "e" then
        focusLobbyButtons()
        selectedButtonIndex = selectEnabledLobbyButton(selectedButtonIndex + 1, 1) or selectedButtonIndex
        updateButtonStates()
        playHoverSound()
        return true
    end

    if key == "return" or key == "space" then
        if isEntryActivationGuardActive() then
            updateButtonStates()
            return true
        end
        if listFocus and #lobbyList > 0 then
            onJoinSelected()
        else
            triggerSelectedButton(buttonOrder[selectedButtonIndex])
        end
        updateButtonStates()
        return true
    end

    return false
end

function onlineLobby.gamepadpressed(joystick, button)
    if button == "a" then
        return onlineLobby.keypressed("return", "return", false)
    end
    if button == "b" or button == "back" then
        return onlineLobby.keypressed("escape", "escape", false)
    end
    if button == "dpup" then
        return onlineLobby.keypressed("up", "up", false)
    end
    if button == "dpdown" then
        return onlineLobby.keypressed("down", "down", false)
    end
    if button == "dpleft" or button == "leftshoulder" then
        return onlineLobby.keypressed("left", "left", false)
    end
    if button == "dpright" or button == "rightshoulder" then
        return onlineLobby.keypressed("right", "right", false)
    end
    return false
end

return onlineLobby
