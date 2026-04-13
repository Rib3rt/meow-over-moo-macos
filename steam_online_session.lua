local steamRuntime = require("steam_runtime")

local STEAM_ONLINE_SETTINGS = ((SETTINGS or {}).STEAM_ONLINE) or {}
local PEER_STABLE_MIN_SEC = tonumber(STEAM_ONLINE_SETTINGS.PEER_STABLE_MIN_SEC) or 0.35
local SNAPSHOT_PEER_MISS_GRACE_SEC = tonumber(STEAM_ONLINE_SETTINGS.SNAPSHOT_PEER_MISS_GRACE_SEC) or 2.0
local LOCAL_MISS_GRACE_SEC = tonumber(STEAM_ONLINE_SETTINGS.LOCAL_MISS_GRACE_SEC) or 2.0
local PEER_TRAFFIC_STALE_SEC = tonumber(STEAM_ONLINE_SETTINGS.PEER_TRAFFIC_STALE_SEC) or 3.0

local MEMBER_STATE_ENTERED = 0x01
local MEMBER_STATE_LEFT = 0x02
local MEMBER_STATE_DISCONNECTED = 0x04
local MEMBER_STATE_KICKED = 0x08
local MEMBER_STATE_BANNED = 0x10

local session = {}
session.__index = session

local function nowSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.time()
end

local function newSessionId()
    local userId = steamRuntime.getLocalUserId() or "local"
    local stamp = tostring(math.floor(nowSeconds() * 1000))
    return tostring(userId) .. ":" .. stamp
end

local function fallbackPersonaNameForUser(userId)
    local idText = userId and tostring(userId) or "unknown"
    return "Player " .. idText:sub(-6)
end

local function resolvePersonaNameForUser(userId, fallbackName)
    if not userId then
        return fallbackName or fallbackPersonaNameForUser(userId)
    end

    local name = steamRuntime.getPersonaNameForUser and steamRuntime.getPersonaNameForUser(userId) or nil
    if name and name ~= "" then
        return name
    end

    if fallbackName and fallbackName ~= "" then
        return fallbackName
    end

    return fallbackPersonaNameForUser(userId)
end

local function refreshPersonaCache(self)
    if not self then
        return
    end

    if self.hostUserId then
        if self.hostUserId == self.localUserId then
            self.hostPersonaName = self.localPersonaName
        else
            self.hostPersonaName = resolvePersonaNameForUser(self.hostUserId, self.hostPersonaName)
        end
    end

    if self.guestUserId then
        if self.guestUserId == self.localUserId then
            self.guestPersonaName = self.localPersonaName
        else
            self.guestPersonaName = resolvePersonaNameForUser(self.guestUserId, self.guestPersonaName)
        end
    end

    if self.peerUserId then
        if self.peerUserId == self.localUserId then
            self.peerPersonaName = self.localPersonaName
        else
            self.peerPersonaName = resolvePersonaNameForUser(self.peerUserId, self.peerPersonaName)
        end
    end
end

local function hasMemberStateFlag(memberState, flag)
    local numericState = tonumber(memberState)
    if not numericState then
        return false
    end
    return (math.floor(numericState / flag) % 2) >= 1
end

local function setPeerSeen(self, peerUserId)
    if not peerUserId then
        return false
    end

    peerUserId = tostring(peerUserId)
    if peerUserId == "" or peerUserId == tostring(self.localUserId) then
        return false
    end

    local now = nowSeconds()
    local changedPeer = self.peerUserId ~= peerUserId

    self.peerUserId = peerUserId
    self.peerLastSeenAt = now
    self.lastPeerTrafficAt = now

    if changedPeer or not self.peerStableSince then
        self.peerStableSince = now
    end

    if self.role == "host" then
        self.guestUserId = peerUserId
    elseif self.role == "guest" and (not self.hostUserId or self.hostUserId == "") then
        self.hostUserId = peerUserId
    end

    self.connected = true
    self.disconnectReason = nil
    self.disconnectDeadline = nil
    refreshPersonaCache(self)

    return true
end

