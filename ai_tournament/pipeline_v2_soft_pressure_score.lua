local rangedResponseScore = require("ai_tournament.ranged_response_score")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function threatPayload(threatResult)
    if not threatResult then
        return nil
    end
    return threatResult.threat or threatResult
end

local function projectedDamage(threatResult)
    local threat = threatPayload(threatResult)
    return num((threatResult and threatResult.projectedDamage) or (threat and threat.projectedDamage), 0)
end

local function attackerCount(threatResult)
    local threat = threatPayload(threatResult)
    return #((threatResult and threatResult.damagingAttackers) or (threat and threat.damagingAttackers) or {})
end

local function threatEntries(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.damagingAttackers)
        or (threat and threat.damagingAttackers)
        or {}
end

local function immediateDanger(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateDanger == true)
        or (threat and threat.immediateDanger == true)
        or projectedDamage(threatResult) > 0
        or attackerCount(threatResult) > 0
end

local function immediateLethal(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateLethal == true)
        or (threat and threat.immediateLethal == true)
end

local function enabled(ctx)
    local cfg = ctx and ctx.cfg or nil
    return not (cfg and cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_SCORING_ENABLED == false)
end

local function clamp(value, minValue, maxValue)
    local n = num(value, minValue)
    if n < minValue then
        return minValue
    end
    if n > maxValue then
        return maxValue
    end
    return n
end

local function pressureScale(ctx)
    local cfg = ctx and ctx.cfg or {}
    local phase = ctx and ctx.phase or {}
    if ctx and (ctx.pipelineV2EndRuntime == true or phase.endgame == true) then
        return clamp(cfg.PIPELINE_V2_ENDGAME_SOFT_DEFENSE_PRESSURE_SCALE, 0, 2)
    end
    if phase.mid == true then
        return clamp(cfg.PIPELINE_V2_MID_SOFT_DEFENSE_PRESSURE_SCALE, 0, 2)
    end
    if phase.early == true then
        return clamp(cfg.PIPELINE_V2_EARLY_SOFT_DEFENSE_PRESSURE_SCALE, 0, 2)
    end
    return 1
end

local function isSoftPressure(contracts)
    return contracts
        and contracts.defenseKind == "pressure"
        and contracts.defensePressureSoft == true
        and contracts.defenseThreat ~= nil
end

local function isSoftLethal(contracts)
    return contracts
        and contracts.defenseLethalSoft == true
        and contracts.defenseThreat ~= nil
end

local function isSoftDefense(contracts)
    return isSoftPressure(contracts) or isSoftLethal(contracts)
end

