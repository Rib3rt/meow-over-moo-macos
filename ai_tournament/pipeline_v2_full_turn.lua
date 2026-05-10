local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
local earlyMoveRisk = require("ai_tournament.early_move_risk")
local earlyPositionForcedSecond = require("ai_tournament.early_position_forced_second")
local earlyPositionSecondAction = require("ai_tournament.early_position_second_action")
local earlyPositionSequence = require("ai_tournament.early_position_sequence")
local earlyPositionStaging = require("ai_tournament.early_position_staging")
local earlyPositionSupport = require("ai_tournament.early_position_support")
local movePatternPenalty = require("ai_tournament.move_pattern_penalty")
local deployBudget = require("ai_tournament.pipeline_v2_deploy_budget")
local repairHeuristics = require("ai_tournament.repair_heuristics")

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

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function copyArray(values)
    local out = {}
    for index, value in ipairs(values or {}) do
        out[index] = value
    end
    return out
end

local function copyMap(values)
    local out = {}
    for key, value in pairs(values or {}) do
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

local function appendBucket(buckets, bucket)
    bucket = tostring(bucket or "")
    if bucket == "" then
        return
    end
    for _, existing in ipairs(buckets or {}) do
        if existing == bucket then
            return
        end
    end
    buckets[#buckets + 1] = bucket
end

local function actionSignature(ctx, actions)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.sequenceSignature then
        return ctx.turnEnumerator.sequenceSignature(actions or {})
    end
    local parts = {}
    for _, action in ipairs(actions or {}) do
        parts[#parts + 1] = tostring(action and action.type or "?")
    end
    return table.concat(parts, "|")
end

local function containsAction(actions, actionType)
    for _, action in ipairs(actions or {}) do
        if action and action.type == actionType then
            return true
        end
    end
    return false
end

local function fullTurnMoveRiskCarryScale(ctx)
    return math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_MOVE_RISK_CARRY_SCALE, 1.0))
end

local function exactSanitizeEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_EXACT_SANITIZE_ENABLED == false)
end

local function sanitizeRejectReason(summary, fallback)
    for reason, count in pairs((summary and summary.reasonCounts) or {}) do
        if num(count, 0) > 0 then
            return tostring(reason)
        end
    end
    return fallback or "sanitize_rewrite"
end