local function clearPeerReference(self)
    self.peerUserId = nil
    self.peerPersonaName = nil
    self.peerStableSince = nil
    self.peerLastSeenAt = nil
    self.lastPeerTrafficAt = nil
    if self.role == "host" then
        self.guestUserId = nil
        self.guestPersonaName = nil
    end
end

local function publishHostLobbyMetadata(self)
    if not self or not self.lobbyId or self.role ~= "host" then
        return
    end

    steamRuntime.setLobbyData(self.lobbyId, "mom_game", "MeowOverMoo")
    steamRuntime.setLobbyData(self.lobbyId, "mom_joinable", "1")
    steamRuntime.setLobbyData(self.lobbyId, "session_id", self.sessionId or "")
    steamRuntime.setLobbyData(self.lobbyId, "protocol_version", tostring(self.protocolVersion))
    steamRuntime.setLobbyData(self.lobbyId, "owner_name", self.localPersonaName or "Host")
    if self.localUserId then
        steamRuntime.setLobbyData(self.lobbyId, "owner_id", tostring(self.localUserId))
    end
    steamRuntime.setLobbyData(self.lobbyId, "mom_visibility", self.lobbyVisibility or "public")
end

function session.new(params)
    params = params or {}
    local self = setmetatable({}, session)

    self.protocolVersion = STEAM_ONLINE_SETTINGS.PROTOCOL_VERSION or 1
    self.reconnectTimeoutSec = STEAM_ONLINE_SETTINGS.RECONNECT_TIMEOUT_SEC or 30

    self.active = false
    self.role = nil -- host | guest
    self.sessionId = nil
    self.lobbyId = nil

    self.localUserId = params.localUserId or steamRuntime.getLocalUserId()
    self.localPersonaName = params.localPersonaName or steamRuntime.getPersonaName() or "Player"

    self.hostUserId = nil
    self.guestUserId = nil
    self.peerUserId = nil

    self.hostPersonaName = nil
    self.guestPersonaName = nil
    self.peerPersonaName = nil

    self.peerLastSeenAt = nil
    self.peerStableSince = nil
    self.lastPeerTrafficAt = nil
    self.lastSnapshotMemberCount = 0
    self.lastSnapshotHash = nil

    self.connected = false
    self.localPresentInLobby = true
    self.localLastSeenAt = nowSeconds()
    self.disconnectReason = nil
    self.disconnectDeadline = nil

    self.preMatchRatings = {
        host = nil,
        guest = nil
    }
    self.preMatchRatingContext = {
        algorithm = "glicko2",
        ranked = true,
        reason = "ranked",
        matchDay = nil,
        host = nil,
        guest = nil,
        hostGuard = nil,
        guestGuard = nil
    }

    self.matchStarted = false
    self.matchSeed = nil
    self.matchSetup = nil
    self.lastLobbyEvent = nil
    self.pendingJoinLobbyId = nil
    self.pendingCreateLobby = false
    self.lobbyVisibility = "public"

    return self
end

function session:resetMatchState()
    self.matchStarted = false
    self.matchSeed = nil
    self.matchSetup = nil
    self.preMatchRatings.host = nil
    self.preMatchRatings.guest = nil
    self.preMatchRatingContext = {
        algorithm = "glicko2",
        ranked = true,
        reason = "ranked",
        matchDay = nil,
        host = nil,
        guest = nil,
        hostGuard = nil,
        guestGuard = nil
    }
end

function session:isOnlineAvailable()
    return steamRuntime.isOnlineReady()
end

