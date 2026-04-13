-- AI Safety and Tactics Module
-- Handles suicide prevention, beneficial trades, and tactical analysis

local unitsInfo = require('unitsInfo')
local aiMovement = require('ai_movement')
local aiInfluence = require('ai_influence')
local aiConfig = require('ai_config')
local aiSafety = {}

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local DEFAULT_SAFETY_MODEL = DEFAULT_AI_PARAMS.SAFETY_MODEL or {}
local DEFAULT_SAFETY_DEFAULTS = DEFAULT_SAFETY_MODEL.DEFAULTS or {}
local DEFAULT_RUNTIME = DEFAULT_AI_PARAMS.RUNTIME or {}
local ZERO_VALUE = DEFAULT_SAFETY_DEFAULTS.ZERO_DAMAGE or DEFAULT_RUNTIME.ZERO
local ONE_VALUE = DEFAULT_SAFETY_DEFAULTS.MIN_HP or DEFAULT_RUNTIME.MIN_HP
local NEGATIVE_ONE_VALUE = -ONE_VALUE
local ORTHOGONAL_DIRECTIONS = {
    {row = ONE_VALUE, col = ZERO_VALUE},
    {row = NEGATIVE_ONE_VALUE, col = ZERO_VALUE},
    {row = ZERO_VALUE, col = ONE_VALUE},
    {row = ZERO_VALUE, col = NEGATIVE_ONE_VALUE}
}

local function resolveValue(value, fallbackValue)
    if value ~= nil then
        return value
    end
    return fallbackValue
end

local function getSafetyModel(self)
    if self and self.AI_PARAMS and self.AI_PARAMS.SAFETY_MODEL then
        return self.AI_PARAMS.SAFETY_MODEL
    end
    return DEFAULT_SAFETY_MODEL
end

local function getSafetyDefault(self, key)
    local model = getSafetyModel(self)
    local defaults = model.DEFAULTS or {}
    if defaults[key] ~= nil then
        return defaults[key]
    end
    return DEFAULT_SAFETY_DEFAULTS[key]
end

local function getSafetySetting(self, key)
    local model = getSafetyModel(self)
    if model[key] ~= nil then
        return model[key]
    end
    return DEFAULT_SAFETY_MODEL[key]
end

local function getSafeUnitHp(self, unit)
    return unit.currentHp or unit.startingHp or getSafetyDefault(self, "MIN_HP")
end

local function getOpposingHub(self, state, playerId)
    local neutralPlayerId = getSafetyDefault(self, "NEUTRAL_PLAYER_ID")
    for hubPlayer, hub in pairs(state.commandHubs or {}) do
        if hub and hubPlayer ~= playerId and hubPlayer ~= neutralPlayerId then
            return hub
        end
    end
    return nil
end

local function getUnitRangeBand(self, unit, rangeContext)
    local attackRange = unitsInfo:getUnitAttackRange(unit, rangeContext) or getSafetyDefault(self, "DEFAULT_ATTACK_RANGE")
    local minRange
    if unitsInfo:canAttackAdjacent(unit.name) then
        minRange = getSafetySetting(self, "ADJACENT_RANGE")
    else
        minRange = getSafetySetting(self, "RANGED_MIN_RANGE")
    end
    return minRange, attackRange
end

local function isPositionBetweenOrthogonal(fromPos, toPos, blockPos)
    if not fromPos or not toPos or not blockPos then
        return false
    end

    if fromPos.row == toPos.row and blockPos.row == fromPos.row then
        local minCol = math.min(fromPos.col, toPos.col)
        local maxCol = math.max(fromPos.col, toPos.col)
        return blockPos.col > minCol and blockPos.col < maxCol
    end

    if fromPos.col == toPos.col and blockPos.col == fromPos.col then
        local minRow = math.min(fromPos.row, toPos.row)
        local maxRow = math.max(fromPos.row, toPos.row)
        return blockPos.row > minRow and blockPos.row < maxRow
    end

    return false
end

local function hasLineOfSightIgnoringMover(self, state, fromPos, toPos, movingUnit)
    local hasLOS = self:hasLineOfSight(state, fromPos, toPos)
    if hasLOS then
        return true
    end

    if not movingUnit or not movingUnit.row or not movingUnit.col then
        return false
    end

    return isPositionBetweenOrthogonal(fromPos, toPos, {row = movingUnit.row, col = movingUnit.col})
end

local function isPositionOccupiedIgnoringMover(self, state, position, movingUnit)
    local occupied = aiSafety.isPositionOccupied(self, state, position)
    if not occupied then
        return false
    end

    if movingUnit and movingUnit.row == position.row and movingUnit.col == position.col then
        return false
    end

    return true
