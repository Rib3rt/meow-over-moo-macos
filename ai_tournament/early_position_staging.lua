local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function enabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_STAGING_ENABLED == false)
end

local function stagingRole(cell)
    local role = tostring(cell and (cell.earlyFrontierRole or cell.frontierRole) or "")
    return role == "support_cover" or role == "rear_support"
end

function M.isStagingCell(cell, ctx)
    if not (enabled(ctx) and cell and cell.earlyPrimaryTarget == false and stagingRole(cell)) then
        return false
    end
    return earlyCellPolicy.isGoodStrategicCell(cell, ctx, {ignorePrimaryTarget = true})
end

function M.score(cell, valueScale, coverScale)
    return earlyCellPolicy.cellValue(cell) * num(valueScale, 0.08)
        + num(cell and cell.earlyCoverValueBonus, 0) * num(coverScale, 0.06)
end

return M
