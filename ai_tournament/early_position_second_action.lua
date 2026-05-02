local punishMap = require("ai_tournament.punish_map")
local earlyForcedMoveValue = require("ai_tournament.early_forced_move_value")
local earlyMoveRisk = require("ai_tournament.early_move_risk")
local earlyPositionUnits = require("ai_tournament.early_position_units")
local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
local earlyPositionSequence = require("ai_tournament.early_position_sequence")
local movePatternPenalty = require("ai_tournament.move_pattern_penalty")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
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

local function cloneCell(cell, status)
    local copy = {}
    for key, value in pairs(cell or {}) do
        copy[key] = value
    end
    copy.status = status or copy.status
    copy.key = copy.key or cellKey(copy)
    return copy
end

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function isAlive(unit)
    return unit and num(unit.currentHp or unit.startingHp, 0) > 0
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

local function getUnitAt(state, row, col)
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    return nil
end

local function canAttackCellFrom(ai, state, unit, fromCell, targetCell)
    local priv = punishMap and punishMap._private or {}
    if priv.canAttackCellFrom then
        return priv.canAttackCellFrom(ai, state, unit, fromCell, targetCell, {allowEmptyTarget = true}) == true
    end

    local rowDiff = math.abs(num(fromCell and fromCell.row, 0) - num(targetCell and targetCell.row, 0))
    local colDiff = math.abs(num(fromCell and fromCell.col, 0) - num(targetCell and targetCell.col, 0))
    local distance = rowDiff + colDiff
    local range = num(unit and (unit.atkRange or unit.range), 1)
    return distance > 0 and distance <= range and (rowDiff == 0 or colDiff == 0)
end

