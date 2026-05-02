local punishMap = require("ai_tournament.punish_map")
local earlyForcedMoveValue = require("ai_tournament.early_forced_move_value")
local earlyPositionUnits = require("ai_tournament.early_position_units")
local earlyPositionSecondAction = require("ai_tournament.early_position_second_action")
local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
local earlyPositionSequence = require("ai_tournament.early_position_sequence")
local earlyPositionStaging = require("ai_tournament.early_position_staging")
local earlyPositionSupport = require("ai_tournament.early_position_support")
local movePatternPenalty = require("ai_tournament.move_pattern_penalty")
local deployBudget = require("ai_tournament.pipeline_v2_deploy_budget")

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
    for i = 1, #(values or {}) do
        out[i] = values[i]
    end
    return out
end

local function actionTargetKey(action)
    return action and action.target and cellKey(action.target.row, action.target.col) or nil
end

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function isHub(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        local ok, result = pcall(ai.isHubUnit, ai, unit)
        if ok then
            return result == true
        end
    end
    return tostring(unit.name or "") == "Commandant"
end

local function isAlive(unit)
    return unit and num(unit.currentHp or unit.startingHp, 0) > 0
end

local function unitAttackRange(ai, unit)
    local priv = punishMap and punishMap._private or {}
    if priv.unitAttackRange then
        return priv.unitAttackRange(ai, unit)
    end
    return num(unit and (unit.atkRange or unit.range), 1)
end

local function canAttackCellFrom(ai, state, unit, fromCell, targetCell)
    local priv = punishMap and punishMap._private or {}
    if priv.canAttackCellFrom then
        return priv.canAttackCellFrom(ai, state, unit, fromCell, targetCell, {allowEmptyTarget = true}) == true
    end

    local rowDiff = math.abs(num(fromCell and fromCell.row, 0) - num(targetCell and targetCell.row, 0))
    local colDiff = math.abs(num(fromCell and fromCell.col, 0) - num(targetCell and targetCell.col, 0))
    local distance = rowDiff + colDiff
    return distance > 0 and distance <= unitAttackRange(ai, unit) and (rowDiff == 0 or colDiff == 0)
end

local function geometryCouldCover(ai, action, cell, playerId)
    if not (action and action.target and cell) then
        return false
    end
    local unit = action.unit or {
        name = action.unitName or action.unitType,
        atkRange = action.atkRange or action.range,
        player = playerId
    }
    local rowDiff = math.abs(num(action.target.row, 0) - num(cell.row, 0))
    local colDiff = math.abs(num(action.target.col, 0) - num(cell.col, 0))
    local distance = rowDiff + colDiff
    local range = unitAttackRange(ai, unit)
    local unitName = tostring(unit and unit.name or "")
    local minRange = (unitName == "Cloudstriker" or unitName == "Artillery") and 2 or 1
    return distance >= minRange and distance <= range and (rowDiff == 0 or colDiff == 0)
end

local function getUnitAt(state, row, col)
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    return nil
end

local function ownNonHubAt(ai, state, playerId, cell)
    local unit = getUnitAt(state, num(cell and cell.row, -1), num(cell and cell.col, -1))
    return unit and unit.player == playerId and isAlive(unit) and not isHub(ai, unit)
end

local function ownAttackCoverCount(ai, state, playerId, cell)
    local count = 0
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == playerId and isAlive(unit) and not isHub(ai, unit) then
            if canAttackCellFrom(ai, state, unit, unit, cell) then
                count = count + 1
            end
        end
    end
    return count
end

local function isOwnedCellHoldable(cell, ctx)
    if earlyCellPolicy.isHoldableOccupiedStrategicCell then
        return earlyCellPolicy.isHoldableOccupiedStrategicCell(cell, ctx)
    end
    return earlyCellPolicy.isGoodStrategicCell(cell, ctx)
end

local function coverPriorityValue(cell, ctx)
    return num(cell and cell.value, 0) + earlyCellPolicy.coverUrgencyBonus(cell, ctx)
end

local function stableCoverEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_STABLE_COVER_ENABLED == false)
end

local function coverRepositionEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_COVER_REPOSITION_ENABLED == false)
end

