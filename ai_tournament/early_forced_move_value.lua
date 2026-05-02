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
    return not (ctx
        and ctx.cfg
        and ctx.cfg.PIPELINE_V2_EARLY_FORCED_MOVE_VALUE_ENABLED == false)
end

local function manhattan(a, b)
    if not (a and b) then
        return 0
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function cfgNumber(ctx, key, fallback)
    return num(ctx and ctx.cfg and ctx.cfg[key], fallback)
end

local function rejectPenalty(ctx, rejectReason, cellValue)
    if not rejectReason then
        return 0
    end
    local base = cfgNumber(ctx, "PIPELINE_V2_EARLY_FORCED_MOVE_REJECT_PENALTY", 160)
    if rejectReason == "low_value" then
        return math.max(base * 0.4, earlyCellPolicy.minStrategicValue(ctx) - num(cellValue, 0))
    end
    if rejectReason == "enemy_attack"
        or rejectReason == "enemy_move_attack"
        or rejectReason == "enemy_punish"
        or rejectReason == "attack_contested" then
        return base * 2
    end
    return base
end

local function ownedCellChurnPenalty(ctx, targetCell)
    local status = tostring(targetCell and targetCell.status or "")
    if status == "owned_uncovered" or status == "owned_covered" then
        return cfgNumber(ctx, "PIPELINE_V2_EARLY_FORCED_MOVE_OWNED_CELL_CHURN_PENALTY", 240)
    end
    return 0
end

function M.enabled(ctx)
    return enabled(ctx)
end

function M.scoreTarget(targetCell, action, ctx)
    if not enabled(ctx) then
        return 0, nil
    end
    if not targetCell then
        return -cfgNumber(ctx, "PIPELINE_V2_EARLY_FORCED_MOVE_MISSING_TARGET_PENALTY", 260),
            "missing_target"
    end

    local value = earlyCellPolicy.cellValue(targetCell)
    local rejectReason = earlyCellPolicy.rejectReason(targetCell, ctx)
    local score = value - rejectPenalty(ctx, rejectReason, value)
    score = score - ownedCellChurnPenalty(ctx, targetCell)
    score = score - manhattan(action and action.unit, action and action.target)
        * cfgNumber(ctx, "PIPELINE_V2_EARLY_FORCED_MOVE_DISTANCE_WEIGHT", 12)
    return score, rejectReason
end

return M
