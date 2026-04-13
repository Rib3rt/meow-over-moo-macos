local unitsInfo = require('unitsInfo')
local aiInfluence = require('ai_influence')
local randomGen = require('randomGenerator')
local aiConfig = require('ai_config')

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local DEFAULT_SCORE_PARAMS = DEFAULT_AI_PARAMS.SCORES or {}
local DEFAULT_UNIT_PROFILES = DEFAULT_AI_PARAMS.UNIT_PROFILES or {}
local RUNTIME_DEFAULTS = DEFAULT_AI_PARAMS.RUNTIME or {}
local ZERO = RUNTIME_DEFAULTS.ZERO
local MIN_HP = RUNTIME_DEFAULTS.MIN_HP
local DEFAULT_TURN = RUNTIME_DEFAULTS.DEFAULT_TURN
local DEFAULT_GRID_SIZE = RUNTIME_DEFAULTS.DEFAULT_GRID_SIZE
local DISTANCE_FALLBACK = RUNTIME_DEFAULTS.DISTANCE_FALLBACK
local PLAYER_INDEX_SUM = RUNTIME_DEFAULTS.PLAYER_INDEX_SUM
local ONE = MIN_HP
local TWO = MIN_HP + MIN_HP
local THREE = TWO + ONE
local FOUR = THREE + ONE
local FIVE = FOUR + ONE
local SIX = FIVE + ONE
local SEVEN = SIX + ONE
local EIGHT = SEVEN + ONE
local TEN = TWO * FIVE
local NEGATIVE_MIN_HP = -MIN_HP
local NEGATIVE_ONE = -ONE
local BASE_AI_REFERENCE = "base"
local RULE_CONTRACT = DEFAULT_AI_PARAMS.RULE_CONTRACT or {}
local SETUP_RULE_CONTRACT = RULE_CONTRACT.SETUP or {}
local ACTION_RULE_CONTRACT = RULE_CONTRACT.ACTIONS or {}
local TURN_RULE_CONTRACT = RULE_CONTRACT.TURN or {}
local PERFORMANCE_RULE_CONTRACT = RULE_CONTRACT.PERFORMANCE or {}
local DEFAULT_POSITIONAL_COMPONENT_WEIGHTS = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).COMPONENT_WEIGHTS) or {
    IMPROVEMENT = ONE,
    REPAIR = 0.9,
    THREAT = 0.8,
    OFFENSIVE = 0.45,
    FORWARD_PRESSURE = 0.5
}

local STRATEGY_INTENT = {
    DEFEND_HARD = "DEFEND_HARD",
    SIEGE_SETUP = "SIEGE_SETUP",
    SIEGE_EXECUTE = "SIEGE_EXECUTE",
    STABILIZE = "STABILIZE"
}

local STRATEGY_ROLE_ORDER = {
    primary = ONE,
    secondary = TWO,
    screen = THREE,
    anchor = FOUR
}

local function valueOr(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

local function deepCopyValue(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do
        copy[deepCopyValue(k, seen)] = deepCopyValue(v, seen)
    end
    return copy
end

local function getMonotonicTimeSeconds()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    if os and os.clock then
        return os.clock()
    end
    return 0
end

local function deepMerge(base, override)
    if type(base) ~= "table" then
        return override ~= nil and override or base
    end
    local result = {}
    for key, value in pairs(base) do
        if type(value) == "table" then
            result[key] = deepMerge(value, type(override) == "table" and override[key] or nil)
        else
            result[key] = value
        end
    end
    if type(override) == "table" then
        for key, value in pairs(override) do
            if type(value) == "table" and type(result[key]) == "table" then
                result[key] = deepMerge(result[key], value)
            elseif value ~= nil then
                result[key] = value
            end
        end
    end
    return result
end

local function hashPosition(pos)
    if not pos or not pos.row or not pos.col then
        return nil
    end
    return string.format("%d,%d", pos.row, pos.col)
end

local function buildMovePatternKey(playerId, unitName, fromRow, fromCol, toRow, toCol)
    return string.format(
        "%s:%s:%d,%d>%d,%d",
        tostring(playerId or ZERO),
        tostring(unitName or "unknown"),
        fromRow or ZERO,
        fromCol or ZERO,
        toRow or ZERO,
        toCol or ZERO
    )
end

return {
    unitsInfo = unitsInfo,
    aiInfluence = aiInfluence,
    randomGen = randomGen,
    aiConfig = aiConfig,

    DEFAULT_AI_PARAMS = DEFAULT_AI_PARAMS,
    DEFAULT_SCORE_PARAMS = DEFAULT_SCORE_PARAMS,
    DEFAULT_UNIT_PROFILES = DEFAULT_UNIT_PROFILES,
    RUNTIME_DEFAULTS = RUNTIME_DEFAULTS,
    ZERO = ZERO,
    MIN_HP = MIN_HP,
    DEFAULT_TURN = DEFAULT_TURN,
    DEFAULT_GRID_SIZE = DEFAULT_GRID_SIZE,
    DISTANCE_FALLBACK = DISTANCE_FALLBACK,
    PLAYER_INDEX_SUM = PLAYER_INDEX_SUM,
    ONE = ONE,
    TWO = TWO,
    THREE = THREE,
    FOUR = FOUR,
    FIVE = FIVE,
    SIX = SIX,
    SEVEN = SEVEN,
    EIGHT = EIGHT,
    TEN = TEN,
    NEGATIVE_MIN_HP = NEGATIVE_MIN_HP,
    NEGATIVE_ONE = NEGATIVE_ONE,
    BASE_AI_REFERENCE = BASE_AI_REFERENCE,
    RULE_CONTRACT = RULE_CONTRACT,
    SETUP_RULE_CONTRACT = SETUP_RULE_CONTRACT,
    ACTION_RULE_CONTRACT = ACTION_RULE_CONTRACT,
    TURN_RULE_CONTRACT = TURN_RULE_CONTRACT,
    PERFORMANCE_RULE_CONTRACT = PERFORMANCE_RULE_CONTRACT,
    DEFAULT_POSITIONAL_COMPONENT_WEIGHTS = DEFAULT_POSITIONAL_COMPONENT_WEIGHTS,
    STRATEGY_INTENT = STRATEGY_INTENT,
    STRATEGY_ROLE_ORDER = STRATEGY_ROLE_ORDER,

    valueOr = valueOr,
    deepCopyValue = deepCopyValue,
    getMonotonicTimeSeconds = getMonotonicTimeSeconds,
    deepMerge = deepMerge,
    hashPosition = hashPosition,
    buildMovePatternKey = buildMovePatternKey
}
