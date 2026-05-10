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

local function threatProjectedDamage(threatResult)
    local threat = threatPayload(threatResult)
    return num((threatResult and threatResult.projectedDamage) or (threat and threat.projectedDamage), 0)
end

local function threatImmediateLethal(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateLethal == true)
        or (threat and threat.immediateLethal == true)
end

local function threatAttackerCount(threatResult)
    local threat = threatPayload(threatResult)
    return #((threatResult and threatResult.damagingAttackers) or (threat and threat.damagingAttackers) or {})
end

local function threatHasImmediateDanger(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateDanger == true)
        or (threat and threat.immediateDanger == true)
        or threatProjectedDamage(threatResult) > 0
        or threatAttackerCount(threatResult) > 0
end

local function threatFor(ai, state, ctx, playerToProtect, attackerPlayer)
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

local function itemWinsNow(ai, item, ctx)
    local score = item and (item.finalScore or item.fastScore) or nil
    local candidate = item and item.candidate or nil
    if candidate and candidate.tacticalTags and candidate.tacticalTags.winsNow == true then
        return true
    end
    local winTier = ctx and ctx.score and ctx.score.TIER and ctx.score.TIER.WIN_NOW or 100
    if score and num(score.tier, 0) >= winTier then
        return true
    end
    if item and item.afterOur and ctx and ctx.evaluator and ctx.evaluator.isCommandantDead then
        return ctx.evaluator.isCommandantDead(item.afterOur, ctx.enemyPlayer) == true
    end
    return false
end

local function conversionAllowsSetup(item)
    local score = item and (item.finalScore or item.fastScore) or nil
    local conversion = score and score.breakdown and score.breakdown.conversion or nil
    return conversion and conversion.setupChosen == true
end

local function activeCombatContract(contracts)
    return contracts
        and (
            contracts.combatActive == true
            or contracts.breakDrawClock == true
            or contracts.forceCommandantPressure == true
            or contracts.eliminateLowHpUnit == true
        )
end

local function earlyBuildPositionContext(ctx)
    return ctx
        and ctx.phase
        and ctx.phase.early == true
        and ctx.earlyPlan
        and ctx.earlyPlan.active == true
end

local function earlySkirmishActive(ctx)
    return ctx
        and ctx.phase
        and ctx.phase.early == true
        and ctx.stats
        and ctx.stats.pipelineV2EarlySkirmishActive == true
end

local function candidateHasAttack(candidate)
    if candidate and (candidate.hasFactionAttack == true or candidate.containsAttack == true) then
        return true
    end
    for _, action in ipairs(candidate and candidate.actions or {}) do
        if action and action.type == "attack" then
            return true
        end
    end
    return false
end

function M.opensOwnCommandantPressure(ai, beforeState, afterOur, candidate, ctx)
    if not (ai and beforeState and afterOur and candidate and ctx and ctx.aiPlayer and ctx.enemyPlayer) then
        return false
    end

    local beforeThreat = threatFor(ai, beforeState, ctx, ctx.aiPlayer, ctx.enemyPlayer)
    local afterThreat = threatFor(ai, afterOur, ctx, ctx.aiPlayer, ctx.enemyPlayer)
    if not threatHasImmediateDanger(afterThreat) then
        return false
    end
    local beforeDamage = threatProjectedDamage(beforeThreat)
    local afterDamage = threatProjectedDamage(afterThreat)
    if threatHasImmediateDanger(beforeThreat)
        and afterDamage <= beforeDamage then
        return false
    end

    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.opensCommandantPressure = true
    candidate.tacticalTags.openedCommandantPressureDamage = afterDamage
    return true, {
        beforeDamage = beforeDamage,
        afterDamage = afterDamage,
        damageIncrease = math.max(0, afterDamage - beforeDamage),
        lethal = threatImmediateLethal(afterThreat)
    }
end

local function commandantPressureSoftGate(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_COMMANDANT_PRESSURE_SOFT_GATE == false)
end

local function commandantPressurePenalty(ctx, analysis)
    local cfg = ctx and ctx.cfg or {}
    local afterDamage = num(analysis and analysis.afterDamage, 0)
    local damageIncrease = num(analysis and analysis.damageIncrease, 0)
    local penalty = num(cfg.OPEN_COMMANDANT_PRESSURE_PENALTY, 28000)
        + math.max(afterDamage, damageIncrease) * num(cfg.OPEN_COMMANDANT_PRESSURE_DAMAGE_WEIGHT, 4200)
    if analysis and analysis.lethal == true then
        penalty = penalty + num(cfg.OPEN_COMMANDANT_PRESSURE_LETHAL_BONUS, 70000)
    end
    return math.max(0, penalty)