local function collectMapCells(positionMap)
    local byKey = {}
    local result = {}
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
            local key = cell.key or cellKey(cell)
            if not byKey[key] then
                byKey[key] = cell
                result[#result + 1] = cell
            end
        end
    end
    return result
end

local function ownCoverExists(ai, state, playerId, cell, ignoredCoverKey)
    for _, unit in ipairs((state and state.units) or {}) do
        local key = cellKey(unit)
        if unit
            and key ~= ignoredCoverKey
            and key ~= cellKey(cell)
            and unit.player == playerId
            and isAlive(unit)
            and not isHub(ai, unit)
            and canAttackCellFrom(ai, state, unit, unit, cell) then
            return true
        end
    end
    return false
end

local function sortCells(list)
    table.sort(list, function(a, b)
        if num(a and a.value, 0) == num(b and b.value, 0) then
            return tostring(a and (a.key or cellKey(a)) or "") < tostring(b and (b.key or cellKey(b)) or "")
        end
        return num(a and a.value, 0) > num(b and b.value, 0)
    end)
end

local function buildPostDeployMap(ai, afterDeploy, ctx, positionMap, deploy)
    local playerId = ctx and ctx.aiPlayer or 1
    local deployedKey = deploy and deploy.target and cellKey(deploy.target) or nil
    local map = {
        ownedUncovered = {},
        ownedCovered = {},
        freeTargets = {},
        nextExpansion = {},
        freeTop = {},
        top = {}
    }

    for _, original in ipairs(collectMapCells(positionMap)) do
        local row = num(original.row, 0)
        local col = num(original.col, 0)
        local occupant = getUnitAt(afterDeploy, row, col)
        local status = original.status
        if occupant and occupant.player == playerId and isAlive(occupant) and not isHub(ai, occupant) then
            status = ownCoverExists(ai, afterDeploy, playerId, original, deployedKey)
                and "owned_covered"
                or "owned_uncovered"
        end

        local cell = cloneCell(original, status)
        map.top[#map.top + 1] = cell
        if status == "owned_uncovered" then
            map.ownedUncovered[#map.ownedUncovered + 1] = cell
        elseif status == "owned_covered" then
            map.ownedCovered[#map.ownedCovered + 1] = cell
        elseif status == "free_target" then
            map.freeTargets[#map.freeTargets + 1] = cell
            map.freeTop[#map.freeTop + 1] = cell
        elseif status == "next_expansion" then
            map.nextExpansion[#map.nextExpansion + 1] = cell
            map.freeTop[#map.freeTop + 1] = cell
        end
    end

    sortCells(map.ownedUncovered)
    sortCells(map.ownedCovered)
    sortCells(map.freeTargets)
    sortCells(map.nextExpansion)
    sortCells(map.freeTop)
    sortCells(map.top)
    return map
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

local function lockedCoverSecondEnabled(ctx)
    return not (ctx
        and ctx.cfg
        and ctx.cfg.PIPELINE_V2_DEPLOY_FIRST_EARLY_SECOND_LOCKED_COVER_ENABLED == false)
end

local function formedPairReleaseEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_FORMED_PAIR_RELEASE_ENABLED == false)
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

local function targetCellForAction(map, action)
    local targetKey = action and action.target and cellKey(action.target) or nil
    if not targetKey then
        return nil
    end
    for _, list in ipairs({map and map.cells or false, map and map.freeTargets, map and map.nextExpansion, map and map.freeTop, map and map.top}) do
        for _, cell in ipairs(list or {}) do
            if (cell.key or cellKey(cell)) == targetKey then
                return cell
            end
        end
    end
    return nil
end

local function movedUnitAfter(afterState, action)
    return action and action.target and getUnitAt(afterState, num(action.target.row, -1), num(action.target.col, -1)) or nil
end

local function coverPriorityValue(cell, ctx)
    return num(cell and cell.value, 0) + earlyCellPolicy.coverUrgencyBonus(cell, ctx)
end

local function classifyCoverReposition(ai, beforeMove, afterMove, ctx, action, coveredCells)
    local moved = movedUnitAfter(afterMove, action)
    if not moved then
        return nil, 0, nil, "early_second_missing_unit_after_move"
    end
    local best = nil
    local bestValue = -math.huge
    for _, cell in ipairs(coveredCells or {}) do
        if not canAttackCellFrom(ai, afterMove, moved, moved, cell) then
            return nil, 0, nil, "early_second_breaks_resolved_cover"
        end
        local priority = coverPriorityValue(cell, ctx)
        if priority > bestValue then
            best = cell
            bestValue = priority
        end
    end
    if not best then
        return nil, 0, nil, "early_second_no_resolved_cover"
    end
    return "cover_reposition_preserves", bestValue * 0.18, best, nil
end

local function classifyCoverTarget(ai, beforeMove, afterMove, ctx, action, coverTargets)
    local moved = movedUnitAfter(afterMove, action)
    if not moved then
        return nil, 0, nil, "early_second_missing_unit_after_move"
    end
    local best = nil
    local bestScore = -math.huge
    for _, cell in ipairs(coverTargets or {}) do
        if canAttackCellFrom(ai, afterMove, moved, moved, cell)
            and not canAttackCellFrom(ai, beforeMove, action.unit, action.unit, cell) then
            local score = coverPriorityValue(cell, ctx) + 220 - (manhattan(action.target, cell) * 12)
            if score > bestScore then
                best = cell
                bestScore = score
            end
        end
    end
    if not best then
        return nil, 0, nil, "early_second_not_covering_target"
    end
    return "cover_target", bestScore, best, nil
end

local function classifyFreeExpansion(map, action, ctx)
    local target = targetCellForAction(map, action)
    if not target then
        return nil, 0, nil, "early_second_target_not_strategic"
    end
    if not earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return nil, 0, nil, "early_second_target_not_safe_strategic"
    end
    if target.status == "free_target" then
        return "free_expand", num(target.value, 0) * 0.65, target, nil
    end
    if target.status == "next_expansion" then
        return "free_expand_next", num(target.value, 0) * 0.7, target, nil
    end
    return nil, 0, nil, "early_second_target_not_free"
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

local function cellForSource(map, sourceKey)
    for _, list in ipairs({
        map and map.ownedCovered,
        map and map.ownedCoveredAll or false,
        map and map.ownedUncovered,
        map and map.ownedUncoveredAll or false,
        map and map.top
    }) do
        for _, cell in ipairs(list or {}) do
            if (cell.key or cellKey(cell)) == sourceKey then
                return cell
            end
        end
    end
    return nil
end

local function classifyRetreatMove(map, action, ctx, sourceKey)
    if not (action and action.type == "move" and sourceKey and earlyCellPolicy.requiresRetreat) then
        return nil, 0, nil, nil
    end

    local source = cellForSource(map, sourceKey)
    if not earlyCellPolicy.requiresRetreat(source, ctx) then
        return nil, 0, nil, nil
    end

    local target = targetCellForAction(map, action)
    if not target then
        return nil, 0, nil, "early_second_retreat_target_missing"
    end
    if not earlyCellPolicy.isGoodStrategicCell(target, ctx) then
        return nil, 0, nil, "early_second_retreat_target_not_safe_strategic"
    end

    local reason = target.status == "next_expansion"
        and "retreat_expand_next"
        or "retreat_to_strategic_cell"
    local distancePenalty = manhattan(action.unit, action.target) * 12
    local score = earlyCellPolicy.cellValue(target)
        + earlyCellPolicy.retreatScoreBonus(ctx)
        + math.max(0, earlyCellPolicy.cellValue(source) * 0.1)
        - distancePenalty
    return reason, score, target, nil
end

local function releaseMoveTargetScore(map, action, ctx)
    local reason, score, targetCell = classifyFreeExpansion(map, action, ctx)
    if reason then
        return reason, score, targetCell
    end

    targetCell = targetCellForAction(map, action)
    if targetCell and earlyCellPolicy.isGoodStrategicCell(targetCell, ctx) then
        return "position_map_target", earlyCellPolicy.cellValue(targetCell) * 0.28, targetCell
    end

    return "forced_step", earlyForcedMoveValue.scoreTarget(targetCell, action, ctx), targetCell
end

local function classifyFormedPairRelease(map, action, ctx, unitPool, sourceKey, coveredCells)
    if not (formedPairReleaseEnabled(ctx) and action and action.type == "move" and sourceKey) then
        return nil
    end

    if #(coveredCells or {}) > 0 then
        local releaseValue, releaseCell = lowestCellValue(coveredCells, ctx)
        local targetReason, targetScore, targetCell = releaseMoveTargetScore(map, action, ctx)
        return {
            action = action,
            reason = "release_cover_then_" .. tostring(targetReason or "forced_step"),
            score = (num(targetScore, 0) * 0.22) - (releaseValue * 0.55),
            targetCell = targetCell or releaseCell,
            releaseTier = 1,
            releaseValue = releaseValue,
            releaseCell = releaseCell
        }
    end

    if unitPool and unitPool.lockedOccupantByKey and unitPool.lockedOccupantByKey[sourceKey] then
        local releaseCell = cellForSource(map, sourceKey)
        local releaseValue = earlyCellPolicy.cellValue(releaseCell)
        local targetReason, targetScore, targetCell = releaseMoveTargetScore(map, action, ctx)
        return {
            action = action,
            reason = "release_occupant_then_" .. tostring(targetReason or "forced_step"),
            score = (num(targetScore, 0) * 0.16) - (releaseValue * 0.75),
            targetCell = targetCell or releaseCell,
            releaseTier = 2,
            releaseValue = releaseValue,
            releaseCell = releaseCell
        }
    end

    return nil
end

local function betterReleaseCandidate(candidate, current)
    if not current then
        return true
    end
    if not candidate then
        return false
    end
    if num(candidate.releaseTier, 99) ~= num(current.releaseTier, 99) then
        return num(candidate.releaseTier, 99) < num(current.releaseTier, 99)
    end
    if num(candidate.score, 0) ~= num(current.score, 0) then
        return num(candidate.score, 0) > num(current.score, 0)
    end
    if num(candidate.releaseValue, 0) ~= num(current.releaseValue, 0) then
        return num(candidate.releaseValue, 0) < num(current.releaseValue, 0)
    end
    return tostring(candidate.action and candidate.action.target and cellKey(candidate.action.target) or "")
        < tostring(current.action and current.action.target and cellKey(current.action.target) or "")
end

local function addSkip(skipped, reason)
    skipped[reason or "early_second_rejected"] = num(skipped[reason or "early_second_rejected"], 0) + 1
end

local function sequenceAccepted(options, action, reason)
    if not (options and options.sequenceValidator) then
        return true, nil
    end
    local ok, rejectReason = options.sequenceValidator(action, reason)
    if ok then
        return true, nil
    end
    return false, rejectReason or "early_second_sequence_rejected"
end

local function bestCoveredCellValue(unitPool, sourceKey)
    local best = 0
    for _, cell in ipairs((unitPool and unitPool.coveredCellsByUnitKey and unitPool.coveredCellsByUnitKey[sourceKey]) or {}) do
        best = math.max(best, earlyCellPolicy.cellValue(cell))
    end
    return best
end

local function occupantCellValue(unitPool, sourceKey)
    local cell = unitPool and unitPool.occupantCellByKey and unitPool.occupantCellByKey[sourceKey] or nil
    return earlyCellPolicy.cellValue(cell)
end

local function entryPriority(map, unitPool, deployedKey, entry, ctx)
    local action = entry and entry.action or nil
    local source = (action and action.unit) or (entry and entry.unit) or nil
    local sourceKey = source and cellKey(source) or nil
    if not sourceKey then
        return 9, 0, 0, ""
    end
    if sourceKey == deployedKey then
        return 8, 0, 0, sourceKey
    end
    local targetScore = earlyForcedMoveValue.scoreTarget(targetCellForAction(map, action), action, ctx)
    local releasable = unitPool and unitPool.releasableByKey and unitPool.releasableByKey[sourceKey] or nil
    if releasable and earlyCellPolicy.requiresRetreat and earlyCellPolicy.requiresRetreat(releasable.cell, ctx) then
        return -1, -earlyCellPolicy.cellValue(releasable.cell), targetScore, sourceKey
    end
    if unitPool and unitPool.coveredCellsByUnitKey and unitPool.coveredCellsByUnitKey[sourceKey] then
        return 1, bestCoveredCellValue(unitPool, sourceKey), targetScore, sourceKey
    end
    if unitPool and unitPool.lockedOccupantByKey and unitPool.lockedOccupantByKey[sourceKey] then
        return 7, occupantCellValue(unitPool, sourceKey), targetScore, sourceKey
    end
    if releasable then
        return 2, earlyCellPolicy.cellValue(releasable.cell), targetScore, sourceKey
    end
    return 0, num(entry and entry.cheapScore, 0) * -1, targetScore, sourceKey
end

local function sortMoveEntriesForEarlySecond(entries, unitPool, deployedKey, ctx, map)
    table.sort(entries, function(a, b)
        local ap, av, at, ak = entryPriority(map, unitPool, deployedKey, a, ctx)
        local bp, bv, bt, bk = entryPriority(map, unitPool, deployedKey, b, ctx)
        if ap ~= bp then
            return ap < bp
        end
        if av ~= bv then
            return av < bv
        end
        if at ~= bt then
            return at > bt
        end
        return tostring(ak) < tostring(bk)
    end)
end

function M.select(ai, beforeState, afterFirstState, ctx, positionMap, firstAction, opts)
    local options = opts or {}
    local scanCap = math.max(0, num(options.scanCap, 8))
    local stats = {
        scanned = 0,
        accepted = 0,
        moveRiskPenalized = 0,
        moveRiskPenaltyMax = 0,
        moveRiskLethal = 0,
        moveRiskSuicidal = 0,
        skippedReasons = {},
        reasonCounts = {}
    }
    if scanCap <= 0 or not (afterFirstState and firstAction and firstAction.type == "supply_deploy") then
        return nil, stats
    end

    local deployedKey = firstAction.target and cellKey(firstAction.target) or nil
    local postMap = buildPostDeployMap(ai, afterFirstState, ctx, positionMap, firstAction)
    local ignoreCover = {}
    if deployedKey then
        ignoreCover[deployedKey] = true
    end
    local unitPool = earlyPositionUnits.classify(ai, afterFirstState, ctx, postMap, {
        ignoreCoverUnitKeys = ignoreCover
    })
    local agenda = earlyPositionSequence.build(postMap, ctx)
    local entries = collectMoveEntries(ai, afterFirstState, ctx)
    sortMoveEntriesForEarlySecond(entries, unitPool, deployedKey, ctx, postMap)
    local best = nil
    local releaseBest = nil

    for _, entry in ipairs(entries) do
        if stats.scanned >= scanCap then
            break
        end
        local move = moveActionWithEntryUnit(entry)
        if move and move.type == "move" then
            stats.scanned = stats.scanned + 1
            local sourceKey = move.unit and cellKey(move.unit) or nil
            local reason, score, targetCell, skipReason = nil, 0, nil, nil
            local releaseItem = nil
            local afterMove = nil

            if sourceKey == deployedKey then
                skipReason = "early_second_deployed_unit_unavailable"
            else
                local coveredCells = unitPool.coveredCellsByUnitKey[sourceKey] or {}
                local sourceLocked = unitPool.lockedOccupantByKey[sourceKey] ~= nil
                local lockedCoverAllowed = lockedCoverSecondEnabled(ctx) and #coveredCells > 0
                if sourceLocked and not lockedCoverAllowed then
                    skipReason = "early_second_source_locked_occupant"
                    releaseItem =
                        classifyFormedPairRelease(postMap, move, ctx, unitPool, sourceKey, coveredCells)
                else
                    afterMove = ctx.cache.simulate(ai, afterFirstState, {move}, ctx.aiPlayer, ctx)
                    reason, score, targetCell, skipReason =
                        classifyRetreatMove(postMap, move, ctx, sourceKey)
                    if not reason and not skipReason and #coveredCells > 0 then
                        local preserveReason, preserveScore, preserveCell, preserveSkip =
                            classifyCoverReposition(ai, afterFirstState, afterMove, ctx, move, coveredCells)
                        if preserveReason then
                            local coverReason, coverScore, coverCell =
                                classifyCoverTarget(ai, afterFirstState, afterMove, ctx, move, unitPool.coverTargets)
                            if coverReason then
                                reason = preserveReason .. "_then_" .. coverReason
                                score = preserveScore + (coverScore * 0.45)
                                targetCell = coverCell
                            else
                                local expandReason, expandScore, expandCell =
                                    classifyFreeExpansion(postMap, move, ctx)
                                if expandReason then
                                    reason = preserveReason .. "_then_" .. expandReason
                                    score = preserveScore + (expandScore * 0.35)
                                    targetCell = expandCell
                                else
                                    reason = preserveReason
                                    score = preserveScore
                                    targetCell = preserveCell
                                end
                            end
                        else
                            skipReason = preserveSkip
                        end
                    elseif not reason and not skipReason then
                        local coverReason, coverScore, coverCell, coverSkip =
                            classifyCoverTarget(ai, afterFirstState, afterMove, ctx, move, unitPool.coverTargets)
                        if coverReason then
                            reason = coverReason
                            score = coverScore
                            targetCell = coverCell
                        else
                            reason, score, targetCell, skipReason = classifyFreeExpansion(postMap, move, ctx)
                            if not reason then
                                skipReason = skipReason or coverSkip
                            end
                        end
                    end
                    if not reason then
                        releaseItem =
                            classifyFormedPairRelease(postMap, move, ctx, unitPool, sourceKey, coveredCells)
                    end
                end
            end

            if reason then
                local acceptedBySequence, rejectReason = sequenceAccepted(options, move, reason)
                if acceptedBySequence then
                    stats.accepted = stats.accepted + 1
                    stats.reasonCounts[reason] = num(stats.reasonCounts[reason], 0) + 1
                    local risk = earlyMoveRisk.analyze(ai, afterFirstState, afterMove, ctx, move)
                    local adjustedScore = earlyMoveRisk.applyToScore(score
                        + earlyPositionSequence.bonusForTarget(agenda, targetCell, reason) * 0.25
                        + num(entry and entry.cheapScore, 0) * 0.08,
                        risk,
                        stats)
                    adjustedScore = movePatternPenalty.adjustScore(ai, afterFirstState, ctx, move, adjustedScore, stats)
                    local item = {
                        action = move,
                        reason = reason,
                        score = adjustedScore,
                        targetCell = targetCell,
                        moveRisk = risk
                    }
                    if not best or num(item.score, 0) > num(best.score, 0) then
                        best = item
                    end
                else
                    addSkip(stats.skippedReasons, rejectReason)
                end
            elseif releaseItem then
                local acceptedBySequence, rejectReason = sequenceAccepted(options, move, releaseItem.reason)
                if acceptedBySequence then
                    stats.accepted = stats.accepted + 1
                    stats.reasonCounts[releaseItem.reason] = num(stats.reasonCounts[releaseItem.reason], 0) + 1
                    afterMove = afterMove or ctx.cache.simulate(ai, afterFirstState, {move}, ctx.aiPlayer, ctx)
                    local risk = earlyMoveRisk.analyze(ai, afterFirstState, afterMove, ctx, move)
                    releaseItem.score = earlyMoveRisk.applyToScore(num(releaseItem.score, 0)
                        + earlyPositionSequence.bonusForTarget(agenda, releaseItem.targetCell, releaseItem.reason) * 0.1
                        + num(entry and entry.cheapScore, 0) * 0.04,
                        risk,
                        stats)
                    releaseItem.score = movePatternPenalty.adjustScore(
                        ai,
                        afterFirstState,
                        ctx,
                        move,
                        releaseItem.score,
                        stats
                    )
                    releaseItem.moveRisk = risk
                    if betterReleaseCandidate(releaseItem, releaseBest) then
                        releaseBest = releaseItem
                    end
                else
                    addSkip(stats.skippedReasons, rejectReason)
                end
            else
                addSkip(stats.skippedReasons, skipReason)
            end
        end
    end

    return best or releaseBest, stats
end

M._private = {
    buildPostDeployMap = buildPostDeployMap,
    cellKey = cellKey,
    canAttackCellFrom = canAttackCellFrom,
    sortMoveEntriesForEarlySecond = sortMoveEntriesForEarlySecond
}

return M
