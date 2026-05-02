local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function addReason(list, reason)
    if not reason then
        return
    end
    list[#list + 1] = reason
end

local function copyActions(actions)
    local out = {}
    for i = 1, #(actions or {}) do
        out[i] = actions[i]
    end
    return out
end

local function actionTouchesHub(action, hub)
    if not action or not hub or action.type ~= "attack" then
        return false
    end
    local target = action.target or {}
    return target.row == hub.row and target.col == hub.col
end

local function buildThreatContext(ai, state, playerToProtect, attackerPlayer, ctx)
    if ctx and ctx.cache and ctx.cache.threat then
        return ctx.cache.threat(ai, state, playerToProtect, attackerPlayer, ctx)
    end
    if ctx and ctx.threatModel and ctx.threatModel.analyzeHubThreatForPlayer then
        return ctx.threatModel.analyzeHubThreatForPlayer(ai, state, playerToProtect, attackerPlayer, ctx)
    end
    if ai and ai.analyzeHubThreatForPlayer then
        return ai:analyzeHubThreatForPlayer(state, playerToProtect, attackerPlayer, ctx)
    end
    return nil
end

local function candidateKillsThreatUnit(candidate, threat)
    if not candidate or not threat then
        return false
    end

    local threatCells = {}
    for _, entry in ipairs(threat.damagingAttackers or {}) do
        local unit = entry and entry.unit
        if unit then
            threatCells[string.format("%d,%d", num(unit.row, -1), num(unit.col, -1))] = true
        end
    end

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "attack" then
            local target = action.target or {}
            local key = string.format("%d,%d", num(target.row, -1), num(target.col, -1))
            if threatCells[key] then
                return true
            end
        end
    end

    return false
end

local function candidateBlocksThreatLine(candidate, threat)
    if not candidate or not threat then
        return false
    end

    local blockCells = {}
    for _, cell in ipairs(threat.blockCells or {}) do
        blockCells[string.format("%d,%d", num(cell.row, -1), num(cell.col, -1))] = true
    end

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "supply_deploy" then
            local target = action.target or {}
            local key = string.format("%d,%d", num(target.row, -1), num(target.col, -1))
            if blockCells[key] then
                return true
            end
        elseif action and action.type == "move" then
            local target = action.target or {}
            local key = string.format("%d,%d", num(target.row, -1), num(target.col, -1))
            if blockCells[key] then
                return true
            end
        end
    end

    return false
end

function M.findImmediateWin(ai, state, ctx)
    local immediateWinSequence = nil
    if ctx and ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
        local lethal, sequence = ctx.threatModel.hasImmediateCommandantLethal(
            ai,
            state,
            ctx.aiPlayer,
            ctx.enemyPlayer,
            ctx
        )
        if not lethal then
            return nil
        end
        if type(sequence) == "table" and #sequence > 0 then
            immediateWinSequence = sequence
        end
    end

    if immediateWinSequence then
        local candidate = {
            actions = copyActions(immediateWinSequence),
            signature = ctx.turnEnumerator.sequenceSignature and ctx.turnEnumerator.sequenceSignature(immediateWinSequence) or nil,
            source = "immediate_lethal_sequence",
            buckets = {"lethal"},
            tacticalTags = {winsNow = true},
            containsDeploy = false,
            containsAttack = false,
            completeTurn = true,
            terminal = true,
            legalSkipReason = "terminal_win"
        }
        for _, action in ipairs(candidate.actions or {}) do
            if action and action.type == "supply_deploy" then
                candidate.containsDeploy = true
            elseif action and action.type == "attack" then
                candidate.containsAttack = true
            end
        end

        local after = ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
        if after and ctx.evaluator.isCommandantDead(after, ctx.enemyPlayer) then
            local score = ctx.evaluator.scoreOwnTurnFast(ai, state, after, candidate, ctx)
            score.tier = ctx.score.TIER.WIN_NOW
            score.terminal = 1000000
            score.signature = candidate.signature
            score = ctx.score.finalize(score)
            return {
                candidate = candidate,
                score = score,
                afterState = after
            }
        end
    end

    local maxCandidates = math.max(4, num(ctx and ctx.cfg and ctx.cfg.IMMEDIATE_WIN_MAX_CANDIDATES, 12))
    local maxFirst = math.max(4, num(ctx and ctx.cfg and ctx.cfg.IMMEDIATE_WIN_MAX_FIRST_ACTIONS, 24))
    local maxSecond = math.max(2, num(ctx and ctx.cfg and ctx.cfg.IMMEDIATE_WIN_MAX_SECOND_ACTIONS, 12))
    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, ctx.aiPlayer, ctx, {
        mode = "lethal_only",
        maxCandidates = maxCandidates,
        maxFirstActions = maxFirst,
        maxSecondActions = maxSecond
    }) or {}

    local best = nil
    for _, candidate in ipairs(candidates) do
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
        local after = ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
        if after and ctx.evaluator.isCommandantDead(after, ctx.enemyPlayer) then
            candidate.tacticalTags = candidate.tacticalTags or {}
            candidate.tacticalTags.winsNow = true

            local score = ctx.evaluator.scoreOwnTurnFast(ai, state, after, candidate, ctx)
            score.tier = ctx.score.TIER.WIN_NOW
            score.terminal = 1000000
            score.signature = candidate.signature
            score = ctx.score.finalize(score)

            if ctx.score.isBetter(score, best and best.score or nil) then
                best = {
                    candidate = candidate,
                    score = score,
                    afterState = after
                }
            end
        end
    end

    return best
