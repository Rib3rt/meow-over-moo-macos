local midPipeline = require("ai_tournament.pipeline_v2_mid")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function scoreTotal(score)
    if type(score) == "table" then
        return num(score.total, 0)
    end
    return num(score, 0)
end

local function setSkipped(stats, reason)
    if stats then
        stats.pipelineV2EndSkipped = true
        stats.pipelineV2EndSkippedReason = reason
        stats.pipelineV2EndFailedReason = reason
    end
    return {
        attempted = false,
        reason = reason
    }
end

local function endReason(reason)
    local text = tostring(reason or "pipeline_v2_end_no_selection")
    if text == "no_mid_candidates" then
        return "no_endgame_candidates"
    end
    local mapped = text:gsub("pipeline_v2_mid", "pipeline_v2_end"):gsub("_mid_", "_endgame_")
    return mapped
end

local CFG_OVERRIDES = {
    {"PIPELINE_V2_MID_GATE_EXTRA_MS", "PIPELINE_V2_ENDGAME_GATE_EXTRA_MS"},
    {"PIPELINE_V2_MID_ATTACK_EXTRA_MS", "PIPELINE_V2_ENDGAME_ATTACK_EXTRA_MS"},
    {"PIPELINE_V2_MID_SECOND_EXTRA_MS", "PIPELINE_V2_ENDGAME_SECOND_EXTRA_MS"},
    {"PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_PENALTY", "PIPELINE_V2_ENDGAME_SECOND_PREFIX_RECOVERY_PENALTY"},
    {"PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_ATTACK_PENALTY", "PIPELINE_V2_ENDGAME_SECOND_PREFIX_RECOVERY_ATTACK_PENALTY"},
    {"PIPELINE_V2_MID_POSITION_EXTRA_MS", "PIPELINE_V2_ENDGAME_POSITION_EXTRA_MS"},
    {"PIPELINE_V2_MID_POSITION_SECOND_EXTRA_MS", "PIPELINE_V2_ENDGAME_POSITION_SECOND_EXTRA_MS"}
}

local function applyCfgOverrides(cfg)
    local saved = {}
    if not cfg then
        return saved
    end
    for _, pair in ipairs(CFG_OVERRIDES) do
        local midKey = pair[1]
        local endKey = pair[2]
        saved[midKey] = cfg[midKey]
        if cfg[endKey] ~= nil then
            cfg[midKey] = cfg[endKey]
        end
    end
    return saved
end

local function restoreCfgOverrides(cfg, saved)
    if not (cfg and saved) then
        return
    end
    for key, value in pairs(saved) do
        cfg[key] = value
    end
end

local function retagSource(candidate)
    if not candidate then
        return nil, nil
    end
    local original = candidate.source
    local mapped = original
    if original == "mid_v2_attack" then
        mapped = "end_v2_attack"
    elseif original == "mid_v2_move_attack" then
        mapped = "end_v2_move_attack"
    elseif original == "mid_v2_position" then
        mapped = "end_v2_position"
    elseif original == "mid_v2_legal_floor" then
        mapped = "end_v2_legal_floor"
    elseif original == "mid_v2_mandatory_floor" then
        mapped = "end_v2_mandatory_floor"
    end
    candidate.endgameOriginalSource = original
    candidate.source = mapped
    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.endV2 = true
    return original, mapped
end

local function copyMidStats(stats)
    if not stats then
        return
    end
    stats.pipelineV2EndCandidates = stats.pipelineV2MidCandidates
    stats.pipelineV2EndAttackCandidates = stats.pipelineV2MidAttackCandidates
    stats.pipelineV2EndPositionCandidates = stats.pipelineV2MidPositionCandidates
    stats.pipelineV2EndGateEvaluated = stats.pipelineV2MidGateEvaluated
    stats.pipelineV2EndPrepared = stats.pipelineV2MidPrepared
    stats.pipelineV2EndAccepted = stats.pipelineV2MidAccepted
    stats.pipelineV2EndFinalists = stats.pipelineV2MidFinalists
    stats.pipelineV2EndRejectedReasons = stats.pipelineV2MidRejectedReasons
    stats.pipelineV2EndRecoveredBestCandidate = stats.pipelineV2MidRecoveredBestCandidate
    stats.pipelineV2EndRecoveredFromReason = stats.pipelineV2MidRecoveredFromReason
    stats.pipelineV2EndGateExtraMs = stats.pipelineV2MidGateExtraMs
    stats.pipelineV2EndAttackExtraMs = stats.pipelineV2MidAttackExtraMs
    stats.pipelineV2EndPositionExtraMs = stats.pipelineV2MidPositionExtraMs
    stats.pipelineV2EndPositionSecondExtraMs = stats.pipelineV2MidPositionSecondExtraMs
    stats.pipelineV2EndSelectedDrawZeroDamageReset = stats.pipelineV2MidSelectedDrawZeroDamageReset
    stats.pipelineV2EndSelectedAllowsZeroDamageDrawReset = stats.pipelineV2MidSelectedAllowsZeroDamageDrawReset
