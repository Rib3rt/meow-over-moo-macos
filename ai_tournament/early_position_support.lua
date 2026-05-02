local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
local punishMap = require("ai_tournament.punish_map")

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

local function enabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_STRICT_SUPPORT_COVER_ENABLED == false)
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
        if unit and num(unit.row, -1) == num(row, -2) and num(unit.col, -1) == num(col, -2) then
            return unit
        end
    end
    return nil
end

local function mapCellsByKey(positionMap)
    local out = {}
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
            out[cell.key or cellKey(cell)] = cell
        end
    end
    return out
end

local function supportSourceUnit(action)
    if not action then
        return nil
    end
    if action.type == "supply_deploy" then
        return action.unit or {
            name = action.unitName,
            player = action.player,
            currentHp = action.currentHp or action.startingHp,
            startingHp = action.startingHp or action.currentHp
        }
    end
    return action.unit
end

local function canCoverFrom(ai, state, unit, fromCell, targetCell)
    if not (unit and fromCell and targetCell) then
        return false
    end
    local priv = punishMap and punishMap._private or {}
    if priv.canAttackCellFrom then
        return priv.canAttackCellFrom(ai, state, unit, fromCell, targetCell, {allowEmptyTarget = true}) == true
    end

    local rowDiff = math.abs(num(fromCell.row, 0) - num(targetCell.row, 0))
    local colDiff = math.abs(num(fromCell.col, 0) - num(targetCell.col, 0))
    local distance = rowDiff + colDiff
    local range = num(unit.atkRange or unit.range, 1)
    return distance > 0 and distance <= range and (rowDiff == 0 or colDiff == 0)
end

local function supportedCellFor(positionMap, supportCell)
    local supportKey = supportCell and (supportCell.earlySupportForKey or supportCell.supportForKey) or nil
    if not supportKey then
        return nil
    end
    return mapCellsByKey(positionMap)[supportKey]
end

local function occupiedHoldCell(ai, state, ctx, supportedCell)
    if not supportedCell then
        return nil
    end
    local playerId = ctx and ctx.aiPlayer or 1
    local occupant = getUnitAt(state, supportedCell.row, supportedCell.col)
    if not (occupant and occupant.player == playerId and isAlive(occupant) and not isHub(ai, occupant)) then
        return nil
    end

    local cell = {}
    for key, value in pairs(supportedCell) do
        cell[key] = value
    end
    cell.status = cell.status == "owned_covered" and "owned_covered" or "owned_uncovered"
    cell.occupiedByUs = true
    cell.occupantHp = occupant.currentHp or occupant.startingHp
    return cell
end

function M.supportedCell(positionMap, supportCell)
    return supportedCellFor(positionMap, supportCell)
end

function M.isUsefulSupportAction(ai, state, ctx, positionMap, supportCell, action)
    if not enabled(ctx) then
        return true
    end
    if not (supportCell and action and action.target) then
        return false, "support_missing_action"
    end
    if tostring(supportCell.earlyFrontierRole or supportCell.frontierRole or "") ~= "support_cover" then
        return false, "support_not_frontier_cover"
    end

    local supportedCell = supportedCellFor(positionMap, supportCell)
    local holdCell = occupiedHoldCell(ai, state, ctx, supportedCell)
    if not holdCell then
        return false, "support_target_not_occupied"
    end
    if not earlyCellPolicy.isHoldableOccupiedStrategicCell(holdCell, ctx, {ignorePrimaryTarget = true}) then
        return false, "support_target_not_holdable"
    end

    local unit = supportSourceUnit(action)
    if not canCoverFrom(ai, state, unit, action.target, supportedCell) then
        return false, "support_action_does_not_cover"
    end

    return true, nil, supportedCell
end

return M
