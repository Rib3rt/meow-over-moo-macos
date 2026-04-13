local M = {}
local logger = require("logger")

function M.mixin(aiClass, shared)
    local unitsInfo = shared.unitsInfo
    local aiInfluence = shared.aiInfluence
    local randomGen = shared.randomGen
    local aiConfig = shared.aiConfig

    local DEFAULT_AI_PARAMS = shared.DEFAULT_AI_PARAMS
    local DEFAULT_SCORE_PARAMS = shared.DEFAULT_SCORE_PARAMS
    local DEFAULT_UNIT_PROFILES = shared.DEFAULT_UNIT_PROFILES
    local RUNTIME_DEFAULTS = shared.RUNTIME_DEFAULTS
    local ZERO = shared.ZERO
    local MIN_HP = shared.MIN_HP
    local DEFAULT_TURN = shared.DEFAULT_TURN
    local DEFAULT_GRID_SIZE = shared.DEFAULT_GRID_SIZE
    local DISTANCE_FALLBACK = shared.DISTANCE_FALLBACK
    local PLAYER_INDEX_SUM = shared.PLAYER_INDEX_SUM
    local ONE = shared.ONE
    local TWO = shared.TWO
    local THREE = shared.THREE
    local FOUR = shared.FOUR
    local FIVE = shared.FIVE
    local SIX = shared.SIX
    local SEVEN = shared.SEVEN
    local EIGHT = shared.EIGHT
    local TEN = shared.TEN
    local NEGATIVE_MIN_HP = shared.NEGATIVE_MIN_HP
    local NEGATIVE_ONE = shared.NEGATIVE_ONE
    local BASE_AI_REFERENCE = shared.BASE_AI_REFERENCE
    local RULE_CONTRACT = shared.RULE_CONTRACT
    local SETUP_RULE_CONTRACT = shared.SETUP_RULE_CONTRACT
    local ACTION_RULE_CONTRACT = shared.ACTION_RULE_CONTRACT
    local TURN_RULE_CONTRACT = shared.TURN_RULE_CONTRACT
    local PERFORMANCE_RULE_CONTRACT = shared.PERFORMANCE_RULE_CONTRACT
    local DEFAULT_POSITIONAL_COMPONENT_WEIGHTS = shared.DEFAULT_POSITIONAL_COMPONENT_WEIGHTS
    local STRATEGY_INTENT = shared.STRATEGY_INTENT
    local STRATEGY_ROLE_ORDER = shared.STRATEGY_ROLE_ORDER

    local valueOr = shared.valueOr
    local deepCopyValue = shared.deepCopyValue
    local getMonotonicTimeSeconds = shared.getMonotonicTimeSeconds
    local deepMerge = shared.deepMerge
    local hashPosition = shared.hashPosition
    local buildMovePatternKey = shared.buildMovePatternKey
    --[[
    SECTION: TURN PHASE ORCHESTRATION
    Schedules AI processing for each phase after a short delay so animations can finish cleanly.
    - Resets per-turn flags when the AI regains control.
    - Delegates to specific handlers for setup, deployment, and action phases.
    ]]
    function aiClass:handleAITurn(phaseInfo, grid)
        -- Skip processing while grid animations run.
        if grid and grid.movingUnits and #grid.movingUnits > ZERO then
            return
        end

        local turnFlowConfig = self:getTurnFlowScoreConfig()
        local defaultTurnFlowConfig = DEFAULT_SCORE_PARAMS.TURN_FLOW or {}
        local startDelay = valueOr(turnFlowConfig.START_DELAY, valueOr(defaultTurnFlowConfig.START_DELAY, ZERO))

        self.gameRuler:scheduleAction(startDelay, function()
            -- Route handling based on the current game phase.
            if phaseInfo.currentPhase == "setup" and self.factionId == ONE then
                self:handleAINeutralBuildingPlacement()

            elseif phaseInfo.currentPhase == "deploy1" or phaseInfo.currentPhase == "deploy2" then
                self:handleAICommandHubPlacement()

            elseif phaseInfo.currentPhase == "deploy1_units" or phaseInfo.currentPhase == "deploy2_units" then
                self:handleAIInitialDeployment()

            elseif phaseInfo.currentPhase == "turn" then
                if phaseInfo.turnPhaseName == "actions" then

                    local currentTurn = GAME.CURRENT and GAME.CURRENT.TURN or nil

                    -- Reset per-turn flags when the AI no longer controls the phase.
                    if self.actionsPhaseStarted then
                        if (currentTurn and self.lastActionTurnProcessed and self.lastActionTurnProcessed ~= currentTurn)
                            or self.gameRuler.currentPlayer ~= self.factionId then
                            self.actionsPhaseStarted = false
                        end
                    end

                    if self.gameRuler.currentPlayer == self.factionId and not self.actionsPhaseStarted then
                        self.hasDeployedThisTurn = false
                        self.currentTurnAttackedObjectives = {}
                        self.currentTurnAttackedObjectivesLookup = {}
                        self.actionsPhaseStarted = true
                        self.lastActionTurnProcessed = currentTurn
                        local currentState = self:getStateFromGrid()
                        if not currentState or not currentState.units then
                            self.actionsPhaseStarted = false
                            self:logDecision("TurnPhase", "Skipping actions phase: state unavailable")
                            return
                        end
                        self._lastLoggedStateSnapshot = currentState
                        self._referenceResolutionState = currentState
                        local profileLabel = self:getAiProfileLabel(currentState, {
                            lock = true,
                            context = "actions_phase_start",
                            logSwitch = true
                        })

                        -- Calculate the current win probability snapshot.
                        local winPercentage = self:calculateWinningPercentage(currentState)

                        -- Refresh win-state profile controls.
                        self:updateWinPercentageProfile(currentTurn, currentState)

                        -- Refresh adaptive profile controls.
                        self:updateAdaptiveProfile(currentTurn, currentState)

                        self:logDecision("TurnPhase", "Starting actions phase", {
                            profile = profileLabel,
                            aiUnits = self:countAiUnits(currentState),
                            totalUnitsOnGrid = currentState.units and #currentState.units or ZERO,
                            winChance = string.format("%.1f%%", winPercentage)
                        })
                        local moveSequence = self:getBestSequence(currentState)
                        self:executeActionsSequence(moveSequence)
                    end
                elseif phaseInfo.turnPhaseName == "commandHub" then
                    -- Commandant defense resolves separately inside nextTurn().
                    -- Skipping here avoids duplicate attacks in the same phase.

                elseif phaseInfo.turnPhaseName == "endTurn" then
                    if not (grid and grid.movingUnits and #grid.movingUnits > ZERO) then
                        self.gameRuler:performAction("confirmEndTurn")
                    end
                else
                    if not (grid and grid.movingUnits and #grid.movingUnits > ZERO) then
                        self.gameRuler:performAction("nextPhase")
                    end
                end
            end
        end)
    end

    --[[
    SECTION: STATE SYNCHRONIZATION
    Centralizes state reads and writes through aiState helpers to avoid duplication.
    - getStateFromGrid proxies to the shared state builder.
    - Guard assignments refresh after pulling a fresh snapshot.
    ]]
    function aiClass:getStateFromGrid()
        return self.aiState.getStateFromGrid(self)
    end

    function aiClass:refreshGuardAssignmentsFromGrid()
        local snapshot = self:getStateFromGrid()
        if not snapshot then
            self.guardAssignments = {}
            return
        end

        local assignments = {}
        local snapshotGuard = snapshot.guardAssignments or {}
        for _, unit in ipairs(snapshot.units or {}) do
            local key = self:getUnitKey(unit)
            if key then
                local existing = snapshotGuard[key] or (self.guardAssignments and self.guardAssignments[key])
                if existing then
                    assignments[key] = {
                        row = existing.row,
                        col = existing.col
                    }
                end
            end
        end
        self.guardAssignments = assignments
    end

    function aiClass:getUnitAtPosition(state, row, col)
        -- Proxy lookup through aiState to avoid duplication.
        return self.aiState.getUnitAtPosition(state, row, col)
    end

    function aiClass:getBoardSize(state)
        return (state and state.gridSize) or (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or DEFAULT_GRID_SIZE
    end

    function aiClass:isInsideBoard(row, col, state)
        local gridSize = self:getBoardSize(state)
        return row >= ONE and row <= gridSize and col >= ONE and col <= gridSize
    end

    function aiClass:getOrthogonalDirections()
        return {
            {row = ONE, col = ZERO},
            {row = NEGATIVE_ONE, col = ZERO},
            {row = ZERO, col = ONE},
            {row = ZERO, col = NEGATIVE_ONE}
        }
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

    --[[
    SECTION: SAFETY VALIDATION
    Guards against friendly fire scenarios before actions resolve.
    - Logs a critical error when identical player ownership is detected.
    - Returns true to abort the attack when a friendly target is identified.
    ]]
    function aiClass:isFriendlyFireAttack(attackerUnit, targetUnit)
        if not attackerUnit or not targetUnit then
            return false
        end

        -- Treat identical player ownership as a friendly fire event.
        if attackerUnit.player and targetUnit.player and attackerUnit.player == targetUnit.player then
            logger.error("AI", "CRITICAL ERROR: Friendly fire detected!")
            logger.error("AI", "  Attacker:", attackerUnit.name, "Player:", attackerUnit.player, "at", attackerUnit.row, attackerUnit.col)
            logger.error("AI", "  Target:", targetUnit.name, "Player:", targetUnit.player, "at", targetUnit.row, targetUnit.col)
            return true
        end

        return false
    end

    function aiClass:removeUnitFromState(state, row, col)
        -- Capture the unit reference before removal to handle Commandant logic.
        local unit = self.aiState.getUnitAtPosition(state, row, col)

        -- Remove through aiState to keep state mutations consistent.
        self.aiState.removeUnitFromState(state, row, col)

        if state and state.neutralBuildings then
            for i = #state.neutralBuildings, ONE, NEGATIVE_ONE do
                local building = state.neutralBuildings[i]
                if building and building.row == row and building.col == col then
                    table.remove(state.neutralBuildings, i)
                end
            end
        end

        -- Clear the Commandant hub entry when the unit was a Commandant.
        if unit and self:isHubUnit(unit) and state and state.commandHubs then
            state.commandHubs[unit.player] = nil
        end
    end

    function aiClass:deepCopyState(state)
        -- Clone the state through aiState to mirror shared logic.
        local copy = self.aiState.deepCopyState(state)

        -- Copy supply data when present so command hub resummons remain accurate.
        if state and state.supply then
            copy.supply = {
                [ONE] = {},
                [TWO] = {}
            }
            for player, units in pairs(state.supply) do
                for _, unit in ipairs(units) do
                    table.insert(copy.supply[player], {
                        name = unit.name,
                        currentHp = math.max(ZERO, unit.currentHp or ZERO),
                        startingHp = math.max(ONE, unit.startingHp or MIN_HP)
                    })
                end
            end
        end

        return copy
    end

    --[[
    SECTION: MOVEMENT QUERIES
    Delegates movement, attack, and repair calculations to ai_mobility helpers.
    - Keeps pathing logic consistent across the AI modules.
    ]]
    function aiClass:getValidMoveCells(state, row, col)
        return self.aiMovement.getValidMoveCells(self, state, row, col)
    end

    function aiClass:getValidAttackCells(state, row, col)
        return self.aiMovement.getValidAttackCells(self, state, row, col)
    end

    function aiClass:getValidRepairCells(state, row, col)
        if not state or not row or not col then
            return {}
        end

        local unit = self:getUnitAtPosition(state, row, col)
        if not unit or not self:unitHasTag(unit, "healer") then
            return {}
        end

        local repairCells = {}
        local repairRange = unitsInfo:getUnitAttackRange(unit, "GET_VALID_REPAIR_CELLS") or ONE

        for _, dir in ipairs(self:getOrthogonalDirections()) do
            for dist = ONE, repairRange do
                local targetRow = row + (dir.row * dist)
                local targetCol = col + (dir.col * dist)
                if targetRow >= ONE and targetRow <= GAME.CONSTANTS.GRID_SIZE
                    and targetCol >= ONE and targetCol <= GAME.CONSTANTS.GRID_SIZE then
                    local targetUnit = self:getUnitAtPosition(state, targetRow, targetCol)
                    if targetUnit and targetUnit.player == unit.player then
                        local currentHp = targetUnit.currentHp or targetUnit.startingHp or ONE
                        local maxHp = targetUnit.startingHp or ONE
                        if currentHp < maxHp then
                            repairCells[#repairCells + ONE] = {row = targetRow, col = targetCol}
                        end
                    end
                end
            end
        end

        return repairCells
    end

    function aiClass:hasLineOfSight(state, from, to)
        return self.aiMovement.hasLineOfSight(self, state, from, to)
    end

    function aiClass:getLinePath(from, to)
        return self.aiMovement.getLinePath(from, to)
    end

    function aiClass:canUnitReachPosition(state, unit, targetPos)
        return self.aiMovement.canUnitReachPosition(self, state, unit, targetPos)
    end

    --[[
    SECTION: CORE DECISION HELPERS
    Centralizes repeated eligibility and safety checks used across priority logic.
    ]]
end

return M
