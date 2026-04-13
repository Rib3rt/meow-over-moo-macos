local aiConfig = require('ai_config')

local M = {}

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local DEFAULT_SCORE_PARAMS = DEFAULT_AI_PARAMS.SCORES or {}
local DEFAULT_MOBILITY_SCORE_PARAMS = DEFAULT_SCORE_PARAMS.MOBILITY or {}
local DEFAULT_RUNTIME = DEFAULT_AI_PARAMS.RUNTIME or {}
local ZERO = DEFAULT_RUNTIME.ZERO
local MIN_HP = DEFAULT_RUNTIME.MIN_HP
local ONE = MIN_HP
local TWO = ONE + ONE
local NEGATIVE_ONE = -ONE

local MOVE_DIRECTIONS = {
    {row = NEGATIVE_ONE, col = ZERO},
    {row = ONE, col = ZERO},
    {row = ZERO, col = NEGATIVE_ONE},
    {row = ZERO, col = ONE}
}

local function valueOr(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

local function hashCell(row, col)
    return tostring(row) .. "," .. tostring(col)
end

local function isInsideBoard(row, col, gridSize)
    return row >= ONE and row <= gridSize and col >= ONE and col <= gridSize
end

local function getMobilityScoreConfig(self)
    local params = (self and self.AI_PARAMS) or {}
    local scoreConfig = (params.SCORES or {}).MOBILITY
    if scoreConfig then
        return scoreConfig
    end
    return DEFAULT_MOBILITY_SCORE_PARAMS
end

function M.mixin(aiClass)
    function aiClass:isCellFree(state, row, col, ignoredPositions)
        if not row or not col then
            return false
        end

        local gridSize = (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or nil
        if self.grid and self.grid.isCellWithinBounds then
            if not self.grid:isCellWithinBounds(row, col) then
                return false
            end
        elseif gridSize then
            if not isInsideBoard(row, col, gridSize) then
                return false
            end
        end

        if ignoredPositions and ignoredPositions[hashCell(row, col)] then
            return false
        end

        for _, stateUnit in ipairs(state.units or {}) do
            if stateUnit.row == row and stateUnit.col == col then
                return false
            end
        end

        return true
    end

    function aiClass:scoreTileMobility(state, row, col, ignoredPositions)
        ignoredPositions = ignoredPositions or {}

        local immediateFree = ZERO
        for _, dir in ipairs(MOVE_DIRECTIONS) do
            local adjRow = row + dir.row
            local adjCol = col + dir.col
            if self:isCellFree(state, adjRow, adjCol, ignoredPositions) then
                immediateFree = immediateFree + ONE
            end
        end

        local visited = {[hashCell(row, col)] = true}
        local frontier = {{row = row, col = col, depth = ZERO}}
        local twoStepFree = ZERO

        while #frontier > ZERO do
            local node = table.remove(frontier, ONE)
            if node.depth == TWO then
                goto continue
            end

            for _, dir in ipairs(MOVE_DIRECTIONS) do
                local nextRow = node.row + dir.row
                local nextCol = node.col + dir.col
                local key = hashCell(nextRow, nextCol)
                if not visited[key] and self:isCellFree(state, nextRow, nextCol, ignoredPositions) then
                    visited[key] = true
                    frontier[#frontier + ONE] = {row = nextRow, col = nextCol, depth = node.depth + ONE}
                    if node.depth + ONE > ONE then
                        twoStepFree = twoStepFree + ONE
                    end
                end
            end

            ::continue::
        end

        local mobilityConfig = getMobilityScoreConfig(self)
        local tileWeights = mobilityConfig.TILE_SCORE or {}
        local defaultTileWeights = DEFAULT_MOBILITY_SCORE_PARAMS.TILE_SCORE or {}
        local immediateWeight = valueOr(tileWeights.IMMEDIATE_WEIGHT, defaultTileWeights.IMMEDIATE_WEIGHT)
        local twoStepWeight = valueOr(tileWeights.TWO_STEP_WEIGHT, defaultTileWeights.TWO_STEP_WEIGHT)

        return immediateFree * immediateWeight + twoStepFree * twoStepWeight
    end

    function aiClass:calculateMobilityBonus(stateBefore, stateAfter, unit, moveCell, ignoredPositions)
        if not unit or not moveCell then
            return ZERO
        end

        local hashOrigin = hashCell(unit.row, unit.col)
        local ignore = {}
        if ignoredPositions then
            for key, value in pairs(ignoredPositions) do
                ignore[key] = value
            end
        end
        ignore[hashOrigin] = true

        local currentMobility = self:scoreTileMobility(stateBefore, unit.row, unit.col, ignore)
        local targetMobility = self:scoreTileMobility(stateAfter or stateBefore, moveCell.row, moveCell.col, ignore)
        return targetMobility - currentMobility
    end
end

return M