end

local function appendMovingUnitOriginIfReachable(self, state, enemy, movingUnit, moveCells, rangeContext)
    if not movingUnit or not movingUnit.row or not movingUnit.col or not moveCells then
        return
    end

    local moveRange = unitsInfo:getUnitMoveRange(enemy, rangeContext) or ZERO_VALUE
    if moveRange <= ZERO_VALUE then
        return
    end

    local distance = math.abs(enemy.row - movingUnit.row) + math.abs(enemy.col - movingUnit.col)
    if distance > moveRange then
        return
    end

    for _, cell in ipairs(moveCells) do
        if cell.row == movingUnit.row and cell.col == movingUnit.col then
            return
        end
    end

    local moverOrigin = {row = movingUnit.row, col = movingUnit.col}
    if aiMovement.canUnitReachPosition(self, state, enemy, moverOrigin) then
        table.insert(moveCells, moverOrigin)
    end
end

local function canUnitAttackFromPosition(self, state, enemy, fromPos, targetPos, defendingUnit, movingUnit, rangeContext)
    if not enemy or not fromPos or not targetPos or not defendingUnit then
        return false, ZERO_VALUE
    end

    local attackDistance = math.abs(fromPos.row - targetPos.row) + math.abs(fromPos.col - targetPos.col)
    local minRange, maxRange = getUnitRangeBand(self, enemy, rangeContext)
    if attackDistance < minRange or attackDistance > maxRange then
        return false, ZERO_VALUE
    end

    if enemy.name == "Cloudstriker" then
        if not hasLineOfSightIgnoringMover(self, state, fromPos, targetPos, movingUnit) then
            return false, ZERO_VALUE
        end
    elseif enemy.name ~= "Artillery" then
        local adjacentRange = getSafetySetting(self, "ADJACENT_RANGE")
        if attackDistance > adjacentRange then
            return false, ZERO_VALUE
        end
    end

    local damage = unitsInfo:calculateAttackDamage(enemy, defendingUnit)
    if not damage or damage <= ZERO_VALUE then
        return false, ZERO_VALUE
    end

    return true, damage
end

local function computeWorstCaseDamage(self, oneActionDamages, twoActionDamages)
    oneActionDamages = oneActionDamages or {}
    twoActionDamages = twoActionDamages or {}
    local zeroDamage = getSafetyDefault(self, "ZERO_DAMAGE")
    local firstDamageIndex = getSafetyDefault(self, "FIRST_DAMAGE_INDEX")
    local secondDamageIndex = getSafetyDefault(self, "SECOND_DAMAGE_INDEX")

    table.sort(oneActionDamages, function(a, b) return a > b end)
    table.sort(twoActionDamages, function(a, b) return a > b end)

    local bestTwoAction = twoActionDamages[firstDamageIndex] or zeroDamage
    local firstOneAction = oneActionDamages[firstDamageIndex] or zeroDamage
    local secondOneAction = oneActionDamages[secondDamageIndex] or zeroDamage

    return math.max(bestTwoAction, firstOneAction + secondOneAction)
end


function aiSafety.isSuicidalMovement(self, state, targetPos, unit)
    -- Input validation
    if not self or not state or not state.units or not unit or not targetPos then
        return false
    end

    local oneActionDamages = {}
    local twoActionDamages = {}
    local adjacentRange = getSafetySetting(self, "ADJACENT_RANGE")

    local function addOneActionDamage(damage)
        if damage and damage > ZERO_VALUE then
            table.insert(oneActionDamages, damage)
        end
    end

    -- Immediate (single-action) threats from current enemy positions
    for _, enemy in ipairs(state.units) do
        if enemy.player ~= unit.player and enemy.name ~= "Rock" then
            local canAttack, damage = canUnitAttackFromPosition(
                self,
                state,
                enemy,
                {row = enemy.row, col = enemy.col},
                targetPos,
                unit,
                unit,
                "SUICIDAL_MOVE_RANGE"
            )
            if canAttack then
                addOneActionDamage(damage)
            end
        end
    end

    -- Commandant adjacency threats
    if state.commandHubs then
        for playerNum, hub in pairs(state.commandHubs) do
            if hub and playerNum ~= unit.player then
                local distance = math.abs(targetPos.row - hub.row) + math.abs(targetPos.col - hub.col)
                if distance <= adjacentRange then
                    local hubUnit = {
                        name = "Commandant",
                        player = playerNum,
                        row = hub.row,
                        col = hub.col,
                        currentHp = hub.currentHp,
                        startingHp = hub.startingHp
                    }
                    addOneActionDamage(unitsInfo:calculateAttackDamage(hubUnit, unit))
                end
            end
        end
    end

    -- Move+attack (two-action) threats
    local meleeMoveDamage = aiSafety.isVulnerableToMoveMeleeAttack(self, state, targetPos, unit)
    if meleeMoveDamage and meleeMoveDamage > ZERO_VALUE then
        table.insert(twoActionDamages, meleeMoveDamage)
    end

    local rangedMoveDamage = aiSafety.isVulnerableToMoveRangedAttack(self, state, targetPos, unit)
    if rangedMoveDamage and rangedMoveDamage > ZERO_VALUE then
        table.insert(twoActionDamages, rangedMoveDamage)
    end

    local unitHp = getSafeUnitHp(self, unit)
    local worstDamage = computeWorstCaseDamage(self, oneActionDamages, twoActionDamages)
    return worstDamage >= unitHp
