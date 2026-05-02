local M = {}

local DEFAULT_PROFILE = {
    name = "balanced",
    baseScoreScale = 0.45,
    deployScale = 1.0,
    moveScale = 1.0,
    earlyScale = 1.0,
    midScale = 0.75,
    endgameScale = 0.45,
    openingScale = 1.0,
    responseScale = 0.12,
    coverageBonus = 80,
    safeCellBonus = 30,
    uncoveredPenalty = 360,
    lethalPunishPenalty = 220,
    maxBonus = 220,
    kindWeights = {
        support = 35,
        deny = 35,
        interdiction = 55,
        choke = 35,
        safe_staging = 30,
        second_threat = 50
    }
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function mergeProfile(base, override)
    local out = {}
    for key, value in pairs(base or {}) do
        if type(value) == "table" then
            out[key] = mergeProfile(value, {})
        else
            out[key] = value
        end
    end
    for key, value in pairs(override or {}) do
        if type(value) == "table" then
            out[key] = mergeProfile(out[key] or {}, value)
        else
            out[key] = value
        end
    end
    return out
end

local function cfgProfile(ctx)
    local cfg = ctx and ctx.cfg or {}
    local profileName = tostring(cfg.STRATEGIC_PROFILE or cfg.TOURNAMENT_STRATEGIC_PROFILE or "balanced")
    local profiles = cfg.STRATEGIC_PROFILES or {}
    return mergeProfile(DEFAULT_PROFILE, profiles[profileName] or profiles.balanced or {})
end

local function phaseScale(profile, ctx)
    local phaseName = tostring(ctx and ctx.phase and ctx.phase.name or ctx and ctx.phase or "")
    if phaseName == "endgame" then
        return num(profile.endgameScale, 0.45)
    end
    if phaseName == "mid" then
        return num(profile.midScale, 0.75)
    end
    return num(profile.earlyScale, 1.0)
end

local function planScale(profile, ctx)
    local role = tostring(ctx and ctx.earlyPlan and ctx.earlyPlan.role or "")
    if role == "response" then
        return num(profile.responseScale, 0.35)
    end
    if role == "opening" then
        return num(profile.openingScale, 1.0)
    end
    return 1.0
end

function M.resolve(ctx, override)
    return mergeProfile(cfgProfile(ctx), override or {})
end

function M.scoreStrategicCell(cell, ctx, opts)
    opts = opts or {}
    local profile = M.resolve(ctx, opts.profile)
    local actionScale = opts.action == "move"
        and num(profile.moveScale, 1.0)
        or num(profile.deployScale, 1.0)
    local interpretationScale = actionScale * phaseScale(profile, ctx) * planScale(profile, ctx)
    local scale = num(profile.baseScoreScale, 0.45) * interpretationScale

    local result = {
        value = 0,
        raw = num(cell and cell.score, 0),
        profile = profile.name or "balanced",
        reasons = {}
    }
    if not cell then
        result.reasons[#result.reasons + 1] = "no_strategic_cell"
        return result
    end

    local value = result.raw * scale
    for _, kind in ipairs(cell.kinds or {}) do
        value = value + num(profile.kindWeights and profile.kindWeights[kind], 0) * interpretationScale
        result.reasons[#result.reasons + 1] = "strategic_kind_" .. tostring(kind)
    end

    if cell.coveredIfOccupied then
        value = value + num(profile.coverageBonus, 80) * interpretationScale
        result.reasons[#result.reasons + 1] = "strategic_covered"
    elseif cell.enemyPunish then
        value = value - num(profile.uncoveredPenalty, 360)
        if cell.enemyPunish.lethal then
            value = value - num(profile.lethalPunishPenalty, 220)
            result.reasons[#result.reasons + 1] = "strategic_lethal_punish"
        else
            result.reasons[#result.reasons + 1] = "strategic_uncovered_punish"
        end
    else
        value = value + num(profile.safeCellBonus, 30) * interpretationScale
        result.reasons[#result.reasons + 1] = "strategic_safe_cell"
    end

    local maxBonus = num(profile.maxBonus, 220)
    if value > maxBonus then
        value = maxBonus
    elseif value < -maxBonus then
        value = -maxBonus
    end

    result.value = value
    return result
end

return M
