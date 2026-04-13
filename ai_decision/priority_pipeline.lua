local M = {}

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
    function aiClass:findBestAiSequance(state)
        local currentState = self:deepCopyState(state)
        currentState.turnActionCount = ZERO
        currentState.firstActionRangedAttack = nil
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end

        -- Initialize position history if not exists (persists across turns)
        if not self.positionHistory then
            self.positionHistory = {}
        end

        -- Clean up old position history to prevent memory bloat.
        local positionalConfig = self:getPositionalScoreConfig()
        local defaultPositionalConfig = DEFAULT_SCORE_PARAMS.POSITIONAL or {}
        local historyKeepTurns = valueOr(positionalConfig.HISTORY_KEEP_TURNS, defaultPositionalConfig.HISTORY_KEEP_TURNS)
        local currentTurn = state.currentTurn or MIN_HP
        for posKey, history in pairs(self.positionHistory) do
            if currentTurn - history.turn > historyKeepTurns then
                self.positionHistory[posKey] = nil
            end
        end

        -- Build influence map for this turn (spatial awareness for positioning)
        -- Pass self so influence map can use LoS and pathfinding functions
        local factionId = self:getFactionId()
        self.influenceMap, self.influenceStats = aiInfluence:buildInfluenceMap(state, factionId, self)

        -- Log dynamic pressure system status at configured bucket intervals.
        local pressureValues = self:getPressurePhaseValues(currentTurn)
        if currentTurn % pressureValues.turnBucket == ONE and currentTurn > ONE then
            local offensiveBonus = pressureValues.offensiveBonus
            local defensivePenalty = pressureValues.defensivePenalty
            self:logDecision("TurnPhase", string.format("Pressure escalation: Turn %d (Phase %d) | Offensive bonus: +%d | Defensive penalty: -%d", 
                currentTurn, pressureValues.turnPhase, offensiveBonus, defensivePenalty))
        end
        local sequence = {}
        local sequenceTags = {}
        local usedUnits = {}        -- Track units that have performed attack/repair or move+attack/repair (no more actions this turn) - by ORIGINAL position key
        local unitMoveCount = {}    -- Track how many actions each unit has made - by ORIGINAL position key
        local occupiedDestinations = {}  -- Track move destinations to prevent collisions
        local rangedSupportPriorityChecked = false
        local maxActions = valueOr(TURN_RULE_CONTRACT.ACTIONS_PER_TURN, valueOr(ACTION_RULE_CONTRACT.MANDATORY_ACTION_COUNT, valueOr(GAME.CONSTANTS.MAX_ACTIONS_PER_TURN, TWO)))
        local strategyConfig = self:getStrategyScoreConfig()
        local strategyDefenseConfig = strategyConfig.DEFENSE or {}
        local strategyAdvancementConfig = strategyConfig.ADVANCEMENT or {}
        local strategicState = self.strategicPlanState or {
            intent = STRATEGY_INTENT.STABILIZE,
            active = false
        }
        local doctrineConfig = self:getDoctrineScoreConfig()
        local earlyTempoConfig = doctrineConfig.EARLY_TEMPO or {}
        local midTempoConfig = doctrineConfig.MID_TEMPO or {}
        local tempoContext = self:getPhaseTempoContext(currentState)
        local inEarlyPhase = tempoContext and tempoContext.phase == "early"
        local inMidPhase = tempoContext and tempoContext.phase == "mid"
        local inEndPhase = tempoContext and tempoContext.phase == "end"
        local earlyRiskSuppressed = valueOr(earlyTempoConfig.SUPPRESS_RISKY_ATTACK_TIERS, true)
        local maxEarlyRiskyActions = math.max(ZERO, valueOr(earlyTempoConfig.MAX_EARLY_RISKY_ACTIONS_PER_TURN, ZERO))
        local midRiskBudget = math.max(ZERO, valueOr(midTempoConfig.MID_RISK_BUDGET, ONE))
        local riskyActionsUsed = ZERO
        local strategicDefenseLock = false
        local strategicPlanAdvancedThisTurn = false

        -- Map current position to original position for unit tracking
        -- This allows us to track units by their starting position even after they move
        local originalPositions = {}  -- [currentPosKey] = originalPosKey
        for _, unit in ipairs(currentState.units) do
            if unit.row and unit.col then
                local posKey = unit.row .. "," .. unit.col
                originalPositions[posKey] = posKey  -- Initially, current = original
            end
        end

        -- Print grid state for tactical context
        self:printGridState(currentState)
        self:logDecision("Priority", "Evaluating priorities", {
            unitsRemaining = self:countAiUnits(currentState)
        })

        -- Decision Helpers
        local function sequenceFull()
            return #sequence >= maxActions
        end

        local function canFitActions(actionCount)
            return (#sequence + actionCount) <= maxActions
        end

        local function getRemainingDecisionBudgetMs()
            local ctx = self._decisionGuardContext
            if not ctx or not ctx.startTime or not ctx.budgetMs then
                return nil
            end
            if not (love and love.timer and love.timer.getTime) then
                return nil
            end
            local elapsedMs = (love.timer.getTime() - ctx.startTime) * 1000
            return ctx.budgetMs - elapsedMs
        end

        local function shouldShortCircuitForBudget(stageTag, thresholdMs)
            local remainingMs = getRemainingDecisionBudgetMs()
            if remainingMs == nil then
                return false
            end
            local threshold = thresholdMs or 90
            if remainingMs <= threshold then
                self:logDecision("Performance", "Priority pipeline budget guard triggered", {
                    stage = stageTag,
                    remainingMs = string.format("%.1f", remainingMs),
                    thresholdMs = threshold
                })
                return true
            end
            return false
        end

        local function sequenceHasTagPrefix(prefix)
            if type(prefix) ~= "string" or #prefix == ZERO then
                return false
            end
            for _, tag in ipairs(sequenceTags) do
                if type(tag) == "string" and string.sub(tag, ONE, #prefix) == prefix then
                    return true
                end
            end
            return false
        end

        local function isImmediateDefensePhase()
            local threatData = self:analyzeHubThreat(currentState)
            if not threatData then
                return false
            end
            return threatData.isUnderAttack == true
                or threatData.projectedThreatActionable == true
                or (self.defenseModeState and self.defenseModeState.active == true)
        end

        local function shouldSuppressRiskyTier(priorityTag)
            if strategicState and strategicState.intent == STRATEGY_INTENT.DEFEND_HARD then
                return false
            end
            if isImmediateDefensePhase() then
                return false
            end
            if shouldShortCircuitForBudget(priorityTag, 120) then
                return true
            end

            if inEarlyPhase and earlyRiskSuppressed then
                if riskyActionsUsed >= maxEarlyRiskyActions then
                    self.earlyAttackSuppressedCount = (self.earlyAttackSuppressedCount or ZERO) + ONE
                    self:logDecision(priorityTag, "Suppressed by early tempo anti-rush gate", {
                        phase = "early",
                        riskyActionsUsed = riskyActionsUsed,
                        maxRiskyActions = maxEarlyRiskyActions
                    })
                    return true
                end
                return false
            end

            if inMidPhase and valueOr(midTempoConfig.ENABLE_FREQUENT_INTERACTIONS, true) then
                if riskyActionsUsed >= midRiskBudget then
                    self:logDecision(priorityTag, "Suppressed by mid risk budget", {
                        phase = "mid",
                        riskyActionsUsed = riskyActionsUsed,
                        midRiskBudget = midRiskBudget
                    })
                    return true
                end
            end

            return false
        end

        local function consumeRiskyAction()
            riskyActionsUsed = riskyActionsUsed + ONE
        end

        local function shouldRejectEarlyExposedMoveAttack(combo, priorityTag)
            if not inEarlyPhase or not combo or not combo.moveAction or not combo.attackAction then
                return false
            end

            local attacker = combo.unit
            if (not attacker) and combo.moveAction.unit then
                attacker = self:getUnitAtPosition(currentState, combo.moveAction.unit.row, combo.moveAction.unit.col)
            end
            if not attacker then
                return false
            end

            local attackTarget = combo.target
            if (not attackTarget) and combo.attackAction.target then
                attackTarget = self:getUnitAtPosition(currentState, combo.attackAction.target.row, combo.attackAction.target.col)
            end
            if not attackTarget then
                return false
            end

            local damage = self:calculateDamage(attacker, attackTarget) or ZERO
            local targetHp = attackTarget.currentHp or attackTarget.startingHp or MIN_HP
            local lethal = damage >= targetHp
            if lethal then
                return false
            end

            local backedAttackOk = self:isNonLethalMoveAttackBacked(currentState, combo.moveAction, combo.attackAction, {
                horizonPlies = TWO,
                tempoContext = tempoContext
            })
            if backedAttackOk then
                return false
            end

            local simAfterMove = self:applyMove(currentState, combo.moveAction)
            local movedUnit = self:getUnitAtPosition(simAfterMove, combo.moveAction.target.row, combo.moveAction.target.col)
            local exposed = movedUnit and self:wouldUnitDieNextTurn(simAfterMove, movedUnit) or false
            if not exposed then
                return false
            end

            local allowSafeHighValueAttack = valueOr(earlyTempoConfig.ALLOW_SAFE_HIGH_VALUE_ATTACK, true)
            local highValueTarget = self:unitHasTag(attackTarget, "high_value") or self:isHubUnit(attackTarget)
            if allowSafeHighValueAttack and highValueTarget then
                return false
            end

            local minSupportedGain = valueOr(earlyTempoConfig.MIN_SUPPORTED_ATTACK_GAIN, 120)
            local exposurePenalty = valueOr(earlyTempoConfig.MOVE_ATTACK_EXPOSURE_PENALTY, 220)
            local tacticalGain = combo.value or ZERO
            local reject = tacticalGain < (minSupportedGain + exposurePenalty)
            if reject then
                self.earlyAttackSuppressedCount = (self.earlyAttackSuppressedCount or ZERO) + ONE
                self:logDecision(priorityTag, "Rejected exposed early move+attack combo", {
                    tacticalGain = tacticalGain,
                    requiredGain = minSupportedGain + exposurePenalty,
                    target = self:describeUnitShort(attackTarget)
                })
            end
            return reject
        end

        local function shouldShortCircuitToFallbackForBudget(stageTag, thresholdMs)
            if not shouldShortCircuitForBudget(stageTag, thresholdMs) then
                return false
            end
            self:logDecision("Performance", "Short-circuiting priority pipeline to fallback", {
                stage = stageTag,
                sequenceLen = #sequence
            })
            return true
        end

        -- Helper function to format candidate lists for readable logging
        local function formatCandidates(candidates, maxShow)
            maxShow = valueOr(maxShow, (MIN_HP + TWO))
            if not candidates or #candidates == ZERO then
                return "[]"
            end

            local summary = string.format("[%d candidates]", #candidates)
            local details = {}

            for i = ONE, math.min(#candidates, maxShow) do
                local c = candidates[i]
                local unitDesc = c.unit and self:describeUnitShort(c.unit) or "?"
                local actionDesc = "?"

                -- Handle different action structures
                if c.moveAction and c.attackAction then
                    -- Move+attack combo
                    actionDesc = string.format("%s->%s->%s", 
                        self:formatCell({row=c.moveAction.unit.row, col=c.moveAction.unit.col}),
                        self:formatCell(c.moveAction.target),
                        self:formatCell(c.attackAction.target))
                elseif c.moveAction and c.repairAction then
                    -- Move+repair combo
                    actionDesc = string.format("%s->%s (repair %s)", 
                        self:formatCell({row=c.moveAction.unit.row, col=c.moveAction.unit.col}),
                        self:formatCell(c.moveAction.target),
                        self:formatCell(c.repairAction.target))
                elseif c.action then
                    -- Single action
                    actionDesc = string.format("%s->%s", 
                        self:formatCell({row=c.action.unit.row, col=c.action.unit.col}),
                        self:formatCell(c.action.target))
                end

                local valueDesc = string.format("val=%.1f", c.value or ZERO)
                table.insert(details, string.format("  %s: %s (%s)", unitDesc, actionDesc, valueDesc))
            end

            if #candidates > maxShow then
                table.insert(details, string.format("  ... and %d more", #candidates - maxShow))
            end

            return summary .. "\n" .. table.concat(details, "\n")
        end

        -- Helper function to safely add actions with reason tracking
        local function formatActionUnitLabel(action, unit)
            if unit then
                return self:describeUnitShort(unit)
            end

            if action then
                if action.type == "supply_deploy" then
                    local name = action.unitName or "supply unit"
                    local target = action.target and self:formatCell(action.target) or "(?,?)"
                    return string.format("%s -> %s", name, target)
                end
                if action.unit and type(action.unit) == "table" then
                    -- Check if action.unit is just a position (row/col only) or a full unit
                    if action.unit.name then
                        -- Full unit object
                        return self:describeUnitShort(action.unit)
                    elseif action.unit.row and action.unit.col then
                        -- Position only - look up the unit in current state
                        local unitAtPos = self:getUnitAtPosition(currentState, action.unit.row, action.unit.col)
                        if unitAtPos then
                            return self:describeUnitShort(unitAtPos)
                        else
                            return string.format("unit at %s", self:formatCell(action.unit))
                        end
                    end
                end
            end

            return "unknown unit"
        end

        local ZERO_DAMAGE_ALLOWED_TAGS = {
            DESPERATE_ATTACK = true,
            RANDOM_ACTION = true,
            MANDATORY_LEGAL_FALLBACK = true
        }
        local COMMANDER_EXPOSURE_ALLOWED_TAGS = {
            WINNING_MOVE = true,
            WINNING_ATTACK = true,
            WINNING_RANGED_ATTACK = true,
            MANDATORY_LEGAL_FALLBACK = true,
            MANDATORY_LEGAL_FALLBACK_SECOND = true,
            COMMANDANT_THREAT_COUNTER_MOVE = true,
            COMMANDANT_THREAT_FOLLOWUP_COUNTER = true,
            STRATEGIC_DEFENSE_MOVE = true,
            STRATEGIC_DEFENSE_COUNTER_MOVE = true,
            STRATEGIC_DEFENSE_GUARD = true
        }

        local function addActionSafely(action, priorityTag, unit)
            local unitLabel = formatActionUnitLabel(action, unit)
            local actionLabel = action and (action.type or action.actionType or "?") or "?"
            local unitKey = unit and self:getUnitKey(unit)

            -- Get original position key for tracking (handles moved units)
            local originalKey = unitKey and originalPositions[unitKey] or unitKey
            local actingUnit = nil

            if sequenceFull() then
                self:logDecision(priorityTag, string.format("Result: skip %s (%s) -> sequence full (%d)", unitLabel, actionLabel, maxActions))
                return false, "sequence_full"
            end

            if originalKey and usedUnits[originalKey] then
                self:logDecision(priorityTag, string.format("Result: skip %s (%s) -> unit already used", unitLabel, actionLabel))
                return false, "unit_used"
            end

            if originalKey and action.type == "move" and unitMoveCount[originalKey] and unitMoveCount[originalKey] >= ONE then
                self:logDecision(priorityTag, string.format("Result: skip %s (%s) -> move limit reached", unitLabel, actionLabel))
                return false, "move_limit"
            end

            -- CRITICAL VALIDATION: Ensure unit exists at the position in currentState
            -- This prevents adding actions that can't be executed
            if action.type ~= "supply_deploy" and action.unit and action.unit.row and action.unit.col then
                actingUnit = self:getUnitAtPosition(currentState, action.unit.row, action.unit.col)
                if not actingUnit then
                    self:logDecision(priorityTag, string.format("Result: skip %s (%s) -> no unit at position %s in current state", 
                        unitLabel, actionLabel, self:formatCell(action.unit)))
                    return false, "unit_not_found"
                end
            end

            if action.type == "move" and action.target then
                local targetRow, targetCol = action.target.row, action.target.col
                local destinationKey = targetRow .. "," .. targetCol

                -- Validate destination is not occupied in currentState
                local unitAtDest = self:getUnitAtPosition(currentState, targetRow, targetCol)
                if unitAtDest then
                    self:logDecision(priorityTag, string.format("Result: skip %s (%s) -> destination %s occupied by %s",
                        unitLabel, actionLabel, self:formatCell(action.target), self:describeUnitShort(unitAtDest)))
                    return false, "destination_occupied"
                end

                if actingUnit and not COMMANDER_EXPOSURE_ALLOWED_TAGS[priorityTag] then
                    local commanderExposurePenalty = self:calculateCommanderExposurePenalty(currentState, actingUnit, action.target)
                    if commanderExposurePenalty > ZERO then
                        self:logDecision(priorityTag, string.format(
                            "Result: skip %s (%s) -> move exposes commandant (penalty=%d)",
                            unitLabel,
                            actionLabel,
                            commanderExposurePenalty
                        ))
                        return false, "commandant_exposure"
                    end
                end

                if occupiedDestinations[destinationKey] then
                    self:logDecision(priorityTag, string.format("Result: skip %s (%s) -> destination %s reserved by %s",
                        unitLabel,
                        actionLabel,
                        self:formatCell(action.target),
                        tostring(occupiedDestinations[destinationKey])
                    ))
                    return false, "destination_reserved"
                end

                occupiedDestinations[destinationKey] = unitLabel
            end

            -- Validate attack/repair target exists in currentState
            if (action.type == "attack" or action.type == "repair") and action.target then
                local targetUnit = self:getUnitAtPosition(currentState, action.target.row, action.target.col)
                if not targetUnit and action.type == "attack" then
                    for _, building in ipairs(currentState.neutralBuildings or {}) do
                        if building.row == action.target.row and building.col == action.target.col then
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
                if not targetUnit then
                    self:logDecision(priorityTag, string.format("Result: skip %s (%s) -> no target at %s in current state",
                        unitLabel, actionLabel, self:formatCell(action.target)))
                    return false, "target_not_found"
                end

                if action.type == "attack" and not ZERO_DAMAGE_ALLOWED_TAGS[priorityTag] then
                    local attackerUnit = actingUnit
                    if not attackerUnit and action.unit and action.unit.row and action.unit.col then
                        attackerUnit = self:getUnitAtPosition(currentState, action.unit.row, action.unit.col)
                    end

                    if attackerUnit then
                        local damage = self:calculateDamage(attackerUnit, targetUnit)
                        if damage <= ZERO then
                            self:logDecision(
                                priorityTag,
                                string.format(
                                    "Result: skip %s (%s) -> zero damage against %s",
                                    unitLabel,
                                    actionLabel,
                                    self:describeUnitShort(targetUnit)
                                )
                            )
                            return false, "zero_damage"
                        end
                    end
                end
            end

            if type(action) == "table" then
                action._aiTag = priorityTag
            end
            table.insert(sequence, action)
            sequenceTags[#sequence] = priorityTag

            if originalKey then
                if action.type == "attack" or action.type == "repair" then
                    usedUnits[originalKey] = true
                elseif action.type == "move" then
                    unitMoveCount[originalKey] = (unitMoveCount[originalKey] or ZERO) + ONE

                    -- Update position mapping: unit moved from unitKey to target position
                    if unitKey and action.target and action.target.row and action.target.col then
                        local newPosKey = action.target.row .. "," .. action.target.col
                        originalPositions[newPosKey] = originalKey  -- Map new position to original
                        originalPositions[unitKey] = nil  -- Remove old position mapping
                    end
                end
            elseif action.type == "supply_deploy" and action.target then
                -- Mark the deployment target position as used so subsequent priorities recognize the new unit
                local deployKey = action.target.row .. "," .. action.target.col
                usedUnits[deployKey] = true
                originalPositions[deployKey] = deployKey  -- New unit's original position is where it's deployed
            end

            self:logDecision(priorityTag, string.format("Result: add %s (%s)", unitLabel, actionLabel))
            return true, "added"
        end

        local function undoAction(action, unit)
            if #sequence == ZERO then
                return
            end

            local lastIndex = #sequence
            local unitKey = unit and self:getUnitKey(unit)

            sequence[lastIndex] = nil
            sequenceTags[lastIndex] = nil

            if action.type == "move" and action.target then
                local destinationKey = action.target.row .. "," .. action.target.col
                occupiedDestinations[destinationKey] = nil
                if unitKey and unitMoveCount[unitKey] then
                    unitMoveCount[unitKey] = unitMoveCount[unitKey] - ONE
                    if unitMoveCount[unitKey] <= ZERO then
                        unitMoveCount[unitKey] = nil
                    end
                end
            elseif unitKey and (action.type == "attack" or action.type == "repair") then
                usedUnits[unitKey] = nil
            end
        end

        local function applyQueuedAction(action, addTag, unit, decisionTag, decisionMessage, opts)
            if not action then
                return false
            end

            local options = opts or {}
            if addActionSafely(action, addTag, unit) then
                if decisionTag and decisionMessage then
                    self:logDecision(decisionTag, decisionMessage, action)
                end

                local stateBeforeAction = currentState
                if options.stateMode == "none" then
                    -- Skip/pass actions only mutate the sequence queue.
                elseif options.stateMode == "deploy" or action.type == "supply_deploy" then
                    currentState = self:applySupplyDeployment(currentState, action)
                else
                    currentState = self:applyMove(currentState, action)
                end

                if action.type == "attack" and action.target then
                    local targetUnit = self:getUnitAtPosition(stateBeforeAction, action.target.row, action.target.col)
                    if not targetUnit then
                        for _, building in ipairs(stateBeforeAction.neutralBuildings or {}) do
                            if building.row == action.target.row and building.col == action.target.col then
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

                    if targetUnit and self:isObstacleUnit(targetUnit) then
                        self.rockAttackChosenCount = (self.rockAttackChosenCount or ZERO) + ONE
                        local rockStrategic = self:isStrategicRockAttack(stateBeforeAction, action, {
                            aiPlayer = aiPlayer,
                            target = targetUnit
                        })
                        if rockStrategic then
                            self.rockAttackStrategicCount = (self.rockAttackStrategicCount or ZERO) + ONE
                        end
                    end
                end
                return true
            end

            return false
        end

        local function applyTwoStepAction(firstStep, secondStep, opts)
            if not firstStep or not secondStep then
                return false
            end

            local options = opts or {}
            local snapshotState = currentState

            local firstAdded = applyQueuedAction(
                firstStep.action,
                firstStep.addTag,
                firstStep.unit,
                firstStep.logTag,
                firstStep.logMessage,
                firstStep.opts
            )
            if not firstAdded then
                return false
            end

            local secondAdded = applyQueuedAction(
                secondStep.action,
                secondStep.addTag,
                secondStep.unit,
                secondStep.logTag,
                secondStep.logMessage,
                secondStep.opts
            )
            if secondAdded then
                return true
            end

            if options.rollbackOnSecondFailure then
                undoAction(firstStep.action, firstStep.unit)
                currentState = snapshotState
            end
            return false
        end

        local function tryPreferDirectAttackOverMoveCombo(combo, priorityTag)
            if not combo or not combo.attackAction or not combo.attackAction.target then
                return false, false
            end

            local targetPos = combo.attackAction.target
            if not targetPos.row or not targetPos.col then
                return false, false
            end

            local targetKey = targetPos.row .. "," .. targetPos.col
            local allowHealerAttacks = self:shouldHealerBeOffensive(currentState, {
                allowEmergencyDefense = true
            })
            local directEntries = self:collectAttackTargetEntries(currentState, usedUnits, {
                mode = "direct",
                aiPlayer = aiPlayer,
                includeFriendlyFireCheck = true,
                requirePositiveDamage = true,
                allowHealerAttacks = allowHealerAttacks
            })

            local bestDirect = nil
            for _, entry in ipairs(directEntries) do
                if entry and entry.target and entry.target.row and entry.target.col then
                    local entryKey = entry.target.row .. "," .. entry.target.col
                    if entryKey == targetKey then
                        local backedAttackOk, backedContext = self:isNonLethalAttackBacked(currentState, entry.action, {
                            horizonPlies = TWO,
                            tempoContext = tempoContext,
                            allowEmergencyDefense = true
                        })
                        if not backedAttackOk then
                            goto continue_direct_preference_entry
                        end
                        local damage = entry.damage or ZERO
                        local targetHp = entry.targetHp or (entry.target.currentHp or entry.target.startingHp or MIN_HP)
                        local lethal = damage >= targetHp
                        local score = damage * 1000
                        if lethal then
                            score = score + 100000
                        end
                        if not bestDirect or score > bestDirect.score then
                            bestDirect = {
                                entry = entry,
                                damage = damage,
                                targetHp = targetHp,
                                lethal = lethal,
                                score = score
                            }
                        end
                    end
                end
                ::continue_direct_preference_entry::
            end

            if not bestDirect then
                return false, false
            end

            local comboTargetUnit = self:getUnitAtPosition(currentState, targetPos.row, targetPos.col)
            local comboTargetHp = combo.targetHp
            if not comboTargetHp and comboTargetUnit then
                comboTargetHp = comboTargetUnit.currentHp or comboTargetUnit.startingHp or MIN_HP
            end
            comboTargetHp = comboTargetHp or MIN_HP

            local comboDamage = combo.damage
            if comboDamage == nil and combo.unit then
                local projectedAttacker = combo.unit
                if combo.moveAction and combo.moveAction.target then
                    projectedAttacker = self:buildProjectedThreatUnit(
                        combo.unit,
                        combo.moveAction.target.row,
                        combo.moveAction.target.col
                    ) or combo.unit
                end

                if comboTargetUnit then
                    comboDamage = self:calculateDamage(projectedAttacker, comboTargetUnit)
                end
            end
            comboDamage = comboDamage or ZERO
            local comboLethal = comboDamage >= comboTargetHp

            local preferDirect = false
            local reason = "same_damage_one_action"
            if bestDirect.lethal and not comboLethal then
                preferDirect = true
                reason = "direct_lethal_combo_not"
            elseif bestDirect.damage > comboDamage then
                preferDirect = true
                reason = "direct_higher_damage"
            elseif bestDirect.damage == comboDamage and bestDirect.damage > ZERO then
                preferDirect = true
                reason = "same_damage_one_action"
            end

            if not preferDirect then
                return false, false
            end

            self:logDecision(priorityTag, "Move+attack candidate downgraded by global direct-attack preference", {
                target = targetPos,
                reason = reason,
                directUnit = self:describeUnitShort(bestDirect.entry.unit),
                directDamage = bestDirect.damage,
                comboUnit = combo.unit and self:describeUnitShort(combo.unit) or "unknown",
                comboDamage = comboDamage
            })

            local applied = applyQueuedAction(
                bestDirect.entry.action,
                "DIRECT_ATTACK_PREFERRED",
                bestDirect.entry.unit,
                priorityTag,
                "Selected direct attack over move+attack"
            )

            return true, applied
        end

        local function findSupportFollowUp(state)
            local info = state.firstActionRangedAttack
            if not info or not info.attacker or not info.target then
                return nil
            end
            local supportFollowUpConfig = self:getSupportFollowUpConfig()
            local defaultSupportFollowUpConfig = ((DEFAULT_SCORE_PARAMS.MOBILITY or {}).SUPPORT_FOLLOW_UP or {})
            local pathMaxSteps = valueOr(supportFollowUpConfig.PATH_MAX_STEPS, defaultSupportFollowUpConfig.PATH_MAX_STEPS)
            local currentDistMinExclusive = valueOr(supportFollowUpConfig.CURRENT_DIST_MIN_EXCLUSIVE, defaultSupportFollowUpConfig.CURRENT_DIST_MIN_EXCLUSIVE)
            local healerHubRadius = valueOr(supportFollowUpConfig.HEALER_HUB_RADIUS, defaultSupportFollowUpConfig.HEALER_HUB_RADIUS)
            local pathToTargetDistMax = valueOr(supportFollowUpConfig.PATH_TO_TARGET_DIST_MAX, defaultSupportFollowUpConfig.PATH_TO_TARGET_DIST_MAX)
            local notHuggingAttackerMin = valueOr(supportFollowUpConfig.NOT_HUGGING_ATTACKER_MIN, defaultSupportFollowUpConfig.NOT_HUGGING_ATTACKER_MIN)
            local attackerProxOrPathDist = valueOr(supportFollowUpConfig.ATTACKER_PROX_OR_PATH_DIST, defaultSupportFollowUpConfig.ATTACKER_PROX_OR_PATH_DIST)
            local meleeSupportDist = valueOr(supportFollowUpConfig.MELEE_SUPPORT_DIST, defaultSupportFollowUpConfig.MELEE_SUPPORT_DIST)
            local rangedProximityBase = valueOr(supportFollowUpConfig.RANGED_PROXIMITY_BASE, defaultSupportFollowUpConfig.RANGED_PROXIMITY_BASE)
            local rangedProximityStep = valueOr(supportFollowUpConfig.RANGED_PROXIMITY_STEP, defaultSupportFollowUpConfig.RANGED_PROXIMITY_STEP)
            local meleeProximityBase = valueOr(supportFollowUpConfig.MELEE_PROXIMITY_BASE, defaultSupportFollowUpConfig.MELEE_PROXIMITY_BASE)
            local meleeProximityStep = valueOr(supportFollowUpConfig.MELEE_PROXIMITY_STEP, defaultSupportFollowUpConfig.MELEE_PROXIMITY_STEP)
            local rangedValueBonus = valueOr(supportFollowUpConfig.RANGED_VALUE_BONUS, defaultSupportFollowUpConfig.RANGED_VALUE_BONUS)
            local minCandidateValue = valueOr(supportFollowUpConfig.MIN_CANDIDATE_VALUE, defaultSupportFollowUpConfig.MIN_CANDIDATE_VALUE)

            local targetUnit = self:getUnitAtPosition(state, info.target.row, info.target.col)
            if not targetUnit or targetUnit.player == self:getFactionId() then
                return nil
            end

            local attackerPos = {row = info.attacker.row, col = info.attacker.col}
            local attackerDistToTarget = math.abs(attackerPos.row - info.target.row) + math.abs(attackerPos.col - info.target.col)
            local candidates = {}
            for _, unit in ipairs(state.units) do
                if self:isUnitEligibleForAction(unit, info.attacker.player, nil) then
                    local currentDist = attackerPos and (math.abs(unit.row - attackerPos.row) + math.abs(unit.col - attackerPos.col)) or math.huge
                    local currentPathToTarget = self:hasLimitedClearPath(state, {row = unit.row, col = unit.col}, info.target, pathMaxSteps)

                    if currentDist > currentDistMinExclusive and not currentPathToTarget then
                        local moveCells = self:getValidMoveCells(state, unit.row, unit.col)
                        local attackRange = unit.atkRange or unitsInfo:getUnitAttackRange(unit, "SUPPORT_FOLLOW_UP_RANGE") or MIN_HP
                        local maxSupportDist = math.max(ONE, attackRange)
                        local allowHealerAttacks = self:shouldHealerBeOffensive(state)
                        local ownHub = state.commandHubs and state.commandHubs[aiPlayer]

                        for _, moveCell in ipairs(moveCells) do
                            local skipHealerMove = false
                            if not allowHealerAttacks and self:unitHasTag(unit, "healer") then
                                if not ownHub or (math.abs(moveCell.row - ownHub.row) + math.abs(moveCell.col - ownHub.col) > healerHubRadius) then
                                    skipHealerMove = true
                                end
                            end

                            if not skipHealerMove then
                                local dist = math.abs(moveCell.row - info.target.row) + math.abs(moveCell.col - info.target.col)
                                local distToAttacker = attackerPos and (math.abs(moveCell.row - attackerPos.row) + math.abs(moveCell.col - attackerPos.col)) or math.huge
                                local pathToTarget = dist <= pathToTargetDistMax and self:hasLimitedClearPath(state, moveCell, info.target, pathMaxSteps)

                                local advancesTowardTarget = dist < attackerDistToTarget
                                local notHuggingAttacker = distToAttacker > notHuggingAttackerMin

                                if dist <= maxSupportDist and advancesTowardTarget and notHuggingAttacker and (distToAttacker <= attackerProxOrPathDist or pathToTarget) then
                                    local safe = self:isMoveSafe(state, unit, moveCell)
                                    if safe then
                                        local simState, simUnit = self:simulateUnitMoveState(state, unit, moveCell, {validate = true})

                                        if simUnit then
                                            local canSupport = false

                                            if attackRange > ONE then
                                                canSupport = self:canUnitDamageTargetFromPosition(
                                                    simState,
                                                    simUnit,
                                                    targetUnit,
                                                    simUnit.row,
                                                    simUnit.col,
                                                    {requirePositiveDamage = true}
                                                )
                                            else
                                                canSupport = (dist == meleeSupportDist)
                                            end

                                            if canSupport then
                                                local positionalGain = self:getPositionalValue(simState, simUnit) - self:getPositionalValue(state, unit)
                                                local proximityBonus
                                                if attackRange > ONE then
                                                    proximityBonus = rangedProximityBase + math.max(ZERO, (attackRange - dist) * rangedProximityStep)
                                                else
                                                    proximityBonus = math.max(ZERO, meleeProximityBase - (dist * meleeProximityStep))
                                                end

                                                local value = positionalGain + proximityBonus
                                                if attackRange > ONE then
                                                    value = value + rangedValueBonus
                                                end

                                                candidates[#candidates + ONE] = {
                                                    unit = unit,
                                                    moveCell = moveCell,
                                                    value = value
                                                }
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if #candidates == ZERO then
                return nil
            end

            self:sortScoredEntries(candidates, {
                scoreField = "value",
                descending = true
            })
            local best = candidates[ONE]
            if not best or best.value <= minCandidateValue then
                return nil
            end

            return {
                unit = best.unit,
                action = {
                    type = "move",
                    unit = {row = best.unit.row, col = best.unit.col},
                    target = {row = best.moveCell.row, col = best.moveCell.col}
                },
                value = best.value
            }
        end

        local function runSupportFollowUp(logTag)
            if rangedSupportPriorityChecked or sequenceFull() then
                return
            end

            local info = currentState.firstActionRangedAttack
            if not info or not info.attacker or not info.target then
                return
            end

            rangedSupportPriorityChecked = true

            local supportAction = findSupportFollowUp(currentState)
            if supportAction then
                applyQueuedAction(
                    supportAction.action,
                    "RANGED_SUPPORT_FOLLOW_UP",
                    supportAction.unit,
                    logTag,
                    "Selected support follow-up move"
                )
            else
                self:logDecision(logTag, "No support follow-up available")
            end

            currentState.firstActionRangedAttack = nil
        end

        local function logSupportDebug(tag, msg, data)
            if not (self.debugSupport or (self.AI_PARAMS and self.AI_PARAMS.DEBUG_SUPPORT)) then
                return
            end
            self:logDecision(tag, msg, data)
        end

        local function triggerSupportReinforcement(context)
            if not context or not context.target then
                logSupportDebug("Support", "Reinforcement skipped (missing context/target)", {
                    hasContext = context ~= nil,
                    hasTarget = context and context.target ~= nil
                })
                return
            end
            if sequenceFull() then
                logSupportDebug("Support", "Reinforcement skipped (sequence full)", {
                    sequenceLen = #sequence,
                    maxActions = maxActions
                })
                return
            end
            local aiPlayer = self:getFactionId()
            if not aiPlayer then
                logSupportDebug("Support", "Reinforcement skipped (no aiPlayer)")
                return
            end

            local mobilityConfig = self:getMobilityScoreConfig()
            local supportConfig = mobilityConfig.SUPPORT_REINFORCEMENT or {}
            local defaultSupportConfig = ((DEFAULT_SCORE_PARAMS.MOBILITY or {}).SUPPORT_REINFORCEMENT or {})
            local baseScore = valueOr(supportConfig.BASE_SCORE, defaultSupportConfig.BASE_SCORE)
            local distWeight = valueOr(supportConfig.DIST_WEIGHT, defaultSupportConfig.DIST_WEIGHT)
            local improvementBonus = valueOr(supportConfig.IMPROVEMENT_BONUS, defaultSupportConfig.IMPROVEMENT_BONUS)
            local regressionPenalty = valueOr(supportConfig.REGRESSION_PENALTY, defaultSupportConfig.REGRESSION_PENALTY)
            local primaryProximityBase = valueOr(supportConfig.PRIMARY_PROXIMITY_BASE, defaultSupportConfig.PRIMARY_PROXIMITY_BASE)
            local primaryProximityStep = valueOr(supportConfig.PRIMARY_PROXIMITY_STEP, defaultSupportConfig.PRIMARY_PROXIMITY_STEP)
            local diagonalBonus = valueOr(supportConfig.DIAGONAL_SUPPORT_BONUS, defaultSupportConfig.DIAGONAL_SUPPORT_BONUS)
            local twoStepBonus = valueOr(supportConfig.TWO_STEP_SUPPORT_BONUS, defaultSupportConfig.TWO_STEP_SUPPORT_BONUS)
            local primaryExcessThreshold = valueOr(supportConfig.PRIMARY_EXCESS_THRESHOLD, defaultSupportConfig.PRIMARY_EXCESS_THRESHOLD)
            local primaryExcessPenalty = valueOr(supportConfig.PRIMARY_EXCESS_PENALTY, defaultSupportConfig.PRIMARY_EXCESS_PENALTY)
            local mobilityWeight = valueOr(supportConfig.MOBILITY_WEIGHT, defaultSupportConfig.MOBILITY_WEIGHT)
            local rangedAlignmentBonus = valueOr(supportConfig.RANGED_ALIGNMENT_BONUS, defaultSupportConfig.RANGED_ALIGNMENT_BONUS)
            local betweenBonus = valueOr(supportConfig.RANGED_BETWEEN_BONUS, defaultSupportConfig.RANGED_BETWEEN_BONUS)
            local moveBonusBase = valueOr(supportConfig.MOVE_BONUS_BASE, defaultSupportConfig.MOVE_BONUS_BASE)
            local moveDistanceWeight = valueOr(supportConfig.MOVE_DISTANCE_WEIGHT, defaultSupportConfig.MOVE_DISTANCE_WEIGHT)
            local pathMaxSteps = valueOr(supportConfig.PATH_MAX_STEPS, defaultSupportConfig.PATH_MAX_STEPS)
            local minDistFromPrimary = valueOr(supportConfig.MIN_DIST_FROM_PRIMARY, defaultSupportConfig.MIN_DIST_FROM_PRIMARY)
            local clearToTargetMaxDist = valueOr(supportConfig.CLEAR_TO_TARGET_MAX_DIST, defaultSupportConfig.CLEAR_TO_TARGET_MAX_DIST)

            local function between(primaryPos, supportPos, targetPos)
                if not primaryPos or not supportPos then
                    return false
                end
                if supportPos.row == targetPos.row and primaryPos.row == targetPos.row then
                    return (supportPos.col <= primaryPos.col and primaryPos.col <= targetPos.col) or
                           (targetPos.col <= primaryPos.col and primaryPos.col <= supportPos.col)
                end
                if supportPos.col == targetPos.col and primaryPos.col == targetPos.col then
                    return (supportPos.row <= primaryPos.row and primaryPos.row <= targetPos.row) or
                           (targetPos.row <= primaryPos.row and primaryPos.row <= supportPos.row)
                end
                return false
            end

            local function scoreCell(unit, cell)
                local target = context.target
                local distTarget = math.abs(cell.row - target.row) + math.abs(cell.col - target.col)
                local score = baseScore - distTarget * distWeight

                local currentDist = math.abs(unit.row - target.row) + math.abs(unit.col - target.col)
                local distImprovement = currentDist - distTarget
                if distImprovement > ZERO then
                    score = score + distImprovement * improvementBonus
                elseif distImprovement < ZERO then
                    score = score + distImprovement * regressionPenalty
                end

                if context.primaryPosition then
                    local distPrimary = math.abs(cell.row - context.primaryPosition.row) + math.abs(cell.col - context.primaryPosition.col)
                    score = score + math.max(ZERO, primaryProximityBase - distPrimary * primaryProximityStep)
                    local rowDelta = math.abs(cell.row - context.primaryPosition.row)
                    local colDelta = math.abs(cell.col - context.primaryPosition.col)
                    if rowDelta == ONE and colDelta == ONE then
                        score = score + diagonalBonus
                    elseif (rowDelta == TWO and colDelta == ZERO) or (rowDelta == ZERO and colDelta == TWO) then
                        score = score + twoStepBonus
                    else
                        score = score - math.max(ZERO, (distPrimary - primaryExcessThreshold) * primaryExcessPenalty)
                    end
                end
                if context.kind == "move" then
                    score = score + math.max(ZERO, moveBonusBase - distTarget * moveDistanceWeight)
                end

                local mobility = ZERO
                for _, dir in ipairs(self:getOrthogonalDirections()) do
                    local nr = cell.row + dir.row
                    local nc = cell.col + dir.col
                    if self:isInsideBoard(nr, nc, currentState) then
                        if not self.aiState.isPositionBlocked(currentState, nr, nc) then
                            mobility = mobility + ONE
                        end
                    end
                end
                score = score + mobility * mobilityWeight

                local range = unit.atkRange or unitsInfo:getUnitAttackRange(unit, "SUPPORT_REINFORCE_RANGE") or MIN_HP
                if range > ONE and (cell.row == target.row or cell.col == target.col) then
                    score = score + rangedAlignmentBonus
                    if between(context.primaryPosition, cell, target) then
                        score = score + betweenBonus
                    end
                end
                return score
            end

            local candidates = {}
            for _, unit in ipairs(currentState.units) do
                if self:isUnitEligibleForAction(unit, aiPlayer, nil) then
                    local unitKey = self:getUnitKey(unit)
                    local originalKey = unitKey and originalPositions[unitKey] or unitKey
                    if originalKey ~= context.primaryOriginalKey and not usedUnits[originalKey] then
                        local evaluateUnit = true
                        if context.primaryPosition then
                            local currentDist = math.abs(unit.row - context.primaryPosition.row) + math.abs(unit.col - context.primaryPosition.col)
                            if currentDist <= minDistFromPrimary then
                                evaluateUnit = false
                            end
                        end

                        if evaluateUnit then
                            local moveCells = self:getValidMoveCells(currentState, unit.row, unit.col)
                            for _, cell in ipairs(moveCells) do
                                if sequenceFull() then
                                    break
                                end
                                if self:isMoveSafe(currentState, unit, cell) then
                                    local valid = true
                                    local closeToPrimary = false
                                    if context.primaryPosition then
                                        local distPrimary = math.abs(cell.row - context.primaryPosition.row) + math.abs(cell.col - context.primaryPosition.col)
                                        if distPrimary <= minDistFromPrimary then
                                            closeToPrimary = true
                                        end
                                    end
                                    local distToTarget = math.abs(cell.row - context.target.row) + math.abs(cell.col - context.target.col)
                                    local clearToTarget = distToTarget <= clearToTargetMaxDist and self:hasLimitedClearPath(currentState, cell, context.target, pathMaxSteps)
                                    if not closeToPrimary and not clearToTarget then
                                        valid = false
                                    end
                                    local range = unit.atkRange or unitsInfo:getUnitAttackRange(unit, "SUPPORT_REINFORCE_RANGE") or MIN_HP
                                    if context.kind == "attack" and range > ONE then
                                        local aligned = (cell.row == context.target.row) or (cell.col == context.target.col)
                                        if not aligned or distToTarget > range then
                                            valid = false
                                        elseif self:unitHasTag(unit, "los") and not self:hasLineOfSight(currentState, cell, context.target) then
                                            valid = false
                                        end
                                    end
                                    if valid then
                                        table.insert(candidates, {
                                            unit = unit,
                                            cell = cell,
                                            score = scoreCell(unit, cell)
                                        })
                                    end
                                end
                            end
                        end
                    end
                end
            end

            logSupportDebug("Support", "Reinforcement candidates evaluated", {
                candidateCount = #candidates,
                kind = context.kind,
                target = context.target
            })

            self:sortScoredEntries(candidates, {
                scoreField = "score",
                descending = true
            })
            for _, candidate in ipairs(candidates) do
                if sequenceFull() then
                    logSupportDebug("Support", "Reinforcement aborted (sequence filled mid-selection)", {
                        sequenceLen = #sequence,
                        maxActions = maxActions
                    })
                    break
                end
                local action = {
                    type = "move",
                    unit = {row = candidate.unit.row, col = candidate.unit.col},
                    target = {row = candidate.cell.row, col = candidate.cell.col}
                }
                if applyQueuedAction(
                    action,
                    context.logTag or "Support",
                    candidate.unit,
                    context.logTag or "Support",
                    "Selected reinforcement move"
                ) then
                    logSupportDebug("Support", "Reinforcement action added", {
                        unit = self:describeUnitShort(candidate.unit),
                        target = action.target,
                        score = candidate.score
                    })
                    break
                end
            end
        end

        local function requestSupport(primaryUnit, action, logTag, kind)
            if not action or not action.target then
                logSupportDebug("Support", "Request skipped (missing action/target)", {
                    hasAction = action ~= nil,
                    hasTarget = action and action.target ~= nil,
                    kind = kind
                })
                return
            end
            if #sequence ~= maxActions - ONE then
                logSupportDebug("Support", "Request skipped (sequence length mismatch)", {
                    sequenceLen = #sequence,
                    maxActions = maxActions,
                    kind = kind
                })
                return
            end
            local unitKey = primaryUnit and self:getUnitKey(primaryUnit)
            local originalKey = unitKey and originalPositions[unitKey] or unitKey
            local primaryPos
            if action.type == "move" then
                primaryPos = {row = action.target.row, col = action.target.col}
            else
                if action.unit and action.unit.row then
                    primaryPos = {row = action.unit.row, col = action.unit.col}
                elseif primaryUnit and primaryUnit.row then
                    primaryPos = {row = primaryUnit.row, col = primaryUnit.col}
                end
            end
            triggerSupportReinforcement({
                target = {row = action.target.row, col = action.target.col},
                primaryOriginalKey = originalKey,
                primaryPosition = primaryPos,
                kind = kind,
                logTag = logTag
            })

            logSupportDebug("Support", "Reinforcement requested", {
                kind = kind,
                target = action.target,
                primaryPosition = primaryPos
            })
        end

        local function hasThreatReleaseLegalAttack()
            local legalDirectAttacks = self:collectLegalActions(currentState, {
                aiPlayer = aiPlayer,
                usedUnits = usedUnits,
                includeMove = false,
                includeAttack = true,
                includeRepair = false,
                includeDeploy = false
            })
            local moveAttackEntries = self:collectAttackTargetEntries(currentState, usedUnits, {
                mode = "move",
                aiPlayer = aiPlayer,
                includeFriendlyFireCheck = true,
                requirePositiveDamage = true,
                requireSafeMove = false,
                checkVulnerableMove = false
            })
            local directAttackCount = #legalDirectAttacks
            local moveAttackCount = #moveAttackEntries
            local hasAnyAttack = (directAttackCount + moveAttackCount) > ZERO
            return hasAnyAttack, directAttackCount, moveAttackCount
        end

        local function isHardHubThreatActiveForInteractionGate()
            local threatConfig = self:getCommandantThreatResponseScoreConfig()
            local defaultThreatConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_THREAT_RESPONSE or {}
            local activateOnPotential = valueOr(
                threatConfig.ACTIVATE_ON_POTENTIAL,
                valueOr(defaultThreatConfig.ACTIVATE_ON_POTENTIAL, true)
            )
            local triggerThreatLevel = valueOr(
                threatConfig.TRIGGER_THREAT_LEVEL,
                valueOr(defaultThreatConfig.TRIGGER_THREAT_LEVEL, ZERO)
            )
            local hubHpTrigger = valueOr(
                threatConfig.HUB_HP_TRIGGER,
                valueOr(defaultThreatConfig.HUB_HP_TRIGGER, EIGHT)
            )

            local threatData = self:analyzeHubThreat(currentState)
            local ownHub = currentState.commandHubs and currentState.commandHubs[aiPlayer]
            local ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO
            local immediateThreat = threatData and threatData.isUnderAttack == true
            local projectedThreat = threatData and threatData.isUnderProjectedThreat == true
            local threatLevel = threatData and threatData.threatLevel or ZERO
            local projectedThreatLevel = threatData and threatData.projectedThreatLevel or ZERO
            local potentialThreat = threatLevel >= triggerThreatLevel
                or projectedThreatLevel >= triggerThreatLevel
            local lowHubHp = ownHub and ownHubHp <= hubHpTrigger

            local active = immediateThreat
                or projectedThreat
                or lowHubHp
                or (activateOnPotential and potentialThreat)

            return active, {
                threatLevel = threatLevel,
                projectedThreatLevel = projectedThreatLevel,
                immediateThreat = immediateThreat,
                projectedThreat = projectedThreat,
                ownHubHp = ownHubHp,
                triggerThreatLevel = triggerThreatLevel
            }
        end

        local function shouldForceInteractionBeforePositioning()
            local drawUrgencyConfig = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY)
                or (DEFAULT_AI_PARAMS and DEFAULT_AI_PARAMS.DRAW_URGENCY)
                or {}
            local pipelineConfig = drawUrgencyConfig.PIPELINE or {}
            local forceWhenNoHardThreat = pipelineConfig.FORCE_INTERACTION_WHEN_NO_HARD_THREAT == true
            local forceInteractionMinTurn = math.max(
                ONE,
                valueOr(pipelineConfig.FORCE_INTERACTION_MIN_TURN, TWO)
            )
            local urgencyActive = self:isDrawUrgencyActive() or self:isStalematePressureActive(currentState)
            local currentTurnForGate = self:getStateTurn(currentState) or ZERO
            local forceWindowActive = forceWhenNoHardThreat and currentTurnForGate >= forceInteractionMinTurn

            if pipelineConfig.RUN_BEFORE_POSITIONING ~= true then
                return false, {reason = "pipeline_disabled"}
            end
            if not urgencyActive and not forceWindowActive then
                return false, {
                    reason = "urgency_inactive",
                    currentTurn = currentTurnForGate,
                    forceInteractionMinTurn = forceInteractionMinTurn
                }
            end
            if self:sequenceHasAttackAction(sequence) then
                return false, {reason = "attack_already_selected"}
            end

            local hubThreatActive, hubThreatContext = isHardHubThreatActiveForInteractionGate()
            if hubThreatActive then
                return false, {
                    reason = "hub_threat_active",
                    threatLevel = hubThreatContext and hubThreatContext.threatLevel or ZERO,
                    projectedThreatLevel = hubThreatContext and hubThreatContext.projectedThreatLevel or ZERO
                }
            end

            local hasAttackAction, directAttackCount, moveAttackCount = hasThreatReleaseLegalAttack()
            if not hasAttackAction then
                return false, {reason = "no_attack_available"}
            end

            local blockPositioning = pipelineConfig.BLOCK_POSITIONING_WHEN_ATTACK_EXISTS == true
            local blockDeploy = pipelineConfig.BLOCK_DEPLOY_WHEN_ATTACK_EXISTS == true
            if not blockPositioning and not blockDeploy then
                return false, {reason = "pipeline_blocks_disabled"}
            end

            return true, {
                reason = urgencyActive and "attack_available_urgency" or "attack_available_no_hard_threat",
                directAttackCount = directAttackCount,
                moveAttackCount = moveAttackCount,
                blockPositioning = blockPositioning,
                blockDeploy = blockDeploy,
                forceWindowActive = forceWindowActive
            }
        end

        local function isCommandantThreatStillActive()
            local threatData = self:analyzeHubThreat(currentState)
            if not threatData then
                return false, nil
            end

            local active = (threatData.isUnderAttack == true) or (threatData.isUnderProjectedThreat == true)
            return active, threatData
        end

        local function shouldSuppressDefensivePriority(priorityTag, flagName)
            -- Never suppress defensive repositioning while our Commandant is actively threatened.
            if self:isOwnHubThreatened(currentState, aiPlayer) then
                return false
            end

            local hasLegalAttack, legalAttackCount, moveAttackCount = hasThreatReleaseLegalAttack()
            if not hasLegalAttack then
                return false
            end

            local reason = nil
            local context = {
                legalAttackCount = legalAttackCount,
                moveAttackCount = moveAttackCount
            }

            local releaseState = self.threatReleaseOffenseState or {}
            local releaseConfig = self:getThreatReleaseOffenseScoreConfig()
            local defaultReleaseConfig = DEFAULT_SCORE_PARAMS.THREAT_RELEASE_OFFENSE or {}
            local releaseSuppress = valueOr(
                releaseConfig.SUPPRESS_DEFENSIVE_REPOSITION,
                valueOr(defaultReleaseConfig.SUPPRESS_DEFENSIVE_REPOSITION, false)
            )
            if releaseSuppress and releaseState.active and (releaseState.turnsRemaining or ZERO) > ZERO then
                local flagEnabled = true
                if flagName then
                    flagEnabled = valueOr(
                        releaseConfig[flagName],
                        valueOr(defaultReleaseConfig[flagName], true)
                    ) ~= false
                end
                if flagEnabled then
                    reason = "threat_release"
                    context.turnsRemaining = releaseState.turnsRemaining or ZERO
                end
            end

            if not reason then
                local drawUrgencyConfig = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or (DEFAULT_AI_PARAMS and DEFAULT_AI_PARAMS.DRAW_URGENCY) or {}
                local drawSuppress = drawUrgencyConfig.SUPPRESS_DEFENSIVE_REPOSITION == true
                local drawActive = self.drawUrgencyMode and self.drawUrgencyMode.active
                if drawSuppress and drawActive then
                    local guardSuppressed = true
                    if flagName == "SUPPRESS_GUARD_REPOSITION" then
                        guardSuppressed = drawUrgencyConfig.SUPPRESS_GUARD_REPOSITION == true
                    end
                    if guardSuppressed then
                        reason = "draw_urgency"
                        context.urgencyLevel = self.drawUrgencyMode.urgencyLevel or ZERO
                    end
                end
            end

            if not reason then
                return false
            end

            self:logDecision(priorityTag, "Suppressed defensive reposition", {
                reason = reason,
                turnsRemaining = context.turnsRemaining,
                urgencyLevel = context.urgencyLevel,
                legalAttackCount = legalAttackCount
            })
            return true
        end

        local function isStrategicPlanIntentActive()
            return strategicState
                and strategicState.active == true
                and (strategicState.intent == STRATEGY_INTENT.SIEGE_SETUP or strategicState.intent == STRATEGY_INTENT.SIEGE_EXECUTE)
        end

        local function shouldSuppressByStrategicPlan(priorityTag, suppressDeploy)
            if not isStrategicPlanIntentActive() then
                return false
            end

            if suppressDeploy then
                if strategyAdvancementConfig.SUPPRESS_GENERIC_DEPLOY_WHEN_PLAN_ACTIVE ~= true then
                    return false
                end
            else
                if strategyAdvancementConfig.SUPPRESS_GENERIC_REPOSITION_WHEN_PLAN_ACTIVE ~= true then
                    return false
                end
            end

            self:logDecision(priorityTag, "Suppressed by strategic plan advancement", {
                intent = strategicState.intent,
                planId = strategicState.planId
            })
            return true
        end

        local function runPriority13cThreatReleaseOffense()
            if sequenceFull() or (not self:isThreatReleaseOffenseActive()) then
                return
            end

            local hasLegalAttack, legalAttackCount = hasThreatReleaseLegalAttack()
            if not hasLegalAttack then
                return
            end

            self:logDecision("Priority13C", "Threat-release offense conversion active", {
                legalAttackCount = legalAttackCount
            })

            local directEntries = self:collectAttackTargetEntries(currentState, usedUnits, {
                mode = "direct",
                aiPlayer = aiPlayer,
                includeFriendlyFireCheck = true,
                requirePositiveDamage = true
            })
            local directCandidates = {}
            for _, entry in ipairs(directEntries) do
                local backedAttackOk, backedContext = self:isNonLethalAttackBacked(currentState, entry.action, {
                    horizonPlies = TWO,
                    tempoContext = tempoContext,
                    allowEmergencyDefense = true
                })
                if not backedAttackOk then
                    self.unsupportedAttackRejected = (self.unsupportedAttackRejected or ZERO) + ONE
                    self:logDecision("Priority13C", "Rejected unsupported threat-release direct attack", {
                        attacker = self:describeUnitShort(entry.unit),
                        target = entry.action and entry.action.target,
                        exchangeDelta = backedContext and backedContext.exchangeDelta or NEGATIVE_MIN_HP,
                        followupAttackers = backedContext and backedContext.followupAttackers or ZERO,
                        reason = backedContext and backedContext.reason or "unsupported_nonlethal"
                    })
                    goto continue_threat_release_direct
                end
                local context = self:getAttackOpportunityContext(currentState, entry.unit, entry.target, {
                    damage = entry.damage,
                    attackPos = {row = entry.unit.row, col = entry.unit.col},
                    includeSafeEnemyHubAdjacency = true
                })
                local value = self:getAttackOpportunityScore(
                    currentState,
                    entry.unit,
                    entry.target,
                    entry.damage,
                    entry.specialUsed,
                    context,
                    {
                        includeTargetValue = true,
                        useBaseTargetValue = true,
                        positionalUnit = entry.unit,
                        includeUnsafeEnemyHubAdj = true
                    }
                )
                directCandidates[#directCandidates + ONE] = {
                    unit = entry.unit,
                    action = entry.action,
                    value = value
                }
                ::continue_threat_release_direct::
            end

            self:sortScoredEntries(directCandidates, {
                scoreField = "value",
                descending = true
            })

            if #directCandidates > ZERO then
                applyQueuedAction(
                    directCandidates[ONE].action,
                    "THREAT_RELEASE_ATTACK",
                    directCandidates[ONE].unit,
                    "Priority13C",
                    "Selected threat-release direct attack"
                )
                return
            end

            if not canFitActions(TWO) then
                return
            end

            local moveEntries = self:collectAttackTargetEntries(currentState, usedUnits, {
                mode = "move",
                aiPlayer = aiPlayer,
                requireSafeMove = true,
                checkVulnerableMove = true,
                includeFriendlyFireCheck = true,
                requirePositiveDamage = true
            })
            local moveCandidates = {}
            for _, entry in ipairs(moveEntries) do
                local backedAttackOk, backedContext = self:isNonLethalMoveAttackBacked(
                    currentState,
                    entry.moveAction,
                    entry.attackAction,
                    {
                        horizonPlies = TWO,
                        tempoContext = tempoContext,
                        allowEmergencyDefense = true
                    }
                )
                if not backedAttackOk then
                    self.unsupportedAttackRejected = (self.unsupportedAttackRejected or ZERO) + ONE
                    self:logDecision("Priority13C", "Rejected unsupported threat-release move+attack", {
                        attacker = self:describeUnitShort(entry.unit),
                        move = entry.moveAction and entry.moveAction.target,
                        target = entry.attackAction and entry.attackAction.target,
                        exchangeDelta = backedContext and backedContext.exchangeDelta or NEGATIVE_MIN_HP,
                        followupAttackers = backedContext and backedContext.followupAttackers or ZERO,
                        reason = backedContext and backedContext.reason or "unsupported_nonlethal"
                    })
                    goto continue_threat_release_move
                end
                local attackerAtMove = self:buildProjectedThreatUnit(entry.unit, entry.moveCell.row, entry.moveCell.col) or entry.unit
                local context = self:getAttackOpportunityContext(currentState, attackerAtMove, entry.target, {
                    damage = entry.damage,
                    attackPos = {row = entry.moveCell.row, col = entry.moveCell.col},
                    includeSafeEnemyHubAdjacency = true
                })
                local value = self:getAttackOpportunityScore(
                    currentState,
                    attackerAtMove,
                    entry.target,
                    entry.damage,
                    entry.specialUsed,
                    context,
                    {
                        includeTargetValue = true,
                        useBaseTargetValue = true,
                        positionalUnit = attackerAtMove,
                        includeUnsafeEnemyHubAdj = true,
                        applyCommanderExposurePenalty = true,
                        movePos = entry.moveCell
                    }
                )
                moveCandidates[#moveCandidates + ONE] = {
                    unit = entry.unit,
                    moveAction = entry.moveAction,
                    attackAction = entry.attackAction,
                    value = value
                }
                ::continue_threat_release_move::
            end

            self:sortScoredEntries(moveCandidates, {
                scoreField = "value",
                descending = true
            })

            if #moveCandidates > ZERO and #sequence == ZERO then
                applyTwoStepAction(
                    {
                        action = moveCandidates[ONE].moveAction,
                        addTag = "THREAT_RELEASE_MOVE",
                        unit = moveCandidates[ONE].unit,
                        logTag = "Priority13C",
                        logMessage = "Selected threat-release move"
                    },
                    {
                        action = moveCandidates[ONE].attackAction,
                        addTag = "THREAT_RELEASE_MOVE_ATTACK",
                        unit = moveCandidates[ONE].unit,
                        logTag = "Priority13C",
                        logMessage = "Selected threat-release move+attack"
                    }
                )
            end
        end

        -- Priority Helpers
        local function runPriority01aStrategicDefense()
            if sequenceFull() then
                return
            end
            if not strategicState or strategicState.intent ~= STRATEGY_INTENT.DEFEND_HARD then
                return
            end

            self:logDecision("Priority01A", "Strategic defense bundle active", {
                intent = strategicState.intent,
                planId = strategicState.planId
            })

            local reserveAll = valueOr(strategyDefenseConfig.RESERVE_ALL_ACTIONS, true)
            local defenseAdded = ZERO
            local loopGuard = ZERO
            while not sequenceFull() and loopGuard < FOUR do
                loopGuard = loopGuard + ONE
                local defenseBundle = self:buildDefenseActionBundle(currentState, usedUnits)
                if not defenseBundle or #defenseBundle == ZERO then
                    break
                end

                local applied = false
                for _, entry in ipairs(defenseBundle) do
                    if sequenceFull() then
                        break
                    end

                    if entry.kind == "pair" then
                        if canFitActions(TWO) then
                            local added = applyTwoStepAction(
                                {
                                    action = entry.moveAction,
                                    addTag = entry.addTagMove or "STRATEGIC_DEFENSE_MOVE",
                                    unit = entry.unit,
                                    logTag = "Priority01A",
                                    logMessage = "Selected strategic defense move"
                                },
                                {
                                    action = entry.attackAction,
                                    addTag = entry.addTagAttack or "STRATEGIC_DEFENSE_ATTACK",
                                    unit = entry.unit,
                                    logTag = "Priority01A",
                                    logMessage = "Selected strategic defense attack"
                                }
                            )
                            if added then
                                defenseAdded = defenseAdded + TWO
                                applied = true
                                break
                            end
                        end
                    else
                        if applyQueuedAction(
                            entry.action,
                            entry.addTag or "STRATEGIC_DEFENSE_ACTION",
                            entry.unit,
                            "Priority01A",
                            "Selected strategic defense action"
                        ) then
                            defenseAdded = defenseAdded + ONE
                            applied = true
                            break
                        end
                    end
                end

                if not applied then
                    break
                end
            end

            local threatData = self:analyzeHubThreat(currentState)
            local projectedActionable = threatData and (
                threatData.projectedThreatActionable == true
                or (threatData.projectedThreatActionable == nil and threatData.isUnderProjectedThreat == true)
            )
            local unresolvedThreat = threatData and (
                threatData.isUnderAttack
                or projectedActionable
                or (self.defenseModeState and self.defenseModeState.active == true)
            )
            if reserveAll and unresolvedThreat and defenseAdded > ZERO then
                strategicDefenseLock = true
            end
        end

        local function runPriority13dStrategicPlanAdvancement()
            if sequenceFull() then
                return
            end
            if not isStrategicPlanIntentActive() then
                return
            end

            local slotsBefore = #sequence
            local loopGuard = ZERO
            while not sequenceFull() and loopGuard < FOUR do
                loopGuard = loopGuard + ONE
                local bundle = self:buildSiegeActionBundle(currentState, usedUnits)
                if not bundle or #bundle == ZERO then
                    break
                end

                local applied = false
                for _, entry in ipairs(bundle) do
                    if sequenceFull() then
                        break
                    end

                    if entry.kind == "pair" then
                        if canFitActions(TWO) then
                            if applyTwoStepAction(
                                {
                                    action = entry.moveAction,
                                    addTag = entry.addTagMove or "STRATEGIC_PLAN_MOVE",
                                    unit = entry.unit,
                                    logTag = "Priority13D",
                                    logMessage = "Selected strategic move"
                                },
                                {
                                    action = entry.attackAction,
                                    addTag = entry.addTagAttack or "STRATEGIC_PLAN_ATTACK",
                                    unit = entry.unit,
                                    logTag = "Priority13D",
                                    logMessage = "Selected strategic attack"
                                }
                            ) then
                                applied = true
                                strategicPlanAdvancedThisTurn = true
                                break
                            end
                        end
                    else
                        if applyQueuedAction(
                            entry.action,
                            entry.addTag or "STRATEGIC_PLAN_ACTION",
                            entry.unit,
                            "Priority13D",
                            "Selected strategic plan advancement action"
                        ) then
                            applied = true
                            strategicPlanAdvancedThisTurn = true
                            break
                        end
                    end
                end

                if not applied then
                    break
                end
            end

            if #sequence > slotsBefore then
                self:logDecision("PlanAdvance", "Strategic plan advanced", {
                    intent = strategicState.intent,
                    planId = strategicState.planId,
                    actionsAdded = #sequence - slotsBefore
                })
            end
        end

        local function runPriority00WinningConditions()
            -- Priority 00: WINNING CONDITIONS (Absolute highest priority)
            -- 1. Attack enemy Commandant if it can be destroyed (instant win)
            -- 2. Kill last enemy unit if enemy has no supply units left (win by elimination)
            if not sequenceFull() then
                local winningAction = self:findWinningConditionActions(currentState, usedUnits)
                if winningAction then
                    self:logDecision("Priority00", "WINNING CONDITION FOUND!", winningAction)

                    -- Handle different combo types
                    if winningAction.isTwoUnitCombo then
                        -- Two separate attacks from different units
                        applyTwoStepAction(
                            {
                                action = winningAction.action,
                                addTag = "WINNING_CONDITION_1",
                                unit = winningAction.unit,
                                logTag = "Priority00",
                                logMessage = "Executing first winning attack"
                            },
                            {
                                action = winningAction.secondAction,
                                addTag = "WINNING_CONDITION_2",
                                unit = winningAction.secondUnit,
                                logTag = "Priority00",
                                logMessage = "Executing second winning attack"
                            }
                        )
                        return sequence

                    elseif winningAction.isMoveAttackCombo then
                        -- Single unit: move then attack
                        applyTwoStepAction(
                            {
                                action = winningAction.action,
                                addTag = "WINNING_MOVE",
                                unit = winningAction.unit,
                                logTag = "Priority00",
                                logMessage = "Executing winning move"
                            },
                            {
                                action = winningAction.secondAction,
                                addTag = "WINNING_ATTACK",
                                unit = winningAction.unit,
                                logTag = "Priority00",
                                logMessage = "Executing winning attack"
                            }
                        )
                        return sequence

                    elseif winningAction.isMoveAndRangedAttack then
                        -- First unit moves, second unit (ranged) attacks
                        applyTwoStepAction(
                            {
                                action = winningAction.action,
                                addTag = "WINNING_MOVE",
                                unit = winningAction.unit,
                                logTag = "Priority00",
                                logMessage = "Executing positioning move"
                            },
                            {
                                action = winningAction.secondAction,
                                addTag = "WINNING_RANGED_ATTACK",
                                unit = winningAction.secondUnit,
                                logTag = "Priority00",
                                logMessage = "Executing ranged winning attack"
                            }
                        )
                        return sequence

                    else
                        -- Single attack
                        applyQueuedAction(
                            winningAction.action,
                            "WINNING_CONDITION",
                            winningAction.unit,
                            "Priority00",
                            "Executing winning move"
                        )
                        return sequence
                    end
                else
                    self:logDecision("Priority00", "No winning condition actions available")
                end
            end

            return nil
        end

        local function runPriority01SafeKills()
            -- Priority 01: Kill safe attacks - 1 unit action (SAFE attaker survive turn after)
            local killActions = self:findSafeKillAttacks(currentState, usedUnits)
            if killActions and #killActions > ZERO then
                self:logDecision("Priority01", "Safe kill candidates:\n" .. formatCandidates(killActions))
            else
                self:logDecision("Priority01", "No safe kill candidates")
            end
            if #killActions > ZERO then

                -- Use proper randomization: pick best value, then randomize among equal-value options
                local selectedKillAction = self:randomizeEqualValueActions(killActions, "value")

                if selectedKillAction then
                    applyQueuedAction(
                        selectedKillAction.action,
                        "SAFE_KILL",
                        selectedKillAction.unit,
                        "Priority01",
                        "Selected safe kill"
                    )
                end
            end
        end

        local function runPriority01bCommandantThreatResponse()
            if sequenceFull() then
                return
            end

            local threatConfig = self:getCommandantThreatResponseScoreConfig()
            local defaultThreatConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_THREAT_RESPONSE or {}
            local activateOnPotential = valueOr(
                threatConfig.ACTIVATE_ON_POTENTIAL,
                valueOr(defaultThreatConfig.ACTIVATE_ON_POTENTIAL, true)
            )
            local triggerThreatLevel = valueOr(
                threatConfig.TRIGGER_THREAT_LEVEL,
                valueOr(defaultThreatConfig.TRIGGER_THREAT_LEVEL, ZERO)
            )
            local hubHpTrigger = valueOr(
                threatConfig.HUB_HP_TRIGGER,
                valueOr(defaultThreatConfig.HUB_HP_TRIGGER, EIGHT)
            )
            local criticalHubHp = valueOr(
                threatConfig.CRITICAL_HUB_HP,
                valueOr(defaultThreatConfig.CRITICAL_HUB_HP, hubHpTrigger)
            )
            local emergencyThreatLevel = valueOr(
                threatConfig.EMERGENCY_THREAT_LEVEL,
                valueOr(defaultThreatConfig.EMERGENCY_THREAT_LEVEL, triggerThreatLevel)
            )
            local criticalThreatLevel = valueOr(
                threatConfig.CRITICAL_THREAT_LEVEL,
                valueOr(defaultThreatConfig.CRITICAL_THREAT_LEVEL, emergencyThreatLevel)
            )
            local maxDirectAttackChain = math.max(
                ONE,
                valueOr(threatConfig.MAX_DIRECT_ATTACK_CHAIN, valueOr(defaultThreatConfig.MAX_DIRECT_ATTACK_CHAIN, TWO))
            )
            local underAttackAllowTwoActions = valueOr(
                threatConfig.UNDER_ATTACK_ALLOW_TWO_ACTIONS,
                valueOr(defaultThreatConfig.UNDER_ATTACK_ALLOW_TWO_ACTIONS, true)
            )
            local underAttackTwoActionMinThreat = valueOr(
                threatConfig.UNDER_ATTACK_TWO_ACTIONS_MIN_THREAT,
                valueOr(defaultThreatConfig.UNDER_ATTACK_TWO_ACTIONS_MIN_THREAT, triggerThreatLevel)
            )
            local underAttackTwoActionsForRanged = valueOr(
                threatConfig.UNDER_ATTACK_TWO_ACTIONS_FOR_RANGED,
                valueOr(defaultThreatConfig.UNDER_ATTACK_TWO_ACTIONS_FOR_RANGED, true)
            )
            local threatData = self:analyzeHubThreat(currentState)
            local threatLevel = (threatData and threatData.threatLevel) or ZERO
            local immediateThreatLevel = (threatData and threatData.immediateThreatLevel) or threatLevel
            local projectedThreatLevel = (threatData and threatData.projectedThreatLevel) or ZERO
            local ownHub = currentState.commandHubs and currentState.commandHubs[aiPlayer]
            local ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO
            local severeThreat = threatLevel >= emergencyThreatLevel
                or (ownHub and ownHubHp <= hubHpTrigger)
            local criticalDefense = threatLevel >= criticalThreatLevel
                or (ownHub and ownHubHp <= criticalHubHp)
            local underImmediateThreat = threatData and threatData.isUnderAttack
            local projectedActionable = threatData and threatData.projectedThreatActionable == true
            local underProjectedThreat = projectedActionable
            local projectedActionableScore = threatData and threatData.projectedThreatActionableScore or ZERO
            local underPotentialThreat = immediateThreatLevel >= triggerThreatLevel
                or projectedActionableScore >= triggerThreatLevel
            local defenseModeActive = self.defenseModeState and self.defenseModeState.active == true
            local shouldRespond = threatData
                and (
                    underImmediateThreat
                    or underProjectedThreat
                    or defenseModeActive
                    or severeThreat
                    or (activateOnPotential and underPotentialThreat)
                )

            if not shouldRespond then
                self:logDecision("Priority01B", "No commandant threat response required", {
                    threatLevel = threatLevel,
                    ownHubHp = ownHubHp
                })
                return
            end

            self:logDecision("Priority01B", "Commandant threat response active", {
                threatType = threatData.type,
                threatLevel = threatLevel,
                immediateThreatLevel = immediateThreatLevel,
                projectedThreatLevel = projectedThreatLevel,
                lookaheadTurnsUsed = threatData.lookaheadTurnsUsed or ZERO,
                ownHubHp = ownHubHp,
                meleeThreats = threatData.meleeThreats,
                rangedThreats = threatData.rangedThreats,
                projectedThreats = threatData.threatsProjected and #threatData.threatsProjected or ZERO,
                projectedThreatActionable = projectedActionable,
                projectedThreatActionableScore = projectedActionableScore,
                defendHardReason = self.defenseModeState and self.defenseModeState.reason or nil
            })

            local defenseActionsAdded = ZERO
            local useTwoActionDefense = severeThreat
            if (not useTwoActionDefense)
                and (underImmediateThreat or underProjectedThreat)
                and underAttackAllowTwoActions then
                local threatGate = threatLevel >= underAttackTwoActionMinThreat
                local rangedGate = underAttackTwoActionsForRanged and ((threatData.rangedThreats or ZERO) > ZERO)
                useTwoActionDefense = threatGate or rangedGate
            end
            if criticalDefense then
                useTwoActionDefense = true
            end
            local maxDefenseActions = useTwoActionDefense and TWO or ONE

            if defenseActionsAdded < maxDefenseActions and maxDefenseActions >= TWO and #sequence == ZERO and canFitActions(TWO) then
                local moveThreatAttack = self:findCommandantThreatMoveAttack(currentState, usedUnits, {
                    criticalDefense = criticalDefense
                })
                if moveThreatAttack then
                    if applyTwoStepAction(
                        {
                            action = moveThreatAttack.moveAction,
                            addTag = "COMMANDANT_THREAT_MOVE",
                            unit = moveThreatAttack.unit,
                            logTag = "Priority01B",
                            logMessage = "Selected threat response move"
                        },
                        {
                            action = moveThreatAttack.attackAction,
                            addTag = "COMMANDANT_THREAT_ATTACK",
                            unit = moveThreatAttack.unit,
                            logTag = "Priority01B",
                            logMessage = "Selected threat response attack"
                        }
                    ) then
                        defenseActionsAdded = defenseActionsAdded + TWO
                    end
                end
            end

            local directAttackAttempts = ZERO
            while defenseActionsAdded < maxDefenseActions
                and not sequenceFull()
                and directAttackAttempts < maxDirectAttackChain do
                local directThreatAttack = self:findCommandantThreatDirectAttack(currentState, usedUnits, {
                    criticalDefense = criticalDefense
                })
                if not directThreatAttack then
                    break
                end

                if applyQueuedAction(
                    directThreatAttack.action,
                    "COMMANDANT_THREAT_DIRECT_ATTACK",
                    directThreatAttack.unit,
                    "Priority01B",
                    "Selected direct commandant threat attack"
                ) then
                    defenseActionsAdded = defenseActionsAdded + ONE
                    directAttackAttempts = directAttackAttempts + ONE
                else
                    break
                end
            end

            if defenseActionsAdded < maxDefenseActions and not sequenceFull() then
                local guardMove = self:findCommandantGuardMove(currentState, usedUnits)
                local counterMove = self:findThreatCounterAttackMove(currentState, usedUnits)
                local preferCounter = counterMove and (underImmediateThreat or underProjectedThreat)

                if preferCounter then
                    if applyQueuedAction(
                        counterMove.action,
                        "COMMANDANT_THREAT_COUNTER_MOVE",
                        counterMove.unit,
                        "Priority01B",
                        "Selected commandant threat counter-position (neutralization priority)"
                    ) then
                        defenseActionsAdded = defenseActionsAdded + ONE
                    end
                elseif guardMove then
                    if applyQueuedAction(
                        guardMove.action,
                        "COMMANDANT_THREAT_GUARD_MOVE",
                        guardMove.unit,
                        "Priority01B",
                        "Selected commandant guard move"
                    ) then
                        defenseActionsAdded = defenseActionsAdded + ONE
                    end
                end
            end

            if defenseActionsAdded < maxDefenseActions and not sequenceFull() then
                local unblockMove = self:findCommandantDefenseUnblockMove(currentState, usedUnits)
                if unblockMove then
                    if applyQueuedAction(
                        unblockMove.action,
                        "COMMANDANT_THREAT_UNBLOCK_MOVE",
                        unblockMove.unit,
                        "Priority01B",
                        "Selected commandant defense unblock move"
                    ) then
                        defenseActionsAdded = defenseActionsAdded + ONE
                    end
                end
            end

            if defenseActionsAdded < maxDefenseActions and not sequenceFull() then
                local emergencySupplyAction = self:findEmergencyDefensiveSupply(currentState, usedUnits)
                if emergencySupplyAction then
                    if applyQueuedAction(
                        emergencySupplyAction,
                        "COMMANDANT_THREAT_EMERGENCY_SUPPLY",
                        nil,
                        "Priority01B",
                        "Selected emergency defensive supply"
                    ) then
                        defenseActionsAdded = defenseActionsAdded + ONE
                    end
                end
            end

            if defenseActionsAdded < maxDefenseActions and not sequenceFull() then
                local counterMove = self:findThreatCounterAttackMove(currentState, usedUnits)
                if counterMove then
                    if applyQueuedAction(
                        counterMove.action,
                        "COMMANDANT_THREAT_COUNTER_MOVE",
                        counterMove.unit,
                        "Priority01B",
                        "Selected commandant threat counter-position"
                    ) then
                        defenseActionsAdded = defenseActionsAdded + ONE
                    end
                end
            end
        end

        local function runPriority01cPostDefenseFollowUp()
            if sequenceFull() or #sequence ~= ONE then
                return
            end
            if not sequenceHasTagPrefix("COMMANDANT_THREAT") then
                return
            end

            local threatActive, threatData = isCommandantThreatStillActive()
            if not threatActive then
                return
            end

            self:logDecision("Priority01C", "Post-defense follow-up active", {
                threatLevel = threatData and threatData.threatLevel or ZERO,
                projectedThreatLevel = threatData and threatData.projectedThreatLevel or ZERO,
                threatType = threatData and threatData.type or "none"
            })

            local counterMove = self:findThreatCounterAttackMove(currentState, usedUnits)
            if counterMove and applyQueuedAction(
                counterMove.action,
                "COMMANDANT_THREAT_FOLLOWUP_COUNTER",
                counterMove.unit,
                "Priority01C",
                "Selected post-defense counter-position"
            ) then
                return
            end

            local guardMove = self:findCommandantGuardMove(currentState, usedUnits)
            if guardMove and applyQueuedAction(
                guardMove.action,
                "COMMANDANT_THREAT_FOLLOWUP_GUARD",
                guardMove.unit,
                "Priority01C",
                "Selected post-defense guard move"
            ) then
                return
            end

            local unblockMove = self:findCommandantDefenseUnblockMove(currentState, usedUnits)
            if unblockMove and applyQueuedAction(
                unblockMove.action,
                "COMMANDANT_THREAT_FOLLOWUP_UNBLOCK",
                unblockMove.unit,
                "Priority01C",
                "Selected post-defense unblock move"
            ) then
                return
            end

            local emergencySupplyAction = self:findEmergencyDefensiveSupply(currentState, usedUnits)
            if emergencySupplyAction then
                applyQueuedAction(
                    emergencySupplyAction,
                    "COMMANDANT_THREAT_FOLLOWUP_SUPPLY",
                    nil,
                    "Priority01C",
                    "Selected post-defense emergency supply"
                )
            end
        end

        local function runPriority02SafeMoveAttackKills()
            -- Priority 02: Kill safe combo move+attack with same unit (SAFE attaker survive turn after)
            if canFitActions(TWO) then  -- Only attempt move+attack combos if we haven't used any actions yet
                local moveAttackKills = self:findSafeMoveAttackKills(currentState, usedUnits)
                if moveAttackKills and #moveAttackKills > ZERO then
                    self:logDecision("Priority02", "Move+attack kill candidates:\n" .. formatCandidates(moveAttackKills))
                else
                    self:logDecision("Priority02", "No move+attack kill candidates")
                end
                if #moveAttackKills > ZERO then
                    -- Use randomization to select from equal-value combos
                    local selectedCombo = self:randomizeEqualValueActions(moveAttackKills, "value")
                    if selectedCombo and #sequence == ZERO and not usedUnits[self:getUnitKey(selectedCombo.unit)] then  -- Must use both actions for this combo
                        local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(selectedCombo, "Priority02")
                        if not directApplied then
                            applyTwoStepAction(
                                {
                                    action = selectedCombo.moveAction,
                                    addTag = "MOVE_ATTACK_KILL_MOVE",
                                    unit = selectedCombo.unit,
                                    logTag = "Priority02",
                                    logMessage = "Selected move action"
                                },
                                {
                                    action = selectedCombo.attackAction,
                                    addTag = "MOVE_ATTACK_KILL_ATTACK",
                                    unit = selectedCombo.unit,
                                    logTag = "Priority02",
                                    logMessage = "Selected attack action"
                                }
                            )
                        elseif directPreferred then
                            self:logDecision("Priority02", "Direct preference replaced move+attack kill combo")
                        end
                    end
                end
            end
        end

        local function runPriority03TwoUnitKillCombos()
            -- Priority 03: Two units attack same enemy - first damages, second kills (Only Adjacent suicide check, no valutation is suicide is a good trade)
            if canFitActions(TWO) then
                local twoUnitKills = self:findTwoUnitKillCombinations(currentState, usedUnits, true)
                if twoUnitKills and #twoUnitKills > ZERO then
                    self:logDecision("Priority03", "Two-unit kill combos", twoUnitKills)
                else
                    self:logDecision("Priority03", "No two-unit kill combos")
                end
                if #twoUnitKills > ZERO then
                    -- Use first valid combo (no randomization)
                    for _, combo in ipairs(twoUnitKills) do
                        if #sequence + TWO <= maxActions and not usedUnits[self:getUnitKey(combo.damager)] and not usedUnits[self:getUnitKey(combo.killer)] then
                            if applyTwoStepAction(
                                {
                                    action = combo.damageAction,
                                    addTag = "TWO_UNIT_KILL_DAMAGE",
                                    unit = combo.damager,
                                    logTag = "Priority03",
                                    logMessage = "Selected damage action"
                                },
                                {
                                    action = combo.killAction,
                                    addTag = "TWO_UNIT_KILL_FINISH",
                                    unit = combo.killer,
                                    logTag = "Priority03",
                                    logMessage = "Selected kill action"
                                }
                            ) then
                                break  -- Exit after first successful combo
                            end
                        end
                    end
                end
            end
        end

        local function runPriority04CorvetteLineOfSightKills()
            -- Priority 04: Cloudstriker line-of-sight kill (move first a unit to clear the path + Corvette shoot, safe to adjacent attack and move+attack)
            if canFitActions(TWO) then
                local cloudstrikerKills = self:findCorvetteLineOfSightKills(currentState, usedUnits)
                if cloudstrikerKills and #cloudstrikerKills > ZERO then
                    self:logDecision("Priority04", "Cloudstriker LoS kill options", cloudstrikerKills)
                else
                    self:logDecision("Priority04", "No Cloudstriker LoS kill options")
                end
                if #cloudstrikerKills > ZERO then
                    -- Use first valid combo (no randomization)
                    for _, combo in ipairs(cloudstrikerKills) do
                        if #sequence + TWO <= maxActions and not usedUnits[self:getUnitKey(combo.mover)] and not usedUnits[self:getUnitKey(combo.cloudstriker)] then
                            if applyTwoStepAction(
                                {
                                    action = combo.moveAction,
                                    addTag = "CLOUDSTRIKER_KILL_MOVE",
                                    unit = combo.mover
                                },
                                {
                                    action = combo.attackAction,
                                    addTag = "CLOUDSTRIKER_KILL_ATTACK",
                                    unit = combo.cloudstriker
                                }
                            ) then
                                break  -- Exit after first successful combo
                            end
                        end
                    end
                end
            end
        end

        local function runPriority05NotSoSafeKillsWithSuicideCheck()
            -- Priority 05: Kill attacks - 1 unit action (Only check if suicide is a good trade)
            if not sequenceFull() then
                local killActions = self:findNotSoSafeKillAttacks(currentState, usedUnits)
                if #killActions > ZERO then
                    self:logDecision("Priority05", "Not so safe kill candidates with suicide trade check", killActions)

                    -- Use proper randomization: pick best value, then randomize among equal-value options
                    local selectedKillAction = self:randomizeEqualValueActions(killActions, "value")

                    if selectedKillAction then
                        self:logDecision("Priority05", "Evaluating selected kill action", selectedKillAction)
                        local targetPos = selectedKillAction.action and selectedKillAction.action.target
                        local targetUnit = targetPos and self:getUnitAtPosition(currentState, targetPos.row, targetPos.col)

                        if targetUnit then
                            local attackAllowed, safetyReason = self:isAttackSafe(currentState, selectedKillAction.unit, targetUnit, {
                                allowBeneficialSuicide = true
                            })

                            if attackAllowed then
                                self:logDecision("Priority05", "Attack accepted by safety policy", {
                                    unit = selectedKillAction.unit,
                                    target = targetUnit,
                                    reason = safetyReason
                                })
                                applyQueuedAction(
                                    selectedKillAction.action,
                                    "SAFE_KILL",
                                    selectedKillAction.unit,
                                    "Priority05",
                                    "Selected safe kill after suicide check"
                                )
                            else
                                self:logDecision("Priority05", "Attack rejected by safety policy", {
                                    unit = selectedKillAction.unit,
                                    target = targetUnit,
                                    reason = safetyReason
                                })
                            end
                        else
                            self:logDecision("Priority05", "Target unit missing for selected kill action", targetPos)
                        end
                    else
                        self:logDecision("Priority05", "No kill action selected from candidates")
                    end
                else
                    self:logDecision("Priority05", "No safe kill candidates with suicide trade check")
                end

                if sequenceFull() then
                    return sequence
                end
            else
                self:logDecision("Priority06", "Skipped (insufficient action slots)")
            end
        end

        local function runPriority06MoveAttackKillsWithSuicideCheck()
            -- Priority 06: Kill combo move+attack with same unit (Only check if suicide is a good trade)
            if canFitActions(TWO) then  -- Only attempt move+attack combos if we haven't used any actions yet
                local moveAttackKills = self:findNotSoSafeMoveAttackKills(currentState, usedUnits)
                if #moveAttackKills > ZERO then
                    self:logDecision("Priority06", "Move+attack kill candidates with suicide trade check", moveAttackKills)
                    -- Use randomization to select from equal-value combos
                    local selectedCombo = self:randomizeEqualValueActions(moveAttackKills, "value")
                    if selectedCombo and #sequence == ZERO and not usedUnits[self:getUnitKey(selectedCombo.unit)] then  -- Must use both actions for this combo
                        self:logDecision("Priority06", "Evaluating selected combo", selectedCombo)
                        local attackTargetPos = selectedCombo.attackAction and selectedCombo.attackAction.target
                        local attackTargetUnit = attackTargetPos and self:getUnitAtPosition(currentState, attackTargetPos.row, attackTargetPos.col)

                        if attackTargetUnit then
                            local projectedAttacker = selectedCombo.unit
                            if selectedCombo.moveAction and selectedCombo.moveAction.target then
                                projectedAttacker = self:buildProjectedThreatUnit(
                                    selectedCombo.unit,
                                    selectedCombo.moveAction.target.row,
                                    selectedCombo.moveAction.target.col
                                ) or selectedCombo.unit
                            end

                            local attackAllowed, safetyReason = self:isAttackSafe(currentState, projectedAttacker, attackTargetUnit, {
                                allowBeneficialSuicide = true
                            })

                            if attackAllowed then
                                self:logDecision("Priority06", "Combo accepted by safety policy", {
                                    unit = selectedCombo.unit,
                                    target = attackTargetUnit,
                                    reason = safetyReason
                                })
                                local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(selectedCombo, "Priority06")
                                if not directApplied then
                                    applyTwoStepAction(
                                        {
                                            action = selectedCombo.moveAction,
                                            addTag = "MOVE_ATTACK_KILL_MOVE",
                                            unit = selectedCombo.unit,
                                            logTag = "Priority06",
                                            logMessage = "Selected move portion of combo"
                                        },
                                        {
                                            action = selectedCombo.attackAction,
                                            addTag = "MOVE_ATTACK_KILL_ATTACK",
                                            unit = selectedCombo.unit,
                                            logTag = "Priority06",
                                            logMessage = "Selected attack portion of combo"
                                        }
                                    )
                                elseif directPreferred then
                                    self:logDecision("Priority06", "Direct preference replaced move+attack kill combo")
                                end
                            else
                                self:logDecision("Priority06", "Combo rejected by safety policy", {
                                    unit = selectedCombo.unit,
                                    target = attackTargetUnit,
                                    reason = safetyReason
                                })
                            end
                        else
                            self:logDecision("Priority06", "Attack target missing for combo", attackTargetPos)
                        end
                    else
                        self:logDecision("Priority06", "No eligible combo selected", selectedCombo)
                    end
                else
                    self:logDecision("Priority06", "No move+attack kill candidates with suicide trade check")
                end
            end
        end

        local function runPriority07NotSoSafeKills()
            -- Priority 07: Kill attacks (No suicide check, single unit attack kill)
            if not sequenceFull() then
                local killActions = self:findNotSoSafeKillAttacks(currentState, usedUnits)
                if #killActions > ZERO then
                    self:logDecision("Priority07", "Not-so-safe kill candidates:\n" .. formatCandidates(killActions))
                    for _, killAction in ipairs(killActions) do
                        if applyQueuedAction(
                            killAction.action,
                            "NOT_SO_SAFE_KILL",
                            killAction.unit,
                            "Priority07",
                            "Selected not-so-safe kill"
                        ) then
                            break  -- Only add one kill per priority
                        end
                    end
                else
                    self:logDecision("Priority07", "No not-so-safe kill candidates")
                end
            else
            end
        end

        local function runPriority08TwoUnitKillCombosNoSafety()
            -- Priority 08: Two units attack same enemy - first damages, second kills (No suicide checks)
            if canFitActions(TWO) then
                local twoUnitKills = self:findTwoUnitKillCombinations(currentState, usedUnits)
                if twoUnitKills and #twoUnitKills > ZERO then
                    self:logDecision("Priority08", "No safe two-unit kill combos", twoUnitKills)
                else
                    self:logDecision("Priority08", "No safe two-unit kill combos")
                end
                if #twoUnitKills > ZERO then
                    -- Use first valid combo (no randomization)
                    for _, combo in ipairs(twoUnitKills) do
                        if #sequence + TWO <= maxActions and not usedUnits[self:getUnitKey(combo.damager)] and not usedUnits[self:getUnitKey(combo.killer)] then
                            if applyTwoStepAction(
                                {
                                    action = combo.damageAction,
                                    addTag = "TWO_UNIT_KILL_DAMAGE",
                                    unit = combo.damager,
                                    logTag = "Priority08",
                                    logMessage = "Selected damage action"
                                },
                                {
                                    action = combo.killAction,
                                    addTag = "TWO_UNIT_KILL_FINISH",
                                    unit = combo.killer,
                                    logTag = "Priority08",
                                    logMessage = "Selected kill action"
                                }
                            ) then
                                break  -- Exit after first successful combo
                            end
                        end
                    end
                end
            end
        end

        local function runPriority09NotSoSafeMoveAttackKillsAndThreats()
            -- Priority 09: Kill combo move+attack with same unit (No suicide check)
            if canFitActions(TWO) then
                local moveAttackKills = self:findNotSoSafeMoveAttackKills(currentState, usedUnits)
                if #moveAttackKills > ZERO then
                    self:logDecision("Priority09", "Not-so-safe move+attack kill candidates:\n" .. formatCandidates(moveAttackKills))
                    for _, combo in ipairs(moveAttackKills) do
                        if not usedUnits[self:getUnitKey(combo.unit)] then
                            local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(combo, "Priority09")
                            if not directApplied then
                                applyTwoStepAction(
                                    {
                                        action = combo.moveAction,
                                        addTag = "NOT_SO_SAFE_MOVE_ATTACK_KILL_MOVE",
                                        unit = combo.unit,
                                        logTag = "Priority09",
                                        logMessage = "Selected move action"
                                    },
                                    {
                                        action = combo.attackAction,
                                        addTag = "NOT_SO_SAFE_MOVE_ATTACK_KILL_ATTACK",
                                        unit = combo.unit,
                                        logTag = "Priority09",
                                        logMessage = "Selected attack action"
                                    }
                                )
                            elseif directPreferred then
                                self:logDecision("Priority09", "Direct preference replaced move+attack kill combo")
                            end
                            break  -- Only do one move+attack combo
                        end
                    end
                else
                    self:logDecision("Priority09", "No not-so-safe move+attack kill candidates")
                end
            else
            end

            if not sequenceFull() then
                local emergencySupplyAction = self:findEmergencyDefensiveSupply(currentState, usedUnits)
                if emergencySupplyAction then
                    self:logDecision("Priority09", "Emergency supply candidate", emergencySupplyAction)
                    if applyQueuedAction(
                        emergencySupplyAction,
                        "EMERGENCY_SUPPLY_DEPLOY",
                        nil,
                        "Priority09",
                        "Selected emergency supply"
                    ) then
                        -- handled by helper
                    else
                        self:logDecision("Priority09", "Failed to add emergency supply", emergencySupplyAction)
                    end
                end
            end

            if not sequenceFull() then
                local counterMove = self:findThreatCounterAttackMove(currentState, usedUnits)
                if counterMove then
                    self:logDecision("Priority09", "Threat counter-attack positioning candidate", counterMove)
                    applyQueuedAction(
                        counterMove.action,
                        "THREAT_COUNTER_POSITION",
                        counterMove.unit,
                        "Priority09",
                        "Selected threat counter-attack positioning"
                    )
                end
            end
        end

        local function runPriority25SurvivalRepairs()
            -- Priority 25: Repair actions for survival (up to 1 repair units, no movement, must guarantee survival)
            if not sequenceFull() then
                local repairActions = self:findSurvivalRepairActions(currentState, usedUnits)
                if #repairActions > ZERO then
                    self:logDecision("Priority25", "Survival repair candidates:\n" .. formatCandidates(repairActions))
                else
                    self:logDecision("Priority25", "No survival repair candidates")
                end
                for _, repairAction in ipairs(repairActions) do
                    if sequenceFull() then
                        break
                    end
                    applyQueuedAction(
                        repairAction.action,
                        "SURVIVAL_REPAIR",
                        repairAction.unit,
                        "Priority25",
                        "Selected survival repair"
                    )
                end
            end
        end

        local function runPriority26SurvivalMoveRepairs()
            -- Priority 26: Move+repair actions for survival (only if sequence == 0, up to 2 combos, must guarantee survival)
            if canFitActions(TWO) then
                local moveRepairActions = self:findSurvivalMoveRepairActions(currentState, usedUnits)
                if #moveRepairActions > ZERO then
                    self:logDecision("Priority26", "Survival move+repair candidates:\n" .. formatCandidates(moveRepairActions))
                else
                    self:logDecision("Priority26", "No survival move+repair candidates")
                end
                for _, moveRepairAction in ipairs(moveRepairActions) do
                    if sequenceFull() then
                        break
                    end
                    applyTwoStepAction(
                        {
                            action = moveRepairAction.moveAction,
                            addTag = "SURVIVAL_MOVE_REPAIR_MOVE",
                            unit = moveRepairAction.unit,
                            logTag = "Priority26",
                            logMessage = "Selected survival move"
                        },
                        {
                            action = moveRepairAction.repairAction,
                            addTag = "SURVIVAL_MOVE_REPAIR_REPAIR",
                            unit = moveRepairAction.unit,
                            logTag = "Priority26",
                            logMessage = "Selected survival repair"
                        }
                    )
                end
            end
        end

        local function runPriority11HighValueSafeAttacks()
            -- Priority 11: High-value attacks (Suicide check)
            if not sequenceFull() then
                local valueActions = self:findHighValueSafeAttacks(currentState, usedUnits)
                if #valueActions > ZERO then
                    self:logDecision("Priority11", "High-value safe attack candidates:\n" .. formatCandidates(valueActions))
                else
                    self:logDecision("Priority11", "No high-value safe attack candidates")
                end

                local attacksAdded = ZERO
                for _, valueAction in ipairs(valueActions) do
                    if sequenceFull() then
                        break  -- Sequence is full
                    end
                    local backedAttackOk, backedContext = self:isNonLethalAttackBacked(currentState, valueAction.action, {
                        horizonPlies = TWO
                    })
                    if not backedAttackOk then
                        self.unsupportedAttackRejected = (self.unsupportedAttackRejected or ZERO) + ONE
                        self:logDecision("Priority11", "Rejected unsupported non-lethal high-value attack", {
                            unit = valueAction.unit and self:describeUnitShort(valueAction.unit) or "unknown",
                            action = valueAction.action,
                            exchangeDelta = backedContext and backedContext.exchangeDelta or nil,
                            followupAttackers = backedContext and backedContext.followupAttackers or ZERO
                        })
                        goto continue_priority11_attack
                    end
                    if applyQueuedAction(
                        valueAction.action,
                        "VALUE",
                        valueAction.unit,
                        "Priority11",
                        "Selected high-value attack"
                    ) then
                        attacksAdded = attacksAdded + ONE
                        requestSupport(valueAction.unit, valueAction.action, "Priority11Support", "attack")
                        if attacksAdded >= TWO then
                            break  -- Maximum two attacks from this priority
                        end
                    end
                    ::continue_priority11_attack::
                end
            end
        end

        local function runPriority11bDoomedEliminations()
            if sequenceFull() then
                return
            end

            local doomedAttack = self:findLastAttackForDoomedUnits(currentState, usedUnits, {
                requireLethalOnly = true,
                includeFinishers = false
            })
            if doomedAttack then
                self:logDecision("Priority11B", "Doomed lethal attack candidate", doomedAttack)
                applyQueuedAction(
                    doomedAttack.action,
                    "DOOMED_LETHAL_ATTACK",
                    doomedAttack.unit,
                    "Priority11B",
                    "Selected doomed lethal attack"
                )
            end

            if #sequence == ZERO and canFitActions(TWO) then
                local doomedMoveAttack = self:findLastMoveAttackForDoomedUnits(currentState, usedUnits, {
                    requireLethalOnly = true,
                    includeFinishers = false
                })
                if doomedMoveAttack then
                    self:logDecision("Priority11B", "Doomed lethal move+attack candidate", doomedMoveAttack)
                    applyTwoStepAction(
                        {
                            action = doomedMoveAttack.moveAction,
                            addTag = "DOOMED_LETHAL_MOVE",
                            unit = doomedMoveAttack.unit,
                            logTag = "Priority11B",
                            logMessage = "Selected doomed lethal move"
                        },
                        {
                            action = doomedMoveAttack.attackAction,
                            addTag = "DOOMED_LETHAL_ATTACK",
                            unit = doomedMoveAttack.unit,
                            logTag = "Priority11B",
                            logMessage = "Selected doomed lethal attack"
                        }
                    )
                end
            end
        end

        local function runPriority10SafeEvasion()
            -- Priority 10: Evade from secure kill next turn (with safe position control + check against to move+attack)
            if shouldSuppressDefensivePriority("Priority10", "SUPPRESS_DEFENSIVE_REPOSITION") then
                return
            end
            if not sequenceFull() then
                local evasionActions = self:findSafeEvasionMoves(currentState, usedUnits)
                if #evasionActions > ZERO then
                    self:logDecision("Priority10", "Safe evasion candidates:\n" .. formatCandidates(evasionActions))
                else
                    self:logDecision("Priority10", "No safe evasion candidates")
                end

                local evasionsAdded = ZERO
                for _, evasionAction in ipairs(evasionActions) do
                    if sequenceFull() then
                        break  -- Sequence is full
                    end
                    if applyQueuedAction(
                        evasionAction.action,
                        "SAFE_EVASION",
                        evasionAction.unit,
                        "Priority10",
                        "Selected evasion action"
                    ) then
                        evasionsAdded = evasionsAdded + ONE
                        if evasionsAdded >= TWO then
                            break  -- Maximum two evasion moves from this priority
                        end
                    end
                end
            end
        end

        local function runPriority10bSingleUnitTwoActionPressure()
            if #sequence ~= ZERO or not canFitActions(TWO) then
                return
            end

            local legalActions = self:collectLegalActions(currentState, {
                aiPlayer = aiPlayer,
                usedUnits = usedUnits,
                includeMove = true,
                includeAttack = true,
                includeRepair = true,
                includeDeploy = false
            })

            local uniqueUnits = {}
            local uniqueCount = ZERO
            for _, action in ipairs(legalActions) do
                if action.unit and action.unit.row and action.unit.col then
                    local key = string.format("%d,%d", action.unit.row, action.unit.col)
                    if not uniqueUnits[key] then
                        uniqueUnits[key] = true
                        uniqueCount = uniqueCount + ONE
                    end
                end
            end

            if uniqueCount ~= ONE then
                return
            end

            local combos = self:findMoveAttackCombinations(currentState, usedUnits)
            if not combos or #combos == ZERO then
                return
            end

            local selectedUnitKey = nil
            for key in pairs(uniqueUnits) do
                selectedUnitKey = key
                break
            end

            local selectedCombo = nil
            for _, combo in ipairs(combos) do
                local comboKey = combo.unit and self:getUnitKey(combo.unit)
                if comboKey and comboKey == selectedUnitKey then
                    selectedCombo = combo
                    break
                end
            end

            if not selectedCombo then
                return
            end

            self:logDecision("Priority10B", "Single-unit pressure combo selected", selectedCombo)
            applyTwoStepAction(
                {
                    action = selectedCombo.moveAction,
                    addTag = "SINGLE_UNIT_PRESSURE_MOVE",
                    unit = selectedCombo.unit,
                    logTag = "Priority10B",
                    logMessage = "Selected single-unit pressure move"
                },
                {
                    action = selectedCombo.attackAction,
                    addTag = "SINGLE_UNIT_PRESSURE_ATTACK",
                    unit = selectedCombo.unit,
                    logTag = "Priority10B",
                    logMessage = "Selected single-unit pressure attack"
                }
            )
        end

        local function runPriority12SupportFollowUp()
            -- Priority 12: Ranged support follow-up (optional positioning after opening ranged attack)
            if not sequenceFull() and not rangedSupportPriorityChecked then
                runSupportFollowUp("Priority12")
            end
        end

        local function runPriority13HighValueAttacks()
            -- Priority 13: High-value attacks (No suicide check)
            if not sequenceFull() then
                local valueActions = self:findHighValueAttacks(currentState, usedUnits)
                if #valueActions > ZERO then
                    self:logDecision("Priority13", "High-value attack candidates:\n" .. formatCandidates(valueActions))
                else
                    self:logDecision("Priority13", "No high-value attack candidates")
                end

                local attacksAdded = ZERO
                for _, valueAction in ipairs(valueActions) do
                    if sequenceFull() then
                        break  -- Sequence is full
                    end
                    local backedAttackOk, backedContext = self:isNonLethalAttackBacked(currentState, valueAction.action, {
                        horizonPlies = TWO
                    })
                    if not backedAttackOk then
                        self.unsupportedAttackRejected = (self.unsupportedAttackRejected or ZERO) + ONE
                        self:logDecision("Priority13", "Rejected unsupported non-lethal high-value attack", {
                            unit = valueAction.unit and self:describeUnitShort(valueAction.unit) or "unknown",
                            action = valueAction.action,
                            exchangeDelta = backedContext and backedContext.exchangeDelta or nil,
                            followupAttackers = backedContext and backedContext.followupAttackers or ZERO
                        })
                        goto continue_priority13_attack
                    end
                    if applyQueuedAction(
                        valueAction.action,
                        "VALUE",
                        valueAction.unit,
                        "Priority13",
                        "Selected high-value attack"
                    ) then
                        attacksAdded = attacksAdded + ONE
                        requestSupport(valueAction.unit, valueAction.action, "Priority13Support", "attack")
                        if attacksAdded >= TWO then
                            break  -- Maximum two attacks from this priority
                        end
                    end
                    ::continue_priority13_attack::
                end
            end
        end

        local function runPriority13bisMoveAttackCombos()
            -- Priority 13bis: Move+attack combinations (Adjacent suicide check + Vulnerability to move+attack)
            if canFitActions(TWO) then  -- Only attempt move+attack combos if we haven't used any actions yet
                local moveAttackCombos = self:findMoveAttackCombinations(currentState, usedUnits)
                if #moveAttackCombos > ZERO then
                    self:logDecision("Priority13", "Move+attack combo candidates:\n" .. formatCandidates(moveAttackCombos))
                else
                    self:logDecision("Priority13", "No move+attack combo candidates")
                end
                for _, combo in ipairs(moveAttackCombos) do
                    if #sequence == ZERO and not usedUnits[self:getUnitKey(combo.unit)] then  -- Must use both actions for this combo
                        if shouldRejectEarlyExposedMoveAttack(combo, "Priority13") then
                            goto continue_priority13_combo
                        end
                        local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(combo, "Priority13")
                        if not directApplied then
                            applyTwoStepAction(
                                {
                                    action = combo.moveAction,
                                    addTag = "SAFE_MOVE_ATTACK_COMBO_MOVE",
                                    unit = combo.unit,
                                    logTag = "Priority13",
                                    logMessage = "Selected safe move action"
                                },
                                {
                                    action = combo.attackAction,
                                    addTag = "SAFE_MOVE_ATTACK_COMBO_ATTACK",
                                    unit = combo.unit,
                                    logTag = "Priority13",
                                    logMessage = "Selected safe attack action"
                                }
                            )
                        elseif directPreferred then
                            self:logDecision("Priority13", "Direct preference replaced move+attack combo")
                        end
                        break  -- Only do one move+attack combo per turn
                    end
                    ::continue_priority13_combo::
                end
            end
        end

        local function runPriority13CommandantGuardMove()
            if shouldSuppressDefensivePriority("Priority13", "SUPPRESS_GUARD_REPOSITION") then
                return
            end
            if shouldSuppressByStrategicPlan("Priority13", false) then
                return
            end
            if not sequenceFull() then
                local guardMove = self:findCommandantGuardMove(currentState, usedUnits)
                if guardMove then
                    self:logDecision("Priority13", "Commandant guard move candidate", guardMove)
                    applyQueuedAction(
                        guardMove.action,
                        "COMMANDANT_GUARD_MOVE",
                        guardMove.unit,
                        "Priority13",
                        "Selected commandant guard move"
                    )
                end
            end
        end

        local function runPriority14BeneficialNoDamageMoves()
            -- Priority 14: Beneficial positioning (Safe No Damage Move)
            if shouldSuppressDefensivePriority("Priority14", "SUPPRESS_DEFENSIVE_REPOSITION") then
                return
            end
            if shouldSuppressByStrategicPlan("Priority14", false) then
                return
            end
            if sequenceHasTagPrefix("COMMANDANT_THREAT") then
                local threatActive, threatData = isCommandantThreatStillActive()
                if threatActive then
                    self:logDecision("Priority14", "Skipped during active commandant threat follow-up window", {
                        threatLevel = threatData and threatData.threatLevel or ZERO,
                        projectedThreatLevel = threatData and threatData.projectedThreatLevel or ZERO
                    })
                    return
                end
            end
            local forceInteraction, interactionContext = shouldForceInteractionBeforePositioning()
            if forceInteraction and interactionContext and interactionContext.blockPositioning then
                self:logDecision("Priority14", "Suppressed by draw-urgency interaction gate", interactionContext)
                return
            end
            if not sequenceFull() then
                local beneficialActions = self:findBeneficialNoDamageMoves(currentState, usedUnits)
                if #beneficialActions > ZERO then
                    self:logDecision("Priority14", "Safe positioning move candidates:\n" .. formatCandidates(beneficialActions))
                else
                    self:logDecision("Priority14", "No safe positioning move candidates")
                end

                local movesAdded = ZERO

            local nonHealerActions = {}
            local healerActions = {}
            for _, beneficialAction in ipairs(beneficialActions) do
                if beneficialAction.unit and self:unitHasTag(beneficialAction.unit, "healer") then
                    healerActions[#healerActions + ONE] = beneficialAction
                else
                    nonHealerActions[#nonHealerActions + ONE] = beneficialAction
                end
            end

                local function processBeneficialList(actionList)
                    for _, beneficialAction in ipairs(actionList) do
                        if sequenceFull() then
                            break  -- Sequence is full
                        end
                        if applyQueuedAction(
                            beneficialAction.action,
                            "SAFE_POSITIONING_MOVE",
                            beneficialAction.unit,
                            "Priority14",
                            "Selected safe positioning move"
                        ) then
                            movesAdded = movesAdded + ONE
                            requestSupport(beneficialAction.unit, beneficialAction.action, "Priority14Support", "move")
                            if movesAdded >= ONE then
                                break  -- Priority14 commits at most one positioning move.
                            end
                        end
                    end
                end

                processBeneficialList(nonHealerActions)

                if movesAdded == ZERO and not sequenceFull() and #healerActions > ZERO then
                    processBeneficialList(healerActions)
                end
            end
        end

        local function runPriority15MoveAttackCombosNoSafety()
            -- Priority 15: Move+attack combinations (No Suicide Check)
            if canFitActions(TWO) then  -- Only attempt move+attack combos if we haven't used any actions yet
                local moveAttackCombos = self:findNotSoSafeMoveAttackCombinations(currentState, usedUnits)
                if #moveAttackCombos > ZERO then
                    self:logDecision("Priority15", "Move+attack combo candidates:\n" .. formatCandidates(moveAttackCombos))
                else
                    self:logDecision("Priority15", "No move+attack combo candidates")
                end
                for _, combo in ipairs(moveAttackCombos) do
                    if #sequence == ZERO and not usedUnits[self:getUnitKey(combo.unit)] then  -- Must use both actions for this combo
                        if shouldRejectEarlyExposedMoveAttack(combo, "Priority15") then
                            goto continue_priority15_combo
                        end
                        local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(combo, "Priority15")
                        if not directApplied then
                            applyTwoStepAction(
                                {
                                    action = combo.moveAction,
                                    addTag = "NOT_SAFE_MOVE_ATTACK_COMBO_MOVE",
                                    unit = combo.unit,
                                    logTag = "Priority15",
                                    logMessage = "Selected move action"
                                },
                                {
                                    action = combo.attackAction,
                                    addTag = "NOT_SAFE_MOVE_ATTACK_COMBO_ATTACK",
                                    unit = combo.unit,
                                    logTag = "Priority15",
                                    logMessage = "Selected attack action"
                                }
                            )
                        elseif directPreferred then
                            self:logDecision("Priority15", "Direct preference replaced move+attack combo")
                        end
                        break  -- Only do one move+attack combo per turn
                    end
                    ::continue_priority15_combo::
                end
            end
        end

        local function runPriority16LastAttack()
            -- Priority 16: Last attack for units that will die next turn
            if #sequence == ONE then
                local lastAttackAction = self:findLastAttackForDoomedUnits(currentState, usedUnits)
                if lastAttackAction then
                    self:logDecision("Priority16", "Last attack candidate", lastAttackAction)
                else
                    self:logDecision("Priority16", "No last attack candidate")
                end
                if lastAttackAction then
                    applyQueuedAction(
                        lastAttackAction.action,
                        "LAST_ATTACK",
                        lastAttackAction.unit,
                        "Priority16",
                        "Selected last attack"
                    )
                end
            end
        end

        local function runPriority17LastMoveAttack()
            -- Priority 17: Last move+attack for units that will die next turn (2-action combo)
            if canFitActions(TWO) then
                local lastMoveAttackAction = self:findLastMoveAttackForDoomedUnits(currentState, usedUnits)
                if lastMoveAttackAction then
                    self:logDecision("Priority17", "Last move+attack candidate", lastMoveAttackAction)
                else
                    self:logDecision("Priority17", "No last move+attack candidate")
                end
                if lastMoveAttackAction then
                    local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(lastMoveAttackAction, "Priority17")
                    if not directApplied then
                        applyTwoStepAction(
                            {
                                action = lastMoveAttackAction.moveAction,
                                addTag = "LAST_MOVE",
                                unit = lastMoveAttackAction.unit,
                                logTag = "Priority17",
                                logMessage = "Selected last move"
                            },
                            {
                                action = lastMoveAttackAction.attackAction,
                                addTag = "LAST_ATTACK",
                                unit = lastMoveAttackAction.unit,
                                logTag = "Priority17",
                                logMessage = "Selected last attack"
                            }
                        )
                    elseif directPreferred then
                        self:logDecision("Priority17", "Direct preference replaced doomed move+attack")
                    end
                end
            end
        end

        local function runPriority18HubSpaceCreation()
            -- Priority 18: If hub has no free cell, move adjacent unit to beneficial position (Adjacent suicide check + Vulnerability to move+attack)
            if shouldSuppressDefensivePriority("Priority18", "SUPPRESS_DEFENSIVE_REPOSITION") then
                return
            end
            if canFitActions(TWO) then
                local aiPlayer = self:getFactionId()
                if not aiPlayer then
                    return
                end
                local ownHub = currentState.commandHubs and currentState.commandHubs[aiPlayer]
                local hasAdjacentFreeCell = false

                if ownHub then
                    local freeCells = self:getFreeCellsAroundHub(currentState, ownHub, true)
                    hasAdjacentFreeCell = freeCells and #freeCells > ZERO
                end

                if not hasAdjacentFreeCell then
                    local hubSpaceAction = self:findHubSpaceCreationMove(currentState, usedUnits)
                    if hubSpaceAction then
                        self:logDecision("Priority18", "Hub space creation candidate", hubSpaceAction)
                    else
                        self:logDecision("Priority18", "No hub space creation candidate")
                    end
                    if hubSpaceAction then
                        applyQueuedAction(
                            hubSpaceAction.action,
                            "HUB_SPACE",
                            hubSpaceAction.unit,
                            "Priority18",
                            "Selected hub space action"
                        )
                    else
                    end
                else
                end
            end
        end

        local function runPriority19EnhancedSupplyDeployment()
            -- Priority 19: Enhanced Supply Deployment (if needed and available)
            if shouldSuppressByStrategicPlan("Priority19", true) then
                return
            end
            if sequenceHasTagPrefix("COMMANDANT_THREAT") then
                local threatActive, threatData = isCommandantThreatStillActive()
                if threatActive then
                    self:logDecision("Priority19", "Skipped during active commandant threat follow-up window", {
                        threatLevel = threatData and threatData.threatLevel or ZERO,
                        projectedThreatLevel = threatData and threatData.projectedThreatLevel or ZERO
                    })
                    return
                end
            end
            local forceInteraction, interactionContext = shouldForceInteractionBeforePositioning()
            if forceInteraction and interactionContext and interactionContext.blockDeploy then
                self:logDecision("Priority19", "Suppressed by draw-urgency interaction gate", interactionContext)
                return
            end
            if not sequenceFull() then
                local supplyDeploymentAction = self:getPlannedDeploymentCandidate(currentState, usedUnits)
                if supplyDeploymentAction then
                    self:logDecision("Priority19", "Enhanced supply deployment candidate", supplyDeploymentAction)
                else
                    self:logDecision("Priority19", "No enhanced supply deployment candidate")
                end
                if supplyDeploymentAction then
                    applyQueuedAction(
                        supplyDeploymentAction,
                        "SUPPLY_DEPLOY",
                        nil,
                        "Priority19",
                        "Selected enhanced supply deployment"
                    )
                end
            end
        end

        local function runPriority20RiskyValuableAttacks()
            -- Priority 20: Risky but potentially valuable attacks (2+ damage, not special/1HP, only if sequence == 1) (Only Adjacent Cells suicide control)
            if shouldSuppressRiskyTier("Priority20") then
                return
            end
            if not sequenceFull() then
                local riskyAttackActions = self:findRiskyValuableAttacks(currentState, usedUnits)
                if riskyAttackActions then
                    self:logDecision("Priority22", "Risky valuable attack candidate", riskyAttackActions)
                else
                    self:logDecision("Priority22", "No risky valuable attack candidate")
                end

                local riskyAttacksAdded = ZERO
                if riskyAttackActions then
                    -- Note: findRiskyValuableAttacks returns a single action, not an array
                    if applyQueuedAction(
                        riskyAttackActions.action,
                        "RISKY_ATTACK",
                        riskyAttackActions.unit,
                        "Priority20",
                        "Selected risky valuable attack"
                    ) then
                        riskyAttacksAdded = riskyAttacksAdded + ONE
                        consumeRiskyAction()
                    end

                    -- Try to find a second risky attack if we still have actions available
                    if not sequenceFull() and riskyAttacksAdded < TWO then
                        local secondRiskyAttack = self:findRiskyValuableAttacks(currentState, usedUnits)
                        if secondRiskyAttack then
                            if applyQueuedAction(
                                secondRiskyAttack.action,
                                "RISKY_ATTACK",
                                secondRiskyAttack.unit,
                                "Priority20",
                                "Selected second risky valuable attack"
                            ) then
                                consumeRiskyAction()
                            end
                        end
                    end
                end
            end
        end

        local function runPriority21RiskyMoveAttackCombos()
            -- Priority 21: Risky move+attack combos (2+ damage, not special/1HP, only if sequence == 0) (Only Adjacent Cells suicide control)
            if shouldSuppressRiskyTier("Priority21") then
                return
            end
            if canFitActions(TWO) then
                local riskyMoveAttackAction = self:findRiskyMoveAttackCombos(currentState, usedUnits)
                if riskyMoveAttackAction then
                    self:logDecision("Priority21", "Risky move+attack combo candidate", riskyMoveAttackAction)
                else
                    self:logDecision("Priority21", "No risky move+attack combo candidate")
                end
                if riskyMoveAttackAction then
                    local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(riskyMoveAttackAction, "Priority21")
                    if not directApplied then
                        if applyTwoStepAction(
                            {
                                action = riskyMoveAttackAction.moveAction,
                                addTag = "RISKY_MOVE_ATTACK_MOVE",
                                unit = riskyMoveAttackAction.unit,
                                logTag = "Priority21",
                                logMessage = "Selected risky move"
                            },
                            {
                                action = riskyMoveAttackAction.attackAction,
                                addTag = "RISKY_MOVE_ATTACK_ATTACK",
                                unit = riskyMoveAttackAction.unit,
                                logTag = "Priority21",
                                logMessage = "Selected risky attack"
                            }
                        ) then
                            consumeRiskyAction()
                        end
                    elseif directPreferred then
                        self:logDecision("Priority21", "Direct preference replaced risky move+attack combo")
                    end
                end
            end
        end

        local function runPriority22BeneficialMoves()
            -- Priority 22: Beneficial positioning (suicidal check only)
            if inEarlyPhase and earlyRiskSuppressed and shouldSuppressRiskyTier("Priority22") then
                return
            end
            if shouldSuppressDefensivePriority("Priority22", "SUPPRESS_DEFENSIVE_REPOSITION") then
                return
            end
            if shouldSuppressByStrategicPlan("Priority22", false) then
                return
            end
            if not sequenceFull() then
                local beneficialActions = self:findBeneficialMoves(currentState, usedUnits)
                if #beneficialActions > ZERO then
                    self:logDecision("Priority20", "Safe positioning move candidates:\n" .. formatCandidates(beneficialActions))
                else
                    self:logDecision("Priority20", "No safe positioning move candidates")
                end

                local movesAdded = ZERO
                for _, beneficialAction in ipairs(beneficialActions) do
                    if sequenceFull() then
                        break  -- Sequence is full
                    end
                    if applyQueuedAction(
                        beneficialAction.action,
                        "SAFE_POSITIONING_MOVE",
                        beneficialAction.unit,
                        "Priority20",
                        "Selected safe positioning move"
                    ) then
                        movesAdded = movesAdded + ONE
                        if inMidPhase then
                            consumeRiskyAction()
                        end
                        if movesAdded >= TWO then
                            break  -- Maximum two positioning moves from this priority
                        end
                    end
                end
            end
        end

        local function runPriority22bDrawUrgencyEngagement()
            if sequenceFull() then
                return
            end
            if not (self:isDrawUrgencyActive() or self:isStalematePressureActive(currentState)) then
                return
            end
            local forceInteraction, interactionContext = shouldForceInteractionBeforePositioning()
            if forceInteraction then
                local urgencyAttackApplied = false

                local directEntries = self:collectAttackTargetEntries(currentState, usedUnits, {
                    mode = "direct",
                    aiPlayer = aiPlayer,
                    includeFriendlyFireCheck = true,
                    requirePositiveDamage = true,
                    allowHealerAttacks = self:shouldHealerBeOffensive(currentState, {
                        allowEmergencyDefense = true
                    })
                })
                local directCandidates = {}
                for _, entry in ipairs(directEntries) do
                    local attackPos = {row = entry.unit.row, col = entry.unit.col}
                    local value = self:getCanonicalAttackScore(
                        currentState,
                        entry.unit,
                        entry.target,
                        entry.damage,
                        {
                            includeTargetValue = true,
                            useBaseTargetValue = true,
                            includeOwnHubAdjBonus = true,
                            aiPlayer = aiPlayer,
                            attackPos = attackPos
                        }
                    )
                    directCandidates[#directCandidates + ONE] = {
                        unit = entry.unit,
                        action = entry.action,
                        value = value
                    }
                end
                self:sortScoredEntries(directCandidates, {
                    scoreField = "value",
                    descending = true
                })
                if #directCandidates > ZERO then
                    urgencyAttackApplied = applyQueuedAction(
                        directCandidates[ONE].action,
                        "DRAW_URGENCY_FORCED_ATTACK",
                        directCandidates[ONE].unit,
                        "Priority22B",
                        "Selected forced interaction attack"
                    ) or false
                end

                if (not urgencyAttackApplied) and canFitActions(TWO) and #sequence == ZERO then
                    local moveEntries = self:collectAttackTargetEntries(currentState, usedUnits, {
                        mode = "move",
                        aiPlayer = aiPlayer,
                        includeFriendlyFireCheck = true,
                        requireSafeMove = true,
                        checkVulnerableMove = true,
                        requirePositiveDamage = true,
                        allowHealerAttacks = self:shouldHealerBeOffensive(currentState, {
                            allowEmergencyDefense = true
                        })
                    })
                    local moveCandidates = {}
                    for _, entry in ipairs(moveEntries) do
                        local attackerAtMove = self:buildProjectedThreatUnit(entry.unit, entry.moveCell.row, entry.moveCell.col) or entry.unit
                        local value = self:getCanonicalAttackScore(
                            currentState,
                            attackerAtMove,
                            entry.target,
                            entry.damage,
                            {
                                includeTargetValue = true,
                                useBaseTargetValue = true,
                                includeOwnHubAdjBonus = true,
                                aiPlayer = aiPlayer,
                                attackPos = entry.moveCell,
                                applyCommanderExposurePenalty = true,
                                movePos = entry.moveCell
                            }
                        )
                        moveCandidates[#moveCandidates + ONE] = {
                            unit = entry.unit,
                            moveAction = entry.moveAction,
                            attackAction = entry.attackAction,
                            value = value
                        }
                    end
                    self:sortScoredEntries(moveCandidates, {
                        scoreField = "value",
                        descending = true
                    })
                    if #moveCandidates > ZERO then
                        urgencyAttackApplied = applyTwoStepAction(
                            {
                                action = moveCandidates[ONE].moveAction,
                                addTag = "DRAW_URGENCY_FORCED_MOVE",
                                unit = moveCandidates[ONE].unit,
                                logTag = "Priority22B",
                                logMessage = "Selected forced interaction move"
                            },
                            {
                                action = moveCandidates[ONE].attackAction,
                                addTag = "DRAW_URGENCY_FORCED_MOVE_ATTACK",
                                unit = moveCandidates[ONE].unit,
                                logTag = "Priority22B",
                                logMessage = "Selected forced interaction move+attack"
                            }
                        ) or false
                    end
                end

                if not urgencyAttackApplied then
                    self:logDecision("Priority22B", "Forced interaction active but no legal attack path", interactionContext)
                end
                return
            end
            if self:sequenceHasAttackAction(sequence) then
                return
            end

            local engagementMove = self:findDrawUrgencyEngagementMove(currentState, usedUnits)
            if engagementMove then
                self:logDecision("Priority22B", "Draw urgency engagement move candidate", engagementMove)
                applyQueuedAction(
                    engagementMove.action,
                    "DRAW_URGENCY_ENGAGE_MOVE",
                    engagementMove.unit,
                    "Priority22B",
                    "Selected draw urgency engagement move"
                )
            else
                self:logDecision("Priority22B", "No draw urgency engagement move candidate")
            end
        end

        local function runPriority28NeutralBuildingAttacks()
            -- Priority 28: Rock Obstacle Attacks (Check for suicidal adjacent and move+attack)
            if not sequenceFull() then
                local neutralAttackAction = self:findNeutralBuildingAttacks(currentState, usedUnits)
                if neutralAttackAction then
                    self:logDecision("Priority28", "Neutral building attack candidate", neutralAttackAction)
                else
                    self:logDecision("Priority28", "No neutral building attack candidate")
                end
                if neutralAttackAction then
                    applyQueuedAction(
                        neutralAttackAction.action,
                        "NEUTRAL_BUILDING_ATTACK",
                        neutralAttackAction.unit,
                        "Priority28",
                        "Selected neutral building attack"
                    )
                end
            end
        end

        local function runPriority29RiskyExpandedAttacks()
            -- Priority 29: Risky Attacks (Expanded, avoid suicidal adjacent cell)
            if shouldSuppressRiskyTier("Priority29") then
                return
            end
            if not sequenceFull() then
                local riskyExpandedAttackResult = self:findRiskyExpandedAttacks(currentState, usedUnits, sequence)
                if riskyExpandedAttackResult then
                    self:logDecision("Priority29", "Risky expanded attack candidates", riskyExpandedAttackResult)
                else
                    self:logDecision("Priority29", "No risky expanded attack candidates")
                end
                if riskyExpandedAttackResult then
                    -- Handle multiple attacks (when sequence == 0) or single attack
                    local attacksToProcess = {}
                    if type(riskyExpandedAttackResult) == "table" and riskyExpandedAttackResult[ONE] and riskyExpandedAttackResult[ONE].action then
                        -- Multiple attacks returned (sequence == 0)
                        attacksToProcess = riskyExpandedAttackResult
                    else
                        -- Single attack returned
                        attacksToProcess = {riskyExpandedAttackResult}
                    end

                    for _, attackAction in ipairs(attacksToProcess) do
                        if sequenceFull() then
                            break
                        end
                        applyQueuedAction(
                            attackAction.action,
                            "RISKY_EXPANDED_ATTACK",
                            attackAction.unit,
                            "Priority29",
                            "Selected risky expanded attack"
                        )
                        consumeRiskyAction()
                    end
                end
            end
        end

        local function runPriority30KillShotsNoGate()
            -- Priority 30: Kill shots without safety gates (guaranteed kills)
            -- Can add up to 2 no-gate kills if available
            if not sequenceFull() then
                local killActions = self:findKillShotsNoGate(currentState, usedUnits)
                if #killActions > ZERO then
                    self:logDecision("Priority30", "No-gate kill candidates", killActions)
                else
                    self:logDecision("Priority30", "No no-gate kill candidates")
                end

                local killsAdded = ZERO
                for _, killAction in ipairs(killActions) do
                    if sequenceFull() then
                        break
                    end
                    if applyQueuedAction(
                        killAction.action,
                        "NO_GATE_KILL",
                        killAction.unit,
                        "Priority30",
                        "Selected no-gate kill"
                    ) then
                        killsAdded = killsAdded + ONE
                        if killsAdded >= TWO then
                            break  -- Maximum two kills from this priority
                        end
                    end
                end
            end
        end

        local function runPriority32MoveKillNoGate()
            -- Priority 32: Move+kill combos without safety gates
            if canFitActions(TWO) then
                local moveKillCombos = self:findMoveKillShotsNoGate(currentState, usedUnits)
                if #moveKillCombos > ZERO then
                    self:logDecision("Priority32", "No-gate move+kill combo candidates", moveKillCombos)
                else
                    self:logDecision("Priority32", "No no-gate move+kill combo candidates")
                end
                for _, combo in ipairs(moveKillCombos) do
                    if #sequence > maxActions - TWO then
                        break
                    end
                    if not usedUnits[self:getUnitKey(combo.unit)] then
                        self:logDecision("Priority32", "Evaluating combo", combo)
                        local directPreferred, directApplied = tryPreferDirectAttackOverMoveCombo(combo, "Priority32")
                        if not directApplied then
                            applyTwoStepAction(
                                {
                                    action = combo.moveAction,
                                    addTag = "NO_GATE_MOVE_KILL_MOVE",
                                    unit = combo.unit,
                                    logTag = "Priority32",
                                    logMessage = "Selected move action"
                                },
                                {
                                    action = combo.attackAction,
                                    addTag = "NO_GATE_MOVE_KILL_ATTACK",
                                    unit = combo.unit,
                                    logTag = "Priority32",
                                    logMessage = "Selected attack action"
                                },
                                {
                                    rollbackOnSecondFailure = true
                                }
                            )
                        elseif directPreferred then
                            self:logDecision("Priority32", "Direct preference replaced no-gate move+kill combo")
                        end
                    end
                end
            end
        end

        local function runPriority33RiskyBeneficialMoves()
            -- Priority 33: Not So Safe Beneficial positioning (avoid suicidal adjacent cell)
            -- Can add up to 2 risky positioning moves if available
            if shouldSuppressRiskyTier("Priority33") then
                return
            end
            if not sequenceFull() then
                local beneficialActions = self:findNotSoSafeBeneficialMoves(currentState, usedUnits)
                if #beneficialActions > ZERO then
                    local formattedCandidates = {}
                    for index, candidate in ipairs(beneficialActions) do
                        local unitLabel = candidate.unit and self:describeUnitShort(candidate.unit) or "unknown"
                        local targetLabel = candidate.action and candidate.action.target and self:formatCell(candidate.action.target) or "(?,?)"
                        table.insert(formattedCandidates, string.format("%d) %s -> %s | value=%.1f risk=%s threat=%s pos=%s",
                            index,
                            unitLabel,
                            targetLabel,
                            candidate.value or ZERO,
                            candidate.riskLevel or "?",
                            candidate.threatValue or "?",
                            candidate.positionalValue or "?"
                        ))
                    end
                    self:logDecision("Priority33", "Risk-tolerant positioning move candidates", table.concat(formattedCandidates, "; "))
                else
                    self:logDecision("Priority33", "No risk-tolerant positioning move candidates")
                end

                local riskyMovesAdded = ZERO
                for _, beneficialAction in ipairs(beneficialActions) do
                    if sequenceFull() then
                        break  -- Sequence is full
                    end
                    if applyQueuedAction(
                        beneficialAction.action,
                        "RISKY_POSITIONING_MOVE",
                        beneficialAction.unit,
                        "Priority33",
                        "Selected risk-tolerant positioning move"
                    ) then
                        riskyMovesAdded = riskyMovesAdded + ONE
                        consumeRiskyAction()
                        if riskyMovesAdded >= TWO then
                            break  -- Maximum two risky positioning moves from this priority
                        end
                    end
                end
            end
        end

        local function runPriority34RiskyMoves()
            -- Priority 34: Risky Moves
            if shouldSuppressRiskyTier("Priority34") then
                return
            end
            if not sequenceFull() then
                local riskyMoveAction = self:findRiskyMoves(currentState, usedUnits)
                if riskyMoveAction then
                    self:logDecision("Priority34", "Risky move candidate", riskyMoveAction)
                else
                    self:logDecision("Priority34", "No risky move candidate")
                end
                if riskyMoveAction then
                    applyQueuedAction(
                        riskyMoveAction.action,
                        "RISKY_MOVE",
                        riskyMoveAction.unit,
                        "Priority34",
                        "Selected risky move"
                    )
                    consumeRiskyAction()
                end
            end
        end

        local function runPriority35BlockingMoves()
            -- Priority 35: Blocking Enemy Objectives
            if not sequenceFull() then
                local blockingMoveAction = self:findBlockingEnemyObjectives(currentState, usedUnits)
                if blockingMoveAction then
                    self:logDecision("Priority35", "Blocking move candidate", blockingMoveAction)
                else
                    self:logDecision("Priority35", "No blocking move candidate")
                end
                if blockingMoveAction then
                    applyQueuedAction(
                        blockingMoveAction.action,
                        "BLOCKING_MOVE",
                        blockingMoveAction.unit,
                        "Priority35",
                        "Selected blocking move"
                    )
                end
            end
        end

        local function runPriority36RandomLegalActions()
            -- Priority 36: Random Legal Actions
            if not sequenceFull() then
                local randomAction = self:findRandomLegalActions(currentState, usedUnits)
                if randomAction then
                    self:logDecision("Priority36", "Random legal action candidate", randomAction)
                else
                    self:logDecision("Priority36", "No random legal action candidate")
                end
                if randomAction then
                    applyQueuedAction(
                        randomAction.action,
                        "RANDOM_ACTION",
                        randomAction.unit,
                        "Priority36",
                        "Selected random legal action"
                    )
                end
            end
        end

        local function runPriority37DesperateAttacks()
            -- Priority 37: Desperate Suicidal Attacks (Final fallback)
            if not sequenceFull() then
                local desperateAttackAction = self:findDesperateAttacks(currentState, usedUnits)
                if desperateAttackAction then
                    self:logDecision("Priority37", "Desperate attack candidate", desperateAttackAction)
                else
                    self:logDecision("Priority37", "No desperate attack candidate")
                end
                if desperateAttackAction then
                    applyQueuedAction(
                        desperateAttackAction.action,
                        "DESPERATE_ATTACK",
                        desperateAttackAction.unit,
                        "Priority37",
                        "Selected desperate attack"
                    )
                end
            end
        end

        local function runPriority38PassTurn()
            -- Priority 38: Mandatory legal fallback, then pass turn only if no legal actions remain
            while #sequence < maxActions do
                local fallbackCandidates = self:getMandatoryFallbackCandidates(currentState, {
                    aiPlayer = aiPlayer,
                    usedUnits = usedUnits,
                    allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                })

                self:logDecision("Priority38", "Fallback candidates computed", {
                    count = #fallbackCandidates
                })

                local handledByFallback = false
                if #fallbackCandidates > ZERO then
                    local doctrineConfig = self:getDoctrineScoreConfig()
                    local rockDoctrine = doctrineConfig.ROCK_ATTACK or {}
                    local onlyStrategicRock = valueOr(rockDoctrine.ONLY_IF_STRATEGIC, true)
                    local lastResortRockOnly = valueOr(rockDoctrine.LAST_RESORT_ONLY, true)
                    local hasSupportedAlternative = false
                    local hasNonRockAlternative = false
                    for _, candidate in ipairs(fallbackCandidates) do
                        local candidateIsRock = candidate.type == "attack"
                            and (candidate.isRockAttack == true or self:isObstacleUnit(candidate.target))
                        local candidateRockStrategic = candidate.rockStrategic == true
                        local candidateRejectedByRockGate = candidateIsRock
                            and onlyStrategicRock
                            and not candidateRockStrategic
                        if candidate.type ~= "attack" or (not candidate.unsupportedNonLethal and not candidateRejectedByRockGate) then
                            hasSupportedAlternative = true
                        end
                        if candidate.type ~= "attack" or not candidateIsRock then
                            hasNonRockAlternative = true
                            break
                        end
                    end

                    for _, candidate in ipairs(fallbackCandidates) do
                        if candidate.type == "attack" and candidate.unsupportedNonLethal and hasSupportedAlternative then
                            self.unsupportedAttackRejected = (self.unsupportedAttackRejected or ZERO) + ONE
                            self:logDecision("Priority38", "Rejected unsupported fallback non-lethal attack", {
                                action = candidate.action,
                                exchangeDelta = candidate.backedAttackContext and candidate.backedAttackContext.exchangeDelta or nil,
                                followupAttackers = candidate.backedAttackContext and candidate.backedAttackContext.followupAttackers or ZERO
                            })
                            goto continue_fallback_candidate
                        end

                        if candidate.type == "attack" and (candidate.isRockAttack == true or self:isObstacleUnit(candidate.target)) then
                            local rockStrategic = candidate.rockStrategic == true
                            if candidate.rockStrategic == nil then
                                rockStrategic = self:isStrategicRockAttack(currentState, candidate.action, {
                                    aiPlayer = aiPlayer,
                                    target = candidate.target
                                })
                            end

                            local rejectRock = false
                            if onlyStrategicRock and not rockStrategic then
                                rejectRock = hasSupportedAlternative or (lastResortRockOnly and hasNonRockAlternative)
                            end
                            if lastResortRockOnly and hasNonRockAlternative and not rockStrategic then
                                rejectRock = true
                            end
                            if rejectRock then
                                self.fillerAttackAvoidedCount = (self.fillerAttackAvoidedCount or ZERO) + ONE
                                self:logDecision("Priority38", "Rejected non-strategic rock fallback attack", {
                                    action = candidate.action,
                                    strategic = rockStrategic,
                                    hasSupportedAlternative = hasSupportedAlternative,
                                    hasNonRockAlternative = hasNonRockAlternative
                                })
                                goto continue_fallback_candidate
                            end
                        end

                        local fallbackAction = candidate.action
                        local actingUnit = nil
                        if fallbackAction and fallbackAction.unit and fallbackAction.unit.row and fallbackAction.unit.col then
                            actingUnit = self:getUnitAtPosition(currentState, fallbackAction.unit.row, fallbackAction.unit.col)
                        end
                        if fallbackAction and applyQueuedAction(
                            fallbackAction,
                            "MANDATORY_LEGAL_FALLBACK",
                            actingUnit,
                            "Priority38",
                            "Added legal fallback action"
                        ) then
                            handledByFallback = true
                            break
                        end
                        ::continue_fallback_candidate::
                    end
                end

                if not handledByFallback then
                    local skipAction = self:createSkipAction(currentState)
                    self:logDecision("Priority38", "Attempting to add skip action", skipAction)
                    if not applyQueuedAction(
                        skipAction,
                        "PASS_TURN",
                        nil,
                        "Priority38",
                        "Added skip action (no legal fallback)",
                        {stateMode = "none"}
                    ) then
                        self:logDecision("Priority38", "Failed to add skip action")
                        -- If we can't even add skip actions, break to prevent infinite loop
                        break
                    end
                end
            end
        end

        -- Priority Pipeline (order preserved)
        local result = runPriority00WinningConditions()
        if result then
            return result
        end

        if sequenceFull() then
            return sequence
        end

        runPriority01aStrategicDefense()
        if sequenceFull() then
            return sequence
        end

        runPriority01bCommandantThreatResponse()
        if sequenceFull() then
            return sequence
        end

        if strategicDefenseLock then
            self:logDecision("DefenseBundle", "Defense lock active; reserving remaining actions for defense", {
                sequenceLen = #sequence
            })
            if not sequenceFull() then
                runPriority01bCommandantThreatResponse()
            end
            if not sequenceFull() then
                runPriority38PassTurn()
            end
            return sequence
        end

        runPriority01cPostDefenseFollowUp()
        if sequenceFull() then
            return sequence
        end

        local autoPriorityWindowStartLen = #sequence

        runPriority01SafeKills()
        if sequenceFull() then
            return sequence
        end

        runPriority02SafeMoveAttackKills()
        runSupportFollowUp("Priority13")
        if sequenceFull() then
            return sequence
        end

        runPriority03TwoUnitKillCombos()
        if sequenceFull() then
            return sequence
        end

        runPriority04CorvetteLineOfSightKills()
        if sequenceFull() then
            return sequence
        end

        runPriority05NotSoSafeKillsWithSuicideCheck()
        if sequenceFull() then
            return sequence
        end

        runPriority06MoveAttackKillsWithSuicideCheck()
        if sequenceFull() then
            return sequence
        end

        runPriority07NotSoSafeKills()
        if sequenceFull() then
            return sequence
        end

        runPriority08TwoUnitKillCombosNoSafety()
        if sequenceFull() then
            return sequence
        end

        runPriority09NotSoSafeMoveAttackKillsAndThreats()
        if sequenceFull() then
            return sequence
        end

        local autoPriorityActionsAdded = #sequence - autoPriorityWindowStartLen
        local autoPriorityWindowTriggered = autoPriorityActionsAdded > ZERO
        if autoPriorityWindowTriggered then
            self:logDecision("PriorityAuto", "Priority01-09 auto window resolved actions; skipping strategic/planning stages", {
                actionsAdded = autoPriorityActionsAdded
            })
            if not sequenceFull() then
                runPriority38PassTurn()
            end

            local enforcedSequence, replacedByUrgency, urgencyContext = self:enforceDrawUrgencyAttackFallback(
                state,
                sequence,
                maxActions
            )
            if replacedByUrgency then
                sequence = enforcedSequence
                self:logDecision("DrawUrgency", "Enforced final attack fallback", urgencyContext)
            end

            return sequence
        end

        runPriority25SurvivalRepairs()
        if sequenceFull() then
            return sequence
        end

        runPriority26SurvivalMoveRepairs()
        if sequenceFull() then
            return sequence
        end

        runPriority11HighValueSafeAttacks()
        runSupportFollowUp("Priority11")
        if sequenceFull() then
            return sequence
        end

        runPriority11bDoomedEliminations()
        if sequenceFull() then
            return sequence
        end

        runPriority22bDrawUrgencyEngagement()
        if sequenceFull() then
            return sequence
        end

        runPriority10SafeEvasion()
        if sequenceFull() then
            return sequence
        end

        runPriority10bSingleUnitTwoActionPressure()
        if sequenceFull() then
            return sequence
        end

        runPriority12SupportFollowUp()
        if sequenceFull() then
            return sequence
        end

        runPriority13HighValueAttacks()
        runSupportFollowUp("Priority13")
        if sequenceFull() then
            return sequence
        end

        runPriority13cThreatReleaseOffense()
        if sequenceFull() then
            return sequence
        end

        runPriority13bisMoveAttackCombos()
        if sequenceFull() then
            return sequence
        end

        runPriority13CommandantGuardMove()
        if sequenceFull() then
            return sequence
        end

        runPriority13dStrategicPlanAdvancement()
        if sequenceFull() then
            return sequence
        end

        if shouldShortCircuitToFallbackForBudget("post_priority13d", 85) then
            if not sequenceFull() then
                runPriority38PassTurn()
            end
            return sequence
        end

        runPriority14BeneficialNoDamageMoves()
        if sequenceFull() then
            return sequence
        end

        runPriority15MoveAttackCombosNoSafety()
        if sequenceFull() then
            return sequence
        end

        runPriority16LastAttack()
        if sequenceFull() then
            return sequence
        end

        runPriority17LastMoveAttack()
        if sequenceFull() then
            return sequence
        end

        runPriority18HubSpaceCreation()
        if sequenceFull() then
            return sequence
        end

        runPriority19EnhancedSupplyDeployment()
        if sequenceFull() then
            return sequence
        end

        if shouldShortCircuitToFallbackForBudget("pre_risky_tiers", 120) then
            if not sequenceFull() then
                runPriority38PassTurn()
            end
            return sequence
        end

        runPriority20RiskyValuableAttacks()
        if sequenceFull() then
            return sequence
        end

        runPriority21RiskyMoveAttackCombos()
        if sequenceFull() then
            return sequence
        end

        runPriority22BeneficialMoves()
        if sequenceFull() then
            return sequence
        end

        -- Priority 23: Free
        -- Priority 24: Free
        -- Priority 27: Free

        runPriority28NeutralBuildingAttacks()
        if sequenceFull() then
            return sequence
        end

        if shouldShortCircuitToFallbackForBudget("post_priority28", 90) then
            if not sequenceFull() then
                runPriority38PassTurn()
            end
            return sequence
        end

        runPriority29RiskyExpandedAttacks()
        if sequenceFull() then
            return sequence
        end

        runPriority30KillShotsNoGate()
        if sequenceFull() then
            return sequence
        end

        runPriority32MoveKillNoGate()
        if sequenceFull() then
            return sequence
        end

        if shouldShortCircuitToFallbackForBudget("post_priority32", 70) then
            if not sequenceFull() then
                runPriority38PassTurn()
            end
            return sequence
        end

        runPriority33RiskyBeneficialMoves()
        if sequenceFull() then
            return sequence
        end

        runPriority34RiskyMoves()
        if sequenceFull() then
            return sequence
        end

        runPriority35BlockingMoves()
        if sequenceFull() then
            return sequence
        end

        runPriority36RandomLegalActions()
        if sequenceFull() then
            return sequence
        end

        runPriority37DesperateAttacks()
        if sequenceFull() then
            return sequence
        end

        runPriority38PassTurn()

        local enforcedSequence, replacedByUrgency, urgencyContext = self:enforceDrawUrgencyAttackFallback(
            state,
            sequence,
            maxActions
        )
        if replacedByUrgency then
            sequence = enforcedSequence
            self:logDecision("DrawUrgency", "Enforced final attack fallback", urgencyContext)
        end

        return sequence
    end

end

return M
