local candidateBuckets = require("ai_tournament.candidate_buckets")
local movePatternPenalty = require("ai_tournament.move_pattern_penalty")
local turnEnumerator = require("ai_tournament.turn_enumerator")

local M = {}

local UNIT_VALUE_FALLBACK = {
    Commandant = 150,
    Artillery = 90,
    Crusher = 80,
    Earthstalker = 75,
    Cloudstriker = 75,
    Bastion = 70,
    Wingstalker = 45,
    Healer = 40,
    Rock = 0
}

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

local function copyActions(actions)
    local out = {}
    for index, action in ipairs(actions or {}) do
        out[index] = copyAction(action)
    end
    return out
end

local function sameCell(a, b)
    return a
        and b
        and num(a.row, -1) == num(b.row, -2)
        and num(a.col, -1) == num(b.col, -2)
end

local function getOpponent(ai, playerId)
    if ai and ai.getOpponentPlayer then
        return ai:getOpponentPlayer(playerId)
    end
    return playerId == 1 and 2 or 1
end

local function getUnitAt(ai, state, row, col)
    if ai and ai.getUnitAtPosition then
        local ok, unit = pcall(ai.getUnitAtPosition, ai, state, row, col)
        if ok and unit then
            return unit
        end
    end
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and num(unit.row, -1) == num(row, -2) and num(unit.col, -1) == num(col, -2) then
            return unit
        end
    end
    for playerId, hub in pairs((state and state.commandHubs) or {}) do
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

local function unitValue(ai, unit, state)
    if not unit then
        return 0
    end
    if ai and ai.getUnitBaseValue then
        local ok, value = pcall(ai.getUnitBaseValue, ai, unit, state)
        if ok and value ~= nil then
            return num(value, 0)
        end
    end
    return num(UNIT_VALUE_FALLBACK[unit.name], 25)
end

local function calculateDamage(ai, attacker, target)
    if ai and ai.calculateDamage then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    return 0
end

local function isAlive(unit)
    return unit and num(unit.currentHp or unit.startingHp, 0) > 0
end

local function recordSafetyReject(stats, reason)
    if not stats then
        return
    end
    local key = tostring(reason or "unsafe_skirmish")
    stats.safetyRejected = num(stats.safetyRejected, 0) + 1
    stats.safetyRejectedReasons = stats.safetyRejectedReasons or {}
    stats.safetyRejectedReasons[key] = num(stats.safetyRejectedReasons[key], 0) + 1
end

local function callIsSuicidalAttack(ai, state, attack)
    if not (ai and ai.isSuicidalAttack and state and attack and attack.type == "attack") then
        return false
    end
    local attacker = attack.attackerUnit
        or getUnitAt(ai, state, attack.unit and attack.unit.row, attack.unit and attack.unit.col)
    local target = attack.targetUnit
        or getUnitAt(ai, state, attack.target and attack.target.row, attack.target and attack.target.col)
    if not (attacker and target) then
        return false
    end
    local ok, suicidal = pcall(ai.isSuicidalAttack, ai, state, attacker, target)
    return ok and suicidal == true
end

local function callIsSuicidalMovement(ai, state, unit)
    if not (ai and ai.isSuicidalMovement and state and unit) then
        return false
    end
    local ok, suicidal = pcall(ai.isSuicidalMovement, ai, state, {
        row = unit.row,
        col = unit.col
    }, unit)
    return ok and suicidal == true
end

local function simulateActions(ai, state, ctx, actions)
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, actions, ctx.aiPlayer or state.currentPlayer or 1, ctx)
    end
    if ai and ai.simulateActionSequenceForPlayer then
        local ok, result = pcall(
            ai.simulateActionSequenceForPlayer,
            ai,
            state,
            actions,
            ctx and ctx.aiPlayer or state.currentPlayer or 1,
            {}
        )
        if ok then
            return result
        end
    end
    return nil
end

local function finalAttackerAfter(ai, afterState, attack)
    if not (afterState and attack and attack.unit) then
        return nil
    end
    return getUnitAt(ai, afterState, attack.unit.row, attack.unit.col)
end