end

function M.run(ai, state, ctx, contracts, callbacks)
    if not (ai and state and ctx and ctx.cfg) then
        return {
            attempted = false,
            reason = "missing_context"
        }
    end

    local stats = ctx.stats or {}
    stats.pipelineV2EndEnabled = ctx.cfg.PIPELINE_V2_ENDGAME_ENABLED == true

    if stats.pipelineV2EndEnabled ~= true then
        return setSkipped(stats, "disabled")
    end

    if not (ctx.phase and ctx.phase.endgame == true) then
        return setSkipped(stats, "not_endgame_phase")
    end

    if contracts and contracts.defenseActive == true then
        return setSkipped(stats, "hard_defense_contract")
    end

    stats.pipelineV2EndAttempted = true
    stats.pipelineV2EndSkipped = false
    stats.pipelineV2EndSkippedReason = nil
    stats.pipelineV2EndFailClosed = false
    stats.pipelineV2EndSupplyP1 = ctx.phase.supply and ctx.phase.supply[1] or nil
    stats.pipelineV2EndSupplyP2 = ctx.phase.supply and ctx.phase.supply[2] or nil
    stats.pipelineV2EndReason = ctx.phase.reason

    local previousEndRuntime = ctx.pipelineV2EndRuntime
    local savedCfg = applyCfgOverrides(ctx.cfg)
    ctx.pipelineV2EndRuntime = true

    local ok, result = pcall(function()
        return midPipeline.run(ai, state, ctx, contracts, callbacks)
    end)

    ctx.pipelineV2EndRuntime = previousEndRuntime
    restoreCfgOverrides(ctx.cfg, savedCfg)

    if not ok then
        error(result, 0)
    end

    copyMidStats(stats)

    if result and result.item then
        local candidate = result.item.candidate
        local originalSource, mappedSource = retagSource(candidate)
        stats.pipelineV2EndSelectedSignature = candidate and candidate.signature or nil
        stats.pipelineV2EndSelectedSource = mappedSource
        stats.pipelineV2EndSelectedOriginalSource = originalSource
        stats.pipelineV2EndSelectedAcceptReason = result.item.finalAcceptReason or result.item.acceptReason
        stats.pipelineV2EndSelectedTradeReason = candidate
            and candidate.midTrade
            and candidate.midTrade.reason
            or nil
        stats.pipelineV2EndSelectedDrawZeroDamageReset = candidate
            and candidate.midTrade
            and candidate.midTrade.drawZeroDamageReset == true
            or false
        stats.pipelineV2EndSelectedAllowsZeroDamageDrawReset = candidate
            and candidate.allowsZeroDamageDrawReset == true
            or false
        stats.pipelineV2EndSelectedScore = scoreTotal(result.item.finalScore)
        stats.pipelineV2EndFellThroughToTournament = false

        return {
            attempted = true,
            item = result.item,
            reason = "pipeline_v2_end_selected",
            originalReason = result.reason
        }
    end

    if result and result.attempted == true then
        local reason = endReason(result.reason)
        stats.pipelineV2EndFailedReason = reason
        stats.pipelineV2EndFailClosed = result.failClosed == true
        stats.pipelineV2EndFellThroughToTournament = false
        return {
            attempted = true,
            reason = reason,
            rejectedReasons = result.rejectedReasons,
            failClosed = result.failClosed
        }
    end

    return setSkipped(stats, result and result.reason or "endgame_pipeline_skipped")
end

return M
