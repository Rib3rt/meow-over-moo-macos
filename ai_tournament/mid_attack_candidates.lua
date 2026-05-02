local turnEnumerator = require("ai_tournament.turn_enumerator")
local midSecondAction = require("ai_tournament.mid_second_action")
local budgetScope = require("ai_tournament.pipeline_v2_budget_scope")
local drawPressure = require("ai_tournament.draw_pressure")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clampLimit(value, minValue, maxValue)
    local n = num(value, minValue)
    if n < minValue then
        return minValue
    end
    if n > maxValue then
        return maxValue
    end
    return n
end

local function pushSecondBudget(ctx, stats)
    local extraMs = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_EXTRA_MS or 0, 0, 5000)
    if extraMs <= 0 then
        return nil
    end
    return budgetScope.push(ctx, stats, {
        extraMs = extraMs,
        extraKey = "pipelineV2MidSecondExtraMs",
        remainingKey = "pipelineV2MidRemainingBeforeSecondMs",
        startKey = "pipelineV2MidSecondStartElapsedMs",
        extendedKey = "pipelineV2MidSecondExtendedHardBudgetMs",
        localWindowKey = "pipelineV2MidSecondLocalWindowMs"
    })
end

local function copyAction(action)
    local out = {}
    for key, value in pairs(action or {}) do
        if type(value) == "table" then
            local child = {}
            for childKey, childValue in pairs(value) do
                child[childKey] = childValue
            end
            out[key] = child
        else
            out[key] = value
        end
    end
    return out
end

local function attachActionSnapshot(action, entry)
    if not (action and entry) then
        return action
    end
    if entry.target and not action.targetUnit then
        action.targetUnit = copyAction(entry.target)
    end
    if entry.unit and not action.attackerUnit then
        action.attackerUnit = copyAction(entry.unit)
    end
    return action
end

local function bumpReason(map, reason)
    if not map then
        return
    end
    local key = tostring(reason or "unknown")
    map[key] = num(map[key], 0) + 1
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function targetCell(ctx, midMap, action)
    local key = cellKey(action and action.target)
    local personalityCell = ctx
        and ctx.midPersonality
        and ctx.midPersonality.byKey
        and ctx.midPersonality.byKey[key]
        or nil
    local mapCell = midMap and midMap.byKey and midMap.byKey[key] or nil
    return personalityCell, mapCell, key
end

local function getUnitAt(ai, state, row, col)
    if not (state and row and col) then
        return nil
    end
    if ai and ai.getUnitAtPosition then
        local ok, unit = pcall(ai.getUnitAtPosition, ai, state, row, col)
        if ok and unit then
            return unit
        end
    end
    for _, unit in ipairs(state.units or {}) do
        if unit and num(unit.row, -1) == num(row, -2) and num(unit.col, -1) == num(col, -2) then
            return unit
        end
    end
    for playerId, hub in pairs(state.commandHubs or {}) do
        if hub and num(hub.row, -1) == num(row, -2) and num(hub.col, -1) == num(col, -2) then
            return {
                name = hub.name or "Commandant",
                player = playerId,
                row = hub.row,
                col = hub.col,
                currentHp = hub.currentHp,
                startingHp = hub.startingHp
            }
        end
    end
    return nil
end

