local aiConfig = require('ai_config')
local randomGen = require('randomGenerator')

local M = {}

local AI_PARAMS = aiConfig.AI_PARAMS or {}
local PROFILE_PARAMS = AI_PARAMS.PROFILE or {}
local WIN_PERCENTAGE_PARAMS = AI_PARAMS.WIN_PERCENTAGE or {}
local SCORE_PARAMS = AI_PARAMS.SCORES or {}

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local DEFAULT_PROFILE_PARAMS = DEFAULT_AI_PARAMS.PROFILE or {}
local DEFAULT_WIN_PERCENTAGE_PARAMS = DEFAULT_AI_PARAMS.WIN_PERCENTAGE or {}
local DEFAULT_SCORE_PARAMS = DEFAULT_AI_PARAMS.SCORES or {}

local WIN_FALLBACK = WIN_PERCENTAGE_PARAMS.FALLBACK or DEFAULT_WIN_PERCENTAGE_PARAMS.FALLBACK or {}
local ZERO_VALUE = WIN_FALLBACK.ZERO_VALUE
local MIN_DENOMINATOR = WIN_FALLBACK.MIN_DENOMINATOR
local NEUTRAL_RATIO = WIN_FALLBACK.NEUTRAL_RATIO
local DEFAULT_EFFICIENCY = WIN_FALLBACK.DEFAULT_EFFICIENCY
local DEFAULT_TURN = WIN_FALLBACK.DEFAULT_TURN
local DEFAULT_GRID_SIZE = WIN_FALLBACK.DEFAULT_GRID_SIZE
local PERCENT_SCALE = WIN_FALLBACK.PERCENT_SCALE
local ONE_VALUE = MIN_DENOMINATOR
local HUB_FALLBACK_HP = ((SCORE_PARAMS.WINNING or {}).HUB_FALLBACK_HP)
    or ((DEFAULT_SCORE_PARAMS.WINNING or {}).HUB_FALLBACK_HP)
local BASE_AI_REFERENCE = "base"

local function resolveValue(value, fallbackValue)
    if value ~= nil then
        return value
    end
    return fallbackValue
end

local DEFAULT_AI_REFERENCE = resolveValue(
    PROFILE_PARAMS.DEFAULT_REFERENCE,
    resolveValue(DEFAULT_PROFILE_PARAMS.DEFAULT_REFERENCE, BASE_AI_REFERENCE)
)

local function getProfileParam(category, key)
    local cat = PROFILE_PARAMS[category]
    local defaultCat = DEFAULT_PROFILE_PARAMS[category]
    if cat and cat[key] ~= nil then
        return cat[key]
    end
    return defaultCat and defaultCat[key]
end

local function getWinWeight(key)
    local weights = WIN_PERCENTAGE_PARAMS.WEIGHTS or {}
    local defaultWeights = DEFAULT_WIN_PERCENTAGE_PARAMS.WEIGHTS or {}
    return resolveValue(weights[key], defaultWeights[key])
end

local function enforceLockedProfile(self)
    if not self.aiReference or self.aiReference == "" then
        self.aiReference = DEFAULT_AI_REFERENCE
    end
    self.profileType = "fixed"
    self.canChangeProfile = false
end

local function logWinChance(self, percentage, breakdown)
    local weightInfluence = getWinWeight("INFLUENCE")
    local weightUnitValue = getWinWeight("UNIT_VALUE")
    local weightHP = getWinWeight("HP")
    local weightHub = getWinWeight("HUB_HP")
    local weightSupply = getWinWeight("SUPPLY")

    self:logDecision(
        "WinChance",
        string.format(
            "Win%%: %.1f%% | Influence: %.1f/%.1f | UnitValue: %.1f/%.1f | HP: %.1f/%.1f | Hub: %.1f/%.1f | Supply: %.1f/%.1f",
            percentage,
            breakdown.influenceScore, weightInfluence,
            breakdown.unitValueScore, weightUnitValue,
            breakdown.hpScore, weightHP,
            breakdown.hubScore, weightHub,
            breakdown.supplyScore, weightSupply
        )
    )
end