local function resolvedCellsCoveredByUnit(ai, state, ctx, positionMap, unit)
    local result = {}
    if not (stableCoverEnabled(ctx) and positionMap and state and unit and unit.row and unit.col) then
        return result
    end

    local playerId = ctx and ctx.aiPlayer or 1
    if unit.player ~= playerId or not isAlive(unit) or isHub(ai, unit) then
        return result
    end

    for _, cell in ipairs(positionMap.ownedCovered or {}) do
        if isOwnedCellHoldable(cell, ctx)
            and ownNonHubAt(ai, state, playerId, cell)
            and canAttackCellFrom(ai, state, unit, unit, cell) then
            result[#result + 1] = cell
        end
    end
    return result
end

local function classifyCoverReposition(ai, beforeState, afterState, ctx, positionMap, action, coveredCells)
    if not (coverRepositionEnabled(ctx) and afterState and action and action.target) then
        return nil, 0, nil, "source_unit_covers_resolved_cell"
    end

    local moved = getUnitAt(afterState, num(action.target.row, -1), num(action.target.col, -1))
    if not moved then
        return nil, 0, nil, "cover_reposition_missing_unit_after_move"
    end

    local bestCell = nil
    local bestValue = -math.huge
    for _, cell in ipairs(coveredCells or {}) do
        if not canAttackCellFrom(ai, afterState, moved, moved, cell) then
            return nil, 0, nil, "cover_reposition_breaks_resolved_cell"
        end
        local priority = coverPriorityValue(cell, ctx)
        if priority > bestValue then
            bestCell = cell
            bestValue = priority
        end
    end

    if not bestCell then
        return nil, 0, nil, "source_unit_covers_resolved_cell"
    end

    local target = nil
    local targetKey = actionTargetKey(action)
    for _, list in ipairs({
        positionMap and positionMap.freeTargets,
        positionMap and positionMap.nextExpansion,
        positionMap and positionMap.freeTop,
        positionMap and positionMap.top
    }) do
        for _, cell in ipairs(list or {}) do
            if (cell.key or cellKey(cell)) == targetKey then
                target = cell
                break
            end
        end
        if target then
            break
        end
    end
    local score = (bestValue * 0.18) + (num(target and target.value, 0) * 0.08)
    return "move_cover_reposition_preserves", score, bestCell, nil
end

local function mapCellsByKey(positionMap)
    local byKey = {}
    for _, list in ipairs({
        positionMap and positionMap.cells or false,
        positionMap and positionMap.freeTargets,
        positionMap and positionMap.ownedUncovered,
        positionMap and positionMap.ownedUncoveredAll or false,
        positionMap and positionMap.ownedCovered,
        positionMap and positionMap.ownedCoveredAll or false,
        positionMap and positionMap.nextExpansion,
        positionMap and positionMap.freeTop,
        positionMap and positionMap.top
    }) do
        for _, cell in ipairs(list or {}) do
            byKey[cell.key or cellKey(cell)] = cell
        end
    end
    return byKey
end

local function bestApproxCoverTarget(positionMap, action, ctx)
    if not (positionMap and action and action.target) then
        return nil, 0
    end
    local best = nil
    local bestScore = -math.huge
    for _, cell in ipairs(positionMap.ownedUncovered or {}) do
        if isOwnedCellHoldable(cell, ctx) then
            local distance = math.abs(num(action.target.row, 0) - num(cell.row, 0))
                + math.abs(num(action.target.col, 0) - num(cell.col, 0))
                local score = coverPriorityValue(cell, ctx) - (distance * 55)
            if distance > 0 and distance <= 3 and score > bestScore then
                best = cell
                bestScore = score
            end
        end
    end
    if not best then
        return nil, 0
    end
    return best, bestScore
end

local function bestRealCoverTarget(ai, beforeState, afterState, ctx, positionMap, action)
    if not (positionMap and beforeState and afterState and ctx and action and action.target) then
        return nil, 0
    end
    local playerId = ctx.aiPlayer or 1
    local best = nil
    local bestScore = -math.huge
    for _, cell in ipairs(positionMap.ownedUncovered or {}) do
        if isOwnedCellHoldable(cell, ctx)
            and ownNonHubAt(ai, beforeState, playerId, cell)
            and geometryCouldCover(ai, action, cell, playerId) then
            local beforeCover = ownAttackCoverCount(ai, beforeState, playerId, cell)
            local afterCover = ownAttackCoverCount(ai, afterState, playerId, cell)
            if afterCover > beforeCover and afterCover > 0 then
                local distance = manhattan(action.target, cell)
                local score = coverPriorityValue(cell, ctx) + 45 - (distance * 12)
                if score > bestScore then
                    best = cell
                    bestScore = score
                end
            end
        end
    end
    if not best then
        return nil, 0
    end
    return best, bestScore
end

local function actionCouldCoverAny(ai, beforeState, ctx, positionMap, action)
    if not (positionMap and beforeState and ctx and action and action.target) then
        return false
    end
    local playerId = ctx.aiPlayer or 1
    for _, cell in ipairs(positionMap.ownedUncovered or {}) do
        if isOwnedCellHoldable(cell, ctx)
            and ownNonHubAt(ai, beforeState, playerId, cell)
            and geometryCouldCover(ai, action, cell, playerId) then
            return true
        end
    end
    return false
end

local function realCoverEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_REAL_COVER_ENABLED == false)
end

local function uncoveredAdvanceEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_UNCOVERED_ADVANCE_ENABLED == false)
end

local function uncoveredAdvanceMinGain(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_UNCOVERED_ADVANCE_MIN_GAIN, 60)
end

local function formedPairReleaseEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_FORMED_PAIR_RELEASE_ENABLED == false)
end

local function earlyDeploySecondEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_DEPLOY_FIRST_EARLY_SECOND_ENABLED == false)
end

local function supportFirstReason(reason)
    return reason == "support_cover" or reason == "support_near_primary"
end

local function strictSupportCoverEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_STRICT_SUPPORT_COVER_ENABLED == false)
end

local function classifyDeployTarget(positionMap, action, ctx)
    local byKey = mapCellsByKey(positionMap)
    local target = byKey[actionTargetKey(action)]
    if target and target.status == "free_target" and earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return "occupy_free_target", num(target.value, 0), target
    end
    if target and target.status == "next_expansion" and earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return "expand_next", num(target.value, 0), target
    end
    return nil, 0, nil
end

local function classifyDeployFallbackTarget(ai, state, positionMap, action, ctx)
    local target = mapCellsByKey(positionMap)[actionTargetKey(action)]
    if target
        and target.earlyFrontierRole == "support_cover"
        and target.earlyPrimaryTarget == false
        and earlyCellPolicy.isGoodStrategicCell(target, ctx, {ignorePrimaryTarget = true}) then
        local useful = earlyPositionSupport.isUsefulSupportAction(ai, state, ctx, positionMap, target, action)
        if useful then
            return "support_cover",
                (num(target.value, 0) * 0.12) + (num(target.earlyCoverValueBonus, 0) * 0.45),
                target
        end
    end
    if earlyPositionStaging.isStagingCell(target, ctx) then
        return "staging_frontier", earlyPositionStaging.score(target, 0.08, 0.06), target
    end
    if target
        and target.earlyPrimaryTarget == false
        and not strictSupportCoverEnabled(ctx)
        and earlyCellPolicy.isGoodStrategicCell(target, ctx, {ignorePrimaryTarget = true}) then
        return "support_near_primary", num(target.value, 0) * 0.12, target
    end
    if target and earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return "position_map_target", num(target.value, 0) * 0.35, target
    end
    return nil, 0, nil
