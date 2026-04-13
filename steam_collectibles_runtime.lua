local steamRuntime = require("steam_runtime")
local collectiblesDefs = require("steam_collectibles_defs")

local collectiblesRuntime = {}

local state = {
    lastError = nil
}

local function normalizeSeries(series, fallback)
    local numeric = math.floor(tonumber(series) or tonumber(fallback) or collectiblesDefs.DEFAULT_BADGE_SERIES or 1)
    if numeric <= 0 then
        numeric = collectiblesDefs.DEFAULT_BADGE_SERIES or 1
    end
    return numeric
end

function collectiblesRuntime.getDefinitions()
    return collectiblesDefs
end

function collectiblesRuntime.getPlayerSteamLevel()
    local level, reason = steamRuntime.getPlayerSteamLevel()
    if level == nil then
        state.lastError = reason or "player_level_unavailable"
        return nil, state.lastError
    end
    state.lastError = nil
    return math.max(0, math.floor(tonumber(level) or 0))
end

function collectiblesRuntime.getBadgeLevel(series, foil)
    local badgeLevel, reason = steamRuntime.getGameBadgeLevel(normalizeSeries(series), foil == true)
    if badgeLevel == nil then
        state.lastError = reason or "badge_level_unavailable"
        return nil, state.lastError
    end
    state.lastError = nil
    return math.max(0, math.floor(tonumber(badgeLevel) or 0))
end

function collectiblesRuntime.getBadgeLevelById(badgeId)
    local definition = collectiblesDefs.BADGES[tostring(badgeId or "")]
    if not definition then
        state.lastError = "badge_definition_missing"
        return nil, state.lastError
    end
    return collectiblesRuntime.getBadgeLevel(definition.series, definition.foil)
end

function collectiblesRuntime.getSummary()
    local standardLevel = collectiblesRuntime.getBadgeLevelById("standard")
    local foilLevel = collectiblesRuntime.getBadgeLevelById("foil")
    local steamLevel = collectiblesRuntime.getPlayerSteamLevel()

    return {
        steamLevel = steamLevel,
        standardBadgeLevel = standardLevel,
        foilBadgeLevel = foilLevel,
        lastError = state.lastError
    }
end

function collectiblesRuntime.getDiagnostics()
    return {
        lastError = state.lastError
    }
end

return collectiblesRuntime