function session:startHostLobby(maxMembers, visibility)
    if not self:isOnlineAvailable() then
        return false, "steam_unavailable"
    end

    local normalizedVisibility = visibility == "friends" and "friends" or "public"

    local ok, lobby = steamRuntime.createFriendsLobby(maxMembers or 2)
    if not ok then
        return false, lobby or "lobby_create_failed"
    end

    self.active = true
    self.role = "host"
    self.sessionId = newSessionId()
    self.lobbyId = lobby and lobby.lobbyId or lobby

    self.hostUserId = self.localUserId
    self.guestUserId = nil
    self.peerUserId = nil
    self.connected = false
    self.localPresentInLobby = true
    self.localLastSeenAt = nowSeconds()
    self.disconnectReason = nil
    self.disconnectDeadline = nil
    self.pendingCreateLobby = self.lobbyId == nil
    self.lobbyVisibility = normalizedVisibility
    self:resetMatchState()

    if self.lobbyId then
        -- Keep Steam transport discoverable even for friends-tagged lobbies;
        -- visibility policy is enforced by mom_visibility metadata in browser filtering.
        steamRuntime.setLobbyVisibility(self.lobbyId, "public")
    end

    refreshPersonaCache(self)
    publishHostLobbyMetadata(self)

    return true, self.lobbyId or "pending"
end

function session:attachJoinedLobby(lobbySnapshot)
    if not lobbySnapshot or type(lobbySnapshot) ~= "table" then
        return false, "invalid_lobby_snapshot"
    end

    self.active = true
    self.role = "guest"
    self.lobbyId = lobbySnapshot.lobbyId
    self.sessionId = lobbySnapshot.sessionId or steamRuntime.getLobbyData(self.lobbyId, "session_id")
    local visibility = steamRuntime.getLobbyData(self.lobbyId, "mom_visibility")
    if visibility == "friends" then
        self.lobbyVisibility = "friends"
    else
        self.lobbyVisibility = "public"
    end
    if not self.hostPersonaName or self.hostPersonaName == "" then
        local ownerName = steamRuntime.getLobbyData(self.lobbyId, "owner_name")
        if ownerName and ownerName ~= "" then
            self.hostPersonaName = ownerName
        end
    end

    local resolvedOwnerId = lobbySnapshot.ownerId or steamRuntime.getLobbyData(self.lobbyId, "owner_id")
    self.hostUserId = resolvedOwnerId
    self.guestUserId = self.localUserId
    self.peerUserId = self.hostUserId
    local validPeer = self.peerUserId ~= nil and self.peerUserId ~= self.localUserId
    if validPeer then
        local now = nowSeconds()
        self.peerLastSeenAt = now
        self.peerStableSince = now
        self.lastPeerTrafficAt = now
    else
        self.peerLastSeenAt = nil
        self.peerStableSince = nil
        self.lastPeerTrafficAt = nil
    end

    self.connected = validPeer
    self.localPresentInLobby = true
    self.localLastSeenAt = nowSeconds()
    self.disconnectReason = nil
    self.disconnectDeadline = nil
    self.pendingJoinLobbyId = nil
    self:resetMatchState()

    refreshPersonaCache(self)
    return true
end

function session:joinLobby(lobbyId)
    if not self:isOnlineAvailable() then
        return false, "steam_unavailable"
    end
    if not lobbyId then
        return false, "invalid_lobby_id"
    end

    local ok, payload = steamRuntime.joinLobby(lobbyId)
    if not ok then
        return false, payload or "join_lobby_failed"
    end

    local snapshot = steamRuntime.getLobbySnapshot(payload and payload.lobbyId or lobbyId)
    if snapshot then
        return self:attachJoinedLobby(snapshot)
    end

    self.active = true
    self.role = "guest"
    self.lobbyId = payload and payload.lobbyId or lobbyId
    self.pendingJoinLobbyId = self.lobbyId
    self.connected = false
    self.localPresentInLobby = true
    self.localLastSeenAt = nowSeconds()
    self.disconnectReason = nil
    self.disconnectDeadline = nil
    self:resetMatchState()
    return true
end

