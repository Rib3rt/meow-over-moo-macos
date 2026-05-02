local M = {}

local DEFAULT_MAX_SLACK = 3

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clamp(value, minValue, maxValue)
    local n = num(value, 0)
    if n < minValue then
        return minValue
    end
    if n > maxValue then
        return maxValue
    end
    return n
end

local function gridSize(state)
    return num(state and state.gridSize, 8)
end

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function enabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.EARLY_FIRE_LANE_ENABLED == false)
end

local function maxSlack(ctx)
    return math.max(0, num(ctx and ctx.cfg and ctx.cfg.EARLY_FIRE_LANE_ROUTE_MAX_SLACK, DEFAULT_MAX_SLACK))
end

local function unitNeedsFireLane(unit)
    local name = tostring(unit and unit.name or "")
    return name == "Cloudstriker"
end

local function unitLikesFireLane(unit)
    local name = tostring(unit and unit.name or "")
    return name == "Cloudstriker" or name == "Artillery"
end

local function routeContext(state, ctx)
    local playerId = ctx and ctx.aiPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or (playerId == 1 and 2 or 1)
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    local distance = math.max(1, manhattan(ownHub, enemyHub))
    return ownHub, enemyHub, distance
end

local function routeFit(cell, ownHub, enemyHub, hubDistance, ctx)
    local slack = math.max(0, manhattan(ownHub, cell) + manhattan(cell, enemyHub) - hubDistance)
    local slackCap = maxSlack(ctx)
    if slack <= 0 then
        return 1, slack
    end
    if slackCap <= 0 then
        return 0, slack
    end
    return clamp(1 - (slack / slackCap), 0, 1), slack
end

local function fallbackCanAttack(ai, state, unit, fromCell, targetCell)
    if not (unit and fromCell and targetCell) then
        return false
    end
    local distance = manhattan(fromCell, targetCell)
    local range = num(unit.atkRange or unit.range, 1)
    if distance <= 0 or distance > range then
        return false
    end
    if fromCell.row ~= targetCell.row and fromCell.col ~= targetCell.col then
        return false
    end
    local name = tostring(unit.name or "")
    if (name == "Cloudstriker" or name == "Artillery") and distance < 2 then
        return false
    end
    return true
end

function M.score(state, ai, ctx, unit, cell, opts)
    opts = opts or {}
    if not (enabled(ctx) and unit and cell) then
        return {
            score = 0,
            controlledCount = 0,
            required = unitNeedsFireLane(unit),
            deadLane = false,
            reason = "disabled_or_missing"
        }
    end

    local ownHub, enemyHub, hubDistance = routeContext(state, ctx)
    if not (ownHub and enemyHub) then
        return {
            score = 0,
            controlledCount = 0,
            required = unitNeedsFireLane(unit),
            deadLane = false,
            reason = "missing_hub"
        }
    end

    local projected = {}
    for key, value in pairs(unit or {}) do
        projected[key] = value
    end
    projected.row = cell.row
    projected.col = cell.col

    local canAttack = opts.canAttackCellFrom or fallbackCanAttack
    local size = gridSize(state)
    local controlledCount = 0
    local best = nil
    local score = 0
    for row = 1, size do
        for col = 1, size do
            local target = {row = row, col = col}
            local fit, slack = routeFit(target, ownHub, enemyHub, hubDistance, ctx)
            if fit > 0 and canAttack(ai, state, projected, projected, target, {allowEmptyTarget = true}) then
                local fieldProgress = clamp(manhattan(ownHub, target) / hubDistance, 0, 1)
                local contribution = 18 + (fit * 58) + (fieldProgress * 26)
                controlledCount = controlledCount + 1
                score = score + contribution
                if not best or contribution > best.value then
                    best = {
                        row = row,
                        col = col,
                        value = contribution,
                        routeFit = fit,
                        routeSlack = slack,
                        fieldProgress = fieldProgress
                    }
                end
            end
        end
    end

    score = math.min(score, num(ctx and ctx.cfg and ctx.cfg.EARLY_FIRE_LANE_MAX_SCORE, 220))
    local required = unitNeedsFireLane(unit)
    local deadLane = required and controlledCount <= 0
    return {
        score = score,
        controlledCount = controlledCount,
        required = required,
        preferred = unitLikesFireLane(unit),
        deadLane = deadLane,
        best = best,
        reason = deadLane and "dead_fire_lane" or (controlledCount > 0 and "route_fire_lane" or "no_fire_lane")
    }
end

M._private = {
    unitNeedsFireLane = unitNeedsFireLane,
    routeFit = routeFit,
    manhattan = manhattan
}

return M
