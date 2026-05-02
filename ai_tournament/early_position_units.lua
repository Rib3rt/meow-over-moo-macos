local punishMap = require("ai_tournament.punish_map")
local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")

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

local function unitKey(unit)
    return cellKey(unit)
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

local function getUnitAt(state, row, col)
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    return nil
end

local function ownBoardUnits(ai, state, playerId)
    local result = {}
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == playerId and isAlive(unit) and not isHub(ai, unit) then
            result[#result + 1] = unit
        end
    end
    return result
end

local function pushSummary(list, unit, reason, cell)
    list[#list + 1] = table.concat({
        tostring(unit and unit.name or "?") .. "@" .. cellKey(unit),
        tostring(reason or "free"),
        cell and cellKey(cell) or "none"
    }, ":")
end

local function pushCellSummary(list, unit, reason, cell)
    list[#list + 1] = table.concat({
        tostring(unit and unit.name or "?") .. "@" .. cellKey(unit),
        tostring(reason or "releasable"),
        cell and cellKey(cell) or "none",
        tostring(math.floor(earlyCellPolicy.cellValue(cell)))
    }, ":")
end

local function sortSummaries(list)
    table.sort(list, function(a, b)
        return tostring(a) < tostring(b)
    end)
end

local function isOwnedCellHoldable(cell, ctx, options)
    if earlyCellPolicy.isHoldableOccupiedStrategicCell then
        return earlyCellPolicy.isHoldableOccupiedStrategicCell(cell, ctx, options)
    end
    return earlyCellPolicy.isGoodStrategicCell(cell, ctx, options)
end

