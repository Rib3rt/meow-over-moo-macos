-- AI Influence Map Module
-- This prevents oscillation and improves strategic positioning

local aiInfluence = {
    CONFIG = require('ai_influence_config'),
    -- Heatmap visualization state
    showHeatmap = false,
    heatmapFaction = nil,
    heatmapData = nil,
    heatmapGameRuler = nil,
    heatmapLastStateHash = nil,
}

-- Load centralized unit info module
local unitsInfo = require('unitsInfo')
local logger = require("logger")

local DEFAULTS = (aiInfluence.CONFIG and aiInfluence.CONFIG.DEFAULTS) or {}
local ZERO = DEFAULTS.ZERO
local ONE = DEFAULTS.ONE
local TWO = ONE + ONE
local THREE = TWO + ONE
local FOUR = TWO + TWO
local FIVE = FOUR + ONE
local SIX = THREE + THREE
local NEGATIVE_ONE = -ONE
local DEFAULT_GRID_SIZE = DEFAULTS.GRID_SIZE
local DEFAULT_TURN = DEFAULTS.CURRENT_TURN
local START_TIME_FALLBACK = DEFAULTS.START_TIME
local DEFAULT_PRESSURE_MULTIPLIER = DEFAULTS.PRESSURE_MULTIPLIER
local DEFAULT_DECAY_RATE = DEFAULTS.DECAY_RATE
local DEFAULT_DECAY_TRANSITION = DEFAULTS.DECAY_PHASE_TRANSITION
local DEFAULT_DECAY_DURATION = DEFAULTS.DECAY_PHASE_DURATION
local DEFAULT_ELIMINATION_GRADIENT = DEFAULTS.ELIMINATION_GRADIENT
local DEFAULT_DEFENSE_RULE_THRESHOLD = DEFAULTS.DEFENSE_RULE_THRESHOLD
local DEFAULT_DEFENSE_RULE_MULTIPLIER = DEFAULTS.DEFENSE_RULE_MULTIPLIER
local DEFAULT_DEFENSE_THREAT_MULTIPLIER = DEFAULTS.DEFENSE_THREAT_MULTIPLIER
local DEFAULT_DEFENSE_ADJACENT_GRADIENT = DEFAULTS.DEFENSE_ADJACENT_GRADIENT
local DEFAULT_FRIENDLY_DIRECT_BONUS = DEFAULTS.ATTACK_RANGE_BONUS_FRIENDLY_DIRECT
local DEFAULT_FRIENDLY_MOVE_BONUS = DEFAULTS.ATTACK_RANGE_BONUS_FRIENDLY_MOVE_ATTACK
local DEFAULT_ENEMY_DIRECT_BONUS = DEFAULTS.ATTACK_RANGE_BONUS_ENEMY_DIRECT
local DEFAULT_ENEMY_MOVE_BONUS = DEFAULTS.ATTACK_RANGE_BONUS_ENEMY_MOVE_ATTACK
local DEFAULT_UNIT_VALUE = DEFAULTS.DEFAULT_UNIT_VALUE
local DEFAULT_MAX_INFLUENCE_CONTRIBUTION = DEFAULTS.MAX_INFLUENCE_CONTRIBUTION
local DEFAULT_INFLUENCE_SCALE = DEFAULTS.INFLUENCE_SCALE
local DEFAULT_STATS_THRESHOLD = DEFAULTS.STATS_THRESHOLD
local DEFAULT_HEATMAP_COLOR_RANGE = DEFAULTS.HEATMAP_COLOR_RANGE
local DEFAULT_HEATMAP_LEGEND_ALPHA = DEFAULTS.HEATMAP_LEGEND_ALPHA
local DEFAULT_HEATMAP_NEUTRAL_COLOR = DEFAULTS.HEATMAP_NEUTRAL_COLOR or {}
local DEFAULT_HEATMAP_OVERLAY_BASE_ALPHA = DEFAULTS.HEATMAP_OVERLAY_BASE_ALPHA
local DEFAULT_HEATMAP_OVERLAY_ALPHA_SCALE = DEFAULTS.HEATMAP_OVERLAY_ALPHA_SCALE
local DEFAULT_HALF = DEFAULTS.HALF
local DEFAULT_MILLISECONDS_PER_SECOND = DEFAULTS.MILLISECONDS_PER_SECOND
local DEFAULT_SMOOTHSTEP_A = DEFAULTS.SMOOTHSTEP_A
local DEFAULT_SMOOTHSTEP_B = DEFAULTS.SMOOTHSTEP_B
local DEFAULT_DIAGONAL_GRADIENT_SCALE = DEFAULTS.DIAGONAL_GRADIENT_SCALE
local DEFAULT_DEBUG_MAP_VALUE_FORMAT = DEFAULTS.DEBUG_MAP_VALUE_FORMAT
local DEFAULT_HEATMAP_CENTER_DIVISOR = DEFAULTS.HEATMAP_CENTER_DIVISOR
local DEFAULT_HEATMAP_POSITIVE_RED_BASE = DEFAULTS.HEATMAP_POSITIVE_RED_BASE
local DEFAULT_HEATMAP_POSITIVE_GREEN_BASE = DEFAULTS.HEATMAP_POSITIVE_GREEN_BASE
local DEFAULT_HEATMAP_POSITIVE_GREEN_SCALE = DEFAULTS.HEATMAP_POSITIVE_GREEN_SCALE
local DEFAULT_HEATMAP_POSITIVE_BLUE_BASE = DEFAULTS.HEATMAP_POSITIVE_BLUE_BASE
local DEFAULT_HEATMAP_NEGATIVE_RED_BASE = DEFAULTS.HEATMAP_NEGATIVE_RED_BASE
local DEFAULT_HEATMAP_NEGATIVE_RED_SCALE = DEFAULTS.HEATMAP_NEGATIVE_RED_SCALE
local DEFAULT_HEATMAP_NEGATIVE_GREEN_BASE = DEFAULTS.HEATMAP_NEGATIVE_GREEN_BASE
local DEFAULT_HEATMAP_NEGATIVE_BLUE_BASE = DEFAULTS.HEATMAP_NEGATIVE_BLUE_BASE
local DEFAULT_UNIT_BASE_VALUES = aiInfluence.CONFIG.UNIT_BASE_VALUES or {}

