local contractGate = require("ai_tournament.pipeline_v2_contract_gate")
local earlyPositionMap = require("ai_tournament.early_position_map")
local earlyPositionCandidates = require("ai_tournament.early_position_candidates")
local earlySkirmishCandidates = require("ai_tournament.early_skirmish_candidates")
local pipelineV2FullTurn = require("ai_tournament.pipeline_v2_full_turn")
local actionExposureGuard = require("ai_tournament.action_exposure_guard")
local budgetScope = require("ai_tournament.pipeline_v2_budget_scope")
local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")

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

local function bumpReason(map, reason)
    local key = tostring(reason or "unknown")
    map[key] = num(map[key], 0) + 1
end

local function sortByScore(ctx, items, scoreField)
    table.sort(items, function(a, b)
        local aScore = a and a[scoreField] or nil
        local bScore = b and b[scoreField] or nil
        if ctx and ctx.score and ctx.score.isBetter then
            return ctx.score.isBetter(aScore, bScore)
        end
        return num(aScore and aScore.total, 0) > num(bScore and bScore.total, 0)
    end)
end

local function scoreTotal(score)
    if type(score) == "table" then
        return num(score.total, 0)
    end
    return num(score, 0)
end

local function firstN(items, limit)
    local result = {}
    for index, item in ipairs(items or {}) do
        if index > limit then
            break
        end
        result[#result + 1] = item
    end
    return result
end

local function copyArray(items)
    local result = {}
    for index, item in ipairs(items or {}) do
        result[index] = item
    end
    return result
end

local function exportPositionHints(ctx, deployFirstCandidates, movePositionCandidates)
    if not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MERGE_POSITIONAL_CANDIDATES == true) then
        return
    end

    local cap = clampLimit(ctx.cfg.PIPELINE_V2_POSITIONAL_HINT_CAP or 24, 1, 96)
    local hints = {}
    local seen = {}
    for _, list in ipairs({deployFirstCandidates or {}, movePositionCandidates or {}}) do
        for _, candidate in ipairs(list) do
            local signature = tostring(candidate and candidate.signature or "")
            if signature ~= "" and not seen[signature] then
                seen[signature] = true
                hints[#hints + 1] = candidate
                if #hints >= cap then
                    break
                end
            end
        end
        if #hints >= cap then
            break
        end
    end

    ctx.pipelineV2PositionHints = hints
    if ctx.stats then
        ctx.stats.pipelineV2PositionHints = #hints
    end
end

local function annotateCandidate(ai, state, ctx, candidate, callbacks)
    if callbacks and callbacks.annotateCandidate then
        candidate = callbacks.annotateCandidate(ai, state, ctx, candidate) or candidate
    end
    if ctx and ctx.tacticalGate and ctx.tacticalGate.annotateCandidate then
        candidate = ctx.tacticalGate.annotateCandidate(ai, state, candidate, ctx) or candidate
    end
    if callbacks and callbacks.annotateCandidate then
        candidate = callbacks.annotateCandidate(ai, state, ctx, candidate) or candidate
    end
    return candidate
end

local function isEarlyBuildPositionScope(ctx, contracts)
    if not (ctx and ctx.phase and ctx.phase.early == true) then
        return false, "not_early_phase"
    end
    if not (ctx.earlyPlan and ctx.earlyPlan.active == true) then
        return false, "early_plan_inactive"
    end
    if contracts and contracts.defenseActive == true then
        return false, "hard_defense_contract"
    end
    return true, nil
end

local function evaluateCandidate(ai, state, ctx, contracts, candidate, callbacks, rejectCounts)
    if not (candidate and candidate.actions and #candidate.actions > 0) then
        bumpReason(rejectCounts, "missing_actions")
        return nil
    end

    candidate = annotateCandidate(ai, state, ctx, candidate, callbacks or {})
    local afterOur = ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
    if not afterOur then
        bumpReason(rejectCounts, "simulation_failed")
        return nil
    end

    actionExposureGuard.analyze(ai, afterOur, ctx, candidate, {
        includeDeploy = true,
        phase = "early"
    })
    local fastScore = ctx.evaluator.scoreOwnTurnFast(ai, state, afterOur, candidate, ctx)
    fastScore = actionExposureGuard.applyScorePenalty(ctx, candidate, fastScore, {
        phase = "early"
    })
    fastScore = softPressureScore.apply(ai, afterOur, ctx, contracts, candidate, fastScore)
    local item = {
        candidate = candidate,
        afterOur = afterOur,
        fastScore = fastScore,
        source = "pipeline_v2"
    }

    local accepted, reason = contractGate.check(ai, state, ctx, contracts, item, callbacks)
    if not accepted then
        bumpReason(rejectCounts, reason)
        return nil
    end

    item.acceptReason = reason
    return item
end

local function rememberBestFastAccepted(stats, item)
    if not (stats and item and item.candidate) then
        return
    end

    stats.pipelineV2BestFastAcceptedAvailable = true
    stats.pipelineV2BestFastAcceptedSignature = item.candidate.signature
    stats.pipelineV2BestFastAcceptedReason = item.acceptReason
    stats.pipelineV2BestFastAcceptedScore = scoreTotal(item.fastScore)
end

local function isRecoverableFastAccepted(ctx, item)
    if not (ctx and item and item.candidate and item.candidate.actions and item.afterOur) then
        return false, "missing_item"
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES ~= false then
        local requiredActions = num(ctx.maxActions, 2)
        if #item.candidate.actions < requiredActions then
            return false, "short_candidate"
        end
    end
    return true, nil
end

local function recoverBestFastAccepted(ctx, stats, item, reason)
    if not (ctx and stats and item and item.candidate) then
        return nil
    end
    if not (ctx.cfg and ctx.cfg.PIPELINE_V2_RETURN_FAST_ACCEPTED_ON_FAIL_CLOSED == true) then
        return nil
    end
    if stats.timeout ~= true then
        stats.pipelineV2BestFastRecoveryRejected = "not_timeout"
        return nil
    end

    local ok, rejectReason = isRecoverableFastAccepted(ctx, item)
    if not ok then
        stats.pipelineV2BestFastRecoveryRejected = rejectReason
        return nil
    end

    item.reply = item.reply or {
        total = 0,
        riskPenalty = 0,
        summary = "pipeline_v2_best_fast_no_reply"
    }
    item.finalScore = item.finalScore or item.fastScore
    item.finalAcceptReason = item.finalAcceptReason or item.acceptReason

    stats.pipelineV2RecoveredFastAccepted = true
    stats.pipelineV2RecoveredFromReason = reason
    stats.pipelineV2SelectedSignature = item.candidate.signature
    stats.pipelineV2SelectedAcceptReason = item.finalAcceptReason or item.acceptReason

    return {
        attempted = true,
        item = item,
        reason = "pipeline_v2_best_fast_before_fail_closed",
        recoveredFrom = reason,
        fallbackSource = "pipeline_v2_best_fast"
    }
end

local function runGate(ai, state, ctx, contracts, callbacks, candidates, maxRanked, rejectCounts)
    local accepted = {}
    local gateEvaluated = 0
    for _, candidate in ipairs(candidates or {}) do
        if ctx.shouldStop and ctx.shouldStop() then
            ctx.stats.timeout = true
            break
        end
        gateEvaluated = gateEvaluated + 1
        local item = evaluateCandidate(ai, state, ctx, contracts, candidate, callbacks, rejectCounts)
        if item then
            accepted[#accepted + 1] = item
        end
        if #accepted >= maxRanked then
            break
        end
    end
    return accepted, gateEvaluated
end

local function shouldRetryFullTurnForPressure(ctx, rejectCounts)
    if ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_RETRY_ON_COMMANDANT_PRESSURE == false then
        return false
    end
    return num(rejectCounts and rejectCounts.opens_own_commandant_pressure, 0) > 0
end

local function scoreFinalist(ai, state, ctx, contracts, item, callbacks, rejectCounts)
    local reply = {
        total = 0,
        riskPenalty = 0,
        summary = "reply_disabled"
    }

    local useReply = not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_USE_REPLY == false)
    if useReply and ctx and ctx.responseModel and ctx.responseModel.evaluateWorstReply then
        local remaining = ctx.remainingMs and ctx.remainingMs() or 0
        local minReplyBudget = clampLimit(ctx.cfg.MIN_REPLY_BUDGET_MS or 75, 10, math.max(10, ctx.hardBudgetMs or 500))
        if remaining > minReplyBudget and not (ctx.hardStop and ctx.hardStop()) then
            ctx.beginStage("pipeline_v2_reply")
            local pushedDeadline = false
            local replyBudget = clampLimit(ctx.cfg.REPLY_EVAL_MAX_MS or 160, 20, math.max(20, remaining))
            if ctx.pushDeadline then
                ctx.pushDeadline(replyBudget)
                pushedDeadline = true
            end
            reply = ctx.responseModel.evaluateWorstReply(ai, item.afterOur, ctx, item.candidate)
            if pushedDeadline and ctx.popDeadline then
                ctx.popDeadline()
            end
            ctx.endStage("pipeline_v2_reply")
            ctx.stats.replyEvaluations = num(ctx.stats.replyEvaluations, 0) + 1
        else
            ctx.stats.replySkippedByBudget = num(ctx.stats.replySkippedByBudget, 0) + 1
            reply.summary = "reply_skipped_budget"
        end
    end

    local finalScore = ctx.evaluator.scoreAfterEnemyReply(
        ai,
        state,
        item.afterOur,
        reply,
        item.candidate,
        ctx,
        nil
    )
    finalScore = actionExposureGuard.applyScorePenalty(ctx, item.candidate, finalScore, {
        phase = "early"
    })
    finalScore = softPressureScore.apply(ai, item.afterOur, ctx, contracts, item.candidate, finalScore)
    item.reply = reply
    item.finalScore = finalScore

    local accepted, reason = contractGate.check(ai, state, ctx, contracts, item, callbacks)
    if not accepted then
        bumpReason(rejectCounts, reason)
        return nil
    end
    item.finalAcceptReason = reason
    return item
end

function M.run(ai, state, ctx, contracts, callbacks)
    if not (ai and state and ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_ENABLED == true) then
        return {
            attempted = false,
            reason = "pipeline_v2_disabled"
        }
    end

    local inScope, scopeReason = isEarlyBuildPositionScope(ctx, contracts)
    if not inScope then
        return {
            attempted = false,
            reason = scopeReason
        }
    end

    local stats = ctx.stats or {}
    ctx.pipelineV2Runtime = true
    stats.pipelineV2Enabled = true
    stats.pipelineV2RejectedReasons = {}

    if ctx.cfg.EARLY_POSITION_MAP_ENABLED ~= false then
        ctx.beginStage("early_position_map")
        ctx.earlyPositionMap = earlyPositionMap.build(ai, state, ctx, {
            limit = ctx.cfg.EARLY_POSITION_MAP_TOP_N or 8
        })
        ctx.endStage("early_position_map")
    end

    ctx.beginStage("pipeline_v2_deploy_first")
    local deployFirstCandidates = earlyPositionCandidates.generateDeployFirst(ai, state, ctx, ctx.earlyPositionMap, {
        maxCandidates = math.min(24, ctx.cfg.PIPELINE_V2_MAX_CANDIDATES or 48),
        deployActionCap = ctx.cfg.PIPELINE_V2_DEPLOY_FIRST_ACTION_CAP or 8,
        continuationCap = ctx.cfg.PIPELINE_V2_DEPLOY_FIRST_CONTINUATION_CAP or 4,
        earlySecondScanCap = ctx.cfg.PIPELINE_V2_DEPLOY_FIRST_EARLY_SECOND_SCAN_CAP or 8,
        earlySecondDeployCap = ctx.cfg.PIPELINE_V2_DEPLOY_FIRST_EARLY_SECOND_DEPLOY_CAP or 3
    })
    ctx.endStage("pipeline_v2_deploy_first")

    local movePositionExtraMs = clampLimit(ctx.cfg.PIPELINE_V2_MOVE_POSITION_EXTRA_MS or 0, 0, 5000)
    local movePositionBudget = nil
    if movePositionExtraMs > 0 then
        movePositionBudget = budgetScope.push(ctx, stats, {
            extraMs = movePositionExtraMs,
            extraKey = "pipelineV2MovePositionExtraMs",
            remainingKey = "pipelineV2RemainingBeforeMovePositionMs",
            startKey = "pipelineV2MovePositionStartElapsedMs",
            extendedKey = "pipelineV2MovePositionExtendedHardBudgetMs",
            localWindowKey = "pipelineV2MovePositionLocalWindowMs"
        })
    end
    ctx.beginStage("pipeline_v2_move_position")
    local movePositionCandidates = earlyPositionCandidates.generateMovePosition(ai, state, ctx, ctx.earlyPositionMap, {
        maxCandidates = math.min(24, ctx.cfg.PIPELINE_V2_MAX_CANDIDATES or 48),
        continuationCap = ctx.cfg.PIPELINE_V2_MOVE_CONTINUATION_CAP or 3
    })
    ctx.endStage("pipeline_v2_move_position")
    if movePositionBudget then
        movePositionBudget.pop()
    end

    local maxCandidates = clampLimit(ctx.cfg.PIPELINE_V2_MAX_CANDIDATES or 48, 1, 240)
    local maxFirstActions = clampLimit(ctx.cfg.PIPELINE_V2_MAX_FIRST_ACTIONS or 14, 1, 80)
    local maxSecondActions = clampLimit(ctx.cfg.PIPELINE_V2_MAX_SECOND_ACTIONS or 8, 1, 48)
    local maxRanked = clampLimit(ctx.cfg.PIPELINE_V2_MAX_RANKED or 18, 1, maxCandidates)
    local maxFinalists = clampLimit(ctx.cfg.PIPELINE_V2_MAX_FINALISTS or 6, 1, maxRanked)
    local gateExtraMs = clampLimit(ctx.cfg.PIPELINE_V2_GATE_EXTRA_MS or 0, 0, 5000)
    local finalistsExtraMs = clampLimit(ctx.cfg.PIPELINE_V2_FINALISTS_EXTRA_MS or 0, 0, 5000)
    local fullTurnExtraMs = clampLimit(ctx.cfg.PIPELINE_V2_FULL_TURN_EXTRA_MS or 0, 0, 5000)

    ctx.beginStage("pipeline_v2_early_skirmish")
    local skirmishCandidates, skirmishStats = earlySkirmishCandidates.generate(ai, state, ctx, {
        directCap = ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_DIRECT_ATTACK_CAP or 8,
        moveAttackScanCap = ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_MOVE_ATTACK_SCAN_CAP or 20,
        moveAttackCap = ctx.cfg.PIPELINE_V2_EARLY_SKIRMISH_MOVE_ATTACK_CAP or 8
    })
    ctx.endStage("pipeline_v2_early_skirmish")
    stats.pipelineV2EarlySkirmishCandidates = #(skirmishCandidates or {})
    stats.pipelineV2EarlySkirmishActive = #(skirmishCandidates or {}) > 0
    stats.pipelineV2EarlySkirmishSkippedReason = skirmishStats and skirmishStats.skippedReason or nil
    stats.pipelineV2EarlySkirmishLegalDirect = num(skirmishStats and skirmishStats.legalDirect, 0)
    stats.pipelineV2EarlySkirmishLegalMoves = num(skirmishStats and skirmishStats.legalMoves, 0)
    stats.pipelineV2EarlySkirmishMoveScanned = num(skirmishStats and skirmishStats.moveScanned, 0)
    stats.pipelineV2EarlySkirmishDirectGenerated = num(skirmishStats and skirmishStats.directGenerated, 0)
    stats.pipelineV2EarlySkirmishMoveAttackGenerated = num(skirmishStats and skirmishStats.moveAttackGenerated, 0)
    stats.pipelineV2EarlySkirmishSafetyRejected = num(skirmishStats and skirmishStats.safetyRejected, 0)
    stats.pipelineV2EarlySkirmishHealerAttackCandidates =
        num(skirmishStats and skirmishStats.healerAttackCandidates, 0)
    stats.pipelineV2EarlySkirmishHealerAttackRejected =
        num(skirmishStats and skirmishStats.healerAttackRejectedByDoctrine, 0)
    stats.pipelineV2EarlySkirmishHealerAttackFallbackUsed =
        skirmishStats and skirmishStats.healerAttackFallbackUsed == true or false
    stats.pipelineV2EarlySkirmishSafetyRejectedReasons =
        skirmishStats and skirmishStats.safetyRejectedReasons or nil
    stats.combatDirectGenerated =
        num(stats.combatDirectGenerated, 0) + num(skirmishStats and skirmishStats.directGenerated, 0)
    stats.combatGeneratedTotal = num(stats.combatGeneratedTotal, 0) + #(skirmishCandidates or {})

    ctx.beginStage("pipeline_v2_enumeration")
    local candidates = {}
    for _, candidate in ipairs(skirmishCandidates or {}) do
        candidates[#candidates + 1] = candidate
    end
    for _, candidate in ipairs(deployFirstCandidates or {}) do
        candidates[#candidates + 1] = candidate
    end
    for _, candidate in ipairs(movePositionCandidates or {}) do
        candidates[#candidates + 1] = candidate
    end
    ctx.endStage("pipeline_v2_enumeration")

    local baseCandidates = copyArray(candidates)

    if ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_ENABLED ~= false then
        stats.pipelineV2GateExtraMs = gateExtraMs
        local fullTurnBudget = nil
        if fullTurnExtraMs > 0 then
            fullTurnBudget = budgetScope.push(ctx, stats, {
                extraMs = fullTurnExtraMs,
                extraKey = "pipelineV2FullTurnExtraMs",
                remainingKey = "pipelineV2RemainingBeforeFullTurnMs",
                startKey = "pipelineV2FullTurnStartElapsedMs",
                extendedKey = "pipelineV2FullTurnExtendedHardBudgetMs",
                localWindowKey = "pipelineV2FullTurnLocalWindowMs"
            })
        end
        ctx.beginStage("pipeline_v2_full_turn")
        candidates = pipelineV2FullTurn.complete(ai, state, ctx, ctx.earlyPositionMap, candidates, {
            requiredActions = ctx.maxActions or 2,
            scanCap = ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_SCAN_CAP or 6,
            maxCompletions = ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_MAX_COMPLETIONS or 2,
            maxCompletionAttempts = ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_ATTEMPT_CAP or 8,
            minCompletedAlternatives = ctx.cfg.PIPELINE_V2_FULL_TURN_MIN_COMPLETED_ALTERNATIVES or 2,
            minOutput = ctx.cfg.PIPELINE_V2_FULL_TURN_MIN_OUTPUT or 5
        }) or {}
        ctx.endStage("pipeline_v2_full_turn")
        if fullTurnBudget then
            fullTurnBudget.pop()
        end
    else
        stats.pipelineV2FullTurnEnabled = false
    end

    exportPositionHints(ctx, candidates, nil)

    if ctx.cfg.PIPELINE_V2_SELECT_ENABLED ~= true then
        stats.pipelineV2Candidates = #candidates
        return {
            attempted = false,
            reason = "pipeline_v2_diagnostic_only"
        }
    end

    stats.pipelineV2Candidates = #candidates
    local rejectCounts = stats.pipelineV2RejectedReasons
    local gateBudget = nil
    if gateExtraMs > 0 then
        gateBudget = budgetScope.push(ctx, stats, {
            extraMs = gateExtraMs,
            extraKey = "pipelineV2GateExtraMs",
            remainingKey = "pipelineV2RemainingBeforeGateMs",
            startKey = "pipelineV2GateStartElapsedMs",
            extendedKey = "pipelineV2GateExtendedHardBudgetMs",
            localWindowKey = "pipelineV2GateLocalWindowMs"
        })
    end

    ctx.beginStage("pipeline_v2_gate")
    local accepted, gateEvaluated = runGate(ai, state, ctx, contracts, callbacks, candidates, maxRanked, rejectCounts)
    ctx.endStage("pipeline_v2_gate")

    if #accepted == 0 and shouldRetryFullTurnForPressure(ctx, rejectCounts) and #baseCandidates > 0 then
        stats.pipelineV2FullTurnRetryTriggered = true
        local retryBudget = nil
        if fullTurnExtraMs > 0 then
            retryBudget = budgetScope.push(ctx, stats, {
                extraMs = fullTurnExtraMs,
                extraKey = "pipelineV2FullTurnRetryExtraMs",
                remainingKey = "pipelineV2RemainingBeforeFullTurnRetryMs",
                startKey = "pipelineV2FullTurnRetryStartElapsedMs",
                extendedKey = "pipelineV2FullTurnRetryExtendedHardBudgetMs",
                localWindowKey = "pipelineV2FullTurnRetryLocalWindowMs"
            })
        end
        ctx.beginStage("pipeline_v2_full_turn_retry")
        local retryCandidates = pipelineV2FullTurn.complete(ai, state, ctx, ctx.earlyPositionMap, baseCandidates, {
            requiredActions = ctx.maxActions or 2,
            scanCap = ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_SCAN_CAP or 6,
            maxCompletions = ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_MAX_COMPLETIONS or 2,
            maxCompletionAttempts = ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_ATTEMPT_CAP or 8,
            minCompletedAlternatives =
                ctx.cfg.PIPELINE_V2_FULL_TURN_RETRY_MIN_COMPLETED_ALTERNATIVES or 2,
            minOutput = ctx.cfg.PIPELINE_V2_FULL_TURN_MIN_OUTPUT or 5
        }) or {}
        ctx.endStage("pipeline_v2_full_turn_retry")
        if retryBudget then
            retryBudget.pop()
        end

        local retryRejectCounts = {}
        ctx.beginStage("pipeline_v2_gate_retry")
        local retryAccepted, retryGateEvaluated =
            runGate(ai, state, ctx, contracts, callbacks, retryCandidates, maxRanked, retryRejectCounts)
        ctx.endStage("pipeline_v2_gate_retry")
        stats.pipelineV2FullTurnRetryCandidates = #retryCandidates
        stats.pipelineV2FullTurnRetryGateEvaluated = retryGateEvaluated
        stats.pipelineV2FullTurnRetryAccepted = #retryAccepted
        stats.pipelineV2FullTurnRetryRejectedReasons = retryRejectCounts
        if #retryAccepted > 0 then
            accepted = retryAccepted
            candidates = retryCandidates
            gateEvaluated = gateEvaluated + retryGateEvaluated
            rejectCounts = retryRejectCounts
            stats.pipelineV2RejectedReasons = retryRejectCounts
            stats.pipelineV2RecoveredByFullTurnRetry = true
            stats.pipelineV2Candidates = #candidates
        end
    end

    if gateBudget then
        gateBudget.pop()
    end

    stats.pipelineV2GateEvaluated = gateEvaluated
    stats.pipelineV2Accepted = #accepted
    if #accepted == 0 then
        local reason = "pipeline_v2_no_contract_valid_candidates"
        if stats.timeout == true and gateEvaluated == 0 and #candidates > 0 then
            reason = "pipeline_v2_gate_skipped_by_budget"
            stats.pipelineV2GateSkippedByBudget = true
        end
        return {
            attempted = true,
            item = nil,
            reason = reason,
            rejectedReasons = rejectCounts
        }
    end

    sortByScore(ctx, accepted, "fastScore")
    local bestFastAccepted = accepted[1]
    rememberBestFastAccepted(stats, bestFastAccepted)

    local finalists = firstN(accepted, math.min(maxFinalists, #accepted))
    stats.pipelineV2Finalists = #finalists

    local best = nil
    local finalistsEvaluated = 0
    local finalistsBudget = nil
    if finalistsExtraMs > 0 then
        finalistsBudget = budgetScope.push(ctx, stats, {
            extraMs = finalistsExtraMs,
            extraKey = "pipelineV2FinalistsExtraMs",
            remainingKey = "pipelineV2RemainingBeforeFinalistsMs",
            startKey = "pipelineV2FinalistsStartElapsedMs",
            extendedKey = "pipelineV2FinalistsExtendedHardBudgetMs",
            localWindowKey = "pipelineV2FinalistsLocalWindowMs"
        })
    end
    ctx.beginStage("pipeline_v2_finalists")
    for _, item in ipairs(finalists) do
        if ctx.hardStop and ctx.hardStop() then
            stats.timeout = true
            break
        end
        finalistsEvaluated = finalistsEvaluated + 1
        local finalist = scoreFinalist(ai, state, ctx, contracts, item, callbacks, rejectCounts)
        if finalist and ctx.score.isBetter(finalist.finalScore, best and best.finalScore or nil) then
            best = finalist
        end
    end
    ctx.endStage("pipeline_v2_finalists")
    if finalistsBudget then
        finalistsBudget.pop()
    end
    stats.pipelineV2FinalistsEvaluated = finalistsEvaluated

    if not best then
        local reason = "pipeline_v2_no_finalist_survived_reply_gate"
        if stats.timeout == true and finalistsEvaluated == 0 and #finalists > 0 then
            stats.pipelineV2FinalistsSkippedByBudget = true
        end
        local recovered = recoverBestFastAccepted(ctx, stats, bestFastAccepted, reason)
        if recovered then
            recovered.rejectedReasons = rejectCounts
            return recovered
        end
        return {
            attempted = true,
            item = nil,
            reason = reason,
            rejectedReasons = rejectCounts
        }
    end

    stats.pipelineV2SelectedSignature = best.candidate and best.candidate.signature or nil
    stats.pipelineV2SelectedAcceptReason = best.finalAcceptReason or best.acceptReason
    return {
        attempted = true,
        item = best,
        reason = "pipeline_v2_selected"
    }
end

return M
