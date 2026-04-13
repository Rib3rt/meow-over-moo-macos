-- AI Evaluation Module
-- Handles unit value calculation, positional analysis, and threat assessment

local aiConfig = require('ai_config')

local aiEvaluation = {}

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local DEFAULT_SCORE_PARAMS = DEFAULT_AI_PARAMS.SCORES or {}
local DEFAULT_EVAL_PARAMS = DEFAULT_SCORE_PARAMS.UNIT_EVAL or {}
local DEFAULT_EVAL_DEFAULTS = DEFAULT_EVAL_PARAMS.DEFAULTS or {}
local RUNTIME_DEFAULTS = DEFAULT_AI_PARAMS.RUNTIME or {}
local ZERO = RUNTIME_DEFAULTS.ZERO
local ONE = RUNTIME_DEFAULTS.MIN_HP

local function resolveValue(value, fallbackValue)
    if value ~= nil then
        return value
    end
    return fallbackValue
end

local function getEvalParams(self)
    local params = (self and self.AI_PARAMS) or {}
    return ((params.SCORES or {}).UNIT_EVAL) or DEFAULT_EVAL_PARAMS
end

local function buildUnitValueMap(unitValueConfig, defaultUnitValueConfig, aliasConfig)
    local map = {}

    for unitName, unitValue in pairs(defaultUnitValueConfig or {}) do
        map[unitName] = unitValue
    end

    for unitName, unitValue in pairs(unitValueConfig or {}) do
        map[unitName] = unitValue
    end

    for aliasName, sourceName in pairs(aliasConfig or {}) do
        if map[aliasName] == nil then
            map[aliasName] = map[sourceName]
        end
    end

    return map
end

