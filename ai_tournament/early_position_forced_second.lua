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

local function coverPriorityValue(cell, ctx)
    return earlyCellPolicy.cellValue(cell) + earlyCellPolicy.coverUrgencyBonus(cell, ctx)
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

local function bestCoveredCellValue(cells, ctx)
    local best = 0
    for _, cell in ipairs(cells or {}) do
        best = math.max(best, coverPriorityValue(cell, ctx))
    end
    return best
end

local function usedUnitKey(firstAction)
    if not firstAction then
        return nil
    end
    if firstAction.target then
        return cellKey(firstAction.target)
    end
    if firstAction.unit then
        return cellKey(firstAction.unit)
    end
    return nil
end

local function sourceTier(unitPool, sourceKey, usedKey, entry, ctx)
    if not sourceKey then
        return 99, 0, "missing_source"
    end
    if usedKey and sourceKey == usedKey then
        return 99, 0, "used_unit"
    end
    if unitPool and unitPool.freeByKey and unitPool.freeByKey[sourceKey] then
        return 0, num(entry and entry.cheapScore, 0) * -0.01, "free"
    end
    local releasable = unitPool and unitPool.releasableByKey and unitPool.releasableByKey[sourceKey] or nil
    if releasable and earlyCellPolicy.requiresRetreat and earlyCellPolicy.requiresRetreat(releasable.cell, ctx) then
        return -1, -earlyCellPolicy.cellValue(releasable.cell), "releasable"
    end
    local covered = unitPool and unitPool.coveredCellsByUnitKey and unitPool.coveredCellsByUnitKey[sourceKey] or nil
    if covered and #covered > 0 then
        local value = lowestCellValue(covered, ctx)
        return 2, value, "cover"
    end
    if releasable then
        return 1, earlyCellPolicy.cellValue(releasable.cell), "releasable"
    end
    local occupied = unitPool and unitPool.occupantCellByKey and unitPool.occupantCellByKey[sourceKey] or nil
    if unitPool and unitPool.lockedOccupantByKey and unitPool.lockedOccupantByKey[sourceKey] then
        return 3, earlyCellPolicy.cellValue(occupied), "occupant"
    end
    return 0, num(entry and entry.cheapScore, 0) * -0.01, "free"
end

local function ownNonHubAt(ai, state, playerId, cell)
    local unit = getUnitAt(state, num(cell and cell.row, -1), num(cell and cell.col, -1))
    return unit and unit.player == playerId and isAlive(unit) and not isHub(ai, unit)
end

local function bestCoverTarget(ai, beforeState, afterState, ctx, unitPool, action)
    if not (afterState and action and action.target) then
        return nil, 0
    end
    local moved = getUnitAt(afterState, num(action.target.row, -1), num(action.target.col, -1))
    if not moved then
        return nil, 0
    end
    local playerId = ctx and ctx.aiPlayer or 1
    local best = nil
    local bestScore = -math.huge
    for _, cell in ipairs(unitPool and unitPool.coverTargets or {}) do
        if ownNonHubAt(ai, beforeState, playerId, cell)
            and canAttackCellFrom(ai, afterState, moved, moved, cell) then
            local score = coverPriorityValue(cell, ctx) + 120 - manhattan(action.target, cell) * 10
            if score > bestScore then
                best = cell
                bestScore = score
            end
        end
    end
    return best, bestScore
end

local function preservesCoveredCells(ai, afterState, action, coveredCells)
    if #(coveredCells or {}) == 0 then
        return true
    end
    local moved = getUnitAt(afterState, num(action and action.target and action.target.row, -1), num(action and action.target and action.target.col, -1))
    if not moved then
        return false
    end
    for _, cell in ipairs(coveredCells or {}) do
        if not canAttackCellFrom(ai, afterState, moved, moved, cell) then
            return false
        end
    end
    return true
end

local function targetReasonAndScore(targetCell, tierName, ctx)
    if not (targetCell and earlyCellPolicy.isGoodStrategicCell(targetCell, ctx)) then
        return nil, 0
    end
    if targetCell.status == "free_target" then
        return "complete_forced_" .. tierName .. "_free_target", earlyCellPolicy.cellValue(targetCell) * 0.5
    end
    if targetCell.status == "next_expansion" then
        return "complete_forced_" .. tierName .. "_next_expansion", earlyCellPolicy.cellValue(targetCell) * 0.48
    end
    return "complete_forced_" .. tierName .. "_position", earlyCellPolicy.cellValue(targetCell) * 0.2
end

local function classifyForcedMove(ai, beforeState, afterState, ctx, positionMap, unitPool, item)
    local action = item and item.action or nil
    if not (action and action.type == "move") then
        return nil
    end

    local tierName = item.tierName or "free"
    local sourceValue = num(item.sourceValue, 0)
    local targetCell = targetCellForAction(positionMap, action)
    local reason, score = targetReasonAndScore(targetCell, tierName, ctx)
    if reason then
        return {
            action = action,
            reason = reason,
            score = score - manhattan(action.unit, action.target) * 8 + num(item.cheapScore, 0) * 0.03,
            targetCell = targetCell
        }
    end

    local coverTarget, coverScore = bestCoverTarget(ai, beforeState, afterState, ctx, unitPool, action)
    if coverTarget then
        return {
            action = action,
            reason = "complete_forced_" .. tierName .. "_cover_target",
            score = coverScore - sourceValue * 0.12 + num(item.cheapScore, 0) * 0.03,
            targetCell = coverTarget
        }
    end

    local covered = unitPool and unitPool.coveredCellsByUnitKey and unitPool.coveredCellsByUnitKey[item.sourceKey] or {}
    if #covered > 0 and preservesCoveredCells(ai, afterState, action, covered) then
        local _, releaseCell = lowestCellValue(covered, ctx)
        return {
            action = action,
            reason = "complete_forced_cover_reposition",
            score = bestCoveredCellValue(covered, ctx) * 0.12 - sourceValue * 0.25 + num(item.cheapScore, 0) * 0.02,
            targetCell = releaseCell
        }
    end

    local penaltyByTier = ({
        free = 0.04,
        releasable = 0.18,
        cover = 0.65,
        occupant = 0.9
    })[tierName] or 0.25
    local forcedTargetScore = earlyForcedMoveValue.scoreTarget(targetCell, action, ctx)
    return {
        action = action,
        reason = "complete_forced_" .. tierName .. "_step",
        score = forcedTargetScore * 0.2
            - sourceValue * penaltyByTier
            - manhattan(action.unit, action.target) * 6
            + num(item.cheapScore, 0) * 0.02,
        targetCell = targetCell
    }