local function completionSequenceAccepted(ai, state, ctx, actions, stats, stage)
    if not (exactSanitizeEnabled(ctx) and ai and ai.sanitizeActionSequenceForState and actions and #actions > 0) then
        return true, nil, nil
    end

    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local sanitized, summary = ai:sanitizeActionSequenceForState(state, actions, {
        aiPlayer = ctx and ctx.aiPlayer or nil,
        maxActions = ctx and ctx.maxActions or 2,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true,
        rejectZeroDamageFactionAttacks = true
    })
    local originalSignature = actionSignature(ctx, actions)
    local sanitizedSignature = sanitized and actionSignature(ctx, sanitized) or ""
    local accepted = sanitized
        and #sanitized == #actions
        and num(summary and summary.replacements, 0) == 0
        and sanitizedSignature == originalSignature

    if not accepted and stats then
        local reason = sanitizeRejectReason(summary, stage or "completion_sanitize_rewrite")
        stats.exactSanitizeRejected = num(stats.exactSanitizeRejected, 0) + 1
        stats.exactSanitizeRejectedReasons[reason] = num(stats.exactSanitizeRejectedReasons[reason], 0) + 1
    end

    return accepted, sanitizeRejectReason(summary, stage), summary
end

local function makeSequenceValidator(ai, state, ctx, firstAction, stats, stage)
    return function(secondAction, reason)
        local ok, rejectReason, summary = completionSequenceAccepted(
            ai,
            state,
            ctx,
            {firstAction, secondAction},
            stats,
            reason or stage
        )
        return ok, rejectReason, summary
    end
end

local function firstActionSignature(ctx, candidate)
    local action = candidate and candidate.actions and candidate.actions[1] or nil
    if not action then
        return nil
    end
    return actionSignature(ctx, {action})
end

local function shouldStop(ctx)
    return (ctx and ctx.hardStop and ctx.hardStop())
        or (ctx and ctx.shouldStop and ctx.shouldStop())
end

local function mapCellsByKey(positionMap)
    local byKey = {}
    for _, list in ipairs({
        positionMap and positionMap.cells or false,
        positionMap and positionMap.freeTargets,
        positionMap and positionMap.nextExpansion,
        positionMap and positionMap.ownedUncoveredAll or false,
        positionMap and positionMap.ownedCoveredAll or false,
        positionMap and positionMap.ownedUncovered,
        positionMap and positionMap.ownedCovered,
        positionMap and positionMap.freeTop,
        positionMap and positionMap.top
    }) do
        for _, cell in ipairs(list or {}) do
            byKey[cell.key or cellKey(cell)] = cell
        end
    end
    return byKey
end

local function targetCellForAction(positionMap, action)
    if not (positionMap and action and action.target) then
        return nil
    end
    return mapCellsByKey(positionMap)[cellKey(action.target)]
end

local function collectDeployEntries(ai, state, ctx)
    return deployBudget.collectEntries(ai, state, ctx, {
        statPrefix = "pipelineV2FullTurnDeploy"
    })
end

local function collectMoveEntries(ai, state, ctx)
    if not (ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions) then
        return {}
    end
    local entries = ctx.turnEnumerator.collectTournamentActions(ai, state, ctx.aiPlayer, ctx, {
        includeMove = true,
        includeAttack = false,
        includeRepair = false,
        includeDeploy = false
    }) or {}
    local moves = {}
    for _, entry in ipairs(entries) do
        local action = entry and entry.action or nil
        if action and action.type == "move" then
            moves[#moves + 1] = entry
        end
    end
    return moves
end

local function mergeMoveRiskStats(stats, source)
    if not (stats and source) then
        return
    end
    stats.moveRiskPenalized = num(stats.moveRiskPenalized, 0) + num(source.moveRiskPenalized, 0)
    stats.moveRiskLethal = num(stats.moveRiskLethal, 0) + num(source.moveRiskLethal, 0)
    stats.moveRiskSuicidal = num(stats.moveRiskSuicidal, 0) + num(source.moveRiskSuicidal, 0)
    stats.moveRiskPenaltyMax = math.max(
        num(stats.moveRiskPenaltyMax, 0),
        num(source.moveRiskPenaltyMax, 0)
    )
end

local function moveActionWithEntryUnit(entry)
    local action = entry and entry.action or nil
    if not (action and action.type == "move" and entry and entry.unit and action.unit) then
        return action
    end

    local hydrated = {}
    for key, value in pairs(action) do
        hydrated[key] = value
    end
    local unit = {}
    for key, value in pairs(entry.unit) do
        unit[key] = value
    end
    unit.row = action.unit.row
    unit.col = action.unit.col
    hydrated.unit = unit
    return hydrated
end

local function deployReasonForCell(ai, state, ctx, positionMap, cell, action)
    if cell
        and cell.earlyFrontierRole == "support_cover"
        and earlyCellPolicy.isGoodStrategicCell(cell, ctx, {ignorePrimaryTarget = true}) then
        local useful = earlyPositionSupport.isUsefulSupportAction(ai, state, ctx, positionMap, cell, action)
        if useful then
            return "complete_deploy_support_cover",
                (earlyCellPolicy.cellValue(cell) * 0.12) + (num(cell.earlyCoverValueBonus, 0) * 0.45)
        end
    end
    if earlyPositionStaging.isStagingCell(cell, ctx) then
        return "complete_deploy_staging_frontier", earlyPositionStaging.score(cell, 0.06, 0.04)
    end
    if cell
        and cell.earlyFrontierRole == "frontier_hold"
        and (cell.status == "owned_uncovered" or cell.status == "owned_covered") then
        return "complete_deploy_frontier_hold_support",
            math.max(0, earlyCellPolicy.cellValue(cell)) * 0.08 + num(cell.earlyCoverValueBonus, 0) * 0.35
    end
    if not (cell and earlyCellPolicy.isGoodStrategicCell(cell, ctx)) then
        return nil, 0
    end
    if cell.status == "free_target" then
        return "complete_deploy_free_target", earlyCellPolicy.cellValue(cell)
    end
    if cell.status == "next_expansion" then
        return "complete_deploy_next_expansion", earlyCellPolicy.cellValue(cell) * 0.92
    end
    return "complete_deploy_map_target", earlyCellPolicy.cellValue(cell) * 0.35
end

local function isGoodMoveCompletionCell(cell, ctx)
    if cell and cell.status == "owned_uncovered" then
        return earlyCellPolicy.isHoldableOccupiedStrategicCell(cell, ctx)
    end
    return earlyCellPolicy.isGoodStrategicCell(cell, ctx)
end

local function moveReasonForCell(ai, state, ctx, positionMap, cell, action)
    if cell
        and cell.earlyFrontierRole == "support_cover"
        and earlyCellPolicy.isGoodStrategicCell(cell, ctx, {ignorePrimaryTarget = true}) then
        local useful = earlyPositionSupport.isUsefulSupportAction(ai, state, ctx, positionMap, cell, action)
        if useful then
            return "complete_move_support_cover",
                (earlyCellPolicy.cellValue(cell) * 0.1) + (num(cell.earlyCoverValueBonus, 0) * 0.35)
        end
    end
    if earlyPositionStaging.isStagingCell(cell, ctx) then
        return "complete_move_staging_frontier", earlyPositionStaging.score(cell, 0.055, 0.035)
    end
    if not (cell and isGoodMoveCompletionCell(cell, ctx)) then
        return nil, 0
    end
    if cell.status == "free_target" then
        return "complete_move_free_target", earlyCellPolicy.cellValue(cell) * 0.75
    end
    if cell.status == "next_expansion" then
        return "complete_move_next_expansion", earlyCellPolicy.cellValue(cell) * 0.78
    end
    if cell.status == "owned_uncovered" then
        return "complete_move_cover_pressure", earlyCellPolicy.cellValue(cell) * 0.25
    end
    return nil, 0
end

local function selectDeploySecond(ai, state, afterFirstState, ctx, positionMap, firstAction, scanCap, stats)
    local entries = collectDeployEntries(ai, afterFirstState, ctx)
    local agenda = earlyPositionSequence.build(positionMap, ctx)
    local validator = makeSequenceValidator(ai, state, ctx, firstAction, stats, "complete_deploy_second")
    local best = nil
    local scanned = 0
    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        local deploy = entry and entry.action or nil
        if deploy and deploy.type == "supply_deploy" then
            scanned = scanned + 1
            local targetCell = targetCellForAction(positionMap, deploy)
            local reason, score = deployReasonForCell(ai, afterFirstState, ctx, positionMap, targetCell, deploy)
            if reason then
                local ok = validator(deploy, reason)
                if ok then
                    local item = {
                        action = deploy,
                        reason = reason,
                        score = score
                            + earlyPositionSequence.bonusForTarget(agenda, targetCell, reason) * 0.2
                            + num(entry and entry.cheapScore, 0) * 0.04,
                        targetCell = targetCell
                    }
                    if not best or num(item.score, 0) > num(best.score, 0) then
                        best = item
                    end
                end
            end
        end
    end
    return best, scanned
end

local function selectMoveSecond(ai, state, afterFirstState, ctx, positionMap, firstAction, scanCap, stats)
    local entries = collectMoveEntries(ai, afterFirstState, ctx)
    local agenda = earlyPositionSequence.build(positionMap, ctx)
    local validator = makeSequenceValidator(ai, state, ctx, firstAction, stats, "complete_move_second")
    local best = nil
    local scanned = 0
    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        local move = moveActionWithEntryUnit(entry)
        if move and move.type == "move" then
            scanned = scanned + 1
            local targetCell = targetCellForAction(positionMap, move)
            local reason, score = moveReasonForCell(ai, afterFirstState, ctx, positionMap, targetCell, move)
            if reason then
                local ok = validator(move, reason)
                if ok then
                    local afterMove = ctx and ctx.cache and ctx.cache.simulate
                        and ctx.cache.simulate(ai, afterFirstState, {move}, ctx.aiPlayer, ctx)
                        or nil
                    local risk = earlyMoveRisk.analyze(ai, afterFirstState, afterMove, ctx, move)
                    local score = earlyMoveRisk.applyToScore(score
                        + earlyPositionSequence.bonusForTarget(agenda, targetCell, reason) * 0.18
                        + num(entry and entry.cheapScore, 0) * 0.05,
                        risk,
                        stats)
                    score = movePatternPenalty.adjustScore(ai, afterFirstState, ctx, move, score, stats)
                    local item = {
                        action = move,
                        reason = reason,
                        score = score,
                        targetCell = targetCell,
                        moveRisk = risk
                    }
                    if not best or num(item.score, 0) > num(best.score, 0) then
                        best = item
                    end
                end
            end
        end
    end
    return best, scanned
end

local function selectSecondAction(ai, state, afterFirstState, ctx, positionMap, firstAction, options, stats)
    local scanCap = clampLimit(options.scanCap or 10, 1, 64)
    if firstAction and firstAction.type == "supply_deploy" then
        local second, secondStats = earlyPositionSecondAction.select(
            ai,
            state,
            afterFirstState,
            ctx,
            positionMap,
            firstAction,
                {
                    scanCap = scanCap,
                    sequenceValidator = makeSequenceValidator(
                        ai,
                        state,
                        ctx,
                        firstAction,
                        stats,
                        "early_second"
                    )
                }
            )
        mergeMoveRiskStats(stats, secondStats)
        stats.secondScanned = stats.secondScanned + num(secondStats and secondStats.scanned, 0)
        for key, value in pairs((secondStats and secondStats.reasonCounts) or {}) do
            stats.reasonCounts[key] = num(stats.reasonCounts[key], 0) + num(value, 0)
        end
        for key, value in pairs((secondStats and secondStats.skippedReasons) or {}) do
            stats.droppedReasons[key] = num(stats.droppedReasons[key], 0) + num(value, 0)
        end
        if second and second.action then
            return second
        end
        return selectMoveSecond(ai, state, afterFirstState, ctx, positionMap, firstAction, scanCap, stats)
    end

    if firstAction and firstAction.type == "move" then
        local deploy, deployScanned = selectDeploySecond(
            ai,
            state,
            afterFirstState,
            ctx,
            positionMap,
            firstAction,
            scanCap,
            stats
        )
        stats.secondScanned = stats.secondScanned + deployScanned
        if deploy then
            stats.reasonCounts[deploy.reason] = num(stats.reasonCounts[deploy.reason], 0) + 1
            return deploy
        end
        local move, moveScanned = selectMoveSecond(ai, state, afterFirstState, ctx, positionMap, firstAction, scanCap, stats)
        stats.secondScanned = stats.secondScanned + moveScanned
        if move then
            stats.reasonCounts[move.reason] = num(stats.reasonCounts[move.reason], 0) + 1
        end
        return move
    end

    return nil
end

local function forcedSecondEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_FORCED_SECOND_ENABLED == false)
end

local function forcedDeploySecondEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_FORCED_DEPLOY_SECOND_ENABLED == false)
end

