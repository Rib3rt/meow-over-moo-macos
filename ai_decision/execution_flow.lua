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

    local function isAiVsAiMode()
        return GAME and GAME.CURRENT and GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI
    end

    local function buildExecScheduleOptions(ai, phase, actionIndex, nextIndex)
        return {
            allowPassiveAnimationBypass = true,
            traceTag = phase,
            traceContext = {
                player = ai and ai.factionId or "?",
                turn = (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?",
                phase = phase,
                actionIndex = actionIndex,
                nextIndex = nextIndex
            }
        }
    end

    local function emitExecChainTrace(ai, phase, actionIndex, nextIndex, seqLen, actionType)
        if not isAiVsAiMode() then
            return
        end

        logger.warn(
            "AI",
            string.format(
                "AI_EXEC_CHAIN player=%s turn=%s phase=%s actionIndex=%s next=%s seqLen=%s actionType=%s",
                tostring(ai and ai.factionId or "?"),
                tostring((GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?"),
                tostring(phase or "?"),
                tostring(actionIndex or "?"),
                tostring(nextIndex or "?"),
                tostring(seqLen or "?"),
                tostring(actionType or "unknown")
            )
        )
    end

    local earlyPlannerModule = nil
    local earlyPlannerLoadFailed = false
    local function getEarlyPlannerModule()
        if earlyPlannerModule or earlyPlannerLoadFailed then
            return earlyPlannerModule
        end
        local ok, module = pcall(require, "ai_tournament.early_planner")
        if ok then
            earlyPlannerModule = module
        else
            earlyPlannerLoadFailed = true
        end
        return earlyPlannerModule
    end

    function aiClass:evaluateSupplyDeployment(state, unit, cell, hubThreat, opts)
        local options = opts or {}
        local score = ZERO
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer then
            return score
        end
        if not state then
            return score
        end
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
                local simState = self:applySupplyDeploymentForPlayer(state, {
                    type = "supply_deploy",
                    unitIndex = unitIndex,
                    unitName = unit.name,
                    target = {row = cell.row, col = cell.col}
                }, aiPlayer)
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

    --- Applies a supply deployment action for an explicit player to a copied state and returns the new state.
    function aiClass:applySupplyDeploymentForPlayer(state, deployment, playerId, opts)
        local _ = opts -- reserved for parity with player-aware simulation signatures
        if not state or not playerId then
            return state
        end

        local newState = self:deepCopyState(state)
        local priorActionCount = state.turnActionCount or ZERO
        newState.turnActionCount = priorActionCount + ONE
        newState.firstActionRangedAttack = state.firstActionRangedAttack
        newState.hasDeployedThisTurn = true
        local aiPlayer = playerId

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

    --- Applies a supply deployment action to a copied state and returns the new state.
    function aiClass:applySupplyDeployment(state, deployment)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return state
        end
        return self:applySupplyDeploymentForPlayer(state, deployment, aiPlayer)
    end

    -- Core AI Decision Making Functions (keeping these in main file for now)
    function aiClass:executeActionsSequence(moveSequence)
        local function attackKindForUnit(unit)
            local attackRange = tonumber(unit and (unit.atkRange or unit.range))
            if not attackRange and unit and self.unitsInfo and self.unitsInfo.getUnitAttackRange then
                local ok, resolved = pcall(self.unitsInfo.getUnitAttackRange, self.unitsInfo, unit, "AI_EXEC_ATTACK_KIND")
                if ok and resolved then
                    attackRange = tonumber(resolved)
                end
            end
            if not attackRange and unit and self.unitHasTag and self:unitHasTag(unit, "ranged") then
                attackRange = TWO
            end
            if not attackRange and unit and (unit.name == "Cloudstriker" or unit.name == "Artillery") then
                attackRange = TWO
            end
            attackRange = attackRange or ONE
            if attackRange >= TWO then
                return "ranged", attackRange
            end
            return "melee", attackRange
        end

        local function isFactionAttackTarget(targetUnit)
            local targetPlayer = tonumber(targetUnit and targetUnit.player)
            local actingPlayer = tonumber(self and self.factionId)
            return targetPlayer and targetPlayer > 0 and actingPlayer and targetPlayer ~= actingPlayer
        end

        local function posToString(pos)
            if type(pos) ~= "table" then
                return "?,?"
            end
            return string.format("%s,%s", tostring(pos.row or "?"), tostring(pos.col or "?"))
        end

        local function emitRuntimeExecTrace(actionIndex, action, success, detail)
            if not (GAME and GAME.CURRENT and GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI) then
                return
            end

            local meta = detail or {}
            logger.warn(
                "AI",
                string.format(
                    "AI_EXEC player=%s turn=%s actionIndex=%d actionType=%s from=%s to=%s success=%s skipReason=%s targetPlayer=%s targetName=%s attackRange=%s attackKind=%s factionAttack=%s",
                    tostring(self.factionId or "?"),
                    tostring((GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?"),
                    tonumber(actionIndex) or 0,
                    tostring(action and action.type or "unknown"),
                    posToString(action and action.unit),
                    posToString(action and action.target),
                    tostring(success == true),
                    tostring(meta.skipReason or "none"),
                    tostring(meta.targetPlayer or "none"),
                    tostring(meta.targetName or "none"),
                    tostring(meta.attackRange or "none"),
                    tostring(meta.attackKind or "none"),
                    tostring(meta.factionAttack == true)
                )
            )
        end

        local executionTrace = {
            selectedFactionAttacks = ZERO,
            selectedMeleeFactionAttacks = ZERO,
            selectedRangedFactionAttacks = ZERO,
            executedFactionAttacks = ZERO,
            executedMeleeFactionAttacks = ZERO,
            executedRangedFactionAttacks = ZERO,
            selectedAttackExecutionFailures = ZERO,
            selectedAttackSkippedNoUnit = ZERO,
            selectedAttackSkippedIllegalAtRuntime = ZERO
        }
        self._lastExecutionTrace = executionTrace

        for _, action in ipairs(moveSequence or {}) do
            if action and action.type == "attack" and self.grid and self.grid.getUnitAt then
                local attacker = action.unit and self.grid:getUnitAt(action.unit.row, action.unit.col) or nil
                local target = action.target and self.grid:getUnitAt(action.target.row, action.target.col) or nil
                if isFactionAttackTarget(target) then
                    executionTrace.selectedFactionAttacks = executionTrace.selectedFactionAttacks + ONE
                    local kind = attackKindForUnit(attacker)
                    if kind == "ranged" then
                        executionTrace.selectedRangedFactionAttacks = executionTrace.selectedRangedFactionAttacks + ONE
                    else
                        executionTrace.selectedMeleeFactionAttacks = executionTrace.selectedMeleeFactionAttacks + ONE
                    end
                end
            end
        end

        local function flushExecutionTraceToDecision()
            if self._lastDecisionSource then
                self._lastDecisionSource.executedFactionAttacks = executionTrace.executedFactionAttacks
                self._lastDecisionSource.executedMeleeFactionAttacks = executionTrace.executedMeleeFactionAttacks
                self._lastDecisionSource.executedRangedFactionAttacks = executionTrace.executedRangedFactionAttacks
                self._lastDecisionSource.selectedAttackExecutionFailures = executionTrace.selectedAttackExecutionFailures
                self._lastDecisionSource.selectedAttackSkippedNoUnit = executionTrace.selectedAttackSkippedNoUnit
                self._lastDecisionSource.selectedAttackSkippedIllegalAtRuntime = executionTrace.selectedAttackSkippedIllegalAtRuntime
            end

            if self.lastTournamentMeta and type(self.lastTournamentMeta) == "table" then
                self.lastTournamentMeta.stats = self.lastTournamentMeta.stats or {}
                self.lastTournamentMeta.stats.executedFactionAttacks = executionTrace.executedFactionAttacks
                self.lastTournamentMeta.stats.executedMeleeFactionAttacks = executionTrace.executedMeleeFactionAttacks
                self.lastTournamentMeta.stats.executedRangedFactionAttacks = executionTrace.executedRangedFactionAttacks
                self.lastTournamentMeta.stats.selectedAttackExecutionFailures = executionTrace.selectedAttackExecutionFailures
                self.lastTournamentMeta.stats.selectedAttackSkippedNoUnit = executionTrace.selectedAttackSkippedNoUnit
                self.lastTournamentMeta.stats.selectedAttackSkippedIllegalAtRuntime = executionTrace.selectedAttackSkippedIllegalAtRuntime
            end
        end

        if not moveSequence or #moveSequence == ZERO then
            self:logDecision("Execution", "No actions to execute")
            emitRuntimeExecTrace(ONE, {type = "skip", unit = {row = ONE, col = ONE}, target = {row = ONE, col = ONE}}, true, {
                skipReason = "empty_sequence",
                targetPlayer = "none",
                targetName = "none",
                attackRange = "none",
                attackKind = "none",
                factionAttack = false
            })
            flushExecutionTraceToDecision()
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
                flushExecutionTraceToDecision()
                if self.grid then
                    aiDebugPrint(string.format("[AI] Sequence complete for faction %s – clearing highlights", tostring(self.factionId)))
                    self.grid:clearHighlightedCells()
                    self.grid:clearForcedHighlightedCells({ attackOnly = true })
                    self.grid:clearActionHighlights()
                end
                self.currentActionPreview = nil
                if self.gameRuler and self.gameRuler.performAction then
                    emitExecChainTrace(self, "sequence_end", actionIndex, "endActions", #moveSequence, "endActions")
                    self:scheduleAfterAnimations(actionsSequenceDelay, function()
                        self.gameRuler:performAction("endActions")
                    end, buildExecScheduleOptions(self, "sequence_end", actionIndex, "endActions"))
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
                emitRuntimeExecTrace(actionIndex, action, true, {
                    skipReason = "skip_action",
                    targetPlayer = "none",
                    targetName = "none",
                    attackRange = "none",
                    attackKind = "none",
                    factionAttack = false
                })
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
                    if action and action.type == "attack" then
                        executionTrace.selectedAttackExecutionFailures = executionTrace.selectedAttackExecutionFailures + ONE
                        executionTrace.selectedAttackSkippedNoUnit = executionTrace.selectedAttackSkippedNoUnit + ONE
                    end
                    emitRuntimeExecTrace(actionIndex, action, false, {
                        skipReason = "source_unit_missing",
                        targetPlayer = "none",
                        targetName = "none",
                        attackRange = "none",
                        attackKind = "none",
                        factionAttack = false
                    })
                    emitExecChainTrace(self, "source_missing_next", actionIndex, actionIndex + ONE, #moveSequence, action.type)
                    self:scheduleAfterAnimations(actionsSequenceDelay, function()
                        executeAction(actionIndex + ONE)
                    end, buildExecScheduleOptions(self, "source_missing_next", actionIndex, actionIndex + ONE))
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
                    local targetUnitBefore = nil
                    local attackKind = "none"
                    local attackRange = "none"
                    local factionAttack = false
                    if action.type == "attack" then
                        targetUnitBefore = self.grid and action.target and self.grid:getUnitAt(action.target.row, action.target.col) or nil
                        local kind, range = attackKindForUnit(unitAtPosition)
                        attackKind = kind
                        attackRange = range
                        factionAttack = isFactionAttackTarget(targetUnitBefore)
                    end

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
                    elseif action.type == "attack" then
                        if factionAttack and result then
                            executionTrace.executedFactionAttacks = executionTrace.executedFactionAttacks + ONE
                            if attackKind == "ranged" then
                                executionTrace.executedRangedFactionAttacks = executionTrace.executedRangedFactionAttacks + ONE
                            else
                                executionTrace.executedMeleeFactionAttacks = executionTrace.executedMeleeFactionAttacks + ONE
                            end
                        elseif factionAttack and not result then
                            executionTrace.selectedAttackExecutionFailures = executionTrace.selectedAttackExecutionFailures + ONE
                            executionTrace.selectedAttackSkippedIllegalAtRuntime = executionTrace.selectedAttackSkippedIllegalAtRuntime + ONE
                        end
                    end

                    emitRuntimeExecTrace(actionIndex, action, result == true, {
                        skipReason = (result == true) and "none" or "runtime_rejected",
                        targetPlayer = targetUnitBefore and targetUnitBefore.player or "none",
                        targetName = targetUnitBefore and targetUnitBefore.name or "none",
                        attackRange = attackRange,
                        attackKind = attackKind,
                        factionAttack = factionAttack
                    })

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

                    emitExecChainTrace(self, "post_action_next", actionIndex, actionIndex + ONE, #moveSequence, action.type)
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
                    end, buildExecScheduleOptions(self, "post_action_next", actionIndex, actionIndex + ONE))
                end)
            else
        -- Unknown action type: skip to next action
                emitRuntimeExecTrace(actionIndex, action, false, {
                    skipReason = "unknown_action_type",
                    targetPlayer = "none",
                    targetName = "none",
                    attackRange = "none",
                    attackKind = "none",
                    factionAttack = false
                })
                emitExecChainTrace(self, "unknown_action_next", actionIndex, actionIndex + ONE, #moveSequence, action and action.type)
                self:scheduleAfterAnimations(actionsSequenceDelay, function()
                    executeAction(actionIndex + ONE)
                end, buildExecScheduleOptions(self, "unknown_action_next", actionIndex, actionIndex + ONE))
            end
        end

        executeAction(ONE)
    end

    function aiClass:handleSupplyDeployment(action, actionsSequenceDelay, executeAction, actionIndex)
        local function emitSupplyTrace(success, skipReason)
            if not (GAME and GAME.CURRENT and GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI) then
                return
            end
            local fromPos = action and (action.hub or action.unit) or {row = "?", col = "?"}
            local toPos = action and action.target or {row = "?", col = "?"}
            logger.warn(
                "AI",
                string.format(
                    "AI_EXEC player=%s turn=%s actionIndex=%d actionType=supply_deploy from=%s,%s to=%s,%s success=%s skipReason=%s targetPlayer=none targetName=none attackRange=none attackKind=none factionAttack=false",
                    tostring(self.factionId or "?"),
                    tostring((GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?"),
                    tonumber(actionIndex) or 0,
                    tostring(fromPos.row or "?"),
                    tostring(fromPos.col or "?"),
                    tostring(toPos.row or "?"),
                    tostring(toPos.col or "?"),
                    tostring(success == true),
                    tostring(skipReason or "none")
                )
            )
        end

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
                emitSupplyTrace(false, "target_occupied")
                if self.grid then
                    self.grid:clearHighlightedCells()
                    self.grid:clearForcedHighlightedCells()
                    self.grid:clearActionHighlights()
                end
                emitExecChainTrace(self, "supply_target_occupied_next", actionIndex, actionIndex + ONE, "?", "supply_deploy")
                self.gameRuler:scheduleAction(actionsSequenceDelay, function()
                    executeAction(actionIndex + ONE)
                end)
                return
            end

            -- Validate supply index
            local currentSupply = self.factionId == ONE and self.gameRuler.player1Supply or self.gameRuler.player2Supply
            if not currentSupply or action.unitIndex > #currentSupply then
                -- Skip this action and continue with the sequence
                emitSupplyTrace(false, "invalid_supply_index")
                if self.grid then
                    self.grid:clearHighlightedCells()
                    self.grid:clearForcedHighlightedCells()
                    self.grid:clearActionHighlights()
                end
                emitExecChainTrace(self, "supply_invalid_index_next", actionIndex, actionIndex + ONE, "?", "supply_deploy")
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
                    emitSupplyTrace(false, "not_adjacent_to_hub")
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
                emitSupplyTrace(true, "none")
            else
                local alternativeDeployment = self:findAlternativeDeploymentPosition(action)
                if alternativeDeployment and self.gameRuler.deploySupplyUnit then
                    success = self.gameRuler:deploySupplyUnit(alternativeDeployment.unitIndex, alternativeDeployment.target.row, alternativeDeployment.target.col)
                    if success then
                        self.hasDeployedThisTurn = true
                        self.globalDeploymentTracking = true
                        emitSupplyTrace(true, "none")
                    end
                else
                end
            end
            if not success then
                emitSupplyTrace(false, "deploy_failed")
            end

            if self.grid then
                self.grid:clearHighlightedCells()
                self.grid:clearForcedHighlightedCells()
                self.grid:clearActionHighlights()
            end

            emitExecChainTrace(self, "supply_next", actionIndex, actionIndex + ONE, "?", "supply_deploy")
            self:scheduleAfterAnimations(actionsSequenceDelay, function()
                executeAction(actionIndex + ONE)
            end, buildExecScheduleOptions(self, "supply_next", actionIndex, actionIndex + ONE))
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
            local availableCells = self.gameRuler.initialDeployment.availableCells
            local earlySetupSelection = nil
            local tournamentCfg = self.getTournamentConfig and self:getTournamentConfig() or {}
            local earlyPlanner = tournamentCfg.EARLY_SETUP_DEPLOY_ENABLED ~= false and getEarlyPlannerModule() or nil
            if earlyPlanner and earlyPlanner.selectInitialDeployment and availableCells and #availableCells > ZERO then
                openingState.currentTurn = openingState.currentTurn or (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or ONE
                openingState.turnNumber = openingState.turnNumber or openingState.currentTurn
                openingState.phase = openingState.phase or "setup"
                openingState.supply = openingState.supply or {}
                openingState.supply[self.factionId] = openingState.supply[self.factionId] or supply
                openingState.commandHubs = openingState.commandHubs or {}
                openingState.commandHubs[self.factionId] = openingState.commandHubs[self.factionId] or {
                    row = hubPos.row,
                    col = hubPos.col
                }
                local enemyPlayer = self.getOpponentPlayer and self:getOpponentPlayer(self.factionId) or (PLAYER_INDEX_SUM - self.factionId)
                local enemySupply = openingState.supply and openingState.supply[enemyPlayer] or nil
                local setupCtx = {
                    aiPlayer = self.factionId,
                    enemyPlayer = enemyPlayer,
                    cfg = tournamentCfg,
                    selfAI = self,
                    setupInitialDeployment = true,
                    supply = {
                        own = {count = #supply},
                        enemy = {count = enemySupply and #enemySupply or ONE}
                    }
                }
                earlySetupSelection = earlyPlanner.selectInitialDeployment(
                    self,
                    openingState,
                    setupCtx,
                    supply,
                    availableCells,
                    hubPos
                )
            end

            -- Select unit using Tournament early intent first, then adaptive opening guardrails.
            local selectedUnitIndex = earlySetupSelection and earlySetupSelection.unitIndex or self:getPreferredSupplyUnitIndex(supply, {
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

            -- Choose deployment position from Tournament early intent first, then baseline center-adjacent rule.
            local selectedCell = earlySetupSelection and earlySetupSelection.cellIndex or nil
            local centerRow = math.floor(GAME.CONSTANTS.GRID_SIZE / TWO)
            local centerCol = math.floor(GAME.CONSTANTS.GRID_SIZE / TWO)
            local bestCenterDist = math.huge
            local bestHubDist = math.huge
            if not selectedCell then
                for i, cell in ipairs(availableCells) do
                    local centerDist = math.abs(cell.row - centerRow) + math.abs(cell.col - centerCol)
                    local hubDist = math.abs(cell.row - hubPos.row) + math.abs(cell.col - hubPos.col)
                    if centerDist < bestCenterDist or (centerDist == bestCenterDist and hubDist < bestHubDist) then
                        bestCenterDist = centerDist
                        bestHubDist = hubDist
                        selectedCell = i
                    end
                end
            end
            selectedCell = selectedCell or randomGen.randomInt(ONE, #availableCells)

            if GAME.CURRENT.MODE == GAME.MODE.AI_VS_AI then
                local plan = earlySetupSelection and earlySetupSelection.plan or nil
                local details = earlySetupSelection and earlySetupSelection.details or nil
                local tournamentConfig = (self.getTournamentConfig and self:getTournamentConfig()) or {}
                local runtimeTag = tournamentConfig.RUNTIME_TAG or "unknown"
                logger.warn(
                    "AI",
                    string.format(
                        "AI_INITIAL_DEPLOY player=%s turn=%s profile=%s early=%s/%s lane=%s selected=%s@%d,%d unitIndex=%s earlyScore=%d reasons=%s rt=%s",
                        tostring(self.factionId or "?"),
                        tostring((GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?"),
                        tostring(profileLabel or "unknown"),
                        tostring(plan and plan.role or "none"),
                        tostring(plan and plan.intent or "none"),
                        tostring(plan and plan.focalLane or "none"),
                        tostring(supply[selectedUnitIndex] and supply[selectedUnitIndex].name or "unknown"),
                        tonumber(availableCells[selectedCell] and availableCells[selectedCell].row) or ZERO,
                        tonumber(availableCells[selectedCell] and availableCells[selectedCell].col) or ZERO,
                        tostring(selectedUnitIndex),
                        math.floor(tonumber(earlySetupSelection and earlySetupSelection.score) or ZERO),
                        table.concat((details and details.reasons) or {}, ","),
                        tostring(runtimeTag)
                    )
                )
            end

            local success = self.gameRuler:performAction("deployUnitNearHub", {
                row = availableCells[selectedCell].row,
                col = availableCells[selectedCell].col,
                unitIndex = selectedUnitIndex
            })
            if success then
                self.gameRuler:currentPlayerStartingUnitsAllDeployed()
            end
        end
    end

    -- Core AI logic functions with 2-phase approach
    function aiClass:getBestSequence(state, opts)
        local decisionOptions = opts or {}
        self._decisionGuardContext = nil
        self._referenceResolutionState = state
        self:getEffectiveAiReference(state, {
            lock = true,
            context = "decision_cycle",
            logSwitch = true
        })
        local decisionStartTime = (love and love.timer and love.timer.getTime and love.timer.getTime()) or nil
        local budgetMs = valueOr(PERFORMANCE_RULE_CONTRACT.DECISION_BUDGET_MS, 500)
        local function getElapsedMs()
            if decisionOptions.budgetElapsedMs then
                return decisionOptions.budgetElapsedMs()
            end
            if decisionStartTime and love and love.timer and love.timer.getTime then
                return (love.timer.getTime() - decisionStartTime) * 1000
            end
            return ZERO
        end

        local function copyReasonCounts(reasonCounts)
            local copy = {}
            for key, value in pairs(reasonCounts or {}) do
                copy[key] = value
            end
            return copy
        end

        local function copyNumericMap(source)
            local copy = {}
            for key, value in pairs(source or {}) do
                copy[key] = tonumber(value) or ZERO
            end
            return copy
        end

        local function formatReasonCounts(reasonCounts)
            local parts = {}
            for key, value in pairs(reasonCounts or {}) do
                parts[#parts + ONE] = tostring(key) .. ":" .. tostring(value)
            end
            table.sort(parts)
            if #parts == ZERO then
                return "none"
            end
            return table.concat(parts, ",")
        end

        local function formatValueList(values)
            local parts = {}
            for _, value in ipairs(values or {}) do
                parts[#parts + ONE] = tostring(value)
            end
            if #parts == ZERO then
                for key, value in pairs(values or {}) do
                    if type(key) == "number" then
                        parts[#parts + ONE] = tostring(value)
                    else
                        parts[#parts + ONE] = tostring(key) .. ":" .. tostring(value)
                    end
                end
            end
            table.sort(parts)
            if #parts == ZERO then
                return "none"
            end
            return table.concat(parts, "+")
        end

        local function formatStageMs(stageMs)
            local order = {
                "context_supply",
                "context_phase",
                "context_early_plan",
                "draw_urgency",
                "legal_attack_count",
                "legal_move_attack_count",
                "immediate_win",
                "contract_detect",
                "early_position_map",
                "pipeline_v2_deploy_first",
                "pipeline_v2_move_position",
                "pipeline_v2_enumeration",
                "pipeline_v2_full_turn",
                "pipeline_v2_gate",
                "pipeline_v2_reply",
                "kernel",
                "defense_lane",
                "combat_lane",
                "required_rank",
                "enumeration",
                "optional_rank",
                "finalists",
                "reply",
                "extension",
                "post_select_prepare",
                "hard_lock_detect",
                "hard_sanitize",
                "sanitize_select",
                "sanitize_recovery",
                "early_gate_initial",
                "early_gate_repair",
                "early_gate_recheck",
                "early_commit_gate",
                "early_commit_repair",
                "early_commit_recheck",
                "defense_override",
                "post_strip_completion",
                "early_gate_final",
                "early_gate_final_repair",
                "early_gate_final_recheck",
                "final_post_strip_completion",
                "post_completion_gate",
                "post_completion_repair",
                "post_completion_recheck",
                "zero_damage_guard",
                "return_gate",
                "return_gate_repair",
                "return_gate_recheck",
                "selected_diagnostics",
                "selected_contract",
                "early_diag_audit"
            }
            local parts = {}
            local seen = {}
            for _, name in ipairs(order) do
                local value = tonumber(stageMs and stageMs[name])
                if value and value > ZERO then
                    parts[#parts + ONE] = string.format("%s:%.1f", name, value)
                    seen[name] = true
                end
            end
            for name, value in pairs(stageMs or {}) do
                if not seen[name] and (tonumber(value) or ZERO) > ZERO then
                    parts[#parts + ONE] = string.format("%s:%.1f", tostring(name), tonumber(value) or ZERO)
                end
            end
            if #parts == ZERO then
                return "none"
            end
            return table.concat(parts, ",")
        end

        local function formatPrimaryTournament(snapshot)
            if not (snapshot and snapshot.primaryTournamentCaptured == true) then
                return "none"
            end
            return string.format(
                "%s/%s/%s/%.0f/%.0f/%.0f",
                tostring(snapshot.primaryTournamentReason or "none"),
                tostring(snapshot.primaryCoreExit or "none"),
                tostring(snapshot.primaryFallbackSource or "none"),
                tonumber(snapshot.primaryOwnCandidates) or ZERO,
                tonumber(snapshot.primaryRankedCandidates) or ZERO,
                tonumber(snapshot.primaryFinalists) or ZERO
            )
        end

        local function scoreTotal(value)
            if type(value) == "table" then
                return tonumber(value.total) or ZERO
            end
            return tonumber(value) or ZERO
        end

        local decisionSnapshot = {
            tournamentAttempted = false,
            tournamentAccepted = false,
            decisionSource = "tournament",
            tournamentPhase = nil,
            tournamentPhaseTurn = nil,
            tournamentPhaseReason = nil,
            tournamentPhaseEarlyMax = nil,
            tournamentPhaseEarlyReference = nil,
            earlyPlanActive = false,
            earlyRole = nil,
            earlyIntent = nil,
            earlyConfidence = ZERO,
            earlyFocalLane = nil,
            earlySupportLane = nil,
            earlyFormationScore = ZERO,
            earlyFormationReasons = {},
            tacticalOverrideReason = nil,
            mandatoryCompletionSkippedByBudget = ZERO,
            mandatoryFullTurnRepair = ZERO,
            mandatoryFullTurnRepairReason = nil,
            mandatoryFullTurnRepairReplacement = nil,
            earlyAttackCommitmentReason = nil,
            earlyAttackCommitmentRejected = false,
            earlyAttackCommitmentReplacement = nil,
            earlyAttackCommitmentMaterialGain = ZERO,
            earlyAttackCommitmentBoardDelta = ZERO,
            earlyDiagnosticsEnabled = false,
            earlyDiagSource = nil,
            earlyDiagFirstRankMode = nil,
            earlyDiagFirstLegalActions = ZERO,
            earlyDiagFirstBeamSelected = ZERO,
            earlyDiagFirstBeamCap = ZERO,
            earlyDiagSecondBeamCap = ZERO,
            earlyDiagCandidateCap = ZERO,
            earlyDiagSecondStates = ZERO,
            earlyDiagSecondLegalActionsTotal = ZERO,
            earlyDiagSecondLegalActionsMax = ZERO,
            earlyDiagSecondBeamSelectedTotal = ZERO,
            earlyDiagSecondBeamSelectedMax = ZERO,
            earlyDiagFullCandidatesGeneratedBeforeFallback = ZERO,
            earlyDiagFullCandidatesReturned = ZERO,
            earlyDiagNormalRankedBeforeGate = ZERO,
            earlyDiagNormalGateKept = ZERO,
            earlyDiagAuditEnabled = false,
            earlyDiagAuditCandidates = ZERO,
            earlyDiagAuditRanked = ZERO,
            earlyDiagAuditGateOriginal = ZERO,
            earlyDiagAuditGateKept = ZERO,
            earlyDiagAuditGateRejected = ZERO,
            earlyDiagAuditGateStoppedByBudget = false,
            earlyDiagAuditFoundGateKept = false,
            earlyDiagAuditGateKeptOutsideNormal = ZERO,
            earlyDiagAuditFirstReason = nil,
            earlyDiagAuditReasonCounts = {},
            earlyDiagAuditMs = ZERO,
            earlyDiagAuditError = nil,
            earlyProductiveEnumerationEnabled = false,
            earlyProductiveFirstPrepared = ZERO,
            earlyProductiveFirstShortlisted = ZERO,
            earlyProductiveFirstSelected = ZERO,
            pipelineV2MidEnabled = false,
            pipelineV2MidAttempted = false,
            pipelineV2MidSkipped = false,
            pipelineV2MidSkippedReason = nil,
            pipelineV2MidFailedReason = nil,
            pipelineV2MidFellThroughToTournament = false,
            pipelineV2MidCandidates = ZERO,
            pipelineV2MidAttackCandidates = ZERO,
            pipelineV2MidPositionCandidates = ZERO,
            pipelineV2MidFinalists = ZERO,
            midPositionMapEnabled = false,
            midPositionMapCellCount = ZERO,
            midPositionMapTopCells = {},
            midPositionMapContestedTop = {},
            midPositionMapPressureTop = {},
            midPositionMapTradeTop = {},
            midPositionMapAttackTargets = {},
            midPositionMapPositionTop = {},
            midPositionMapStatusCounts = {},
            midPersonalityName = nil,
            midPersonalityReference = nil,
            midPersonalityLabel = nil,
            midPersonalityTop = {},
            midPersonalityAttackTargets = {},
            midPersonalityPositionTargets = {},
            midPersonalityContestedTargets = {},
            midPersonalityTradeTargets = {},
            selectedContract = nil,
            activeContracts = {},
            tournamentReason = nil,
            fallbackReason = nil,
            sanitizerReplacements = ZERO,
            sanitizerReasonCounts = {},
            runtimeSanitizerRejected = false,
            runtimeSanitizerRejectReason = nil,
            runtimeSanitizerRejectReplacements = ZERO,
            runtimeSanitizerRejectReasonCounts = {},
            rawSequenceSignature = "",
            ownCandidates = ZERO,
            rankedCandidates = ZERO,
            finalists = ZERO,
            evaluatedCandidates = ZERO,
            bestSoFarAvailable = false,
            bestSoFarSource = nil,
            bestSoFarSignature = nil,
            coreExit = nil,
            fallbackSource = nil,
            primaryTournamentCaptured = false,
            primaryTournamentReason = nil,
            primaryFallbackReason = nil,
            primaryCoreExit = nil,
            primaryFallbackSource = nil,
            primaryOwnCandidates = ZERO,
            primaryRankedCandidates = ZERO,
            primaryFinalists = ZERO,
            primaryEvaluatedCandidates = ZERO,
            primaryTimeout = false,
            cooperativeYields = ZERO,
            cacheHits = ZERO,
            cacheMisses = ZERO,
            cacheSimulationHits = ZERO,
            cacheSimulationMisses = ZERO,
            cacheFeatureHits = ZERO,
            cacheFeatureMisses = ZERO,
            cacheLegalHits = ZERO,
            cacheLegalMisses = ZERO,
            cacheThreatHits = ZERO,
            cacheThreatMisses = ZERO,
            cacheSupplyHits = ZERO,
            cacheSupplyMisses = ZERO,
            cacheExtensionHits = ZERO,
            cacheExtensionMisses = ZERO,
            replies = ZERO,
            extensions = ZERO,
            replySkippedByBudget = ZERO,
            enemyReplyBatches = ZERO,
            enemyReplyCandidatesGenerated = ZERO,
            enemyReplyCandidatesGeneratedMax = ZERO,
            enemyReplyCandidatesSelected = ZERO,
            enemyReplyScoredForSort = ZERO,
            enemyReplyScoredWorst = ZERO,
            enemyReplySortStoppedByBudget = ZERO,
            enemyReplyWorstStoppedByBudget = ZERO,
            enemyReplyFirstActionPoolTotal = ZERO,
            enemyReplyFirstActionPoolMax = ZERO,
            enemyReplySecondActionStates = ZERO,
            enemyReplySecondActionPoolTotal = ZERO,
            enemyReplySecondActionPoolMax = ZERO,
            enemyReplyCacheHits = ZERO,
            enemyReplyCacheMisses = ZERO,
            enemyReplyDeployCandidates = ZERO,
            enemyDeployReplies = ZERO,
            enemyReplyTacticalExtensionChecks = ZERO,
            enemyReplyTacticalExtensionUsed = ZERO,
            replyOwnUnitKills = ZERO,
            replyOwnUnitKillValue = ZERO,
            replyFreeUnitLossGuardHits = ZERO,
            replyFreeUnitLossGuardPenalty = ZERO,
            replyFreeUnitLossGuardMaxPenalty = ZERO,
            replyQuestionCounts = {},
            replyOutcomeCounts = {},
            replyUsefulEvaluations = ZERO,
            replyNoScoreEvaluations = ZERO,
            replyCheapSafetyEvaluations = ZERO,
            extensionQuestionCounts = {},
            extensionOutcomeCounts = {},
            extensionSkippedByBudget = ZERO,
            stageMs = {},
            timeout = false,
            legalAttackActions = ZERO,
            legalMoveAttackActions = ZERO,
            defenseKind = nil,
            directThreatAttackActions = ZERO,
            directThreatReductionActions = ZERO,
            moveThreatAttackActions = ZERO,
            ownCommandantProjectedThreatDamage = ZERO,
            candidateWithFactionAttack = ZERO,
            rankedWithFactionAttack = ZERO,
            finalistWithFactionAttack = ZERO,
            rankedSourceCountsBeforeGate = {},
            rankedSourceCountsAfterGate = {},
            finalistSourceCounts = {},
            selectedHasFactionAttack = false,
            selectedPassiveOnly = false,
            selectedFactionAttackCount = ZERO,
            selectedMeleeFactionAttackCount = ZERO,
            selectedRangedFactionAttackCount = ZERO,
            selectedCombatClass = nil,
            selectedCombatSafetyReason = nil,
            bestFactionAttackFastScore = ZERO,
            selectedFastScore = ZERO,
            selectedFinalScore = ZERO,
            selectedScoreDelta = ZERO,
            selectedCandidateSource = nil,
            selectedCandidateLane = nil,
            selectedRequiredLane = false,
            selectedEarlyPositionReason = nil,
            selectedEarlyPositionTarget = nil,
            selectedContainsDeploy = false,
            selectedContainsAttack = false,
            selectedReplyQuestion = nil,
            selectedReplyOutcome = nil,
            selectedExtensionQuestion = nil,
            selectedExtensionOutcome = nil,
            selectedMatchesBestSoFar = false,
            preSanitizeSelectedStage = nil,
            preSanitizeSelectedSignature = nil,
            preSanitizeCandidateSource = nil,
            preSanitizeCandidateLane = nil,
            preSanitizeRequiredLane = false,
            preSanitizeEarlyPositionReason = nil,
            preSanitizeEarlyPositionTarget = nil,
            preSanitizeContainsDeploy = false,
            preSanitizeContainsAttack = false,
            preSanitizeFastScore = ZERO,
            preSanitizeFinalScore = ZERO,
            preSanitizeScoreDelta = ZERO,
            preSanitizeReplyQuestion = nil,
            preSanitizeReplyOutcome = nil,
            preSanitizeExtensionQuestion = nil,
            preSanitizeExtensionOutcome = nil,
            preSanitizeMatchesBestSoFar = false,
            attackLossReason = nil,
            safeCombatAvailable = false,
            bestSafeCombatClass = nil,
            bestSafeCombatSignature = nil,
            bestSafeCombatDamage = ZERO,
            bestSafeCombatKills = ZERO,
            bestSafeCombatTargetValue = ZERO,
            drawStreak = ZERO,
            drawUrgencyActive = false,
            drawUrgency = ZERO,
            drawConversionOpportunity = false,
            drawConversionChosen = false,
            drawConversionMissReason = nil,
            kernelAvailable = false,
            kernelReason = nil,
            kernelSource = nil,
            combatContractActive = false,
            combatDirectGenerated = ZERO,
            combatMoveAttackGenerated = ZERO,
            combatRanked = ZERO,
            combatFinalists = ZERO,
            combatSelected = ZERO,
            combatSkippedWithProof = ZERO,
            combatSkippedWithoutProof = ZERO,
            conversionContractActive = false,
            conversionContracts = {},
            conversionMaterialDiff = ZERO,
            conversionOwnUnits = ZERO,
            conversionEnemyUnits = ZERO,
            conversionOwnHubHp = ZERO,
            conversionEnemyHubHp = ZERO,
            conversionCommandantPressure = ZERO,
            selectedCommandantDamage = ZERO,
            selectedKillCount = ZERO,
            selectedCreatesNextTurnCommandantLethal = false,
            selectedRemovesEnemyLastAttacker = false,
            passiveOverrideReason = nil,
            selectedProofReason = nil,
            passiveOverrideAllowed = false,
            hardSelectionLocked = false,
            hardSelectionRejected = false,
            hardSelectionReason = nil,
            hardSelectionSignature = nil,
            hardSelectionPrefixCompleted = false,
            hardSelectionPrefixSignature = nil,
            hardSelectionCompletedSignature = nil,
            hardSelectionRejectReason = nil,
            hardSelectionRejectStage = nil,
            hardSelectionRejectSignature = nil,
            hardSelectionRejectSanitizerReplacements = ZERO,
            hardSelectionRejectSanitizerReasonCounts = {},
            hardSelectionFallbackPath = nil,
            runtimeSanitizerRejectRawSignature = nil,
            runtimeSanitizerRejectSanitizedSignature = nil,
            sequenceSignature = "",
            tournamentComputeMs = nil,
            elapsedMs = ZERO
        }

        local function captureHardSelectionReject(reason, stage, signature, sanitizeSummary)
            decisionSnapshot.hardSelectionRejected = true
            decisionSnapshot.hardSelectionRejectReason = tostring(
                reason
                    or decisionSnapshot.hardSelectionRejectReason
                    or decisionSnapshot.fallbackReason
                    or "hard_selection_rejected"
            )
            decisionSnapshot.hardSelectionRejectStage = tostring(
                stage
                    or decisionSnapshot.hardSelectionRejectStage
                    or "unknown"
            )
            decisionSnapshot.hardSelectionRejectSignature = tostring(
                signature
                    or decisionSnapshot.hardSelectionRejectSignature
                    or decisionSnapshot.rawSequenceSignature
                    or decisionSnapshot.hardSelectionSignature
                    or ""
            )
            decisionSnapshot.hardSelectionRejectSanitizerReplacements =
                tonumber(sanitizeSummary and sanitizeSummary.replacements)
                    or tonumber(decisionSnapshot.hardSelectionRejectSanitizerReplacements)
                    or ZERO
            decisionSnapshot.hardSelectionRejectSanitizerReasonCounts = copyReasonCounts(
                sanitizeSummary and sanitizeSummary.reasonCounts
                    or decisionSnapshot.hardSelectionRejectSanitizerReasonCounts
                    or decisionSnapshot.sanitizerReasonCounts
                    or {}
            )
        end

        local function snapshotHardSelectionReject()
            if decisionSnapshot.hardSelectionRejected ~= true then
                return nil
            end
            return {
                hardSelectionRejected = true,
                hardSelectionLocked = decisionSnapshot.hardSelectionLocked == true,
                hardSelectionReason = decisionSnapshot.hardSelectionReason,
                hardSelectionSignature = decisionSnapshot.hardSelectionSignature,
                hardSelectionPrefixCompleted = decisionSnapshot.hardSelectionPrefixCompleted == true,
                hardSelectionPrefixSignature = decisionSnapshot.hardSelectionPrefixSignature,
                hardSelectionCompletedSignature = decisionSnapshot.hardSelectionCompletedSignature,
                hardSelectionRejectReason = decisionSnapshot.hardSelectionRejectReason,
                hardSelectionRejectStage = decisionSnapshot.hardSelectionRejectStage,
                hardSelectionRejectSignature = decisionSnapshot.hardSelectionRejectSignature,
                hardSelectionRejectSanitizerReplacements =
                    tonumber(decisionSnapshot.hardSelectionRejectSanitizerReplacements) or ZERO,
                hardSelectionRejectSanitizerReasonCounts =
                    copyReasonCounts(decisionSnapshot.hardSelectionRejectSanitizerReasonCounts)
            }
        end

        local function restoreHardSelectionReject(snapshot)
            if not snapshot or snapshot.hardSelectionRejected ~= true then
                return
            end
            decisionSnapshot.hardSelectionRejected = true
            decisionSnapshot.hardSelectionLocked =
                decisionSnapshot.hardSelectionLocked == true or snapshot.hardSelectionLocked == true
            decisionSnapshot.hardSelectionReason =
                decisionSnapshot.hardSelectionReason or snapshot.hardSelectionReason
            decisionSnapshot.hardSelectionSignature =
                decisionSnapshot.hardSelectionSignature or snapshot.hardSelectionSignature
            decisionSnapshot.hardSelectionPrefixCompleted =
                decisionSnapshot.hardSelectionPrefixCompleted == true
                    or snapshot.hardSelectionPrefixCompleted == true
            decisionSnapshot.hardSelectionPrefixSignature =
                decisionSnapshot.hardSelectionPrefixSignature or snapshot.hardSelectionPrefixSignature
            decisionSnapshot.hardSelectionCompletedSignature =
                decisionSnapshot.hardSelectionCompletedSignature or snapshot.hardSelectionCompletedSignature
            decisionSnapshot.hardSelectionRejectReason =
                decisionSnapshot.hardSelectionRejectReason or snapshot.hardSelectionRejectReason
            decisionSnapshot.hardSelectionRejectStage =
                decisionSnapshot.hardSelectionRejectStage or snapshot.hardSelectionRejectStage
            decisionSnapshot.hardSelectionRejectSignature =
                decisionSnapshot.hardSelectionRejectSignature or snapshot.hardSelectionRejectSignature
            decisionSnapshot.hardSelectionRejectSanitizerReplacements =
                (tonumber(decisionSnapshot.hardSelectionRejectSanitizerReplacements) or ZERO) > ZERO
                    and (tonumber(decisionSnapshot.hardSelectionRejectSanitizerReplacements) or ZERO)
                    or (tonumber(snapshot.hardSelectionRejectSanitizerReplacements) or ZERO)
            if not decisionSnapshot.hardSelectionRejectSanitizerReasonCounts
                or not next(decisionSnapshot.hardSelectionRejectSanitizerReasonCounts) then
                decisionSnapshot.hardSelectionRejectSanitizerReasonCounts =
                    copyReasonCounts(snapshot.hardSelectionRejectSanitizerReasonCounts)
            end
        end

        local function snapshotRuntimeSanitizerReject()
            if decisionSnapshot.runtimeSanitizerRejected ~= true then
                return nil
            end
            return {
                runtimeSanitizerRejected = true,
                runtimeSanitizerRejectReason = decisionSnapshot.runtimeSanitizerRejectReason,
                runtimeSanitizerRejectReplacements =
                    tonumber(decisionSnapshot.runtimeSanitizerRejectReplacements) or ZERO,
                runtimeSanitizerRejectReasonCounts =
                    copyReasonCounts(decisionSnapshot.runtimeSanitizerRejectReasonCounts),
                runtimeSanitizerRejectRawSignature =
                    decisionSnapshot.runtimeSanitizerRejectRawSignature,
                runtimeSanitizerRejectSanitizedSignature =
                    decisionSnapshot.runtimeSanitizerRejectSanitizedSignature
            }
        end

        local function restoreRuntimeSanitizerReject(snapshot)
            if not snapshot or snapshot.runtimeSanitizerRejected ~= true then
                return
            end
            decisionSnapshot.runtimeSanitizerRejected = true
            decisionSnapshot.runtimeSanitizerRejectReason =
                decisionSnapshot.runtimeSanitizerRejectReason or snapshot.runtimeSanitizerRejectReason
            decisionSnapshot.runtimeSanitizerRejectReplacements =
                (tonumber(decisionSnapshot.runtimeSanitizerRejectReplacements) or ZERO) > ZERO
                    and (tonumber(decisionSnapshot.runtimeSanitizerRejectReplacements) or ZERO)
                    or (tonumber(snapshot.runtimeSanitizerRejectReplacements) or ZERO)
            if not decisionSnapshot.runtimeSanitizerRejectReasonCounts
                or not next(decisionSnapshot.runtimeSanitizerRejectReasonCounts) then
                decisionSnapshot.runtimeSanitizerRejectReasonCounts =
                    copyReasonCounts(snapshot.runtimeSanitizerRejectReasonCounts)
            end
            decisionSnapshot.runtimeSanitizerRejectRawSignature =
                decisionSnapshot.runtimeSanitizerRejectRawSignature
                    or snapshot.runtimeSanitizerRejectRawSignature
            decisionSnapshot.runtimeSanitizerRejectSanitizedSignature =
                decisionSnapshot.runtimeSanitizerRejectSanitizedSignature
                    or snapshot.runtimeSanitizerRejectSanitizedSignature
        end

        local function hydrateDecisionSnapshotFromTournamentMeta(meta)
            local stats = meta and meta.stats or {}
            local evidence = meta and meta.contractEvidence or {}
            local inferredCoreExit = stats.coreExit
            if not inferredCoreExit then
                local reason = tostring(meta and meta.reason or "")
                if reason == "immediate_win" then
                    inferredCoreExit = "hard_contract"
                elseif meta and meta.fallbackReason then
                    inferredCoreExit = stats.timeout == true and "timeout_no_best" or "no_core_selection"
                elseif reason == "selected" then
                    inferredCoreExit = stats.timeout == true and "timeout_with_best" or "completed"
                end
            end
            inferredCoreExit = inferredCoreExit or "not_reported"
            local inferredFallbackSource = stats.fallbackSource
            if not inferredFallbackSource then
                if inferredCoreExit == "timeout_with_best" or inferredCoreExit == "budget_guard_with_best" then
                    inferredFallbackSource = "core_best"
                elseif meta and meta.fallbackReason then
                    inferredFallbackSource = "technical_fallback"
                else
                    inferredFallbackSource = "none"
                end
            end
            decisionSnapshot.ownCandidates = tonumber(stats.ownCandidates) or ZERO
            decisionSnapshot.rankedCandidates = tonumber(stats.ranked) or ZERO
            decisionSnapshot.finalists = tonumber(stats.finalists) or ZERO
            decisionSnapshot.evaluatedCandidates = tonumber(stats.evaluatedCandidates) or ZERO
            decisionSnapshot.bestSoFarAvailable = stats.bestSoFarAvailable == true
            decisionSnapshot.bestSoFarSource = stats.bestSoFarSource
            decisionSnapshot.bestSoFarSignature = stats.bestSoFarSignature
            decisionSnapshot.coreExit = inferredCoreExit
            decisionSnapshot.fallbackSource = inferredFallbackSource
            decisionSnapshot.cooperativeYields = tonumber(stats.cooperativeYields) or ZERO
            decisionSnapshot.cacheHits = tonumber(stats.cacheHits) or ZERO
            decisionSnapshot.cacheMisses = tonumber(stats.cacheMisses) or ZERO
            decisionSnapshot.cacheSimulationHits = tonumber(stats.cacheSimulationHits) or ZERO
            decisionSnapshot.cacheSimulationMisses = tonumber(stats.cacheSimulationMisses) or ZERO
            decisionSnapshot.cacheFeatureHits = tonumber(stats.cacheFeatureHits) or ZERO
            decisionSnapshot.cacheFeatureMisses = tonumber(stats.cacheFeatureMisses) or ZERO
            decisionSnapshot.cacheLegalHits = tonumber(stats.cacheLegalHits) or ZERO
            decisionSnapshot.cacheLegalMisses = tonumber(stats.cacheLegalMisses) or ZERO
            decisionSnapshot.cacheThreatHits = tonumber(stats.cacheThreatHits) or ZERO
            decisionSnapshot.cacheThreatMisses = tonumber(stats.cacheThreatMisses) or ZERO
            decisionSnapshot.cacheSupplyHits = tonumber(stats.cacheSupplyHits) or ZERO
            decisionSnapshot.cacheSupplyMisses = tonumber(stats.cacheSupplyMisses) or ZERO
            decisionSnapshot.cacheExtensionHits = tonumber(stats.cacheExtensionHits) or ZERO
            decisionSnapshot.cacheExtensionMisses = tonumber(stats.cacheExtensionMisses) or ZERO
            decisionSnapshot.replies = tonumber(stats.replyEvaluations) or ZERO
            decisionSnapshot.extensions = tonumber(stats.extensionEvaluations) or ZERO
            decisionSnapshot.replySkippedByBudget = tonumber(stats.replySkippedByBudget) or ZERO
            decisionSnapshot.enemyReplyBatches = tonumber(stats.enemyReplyBatches) or ZERO
            decisionSnapshot.enemyReplyCandidatesGenerated = tonumber(stats.enemyReplyCandidatesGenerated) or ZERO
            decisionSnapshot.enemyReplyCandidatesGeneratedMax = tonumber(stats.enemyReplyCandidatesGeneratedMax) or ZERO
            decisionSnapshot.enemyReplyCandidatesSelected = tonumber(stats.enemyReplyCandidatesSelected) or ZERO
            decisionSnapshot.enemyReplyScoredForSort = tonumber(stats.enemyReplyScoredForSort) or ZERO
            decisionSnapshot.enemyReplyScoredWorst = tonumber(stats.enemyReplyScoredWorst) or ZERO
            decisionSnapshot.enemyReplySortStoppedByBudget = tonumber(stats.enemyReplySortStoppedByBudget) or ZERO
            decisionSnapshot.enemyReplyWorstStoppedByBudget = tonumber(stats.enemyReplyWorstStoppedByBudget) or ZERO
            decisionSnapshot.enemyReplyFirstActionPoolTotal = tonumber(stats.enemyReplyFirstActionPoolTotal) or ZERO
            decisionSnapshot.enemyReplyFirstActionPoolMax = tonumber(stats.enemyReplyFirstActionPoolMax) or ZERO
            decisionSnapshot.enemyReplySecondActionStates = tonumber(stats.enemyReplySecondActionStates) or ZERO
            decisionSnapshot.enemyReplySecondActionPoolTotal = tonumber(stats.enemyReplySecondActionPoolTotal) or ZERO
            decisionSnapshot.enemyReplySecondActionPoolMax = tonumber(stats.enemyReplySecondActionPoolMax) or ZERO
            decisionSnapshot.enemyReplyCacheHits = tonumber(stats.enemyReplyCacheHits) or ZERO
            decisionSnapshot.enemyReplyCacheMisses = tonumber(stats.enemyReplyCacheMisses) or ZERO
            decisionSnapshot.enemyReplyDeployCandidates = tonumber(stats.enemyReplyDeployCandidates) or ZERO
            decisionSnapshot.enemyDeployReplies = tonumber(stats.enemyDeployReplies) or ZERO
            decisionSnapshot.enemyReplyTacticalExtensionChecks =
                tonumber(stats.enemyReplyTacticalExtensionChecks) or ZERO
            decisionSnapshot.enemyReplyTacticalExtensionUsed =
                tonumber(stats.enemyReplyTacticalExtensionUsed) or ZERO
            decisionSnapshot.replyOwnUnitKills = tonumber(stats.replyOwnUnitKills) or ZERO
            decisionSnapshot.replyOwnUnitKillValue = tonumber(stats.replyOwnUnitKillValue) or ZERO
            decisionSnapshot.replyFreeUnitLossGuardHits = tonumber(stats.replyFreeUnitLossGuardHits) or ZERO
            decisionSnapshot.replyFreeUnitLossGuardPenalty = tonumber(stats.replyFreeUnitLossGuardPenalty) or ZERO
            decisionSnapshot.replyFreeUnitLossGuardMaxPenalty =
                tonumber(stats.replyFreeUnitLossGuardMaxPenalty) or ZERO
            decisionSnapshot.replyQuestionCounts = copyReasonCounts(stats.replyQuestionCounts or {})
            decisionSnapshot.replyOutcomeCounts = copyReasonCounts(stats.replyOutcomeCounts or {})
            decisionSnapshot.replyUsefulEvaluations = tonumber(stats.replyUsefulEvaluations) or ZERO
            decisionSnapshot.replyNoScoreEvaluations = tonumber(stats.replyNoScoreEvaluations) or ZERO
            decisionSnapshot.replyCheapSafetyEvaluations = tonumber(stats.replyCheapSafetyEvaluations) or ZERO
            decisionSnapshot.extensionQuestionCounts = copyReasonCounts(stats.extensionQuestionCounts or {})
            decisionSnapshot.extensionOutcomeCounts = copyReasonCounts(stats.extensionOutcomeCounts or {})
            decisionSnapshot.extensionSkippedByBudget = tonumber(stats.extensionSkippedByBudget) or ZERO
            decisionSnapshot.stageMs = copyNumericMap(stats.stageMs)
            decisionSnapshot.stageTotalMs = tonumber(stats.stageTotalMs) or ZERO
            decisionSnapshot.stageMeasuredMs = tonumber(stats.stageMeasuredMs) or ZERO
            decisionSnapshot.stageResidualMs = tonumber(stats.stageResidualMs) or ZERO
            decisionSnapshot.timeout = stats.timeout == true
            decisionSnapshot.tournamentPhase = stats.phase
            decisionSnapshot.tournamentPhaseTurn = stats.phaseTurn
            decisionSnapshot.tournamentPhaseReason = stats.phaseReason
            decisionSnapshot.tournamentPhaseEarlyMax = stats.phaseEarlyMax
            decisionSnapshot.tournamentPhaseEarlyReference = stats.phaseEarlyReference
            decisionSnapshot.earlyPlanActive = stats.earlyPlanActive == true
            decisionSnapshot.earlyRole = stats.earlyRole
            decisionSnapshot.earlyIntent = stats.earlyIntent
            decisionSnapshot.earlyConfidence = tonumber(stats.earlyConfidence) or ZERO
            decisionSnapshot.earlyFocalLane = stats.earlyFocalLane
            decisionSnapshot.earlySupportLane = stats.earlySupportLane
            decisionSnapshot.earlyFormationScore = tonumber(stats.earlyFormationScore) or ZERO
            decisionSnapshot.earlyFormationReasons = copyReasonCounts(stats.earlyFormationReasons or {})
            decisionSnapshot.tacticalOverrideReason = stats.tacticalOverrideReason
            decisionSnapshot.mandatoryCompletionSkippedByBudget =
                tonumber(stats.mandatoryCompletionSkippedByBudget) or ZERO
            decisionSnapshot.mandatoryFullTurnRepair =
                tonumber(stats.mandatoryFullTurnRepair) or ZERO
            decisionSnapshot.mandatoryFullTurnRepairReason = stats.mandatoryFullTurnRepairReason
            decisionSnapshot.mandatoryFullTurnRepairReplacement = stats.mandatoryFullTurnRepairReplacement
            decisionSnapshot.earlyAttackCommitmentReason = stats.earlyAttackCommitmentReason
            decisionSnapshot.earlyAttackCommitmentRejected = stats.earlyAttackCommitmentRejected == true
            decisionSnapshot.earlyAttackCommitmentReplacement = stats.earlyAttackCommitmentReplacement
            decisionSnapshot.earlyAttackCommitmentMaterialGain = tonumber(stats.earlyAttackCommitmentMaterialGain) or ZERO
            decisionSnapshot.earlyAttackCommitmentBoardDelta = tonumber(stats.earlyAttackCommitmentBoardDelta) or ZERO
            decisionSnapshot.earlyDiagnosticsEnabled = stats.earlyDiagnosticsEnabled == true
            decisionSnapshot.earlyDiagSource = stats.earlyDiagSource
            decisionSnapshot.earlyDiagFirstRankMode = stats.earlyDiagFirstRankMode
            decisionSnapshot.earlyDiagFirstLegalActions = tonumber(stats.earlyDiagFirstLegalActions) or ZERO
            decisionSnapshot.earlyDiagFirstBeamSelected = tonumber(stats.earlyDiagFirstBeamSelected) or ZERO
            decisionSnapshot.earlyDiagFirstBeamCap = tonumber(stats.earlyDiagFirstBeamCap) or ZERO
            decisionSnapshot.earlyDiagSecondBeamCap = tonumber(stats.earlyDiagSecondBeamCap) or ZERO
            decisionSnapshot.earlyDiagCandidateCap = tonumber(stats.earlyDiagCandidateCap) or ZERO
            decisionSnapshot.earlyDiagSecondStates = tonumber(stats.earlyDiagSecondStates) or ZERO
            decisionSnapshot.earlyDiagSecondLegalActionsTotal =
                tonumber(stats.earlyDiagSecondLegalActionsTotal) or ZERO
            decisionSnapshot.earlyDiagSecondLegalActionsMax =
                tonumber(stats.earlyDiagSecondLegalActionsMax) or ZERO
            decisionSnapshot.earlyDiagSecondBeamSelectedTotal =
                tonumber(stats.earlyDiagSecondBeamSelectedTotal) or ZERO
            decisionSnapshot.earlyDiagSecondBeamSelectedMax =
                tonumber(stats.earlyDiagSecondBeamSelectedMax) or ZERO
            decisionSnapshot.earlyDiagFullCandidatesGeneratedBeforeFallback =
                tonumber(stats.earlyDiagFullCandidatesGeneratedBeforeFallback) or ZERO
            decisionSnapshot.earlyDiagFullCandidatesReturned =
                tonumber(stats.earlyDiagFullCandidatesReturned) or ZERO
            decisionSnapshot.earlyDiagNormalRankedBeforeGate =
                tonumber(stats.earlyDiagNormalRankedBeforeGate) or ZERO
            decisionSnapshot.earlyDiagNormalGateKept = tonumber(stats.earlyDiagNormalGateKept) or ZERO
            decisionSnapshot.earlyDiagAuditEnabled = stats.earlyDiagAuditEnabled == true
            decisionSnapshot.earlyDiagAuditCandidates = tonumber(stats.earlyDiagAuditCandidates) or ZERO
            decisionSnapshot.earlyDiagAuditRanked = tonumber(stats.earlyDiagAuditRanked) or ZERO
            decisionSnapshot.earlyDiagAuditGateOriginal = tonumber(stats.earlyDiagAuditGateOriginal) or ZERO
            decisionSnapshot.earlyDiagAuditGateKept = tonumber(stats.earlyDiagAuditGateKept) or ZERO
            decisionSnapshot.earlyDiagAuditGateRejected = tonumber(stats.earlyDiagAuditGateRejected) or ZERO
            decisionSnapshot.earlyDiagAuditGateStoppedByBudget =
                stats.earlyDiagAuditGateStoppedByBudget == true
            decisionSnapshot.earlyDiagAuditFoundGateKept = stats.earlyDiagAuditFoundGateKept == true
            decisionSnapshot.earlyDiagAuditGateKeptOutsideNormal =
                tonumber(stats.earlyDiagAuditGateKeptOutsideNormal) or ZERO
            decisionSnapshot.earlyDiagAuditFirstReason = stats.earlyDiagAuditFirstReason
            decisionSnapshot.earlyDiagAuditReasonCounts = copyReasonCounts(stats.earlyDiagAuditReasonCounts or {})
            decisionSnapshot.earlyDiagAuditMs = tonumber(stats.earlyDiagAuditMs) or ZERO
            decisionSnapshot.earlyDiagAuditError = stats.earlyDiagAuditError
            decisionSnapshot.earlyProductiveEnumerationEnabled = stats.earlyProductiveEnumerationEnabled == true
            decisionSnapshot.earlyProductiveFirstPrepared = tonumber(stats.earlyProductiveFirstPrepared) or ZERO
            decisionSnapshot.earlyProductiveFirstShortlisted =
                tonumber(stats.earlyProductiveFirstShortlisted) or ZERO
            decisionSnapshot.earlyProductiveFirstSelected = tonumber(stats.earlyProductiveFirstSelected) or ZERO
            decisionSnapshot.pipelineV2MidEnabled = stats.pipelineV2MidEnabled == true
            decisionSnapshot.pipelineV2MidAttempted = stats.pipelineV2MidAttempted == true
            decisionSnapshot.pipelineV2MidSkipped = stats.pipelineV2MidSkipped == true
            decisionSnapshot.pipelineV2MidSkippedReason = stats.pipelineV2MidSkippedReason
            decisionSnapshot.pipelineV2MidFailedReason = stats.pipelineV2MidFailedReason
            decisionSnapshot.pipelineV2MidFellThroughToTournament = stats.pipelineV2MidFellThroughToTournament == true
            decisionSnapshot.pipelineV2MidCandidates = tonumber(stats.pipelineV2MidCandidates) or ZERO
            decisionSnapshot.pipelineV2MidAttackCandidates = tonumber(stats.pipelineV2MidAttackCandidates) or ZERO
            decisionSnapshot.pipelineV2MidPositionCandidates = tonumber(stats.pipelineV2MidPositionCandidates) or ZERO
            decisionSnapshot.pipelineV2MidFinalists = tonumber(stats.pipelineV2MidFinalists) or ZERO
            decisionSnapshot.midPositionMapEnabled = stats.midPositionMapEnabled == true
            decisionSnapshot.midPositionMapCellCount = tonumber(stats.midPositionMapCellCount) or ZERO
            decisionSnapshot.midPositionMapTopCells = stats.midPositionMapTopCells or {}
            decisionSnapshot.midPositionMapContestedTop = stats.midPositionMapContestedTop or {}
            decisionSnapshot.midPositionMapPressureTop = stats.midPositionMapPressureTop or {}
            decisionSnapshot.midPositionMapTradeTop = stats.midPositionMapTradeTop or {}
            decisionSnapshot.midPositionMapAttackTargets = stats.midPositionMapAttackTargets or {}
            decisionSnapshot.midPositionMapPositionTop = stats.midPositionMapPositionTop or {}
            decisionSnapshot.midPositionMapStatusCounts = copyReasonCounts(stats.midPositionMapStatusCounts or {})
            decisionSnapshot.midPersonalityName = stats.midPersonalityName
            decisionSnapshot.midPersonalityReference = stats.midPersonalityReference
            decisionSnapshot.midPersonalityLabel = stats.midPersonalityLabel
            decisionSnapshot.midPersonalityTop = stats.midPersonalityTop or {}
            decisionSnapshot.midPersonalityAttackTargets = stats.midPersonalityAttackTargets or {}
            decisionSnapshot.midPersonalityPositionTargets = stats.midPersonalityPositionTargets or {}
            decisionSnapshot.midPersonalityContestedTargets = stats.midPersonalityContestedTargets or {}
            decisionSnapshot.midPersonalityTradeTargets = stats.midPersonalityTradeTargets or {}
            decisionSnapshot.midTradeEvaluations = tonumber(stats.midTradeEvaluations) or ZERO
            decisionSnapshot.midTradeAccepted = tonumber(stats.midTradeAccepted) or ZERO
            decisionSnapshot.midTradeRejected = tonumber(stats.midTradeRejected) or ZERO
            decisionSnapshot.midTradeReasonCounts = copyReasonCounts(stats.midTradeReasonCounts or {})
            decisionSnapshot.midTradeLastReason = stats.midTradeLastReason
            decisionSnapshot.pipelineV2MidAttackExtraMs =
                tonumber(stats.pipelineV2MidAttackExtraMs) or ZERO
            decisionSnapshot.pipelineV2MidRemainingBeforeAttackMs =
                tonumber(stats.pipelineV2MidRemainingBeforeAttackMs) or ZERO
            decisionSnapshot.pipelineV2MidPositionExtraMs =
                tonumber(stats.pipelineV2MidPositionExtraMs) or ZERO
            decisionSnapshot.pipelineV2MidRemainingBeforePositionMs =
                tonumber(stats.pipelineV2MidRemainingBeforePositionMs) or ZERO
            decisionSnapshot.pipelineV2Enabled = stats.pipelineV2Enabled == true
            decisionSnapshot.pipelineV2Skipped = stats.pipelineV2Skipped == true
            decisionSnapshot.pipelineV2FailClosed = stats.pipelineV2FailClosed == true
            decisionSnapshot.pipelineV2FailedReason = stats.pipelineV2FailedReason
            decisionSnapshot.pipelineV2Candidates = tonumber(stats.pipelineV2Candidates) or ZERO
            decisionSnapshot.pipelineV2Accepted = tonumber(stats.pipelineV2Accepted) or ZERO
            decisionSnapshot.pipelineV2Finalists = tonumber(stats.pipelineV2Finalists) or ZERO
            decisionSnapshot.pipelineV2FinalistsExtraMs =
                tonumber(stats.pipelineV2FinalistsExtraMs) or ZERO
            decisionSnapshot.pipelineV2RemainingBeforeFinalistsMs =
                tonumber(stats.pipelineV2RemainingBeforeFinalistsMs) or ZERO
            decisionSnapshot.pipelineV2FinalistsEvaluated =
                tonumber(stats.pipelineV2FinalistsEvaluated) or ZERO
            decisionSnapshot.pipelineV2FinalistsSkippedByBudget =
                stats.pipelineV2FinalistsSkippedByBudget == true
            decisionSnapshot.pipelineV2FullTurnEnabled = stats.pipelineV2FullTurnEnabled == true
            decisionSnapshot.pipelineV2FullTurnInputCandidates =
                tonumber(stats.pipelineV2FullTurnInputCandidates) or ZERO
            decisionSnapshot.pipelineV2FullTurnOutputCandidates =
                tonumber(stats.pipelineV2FullTurnOutputCandidates) or ZERO
            decisionSnapshot.pipelineV2FullTurnCompleted =
                tonumber(stats.pipelineV2FullTurnCompleted) or ZERO
            decisionSnapshot.pipelineV2FullTurnDropped =
                tonumber(stats.pipelineV2FullTurnDropped) or ZERO
            decisionSnapshot.pipelineV2FullTurnSingleActionOutput =
                tonumber(stats.pipelineV2FullTurnSingleActionOutput) or ZERO
            decisionSnapshot.pipelineV2FullTurnSecondScanned =
                tonumber(stats.pipelineV2FullTurnSecondScanned) or ZERO
            decisionSnapshot.pipelineV2FullTurnMoveRiskPenalized =
                tonumber(stats.pipelineV2FullTurnMoveRiskPenalized) or ZERO
            decisionSnapshot.pipelineV2FullTurnMoveRiskLethal =
                tonumber(stats.pipelineV2FullTurnMoveRiskLethal) or ZERO
            decisionSnapshot.pipelineV2FullTurnMoveRiskSuicidal =
                tonumber(stats.pipelineV2FullTurnMoveRiskSuicidal) or ZERO
            decisionSnapshot.pipelineV2FullTurnMoveRiskPenaltyMax =
                tonumber(stats.pipelineV2FullTurnMoveRiskPenaltyMax) or ZERO
            decisionSnapshot.pipelineV2FullTurnReasonCounts =
                copyReasonCounts(stats.pipelineV2FullTurnReasonCounts or {})
            decisionSnapshot.pipelineV2FullTurnDroppedReasons =
                copyReasonCounts(stats.pipelineV2FullTurnDroppedReasons or {})
            decisionSnapshot.pipelineV2RejectedReasons =
                copyReasonCounts(stats.pipelineV2RejectedReasons or {})
            decisionSnapshot.pipelineV2EarlyGateEnabled = stats.pipelineV2EarlyGateEnabled == true
            decisionSnapshot.pipelineV2EarlyGatePath = tostring(stats.pipelineV2EarlyGatePath or "v2")
            decisionSnapshot.pipelineV2EarlyGateChecks =
                tonumber(stats.pipelineV2EarlyGateChecks) or ZERO
            decisionSnapshot.pipelineV2EarlyGateAccepted =
                tonumber(stats.pipelineV2EarlyGateAccepted) or ZERO
            decisionSnapshot.pipelineV2EarlyGateRejected =
                tonumber(stats.pipelineV2EarlyGateRejected) or ZERO
            decisionSnapshot.pipelineV2EarlyGateRejectedReasons =
                copyReasonCounts(stats.pipelineV2EarlyGateRejectedReasons or {})
            decisionSnapshot.pipelineV2EarlyGateFirstRejectedReason =
                stats.pipelineV2EarlyGateFirstRejectedReason
            decisionSnapshot.pipelineV2PositionHints = tonumber(stats.pipelineV2PositionHints) or ZERO
            decisionSnapshot.pipelineV2PositionHintsEligible =
                tonumber(stats.pipelineV2PositionHintsEligible) or ZERO
            decisionSnapshot.pipelineV2PositionHintsSkippedShort =
                tonumber(stats.pipelineV2PositionHintsSkippedShort) or ZERO
            decisionSnapshot.pipelineV2PositionHintsRanked =
                tonumber(stats.pipelineV2PositionHintsRanked) or ZERO
            decisionSnapshot.pipelineV2SelectedSignature = stats.pipelineV2SelectedSignature
            decisionSnapshot.pipelineV2SelectedAcceptReason = stats.pipelineV2SelectedAcceptReason
            decisionSnapshot.earlyPositionMapCellCount = tonumber(stats.earlyPositionMapCellCount) or ZERO
            decisionSnapshot.earlyPositionMapLaneWidth = tonumber(stats.earlyPositionMapLaneWidth) or ZERO
            decisionSnapshot.earlyPositionMapCenterlineBias = tonumber(stats.earlyPositionMapCenterlineBias) or ZERO
            decisionSnapshot.earlyPositionMapMainRouteSaturation =
                tonumber(stats.earlyPositionMapMainRouteSaturation) or ZERO
            decisionSnapshot.earlyPositionMapStatusCounts =
                copyReasonCounts(stats.earlyPositionMapStatusCounts or {})
            decisionSnapshot.earlyPositionMapTopCells = stats.earlyPositionMapTopCells or {}
            decisionSnapshot.earlyPositionMapOwnedUncovered = stats.earlyPositionMapOwnedUncovered or {}
            decisionSnapshot.earlyPositionFrontierPreTargetSuppressed =
                tonumber(stats.earlyPositionFrontierPreTargetSuppressed) or ZERO
            decisionSnapshot.earlyPositionFrontierPreTargetSupport =
                tonumber(stats.earlyPositionFrontierPreTargetSupport) or ZERO
            decisionSnapshot.earlyPositionFrontierPreTargetRear =
                tonumber(stats.earlyPositionFrontierPreTargetRear) or ZERO
            decisionSnapshot.earlyPositionFrontierProjectedEnabled =
                stats.earlyPositionFrontierProjectedEnabled == true
            decisionSnapshot.earlyPositionFrontierProjectedConsidered =
                tonumber(stats.earlyPositionFrontierProjectedConsidered) or ZERO
            decisionSnapshot.earlyPositionFrontierProjectedAnchors =
                tonumber(stats.earlyPositionFrontierProjectedAnchors) or ZERO
            decisionSnapshot.earlyPositionFrontierProjectedSuppressed =
                tonumber(stats.earlyPositionFrontierProjectedSuppressed) or ZERO
            decisionSnapshot.pipelineV2EarlySequencePrimary = stats.pipelineV2EarlySequencePrimary
            decisionSnapshot.pipelineV2DeployFirstCandidates =
                tonumber(stats.pipelineV2DeployFirstCandidates) or ZERO
            decisionSnapshot.pipelineV2DeployFirstDeployActions =
                tonumber(stats.pipelineV2DeployFirstDeployActions) or ZERO
            decisionSnapshot.pipelineV2DeployFirstBudgetExtraMs =
                tonumber(stats.pipelineV2DeployFirstBudgetExtraMs) or ZERO
            decisionSnapshot.pipelineV2DeployFirstBudgetRemainingBeforeMs =
                tonumber(stats.pipelineV2DeployFirstBudgetRemainingBeforeMs) or ZERO
            decisionSnapshot.pipelineV2DeployFirstBudgetUses =
                tonumber(stats.pipelineV2DeployFirstBudgetUses) or ZERO
            decisionSnapshot.pipelineV2DeployFirstBudgetReturned =
                tonumber(stats.pipelineV2DeployFirstBudgetReturned) or ZERO
            decisionSnapshot.pipelineV2DeployFirstReasonCounts =
                copyReasonCounts(stats.pipelineV2DeployFirstReasonCounts or {})
            decisionSnapshot.pipelineV2DeployFirstCoverMode = stats.pipelineV2DeployFirstCoverMode
            decisionSnapshot.pipelineV2DeployFirstRealCoverChecks =
                tonumber(stats.pipelineV2DeployFirstRealCoverChecks) or ZERO
            decisionSnapshot.pipelineV2DeployFirstRealCoverHits =
                tonumber(stats.pipelineV2DeployFirstRealCoverHits) or ZERO
            decisionSnapshot.pipelineV2DeployFirstContinuationMode =
                stats.pipelineV2DeployFirstContinuationMode
            decisionSnapshot.pipelineV2DeployFirstContinuationCandidates =
                tonumber(stats.pipelineV2DeployFirstContinuationCandidates) or ZERO
            decisionSnapshot.pipelineV2DeployFirstEarlySecondScanned =
                tonumber(stats.pipelineV2DeployFirstEarlySecondScanned) or ZERO
            decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskPenalized =
                tonumber(stats.pipelineV2DeployFirstEarlySecondMoveRiskPenalized) or ZERO
            decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskLethal =
                tonumber(stats.pipelineV2DeployFirstEarlySecondMoveRiskLethal) or ZERO
            decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskSuicidal =
                tonumber(stats.pipelineV2DeployFirstEarlySecondMoveRiskSuicidal) or ZERO
            decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskPenaltyMax =
                tonumber(stats.pipelineV2DeployFirstEarlySecondMoveRiskPenaltyMax) or ZERO
            decisionSnapshot.pipelineV2DeployFirstEarlySecondReasonCounts =
                copyReasonCounts(stats.pipelineV2DeployFirstEarlySecondReasonCounts or {})
            decisionSnapshot.pipelineV2DeployFirstEarlySecondSkippedReasons =
                copyReasonCounts(stats.pipelineV2DeployFirstEarlySecondSkippedReasons or {})
            decisionSnapshot.pipelineV2DeployFirstTop = stats.pipelineV2DeployFirstTop or {}
            decisionSnapshot.pipelineV2MovePositionCandidates =
                tonumber(stats.pipelineV2MovePositionCandidates) or ZERO
            decisionSnapshot.pipelineV2MovePositionActions =
                tonumber(stats.pipelineV2MovePositionActions) or ZERO
            decisionSnapshot.pipelineV2MovePositionReasonCounts =
                copyReasonCounts(stats.pipelineV2MovePositionReasonCounts or {})
            decisionSnapshot.pipelineV2MovePositionSkippedReasons =
                copyReasonCounts(stats.pipelineV2MovePositionSkippedReasons or {})
            decisionSnapshot.pipelineV2MovePositionCoverMode = stats.pipelineV2MovePositionCoverMode
            decisionSnapshot.pipelineV2MovePositionRealCoverChecks =
                tonumber(stats.pipelineV2MovePositionRealCoverChecks) or ZERO
            decisionSnapshot.pipelineV2MovePositionRealCoverHits =
                tonumber(stats.pipelineV2MovePositionRealCoverHits) or ZERO
            decisionSnapshot.pipelineV2MovePositionTop = stats.pipelineV2MovePositionTop or {}
            decisionSnapshot.pipelineV2UnitPoolFreeUnits =
                tonumber(stats.pipelineV2UnitPoolFreeUnits) or ZERO
            decisionSnapshot.pipelineV2UnitPoolLockedOccupants =
                tonumber(stats.pipelineV2UnitPoolLockedOccupants) or ZERO
            decisionSnapshot.pipelineV2UnitPoolLockedCoverUnits =
                tonumber(stats.pipelineV2UnitPoolLockedCoverUnits) or ZERO
            decisionSnapshot.pipelineV2UnitPoolReleasableOccupants =
                tonumber(stats.pipelineV2UnitPoolReleasableOccupants) or ZERO
            decisionSnapshot.pipelineV2UnitPoolCoverTargets =
                tonumber(stats.pipelineV2UnitPoolCoverTargets) or ZERO
            decisionSnapshot.pipelineV2UnitPoolResolvedCells =
                tonumber(stats.pipelineV2UnitPoolResolvedCells) or ZERO
            decisionSnapshot.pipelineV2UnitPoolFree = stats.pipelineV2UnitPoolFree or {}
            decisionSnapshot.pipelineV2UnitPoolLockedOccupantsList =
                stats.pipelineV2UnitPoolLockedOccupantsList or {}
            decisionSnapshot.pipelineV2UnitPoolLockedCoverUnitsList =
                stats.pipelineV2UnitPoolLockedCoverUnitsList or {}
            decisionSnapshot.pipelineV2UnitPoolReleasableOccupantsList =
                stats.pipelineV2UnitPoolReleasableOccupantsList or {}
            decisionSnapshot.movePatternPenalized =
                tonumber(stats.movePatternPenalized) or ZERO
            decisionSnapshot.movePatternPenaltyMax =
                tonumber(stats.movePatternPenaltyMax) or ZERO
            decisionSnapshot.cloudstrikerMeleeContactPenalized =
                tonumber(stats.cloudstrikerMeleeContactPenalized) or ZERO
            decisionSnapshot.cloudstrikerMeleeContactPenaltyMax =
                tonumber(stats.cloudstrikerMeleeContactPenaltyMax) or ZERO
            decisionSnapshot.tournamentReason = meta and meta.reason or nil
            decisionSnapshot.legalAttackActions = tonumber(stats.legalAttackActions) or ZERO
            decisionSnapshot.legalMoveAttackActions = tonumber(stats.legalMoveAttackActions) or ZERO
            decisionSnapshot.defenseKind = stats.defenseKind
            decisionSnapshot.directThreatAttackActions = tonumber(stats.directThreatAttackActions) or ZERO
            decisionSnapshot.directThreatReductionActions = tonumber(stats.directThreatReductionActions) or ZERO
            decisionSnapshot.moveThreatAttackActions = tonumber(stats.moveThreatAttackActions) or ZERO
            decisionSnapshot.ownCommandantProjectedThreatDamage = tonumber(stats.ownCommandantProjectedThreatDamage) or ZERO
            decisionSnapshot.candidateWithFactionAttack = tonumber(stats.candidateWithFactionAttack) or ZERO
            decisionSnapshot.rankedWithFactionAttack = tonumber(stats.rankedWithFactionAttack) or ZERO
            decisionSnapshot.finalistWithFactionAttack = tonumber(stats.finalistWithFactionAttack) or ZERO
            decisionSnapshot.rankedSourceCountsBeforeGate =
                copyReasonCounts(stats.rankedSourceCountsBeforeGate or {})
            decisionSnapshot.rankedSourceCountsAfterGate =
                copyReasonCounts(stats.rankedSourceCountsAfterGate or {})
            decisionSnapshot.finalistSourceCounts = copyReasonCounts(stats.finalistSourceCounts or {})
            decisionSnapshot.selectedHasFactionAttack = stats.selectedHasFactionAttack == true
            decisionSnapshot.selectedPassiveOnly = stats.selectedPassiveOnly == true
            decisionSnapshot.selectedFactionAttackCount = tonumber(stats.selectedFactionAttackCount) or ZERO
            decisionSnapshot.selectedMeleeFactionAttackCount = tonumber(stats.selectedMeleeFactionAttackCount) or ZERO
            decisionSnapshot.selectedRangedFactionAttackCount = tonumber(stats.selectedRangedFactionAttackCount) or ZERO
            decisionSnapshot.selectedCombatClass = stats.selectedCombatClass
            decisionSnapshot.selectedCombatSafetyReason = stats.selectedCombatSafetyReason
            decisionSnapshot.bestFactionAttackFastScore = scoreTotal(stats.bestFactionAttackFastScore)
            decisionSnapshot.selectedFastScore = scoreTotal(stats.selectedFastScore)
            decisionSnapshot.selectedFinalScore = scoreTotal(stats.selectedFinalScore)
            decisionSnapshot.selectedScoreDelta = tonumber(stats.selectedScoreDelta) or ZERO
            decisionSnapshot.selectedCandidateSource = stats.selectedCandidateSource
            decisionSnapshot.selectedCandidateLane = stats.selectedCandidateLane
            decisionSnapshot.selectedRequiredLane = stats.selectedRequiredLane == true
            decisionSnapshot.selectedEarlyPositionReason = stats.selectedEarlyPositionReason
            decisionSnapshot.selectedEarlyPositionTarget = stats.selectedEarlyPositionTarget
            decisionSnapshot.selectedSoftDefensePressure = stats.selectedSoftDefensePressure == true
            decisionSnapshot.selectedSoftDefensePressureReason = stats.selectedSoftDefensePressureReason
            decisionSnapshot.selectedSoftDefensePressureBeforeDamage =
                tonumber(stats.selectedSoftDefensePressureBeforeDamage) or ZERO
            decisionSnapshot.selectedSoftDefensePressureAfterDamage =
                tonumber(stats.selectedSoftDefensePressureAfterDamage) or ZERO
            decisionSnapshot.selectedSoftDefensePressureBeforeAttackers =
                tonumber(stats.selectedSoftDefensePressureBeforeAttackers) or ZERO
            decisionSnapshot.selectedSoftDefensePressureAfterAttackers =
                tonumber(stats.selectedSoftDefensePressureAfterAttackers) or ZERO
            decisionSnapshot.selectedSoftDefensePressureNet =
                tonumber(stats.selectedSoftDefensePressureNet) or ZERO
            decisionSnapshot.selectedContainsDeploy = stats.selectedContainsDeploy == true
            decisionSnapshot.selectedContainsAttack = stats.selectedContainsAttack == true
            decisionSnapshot.selectedReplyQuestion = stats.selectedReplyQuestion
            decisionSnapshot.selectedReplyOutcome = stats.selectedReplyOutcome
            decisionSnapshot.selectedExtensionQuestion = stats.selectedExtensionQuestion
            decisionSnapshot.selectedExtensionOutcome = stats.selectedExtensionOutcome
            decisionSnapshot.selectedMatchesBestSoFar = stats.selectedMatchesBestSoFar == true
            decisionSnapshot.preSanitizeSelectedStage = stats.preSanitizeSelectedStage
            decisionSnapshot.preSanitizeSelectedSignature = stats.preSanitizeSelectedSignature
            decisionSnapshot.preSanitizeCandidateSource = stats.preSanitizeCandidateSource
            decisionSnapshot.preSanitizeCandidateLane = stats.preSanitizeCandidateLane
            decisionSnapshot.preSanitizeRequiredLane = stats.preSanitizeRequiredLane == true
            decisionSnapshot.preSanitizeEarlyPositionReason = stats.preSanitizeEarlyPositionReason
            decisionSnapshot.preSanitizeEarlyPositionTarget = stats.preSanitizeEarlyPositionTarget
            decisionSnapshot.preSanitizeContainsDeploy = stats.preSanitizeContainsDeploy == true
            decisionSnapshot.preSanitizeContainsAttack = stats.preSanitizeContainsAttack == true
            decisionSnapshot.preSanitizeFastScore = scoreTotal(stats.preSanitizeFastScore)
            decisionSnapshot.preSanitizeFinalScore = scoreTotal(stats.preSanitizeFinalScore)
            decisionSnapshot.preSanitizeScoreDelta = tonumber(stats.preSanitizeScoreDelta) or ZERO
            decisionSnapshot.preSanitizeReplyQuestion = stats.preSanitizeReplyQuestion
            decisionSnapshot.preSanitizeReplyOutcome = stats.preSanitizeReplyOutcome
            decisionSnapshot.preSanitizeExtensionQuestion = stats.preSanitizeExtensionQuestion
            decisionSnapshot.preSanitizeExtensionOutcome = stats.preSanitizeExtensionOutcome
            decisionSnapshot.preSanitizeMatchesBestSoFar = stats.preSanitizeMatchesBestSoFar == true
            decisionSnapshot.attackLossReason = stats.attackLossReason
            decisionSnapshot.safeCombatAvailable = stats.safeCombatAvailable == true
            decisionSnapshot.bestSafeCombatClass = stats.bestSafeCombatClass
            decisionSnapshot.bestSafeCombatSignature = stats.bestSafeCombatSignature
            decisionSnapshot.bestSafeCombatDamage = tonumber(stats.bestSafeCombatDamage) or ZERO
            decisionSnapshot.bestSafeCombatKills = tonumber(stats.bestSafeCombatKills) or ZERO
            decisionSnapshot.bestSafeCombatTargetValue = tonumber(stats.bestSafeCombatTargetValue) or ZERO
            decisionSnapshot.drawStreak = tonumber(stats.drawStreak) or ZERO
            decisionSnapshot.drawUrgencyActive = stats.officialDrawUrgencyActive == true
            decisionSnapshot.drawUrgency = tonumber(stats.officialDrawUrgency) or ZERO
            decisionSnapshot.drawConversionOpportunity = stats.drawConversionOpportunity == true
            decisionSnapshot.drawConversionChosen = stats.drawConversionChosen == true
            decisionSnapshot.drawConversionMissReason = stats.drawConversionMissReason
            decisionSnapshot.kernelAvailable = stats.kernelAvailable == true
            decisionSnapshot.kernelReason = stats.kernelReason
            decisionSnapshot.kernelSource = stats.kernelSource
            decisionSnapshot.selectedContract = meta and meta.contract or nil
            decisionSnapshot.activeContracts = copyReasonCounts(evidence.activeContracts or {})
            decisionSnapshot.combatContractActive = stats.combatContractActive == true
            decisionSnapshot.combatDirectGenerated = tonumber(stats.combatDirectGenerated) or ZERO
            decisionSnapshot.combatMoveAttackGenerated = tonumber(stats.combatMoveAttackGenerated) or ZERO
            decisionSnapshot.combatRanked = tonumber(stats.combatRanked) or ZERO
            decisionSnapshot.combatFinalists = tonumber(stats.combatFinalists) or ZERO
            decisionSnapshot.combatSelected = tonumber(stats.combatSelected) or ZERO
            decisionSnapshot.combatSkippedWithProof = tonumber(stats.combatSkippedWithProof) or ZERO
            decisionSnapshot.combatSkippedWithoutProof = tonumber(stats.combatSkippedWithoutProof) or ZERO
            decisionSnapshot.conversionContractActive = stats.conversionContractActive == true
            decisionSnapshot.conversionContracts = copyReasonCounts(stats.conversionContracts or {})
            decisionSnapshot.conversionMaterialDiff = tonumber(stats.conversionMaterialDiff) or ZERO
            decisionSnapshot.conversionOwnUnits = tonumber(stats.conversionOwnUnits) or ZERO
            decisionSnapshot.conversionEnemyUnits = tonumber(stats.conversionEnemyUnits) or ZERO
            decisionSnapshot.conversionOwnHubHp = tonumber(stats.conversionOwnHubHp) or ZERO
            decisionSnapshot.conversionEnemyHubHp = tonumber(stats.conversionEnemyHubHp) or ZERO
            decisionSnapshot.conversionCommandantPressure = tonumber(stats.conversionCommandantPressure) or ZERO
            decisionSnapshot.selectedCommandantDamage = tonumber(stats.selectedCommandantDamage) or ZERO
            decisionSnapshot.selectedKillCount = tonumber(stats.selectedKillCount) or ZERO
            decisionSnapshot.selectedCreatesNextTurnCommandantLethal = stats.selectedCreatesNextTurnCommandantLethal == true
            decisionSnapshot.selectedRemovesEnemyLastAttacker = stats.selectedRemovesEnemyLastAttacker == true
            decisionSnapshot.passiveOverrideReason = stats.passiveOverrideReason
            decisionSnapshot.selectedProofReason = evidence.selectedProofReason
            decisionSnapshot.passiveOverrideAllowed = evidence.passiveOverride and evidence.passiveOverride.allowed == true
            decisionSnapshot.hardSelectionLocked = stats.hardSelectionLocked == true
            decisionSnapshot.hardSelectionRejected = stats.hardSelectionRejected == true
            decisionSnapshot.hardSelectionReason = stats.hardSelectionReason
            decisionSnapshot.hardSelectionSignature = stats.hardSelectionSignature
            decisionSnapshot.hardSelectionPrefixCompleted = stats.hardSelectionPrefixCompleted == true
            decisionSnapshot.hardSelectionPrefixSignature = stats.hardSelectionPrefixSignature
            decisionSnapshot.hardSelectionCompletedSignature = stats.hardSelectionCompletedSignature
            decisionSnapshot.hardSelectionRejectReason = stats.hardSelectionRejectReason
                or (decisionSnapshot.hardSelectionRejected == true and (meta and meta.reason or nil))
            decisionSnapshot.hardSelectionRejectStage = stats.hardSelectionRejectStage
                or (decisionSnapshot.hardSelectionRejected == true and "tournament_sanitizer" or nil)
            decisionSnapshot.hardSelectionRejectSignature = stats.hardSelectionRejectSignature
                or stats.hardSelectionSignature
            decisionSnapshot.hardSelectionRejectSanitizerReplacements =
                tonumber(stats.hardSelectionRejectSanitizerReplacements) or ZERO
            decisionSnapshot.hardSelectionRejectSanitizerReasonCounts =
                copyReasonCounts(stats.hardSelectionRejectSanitizerReasonCounts or {})
            decisionSnapshot.hardSelectionFallbackPath = stats.hardSelectionFallbackPath
            decisionSnapshot.runtimeSanitizerRejected = stats.runtimeSanitizerRejected == true
            decisionSnapshot.runtimeSanitizerRejectReason = stats.runtimeSanitizerRejectReason
            decisionSnapshot.runtimeSanitizerRejectReplacements =
                tonumber(stats.runtimeSanitizerRejectReplacements) or ZERO
            decisionSnapshot.runtimeSanitizerRejectReasonCounts =
                copyReasonCounts(stats.runtimeSanitizerRejectReasonCounts or {})
            decisionSnapshot.runtimeSanitizerRejectRawSignature =
                stats.runtimeSanitizerRejectRawSignature
            decisionSnapshot.runtimeSanitizerRejectSanitizedSignature =
                stats.runtimeSanitizerRejectSanitizedSignature
            if type(meta) == "table" and type(meta.elapsedMs) == "number" then
                decisionSnapshot.tournamentComputeMs = meta.elapsedMs
            end
        end

        local function capturePrimaryTournamentSnapshot(trigger)
            if decisionSnapshot.primaryTournamentCaptured == true then
                return
            end
            decisionSnapshot.primaryTournamentCaptured = true
            decisionSnapshot.primaryTournamentTrigger = trigger
            decisionSnapshot.primaryTournamentReason = decisionSnapshot.tournamentReason
            decisionSnapshot.primaryFallbackReason = decisionSnapshot.fallbackReason
            decisionSnapshot.primaryCoreExit = decisionSnapshot.coreExit
            decisionSnapshot.primaryFallbackSource = decisionSnapshot.fallbackSource
            decisionSnapshot.primaryOwnCandidates = decisionSnapshot.ownCandidates
            decisionSnapshot.primaryRankedCandidates = decisionSnapshot.rankedCandidates
            decisionSnapshot.primaryFinalists = decisionSnapshot.finalists
            decisionSnapshot.primaryEvaluatedCandidates = decisionSnapshot.evaluatedCandidates
            decisionSnapshot.primaryTimeout = decisionSnapshot.timeout == true
        end

        local function emitRuntimeDecisionTrace()
            if not (GAME and GAME.CURRENT) then
                return
            end

            local tournamentConfig = (self.getTournamentConfig and self:getTournamentConfig()) or {}
            local runtimeTag = tournamentConfig.RUNTIME_TAG or "unknown"
            local currentMode = tostring(GAME.CURRENT.MODE or "unknown")
            local currentTurn = tostring((GAME and GAME.CURRENT and GAME.CURRENT.TURN) or "?")
            local currentPlayer = tostring(self.factionId or "?")
            local selectedContract = tostring(decisionSnapshot.selectedContract or "none")
            local tournamentReason = tostring(decisionSnapshot.tournamentReason or "unknown")
            local activeContracts = formatValueList(decisionSnapshot.activeContracts)
            local activeLookup = {}
            for _, contractName in ipairs(decisionSnapshot.activeContracts or {}) do
                activeLookup[tostring(contractName)] = true
            end

            local hardOutcome = "pass_to_core"
            local hardReason = "no_immediate_win"
            local coreEntered = true
            if decisionSnapshot.hardSelectionRejected == true then
                hardOutcome = "hard_rejected_" .. tostring(decisionSnapshot.hardSelectionRejectStage or "unknown")
                hardReason = tostring(decisionSnapshot.hardSelectionRejectReason
                    or decisionSnapshot.hardSelectionReason
                    or tournamentReason)
                coreEntered = false
            elseif decisionSnapshot.hardSelectionLocked == true then
                hardOutcome = "hard_locked_" .. tostring(decisionSnapshot.hardSelectionReason or "selected")
                hardReason = tostring(decisionSnapshot.hardSelectionReason or tournamentReason)
                coreEntered = tostring(decisionSnapshot.hardSelectionReason or "") ~= "win_now"
            elseif selectedContract == "WIN_NOW" or tournamentReason == "immediate_win" then
                hardOutcome = "win_now_selected"
                hardReason = "immediate_win"
                coreEntered = false
            elseif activeLookup.DEFEND_NOW then
                if selectedContract == "DEFEND_NOW" then
                    local defenseRecovery = tostring(decisionSnapshot.fallbackReason or ""):find("defense", ONE, true)
                        and tostring(decisionSnapshot.fallbackReason or ""):find("recovery", ONE, true)
                    if defenseRecovery then
                        hardOutcome = "defend_now_resolved_by_recovery"
                    else
                        hardOutcome = "defend_now_resolved_by_core"
                    end
                    hardReason = tostring(decisionSnapshot.selectedProofReason
                        or decisionSnapshot.passiveOverrideReason
                        or tournamentReason)
                elseif tostring(decisionSnapshot.fallbackReason or ""):find("defense", ONE, true)
                    or tournamentReason:find("defend_now", ONE, true) then
                    hardOutcome = "defend_now_fallback"
                    hardReason = tostring(decisionSnapshot.fallbackReason or tournamentReason)
                else
                    hardOutcome = "defend_now_entered_core"
                    hardReason = tostring(decisionSnapshot.selectedProofReason
                        or decisionSnapshot.passiveOverrideReason
                        or tournamentReason)
                end
            elseif activeLookup.COMBAT_OR_DRAW_RESET then
                hardOutcome = "no_win_no_defense_core_combat"
                hardReason = "legal_combat_or_draw_reset_available"
            else
                hardOutcome = "no_hard_contract"
                hardReason = "no_win_no_defense_no_forced_combat"
            end

            local budgetState = "ok"
            if decisionSnapshot.timeout == true then
                budgetState = "timeout"
            elseif tournamentReason:find("budget", ONE, true)
                or tostring(decisionSnapshot.fallbackReason or ""):find("budget", ONE, true) then
                budgetState = "budget_guard"
            elseif (tonumber(decisionSnapshot.replySkippedByBudget) or ZERO) > ZERO
                or (tonumber(decisionSnapshot.extensionSkippedByBudget) or ZERO) > ZERO
                or (tonumber(decisionSnapshot.mandatoryCompletionSkippedByBudget) or ZERO) > ZERO then
                budgetState = "budget_degraded"
            end

            logger.warn(
                "AI",
                string.format(
                    "AI_CONTRACTS p=%s turn=%s mode=%s active=%s hard=%s core=%s reason=%s defense=%s threatDmg=%.0f legalAtk=%.0f legalMoveAtk=%.0f threatAtk=%.0f threatReduce=%.0f threatMoveAtk=%.0f draw=%s/%.0f conversion=%s safeCombat=%s/%s safeKills=%.0f safeDmg=%.0f proof=%s proofOk=%s rt=%s",
                    currentPlayer,
                    currentTurn,
                    currentMode,
                    activeContracts,
                    hardOutcome,
                    tostring(coreEntered),
                    hardReason,
                    tostring(decisionSnapshot.defenseKind or "none"),
                    tonumber(decisionSnapshot.ownCommandantProjectedThreatDamage) or ZERO,
                    tonumber(decisionSnapshot.legalAttackActions) or ZERO,
                    tonumber(decisionSnapshot.legalMoveAttackActions) or ZERO,
                    tonumber(decisionSnapshot.directThreatAttackActions) or ZERO,
                    tonumber(decisionSnapshot.directThreatReductionActions) or ZERO,
                    tonumber(decisionSnapshot.moveThreatAttackActions) or ZERO,
                    tostring(decisionSnapshot.drawUrgencyActive == true),
                    tonumber(decisionSnapshot.drawStreak) or ZERO,
                    tostring(decisionSnapshot.conversionContractActive == true),
                    tostring(decisionSnapshot.safeCombatAvailable == true),
                    tostring(decisionSnapshot.bestSafeCombatClass or "none"),
                    tonumber(decisionSnapshot.bestSafeCombatKills) or ZERO,
                    tonumber(decisionSnapshot.bestSafeCombatDamage) or ZERO,
                    tostring(decisionSnapshot.selectedProofReason or decisionSnapshot.passiveOverrideReason or "none"),
                    tostring(decisionSnapshot.passiveOverrideAllowed == true),
                    tostring(runtimeTag)
                )
            )

                logger.warn(
                    "AI",
                    string.format(
                    "AI_CORE p=%s turn=%s mode=%s reason=%s budget=%s coreExit=%s bestSoFar=%s/%s fallbackSource=%s primary=%s yields=%.0f kernel=%s/%s stageMs=%s covered=%.1f residual=%.1f budgetSkip=%s v2=%s/%s/%s v2Cand=%.0f/%.0f/%.0f v2Reject=%s midV2=%s/%s/%s/%.0f/%.0f/%.0f mMap=%s/%.0f/status:%s mTop=%s mCont=%s mAtk=%s mPos=%s mPers=%s/%s/%s mPTop=%s mPCont=%s mPAtk=%s mPPos=%s mTrade=%.0f/%.0f/%.0f/%s/%s mMidSel=%s/%s/%.0f mGate=%.0f/%.1f/%.0f/%.0f/%s mBud=%.0f/%.1f/%.0f/%.1f v2Full=%s/%.0f/%.0f/%.0f/%.0f/%.0f/scan%.0f/risk%.0f/%.0f/%.0f/%.0f/reasons:%s/drop:%s v2Gate=%s/%s/%.0f/%.0f/%.0f/rej:%s/first:%s v2Fin=%.0f/%.1f/%.0f/%s v2Hint=%.0f/%.0f/%.0f/%.0f eMap=%.0f/lane%.1f/center%.2f/sat%.2f eMapStatus=%s eTop=%s eOwned=%s eFrontier=pre%.0f/s%.0f/r%.0f/proj%s:%.0f/%.0f/%.0f seq=%s v2Deploy=%s/cont:%s/%.0f/scan%.0f/risk%.0f/%.0f/%.0f/%.0f/acts%.0f/cand%.0f/cover%.0f/%.0f/reasons:%s/contReasons:%s/contSkip:%s/top:%s depBudget=%.0f/%.1f/%.0f/%.0f v2Move=%s/acts%.0f/cand%.0f/cover%.0f/%.0f/reasons:%s/skip:%s/top:%s posPen=%.0f/%.0f cloudMelee=%.0f/%.0f unitPool=free%.0f/occ%.0f/cov%.0f/rel%.0f/targets%.0f/resolved%.0f poolFree=%s poolOcc=%s poolCov=%s poolRel=%s cand=%.0f ranked=%.0f eval=%.0f final=%.0f replies=%.0f replySkip=%.0f replyUseful=%.0f/%.0f/%.0f replyQ=%s replyOut=%s cache=%.0f/%.0f cKind=sim:%.0f/%.0f feat:%.0f/%.0f legal:%.0f/%.0f threat:%.0f/%.0f supply:%.0f/%.0f ext:%.0f/%.0f rGen=%.0f/%.0f/%.0f rPick=%.0f rScore=%.0f/%.0f rStop=%.0f/%.0f rPool=%.0f/%.0f/%.0f/%.0f rCache=%.0f/%.0f rDeploy=%.0f/%.0f rExt=%.0f/%.0f rFree=%.0f/%.0f/%.0f/%.0f/%.0f ext=%.0f extSkip=%.0f extQ=%s extOut=%s attackLoss=%s selectedAtk=%s selectedClass=%s safety=%s bestAtkScore=%.0f selectedScore=%.0f fallback=%s rt=%s",
                    currentPlayer,
                    currentTurn,
                    currentMode,
                    tournamentReason,
                    budgetState,
                    tostring(decisionSnapshot.coreExit or "not_reported"),
                    tostring(decisionSnapshot.bestSoFarAvailable == true),
                    tostring(decisionSnapshot.bestSoFarSource or "none"),
                    tostring(decisionSnapshot.fallbackSource or "none"),
                    formatPrimaryTournament(decisionSnapshot),
                    tonumber(decisionSnapshot.cooperativeYields) or ZERO,
                    tostring(decisionSnapshot.kernelAvailable == true),
                    tostring(decisionSnapshot.kernelReason or "none"),
                    formatStageMs(decisionSnapshot.stageMs),
                    tonumber(decisionSnapshot.stageMeasuredMs) or ZERO,
                    tonumber(decisionSnapshot.stageResidualMs) or ZERO,
                    tostring(decisionSnapshot.mandatoryCompletionSkippedByBudget or ZERO),
                    tostring(decisionSnapshot.pipelineV2Enabled == true),
                    tostring(decisionSnapshot.pipelineV2FailedReason or "none"),
                    tostring(decisionSnapshot.pipelineV2FailClosed == true),
                    tonumber(decisionSnapshot.pipelineV2Candidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2Accepted) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2Finalists) or ZERO,
                    formatReasonCounts(decisionSnapshot.pipelineV2RejectedReasons),
                    tostring(decisionSnapshot.pipelineV2MidEnabled == true),
                    tostring(decisionSnapshot.pipelineV2MidFailedReason
                        or decisionSnapshot.pipelineV2MidSkippedReason
                        or "none"),
                    tostring(decisionSnapshot.pipelineV2MidFellThroughToTournament == true),
                    tonumber(decisionSnapshot.pipelineV2MidCandidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidAttackCandidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidPositionCandidates) or ZERO,
                    tostring(decisionSnapshot.midPositionMapEnabled == true),
                    tonumber(decisionSnapshot.midPositionMapCellCount) or ZERO,
                    formatReasonCounts(decisionSnapshot.midPositionMapStatusCounts),
                    formatValueList(decisionSnapshot.midPositionMapTopCells),
                    formatValueList(decisionSnapshot.midPositionMapContestedTop),
                    formatValueList(decisionSnapshot.midPositionMapAttackTargets),
                    formatValueList(decisionSnapshot.midPositionMapPositionTop),
                    tostring(decisionSnapshot.midPersonalityName or "none"),
                    tostring(decisionSnapshot.midPersonalityReference or "none"),
                    tostring(decisionSnapshot.midPersonalityLabel or "none"),
                    formatValueList(decisionSnapshot.midPersonalityTop),
                    formatValueList(decisionSnapshot.midPersonalityContestedTargets),
                    formatValueList(decisionSnapshot.midPersonalityAttackTargets),
                    formatValueList(decisionSnapshot.midPersonalityPositionTargets),
                    tonumber(decisionSnapshot.midTradeEvaluations) or ZERO,
                    tonumber(decisionSnapshot.midTradeAccepted) or ZERO,
                    tonumber(decisionSnapshot.midTradeRejected) or ZERO,
                    formatReasonCounts(decisionSnapshot.midTradeReasonCounts),
                    tostring(decisionSnapshot.midTradeLastReason or "none"),
                    tostring(decisionSnapshot.pipelineV2MidSelectedSource or "none"),
                    tostring(decisionSnapshot.pipelineV2MidSelectedTradeReason
                        or decisionSnapshot.pipelineV2MidSelectedAcceptReason
                        or "none"),
                    tonumber(decisionSnapshot.pipelineV2MidSelectedScore) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidGateExtraMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidRemainingBeforeGateMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidGateEvaluated) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidAccepted) or ZERO,
                    tostring(decisionSnapshot.pipelineV2MidGateSkippedByBudget == true),
                    tonumber(decisionSnapshot.pipelineV2MidAttackExtraMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidRemainingBeforeAttackMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidPositionExtraMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MidRemainingBeforePositionMs) or ZERO,
                    tostring(decisionSnapshot.pipelineV2FullTurnEnabled == true),
                    tonumber(decisionSnapshot.pipelineV2FullTurnInputCandidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnOutputCandidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnCompleted) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnDropped) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnSingleActionOutput) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnSecondScanned) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnMoveRiskPenalized) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnMoveRiskLethal) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnMoveRiskSuicidal) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FullTurnMoveRiskPenaltyMax) or ZERO,
                    formatReasonCounts(decisionSnapshot.pipelineV2FullTurnReasonCounts),
                    formatReasonCounts(decisionSnapshot.pipelineV2FullTurnDroppedReasons),
                    tostring(decisionSnapshot.pipelineV2EarlyGateEnabled == true),
                    tostring(decisionSnapshot.pipelineV2EarlyGatePath or "v2"),
                    tonumber(decisionSnapshot.pipelineV2EarlyGateChecks) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2EarlyGateAccepted) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2EarlyGateRejected) or ZERO,
                    formatReasonCounts(decisionSnapshot.pipelineV2EarlyGateRejectedReasons),
                    tostring(decisionSnapshot.pipelineV2EarlyGateFirstRejectedReason or "none"),
                    tonumber(decisionSnapshot.pipelineV2FinalistsExtraMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2RemainingBeforeFinalistsMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2FinalistsEvaluated) or ZERO,
                    tostring(decisionSnapshot.pipelineV2FinalistsSkippedByBudget == true),
                    tonumber(decisionSnapshot.pipelineV2PositionHints) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2PositionHintsEligible) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2PositionHintsSkippedShort) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2PositionHintsRanked) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionMapCellCount) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionMapLaneWidth) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionMapCenterlineBias) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionMapMainRouteSaturation) or ZERO,
                    formatReasonCounts(decisionSnapshot.earlyPositionMapStatusCounts),
                    formatValueList(decisionSnapshot.earlyPositionMapTopCells),
                    formatValueList(decisionSnapshot.earlyPositionMapOwnedUncovered),
                    tonumber(decisionSnapshot.earlyPositionFrontierPreTargetSuppressed) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionFrontierPreTargetSupport) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionFrontierPreTargetRear) or ZERO,
                    tostring(decisionSnapshot.earlyPositionFrontierProjectedEnabled == true),
                    tonumber(decisionSnapshot.earlyPositionFrontierProjectedConsidered) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionFrontierProjectedAnchors) or ZERO,
                    tonumber(decisionSnapshot.earlyPositionFrontierProjectedSuppressed) or ZERO,
                    tostring(decisionSnapshot.pipelineV2EarlySequencePrimary or "none"),
                    tostring(decisionSnapshot.pipelineV2DeployFirstCoverMode or "none"),
                    tostring(decisionSnapshot.pipelineV2DeployFirstContinuationMode or "none"),
                    tonumber(decisionSnapshot.pipelineV2DeployFirstContinuationCandidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstEarlySecondScanned) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskPenalized) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskLethal) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskSuicidal) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstEarlySecondMoveRiskPenaltyMax) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstDeployActions) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstCandidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstRealCoverChecks) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstRealCoverHits) or ZERO,
                    formatReasonCounts(decisionSnapshot.pipelineV2DeployFirstReasonCounts),
                    formatReasonCounts(decisionSnapshot.pipelineV2DeployFirstEarlySecondReasonCounts),
                    formatReasonCounts(decisionSnapshot.pipelineV2DeployFirstEarlySecondSkippedReasons),
                    formatValueList(decisionSnapshot.pipelineV2DeployFirstTop),
                    tonumber(decisionSnapshot.pipelineV2DeployFirstBudgetExtraMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstBudgetRemainingBeforeMs) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstBudgetUses) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2DeployFirstBudgetReturned) or ZERO,
                    tostring(decisionSnapshot.pipelineV2MovePositionCoverMode or "none"),
                    tonumber(decisionSnapshot.pipelineV2MovePositionActions) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MovePositionCandidates) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MovePositionRealCoverChecks) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2MovePositionRealCoverHits) or ZERO,
                    formatReasonCounts(decisionSnapshot.pipelineV2MovePositionReasonCounts),
                    formatReasonCounts(decisionSnapshot.pipelineV2MovePositionSkippedReasons),
                    formatValueList(decisionSnapshot.pipelineV2MovePositionTop),
                    tonumber(decisionSnapshot.movePatternPenalized) or ZERO,
                    tonumber(decisionSnapshot.movePatternPenaltyMax) or ZERO,
                    tonumber(decisionSnapshot.cloudstrikerMeleeContactPenalized) or ZERO,
                    tonumber(decisionSnapshot.cloudstrikerMeleeContactPenaltyMax) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2UnitPoolFreeUnits) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2UnitPoolLockedOccupants) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2UnitPoolLockedCoverUnits) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2UnitPoolReleasableOccupants) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2UnitPoolCoverTargets) or ZERO,
                    tonumber(decisionSnapshot.pipelineV2UnitPoolResolvedCells) or ZERO,
                    formatValueList(decisionSnapshot.pipelineV2UnitPoolFree),
                    formatValueList(decisionSnapshot.pipelineV2UnitPoolLockedOccupantsList),
                    formatValueList(decisionSnapshot.pipelineV2UnitPoolLockedCoverUnitsList),
                    formatValueList(decisionSnapshot.pipelineV2UnitPoolReleasableOccupantsList),
                    tonumber(decisionSnapshot.ownCandidates) or ZERO,
                    tonumber(decisionSnapshot.rankedCandidates) or ZERO,
                    tonumber(decisionSnapshot.evaluatedCandidates) or ZERO,
                    tonumber(decisionSnapshot.finalists) or ZERO,
                    tonumber(decisionSnapshot.replies) or ZERO,
                    tonumber(decisionSnapshot.replySkippedByBudget) or ZERO,
                    tonumber(decisionSnapshot.replyUsefulEvaluations) or ZERO,
                    tonumber(decisionSnapshot.replyNoScoreEvaluations) or ZERO,
                    tonumber(decisionSnapshot.replyCheapSafetyEvaluations) or ZERO,
                    formatReasonCounts(decisionSnapshot.replyQuestionCounts),
                    formatReasonCounts(decisionSnapshot.replyOutcomeCounts),
                    tonumber(decisionSnapshot.cacheHits) or ZERO,
                    tonumber(decisionSnapshot.cacheMisses) or ZERO,
                    tonumber(decisionSnapshot.cacheSimulationHits) or ZERO,
                    tonumber(decisionSnapshot.cacheSimulationMisses) or ZERO,
                    tonumber(decisionSnapshot.cacheFeatureHits) or ZERO,
                    tonumber(decisionSnapshot.cacheFeatureMisses) or ZERO,
                    tonumber(decisionSnapshot.cacheLegalHits) or ZERO,
                    tonumber(decisionSnapshot.cacheLegalMisses) or ZERO,
                    tonumber(decisionSnapshot.cacheThreatHits) or ZERO,
                    tonumber(decisionSnapshot.cacheThreatMisses) or ZERO,
                    tonumber(decisionSnapshot.cacheSupplyHits) or ZERO,
                    tonumber(decisionSnapshot.cacheSupplyMisses) or ZERO,
                    tonumber(decisionSnapshot.cacheExtensionHits) or ZERO,
                    tonumber(decisionSnapshot.cacheExtensionMisses) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyBatches) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyCandidatesGenerated) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyCandidatesGeneratedMax) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyCandidatesSelected) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyScoredForSort) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyScoredWorst) or ZERO,
                    tonumber(decisionSnapshot.enemyReplySortStoppedByBudget) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyWorstStoppedByBudget) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyFirstActionPoolMax) or ZERO,
                    tonumber(decisionSnapshot.enemyReplySecondActionStates) or ZERO,
                    tonumber(decisionSnapshot.enemyReplySecondActionPoolTotal) or ZERO,
                    tonumber(decisionSnapshot.enemyReplySecondActionPoolMax) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyCacheHits) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyCacheMisses) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyDeployCandidates) or ZERO,
                    tonumber(decisionSnapshot.enemyDeployReplies) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyTacticalExtensionChecks) or ZERO,
                    tonumber(decisionSnapshot.enemyReplyTacticalExtensionUsed) or ZERO,
                    tonumber(decisionSnapshot.replyOwnUnitKills) or ZERO,
                    tonumber(decisionSnapshot.replyOwnUnitKillValue) or ZERO,
                    tonumber(decisionSnapshot.replyFreeUnitLossGuardHits) or ZERO,
                    tonumber(decisionSnapshot.replyFreeUnitLossGuardPenalty) or ZERO,
                    tonumber(decisionSnapshot.replyFreeUnitLossGuardMaxPenalty) or ZERO,
                    tonumber(decisionSnapshot.extensions) or ZERO,
                    tonumber(decisionSnapshot.extensionSkippedByBudget) or ZERO,
                    formatReasonCounts(decisionSnapshot.extensionQuestionCounts),
                    formatReasonCounts(decisionSnapshot.extensionOutcomeCounts),
                    tostring(decisionSnapshot.attackLossReason or "none"),
                    tostring(decisionSnapshot.selectedHasFactionAttack == true),
                    tostring(decisionSnapshot.selectedCombatClass or "none"),
                    tostring(decisionSnapshot.selectedCombatSafetyReason or "none"),
                    tonumber(decisionSnapshot.bestFactionAttackFastScore) or ZERO,
                    tonumber(decisionSnapshot.selectedFastScore) or ZERO,
                    tostring(decisionSnapshot.fallbackReason or "none"),
                    tostring(runtimeTag)
                )
            )

            logger.warn(
                "AI",
                string.format(
                        "AI_DECISION p=%s turn=%s mode=%s tPhase=%s/%s@%s:%s early=%s/%s lane=%s eForm=%.0f tactic=%s hardLock=%s/%s hardFill=%s hardReject=%s/%s hardRejectStage=%s hardFallback=%s hardRejectSeq=%s fullRepair=%.0f/%s reason=%s fallback=%s contract=%s sel=%s/%s/%s/%s/%s selAct=%s/%s selScore=%.0f/%.0f/%+.0f softDef=%s/%s/%+.0f/%s>%s/%s>%s preStage=%s preSel=%s/%s/%s/%s/%s preAct=%s/%s preScore=%.0f/%.0f/%+.0f preReply=%s/%s preExt=%s/%s src=%s>%s>%s replySel=%s/%s extSel=%s/%s cand=%.0f ranked=%.0f final=%.0f timeout=%s seq=%s rawSeq=%s sanitize=%.0f sanitizeReasons=%s rtSanReject=%s/%.0f/%s rtSanSeq=%s>%s hardRejectSanitize=%.0f hardRejectReasons=%s ms=%.1f cpuMs=%.1f rt=%s",
                    currentPlayer,
                    currentTurn,
                    currentMode,
                    tostring(decisionSnapshot.tournamentPhase or "unknown"),
                    tostring(decisionSnapshot.tournamentPhaseReason or "none"),
                    tostring(decisionSnapshot.tournamentPhaseEarlyReference or "base"),
                    tostring(decisionSnapshot.tournamentPhaseEarlyMax or "na"),
                    tostring(decisionSnapshot.earlyRole or "none"),
                    tostring(decisionSnapshot.earlyIntent or "none"),
                    tostring(decisionSnapshot.earlyFocalLane or "none"),
                    math.floor(tonumber(decisionSnapshot.earlyFormationScore) or ZERO),
                    tostring(decisionSnapshot.tacticalOverrideReason or "none"),
                    tostring(decisionSnapshot.hardSelectionLocked == true),
                    tostring(decisionSnapshot.hardSelectionReason or "none"),
                    tostring(decisionSnapshot.hardSelectionPrefixCompleted == true),
                    tostring(decisionSnapshot.hardSelectionRejected == true),
                    tostring(decisionSnapshot.hardSelectionRejectReason or "none"),
                    tostring(decisionSnapshot.hardSelectionRejectStage or "none"),
                    tostring(decisionSnapshot.hardSelectionFallbackPath or "none"),
                    tostring(decisionSnapshot.hardSelectionRejectSignature or "none"),
                    tonumber(decisionSnapshot.mandatoryFullTurnRepair) or ZERO,
                    tostring(decisionSnapshot.mandatoryFullTurnRepairReplacement
                        or decisionSnapshot.mandatoryFullTurnRepairReason
                        or "none"),
                    tournamentReason,
                    tostring(decisionSnapshot.fallbackReason or "none"),
                    selectedContract,
                    tostring(decisionSnapshot.selectedCandidateSource or "none"),
                    tostring(decisionSnapshot.selectedCandidateLane or "none"),
                    tostring(decisionSnapshot.selectedEarlyPositionReason or "none"),
                    tostring(decisionSnapshot.selectedEarlyPositionTarget or "none"),
                    tostring(decisionSnapshot.selectedMatchesBestSoFar == true),
                    tostring(decisionSnapshot.selectedContainsDeploy == true),
                    tostring(decisionSnapshot.selectedContainsAttack == true),
                    tonumber(decisionSnapshot.selectedFastScore) or ZERO,
                    tonumber(decisionSnapshot.selectedFinalScore) or ZERO,
                    tonumber(decisionSnapshot.selectedScoreDelta) or ZERO,
                    tostring(decisionSnapshot.selectedSoftDefensePressure == true),
                    tostring(decisionSnapshot.selectedSoftDefensePressureReason or "none"),
                    tonumber(decisionSnapshot.selectedSoftDefensePressureNet) or ZERO,
                    tostring(decisionSnapshot.selectedSoftDefensePressureBeforeDamage or ZERO),
                    tostring(decisionSnapshot.selectedSoftDefensePressureAfterDamage or ZERO),
                    tostring(decisionSnapshot.selectedSoftDefensePressureBeforeAttackers or ZERO),
                    tostring(decisionSnapshot.selectedSoftDefensePressureAfterAttackers or ZERO),
                    tostring(decisionSnapshot.preSanitizeSelectedStage or "none"),
                    tostring(decisionSnapshot.preSanitizeCandidateSource or "none"),
                    tostring(decisionSnapshot.preSanitizeCandidateLane or "none"),
                    tostring(decisionSnapshot.preSanitizeEarlyPositionReason or "none"),
                    tostring(decisionSnapshot.preSanitizeEarlyPositionTarget or "none"),
                    tostring(decisionSnapshot.preSanitizeMatchesBestSoFar == true),
                    tostring(decisionSnapshot.preSanitizeContainsDeploy == true),
                    tostring(decisionSnapshot.preSanitizeContainsAttack == true),
                    tonumber(decisionSnapshot.preSanitizeFastScore) or ZERO,
                    tonumber(decisionSnapshot.preSanitizeFinalScore) or ZERO,
                    tonumber(decisionSnapshot.preSanitizeScoreDelta) or ZERO,
                    tostring(decisionSnapshot.preSanitizeReplyQuestion or "none"),
                    tostring(decisionSnapshot.preSanitizeReplyOutcome or "none"),
                    tostring(decisionSnapshot.preSanitizeExtensionQuestion or "none"),
                    tostring(decisionSnapshot.preSanitizeExtensionOutcome or "none"),
                    formatReasonCounts(decisionSnapshot.rankedSourceCountsBeforeGate),
                    formatReasonCounts(decisionSnapshot.rankedSourceCountsAfterGate),
                    formatReasonCounts(decisionSnapshot.finalistSourceCounts),
                    tostring(decisionSnapshot.selectedReplyQuestion or "none"),
                    tostring(decisionSnapshot.selectedReplyOutcome or "none"),
                    tostring(decisionSnapshot.selectedExtensionQuestion or "none"),
                    tostring(decisionSnapshot.selectedExtensionOutcome or "none"),
                    tonumber(decisionSnapshot.ownCandidates) or ZERO,
                    tonumber(decisionSnapshot.rankedCandidates) or ZERO,
                    tonumber(decisionSnapshot.finalists) or ZERO,
                    tostring(decisionSnapshot.timeout == true),
                    tostring(decisionSnapshot.sequenceSignature or ""),
                    tostring(decisionSnapshot.rawSequenceSignature or decisionSnapshot.sequenceSignature or ""),
                    tonumber(decisionSnapshot.sanitizerReplacements) or ZERO,
                    formatReasonCounts(decisionSnapshot.sanitizerReasonCounts),
                    tostring(decisionSnapshot.runtimeSanitizerRejected == true),
                    tonumber(decisionSnapshot.runtimeSanitizerRejectReplacements) or ZERO,
                    formatReasonCounts(decisionSnapshot.runtimeSanitizerRejectReasonCounts),
                    tostring(decisionSnapshot.runtimeSanitizerRejectRawSignature or "none"),
                    tostring(decisionSnapshot.runtimeSanitizerRejectSanitizedSignature or "none"),
                    tonumber(decisionSnapshot.hardSelectionRejectSanitizerReplacements) or ZERO,
                    formatReasonCounts(decisionSnapshot.hardSelectionRejectSanitizerReasonCounts),
                    tonumber(decisionSnapshot.elapsedMs) or 0,
                    tonumber(decisionSnapshot.tournamentComputeMs or decisionSnapshot.elapsedMs) or 0,
                    tostring(runtimeTag)
                )
            )

            if decisionSnapshot.earlyDiagnosticsEnabled == true then
                logger.warn(
                    "AI",
                    string.format(
                        "AI_EARLY_DIAG p=%s turn=%s mode=%s phase=%s early=%s/%s source=%s rankMode=%s productive=%s/%s/%s/%s first=%s/%s cap=%s secondStates=%s secondLegal=%s/%s secondBeam=%s/%s cand=%s/%s rankedGate=%s/%s audit=%s auditCand=%s auditRanked=%s auditGate=%s/%s outside=%s found=%s auditReason=%s auditReasons=%s auditMs=%.1f auditErr=%s reply=%s/%s/%s/%s ext=%s/%s rt=%s",
                        currentPlayer,
                        currentTurn,
                        currentMode,
                        tostring(decisionSnapshot.tournamentPhase or "unknown"),
                        tostring(decisionSnapshot.earlyRole or "none"),
                        tostring(decisionSnapshot.earlyIntent or "none"),
                        tostring(decisionSnapshot.earlyDiagSource or "none"),
                        tostring(decisionSnapshot.earlyDiagFirstRankMode or "none"),
                        tostring(decisionSnapshot.earlyProductiveEnumerationEnabled == true),
                        tostring(decisionSnapshot.earlyProductiveFirstPrepared or ZERO),
                        tostring(decisionSnapshot.earlyProductiveFirstShortlisted or ZERO),
                        tostring(decisionSnapshot.earlyProductiveFirstSelected or ZERO),
                        tostring(decisionSnapshot.earlyDiagFirstBeamSelected or ZERO),
                        tostring(decisionSnapshot.earlyDiagFirstLegalActions or ZERO),
                        tostring(decisionSnapshot.earlyDiagFirstBeamCap or ZERO),
                        tostring(decisionSnapshot.earlyDiagSecondStates or ZERO),
                        tostring(decisionSnapshot.earlyDiagSecondLegalActionsTotal or ZERO),
                        tostring(decisionSnapshot.earlyDiagSecondLegalActionsMax or ZERO),
                        tostring(decisionSnapshot.earlyDiagSecondBeamSelectedTotal or ZERO),
                        tostring(decisionSnapshot.earlyDiagSecondBeamSelectedMax or ZERO),
                        tostring(decisionSnapshot.earlyDiagFullCandidatesGeneratedBeforeFallback or ZERO),
                        tostring(decisionSnapshot.earlyDiagFullCandidatesReturned or ZERO),
                        tostring(decisionSnapshot.earlyDiagNormalRankedBeforeGate or ZERO),
                        tostring(decisionSnapshot.earlyDiagNormalGateKept or ZERO),
                        tostring(decisionSnapshot.earlyDiagAuditEnabled == true),
                        tostring(decisionSnapshot.earlyDiagAuditCandidates or ZERO),
                        tostring(decisionSnapshot.earlyDiagAuditRanked or ZERO),
                        tostring(decisionSnapshot.earlyDiagAuditGateKept or ZERO),
                        tostring(decisionSnapshot.earlyDiagAuditGateRejected or ZERO),
                        tostring(decisionSnapshot.earlyDiagAuditGateKeptOutsideNormal or ZERO),
                        tostring(decisionSnapshot.earlyDiagAuditFoundGateKept == true),
                        tostring(decisionSnapshot.earlyDiagAuditFirstReason or "none"),
                        formatReasonCounts(decisionSnapshot.earlyDiagAuditReasonCounts),
                        tonumber(decisionSnapshot.earlyDiagAuditMs) or ZERO,
                        tostring(decisionSnapshot.earlyDiagAuditError or "none"),
                        tostring(decisionSnapshot.replies or ZERO),
                        tostring(decisionSnapshot.replySkippedByBudget or ZERO),
                        tostring(decisionSnapshot.replyUsefulEvaluations or ZERO),
                        tostring(decisionSnapshot.replyCheapSafetyEvaluations or ZERO),
                        tostring(decisionSnapshot.extensions or ZERO),
                        tostring(decisionSnapshot.extensionSkippedByBudget or ZERO),
                        tostring(runtimeTag)
                    )
                )
            end
        end

        local function commitDecisionSnapshot(sequence)
            decisionSnapshot.sequenceSignature = self:buildActionSequenceSignature(sequence or {})
            decisionSnapshot.elapsedMs = getElapsedMs()
            self._lastDecisionSource = {
                tournamentAttempted = decisionSnapshot.tournamentAttempted == true,
                tournamentAccepted = decisionSnapshot.tournamentAccepted == true,
                decisionSource = tostring(decisionSnapshot.decisionSource or "tournament"),
                selectedContract = decisionSnapshot.selectedContract,
                activeContracts = copyReasonCounts(decisionSnapshot.activeContracts),
                tournamentReason = decisionSnapshot.tournamentReason,
                fallbackReason = decisionSnapshot.fallbackReason,
                sanitizerReplacements = tonumber(decisionSnapshot.sanitizerReplacements) or ZERO,
                sanitizerReasonCounts = copyReasonCounts(decisionSnapshot.sanitizerReasonCounts),
                runtimeSanitizerRejected = decisionSnapshot.runtimeSanitizerRejected == true,
                runtimeSanitizerRejectReason = decisionSnapshot.runtimeSanitizerRejectReason,
                runtimeSanitizerRejectReplacements =
                    tonumber(decisionSnapshot.runtimeSanitizerRejectReplacements) or ZERO,
                runtimeSanitizerRejectReasonCounts =
                    copyReasonCounts(decisionSnapshot.runtimeSanitizerRejectReasonCounts),
                rawSequenceSignature = decisionSnapshot.rawSequenceSignature,
                sanitizedSequenceSignature = decisionSnapshot.sequenceSignature,
                ownCandidates = tonumber(decisionSnapshot.ownCandidates) or ZERO,
                rankedCandidates = tonumber(decisionSnapshot.rankedCandidates) or ZERO,
                finalists = tonumber(decisionSnapshot.finalists) or ZERO,
                rankedSourceCountsBeforeGate =
                    copyReasonCounts(decisionSnapshot.rankedSourceCountsBeforeGate),
                rankedSourceCountsAfterGate =
                    copyReasonCounts(decisionSnapshot.rankedSourceCountsAfterGate),
                finalistSourceCounts = copyReasonCounts(decisionSnapshot.finalistSourceCounts),
                replies = tonumber(decisionSnapshot.replies) or ZERO,
                extensions = tonumber(decisionSnapshot.extensions) or ZERO,
                replySkippedByBudget = tonumber(decisionSnapshot.replySkippedByBudget) or ZERO,
                extensionSkippedByBudget = tonumber(decisionSnapshot.extensionSkippedByBudget) or ZERO,
                cooperativeYields = tonumber(decisionSnapshot.cooperativeYields) or ZERO,
                legalAttackActions = tonumber(decisionSnapshot.legalAttackActions) or ZERO,
                legalMoveAttackActions = tonumber(decisionSnapshot.legalMoveAttackActions) or ZERO,
                defenseKind = decisionSnapshot.defenseKind,
                directThreatAttackActions = tonumber(decisionSnapshot.directThreatAttackActions) or ZERO,
                directThreatReductionActions = tonumber(decisionSnapshot.directThreatReductionActions) or ZERO,
                moveThreatAttackActions = tonumber(decisionSnapshot.moveThreatAttackActions) or ZERO,
                ownCommandantProjectedThreatDamage = tonumber(decisionSnapshot.ownCommandantProjectedThreatDamage) or ZERO,
                candidateWithFactionAttack = tonumber(decisionSnapshot.candidateWithFactionAttack) or ZERO,
                rankedWithFactionAttack = tonumber(decisionSnapshot.rankedWithFactionAttack) or ZERO,
                finalistWithFactionAttack = tonumber(decisionSnapshot.finalistWithFactionAttack) or ZERO,
                selectedHasFactionAttack = decisionSnapshot.selectedHasFactionAttack == true,
                selectedPassiveOnly = decisionSnapshot.selectedPassiveOnly == true,
                selectedFactionAttackCount = tonumber(decisionSnapshot.selectedFactionAttackCount) or ZERO,
                selectedMeleeFactionAttackCount = tonumber(decisionSnapshot.selectedMeleeFactionAttackCount) or ZERO,
                selectedRangedFactionAttackCount = tonumber(decisionSnapshot.selectedRangedFactionAttackCount) or ZERO,
                selectedCombatClass = decisionSnapshot.selectedCombatClass,
                selectedCombatSafetyReason = decisionSnapshot.selectedCombatSafetyReason,
                selectedFinalScore = tonumber(decisionSnapshot.selectedFinalScore) or ZERO,
                selectedScoreDelta = tonumber(decisionSnapshot.selectedScoreDelta) or ZERO,
                selectedCandidateSource = decisionSnapshot.selectedCandidateSource,
                selectedCandidateLane = decisionSnapshot.selectedCandidateLane,
                selectedRequiredLane = decisionSnapshot.selectedRequiredLane == true,
                selectedEarlyPositionReason = decisionSnapshot.selectedEarlyPositionReason,
                selectedEarlyPositionTarget = decisionSnapshot.selectedEarlyPositionTarget,
                selectedContainsDeploy = decisionSnapshot.selectedContainsDeploy == true,
                selectedContainsAttack = decisionSnapshot.selectedContainsAttack == true,
                selectedReplyQuestion = decisionSnapshot.selectedReplyQuestion,
                selectedReplyOutcome = decisionSnapshot.selectedReplyOutcome,
                selectedExtensionQuestion = decisionSnapshot.selectedExtensionQuestion,
                selectedExtensionOutcome = decisionSnapshot.selectedExtensionOutcome,
                selectedMatchesBestSoFar = decisionSnapshot.selectedMatchesBestSoFar == true,
                preSanitizeSelectedStage = decisionSnapshot.preSanitizeSelectedStage,
                preSanitizeSelectedSignature = decisionSnapshot.preSanitizeSelectedSignature,
                preSanitizeCandidateSource = decisionSnapshot.preSanitizeCandidateSource,
                preSanitizeCandidateLane = decisionSnapshot.preSanitizeCandidateLane,
                preSanitizeRequiredLane = decisionSnapshot.preSanitizeRequiredLane == true,
                preSanitizeEarlyPositionReason = decisionSnapshot.preSanitizeEarlyPositionReason,
                preSanitizeEarlyPositionTarget = decisionSnapshot.preSanitizeEarlyPositionTarget,
                preSanitizeContainsDeploy = decisionSnapshot.preSanitizeContainsDeploy == true,
                preSanitizeContainsAttack = decisionSnapshot.preSanitizeContainsAttack == true,
                preSanitizeFastScore = tonumber(decisionSnapshot.preSanitizeFastScore) or ZERO,
                preSanitizeFinalScore = tonumber(decisionSnapshot.preSanitizeFinalScore) or ZERO,
                preSanitizeScoreDelta = tonumber(decisionSnapshot.preSanitizeScoreDelta) or ZERO,
                preSanitizeReplyQuestion = decisionSnapshot.preSanitizeReplyQuestion,
                preSanitizeReplyOutcome = decisionSnapshot.preSanitizeReplyOutcome,
                preSanitizeExtensionQuestion = decisionSnapshot.preSanitizeExtensionQuestion,
                preSanitizeExtensionOutcome = decisionSnapshot.preSanitizeExtensionOutcome,
                preSanitizeMatchesBestSoFar = decisionSnapshot.preSanitizeMatchesBestSoFar == true,
                bestFactionAttackFastScore = tonumber(decisionSnapshot.bestFactionAttackFastScore) or ZERO,
                selectedFastScore = tonumber(decisionSnapshot.selectedFastScore) or ZERO,
                attackLossReason = decisionSnapshot.attackLossReason,
                safeCombatAvailable = decisionSnapshot.safeCombatAvailable == true,
                bestSafeCombatClass = decisionSnapshot.bestSafeCombatClass,
                bestSafeCombatSignature = decisionSnapshot.bestSafeCombatSignature,
                bestSafeCombatDamage = tonumber(decisionSnapshot.bestSafeCombatDamage) or ZERO,
                bestSafeCombatKills = tonumber(decisionSnapshot.bestSafeCombatKills) or ZERO,
                bestSafeCombatTargetValue = tonumber(decisionSnapshot.bestSafeCombatTargetValue) or ZERO,
                tournamentPhase = decisionSnapshot.tournamentPhase,
                tournamentPhaseTurn = decisionSnapshot.tournamentPhaseTurn,
                tournamentPhaseReason = decisionSnapshot.tournamentPhaseReason,
                tournamentPhaseEarlyMax = decisionSnapshot.tournamentPhaseEarlyMax,
                tournamentPhaseEarlyReference = decisionSnapshot.tournamentPhaseEarlyReference,
                earlyPlanActive = decisionSnapshot.earlyPlanActive == true,
                earlyRole = decisionSnapshot.earlyRole,
                earlyIntent = decisionSnapshot.earlyIntent,
                earlyConfidence = tonumber(decisionSnapshot.earlyConfidence) or ZERO,
                earlyFocalLane = decisionSnapshot.earlyFocalLane,
                earlySupportLane = decisionSnapshot.earlySupportLane,
                earlyFormationScore = tonumber(decisionSnapshot.earlyFormationScore) or ZERO,
                earlyFormationReasons = copyReasonCounts(decisionSnapshot.earlyFormationReasons),
                tacticalOverrideReason = decisionSnapshot.tacticalOverrideReason,
                pipelineV2MidEnabled = decisionSnapshot.pipelineV2MidEnabled == true,
                pipelineV2MidAttempted = decisionSnapshot.pipelineV2MidAttempted == true,
                pipelineV2MidSkipped = decisionSnapshot.pipelineV2MidSkipped == true,
                pipelineV2MidSkippedReason = decisionSnapshot.pipelineV2MidSkippedReason,
                pipelineV2MidFailedReason = decisionSnapshot.pipelineV2MidFailedReason,
                pipelineV2MidFellThroughToTournament =
                    decisionSnapshot.pipelineV2MidFellThroughToTournament == true,
                pipelineV2MidCandidates = tonumber(decisionSnapshot.pipelineV2MidCandidates) or ZERO,
                pipelineV2MidAttackCandidates = tonumber(decisionSnapshot.pipelineV2MidAttackCandidates) or ZERO,
                pipelineV2MidPositionCandidates = tonumber(decisionSnapshot.pipelineV2MidPositionCandidates) or ZERO,
                pipelineV2MidFinalists = tonumber(decisionSnapshot.pipelineV2MidFinalists) or ZERO,
                midPositionMapEnabled = decisionSnapshot.midPositionMapEnabled == true,
                midPositionMapCellCount = tonumber(decisionSnapshot.midPositionMapCellCount) or ZERO,
                midPositionMapTopCells = decisionSnapshot.midPositionMapTopCells or {},
                midPositionMapContestedTop = decisionSnapshot.midPositionMapContestedTop or {},
                midPositionMapPressureTop = decisionSnapshot.midPositionMapPressureTop or {},
                midPositionMapTradeTop = decisionSnapshot.midPositionMapTradeTop or {},
                midPositionMapAttackTargets = decisionSnapshot.midPositionMapAttackTargets or {},
                midPositionMapPositionTop = decisionSnapshot.midPositionMapPositionTop or {},
                midPositionMapStatusCounts = copyReasonCounts(decisionSnapshot.midPositionMapStatusCounts or {}),
                midPersonalityName = decisionSnapshot.midPersonalityName,
                midPersonalityReference = decisionSnapshot.midPersonalityReference,
                midPersonalityLabel = decisionSnapshot.midPersonalityLabel,
                midPersonalityTop = decisionSnapshot.midPersonalityTop or {},
                midPersonalityAttackTargets = decisionSnapshot.midPersonalityAttackTargets or {},
                midPersonalityPositionTargets = decisionSnapshot.midPersonalityPositionTargets or {},
                midPersonalityContestedTargets = decisionSnapshot.midPersonalityContestedTargets or {},
                midPersonalityTradeTargets = decisionSnapshot.midPersonalityTradeTargets or {},
                earlyAttackCommitmentReason = decisionSnapshot.earlyAttackCommitmentReason,
                earlyAttackCommitmentRejected = decisionSnapshot.earlyAttackCommitmentRejected == true,
                earlyAttackCommitmentReplacement = decisionSnapshot.earlyAttackCommitmentReplacement,
                earlyAttackCommitmentMaterialGain = tonumber(decisionSnapshot.earlyAttackCommitmentMaterialGain) or ZERO,
                earlyAttackCommitmentBoardDelta = tonumber(decisionSnapshot.earlyAttackCommitmentBoardDelta) or ZERO,
                drawStreak = tonumber(decisionSnapshot.drawStreak) or ZERO,
                drawUrgencyActive = decisionSnapshot.drawUrgencyActive == true,
                drawUrgency = tonumber(decisionSnapshot.drawUrgency) or ZERO,
                drawConversionOpportunity = decisionSnapshot.drawConversionOpportunity == true,
                drawConversionChosen = decisionSnapshot.drawConversionChosen == true,
                drawConversionMissReason = decisionSnapshot.drawConversionMissReason,
                kernelAvailable = decisionSnapshot.kernelAvailable == true,
                kernelReason = decisionSnapshot.kernelReason,
                kernelSource = decisionSnapshot.kernelSource,
                combatContractActive = decisionSnapshot.combatContractActive == true,
                combatDirectGenerated = tonumber(decisionSnapshot.combatDirectGenerated) or ZERO,
                combatMoveAttackGenerated = tonumber(decisionSnapshot.combatMoveAttackGenerated) or ZERO,
                combatRanked = tonumber(decisionSnapshot.combatRanked) or ZERO,
                combatFinalists = tonumber(decisionSnapshot.combatFinalists) or ZERO,
                combatSelected = tonumber(decisionSnapshot.combatSelected) or ZERO,
                combatSkippedWithProof = tonumber(decisionSnapshot.combatSkippedWithProof) or ZERO,
                combatSkippedWithoutProof = tonumber(decisionSnapshot.combatSkippedWithoutProof) or ZERO,
                conversionContractActive = decisionSnapshot.conversionContractActive == true,
                conversionContracts = copyReasonCounts(decisionSnapshot.conversionContracts),
                conversionMaterialDiff = tonumber(decisionSnapshot.conversionMaterialDiff) or ZERO,
                conversionOwnUnits = tonumber(decisionSnapshot.conversionOwnUnits) or ZERO,
                conversionEnemyUnits = tonumber(decisionSnapshot.conversionEnemyUnits) or ZERO,
                conversionOwnHubHp = tonumber(decisionSnapshot.conversionOwnHubHp) or ZERO,
                conversionEnemyHubHp = tonumber(decisionSnapshot.conversionEnemyHubHp) or ZERO,
                conversionCommandantPressure = tonumber(decisionSnapshot.conversionCommandantPressure) or ZERO,
                selectedCommandantDamage = tonumber(decisionSnapshot.selectedCommandantDamage) or ZERO,
                selectedKillCount = tonumber(decisionSnapshot.selectedKillCount) or ZERO,
                selectedCreatesNextTurnCommandantLethal = decisionSnapshot.selectedCreatesNextTurnCommandantLethal == true,
                selectedRemovesEnemyLastAttacker = decisionSnapshot.selectedRemovesEnemyLastAttacker == true,
                passiveOverrideReason = decisionSnapshot.passiveOverrideReason,
                selectedProofReason = decisionSnapshot.selectedProofReason,
                passiveOverrideAllowed = decisionSnapshot.passiveOverrideAllowed == true,
                hardSelectionLocked = decisionSnapshot.hardSelectionLocked == true,
                hardSelectionRejected = decisionSnapshot.hardSelectionRejected == true,
                hardSelectionReason = decisionSnapshot.hardSelectionReason,
                hardSelectionSignature = decisionSnapshot.hardSelectionSignature,
                hardSelectionPrefixCompleted = decisionSnapshot.hardSelectionPrefixCompleted == true,
                hardSelectionPrefixSignature = decisionSnapshot.hardSelectionPrefixSignature,
                hardSelectionCompletedSignature = decisionSnapshot.hardSelectionCompletedSignature,
                hardSelectionRejectReason = decisionSnapshot.hardSelectionRejectReason,
                hardSelectionRejectStage = decisionSnapshot.hardSelectionRejectStage,
                hardSelectionRejectSignature = decisionSnapshot.hardSelectionRejectSignature,
                hardSelectionRejectSanitizerReplacements =
                    tonumber(decisionSnapshot.hardSelectionRejectSanitizerReplacements) or ZERO,
                hardSelectionRejectSanitizerReasonCounts =
                    copyReasonCounts(decisionSnapshot.hardSelectionRejectSanitizerReasonCounts),
                hardSelectionFallbackPath = decisionSnapshot.hardSelectionFallbackPath,
                runtimeSanitizerRejectRawSignature =
                    decisionSnapshot.runtimeSanitizerRejectRawSignature,
                runtimeSanitizerRejectSanitizedSignature =
                    decisionSnapshot.runtimeSanitizerRejectSanitizedSignature,
                stageMs = copyNumericMap(decisionSnapshot.stageMs),
                timeout = decisionSnapshot.timeout == true,
                sequenceSignature = decisionSnapshot.sequenceSignature,
                elapsedMs = decisionSnapshot.elapsedMs
            }

            if decisionSnapshot.tournamentAttempted then
                local meta = self.lastTournamentMeta
                if type(meta) ~= "table" then
                    meta = {
                        source = "tournament"
                    }
                end
                meta.stats = meta.stats or {}
                meta.stats.ownCandidates = decisionSnapshot.ownCandidates
                meta.stats.ranked = decisionSnapshot.rankedCandidates
                meta.stats.finalists = decisionSnapshot.finalists
                meta.stats.evaluatedCandidates = decisionSnapshot.evaluatedCandidates
                meta.stats.bestSoFarAvailable = decisionSnapshot.bestSoFarAvailable == true
                meta.stats.bestSoFarSource = decisionSnapshot.bestSoFarSource
                meta.stats.bestSoFarSignature = decisionSnapshot.bestSoFarSignature
                meta.stats.coreExit = decisionSnapshot.coreExit
                meta.stats.fallbackSource = decisionSnapshot.fallbackSource
                meta.stats.primaryTournamentCaptured = decisionSnapshot.primaryTournamentCaptured == true
                meta.stats.primaryTournamentTrigger = decisionSnapshot.primaryTournamentTrigger
                meta.stats.primaryTournamentReason = decisionSnapshot.primaryTournamentReason
                meta.stats.primaryFallbackReason = decisionSnapshot.primaryFallbackReason
                meta.stats.primaryCoreExit = decisionSnapshot.primaryCoreExit
                meta.stats.primaryFallbackSource = decisionSnapshot.primaryFallbackSource
                meta.stats.primaryOwnCandidates = decisionSnapshot.primaryOwnCandidates
                meta.stats.primaryRankedCandidates = decisionSnapshot.primaryRankedCandidates
                meta.stats.primaryFinalists = decisionSnapshot.primaryFinalists
                meta.stats.primaryEvaluatedCandidates = decisionSnapshot.primaryEvaluatedCandidates
                meta.stats.primaryTimeout = decisionSnapshot.primaryTimeout == true
                meta.stats.cooperativeYields = decisionSnapshot.cooperativeYields
                meta.stats.replyEvaluations = decisionSnapshot.replies
                meta.stats.extensionEvaluations = decisionSnapshot.extensions
                meta.stats.replySkippedByBudget = decisionSnapshot.replySkippedByBudget
                meta.stats.extensionSkippedByBudget = decisionSnapshot.extensionSkippedByBudget
                meta.stats.stageMs = copyNumericMap(decisionSnapshot.stageMs)
                meta.stats.timeout = decisionSnapshot.timeout == true
                meta.stats.phase = decisionSnapshot.tournamentPhase
                meta.stats.phaseTurn = decisionSnapshot.tournamentPhaseTurn
                meta.stats.phaseReason = decisionSnapshot.tournamentPhaseReason
                meta.stats.phaseEarlyMax = decisionSnapshot.tournamentPhaseEarlyMax
                meta.stats.phaseEarlyReference = decisionSnapshot.tournamentPhaseEarlyReference
                meta.stats.earlyPlanActive = decisionSnapshot.earlyPlanActive == true
                meta.stats.earlyRole = decisionSnapshot.earlyRole
                meta.stats.earlyIntent = decisionSnapshot.earlyIntent
                meta.stats.earlyConfidence = decisionSnapshot.earlyConfidence
                meta.stats.earlyFocalLane = decisionSnapshot.earlyFocalLane
                meta.stats.earlySupportLane = decisionSnapshot.earlySupportLane
                meta.stats.earlyFormationScore = decisionSnapshot.earlyFormationScore
                meta.stats.earlyFormationReasons = copyReasonCounts(decisionSnapshot.earlyFormationReasons)
                meta.stats.tacticalOverrideReason = decisionSnapshot.tacticalOverrideReason
                meta.stats.mandatoryCompletionSkippedByBudget =
                    tonumber(decisionSnapshot.mandatoryCompletionSkippedByBudget) or ZERO
                meta.stats.pipelineV2MidEnabled = decisionSnapshot.pipelineV2MidEnabled == true
                meta.stats.pipelineV2MidAttempted = decisionSnapshot.pipelineV2MidAttempted == true
                meta.stats.pipelineV2MidSkipped = decisionSnapshot.pipelineV2MidSkipped == true
                meta.stats.pipelineV2MidSkippedReason = decisionSnapshot.pipelineV2MidSkippedReason
                meta.stats.pipelineV2MidFailedReason = decisionSnapshot.pipelineV2MidFailedReason
                meta.stats.pipelineV2MidFellThroughToTournament =
                    decisionSnapshot.pipelineV2MidFellThroughToTournament == true
                meta.stats.pipelineV2MidCandidates = decisionSnapshot.pipelineV2MidCandidates
                meta.stats.pipelineV2MidAttackCandidates = decisionSnapshot.pipelineV2MidAttackCandidates
                meta.stats.pipelineV2MidPositionCandidates = decisionSnapshot.pipelineV2MidPositionCandidates
                meta.stats.pipelineV2MidFinalists = decisionSnapshot.pipelineV2MidFinalists
                meta.stats.midPositionMapEnabled = decisionSnapshot.midPositionMapEnabled == true
                meta.stats.midPositionMapCellCount = decisionSnapshot.midPositionMapCellCount
                meta.stats.midPositionMapTopCells = decisionSnapshot.midPositionMapTopCells or {}
                meta.stats.midPositionMapContestedTop = decisionSnapshot.midPositionMapContestedTop or {}
                meta.stats.midPositionMapPressureTop = decisionSnapshot.midPositionMapPressureTop or {}
                meta.stats.midPositionMapTradeTop = decisionSnapshot.midPositionMapTradeTop or {}
                meta.stats.midPositionMapAttackTargets = decisionSnapshot.midPositionMapAttackTargets or {}
                meta.stats.midPositionMapPositionTop = decisionSnapshot.midPositionMapPositionTop or {}
                meta.stats.midPositionMapStatusCounts =
                    copyReasonCounts(decisionSnapshot.midPositionMapStatusCounts or {})
                meta.stats.midPersonalityName = decisionSnapshot.midPersonalityName
                meta.stats.midPersonalityReference = decisionSnapshot.midPersonalityReference
                meta.stats.midPersonalityLabel = decisionSnapshot.midPersonalityLabel
                meta.stats.midPersonalityTop = decisionSnapshot.midPersonalityTop or {}
                meta.stats.midPersonalityAttackTargets = decisionSnapshot.midPersonalityAttackTargets or {}
                meta.stats.midPersonalityPositionTargets = decisionSnapshot.midPersonalityPositionTargets or {}
                meta.stats.midPersonalityContestedTargets = decisionSnapshot.midPersonalityContestedTargets or {}
                meta.stats.midPersonalityTradeTargets = decisionSnapshot.midPersonalityTradeTargets or {}
                meta.stats.earlyAttackCommitmentReason = decisionSnapshot.earlyAttackCommitmentReason
                meta.stats.earlyAttackCommitmentRejected = decisionSnapshot.earlyAttackCommitmentRejected == true
                meta.stats.earlyAttackCommitmentReplacement = decisionSnapshot.earlyAttackCommitmentReplacement
                meta.stats.earlyAttackCommitmentMaterialGain = decisionSnapshot.earlyAttackCommitmentMaterialGain
                meta.stats.earlyAttackCommitmentBoardDelta = decisionSnapshot.earlyAttackCommitmentBoardDelta
                meta.stats.legalAttackActions = decisionSnapshot.legalAttackActions
                meta.stats.legalMoveAttackActions = decisionSnapshot.legalMoveAttackActions
                meta.stats.defenseKind = decisionSnapshot.defenseKind
                meta.stats.directThreatAttackActions = decisionSnapshot.directThreatAttackActions
                meta.stats.directThreatReductionActions = decisionSnapshot.directThreatReductionActions
                meta.stats.moveThreatAttackActions = decisionSnapshot.moveThreatAttackActions
                meta.stats.ownCommandantProjectedThreatDamage = decisionSnapshot.ownCommandantProjectedThreatDamage
                meta.stats.candidateWithFactionAttack = decisionSnapshot.candidateWithFactionAttack
                meta.stats.rankedWithFactionAttack = decisionSnapshot.rankedWithFactionAttack
                meta.stats.finalistWithFactionAttack = decisionSnapshot.finalistWithFactionAttack
                meta.stats.rankedSourceCountsBeforeGate =
                    copyReasonCounts(decisionSnapshot.rankedSourceCountsBeforeGate)
                meta.stats.rankedSourceCountsAfterGate =
                    copyReasonCounts(decisionSnapshot.rankedSourceCountsAfterGate)
                meta.stats.finalistSourceCounts =
                    copyReasonCounts(decisionSnapshot.finalistSourceCounts)
                meta.stats.selectedHasFactionAttack = decisionSnapshot.selectedHasFactionAttack == true
                meta.stats.selectedPassiveOnly = decisionSnapshot.selectedPassiveOnly == true
                meta.stats.selectedFactionAttackCount = decisionSnapshot.selectedFactionAttackCount
                meta.stats.selectedMeleeFactionAttackCount = decisionSnapshot.selectedMeleeFactionAttackCount
                meta.stats.selectedRangedFactionAttackCount = decisionSnapshot.selectedRangedFactionAttackCount
                meta.stats.selectedCombatClass = decisionSnapshot.selectedCombatClass
                meta.stats.selectedCombatSafetyReason = decisionSnapshot.selectedCombatSafetyReason
                meta.stats.bestFactionAttackFastScore = decisionSnapshot.bestFactionAttackFastScore
                meta.stats.selectedFastScore = decisionSnapshot.selectedFastScore
                meta.stats.selectedFinalScore = decisionSnapshot.selectedFinalScore
                meta.stats.selectedScoreDelta = decisionSnapshot.selectedScoreDelta
                meta.stats.selectedCandidateSource = decisionSnapshot.selectedCandidateSource
                meta.stats.selectedCandidateLane = decisionSnapshot.selectedCandidateLane
                meta.stats.selectedRequiredLane = decisionSnapshot.selectedRequiredLane == true
                meta.stats.selectedEarlyPositionReason = decisionSnapshot.selectedEarlyPositionReason
                meta.stats.selectedEarlyPositionTarget = decisionSnapshot.selectedEarlyPositionTarget
                meta.stats.selectedContainsDeploy = decisionSnapshot.selectedContainsDeploy == true
                meta.stats.selectedContainsAttack = decisionSnapshot.selectedContainsAttack == true
                meta.stats.selectedReplyQuestion = decisionSnapshot.selectedReplyQuestion
                meta.stats.selectedReplyOutcome = decisionSnapshot.selectedReplyOutcome
                meta.stats.selectedExtensionQuestion = decisionSnapshot.selectedExtensionQuestion
                meta.stats.selectedExtensionOutcome = decisionSnapshot.selectedExtensionOutcome
                meta.stats.selectedMatchesBestSoFar = decisionSnapshot.selectedMatchesBestSoFar == true
                meta.stats.preSanitizeSelectedStage = decisionSnapshot.preSanitizeSelectedStage
                meta.stats.preSanitizeSelectedSignature = decisionSnapshot.preSanitizeSelectedSignature
                meta.stats.preSanitizeCandidateSource = decisionSnapshot.preSanitizeCandidateSource
                meta.stats.preSanitizeCandidateLane = decisionSnapshot.preSanitizeCandidateLane
                meta.stats.preSanitizeRequiredLane = decisionSnapshot.preSanitizeRequiredLane == true
                meta.stats.preSanitizeEarlyPositionReason = decisionSnapshot.preSanitizeEarlyPositionReason
                meta.stats.preSanitizeEarlyPositionTarget = decisionSnapshot.preSanitizeEarlyPositionTarget
                meta.stats.preSanitizeContainsDeploy = decisionSnapshot.preSanitizeContainsDeploy == true
                meta.stats.preSanitizeContainsAttack = decisionSnapshot.preSanitizeContainsAttack == true
                meta.stats.preSanitizeFastScore = decisionSnapshot.preSanitizeFastScore
                meta.stats.preSanitizeFinalScore = decisionSnapshot.preSanitizeFinalScore
                meta.stats.preSanitizeScoreDelta = decisionSnapshot.preSanitizeScoreDelta
                meta.stats.preSanitizeReplyQuestion = decisionSnapshot.preSanitizeReplyQuestion
                meta.stats.preSanitizeReplyOutcome = decisionSnapshot.preSanitizeReplyOutcome
                meta.stats.preSanitizeExtensionQuestion = decisionSnapshot.preSanitizeExtensionQuestion
                meta.stats.preSanitizeExtensionOutcome = decisionSnapshot.preSanitizeExtensionOutcome
                meta.stats.preSanitizeMatchesBestSoFar = decisionSnapshot.preSanitizeMatchesBestSoFar == true
                meta.stats.attackLossReason = decisionSnapshot.attackLossReason
                meta.stats.safeCombatAvailable = decisionSnapshot.safeCombatAvailable == true
                meta.stats.bestSafeCombatClass = decisionSnapshot.bestSafeCombatClass
                meta.stats.bestSafeCombatSignature = decisionSnapshot.bestSafeCombatSignature
                meta.stats.bestSafeCombatDamage = decisionSnapshot.bestSafeCombatDamage
                meta.stats.bestSafeCombatKills = decisionSnapshot.bestSafeCombatKills
                meta.stats.bestSafeCombatTargetValue = decisionSnapshot.bestSafeCombatTargetValue
                meta.stats.drawStreak = decisionSnapshot.drawStreak
                meta.stats.officialDrawUrgencyActive = decisionSnapshot.drawUrgencyActive == true
                meta.stats.officialDrawUrgency = decisionSnapshot.drawUrgency
                meta.stats.drawConversionOpportunity = decisionSnapshot.drawConversionOpportunity == true
                meta.stats.drawConversionChosen = decisionSnapshot.drawConversionChosen == true
                meta.stats.drawConversionMissReason = decisionSnapshot.drawConversionMissReason
                meta.stats.kernelAvailable = decisionSnapshot.kernelAvailable == true
                meta.stats.kernelReason = decisionSnapshot.kernelReason
                meta.stats.kernelSource = decisionSnapshot.kernelSource
                meta.stats.combatContractActive = decisionSnapshot.combatContractActive == true
                meta.stats.combatDirectGenerated = decisionSnapshot.combatDirectGenerated
                meta.stats.combatMoveAttackGenerated = decisionSnapshot.combatMoveAttackGenerated
                meta.stats.combatRanked = decisionSnapshot.combatRanked
                meta.stats.combatFinalists = decisionSnapshot.combatFinalists
                meta.stats.combatSelected = decisionSnapshot.combatSelected
                meta.stats.combatSkippedWithProof = decisionSnapshot.combatSkippedWithProof
                meta.stats.combatSkippedWithoutProof = decisionSnapshot.combatSkippedWithoutProof
                meta.stats.conversionContractActive = decisionSnapshot.conversionContractActive == true
                meta.stats.conversionContracts = copyReasonCounts(decisionSnapshot.conversionContracts)
                meta.stats.conversionMaterialDiff = decisionSnapshot.conversionMaterialDiff
                meta.stats.conversionOwnUnits = decisionSnapshot.conversionOwnUnits
                meta.stats.conversionEnemyUnits = decisionSnapshot.conversionEnemyUnits
                meta.stats.conversionOwnHubHp = decisionSnapshot.conversionOwnHubHp
                meta.stats.conversionEnemyHubHp = decisionSnapshot.conversionEnemyHubHp
                meta.stats.conversionCommandantPressure = decisionSnapshot.conversionCommandantPressure
                meta.stats.selectedCommandantDamage = decisionSnapshot.selectedCommandantDamage
                meta.stats.selectedKillCount = decisionSnapshot.selectedKillCount
                meta.stats.selectedCreatesNextTurnCommandantLethal = decisionSnapshot.selectedCreatesNextTurnCommandantLethal == true
                meta.stats.selectedRemovesEnemyLastAttacker = decisionSnapshot.selectedRemovesEnemyLastAttacker == true
                meta.stats.passiveOverrideReason = decisionSnapshot.passiveOverrideReason
                meta.stats.selectedProofReason = decisionSnapshot.selectedProofReason
                meta.stats.passiveOverrideAllowed = decisionSnapshot.passiveOverrideAllowed == true
                meta.stats.hardSelectionLocked = decisionSnapshot.hardSelectionLocked == true
                meta.stats.hardSelectionRejected = decisionSnapshot.hardSelectionRejected == true
                meta.stats.hardSelectionReason = decisionSnapshot.hardSelectionReason
                meta.stats.hardSelectionSignature = decisionSnapshot.hardSelectionSignature
                meta.stats.hardSelectionPrefixCompleted = decisionSnapshot.hardSelectionPrefixCompleted == true
                meta.stats.hardSelectionPrefixSignature = decisionSnapshot.hardSelectionPrefixSignature
                meta.stats.hardSelectionCompletedSignature = decisionSnapshot.hardSelectionCompletedSignature
                meta.stats.hardSelectionRejectReason = decisionSnapshot.hardSelectionRejectReason
                meta.stats.hardSelectionRejectStage = decisionSnapshot.hardSelectionRejectStage
                meta.stats.hardSelectionRejectSignature = decisionSnapshot.hardSelectionRejectSignature
                meta.stats.hardSelectionRejectSanitizerReplacements =
                    tonumber(decisionSnapshot.hardSelectionRejectSanitizerReplacements) or ZERO
                meta.stats.hardSelectionRejectSanitizerReasonCounts =
                    copyReasonCounts(decisionSnapshot.hardSelectionRejectSanitizerReasonCounts)
                meta.stats.hardSelectionFallbackPath = decisionSnapshot.hardSelectionFallbackPath
                meta.stats.runtimeSanitizerRejected = decisionSnapshot.runtimeSanitizerRejected == true
                meta.stats.runtimeSanitizerRejectReason = decisionSnapshot.runtimeSanitizerRejectReason
                meta.stats.runtimeSanitizerRejectReplacements =
                    tonumber(decisionSnapshot.runtimeSanitizerRejectReplacements) or ZERO
                meta.stats.runtimeSanitizerRejectReasonCounts =
                    copyReasonCounts(decisionSnapshot.runtimeSanitizerRejectReasonCounts)
                meta.stats.runtimeSanitizerRejectRawSignature =
                    decisionSnapshot.runtimeSanitizerRejectRawSignature
                meta.stats.runtimeSanitizerRejectSanitizedSignature =
                    decisionSnapshot.runtimeSanitizerRejectSanitizedSignature
                meta.tournamentAttempted = decisionSnapshot.tournamentAttempted == true
                meta.tournamentAccepted = decisionSnapshot.tournamentAccepted == true
                meta.decisionSource = decisionSnapshot.decisionSource
                meta.reason = decisionSnapshot.tournamentReason or meta.reason
                meta.contract = decisionSnapshot.selectedContract
                meta.contractEvidence = meta.contractEvidence or {}
                meta.contractEvidence.activeContracts = copyReasonCounts(decisionSnapshot.activeContracts)
                meta.contractEvidence.selectedProofReason = decisionSnapshot.selectedProofReason
                meta.contractEvidence.passiveOverride = meta.contractEvidence.passiveOverride or {}
                meta.contractEvidence.passiveOverride.allowed = decisionSnapshot.passiveOverrideAllowed == true
                meta.contractEvidence.passiveOverride.reason = decisionSnapshot.passiveOverrideReason
                meta.fallbackReason = decisionSnapshot.fallbackReason
                meta.sanitizerReplacements = tonumber(decisionSnapshot.sanitizerReplacements) or ZERO
                meta.sanitizerReasonCounts = copyReasonCounts(decisionSnapshot.sanitizerReasonCounts)
                meta.runtimeSanitizerRejected = decisionSnapshot.runtimeSanitizerRejected == true
                meta.runtimeSanitizerRejectReason = decisionSnapshot.runtimeSanitizerRejectReason
                meta.runtimeSanitizerRejectReplacements =
                    tonumber(decisionSnapshot.runtimeSanitizerRejectReplacements) or ZERO
                meta.runtimeSanitizerRejectReasonCounts =
                    copyReasonCounts(decisionSnapshot.runtimeSanitizerRejectReasonCounts)
                meta.sequenceSignature = decisionSnapshot.sequenceSignature
                meta.elapsedMs = decisionSnapshot.elapsedMs
                self.lastTournamentMeta = meta
            else
                -- Avoid stale Tournament metadata when no Tournament decision was produced.
                self.lastTournamentMeta = nil
            end

            emitRuntimeDecisionTrace()
        end

        local function finalizeDecisionLatency(sequence)
            if not decisionStartTime or not (love and love.timer and love.timer.getTime) then
                self._decisionGuardContext = nil
                self._referenceResolutionState = nil
                return
            end
            local wallElapsedMs = (love.timer.getTime() - decisionStartTime) * 1000
            local elapsedMs = getElapsedMs()
            self.lastDecisionLatencyMs = elapsedMs
            self.lastDecisionWallLatencyMs = wallElapsedMs
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
                    "Decision compute summary after %d decisions: median %.1fms, p95 %.1fms, budget %dms",
                    self.decisionCount,
                    medianMs,
                    p95Ms,
                    budgetMs
                ))
            end

            if elapsedMs > budgetMs or p95Ms > budgetMs then
                self:logDecision("Performance", string.format(
                    "Decision compute %.1fms (median %.1fms, p95 %.1fms) exceeded budget (%dms)",
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

        -- Validate state before processing
        if not state or not state.units then
            self.isProcessingTurn = false
            decisionSnapshot.decisionSource = "technical_safety_net"
            decisionSnapshot.fallbackReason = "invalid_state"
            commitDecisionSnapshot({})
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

        local tournamentEnabled = self.isTournamentAiEnabled and self:isTournamentAiEnabled()
        if tournamentEnabled then
            decisionSnapshot.tournamentAttempted = true
            decisionSnapshot.tournamentAccepted = false
            decisionSnapshot.decisionSource = "tournament"

            local tournamentBrain = require("ai_tournament.brain")
            local tournamentConfig = self.getTournamentConfig and self:getTournamentConfig() or {}
            local tournamentSequence, tournamentMeta = tournamentBrain.chooseTurn(self, state, {
                maxActions = maxActions,
                decisionStartTime = decisionStartTime,
                budgetMs = budgetMs,
                budgetElapsedMs = decisionOptions.budgetElapsedMs,
                cooperative = decisionOptions.cooperative == true,
                shouldYield = decisionOptions.shouldYield,
                softBudgetMs = decisionOptions.tournamentSoftBudgetMs,
                hardBudgetMs = decisionOptions.tournamentHardBudgetMs
            })

            self.lastTournamentMeta = tournamentMeta
            hydrateDecisionSnapshotFromTournamentMeta(tournamentMeta)

            if tournamentSequence and #tournamentSequence > ZERO then
                decisionSnapshot.rawSequenceSignature = self:buildActionSequenceSignature(tournamentSequence)
                local tournamentStats = tournamentMeta and tournamentMeta.stats or {}
                local allowZeroDamageDrawReset =
                    tournamentStats.pipelineV2MidSelectedAllowsZeroDamageDrawReset == true
                    or tournamentStats.pipelineV2EndSelectedAllowsZeroDamageDrawReset == true
                local sanitized, sanitizeSummary = self:sanitizeActionSequenceForState(state, tournamentSequence, {
                    aiPlayer = self:getFactionId(),
                    maxActions = maxActions,
                    allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true,
                    rejectZeroDamageFactionAttacks = not allowZeroDamageDrawReset
                })

                local replacements = sanitizeSummary and (sanitizeSummary.replacements or ZERO) or ZERO
                local requireSanitized = tournamentConfig.REQUIRE_SANITIZED_SEQUENCE == true
                local accepted = sanitized and #sanitized > ZERO
                decisionSnapshot.sanitizerReplacements = replacements
                decisionSnapshot.sanitizerReasonCounts = copyReasonCounts(
                    sanitizeSummary and sanitizeSummary.reasonCounts or {}
                )

                if accepted and replacements > ZERO then
                    if decisionSnapshot.hardSelectionLocked == true then
                        accepted = false
                        decisionSnapshot.hardSelectionRejected = true
                        decisionSnapshot.fallbackReason = "hard_selection_runtime_sanitize_rejected"
                        captureHardSelectionReject(
                            decisionSnapshot.fallbackReason,
                            "runtime_sanitizer",
                            decisionSnapshot.rawSequenceSignature,
                            sanitizeSummary
                        )
                        if tournamentMeta and tournamentMeta.stats then
                            tournamentMeta.stats.hardSelectionRejected = true
                            tournamentMeta.stats.hardSelectionRejectReason = decisionSnapshot.hardSelectionRejectReason
                            tournamentMeta.stats.hardSelectionRejectStage = decisionSnapshot.hardSelectionRejectStage
                            tournamentMeta.stats.hardSelectionRejectSignature = decisionSnapshot.hardSelectionRejectSignature
                            tournamentMeta.stats.hardSelectionRejectSanitizerReplacements =
                                decisionSnapshot.hardSelectionRejectSanitizerReplacements
                            tournamentMeta.stats.hardSelectionRejectSanitizerReasonCounts =
                                copyReasonCounts(decisionSnapshot.hardSelectionRejectSanitizerReasonCounts)
                        end
                        self:logDecision("TournamentAI", "Hard-locked Tournament sequence rejected after runtime sanitizer rewrite", {
                            reason = decisionSnapshot.fallbackReason,
                            hardReason = decisionSnapshot.hardSelectionReason,
                            hardSignature = decisionSnapshot.hardSelectionRejectSignature,
                            replacements = replacements
                        })
                    elseif requireSanitized then
                        accepted = false
                        local sanitizedSignature = self:buildActionSequenceSignature(sanitized)
                        decisionSnapshot.runtimeSanitizerRejected = true
                        decisionSnapshot.runtimeSanitizerRejectReason = "tournament_runtime_sanitize_rejected"
                        decisionSnapshot.runtimeSanitizerRejectReplacements = replacements
                        decisionSnapshot.runtimeSanitizerRejectReasonCounts = copyReasonCounts(
                            sanitizeSummary and sanitizeSummary.reasonCounts or {}
                        )
                        decisionSnapshot.runtimeSanitizerRejectRawSignature =
                            decisionSnapshot.rawSequenceSignature
                        decisionSnapshot.runtimeSanitizerRejectSanitizedSignature =
                            sanitizedSignature
                        decisionSnapshot.fallbackReason = decisionSnapshot.runtimeSanitizerRejectReason
                        if tournamentMeta and tournamentMeta.stats then
                            tournamentMeta.stats.runtimeSanitizerRejected = true
                            tournamentMeta.stats.runtimeSanitizerRejectReason =
                                decisionSnapshot.runtimeSanitizerRejectReason
                            tournamentMeta.stats.runtimeSanitizerRejectReplacements = replacements
                            tournamentMeta.stats.runtimeSanitizerRejectReasonCounts =
                                copyReasonCounts(decisionSnapshot.runtimeSanitizerRejectReasonCounts)
                            tournamentMeta.stats.runtimeSanitizerRejectRawSignature =
                                decisionSnapshot.runtimeSanitizerRejectRawSignature
                            tournamentMeta.stats.runtimeSanitizerRejectSanitizedSignature =
                                decisionSnapshot.runtimeSanitizerRejectSanitizedSignature
                        end
                        self:logDecision("TournamentAI", "Tournament sequence rejected after runtime sanitizer rewrite", {
                            reason = decisionSnapshot.runtimeSanitizerRejectReason,
                            rawSignature = decisionSnapshot.rawSequenceSignature,
                            sanitizedSignature = sanitizedSignature,
                            replacements = replacements,
                            sanitizeReasons = sanitizeSummary and sanitizeSummary.reasonCounts or {}
                        })
                    end
                end

                if accepted then
                    local fallbackReason = tournamentMeta and tournamentMeta.fallbackReason or nil
                    if replacements > ZERO and not fallbackReason then
                        fallbackReason = "tournament_runtime_sanitizer_rewrite"
                        self:logDecision("TournamentAI", "Tournament sequence accepted after sanitizer rewrote actions", {
                            reason = fallbackReason,
                            replacements = replacements
                        })
                    end
                    if tournamentBrain.logDecision then
                        tournamentBrain.logDecision(self, tournamentMeta, sanitized, sanitizeSummary)
                    end

                    self._lastSanitizeSummary = sanitizeSummary
                    decisionSnapshot.tournamentAccepted = true
                    decisionSnapshot.decisionSource = "tournament"
                    decisionSnapshot.fallbackReason = fallbackReason
                    self.isProcessingTurn = false
                    self.lastSequence = sanitized
                    commitDecisionSnapshot(sanitized)
                    finalizeDecisionLatency(sanitized)
                    return sanitized
                end

                decisionSnapshot.tournamentAccepted = false
                decisionSnapshot.decisionSource = "tournament"
                if decisionSnapshot.hardSelectionLocked == true then
                    decisionSnapshot.fallbackReason = decisionSnapshot.fallbackReason
                        or "hard_selection_runtime_sanitize_empty"
                    captureHardSelectionReject(
                        decisionSnapshot.fallbackReason,
                        "runtime_sanitizer",
                        decisionSnapshot.rawSequenceSignature,
                        sanitizeSummary
                    )
                elseif decisionSnapshot.runtimeSanitizerRejected ~= true then
                    decisionSnapshot.fallbackReason = "tournament_runtime_empty_after_sanitize"
                end
                self:logDecision("TournamentAI", "Tournament sequence failed sanitizer constraints", {
                    reason = "tournament_sequence_failed_sanitizer",
                    hardRejected = decisionSnapshot.hardSelectionRejected == true,
                    hardRejectReason = decisionSnapshot.hardSelectionRejectReason,
                    hardRejectStage = decisionSnapshot.hardSelectionRejectStage,
                    sanitizeSummary = sanitizeSummary
                })
            end

            local fallbackReason = decisionSnapshot.fallbackReason
                or (tournamentMeta and tournamentMeta.fallbackReason)
                or (tournamentMeta and tournamentMeta.reason)
                or "tournament_runtime_no_sequence"
            capturePrimaryTournamentSnapshot("before_runtime_safety_net")

            self:logDecision("TournamentAI", "Tournament returned no sequence; using runtime safety net", {
                reason = fallbackReason,
                hardRejected = decisionSnapshot.hardSelectionRejected == true,
                hardRejectReason = decisionSnapshot.hardSelectionRejectReason,
                hardRejectStage = decisionSnapshot.hardSelectionRejectStage
            })
            local fallbackCandidates = self:getMandatoryFallbackCandidates(state, {
                aiPlayer = self:getFactionId(),
                includeMove = true,
                includeAttack = true,
                includeRepair = true,
                includeDeploy = true,
                allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
            })
            local forcedSeed = (fallbackCandidates and fallbackCandidates[ONE] and fallbackCandidates[ONE].action) or nil
            decisionSnapshot.rawSequenceSignature = self:buildActionSequenceSignature(forcedSeed and {forcedSeed} or {})
            local forcedSequence, forcedSummary = self:sanitizeActionSequenceForState(state, forcedSeed and {forcedSeed} or {}, {
                aiPlayer = self:getFactionId(),
                maxActions = maxActions,
                allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true,
                rejectZeroDamageFactionAttacks = true
            })
            if not forcedSequence or #forcedSequence == ZERO then
                forcedSequence = {
                    self:createSkipAction(state),
                    self:createSkipAction(state)
                }
                if decisionSnapshot.hardSelectionRejected == true then
                    decisionSnapshot.hardSelectionFallbackPath = "forced_skip_sequence"
                end
            elseif decisionSnapshot.hardSelectionRejected == true then
                decisionSnapshot.hardSelectionFallbackPath = "forced_legal_tournament_sequence"
            end
            decisionSnapshot.tournamentAccepted = true
            decisionSnapshot.decisionSource = "tournament"
            decisionSnapshot.fallbackReason = fallbackReason
            decisionSnapshot.sanitizerReplacements = forcedSummary and (forcedSummary.replacements or ZERO) or ZERO
            decisionSnapshot.sanitizerReasonCounts = copyReasonCounts(forcedSummary and forcedSummary.reasonCounts or {})
            if decisionSnapshot.hardSelectionRejected == true then
                self:logDecision("TournamentAI", "Hard-locked Tournament rejection using final forced fallback", {
                    rejectReason = decisionSnapshot.hardSelectionRejectReason,
                    rejectStage = decisionSnapshot.hardSelectionRejectStage,
                    rejectSignature = decisionSnapshot.hardSelectionRejectSignature,
                    fallbackReason = decisionSnapshot.fallbackReason,
                    fallbackPath = decisionSnapshot.hardSelectionFallbackPath,
                    fallbackSignature = self:buildActionSequenceSignature(forcedSequence),
                    sanitizerReplacements = decisionSnapshot.hardSelectionRejectSanitizerReplacements,
                    sanitizerReasons = decisionSnapshot.hardSelectionRejectSanitizerReasonCounts
                })
            end
            self.isProcessingTurn = false
            self.lastSequence = forcedSequence
            commitDecisionSnapshot(forcedSequence)
            finalizeDecisionLatency(forcedSequence)
            return forcedSequence
        end

        decisionSnapshot.tournamentAttempted = true
        decisionSnapshot.tournamentAccepted = false
        decisionSnapshot.decisionSource = "tournament"
        decisionSnapshot.fallbackReason = "tournament_unavailable_technical_safety_net"
        self.lastTournamentMeta = nil

        local fallbackCandidates = self:getMandatoryFallbackCandidates(state, {
            aiPlayer = self:getFactionId(),
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true,
            allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
        })
        local forcedSeed = (fallbackCandidates and fallbackCandidates[ONE] and fallbackCandidates[ONE].action) or nil
        local forcedSequence, forcedSummary = self:sanitizeActionSequenceForState(state, forcedSeed and {forcedSeed} or {}, {
            aiPlayer = self:getFactionId(),
            maxActions = maxActions,
            allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true,
            rejectZeroDamageFactionAttacks = true
        })
        if not forcedSequence or #forcedSequence == ZERO then
            forcedSequence = {
                self:createSkipAction(state),
                self:createSkipAction(state)
            }
        end

        decisionSnapshot.tournamentAccepted = true
        decisionSnapshot.sanitizerReplacements = forcedSummary and (forcedSummary.replacements or ZERO) or ZERO
        decisionSnapshot.sanitizerReasonCounts = copyReasonCounts(forcedSummary and forcedSummary.reasonCounts or {})
        self.isProcessingTurn = false
        self.lastSequence = forcedSequence
        commitDecisionSnapshot(forcedSequence)
        finalizeDecisionLatency(forcedSequence)
        return forcedSequence
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

    function aiClass:getPossibleSupplyDeploymentsForPlayer(state, playerId, skipGridCheck, opts)
        local options = opts or {}
        local deployments = {}
        local aiPlayer = playerId
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

        local scoringAllowed = options.scoreDeployments ~= false and aiPlayer == self:getFactionId()
        local hubThreat = nil
        local healerEarlyDeployAllowed = true
        local adjacentRescueContext = nil

        if scoringAllowed then
            hubThreat = options.hubThreat or self:analyzeHubThreat(state)
            healerEarlyDeployAllowed = self:isHealerEarlyDeployAllowed(state, aiPlayer, hubThreat)
            adjacentRescueContext = self:getAdjacentRangedThreatContext(state, aiPlayer)
        end

        for unitIndex = ONE, #state.supply[aiPlayer] do
            local unit = state.supply[aiPlayer][unitIndex]
            if scoringAllowed and self:unitHasTag(unit, "healer") and not healerEarlyDeployAllowed then
                goto continue_supply_unit
            end
            for _, cell in ipairs(validFreeCells) do
                local score = ZERO
                if scoringAllowed then
                    score = self:evaluateSupplyDeployment(state, unit, cell, hubThreat, {
                        aiPlayer = aiPlayer,
                        unitIndex = unitIndex,
                        adjacentRangedThreatContext = adjacentRescueContext
                    })
                end

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

        if scoringAllowed then
            -- Sort deployments by score (best first)
            self:sortScoredEntries(deployments, {
                scoreField = "score",
                descending = true
            })
        end

        return deployments
    end

    function aiClass:getPossibleSupplyDeployments(state, skipGridCheck)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        return self:getPossibleSupplyDeploymentsForPlayer(state, aiPlayer, skipGridCheck)
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