function M.classify(ai, state, ctx, positionMap, opts)
    local options = opts or {}
    local playerId = ctx and ctx.aiPlayer or 1
    local ignoreCoverUnitKeys = options.ignoreCoverUnitKeys or {}
    local lockedOccupantByKey = {}
    local lockedCoverByKey = {}
    local releasableByKey = {}
    local freeByKey = {}
    local occupantCellByKey = {}
    local coveredCellsByUnitKey = {}
    local lockedOccupants = {}
    local lockedCoverUnits = {}
    local freeUnits = {}
    local coverTargets = {}
    local resolvedCells = {}
    local releasableOccupants = {}
    local lockedOccupantSummaries = {}
    local lockedCoverSummaries = {}
    local freeSummaries = {}
    local releasableSummaries = {}

    for _, cell in ipairs(positionMap and (positionMap.ownedUncoveredAll or positionMap.ownedUncovered) or {}) do
        local unit = getUnitAt(state, cell.row, cell.col)
        if unit and unit.player == playerId and isAlive(unit) and not isHub(ai, unit) then
            local key = unitKey(unit)
            occupantCellByKey[key] = occupantCellByKey[key] or cell
            if isOwnedCellHoldable(cell, ctx, options) then
                coverTargets[#coverTargets + 1] = cell
                if not lockedOccupantByKey[key] then
                    lockedOccupantByKey[key] = "owned_uncovered"
                    lockedOccupants[#lockedOccupants + 1] = unit
                    pushSummary(lockedOccupantSummaries, unit, "owned_uncovered", cell)
                end
            else
                local reason = earlyCellPolicy.rejectReason(cell, ctx, options) or "not_strategic"
                releasableByKey[key] = {
                    unit = unit,
                    cell = cell,
                    reason = reason
                }
                releasableOccupants[#releasableOccupants + 1] = {
                    unit = unit,
                    cell = cell,
                    reason = reason
                }
                pushCellSummary(
                    releasableSummaries,
                    unit,
                    "releasable_" .. tostring(reason),
                    cell
                )
            end
        end
    end

    for _, cell in ipairs(positionMap and (positionMap.ownedCoveredAll or positionMap.ownedCovered) or {}) do
        local occupant = getUnitAt(state, cell.row, cell.col)
        if occupant and occupant.player == playerId and isAlive(occupant) and not isHub(ai, occupant) then
            local key = unitKey(occupant)
            occupantCellByKey[key] = occupantCellByKey[key] or cell
            if isOwnedCellHoldable(cell, ctx, options) then
                resolvedCells[#resolvedCells + 1] = cell
                if not lockedOccupantByKey[key] then
                    lockedOccupantByKey[key] = "owned_covered"
                    lockedOccupants[#lockedOccupants + 1] = occupant
                    pushSummary(lockedOccupantSummaries, occupant, "owned_covered", cell)
                end

                for _, unit in ipairs(ownBoardUnits(ai, state, playerId)) do
                    local coverKey = unitKey(unit)
                    if not ignoreCoverUnitKeys[coverKey]
                        and coverKey ~= cellKey(cell)
                        and canAttackCellFrom(ai, state, unit, unit, cell) then
                        coveredCellsByUnitKey[coverKey] = coveredCellsByUnitKey[coverKey] or {}
                        coveredCellsByUnitKey[coverKey][#coveredCellsByUnitKey[coverKey] + 1] = cell
                        if not lockedCoverByKey[coverKey] then
                            lockedCoverByKey[coverKey] = true
                            lockedCoverUnits[#lockedCoverUnits + 1] = unit
                            pushSummary(lockedCoverSummaries, unit, "covers_resolved", cell)
                        end
                    end
                end
            else
                local reason = earlyCellPolicy.rejectReason(cell, ctx, options) or "not_strategic"
                releasableByKey[key] = {
                    unit = occupant,
                    cell = cell,
                    reason = reason
                }
                releasableOccupants[#releasableOccupants + 1] = {
                    unit = occupant,
                    cell = cell,
                    reason = reason
                }
                pushCellSummary(
                    releasableSummaries,
                    occupant,
                    "releasable_" .. tostring(reason),
                    cell
                )
            end
        end
    end

    if next(lockedCoverByKey) ~= nil then
        local filteredReleasable = {}
        releasableSummaries = {}
        for _, item in ipairs(releasableOccupants) do
            local key = unitKey(item and item.unit)
            local urgentRetreat = earlyCellPolicy.requiresRetreat
                and earlyCellPolicy.requiresRetreat(item and item.cell, ctx)
            if lockedCoverByKey[key] and not urgentRetreat then
                releasableByKey[key] = nil
            else
                filteredReleasable[#filteredReleasable + 1] = item
                pushCellSummary(
                    releasableSummaries,
                    item and item.unit,
                    "releasable_" .. tostring(item and item.reason or "not_strategic"),
                    item and item.cell
                )
            end
        end
        releasableOccupants = filteredReleasable
    end

    table.sort(releasableOccupants, function(a, b)
        local av = earlyCellPolicy.cellValue(a and a.cell)
        local bv = earlyCellPolicy.cellValue(b and b.cell)
        if av == bv then
            return cellKey(a and a.cell) < cellKey(b and b.cell)
        end
        return av < bv
    end)

    for _, unit in ipairs(ownBoardUnits(ai, state, playerId)) do
        local key = unitKey(unit)
        if not lockedOccupantByKey[key] and not lockedCoverByKey[key] then
            freeByKey[key] = true
            freeUnits[#freeUnits + 1] = unit
            pushSummary(freeSummaries, unit, "free", nil)
        end
    end

    sortSummaries(lockedOccupantSummaries)
    sortSummaries(lockedCoverSummaries)
    sortSummaries(freeSummaries)
    sortSummaries(releasableSummaries)

    return {
        freeUnits = freeUnits,
        lockedOccupants = lockedOccupants,
        lockedCoverUnits = lockedCoverUnits,
        releasableOccupants = releasableOccupants,
        lockedOccupantByKey = lockedOccupantByKey,
        lockedCoverByKey = lockedCoverByKey,
        releasableByKey = releasableByKey,
        freeByKey = freeByKey,
        occupantCellByKey = occupantCellByKey,
        coveredCellsByUnitKey = coveredCellsByUnitKey,
        coverTargets = coverTargets,
        resolvedCells = resolvedCells,
        summaries = {
            free = freeSummaries,
            lockedOccupants = lockedOccupantSummaries,
            lockedCoverUnits = lockedCoverSummaries,
            releasableOccupants = releasableSummaries
        }
    }
end

M._private = {
    cellKey = cellKey,
    unitKey = unitKey,
    canAttackCellFrom = canAttackCellFrom
}

return M