end

function M.detectImmediateThreat(ai, state, playerToProtect, attackerPlayer, ctx)
    local prepared = ai:prepareStateForPlayerTurn(state, attackerPlayer, {
        resetDeployment = true,
        resetActionCount = true
    })

    local preThreat = buildThreatContext(ai, prepared, playerToProtect, attackerPlayer, ctx)
    local immediateDanger = preThreat and preThreat.immediateDanger == true
    local projectedDamage = num(preThreat and preThreat.projectedDamage, 0)
    local damagingAttackers = preThreat and preThreat.damagingAttackers or {}
    local immediateLethal = false
    if ctx and ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
        immediateLethal = ctx.threatModel.hasImmediateCommandantLethal(ai, prepared, attackerPlayer, playerToProtect, ctx) == true
    elseif ai and ai.hasImmediateCommandantLethal then
        immediateLethal = ai:hasImmediateCommandantLethal(prepared, attackerPlayer, playerToProtect, ctx) == true
    end

    local blockCells = {}
    if immediateDanger and ctx and ctx.threatModel and ctx.threatModel.findBlockCells then
        blockCells = ctx.threatModel.findBlockCells(ai, prepared, attackerPlayer, playerToProtect, preThreat, ctx) or {}
    end

    if not immediateLethal then
        return {
            immediateLethal = false,
            immediateDanger = immediateDanger,
            projectedDamage = projectedDamage,
            damagingAttackers = damagingAttackers,
            blockCells = blockCells,
            threat = preThreat
        }
    end

    local collectExamples = ctx
        and ctx.cfg
        and ctx.cfg.DETECT_IMMEDIATE_THREAT_COLLECT_EXAMPLES == true
    if not collectExamples then
        return {
            immediateLethal = true,
            immediateDanger = immediateDanger,
            projectedDamage = projectedDamage,
            damagingAttackers = damagingAttackers,
            lethalCount = -1,
            examples = {},
            blockCells = blockCells,
            threat = preThreat,
            reason = "threat_model_lethal"
        }
    end

    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, prepared, attackerPlayer, ctx, {
        mode = "punish_commandant",
        maxCandidates = ctx.cfg.MAX_ENEMY_REPLY_CANDIDATES or 20
    }) or {}

    local lethal = {}
    for _, candidate in ipairs(candidates) do
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
        local after = ctx.cache.simulate(ai, prepared, candidate.actions, attackerPlayer, ctx)
        if after and ctx.evaluator.isCommandantDead(after, playerToProtect) then
            lethal[#lethal + 1] = {
                candidate = candidate,
                afterState = after
            }
        end
    end

    if #lethal == 0 then
        return {
            immediateLethal = true,
            immediateDanger = immediateDanger,
            projectedDamage = projectedDamage,
            damagingAttackers = damagingAttackers,
            lethalCount = 0,
            examples = {},
            blockCells = blockCells,
            threat = preThreat,
            reason = "threat_model_lethal_no_example_line"
        }
    end

    return {
        immediateLethal = true,
        immediateDanger = immediateDanger,
        projectedDamage = projectedDamage,
        damagingAttackers = damagingAttackers,
        lethalCount = #lethal,
        examples = lethal,
        blockCells = blockCells,
        threat = preThreat
    }
end