function session:applyLobbySnapshot(snapshot)
    if not snapshot or type(snapshot) ~= "table" then
        return false
    end

    local now = nowSeconds()
    local wasConnected = self.connected == true

    local resolvedOwnerId = snapshot.ownerId or (self.lobbyId and steamRuntime.getLobbyData(self.lobbyId, "owner_id"))
    if resolvedOwnerId and resolvedOwnerId ~= "" then
        self.hostUserId = tostring(resolvedOwnerId)
    end
    if snapshot.ownerName and snapshot.ownerName ~= "" then
        self.hostPersonaName = snapshot.ownerName
    elseif (not self.hostPersonaName or self.hostPersonaName == "") and self.lobbyId then
        local ownerName = steamRuntime.getLobbyData(self.lobbyId, "owner_name")
        if ownerName and ownerName ~= "" then
            self.hostPersonaName = ownerName
        end
    end

    local localPresent = self.localPresentInLobby ~= false
    local processedMembers = false
    local remotePeer = nil
    local snapshotMemberIds = {}

    if type(snapshot.members) == "table" and #snapshot.members > 0 then
        processedMembers = true
        localPresent = false
        for _, member in ipairs(snapshot.members) do
            local memberId = tostring(member)
            snapshotMemberIds[#snapshotMemberIds + 1] = memberId
            if memberId == tostring(self.localUserId) then
                localPresent = true
            elseif memberId ~= tostring(self.localUserId) and not remotePeer then
                remotePeer = memberId
            end
        end
    end

    if processedMembers then
        local snapshotHash = table.concat(snapshotMemberIds, ",")
        self.lastSnapshotMemberCount = #snapshotMemberIds
        if self.lastSnapshotHash ~= snapshotHash then
            self.lastSnapshotHash = snapshotHash
            print(string.format("[OnlineSession] Snapshot members updated: count=%d ids=%s", self.lastSnapshotMemberCount, snapshotHash))
        end
    end

    self.localPresentInLobby = localPresent
    if localPresent then
        self.localLastSeenAt = now
    end

    if remotePeer then
        setPeerSeen(self, remotePeer)
    elseif self.role == "guest" and self.hostUserId and tostring(self.hostUserId) ~= tostring(self.localUserId) then
        if not self.peerUserId or tostring(self.peerUserId) ~= tostring(self.hostUserId) then
            setPeerSeen(self, self.hostUserId)
        else
            self.peerLastSeenAt = self.peerLastSeenAt or now
            self.peerStableSince = self.peerStableSince or now
        end
    elseif processedMembers then
        local graceActive = false
        if self.peerUserId and self.peerLastSeenAt then
            graceActive = (now - self.peerLastSeenAt) < SNAPSHOT_PEER_MISS_GRACE_SEC
        end
        if not graceActive then
            clearPeerReference(self)
        end
    end

    local hasValidPeer = self.peerUserId ~= nil and tostring(self.peerUserId) ~= tostring(self.localUserId)
    local localGraceActive = false
    if processedMembers and not localPresent and self.localLastSeenAt then
        localGraceActive = (now - self.localLastSeenAt) < LOCAL_MISS_GRACE_SEC
    end

    if processedMembers and not localPresent and not localGraceActive then
        if wasConnected or self.disconnectDeadline == nil then
            self:markDisconnected("local_missing_from_lobby")
        end
    elseif hasValidPeer then
        if not self.connected or self.disconnectDeadline ~= nil then
            self:markReconnected(self.peerUserId)
        else
            self.connected = true
            self.disconnectReason = nil
            self.disconnectDeadline = nil
        end
    elseif processedMembers and wasConnected then
        self:markDisconnected("peer_missing_from_lobby")
    else
        self.connected = false
    end

    refreshPersonaCache(self)
    return true
end

function session:inviteFriend(friendId)
    if not self.lobbyId then
        return false, "lobby_missing"
    end
    local invited = steamRuntime.inviteFriend(self.lobbyId, friendId)
    if not invited then
        return false, "invite_failed"
    end
    return true
end

function session:setLobbyVisibility(visibility)
    if self.role ~= "host" or not self.lobbyId then
        return false, "host_lobby_required"
    end

    local normalized = visibility == "friends" and "friends" or "public"
    self.lobbyVisibility = normalized
    -- Always keep lobby transport public for cross-client discoverability on AppID 480.
    steamRuntime.setLobbyVisibility(self.lobbyId, "public")
    steamRuntime.setLobbyData(self.lobbyId, "mom_visibility", normalized)
    publishHostLobbyMetadata(self)
    return true
end

function session:handleLobbyEvent(event)
    if type(event) ~= "table" then
        return nil
    end

    self.lastLobbyEvent = event
    local eventType = event.type

    if eventType == "lobby_created" then
        self.active = true
        self.role = self.role or "host"
        self.hostUserId = self.localUserId
        self.lobbyId = event.lobbyId or self.lobbyId
        self.pendingCreateLobby = false
        if not self.sessionId then
            self.sessionId = newSessionId()
        end
        publishHostLobbyMetadata(self)
        refreshPersonaCache(self)
        return "lobby_created"
    end

    if eventType == "lobby_joined" then
        local lobbyId = event.lobbyId or self.lobbyId or self.pendingJoinLobbyId
        local snapshot = lobbyId and steamRuntime.getLobbySnapshot(lobbyId) or nil
        if snapshot then
            self:attachJoinedLobby(snapshot)
        else
            self.active = true
            self.role = "guest"
            self.lobbyId = lobbyId
            self.hostUserId = event.ownerId or (self.lobbyId and steamRuntime.getLobbyData(self.lobbyId, "owner_id"))
            self.guestUserId = self.localUserId
            self.peerUserId = self.hostUserId
            self.connected = self.peerUserId ~= nil and self.peerUserId ~= self.localUserId
            local now = nowSeconds()
            self.localPresentInLobby = true
            self.localLastSeenAt = now
            if self.connected then
                self.lastPeerTrafficAt = now
                self.peerLastSeenAt = self.peerLastSeenAt or now
                self.peerStableSince = self.peerStableSince or now
            else
                self.lastPeerTrafficAt = nil
            end
            self.disconnectReason = nil
            self.disconnectDeadline = nil
            self.pendingJoinLobbyId = nil
        end

        if self.hostUserId and tostring(self.hostUserId) ~= tostring(self.localUserId) then
            setPeerSeen(self, self.hostUserId)
        end

        refreshPersonaCache(self)
        return "lobby_joined"
    end

    if eventType == "lobby_join_failed" then
        self.pendingJoinLobbyId = nil
        self.disconnectReason = event.result or "lobby_join_failed"
        return "lobby_join_failed"
    end

    if eventType == "lobby_member_update" or eventType == "lobby_data_update" then
        if eventType == "lobby_member_update" then
            local memberId = event.memberId and tostring(event.memberId) or nil
            local memberState = tonumber(event.memberState) or 0
            local entered = hasMemberStateFlag(memberState, MEMBER_STATE_ENTERED)
            local left = hasMemberStateFlag(memberState, MEMBER_STATE_LEFT)
            local disconnected = hasMemberStateFlag(memberState, MEMBER_STATE_DISCONNECTED)
            local kicked = hasMemberStateFlag(memberState, MEMBER_STATE_KICKED)
            local banned = hasMemberStateFlag(memberState, MEMBER_STATE_BANNED)

            print(string.format(
                "[OnlineSession] lobby_member_update member=%s state=%d entered=%s left=%s disconnected=%s kicked=%s banned=%s local=%s peer=%s",
                tostring(memberId),
                memberState,
                tostring(entered),
                tostring(left),
                tostring(disconnected),
                tostring(kicked),
                tostring(banned),
                tostring(self.localUserId),
                tostring(self.peerUserId)
            ))

            if memberId and memberId == tostring(self.localUserId) then
                if left or disconnected or kicked or banned then
                    self.localPresentInLobby = false
                    self:markDisconnected("local_missing_from_lobby")
                elseif entered then
                    self.localPresentInLobby = true
                    self.localLastSeenAt = nowSeconds()
                end
            elseif memberId and memberId ~= tostring(self.localUserId) then
                if entered then
                    setPeerSeen(self, memberId)
                elseif left or disconnected or kicked or banned then
                    if self.peerUserId and tostring(self.peerUserId) == tostring(memberId) then
                        clearPeerReference(self)
                    end
                    self:markDisconnected("peer_missing_from_lobby")
                else
                    setPeerSeen(self, memberId)
                end
            end
        end

        local lobbyId = event.lobbyId or self.lobbyId
        if lobbyId then
            local snapshot = steamRuntime.getLobbySnapshot(lobbyId)
            if snapshot then
                self:applyLobbySnapshot(snapshot)
            end
        end
        return eventType
    end

    return eventType
end

function session:leave()
    if self.lobbyId then
        steamRuntime.leaveLobby(self.lobbyId)
    end

    self.active = false
    self.role = nil
    self.sessionId = nil
    self.lobbyId = nil
    self.hostUserId = nil
    self.guestUserId = nil
    self.peerUserId = nil
    self.connected = false
    self.localPresentInLobby = true
    self.localLastSeenAt = nil
    self.disconnectReason = nil
    self.disconnectDeadline = nil
    self.pendingJoinLobbyId = nil
    self.pendingCreateLobby = false
    self.lobbyVisibility = "public"
    self:resetMatchState()

    self.peerLastSeenAt = nil
    self.peerStableSince = nil
    self.lastPeerTrafficAt = nil
    self.lastSnapshotMemberCount = 0
    self.lastSnapshotHash = nil

    self.hostPersonaName = nil
    self.guestPersonaName = nil
    self.peerPersonaName = nil

    return true
end

function session:markDisconnected(reason)
    self.connected = false
    self.disconnectReason = reason or "transport_lost"
    self.disconnectDeadline = nowSeconds() + self.reconnectTimeoutSec
    self.peerStableSince = nil
end

function session:markReconnected(peerUserId)
    local nextPeer = peerUserId and tostring(peerUserId) or (self.peerUserId and tostring(self.peerUserId))
    if not nextPeer or nextPeer == "" or nextPeer == tostring(self.localUserId) then
        self.connected = false
        return false
    end

    local changedPeer = tostring(self.peerUserId or "") ~= nextPeer
    self.peerUserId = nextPeer
    if self.role == "host" then
        self.guestUserId = nextPeer
    end

    local now = nowSeconds()
    self.peerLastSeenAt = now
    self.lastPeerTrafficAt = now
    if changedPeer or not self.peerStableSince then
        self.peerStableSince = now
    end

    self.connected = true
    self.disconnectReason = nil
    self.disconnectDeadline = nil
    refreshPersonaCache(self)
    return true
end

function session:notePeerTraffic(peerUserId)
    local now = nowSeconds()
    local candidatePeer = peerUserId and tostring(peerUserId) or nil

    if candidatePeer and candidatePeer ~= "" and candidatePeer ~= tostring(self.localUserId) then
        if not self.peerUserId or tostring(self.peerUserId) ~= candidatePeer then
            setPeerSeen(self, candidatePeer)
        else
            self.peerLastSeenAt = now
            self.connected = true
        end
    elseif self.peerUserId and tostring(self.peerUserId) ~= tostring(self.localUserId) then
        self.peerLastSeenAt = now
        self.connected = true
    else
        return false
    end

    self.lastPeerTrafficAt = now
    self.disconnectReason = nil
    self.disconnectDeadline = nil

    if not self.peerStableSince then
        self.peerStableSince = now
    end

    return true
end

function session:isPeerTrafficStale(timeoutSec)
    local staleWindow = tonumber(timeoutSec) or PEER_TRAFFIC_STALE_SEC
    if staleWindow <= 0 then
        staleWindow = PEER_TRAFFIC_STALE_SEC
    end

    if not self.connected then
        return true
    end

    local baseline = self.lastPeerTrafficAt or self.peerLastSeenAt
    if not baseline then
        return true
    end

    return (nowSeconds() - baseline) > staleWindow
end

function session:getPeerStableSeconds()
    if not self.peerStableSince then
        return 0
    end
    return math.max(0, nowSeconds() - self.peerStableSince)
end

function session:isPeerStable()
    if not self.connected then
        return false
    end
    if not self.peerUserId or tostring(self.peerUserId) == tostring(self.localUserId) then
        return false
    end
    return self:getPeerStableSeconds() >= PEER_STABLE_MIN_SEC
end

function session:clearPeerForWaiting(reason)
    clearPeerReference(self)
    self.connected = false
    self.disconnectReason = reason or "peer_timeout_pre_match"
    self.disconnectDeadline = nil
    self.lastSnapshotMemberCount = 0
    self.lastSnapshotHash = nil
    refreshPersonaCache(self)
    return true
end

function session:getReconnectTimeRemaining()
    if not self.disconnectDeadline then
        return nil
    end
    return math.max(0, self.disconnectDeadline - nowSeconds())
end

function session:isReconnectExpired()
    local remaining = self:getReconnectTimeRemaining()
    return remaining ~= nil and remaining <= 0
end

function session:update()
    if self.disconnectDeadline and self:isReconnectExpired() then
        return "timeout"
    end
    return nil
end

function session:canControlSetup()
    return self.role == "host"
end

function session:setPreMatchRatings(hostRating, guestRating)
    self.preMatchRatings.host = hostRating
    self.preMatchRatings.guest = guestRating
end

function session:setPreMatchRatingContext(context)
    context = type(context) == "table" and context or {}
    self.preMatchRatingContext = {
        algorithm = tostring(context.algorithm or "glicko2"),
        ranked = context.ranked ~= false,
        reason = tostring(context.reason or "ranked"),
        matchDay = tonumber(context.matchDay),
        host = type(context.host) == "table" and context.host or nil,
        guest = type(context.guest) == "table" and context.guest or nil,
        hostGuard = type(context.hostGuard) == "table" and context.hostGuard or nil,
        guestGuard = type(context.guestGuard) == "table" and context.guestGuard or nil
    }
    if self.preMatchRatingContext.host then
        self.preMatchRatings.host = tonumber(self.preMatchRatingContext.host.rating) or self.preMatchRatings.host
    end
    if self.preMatchRatingContext.guest then
        self.preMatchRatings.guest = tonumber(self.preMatchRatingContext.guest.rating) or self.preMatchRatings.guest
    end
end

function session:createMatchStartPayload(seed, setupPayload)
    return {
        sessionId = self.sessionId,
        protocolVersion = self.protocolVersion,
        seed = seed,
        setup = setupPayload,
        preMatchRatings = {
            host = self.preMatchRatings.host,
            guest = self.preMatchRatings.guest
        },
        ratingContext = self.preMatchRatingContext
    }
end

function session:applyMatchStartPayload(payload)
    if type(payload) ~= "table" then
        return false, "invalid_match_start_payload"
    end

    self.matchStarted = true
    self.matchSeed = payload.seed
    self.matchSetup = payload.setup

    if payload.preMatchRatings then
        self.preMatchRatings.host = payload.preMatchRatings.host
        self.preMatchRatings.guest = payload.preMatchRatings.guest
    end
    if payload.ratingContext then
        self:setPreMatchRatingContext(payload.ratingContext)
    end

    return true
end

function session:getSnapshot()
    return {
        active = self.active,
        role = self.role,
        sessionId = self.sessionId,
        lobbyId = self.lobbyId,
        localUserId = self.localUserId,
        hostUserId = self.hostUserId,
        guestUserId = self.guestUserId,
        peerUserId = self.peerUserId,
        hostPersonaName = self.hostPersonaName,
        guestPersonaName = self.guestPersonaName,
        peerPersonaName = self.peerPersonaName,
        connected = self.connected,
        localPresentInLobby = self.localPresentInLobby,
        localLastSeenAt = self.localLastSeenAt,
        lastPeerTrafficAt = self.lastPeerTrafficAt,
        peerTrafficStale = self:isPeerTrafficStale(),
        peerStableSeconds = self:getPeerStableSeconds(),
        peerStable = self:isPeerStable(),
        disconnectReason = self.disconnectReason,
        reconnectRemaining = self:getReconnectTimeRemaining(),
        preMatchRatings = {
            host = self.preMatchRatings.host,
            guest = self.preMatchRatings.guest
        },
        preMatchRatingContext = self.preMatchRatingContext,
        pendingCreateLobby = self.pendingCreateLobby == true,
        pendingJoinLobbyId = self.pendingJoinLobbyId,
        lastLobbyEvent = self.lastLobbyEvent,
        matchStarted = self.matchStarted,
        matchSeed = self.matchSeed
    }
end

return session