end

function aiSafety.isSuicidalAttack(self, state, attacker, target)
    if not self or not state or not attacker or not target then
        return false
    end

    local adjacentRange = getSafetySetting(self, "ADJACENT_RANGE")

    local damage = unitsInfo:calculateAttackDamage(attacker, target)
    local targetHpAfter = getSafeUnitHp(self, target) - damage
    local isKillAttack = targetHpAfter <= ZERO_VALUE
    local attackRange = unitsInfo:getUnitAttackRange(attacker, "SUICIDAL_ATTACK")
    local canAttackAdjacent = unitsInfo:canAttackAdjacent(attacker.name)
    local isRangedAttacker = attackRange and attackRange > adjacentRange and not canAttackAdjacent


    if isKillAttack then
        if isRangedAttacker then
            return false
        end

        local targetPos = {row = target.row, col = target.col}

        local tempState = {
            units = {},
            commandHubs = state.commandHubs,
            neutralBuildings = state.neutralBuildings
        }

        local unitsRemoved = ZERO_VALUE
        for _, unit in ipairs(state.units) do
            if not (unit.row == target.row and unit.col == target.col and unit.player == target.player) then
                table.insert(tempState.units, unit)
            else
                unitsRemoved = unitsRemoved + ONE_VALUE
            end
        end


        if self:isSuicidalMovement(tempState, targetPos, attacker) then
            return true
        end

        return false
    end

    local currentPos = {row = attacker.row, col = attacker.col}
    local oneActionDamages = {}
    local twoActionDamages = {}

    local function addImmediateDamage(damage)
        if damage and damage > ZERO_VALUE then
            table.insert(oneActionDamages, damage)
        end
    end

    -- Immediate threats after the attack resolves
    for _, enemy in ipairs(state.units) do
        if enemy.player ~= attacker.player and enemy ~= target and enemy.name ~= "Rock" then
            local canAttack, damage = canUnitAttackFromPosition(
                self,
                state,
                enemy,
                {row = enemy.row, col = enemy.col},
                currentPos,
                attacker,
                nil,
                "SUICIDAL_ATTACK_RANGE"
            )
            if canAttack then
                addImmediateDamage(damage)
            end
        end
    end

    -- Commandant adjacency threat
    if state.commandHubs then
        for playerNum, hub in pairs(state.commandHubs) do
            if hub and playerNum ~= attacker.player then
                local distance = math.abs(hub.row - currentPos.row) + math.abs(hub.col - currentPos.col)
                if distance <= adjacentRange then
                    local hubUnit = {
                        name = "Commandant",
                        player = playerNum,
                        row = hub.row,
                        col = hub.col,
                        currentHp = hub.currentHp,
                        startingHp = hub.startingHp
                    }
                    addImmediateDamage(unitsInfo:calculateAttackDamage(hubUnit, attacker))
                end
            end
        end
    end

    -- Move+attack threats after the attack
    local meleeMoveDamage = aiSafety.isVulnerableToMoveMeleeAttack(self, state, currentPos, attacker)
    if meleeMoveDamage and meleeMoveDamage > ZERO_VALUE then
        table.insert(twoActionDamages, meleeMoveDamage)
    end

    local rangedMoveDamage = aiSafety.isVulnerableToMoveRangedAttack(self, state, currentPos, attacker)
    if rangedMoveDamage and rangedMoveDamage > ZERO_VALUE then
        table.insert(twoActionDamages, rangedMoveDamage)
    end

    local attackerHp = getSafeUnitHp(self, attacker)
    local worstDamage = computeWorstCaseDamage(self, oneActionDamages, twoActionDamages)
    return worstDamage >= attackerHp
end

