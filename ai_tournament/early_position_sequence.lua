local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")

local M = {}

local ACTIONABLE_STATUS = {
    free_target = true,
    next_expansion = true,
    owned_uncovered = true,
    owned_covered = true
}

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

local function sequenceEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_SEQUENCE_ENABLED == false)
end

local function modeForStatus(status)
    if status == "owned_covered" then
        return "resolved"
    end
    if status == "owned_uncovered" then
        return "cover"
    end
    if status == "free_target" or status == "next_expansion" then
        return "occupy"
    end
    return nil
end

local function collectCells(positionMap)
    local byKey = {}
    local cells = {}
    for _, list in ipairs({
        positionMap and positionMap.top,
        positionMap and positionMap.freeTop,
        positionMap and positionMap.freeTargets,
        positionMap and positionMap.nextExpansion,
        positionMap and positionMap.ownedUncovered,
        positionMap and positionMap.ownedCovered
    }) do
        for _, cell in ipairs(list or {}) do
            local key = cell and (cell.key or cellKey(cell)) or nil
            local status = cell and cell.status or nil
            if key and ACTIONABLE_STATUS[status] and not byKey[key] then
                byKey[key] = cell
                cells[#cells + 1] = cell
            end
        end
    end
    return cells
end

local function isActionableStrategicCell(cell, ctx)
    if cell and (cell.status == "owned_uncovered" or cell.status == "owned_covered") then
        return earlyCellPolicy.isHoldableOccupiedStrategicCell(cell, ctx)
    end
    return earlyCellPolicy.isGoodStrategicCell(cell, ctx)
end

function M.build(positionMap, ctx)
    if not sequenceEnabled(ctx) then
        return {
            items = {},
            byKey = {},
            primary = nil
        }
    end

    local cells = {}
    for _, cell in ipairs(collectCells(positionMap)) do
        if isActionableStrategicCell(cell, ctx) then
            cells[#cells + 1] = cell
        end
    end

    table.sort(cells, function(a, b)
        local av = earlyCellPolicy.cellValue(a)
        local bv = earlyCellPolicy.cellValue(b)
        if av == bv then
            return tostring(a and (a.key or cellKey(a)) or "") < tostring(b and (b.key or cellKey(b)) or "")
        end
        return av > bv
    end)

    local agenda = {
        items = {},
        byKey = {},
        primary = nil
    }
    for _, cell in ipairs(cells) do
        local mode = modeForStatus(cell.status)
        if mode then
            local item = {
                rank = #agenda.items + 1,
                key = cell.key or cellKey(cell),
                mode = mode,
                cell = cell,
                value = earlyCellPolicy.cellValue(cell)
            }
            agenda.items[#agenda.items + 1] = item
            agenda.byKey[item.key] = item
            if not agenda.primary and mode ~= "resolved" then
                agenda.primary = item
            end
        end
    end
    return agenda
end

function M.describe(item)
    if not item then
        return "none"
    end
    return table.concat({
        tostring(item.key or "?"),
        tostring(item.mode or "?"),
        tostring(math.floor(num(item.value, 0)))
    }, ":")
end

function M.bonusForTarget(agenda, targetCell, reason)
    local key = targetCell and (targetCell.key or cellKey(targetCell)) or nil
    local item = key and agenda and agenda.byKey and agenda.byKey[key] or nil
    if not item or item.mode == "resolved" then
        return 0
    end

    local rankBonus = math.max(0, 320 - ((num(item.rank, 1) - 1) * 35))
    local reasonText = tostring(reason or "")
    local modeBonus = 0
    if item.mode == "occupy" then
        if reasonText:find("occupy", 1, true)
            or reasonText:find("expand", 1, true)
            or reasonText:find("position_map_target", 1, true) then
            modeBonus = 180
        end
    elseif item.mode == "cover" then
        if reasonText:find("cover", 1, true) then
            modeBonus = 220
        else
            modeBonus = -120
        end
    end
    return rankBonus + modeBonus
end

return M
