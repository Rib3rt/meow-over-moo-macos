local M = {}

local DEFAULT_NEUTRAL_BASE = {
    name = "neutral_base",
    global = {
        baseStrategicScale = 0.15,
        hardTacticsPriority = true
    },
    purposeScales = {
        expand = 1.0,
        contain = 1.0,
        support = 1.0,
        pressure = 0.95,
        deploy = 1.0,
        retreat = 0.9
    },
    weights = {
        expand = {
            support = 32,
            covered = 42,
            enemyPunish = -145,
            lethalPunish = -220
        },
        contain = {
            support = 26,
            covered = 52,
            enemyPunish = -105,
            lethalPunish = -175
        },
        support = {
            support = 88,
            covered = 56,
            enemyPunish = -150,
            lethalPunish = -230
        },
        pressure = {
            covered = 42,
            enemyPunish = -135,
            lethalPunish = -220
        },
        deploy = {
            support = 32,
            covered = 50,
            enemyPunish = -150,
            lethalPunish = -230
        },
        retreat = {
            heal = 84,
            covered = 62
        }
    }
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = clone(child)
    end
    return out
end

local function merge(base, override)
    local out = clone(base or {})
    for key, value in pairs(override or {}) do
        if type(value) == "table" and type(out[key]) == "table" then
            out[key] = merge(out[key], value)
        else
            out[key] = clone(value)
        end
    end
    return out
end

local function requestedName(ctx, override)
    if type(override) == "string" then
        return override
    end
    if type(override) == "table" and override.name then
        return tostring(override.name)
    end
    local cfg = ctx and ctx.cfg or {}
    if cfg.STRATEGIC_PERSONALITY_USE_AI_REFERENCE == true then
        local reference = tostring(
            (ctx and (ctx.aiReference or ctx.earlyPhaseReference or ctx.midPersonalityReference))
                or "neutral_base"
        ):lower()
        if reference == "bart" then
            reference = "burt"
        end
        local byReference = cfg.STRATEGIC_PERSONALITY_BY_REFERENCE
            or cfg.TOURNAMENT_STRATEGIC_PERSONALITY_BY_REFERENCE
            or {}
        if byReference[reference] then
            return tostring(byReference[reference])
        end
        local configured = cfg.STRATEGIC_PERSONALITIES or cfg.TOURNAMENT_STRATEGIC_PERSONALITIES or {}
        if configured[reference] then
            return reference
        end
    end
    return tostring(cfg.STRATEGIC_PERSONALITY or cfg.TOURNAMENT_STRATEGIC_PERSONALITY or "neutral_base")
end

function M.resolve(ctx, override)
    local cfg = ctx and ctx.cfg or {}
    local name = requestedName(ctx, override)
    local configured = cfg.STRATEGIC_PERSONALITIES or cfg.TOURNAMENT_STRATEGIC_PERSONALITIES or {}
    local profile = merge(DEFAULT_NEUTRAL_BASE, configured[name] or configured.neutral_base or {})

    if type(override) == "table" then
        profile = merge(profile, override)
    end

    profile.name = tostring(profile.name or name or "neutral_base")
    return profile
end

local function scaleNumericWeights(weights, scale)
    if scale == 1 then
        return weights
    end
    local out = {}
    for key, value in pairs(weights or {}) do
        out[key] = type(value) == "number" and value * scale or value
    end
    return out
end

function M.applyToWeights(baseWeights, purpose, ctx, opts)
    opts = opts or {}
    local profile = M.resolve(ctx, opts.personality)
    local key = tostring(purpose or "expand")
    local weights = merge(baseWeights or {}, profile.weights and profile.weights[key] or {})

    if profile.global and profile.global.baseStrategicScale ~= nil then
        weights.baseStrategicScale = num(profile.global.baseStrategicScale, weights.baseStrategicScale)
    end

    weights = scaleNumericWeights(weights, num(profile.purposeScales and profile.purposeScales[key], 1))
    return weights, profile
end

M.DEFAULT_NEUTRAL_BASE = DEFAULT_NEUTRAL_BASE

return M
