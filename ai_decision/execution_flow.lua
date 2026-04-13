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

    local function aiDebugPrint(...)
        if DEBUG and DEBUG.AI then
            logger.debug("AI", ...)
        end
    end

    function aiClass:evaluateSupplyDeployment(state, unit, cell, hubThreat, opts)
        local score = ZERO
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return score
        end
        if not state then
            return score
        end
        local options = opts or {}
        local tempoContext = self:getPhaseTempoContext(state)
        local doctrineConfig = self:getDoctrineScoreConfig()
        local closeoutConfig = doctrineConfig.ENDGAME_CLOSEOUT or {}
        local adjacentRescueContext = options.adjacentRangedThreatContext
        if adjacentRescueContext == nil then
            adjacentRescueContext = self:getAdjacentRangedThreatContext(state, aiPlayer)
        end
        local supplyEvalConfig = self:getSupplyEvalScoreConfig()
        local defaultSupplyEvalConfig = DEFAULT_SCORE_PARAMS.SUPPLY_EVAL or {}
        local supplyScoreConfig = self:getSupplyDeploymentScoreConfig()
        local defaultSupplyScoreConfig = DEFAULT_SCORE_PARAMS.SUPPLY_DEPLOYMENT or {}
        local hubDistanceConfig = supplyScoreConfig.HUB_DISTANCE or {}
        local defaultHubDistanceConfig = defaultSupplyScoreConfig.HUB_DISTANCE or {}
        local earlyCorvetteTurnMax = valueOr(
            supplyScoreConfig.EARLY_CORVETTE_TURN_MAX,
            valueOr(defaultSupplyScoreConfig.EARLY_CORVETTE_TURN_MAX, ZERO)
        )
        local hubPos = state.commandHubs and state.commandHubs[aiPlayer]
        local blockLineBonus = valueOr(
            supplyEvalConfig.BLOCK_LINE_OF_SIGHT,
            valueOr(defaultSupplyEvalConfig.BLOCK_LINE_OF_SIGHT, ZERO)
        )
        local goodFiringLaneBonus = valueOr(supplyEvalConfig.GOOD_FIRING_LANE, defaultSupplyEvalConfig.GOOD_FIRING_LANE)

        local function getSpawnValue(tableName, unitName)
            local currentValues = supplyEvalConfig[tableName] or {}
            if currentValues[unitName] ~= nil then
                return currentValues[unitName]
            end
            local defaultValues = defaultSupplyEvalConfig[tableName] or {}
            return defaultValues[unitName] or ZERO
        end

        local friendlyCounts = {}
        local enemyGroundCount = ZERO
        for _, boardUnit in ipairs(state.units or {}) do
            if boardUnit.player == aiPlayer and not self:isHubUnit(boardUnit) and not self:isObstacleUnit(boardUnit) then
                friendlyCounts[boardUnit.name] = (friendlyCounts[boardUnit.name] or ZERO) + ONE
            elseif self:isAttackableEnemyUnit(boardUnit, aiPlayer, {excludeHub = true}) and not self:isObstacleUnit(boardUnit) then
                if not boardUnit.fly then
                    enemyGroundCount = enemyGroundCount + ONE
                end
            end
        end

        -- Threat-based weighting
        if hubThreat and hubThreat.isUnderAttack then
            if hubThreat.type == "melee" then
                score = score + getSpawnValue("UNIT_SPAWN_VALUES_UNDER_ATTACK", unit.name)
                -- blocking line check
                if hubThreat.direction and hubPos then
                    if self:isPositionBetween(cell, {row = hubPos.row + hubThreat.direction.row, col = hubPos.col + hubThreat.direction.col}, hubPos) then
                        score = score + blockLineBonus
                    end
                end
            else -- ranged
                score = score + getSpawnValue("UNIT_SPAWN_VALUES_UNDER_ATTACK", unit.name)
                if hubThreat.direction then
                    if self:wouldBlockLineOfSight(state, cell, hubThreat.direction) then
                        score = score + blockLineBonus
                    end
                end
                if self:unitHasTag(unit, "corvette") and self:hasGoodFiringLanes(state, cell) then
                    score = score + goodFiringLaneBonus
                end
            end
        else
            -- Normal situation
            score = score + getSpawnValue("UNIT_SPAWN_VALUES", unit.name)
            if self:unitHasTag(unit, "corvette") and state.turnNumber <= earlyCorvetteTurnMax then
                score = score + getSpawnValue("UNIT_SPAWN_VALUES", "Cloudstriker")
                if self:hasGoodFiringLanes(state, cell) then
                    score = score + goodFiringLaneBonus
                end
            end
        end

        -- Doctrine-driven squad synergy for spawn prioritization.
        if unit.name == "Bastion" and (friendlyCounts.Artillery or ZERO) > ZERO then
            score = score + 55
        elseif unit.name == "Artillery" and (friendlyCounts.Bastion or ZERO) > ZERO then
            score = score + 55
        elseif unit.name == "Cloudstriker" and (friendlyCounts.Wingstalker or ZERO) > ZERO then
            score = score + 40
        elseif unit.name == "Wingstalker" and (friendlyCounts.Cloudstriker or ZERO) > ZERO then
            score = score + 40
        elseif unit.name == "Earthstalker" and enemyGroundCount > ZERO then
            score = score + math.min(60, enemyGroundCount * 20)
        end

        if self:unitHasTag(unit, "healer") then
            local damagedAllies = self:countDamagedFriendlyUnits(state, aiPlayer, {includeHub = true})
            if damagedAllies == ZERO and not (hubThreat and hubThreat.isUnderAttack) then
                score = score - 120
            end
        end

        score = score + self:getAdjacentRangedRescueDeploymentScore(
            state,
            unit,
            cell,
            adjacentRescueContext
        )

        if tempoContext and tempoContext.phase ~= "end" then
            score = score + self:getOpeningCounterScore(state, aiPlayer, unit.name)
        end

        -- Distance to hub (prefer adjacent)
        if hubPos then
            local hubDistanceBase = valueOr(hubDistanceConfig.BASE, valueOr(defaultHubDistanceConfig.BASE, ZERO))
            local hubDistancePerTile = valueOr(hubDistanceConfig.PER_TILE, valueOr(defaultHubDistanceConfig.PER_TILE, ZERO))
            score = score + (hubDistanceBase - (math.abs(cell.row - hubPos.row) + math.abs(cell.col - hubPos.col))) * hubDistancePerTile
        end

        if tempoContext and tempoContext.phase == "end"
            and tostring(valueOr(closeoutConfig.DEPLOY_STYLE, "finish_first")) == "finish_first" then
            local selectedPath = tempoContext.endgamePath or "hub"
            local horizon = math.max(ONE, valueOr(closeoutConfig.ETA_HORIZON_TURNS, THREE))
            local minImprovement = math.max(ZERO, valueOr(closeoutConfig.DEPLOY_ONLY_IF_ETA_IMPROVES_BY, ONE))
            local unitIndex = options.unitIndex
            if not unitIndex then
                local supplyList = state.supply and state.supply[aiPlayer] or {}
                for idx, supplyUnit in ipairs(supplyList) do
                    if supplyUnit and supplyUnit.name == unit.name then
                        unitIndex = idx
                        break
                    end
                end
            end

            if unitIndex then
                local etaBefore = self:estimateEndgamePathEta(state, selectedPath, horizon)
                local simState = self:applySupplyDeployment(state, {
                    type = "supply_deploy",
                    unitIndex = unitIndex,
                    unitName = unit.name,
                    target = {row = cell.row, col = cell.col}
                })
                local etaAfter = self:estimateEndgamePathEta(simState, selectedPath, horizon)
                local improvement = etaBefore - etaAfter
                local immediateLossRisk = self:isOwnHubThreatened(state, aiPlayer)

                if (not immediateLossRisk) and improvement < minImprovement then
                    self.endgameDeploySkippedCount = (self.endgameDeploySkippedCount or ZERO) + ONE
                    score = score - 5000
                else
                    score = score + math.max(ZERO, improvement * 180)
                end
            end
        end

        return score
    end

    --- Applies a supply deployment action to a copied state and returns the new state
    function aiClass:applySupplyDeployment(state, deployment)
        local newState = self:deepCopyState(state)
        local priorActionCount = state.turnActionCount or ZERO
        newState.turnActionCount = priorActionCount + ONE
        newState.firstActionRangedAttack = state.firstActionRangedAttack
        newState.hasDeployedThisTurn = true
        local aiPlayer = self:getFactionId()  -- Always use AI's faction, not state.currentPlayer

        if not newState.supply or not newState.supply[aiPlayer] then
            return state
        end
        if not deployment or deployment.type ~= "supply_deploy" then
            return state
        end
        if deployment.unitIndex < ONE or deployment.unitIndex > #newState.supply[aiPlayer] then
            return state
        end

        local unit = newState.supply[aiPlayer][deployment.unitIndex]
        if not unit then return state end

        -- ensure target empty
        if self:getUnitAtPosition(newState, deployment.target.row, deployment.target.col) then
            return state
        end

        -- remove from supply list
        table.remove(newState.supply[aiPlayer], deployment.unitIndex)

        -- place unit
        unit.row = deployment.target.row
        unit.col = deployment.target.col
        unit.player = aiPlayer  -- CRITICAL: Ensure deployed unit has correct player field
        unit.hasMoved = false
        unit.hasActed = true -- deploying counts as action
        unit.actionsUsed = ONE
        table.insert(newState.units, unit)

        if deployment.guardIntent then
            newState.guardAssignments = newState.guardAssignments or {}
            local unitKey = self:getUnitKey(unit)
            if unitKey then
                newState.guardAssignments[unitKey] = {
                    row = deployment.guardIntent.row,
                    col = deployment.guardIntent.col
                }
            end
        end

        -- update remaining actions tracking
        self:removeUnitFromRemainingActions(newState, unit)

        return newState
    end

    -- Core AI Decision Making Functions (keeping these in main file for now)
    function aiClass:executeActionsSequence(moveSequence)
        if not moveSequence or #moveSequence == ZERO then
            self:logDecision("Execution", "No actions to execute")
            if self.grid then
                aiDebugPrint("[AI] Clearing highlights: empty sequence")
                self.grid:clearHighlightedCells()
                self.grid:clearForcedHighlightedCells({ attackOnly = true })
                self.grid:clearActionHighlights()
            end
            self.currentActionPreview = nil
            if self.gameRuler and self.gameRuler.performAction then
                self.gameRuler:performAction("endActions")
            end
            return
        end

        self:logDecision("Execution", "Executing action sequence", moveSequence)

        local turnFlowConfig = self:getTurnFlowScoreConfig()
        local defaultTurnFlowConfig = DEFAULT_SCORE_PARAMS.TURN_FLOW or {}
        local actionsSequenceDelay = valueOr(turnFlowConfig.ACTION_SEQUENCE_DELAY, valueOr(defaultTurnFlowConfig.ACTION_SEQUENCE_DELAY, ZERO))
        local attackPointerDelay = valueOr(turnFlowConfig.ATTACK_POINTER_DELAY, valueOr(defaultTurnFlowConfig.ATTACK_POINTER_DELAY, ZERO))

        local function executeAction(actionIndex)
            if actionIndex > #moveSequence then
                self:logDecision("Execution", "Sequence completed")
                if self.grid then
                    aiDebugPrint(string.format("[AI] Sequence complete for faction %s – clearing highlights", tostring(self.factionId)))
                    self.grid:clearHighlightedCells()
                    self.grid:clearForcedHighlightedCells({ attackOnly = true })
                    self.grid:clearActionHighlights()
                end
                self.currentActionPreview = nil
                if self.gameRuler and self.gameRuler.performAction then
                    self:scheduleAfterAnimations(actionsSequenceDelay, function()
                        self.gameRuler:performAction("endActions")
                    end)
                end
                return
            end

            local action = moveSequence[actionIndex]
            local previewFunc, executeFunc


            if action.type == "move" then
                previewFunc = "previewUnitMovement"
                executeFunc = "executeUnitMovement"
            elseif action.type == "attack" then
                previewFunc = "previewUnitAttack"
                executeFunc = "executeUnitAttack"
            elseif action.type == "repair" then
                previewFunc = "previewUnitRepair"
                executeFunc = "executeUnitRepair"
            elseif action.type == "supply_deploy" then
                self:handleSupplyDeployment(action, actionsSequenceDelay, executeAction, actionIndex)
                return
            elseif action.type == "skip" then
                executeAction(actionIndex + ONE)
                return
            end

            if previewFunc and executeFunc then
                local unitAtPosition = nil

                if action.unit and action.unit.row and action.unit.col then
                    local cell = self.grid and self.grid:getCell(action.unit.row, action.unit.col)
                    unitAtPosition = cell and cell.unit
                end

                if not unitAtPosition then
                    logger.error("AI", "ERROR: No unit found at position for action execution:", action.unit and action.unit.row, action.unit and action.unit.col, "Action type:", action.type)
                    logger.warn("AI", "  Skipping action and continuing to next...")
                    self:scheduleAfterAnimations(actionsSequenceDelay, function()
                        executeAction(actionIndex + ONE)
                    end)
                    return
                end
            
                self.gameRuler[previewFunc](self.gameRuler, action.unit.row, action.unit.col)
            
                -- In AI vs AI mode, show the unit info in the info panel
                if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI and GAME.CURRENT.UI then
                    local ui = GAME.CURRENT.UI
                    if unitAtPosition then
                        aiDebugPrint("AI vs AI: Showing unit info for", unitAtPosition.name, "at", action.unit.row, action.unit.col)
                        if ui.createUnitInfoFromUnit and ui.setContent then
                            local unitInfo = ui:createUnitInfoFromUnit(unitAtPosition, self.factionId)
                            ui:setContent(unitInfo, ui.playerThemes[self.factionId] or ui.playerThemes[ZERO])
                            ui.forceInfoPanelDefault = false
                            aiDebugPrint("Info panel updated with unit:", unitAtPosition.name)
                        end
                    else
                        aiDebugPrint("AI vs AI: Failed to show unit info - no unit at position")
                    end
                end

                self:scheduleAfterAnimations(actionsSequenceDelay, function()
                    -- Debug: Log the action being executed with full context
                    if action.type == "move" then
                        aiDebugPrint(string.format("DEBUG: Executing move from (%d,%d) to (%d,%d)", 
                            action.unit.row, action.unit.col, action.target.row, action.target.col))
                    
                        -- Check unit state before execution
                        local unit = self.grid and self.grid:getUnitAt(action.unit.row, action.unit.col)
                        if unit then
                            aiDebugPrint(string.format("  Unit: %s | hasActed=%s | hasMoved=%s | turnActions=%s", 
                                unit.name, tostring(unit.hasActed), tostring(unit.hasMoved), 
                                unit.turnActions and (unit.turnActions.move and "move=true" or "move=nil") or "nil"))
                        else
                            aiDebugPrint("  WARNING: No unit found at source position!")
                        end
                    
                        -- Check destination
                        local destCell = self.grid and self.grid:getCell(action.target.row, action.target.col)
                        if destCell and destCell.unit then
                            aiDebugPrint(string.format("  WARNING: Destination occupied by %s!", destCell.unit.name))
                        end
                    elseif action.type == "attack" then
                        aiDebugPrint(string.format("DEBUG: Executing attack from (%d,%d) to (%d,%d)", 
                            action.unit.row, action.unit.col, action.target.row, action.target.col))
                    end
                
                    local result = self.gameRuler[executeFunc](self.gameRuler,
                        action.unit.row,
                        action.unit.col,
                        action.target.row,
                        action.target.col)
                
                    -- Log execution result
                    if action.type == "move" then
                        aiDebugPrint(string.format("  Execution result: %s", tostring(result)))
                        if result then
                            local movedUnit = self.grid and self.grid:getUnitAt(action.target.row, action.target.col) or unitAtPosition
                            self:recordExecutedLowImpactMovePattern(
                                movedUnit or unitAtPosition,
                                action.unit,
                                action.target,
                                action._aiTag,
                                GAME and GAME.CURRENT and GAME.CURRENT.TURN or ZERO
                            )
                        end
                    end

                    if self.grid then
                        aiDebugPrint(string.format("[AI] Action %s executed – clearing cached previews", action.type))
                        self.grid:clearHighlightedCells()
                        self.grid:clearForcedHighlightedCells({ attackOnly = true })
                        self.grid:clearActionHighlights()
                    end
                    self.currentActionPreview = nil

                    if action.type == "move" then
                        self:refreshGuardAssignmentsFromGrid()
                    elseif action.type == "supply_deploy" then
                        self.guardAssignments = self.guardAssignments or {}
                        local spawnKey = string.format("spawn:%d,%d", action.target.row, action.target.col)
                        local spawnAssignment = self.guardAssignments[spawnKey]
                        self:refreshGuardAssignmentsFromGrid()
                        if spawnAssignment then
                            local movedUnit = self.grid and self.grid:getUnitAt(action.target.row, action.target.col)
                            if movedUnit then
                                local newKey = self:getUnitKey(movedUnit)
                                if newKey then
                                    self.guardAssignments[newKey] = {
                                        row = spawnAssignment.row,
                                        col = spawnAssignment.col
                                    }
                                end
                            end
                        end
                        self.guardAssignments[spawnKey] = nil
                    end

                    if self.grid and self.grid.addAIDecisionEffect and action.target then
                        local effectType = action.type
                        if effectType == "supply_deploy" then
                            effectType = "supply"
                        end

                        local function triggerDecisionEffect()
                            self.grid:addAIDecisionEffect(action.target.row, action.target.col, effectType)
                        end

                        if effectType == "attack" and self.gameRuler and self.gameRuler.scheduleAction then
                            self.gameRuler:scheduleAction(attackPointerDelay, triggerDecisionEffect)
                        else
                            triggerDecisionEffect()
                        end
                    end

                    self:scheduleAfterAnimations(actionsSequenceDelay, function()
                        local postState = self:getStateFromGrid()
                        if postState then
                            self._lastLoggedStateSnapshot = postState
                            self:logDecision("Execution", "Post-action grid", {
                                aiUnits = self:countAiUnits(postState),
                                totalUnitsOnGrid = postState.units and #postState.units or ZERO
                            })
                        else
                            self:logDecision("Execution", "Post-action grid unavailable")
                        end
                        executeAction(actionIndex + ONE)
                    end)
                end)
            else
        -- Unknown action type: skip to next action
                self:scheduleAfterAnimations(actionsSequenceDelay, function()
                    executeAction(actionIndex + ONE)
                end)
            end
        end

        executeAction(ONE)
    end

    function aiClass:handleSupplyDeployment(action, actionsSequenceDelay, executeAction, actionIndex)
        -- In AI vs AI mode, show the unit being deployed in the info panel
        if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI and GAME.CURRENT.UI then
            local ui = GAME.CURRENT.UI
            local currentSupply = self.factionId == ONE and self.gameRuler.player1Supply or self.gameRuler.player2Supply
            if currentSupply and action.unitIndex and currentSupply[action.unitIndex] then
                local unitToDeploy = currentSupply[action.unitIndex]
                aiDebugPrint("AI vs AI: Showing deployment unit info for", unitToDeploy.name)
                local unitInfo = ui:createUnitInfoFromUnit(unitToDeploy, self.factionId)
                ui:setContent(unitInfo, ui.playerThemes[self.factionId] or ui.playerThemes[ZERO])
                ui.forceInfoPanelDefault = false
            end
        end
    
        self:scheduleAfterAnimations(actionsSequenceDelay, function()
            local success = false
            local currentTurn = GAME.CURRENT.TURN

            -- Validate position is still available (grid should be current at this point)
            local targetUnit = self.grid and self.grid:getUnitAt(action.target.row, action.target.col)
            if targetUnit then
                -- Skip this action and continue with the sequence
                if self.grid then
                    self.grid:clearHighlightedCells()
                    self.grid:clearForcedHighlightedCells()
                    self.grid:clearActionHighlights()
                end
                self.gameRuler:scheduleAction(actionsSequenceDelay, function()
                    executeAction(actionIndex + ONE)
                end)
                return
            end

            -- Validate supply index
            local currentSupply = self.factionId == ONE and self.gameRuler.player1Supply or self.gameRuler.player2Supply
            if not currentSupply or action.unitIndex > #currentSupply then
                -- Skip this action and continue with the sequence
                if self.grid then
                    self.grid:clearHighlightedCells()
                    self.grid:clearForcedHighlightedCells()
                    self.grid:clearActionHighlights()
                end
                self.gameRuler:scheduleAction(actionsSequenceDelay, function()
                    executeAction(actionIndex + ONE)
                end)
                return
            end

            -- Debug hub position mismatch - get fresh state to ensure accurate hub tracking
            local freshState = self:getStateFromGrid()
            local aiHubPos = nil
            if freshState and freshState.commandHubs then
                aiHubPos = freshState.commandHubs[self.factionId]
            end
            local gameHubPos = self.gameRuler.commandHubPositions and self.gameRuler.commandHubPositions[self.factionId]


            -- Validate deployment position against actual game hub position
            if gameHubPos then
                local distance = math.abs(action.target.row - gameHubPos.row) + math.abs(action.target.col - gameHubPos.col)
                if distance ~= ONE then
                    executeAction(actionIndex + ONE)
                    return
                end
            end

            -- Try deployment

            -- Use the correct deployment method for actions phase
            if self.gameRuler.performAction then
                success = self.gameRuler:performAction("deployUnit", {
                    unitIndex = action.unitIndex,
                    row = action.target.row,
                    col = action.target.col
                })
            elseif self.gameRuler.deployUnitInActionsPhase then
                success = self.gameRuler:deployUnitInActionsPhase(action.unitIndex, action.target.row, action.target.col)
            elseif self.gameRuler.deploySupplyUnit then
                success = self.gameRuler:deploySupplyUnit(action.unitIndex, action.target.row, action.target.col)
            elseif self.gameRuler.deployFromSupply then
                success = self.gameRuler:deployFromSupply(action.unitIndex, action.target.row, action.target.col)
            elseif self.gameRuler.placeSupplyUnit then
                success = self.gameRuler:placeSupplyUnit(action.unitIndex, action.target.row, action.target.col)
            end


            if success then
                self.hasDeployedThisTurn = true
                self.globalDeploymentTracking = true
            else
                local alternativeDeployment = self:findAlternativeDeploymentPosition(action)
                if alternativeDeployment and self.gameRuler.deploySupplyUnit then
                    success = self.gameRuler:deploySupplyUnit(alternativeDeployment.unitIndex, alternativeDeployment.target.row, alternativeDeployment.target.col)
                    if success then
                        self.hasDeployedThisTurn = true
                        self.globalDeploymentTracking = true
                    end
                else
                end
            end

            if self.grid then
                self.grid:clearHighlightedCells()
                self.grid:clearForcedHighlightedCells()
                self.grid:clearActionHighlights()
            end

            self:scheduleAfterAnimations(actionsSequenceDelay, function()
                executeAction(actionIndex + ONE)
            end)
        end)
    end

    function aiClass:findAlternativeDeploymentPosition(originalAction)
        local currentState = self:getStateFromGrid()
        if not currentState then
            return nil
        end
        local supplyDeployments = self:getPossibleSupplyDeployments(currentState)

        local alternatives = {}
        for _, deployment in ipairs(supplyDeployments) do
            if deployment.target.row ~= originalAction.target.row or 
               deployment.target.col ~= originalAction.target.col then

                local targetUnit = self.grid and self.grid:getUnitAt(deployment.target.row, deployment.target.col)
                if not targetUnit then
                    table.insert(alternatives, deployment)
                end
            end
        end

        return alternatives[ONE]
    end

    -- Placeholder functions for game phase handlers (these would be refactored into separate modules)
    function aiClass:handleAINeutralBuildingPlacement()
        local setupState = self:getStateFromGrid()
        self._referenceResolutionState = setupState
        self:getEffectiveAiReference(setupState, {
            lock = true,
            context = "setup_neutral_buildings",
            logSwitch = true
        })
        local setupConfig = self:getSetupScoreConfig()
        local defaultSetupConfig = DEFAULT_SCORE_PARAMS.SETUP or {}
        local neutralBuildings = self.gameRuler and self.gameRuler.neutralBuildings
        local placedBuildings = neutralBuildings and #neutralBuildings or ZERO
        local requiredBuildings = valueOr(
            (SETUP_RULE_CONTRACT.OBSTACLES or {}).COUNT,
            valueOr(setupConfig.REQUIRED_NEUTRAL_BUILDINGS, valueOr(defaultSetupConfig.REQUIRED_NEUTRAL_BUILDINGS, FOUR))
        )
        local rockDisplayConfig = setupConfig.NEUTRAL_ROCK_DISPLAY or defaultSetupConfig.NEUTRAL_ROCK_DISPLAY or {}

        -- In AI vs AI mode, show rock info in the info panel
        if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI and GAME.CURRENT.UI then
            local ui = GAME.CURRENT.UI
            -- Create a rock unit-like object for display
            local rockUnit = {
                name = "Rock",
                shortName = "Rock",
                type = "Obstacle",
                currentHp = valueOr(rockDisplayConfig.currentHp, FIVE),
                startingHp = valueOr(rockDisplayConfig.startingHp, FIVE),
                atkDamage = valueOr(rockDisplayConfig.atkDamage, ZERO),
                atkRange = valueOr(rockDisplayConfig.atkRange, ZERO),
                move = valueOr(rockDisplayConfig.move, ZERO),
                fly = false,
                pathUiIcon = "assets/sprites/NeutralBulding1_Resized.png",
                descriptions = {"Neutral terrain obstacle that blocks movement and line of sight."},
                specialAbilitiesDescriptions = {"Can be destroyed by Artillery units."},
                player = valueOr(rockDisplayConfig.player, ZERO)
            }
            local rockInfo = ui:createUnitInfoFromUnit(rockUnit, rockUnit.player)
            ui:setContent(rockInfo, ui.playerThemes[rockUnit.player])
            ui.forceInfoPanelDefault = false
        end

        if placedBuildings < requiredBuildings then
            local success, message = self.gameRuler:performAction("placeAllNeutralBuildings", {})
            return success
        else
            self.gameRuler:nextTurn()
            return true
        end
    end

    function aiClass:handleAICommandHubPlacement()
        local placementState = self:getStateFromGrid()
        self._referenceResolutionState = placementState
        local profileLabel = self:getAiProfileLabel(placementState, {
            lock = true,
            context = "setup_hub_placement",
            logSwitch = true
        })
        -- Unified baseline hub placement logic
        local setupConfig = self:getSetupScoreConfig()
        local defaultSetupConfig = DEFAULT_SCORE_PARAMS.SETUP or {}
        local maxPlacementAttempts = valueOr(setupConfig.HUB_PLACEMENT_ATTEMPTS, valueOr(defaultSetupConfig.HUB_PLACEMENT_ATTEMPTS, TEN))
        local preferredRowAttempts = valueOr(setupConfig.HUB_PREFERRED_ROW_ATTEMPTS, valueOr(defaultSetupConfig.HUB_PREFERRED_ROW_ATTEMPTS, THREE))
        local validZone = self.gameRuler.commandHubsValidPositions[self.factionId]
    
        aiDebugPrint("AI placing command hub for faction:", self.factionId, "Profile:", profileLabel)
        aiDebugPrint("Current phase:", self.gameRuler:getCurrentPhaseInfo().currentPhase)
        aiDebugPrint("Hub already placed?", self.gameRuler.commandHubPositions[self.factionId] ~= nil)

        -- Check if hub is already placed for this faction
        if self.gameRuler.commandHubPositions[self.factionId] then
            aiDebugPrint("Hub already placed for faction", self.factionId, "- skipping")
            return true
        end

        -- Use center row as deterministic baseline.
        local preferredRow = math.floor((validZone.min + validZone.max) / TWO)

        -- Try preferred row first, then expand search
        for attempts = ONE, maxPlacementAttempts do
            local row
            if attempts <= preferredRowAttempts then
                -- First 3 attempts: try preferred row
                row = preferredRow
            else
                -- Fallback: random within valid zone
                row = randomGen.randomInt(validZone.min, validZone.max)
            end
        
            local col = randomGen.randomInt(ONE, GAME.CONSTANTS.GRID_SIZE)

            if self.grid:isCellEmpty(row, col) then
                local success = self.gameRuler:performAction("placeCommandHub", {
                    row = row, col = col
                })
                if success then 
                    aiDebugPrint("Successfully placed hub for faction", self.factionId, "at", row, col, "(profile:", profileLabel, ")")
                
                    -- In AI vs AI mode, show Commandant info after placement
                    if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI and GAME.CURRENT.UI then
                        local ui = GAME.CURRENT.UI
                        local commandant = self.grid:getUnitAt(row, col)
                        if commandant and ui.createUnitInfoFromUnit then
                            local unitInfo = ui:createUnitInfoFromUnit(commandant, self.factionId)
                            ui:setContent(unitInfo, ui.playerThemes[self.factionId] or ui.playerThemes[ZERO])
                            ui.forceInfoPanelDefault = false
                        end
                    end
                
                    return true 
                end
            end
        end

        aiDebugPrint("Failed to place hub for faction", self.factionId)
        return false
    end

    function aiClass:handleAIInitialDeployment()
        -- Unified baseline deployment logic
        local supply = self.factionId == ONE and self.gameRuler.player1Supply or self.gameRuler.player2Supply
        local hubPos = self.gameRuler.commandHubPositions[self.factionId]

        if supply and #supply > ZERO and hubPos then
            local openingState = self:getStateFromGrid()
            self._referenceResolutionState = openingState
            local profileLabel = self:getAiProfileLabel(openingState, {
                lock = true,
                context = "setup_initial_deploy",
                logSwitch = true
            })
            -- Select unit using adaptive opening guardrails first.
            local selectedUnitIndex = self:getPreferredSupplyUnitIndex(supply, {
                hubPos = hubPos,
                turnNumber = (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or ONE,
                state = openingState
            })
            if not selectedUnitIndex then
                for i, unit in ipairs(supply) do
                    if not self:unitHasTag(unit, "healer") then
                        selectedUnitIndex = i
                        break
                    end
                end
            end
            selectedUnitIndex = selectedUnitIndex or ONE
            self.gameRuler.initialDeployment.selectedUnitIndex = selectedUnitIndex
        
            aiDebugPrint("AI initial deployment - Profile:", profileLabel, "Selected:", supply[selectedUnitIndex].name)
        
            -- In AI vs AI mode, show the unit being deployed
            if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI and GAME.CURRENT.UI then
                local ui = GAME.CURRENT.UI
                local unitToDeploy = supply[selectedUnitIndex]
                if unitToDeploy and ui.createUnitInfoFromUnit then
                    local unitInfo = ui:createUnitInfoFromUnit(unitToDeploy, self.factionId)
                    ui:setContent(unitInfo, ui.playerThemes[self.factionId] or ui.playerThemes[ZERO])
                    ui.forceInfoPanelDefault = false
                end
            end

            -- Choose deployment position with a single baseline rule: prefer center-adjacent cell.
            local availableCells = self.gameRuler.initialDeployment.availableCells
            local selectedCell = nil
            local centerRow = math.floor(GAME.CONSTANTS.GRID_SIZE / TWO)
            local centerCol = math.floor(GAME.CONSTANTS.GRID_SIZE / TWO)
            local bestCenterDist = math.huge
            local bestHubDist = math.huge
            for i, cell in ipairs(availableCells) do
                local centerDist = math.abs(cell.row - centerRow) + math.abs(cell.col - centerCol)
                local hubDist = math.abs(cell.row - hubPos.row) + math.abs(cell.col - hubPos.col)
                if centerDist < bestCenterDist or (centerDist == bestCenterDist and hubDist < bestHubDist) then
                    bestCenterDist = centerDist
                    bestHubDist = hubDist
                    selectedCell = i
                end
            end
            selectedCell = selectedCell or randomGen.randomInt(ONE, #availableCells)

            local success = self.gameRuler:performAction("deployUnitNearHub", {
                row = availableCells[selectedCell].row,
                col = availableCells[selectedCell].col
            })
            if success then
                self.gameRuler:currentPlayerStartingUnitsAllDeployed()
            end
        end
    end

    -- Core AI logic functions with 2-phase approach
    function aiClass:getBestSequence(state)
        self._decisionGuardContext = nil
        self._referenceResolutionState = state
        self:getEffectiveAiReference(state, {
            lock = true,
            context = "decision_cycle",
            logSwitch = true
        })
        local decisionStartTime = (love and love.timer and love.timer.getTime and love.timer.getTime()) or nil
        local budgetMs = valueOr(PERFORMANCE_RULE_CONTRACT.DECISION_BUDGET_MS, 500)
        local function finalizeDecisionLatency(sequence)
            if not decisionStartTime or not (love and love.timer and love.timer.getTime) then
                self._decisionGuardContext = nil
                self._referenceResolutionState = nil
                return
            end
            local elapsedMs = (love.timer.getTime() - decisionStartTime) * 1000
            self.lastDecisionLatencyMs = elapsedMs
            self.decisionLatencySamples = self.decisionLatencySamples or {}
            table.insert(self.decisionLatencySamples, elapsedMs)
            local maxSamples = valueOr(PERFORMANCE_RULE_CONTRACT.MAX_SAMPLE_WINDOW, 200)
            while #self.decisionLatencySamples > maxSamples do
                table.remove(self.decisionLatencySamples, ONE)
            end

            local sortedSamples = {}
            for i = ONE, #self.decisionLatencySamples do
                sortedSamples[i] = self.decisionLatencySamples[i]
            end
            table.sort(sortedSamples)

            local sampleCount = #sortedSamples
            local medianIdx = math.max(ONE, math.ceil(sampleCount * 0.5))
            local p95Idx = math.max(ONE, math.ceil(sampleCount * 0.95))
            local medianMs = sortedSamples[medianIdx] or elapsedMs
            local p95Ms = sortedSamples[p95Idx] or elapsedMs
            self.lastDecisionLatencySummary = {
                count = sampleCount,
                medianMs = medianMs,
                p95Ms = p95Ms
            }

            self.decisionCount = (self.decisionCount or ZERO) + ONE
            local reportInterval = valueOr(PERFORMANCE_RULE_CONTRACT.REPORT_INTERVAL, 20)
            if reportInterval > ZERO and (self.decisionCount % reportInterval) == ZERO then
                self:logDecision("Performance", string.format(
                    "Latency summary after %d decisions: median %.1fms, p95 %.1fms, budget %dms",
                    self.decisionCount,
                    medianMs,
                    p95Ms,
                    budgetMs
                ))
            end

            if elapsedMs > budgetMs or p95Ms > budgetMs then
                self:logDecision("Performance", string.format(
                    "Decision latency %.1fms (median %.1fms, p95 %.1fms) exceeded budget (%dms)",
                    elapsedMs,
                    medianMs,
                    p95Ms,
                    budgetMs
                ))
            end

            self:recordDeterminismObservation(state, sequence or {})
            self._decisionGuardContext = nil
            self._referenceResolutionState = nil
        end

        -- Enhanced turn tracking
        local currentTurn = GAME.CURRENT.TURN
        local currentPhase = state.phase or "actions"
        local turnPhaseKey = currentTurn .. "_" .. currentPhase .. "_" .. valueOr(self.factionId, TWO)

        -- Prevent multiple processing of same turn
        if self.lastProcessedTurnKey == turnPhaseKey then
            self._referenceResolutionState = nil
            return self.lastSequence or {}
        end

        -- Reset flags for new turn
        if not self.lastProcessedTurn or self.lastProcessedTurn < currentTurn then
            self.hasDeployedThisTurn = false
            self.globalDeploymentTracking = false
            self.lastProcessedTurn = currentTurn
            self.isProcessingTurn = false
        end

        -- Prevent concurrent processing
        if self.isProcessingTurn then
            self._referenceResolutionState = nil
            return {}
        end

        self.isProcessingTurn = true
        self._rangedDuelPressureCache = {}
        self.lastProcessedTurnKey = turnPhaseKey

        self._lastLoggedStateSnapshot = state
    
        -- Refresh adaptive profile controls.
        if currentPhase == "actions" then
            self:updateAdaptiveProfile(currentTurn, state)
        end

        -- Update draw urgency using configurable parameters
        self:updateDrawUrgencyState(state)
        local threatReleaseState = self:updateThreatReleaseOffenseState(state)
        local strategicState = self:updateStrategicPlanState(state)
        local tempoContext = self:getPhaseTempoContext(state)

        self:logDecision("TempoPhase", "Tempo phase classified", {
            phase = tempoContext and tempoContext.phase or "mid",
            reason = tempoContext and tempoContext.reason or "unknown",
            enemySupplyRemaining = tempoContext and tempoContext.enemySupplyRemaining or ZERO,
            contactTriggered = tempoContext and tempoContext.contactTriggered or false,
            endgamePath = tempoContext and tempoContext.endgamePath or nil
        })

        self:logDecision("Sequence", "Begin decision search", {
            turn = currentTurn,
            phase = currentPhase,
            tempoPhase = tempoContext and tempoContext.phase or "mid",
            totalUnitsOnGrid = state.units and #state.units or ZERO,
            threatReleaseActive = threatReleaseState and threatReleaseState.active or false,
            threatReleaseTurnsRemaining = threatReleaseState and threatReleaseState.turnsRemaining or ZERO,
            strategyIntent = strategicState and strategicState.intent or STRATEGY_INTENT.STABILIZE,
            strategyPlanId = strategicState and strategicState.planId or nil,
            strategyPlanTurnsLeft = strategicState and strategicState.planTurnsLeft or ZERO,
            strategyPlanScore = strategicState and strategicState.planScore or ZERO
        })

        -- Validate state before processing
        if not state or not state.units then
            self.isProcessingTurn = false
            finalizeDecisionLatency({})
            return {}
        end

        -- Ensure we always return exactly 2 actions per turn
        local maxActions = valueOr(TURN_RULE_CONTRACT.ACTIONS_PER_TURN, valueOr(ACTION_RULE_CONTRACT.MANDATORY_ACTION_COUNT, valueOr(GAME.CONSTANTS.MAX_ACTIONS_PER_TURN, TWO)))
        local sequence = {}
        self._decisionGuardContext = {
            startTime = decisionStartTime,
            budgetMs = budgetMs
        }

        -- PHASE 1: Find obvious moves (priority heuristic)
        self._logState = state
        self._lastSequenceStateForLogging = state

        local obviousMoves = self:findBestAiSequance(state)
        if obviousMoves and #obviousMoves > ZERO then
            self:logDecision("Sequence", "Obvious moves candidates", obviousMoves)
        else
            self:logDecision("Sequence", "No obvious moves found")
        end

        if self.drawUrgencyMode and self.drawUrgencyMode.active then
            local prioritized = {}
            local deferred = {}

            for _, action in ipairs(obviousMoves or {}) do
                if action.type == "attack" then
                    table.insert(prioritized, action)
                else
                    table.insert(deferred, action)
                end
            end

            if #prioritized > ZERO then
                local combined = {}
                for _, action in ipairs(prioritized) do
                    table.insert(combined, action)
                end
                for _, action in ipairs(deferred) do
                    table.insert(combined, action)
                end
                obviousMoves = combined
                self:logDecision("DrawUrgency", "Attack-first reorder applied during draw urgency")
            end
        end

        -- Add obvious moves to sequence (findBestAiSequance already ensures maxActions with skip actions)
        for _, action in ipairs(obviousMoves) do
            if #sequence < maxActions then
                table.insert(sequence, action)
            end
        end
    
        -- Limit to exactly maxActions
        local finalSequence = {}
        for i = ONE, math.min(#sequence, maxActions) do
            table.insert(finalSequence, sequence[i])
        end

        finalSequence, self._lastSanitizeSummary = self:sanitizeActionSequenceForState(state, finalSequence, {
            aiPlayer = self:getFactionId(),
            maxActions = maxActions,
            allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
        })
        if self._lastSanitizeSummary and (self._lastSanitizeSummary.replacements or ZERO) > ZERO then
            self:logDecision("Sequence", "Sequence sanitized before execution", {
                replacements = self._lastSanitizeSummary.replacements,
                reasons = self._lastSanitizeSummary.reasonCounts
            })
        end

        local verifierConfig = (self:getStrategyScoreConfig().VERIFIER or {})
        local sequenceHasPriority00 = false
        for _, action in ipairs(finalSequence or {}) do
            local tag = action and action._aiTag
            if type(tag) == "string" and string.sub(tag, ONE, 7) == "WINNING" then
                sequenceHasPriority00 = true
                break
            end
        end

        local siegeActive = strategicState
            and strategicState.active
            and (strategicState.intent == STRATEGY_INTENT.SIEGE_SETUP or strategicState.intent == STRATEGY_INTENT.SIEGE_EXECUTE)
        local verifierEnabled = valueOr(verifierConfig.ENABLED, true)
        local runDuringSiege = valueOr(verifierConfig.RUN_DURING_SIEGE, false)
        local skipOnlyPriority00 = valueOr(verifierConfig.SKIP_ONLY_FOR_PRIORITY00, false)
        local verifierBudgetMs = valueOr(verifierConfig.BUDGET_MS, 180)
        local remainingBudgetForVerifier = nil

        local skipVerifier = false
        local skipReason = nil
        if verifierEnabled then
            if siegeActive and not runDuringSiege then
                skipVerifier = true
                skipReason = "siege_disabled"
            end
            if skipOnlyPriority00 and sequenceHasPriority00 then
                skipVerifier = true
                skipReason = "priority00_winning_sequence"
            end
            if decisionStartTime and love and love.timer and love.timer.getTime then
                local elapsedMs = (love.timer.getTime() - decisionStartTime) * 1000
                remainingBudgetForVerifier = budgetMs - elapsedMs - 15
                if remainingBudgetForVerifier <= 10 then
                    skipVerifier = true
                    skipReason = "budget_exhausted"
                else
                    verifierBudgetMs = math.max(10, math.min(verifierBudgetMs, remainingBudgetForVerifier))
                end
            end
            if verifierBudgetMs <= 40 then
                skipVerifier = true
                skipReason = "insufficient_verifier_budget"
            end
        end

        if verifierEnabled and not skipVerifier then
            if siegeActive then
                self.verifierSiegeRuns = (self.verifierSiegeRuns or ZERO) + ONE
            end
            local candidates = self:collectSequenceCandidates(state, finalSequence, {
                verifierBudgetMs = verifierBudgetMs,
                remainingDecisionBudgetMs = remainingBudgetForVerifier,
                tempoContext = tempoContext
            })
            local verifiedSequence, verifierMeta = self:selectVerifiedSequence(
                state,
                candidates,
                verifierBudgetMs
            )
            if verifierMeta and verifierMeta.timedOut then
                self:logDecision("Verifier", "Verifier budget timeout; using best evaluated candidate", {
                    evaluated = verifierMeta.evaluated or ZERO,
                    bestSource = verifierMeta.bestSource,
                    bestScore = verifierMeta.bestScore
                })
            end
            if verifiedSequence and #verifiedSequence > ZERO then
                local primarySignature = self:buildActionSequenceSignature(finalSequence)
                local verifiedSignature = self:buildActionSequenceSignature(verifiedSequence)
                if verifiedSignature ~= primarySignature then
                    local function countAttacks(seq)
                        local count = ZERO
                        for _, action in ipairs(seq or {}) do
                            if action and action.type == "attack" then
                                count = count + ONE
                            end
                        end
                        return count
                    end
                    local function countActionsByType(seq, actionType)
                        local count = ZERO
                        for _, action in ipairs(seq or {}) do
                            if action and action.type == actionType then
                                count = count + ONE
                            end
                        end
                        return count
                    end
                    local function countTaggedActions(seq, tagPrefix)
                        local count = ZERO
                        if type(tagPrefix) ~= "string" or #tagPrefix == ZERO then
                            return count
                        end
                        for _, action in ipairs(seq or {}) do
                            local tag = action and action._aiTag
                            if type(tag) == "string" and string.sub(tag, ONE, #tagPrefix) == tagPrefix then
                                count = count + ONE
                            end
                        end
                        return count
                    end

                    local primaryAttackCount = countAttacks(finalSequence)
                    local verifiedAttackCount = countAttacks(verifiedSequence)
                    local primaryDefenseAttackCount = countTaggedActions(finalSequence, "STRATEGIC_DEFENSE_")
                    local primaryDeployCount = countActionsByType(finalSequence, "supply_deploy")
                    local verifiedDeployCount = countActionsByType(verifiedSequence, "supply_deploy")
                    local primaryStrategicSetupCount = countTaggedActions(finalSequence, "STRATEGIC_PLAN_")
                    local verifiedStrategicSetupCount = countTaggedActions(verifiedSequence, "STRATEGIC_PLAN_")
                    local primaryScore = verifierMeta and verifierMeta.primaryScore or nil
                    local bestScore = verifierMeta and verifierMeta.bestScore or nil
                    local scoreGain = (type(bestScore) == "number" and type(primaryScore) == "number")
                        and (bestScore - primaryScore)
                        or nil
                    local doctrineConfig = self:getDoctrineScoreConfig()
                    local legacyAttackGuardConfig = doctrineConfig.VERIFIER_ATTACK_GUARD or {}
                    local phaseGuardConfig = doctrineConfig.VERIFIER_PHASE_GUARD or legacyAttackGuardConfig
                    local attackGuardEnabled = valueOr(legacyAttackGuardConfig.ENABLED, true)
                    local earlyMinGain = valueOr(
                        phaseGuardConfig.EARLY_ATTACK_DROP_MIN_GAIN,
                        valueOr(legacyAttackGuardConfig.EARLY_MIN_GAIN, 260)
                    )
                    local midMinGain = valueOr(
                        phaseGuardConfig.MID_ATTACK_DROP_MIN_GAIN,
                        valueOr(legacyAttackGuardConfig.MID_MIN_GAIN, 180)
                    )
                    local allowAttackDropInDefendHard = valueOr(
                        phaseGuardConfig.ALLOW_ATTACK_DROP_IN_DEFEND_HARD,
                        valueOr(legacyAttackGuardConfig.DISABLE_IN_DEFEND_HARD, true)
                    )
                    local tempoPhase = tempoContext and tempoContext.phase or "mid"
                    local minAttackDropGain = (tempoPhase == "early") and earlyMinGain or midMinGain
                    local attackDropSuppressed = false
                    local defendHardIntent = strategicState and strategicState.intent == STRATEGY_INTENT.DEFEND_HARD
                    local defendHardDefenseAttack = defendHardIntent and primaryDefenseAttackCount > ZERO

                    if attackGuardEnabled
                        and primaryAttackCount > verifiedAttackCount
                        and strategicState
                        and (not (allowAttackDropInDefendHard and defendHardIntent and not defendHardDefenseAttack))
                        and not sequenceHasPriority00 then
                        if scoreGain == nil or scoreGain < minAttackDropGain then
                            attackDropSuppressed = true
                        end
                    end

                    if attackDropSuppressed then
                        self:logDecision("Verifier", "Override suppressed due to attack-loss guard", {
                            primary = primarySignature,
                            selected = verifiedSignature,
                            primaryAttackCount = primaryAttackCount,
                            verifiedAttackCount = verifiedAttackCount,
                            primaryDefenseAttackCount = primaryDefenseAttackCount,
                            scoreGain = scoreGain,
                            requiredGain = minAttackDropGain,
                            phase = tempoPhase
                        })
                        goto continue_verifier_selection
                    end

                    local strategicSetupSuppressed = false
                    local bestSource = verifierMeta and verifierMeta.bestSource or "unknown"
                    if not sequenceHasPriority00
                        and bestSource == "fallback_variant"
                        and primaryStrategicSetupCount > verifiedStrategicSetupCount then
                        local baseRequiredGain = (tempoPhase == "early")
                            and math.max(earlyMinGain, 260)
                            or math.max(midMinGain, 220)
                        local deploySwapPenalty = (verifiedDeployCount > primaryDeployCount) and 40 or ZERO
                        local requiredGain = baseRequiredGain + deploySwapPenalty
                        if scoreGain == nil or scoreGain < requiredGain then
                            strategicSetupSuppressed = true
                            self:logDecision("Verifier", "Override suppressed to preserve strategic setup tempo", {
                                primary = primarySignature,
                                selected = verifiedSignature,
                                selectedSource = bestSource,
                                primaryStrategicSetupCount = primaryStrategicSetupCount,
                                verifiedStrategicSetupCount = verifiedStrategicSetupCount,
                                primaryDeployCount = primaryDeployCount,
                                verifiedDeployCount = verifiedDeployCount,
                                scoreGain = scoreGain,
                                requiredGain = requiredGain,
                                phase = tempoPhase
                            })
                        end
                    end
                    if strategicSetupSuppressed then
                        goto continue_verifier_selection
                    end

                    self.verifierOverrideCount = (self.verifierOverrideCount or ZERO) + ONE
                    if siegeActive then
                        self.verifierSiegeOverrides = (self.verifierSiegeOverrides or ZERO) + ONE
                    end
                    self:logDecision("Verifier", "Verifier override applied", {
                        primary = primarySignature,
                        selected = verifiedSignature,
                        selectedSource = verifierMeta and verifierMeta.bestSource or "unknown",
                        selectedScore = verifierMeta and verifierMeta.bestScore or nil,
                        evaluated = verifierMeta and verifierMeta.evaluated or ZERO
                    })
                    finalSequence = verifiedSequence
                end
            end
            ::continue_verifier_selection::
        elseif verifierEnabled and skipVerifier then
            self:logDecision("Verifier", "Verifier skipped", {
                reason = skipReason,
                siegeActive = siegeActive,
                sequenceHasPriority00 = sequenceHasPriority00,
                remainingBudgetMs = remainingBudgetForVerifier
            })
        end
    
        -- Cleanup
        self.isProcessingTurn = false
        self.lastSequence = finalSequence

        self:logDecision("Sequence", "Final sequence selected", finalSequence)
        finalizeDecisionLatency(finalSequence)
        return finalSequence
    end

    function aiClass:createSkipAction(state)
        local turnFlowConfig = self:getTurnFlowScoreConfig()
        local defaultTurnFlowConfig = DEFAULT_SCORE_PARAMS.TURN_FLOW or {}
        local defaultCell = turnFlowConfig.SKIP_FALLBACK_CELL or defaultTurnFlowConfig.SKIP_FALLBACK_CELL or {row = ONE, col = ONE}

        -- Create a skip action as last resort
        self:logDecision("Sequence", "Skip action created", {
            type = "skip",
            unit = {row = defaultCell.row, col = defaultCell.col}
        })
        return {
            type = "skip",
            unit = {row = defaultCell.row, col = defaultCell.col}
        }
    end

    function aiClass:calculateDamage(attackingUnit, defendingUnit)
        -- Use centralized damage calculation from unitsInfo
        return unitsInfo:calculateAttackDamage(attackingUnit, defendingUnit)
    end

    function aiClass:applyMove(state, move)
        -- Input validation
        if not state or not move or not move.unit then
            return state
        end

        local newState = self:deepCopyState(state)
        newState.attackedObjectivesThisTurn = newState.attackedObjectivesThisTurn or {}
        local unit = self:getUnitAtPosition(newState, move.unit.row, move.unit.col)
        if not unit then return newState end

        -- Track unit actions
        if not unit.actionsUsed then unit.actionsUsed = ZERO end
        if not unit.hasMoved then unit.hasMoved = false end

        newState.lastActionType = move.type
        newState.guardAssignments = newState.guardAssignments or {}
        local guardAssignments = newState.guardAssignments
        local oldGuardKey = self:getUnitKey(unit)

        if move.type == "move" then
            if oldGuardKey then
                guardAssignments[oldGuardKey] = nil
            end

            unit.row = move.target.row
            unit.col = move.target.col
            unit.actionsUsed = unit.actionsUsed + ONE
            unit.hasMoved = true
            -- Movement doesn't end the turn, unit can still attack/repair if not acted
            unit.hasActed = false

            if newState.turnActionCount == ONE then
                newState.firstActionRangedAttack = nil
            end

            -- Update position history to track recent positions (prevents oscillation)
            if self.positionHistory and unit.name then
                local posKey = string.format("%s_%d_%d", unit.name, unit.row, unit.col)
                self.positionHistory[posKey] = {
                    turn = state.currentTurn or MIN_HP,
                    unitName = unit.name
                }
            end

            if move.guardIntent then
                local newGuardKey = self:getUnitKey(unit)
                if newGuardKey then
                    guardAssignments[newGuardKey] = {
                        row = move.guardIntent.row,
                        col = move.guardIntent.col
                    }
                end
            end

        elseif move.type == "attack" then
            local targetUnit = self:getUnitAtPosition(newState, move.target.row, move.target.col)
            if not targetUnit then
                for _, building in ipairs(newState.neutralBuildings or {}) do
                    if building.row == move.target.row and building.col == move.target.col then
                        targetUnit = {
                            row = building.row,
                            col = building.col,
                            name = "Rock",
                            player = ZERO,
                            currentHp = building.currentHp,
                            startingHp = building.startingHp
                        }
                        break
                    end
                end
            end
            if targetUnit then
                local damage = self:calculateDamage(unit, targetUnit)
                local targetHp = targetUnit.currentHp or targetUnit.startingHp or MIN_HP
                targetUnit.currentHp = math.max(ZERO, targetHp - damage)
                if targetUnit.name == "Rock" and targetUnit.player == ZERO then
                    for _, building in ipairs(newState.neutralBuildings or {}) do
                        if building.row == move.target.row and building.col == move.target.col then
                            building.currentHp = targetUnit.currentHp
                            break
                        end
                    end
                end

                if damage > ZERO then
                    self:addAttackedObjectiveToState(newState, targetUnit, {
                        row = move.target.row,
                        col = move.target.col
                    }, unit.player)
                end

                newState.attackInfo = {
                    damage = damage,
                    killed = targetUnit.currentHp <= ZERO,
                    leftVulnerable = targetUnit.currentHp <= TWO and targetUnit.currentHp > ZERO,
                    targetValue = self:getUnitBaseValue(targetUnit, newState)
                }

                if targetUnit.currentHp <= ZERO then
                    local isAdjacent = math.abs(unit.row - move.target.row) + 
                                     math.abs(unit.col - move.target.col) == ONE

                    self:removeUnitFromState(newState, move.target.row, move.target.col)

                    if isAdjacent and not self:unitHasTag(unit, "corvette") then
                        unit.row = move.target.row
                        unit.col = move.target.col
                    end
                end
            end

            unit.actionsUsed = unit.actionsUsed + ONE
            unit.hasActed = true  -- Attack ends unit's turn - unit cannot do anything else

            if newState.turnActionCount == ONE then
                local attackRange = unit.atkRange or unitsInfo:getUnitAttackRange(unit, "FIRST_ACTION_SUPPORT") or MIN_HP
                if attackRange > ONE then
                    newState.firstActionRangedAttack = {
                        attacker = {
                            row = unit.row,
                            col = unit.col,
                            name = unit.name,
                            player = unit.player,
                            atkRange = attackRange
                        },
                        target = {
                            row = move.target.row,
                            col = move.target.col
                        }
                    }
                else
                    newState.firstActionRangedAttack = nil
                end
            else
                newState.firstActionRangedAttack = nil
            end

        elseif move.type == "repair" then
            local targetUnit = self:getUnitAtPosition(newState, move.target.row, move.target.col)
            if targetUnit then
                local currentHp = targetUnit.currentHp or targetUnit.startingHp or MIN_HP
                local maxHp = targetUnit.startingHp or MIN_HP
                local beforeHp = currentHp
                targetUnit.currentHp = math.min(maxHp, currentHp + TWO)

                newState.repairInfo = {
                    targetValue = self:getUnitBaseValue(targetUnit, newState),
                    healedToFull = targetUnit.currentHp == maxHp
                }
            end

            unit.actionsUsed = unit.actionsUsed + ONE
            unit.hasActed = true  -- Repair ends unit's turn - unit cannot do anything else

            if newState.turnActionCount == ONE then
                newState.firstActionRangedAttack = nil
            end

        elseif move.type == "supply_deploy" then
            -- Handle supply deployment in simulated state
            -- Add the deployed unit to the state so subsequent priorities know about it
            if (move.unitType or move.unitName) and move.target then
                -- Get player from the unit that's performing the action, or from state
                local aiPlayer = unit and unit.player
                if not aiPlayer then
                    aiPlayer = self:getFactionId()
                end
                if not aiPlayer then
                    -- Last resort: try to infer from existing units in state
                    for _, u in ipairs(state.units) do
                        if u.player and u.player > ZERO then
                            aiPlayer = u.player
                            break
                        end
                    end
                end
            
                local unitType = move.unitType or move.unitName
            
                local deployedUnit = {
                    row = move.target.row,
                    col = move.target.col,
                    name = unitType,
                    player = aiPlayer,  -- CRITICAL: Must have valid player ID
                    currentHp = self.unitsInfo:getUnitHP({name = unitType}, "SUPPLY_DEPLOY_SIM"),
                    startingHp = self.unitsInfo:getUnitHP({name = unitType}, "SUPPLY_DEPLOY_SIM"),
                    hasActed = true,  -- Deployed units can't act this turn
                    hasMoved = false,
                    actionsUsed = ZERO,
                    fly = self.unitsInfo:getUnitFlyStatus({name = unitType}, "SUPPLY_DEPLOY_SIM"),
                    atkDamage = self.unitsInfo:getUnitAttackDamage({name = unitType}, "SUPPLY_DEPLOY_SIM"),
                    move = self.unitsInfo:getUnitMoveRange({name = unitType}, "SUPPLY_DEPLOY_SIM"),
                    atkRange = self.unitsInfo:getUnitAttackRange({name = unitType}, "SUPPLY_DEPLOY_SIM"),
                    corvetteDamageFlag = false,
                    artilleryDamageFlag = false
                }
                table.insert(newState.units, deployedUnit)

                if move.guardIntent then
                    newState.guardAssignments = newState.guardAssignments or {}
                    local deployedKey = self:getUnitKey(deployedUnit)
                    if deployedKey then
                        newState.guardAssignments[deployedKey] = {
                            row = move.guardIntent.row,
                            col = move.guardIntent.col
                        }
                    end
                end
            end
        end

        if move.type ~= "move" and oldGuardKey then
            -- Clear guard assignment if unit died or changed identity (remove stale entries)
            local stillExists = self:getUnitAtPosition(newState, unit.row, unit.col)
            if not stillExists then
                guardAssignments[oldGuardKey] = nil
            end
        end

        self:removeUnitFromRemainingActions(newState, unit)
        return newState
    end

    function aiClass:getPossibleSupplyDeployments(state, skipGridCheck)
        local deployments = {}
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return deployments
        end
        if not state then
            return deployments
        end
        if state.hasDeployedThisTurn then
            return deployments
        end

        -- Check if AI has supply remaining
        if not state.supply or not state.supply[aiPlayer] or #state.supply[aiPlayer] == ZERO then
            return deployments
        end

        if not state.commandHubs then
            return deployments
        end

        -- Check if Commandant exists
        local ownHub = state.commandHubs[aiPlayer]
        if not ownHub then
            return deployments
        end

        -- Get free cells around Commandant
        local freeCells = self:getFreeCellsAroundHub(state, ownHub, skipGridCheck)
        if #freeCells == ZERO then
            return deployments
        end

        -- Validate cells are actually free in current game state
        local validFreeCells = {}
        for _, cell in ipairs(freeCells) do
            local existingUnit = nil

            -- Check in state
            if self:getUnitAtPosition(state, cell.row, cell.col) then
                existingUnit = self:getUnitAtPosition(state, cell.row, cell.col)
            end

            -- Also check actual grid if available (but skip if this is a simulation check)
            if not existingUnit and self.grid and not skipGridCheck then
                existingUnit = self.grid:getUnitAt(cell.row, cell.col)
            end

            if not existingUnit then
                table.insert(validFreeCells, cell)
            else
            end
        end

        if #validFreeCells == ZERO then
            return deployments
        end

        local hubThreat = self:analyzeHubThreat(state)
        local healerEarlyDeployAllowed = self:isHealerEarlyDeployAllowed(state, aiPlayer, hubThreat)
        local adjacentRescueContext = self:getAdjacentRangedThreatContext(state, aiPlayer)

        for unitIndex = ONE, #state.supply[aiPlayer] do
            local unit = state.supply[aiPlayer][unitIndex]
            if self:unitHasTag(unit, "healer") and not healerEarlyDeployAllowed then
                goto continue_supply_unit
            end
            for _, cell in ipairs(validFreeCells) do
                local score = self:evaluateSupplyDeployment(state, unit, cell, hubThreat, {
                    unitIndex = unitIndex,
                    adjacentRangedThreatContext = adjacentRescueContext
                })

                table.insert(deployments, {
                    type = "supply_deploy",
                    unitIndex = unitIndex,
                    unitName = unit.name,
                    target = {row = cell.row, col = cell.col},
                    hub = {row = ownHub.row, col = ownHub.col},
                    score = score
                })
            end
            ::continue_supply_unit::
        end

        -- Sort deployments by score (best first)
        self:sortScoredEntries(deployments, {
            scoreField = "score",
            descending = true
        })

        return deployments
    end

    function aiClass:enter(gameRulerRef, gridRef)
        self.gameRuler = gameRulerRef
        self.grid = gridRef
    end

    function aiClass:update(dt, phaseInfoRef)

    end

    function aiClass:draw()

    end

    -- Print grid state for debugging
    function aiClass:printGridState(state) 
        local symbolByUnit = {
            Commandant = "HUB",
            Crusher = "ASS",
            Earthstalker = "HUN",
            Wingstalker = "SCO",
            Healer = "REP",
            Cloudstriker = "COR",
            Bastion = "GIG",
            Rock = "NEUT",
        }

        -- Create a visual grid representation
        local gridSize = GAME.CONSTANTS.GRID_SIZE or DEFAULT_GRID_SIZE
        local grid = {}

        -- Initialize empty grid
        for row = ONE, gridSize do
            grid[row] = {}
            for col = ONE, gridSize do
                grid[row][col] = "   .   "  -- Empty cell
            end
        end

        -- Place units on grid
        if state and state.units then
            for _, unit in ipairs(state.units) do
                if unit.row and unit.col and unit.row >= ONE and unit.row <= gridSize and unit.col >= ONE and unit.col <= gridSize then
                    local unitSymbol = ""
                    local playerColor = unit.player == ONE and "P1" or "P2"

                    -- Create unit symbol with HP
                    local unitCode = symbolByUnit[unit.name]
                    if unitCode == "NEUT" then
                        unitSymbol = unitCode .. (unit.currentHp or "?")
                    elseif unitCode then
                        unitSymbol = playerColor .. unitCode .. (unit.currentHp or "?")
                    else
                        unitSymbol = playerColor .. "UNK" .. (unit.currentHp or "?")
                    end

                    -- Pad to consistent width
                    while string.len(unitSymbol) < SEVEN do
                        unitSymbol = unitSymbol .. " "
                    end

                    grid[unit.row][unit.col] = unitSymbol
                end
            end
        end

        -- Print column headers
        local header = "    "
        for col = ONE, gridSize do
            header = header .. string.format("%7d", col)
        end

        -- Print grid with row numbers
        for row = ONE, gridSize do
            local line = string.format("%2d: ", row)
            for col = ONE, gridSize do
                line = line .. grid[row][col]
            end
        end

    end

end

return M