local ORTHOGONAL_DIRECTIONS = {
    {row = NEGATIVE_ONE, col = ZERO},
    {row = ONE, col = ZERO},
    {row = ZERO, col = NEGATIVE_ONE},
    {row = ZERO, col = ONE},
}

local SECOND_RING_DIRECTIONS = {
    {row = -TWO, col = ZERO},
    {row = TWO, col = ZERO},
    {row = ZERO, col = -TWO},
    {row = ZERO, col = TWO},
}

local DIAGONAL_DIRECTIONS = {
    {row = NEGATIVE_ONE, col = NEGATIVE_ONE},
    {row = NEGATIVE_ONE, col = ONE},
    {row = ONE, col = NEGATIVE_ONE},
    {row = ONE, col = ONE},
}
local BASE_PROFILE = "base"

local function valueOr(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

-- ============================================================================
-- CONFIGURATION - Already loaded above
-- ============================================================================

-- ============================================================================
-- DECAY FUNCTIONS - How influence spreads over distance
-- ============================================================================

local function linearDecay(distance)
    return ONE / (distance + ONE)
end

local function quadraticDecay(distance)
    return ONE / (distance * distance + ONE)
end

local function sqrtDecay(distance)
    return ONE / (math.sqrt(distance) + ONE)
end

-- Exponential decay with dynamic rate (phase-based)
local function exponentialDecay(distance, decayRate)
    -- Middle ground between linear and quadratic
    -- decayRate: 0.35 (early, wider) to 0.50 (late, tighter)
    decayRate = valueOr(decayRate, DEFAULT_DECAY_RATE)
    return math.exp(-distance * decayRate)
end

local DECAY_FUNCTIONS = {
    linear = linearDecay,
    exponential = exponentialDecay,
    quadratic = quadraticDecay,
    sqrt = sqrtDecay,
}

-- ============================================================================
-- CORE INFLUENCE MAP BUILDING
-- ============================================================================

function aiInfluence:buildInfluenceMap(state, factionId, aiInstance)
    local startTime = love.timer and love.timer.getTime() or START_TIME_FALLBACK
    local map = {}
    local gridSize = valueOr(self.CONFIG.GRID_SIZE, DEFAULT_GRID_SIZE)
    
    -- Initialize empty map
    for row = ONE, gridSize do
        map[row] = {}
        for col = ONE, gridSize do
            map[row][col] = ZERO
        end
    end
    
    -- Get decay function
    local decayFunc = DECAY_FUNCTIONS[self.CONFIG.DECAY_TYPE] or linearDecay
    
    -- Calculate victory pressure multiplier based on turn phase.
    local currentTurn = valueOr(state.currentTurn, DEFAULT_TURN)
    local pressureMultiplier = self:getVictoryPressureMultiplier(currentTurn)
    
    -- Calculate phase-based decay rate (tightens influence in late game)
    local decayRate
    if self.CONFIG.DECAY_RATE_EARLY and self.CONFIG.DECAY_RATE_LATE then
        local transitionTurn = valueOr(self.CONFIG.DECAY_PHASE_TRANSITION, DEFAULT_DECAY_TRANSITION)
        if currentTurn <= transitionTurn then
            decayRate = self.CONFIG.DECAY_RATE_EARLY
        else
            -- Smooth S-curve transition from early to late rate (smoothstep)
            local progress = math.min(DEFAULT_PRESSURE_MULTIPLIER, (currentTurn - transitionTurn) / DEFAULT_DECAY_DURATION)
            -- Smoothstep formula: 3t² - 2t³ (creates smooth acceleration/deceleration)
            progress = progress * progress * (DEFAULT_SMOOTHSTEP_A - DEFAULT_SMOOTHSTEP_B * progress)
            decayRate = self.CONFIG.DECAY_RATE_EARLY + (self.CONFIG.DECAY_RATE_LATE - self.CONFIG.DECAY_RATE_EARLY) * progress
        end
    end
    
    -- Add unit influences (with LoS and pathfinding checks)
    local unitStats = {friendly = ZERO, enemy = ZERO, neutral = ZERO}
    for _, unit in ipairs(state.units or {}) do
        if unit.player == factionId then
            self:addUnitInfluence(map, unit, self.CONFIG.FRIENDLY_MULTIPLIER, decayFunc, gridSize, state, aiInstance, decayRate)
            unitStats.friendly = unitStats.friendly + ONE
        elseif unit.player == ZERO or unit.name == "Rock" then
            -- Neutral units (rocks) - don't add influence, just count
            unitStats.neutral = unitStats.neutral + ONE
        else
            self:addUnitInfluence(map, unit, self.CONFIG.ENEMY_MULTIPLIER, decayFunc, gridSize, state, aiInstance, decayRate)
            unitStats.enemy = unitStats.enemy + ONE
        end
    end
    
    -- Add objective influences (friendly Commandant with pressure scaling)
    self:addObjectiveInfluence(map, state, factionId, gridSize, pressureMultiplier)
    
    -- Add victory pressure influences (Commandant priority, unit elimination, protection).
    self:addVictoryPressure(map, state, factionId, gridSize, currentTurn, unitStats, pressureMultiplier, aiInstance)
    
    -- Calculate statistics
    local stats = self:calculateMapStats(map, gridSize)
    if love.timer then
        stats.buildTime = (love.timer.getTime() - startTime) * DEFAULT_MILLISECONDS_PER_SECOND  -- Convert to ms
    else
        stats.buildTime = ZERO
    end
    stats.unitStats = unitStats
    stats.pressureMultiplier = pressureMultiplier
    
    -- Debug output
    if self.CONFIG.DEBUG_ENABLED and DEBUG and DEBUG.AI then
        self:debugInfluenceMap(map, stats, gridSize)
    end
    
    return map, stats
end

-- ============================================================================
-- ADD UNIT INFLUENCE (WITH ATTACK RANGE CONSIDERATION)
-- ============================================================================

function aiInfluence:addUnitInfluence(map, unit, multiplier, decayFunc, gridSize, state, aiInstance, decayRate)
    if not unit or not unit.row or not unit.col then return end
    
    local unitValue = self:getUnitValue(unit)
    local maxRange = self.CONFIG.MAX_INFLUENCE_RANGE
    
    -- Get unit's attack and move ranges from centralized unitsInfo
    local attackRange = self:getUnitAttackRange(unit)
    local moveRange = self:getUnitMoveRange(unit)
    
    -- Get attack damage for threat scaling (from unitsInfo, no hardcoding)
    local attackDamage = valueOr(unitsInfo:getUnitAttackDamage(unit, "INFLUENCE_ATTACK_POWER"), ZERO)
    local damageMultiplier = DEFAULT_PRESSURE_MULTIPLIER + (attackDamage * self.CONFIG.ATTACK_POWER_SCALE)
    local attackRangeBonuses = self.CONFIG.ATTACK_RANGE_BONUSES or {}
    local friendlyRangeBonuses = attackRangeBonuses.friendly or {}
    local enemyRangeBonuses = attackRangeBonuses.enemy or {}

    local friendlyDirectBonus = valueOr(friendlyRangeBonuses.direct, DEFAULT_FRIENDLY_DIRECT_BONUS)
    local friendlyMoveBonus = valueOr(friendlyRangeBonuses.moveAttack, DEFAULT_FRIENDLY_MOVE_BONUS)
    local enemyDirectBonus = valueOr(enemyRangeBonuses.direct, DEFAULT_ENEMY_DIRECT_BONUS)
    local enemyMoveBonus = valueOr(enemyRangeBonuses.moveAttack, DEFAULT_ENEMY_MOVE_BONUS)
    
    for row = ONE, gridSize do
        for col = ONE, gridSize do
            local dist = math.abs(row - unit.row) + math.abs(col - unit.col)

            if dist <= maxRange then
                local canDirectAttack = false
                local canMoveAndAttack = false

                if attackRange and dist > ZERO then
                    if dist <= attackRange then
                        canDirectAttack = self:canUnitAttackPosition(state, unit, row, col, dist, aiInstance)
                    end

                    if moveRange and dist <= (attackRange + moveRange) then
                        if not canDirectAttack or dist > attackRange then
                            canMoveAndAttack = self:canUnitMoveAndAttack(state, unit, row, col, moveRange, attackRange, aiInstance)
                        elseif dist > attackRange then
                            canMoveAndAttack = self:canUnitMoveAndAttack(state, unit, row, col, moveRange, attackRange, aiInstance)
                        end
                    end
                end

                local reachable = (dist == ZERO) or canDirectAttack or canMoveAndAttack

                if reachable then
                    local decay = decayFunc(dist, decayRate)
                    local influence = unitValue * decay * multiplier

                    if canDirectAttack then
                        if multiplier < ZERO then
                            local threatBonus = enemyDirectBonus * damageMultiplier
                            influence = influence - threatBonus
                        else
                            local controlBonus = friendlyDirectBonus
                            influence = influence + controlBonus
                        end
                    elseif canMoveAndAttack then
                        if multiplier < ZERO then
                            local threatBonus = enemyMoveBonus * damageMultiplier
                            influence = influence - threatBonus
                        else
                            local controlBonus = friendlyMoveBonus
                            influence = influence + controlBonus
                        end
                    end

                    map[row][col] = map[row][col] + influence
                end
            end
        end
    end
end

-- ============================================================================
-- ADD OBJECTIVE INFLUENCE
-- ============================================================================

function aiInfluence:addObjectiveInfluence(map, state, factionId, gridSize, pressureMultiplier)
    if not state.commandHubs then return end
    
    pressureMultiplier = valueOr(pressureMultiplier, DEFAULT_PRESSURE_MULTIPLIER)
    
    -- Friendly Commandant (defend) - scales with pressure
    local friendlyCommandant = state.commandHubs[factionId]
    if friendlyCommandant then
        local influenceConfig = self.CONFIG.FRIENDLY_COMMANDANT_INFLUENCE
        local influence
        
        if type(influenceConfig) == "table" then
            -- New system: base × (pressure ^ scale)
            influence = influenceConfig.base * (pressureMultiplier ^ influenceConfig.pressureScale)
        else
            -- Fallback for old config format
            influence = influenceConfig
        end
        
        map[friendlyCommandant.row] = map[friendlyCommandant.row] or {}
        map[friendlyCommandant.row][friendlyCommandant.col] = valueOr(map[friendlyCommandant.row][friendlyCommandant.col], ZERO) + influence
    end
end

-- ============================================================================
-- VICTORY PRESSURE SYSTEM
-- ============================================================================

function aiInfluence:getVictoryPressureMultiplier(currentTurn)
    -- Returns escalating pressure multiplier based on turn number.
    local multipliers = self.CONFIG.PRESSURE_MULTIPLIERS or {}
    local early = valueOr(multipliers.early, DEFAULT_PRESSURE_MULTIPLIER)
    local mid = valueOr(multipliers.mid, DEFAULT_PRESSURE_MULTIPLIER)
    local late = valueOr(multipliers.late, DEFAULT_PRESSURE_MULTIPLIER)
    local critical = valueOr(multipliers.critical, DEFAULT_PRESSURE_MULTIPLIER)
    
    if currentTurn <= self.CONFIG.PRESSURE_TURN_EARLY then
        return early
    elseif currentTurn <= self.CONFIG.PRESSURE_TURN_MID then
        return mid
    elseif currentTurn <= self.CONFIG.PRESSURE_TURN_LATE then
        return late
    else
        return critical
    end
end

function aiInfluence:addVictoryPressure(map, state, factionId, gridSize, currentTurn, unitStats, pressureMultiplier, aiInstance)
    if not state.units then return end
    
    pressureMultiplier = valueOr(pressureMultiplier, DEFAULT_PRESSURE_MULTIPLIER)
    
    -- 1. ENEMY COMMANDANT ATTACK PRIORITY (scaled by pressure multiplier)
    local commandantPriorityConfig = self.CONFIG.COMMANDANT_ATTACK_PRIORITY
    local commandantAttackPriority
    local orthogonalGradient
    local orthogonalDecay
    local diagonalGradient

    if type(commandantPriorityConfig) == "table" then
        commandantAttackPriority = valueOr(commandantPriorityConfig.base, ZERO) * pressureMultiplier
        orthogonalGradient = valueOr(commandantPriorityConfig.orthogonalGradient, self.CONFIG.COMMANDANT_ATTACK_GRADIENT)
        orthogonalGradient = valueOr(orthogonalGradient, ZERO)
        orthogonalDecay = commandantPriorityConfig.orthogonalDecay
        diagonalGradient = valueOr(commandantPriorityConfig.diagonalGradient, orthogonalGradient and orthogonalGradient * DEFAULT_DIAGONAL_GRADIENT_SCALE)
        diagonalGradient = valueOr(diagonalGradient, ZERO)
    else
        commandantAttackPriority = valueOr(commandantPriorityConfig, ZERO) * pressureMultiplier
        orthogonalGradient = valueOr(self.CONFIG.COMMANDANT_ATTACK_GRADIENT, ZERO)
        orthogonalDecay = nil
        diagonalGradient = orthogonalGradient * DEFAULT_DIAGONAL_GRADIENT_SCALE
    end
    
    -- Find enemy Commandant and add strong influence towards it
    for _, unit in ipairs(state.units) do
        if unit.player ~= factionId and unit.player ~= ZERO and unit.name == "Commandant" then
            -- Add influence to the objective cell
            map[unit.row] = map[unit.row] or {}
            map[unit.row][unit.col] = valueOr(map[unit.row][unit.col], ZERO) + commandantAttackPriority
            
            -- ENHANCED: Add boosted influence to adjacent cells to create "path gradient"
            -- This helps units find clear paths toward the objective
            if orthogonalGradient and orthogonalGradient ~= ZERO then
                local orthogonalBoost = commandantAttackPriority * orthogonalGradient
                for _, dir in ipairs(ORTHOGONAL_DIRECTIONS) do
                    local adjRow = unit.row + dir.row
                    local adjCol = unit.col + dir.col

                    -- Check bounds
                    if adjRow >= ONE and adjRow <= gridSize and adjCol >= ONE and adjCol <= gridSize then
                        map[adjRow] = map[adjRow] or {}
                        map[adjRow][adjCol] = valueOr(map[adjRow][adjCol], ZERO) + orthogonalBoost
                    end
                end

                if orthogonalDecay and orthogonalDecay ~= ZERO then
                    local secondRingBoost = orthogonalBoost * orthogonalDecay
                    for _, dir in ipairs(SECOND_RING_DIRECTIONS) do
                        local ringRow = unit.row + dir.row
                        local ringCol = unit.col + dir.col

                        if ringRow >= ONE and ringRow <= gridSize and ringCol >= ONE and ringCol <= gridSize then
                            map[ringRow] = map[ringRow] or {}
                            map[ringRow][ringCol] = valueOr(map[ringRow][ringCol], ZERO) + secondRingBoost
                        end
                    end
                end
            end

            if diagonalGradient and diagonalGradient ~= ZERO then
                local diagonalBoost = commandantAttackPriority * diagonalGradient
                for _, dir in ipairs(DIAGONAL_DIRECTIONS) do
                    local diagRow = unit.row + dir.row
                    local diagCol = unit.col + dir.col

                    if diagRow >= ONE and diagRow <= gridSize and diagCol >= ONE and diagCol <= gridSize then
                        map[diagRow] = map[diagRow] or {}
                        map[diagRow][diagCol] = valueOr(map[diagRow][diagCol], ZERO) + diagonalBoost
                    end
                end
            end
        end
    end
    
    -- 2. UNIT ELIMINATION PRESSURE (scaled by pressure multiplier, when enemy has few units)
    if unitStats.enemy <= self.CONFIG.UNIT_ELIMINATION_THRESHOLD then
        local eliminationBonus = self.CONFIG.UNIT_ELIMINATION_BONUS * pressureMultiplier
        
        -- Add bonus influence towards all remaining enemy units
        for _, unit in ipairs(state.units) do
            if unit.player ~= factionId and unit.player ~= ZERO and unit.name ~= "Rock" then
                -- Add influence to the target unit cell
                map[unit.row] = map[unit.row] or {}
                local currentValue = valueOr(map[unit.row][unit.col], ZERO)
                local elevatedValue = currentValue + eliminationBonus
                map[unit.row][unit.col] = math.max(elevatedValue, eliminationBonus)
                
                -- ENHANCED: Add boosted influence to adjacent cells for path guidance
                local eliminationGradient = valueOr(self.CONFIG.UNIT_ELIMINATION_GRADIENT, DEFAULT_ELIMINATION_GRADIENT)
                local adjacentBoost = eliminationBonus * eliminationGradient
                
                for _, dir in ipairs(ORTHOGONAL_DIRECTIONS) do
                    local adjRow = unit.row + dir.row
                    local adjCol = unit.col + dir.col
                    
                    -- Check bounds
                    if adjRow >= ONE and adjRow <= gridSize and adjCol >= ONE and adjCol <= gridSize then
                        map[adjRow] = map[adjRow] or {}
                        local neighborValue = valueOr(map[adjRow][adjCol], ZERO)
                        local boostedValue = neighborValue + adjacentBoost
                        map[adjRow][adjCol] = math.max(boostedValue, adjacentBoost)
                    end
                end
            end
        end
    end
    
    -- 3. COMMANDANT DEFENSE PRIORITY
    self:addCommandantDefensePriority(map, state, factionId, pressureMultiplier, aiInstance)
end

-- ============================================================================
-- COMMANDANT DEFENSE PRIORITY
-- ============================================================================

function aiInfluence:addCommandantDefensePriority(map, state, factionId, pressureMultiplier, aiInstance)
    if not state.commandHubs or not state.units then return end
    
    -- Get friendly Commandant position
    local friendlyCommandant = state.commandHubs[factionId]
    if not friendlyCommandant then return end
    
    -- Get defense priority with inverse scaling.
    local defenseConfig = self.CONFIG.COMMANDANT_DEFENSE_PRIORITY or {}
    local defensePriority
    
    if type(defenseConfig) == "table" then
        -- New system: base × (pressure ^ scale)
        defensePriority = defenseConfig.base * (pressureMultiplier ^ defenseConfig.pressureScale)
    else
        -- Fallback for old config format
        defensePriority = defenseConfig * pressureMultiplier
    end
    
    -- HP-aware scaling: Increase defense priority when Commandant is wounded
    if friendlyCommandant.currentHp and friendlyCommandant.startingHp then
        local hpPercent = friendlyCommandant.currentHp / friendlyCommandant.startingHp
        local hpScalingConfig = self.CONFIG.COMMANDANT_DEFENSE_HP_SCALING
        if type(hpScalingConfig) == "table" then
            for _, rule in ipairs(hpScalingConfig) do
                if hpPercent < valueOr(rule.threshold, DEFAULT_DEFENSE_RULE_THRESHOLD) then
                    defensePriority = defensePriority * valueOr(rule.multiplier, DEFAULT_DEFENSE_RULE_MULTIPLIER)
                    break
                end
            end
        end
    end
    
    -- Find all enemy units threatening the friendly Commandant
    for _, unit in ipairs(state.units) do
        if unit.player ~= factionId and unit.player ~= ZERO and unit.name ~= "Rock" then
            local dist = math.abs(unit.row - friendlyCommandant.row) + math.abs(unit.col - friendlyCommandant.col)
            local isThreat = false
            
            -- Check if unit is adjacent (distance 1)
            if dist == ONE then
                isThreat = true
            
            -- Check if ranged unit can attack Commandant
            elseif dist >= TWO then
                local canAttack = self:canUnitAttackPosition(state, unit, friendlyCommandant.row, friendlyCommandant.col, dist, aiInstance)
                if canAttack then
                    isThreat = true
                end
            end
            
            -- Add high priority to kill this threatening unit
            if isThreat then
                -- ENHANCED: Much stronger bonus for units threatening our Commandant
                map[unit.row] = map[unit.row] or {}
                local defenseResponse = self.CONFIG.COMMANDANT_DEFENSE_RESPONSE or {}
                local threatMultiplierConfig = defenseResponse.threatMultiplier
                local threatMultiplier
                threatMultiplier = threatMultiplierConfig
                threatMultiplier = valueOr(threatMultiplier, DEFAULT_DEFENSE_THREAT_MULTIPLIER)
                local threatBonus = defensePriority * pressureMultiplier * threatMultiplier
                map[unit.row][unit.col] = valueOr(map[unit.row][unit.col], ZERO) + threatBonus
                
                -- ENHANCED: Add path gradient toward threatening units
                -- This helps units move toward threats even if not in direct range
                local adjacentGradient = valueOr(defenseResponse.adjacentGradient, DEFAULT_DEFENSE_ADJACENT_GRADIENT)
                local adjacentBoost = threatBonus * adjacentGradient
                
                for _, dir in ipairs(ORTHOGONAL_DIRECTIONS) do
                    local adjRow = unit.row + dir.row
                    local adjCol = unit.col + dir.col
                    
                    -- Check bounds
                    local gridSize = valueOr(state.gridSize, DEFAULT_GRID_SIZE)
                    if adjRow >= ONE and adjRow <= gridSize and adjCol >= ONE and adjCol <= gridSize then
                        map[adjRow] = map[adjRow] or {}
                        map[adjRow][adjCol] = valueOr(map[adjRow][adjCol], ZERO) + adjacentBoost
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- ATTACK & MOVEMENT VALIDATION
-- ============================================================================

function aiInfluence:canUnitAttackPosition(state, unit, targetRow, targetCol, dist, aiInstance)
    local rowDiff = math.abs(unit.row - targetRow)
    local colDiff = math.abs(unit.col - targetCol)
    local isOrthogonal = (rowDiff == ZERO) ~= (colDiff == ZERO)  -- exactly one axis differs

    if not isOrthogonal then
        return false
    end

    -- Cloudstriker and Artillery cannot attack at distance 1
    if (unit.name == "Cloudstriker" or unit.name == "Artillery") and dist == ONE then
        return false
    end
    
    -- Artillery shoots through everything (no LoS check needed)
    if unit.name == "Artillery" and dist >= TWO and dist <= THREE then
        return true
    end
    
    -- Cloudstriker needs orthogonal line of sight
    if unit.name == "Cloudstriker" and dist >= TWO and dist <= THREE then
        if aiInstance and aiInstance.hasLineOfSight then
            return aiInstance:hasLineOfSight(state, unit, {row = targetRow, col = targetCol})
        end
        return false
    end
    
    -- Melee units (distance 1 only)
    if dist == ONE then
        return true
    end
    
    return false
end

function aiInfluence:canUnitMoveAndAttack(state, unit, targetRow, targetCol, moveRange, attackRange, aiInstance)
    if not aiInstance or not aiInstance.getValidMoveCells then
        -- Fallback: assume possible if no AI instance
        return true
    end
    
    -- Get all valid move positions for this unit
    local moveCells = aiInstance:getValidMoveCells(state, unit.row, unit.col)
    if not moveCells then return false end
    
    -- Check each possible move position
    for _, moveCell in ipairs(moveCells) do
        local moveDist = math.abs(unit.row - moveCell.row) + math.abs(unit.col - moveCell.col)
        
        -- Only consider positions within move range
        if moveDist <= moveRange then
            local attackRowDiff = math.abs(moveCell.row - targetRow)
            local attackColDiff = math.abs(moveCell.col - targetCol)
            local attackDist = attackRowDiff + attackColDiff
            local attackOrthogonal = (attackRowDiff == ZERO) ~= (attackColDiff == ZERO)
            
            -- Check if we can attack target from this position
            if attackOrthogonal and attackDist >= TWO and attackDist <= attackRange then
                -- Cloudstriker and Artillery cannot attack at distance 1
                if (unit.name == "Cloudstriker" or unit.name == "Artillery") and attackDist == ONE then
                    -- Skip
                else
                    -- Artillery always can attack (shoots through everything)
                    if unit.name == "Artillery" then
                        return true
                    end
                    
                    -- Cloudstriker needs LoS from move position
                    if unit.name == "Cloudstriker" then
                        if aiInstance.hasLineOfSight then
                            local hasLoS = aiInstance:hasLineOfSight(state, 
                                {row = moveCell.row, col = moveCell.col}, 
                                {row = targetRow, col = targetCol})
                            if hasLoS then
                                return true
                            end
                        end
                    else
                        -- Melee units
                        if attackDist == ONE then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    return false
end

-- ============================================================================
-- UNIT STATS (Using centralized unitsInfo module)
-- ============================================================================

function aiInfluence:getUnitAttackRange(unit)
    -- Use centralized unitsInfo module for attack range
    return unitsInfo:getUnitAttackRange(unit, "INFLUENCE_MAP_ATTACK_RANGE")
end

function aiInfluence:getUnitMoveRange(unit)
    -- Use centralized unitsInfo module for move range
    return unitsInfo:getUnitMoveRange(unit, "INFLUENCE_MAP_MOVE_RANGE")
end

-- ============================================================================
-- UNIT VALUE CALCULATION
-- ============================================================================

function aiInfluence:getUnitValue(unit)
    -- Base values for different unit types
    local baseValues = DEFAULT_UNIT_BASE_VALUES
    
    local value = valueOr(baseValues[unit.name], DEFAULT_UNIT_VALUE)
    
    -- Adjust for HP (wounded units less influential)
    if unit.currentHp and unit.startingHp then
        local hpRatio = unit.currentHp / unit.startingHp
        value = value * (DEFAULT_HALF + (hpRatio * DEFAULT_HALF))  -- 50-100% value based on HP
    end
    
    return value
end

-- ============================================================================
-- MAP STATISTICS
-- ============================================================================

function aiInfluence:calculateMapStats(map, gridSize)
    local stats = {
        min = math.huge,
        max = -math.huge,
        avg = ZERO,
        positiveCount = ZERO,
        negativeCount = ZERO,
        neutralCount = ZERO,
    }
    
    local sum = ZERO
    local count = ZERO
    
    for row = ONE, gridSize do
        for col = ONE, gridSize do
            local value = valueOr(map[row][col], ZERO)
            
            stats.min = math.min(stats.min, value)
            stats.max = math.max(stats.max, value)
            sum = sum + value
            count = count + ONE
            
            if value > DEFAULT_STATS_THRESHOLD then
                stats.positiveCount = stats.positiveCount + ONE
            elseif value < -DEFAULT_STATS_THRESHOLD then
                stats.negativeCount = stats.negativeCount + ONE
            else
                stats.neutralCount = stats.neutralCount + ONE
            end
        end
    end
    
    stats.avg = sum / count
    
    return stats
end

-- ============================================================================
-- INFLUENCE EVALUATION FOR POSITIONING
-- ============================================================================

function aiInfluence:evaluatePosition(map, row, col)
    if not map or not map[row] then
        return ZERO, ZERO
    end
    
    local influence = valueOr(map[row][col], ZERO)
    
    -- Sigmoid scaling to prevent influence from dominating tactical decisions
    -- Maps influence to smooth -50 to +50 range instead of unbounded multiplication
    local maxInfluenceContribution = valueOr(self.CONFIG.MAX_INFLUENCE_CONTRIBUTION, DEFAULT_MAX_INFLUENCE_CONTRIBUTION)
    
    -- Get sigmoid scale
    local influenceScaleConfig = self.CONFIG.INFLUENCE_SCALE
    local influenceScale
    if type(influenceScaleConfig) == "table" then
        influenceScale = valueOr(influenceScaleConfig[BASE_PROFILE], influenceScaleConfig.base)
        influenceScale = valueOr(influenceScale, DEFAULT_INFLUENCE_SCALE)
    else
        influenceScale = valueOr(influenceScaleConfig, DEFAULT_INFLUENCE_SCALE)
    end
    
    local score = maxInfluenceContribution * (TWO / (ONE + math.exp(-influence / influenceScale)) - ONE)
    
    return score, influence
end

function aiInfluence:evaluateMove(map, fromRow, fromCol, toRow, toCol)
    local currentInfluence = valueOr(map[fromRow] and map[fromRow][fromCol], ZERO)
    local targetInfluence = valueOr(map[toRow] and map[toRow][toCol], ZERO)
    
    local delta = targetInfluence - currentInfluence
    
    -- Use sigmoid scaling for move evaluation too
    local currentScore = self:evaluatePosition(map, fromRow, fromCol)
    local targetScore = self:evaluatePosition(map, toRow, toCol)
    local score = targetScore - currentScore
    
    return score, delta, currentInfluence, targetInfluence
end

-- ============================================================================
-- DEBUG UTILITIES
-- ============================================================================

function aiInfluence:debugInfluenceMap(map, stats, gridSize)
    logger.debug("AI", "\n=== INFLUENCE MAP DEBUG ===")
    logger.debug("AI", string.format("Build time: %.2fms", valueOr(stats.buildTime, ZERO)))
    logger.debug("AI", string.format("Units: %d friendly, %d enemy, %d neutral",
        valueOr(stats.unitStats.friendly, ZERO), valueOr(stats.unitStats.enemy, ZERO), valueOr(stats.unitStats.neutral, ZERO)))
    if stats.pressureMultiplier then
        logger.debug("AI", string.format("Victory Pressure: %.1fx", stats.pressureMultiplier))
    end
    logger.debug("AI", string.format("Range: %.1f to %.1f (avg: %.1f)",
        stats.min, stats.max, stats.avg))
    logger.debug("AI", string.format("Cells: %d positive, %d negative, %d neutral",
        stats.positiveCount, stats.negativeCount, stats.neutralCount))
    
    if self.CONFIG.DEBUG_SHOW_MAP then
        logger.debug("AI", "\nInfluence Map (values):")
        for row = ONE, gridSize do
            local line = string.format("Row %d: ", row)
            for col = ONE, gridSize do
                local val = valueOr(map[row][col], ZERO)
                line = line .. string.format(DEFAULT_DEBUG_MAP_VALUE_FORMAT, val)
            end
            logger.debug("AI", line)
        end
    end
    
    logger.debug("AI", "=== END INFLUENCE MAP ===\n")
end

function aiInfluence:debugMoveEvaluation(unitName, fromRow, fromCol, toRow, toCol, score, delta, currentInf, targetInf)
    if not self.CONFIG.DEBUG_ENABLED then return end
    
    logger.debug("AI", string.format("  [INFLUENCE] %s (%d,%d)->(%d,%d): current=%.1f target=%.1f delta=%+.1f score=%+.1f",
        unitName, fromRow, fromCol, toRow, toCol, currentInf, targetInf, delta, score))
end

-- ============================================================================
-- CONFIGURATION HELPERS
-- ============================================================================

function aiInfluence:setConfig(key, value)
    if self.CONFIG[key] ~= nil then
        self.CONFIG[key] = value
        logger.info("AI", string.format("[INFLUENCE CONFIG] Set %s = %s", key, tostring(value)))
    else
        logger.warn("AI", string.format("[INFLUENCE CONFIG] Warning: Unknown config key '%s'", key))
    end
end

function aiInfluence:getConfig(key)
    return self.CONFIG[key]
end

function aiInfluence:printConfig()
    logger.info("AI", "\n=== INFLUENCE MAP CONFIGURATION ===")
    for key, value in pairs(self.CONFIG) do
        logger.info("AI", string.format("  %s = %s", key, tostring(value)))
    end
    logger.info("AI", "=== END CONFIGURATION ===\n")
end

-- ============================================================================
-- HEATMAP VISUALIZATION
-- ============================================================================

function aiInfluence:toggleHeatmap(gameRuler, factionId)
    self.showHeatmap = not self.showHeatmap
    
    if self.showHeatmap then
        -- Store gameRuler reference for updates
        self.heatmapGameRuler = gameRuler
        -- Don't lock faction - will update dynamically
        self.heatmapFaction = nil
        self.heatmapLastStateHash = nil  -- Force initial update
        logger.info("AI", "[INFLUENCE] Heatmap enabled (dynamic perspective)")
    else
        self.heatmapGameRuler = nil
        self.heatmapFaction = nil
        self.heatmapData = nil
        self.heatmapLastStateHash = nil
        logger.info("AI", "[INFLUENCE] Heatmap disabled")
    end
end

function aiInfluence:getGridStateHash()
    -- Create a hash of grid state (unit positions and HP)
    if not self.heatmapGameRuler or not self.heatmapGameRuler.currentGrid then
        return ""
    end
    
    local hash = ""
    local gridSize = valueOr(self.CONFIG.GRID_SIZE, DEFAULT_GRID_SIZE)
    for row = ONE, gridSize do
        for col = ONE, gridSize do
            local unit = self.heatmapGameRuler.currentGrid:getUnitAt(row, col)
            if unit then
                -- Include position, player, name, and HP in hash
                hash = hash .. string.format("%d%d%d%s%d", 
                    row, col, unit.player, unit.name, valueOr(unit.currentHp, ZERO))
            end
        end
    end
    
    -- Add turn number to hash
    hash = hash .. valueOr(self.heatmapGameRuler.currentTurn, DEFAULT_TURN)
    
    return hash
end

function aiInfluence:updateHeatmap()
    if not self.showHeatmap or not self.heatmapGameRuler then
        return
    end
    
    -- Get current player from game state (dynamic perspective)
    local phaseInfo = self.heatmapGameRuler:getCurrentPhaseInfo()
    local currentFaction = valueOr(phaseInfo and phaseInfo.currentPlayer, ONE)
    
    -- Get current grid state hash (include faction in hash so it updates on turn change)
    local currentHash = self:getGridStateHash() .. "_F" .. currentFaction
    
    -- Only rebuild if state has changed OR faction changed
    if currentHash ~= self.heatmapLastStateHash then
        -- Rebuild influence map from current game state with current player's perspective
        local state = self:buildStateFromGameRuler(self.heatmapGameRuler, currentFaction)
        self.heatmapData, self.heatmapStats = self:buildInfluenceMap(state, currentFaction, nil)
        
        -- Debug: Show which faction's perspective
        logger.debug("AI", string.format("[INFLUENCE] Updated heatmap for FACTION %d (Turn: %d)",
            currentFaction, valueOr(self.heatmapGameRuler.currentTurn, ZERO)))
        
        -- Update tracking
        self.heatmapLastStateHash = currentHash
        self.heatmapFaction = currentFaction  -- Store for legend display
    end
end

function aiInfluence:buildStateFromGameRuler(gameRuler, factionId)
    local state = {
        units = {},
        commandHubs = {},
        currentPlayer = factionId,
        currentTurn = valueOr(gameRuler.currentTurn, DEFAULT_TURN),
        phase = "actions"
    }
    
    if not gameRuler.currentGrid then return state end
    
    local grid = gameRuler.currentGrid
    
    -- Get units from grid
    local gridSize = valueOr(self.CONFIG.GRID_SIZE, DEFAULT_GRID_SIZE)
    for row = ONE, gridSize do
        for col = ONE, gridSize do
            local unit = grid:getUnitAt(row, col)
            if unit then
                table.insert(state.units, {
                    row = row,
                    col = col,
                    player = unit.player,
                    name = unit.name,
                    currentHp = unit.currentHp,
                    startingHp = unit.startingHp,
                    hasActed = unit.hasActed,
                    hasMoved = unit.hasMoved
                })
                
                -- Track command hubs
                if unit.name == "Commandant" then
                    state.commandHubs[unit.player] = {row = row, col = col}
                end
            end
        end
    end
    
    return state
end

function aiInfluence:drawHeatmap(cellSize, offsetX, offsetY)
    if not self.showHeatmap then return end
    
    -- Update heatmap data every frame
    self:updateHeatmap()
    
    if not self.heatmapData then return end
    
    local gridSize = valueOr(self.CONFIG.GRID_SIZE, DEFAULT_GRID_SIZE)
    love.graphics.push()
    
    -- Draw heatmap overlay
    for row = ONE, gridSize do
        for col = ONE, gridSize do
            local influence = valueOr(self.heatmapData[row][col], ZERO)
            
            -- Calculate position
            local x = offsetX + (col - ONE) * cellSize
            local y = offsetY + (row - ONE) * cellSize
            
            -- Map influence to color
            local r, g, b, a = self:influenceToColor(influence)
            
            -- Draw semi-transparent overlay
            love.graphics.setColor(r, g, b, a)
            love.graphics.rectangle("fill", x, y, cellSize, cellSize)
            
            -- Draw influence value text
            love.graphics.setColor(ONE, ONE, ONE, DEFAULT_HEATMAP_LEGEND_ALPHA)
            local text = string.format("%.0f", influence)
            local font = love.graphics.getFont()
            local textWidth = font:getWidth(text)
            local textHeight = font:getHeight()
            love.graphics.print(text, 
                x + (cellSize - textWidth) / DEFAULT_HEATMAP_CENTER_DIVISOR, 
                y + (cellSize - textHeight) / DEFAULT_HEATMAP_CENTER_DIVISOR)
        end
    end
    
    love.graphics.pop()
    love.graphics.setColor(ONE, ONE, ONE, ONE)
end

function aiInfluence:influenceToColor(influence)
    -- Map influence to color gradient
    -- Positive (friendly) = Green, Negative (enemy) = Red, Neutral = Gray
    
    local maxInfluence = DEFAULT_HEATMAP_COLOR_RANGE
    local normalized = math.max(-ONE, math.min(ONE, influence / maxInfluence))
    
    local r, g, b, a
    
    if normalized > ZERO then
        -- Positive influence: Green gradient
        r = DEFAULT_HEATMAP_POSITIVE_RED_BASE * (ONE - normalized)
        g = DEFAULT_HEATMAP_POSITIVE_GREEN_BASE + DEFAULT_HEATMAP_POSITIVE_GREEN_SCALE * normalized
        b = DEFAULT_HEATMAP_POSITIVE_BLUE_BASE * (ONE - normalized)
        a = DEFAULT_HEATMAP_OVERLAY_BASE_ALPHA + DEFAULT_HEATMAP_OVERLAY_ALPHA_SCALE * normalized
    elseif normalized < ZERO then
        -- Negative influence: Red gradient
        r = DEFAULT_HEATMAP_NEGATIVE_RED_BASE + DEFAULT_HEATMAP_NEGATIVE_RED_SCALE * math.abs(normalized)
        g = DEFAULT_HEATMAP_NEGATIVE_GREEN_BASE * (ONE - math.abs(normalized))
        b = DEFAULT_HEATMAP_NEGATIVE_BLUE_BASE * (ONE - math.abs(normalized))
        a = DEFAULT_HEATMAP_OVERLAY_BASE_ALPHA + DEFAULT_HEATMAP_OVERLAY_ALPHA_SCALE * math.abs(normalized)
    else
        -- Neutral: Gray
        r = DEFAULT_HEATMAP_NEUTRAL_COLOR[ONE]
        g = DEFAULT_HEATMAP_NEUTRAL_COLOR[TWO]
        b = DEFAULT_HEATMAP_NEUTRAL_COLOR[THREE]
        a = DEFAULT_HEATMAP_NEUTRAL_COLOR[FOUR]
    end
    
    return r, g, b, a
end

return aiInfluence