function M.filterForcedResponses(ai, state, candidates, threat, ctx)
    if not threat or threat.immediateLethal ~= true then
        return candidates, {forced = false}
    end

    local safe = {}
    local unsafe = {}

    for _, candidate in ipairs(candidates or {}) do
        candidate.tacticalTags = candidate.tacticalTags or {}

        local afterOur = ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
        local enemyThreatAfter = M.detectImmediateThreat(ai, afterOur, ctx.aiPlayer, ctx.enemyPlayer, ctx)

        if enemyThreatAfter.immediateLethal then
            candidate.tacticalTags.allowsImmediateLoss = true
            unsafe[#unsafe + 1] = candidate
        else
            candidate.tacticalTags.preventsImmediateLoss = true
            safe[#safe + 1] = candidate
        end

        if ctx.shouldStop and ctx.shouldStop() then
            break
        end
    end

    if #safe > 0 then
        return safe, {
            forced = true,
            safeCount = #safe,
            unsafeCount = #unsafe,
            reason = "enemy_immediate_lethal"
        }
    end

    return candidates, {
        forced = true,
        safeCount = 0,
        unsafeCount = #unsafe,
        reason = "enemy_immediate_lethal_no_defense_found"
    }
end

function M.annotateCandidate(ai, state, candidate, ctx)
    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.annotationReasons = candidate.annotationReasons or {}

    local enemyHub = state and state.commandHubs and state.commandHubs[ctx.enemyPlayer]
    local ownThreat = buildThreatContext(ai, state, ctx.aiPlayer, ctx.enemyPlayer, ctx)

    for _, action in ipairs(candidate.actions or {}) do
        if actionTouchesHub(action, enemyHub) then
            candidate.tacticalTags.commandantPressure = true
            addReason(candidate.annotationReasons, "commandant_pressure")
        end
    end

    if candidate.terminal then
        candidate.tacticalTags.winsNow = true
        addReason(candidate.annotationReasons, "immediate_win")
    end

    if ownThreat then
        if candidateKillsThreatUnit(candidate, ownThreat) then
            candidate.tacticalTags.killsThreateningUnit = true
            addReason(candidate.annotationReasons, "kills_threatening_unit")
        end
        if candidateBlocksThreatLine(candidate, ownThreat) then
            candidate.tacticalTags.blocksThreatLine = true
            addReason(candidate.annotationReasons, "blocks_threat_line")
        end
    end

    if ownThreat and ownThreat.immediateLethal then
        local after = ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
        local enemyThreatAfter = M.detectImmediateThreat(ai, after, ctx.aiPlayer, ctx.enemyPlayer, ctx)
        if enemyThreatAfter.immediateLethal then
            candidate.tacticalTags.allowsImmediateLoss = true
            addReason(candidate.annotationReasons, "allows_immediate_loss")
        else
            candidate.tacticalTags.preventsImmediateLoss = true
            addReason(candidate.annotationReasons, "prevents_immediate_loss")
        end
    end

    return candidate
end

function M.needsTacticalExtension(ai, state, candidate, ctx)
    local tags = candidate and candidate.tacticalTags or {}
    if tags.winsNow or tags.preventsImmediateLoss or tags.allowsImmediateLoss then
        return true
    end

    local forcingBuckets = {
        lethal = true,
        anti_lethal = true,
        commandant_pressure = true,
        high_value_attack = true,
        supply_defense = true,
        supply_offense = true
    }

    for _, bucket in ipairs((candidate and candidate.buckets) or {}) do
        if forcingBuckets[bucket] then
            return true
        end
    end

    if candidate and candidate.containsDeploy then
        return true
    end

    if candidate and candidate.fastScore and ctx and ctx.score then
        local tier = candidate.fastScore.tier
        if tier == ctx.score.TIER.FORCE_WIN_NEXT
            or tier == ctx.score.TIER.STOP_FORCE
            or tier == ctx.score.TIER.AVOID_LOSS
            or tier == ctx.score.TIER.MAJOR_ADVANTAGE then
            return true
        end
    end

    local enemyHub = state and state.commandHubs and state.commandHubs[ctx.enemyPlayer]
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if actionTouchesHub(action, enemyHub) then
            return true
        end
    end

    local after = nil
    if candidate and ctx and ctx.cache then
        after = ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
    end
    if after then
        local ownThreatAfter = buildThreatContext(ai, after, ctx.aiPlayer, ctx.enemyPlayer, ctx)
        if ownThreatAfter and (ownThreatAfter.immediateLethal or ownThreatAfter.immediateDanger) then
            return true
        end
    end

    return false
end

return M
