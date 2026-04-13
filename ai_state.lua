-- AI State Management Module
-- Handles game state conversion, unit operations, and validation

local unitsInfo = require('unitsInfo')
local aiConfig = require('ai_config')
local aiState = {}

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local RUNTIME_DEFAULTS = DEFAULT_AI_PARAMS.RUNTIME or {}
local ZERO = RUNTIME_DEFAULTS.ZERO
local MIN_HP = RUNTIME_DEFAULTS.MIN_HP
local DEFAULT_TURN = RUNTIME_DEFAULTS.DEFAULT_TURN
local ONE = MIN_HP
local TWO = ONE + ONE
local NEGATIVE_ONE = -ONE

local function valueOr(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

function aiState.getStateFromGrid(self)
    local state = {
        units = {},
        commandHubs = {},
        neutralBuildings = {},
        unitsWithRemainingActions = {},
        currentPlayer = valueOr(self.gameRuler and self.gameRuler.currentPlayer, GAME.CURRENT.AI_PLAYER_NUMBER),
        turnNumber = GAME.CURRENT.TURN,
        currentTurn = valueOr(self.gameRuler and self.gameRuler.currentTurn, valueOr(GAME.CURRENT.TURN, DEFAULT_TURN)),
        phase = "actions",
        turnsWithoutDamage = valueOr(self.gameRuler and self.gameRuler.turnsWithoutDamage, ZERO),
        hasDeployedThisTurn = valueOr(self.gameRuler and self.gameRuler.hasDeployedThisTurn, false),
        attackedObjectivesThisTurn = {}
    }

    if not self.grid then return state end

    -- Get units from grid with proper property mapping (consistent with ai.lua)
    for row = ONE, GAME.CONSTANTS.GRID_SIZE do
        for col = ONE, GAME.CONSTANTS.GRID_SIZE do
            local unit = self.grid:getUnitAt(row, col)
            if unit then
                -- Get unit stats from unitsInfo
                local unitInfo = self.unitStats and self.unitStats[unit.name] or {}

                local unitCopy = {
                    row = row,
                    col = col,
                    name = unit.name,
                    player = unit.player,
                    currentHp = unit.currentHp or unitsInfo:getUnitHP(unit, "AI_STATE_CURRENT_HP"),
                    startingHp = valueOr(unit.startingHp, valueOr(unit.maxHp, valueOr(unitInfo.startingHp, MIN_HP))),
                    hasActed = unit.hasActed or false,
                    hasMoved = unit.hasMoved or false,
                    actionsUsed = valueOr(unit.actionsUsed, ZERO),
                    fly = unitsInfo:getUnitFlyStatus(unit, "AI_STATE_CREATION"),
                    atkDamage = unitsInfo:getUnitAttackDamage(unit, "AI_STATE_CREATION"),
                    move = unitsInfo:getUnitMoveRange(unit, "AI_STATE_CREATION"),
                    atkRange = unitsInfo:getUnitAttackRange(unit, "AI_STATE_CREATION"),
                    corvetteDamageFlag = unit.corvetteDamageFlag or false,
                    artilleryDamageFlag = unit.artilleryDamageFlag or false
                }

                table.insert(state.units, unitCopy)

                if unit.name == "Commandant" then
                    state.commandHubs[unit.player] = {
                        row = row,
                        col = col,
                        currentHp = unitCopy.currentHp,
                        startingHp = unitCopy.startingHp
                    }
                end

                if not unit.hasActed and unit.player == GAME.CURRENT.AI_PLAYER_NUMBER and unit.name ~= "Commandant" then
                    table.insert(state.unitsWithRemainingActions, {
                        row = row,
                        col = col,
                        name = unit.name,
                        player = unit.player
                    })
                end
            end
        end
    end

    -- Get Rocks from gameRuler
    if self.gameRuler and self.gameRuler.neutralBuildings then
        for _, building in ipairs(self.gameRuler.neutralBuildings) do
            table.insert(state.neutralBuildings, {
                row = building.row,
                col = building.col,
                currentHp = building.currentHp,
                startingHp = building.startingHp or building.maxHp
            })
        end
    end

    state.supply = {
        [ONE] = {},
        [TWO] = {}
    }

    if self.gameRuler then
        if self.gameRuler.player1Supply then
            for _, unit in ipairs(self.gameRuler.player1Supply) do
                table.insert(state.supply[ONE], {
                    name = unit.name,
                    currentHp = unit.currentHp or unitsInfo:getUnitHP(unit, "SUPPLY_CREATION_P1_CURRENT"),
                    startingHp = unit.startingHp or unit.maxHp or unitsInfo:getUnitHP(unit, "SUPPLY_CREATION_P1_STARTING")
                })
            end
        end

        if self.gameRuler.player2Supply then
            for _, unit in ipairs(self.gameRuler.player2Supply) do
                table.insert(state.supply[TWO], {
                    name = unit.name,
                    currentHp = unit.currentHp or unitsInfo:getUnitHP(unit, "SUPPLY_CREATION_P2_CURRENT"),
                    startingHp = unit.startingHp or unit.maxHp or unitsInfo:getUnitHP(unit, "SUPPLY_CREATION_P2_STARTING")
                })
            end
        end
    end

    if self.validateAndFixUnitStates then
        state = self:validateAndFixUnitStates(state)
    end

    local attackedObjectives = self.currentTurnAttackedObjectives
    if attackedObjectives then
        for _, objective in ipairs(attackedObjectives) do
            if objective and objective.row and objective.col then
                table.insert(state.attackedObjectivesThisTurn, {
                    row = objective.row,
                    col = objective.col
                })
            end
        end
    end

    return state
end

function aiState.getUnitAtPosition(state, row, col)
    -- Input validation
    if not state or not state.units or not row or not col then
        return nil
    end

    for _, unit in ipairs(state.units) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end
    return nil
end

function aiState.getUnitKey(self, unit, opts)
    if not unit or not unit.row or not unit.col then
        return nil
    end

    opts = opts or {}
    local includeName = opts.includeName
    if includeName == nil then
        includeName = true
    end

    local baseKey = string.format("%d,%d", unit.row, unit.col)
    if includeName then
        local name = unit.name or opts.fallbackName
        if name then
            return string.format("%s:%s", name, baseKey)
        end
    end

    return baseKey
end

function aiState.removeUnitFromState(state, row, col)
    -- Input validation
    if not state or not state.units or not row or not col then
        return
    end

    for i = #state.units, ONE, NEGATIVE_ONE do
        local unit = state.units[i]
        if unit and unit.row == row and unit.col == col then
            table.remove(state.units, i)
            break
        end
    end
end

function aiState.deepCopyState(state)
    -- Input validation
    if not state then
        return {
            units = {},
            commandHubs = {},
            currentPlayer = MIN_HP,
            unitsWithRemainingActions = {},
            turnNumber = DEFAULT_TURN,
            currentTurn = DEFAULT_TURN,
            phase = "actions",
            turnsWithoutDamage = ZERO,
            attackedObjectivesThisTurn = {}
        }
    end

    local copy = {
        units = {},
        commandHubs = {},
        currentPlayer = valueOr(state.currentPlayer, MIN_HP),
        unitsWithRemainingActions = {},
        turnNumber = valueOr(state.turnNumber, DEFAULT_TURN),
        phase = state.phase or "actions",
        currentTurn = valueOr(state.currentTurn, DEFAULT_TURN),
        turnsWithoutDamage = valueOr(state.turnsWithoutDamage, ZERO),
        hasDeployedThisTurn = valueOr(state.hasDeployedThisTurn, false),
        attackedObjectivesThisTurn = {}
    }

    -- Copy units with validation (consistent with ai.lua)
    for _, unit in ipairs(state.units) do
        local startingHp = math.max(MIN_HP, valueOr(unit.startingHp, MIN_HP))
        local currentHp = valueOr(unit.currentHp, startingHp)
        currentHp = math.max(ZERO, currentHp)

        if currentHp > startingHp then
            currentHp = startingHp
        end

        table.insert(copy.units, {
            row = unit.row,
            col = unit.col,
            name = unit.name,
            player = unit.player,
            currentHp = currentHp,
            startingHp = startingHp,
            -- Use centralized functions to get unit stats with debug printing
            fly = unitsInfo:getUnitFlyStatus(unit, "AI_STATE_COPY_UNIT"),
            atkDamage = unitsInfo:getUnitAttackDamage(unit, "AI_STATE_COPY_UNIT"),
            move = unitsInfo:getUnitMoveRange(unit, "AI_STATE_COPY_UNIT"),
            atkRange = unitsInfo:getUnitAttackRange(unit, "AI_STATE_COPY_UNIT"),
            hasActed = unit.hasActed,
            hasMoved = unit.hasMoved or false,
            actionsUsed = valueOr(unit.actionsUsed, ZERO),
            corvetteDamageFlag = unit.corvetteDamageFlag or false,
            artilleryDamageFlag = unit.artilleryDamageFlag or false
        })
    end

    -- Copy Commandants with validation
    for player, hub in pairs(state.commandHubs) do
        copy.commandHubs[player] = {
            row = hub.row,
            col = hub.col,
            currentHp = math.max(ZERO, valueOr(hub.currentHp, ZERO)),
            startingHp = math.max(MIN_HP, valueOr(hub.startingHp, MIN_HP))
        }
    end

    -- Copy units with remaining actions
    for _, unit in ipairs(state.unitsWithRemainingActions) do
        table.insert(copy.unitsWithRemainingActions, {
            row = unit.row,
            col = unit.col,
            name = unit.name,
            player = unit.player,
        })
    end

    -- Copy Rocks if they exist
    if state.neutralBuildings then
        copy.neutralBuildings = {}
        for _, building in ipairs(state.neutralBuildings) do
            table.insert(copy.neutralBuildings, {
                row = building.row,
                col = building.col,
                currentHp = math.max(ZERO, valueOr(building.currentHp, ZERO)),
                startingHp = math.max(MIN_HP, valueOr(building.startingHp, MIN_HP))
            })
        end
    end

    for _, objective in ipairs(state.attackedObjectivesThisTurn or {}) do
        if objective and objective.row and objective.col then
            table.insert(copy.attackedObjectivesThisTurn, {
                row = objective.row,
                col = objective.col
            })
        end
    end

    return copy
end

function aiState.isPositionBlocked(state, row, col)
    -- Check bounds
    if row < ONE or row > GAME.CONSTANTS.GRID_SIZE or col < ONE or col > GAME.CONSTANTS.GRID_SIZE then
        return true
    end

    -- Check for units
    if aiState.getUnitAtPosition(state, row, col) then
        return true
    end

    -- Check for Rocks
    if state.neutralBuildings then
        for _, building in ipairs(state.neutralBuildings) do
            if building.row == row and building.col == col then
                return true
            end
        end
    end

    return false
end

function aiState.removeUnitFromRemainingActions(state, unit)
    -- Only remove unit if it has completely acted
    if unit.hasActed then
        for i = #state.unitsWithRemainingActions, ONE, NEGATIVE_ONE do
            local unitInfo = state.unitsWithRemainingActions[i]
            if unitInfo.row == unit.row and unitInfo.col == unit.col then
                table.remove(state.unitsWithRemainingActions, i)
                break
            end
        end
    end
end

return aiState
