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

local function count(bucket)
    return num(bucket and bucket.count, 0)
end

local function active(bucket)
    return bucket and bucket.active == true
end

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function enabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_TOLL_ROUTE_ENABLED == false)
end

local function maxSlack(ctx)
    return math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_TOLL_ROUTE_MAX_SLACK, DEFAULT_MAX_SLACK))
end

local function cfgWeight(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_TOLL_ROUTE_WEIGHT, 1)
end

local function fireLaneEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.EARLY_FIRE_LANE_ENABLED == false)
end

local function deadFireLanePenalty(ctx)
    return math.abs(num(ctx and ctx.cfg and ctx.cfg.EARLY_DEAD_FIRE_LANE_PENALTY, 220))
end

local function routeContext(route, state, ctx)
    local playerId = ctx and ctx.aiPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or (playerId == 1 and 2 or 1)
    local ownHub = route and route.ownHub or state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = route and route.enemyHub or state and state.commandHubs and state.commandHubs[enemyPlayer]
    local distance = num(route and route.distance, manhattan(ownHub, enemyHub))
    return ownHub, enemyHub, math.max(1, distance)
end

local function routeFit(routeSlack, ctx)
    local slackCap = maxSlack(ctx)
    if routeSlack <= 0 then
        return 1
    end
    if slackCap <= 0 then
        return 0
    end
    return clamp(1 - (routeSlack / slackCap), 0, 1)
end

function M.score(state, ctx, route, cell)
    if not (enabled(ctx) and cell) then
        return {
            value = 0,
            routeSlack = 99,
            routeFit = 0,
            fieldProgress = 0,
            tollPressure = 0,
            safetyPenalty = 0
        }
    end

    local ownHub, enemyHub, hubDistance = routeContext(route, state, ctx)
    if not (ownHub and enemyHub) then
        return {
            value = 0,
            routeSlack = 99,
            routeFit = 0,
            fieldProgress = 0,
            tollPressure = 0,
            safetyPenalty = 0
        }
    end

    local ownDistance = manhattan(ownHub, cell)
    local enemyDistance = manhattan(enemyHub, cell)
    local routeSlackValue = math.max(0, ownDistance + enemyDistance - hubDistance)
    local fit = routeFit(routeSlackValue, ctx)
    local fieldProgress = clamp(ownDistance / hubDistance, 0, 1)
    local ownAttack = cell.attackInfluence and cell.attackInfluence.us
    local enemyAttack = cell.attackInfluence and cell.attackInfluence.enemy
    local tollPressure = 0

    if routeSlackValue <= 0 then
        tollPressure = tollPressure + 55
    elseif fit > 0 then
        tollPressure = tollPressure + (25 * fit)
    end
    if cell.coveredIfOccupied == true then
        tollPressure = tollPressure + 65
    end
    if active(ownAttack) then
        tollPressure = tollPressure + 35 + (count(ownAttack) * 12)
    end
    if cell.potentialInfluencedByUs == true then
        tollPressure = tollPressure + 25
    end
    local fireLaneScore = fireLaneEnabled(ctx)
        and num(cell.fireLaneScore, num(cell.fireLane and cell.fireLane.score, 0))
        or 0
    if fireLaneScore > 0 then
        tollPressure = tollPressure + math.min(fireLaneScore * 0.5, 110)
    end

    local routeValue = fit * (45 + (fieldProgress * 165))
    local tollValue = fit * tollPressure
    local safetyPenalty = 0
    if cell.attackContested == true then
        safetyPenalty = safetyPenalty - 45
    end
    if count(enemyAttack) > 0 then
        safetyPenalty = safetyPenalty - (55 + (count(enemyAttack) * 18))
    end
    if cell.risk and cell.risk.lethalPunish then
        safetyPenalty = safetyPenalty - 120
    elseif cell.risk and cell.risk.enemyPunish then
        safetyPenalty = safetyPenalty - 70
    end
    if fireLaneEnabled(ctx) and cell.deadFireLane == true then
        safetyPenalty = safetyPenalty - deadFireLanePenalty(ctx)
    end

    local value = (routeValue + tollValue + safetyPenalty) * cfgWeight(ctx)
    return {
        value = value,
        routeSlack = routeSlackValue,
        routeFit = fit,
        fieldProgress = fieldProgress,
        ownDistance = ownDistance,
        enemyDistance = enemyDistance,
        tollPressure = tollPressure,
        fireLaneScore = fireLaneScore,
        routeValue = routeValue,
        tollValue = tollValue,
        safetyPenalty = safetyPenalty
    }
end

M._private = {
    enabled = enabled,
    maxSlack = maxSlack,
    routeFit = routeFit,
    manhattan = manhattan
}

return M