-- Helper function to check if a position is occupied by any unit or Commandant
function aiSafety.isPositionOccupied(self, state, position)
    -- Check if any unit occupies this position
    for _, unit in ipairs(state.units) do
        if unit.row == position.row and unit.col == position.col then
            return true
        end
    end

    -- Check if Commandant occupies this position
    if state.commandHubs then
        for _, hub in pairs(state.commandHubs) do
            if hub and hub.row == position.row and hub.col == position.col then
                return true
            end
        end
    end

    return false
end

-- Helper function to check vulnerability to melee move+attack combinations
function aiSafety.isVulnerableToMoveMeleeAttack(self, state, targetPos, unit)
    local maxDamage = ZERO_VALUE

    -- Check each enemy melee unit to see if it could move adjacent and attack
    for _, enemy in ipairs(state.units) do
        if enemy.player ~= unit.player and enemy.name ~= "Commandant" and enemy.name ~= "Rock" then
            -- Skip ranged units (handled by separate function)
            if enemy.name ~= "Cloudstriker" and enemy.name ~= "Artillery" then
                -- Melee units: range 1, need to move adjacent
                local adjacentCells = {
                    {row = targetPos.row - ONE_VALUE, col = targetPos.col},     -- up
                    {row = targetPos.row + ONE_VALUE, col = targetPos.col},     -- down
                    {row = targetPos.row, col = targetPos.col - ONE_VALUE},     -- left
                    {row = targetPos.row, col = targetPos.col + ONE_VALUE}      -- right
                }

                for _, adjCell in ipairs(adjacentCells) do
                    -- Use proper pathfinding to check if enemy can actually reach this adjacent cell
                    local canEnemyReach = aiMovement.canUnitReachPosition(self, state, enemy, adjCell)

                    if canEnemyReach then
                        local cellOccupied = isPositionOccupiedIgnoringMover(self, state, adjCell, unit)

                        -- If cell is free, enemy could move there and attack
                        if not cellOccupied then
                            local damage = unitsInfo:calculateAttackDamage(enemy, unit)
                            if damage and damage > maxDamage then
                                maxDamage = damage
                            end
                            break -- Only count one attack per enemy
                        end
                    end
                end
            end
        end
    end

    return maxDamage
end

-- Helper function to check vulnerability to ranged move+attack combinations
function aiSafety.isVulnerableToMoveRangedAttack(self, state, targetPos, unit)
    local maxDamage = ZERO_VALUE

    -- Check each enemy ranged unit to see if it could move and attack
    for _, enemy in ipairs(state.units) do
        if enemy.player ~= unit.player and (enemy.name == "Cloudstriker" or enemy.name == "Artillery") then
            local moveCells = self:getValidMoveCells(state, enemy.row, enemy.col) or {}
            appendMovingUnitOriginIfReachable(
                self,
                state,
                enemy,
                unit,
                moveCells,
                "VULNERABLE_MOVE_RANGED_MOVE_RANGE"
            )

            for _, movePos in ipairs(moveCells) do
                if not isPositionOccupiedIgnoringMover(self, state, movePos, unit) then
                    local canAttack, damage = canUnitAttackFromPosition(
                        self,
                        state,
                        enemy,
                        movePos,
                        targetPos,
                        unit,
                        unit,
                        "VULNERABLE_MOVE_RANGED_RANGE"
                    )
                    if canAttack and damage > maxDamage then
                        maxDamage = damage
                    end
                end
            end
        end
    end

    return maxDamage
end

-- Main function to check if a position is vulnerable to enemy move+attack combinations (aka can die in that position)
function aiSafety.isVulnerableToMoveAttack(self, state, targetPos, unit)
    -- Input validation
    if not self or not state or not state.units or not unit or not targetPos then return false end

    local adjacentRange = getSafetySetting(self, "ADJACENT_RANGE")
    local unitHp = getSafeUnitHp(self, unit)

    local oneActionDamages = {}
    local twoActionDamages = {}

    local meleeDamage = aiSafety.isVulnerableToMoveMeleeAttack(self, state, targetPos, unit)
    if meleeDamage and meleeDamage > ZERO_VALUE then
        table.insert(twoActionDamages, meleeDamage)
    end

    local rangedDamage = aiSafety.isVulnerableToMoveRangedAttack(self, state, targetPos, unit)
    if rangedDamage and rangedDamage > ZERO_VALUE then
        table.insert(twoActionDamages, rangedDamage)
    end

    -- Add Commandant damage if it can attack the target position
    if state.commandHubs then
        for playerNum, hub in pairs(state.commandHubs) do
            if hub and playerNum ~= unit.player then
                local distance = math.abs(targetPos.row - hub.row) + math.abs(targetPos.col - hub.col)
                -- Commandant has atkRange = 1, can attack adjacent cells
                if distance <= adjacentRange then
                    local hubUnit = {
                        name = "Commandant",
                        player = playerNum,
                        row = hub.row,
                        col = hub.col,
                        currentHp = hub.currentHp,
                        startingHp = hub.startingHp
                    }
                    local hubDamage = unitsInfo:calculateAttackDamage(hubUnit, unit)
                    if hubDamage and hubDamage > ZERO_VALUE then
                        table.insert(oneActionDamages, hubDamage)
                    end
                end
            end
        end
    end

    local worstDamage = computeWorstCaseDamage(self, oneActionDamages, twoActionDamages)
    return worstDamage >= unitHp