local function afterThreatFor(ai, afterOur, ctx)
    if ctx and ctx.cache and ctx.cache.threat then
        return ctx.cache.threat(ai, afterOur, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    end
    if ctx and ctx.threatModel and ctx.threatModel.analyzeHubThreatForPlayer then
        return ctx.threatModel.analyzeHubThreatForPlayer(ai, afterOur, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    end
    if ai and ai.analyzeHubThreatForPlayer then
        return ai:analyzeHubThreatForPlayer(afterOur, ctx and ctx.aiPlayer, ctx and ctx.enemyPlayer, ctx)
    end
    return nil
end

local function candidateReason(candidate)
    local tags = candidate and candidate.tacticalTags or {}
    return tostring(
        tags.earlyPositionReason
            or tags.midPositionReason
            or (candidate and candidate.source)
            or ""
    )
end

local function looksLikePressureResponse(candidate)
    local tags = candidate and candidate.tacticalTags or {}
    local reason = candidateReason(candidate)
    return tags.defensivePressureMove == true
        or tags.blocksThreatLine == true
        or string.find(reason, "pressure", 1, true) ~= nil
        or string.find(reason, "defense", 1, true) ~= nil
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    if row == nil or col == nil then
        return nil
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
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

local function calculateDamage(ai, attacker, target)
    if not (attacker and target) then
        return 0
    end
    if ai and ai.calculateDamage then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok and tonumber(value) then
            return math.max(0, num(value, 0))
        end
    end
    return math.max(0, num(attacker.atkDamage, 0))
end

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function isRangedUnit(ai, unit)
    if not unit then
        return false
    end
    local range = num(unit.atkRange or unit.attackRange or unit.range, nil)
    if range and range > 1 then
        return true
    end
    if ai and ai.unitHasTag then
        local ok, value = pcall(ai.unitHasTag, ai, unit, "ranged")
        if ok and value == true then
            return true
        end
    end
    local name = tostring(unit.name or "")
    return name == "Cloudstriker" or name == "Artillery"
end

local function isFactionEnemy(target, playerId)
    return target
        and target.player ~= nil
        and num(target.player, -1) > 0
        and num(target.player, -1) ~= num(playerId, -2)
end

local function simulateOne(ai, state, action, ctx)
    if not (state and action and action.type and action.type ~= "skip") then
        return state
    end
    if ctx and ctx.cache and ctx.cache.simulate then
        local ok, simulated = pcall(ctx.cache.simulate, ai, state, {action}, ctx.aiPlayer, ctx)
        if ok and simulated then
            return simulated
        end
    end
    if ai and ai.simulateActionSequenceForPlayer then
        local ok, simulated = pcall(ai.simulateActionSequenceForPlayer, ai, state, {action}, ctx and ctx.aiPlayer, {})
        if ok and simulated then
            return simulated
        end
    end
    return state
end

local function buildThreatLookup(ai, beforeThreat)
    local lookup = {}
    local ranged = false
    local count = 0
    for _, entry in ipairs(threatEntries(beforeThreat)) do
        local unit = entry and entry.unit
        local key = cellKey(unit)
        if key then
            lookup[key] = {
                unit = unit,
                ranged = isRangedUnit(ai, unit)
            }
            count = count + 1
            ranged = ranged or lookup[key].ranged == true
        end
    end
    return lookup, ranged, count
end

local function sourceScoringEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_SOFT_DEFENSE_SOURCE_SCORING_ENABLED == false)
end

local function buildSourceAnalysis(ai, ctx, contracts, candidate, beforeThreat, delta)
    if not (sourceScoringEnabled(ctx) and candidate and candidate.actions and ctx and ctx.currentState) then
        return nil
    end

    local threatLookup, hasRangedThreat = buildThreatLookup(ai, beforeThreat)
    if not next(threatLookup) then
        return nil
    end

    local playerId = ctx.aiPlayer
    local current = ctx.currentState
    local out = {
        targetsThreat = false,
        targetThreatAttacks = 0,
        sourceDamage = 0,
        sourceKills = 0,
        sourceRanged = false,
        offThreatFactionAttacks = 0,
        rangedDuelNonReducing = false,
        hasRangedThreat = hasRangedThreat,
        hasFactionAttack = false,
        bonus = 0,
        penalty = 0,
        reasons = {}
    }

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "attack" then
            local attacker = action.unit and getUnitAt(ai, current, action.unit.row, action.unit.col) or nil
            local target = action.target and getUnitAt(ai, current, action.target.row, action.target.col) or nil
            if not target and action.targetUnit then
                target = action.targetUnit
            end
            local targetKey = cellKey(target or action.target)
            local threatInfo = targetKey and threatLookup[targetKey] or nil
            local damage = calculateDamage(ai, attacker, target)
            local lethal = target and unitHp(target) > 0 and damage >= unitHp(target)
            local factionEnemy = isFactionEnemy(target, playerId)

            if factionEnemy then
                out.hasFactionAttack = true
            end
            if threatInfo then
                out.targetsThreat = true
                out.targetThreatAttacks = out.targetThreatAttacks + 1
                out.sourceDamage = out.sourceDamage + damage
                out.sourceKills = out.sourceKills + (lethal and 1 or 0)
                out.sourceRanged = out.sourceRanged or threatInfo.ranged == true
                if isRangedUnit(ai, attacker)
                    and isRangedUnit(ai, target)
                    and not lethal
                    and delta
                    and delta.reduced ~= true then
                    out.rangedDuelNonReducing = true
                end
            elseif factionEnemy then
                out.offThreatFactionAttacks = out.offThreatFactionAttacks + 1
            end
        end
        current = simulateOne(ai, current, action, ctx)
    end

    local cfg = ctx.cfg or {}
    if out.targetsThreat then
        local damageWeight = num(cfg.PIPELINE_V2_SOFT_DEFENSE_SOURCE_DAMAGE_WEIGHT, 1800)
        local sourceBonus = math.max(0, out.sourceDamage) * damageWeight
        if delta and delta.reduced == true then
            sourceBonus = sourceBonus + num(cfg.PIPELINE_V2_SOFT_DEFENSE_SOURCE_REDUCTION_BONUS, 7000)
            out.reasons[#out.reasons + 1] = "soft_pressure_source_reduced"
            if delta.cleared == true then
                sourceBonus = sourceBonus + num(cfg.PIPELINE_V2_SOFT_DEFENSE_SOURCE_CLEAR_BONUS, 11000)
                out.reasons[#out.reasons + 1] = "soft_pressure_source_cleared"
            end
            if out.sourceRanged then
                sourceBonus = sourceBonus + num(cfg.PIPELINE_V2_SOFT_DEFENSE_SOURCE_RANGED_BONUS, 5000)
                out.reasons[#out.reasons + 1] = "soft_pressure_ranged_source_answered"
            end
        elseif out.sourceDamage > 0 then
            sourceBonus = math.floor(sourceBonus * 0.45)
            out.reasons[#out.reasons + 1] = "soft_pressure_source_chipped"
        end
        out.bonus = out.bonus + sourceBonus
    end

    local responseAvailable = num(contracts and contracts.directThreatAttackActions, 0)
        + num(contracts and contracts.directThreatReductionActions, 0)
        + num(contracts and contracts.moveThreatAttackActions, 0)
    if not (delta and delta.reduced == true)
        and out.offThreatFactionAttacks > 0
        and not out.targetsThreat then
        local penalty = num(cfg.PIPELINE_V2_SOFT_DEFENSE_OFF_SOURCE_ATTACK_PENALTY, 9000)
        if responseAvailable > 0 then
            penalty = penalty + num(cfg.PIPELINE_V2_SOFT_DEFENSE_AVAILABLE_RESPONSE_PENALTY, 6000)
        end
        if out.hasRangedThreat then
            penalty = penalty + num(cfg.PIPELINE_V2_SOFT_DEFENSE_SOURCE_RANGED_BONUS, 5000)
        end
        out.penalty = out.penalty + penalty
        out.reasons[#out.reasons + 1] = "soft_pressure_off_source_attack"
    end

    if out.rangedDuelNonReducing then
        out.penalty = out.penalty + num(cfg.PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_NONREDUCING_PENALTY, 2800)
        out.reasons[#out.reasons + 1] = "soft_pressure_ranged_duel_nonreducing"
    end

    local rangedResponse = rangedResponseScore.analyze(ai, ctx, {
        candidate = candidate,
        beforeState = ctx.currentState,
        afterState = current,
        beforeThreat = beforeThreat,
        delta = delta
    })
    if rangedResponse then
        out.rangedResponse = rangedResponse
        out.bonus = out.bonus + num(rangedResponse.bonus, 0)
        out.penalty = out.penalty + num(rangedResponse.penalty, 0)
        if rangedResponse.killNow then
            out.sourceKills = math.max(num(out.sourceKills, 0), 1)
        end
        for _, reason in ipairs(rangedResponse.reasons or {}) do
            out.reasons[#out.reasons + 1] = reason
        end
    end

    return out
end

local function buildAnalysis(ai, ctx, contracts, candidate, afterThreat)
    local beforeThreat = contracts and contracts.defenseThreat or nil
    local beforeProjected = projectedDamage(beforeThreat)
    local afterProjected = projectedDamage(afterThreat)
    local beforeCount = attackerCount(beforeThreat)
    local afterCount = attackerCount(afterThreat)
    local softLethal = isSoftLethal(contracts)
    local beforeLethal = immediateLethal(beforeThreat) or softLethal
    local afterLethal = immediateLethal(afterThreat)
    local reduced = afterProjected <= 0
        or afterProjected < beforeProjected
        or afterCount < beforeCount
    local cleared = afterProjected <= 0 or afterCount <= 0 or not immediateDanger(afterThreat)
    local worsened = afterProjected > beforeProjected
        or (afterProjected == beforeProjected and afterCount > beforeCount)
    local pressureResponse = looksLikePressureResponse(candidate)
    local cfg = ctx and ctx.cfg or {}
    local delta = {
        projectedDamageDelta = beforeProjected - afterProjected,
        attackerDelta = beforeCount - afterCount,
        reduced = reduced,
        cleared = cleared,
        worsened = worsened
    }
    local source = buildSourceAnalysis(ai, ctx, contracts, candidate, beforeThreat, delta)

    local penalty = 0
    local bonus = 0
    local reason = "soft_pressure_neutral"
    if reduced then
        bonus = num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_REDUCED_BONUS, 9000)
            + math.max(0, beforeProjected - afterProjected)
                * num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_REDUCTION_DAMAGE_WEIGHT, 4500)
            + math.max(0, beforeCount - afterCount)
                * num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_ATTACKER_WEIGHT, 2500)
        if cleared then
            bonus = bonus + num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_CLEAR_BONUS, 14000)
            reason = "soft_pressure_cleared"
        else
            reason = "soft_pressure_reduced"
        end
    else
        penalty = num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_NONREDUCING_PENALTY, 14000)
            + afterProjected * num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_DAMAGE_WEIGHT, 3500)
        reason = "soft_pressure_not_reduced"
        if pressureResponse then
            penalty = penalty + num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_FALSE_RESPONSE_PENALTY, 22000)
            reason = "soft_pressure_false_response"
        end
        if worsened then
            penalty = penalty + num(cfg.PIPELINE_V2_SOFT_DEFENSE_PRESSURE_WORSEN_PENALTY, 45000)
            reason = "soft_pressure_worsened"
        end
    end

    if softLethal then
        if afterLethal then
            penalty = penalty
                + num(cfg.PIPELINE_V2_SOFT_DEFENSE_LETHAL_UNRESOLVED_PENALTY, 120000)
                + afterProjected * num(cfg.PIPELINE_V2_SOFT_DEFENSE_LETHAL_DAMAGE_WEIGHT, 6000)
                + afterCount * num(cfg.PIPELINE_V2_SOFT_DEFENSE_LETHAL_ATTACKER_WEIGHT, 9000)
            reason = "soft_lethal_not_resolved"
        else
            bonus = bonus + num(cfg.PIPELINE_V2_SOFT_DEFENSE_LETHAL_CLEARED_BONUS, 80000)
            reason = "soft_lethal_cleared"
        end
    end

    if source then
        bonus = bonus + num(source.bonus, 0)
        penalty = penalty + num(source.penalty, 0)
        if not reduced and not softLethal then
            if source.offThreatFactionAttacks > 0 and not source.targetsThreat then
                reason = "soft_pressure_off_source_attack"
            elseif source.rangedResponse and source.rangedResponse.setupKill then
                reason = "soft_pressure_ranged_setup_kill"
            elseif source.rangedResponse and source.rangedResponse.killNow then
                reason = "soft_pressure_ranged_source_kill"
            elseif source.rangedResponse and source.rangedResponse.repositionSafe then
                reason = "soft_pressure_ranged_reposition_safe"
            elseif source.rangedResponse and source.rangedResponse.repositionAwkward then
                reason = "soft_pressure_ranged_reposition_awkward"
            elseif source.rangedResponse and source.rangedResponse.penalty > 0 then
                reason = "soft_pressure_ranged_duel_futile"
            elseif source.rangedDuelNonReducing then
                reason = "soft_pressure_ranged_duel_nonreducing"
            elseif source.targetsThreat and source.sourceDamage > 0 then
                reason = "soft_pressure_source_chipped"
            end
        end
    end
    local rawBonus = math.max(0, bonus)
    local rawPenalty = math.max(0, penalty)
    local scale = pressureScale(ctx)
    bonus = math.floor(rawBonus * scale)
    penalty = math.floor(rawPenalty * scale)

    return {
        beforeProjected = beforeProjected,
        afterProjected = afterProjected,
        beforeCount = beforeCount,
        afterCount = afterCount,
        softLethal = softLethal,
        beforeLethal = beforeLethal,
        afterLethal = afterLethal,
        projectedDamageDelta = beforeProjected - afterProjected,
        attackerDelta = beforeCount - afterCount,
        reduced = reduced,
        cleared = cleared,
        worsened = worsened,
        pressureResponse = pressureResponse,
        penalty = math.max(0, penalty),
        bonus = math.max(0, bonus),
        rawPenalty = rawPenalty,
        rawBonus = rawBonus,
        scale = scale,
        net = math.max(0, bonus) - math.max(0, penalty),
        reason = reason,
        source = source
    }
end

local function record(ctx, candidate, analysis)
    if not (candidate and analysis) then
        return
    end
    candidate.tacticalTags = candidate.tacticalTags or {}
    local tags = candidate.tacticalTags
    tags.softDefensePressure = true
    tags.softDefensePressureReason = analysis.reason
    tags.softDefensePressureBeforeDamage = analysis.beforeProjected
    tags.softDefensePressureAfterDamage = analysis.afterProjected
    tags.softDefensePressureBeforeAttackers = analysis.beforeCount
    tags.softDefensePressureAfterAttackers = analysis.afterCount
    tags.softDefensePressureReduced = analysis.reduced == true
    tags.softDefensePressureCleared = analysis.cleared == true
    tags.softDefensePressureWorsened = analysis.worsened == true
    tags.softDefenseLethal = analysis.softLethal == true
    tags.softDefenseLethalBefore = analysis.beforeLethal == true
    tags.softDefenseLethalAfter = analysis.afterLethal == true
    if analysis.softLethal == true then
        tags.preventsImmediateLoss = analysis.afterLethal ~= true
        tags.allowsImmediateLoss = analysis.afterLethal == true
    end
    tags.softDefensePressurePenalty = analysis.penalty
    tags.softDefensePressureBonus = analysis.bonus
    tags.softDefensePressureNet = analysis.net
    tags.softDefensePressureScale = analysis.scale
    if analysis.source then
        tags.softDefenseSourceScored = true
        tags.softDefenseSourceTargeted = analysis.source.targetsThreat == true
        tags.softDefenseSourceDamage = analysis.source.sourceDamage
        tags.softDefenseSourceKills = analysis.source.sourceKills
        tags.softDefenseSourceRanged = analysis.source.sourceRanged == true
        tags.softDefenseOffSourceFactionAttacks = analysis.source.offThreatFactionAttacks
        tags.softDefenseRangedDuelNonReducing = analysis.source.rangedDuelNonReducing == true
        tags.softDefenseSourceBonus = analysis.source.bonus
        tags.softDefenseSourcePenalty = analysis.source.penalty
        if analysis.source.rangedResponse then
            local ranged = analysis.source.rangedResponse
            tags.softDefenseRangedResponseScored = true
            tags.softDefenseRangedResponseKillNow = ranged.killNow == true
            tags.softDefenseRangedResponseSetupKill = ranged.setupKill == true
            tags.softDefenseRangedResponseFutile =
                ranged.attackedRangedSource == true and num(ranged.penalty, 0) > 0
            tags.softDefenseRangedRepositionSafe = ranged.repositionSafe == true
            tags.softDefenseRangedRepositionAwkward = ranged.repositionAwkward == true
            tags.softDefenseRangedRepositionStatic = ranged.repositionStatic == true
            tags.softDefenseRangedResponseBonus = ranged.bonus
            tags.softDefenseRangedResponsePenalty = ranged.penalty
        end
    end

    if ctx and ctx.stats then
        ctx.stats.softDefensePressureScored = num(ctx.stats.softDefensePressureScored, 0) + 1
        if analysis.reduced then
            ctx.stats.softDefensePressureReduced = num(ctx.stats.softDefensePressureReduced, 0) + 1
        else
            ctx.stats.softDefensePressureNotReduced = num(ctx.stats.softDefensePressureNotReduced, 0) + 1
        end
        if analysis.softLethal then
            ctx.stats.softDefenseLethalScored = num(ctx.stats.softDefenseLethalScored, 0) + 1
            if analysis.afterLethal then
                ctx.stats.softDefenseLethalUnresolved = num(ctx.stats.softDefenseLethalUnresolved, 0) + 1
            else
                ctx.stats.softDefenseLethalCleared = num(ctx.stats.softDefenseLethalCleared, 0) + 1
            end
        end
        if analysis.pressureResponse and not analysis.reduced then
            ctx.stats.softDefensePressureFalseResponses =
                num(ctx.stats.softDefensePressureFalseResponses, 0) + 1
        end
        if analysis.source then
            ctx.stats.softDefenseSourceScored = num(ctx.stats.softDefenseSourceScored, 0) + 1
            if analysis.source.targetsThreat then
                ctx.stats.softDefenseSourceTargeted = num(ctx.stats.softDefenseSourceTargeted, 0) + 1
            end
            if analysis.source.offThreatFactionAttacks > 0 and not analysis.source.targetsThreat then
                ctx.stats.softDefenseOffSourceAttacks = num(ctx.stats.softDefenseOffSourceAttacks, 0) + 1
            end
            if analysis.source.rangedDuelNonReducing then
                ctx.stats.softDefenseRangedDuelNonReducing =
                    num(ctx.stats.softDefenseRangedDuelNonReducing, 0) + 1
            end
            if analysis.source.rangedResponse then
                ctx.stats.softDefenseRangedResponseScored =
                    num(ctx.stats.softDefenseRangedResponseScored, 0) + 1
                if analysis.source.rangedResponse.setupKill then
                    ctx.stats.softDefenseRangedResponseSetupKill =
                        num(ctx.stats.softDefenseRangedResponseSetupKill, 0) + 1
                end
                if analysis.source.rangedResponse.killNow then
                    ctx.stats.softDefenseRangedResponseKillNow =
                        num(ctx.stats.softDefenseRangedResponseKillNow, 0) + 1
                end
                if analysis.source.rangedResponse.repositionSafe or analysis.source.rangedResponse.repositionAwkward then
                    ctx.stats.softDefenseRangedResponseReposition =
                        num(ctx.stats.softDefenseRangedResponseReposition, 0) + 1
                end
            end
        end
    end
end

function M.analyze(ai, afterOur, ctx, contracts, candidate)
    if not (enabled(ctx) and isSoftDefense(contracts) and afterOur) then
        return nil
    end
    local afterThreat = afterThreatFor(ai, afterOur, ctx)
    if not afterThreat then
        return nil
    end
    local analysis = buildAnalysis(ai, ctx, contracts, candidate, afterThreat)
    record(ctx, candidate, analysis)
    return analysis
end

function M.applyScore(ctx, candidate, score, analysis)
    if not (score and analysis) then
        return score
    end
    if score.breakdown and score.breakdown.softDefensePressureApplied == true then
        return score
    end

    local net = num(analysis.net, 0)
    if net ~= 0 then
        score.survival = num(score.survival, 0) + net
        if net > 0 then
            score.force = num(score.force, 0) + math.floor(net * 0.12)
        else
            score.risk = num(score.risk, 0) + math.floor(net * 0.15)
        end
    end

    score.breakdown = score.breakdown or {}
    score.breakdown.softDefensePressureApplied = true
    score.breakdown.softDefensePressure = {
        reason = analysis.reason,
        beforeDamage = analysis.beforeProjected,
        afterDamage = analysis.afterProjected,
        beforeAttackers = analysis.beforeCount,
        afterAttackers = analysis.afterCount,
        softLethal = analysis.softLethal == true,
        beforeLethal = analysis.beforeLethal == true,
        afterLethal = analysis.afterLethal == true,
        reduced = analysis.reduced == true,
        cleared = analysis.cleared == true,
        worsened = analysis.worsened == true,
        pressureResponse = analysis.pressureResponse == true,
        penalty = analysis.penalty,
        bonus = analysis.bonus,
        rawPenalty = analysis.rawPenalty,
        rawBonus = analysis.rawBonus,
        scale = analysis.scale,
        net = net
    }
    if analysis.source then
        score.breakdown.softDefensePressure.source = {
            targeted = analysis.source.targetsThreat == true,
            sourceDamage = analysis.source.sourceDamage,
            sourceKills = analysis.source.sourceKills,
            sourceRanged = analysis.source.sourceRanged == true,
            offThreatFactionAttacks = analysis.source.offThreatFactionAttacks,
            rangedDuelNonReducing = analysis.source.rangedDuelNonReducing == true,
            bonus = analysis.source.bonus,
            penalty = analysis.source.penalty,
            reasons = analysis.source.reasons
        }
        if analysis.source.rangedResponse then
            local ranged = analysis.source.rangedResponse
            score.breakdown.softDefensePressure.source.rangedResponse = {
                killNow = ranged.killNow == true,
                setupKill = ranged.setupKill == true,
                attackedRangedSource = ranged.attackedRangedSource == true,
                totalSourceDamage = ranged.totalSourceDamage,
                setupDamage = ranged.setupDamage,
                repositionSafe = ranged.repositionSafe == true,
                repositionAwkward = ranged.repositionAwkward == true,
                repositionStatic = ranged.repositionStatic == true,
                bonus = ranged.bonus,
                penalty = ranged.penalty,
                reasons = ranged.reasons
            }
        end
    end
    score.breakdown.reasons = score.breakdown.reasons or {}
    score.breakdown.reasons[#score.breakdown.reasons + 1] = analysis.reason

    if ctx and ctx.score and ctx.score.finalize then
        return ctx.score.finalize(score)
    end
    score.total = num(score.total, 0) + net
    return score
end

function M.apply(ai, afterOur, ctx, contracts, candidate, score)
    local analysis = M.analyze(ai, afterOur, ctx, contracts, candidate)
    return M.applyScore(ctx, candidate, score, analysis)
end

return M