end

local function classifyDeployApprox(ai, state, positionMap, action, ctx)
    local reason, score, target = classifyDeployTarget(positionMap, action, ctx)
    if reason then
        return reason, score, target
    end
    return classifyDeployFallbackTarget(ai, state, positionMap, action, ctx)
end

local function classifyMoveTarget(positionMap, action, ctx)
    local byKey = mapCellsByKey(positionMap)
    local source = action and action.unit and byKey[cellKey(action.unit.row, action.unit.col)] or nil
    if source and source.status == "owned_covered" and isOwnedCellHoldable(source, ctx) then
        return nil, 0, nil, "source_cell_already_covered"
    end
    if source and source.status == "owned_uncovered" and isOwnedCellHoldable(source, ctx) then
        return nil, 0, nil, "source_cell_uncovered_requires_upgrade"
    end

    local target = byKey[actionTargetKey(action)]
    if target and target.status == "free_target" and earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return "move_occupy_free_target", num(target.value, 0), target
    end
    if target and target.status == "next_expansion" and earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return "move_expand_next", num(target.value, 0), target
    end
    return nil, 0, nil, "target_not_strategic"
end

local function classifyMoveFallbackTarget(ai, state, positionMap, action, ctx)
    local target = mapCellsByKey(positionMap)[actionTargetKey(action)]
    if target
        and target.earlyFrontierRole == "support_cover"
        and target.earlyPrimaryTarget == false
        and earlyCellPolicy.isGoodStrategicCell(target, ctx, {ignorePrimaryTarget = true}) then
        local useful = earlyPositionSupport.isUsefulSupportAction(ai, state, ctx, positionMap, target, action)
        if useful then
            return "move_support_cover",
                (num(target.value, 0) * 0.1) + (num(target.earlyCoverValueBonus, 0) * 0.35),
                target,
                nil
        end
    end
    if earlyPositionStaging.isStagingCell(target, ctx) then
        return "move_staging_frontier", earlyPositionStaging.score(target, 0.07, 0.05), target, nil
    end
    if target and earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return "move_position_map_target", num(target.value, 0) * 0.25, target, nil
    end
    return nil, 0, nil, "target_not_strategic"
end

local function classifyRetreatMove(positionMap, action, ctx)
    if not (action and action.type == "move" and action.unit and action.target) then
        return nil, 0, nil, nil
    end
    if not earlyCellPolicy.requiresRetreat then
        return nil, 0, nil, nil
    end

    local byKey = mapCellsByKey(positionMap)
    local source = byKey[cellKey(action.unit.row, action.unit.col)]
    if not earlyCellPolicy.requiresRetreat(source, ctx) then
        return nil, 0, nil, nil
    end

    local target = byKey[actionTargetKey(action)]
    if not target then
        return nil, 0, nil, "retreat_target_missing"
    end
    if not earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return nil, 0, nil, "retreat_target_not_safe_strategic"
    end

    local reason = target.status == "next_expansion"
        and "move_retreat_expand_next"
        or "move_retreat_to_strategic_cell"
    local distancePenalty = manhattan(action.unit, action.target) * 12
    local score = num(target.value, 0)
        + earlyCellPolicy.retreatScoreBonus(ctx)
        + math.max(0, earlyCellPolicy.cellValue(source) * 0.1)
        - distancePenalty
    return reason, score, target, nil
end

local function lowestCellValue(cells, ctx)
    local bestCell = nil
    local bestValue = math.huge
    for _, cell in ipairs(cells or {}) do
        local value = coverPriorityValue(cell, ctx)
        if value < bestValue then
            bestCell = cell
            bestValue = value
        end
    end
    if bestValue == math.huge then
        bestValue = 0
    end
    return bestValue, bestCell
end

local function sourceMapCell(positionMap, action)
    local byKey = mapCellsByKey(positionMap)
    return action and action.unit and byKey[cellKey(action.unit.row, action.unit.col)] or nil
end

local function releaseMoveTargetScore(ai, state, positionMap, action, ctx)
    local reason, score, targetCell = classifyMoveFallbackTarget(ai, state, positionMap, action, ctx)
    if reason then
        return reason, score, targetCell
    end
    targetCell = mapCellsByKey(positionMap)[actionTargetKey(action)]
    return "forced_step", earlyForcedMoveValue.scoreTarget(targetCell, action, ctx), targetCell
end

local function classifyFormedPairRelease(ai, state, positionMap, action, ctx, unitPool, coveredResolvedCells)
    if not (formedPairReleaseEnabled(ctx) and action and action.type == "move") then
        return nil
    end

    if #(coveredResolvedCells or {}) > 0 then
        local releaseValue, releaseCell = lowestCellValue(coveredResolvedCells, ctx)
        local targetReason, targetScore, targetCell = releaseMoveTargetScore(ai, state, positionMap, action, ctx)
        return {
            action = action,
            reason = "move_release_cover_then_" .. tostring(targetReason or "forced_step"),
            score = (num(targetScore, 0) * 0.22) - (releaseValue * 0.55),
            targetCell = targetCell or releaseCell,
            releaseTier = 1,
            releaseValue = releaseValue
        }
    end

    local sourceKey = action.unit and cellKey(action.unit) or nil
    if unitPool and unitPool.lockedOccupantByKey and unitPool.lockedOccupantByKey[sourceKey] then
        local releaseCell = sourceMapCell(positionMap, action)
        local releaseValue = earlyCellPolicy.cellValue(releaseCell)
        local targetReason, targetScore, targetCell = releaseMoveTargetScore(ai, state, positionMap, action, ctx)
        return {
            action = action,
            reason = "move_release_occupant_then_" .. tostring(targetReason or "forced_step"),
            score = (num(targetScore, 0) * 0.16) - (releaseValue * 0.75),
            targetCell = targetCell or releaseCell,
            releaseTier = 2,
            releaseValue = releaseValue
        }
    end

    return nil