end

function aiSafety.isBeneficialSuicidalAttack(self, state, attacker, target)
    -- Input validation
    if not self or not state or not attacker or not target then return false end

    local safetyModel = getSafetyModel(self)
    local beneficialConfig = safetyModel.BENEFICIAL_SUICIDE or {}
    local defaultBeneficialConfig = DEFAULT_SAFETY_MODEL.BENEFICIAL_SUICIDE or {}
    local zeroDamage = getSafetyDefault(self, "ZERO_DAMAGE")
    local minHp = getSafetyDefault(self, "MIN_HP")
    local alwaysBeneficialTargets = {}
    for _, targetName in ipairs(beneficialConfig.ALWAYS_BENEFICIAL_TARGETS or defaultBeneficialConfig.ALWAYS_BENEFICIAL_TARGETS or {}) do
        alwaysBeneficialTargets[targetName] = true
    end
    local killTradeRatioMin = resolveValue(beneficialConfig.KILL_TRADE_RATIO_MIN, defaultBeneficialConfig.KILL_TRADE_RATIO_MIN)
    local nonKillMaxTargetHp = resolveValue(beneficialConfig.NON_KILL_MAX_TARGET_HP, defaultBeneficialConfig.NON_KILL_MAX_TARGET_HP)
    local nonKillTradeRatioMin = resolveValue(beneficialConfig.NON_KILL_TRADE_RATIO_MIN, defaultBeneficialConfig.NON_KILL_TRADE_RATIO_MIN)

    local attackerValue = self.getUnitBaseValue and self:getUnitBaseValue(attacker, state) or zeroDamage
    local targetValue = self.getUnitBaseValue and self:getUnitBaseValue(target, state) or zeroDamage

    -- Calculate expected damage
    local damage = unitsInfo:calculateAttackDamage(attacker, target)
    local targetHp = target.currentHp or target.startingHp or minHp
    local targetHpAfter = targetHp - damage

    -- ENHANCED: Include positional/influence value in trade evaluation
    local attackerPositionalValue = zeroDamage
    local targetPositionalValue = zeroDamage
    
    if self.influenceMap and aiInfluence then
        -- Get influence scores for both units
        local attackerInfluence = aiInfluence:evaluatePosition(
            self.influenceMap, 
            attacker.row, 
            attacker.col
        )
        local targetInfluence = aiInfluence:evaluatePosition(
            self.influenceMap, 
            target.row, 
            target.col
        )
        
        -- Attacker's position value (positive = good position for us)
        attackerPositionalValue = attackerInfluence or zeroDamage
        
        -- Target's position value (we flip sign because it's enemy position)
        -- If enemy is at +40 influence (good for them), it's -40 for us
        targetPositionalValue = -(targetInfluence or zeroDamage)
    end
    
    -- Calculate total values (unit + position)
    local attackerTotalValue = attackerValue + attackerPositionalValue
    local targetTotalValue = targetValue + math.abs(targetPositionalValue)  -- Absolute because we gain by removing enemy from good position
    
    -- Beneficial if we trade favorably (considering both unit and position value)
    local tradeRatio = targetTotalValue / math.max(minHp, attackerTotalValue)

    -- Special cases for high-value targets - always worth attacking
    if alwaysBeneficialTargets[target.name] then
        return true
    end

    -- Check if this is a kill attack
    if targetHpAfter <= ZERO_VALUE then
        -- Kill attack: more lenient trade ratio for kills (1:1 is acceptable)
        -- Now considers: "Is killing this enemy (unit + position) worth losing our unit (unit + position)?"
        return tradeRatio >= killTradeRatioMin
    else
        -- Non-kill attack: need to leave target with very low HP and have good trade ratio
        return targetHpAfter <= nonKillMaxTargetHp and tradeRatio >= nonKillTradeRatioMin
    end
end