end

local function addSkip(stats, reason)
    local key = tostring(reason or "forced_second_rejected")
    stats.skippedReasons[key] = num(stats.skippedReasons[key], 0) + 1
end

local function sequenceAccepted(options, action, reason)
    if not (options and options.sequenceValidator) then
        return true, nil
    end
    local ok, rejectReason = options.sequenceValidator(action, reason)
    if ok then
        return true, nil
    end
    return false, rejectReason or "forced_second_sequence_rejected"
end

function M.select(ai, beforeState, afterFirstState, ctx, positionMap, firstAction, opts)
    local options = opts or {}
    local scanCap = math.max(0, num(options.scanCap, 6))
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
    if scanCap <= 0 or not (afterFirstState and firstAction) then
        return nil, stats
    end

    local ignoreCover = {}
    local usedKey = usedUnitKey(firstAction)
    if firstAction.type == "supply_deploy" and usedKey then
        ignoreCover[usedKey] = true
    end
    local unitPool = earlyPositionUnits.classify(ai, afterFirstState, ctx, positionMap, {
        ignoreCoverUnitKeys = ignoreCover
    })
    local agenda = earlyPositionSequence.build(positionMap, ctx)
    local entries = collectMoveEntries(ai, afterFirstState, ctx)
    local items = {}
    for _, entry in ipairs(entries) do
        local move = moveActionWithEntryUnit(entry)
        local sourceKey = move and move.unit and cellKey(move.unit) or nil
        local tier, sourceValue, tierName = sourceTier(unitPool, sourceKey, usedKey, entry, ctx)
        if tier < 99 then
            local targetCell = targetCellForAction(positionMap, move)
            local targetValue = targetCell and earlyCellPolicy.isGoodStrategicCell(targetCell, ctx)
                and earlyCellPolicy.cellValue(targetCell)
                or earlyForcedMoveValue.scoreTarget(targetCell, move, ctx)
            items[#items + 1] = {
                entry = entry,
                action = move,
                sourceKey = sourceKey,
                tier = tier,
                sourceValue = sourceValue,
                tierName = tierName,
                targetValue = targetValue,
                targetKey = targetCell and (targetCell.key or cellKey(targetCell)) or "",
                cheapScore = num(entry and entry.cheapScore, 0)
            }
        else
            addSkip(stats, tierName)
        end
    end

    table.sort(items, function(a, b)
        if a.tier ~= b.tier then
            return a.tier < b.tier
        end
        if a.sourceValue ~= b.sourceValue then
            return a.sourceValue < b.sourceValue
        end
        if a.targetValue ~= b.targetValue then
            return a.targetValue > b.targetValue
        end
        if a.cheapScore ~= b.cheapScore then
            return a.cheapScore > b.cheapScore
        end
        return tostring(a.sourceKey) .. tostring(a.targetKey) < tostring(b.sourceKey) .. tostring(b.targetKey)
    end)

    local best = nil
    for _, item in ipairs(items) do
        if stats.scanned >= scanCap then
            break
        end
        stats.scanned = stats.scanned + 1
        local afterMove = ctx and ctx.cache and ctx.cache.simulate
            and ctx.cache.simulate(ai, afterFirstState, {item.action}, ctx.aiPlayer, ctx)
            or nil
        if afterMove then
            local candidate = classifyForcedMove(ai, afterFirstState, afterMove, ctx, positionMap, unitPool, item)
            if candidate then
                local acceptedBySequence, rejectReason = sequenceAccepted(options, item.action, candidate.reason)
                if acceptedBySequence then
                    local risk = earlyMoveRisk.analyze(ai, afterFirstState, afterMove, ctx, item.action)
                    candidate.score = earlyMoveRisk.applyToScore(
                        num(candidate.score, 0)
                            + earlyPositionSequence.bonusForTarget(agenda, candidate.targetCell, candidate.reason) * 0.08,
                        risk,
                        stats
                    )
                    candidate.score = movePatternPenalty.adjustScore(ai, afterFirstState, ctx, item.action, candidate.score, stats)
                    candidate.moveRisk = risk
                    stats.accepted = stats.accepted + 1
                    stats.reasonCounts[candidate.reason] = num(stats.reasonCounts[candidate.reason], 0) + 1
                    if not best or num(candidate.score, 0) > num(best.score, 0) then
                        best = candidate
                    end
                else
                    addSkip(stats, rejectReason)
                end
            else
                addSkip(stats, "forced_second_unclassified")
            end
        else
            addSkip(stats, "forced_second_simulation_failed")
        end
    end

    return best, stats
end

return M