end

local function betterReleaseCandidate(a, b)
    if not b then
        return true
    end
    if not a then
        return false
    end
    if num(a.releaseTier, 99) ~= num(b.releaseTier, 99) then
        return num(a.releaseTier, 99) < num(b.releaseTier, 99)
    end
    return num(a.score, num(a.cheapScore, 0)) > num(b.score, num(b.cheapScore, 0))
end

local function classifyUncoveredAdvance(positionMap, action, ctx)
    if not (uncoveredAdvanceEnabled(ctx) and action and action.unit and action.target) then
        return nil, 0, nil, nil
    end

    local byKey = mapCellsByKey(positionMap)
    local source = byKey[cellKey(action.unit.row, action.unit.col)]
    if not (source and source.status == "owned_uncovered" and isOwnedCellHoldable(source, ctx)) then
        return nil, 0, nil, nil
    end

    local target = byKey[actionTargetKey(action)]
    if not (target
        and (target.status == "free_target" or target.status == "next_expansion")
        and earlyCellPolicy.isGoodStrategicCell(target, ctx)) then
        return nil, 0, nil, "owned_uncovered_target_not_upgrade"
    end

    local gain = num(target.value, 0) - num(source.value, 0)
    if gain < uncoveredAdvanceMinGain(ctx) then
        return nil, 0, nil, "owned_uncovered_upgrade_too_small"
    end

    local reason = target.status == "next_expansion"
        and "move_uncovered_advance_next"
        or "move_uncovered_occupy_better"
    return reason, num(target.value, 0) + (gain * 0.25), target, nil
end

local function classifyMoveApprox(ai, state, positionMap, action, ctx)
    local reason, score, target, skipReason = classifyMoveTarget(positionMap, action, ctx)
    if reason
        or skipReason == "source_cell_already_covered"
        or skipReason == "source_cell_uncovered_requires_upgrade" then
        return reason, score, target, skipReason
    end
    local coverTarget, coverScore = bestApproxCoverTarget(positionMap, action, ctx)
    if coverTarget then
        return "move_cover_owned_uncovered", coverScore, coverTarget
    end
    return classifyMoveFallbackTarget(ai, state, positionMap, action, ctx)
end

local function candidateSignature(ctx, actions)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.sequenceSignature then
        return ctx.turnEnumerator.sequenceSignature(actions)
    end
    local parts = {}
    for _, action in ipairs(actions or {}) do
        parts[#parts + 1] = tostring(action and action.type or "?")
    end
    return table.concat(parts, "|")
end

local function containsDeploy(actions)
    for _, action in ipairs(actions or {}) do
        if action and action.type == "supply_deploy" then
            return true
        end
    end
    return false
end

local function containsAttack(actions)
    for _, action in ipairs(actions or {}) do
        if action and action.type == "attack" then
            return true
        end
    end
    return false
end

local function buildCandidate(ctx, actions, reason, mapScore, targetCell, source)
    local sequence = movePatternPenalty.tagPositionMoves(copyArray(actions))
    return {
        actions = sequence,
        signature = candidateSignature(ctx, sequence),
        source = source or "early_position_deploy_first",
        buckets = {reason or "early_position"},
        cheapScore = num(mapScore, 0),
        tacticalTags = {
            earlyPositionReason = reason,
            earlyPositionTarget = targetCell and {
                row = targetCell.row,
                col = targetCell.col,
                status = targetCell.status,
                value = targetCell.value,
                positionValue = targetCell.earlyPositionValue,
                frontierRole = targetCell.earlyFrontierRole,
                supportForKey = targetCell.earlySupportForKey,
                coverValueBonus = targetCell.earlyCoverValueBonus
            } or nil
        },
        containsDeploy = containsDeploy(sequence),
        containsAttack = containsAttack(sequence),
        completeTurn = true,
        terminal = false,
        legalSkipReason = nil
    }
end

local function legalFloorEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_LEGAL_FLOOR_ENABLED == false)
end

local function legalFloorCap(ctx, maxCandidates)
    local configured = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_LEGAL_FLOOR_CANDIDATE_CAP, 4)
    return clampLimit(configured, 1, math.max(1, maxCandidates or 4))
end

local function buildLegalFloorCandidate(ai, state, ctx, positionMap, entry, move)
    if not (legalFloorEnabled(ctx) and move and move.type == "move") then
        return nil
    end
    local targetCell = mapCellsByKey(positionMap)[actionTargetKey(move)]
    local forcedScore = earlyForcedMoveValue.scoreTarget(targetCell, move, ctx)
    local penalty = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_LEGAL_FLOOR_PENALTY, 9000)
    local mapScore = num(forcedScore, 0)
        + num(entry and entry.cheapScore, 0) * 0.03
        - penalty
    mapScore = movePatternPenalty.adjustScore(ai, state, ctx, move, mapScore)
    local candidate = buildCandidate(
        ctx,
        {move},
        "move_legal_floor_non_strategic",
        mapScore,
        targetCell,
        "early_position_move"
    )
    candidate.earlyLegalFloor = true
    candidate.legalSkipReason = "target_not_strategic"
    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.earlyPositionLegalFloor = true
    return candidate
end