function aiSafety.isStrategicNeutralBuildingAttack(self, state, attacker, building)
    -- Input validation
    if not self or not state or not attacker or not building then return false end

    local safetyModel = getSafetyModel(self)
    local neutralConfig = safetyModel.NEUTRAL_BUILDING or {}
    local defaultNeutralConfig = DEFAULT_SAFETY_MODEL.NEUTRAL_BUILDING or {}
    local zeroDamage = getSafetyDefault(self, "ZERO_DAMAGE")
    local nearbyEnemyDistance = resolveValue(neutralConfig.NEARBY_ENEMY_DISTANCE, defaultNeutralConfig.NEARBY_ENEMY_DISTANCE)
    local nearbyEnemyMin = resolveValue(neutralConfig.NEARBY_ENEMY_MIN, defaultNeutralConfig.NEARBY_ENEMY_MIN)
    local nearbyEnemyBonus = resolveValue(neutralConfig.NEARBY_ENEMY_BONUS, defaultNeutralConfig.NEARBY_ENEMY_BONUS)
    local directionalBonus = resolveValue(neutralConfig.DIRECTIONAL_BONUS, defaultNeutralConfig.DIRECTIONAL_BONUS)
    local minStrategicValue = resolveValue(neutralConfig.MIN_STRATEGIC_VALUE, defaultNeutralConfig.MIN_STRATEGIC_VALUE)

    -- Never attack Rocks if it would be suicidal
    local attackerPos = {row = attacker.row, col = attacker.col}
    if self:isSuicidalMovement(state, attackerPos, attacker) then
        return false
    end

    -- Strategic reasons to attack Rocks:
    -- 1. Blocking enemy movement
    -- 2. Creating tactical advantage
    -- 3. Denying enemy cover

    local strategicValue = zeroDamage

    -- Check if building blocks important paths
    local buildingPos = {row = building.row, col = building.col}

    -- Count nearby enemy units that might use this for cover
    local nearbyEnemies = zeroDamage
    for _, unit in ipairs(state.units) do
        if unit.player ~= attacker.player then
            local distance = math.abs(unit.row - building.row) + math.abs(unit.col - building.col)
            if distance <= nearbyEnemyDistance then
                nearbyEnemies = nearbyEnemies + ONE_VALUE
            end
        end
    end

    if nearbyEnemies >= nearbyEnemyMin then
        strategicValue = strategicValue + nearbyEnemyBonus
    end

    -- Check if it's blocking our advance
    local ourHub = state.commandHubs[attacker.player]
    local enemyHub = getOpposingHub(self, state, attacker.player)

    if ourHub and enemyHub then
        -- If building is roughly between our hub and enemy hub
        local hubToHub = {
            row = enemyHub.row - ourHub.row,
            col = enemyHub.col - ourHub.col
        }
        local hubToBuilding = {
            row = building.row - ourHub.row,
            col = building.col - ourHub.col
        }

        -- Simple check if building is in the general direction
        local dotProduct = (hubToHub.row * hubToBuilding.row) + (hubToHub.col * hubToBuilding.col)
        if dotProduct > ZERO_VALUE then
            strategicValue = strategicValue + directionalBonus
        end
    end

    return strategicValue >= minStrategicValue
end

function aiSafety.isDeadEndPosition(self, state, targetPos, unit)
    local safetyModel = getSafetyModel(self)
    local deadEndConfig = safetyModel.DEAD_END or {}
    local defaultDeadEndConfig = DEFAULT_SAFETY_MODEL.DEAD_END or {}
    local minHp = getSafetyDefault(self, "MIN_HP")
    local deadEndRouteMax = resolveValue(deadEndConfig.DEAD_END_ROUTE_MAX, defaultDeadEndConfig.DEAD_END_ROUTE_MAX)
    local restrictionHigh = resolveValue(deadEndConfig.RESTRICTION_HIGH, defaultDeadEndConfig.RESTRICTION_HIGH)
    local restrictionMidRouteMax = resolveValue(deadEndConfig.RESTRICTION_MID_ROUTE_MAX, defaultDeadEndConfig.RESTRICTION_MID_ROUTE_MAX)
    local restrictionMid = resolveValue(deadEndConfig.RESTRICTION_MID, defaultDeadEndConfig.RESTRICTION_MID)
    local restrictionLow = resolveValue(deadEndConfig.RESTRICTION_LOW, defaultDeadEndConfig.RESTRICTION_LOW)

    local escapeRoutes = getSafetyDefault(self, "ZERO_DAMAGE")

    for _, dir in ipairs(ORTHOGONAL_DIRECTIONS) do
        local checkRow = targetPos.row + dir.row
        local checkCol = targetPos.col + dir.col

        -- Check bounds
        if checkRow >= minHp and checkRow <= GAME.CONSTANTS.GRID_SIZE and
           checkCol >= minHp and checkCol <= GAME.CONSTANTS.GRID_SIZE then

            local isBlocked = false

            -- Check for units (except original position)
            local occupyingUnit = self.aiState.getUnitAtPosition(state, checkRow, checkCol)
            if occupyingUnit then
                if checkRow == unit.row and checkCol == unit.col then
                    escapeRoutes = escapeRoutes + ONE_VALUE -- Original position counts as escape
                else
                    isBlocked = true
                end
            end

            -- Check for Rocks
            if not isBlocked and state.neutralBuildings then
                for _, building in ipairs(state.neutralBuildings) do
                    if building.row == checkRow and building.col == checkCol then
                        isBlocked = true
                        break
                    end
                end
            end

            -- Check for Commandants
            if not isBlocked then
                for _, hub in pairs(state.commandHubs) do
                    if hub.row == checkRow and hub.col == checkCol then
                        isBlocked = true
                        break
                    end
                end
            end

            if not isBlocked then
                escapeRoutes = escapeRoutes + ONE_VALUE
            end
        end
    end

    -- Dead end criteria
    local isDeadEnd = escapeRoutes <= deadEndRouteMax
    local restrictionLevel
    if escapeRoutes <= deadEndRouteMax then
        restrictionLevel = restrictionHigh
    elseif escapeRoutes == restrictionMidRouteMax then
        restrictionLevel = restrictionMid
    else
        restrictionLevel = restrictionLow
    end

    return isDeadEnd, restrictionLevel, escapeRoutes
