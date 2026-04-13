local steamRuntime = require("steam_runtime")
local codec = require("steam_packet_codec")

local SETTINGS_ONLINE = ((SETTINGS or {}).STEAM_ONLINE) or {}

local lockstep = {}
lockstep.__index = lockstep

local function newEvent(kind, payload)
    return {
        kind = kind,
        payload = payload
    }
end

local function normalizeUserId(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    if text == "" or text == "0" then
        return nil
    end
    return text
end

local function resolveLocalUserId(session)
    return normalizeUserId(session and session.localUserId) or "local"
end

local function normalizeSequence(seq)
    local numeric = tonumber(seq) or 0
    if numeric < 0 then
        numeric = 0
    end
    return math.floor(numeric)
end

local function buildCommandId(proposerId, seq)
    local normalizedProposer = normalizeUserId(proposerId) or "unknown"
    return string.format("%s:%d", normalizedProposer, normalizeSequence(seq))
end

local function normalizeCommandIdentity(identity, session, defaultProposer)
    local localUserId = resolveLocalUserId(session)
    local fallbackProposer = normalizeUserId(defaultProposer) or localUserId

    if type(identity) == "table" then
        local seq = normalizeSequence(identity.seq)
        local proposerId = normalizeUserId(identity.proposerId) or fallbackProposer
        local commandId = identity.commandId
        if type(commandId) ~= "string" or commandId == "" then
            commandId = buildCommandId(proposerId, seq)
        end
        return {
            seq = seq,
            proposerId = proposerId,
            commandId = commandId
        }
    end

    if type(identity) == "string" and identity ~= "" then
        local commandId = identity
        local seqText = identity:match(":(%-?%d+)$")
        local seq = normalizeSequence(seqText)
        local proposerId = normalizeUserId(identity:match("^(.-):%-?%d+$")) or fallbackProposer
        return {
            seq = seq,
            proposerId = proposerId,
            commandId = commandId
        }
    end

    local seq = normalizeSequence(identity)
    local proposerId = fallbackProposer
    return {
        seq = seq,
        proposerId = proposerId,
        commandId = buildCommandId(proposerId, seq)
    }
end

local function resolveInboundIdentity(packet, netPacket, session, defaultProposer)
    local seq = normalizeSequence(packet and packet.seq)
    local packetProposer = normalizeUserId(packet and packet.proposerId)
    local peerProposer = normalizeUserId(netPacket and netPacket.peerId)
    local fallbackProposer = normalizeUserId(defaultProposer)
    local localUserId = resolveLocalUserId(session)

    local proposerId = packetProposer or peerProposer or fallbackProposer or localUserId or "unknown"

    local commandId = packet and packet.commandId
    if type(commandId) ~= "string" or commandId == "" then
        commandId = buildCommandId(proposerId, seq)
    end

    return {
        seq = seq,
        proposerId = proposerId,
        commandId = commandId
    }
end

function lockstep.new(params)
    params = params or {}
    local self = setmetatable({}, lockstep)

    self.protocolVersion = SETTINGS_ONLINE.PROTOCOL_VERSION or 1
    self.actionChannel = SETTINGS_ONLINE.PACKET_CHANNEL_ACTION or 1
    self.controlChannel = SETTINGS_ONLINE.PACKET_CHANNEL_CONTROL or 2

    self.session = params.session
    self.sequence = 0
    self.appliedSequence = 0

    self.pendingOutbound = {}
    self.pendingInbound = {}
    self.pendingStateHash = {}

    self.lastLocalStateHash = nil
    self.lastRemoteStateHash = nil

    self.drawProposal = nil
    self.localDrawVote = nil
    self.remoteDrawVote = nil

    self.abortedReason = nil
    self.events = {}

    self.validateCommand = params.validateCommand

    return self
end

function lockstep:reset()
    self.sequence = 0
    self.appliedSequence = 0
    self.pendingOutbound = {}
    self.pendingInbound = {}
    self.pendingStateHash = {}
    self.lastLocalStateHash = nil
    self.lastRemoteStateHash = nil
    self.drawProposal = nil
    self.localDrawVote = nil
    self.remoteDrawVote = nil
    self.abortedReason = nil
    self.events = {}
end

function lockstep:isAborted()
    return self.abortedReason ~= nil
end

function lockstep:getAbortReason()
    return self.abortedReason
end

function lockstep:emit(kind, payload)
    self.events[#self.events + 1] = newEvent(kind, payload)
end

function lockstep:pollEvent()
    if #self.events == 0 then
        return nil
    end
    return table.remove(self.events, 1)
end

function lockstep:sendPacket(packet, channel)
    if not self.session or not self.session.peerUserId then
        return false, "peer_missing"
    end

    local encoded, err = codec.encode(packet, self.protocolVersion)
    if not encoded then
        return false, err
    end

    local sent, sendReason = steamRuntime.sendNet(self.session.peerUserId, encoded, channel or self.controlChannel, "reliable")
    if not sent then
        return false, sendReason or "send_failed"
    end

    return true
end

function lockstep:injectPacket(packet)
    self:handlePacket(packet)
end

function lockstep:pollNetwork()
    local packets = steamRuntime.pollNet(64)
    for _, netPacket in ipairs(packets) do
        if self.session and type(self.session.notePeerTraffic) == "function" then
            self.session:notePeerTraffic(netPacket.peerId)
        end

        local decoded, err = codec.decode(netPacket.payload, self.protocolVersion)
        if decoded then
            self:handlePacket(decoded, netPacket)
        else
            self:emit("protocol_error", {
                reason = err,
                packet = netPacket
            })
        end
    end
end

function lockstep:proposeAction(command, context)
    if self:isAborted() then
        return false, "lockstep_aborted"
    end

    self.sequence = self.sequence + 1
    local seq = self.sequence
    local proposerId = resolveLocalUserId(self.session)
    local commandId = buildCommandId(proposerId, seq)

    local packet = {
        kind = "ACTION_PROPOSE",
        sessionId = self.session and self.session.sessionId or nil,
        seq = seq,
        proposerId = proposerId,
        commandId = commandId,
        command = command,
        context = context
    }

    self.pendingOutbound[commandId] = {
        command = command,
        context = context,
        accepted = false,
        committed = false,
        seq = seq,
        proposerId = proposerId,
        commandId = commandId
    }

    local ok, err = self:sendPacket(packet, self.actionChannel)
    if not ok then
        self.pendingOutbound[commandId] = nil
        return false, err
    end

    print(string.format(
        "[OnlineLockstep] TX ACTION_PROPOSE session=%s commandId=%s proposer=%s seq=%s action=%s",
        tostring(packet.sessionId),
        tostring(commandId),
        tostring(proposerId),
        tostring(seq),
        tostring(command and command.actionType or "unknown")
    ))

    return true, seq
end

function lockstep:commitAction(identity)
    local normalized = normalizeCommandIdentity(identity, self.session, resolveLocalUserId(self.session))
    local pending = self.pendingOutbound[normalized.commandId]
    if not pending or pending.committed then
        return false, "invalid_seq"
    end

    pending.committed = true

    local commitPacket = {
        kind = "ACTION_COMMIT",
        sessionId = self.session and self.session.sessionId or nil,
        seq = pending.seq,
        proposerId = pending.proposerId,
        commandId = pending.commandId,
        command = pending.command,
        context = pending.context
    }

    local ok, err = self:sendPacket(commitPacket, self.actionChannel)
    if not ok then
        pending.committed = false
        return false, err
    end

    print(string.format(
        "[OnlineLockstep] TX ACTION_COMMIT session=%s commandId=%s proposer=%s seq=%s",
        tostring(commitPacket.sessionId),
        tostring(pending.commandId),
        tostring(pending.proposerId),
        tostring(pending.seq)
    ))

    self:emit("apply_command", {
        seq = pending.seq,
        proposerId = pending.proposerId,
        commandId = pending.commandId,
        command = pending.command,
        context = pending.context,
        source = "local"
    })

    return true
end

function lockstep:sendStateHash(identity, hash)
    local normalized = normalizeCommandIdentity(identity, self.session, resolveLocalUserId(self.session))
    local packet = {
        kind = "STATE_HASH",
        sessionId = self.session and self.session.sessionId or nil,
        seq = normalized.seq,
        proposerId = normalized.proposerId,
        commandId = normalized.commandId,
        hash = hash
    }

    print(string.format(
        "[OnlineLockstep] TX STATE_HASH session=%s commandId=%s proposer=%s seq=%s hash=%s",
        tostring(packet.sessionId),
        tostring(packet.commandId),
        tostring(packet.proposerId),
        tostring(packet.seq),
        tostring(packet.hash)
    ))

    return self:sendPacket(packet, self.controlChannel)
end

function lockstep:proposeDraw(turn)
    if self.drawProposal then
        return false, "draw_already_pending"
    end

    self.drawProposal = {
        turn = turn,
        proposer = self.session and self.session.localUserId or "local"
    }
    self.localDrawVote = true
    self.remoteDrawVote = nil

    local ok, err = self:sendPacket({
        kind = "DRAW_PROPOSE",
        turn = turn
    }, self.controlChannel)

    if not ok then
        self.drawProposal = nil
        self.localDrawVote = nil
        return false, err
    end

    return true
end

function lockstep:voteDraw(accept)
    if not self.drawProposal then
        return false, "draw_not_pending"
    end

    self.localDrawVote = accept == true

    local ok, err = self:sendPacket({
        kind = "DRAW_VOTE",
        accept = accept == true
    }, self.controlChannel)
    if not ok then
        return false, err
    end

    self:evaluateDrawVote()
    return true
end

function lockstep:sendReadyRequest(ready, revision)
    local payloadRevision = tonumber(revision) or 0
    if self.session then
        print(string.format(
            "[OnlineLockstep] TX READY_REQUEST peer=%s session=%s setupRev=%s ready=%s",
            tostring(self.session.peerUserId),
            tostring(self.session.sessionId),
            tostring(payloadRevision),
            tostring(ready == true)
        ))
    end
    return self:sendPacket({
        kind = "READY_REQUEST",
        sessionId = self.session and self.session.sessionId or nil,
        ready = ready == true,
        revision = payloadRevision
    }, self.controlChannel)
end

function lockstep:sendReadyState(hostReady, guestReady, revision, setupRevision)
    local payloadRevision = tonumber(revision) or 0
    local payloadSetupRevision = tonumber(setupRevision) or 0
    if self.session then
        print(string.format(
            "[OnlineLockstep] TX READY_STATE peer=%s session=%s rev=%s setupRev=%s hostReady=%s guestReady=%s",
            tostring(self.session.peerUserId),
            tostring(self.session.sessionId),
            tostring(payloadRevision),
            tostring(payloadSetupRevision),
            tostring(hostReady == true),
            tostring(guestReady == true)
        ))
    end
    return self:sendPacket({
        kind = "READY_STATE",
        sessionId = self.session and self.session.sessionId or nil,
        hostReady = hostReady == true,
        guestReady = guestReady == true,
        revision = payloadRevision,
        setupRevision = payloadSetupRevision
    }, self.controlChannel)
end

function lockstep:sendPrematchHello(setupRevision, nonce, ratingProfile)
    local payloadSetupRevision = tonumber(setupRevision) or 0
    local payloadNonce = tonumber(nonce) or 0
    if self.session then
        print(string.format(
            "[OnlineLockstep] TX PREMATCH_HELLO peer=%s session=%s setupRev=%s nonce=%s",
            tostring(self.session.peerUserId),
            tostring(self.session.sessionId),
            tostring(payloadSetupRevision),
            tostring(payloadNonce)
        ))
    end
    return self:sendPacket({
        kind = "PREMATCH_HELLO",
        sessionId = self.session and self.session.sessionId or nil,
        setupRevision = payloadSetupRevision,
        nonce = payloadNonce,
        ratingProfile = ratingProfile
    }, self.controlChannel)
end

function lockstep:sendPrematchAck(setupRevision, nonce, ratingProfile)
    local payloadSetupRevision = tonumber(setupRevision) or 0
    local payloadNonce = tonumber(nonce) or 0
    if self.session then
        print(string.format(
            "[OnlineLockstep] TX PREMATCH_ACK peer=%s session=%s setupRev=%s nonce=%s",
            tostring(self.session.peerUserId),
            tostring(self.session.sessionId),
            tostring(payloadSetupRevision),
            tostring(payloadNonce)
        ))
    end
    return self:sendPacket({
        kind = "PREMATCH_ACK",
        sessionId = self.session and self.session.sessionId or nil,
        setupRevision = payloadSetupRevision,
        nonce = payloadNonce,
        ratingProfile = ratingProfile
    }, self.controlChannel)
end

function lockstep:sendPreviewSelect(payload)
    payload = payload or {}

    local row = tonumber(payload.row)
    local col = tonumber(payload.col)
    if not row or not col then
        return false, "preview_cell_missing"
    end

    return self:sendPacket({
        kind = "PREVIEW_SELECT",
        sessionId = self.session and self.session.sessionId or nil,
        row = row,
        col = col,
        turn = tonumber(payload.turn),
        phase = payload.phase,
        turnPhase = payload.turnPhase
    }, self.controlChannel)
end

function lockstep:sendPreviewClear(payload)
    payload = payload or {}
    return self:sendPacket({
        kind = "PREVIEW_CLEAR",
        sessionId = self.session and self.session.sessionId or nil,
        turn = tonumber(payload.turn),
        phase = payload.phase,
        turnPhase = payload.turnPhase
    }, self.controlChannel)
end

function lockstep:sendReactionSignal(payload)
    payload = payload or {}

    local reactionId = tostring(payload.reactionId or "")
    if reactionId == "" then
        return false, "reaction_id_missing"
    end

    local senderFaction = tonumber(payload.senderFaction)
    if senderFaction ~= 1 and senderFaction ~= 2 then
        return false, "reaction_sender_missing"
    end

    return self:sendPacket({
        kind = "REACTION_SIGNAL",
        sessionId = self.session and self.session.sessionId or nil,
        reactionId = reactionId,
        senderFaction = senderFaction,
        senderName = payload.senderName and tostring(payload.senderName) or nil,
        senderUserId = payload.senderUserId and tostring(payload.senderUserId) or nil,
        sentAt = love and love.timer and love.timer.getTime and love.timer.getTime() or nil
    }, self.controlChannel)
end

function lockstep:evaluateDrawVote()
    if self.localDrawVote == nil or self.remoteDrawVote == nil then
        return
    end

    if self.localDrawVote and self.remoteDrawVote then
        self:emit("draw_accepted", {
            turn = self.drawProposal and self.drawProposal.turn
        })
    else
        self:emit("draw_rejected", {
            turn = self.drawProposal and self.drawProposal.turn
        })
    end

    self.drawProposal = nil
    self.localDrawVote = nil
    self.remoteDrawVote = nil
end

function lockstep:abort(reason)
    if self.abortedReason then
        return
    end
    self.abortedReason = reason or "unknown"
    self:emit("aborted", { reason = self.abortedReason })
end

function lockstep:handleActionPropose(packet, netPacket)
    local identity = resolveInboundIdentity(packet, netPacket, self.session)

    local valid = true
    if type(self.validateCommand) == "function" then
        valid = self.validateCommand(packet.command, packet.context) ~= false
    end

    if not valid then
        self:sendPacket({
            kind = "ACTION_REJECT",
            sessionId = self.session and self.session.sessionId or nil,
            seq = identity.seq,
            proposerId = identity.proposerId,
            commandId = identity.commandId,
            reason = "illegal_command"
        }, self.actionChannel)
        return
    end

    self.pendingInbound[identity.commandId] = {
        command = packet.command,
        context = packet.context,
        seq = identity.seq,
        proposerId = identity.proposerId,
        commandId = identity.commandId
    }

    self:sendPacket({
        kind = "ACTION_ACCEPT",
        sessionId = self.session and self.session.sessionId or nil,
        seq = identity.seq,
        proposerId = identity.proposerId,
        commandId = identity.commandId
    }, self.actionChannel)
end

function lockstep:handleActionAccept(packet, netPacket)
    local identity = resolveInboundIdentity(packet, netPacket, self.session, resolveLocalUserId(self.session))
    local pending = self.pendingOutbound[identity.commandId]
    if not pending then
        local fallbackCommandId = buildCommandId(resolveLocalUserId(self.session), identity.seq)
        pending = self.pendingOutbound[fallbackCommandId]
        if pending then
            identity.commandId = fallbackCommandId
        end
    end

    if not pending then
        return
    end

    pending.accepted = true
    self:commitAction(identity.commandId)
end

function lockstep:handleActionCommit(packet, netPacket)
    local identity = resolveInboundIdentity(packet, netPacket, self.session)
    local inbound = self.pendingInbound[identity.commandId]
    if not inbound then
        local valid = true
        if type(self.validateCommand) == "function" then
            valid = self.validateCommand(packet.command, packet.context) ~= false
        end
        if not valid then
            return
        end

        inbound = {
            command = packet.command,
            context = packet.context,
            seq = identity.seq,
            proposerId = identity.proposerId,
            commandId = identity.commandId
        }
    end

    self.appliedSequence = math.max(self.appliedSequence, inbound.seq or identity.seq)

    self:emit("apply_command", {
        seq = inbound.seq or identity.seq,
        proposerId = inbound.proposerId or identity.proposerId,
        commandId = inbound.commandId or identity.commandId,
        command = inbound.command,
        context = inbound.context,
        source = "remote"
    })

    self.pendingInbound[identity.commandId] = nil
end

function lockstep:handleStateHash(packet, netPacket)
    if type(packet.hash) ~= "string" then
        return
    end

    local identity = resolveInboundIdentity(packet, netPacket, self.session)

    self.lastRemoteStateHash = packet.hash

    local localHash = self.pendingStateHash[identity.commandId]
    if localHash and localHash ~= packet.hash then
        print(string.format(
            "[OnlineLockstep] DESYNC_ABORT commandId=%s localHash=%s remoteHash=%s",
            tostring(identity.commandId),
            tostring(localHash),
            tostring(packet.hash)
        ))
        self:abort("desync_hash_mismatch")
    elseif localHash and localHash == packet.hash then
        self.pendingStateHash[identity.commandId] = nil
    end
end

function lockstep:reportLocalStateHash(identity, signature)
    local normalized = normalizeCommandIdentity(identity, self.session, resolveLocalUserId(self.session))
    local hash = codec.stateHashSignature(signature)
    self.lastLocalStateHash = hash
    self.pendingStateHash[normalized.commandId] = hash
    self:sendStateHash(normalized, hash)
end

function lockstep:handlePacket(packet, netPacket)
    if type(packet) ~= "table" then
        return
    end

    local sessionId = self.session and self.session.sessionId or nil
    if packet.sessionId and sessionId and packet.sessionId ~= sessionId then
        return
    end

    local kind = packet.kind
    if kind == "ACTION_PROPOSE" then
        local identity = resolveInboundIdentity(packet, netPacket, self.session)
        print(string.format(
            "[OnlineLockstep] RX ACTION_PROPOSE session=%s commandId=%s proposer=%s seq=%s action=%s",
            tostring(packet.sessionId),
            tostring(identity.commandId),
            tostring(identity.proposerId),
            tostring(identity.seq),
            tostring(packet.command and packet.command.actionType or "unknown")
        ))
        self:handleActionPropose(packet, netPacket)
    elseif kind == "ACTION_ACCEPT" then
        local identity = resolveInboundIdentity(packet, netPacket, self.session, resolveLocalUserId(self.session))
        print(string.format(
            "[OnlineLockstep] RX ACTION_ACCEPT session=%s commandId=%s proposer=%s seq=%s",
            tostring(packet.sessionId),
            tostring(identity.commandId),
            tostring(identity.proposerId),
            tostring(identity.seq)
        ))
        self:handleActionAccept(packet, netPacket)
    elseif kind == "ACTION_COMMIT" then
        local identity = resolveInboundIdentity(packet, netPacket, self.session)
        print(string.format(
            "[OnlineLockstep] RX ACTION_COMMIT session=%s commandId=%s proposer=%s seq=%s",
            tostring(packet.sessionId),
            tostring(identity.commandId),
            tostring(identity.proposerId),
            tostring(identity.seq)
        ))
        self:handleActionCommit(packet, netPacket)
    elseif kind == "ACTION_REJECT" then
        local identity = resolveInboundIdentity(packet, netPacket, self.session)
        print(string.format(
            "[OnlineLockstep] RX ACTION_REJECT session=%s commandId=%s proposer=%s seq=%s reason=%s",
            tostring(packet.sessionId),
            tostring(identity.commandId),
            tostring(identity.proposerId),
            tostring(identity.seq),
            tostring(packet.reason)
        ))
        self:emit("action_rejected", {
            seq = identity.seq,
            proposerId = identity.proposerId,
            commandId = identity.commandId,
            reason = packet.reason
        })
    elseif kind == "STATE_HASH" then
        local identity = resolveInboundIdentity(packet, netPacket, self.session)
        print(string.format(
            "[OnlineLockstep] RX STATE_HASH session=%s commandId=%s proposer=%s seq=%s hash=%s",
            tostring(packet.sessionId),
            tostring(identity.commandId),
            tostring(identity.proposerId),
            tostring(identity.seq),
            tostring(packet.hash)
        ))
        self:handleStateHash(packet, netPacket)
    elseif kind == "DRAW_PROPOSE" then
        self.drawProposal = {
            turn = packet.turn,
            proposer = self.session and self.session.peerUserId or "remote"
        }
        self.localDrawVote = nil
        self.remoteDrawVote = true
        self:emit("draw_proposed", {
            turn = packet.turn
        })
    elseif kind == "DRAW_VOTE" then
        self.remoteDrawVote = packet.accept == true
        self:evaluateDrawVote()
    elseif kind == "PREMATCH_HELLO" then
        print(string.format(
            "[OnlineLockstep] RX PREMATCH_HELLO session=%s setupRev=%s nonce=%s",
            tostring(packet.sessionId),
            tostring(packet.setupRevision),
            tostring(packet.nonce)
        ))
        self:emit("prematch_hello", {
            setupRevision = tonumber(packet.setupRevision) or 0,
            nonce = tonumber(packet.nonce) or 0,
            ratingProfile = packet.ratingProfile
        })
    elseif kind == "PREMATCH_ACK" then
        print(string.format(
            "[OnlineLockstep] RX PREMATCH_ACK session=%s setupRev=%s nonce=%s",
            tostring(packet.sessionId),
            tostring(packet.setupRevision),
            tostring(packet.nonce)
        ))
        self:emit("prematch_ack", {
            setupRevision = tonumber(packet.setupRevision) or 0,
            nonce = tonumber(packet.nonce) or 0,
            ratingProfile = packet.ratingProfile
        })
    elseif kind == "SETUP_SNAPSHOT" then
        print(string.format(
            "[OnlineLockstep] RX SETUP_SNAPSHOT session=%s setupRev=%s",
            tostring(packet.sessionId),
            tostring(packet.setup and packet.setup.setupRevision)
        ))
        self:emit("setup_snapshot", {
            setup = packet.setup
        })
    elseif kind == "MATCH_START" then
        self:emit("match_start", {
            payload = packet.payload
        })
    elseif kind == "READY_REQUEST" then
        print(string.format(
            "[OnlineLockstep] RX READY_REQUEST session=%s setupRev=%s ready=%s",
            tostring(packet.sessionId),
            tostring(packet.revision),
            tostring(packet.ready == true)
        ))
        self:emit("ready_request", {
            ready = packet.ready == true,
            revision = tonumber(packet.revision)
        })
    elseif kind == "READY_STATE" then
        print(string.format(
            "[OnlineLockstep] RX READY_STATE session=%s rev=%s setupRev=%s hostReady=%s guestReady=%s",
            tostring(packet.sessionId),
            tostring(packet.revision),
            tostring(packet.setupRevision),
            tostring(packet.hostReady == true),
            tostring(packet.guestReady == true)
        ))
        self:emit("ready_state", {
            hostReady = packet.hostReady == true,
            guestReady = packet.guestReady == true,
            revision = tonumber(packet.revision) or 0,
            setupRevision = tonumber(packet.setupRevision) or 0
        })
    elseif kind == "PREVIEW_SELECT" then
        self:emit("preview_select", {
            row = tonumber(packet.row),
            col = tonumber(packet.col),
            turn = tonumber(packet.turn),
            phase = packet.phase,
            turnPhase = packet.turnPhase
        })
    elseif kind == "PREVIEW_CLEAR" then
        self:emit("preview_clear", {
            turn = tonumber(packet.turn),
            phase = packet.phase,
            turnPhase = packet.turnPhase
        })
    elseif kind == "REACTION_SIGNAL" then
        self:emit("reaction_received", {
            reactionId = packet.reactionId and tostring(packet.reactionId) or nil,
            senderFaction = tonumber(packet.senderFaction),
            senderName = packet.senderName and tostring(packet.senderName) or nil,
            senderUserId = packet.senderUserId and tostring(packet.senderUserId) or nil,
            sentAt = tonumber(packet.sentAt)
        })
    elseif kind == "REJOIN_HELLO" then
        self:sendPacket({
            kind = "REJOIN_ACK",
            sessionId = self.session and self.session.sessionId or nil
        }, self.controlChannel)
        self:emit("peer_rejoin_requested", {})
    elseif kind == "REJOIN_ACK" then
        self:emit("rejoin_acked", {})
    elseif kind == "HEARTBEAT" then
        self:emit("heartbeat", {
            timestamp = packet.timestamp
        })
    elseif kind == "MATCH_ABORT" then
        self:abort(packet.reason or "remote_abort")
    end
end

function lockstep:update()
    if self:isAborted() then
        return
    end
    self:pollNetwork()
end

return lockstep