local function selectForcedSecondAction(ai, state, afterFirstState, ctx, positionMap, firstAction, options, stats)
    if not forcedSecondEnabled(ctx) then
        return nil
    end

    local second, secondStats = earlyPositionForcedSecond.select(
        ai,
        state,
        afterFirstState,
        ctx,
            positionMap,
            firstAction,
            {
                scanCap = options.scanCap,
                sequenceValidator = makeSequenceValidator(
                    ai,
                    state,
                    ctx,
                    firstAction,
                    stats,
                    "forced_second"
                )
            }
        )
    mergeMoveRiskStats(stats, secondStats)
    stats.secondScanned = stats.secondScanned + num(secondStats and secondStats.scanned, 0)
    stats.forcedSecondScanned = num(stats.forcedSecondScanned, 0) + num(secondStats and secondStats.scanned, 0)
    stats.forcedSecondAccepted = num(stats.forcedSecondAccepted, 0) + num(secondStats and secondStats.accepted, 0)
    for key, value in pairs((secondStats and secondStats.reasonCounts) or {}) do
        stats.reasonCounts[key] = num(stats.reasonCounts[key], 0) + num(value, 0)
    end
    for key, value in pairs((secondStats and secondStats.skippedReasons) or {}) do
        stats.droppedReasons[key] = num(stats.droppedReasons[key], 0) + num(value, 0)
    end
    return second
