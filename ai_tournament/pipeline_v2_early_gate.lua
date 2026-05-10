local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")

local M = {}

local V2_POSITION_SOURCES = {
    early_position_deploy_first = true,
    early_position_move = true,
    early_position_move_release = true
}

local V2_POSITION_REASON_TOKENS = {
    "occupy_free_target",
    "cover_target",
    "cover_reposition_preserves",
    "free_expand",
    "expand_next",
    "position_map_target",
    "support_cover",
    "staging_frontier",
    "move_cover_owned_uncovered",
    "move_uncovered_occupy_better",
    "move_legal_floor",
    "release_cover_then",
    "release_occupant_then",
    "then_position",
    "complete_deploy_free_target",
    "complete_deploy_next_expansion",
    "complete_deploy_frontier_hold_support",
    "complete_deploy_support_cover",
    "complete_deploy_staging_frontier",
    "complete_move_free_target",
    "complete_move_next_expansion",
    "complete_move_cover_pressure",
    "complete_move_support_cover",
    "complete_move_staging_frontier",
    "complete_forced_",
    "retreat_to_strategic_cell",
    "retreat_expand_next"
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function bump(map, reason)
    local key = tostring(reason or "unknown")
    map[key] = num(map[key], 0) + 1
end

local function actionCount(candidate)
    return #(candidate and candidate.actions or {})
end

local function hasAttack(candidate)
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

local function technicalSecondAllowed(ctx)
    return ctx
        and ctx.cfg
        and ctx.cfg.PIPELINE_V2_EARLY_GATE_ALLOW_TECHNICAL_SECOND == true
end

local function reasonLooksV2Position(reason, ctx)
    reason = tostring(reason or "")
    if reason == "" then
        return false
    end
    if reason:find("complete_technical_", 1, true) and not technicalSecondAllowed(ctx) then
        return false
    end
    for _, token in ipairs(V2_POSITION_REASON_TOKENS) do
        if reason:find(token, 1, true) then
            return true
        end
    end
    return false
end

local function record(ctx, accepted, reason, candidate)
    if not (ctx and ctx.stats) then
        return
    end

    local stats = ctx.stats
    stats.pipelineV2EarlyGateEnabled = true
    stats.pipelineV2EarlyGateChecks = num(stats.pipelineV2EarlyGateChecks, 0) + 1
    if accepted then
        stats.pipelineV2EarlyGateAccepted = num(stats.pipelineV2EarlyGateAccepted, 0) + 1
        stats.pipelineV2EarlyGateAcceptedReasons = stats.pipelineV2EarlyGateAcceptedReasons or {}
        bump(stats.pipelineV2EarlyGateAcceptedReasons, reason)
    else
        stats.pipelineV2EarlyGateRejected = num(stats.pipelineV2EarlyGateRejected, 0) + 1
        stats.pipelineV2EarlyGateRejectedReasons = stats.pipelineV2EarlyGateRejectedReasons or {}
        bump(stats.pipelineV2EarlyGateRejectedReasons, reason)
        stats.pipelineV2EarlyGateFirstRejected = stats.pipelineV2EarlyGateFirstRejected
            or tostring(candidate and candidate.signature or "unknown")
        stats.pipelineV2EarlyGateFirstRejectedReason = stats.pipelineV2EarlyGateFirstRejectedReason
            or tostring(reason or "unknown")
    end
end

local function accept(ctx, reason, candidate)
    record(ctx, true, reason, candidate)
    return false, nil
end

local function reject(ctx, reason, candidate)
    record(ctx, false, reason, candidate)
    return true, reason
end

local function acceptLowValueTarget(ctx, candidate, target)
    if candidate then
        candidate.tacticalTags = candidate.tacticalTags or {}
        candidate.tacticalTags.earlyPositionLowValueTarget = true
        candidate.tacticalTags.earlyPositionLowValueTargetValue = earlyCellPolicy.cellValue(target)
        candidate.tacticalTags.earlyPositionLowValueTargetMin = earlyCellPolicy.minStrategicValue(ctx)
    end
    if ctx and ctx.stats then
        ctx.stats.pipelineV2EarlyGateLowValueSoftened =
            num(ctx.stats.pipelineV2EarlyGateLowValueSoftened, 0) + 1
    end
    return accept(ctx, "v2_early_gate_low_value_target_softened", candidate)
end

function M.rejects(ai, state, ctx, contracts, item)
    if ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_GATE_ENABLED == false then
        if ctx.stats then
            ctx.stats.pipelineV2EarlyGateEnabled = false
        end
        return false, nil
    end

    local candidate = item and item.candidate or nil
    if not candidate then
        return reject(ctx, "v2_early_gate_missing_candidate", candidate)
    end

    if not (ctx and ctx.phase and ctx.phase.early == true and ctx.earlyPlan and ctx.earlyPlan.active == true) then
        return accept(ctx, "v2_early_gate_out_of_scope", candidate)
    end

    if contracts and contracts.defenseActive == true then
        return reject(ctx, "v2_early_gate_defense_contract_not_position", candidate)
    end

    local requiredActions = math.max(1, num(ctx and ctx.maxActions, 2))
    local requireFullTurn = not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES == false)
    if requireFullTurn and candidate.terminal ~= true and actionCount(candidate) < requiredActions then
        return reject(ctx, "v2_early_gate_incomplete_turn", candidate)
    end

    local tags = candidate.tacticalTags or {}
    if tags.earlySkirmish == true and hasAttack(candidate) then
        return accept(ctx, "v2_early_gate_skirmish", candidate)
    end

    if hasAttack(candidate) then
        return reject(ctx, "v2_early_gate_attack_not_build_position", candidate)
    end

    local source = tostring(candidate.source or "")
    if V2_POSITION_SOURCES[source] ~= true then
        return reject(ctx, "v2_early_gate_unknown_source", candidate)
    end

    local reason = tostring(tags.earlyPositionReason or "")
    if not reasonLooksV2Position(reason, ctx) then
        return reject(ctx, "v2_early_gate_unknown_position_reason", candidate)
    end

    local target = tags.earlyPositionTarget
    if target and target.value ~= nil and earlyCellPolicy.cellValue(target) < earlyCellPolicy.minStrategicValue(ctx) then
        return acceptLowValueTarget(ctx, candidate, target)
    end

    return accept(ctx, "v2_early_gate_accepted", candidate)
end

return M