function M.mixin(aiClass)
    function aiClass:randomizeEqualValueActions(actions, valueKey, tolerance)
        if not actions or #actions == ZERO_VALUE then
            return nil
        end

        if #actions == ONE_VALUE then
            return actions[ONE_VALUE]
        end

        local topValue = tonumber(actions[ONE_VALUE][valueKey]) or ZERO_VALUE
        local defaultTolerance = tonumber(getProfileParam('RANDOMIZER', 'BASE_TOLERANCE'))
        local scale = tonumber(getProfileParam('RANDOMIZER', 'VALUE_RATIO'))
        tolerance = tonumber(tolerance) or math.max(defaultTolerance, math.abs(topValue) * scale)

        local topActions = {}
        for _, action in ipairs(actions) do
            local actionValue = tonumber(action[valueKey]) or ZERO_VALUE
            local valueDiff = math.abs(actionValue - topValue)
            if valueDiff <= tolerance then
                table.insert(topActions, action)
            else
                break
            end
        end

        if #topActions == ONE_VALUE then
            return topActions[ONE_VALUE]
        end

        local deterministic = getProfileParam('RANDOMIZER', 'DETERMINISTIC')
        if deterministic ~= false then
            return topActions[ONE_VALUE]
        end

        local randomIndex = randomGen.randomInt(ONE_VALUE, #topActions)
        return topActions[randomIndex]
    end

    function aiClass:evaluateProfileFromInfluence(state)
        return BASE_AI_REFERENCE
    end

    function aiClass:calculateWinningPercentage(state)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return NEUTRAL_RATIO * PERCENT_SCALE
        end

        local weights = WIN_PERCENTAGE_PARAMS.WEIGHTS or {}
        local defaultWeights = DEFAULT_WIN_PERCENTAGE_PARAMS.WEIGHTS or {}
        local weightInfluence = resolveValue(weights.INFLUENCE, defaultWeights.INFLUENCE)
        local weightUnitValue = resolveValue(weights.UNIT_VALUE, defaultWeights.UNIT_VALUE)
        local weightHP = resolveValue(weights.HP, defaultWeights.HP)
        local weightHub = resolveValue(weights.HUB_HP, defaultWeights.HUB_HP)
        local weightSupply = resolveValue(weights.SUPPLY, defaultWeights.SUPPLY)

        local maxScore = weightInfluence + weightUnitValue + weightHP + weightHub + weightSupply
        if maxScore <= ZERO_VALUE then
            maxScore = MIN_DENOMINATOR
        end

        local score = ZERO_VALUE
        local defaultUnitValue = resolveValue(
            WIN_PERCENTAGE_PARAMS.DEFAULT_UNIT_VALUE,
            DEFAULT_WIN_PERCENTAGE_PARAMS.DEFAULT_UNIT_VALUE
        )

        -- Influence
        local influenceScore = weightInfluence * NEUTRAL_RATIO
        if self.influenceStats then
            local stats = self.influenceStats
            local gridSize = (GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or DEFAULT_GRID_SIZE
            local totalCells = gridSize * gridSize
            local positiveCells = stats.positiveCells or ZERO_VALUE
            local negativeCells = stats.negativeCells or ZERO_VALUE

            if totalCells > ZERO_VALUE then
                local netControl = (positiveCells - negativeCells) / totalCells
                local controlRatio = (netControl + MIN_DENOMINATOR) * NEUTRAL_RATIO
                influenceScore = controlRatio * weightInfluence
            end
        end
        score = score + influenceScore

        -- Unit value
        local friendlyValue = ZERO_VALUE
        local enemyValue = ZERO_VALUE
        if state.units then
            for _, unit in ipairs(state.units) do
                if unit.player == aiPlayer and unit.name ~= "Commandant" then
                    friendlyValue = friendlyValue + (self:getUnitBaseValue(unit, state) or defaultUnitValue)
                elseif unit.player ~= ZERO_VALUE and unit.player ~= aiPlayer and unit.name ~= "Rock" and unit.name ~= "Commandant" then
                    enemyValue = enemyValue + (self:getUnitBaseValue(unit, state) or defaultUnitValue)
                end
            end
        end

        local totalValue = friendlyValue + enemyValue
        local unitValueScore
        if totalValue > ZERO_VALUE then
            local valueRatio = friendlyValue / totalValue
            unitValueScore = valueRatio * weightUnitValue
        else
            unitValueScore = weightUnitValue * NEUTRAL_RATIO
        end
        score = score + unitValueScore

        -- Unit HP
        local friendlyHP = ZERO_VALUE
        local friendlyMaxHP = ZERO_VALUE
        local enemyHP = ZERO_VALUE
        local enemyMaxHP = ZERO_VALUE
        if state.units then
            for _, unit in ipairs(state.units) do
                local currentHP = unit.currentHp or unit.hp or ZERO_VALUE
                local maxHP = unit.startingHp or unit.hp or MIN_DENOMINATOR

                if unit.player == aiPlayer and unit.name ~= "Commandant" then
                    friendlyHP = friendlyHP + currentHP
                    friendlyMaxHP = friendlyMaxHP + maxHP
                elseif unit.player ~= ZERO_VALUE and unit.player ~= aiPlayer and unit.name ~= "Rock" and unit.name ~= "Commandant" then
                    enemyHP = enemyHP + currentHP
                    enemyMaxHP = enemyMaxHP + maxHP
                end
            end
        end

        local hpDistribution = WIN_PERCENTAGE_PARAMS.HP_WEIGHT_DISTRIBUTION or {}
        local defaultHpDistribution = DEFAULT_WIN_PERCENTAGE_PARAMS.HP_WEIGHT_DISTRIBUTION or {}
        local rawWeightRatio = resolveValue(hpDistribution.RAW, defaultHpDistribution.RAW)
        local efficiencyWeightRatio = resolveValue(hpDistribution.EFFICIENCY, defaultHpDistribution.EFFICIENCY)
        local ratioSum = rawWeightRatio + efficiencyWeightRatio
        if ratioSum == ZERO_VALUE then
            rawWeightRatio = defaultHpDistribution.RAW
            efficiencyWeightRatio = defaultHpDistribution.EFFICIENCY
            ratioSum = MIN_DENOMINATOR
        end

        local rawWeight = weightHP * (rawWeightRatio / ratioSum)
        local efficiencyWeight = weightHP * (efficiencyWeightRatio / ratioSum)

        local totalHP = friendlyHP + enemyHP
        local rawHPScore = totalHP > ZERO_VALUE and ((friendlyHP / totalHP) * rawWeight) or (rawWeight * NEUTRAL_RATIO)

        local friendlyEfficiency = friendlyMaxHP > ZERO_VALUE and (friendlyHP / friendlyMaxHP) or DEFAULT_EFFICIENCY
        local enemyEfficiency = enemyMaxHP > ZERO_VALUE and (enemyHP / enemyMaxHP) or DEFAULT_EFFICIENCY
        local totalEfficiency = friendlyEfficiency + enemyEfficiency
        local efficiencyScore = totalEfficiency > ZERO_VALUE and ((friendlyEfficiency / totalEfficiency) * efficiencyWeight) or (efficiencyWeight * NEUTRAL_RATIO)

        local hpScore = rawHPScore + efficiencyScore
        score = score + hpScore

        -- Commandant HP
        local friendlyHubHP = ZERO_VALUE
        local enemyHubHP = ZERO_VALUE
        if state.commandHubs then
            if state.commandHubs[aiPlayer] then
                friendlyHubHP = state.commandHubs[aiPlayer].currentHp or state.commandHubs[aiPlayer].hp or HUB_FALLBACK_HP
            end

            for player, hub in pairs(state.commandHubs) do
                if player ~= aiPlayer and player ~= ZERO_VALUE then
                    enemyHubHP = hub.currentHp or hub.hp or HUB_FALLBACK_HP
                    break
                end
            end
        end

        local totalHubHP = friendlyHubHP + enemyHubHP
        local hubScore
        if totalHubHP > ZERO_VALUE then
            local hubRatio = friendlyHubHP / totalHubHP
            hubScore = hubRatio * weightHub
        else
            hubScore = weightHub * NEUTRAL_RATIO
        end
        score = score + hubScore

        -- Supply
        local friendlySupplyValue = ZERO_VALUE
        local enemySupplyValue = ZERO_VALUE
        local supplyValues = WIN_PERCENTAGE_PARAMS.SUPPLY_UNIT_VALUES or {}
        local defaultSupplyValues = DEFAULT_WIN_PERCENTAGE_PARAMS.SUPPLY_UNIT_VALUES or {}
        local defaultSupplyValue = resolveValue(supplyValues.DEFAULT, defaultSupplyValues.DEFAULT)

        if state.supplyPanels then
            for player, supply in pairs(state.supplyPanels) do
                if player == aiPlayer and supply then
                    for _, unitName in ipairs(supply) do
                        local unitValue = supplyValues[unitName] or defaultSupplyValue
                        friendlySupplyValue = friendlySupplyValue + unitValue
                    end
                elseif player ~= ZERO_VALUE and player ~= aiPlayer and supply then
                    for _, unitName in ipairs(supply) do
                        local unitValue = supplyValues[unitName] or defaultSupplyValue
                        enemySupplyValue = enemySupplyValue + unitValue
                    end
                end
            end
        end

        local totalSupplyValue = friendlySupplyValue + enemySupplyValue
        local supplyScore
        if totalSupplyValue > ZERO_VALUE then
            supplyScore = (friendlySupplyValue / totalSupplyValue) * weightSupply
        else
            supplyScore = weightSupply * NEUTRAL_RATIO
        end
        score = score + supplyScore

        -- Final percentage
        local percentage = (score / maxScore) * PERCENT_SCALE
        percentage = math.max(ZERO_VALUE, math.min(PERCENT_SCALE, percentage))

        logWinChance(self, percentage, {
            influenceScore = influenceScore,
            unitValueScore = unitValueScore,
            hpScore = hpScore,
            hubScore = hubScore,
            supplyScore = supplyScore
        })

        return percentage
    end

    function aiClass:updateWinPercentageProfile(turn, state)
        enforceLockedProfile(self)
    end

    function aiClass:updateAdaptiveProfile(turn, state)
        enforceLockedProfile(self)
    end
end

return M