end

local function selectForcedDeploySecondAction(ai, state, afterFirstState, ctx, positionMap, firstAction, options, stats)
    if not (forcedDeploySecondEnabled(ctx) and afterFirstState and firstAction) then
        return nil
    end
    if firstAction.type == "supply_deploy" then
        return nil
    end

    local scanCap = clampLimit(
        options.forcedDeploySecondScanCap
            or (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_FORCED_DEPLOY_SECOND_SCAN_CAP)
            or options.scanCap
            or 6,
        1,
        64
    )
    local entries = collectDeployEntries(ai, afterFirstState, ctx)
    local agenda = earlyPositionSequence.build(positionMap, ctx)
    local validator = makeSequenceValidator(ai, state, ctx, firstAction, stats, "forced_deploy_second")
    local best = nil
    local scanned = 0
    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        local deploy = entry and entry.action or nil
        if deploy and deploy.type == "supply_deploy" then
            scanned = scanned + 1
            local targetCell = targetCellForAction(positionMap, deploy)
            local reason, score = deployReasonForCell(ai, afterFirstState, ctx, positionMap, targetCell, deploy)
            if not reason then
                reason = "complete_forced_deploy_reserve"
                score = num(entry and entry.cheapScore, 0) * 0.03 - 45
                targetCell = nil
            else
                reason = "complete_forced_" .. tostring(reason:gsub("^complete_", ""))
                score = num(score, 0) * 0.72
                    + earlyPositionSequence.bonusForTarget(agenda, targetCell, reason) * 0.08
                    + num(entry and entry.cheapScore, 0) * 0.03
            end
            local item = {
                action = deploy,
                reason = reason,
                score = score,
                targetCell = targetCell
            }
            local ok = validator(deploy, reason)
            if ok then
                stats.forcedDeploySecondAccepted = num(stats.forcedDeploySecondAccepted, 0) + 1
                stats.reasonCounts[item.reason] = num(stats.reasonCounts[item.reason], 0) + 1
                if not best or num(item.score, 0) > num(best.score, 0) then
                    best = item
                end
            end
        end
    end
    stats.secondScanned = stats.secondScanned + scanned
    stats.forcedDeploySecondScanned = num(stats.forcedDeploySecondScanned, 0) + scanned
    return best
