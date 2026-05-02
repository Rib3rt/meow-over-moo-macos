local M = {}

local POSITION_MOVE_TAG = "STRATEGIC_PLAN_MOVE"

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
        and ctx.cfg.PIPELINE_V2_POSITION_PATTERN_PENALTY_ENABLED == false)
end

local function cap(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_POSITION_PATTERN_PENALTY_CAP, 220)
end

local function cloudstrikerMeleeEnabled(ctx)
    return not (ctx
        and ctx.cfg
        and ctx.cfg.PIPELINE_V2_CLOUDSTRIKER_MELEE_CONTACT_PENALTY_ENABLED == false)
end

local function cloudstrikerMeleePenalty(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_CLOUDSTRIKER_MELEE_CONTACT_PENALTY, 3200)
end

local function samePlayer(a, b)
    local na = tonumber(a)
    local nb = tonumber(b)
    if na and nb then
        return na == nb
    end
    return tostring(a) == tostring(b)
end

local function manhattan(a, b)
    if not (a and b) then
        return 999
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function getUnitAt(ai, state, row, col)
    if ai and ai.getUnitAtPosition then
        local ok, unit = pcall(ai.getUnitAtPosition, ai, state, row, col)
        if ok and unit then
            return unit
        end
    end
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    return nil
end

local function adjacentEnemyCount(state, playerId, target)
    if not (state and target and playerId ~= nil) then
        return 0
    end
    local count = 0
    for _, unit in ipairs(state.units or {}) do
        if unit
            and num(unit.player, 0) > 0
            and not samePlayer(unit.player, playerId)
            and manhattan(unit, target) == 1 then
            count = count + 1
        end
    end
    for hubPlayer, hub in pairs(state.commandHubs or {}) do
        if hub
            and not samePlayer(hubPlayer, playerId)
            and manhattan(hub, target) == 1 then
            count = count + 1
        end
    end
    return count
end

local function sourceUnit(ai, state, action)
    if not (action and action.unit) then
        return nil
    end
    if action.unit.name then
        return action.unit
    end
    return getUnitAt(ai, state, num(action.unit.row, -1), num(action.unit.col, -1))
        or action.unit
end

local function cloudstrikerMeleeContactPenalty(ai, state, ctx, action, unit)
    if not (cloudstrikerMeleeEnabled(ctx)
        and action
        and action.type == "move"
        and action.target
        and unit
        and tostring(unit.name or "") == "Cloudstriker") then
        return 0
    end

    if ctx and ctx.activeContracts and ctx.activeContracts.defenseActive == true then
        return 0
    end

    local playerId = ctx and ctx.aiPlayer or unit.player
    local contactCount = adjacentEnemyCount(state, playerId, action.target)
    if contactCount <= 0 then
        return 0
    end

    local base = cloudstrikerMeleePenalty(ctx)
    return math.max(0, base + math.max(0, contactCount - 1) * math.floor(base * 0.35))
end

function M.tagAction(action)
    if action and action.type == "move" and not action._aiTag then
        action._aiTag = POSITION_MOVE_TAG
    end
    return action
end

function M.tagPositionMoves(actions)
    for _, action in ipairs(actions or {}) do
        M.tagAction(action)
    end
    return actions
end

function M.penalty(ai, state, ctx, action)
    if not (action
        and action.type == "move"
        and action.target
        and ai) then
        return 0
    end

    local unit = sourceUnit(ai, state, action)
    if not unit then
        return 0
    end

    local cloudstrikerPenalty = cloudstrikerMeleeContactPenalty(ai, state, ctx, action, unit)
    local patternPenalty = 0
    if enabled(ctx) and ai.getRepeatedLowImpactPatternPenalty then
        local ok, value = pcall(
            ai.getRepeatedLowImpactPatternPenalty,
            ai,
            state,
            unit,
            action.target,
            ctx and ctx.aiPlayer or unit.player,
            nil
        )
        if ok then
            patternPenalty = math.min(math.max(0, num(value, 0)), math.max(0, cap(ctx)))
        end
    end

    return patternPenalty + cloudstrikerPenalty
end

function M.adjustScore(ai, state, ctx, action, score, stats)
    local penalty = M.penalty(ai, state, ctx, action)
    if penalty > 0 and stats then
        stats.movePatternPenalized = num(stats.movePatternPenalized, 0) + 1
        stats.movePatternPenaltyMax = math.max(num(stats.movePatternPenaltyMax, 0), penalty)
        local unit = sourceUnit(ai, state, action)
        local cloudstrikerPenalty = cloudstrikerMeleeContactPenalty(ai, state, ctx, action, unit)
        if cloudstrikerPenalty > 0 then
            stats.cloudstrikerMeleeContactPenalized = num(stats.cloudstrikerMeleeContactPenalized, 0) + 1
            stats.cloudstrikerMeleeContactPenaltyMax =
                math.max(num(stats.cloudstrikerMeleeContactPenaltyMax, 0), cloudstrikerPenalty)
        end
    end
    return num(score, 0) - penalty, penalty
end

return M
