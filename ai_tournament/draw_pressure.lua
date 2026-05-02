local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function drawRules(ai)
    local draw = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).DRAW or {})
    return {
        countFromFullTurn = num(draw.COUNT_FROM_FULL_TURN or draw.START_TURN, 11),
        noInteractionLimit = num(draw.NO_INTERACTION_LIMIT, 5),
        urgencyStartRemaining = num(draw.URGENCY_START_REMAINING, 4)
    }
end

function M.build(ai, beforeState, ctx)
    local rules = drawRules(ai)
    local currentFullTurn = num(beforeState and (beforeState.currentTurn or beforeState.turnNumber), 0)
    local streak = math.max(0, num(beforeState and beforeState.turnsWithoutDamage, 0))
    local limit = math.max(1, rules.noInteractionLimit)
    local preWindowStart = math.max(1, rules.countFromFullTurn - 2)
    local urgencyStartRemaining = math.max(1, math.min(limit, rules.urgencyStartRemaining))
    local pressureStreak = math.max(0, limit - urgencyStartRemaining)
    local nearStreak = math.max(0, limit - 2)
    local criticalStreak = math.max(0, limit - 1)
    local active = currentFullTurn >= preWindowStart
    local preWindow = currentFullTurn < rules.countFromFullTurn
    local urgencyMax = math.max(1, criticalStreak - pressureStreak + 1)
    local urgency = active and math.max(0, math.min(urgencyMax, streak - pressureStreak + 1)) or 0

    if ctx and ctx.stats then
        local stats = ctx.stats
        stats.officialDrawPressureStreak = pressureStreak
        stats.officialDrawNearStreak = nearStreak
        stats.officialDrawCriticalStreak = criticalStreak
        stats.officialDrawUrgencyMax = urgencyMax
        stats.officialDrawRemainingBeforeLimit = math.max(0, limit - streak)
    end

    return {
        active = active,
        preWindow = preWindow,
        streak = streak,
        urgency = urgency,
        urgencyMax = urgencyMax,
        urgencyRatio = urgencyMax > 0 and urgency / urgencyMax or 0,
        countFromFullTurn = rules.countFromFullTurn,
        noInteractionLimit = limit,
        pressureStreak = pressureStreak,
        nearStreak = nearStreak,
        criticalStreak = criticalStreak,
        pressureLimit = active and urgency > 0,
        nearLimit = active and streak >= nearStreak,
        criticalLimit = active and streak >= criticalStreak,
        remainingBeforeLimit = math.max(0, limit - streak)
    }
end

function M.isNearLimit(drawState)
    return drawState and drawState.active == true and drawState.nearLimit == true
end

function M.isPressure(drawState)
    return drawState and drawState.active == true and drawState.pressureLimit == true
end

function M.isCritical(drawState)
    return drawState and drawState.active == true and drawState.criticalLimit == true
end

return M
