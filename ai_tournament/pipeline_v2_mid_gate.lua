local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function threatPayload(threatResult)
    return threatResult and (threatResult.threat or threatResult) or nil
end

local function projectedDamage(threatResult)
    local threat = threatPayload(threatResult)
    return num((threatResult and threatResult.projectedDamage) or (threat and threat.projectedDamage), 0)
end

local function immediateLethal(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateLethal == true)
        or (threat and threat.immediateLethal == true)
end

local function damagingAttackers(threatResult)
    local threat = threatPayload(threatResult)
    return #((threatResult and threatResult.damagingAttackers) or (threat and threat.damagingAttackers) or {})
end

local function immediateDanger(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.immediateDanger == true)
        or (threat and threat.immediateDanger == true)
        or projectedDamage(threatResult) > 0
        or damagingAttackers(threatResult) > 0
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

local function winsNow(ai, item, ctx)
    local candidate = item and item.candidate or nil
    if candidate and candidate.tacticalTags and candidate.tacticalTags.winsNow == true then
        return true
    end
    local trade = candidate and candidate.midTrade or item and item.midTrade or nil
    if trade and trade.class == "win_now" then
        return true
    end
    if item and item.afterOur and ctx and ctx.evaluator and ctx.evaluator.isCommandantDead then
        return ctx.evaluator.isCommandantDead(item.afterOur, ctx.enemyPlayer) == true
    end
    return false
end

local function opensOwnCommandantPressure(ai, beforeState, afterOur, ctx)
    if not (ai and beforeState and afterOur and ctx and ctx.aiPlayer and ctx.enemyPlayer) then
        return false
    end
    local before = threatFor(ai, beforeState, ctx, ctx.aiPlayer, ctx.enemyPlayer)
    local after = threatFor(ai, afterOur, ctx, ctx.aiPlayer, ctx.enemyPlayer)
    if not immediateDanger(after) then
        return false
    end
    local beforeDamage = projectedDamage(before)
    local afterDamage = projectedDamage(after)
    if immediateDanger(before) and afterDamage <= beforeDamage then
        return false
    end
    return true, {
        beforeDamage = beforeDamage,
        afterDamage = afterDamage,
        damageIncrease = math.max(0, afterDamage - beforeDamage),
        lethal = immediateLethal(after)
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
        candidate.tacticalTags.opensCommandantPressure = true
        candidate.tacticalTags.openedCommandantPressureDamage = num(analysis and analysis.afterDamage, 0)
        candidate.tacticalTags.opensCommandantPressureSoftGate = true
    end
    if ctx and ctx.stats then
        ctx.stats.pipelineV2MidCommandantPressureSoftened =
            num(ctx.stats.pipelineV2MidCommandantPressureSoftened, 0) + 1
        ctx.stats.pipelineV2MidCommandantPressureSoftenedDamage =
            math.max(
                num(ctx.stats.pipelineV2MidCommandantPressureSoftenedDamage, 0),
                num(analysis and analysis.afterDamage, 0)
            )
    end
end

function M.check(ai, state, ctx, contracts, item, options)
    local _options = options
    local candidate = item and item.candidate or nil
    local trade = candidate and candidate.midTrade or item and item.midTrade or nil
    local position = candidate and candidate.midPosition or item and item.midPosition or nil
    if not (candidate and item and item.afterOur) then
        return false, "mid_gate_missing_candidate_state"
    end
    if winsNow(ai, item, ctx) then
        return true, "mid_gate_win_now"
    end
    if contracts and contracts.defenseActive == true then
        return false, "mid_gate_hard_defense_contract"
    end
    if candidate.containsAttack == true then
        if not (trade and trade.accepted == true) then
            return false, trade and trade.reason or "mid_gate_trade_rejected"
        end
    elseif candidate.tacticalTags and candidate.tacticalTags.midPosition == true then
        if not (position and position.accepted == true) then
            return false, position and position.reason or "mid_gate_position_rejected"
        end
    else
        return false, "mid_gate_unknown_candidate_kind"
    end
    if ctx and ctx.evaluator and ctx.evaluator.isCommandantDead
        and ctx.evaluator.isCommandantDead(item.afterOur, ctx.aiPlayer) == true then
        return false, "mid_gate_own_commandant_dead"
    end
    local opensPressure, pressureAnalysis = opensOwnCommandantPressure(ai, state, item.afterOur, ctx)
    if opensPressure then
        if not commandantPressureSoftGate(ctx) then
            return false, "mid_gate_opens_own_commandant_pressure"
        end
        applyCommandantPressurePenalty(ctx, item, pressureAnalysis)
        recordSoftenedCommandantPressure(ctx, candidate, pressureAnalysis)
    end
    if position and position.accepted == true then
        return true, position.reason or "mid_gate_position_accepted"
    end
    return true, trade.reason or "mid_gate_accepted"
end

return M