end

function aiSafety.wouldBlockLineOfSight(self, state, cell, direction)
    if not direction then return false end
    local safetyModel = getSafetyModel(self)
    local lineConfig = safetyModel.LINE_OF_SIGHT_BLOCK or {}
    local defaultLineConfig = DEFAULT_SAFETY_MODEL.LINE_OF_SIGHT_BLOCK or {}
    local minHp = getSafetyDefault(self, "MIN_HP")
    local zeroDamage = getSafetyDefault(self, "ZERO_DAMAGE")
    local checkDistance = resolveValue(lineConfig.CHECK_DISTANCE, defaultLineConfig.CHECK_DISTANCE)

    -- Normalize direction
    local dx = direction.row ~= zeroDamage and direction.row/math.abs(direction.row) or zeroDamage
    local dy = direction.col ~= zeroDamage and direction.col/math.abs(direction.col) or zeroDamage
    local isInLine = false
    local aiPlayer = (self and self.getFactionId and self:getFactionId())
        or (GAME.CURRENT and GAME.CURRENT.AI_PLAYER_NUMBER)
        or ONE_VALUE

    -- Check if we're protecting an ally
    for i = ONE_VALUE, checkDistance do
        local checkRow = cell.row + (dx * i)
        local checkCol = cell.col + (dy * i)

        if checkRow < minHp or checkRow > GAME.CONSTANTS.GRID_SIZE or
           checkCol < minHp or checkCol > GAME.CONSTANTS.GRID_SIZE then
            break
        end

        local targetUnit = self.aiState.getUnitAtPosition(state, checkRow, checkCol)
        if targetUnit and targetUnit.player == aiPlayer then
            isInLine = true
            break
        end
    end

    -- Check for enemy shooters in opposite direction
    for i = ONE_VALUE, checkDistance do
        local checkRow = cell.row - (dx * i)
        local checkCol = cell.col - (dy * i)

        if checkRow < minHp or checkRow > GAME.CONSTANTS.GRID_SIZE or
           checkCol < minHp or checkCol > GAME.CONSTANTS.GRID_SIZE then
            break
        end

        local potentialShooter = self.aiState.getUnitAtPosition(state, checkRow, checkCol)
        if potentialShooter and 
           potentialShooter.player ~= aiPlayer and
           potentialShooter.name == "Cloudstriker" and
           isInLine then
            return true
        end
    end

    return false
end