end

local function technicalSecondEnabled(ctx)
    return ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_TECHNICAL_SECOND_ENABLED == true
end

local function collectTechnicalSecondEntries(ai, state, ctx, firstAction, scanCap)
    local entries = {}
    if firstAction and firstAction.type ~= "supply_deploy" then
        for _, entry in ipairs(collectDeployEntries(ai, state, ctx)) do
            if #entries >= scanCap then
                return entries
            end
            entries[#entries + 1] = entry
        end
    end
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        local nonCombat = ctx.turnEnumerator.collectTournamentActions(ai, state, ctx.aiPlayer, ctx, {
            includeMove = true,
            includeAttack = false,
            includeRepair = true,
            includeDeploy = false
        }) or {}
        for _, entry in ipairs(nonCombat) do
            if #entries >= scanCap then
                break
            end
            local action = entry and entry.action or nil
            if action and action.type ~= "attack" and action.type ~= "supply_deploy" then
                entries[#entries + 1] = entry
            end
        end
    end
    return entries
end

local function actionDistance(action)
    if not (action and action.unit and action.target) then
        return 0
    end
    return math.abs(num(action.unit.row, 0) - num(action.target.row, 0))
        + math.abs(num(action.unit.col, 0) - num(action.target.col, 0))
end

local function classifyTechnicalSecond(ai, beforeSecondState, ctx, positionMap, entry)
    local rawAction = entry and entry.action or nil
    local action = rawAction and rawAction.type == "move" and moveActionWithEntryUnit(entry) or rawAction
    if not (action and action.type) then
        return nil
    end

    local targetCell = targetCellForAction(positionMap, action)
    local targetValue = targetCell and earlyCellPolicy.cellValue(targetCell) or 0
    local cheap = num(entry and entry.cheapScore, 0)
    if action.type == "supply_deploy" then
        return {
            action = action,
            reason = "complete_technical_deploy_step",
            score = cheap * 0.05 + targetValue * 0.04,
            targetCell = targetCell
        }
    end
    if action.type == "move" then
        return {
            action = action,
            reason = "complete_technical_move_step",
            score = cheap * 0.03 + targetValue * 0.03 - actionDistance(action) * 4,
            targetCell = targetCell
        }
    end
    if action.type == "repair" then
        local fullHpPenalty = repairHeuristics.isFullHpRepair(ai, beforeSecondState, action)
            and repairHeuristics.fullHpRepairSecondActionPenalty(ctx)
            or 0
        return {
            action = action,
            reason = "complete_technical_repair_step",
            score = cheap * 0.04 + targetValue * 0.02 - fullHpPenalty,
            targetCell = targetCell
        }
    end
    return {
        action = action,
        reason = "complete_technical_" .. tostring(action.type) .. "_step",
        score = cheap * 0.02,
        targetCell = targetCell
    }
end

local function selectTechnicalSecondAction(ai, state, afterFirstState, ctx, positionMap, firstAction, options, stats)
    if not (technicalSecondEnabled(ctx) and afterFirstState and firstAction) then
        return nil
    end

    local scanCap = clampLimit(
        options.technicalSecondScanCap
            or (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_TECHNICAL_SECOND_SCAN_CAP)
            or 12,
        1,
        64
    )
    local entries = collectTechnicalSecondEntries(ai, afterFirstState, ctx, firstAction, scanCap)
    local validator = makeSequenceValidator(ai, state, ctx, firstAction, stats, "technical_second")
    local best = nil
    local scanned = 0
    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        scanned = scanned + 1
            local item = classifyTechnicalSecond(ai, afterFirstState, ctx, positionMap, entry)
        if item and item.action then
            local ok = validator(item.action, item.reason)
            if ok then
                stats.technicalSecondAccepted = num(stats.technicalSecondAccepted, 0) + 1
                stats.reasonCounts[item.reason] = num(stats.reasonCounts[item.reason], 0) + 1
                if not best or num(item.score, 0) > num(best.score, 0) then
                    best = item
                end
            end
        end
    end
    stats.secondScanned = stats.secondScanned + scanned
    stats.technicalSecondScanned = num(stats.technicalSecondScanned, 0) + scanned
    return best
end

local function completedCandidate(ctx, candidate, actions, second)
    local out = {}
    for key, value in pairs(candidate or {}) do
        if key ~= "actions" and key ~= "signature" and key ~= "buckets" and key ~= "tacticalTags" then
            out[key] = value
        end
    end

    local oldTags = candidate and candidate.tacticalTags or {}
    local oldReason = oldTags.earlyPositionReason or "early_position"
    local secondReason = second and second.reason or "complete_turn"
    local secondTarget = second and second.targetCell or nil
    local secondRole = tostring(
        secondTarget and (secondTarget.earlyFrontierRole or secondTarget.frontierRole) or ""
    )
    local secondIsSupport = secondRole == "support_cover" or secondRole == "frontier_hold"
    local targetCell = secondIsSupport and oldTags.earlyPositionTarget or secondTarget or oldTags.earlyPositionTarget

    out.actions = movePatternPenalty.tagPositionMoves(copyArray(actions))
    out.signature = actionSignature(ctx, actions)
    out.source = candidate and candidate.source or "pipeline_v2_full_turn"
    out.buckets = copyArray(candidate and candidate.buckets or {})
    appendBucket(out.buckets, "pipeline_v2_full_turn")
    out.tacticalTags = copyMap(oldTags)
    out.tacticalTags.earlyPositionReason = tostring(oldReason) .. "_then_" .. tostring(secondReason)
    if targetCell then
        out.tacticalTags.earlyPositionTarget = {
            row = targetCell.row,
            col = targetCell.col,
            status = targetCell.status,
            value = targetCell.value,
            positionValue = targetCell.earlyPositionValue or targetCell.positionValue,
            frontierRole = targetCell.earlyFrontierRole or targetCell.frontierRole,
            supportForKey = targetCell.earlySupportForKey or targetCell.supportForKey,
            coverValueBonus = targetCell.earlyCoverValueBonus or targetCell.coverValueBonus
        }
    end
    if secondIsSupport and secondTarget then
        out.tacticalTags.earlyPositionSupportTarget = {
            row = secondTarget.row,
            col = secondTarget.col,
            status = secondTarget.status,
            value = secondTarget.value,
            positionValue = secondTarget.earlyPositionValue or secondTarget.positionValue,
            frontierRole = secondTarget.earlyFrontierRole or secondTarget.frontierRole,
            supportForKey = secondTarget.earlySupportForKey or secondTarget.supportForKey,
            coverValueBonus = secondTarget.earlyCoverValueBonus or secondTarget.coverValueBonus
        }
    end
    local secondRisk = second and second.moveRisk or nil
    local riskPenalty = num(secondRisk and secondRisk.penalty, 0)
    local riskCarryPenalty = riskPenalty * fullTurnMoveRiskCarryScale(ctx)
    out.cheapScore = num(candidate and candidate.cheapScore, 0)
        + num(second and second.score, 0) * 0.12
        - riskCarryPenalty
    if riskPenalty > 0 then
        out.tacticalTags.fullTurnMoveRiskPenalty = riskPenalty
        out.tacticalTags.fullTurnMoveRiskCarryPenalty = riskCarryPenalty
        out.tacticalTags.fullTurnMoveRiskReason = secondRisk and secondRisk.reason or nil
        out.tacticalTags.fullTurnMoveRiskLethal = secondRisk and secondRisk.lethal == true or false
        out.tacticalTags.fullTurnMoveRiskSuicidal = secondRisk and secondRisk.suicidal == true or false
    end
    out.containsDeploy = containsAction(actions, "supply_deploy")
    out.containsAttack = containsAction(actions, "attack")
    out.completeTurn = true
    out.terminal = candidate and candidate.terminal == true or false
    out.v2FullTurnCompleted = true
    return out
end

local function addDropped(stats, reason)
    stats.dropped = stats.dropped + 1
    stats.droppedReasons[reason or "dropped"] = num(stats.droppedReasons[reason or "dropped"], 0) + 1
end

function M.complete(ai, state, ctx, positionMap, candidates, opts)
    local options = opts or {}
    local stats = {
        input = #(candidates or {}),
        kept = 0,
        completed = 0,
        dropped = 0,
        incompleteInput = 0,
        singleActionOutput = 0,
        secondScanned = 0,
        forcedSecondScanned = 0,
        forcedSecondAccepted = 0,
        forcedDeploySecondScanned = 0,
        forcedDeploySecondAccepted = 0,
        technicalSecondScanned = 0,
        technicalSecondAccepted = 0,
        exactSanitizeRejected = 0,
        exactSanitizeRejectedReasons = {},
        moveRiskPenalized = 0,
        moveRiskPenaltyMax = 0,
        moveRiskLethal = 0,
        moveRiskSuicidal = 0,
        riskyCompleted = 0,
        riskyCompletionPenaltyMax = 0,
        completionAttempts = 0,
        reasonCounts = {},
        droppedReasons = {}
    }
    local requiredActions = math.max(1, num(options.requiredActions, num(ctx and ctx.maxActions, 2)))
    local requireFullTurn = not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_REQUIRE_FULL_TURN_CANDIDATES == false)
    local maxCompletions = clampLimit(
        options.maxCompletions
            or (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_MAX_COMPLETIONS)
            or 2,
        0,
        64
    )
    local minOutput = clampLimit(
        options.minOutput
            or (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_MIN_OUTPUT)
            or 5,
        1,
        128
    )
    local maxCompletionAttempts = clampLimit(
        options.maxCompletionAttempts
            or (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_COMPLETION_ATTEMPT_CAP)
            or math.max(maxCompletions * 4, maxCompletions),
        maxCompletions,
        128
    )
    local minCompletedAlternatives = clampLimit(
        options.minCompletedAlternatives
            or (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_MIN_COMPLETED_ALTERNATIVES)
            or 0,
        0,
        maxCompletions
    )
    local riskAlternativeCompletions = clampLimit(
        options.riskAlternativeCompletions
            or (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_FULL_TURN_RISK_ALTERNATIVE_COMPLETIONS)
            or 5,
        0,
        64
    )
    local output = {}
    local seen = {}
    local fullFirstSeen = {}
    local incomplete = {}

    local function needsRiskAlternatives()
        return stats.riskyCompleted > 0 and stats.completed < riskAlternativeCompletions
    end

    for _, candidate in ipairs(candidates or {}) do
        local actions = candidate and candidate.actions or {}
        if candidate and candidate.terminal == true then
            output[#output + 1] = candidate
            seen[tostring(candidate.signature or actionSignature(ctx, actions))] = true
            local firstSignature = firstActionSignature(ctx, candidate)
            if firstSignature then
                fullFirstSeen[firstSignature] = true
            end
            stats.kept = stats.kept + 1
        elseif #actions >= requiredActions then
            if completionSequenceAccepted(ai, state, ctx, actions, stats, "existing_full_turn") then
                candidate.completeTurn = true
                output[#output + 1] = candidate
                seen[tostring(candidate.signature or actionSignature(ctx, actions))] = true
                local firstSignature = firstActionSignature(ctx, candidate)
                if firstSignature then
                    fullFirstSeen[firstSignature] = true
                end
                stats.kept = stats.kept + 1
                if #actions == 1 then
                    stats.singleActionOutput = stats.singleActionOutput + 1
                end
            else
                addDropped(stats, "existing_full_turn_sanitize_rejected")
            end
        elseif not requireFullTurn then
            output[#output + 1] = candidate
            seen[tostring(candidate.signature or actionSignature(ctx, actions))] = true
            stats.kept = stats.kept + 1
            if #actions == 1 then
                stats.singleActionOutput = stats.singleActionOutput + 1
            end
        else
            incomplete[#incomplete + 1] = candidate
        end
    end

    stats.incompleteInput = #incomplete
    table.sort(incomplete, function(a, b)
        return num(a and a.cheapScore, 0) > num(b and b.cheapScore, 0)
    end)

    for _, candidate in ipairs(incomplete) do
        if shouldStop(ctx) then
            addDropped(stats, "stopped_by_budget")
            break
        end

        local actions = candidate and candidate.actions or {}
        local firstAction = actions[1]
        local firstSignature = firstActionSignature(ctx, candidate)
        local needsAlternativeCompletion = stats.completed < minCompletedAlternatives or needsRiskAlternatives()
        if not firstAction then
            addDropped(stats, "missing_first_action")
        elseif firstSignature and fullFirstSeen[firstSignature] and not needsAlternativeCompletion then
            addDropped(stats, "covered_by_existing_full_turn")
        elseif stats.completed >= maxCompletions and not needsRiskAlternatives() then
            addDropped(stats, "completion_cap_reached")
        elseif stats.completionAttempts >= maxCompletionAttempts then
            addDropped(stats, "completion_attempt_cap_reached")
        elseif #output >= minOutput and not needsAlternativeCompletion then
            addDropped(stats, "completion_cap_reached")
        else
            stats.completionAttempts = stats.completionAttempts + 1
            local afterFirst = ctx and ctx.cache and ctx.cache.simulate
                and ctx.cache.simulate(ai, state, {firstAction}, ctx.aiPlayer, ctx)
                or nil
            if not afterFirst then
                addDropped(stats, "first_action_simulation_failed")
            else
                local second = selectSecondAction(ai, state, afterFirst, ctx, positionMap, firstAction, options, stats)
                if not (second and second.action) then
                    second = selectForcedSecondAction(ai, state, afterFirst, ctx, positionMap, firstAction, options, stats)
                end
                if not (second and second.action) then
                    second = selectForcedDeploySecondAction(ai, state, afterFirst, ctx, positionMap, firstAction, options, stats)
                end
                if not (second and second.action) and #output == 0 then
                    second = selectTechnicalSecondAction(ai, state, afterFirst, ctx, positionMap, firstAction, options, stats)
                end
                if second and second.action then
                    local actionsOut = {firstAction, second.action}
                    local signature = actionSignature(ctx, actionsOut)
                    if not completionSequenceAccepted(ai, state, ctx, actionsOut, stats, "completed_candidate") then
                        addDropped(stats, "completion_sanitize_rejected")
                    elseif not seen[signature] then
                        local completed = completedCandidate(ctx, candidate, actionsOut, second)
                        output[#output + 1] = completed
                        seen[signature] = true
                        if firstSignature then
                            fullFirstSeen[firstSignature] = true
                        end
                        stats.completed = stats.completed + 1
                        local riskPenalty = num(completed.tacticalTags and completed.tacticalTags.fullTurnMoveRiskPenalty, 0)
                        if riskPenalty > 0 then
                            stats.riskyCompleted = stats.riskyCompleted + 1
                            stats.riskyCompletionPenaltyMax = math.max(stats.riskyCompletionPenaltyMax, riskPenalty)
                        end
                    else
                        addDropped(stats, "duplicate_completed_signature")
                    end
                else
                    addDropped(stats, "no_v2_second_action")
                end
            end
        end
    end

    table.sort(output, function(a, b)
        return num(a and a.cheapScore, 0) > num(b and b.cheapScore, 0)
    end)

    if ctx and ctx.stats then
        ctx.stats.pipelineV2FullTurnEnabled = true
        ctx.stats.pipelineV2FullTurnInputCandidates = stats.input
        ctx.stats.pipelineV2FullTurnOutputCandidates = #output
        ctx.stats.pipelineV2FullTurnKept = stats.kept
        ctx.stats.pipelineV2FullTurnCompleted = stats.completed
        ctx.stats.pipelineV2FullTurnDropped = stats.dropped
        ctx.stats.pipelineV2FullTurnIncompleteInput = stats.incompleteInput
        ctx.stats.pipelineV2FullTurnSingleActionOutput = stats.singleActionOutput
        ctx.stats.pipelineV2FullTurnSecondScanned = stats.secondScanned
        ctx.stats.pipelineV2FullTurnForcedSecondScanned = stats.forcedSecondScanned
        ctx.stats.pipelineV2FullTurnForcedSecondAccepted = stats.forcedSecondAccepted
        ctx.stats.pipelineV2FullTurnForcedDeploySecondScanned = stats.forcedDeploySecondScanned
        ctx.stats.pipelineV2FullTurnForcedDeploySecondAccepted = stats.forcedDeploySecondAccepted
        ctx.stats.pipelineV2FullTurnTechnicalSecondScanned = stats.technicalSecondScanned
        ctx.stats.pipelineV2FullTurnTechnicalSecondAccepted = stats.technicalSecondAccepted
        ctx.stats.pipelineV2FullTurnExactSanitizeRejected = stats.exactSanitizeRejected
        ctx.stats.pipelineV2FullTurnExactSanitizeRejectedReasons = stats.exactSanitizeRejectedReasons
        ctx.stats.pipelineV2FullTurnMoveRiskPenalized = stats.moveRiskPenalized
        ctx.stats.pipelineV2FullTurnMoveRiskPenaltyMax = stats.moveRiskPenaltyMax
        ctx.stats.pipelineV2FullTurnMoveRiskLethal = stats.moveRiskLethal
        ctx.stats.pipelineV2FullTurnMoveRiskSuicidal = stats.moveRiskSuicidal
        ctx.stats.pipelineV2FullTurnRiskyCompleted = stats.riskyCompleted
        ctx.stats.pipelineV2FullTurnRiskyCompletionPenaltyMax = stats.riskyCompletionPenaltyMax
        ctx.stats.pipelineV2FullTurnCompletionAttempts = stats.completionAttempts
        ctx.stats.pipelineV2FullTurnReasonCounts = stats.reasonCounts
        ctx.stats.pipelineV2FullTurnDroppedReasons = stats.droppedReasons
    end

    return output, stats
end

return M