end

local function applyCommandantPressurePenalty(ctx, item, analysis)
    local score = item and (item.finalScore or item.fastScore) or nil
    if type(score) ~= "table" then
        return
    end
    score.breakdown = score.breakdown or {}
    if score.breakdown.openedCommandantPressure then
        return
    end

    local penalty = commandantPressurePenalty(ctx, analysis)
    score.survival = num(score.survival, 0) - penalty
    score.breakdown.reasons = score.breakdown.reasons or {}
    score.breakdown.reasons[#score.breakdown.reasons + 1] = "opens_commandant_pressure_soft_gate"
    score.breakdown.openedCommandantPressure = {
        beforeDamage = num(analysis and analysis.beforeDamage, 0),
        afterDamage = num(analysis and analysis.afterDamage, 0),
        damageIncrease = num(analysis and analysis.damageIncrease, 0),
        lethal = analysis and analysis.lethal == true,
        penalty = penalty,
        softGate = true
    }
    if ctx and ctx.score and ctx.score.finalize then
        ctx.score.finalize(score)
    else
        score.total = num(score.total, 0) - penalty
    end
end

local function recordSoftenedCommandantPressure(ctx, candidate, analysis)
    if candidate then
        candidate.tacticalTags = candidate.tacticalTags or {}
        candidate.tacticalTags.opensCommandantPressureSoftGate = true
    end
    if ctx and ctx.stats then
        ctx.stats.pipelineV2CommandantPressureSoftened =
            num(ctx.stats.pipelineV2CommandantPressureSoftened, 0) + 1
        ctx.stats.pipelineV2CommandantPressureSoftenedDamage =
            math.max(
                num(ctx.stats.pipelineV2CommandantPressureSoftenedDamage, 0),
                num(analysis and analysis.afterDamage, 0)
            )
    end
end

function M.check(ai, state, ctx, contracts, item, callbacks)
    local candidate = item and item.candidate or nil
    if not (candidate and item and item.afterOur) then
        return false, "missing_candidate_state"
    end

    if itemWinsNow(ai, item, ctx) then
        return true, "wins_now"
    end

    if ctx and ctx.evaluator and ctx.evaluator.isCommandantDead
        and ctx.evaluator.isCommandantDead(item.afterOur, ctx.aiPlayer) == true then
        return false, "own_commandant_dead"
    end

    callbacks = callbacks or {}
    if contracts and contracts.defenseActive == true then
        local addressesDefense = callbacks.addressesActiveDefense
            and callbacks.addressesActiveDefense(ai, item, contracts, ctx)
            or false
        if not addressesDefense then
            return false, "does_not_satisfy_defense_contract"
        end
    else
        local opensPressure, pressureAnalysis =
            M.opensOwnCommandantPressure(ai, state, item.afterOur, candidate, ctx)
        if opensPressure then
            if not commandantPressureSoftGate(ctx) then
                return false, "opens_own_commandant_pressure"
            end
            applyCommandantPressurePenalty(ctx, item, pressureAnalysis)
            recordSoftenedCommandantPressure(ctx, candidate, pressureAnalysis)
        end
    end

    if earlySkirmishActive(ctx)
        and not candidateHasAttack(candidate)
        and not (candidate.tacticalTags and candidate.tacticalTags.earlySkirmish == true) then
        return false, "does_not_answer_early_skirmish"
    end

    local strictGate = not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_STRICT_CONTRACT_GATE == false)
    if strictGate
        and not earlyBuildPositionContext(ctx)
        and activeCombatContract(contracts)
        and num(ctx and ctx.stats and ctx.stats.legalAttackActions, 0) > 0
        and candidate.hasFactionAttack ~= true
        and not conversionAllowsSetup(item) then
        return false, "does_not_satisfy_combat_contract"
    end

    local hardReason = callbacks.hardLockReason
        and callbacks.hardLockReason(ai, state, ctx, contracts, item)
        or nil
    if hardReason then
        return true, hardReason
    end

    if callbacks.earlyGateRejects then
        local rejected, reason = callbacks.earlyGateRejects(ai, state, ctx, contracts, item)
        if rejected then
            return false, reason or "early_gate_rejected"
        end
    end

    return true, "accepted"
end

return M