local function isObstacle(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        local ok, result = pcall(ai.isObstacleUnit, ai, unit)
        if ok then
            return result == true
        end
    end
    return unit.player == 0 or tostring(unit.name or "") == "Rock"
end

local function isFactionAttackAction(ai, state, ctx, action)
    if not (action and action.type == "attack" and action.target) then
        return false
    end
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer
    local target = getUnitAt(ai, state, action.target.row, action.target.col)
    if not target and action.targetUnit and action.targetUnit.player ~= nil then
        target = action.targetUnit
    end
    return target
        and target.player ~= nil
        and num(target.player, -1) > 0
        and num(target.player, -1) ~= num(playerId, -2)
        and not isObstacle(ai, target)
end

local function drawActive(ai, state, ctx)
    if ctx and ctx.stats and ctx.stats.officialDrawUrgencyActive == true then
        return true
    end
    local draw = drawPressure.build(ai, state, ctx)
    return draw and draw.active == true
end

local function actionSignature(ctx, action)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.actionSignature then
        return ctx.turnEnumerator.actionSignature(action)
    end
    return turnEnumerator.actionSignature(action)
end

local function sequenceSignature(ctx, actions)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.sequenceSignature then
        return ctx.turnEnumerator.sequenceSignature(actions)
    end
    return turnEnumerator.sequenceSignature(actions)
end

local function normalizeEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    if entry.action then
        return entry
    end
    if entry.type then
        return {
            action = entry,
            signature = actionSignature(nil, entry),
            cheapScore = num(entry.cheapScore, 0)
        }
    end
    return nil
end

local function collectAttackEntries(ai, state, ctx)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local raw = {}
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        raw = ctx.turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = false,
            includeAttack = true,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    elseif ai and ai.collectLegalActions then
        raw = ai:collectLegalActions(state, {
            aiPlayer = playerId,
            includeMove = false,
            includeAttack = true,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    else
        raw = turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = false,
            includeAttack = true,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    end

    local entries = {}
    for _, rawEntry in ipairs(raw) do
        local entry = normalizeEntry(rawEntry)
        if entry and entry.action and entry.action.type == "attack" then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function collectMoveEntries(ai, state, ctx)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local raw = {}
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        raw = ctx.turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = true,
            includeAttack = false,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    elseif ai and ai.collectLegalActions then
        raw = ai:collectLegalActions(state, {
            aiPlayer = playerId,
            includeMove = true,
            includeAttack = false,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    else
        raw = turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = true,
            includeAttack = false,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    end

    local entries = {}
    for _, rawEntry in ipairs(raw) do
        local entry = normalizeEntry(rawEntry)
        if entry and entry.action and entry.action.type == "move" then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function attackPreScore(ai, state, ctx, midMap, entry, underDrawPressure)
    local personalityCell, mapCell = targetCell(ctx, midMap, entry and entry.action)
    local personalityValue = num(personalityCell and personalityCell.value, 0)
    local mapValue = num(mapCell and mapCell.value, 0)
    local score = personalityValue + (mapValue * 0.25) + num(entry and entry.cheapScore, 0)
    if isFactionAttackAction(ai, state, ctx, entry and entry.action) then
        score = score + num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_FACTION_ATTACK_PRESCORE_BONUS, 5000)
    elseif underDrawPressure then
        score = score - num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_NONFACTION_ATTACK_PRESCORE_PENALTY, 2500)
    end
    return score
end

local function moveCellScore(ctx, midMap, entry)
    local personalityCell, mapCell = targetCell(ctx, midMap, entry and entry.action)
    local personalityValue = num(personalityCell and personalityCell.value, 0)
    local mapValue = num(mapCell and mapCell.value, 0)
    return personalityValue + (mapValue * 0.25) + num(entry and entry.cheapScore, 0)
end

local function sameCell(a, b)
    return a and b and num(a.row, -1) == num(b.row, -2) and num(a.col, -1) == num(b.col, -2)
end

local function endgameSingleActionAllowed(ctx)
    return ctx
        and ctx.pipelineV2EndRuntime == true
        and ctx.supply
        and ctx.supply.own
        and num(ctx.supply.own.count, 0) <= 0
end

local function attachTrade(candidate, trade)
    candidate._midAfterState = trade and trade.afterState or nil
    if trade then
        trade.afterState = nil
    end
    candidate.midTrade = trade
    candidate.hasFactionAttack = trade and num(trade.factionAttackCount, 0) > 0 or candidate.containsAttack == true
    candidate.combatValue = {
        damage = num(trade and trade.totalDamage, 0),
        kills = num(trade and trade.kills, 0),
        commandantDamage = num(trade and trade.commandantDamage, 0)
    }
    candidate.cheapScore = num(candidate.cheapScore, 0) + num(trade and trade.score, 0)
    candidate.tacticalTags.midTradeReason = trade and trade.reason or nil
    candidate.tacticalTags.midTradeClass = trade and trade.class or nil
    candidate.tacticalTags.drawSuicideChip = trade and trade.drawSuicideChip == true or nil
    candidate.tacticalTags.drawZeroDamageReset = trade and trade.drawZeroDamageReset == true or nil
    candidate.tacticalTags.winsNow = trade and trade.class == "win_now" or false
end

local function recordAcceptedTradeShape(stats, trade)
    if not stats then
        return
    end
    if trade and trade.drawSuicideChip == true then
        stats.pipelineV2MidWeakSuicideInteractionCandidates =
            num(stats.pipelineV2MidWeakSuicideInteractionCandidates, 0) + 1
    else
        stats.pipelineV2MidMeaningfulInteractionCandidates =
            num(stats.pipelineV2MidMeaningfulInteractionCandidates, 0) + 1
    end
end

local function compactCandidate(candidate)
    local trade = candidate and candidate.midTrade or nil
    if not trade then
        return nil
    end
    local signature = candidate.signature or sequenceSignature(nil, candidate.actions or {})
    return table.concat({
        tostring(math.floor(num(candidate.cheapScore, 0))),
        tostring(trade.reason or "none"),
        tostring(signature),
        table.concat(trade.compactReasons or {}, "+")
    }, ":")
end

function M.generate(ai, state, ctx, midMap, tradeModel, options)
    options = options or {}
    local stats = ctx and ctx.stats or nil
    if stats then
        stats.pipelineV2MidAttackCandidates = 0
        stats.pipelineV2MidAttackEvaluated = 0
        stats.pipelineV2MidAttackRejectedReasons = {}
        stats.pipelineV2MidAttackTop = {}
        stats.pipelineV2MidAttackPrefixesAccepted = 0
        stats.pipelineV2MidAttackPrefixesWithoutSecond = 0
        stats.pipelineV2MidMoveAttackEvaluated = 0
        stats.pipelineV2MidMoveAttackAccepted = 0
        stats.pipelineV2MidMoveAttackCandidates = 0
    end

    if not (ai and state and ctx and tradeModel and tradeModel.evaluateAttack) then
        return {}
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_MID_ATTACK_CANDIDATES_ENABLED == false then
        if stats then
            stats.pipelineV2MidAttackSkippedReason = "disabled"
        end
        return {}
    end

    local entries = collectAttackEntries(ai, state, ctx)
    if stats then
        stats.pipelineV2MidAttackLegalActions = #entries
    end
    local underDrawPressure = drawActive(ai, state, ctx)

    table.sort(entries, function(a, b)
        local av = attackPreScore(ai, state, ctx, midMap, a, underDrawPressure)
        local bv = attackPreScore(ai, state, ctx, midMap, b, underDrawPressure)
        if av == bv then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return av > bv
    end)

    local scanCap = clampLimit(
        options.scanCap or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_ATTACK_SCAN_CAP) or 18,
        1,
        80
    )
    if underDrawPressure and num(ctx and ctx.stats and ctx.stats.legalAttackActions, 0) > 0 then
        scanCap = math.max(
            scanCap,
            clampLimit(ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_ATTACK_SCAN_CAP or 48, 1, 80)
        )
    end
    local maxCandidates = clampLimit(
        options.maxCandidates or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_ATTACK_CANDIDATE_CAP) or 8,
        1,
        32
    )
    if underDrawPressure
        and (
            num(ctx and ctx.stats and ctx.stats.legalAttackActions, 0) > 0
            or num(ctx and ctx.stats and ctx.stats.legalMoveAttackActions, 0) > 0
        ) then
        maxCandidates = math.max(
            maxCandidates,
            clampLimit(ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_ATTACK_CANDIDATE_CAP or 16, 1, 32)
        )
    end
    local candidates = {}
    local prefixSeen = {}
    local seen = {}
    local scanned = 0

    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        if ctx.shouldStop and ctx.shouldStop() then
            if stats then
                stats.pipelineV2MidAttackStopped = true
            end
            break
        end

        scanned = scanned + 1
        local action = attachActionSnapshot(copyAction(entry.action), entry)
        local actions = {action}
        local signature = sequenceSignature(ctx, actions)
        if not prefixSeen[signature] then
            prefixSeen[signature] = true
            local personalityCell, mapCell, key = targetCell(ctx, midMap, action)
            local candidate = {
                actions = actions,
                signature = signature,
                source = "mid_v2_attack",
                buckets = {"mid_attack"},
                cheapScore = attackPreScore(ai, state, ctx, midMap, entry, underDrawPressure),
                tacticalTags = {
                    midV2 = true,
                    midAttack = true,
                    midTargetKey = key,
                    midTargetStatus = mapCell and mapCell.status or nil,
                    midTargetValue = personalityCell and personalityCell.value or mapCell and mapCell.value or nil
                },
                containsDeploy = false,
                containsAttack = true,
                completeTurn = false,
                terminal = false,
                legalSkipReason = nil
            }

            local trade = tradeModel.evaluateAttack(ai, state, ctx, candidate, {
                profile = ctx.midPersonality and ctx.midPersonality.profile or nil,
                includeAfterState = true
            })
            if stats then
                stats.pipelineV2MidAttackEvaluated = num(stats.pipelineV2MidAttackEvaluated, 0) + 1
            end

            if trade and trade.accepted == true then
                recordAcceptedTradeShape(stats, trade)
                if stats then
                    stats.pipelineV2MidAttackPrefixesAccepted =
                        num(stats.pipelineV2MidAttackPrefixesAccepted, 0) + 1
                end
                attachTrade(candidate, trade)
                local secondBudget = pushSecondBudget(ctx, stats)
                local completed = midSecondAction.complete(ai, state, ctx, midMap, tradeModel, candidate, {
                    scanCap = ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_SCAN_CAP or nil,
                    maxCompletions = ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_COMPLETION_CAP or nil
                })
                if secondBudget then
                    secondBudget.pop()
                end
                if #completed == 0 then
                    if stats then
                        stats.pipelineV2MidAttackPrefixesWithoutSecond =
                            num(stats.pipelineV2MidAttackPrefixesWithoutSecond, 0) + 1
                    end
                    if endgameSingleActionAllowed(ctx) then
                        candidate.completeTurn = true
                        candidate.tacticalTags.endgameSingleAction = true
                        seen[signature] = true
                        candidates[#candidates + 1] = candidate
                        if stats then
                            stats.pipelineV2MidAttackEndgameSingleActionAccepted =
                                num(stats.pipelineV2MidAttackEndgameSingleActionAccepted, 0) + 1
                        end
                    else
                        bumpReason(stats and stats.pipelineV2MidAttackRejectedReasons, "mid_no_second_action")
                    end
                end
                for _, fullCandidate in ipairs(completed) do
                    local fullSignature = tostring(fullCandidate.signature or sequenceSignature(ctx, fullCandidate.actions))
                    if not seen[fullSignature] then
                        seen[fullSignature] = true
                        fullCandidate.signature = fullSignature
                        candidates[#candidates + 1] = fullCandidate
                    end
                    if #candidates >= maxCandidates then
                        break
                    end
                end
                if #candidates >= maxCandidates then
                    break
                end
            elseif stats then
                bumpReason(stats.pipelineV2MidAttackRejectedReasons, trade and trade.reason or "trade_rejected")
            end
        end
    end

    if not (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MOVE_ATTACK_CANDIDATES_ENABLED == false) then
        local moveEntries = collectMoveEntries(ai, state, ctx)
        if stats then
            stats.pipelineV2MidMoveAttackLegalMoves = #moveEntries
        end
        table.sort(moveEntries, function(a, b)
            local av = moveCellScore(ctx, midMap, a)
            local bv = moveCellScore(ctx, midMap, b)
            if av == bv then
                return tostring(a and a.signature or "") < tostring(b and b.signature or "")
            end
            return av > bv
        end)

        local moveScanCap = clampLimit(
            options.moveAttackScanCap or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MOVE_ATTACK_SCAN_CAP) or 12,
            0,
            80
        )
        if underDrawPressure and num(ctx and ctx.stats and ctx.stats.legalMoveAttackActions, 0) > 0 then
            moveScanCap = math.max(
                moveScanCap,
                clampLimit(ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_MOVE_ATTACK_SCAN_CAP or 48, 0, 80)
            )
        end
        local moveScanned = 0
        local moveAccepted = 0
        for _, moveEntry in ipairs(moveEntries) do
            if moveScanned >= moveScanCap or moveAccepted >= maxCandidates then
                break
            end
            if ctx.shouldStop and ctx.shouldStop() then
                if stats then
                    stats.pipelineV2MidAttackStopped = true
                end
                break
            end

            local move = copyAction(moveEntry.action)
            local afterMove = ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, {move}, ctx.aiPlayer, ctx) or nil
            moveScanned = moveScanned + 1
            if afterMove then
                local attackEntries = collectAttackEntries(ai, afterMove, ctx)
                for _, attackEntry in ipairs(attackEntries) do
                    local attack = attachActionSnapshot(copyAction(attackEntry and attackEntry.action), attackEntry)
                    if attack and attack.type == "attack" and sameCell(attack.unit, move.target) then
                        local actions = {move, attack}
                        local fullSignature = sequenceSignature(ctx, actions)
                        if not seen[fullSignature] then
                            local personalityCell, mapCell, key = targetCell(ctx, midMap, attack)
                            local candidate = {
                                actions = actions,
                                signature = fullSignature,
                                source = "mid_v2_move_attack",
                                buckets = {"mid_attack", "move_attack"},
                                cheapScore = moveCellScore(ctx, midMap, moveEntry)
                                    + attackPreScore(ai, afterMove, ctx, midMap, attackEntry, underDrawPressure),
                                tacticalTags = {
                                    midV2 = true,
                                    midAttack = true,
                                    midMoveAttack = true,
                                    midTargetKey = key,
                                    midTargetStatus = mapCell and mapCell.status or nil,
                                    midTargetValue = personalityCell and personalityCell.value or mapCell and mapCell.value or nil
                                },
                                containsDeploy = false,
                                containsAttack = true,
                                completeTurn = true,
                                terminal = false,
                                legalSkipReason = nil
                            }
                            local trade = tradeModel.evaluateAttack(ai, state, ctx, candidate, {
                                profile = ctx.midPersonality and ctx.midPersonality.profile or nil,
                                includeAfterState = true
                            })
                            if stats then
                                stats.pipelineV2MidMoveAttackEvaluated =
                                    num(stats.pipelineV2MidMoveAttackEvaluated, 0) + 1
                            end
                            if trade and trade.accepted == true then
                                recordAcceptedTradeShape(stats, trade)
                                attachTrade(candidate, trade)
                                seen[fullSignature] = true
                                candidates[#candidates + 1] = candidate
                                moveAccepted = moveAccepted + 1
                                if stats then
                                    stats.pipelineV2MidMoveAttackAccepted =
                                        num(stats.pipelineV2MidMoveAttackAccepted, 0) + 1
                                end
                                if moveAccepted >= maxCandidates then
                                    break
                                end
                            elseif stats then
                                bumpReason(stats.pipelineV2MidAttackRejectedReasons, trade and trade.reason or "move_attack_trade_rejected")
                            end
                        end
                    end
                end
            elseif stats then
                bumpReason(stats.pipelineV2MidAttackRejectedReasons, "mid_move_attack_simulation_failed")
            end
        end
        if stats then
            stats.pipelineV2MidMoveAttackScanned = moveScanned
            stats.pipelineV2MidMoveAttackCandidates = moveAccepted
        end
    elseif stats then
        stats.pipelineV2MidMoveAttackSkippedReason = "disabled"
    end

    table.sort(candidates, function(a, b)
        local av = num(a and a.cheapScore, 0)
        local bv = num(b and b.cheapScore, 0)
        if av == bv then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return av > bv
    end)
    while #candidates > maxCandidates do
        candidates[#candidates] = nil
    end

    if stats then
        stats.pipelineV2MidAttackScanned = scanned
        stats.pipelineV2MidAttackCandidates = #candidates
        for index, candidate in ipairs(candidates) do
            if index > 5 then
                break
            end
            stats.pipelineV2MidAttackTop[#stats.pipelineV2MidAttackTop + 1] = compactCandidate(candidate)
        end
    end

    return candidates
end

return M