function aiEvaluation.getUnitBaseValue(self, unit, state)
    -- Input validation
    if not self or not unit or not unit.name or not state then return ZERO end

    local evalParams = getEvalParams(self)
    local unitValueConfig = evalParams.UNIT_VALUES or {}
    local defaultUnitValueConfig = DEFAULT_EVAL_PARAMS.UNIT_VALUES or {}
    local aliasConfig = evalParams.UNIT_VALUE_ALIASES or DEFAULT_EVAL_PARAMS.UNIT_VALUE_ALIASES or {}
    local roleConfig = evalParams.ROLE_BONUSES or {}
    local defaultRoleConfig = DEFAULT_EVAL_PARAMS.ROLE_BONUSES or {}
    local defaults = evalParams.DEFAULTS or DEFAULT_EVAL_DEFAULTS

    local unitValueMap = buildUnitValueMap(unitValueConfig, defaultUnitValueConfig, aliasConfig)
    local canonicalName = aliasConfig[unit.name] or unit.name

    local baseValue = resolveValue(unitValueMap[unit.name], resolveValue(unitValueMap[canonicalName], defaults.ZERO_VALUE))

    -- Role-specific bonuses
    local roleBonus = defaults.ZERO_VALUE
    if canonicalName == "Healer" or unit.name == "Healer" then
        -- Repair units more valuable when allies are damaged
        local damagedAllies = ZERO
        for _, ally in ipairs(state.units or {}) do
            if ally.player == unit.player and ally.currentHp < ally.startingHp then
                damagedAllies = damagedAllies + ONE
            end
        end
        local healerConfig = roleConfig.HEALER or defaultRoleConfig.HEALER or {}
        local defaultHealerConfig = defaultRoleConfig.HEALER or {}
        local damagedBonus = resolveValue(healerConfig.DAMAGED_ALLY_BONUS, defaultHealerConfig.DAMAGED_ALLY_BONUS)
        roleBonus = damagedAllies * damagedBonus
    elseif canonicalName == "Wingstalker" or unit.name == "Wingstalker" then
        -- Scout more valuable early game
        local scoutConfig = roleConfig.SCOUT or defaultRoleConfig.SCOUT or {}
        local defaultScoutConfig = defaultRoleConfig.SCOUT or {}
        local baseBonus = resolveValue(scoutConfig.EARLY_BONUS_BASE, defaultScoutConfig.EARLY_BONUS_BASE)
        local decay = resolveValue(scoutConfig.EARLY_BONUS_DECAY, defaultScoutConfig.EARLY_BONUS_DECAY)
        local currentTurn = (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or defaults.CURRENT_TURN
        local turnBonus = math.max(defaults.ZERO_VALUE, baseBonus - currentTurn * decay)
        roleBonus = turnBonus
    end

    return baseValue + roleBonus
end

function aiEvaluation.getNearbyDamagedAlliesScore(self, state, unit)
    -- Input validation
    if not self or not state or not unit or unit.name ~= "Healer" then return ZERO end

    local evalParams = getEvalParams(self)
    local defaultRoleConfig = (DEFAULT_EVAL_PARAMS.ROLE_BONUSES or {}).HEALER or {}
    local healerConfig = ((evalParams.ROLE_BONUSES or {}).HEALER) or defaultRoleConfig
    local maxDistance = resolveValue(healerConfig.NEARBY_DISTANCE, defaultRoleConfig.NEARBY_DISTANCE)
    local damageWeight = resolveValue(healerConfig.NEARBY_DAMAGE_WEIGHT, defaultRoleConfig.NEARBY_DAMAGE_WEIGHT)
    local defaults = evalParams.DEFAULTS or DEFAULT_EVAL_DEFAULTS

    local score = defaults.ZERO_VALUE
    for _, ally in ipairs(state.units or {}) do
        if ally.player == unit.player and ally.currentHp < ally.startingHp then
            local distance = math.abs(unit.row - ally.row) + math.abs(unit.col - ally.col)
            if distance <= maxDistance then
                local damageRatio = (ally.startingHp - ally.currentHp) / ally.startingHp
                local effectiveDistance = math.max(defaults.MIN_HP, distance)
                score = score + (damageRatio * damageWeight) / effectiveDistance
            end
        end
    end
    return score
end

function aiEvaluation.getExposureScore(self, state, unit)
    -- Input validation
    if not self or not state or not unit then return ZERO end

    local evalParams = getEvalParams(self)
    local defaults = evalParams.DEFAULTS or DEFAULT_EVAL_DEFAULTS
    local exposureConfig = evalParams.EXPOSURE or {}
    local defaultExposureConfig = DEFAULT_EVAL_PARAMS.EXPOSURE or {}
    local maxDistance = resolveValue(exposureConfig.MAX_DISTANCE, defaultExposureConfig.MAX_DISTANCE)
    local enemyWeight = resolveValue(exposureConfig.ENEMY_WEIGHT, defaultExposureConfig.ENEMY_WEIGHT)
    local allyWeight = resolveValue(exposureConfig.ALLY_WEIGHT, defaultExposureConfig.ALLY_WEIGHT)

    local exposure = defaults.ZERO_VALUE
    local protection = defaults.ZERO_VALUE

    -- Count nearby enemies and allies
    for _, otherUnit in ipairs(state.units or {}) do
        if otherUnit ~= unit then
            local distance = math.abs(unit.row - otherUnit.row) + math.abs(unit.col - otherUnit.col)

            if distance <= maxDistance then
                local proximityFactor = (maxDistance + defaults.MIN_HP) - distance
                if proximityFactor < defaults.ZERO_VALUE then
                    proximityFactor = defaults.ZERO_VALUE
                end
                if otherUnit.player ~= unit.player then
                    -- Enemy nearby increases exposure
                    exposure = exposure + proximityFactor * enemyWeight
                else
                    -- Ally nearby provides protection
                    protection = protection + proximityFactor * allyWeight
                end
            end
        end
    end

    return protection - exposure
end

function aiEvaluation.assessUnitThreatLevel(self, unit, distanceToOurHub)
    -- Input validation
    if not self or not unit then return ZERO end

    local evalParams = getEvalParams(self)
    local defaults = evalParams.DEFAULTS or DEFAULT_EVAL_DEFAULTS
    local unitValueConfig = evalParams.UNIT_VALUES or {}
    local defaultUnitValueConfig = DEFAULT_EVAL_PARAMS.UNIT_VALUES or {}
    local aliasConfig = evalParams.UNIT_VALUE_ALIASES or DEFAULT_EVAL_PARAMS.UNIT_VALUE_ALIASES or {}
    local threatConfig = evalParams.THREAT or {}
    local defaultThreatConfig = DEFAULT_EVAL_PARAMS.THREAT or {}
    local baseDivisor = resolveValue(threatConfig.BASE_DIVISOR, defaultThreatConfig.BASE_DIVISOR)
    local distanceConfig = threatConfig.DISTANCE or {}
    local defaultDistanceConfig = defaultThreatConfig.DISTANCE or {}
    local distanceBase = resolveValue(distanceConfig.BASE, defaultDistanceConfig.BASE)
    local distanceMultiplier = resolveValue(distanceConfig.MULTIPLIER, defaultDistanceConfig.MULTIPLIER)
    local unitMultipliers = threatConfig.UNIT_MULTIPLIERS or {}
    local defaultUnitMultipliers = defaultThreatConfig.UNIT_MULTIPLIERS or {}

    local threat = defaults.ZERO_VALUE
    local unitValueMap = buildUnitValueMap(unitValueConfig, defaultUnitValueConfig, aliasConfig)
    local baseValue = resolveValue(unitValueMap[unit.name], defaults.ZERO_VALUE)

    -- Base threat from unit value
    threat = baseValue / baseDivisor

    -- Distance factor (closer = more threatening)
    if distanceToOurHub then
        local distanceBonus = math.max(defaults.ZERO_VALUE, distanceBase - distanceToOurHub)
        threat = threat + distanceBonus * distanceMultiplier
    end

    -- Unit-specific threat modifiers
    local unitMultiplier = resolveValue(unitMultipliers[unit.name], defaultUnitMultipliers[unit.name])
    if unitMultiplier == nil then
        unitMultiplier = defaults.UNIT_MULTIPLIER
    end
    threat = threat * unitMultiplier

    -- HP scaling
    local hpDenominator = unit.startingHp or unit.currentHp or defaults.MIN_HP
    local hpRatio = unit.currentHp / hpDenominator
    threat = threat * hpRatio

    return threat
end

function aiEvaluation.analyzeHubThreat(self, state)
    -- Input validation
    if not self or not state or not state.commandHubs then return ZERO, {} end

    local evalParams = getEvalParams(self)
    local threatConfig = evalParams.THREAT or {}
    local defaultThreatConfig = DEFAULT_EVAL_PARAMS.THREAT or {}
    local hubMaxDistance = resolveValue(threatConfig.HUB_MAX_DISTANCE, defaultThreatConfig.HUB_MAX_DISTANCE)

    local ourPlayerNumber = GAME.CURRENT.AI_PLAYER_NUMBER
    local ourHub = state.commandHubs[ourPlayerNumber]

    if not ourHub then return ZERO, {} end

    
    local totalThreat = ZERO
    local threats = {}
    
    for _, unit in ipairs(state.units) do
        if unit.player ~= ourPlayerNumber then
            local distance = math.abs(unit.row - ourHub.row) + math.abs(unit.col - ourHub.col)
            
            -- Only consider units that could threaten the hub
            if distance <= hubMaxDistance then
                local threatLevel = self:assessUnitThreatLevel(unit, distance)
                totalThreat = totalThreat + threatLevel

                table.insert(threats, {
                    unit = unit,
                    distance = distance,
                    threatLevel = threatLevel
                })
            end
        end
    end
    
    -- Sort threats by priority
    table.sort(threats, function(a, b) 
        return a.threatLevel > b.threatLevel 
    end)
    
    return totalThreat, threats
end

return aiEvaluation