function aiSafety.hasGoodFiringLanes(self, state, pos)
    local safetyModel = getSafetyModel(self)
    local laneConfig = safetyModel.FIRING_LANES or {}
    local defaultLaneConfig = DEFAULT_SAFETY_MODEL.FIRING_LANES or {}
    local minHp = getSafetyDefault(self, "MIN_HP")
    local zeroDamage = getSafetyDefault(self, "ZERO_DAMAGE")
    local checkDistance = resolveValue(laneConfig.CHECK_DISTANCE, defaultLaneConfig.CHECK_DISTANCE)
    local clearCellsRequired = resolveValue(laneConfig.CLEAR_CELLS_REQUIRED, defaultLaneConfig.CLEAR_CELLS_REQUIRED)
    local goodLanesRequired = resolveValue(laneConfig.GOOD_LANES_REQUIRED, defaultLaneConfig.GOOD_LANES_REQUIRED)

    local goodLanes = zeroDamage

    for _, dir in ipairs(ORTHOGONAL_DIRECTIONS) do
        local clearCells = zeroDamage
        for dist = ONE_VALUE, checkDistance do
            local checkRow = pos.row + (dir.row * dist)
            local checkCol = pos.col + (dir.col * dist)

            if checkRow < minHp or checkRow > GAME.CONSTANTS.GRID_SIZE or
               checkCol < minHp or checkCol > GAME.CONSTANTS.GRID_SIZE then
                break
            end

            if self.aiState.isPositionBlocked(state, checkRow, checkCol) then
                break
            end

            clearCells = clearCells + ONE_VALUE
        end

        if clearCells >= clearCellsRequired then
            goodLanes = goodLanes + ONE_VALUE
        end
    end

    return goodLanes >= goodLanesRequired
end

-- Comprehensive helper function to check if a position is completely safe from all possible threats
-- Checks for: adjacent attacks, ranged attacks, and move+attack combinations
function aiSafety.isPositionCompletelySafe(self, state, position, unit)
    -- Input validation
    if not self or not state or not state.units or not unit or not position then 
        return false 
    end

    local safetyModel = getSafetyModel(self)
    local adjacentRange = getSafetySetting(self, "ADJACENT_RANGE")
    local completeSafetyConfig = safetyModel.COMPLETE_SAFETY or {}
    local defaultCompleteSafetyConfig = DEFAULT_SAFETY_MODEL.COMPLETE_SAFETY or {}
    local safeDamageThreshold = resolveValue(completeSafetyConfig.SAFE_DAMAGE_THRESHOLD, defaultCompleteSafetyConfig.SAFE_DAMAGE_THRESHOLD)

    local oneActionDamages = {}
    local twoActionDamages = {}

    -- PHASE 1: Check immediate threats from current enemy positions

    for _, enemy in ipairs(state.units) do
        if enemy.player ~= unit.player and enemy.name ~= "Rock" then
            local canAttack, damage = canUnitAttackFromPosition(
                self,
                state,
                enemy,
                {row = enemy.row, col = enemy.col},
                position,
                unit,
                unit,
                "COMPLETE_SAFETY_IMMEDIATE_RANGE"
            )
            if canAttack then
                table.insert(oneActionDamages, damage)
            end
        end
    end

    -- Check Commandant immediate threats
    if state.commandHubs then
        for playerNum, hub in pairs(state.commandHubs) do
            if hub and playerNum ~= unit.player then
                local distance = math.abs(position.row - hub.row) + math.abs(position.col - hub.col)
                -- Commandant has atkRange = 1, can attack adjacent cells
                if distance <= adjacentRange then
                    local hubUnit = {
                        name = "Commandant",
                        player = playerNum,
                        row = hub.row,
                        col = hub.col,
                        currentHp = hub.currentHp,
                        startingHp = hub.startingHp
                    }
                    local damage = unitsInfo:calculateAttackDamage(hubUnit, unit)
                    if damage > ZERO_VALUE then
                        table.insert(oneActionDamages, damage)
                    end
                end
            end
        end
    end

    -- PHASE 2: Check move+attack threats (enemies that can move and then attack)

    for _, enemy in ipairs(state.units) do
        if enemy.player ~= unit.player and enemy.name ~= "Rock" then
            local validMovePositions = self:getValidMoveCells(state, enemy.row, enemy.col) or {}
            appendMovingUnitOriginIfReachable(
                self,
                state,
                enemy,
                unit,
                validMovePositions,
                "COMPLETE_SAFETY_MOVE_CHECK"
            )

            local bestMoveDamageForEnemy = ZERO_VALUE
            for _, movePos in ipairs(validMovePositions) do
                if not isPositionOccupiedIgnoringMover(self, state, movePos, unit) then
                    local canAttackFromMove, damage = canUnitAttackFromPosition(
                        self,
                        state,
                        enemy,
                        movePos,
                        position,
                        unit,
                        unit,
                        "COMPLETE_SAFETY_MOVE_RANGE"
                    )
                    if canAttackFromMove and damage > bestMoveDamageForEnemy then
                        bestMoveDamageForEnemy = damage
                    end
                end
            end

            if bestMoveDamageForEnemy > ZERO_VALUE then
                table.insert(twoActionDamages, bestMoveDamageForEnemy)
            end
        end
    end

    -- PHASE 3: Evaluate safety
    local worstDamage = computeWorstCaseDamage(self, oneActionDamages, twoActionDamages)
    local isSafe = worstDamage < safeDamageThreshold

    return isSafe
end

return aiSafety