local function collectDeployEntries(ai, state, ctx)
    return deployBudget.collectEntries(ai, state, ctx, {
        statPrefix = "pipelineV2DeployFirst"
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
    local result = {}
    for _, entry in ipairs(entries) do
        local action = entry and entry.action or nil
        if action and action.type == "move" then
            result[#result + 1] = entry
        end
    end
    return result
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

local function collectNonCombatContinuations(ai, state, ctx, limit)
    local result = {}
    if not (ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions) then
        return result
    end
    local entries = ctx.turnEnumerator.collectTournamentActions(ai, state, ctx.aiPlayer, ctx, {
        includeMove = true,
        includeAttack = false,
        includeRepair = true,
        includeDeploy = false
    }) or {}
    for _, entry in ipairs(entries) do
        local action = entry and entry.action or entry
        if action and action.type and action.type ~= "attack" and action.type ~= "supply_deploy" then
            result[#result + 1] = entry
            if #result >= limit then
                break
            end
        end
    end
    return result
end

local function continuationAllowed(positionMap, action, ctx)
    if not action then
        return false, "missing_action"
    end
    if action.type == "move" then
        local target = mapCellsByKey(positionMap)[actionTargetKey(action)]
        if not earlyCellPolicy.isGoodStrategicCell(target, ctx) then
            return false, earlyCellPolicy.rejectReason(target, ctx) or "move_continuation_target_not_strategic"
        end
    end
    return true, nil
end

local function rankedDeployEntries(ai, state, positionMap, deployEntries, ctx, useRealCover, agenda)
    local ranked = {}
    for _, entry in ipairs(deployEntries or {}) do
        local deploy = entry and entry.action or nil
        if deploy and deploy.type == "supply_deploy" then
            local reason, mapScore, targetCell = nil, 0, nil
            if useRealCover then
                reason, mapScore, targetCell = classifyDeployTarget(positionMap, deploy, ctx)
                if not reason then
                    reason, mapScore, targetCell = classifyDeployFallbackTarget(ai, state, positionMap, deploy, ctx)
                end
            else
                reason, mapScore, targetCell = classifyDeployApprox(ai, state, positionMap, deploy, ctx)
            end
            if reason then
                local sequenceBonus = earlyPositionSequence.bonusForTarget(agenda, targetCell, reason)
                local adjustedScore = mapScore + sequenceBonus
                ranked[#ranked + 1] = {
                    entry = entry,
                    action = deploy,
                    reason = reason,
                    mapScore = adjustedScore,
                    targetCell = targetCell,
                    sequenceBonus = sequenceBonus,
                    sortScore = num(adjustedScore, 0) + (num(entry and entry.cheapScore, 0) * 0.02)
                }
            end
        end
    end

    table.sort(ranked, function(a, b)
        if num(a and a.sortScore, 0) == num(b and b.sortScore, 0) then
            return candidateSignature(ctx, {a and a.action}) < candidateSignature(ctx, {b and b.action})
        end
        return num(a and a.sortScore, 0) > num(b and b.sortScore, 0)
    end)
    return ranked
end

function M.generateDeployFirst(ai, state, ctx, positionMap, opts)
    opts = opts or {}
    local maxCandidates = math.max(1, num(opts.maxCandidates, 24))
    local deployActionCap = math.max(0, num(opts.deployActionCap, 8))
    local allowEarlySecond = earlyDeploySecondEnabled(ctx)
    local continuationCap = 0
    local earlySecondScanCap = math.max(0, num(opts.earlySecondScanCap, 8))
    local earlySecondDeployCap = math.max(0, num(opts.earlySecondDeployCap, 3))
    local useRealCover = realCoverEnabled(ctx)
    local candidates = {}
    local seen = {}
    local reasonCounts = {}
    local earlySecondReasonCounts = {}
    local earlySecondSkippedReasons = {}
    local realCoverChecks = 0
    local realCoverHits = 0
    local continuationCandidates = 0
    local earlySecondScanned = 0
    local earlySecondDeploysScanned = 0
    local earlySecondMoveRiskPenalized = 0
    local earlySecondMoveRiskPenaltyMax = 0
    local earlySecondMoveRiskLethal = 0
    local earlySecondMoveRiskSuicidal = 0
    local agenda = earlyPositionSequence.build(positionMap, ctx)
    local deployEntries = collectDeployEntries(ai, state, ctx)
    local deployRanked = rankedDeployEntries(ai, state, positionMap, deployEntries, ctx, useRealCover, agenda)
    local consideredDeployActions = 0

    for _, ranked in ipairs(deployRanked) do
        if deployActionCap > 0 and consideredDeployActions >= deployActionCap then
            break
        end
        local deploy = ranked.action
        local reason = ranked.reason
        local mapScore = ranked.mapScore
        local targetCell = ranked.targetCell
        local supportFirst = supportFirstReason(reason)
        consideredDeployActions = consideredDeployActions + 1
        reasonCounts[reason] = num(reasonCounts[reason], 0) + 1

        if not supportFirst then
            local baseCandidate = buildCandidate(ctx, {deploy}, reason, mapScore, targetCell)
            if not seen[baseCandidate.signature] then
                seen[baseCandidate.signature] = true
                candidates[#candidates + 1] = baseCandidate
            end
        end

        local afterDeploy = nil
        if allowEarlySecond
            and earlySecondScanCap > 0
            and earlySecondDeploysScanned < earlySecondDeployCap then
            afterDeploy = afterDeploy or ctx.cache.simulate(ai, state, {deploy}, ctx.aiPlayer, ctx)
            if afterDeploy then
                        earlySecondDeploysScanned = earlySecondDeploysScanned + 1
                        local second, secondStats = earlyPositionSecondAction.select(
                            ai,
                            state,
                            afterDeploy,
                            ctx,
                            positionMap,
                            deploy,
                            {scanCap = earlySecondScanCap}
                        )
                        earlySecondScanned = earlySecondScanned + num(secondStats and secondStats.scanned, 0)
                        earlySecondMoveRiskPenalized = earlySecondMoveRiskPenalized
                            + num(secondStats and secondStats.moveRiskPenalized, 0)
                        earlySecondMoveRiskPenaltyMax = math.max(
                            earlySecondMoveRiskPenaltyMax,
                            num(secondStats and secondStats.moveRiskPenaltyMax, 0)
                        )
                        earlySecondMoveRiskLethal = earlySecondMoveRiskLethal
                            + num(secondStats and secondStats.moveRiskLethal, 0)
                        earlySecondMoveRiskSuicidal = earlySecondMoveRiskSuicidal
                            + num(secondStats and secondStats.moveRiskSuicidal, 0)
                        for key, value in pairs((secondStats and secondStats.reasonCounts) or {}) do
                            earlySecondReasonCounts[key] = num(earlySecondReasonCounts[key], 0) + num(value, 0)
                        end
                        for key, value in pairs((secondStats and secondStats.skippedReasons) or {}) do
                            earlySecondSkippedReasons[key] = num(earlySecondSkippedReasons[key], 0) + num(value, 0)
                        end
                        if second and second.action then
                            local candidate = buildCandidate(
                                ctx,
                                {deploy, second.action},
                                reason .. "_then_" .. tostring(second.reason or "early_second"),
                                mapScore + num(second.score, 0) * 0.12,
                                second.targetCell or targetCell
                            )
                            if not seen[candidate.signature] then
                                seen[candidate.signature] = true
                                candidates[#candidates + 1] = candidate
                                continuationCandidates = continuationCandidates + 1
                            end
                        end
            end
        end
        if #candidates >= maxCandidates then
            break
        end
    end

    table.sort(candidates, function(a, b)
        if num(a.cheapScore, 0) == num(b.cheapScore, 0) then
            return tostring(a.signature or "") < tostring(b.signature or "")
        end
        return num(a.cheapScore, 0) > num(b.cheapScore, 0)
    end)

    while #candidates > maxCandidates do
        table.remove(candidates)
    end

    if ctx and ctx.stats then
        ctx.stats.pipelineV2DeployFirstCandidates = #candidates
        ctx.stats.pipelineV2DeployFirstDeployActions = consideredDeployActions
        ctx.stats.pipelineV2DeployFirstTotalDeployActions = #deployEntries
        ctx.stats.pipelineV2DeployFirstRankedDeployActions = #deployRanked
        ctx.stats.pipelineV2DeployFirstActionCap = deployActionCap
        ctx.stats.pipelineV2DeployFirstReasonCounts = reasonCounts
        ctx.stats.pipelineV2DeployFirstCoverMode = "deploy_not_cover"
        ctx.stats.pipelineV2DeployFirstRealCoverChecks = realCoverChecks
        ctx.stats.pipelineV2DeployFirstRealCoverHits = realCoverHits
        ctx.stats.pipelineV2DeployFirstContinuationMode =
            allowEarlySecond and "early_second_action" or "pure_deploy_only"
        ctx.stats.pipelineV2DeployFirstContinuationCap = continuationCap
        ctx.stats.pipelineV2DeployFirstContinuationCandidates = continuationCandidates
        ctx.stats.pipelineV2DeployFirstEarlySecondScanCap = earlySecondScanCap
        ctx.stats.pipelineV2DeployFirstEarlySecondDeployCap = earlySecondDeployCap
        ctx.stats.pipelineV2DeployFirstEarlySecondDeploysScanned = earlySecondDeploysScanned
        ctx.stats.pipelineV2DeployFirstEarlySecondScanned = earlySecondScanned
        ctx.stats.pipelineV2DeployFirstEarlySecondMoveRiskPenalized = earlySecondMoveRiskPenalized
        ctx.stats.pipelineV2DeployFirstEarlySecondMoveRiskPenaltyMax = earlySecondMoveRiskPenaltyMax
        ctx.stats.pipelineV2DeployFirstEarlySecondMoveRiskLethal = earlySecondMoveRiskLethal
        ctx.stats.pipelineV2DeployFirstEarlySecondMoveRiskSuicidal = earlySecondMoveRiskSuicidal
        ctx.stats.pipelineV2DeployFirstEarlySecondReasonCounts = earlySecondReasonCounts
        ctx.stats.pipelineV2DeployFirstEarlySecondSkippedReasons = earlySecondSkippedReasons
        ctx.stats.pipelineV2EarlySequencePrimary = earlyPositionSequence.describe(agenda and agenda.primary)
        ctx.stats.pipelineV2DeployFirstTop = {}
        for index = 1, math.min(8, #candidates) do
            local candidate = candidates[index]
            ctx.stats.pipelineV2DeployFirstTop[#ctx.stats.pipelineV2DeployFirstTop + 1] =
                tostring(math.floor(num(candidate.cheapScore, 0)))
                .. ":"
                .. tostring(candidate.tacticalTags and candidate.tacticalTags.earlyPositionReason or "unknown")
                .. ":"
                .. tostring(candidate.signature or "")
        end
    end

    return candidates
end

function M.generateMovePosition(ai, state, ctx, positionMap, opts)
    opts = opts or {}
    local maxCandidates = math.max(1, num(opts.maxCandidates, 24))
    local continuationCap = math.max(0, num(opts.continuationCap, 3))
    local useRealCover = realCoverEnabled(ctx)
    local candidates = {}
    local seen = {}
    local reasonCounts = {}
    local skippedReasons = {}
    local realCoverChecks = 0
    local realCoverHits = 0
    local agenda = earlyPositionSequence.build(positionMap, ctx)
    local releaseCandidates = {}
    local legalFloorCandidates = {}
    local legalFloorPromoted = 0
    local moveEntries = collectMoveEntries(ai, state, ctx)
    local unitPool = earlyPositionUnits.classify(ai, state, ctx, positionMap)

    for _, entry in ipairs(moveEntries) do
        local move = moveActionWithEntryUnit(entry)
        if move and move.type == "move" then
            local reason, mapScore, targetCell, skipReason = nil, 0, nil, nil
            local afterMove = nil
            local releaseItem = nil
            local coveredResolvedCells = {}
            if stableCoverEnabled(ctx) and unitPool and unitPool.coveredCellsByUnitKey then
                coveredResolvedCells = unitPool.coveredCellsByUnitKey[cellKey(move.unit)] or {}
            end
            if #coveredResolvedCells > 0 then
                afterMove = ctx.cache.simulate(ai, state, {move}, ctx.aiPlayer, ctx)
                reason, mapScore, targetCell, skipReason =
                    classifyCoverReposition(ai, state, afterMove, ctx, positionMap, move, coveredResolvedCells)
            end

            if not reason and not skipReason then
                reason, mapScore, targetCell, skipReason = classifyRetreatMove(positionMap, move, ctx)
            end
            if not reason and not skipReason then
                reason, mapScore, targetCell, skipReason = classifyUncoveredAdvance(positionMap, move, ctx)
            end
            if not reason and not skipReason and useRealCover then
                reason, mapScore, targetCell, skipReason = classifyMoveTarget(positionMap, move, ctx)
            elseif not reason and not skipReason then
                reason, mapScore, targetCell, skipReason = classifyMoveApprox(ai, state, positionMap, move, ctx)
            end
            if not reason
                and useRealCover
                and skipReason ~= "source_cell_already_covered"
                and skipReason ~= "source_unit_covers_resolved_cell"
                and skipReason ~= "cover_reposition_breaks_resolved_cell"
                and skipReason ~= "cover_reposition_missing_unit_after_move"
                and skipReason ~= "source_cell_uncovered_requires_upgrade"
                and skipReason ~= "owned_uncovered_target_not_upgrade"
                and skipReason ~= "owned_uncovered_upgrade_too_small"
                and actionCouldCoverAny(ai, state, ctx, positionMap, move) then
                afterMove = ctx.cache.simulate(ai, state, {move}, ctx.aiPlayer, ctx)
                if afterMove then
                    realCoverChecks = realCoverChecks + 1
                    local coverTarget, coverScore = bestRealCoverTarget(ai, state, afterMove, ctx, positionMap, move)
                    if coverTarget then
                        reason = "move_cover_owned_uncovered"
                        mapScore = coverScore
                        targetCell = coverTarget
                        skipReason = nil
                        realCoverHits = realCoverHits + 1
                    end
                end
            end
            if not reason
                and useRealCover
                and skipReason ~= "source_cell_already_covered"
                and skipReason ~= "source_unit_covers_resolved_cell"
                and skipReason ~= "cover_reposition_breaks_resolved_cell"
                and skipReason ~= "cover_reposition_missing_unit_after_move"
                and skipReason ~= "source_cell_uncovered_requires_upgrade"
                and skipReason ~= "owned_uncovered_target_not_upgrade"
                and skipReason ~= "owned_uncovered_upgrade_too_small" then
                reason, mapScore, targetCell, skipReason = classifyMoveFallbackTarget(ai, state, positionMap, move, ctx)
            end
            if not reason then
                releaseItem = classifyFormedPairRelease(ai, state, positionMap, move, ctx, unitPool, coveredResolvedCells)
            end
            if reason then
                mapScore = mapScore + earlyPositionSequence.bonusForTarget(agenda, targetCell, reason)
                mapScore = movePatternPenalty.adjustScore(ai, state, ctx, move, mapScore)
                reasonCounts[reason] = num(reasonCounts[reason], 0) + 1
                afterMove = afterMove or ctx.cache.simulate(ai, state, {move}, ctx.aiPlayer, ctx)
                if afterMove then
                    local baseCandidate = buildCandidate(
                        ctx,
                        {move},
                        reason,
                        mapScore + num(entry and entry.cheapScore, 0) * 0.1,
                        targetCell,
                        "early_position_move"
                    )
                    if not seen[baseCandidate.signature] then
                        seen[baseCandidate.signature] = true
                        candidates[#candidates + 1] = baseCandidate
                    end

                    if continuationCap > 0 then
                        local continuations = collectNonCombatContinuations(ai, afterMove, ctx, continuationCap)
                        for _, continuationEntry in ipairs(continuations) do
                            local continuation = continuationEntry and continuationEntry.action or nil
                            local allowed, blockedReason = continuationAllowed(positionMap, continuation, ctx)
                            if continuation and allowed then
                                local candidate = buildCandidate(
                                    ctx,
                                    {move, continuation},
                                    reason .. "_then_position",
                                    mapScore + num(entry and entry.cheapScore, 0) * 0.1
                                        + num(continuationEntry and continuationEntry.cheapScore, 0) * 0.08,
                                    targetCell,
                                    "early_position_move"
                                )
                                if not seen[candidate.signature] then
                                    seen[candidate.signature] = true
                                    candidates[#candidates + 1] = candidate
                                end
                                if #candidates >= maxCandidates then
                                    break
                                end
                            elseif blockedReason then
                                skippedReasons["continuation_" .. tostring(blockedReason)] =
                                    num(skippedReasons["continuation_" .. tostring(blockedReason)], 0) + 1
                            end
                        end
                    end
                end
            elseif releaseItem then
                releaseItem.score = num(releaseItem.score, 0)
                    + earlyPositionSequence.bonusForTarget(agenda, releaseItem.targetCell, releaseItem.reason) * 0.08
                    + num(entry and entry.cheapScore, 0) * 0.04
                releaseItem.score = movePatternPenalty.adjustScore(ai, state, ctx, move, releaseItem.score)
                afterMove = afterMove or ctx.cache.simulate(ai, state, {move}, ctx.aiPlayer, ctx)
                if afterMove then
                    releaseCandidates[#releaseCandidates + 1] = buildCandidate(
                        ctx,
                        {move},
                        releaseItem.reason,
                        releaseItem.score,
                        releaseItem.targetCell,
                        "early_position_move_release"
                    )
                    releaseCandidates[#releaseCandidates].releaseTier = releaseItem.releaseTier
                    releaseCandidates[#releaseCandidates].releaseValue = releaseItem.releaseValue
                end
            else
                skippedReasons[skipReason or "move_not_position_target"] =
                    num(skippedReasons[skipReason or "move_not_position_target"], 0) + 1
                if skipReason == "target_not_strategic" then
                    local floorCandidate = buildLegalFloorCandidate(ai, state, ctx, positionMap, entry, move)
                    if floorCandidate then
                        legalFloorCandidates[#legalFloorCandidates + 1] = floorCandidate
                    end
                end
            end
        end
        if #candidates >= maxCandidates then
            break
        end
    end

    if #candidates == 0 and #releaseCandidates > 0 then
        table.sort(releaseCandidates, function(a, b)
            if betterReleaseCandidate(a, b) then
                return true
            end
            if betterReleaseCandidate(b, a) then
                return false
            end
            return tostring(a.signature or "") < tostring(b.signature or "")
        end)
        for _, candidate in ipairs(releaseCandidates) do
            if not seen[candidate.signature] then
                seen[candidate.signature] = true
                candidates[#candidates + 1] = candidate
                local reason = candidate.tacticalTags and candidate.tacticalTags.earlyPositionReason
                reasonCounts[reason or "move_release_formed_pair"] =
                    num(reasonCounts[reason or "move_release_formed_pair"], 0) + 1
            end
            if #candidates >= maxCandidates then
                break
            end
        end
    end

    if #candidates == 0 and #releaseCandidates == 0 and #legalFloorCandidates > 0 then
        table.sort(legalFloorCandidates, function(a, b)
            if num(a and a.cheapScore, 0) == num(b and b.cheapScore, 0) then
                return tostring(a and a.signature or "") < tostring(b and b.signature or "")
            end
            return num(a and a.cheapScore, 0) > num(b and b.cheapScore, 0)
        end)
        for _, candidate in ipairs(legalFloorCandidates) do
            if not seen[candidate.signature] then
                seen[candidate.signature] = true
                candidates[#candidates + 1] = candidate
                legalFloorPromoted = legalFloorPromoted + 1
                reasonCounts.move_legal_floor_non_strategic =
                    num(reasonCounts.move_legal_floor_non_strategic, 0) + 1
            end
            if legalFloorPromoted >= legalFloorCap(ctx, maxCandidates) or #candidates >= maxCandidates then
                break
            end
        end
    end

    table.sort(candidates, function(a, b)
        if num(a.cheapScore, 0) == num(b.cheapScore, 0) then
            return tostring(a.signature or "") < tostring(b.signature or "")
        end
        return num(a.cheapScore, 0) > num(b.cheapScore, 0)
    end)

    while #candidates > maxCandidates do
        table.remove(candidates)
    end

    if ctx and ctx.stats then
        ctx.stats.pipelineV2MovePositionCandidates = #candidates
        ctx.stats.pipelineV2MovePositionActions = #moveEntries
        ctx.stats.pipelineV2MovePositionLegalFloorCandidates = #legalFloorCandidates
        ctx.stats.pipelineV2MovePositionLegalFloorPromoted = legalFloorPromoted
        ctx.stats.pipelineV2MovePositionReasonCounts = reasonCounts
        ctx.stats.pipelineV2MovePositionSkippedReasons = skippedReasons
        ctx.stats.pipelineV2MovePositionCoverMode = useRealCover and "real_influence" or "distance_approx"
        ctx.stats.pipelineV2MovePositionRealCoverChecks = realCoverChecks
        ctx.stats.pipelineV2MovePositionRealCoverHits = realCoverHits
        ctx.stats.pipelineV2UnitPoolFreeUnits = #(unitPool and unitPool.freeUnits or {})
        ctx.stats.pipelineV2UnitPoolLockedOccupants = #(unitPool and unitPool.lockedOccupants or {})
        ctx.stats.pipelineV2UnitPoolLockedCoverUnits = #(unitPool and unitPool.lockedCoverUnits or {})
        ctx.stats.pipelineV2UnitPoolReleasableOccupants = #(unitPool and unitPool.releasableOccupants or {})
        ctx.stats.pipelineV2UnitPoolCoverTargets = #(unitPool and unitPool.coverTargets or {})
        ctx.stats.pipelineV2UnitPoolResolvedCells = #(unitPool and unitPool.resolvedCells or {})
        ctx.stats.pipelineV2UnitPoolFree = unitPool and unitPool.summaries and unitPool.summaries.free or {}
        ctx.stats.pipelineV2UnitPoolLockedOccupantsList =
            unitPool and unitPool.summaries and unitPool.summaries.lockedOccupants or {}
        ctx.stats.pipelineV2UnitPoolLockedCoverUnitsList =
            unitPool and unitPool.summaries and unitPool.summaries.lockedCoverUnits or {}
        ctx.stats.pipelineV2UnitPoolReleasableOccupantsList =
            unitPool and unitPool.summaries and unitPool.summaries.releasableOccupants or {}
        ctx.stats.pipelineV2EarlySequencePrimary =
            ctx.stats.pipelineV2EarlySequencePrimary or earlyPositionSequence.describe(agenda and agenda.primary)
        ctx.stats.pipelineV2MovePositionTop = {}
        for index = 1, math.min(8, #candidates) do
            local candidate = candidates[index]
            ctx.stats.pipelineV2MovePositionTop[#ctx.stats.pipelineV2MovePositionTop + 1] =
                tostring(math.floor(num(candidate.cheapScore, 0)))
                .. ":"
                .. tostring(candidate.tacticalTags and candidate.tacticalTags.earlyPositionReason or "unknown")
                .. ":"
                .. tostring(candidate.signature or "")
        end
    end

    return candidates
end

return M
