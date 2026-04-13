-- AI Movement and Validation Module
-- Handles unit movement, attack range, repair validation, and line of sight

local unitsInfo = require('unitsInfo')
local aiMovement = {}
local aiState = require('ai_state')
local aiConfig = require('ai_config')

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local RUNTIME_DEFAULTS = DEFAULT_AI_PARAMS.RUNTIME or {}
local ZERO = RUNTIME_DEFAULTS.ZERO
local ONE = RUNTIME_DEFAULTS.MIN_HP
local TWO = ONE + ONE
local POSITIVE_STEP = ONE
local NEGATIVE_STEP = -ONE

local ORTHOGONAL_DIRECTIONS = {
    {row = POSITIVE_STEP, col = ZERO},
    {row = NEGATIVE_STEP, col = ZERO},
    {row = ZERO, col = POSITIVE_STEP},
    {row = ZERO, col = NEGATIVE_STEP}
}

local function isInsideGrid(row, col)
    local gridSize = GAME.CONSTANTS.GRID_SIZE
    return row >= ONE and row <= gridSize and col >= ONE and col <= gridSize
end

-- Pathfinding function that considers flying units and Rocks
function aiMovement.canUnitReachPosition(self, state, unit, targetPos)
    if not self or not state or not unit or not targetPos then
        return false
    end
    
    local startRow, startCol = unit.row, unit.col
    local targetRow, targetCol = targetPos.row, targetPos.col
    
    -- If already at target position
    if startRow == targetRow and startCol == targetCol then
        return true
    end
    
    local moveRange = unitsInfo:getUnitMoveRange(unit)
    if moveRange <= ZERO then
        return false
    end
    
    local canFly = unitsInfo:getUnitFlyStatus(unit)
    
    -- Use breadth-first search to find valid orthogonal path
    local queue = {{row = startRow, col = startCol, distance = ZERO}}
    local visited = {}
    visited[startRow .. "," .. startCol] = true
    
    while #queue > ZERO do
        local current = table.remove(queue, ONE)
        
        -- Found target
        if current.row == targetRow and current.col == targetCol then
            return true
        end
        
        -- Don't explore beyond move range - use proper control flow instead of goto
        if current.distance < moveRange then
            -- Explore orthogonal neighbors
            local neighbors = {
                {row = current.row + ONE, col = current.col},
                {row = current.row - ONE, col = current.col},
                {row = current.row, col = current.col + ONE},
                {row = current.row, col = current.col - ONE}
            }
            
            for _, neighbor in ipairs(neighbors) do
                local key = neighbor.row .. "," .. neighbor.col
                if not visited[key] and
                   isInsideGrid(neighbor.row, neighbor.col) then
                    
                    local canExploreThrough = false
                    
                    if canFly then
                        -- Flying units can move through Rocks but target must be empty
                        canExploreThrough = true  -- Can always explore through any cell
                        -- Check if target position is reachable (empty)
                        if neighbor.row == targetRow and neighbor.col == targetCol then
                            canExploreThrough = not aiState.isPositionBlocked(state, neighbor.row, neighbor.col)
                        end
                    else
                        -- Ground units cannot move through occupied cells
                        canExploreThrough = not aiState.isPositionBlocked(state, neighbor.row, neighbor.col)
                    end
                    
                    if canExploreThrough then
                        visited[key] = true
                        table.insert(queue, {
                            row = neighbor.row, 
                            col = neighbor.col, 
                            distance = current.distance + ONE
                        })
                    end
                end
            end
        end
    end
    
    return false -- No valid path found
end

function aiMovement.getValidMoveCells(self, state, row, col)
    if not self or not state or not row or not col then
        return {}
    end

    local unit = self.aiState.getUnitAtPosition(state, row, col)
    if not unit then
        return {}
    end

    local movementRange = unitsInfo:getUnitMoveRange(unit)
    if movementRange <= ZERO then
        return {}
    end

    local canFly = unitsInfo:getUnitFlyStatus(unit)
    local validCells = {}

    for _, dir in ipairs(ORTHOGONAL_DIRECTIONS) do
        for dist = ONE, movementRange do
            local nextRow = row + dir.row * dist
            local nextCol = col + dir.col * dist

            if not isInsideGrid(nextRow, nextCol) then
                break
            end

            local blocked = false

            if canFly then
                -- Flying units ignore intermediate blockers but cannot land on occupied cells
                if aiState.isPositionBlocked(state, nextRow, nextCol) then
                    blocked = true
                end
            else
                -- Ground units require every intermediate tile to be clear
                for step = ONE, dist do
                    local checkRow = row + dir.row * step
                    local checkCol = col + dir.col * step

                    if aiState.isPositionBlocked(state, checkRow, checkCol) then
                        blocked = true
                        break
                    end
                end
            end

            if blocked then
                break
            end

            table.insert(validCells, {row = nextRow, col = nextCol})
        end
    end

    return validCells