local function passesSkirmishSafety(ai, state, attackState, afterActions, ctx, attack, details, stats)
    if details and details.winsNow == true then
        return true
    end
    if callIsSuicidalAttack(ai, attackState or state, attack) then
        recordSafetyReject(stats, "suicidal_attack")
        return false
    end
    if afterActions then
        local attackerAfter = finalAttackerAfter(ai, afterActions, attack)
        if not isAlive(attackerAfter) then
            recordSafetyReject(stats, "attacker_lost_after_attack")
            return false
        end
        if callIsSuicidalMovement(ai, afterActions, attackerAfter) then
            recordSafetyReject(stats, "suicidal_post_attack_position")
            return false
        end
    end
    return true
end

local function sequenceSignature(ctx, actions)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.sequenceSignature then
        return ctx.turnEnumerator.sequenceSignature(actions or {})
    end
    return turnEnumerator.sequenceSignature(actions or {})
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
            unit = entry.unit,
            target = entry.target,
            cheapScore = entry.cheapScore
        }
    end
    return nil
end

local function collectEntries(ai, state, ctx, opts)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local raw = {}
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        raw = ctx.turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, opts) or {}
    elseif ai and ai.collectLegalActions then
        raw = ai:collectLegalActions(state, opts) or {}
    else
        raw = turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, opts) or {}
    end

    local entries = {}
    for _, rawEntry in ipairs(raw) do
        local entry = normalizeEntry(rawEntry)
        if entry and entry.action then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function collectAttackEntries(ai, state, ctx)
    return collectEntries(ai, state, ctx, {
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false
    })
end

local function collectMoveEntries(ai, state, ctx)
    return collectEntries(ai, state, ctx, {
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false
    })
end

local function attachSnapshots(action, entry)
    if not (action and entry) then
        return action
    end
    if action.unit and entry.unit and not action.unit.name then
        local unit = copyAction(entry.unit)
        unit.row = action.unit.row
        unit.col = action.unit.col
        action.unit = unit
    end
    if entry.unit and not action.attackerUnit then
        action.attackerUnit = copyAction(entry.unit)
    end
    if entry.target and not action.targetUnit then
        action.targetUnit = copyAction(entry.target)
    end
    return action
end

local function isFactionAttack(ai, state, ctx, action)
    if not (action and action.type == "attack" and action.target) then
        return false
    end
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local target = action.targetUnit or getUnitAt(ai, state, action.target.row, action.target.col)
    return target
        and target.player ~= nil
        and num(target.player, -1) > 0
        and num(target.player, -1) ~= num(playerId, -2)
        and not isObstacle(ai, target)
end

local function attackScore(ai, state, ctx, action, entry, classified)
    local attacker = action.attackerUnit or getUnitAt(ai, state, action.unit and action.unit.row, action.unit and action.unit.col)
    local target = action.targetUnit or getUnitAt(ai, state, action.target and action.target.row, action.target and action.target.col)
    local attackerName = attacker and tostring(attacker.name or "") or nil
    local damage = calculateDamage(ai, attacker, target)
    local targetHp = num(target and (target.currentHp or target.startingHp), 0)
    local targetValue = unitValue(ai, target, state)
    local lethal = targetHp > 0 and damage >= targetHp
    local wounded = targetHp > 0 and targetHp <= math.max(1, damage + 1)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local targetIsEnemyCommandant = target
        and tostring(target.name or "") == "Commandant"
        and num(target.player, -1) ~= num(playerId, -2)
    local base = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_COMBAT_BONUS, 18000)
    local score = base
        + num(classified and classified.cheapScore, num(entry and entry.cheapScore, 0))
        + targetValue * 24
        + damage * 900
        + (lethal and 5200 or 0)
        + (wounded and 1200 or 0)
    return score, {
        damage = damage,
        targetValue = targetValue,
        lethal = lethal,
        winsNow = lethal and targetIsEnemyCommandant == true,
        attackerName = attackerName,
        healerAttack = attackerName == "Healer"
    }
end