end

function aiMovement.getValidAttackCells(self, state, row, col)
    -- Input validation
    if not self or not state or not row or not col then
        return {}
    end

    local unit = self.aiState.getUnitAtPosition(state, row, col)
    if not unit then
        return {}
    end

    -- Use centralized function to get attack range
    local attackRange = unitsInfo:getUnitAttackRange(unit)
    if attackRange <= ZERO then
        return {}
    end

    local validCells = {}

    -- Use directional approach for proper line-of-sight logic
    for _, dir in ipairs(ORTHOGONAL_DIRECTIONS) do
        for dist = ONE, attackRange do
            local r = row + (dir.row * dist)
            local c = col + (dir.col * dist)

            -- Check if position is valid
            if isInsideGrid(r, c) then
                local targetUnit = self.aiState.getUnitAtPosition(state, r, c)
                local neutralBuilding = nil
                local commandHub = nil

                -- Check for Rock
                for _, building in ipairs(state.neutralBuildings or {}) do
                    if building.row == r and building.col == c then
                        neutralBuilding = building
                        break
                    end
                end

                -- Check for Commandant
                for _, hub in pairs(state.commandHubs) do
                    if hub and hub.row == r and hub.col == c and hub.player ~= unit.player then
                        commandHub = hub
                        break
                    end
                end

                -- Valid targets: enemy units, Rocks, or enemy Commandants
                if (targetUnit and targetUnit.player ~= unit.player) or 
                   neutralBuilding or commandHub then

                    -- Special attack rules for units with restrictions
                    if unit.name == "Cloudstriker" then
                        -- Corvettes cannot attack adjacent cells and need line of sight
                        if dist > ONE and self:hasLineOfSight(state, {row = row, col = col}, {row = r, col = c}) then
                            table.insert(validCells, {row = r, col = c})
                        end
                    elseif unit.name == "Artillery" then
                        -- Artillery cannot attack adjacent cells but can shoot through Rocks
                        if dist > ONE then
                            table.insert(validCells, {row = r, col = c})
                        end
                    else
                        -- Regular units can attack any target in range
                        if dist <= attackRange then
                            table.insert(validCells, {row = r, col = c})
                        end
                    end
                end

                -- Handle blocking logic based on unit type
                if unit.name == "Cloudstriker" then
                    -- Corvette: blocked by any unit or Rock (needs free line of sight)
                    if targetUnit or neutralBuilding then
                        break -- Stop in this direction
                    end
                elseif unit.name == "Artillery" then
                    -- Artillery: NEVER blocked - can shoot over/through everything
                    -- Artillery continues through units, buildings, Commandants - nothing stops it
                    -- No break statement - Artillery always continues
                else
                    -- Regular units: blocked by any unit or Rock
                    if targetUnit or neutralBuilding then
                        break -- Stop in this direction
                    end
                end
            else
                break -- Out of bounds, stop in this direction
            end
        end
    end

    return validCells
end

function aiMovement.hasLineOfSight(self, state, from, to)
    if not from or not to then return false end

    if from.row == to.row and from.col == to.col then
        return true
    end

    if from.row ~= to.row and from.col ~= to.col then
        return false
    end

    local attacker = self.aiState.getUnitAtPosition(state, from.row, from.col)
    local path = aiMovement.getLinePath(from, to)

    if #path == ZERO then
        return false
    end

    for i = TWO, #path - ONE do
        local pos = path[i]
        if attacker and attacker.name == "Artillery" then
            -- Artillery ignores obstacles entirely
        else
            if self.aiState.isPositionBlocked(state, pos.row, pos.col) then
                return false
            end
        end
    end

    return true
end

function aiMovement.getLinePath(from, to)
    if not from or not to then
        return {}
    end

    local path = {}
    local dx = to.col - from.col
    local dy = to.row - from.row

    if dx ~= ZERO and dy ~= ZERO then
        return {}
    end

    local steps = math.abs(dx) + math.abs(dy)

    if steps == ZERO then
        table.insert(path, {row = from.row, col = from.col})
        return path
    end

    if dx ~= ZERO then
        local stepDirection = dx > ZERO and POSITIVE_STEP or NEGATIVE_STEP
        for i = ZERO, math.abs(dx) do
            table.insert(path, {row = from.row, col = from.col + (stepDirection * i)})
        end
    else
        local stepDirection = dy > ZERO and POSITIVE_STEP or NEGATIVE_STEP
        for i = ZERO, math.abs(dy) do
            table.insert(path, {row = from.row + (stepDirection * i), col = from.col})
        end
    end

    return path
end

return aiMovement