local function makeCandidate(ctx, actions, source, reason, score, details)
    local copied = movePatternPenalty.tagPositionMoves(copyActions(actions))
    local tags = {
        earlySkirmish = true,
        earlySkirmishReason = reason,
        earlySkirmishDamage = details and details.damage or nil,
        earlySkirmishTargetValue = details and details.targetValue or nil,
        earlySkirmishAttackerName = details and details.attackerName or nil,
        healerAttack = details and details.healerAttack == true or false,
        winsNow = details and details.winsNow == true or false
    }
    return {
        actions = copied,
        signature = sequenceSignature(ctx, copied),
        source = source,
        buckets = {"early_skirmish", reason},
        cheapScore = math.floor(num(score, 0)),
        tacticalTags = tags,
        containsDeploy = false,
        containsAttack = true,
        hasFactionAttack = true,
        completeTurn = #copied >= num(ctx and ctx.maxActions, 2),
        terminal = false,
        legalSkipReason = nil
    }
end

local function addCandidate(out, seen, candidate)
    local signature = tostring(candidate and candidate.signature or "")
    if signature == "" or seen[signature] then
        return false
    end
    seen[signature] = true
    out[#out + 1] = candidate
    return true
end

local function filterHealerAttackDoctrine(candidates, stats)
    local healerAttackCandidates = 0
    local hasNonHealerCombat = false

    for _, candidate in ipairs(candidates or {}) do
        local tags = candidate and candidate.tacticalTags or {}
        local doctrinalHealerAttack = tags.healerAttack == true and tags.winsNow ~= true
        if doctrinalHealerAttack then
            healerAttackCandidates = healerAttackCandidates + 1
        else
            hasNonHealerCombat = true
        end
    end

    if stats then
        stats.healerAttackCandidates = healerAttackCandidates
        stats.healerAttackRejectedByDoctrine = 0
        stats.healerAttackFallbackUsed = false
    end

    if healerAttackCandidates <= 0 then
        return candidates
    end

    if not hasNonHealerCombat then
        if stats then
            stats.healerAttackFallbackUsed = true
        end
        return candidates
    end

    local filtered = {}
    for _, candidate in ipairs(candidates or {}) do
        local tags = candidate and candidate.tacticalTags or {}
        if tags.healerAttack == true and tags.winsNow ~= true then
            if stats then
                stats.healerAttackRejectedByDoctrine = num(stats.healerAttackRejectedByDoctrine, 0) + 1
            end
        else
            filtered[#filtered + 1] = candidate
        end
    end

    return filtered
end

local function generateDirect(ai, state, ctx, out, seen, stats, cap)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local entries = collectAttackEntries(ai, state, ctx)
    stats.legalDirect = #entries
    local prepared = {}
    for _, entry in ipairs(entries) do
        local action = attachSnapshots(copyAction(entry.action), entry)
        if isFactionAttack(ai, state, ctx, action) then
            local classified = candidateBuckets.classifyAction(ai, state, action, playerId, ctx, {
                entry = entry,
                stage = "first"
            })
            local score, details = attackScore(ai, state, ctx, action, entry, classified)
            if num(details.damage, 0) > 0 then
                prepared[#prepared + 1] = {
                    action = action,
                    score = score,
                    details = details
                }
            end
        end
    end
    table.sort(prepared, function(a, b)
        if num(a and a.score, 0) == num(b and b.score, 0) then
            return sequenceSignature(ctx, {a and a.action}) < sequenceSignature(ctx, {b and b.action})
        end
        return num(a and a.score, 0) > num(b and b.score, 0)
    end)
    for _, item in ipairs(prepared) do
        if stats.directGenerated >= cap then
            break
        end
        local candidate = makeCandidate(
            ctx,
            {item.action},
            "early_skirmish_attack",
            "direct_attack",
            item.score,
            item.details
        )
        local afterAttack = simulateActions(ai, state, ctx, {item.action})
        if afterAttack
            and passesSkirmishSafety(ai, state, state, afterAttack, ctx, item.action, item.details, stats)
            and addCandidate(out, seen, candidate) then
            stats.directGenerated = stats.directGenerated + 1
        end
    end
end

local function generateMoveAttacks(ai, state, ctx, out, seen, stats, scanCap, cap)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local entries = collectMoveEntries(ai, state, ctx)
    stats.legalMoves = #entries
    table.sort(entries, function(a, b)
        if num(a and a.cheapScore, 0) == num(b and b.cheapScore, 0) then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return num(a and a.cheapScore, 0) > num(b and b.cheapScore, 0)
    end)

    local scanned = 0
    for _, moveEntry in ipairs(entries) do
        if scanned >= scanCap or stats.moveAttackGenerated >= cap then
            break
        end
        local move = attachSnapshots(copyAction(moveEntry and moveEntry.action), moveEntry)
        if move and move.type == "move" then
            scanned = scanned + 1
            local afterMove = ctx and ctx.cache and ctx.cache.simulate
                and ctx.cache.simulate(ai, state, {move}, playerId, ctx)
                or nil
            if afterMove then
                for _, attackEntry in ipairs(collectAttackEntries(ai, afterMove, ctx)) do
                    local attack = attachSnapshots(copyAction(attackEntry.action), attackEntry)
                    if attack
                        and attack.type == "attack"
                        and sameCell(attack.unit, move.target)
                        and isFactionAttack(ai, afterMove, ctx, attack) then
                        local classified = candidateBuckets.classifyAction(ai, afterMove, attack, playerId, ctx, {
                            entry = attackEntry,
                            stage = "second"
                        })
                        local score, details = attackScore(ai, afterMove, ctx, attack, attackEntry, classified)
                        if num(details.damage, 0) > 0 then
                            local moveScore = movePatternPenalty.adjustScore(
                                ai,
                                state,
                                ctx,
                                move,
                                num(moveEntry and moveEntry.cheapScore, 0) * 0.1,
                                stats
                            )
                            local candidate = makeCandidate(
                                ctx,
                                {move, attack},
                                "early_skirmish_move_attack",
                                "move_attack",
                                score + moveScore,
                                details
                            )
                            local afterActions = ctx and ctx.cache and ctx.cache.simulate
                                and ctx.cache.simulate(ai, state, {move, attack}, playerId, ctx)
                                or simulateActions(ai, state, ctx, {move, attack})
                            if afterActions
                                and passesSkirmishSafety(
                                    ai,
                                    state,
                                    afterMove,
                                    afterActions,
                                    ctx,
                                    attack,
                                    details,
                                    stats
                                )
                                and addCandidate(out, seen, candidate) then
                                stats.moveAttackGenerated = stats.moveAttackGenerated + 1
                                if stats.moveAttackGenerated >= cap then
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    stats.moveScanned = scanned
end

function M.generate(ai, state, ctx, opts)
    local options = opts or {}
    local stats = {
        legalDirect = 0,
        legalMoves = 0,
        moveScanned = 0,
        directGenerated = 0,
        moveAttackGenerated = 0,
        movePatternPenalized = 0,
        movePatternPenaltyMax = 0,
        cloudstrikerMeleeContactPenalized = 0,
        cloudstrikerMeleeContactPenaltyMax = 0,
        safetyRejected = 0,
        safetyRejectedReasons = {}
    }
    if not (ai and state and ctx) then
        return {}, stats
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_CANDIDATES_ENABLED == false then
        stats.skippedReason = "disabled"
        return {}, stats
    end
    if num(ctx.stats and ctx.stats.legalAttackActions, 0) <= 0
        and num(ctx.stats and ctx.stats.legalMoveAttackActions, 0) <= 0 then
        stats.skippedReason = "no_skirmish_opportunity"
        return {}, stats
    end

    local out = {}
    local seen = {}
    local directCap = clampLimit(
        options.directCap or ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_DIRECT_ATTACK_CAP or 8,
        0,
        32
    )
    local moveScanCap = clampLimit(
        options.moveAttackScanCap or ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_MOVE_ATTACK_SCAN_CAP or 20,
        0,
        96
    )
    local moveAttackCap = clampLimit(
        options.moveAttackCap or ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_MOVE_ATTACK_CAP or 8,
        0,
        32
    )

    if directCap > 0 then
        generateDirect(ai, state, ctx, out, seen, stats, directCap)
    end
    if moveAttackCap > 0 and moveScanCap > 0 then
        generateMoveAttacks(ai, state, ctx, out, seen, stats, moveScanCap, moveAttackCap)
    end
    out = filterHealerAttackDoctrine(out, stats)

    table.sort(out, function(a, b)
        if num(a and a.cheapScore, 0) == num(b and b.cheapScore, 0) then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return num(a and a.cheapScore, 0) > num(b and b.cheapScore, 0)
    end)

    return out, stats
end

return M
