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
    function aiClass:updateDrawUrgencyState(state)
        local params = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        if params.ENABLED == false then
            self.drawUrgencyMode = nil
            return
        end

        local minTurn = params.MIN_TURN
        local triggerMargin = params.TRIGGER_MARGIN
        local winThreshold = params.WIN_PERCENT_THRESHOLD

        local attackBase = params.ATTACK_BONUS_BASE
        local attackPerLevel = params.ATTACK_BONUS_PER_LEVEL
        local nonAttackBase = params.NON_ATTACK_PENALTY_BASE
        local nonAttackPerLevel = params.NON_ATTACK_PENALTY_PER_LEVEL
        local passiveRatio = params.PASSIVE_PENALTY_RATIO
        local forceActivationMargin = valueOr(params.FORCE_ACTIVATION_MARGIN, ZERO)
        local criticalMargin = valueOr(params.CRITICAL_MARGIN, TWO)

        local turnsWithoutDamage = state.turnsWithoutDamage or ZERO
        local drawThreshold = valueOr((RULE_CONTRACT.DRAW or {}).NO_INTERACTION_LIMIT, GAME.CONSTANTS.MAX_TURNS_WITHOUT_DAMAGE)
        local triggerLevel = math.max(ZERO, drawThreshold - triggerMargin)

        if not state.currentTurn or state.currentTurn < minTurn then
            if self.drawUrgencyMode and self.drawUrgencyMode.active then
                self:logDecision("DrawUrgency", string.format(
                    "Deactivated before min turn (turn=%d, required=%d)",
                    state.currentTurn or (ZERO - MIN_HP),
                    minTurn
                ))
            end
            self.drawUrgencyMode = nil
            return
        end

        if turnsWithoutDamage < triggerLevel then
            if self.drawUrgencyMode and self.drawUrgencyMode.active then
                self:logDecision("DrawUrgency", string.format(
                    "Deactivated (no-damage streak reset: %d < %d)",
                    turnsWithoutDamage,
                    triggerLevel
                ))
            end
            self.drawUrgencyMode = nil
            return
        end

        local winPercentage = self:calculateWinningPercentage(state)
        local forceActivateAtStreak = math.max(ZERO, drawThreshold - forceActivationMargin)
        local forceActivate = turnsWithoutDamage >= forceActivateAtStreak
        if (not forceActivate) and winPercentage < winThreshold then
            if self.drawUrgencyMode and self.drawUrgencyMode.active then
                self:logDecision("DrawUrgency", string.format(
                    "Deactivated (win%% %.1f < %.1f)",
                    winPercentage,
                    winThreshold
                ))
            end
            self.drawUrgencyMode = nil
            return
        end

        local urgencyLevel = math.max(MIN_HP, turnsWithoutDamage - triggerLevel + MIN_HP)
        local attackBonus = attackBase + (urgencyLevel * attackPerLevel)
        local nonAttackPenalty = nonAttackBase + (urgencyLevel * nonAttackPerLevel)
        local criticalLevel = math.max(ZERO, drawThreshold - criticalMargin)
        local critical = turnsWithoutDamage >= criticalLevel

        self.drawUrgencyMode = {
            active = true,
            critical = critical,
            attackBonus = attackBonus,
            nonAttackPenalty = nonAttackPenalty,
            passivePenalty = math.floor(nonAttackPenalty * passiveRatio),
            turnsWithoutDamage = turnsWithoutDamage,
            drawThreshold = drawThreshold,
            winPercentage = winPercentage,
            urgencyLevel = urgencyLevel
        }

        self:logDecision("DrawUrgency", string.format(
            "Attack bias enabled (turn=%d, no-damage=%d/%d, win=%.1f%%, level=%d, bonus=%d, penalty=%d, critical=%s)",
            state.currentTurn,
            turnsWithoutDamage,
            drawThreshold,
            winPercentage,
            urgencyLevel,
            attackBonus,
            nonAttackPenalty,
            tostring(critical)
        ))
    end

    function aiClass:sequenceHasAttackAction(sequence)
        for _, action in ipairs(sequence or {}) do
            if action and action.type == "attack" then
                return true
            end
        end
        return false
    end

    function aiClass:findDrawUrgencyEngagementMove(state, usedUnits)
        if not (self:isDrawUrgencyActive() or self:isStalematePressureActive(state)) then
            return nil
        end
        if not state then
            return nil
        end

        local drawParams = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        local engagementConfig = drawParams.ENGAGEMENT_MOVE or {}
        if engagementConfig.ENABLED == false then
            return nil
        end

        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end
        if self:isOwnHubThreatened(state, aiPlayer) and not valueOr(engagementConfig.ALLOW_WHEN_HUB_THREATENED, false) then
            return nil
        end

        local allowSuicidal = valueOr(engagementConfig.ALLOW_SUICIDAL, false)
        local checkVulnerableMove = valueOr(engagementConfig.CHECK_VULNERABLE_MOVE, true)
        local threatLookaheadTurns = math.max(ONE, valueOr(engagementConfig.THREAT_LOOKAHEAD_TURNS, THREE))
        local threatFrontierMax = math.max(ONE, valueOr(engagementConfig.THREAT_FRONTIER_MAX, 16))
        local distGainWeight = valueOr(engagementConfig.DIST_GAIN_WEIGHT, ZERO)
        local proximityBase = valueOr(engagementConfig.PROXIMITY_BASE, ZERO)
        local proximityDecay = valueOr(engagementConfig.PROXIMITY_DECAY, ZERO)
        local targetValueWeight = valueOr(engagementConfig.TARGET_VALUE_WEIGHT, ZERO)
        local threatNowBonus = valueOr(engagementConfig.THREAT_NOW_BONUS, ZERO)
        local threatNextBonus = valueOr(engagementConfig.THREAT_NEXT_BONUS, ZERO)
        local threatLateBonus = valueOr(engagementConfig.THREAT_LATE_BONUS, ZERO)
        local adjacentEngageBonus = valueOr(engagementConfig.ADJACENT_ENGAGE_BONUS, ZERO)
        local exposurePenaltyScale = valueOr(engagementConfig.EXPOSURE_PENALTY_SCALE, ZERO)
        local minScore = valueOr(engagementConfig.MIN_SCORE, ZERO)
        local criticalMode = self:isDrawUrgencyCritical()
        if criticalMode then
            allowSuicidal = valueOr(drawParams.CRITICAL_ALLOW_SUICIDAL_ENGAGE, allowSuicidal)
            local ignoreVulnerable = valueOr(drawParams.CRITICAL_IGNORE_VULNERABLE_CHECK, false)
            if ignoreVulnerable then
                checkVulnerableMove = false
            end
            minScore = valueOr(drawParams.CRITICAL_ENGAGE_MIN_SCORE, minScore)
            threatLookaheadTurns = math.max(
                threatLookaheadTurns,
                math.max(ONE, valueOr(drawParams.CRITICAL_THREAT_LOOKAHEAD_TURNS, threatLookaheadTurns))
            )
        end

        local targets = {}
        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, aiPlayer) then
                targets[#targets + ONE] = enemy
            end
        end
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)] or nil
        if enemyHub then
            targets[#targets + ONE] = {
                row = enemyHub.row,
                col = enemyHub.col,
                player = self:getOpponentPlayer(aiPlayer),
                name = "Commandant",
                currentHp = enemyHub.currentHp,
                startingHp = enemyHub.startingHp
            }
        end

        if #targets == ZERO then
            return nil
        end

        local function isMoveLegalForEngagement(unit, moveCell)
            if allowSuicidal then
                if self:getUnitAtPosition(state, moveCell.row, moveCell.col) then
                    return false
                end
                if checkVulnerableMove and self:isVulnerableToMoveAttack(state, moveCell, unit) then
                    return false
                end
                return true
            end

            return self:isOpenSafeMoveCell(state, unit, moveCell, {
                checkVulnerable = checkVulnerableMove
            })
        end

        local bestCandidate = nil
        local bestScore = -math.huge
        local bestKey = nil

        for _, unit in ipairs(state.units or {}) do
            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits, {
                requireNotActed = true,
                requireNotMoved = true,
                disallowCommandant = true,
                requireAlive = true
            }) then
                local moveCells = self:getValidMoveCells(state, unit.row, unit.col) or {}
                for _, moveCell in ipairs(moveCells) do
                    if isMoveLegalForEngagement(unit, moveCell) then
                        local simState, simUnit = self:simulateUnitMoveState(state, unit, moveCell, {validate = true})
                        local projectedUnit = simUnit or self:buildProjectedThreatUnit(unit, moveCell.row, moveCell.col) or unit
                        projectedUnit.hasMoved = true
                        projectedUnit.hasActed = unit.hasActed or false

                        local bestTarget = nil
                        local bestTargetScore = -math.huge
                        local bestThreatTurn = nil

                        for _, target in ipairs(targets) do
                            local currentDist = math.abs(unit.row - target.row) + math.abs(unit.col - target.col)
                            local newDist = math.abs(moveCell.row - target.row) + math.abs(moveCell.col - target.col)
                            local distGain = math.max(ZERO, currentDist - newDist)
                            local proximityScore = math.max(ZERO, proximityBase - (newDist * proximityDecay))
                            local targetValue = self:getUnitBaseValue(target, state) or ZERO

                            local targetScore = (distGain * distGainWeight)
                                + proximityScore
                                + (targetValue * targetValueWeight)

                            local threatTurn = nil
                            if self:canUnitDamageTargetFromPosition(
                                simState,
                                projectedUnit,
                                target,
                                moveCell.row,
                                moveCell.col,
                                {requirePositiveDamage = false}
                            ) then
                                threatTurn = ONE
                            else
                                threatTurn = self:getUnitThreatTiming(
                                    simState,
                                    projectedUnit,
                                    target,
                                    threatLookaheadTurns,
                                    {
                                        considerCurrentActionState = true,
                                        allowMoveOnFirstTurn = false,
                                        requirePositiveDamage = false,
                                        maxFrontierNodes = threatFrontierMax
                                    }
                                )
                            end

                            if threatTurn == ONE then
                                targetScore = targetScore + threatNowBonus
                            elseif threatTurn == TWO then
                                targetScore = targetScore + threatNextBonus
                            elseif threatTurn and threatTurn <= threatLookaheadTurns then
                                targetScore = targetScore + threatLateBonus
                            end

                            if newDist <= ONE then
                                targetScore = targetScore + adjacentEngageBonus
                            end

                            if targetScore > bestTargetScore then
                                bestTargetScore = targetScore
                                bestTarget = target
                                bestThreatTurn = threatTurn
                            end
                        end

                        if bestTarget then
                            local exposurePenalty = ZERO
                            if exposurePenaltyScale > ZERO then
                                exposurePenalty = math.floor(
                                    self:calculateCommanderExposurePenalty(state, unit, moveCell) * exposurePenaltyScale
                                )
                            end

                            local finalScore = bestTargetScore - exposurePenalty
                            local tieKey = string.format(
                                "%02d,%02d->%02d,%02d|%02d,%02d",
                                unit.row or ZERO,
                                unit.col or ZERO,
                                moveCell.row or ZERO,
                                moveCell.col or ZERO,
                                bestTarget.row or ZERO,
                                bestTarget.col or ZERO
                            )

                            if finalScore > bestScore or (finalScore == bestScore and (not bestKey or tieKey < bestKey)) then
                                bestScore = finalScore
                                bestKey = tieKey
                                bestCandidate = {
                                    unit = unit,
                                    action = {
                                        type = "move",
                                        unit = {row = unit.row, col = unit.col},
                                        target = {row = moveCell.row, col = moveCell.col}
                                    },
                                    target = {
                                        row = bestTarget.row,
                                        col = bestTarget.col,
                                        name = bestTarget.name
                                    },
                                    threatTurn = bestThreatTurn,
                                    score = finalScore
                                }
                            end
                        end
                    end
                end
            end
        end

        if bestCandidate and bestCandidate.score >= minScore then
            return bestCandidate
        end

        return nil
    end

    function aiClass:enforceDrawUrgencyAttackFallback(state, sequence, maxActions)
        local drawParams = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        local enforceConfig = drawParams.ENFORCE_ATTACK or {}
        if enforceConfig.ENABLED == false then
            return sequence, false, nil
        end

        local enforceOnStalematePressure = valueOr(enforceConfig.ENABLE_WHEN_STALEMATE_PRESSURE, true)
        if not self:isDrawUrgencyActive() then
            if not (enforceOnStalematePressure and self:isStalematePressureActive(state)) then
                return sequence, false, nil
            end
        end

        if not state or not sequence or #sequence == ZERO then
            return sequence, false, nil
        end

        if self:sequenceHasAttackAction(sequence) then
            return sequence, false, nil
        end

        local maxActionCount = math.max(ONE, maxActions or #sequence)
        local currentActionCount = math.min(#sequence, maxActionCount)
        local minPrefixActions = math.max(ZERO, valueOr(enforceConfig.MIN_PREFIX_ACTIONS, ZERO))
        local allowZeroDamage = valueOr(enforceConfig.ALLOW_ZERO_DAMAGE, true)
        local allowNeutralTargets = valueOr(enforceConfig.ALLOW_NEUTRAL_TARGETS, false)
        if self:isDrawUrgencyCritical() then
            allowNeutralTargets = valueOr(drawParams.CRITICAL_ALLOW_NEUTRAL_TARGETS, allowNeutralTargets)
        end
        local damageWeight = valueOr(enforceConfig.DAMAGE_WEIGHT, ZERO)
        local targetValueWeight = valueOr(enforceConfig.TARGET_VALUE_WEIGHT, ZERO)
        local killBonus = valueOr(enforceConfig.KILL_BONUS, ZERO)
        local commandantBonus = valueOr(enforceConfig.COMMANDANT_BONUS, ZERO)
        local zeroDamagePenalty = valueOr(enforceConfig.ZERO_DAMAGE_PENALTY, ZERO)
        local aiPlayer = self:getFactionId()
        if aiPlayer and self:isOwnHubThreatened(state, aiPlayer) and not valueOr(enforceConfig.ALLOW_WHEN_HUB_THREATENED, false) then
            return sequence, false, nil
        end

        local maxPrefix = currentActionCount
        if currentActionCount >= maxActionCount then
            maxPrefix = maxActionCount - ONE
        end

        if maxPrefix < minPrefixActions then
            return sequence, false, nil
        end

        local function buildStateFromPrefix(prefixLen)
            local simulatedState = self:deepCopyState(state)
            for index = ONE, prefixLen do
                local action = sequence[index]
                if action and action.type and action.type ~= "skip" then
                    if action.type == "supply_deploy" then
                        simulatedState = self:applySupplyDeployment(simulatedState, action)
                    else
                        simulatedState = self:applyMove(simulatedState, action)
                    end
                end
            end
            return simulatedState
        end

        local function getUrgencyAttackScore(entry, boardState)
            local damage = entry._drawUrgencyDamage or ZERO
            local targetValue = self:getUnitBaseValue(entry.target, boardState) or ZERO
            local targetHp = entry.target.currentHp or entry.target.startingHp or MIN_HP
            local score = (damage * damageWeight) + (targetValue * targetValueWeight)
            if damage >= targetHp then
                score = score + killBonus
            end
            if entry.target.name == "Commandant" then
                score = score + commandantBonus
            end
            if damage <= ZERO then
                score = score - zeroDamagePenalty
            end
            return score
        end

        for prefixLen = maxPrefix, minPrefixActions, -ONE do
            local simulatedState = buildStateFromPrefix(prefixLen)
            local legalEntries = self:collectLegalActions(simulatedState, {
                includeMove = false,
                includeAttack = true,
                includeRepair = false,
                includeDeploy = false,
                allowFullHpHealerRepairException = false
            })

            local attackEntries = {}
            for _, entry in ipairs(legalEntries) do
                if entry and entry.type == "attack" and entry.action and entry.unit and entry.target then
                    local targetPlayer = entry.target.player
                    local isNeutralTarget = targetPlayer == nil or targetPlayer == ZERO
                    if allowNeutralTargets or not isNeutralTarget then
                        local damage = self:calculateDamage(entry.unit, entry.target) or ZERO
                        if allowZeroDamage or damage > ZERO then
                            entry._drawUrgencyDamage = damage
                            attackEntries[#attackEntries + ONE] = entry
                        end
                    end
                end
            end

            if #attackEntries > ZERO then
                self:sortScoredEntries(attackEntries, {
                    scoreFn = function(entry)
                        return getUrgencyAttackScore(entry, simulatedState)
                    end,
                    descending = true
                })

                local chosenEntry = attackEntries[ONE]
                if chosenEntry and chosenEntry.action then
                    local adjustedSequence = {}
                    for idx = ONE, prefixLen do
                        adjustedSequence[#adjustedSequence + ONE] = sequence[idx]
                    end
                    adjustedSequence[#adjustedSequence + ONE] = {
                        type = "attack",
                        unit = {
                            row = chosenEntry.action.unit.row,
                            col = chosenEntry.action.unit.col
                        },
                        target = {
                            row = chosenEntry.action.target.row,
                            col = chosenEntry.action.target.col
                        }
                    }

                    while #adjustedSequence < maxActionCount do
                        adjustedSequence[#adjustedSequence + ONE] = self:createSkipAction(simulatedState)
                    end

                    return adjustedSequence, true, {
                        keptPrefixActions = prefixLen,
                        replacedActions = currentActionCount - prefixLen,
                        attacker = chosenEntry.unit and chosenEntry.unit.name or nil,
                        target = chosenEntry.target and {
                            row = chosenEntry.target.row,
                            col = chosenEntry.target.col,
                            name = chosenEntry.target.name
                        } or nil,
                        damage = chosenEntry._drawUrgencyDamage or ZERO
                    }
                end
            end
        end

        local maxPrefixForCombo = math.min(maxPrefix, maxActionCount - TWO)
        if maxPrefixForCombo >= minPrefixActions then
            for prefixLen = maxPrefixForCombo, minPrefixActions, -ONE do
                local simulatedState = buildStateFromPrefix(prefixLen)
                local allowHealerAttacks = self:shouldHealerBeOffensive(simulatedState)
                local moveAttackEntries = self:collectAttackTargetEntries(simulatedState, {}, {
                    mode = "move",
                    aiPlayer = aiPlayer,
                    allowHealerAttacks = allowHealerAttacks,
                    requireSafeMove = not self:isDrawUrgencyCritical(),
                    checkVulnerableMove = not self:isDrawUrgencyCritical(),
                    includeFriendlyFireCheck = true,
                    requirePositiveDamage = not allowZeroDamage
                })

                local candidates = {}
                for _, entry in ipairs(moveAttackEntries) do
                    local targetPlayer = entry.target and entry.target.player
                    local isNeutralTarget = targetPlayer == nil or targetPlayer == ZERO
                    if (allowNeutralTargets or not isNeutralTarget) and entry.moveAction and entry.attackAction then
                        local damage = entry.damage or self:calculateDamage(entry.unit, entry.target) or ZERO
                        if allowZeroDamage or damage > ZERO then
                            entry._drawUrgencyDamage = damage
                            candidates[#candidates + ONE] = entry
                        end
                    end
                end

                if #candidates > ZERO then
                    self:sortScoredEntries(candidates, {
                        scoreFn = function(entry)
                            return getUrgencyAttackScore(entry, simulatedState)
                        end,
                        descending = true
                    })

                    local chosenEntry = candidates[ONE]
                    if chosenEntry and chosenEntry.moveAction and chosenEntry.attackAction then
                        local adjustedSequence = {}
                        for idx = ONE, prefixLen do
                            adjustedSequence[#adjustedSequence + ONE] = sequence[idx]
                        end

                        adjustedSequence[#adjustedSequence + ONE] = {
                            type = "move",
                            unit = {
                                row = chosenEntry.moveAction.unit.row,
                                col = chosenEntry.moveAction.unit.col
                            },
                            target = {
                                row = chosenEntry.moveAction.target.row,
                                col = chosenEntry.moveAction.target.col
                            }
                        }
                        adjustedSequence[#adjustedSequence + ONE] = {
                            type = "attack",
                            unit = {
                                row = chosenEntry.attackAction.unit.row,
                                col = chosenEntry.attackAction.unit.col
                            },
                            target = {
                                row = chosenEntry.attackAction.target.row,
                                col = chosenEntry.attackAction.target.col
                            }
                        }

                        while #adjustedSequence < maxActionCount do
                            adjustedSequence[#adjustedSequence + ONE] = self:createSkipAction(simulatedState)
                        end

                        return adjustedSequence, true, {
                            keptPrefixActions = prefixLen,
                            replacedActions = currentActionCount - prefixLen,
                            moveAttack = true,
                            attacker = chosenEntry.unit and chosenEntry.unit.name or nil,
                            target = chosenEntry.target and {
                                row = chosenEntry.target.row,
                                col = chosenEntry.target.col,
                                name = chosenEntry.target.name
                            } or nil,
                            damage = chosenEntry._drawUrgencyDamage or ZERO
                        }
                    end
                end
            end
        end

        local engagementFallback = self:findDrawUrgencyEngagementMove(state, {})
        if engagementFallback and engagementFallback.action then
            local adjustedSequence = {
                {
                    type = "move",
                    unit = {
                        row = engagementFallback.action.unit.row,
                        col = engagementFallback.action.unit.col
                    },
                    target = {
                        row = engagementFallback.action.target.row,
                        col = engagementFallback.action.target.col
                    }
                }
            }

            local postMoveState = self:deepCopyState(state)
            postMoveState = self:applyMove(postMoveState, adjustedSequence[ONE])

            if maxActionCount > ONE then
                local fallbackCandidates = self:getMandatoryFallbackCandidates(postMoveState, {
                    allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                })
                for _, candidate in ipairs(fallbackCandidates) do
                    if candidate and candidate.action then
                        local a = candidate.action
                        adjustedSequence[#adjustedSequence + ONE] = {
                            type = a.type,
                            unit = a.unit and {row = a.unit.row, col = a.unit.col} or nil,
                            target = a.target and {row = a.target.row, col = a.target.col} or nil,
                            unitIndex = a.unitIndex,
                            unitName = a.unitName,
                            hub = a.hub
                        }
                        break
                    end
                end
            end

            while #adjustedSequence < maxActionCount do
                adjustedSequence[#adjustedSequence + ONE] = self:createSkipAction(postMoveState)
            end

            return adjustedSequence, true, {
                keptPrefixActions = ZERO,
                replacedActions = currentActionCount,
                fallback = "engagement_move",
                target = engagementFallback.target,
                threatTurn = engagementFallback.threatTurn
            }
        end

        return sequence, false, nil
    end

    function aiClass:isThreatReleaseOffenseActive()
        local state = self.threatReleaseOffenseState
        return state and state.active == true and (state.turnsRemaining or ZERO) > ZERO
    end

    function aiClass:updateThreatReleaseOffenseState(state)
        local releaseConfig = self:getThreatReleaseOffenseScoreConfig()
        local defaultReleaseConfig = DEFAULT_SCORE_PARAMS.THREAT_RELEASE_OFFENSE or {}
        if releaseConfig.ENABLED == false then
            self.threatReleaseOffenseState = nil
            return nil
        end

        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            self.threatReleaseOffenseState = nil
            return nil
        end

        local currentTurn = (state and state.currentTurn) or (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or DEFAULT_TURN
        local memoryTurns = math.max(
            ZERO,
            valueOr(releaseConfig.MEMORY_TURNS, valueOr(defaultReleaseConfig.MEMORY_TURNS, ZERO))
        )
        local armOnThreatLevel = valueOr(
            releaseConfig.ARM_ON_THREAT_LEVEL,
            valueOr(defaultReleaseConfig.ARM_ON_THREAT_LEVEL, ZERO)
        )
        local armOnHubHp = valueOr(
            releaseConfig.ARM_ON_HUB_HP_AT_OR_BELOW,
            valueOr(defaultReleaseConfig.ARM_ON_HUB_HP_AT_OR_BELOW, ZERO)
        )
        local releaseThreatLevelMax = valueOr(
            releaseConfig.RELEASE_THREAT_LEVEL_MAX,
            valueOr(defaultReleaseConfig.RELEASE_THREAT_LEVEL_MAX, armOnThreatLevel)
        )

        local threatData = self:analyzeHubThreat(state or {}) or {isUnderAttack = false, threatLevel = ZERO}
        local threatLevel = threatData.threatLevel or ZERO
        local ownHub = state and state.commandHubs and state.commandHubs[aiPlayer] or nil
        local ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO
        local severeThreat = threatLevel >= armOnThreatLevel or (ownHub and ownHubHp <= armOnHubHp)
        local threatNeutralized = (not threatData.isUnderAttack) and (threatLevel <= releaseThreatLevelMax)

        local releaseState = self.threatReleaseOffenseState or {
            armed = false,
            active = false,
            turnsRemaining = ZERO,
            lastProcessedTurn = nil
        }

        local wasActive = releaseState.active == true
        local wasArmed = releaseState.armed == true

        if releaseState.lastProcessedTurn ~= currentTurn then
            if releaseState.active and (releaseState.turnsRemaining or ZERO) > ZERO then
                releaseState.turnsRemaining = math.max(ZERO, (releaseState.turnsRemaining or ZERO) - ONE)
            end
            if (releaseState.turnsRemaining or ZERO) <= ZERO then
                releaseState.active = false
            end
            releaseState.lastProcessedTurn = currentTurn
        end

        if severeThreat then
            releaseState.armed = true
            releaseState.active = false
            releaseState.turnsRemaining = ZERO
        elseif releaseState.armed and threatNeutralized and memoryTurns > ZERO then
            releaseState.armed = false
            releaseState.active = true
            releaseState.turnsRemaining = memoryTurns
            releaseState.activationTurn = currentTurn
        elseif releaseState.armed and threatNeutralized and memoryTurns <= ZERO then
            releaseState.armed = false
            releaseState.active = false
            releaseState.turnsRemaining = ZERO
        end

        releaseState.lastThreatLevel = threatLevel
        releaseState.lastHubHp = ownHubHp
        self.threatReleaseOffenseState = releaseState

        if releaseState.armed and not wasArmed then
            self:logDecision("ThreatRelease", "Armed after severe commandant threat", {
                turn = currentTurn,
                threatLevel = threatLevel,
                ownHubHp = ownHubHp
            })
        end
        if releaseState.active and not wasActive then
            self:logDecision("ThreatRelease", "Activated offensive conversion window", {
                turn = currentTurn,
                turnsRemaining = releaseState.turnsRemaining,
                threatLevel = threatLevel
            })
        end
        if wasActive and not releaseState.active then
            self:logDecision("ThreatRelease", "Offensive conversion window expired", {
                turn = currentTurn
            })
        end

        return releaseState
    end

    function aiClass:getThreatReleaseOffenseBonus(state, target, attackPos, actionKind)
        if not self:isThreatReleaseOffenseActive() then
            return ZERO
        end

        local releaseConfig = self:getThreatReleaseOffenseScoreConfig()
        local defaultReleaseConfig = DEFAULT_SCORE_PARAMS.THREAT_RELEASE_OFFENSE or {}
        local baseAttackBonus = valueOr(
            releaseConfig.ATTACK_BONUS,
            valueOr(defaultReleaseConfig.ATTACK_BONUS, ZERO)
        )
        local moveAttackBonus = valueOr(
            releaseConfig.MOVE_ATTACK_BONUS,
            valueOr(defaultReleaseConfig.MOVE_ATTACK_BONUS, ZERO)
        )
        local enemyHubAdjBonus = valueOr(
            releaseConfig.ENEMY_HUB_ADJ_BONUS,
            valueOr(defaultReleaseConfig.ENEMY_HUB_ADJ_BONUS, ZERO)
        )
        local enemyHubNearBonus = valueOr(
            releaseConfig.ENEMY_HUB_NEAR_BONUS,
            valueOr(defaultReleaseConfig.ENEMY_HUB_NEAR_BONUS, ZERO)
        )
        local enemyHubNearDistance = valueOr(
            releaseConfig.ENEMY_HUB_NEAR_DISTANCE,
            valueOr(defaultReleaseConfig.ENEMY_HUB_NEAR_DISTANCE, TWO)
        )

        local bonus = (actionKind == "move_attack") and moveAttackBonus or baseAttackBonus
        local aiPlayer = self:getFactionId()
        local enemyHub = aiPlayer and state and state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)] or nil

        if enemyHub then
            local focusPos = attackPos or target
            if target and target.row and target.col then
                focusPos = target
            end
            if focusPos and focusPos.row and focusPos.col then
                local distToEnemyHub = math.abs(focusPos.row - enemyHub.row) + math.abs(focusPos.col - enemyHub.col)
                if distToEnemyHub == ONE then
                    bonus = bonus + enemyHubAdjBonus
                elseif distToEnemyHub <= enemyHubNearDistance then
                    bonus = bonus + enemyHubNearBonus
                end
            end
        end

        return bonus
    end

    function aiClass:getObjectiveTargets(state, aiPlayer)
        local objectives = {}
        if not state then
            return objectives
        end

        aiPlayer = aiPlayer or self:getFactionId()
        if not aiPlayer then
            return objectives
        end

        local mobilityConfig = self:getMobilityScoreConfig()
        local objectiveConfig = mobilityConfig.OBJECTIVE_SUPPORT or {}
        local defaultObjectiveConfig = ((DEFAULT_SCORE_PARAMS.MOBILITY or {}).OBJECTIVE_SUPPORT or {})
        local commandantValue = valueOr(objectiveConfig.COMMANDANT_VALUE, defaultObjectiveConfig.COMMANDANT_VALUE)
        local valueWeightBase = valueOr(objectiveConfig.VALUE_WEIGHT_BASE, defaultObjectiveConfig.VALUE_WEIGHT_BASE)

        local used = {}

        for _, unit in ipairs(state.units or {}) do
            if unit.player and unit.player ~= aiPlayer and unit.player ~= ZERO then
                local key = hashPosition(unit)
                if key and not used[key] then
                    objectives[#objectives + ONE] = {
                        row = unit.row,
                        col = unit.col,
                        value = self:getUnitBaseValue(unit, state) or valueWeightBase,
                        type = unit.name,
                        attacked = false,
                        unitRef = unit
                    }
                    used[key] = true
                end
            end
        end

        for player, hub in pairs(state.commandHubs or {}) do
            if player ~= aiPlayer and hub then
                local key = hashPosition(hub)
                if key and not used[key] then
                    local hubUnit = self:getUnitAtPosition(state, hub.row, hub.col)
                    objectives[#objectives + ONE] = {
                        row = hub.row,
                        col = hub.col,
                        value = commandantValue,
                        type = "Commandant",
                        attacked = false,
                        unitRef = hubUnit
                    }
                    used[key] = true
                end
            end
        end

        return objectives
    end

    function aiClass:calculateObjectiveMobilityBonus(stateBefore, stateAfter, unit, movePos)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not stateBefore or not unit or not movePos then
            return ZERO
        end

        local objectives = self:getObjectiveTargets(stateAfter or stateBefore, aiPlayer)
        if #objectives == ZERO then
            return ZERO
        end

        local mobilityConfig = self:getMobilityScoreConfig()
        local objectiveConfig = mobilityConfig.OBJECTIVE_SUPPORT or {}
        local defaultObjectiveConfig = ((DEFAULT_SCORE_PARAMS.MOBILITY or {}).OBJECTIVE_SUPPORT or {})

        local progressPerTile = valueOr(objectiveConfig.PROGRESS_PER_TILE, defaultObjectiveConfig.PROGRESS_PER_TILE)
        local valueWeightBase = valueOr(objectiveConfig.VALUE_WEIGHT_BASE, defaultObjectiveConfig.VALUE_WEIGHT_BASE)
        local approachBonus = valueOr(objectiveConfig.APPROACH_BONUS, defaultObjectiveConfig.APPROACH_BONUS)
        local supportMultiplier = valueOr(objectiveConfig.SUPPORT_MULTIPLIER, defaultObjectiveConfig.SUPPORT_MULTIPLIER)
        local supportFlat = valueOr(objectiveConfig.SUPPORT_FLAT, defaultObjectiveConfig.SUPPORT_FLAT)

        local attackedLookup = {}
        for _, entry in ipairs(stateBefore.attackedObjectivesThisTurn or {}) do
            local key = hashPosition(entry)
            if key then
                attackedLookup[key] = true
            end
        end

        local evaluationState = stateAfter or stateBefore

        local function cloneUnitAt(row, col)
            return {
                row = row,
                col = col,
                name = unit.name,
                player = unit.player,
                currentHp = unit.currentHp,
                startingHp = unit.startingHp,
                atkDamage = unit.atkDamage,
                move = unit.move,
                atkRange = unit.atkRange,
                fly = unit.fly
            }
        end

        local bestProgressBonus = ZERO
        local bestSupportBonus = ZERO
        local supportTriggered = false

        local gridSize = GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE or DEFAULT_GRID_SIZE

        for _, objective in ipairs(objectives) do
            local targetUnit = objective.unitRef or self:getUnitAtPosition(evaluationState, objective.row, objective.col)
            if targetUnit then
                local function canDamageAtPosition(posRow, posCol)
                    local attacker = cloneUnitAt(posRow, posCol)
                    return self:canUnitDamageTargetFromPosition(
                        evaluationState,
                        attacker,
                        targetUnit,
                        posRow,
                        posCol,
                        {requirePositiveDamage = true}
                    )
                end

                local damagePossible = canDamageAtPosition(movePos.row, movePos.col)

                local function buildApproachCells()
                    local cells = {}
                    local added = {}

                    local function tryAdd(row, col)
                        if row < MIN_HP or row > gridSize or col < MIN_HP or col > gridSize then
                            return
                        end
                        if row == objective.row and col == objective.col then
                            return
                        end

                        local key = row .. "," .. col
                        if added[key] then
                            return
                        end

                        local occupant = self:getUnitAtPosition(evaluationState, row, col)
                        if occupant and occupant.player ~= aiPlayer then
                            return
                        end

                        if not canDamageAtPosition(row, col) then
                            return
                        end

                        added[key] = true
                        cells[#cells + ONE] = {row = row, col = col}
                    end

                    -- Always consider orthogonal adjacency for melee-style support
                    tryAdd(objective.row + ONE, objective.col)
                    tryAdd(objective.row - ONE, objective.col)
                    tryAdd(objective.row, objective.col + ONE)
                    tryAdd(objective.row, objective.col - ONE)

                    local attackRange = unit.atkRange or unitsInfo:getUnitAttackRange(unit, "OBJECTIVE_SUPPORT_RANGE") or MIN_HP
                    if attackRange > MIN_HP then
                        local searchRadius = attackRange + MIN_HP
                        for dRow = -searchRadius, searchRadius do
                            for dCol = -searchRadius, searchRadius do
                                if not (dRow == ZERO and dCol == ZERO) then
                                    local candidateRow = objective.row + dRow
                                    local candidateCol = objective.col + dCol
                                    tryAdd(candidateRow, candidateCol)
                                end
                            end
                        end
                    end

                    return cells
                end

                local approachCells = buildApproachCells()
                if #approachCells > ZERO then
                    local function distanceToApproach(row, col)
                        local best = math.huge
                        for _, cell in ipairs(approachCells) do
                            local dist = math.abs(row - cell.row) + math.abs(col - cell.col)
                            if dist < best then
                                best = dist
                            end
                        end
                        return best
                    end

                    local currentDistance = distanceToApproach(unit.row, unit.col)
                    local newDistance = distanceToApproach(movePos.row, movePos.col)

                    if newDistance < math.huge and currentDistance < math.huge then
                        local improvement = currentDistance - newDistance
                        local valueWeight = math.max(MIN_HP / MIN_HP, (objective.value or valueWeightBase) / valueWeightBase)

                        local approachReachable = false

                        for _, cell in ipairs(approachCells) do
                            local occupant = self:getUnitAtPosition(evaluationState, cell.row, cell.col)
                            if not occupant or occupant.player == aiPlayer then
                                local tempUnit = cloneUnitAt(movePos.row, movePos.col)
                                if self:canUnitReachPosition(evaluationState, tempUnit, cell) then
                                    approachReachable = true
                                    damagePossible = true
                                    break
                                end
                            end
                        end

                        if damagePossible then
                            local effectiveImprovement = improvement
                            if improvement <= ZERO then
                                effectiveImprovement = math.max(MIN_HP, improvement)
                            end

                            local progressBonus = effectiveImprovement * progressPerTile * valueWeight
                            if approachReachable then
                                progressBonus = progressBonus + (approachBonus * valueWeight)
                            end

                            if progressBonus > bestProgressBonus then
                                bestProgressBonus = progressBonus
                            end

                            local key = hashPosition(objective)
                            if key and attackedLookup[key] then
                                local supportBonus = progressBonus * supportMultiplier + supportFlat
                                if supportBonus > ZERO then
                                    supportTriggered = true
                                end
                                if supportBonus > bestSupportBonus then
                                    bestSupportBonus = supportBonus
                                end
                            end
                        end
                    end
                end
            end
        end

        return bestProgressBonus + bestSupportBonus, supportTriggered
    end

    function aiClass:addAttackedObjectiveToState(state, targetUnit, targetPos, aiPlayer)
        if not state then
            return
        end

        local actingPlayer = aiPlayer or self:getFactionId()
        local pos = targetPos or (targetUnit and {row = targetUnit.row, col = targetUnit.col})
        if not pos or not pos.row or not pos.col then
            return
        end

        if targetUnit then
            if actingPlayer and targetUnit.player == actingPlayer then
                return
            end
            if self:isObstacleUnit(targetUnit) then
                return
            end
        end

        state.attackedObjectivesThisTurn = state.attackedObjectivesThisTurn or {}
        for _, entry in ipairs(state.attackedObjectivesThisTurn) do
            if entry.row == pos.row and entry.col == pos.col then
                return
            end
        end

        table.insert(state.attackedObjectivesThisTurn, {
            row = pos.row,
            col = pos.col
        })
    end

    -- Helper to create position key for unit tracking (name-inclusive by default)
    function aiClass:getUnitKey(unit)
        return self.aiState.getUnitKey(self, unit, {includeName = true})
    end

    function aiClass:countTotalFriendlyUnits(state)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return ZERO
        end

        local total = ZERO
        for _, unit in ipairs(state.units or {}) do
            if unit.player == aiPlayer then
                local hp = unit.currentHp or unit.hp or unit.startingHp or ZERO
                if hp > ZERO then
                    total = total + MIN_HP
                end
            end
        end

        if state.supply and state.supply[aiPlayer] then
            for _, unit in ipairs(state.supply[aiPlayer]) do
                local hp = unit.currentHp or unit.hp or unit.startingHp or ZERO
                if hp > ZERO then
                    total = total + MIN_HP
                end
            end
        end

        return total
    end

    function aiClass:hasNonHealerAttackOptions(state, aiPlayer, opts)
        if not state or not aiPlayer then
            return false
        end

        local options = opts or {}
        local lookaheadTurns = math.max(ONE, valueOr(options.lookaheadTurns, ONE))
        local includeMove = options.includeMove ~= false

        local directEntries = self:collectAttackTargetEntries(state, nil, {
            mode = "direct",
            aiPlayer = aiPlayer,
            allowHealerAttacks = false,
            includeFriendlyFireCheck = true,
            requirePositiveDamage = true,
            minDamage = ONE
        })
        if #directEntries > ZERO then
            return true
        end

        if includeMove then
            local moveEntries = self:collectAttackTargetEntries(state, nil, {
                mode = "move",
                aiPlayer = aiPlayer,
                allowHealerAttacks = false,
                includeFriendlyFireCheck = true,
                requirePositiveDamage = true,
                minDamage = ONE,
                requireSafeMove = false,
                checkVulnerableMove = false
            })
            if #moveEntries > ZERO then
                return true
            end

            if lookaheadTurns > ONE then
                for _, ally in ipairs(state.units or {}) do
                    if self:isUnitEligibleForAction(ally, aiPlayer, nil, {
                        requireNotActed = true,
                        requireNotMoved = false,
                        disallowCommandant = true,
                        disallowRock = true,
                        allowHealerAttacks = false,
                        requireAlive = true
                    }) then
                        for _, enemy in ipairs(state.units or {}) do
                            if self:isAttackableEnemyUnit(enemy, aiPlayer) then
                                local threatTurn = self:getUnitThreatTiming(
                                    state,
                                    ally,
                                    enemy,
                                    lookaheadTurns,
                                    {
                                        requirePositiveDamage = true,
                                        considerCurrentActionState = true,
                                        allowMoveOnFirstTurn = true
                                    }
                                )
                                if threatTurn and threatTurn <= lookaheadTurns then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end

        return false
    end

    function aiClass:shouldHealerBeOffensive(state, opts)
        if not state then
            return false
        end

        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return false
        end

        local options = opts or {}
        local healerConfig = self:getHealerOffenseScoreConfig()
        local defaultHealerConfig = DEFAULT_SCORE_PARAMS.HEALER_OFFENSE or {}
        local doctrineConfig = self:getDoctrineScoreConfig()
        local healerDoctrine = doctrineConfig.HEALER or {}
        local enabled = valueOr(healerConfig.ENABLED, valueOr(defaultHealerConfig.ENABLED, true))
        if not enabled then
            return false
        end

        local currentTurn = state.currentTurn or state.turnNumber or (GAME.CURRENT and GAME.CURRENT.TURN) or ONE
        local lateGameTurnMin = valueOr(
            healerConfig.LATE_GAME_TURN_MIN,
            valueOr(defaultHealerConfig.LATE_GAME_TURN_MIN, TEN)
        )
        local maxFriendlyNonHealerUnits = valueOr(
            healerConfig.MAX_FRIENDLY_NON_HEALER_UNITS,
            valueOr(defaultHealerConfig.MAX_FRIENDLY_NON_HEALER_UNITS, ONE)
        )
        local maxEnemyUnits = valueOr(
            healerConfig.MAX_ENEMY_UNITS,
            valueOr(defaultHealerConfig.MAX_ENEMY_UNITS, TWO)
        )
        local requireNoNonHealerAttackers = valueOr(
            healerConfig.REQUIRE_NO_NON_HEALER_ATTACKERS,
            valueOr(defaultHealerConfig.REQUIRE_NO_NON_HEALER_ATTACKERS, true)
        )
        local nonHealerAttackLookaheadTurns = valueOr(
            healerConfig.NON_HEALER_ATTACK_LOOKAHEAD_TURNS,
            valueOr(defaultHealerConfig.NON_HEALER_ATTACK_LOOKAHEAD_TURNS, ONE)
        )
        local allowEmergencyCommandantDefense = valueOr(
            healerConfig.ALLOW_EMERGENCY_COMMANDANT_DEFENSE,
            valueOr(defaultHealerConfig.ALLOW_EMERGENCY_COMMANDANT_DEFENSE, true)
        )
        local emergencyHubHpThreshold = valueOr(
            healerConfig.EMERGENCY_HUB_HP_AT_OR_BELOW,
            valueOr(defaultHealerConfig.EMERGENCY_HUB_HP_AT_OR_BELOW, FIVE)
        )

        local friendlyNonHealerUnits = ZERO
        local enemyUnits = ZERO
        for _, unit in ipairs(state.units or {}) do
            local hp = unit.currentHp or unit.hp or unit.startingHp or ZERO
            if hp > ZERO and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                if unit.player == aiPlayer then
                    if not self:unitHasTag(unit, "healer") then
                        friendlyNonHealerUnits = friendlyNonHealerUnits + ONE
                    end
                elseif unit.player ~= ZERO then
                    enemyUnits = enemyUnits + ONE
                end
            end
        end

        local isLateGame = currentTurn >= lateGameTurnMin
        local endgameShapeReady = friendlyNonHealerUnits <= maxFriendlyNonHealerUnits and enemyUnits <= maxEnemyUnits

        local emergencyDefenseAllowed = false
        if allowEmergencyCommandantDefense and options.allowEmergencyDefense then
            local threatData = options.commandantThreatData
            if not threatData then
                threatData = self:analyzeHubThreat(state)
            end
            local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
            local ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO
            local underThreat = threatData and ((threatData.isUnderAttack == true) or (threatData.isUnderProjectedThreat == true))
            if underThreat and ownHub and ownHubHp <= emergencyHubHpThreshold then
                emergencyDefenseAllowed = true
            end
        end

        if valueOr(healerDoctrine.ALLOW_OFFENSIVE, true) == false then
            return emergencyDefenseAllowed
        end

        if not isLateGame and not emergencyDefenseAllowed then
            return false
        end
        if not endgameShapeReady and not emergencyDefenseAllowed then
            return false
        end

        if requireNoNonHealerAttackers then
            local nonHealerCanAttack = self:hasNonHealerAttackOptions(state, aiPlayer, {
                lookaheadTurns = nonHealerAttackLookaheadTurns,
                includeMove = true
            })
            if nonHealerCanAttack and not emergencyDefenseAllowed then
                return false
            end
        end

        return true
    end

    -- Corvette-specific positional evaluation
    function aiClass:getCorvettePositionalScore(state, unit)
        local score = ZERO
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ZERO
        end
        if not state or not state.units then
            return ZERO
        end
        local scoreConfig = self:getScoreConfig()
        local corvetteConfig = scoreConfig.CORVETTE or {}
        local defaultCorvetteConfig = DEFAULT_SCORE_PARAMS.CORVETTE or {}
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        local corvetteProfile = self:getUnitProfile(unit)
        local minRange = (corvetteProfile and corvetteProfile.minRange) or TWO
        local maxRange = (corvetteProfile and corvetteProfile.maxRange) or THREE
        local extendedRange = maxRange + ONE

        -- Check for enemies that Corvette can attack (range 2-3 with line of sight)
        for _, enemy in ipairs(state.units) do
            if enemy.player ~= aiPlayer then
                local distance = math.abs(unit.row - enemy.row) + math.abs(unit.col - enemy.col)

                -- Corvette optimal range is 2-3
                if distance >= minRange and distance <= maxRange then
                    -- Check line of sight
                    if self:hasLineOfSight(state, unit, enemy) then
                        if self:unitHasTag(enemy, "hub") then
                            score = score + valueOr(corvetteConfig.ATTACK_COMMANDANT, defaultCorvetteConfig.ATTACK_COMMANDANT)
                        elseif self:unitHasTag(enemy, "tank") then
                            score = score + valueOr(corvetteConfig.ATTACK_HIGH_VALUE, defaultCorvetteConfig.ATTACK_HIGH_VALUE)
                        else
                            score = score + valueOr(corvetteConfig.ATTACK_STANDARD, defaultCorvetteConfig.ATTACK_STANDARD)
                        end
                    end
                end
            end
        end

        -- Penalty for being adjacent to enemies
        for _, dir in ipairs(self:getOrthogonalDirections()) do
            local checkRow = unit.row + dir.row
            local checkCol = unit.col + dir.col
            local adjacentUnit = self:getUnitAtPosition(state, checkRow, checkCol)

            if adjacentUnit and adjacentUnit.player ~= aiPlayer and not self:unitHasTag(adjacentUnit, "corvette") then
                score = score - valueOr(corvetteConfig.ADJACENT_ENEMY_PENALTY, defaultCorvetteConfig.ADJACENT_ENEMY_PENALTY)
            end
        end

        -- Bonus for maintaining good firing lanes to enemy hub
        if enemyHub then
            local distToEnemyHub = math.abs(unit.row - enemyHub.row) + math.abs(unit.col - enemyHub.col)

            -- BALANCED: Hub LOS bonus (reduced by 30% from audit)
            if distToEnemyHub >= minRange and distToEnemyHub <= maxRange then
                if self:hasLineOfSight(state, unit, enemyHub) then
                    score = score + valueOr(corvetteConfig.HUB_LOS_BONUS, defaultCorvetteConfig.HUB_LOS_BONUS)
                else
                    score = score + valueOr(corvetteConfig.HUB_RANGE_NO_LOS_BONUS, defaultCorvetteConfig.HUB_RANGE_NO_LOS_BONUS)
                end
            elseif distToEnemyHub == extendedRange then
                score = score + valueOr(corvetteConfig.HUB_RANGE_DIST4_BONUS, defaultCorvetteConfig.HUB_RANGE_DIST4_BONUS)
            end
        end

        -- Strategic positioning bonus - avoid corners and edges where possible
        local edgeDistance = math.min(
            unit.row - ONE,  -- Distance from top
            GAME.CONSTANTS.GRID_SIZE - unit.row,  -- Distance from bottom
            unit.col - ONE,  -- Distance from left
            GAME.CONSTANTS.GRID_SIZE - unit.col   -- Distance from right
        )

        if edgeDistance >= TWO then
            score = score + valueOr(corvetteConfig.CENTER_BONUS, defaultCorvetteConfig.CENTER_BONUS)
        end

        return score
    end

    function aiClass:getNearbyDamagedAlliesScore(state, unit)
        return self.aiEvaluation.getNearbyDamagedAlliesScore(self, state, unit)
    end

    function aiClass:getExposureScore(state, unit)
        return self.aiEvaluation.getExposureScore(self, state, unit)
    end

    function aiClass:assessUnitThreatLevel(unit, distanceToOurHub)
        return self.aiEvaluation.assessUnitThreatLevel(self, unit, distanceToOurHub)
    end

    function aiClass:analyzeHubThreat(state)
        local aiPlayer = self:getFactionId()
        local function emptyThreatResult()
            return {
                isUnderAttack = false,
                isUnderProjectedThreat = false,
                type = "none",
                threatLevel = ZERO,
                immediateThreatLevel = ZERO,
                projectedThreatLevel = ZERO,
                meleeThreats = ZERO,
                rangedThreats = ZERO,
                projectedThreatActionable = false,
                projectedThreatActionableScore = ZERO,
                projectedThreatUnitsInWindow = ZERO,
                projectedThreatReason = "none",
                lookaheadTurnsUsed = ZERO,
                threats = {},
                threatsProjected = {}
            }
        end

        if not aiPlayer then
            return emptyThreatResult()
        end
        if not state or not state.commandHubs then
            return emptyThreatResult()
        end
        local ourHub = state.commandHubs[aiPlayer]
    
        if not ourHub then 
            return emptyThreatResult()
        end
    
        local totalThreat = ZERO
        local immediateThreatLevel = ZERO
        local projectedThreatLevel = ZERO
        local meleeThreats = ZERO
        local rangedThreats = ZERO
        local threats = {}
        local threatsProjected = {}
        local hubThreatConfig = self:getScoreConfig().HUB_THREAT or {}
        local defaultHubThreatConfig = DEFAULT_SCORE_PARAMS.HUB_THREAT or {}
        local lookaheadConfig = self:getHubThreatLookaheadScoreConfig()
        local defaultLookaheadConfig = DEFAULT_SCORE_PARAMS.HUB_THREAT_LOOKAHEAD or {}
        local strategyConfig = self:getStrategyScoreConfig()
        local defenseConfig = strategyConfig.DEFENSE or {}
        local threatResponseConfig = self:getCommandantThreatResponseScoreConfig()
        local defaultThreatResponseConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_THREAT_RESPONSE or {}

        local maxDistance = valueOr(hubThreatConfig.MAX_DISTANCE, defaultHubThreatConfig.MAX_DISTANCE)
        local distanceBase = valueOr(hubThreatConfig.DISTANCE_BASE, defaultHubThreatConfig.DISTANCE_BASE)
        local distanceMultiplier = valueOr(hubThreatConfig.DISTANCE_MULT, defaultHubThreatConfig.DISTANCE_MULT)
        local potentialThreshold = valueOr(hubThreatConfig.POTENTIAL_THRESHOLD, defaultHubThreatConfig.POTENTIAL_THRESHOLD)
        local rangedMin = valueOr(hubThreatConfig.RANGED_MIN_RANGE, defaultHubThreatConfig.RANGED_MIN_RANGE)
        local rangedMax = valueOr(hubThreatConfig.RANGED_MAX_RANGE, defaultHubThreatConfig.RANGED_MAX_RANGE)
        local artilleryBonus = valueOr(hubThreatConfig.ARTILLERY_RANGE_BONUS, defaultHubThreatConfig.ARTILLERY_RANGE_BONUS)
        local corvetteLosBonus = valueOr(hubThreatConfig.CORVETTE_LOS_BONUS, defaultHubThreatConfig.CORVETTE_LOS_BONUS)
        local baseByUnit = hubThreatConfig.UNIT_BASE or {}
        local meleeRangeByUnit = hubThreatConfig.MELEE_TRIGGER_RANGE or {}
        local lookaheadEnabled = valueOr(lookaheadConfig.ENABLED, valueOr(defaultLookaheadConfig.ENABLED, true))
        local horizonNormal = math.max(
            ONE,
            valueOr(lookaheadConfig.HORIZON_NORMAL, valueOr(defaultLookaheadConfig.HORIZON_NORMAL, TWO))
        )
        local horizonThreatened = math.max(
            horizonNormal,
            valueOr(lookaheadConfig.HORIZON_THREATENED, valueOr(defaultLookaheadConfig.HORIZON_THREATENED, THREE))
        )
        local frontierMax = math.max(
            ONE,
            valueOr(lookaheadConfig.FRONTIER_MAX, valueOr(defaultLookaheadConfig.FRONTIER_MAX, 16))
        )
        local turnWeight = lookaheadConfig.TURN_WEIGHT
            or defaultLookaheadConfig.TURN_WEIGHT
            or {}
        local projectedThreatMult = valueOr(
            lookaheadConfig.PROJECTED_THREAT_MULT,
            valueOr(defaultLookaheadConfig.PROJECTED_THREAT_MULT, ONE)
        )
        local projectedTriggerMinScore = math.max(
            ZERO,
            valueOr(defenseConfig.PROJECTED_TRIGGER_MIN_SCORE, 120)
        )
        local projectedTriggerMaxTurn = math.max(
            ONE,
            valueOr(defenseConfig.PROJECTED_TRIGGER_MAX_TURN, TWO)
        )
        local projectedTriggerMinUnits = math.max(
            ONE,
            valueOr(defenseConfig.PROJECTED_TRIGGER_MIN_UNITS, ONE)
        )
        local ownHubHp = ourHub.currentHp or ourHub.startingHp or ZERO
        local hubHpTrigger = valueOr(
            threatResponseConfig.HUB_HP_TRIGGER,
            valueOr(defaultThreatResponseConfig.HUB_HP_TRIGGER, EIGHT)
        )
        local lookaheadTurnsUsed = horizonNormal
    
        for _, unit in ipairs(state.units or {}) do
            if unit.player ~= aiPlayer and not self:isObstacleUnit(unit) and not self:isHubUnit(unit) then
                local distance = math.abs(unit.row - ourHub.row) + math.abs(unit.col - ourHub.col)
            
                -- Check for immediate threats
                if distance <= maxDistance then
                    local threatLevel = baseByUnit[unit.name] or ZERO
                    if threatLevel > ZERO then
                        local meleeRange = meleeRangeByUnit[unit.name]
                        if meleeRange and distance <= meleeRange then
                            meleeThreats = meleeThreats + ONE
                        end

                        if self:unitHasTag(unit, "ranged") and distance >= rangedMin and distance <= rangedMax then
                            if self:unitHasTag(unit, "artillery") then
                                rangedThreats = rangedThreats + ONE
                                threatLevel = threatLevel + artilleryBonus
                            elseif self:unitHasTag(unit, "los") and self:hasLineOfSight(state, unit, ourHub) then
                                rangedThreats = rangedThreats + ONE
                                threatLevel = threatLevel + corvetteLosBonus
                            end
                        end

                        -- Distance factor (closer = more threatening)
                        threatLevel = threatLevel + (distanceBase - distance) * distanceMultiplier
                    
                        immediateThreatLevel = immediateThreatLevel + threatLevel
                    
                        table.insert(threats, {
                            unit = unit,
                            distance = distance,
                            threatLevel = threatLevel
                        })
                    end
                end
            end
        end

        local underImmediateThreat = (meleeThreats > ZERO or rangedThreats > ZERO)
        if underImmediateThreat or ownHubHp <= hubHpTrigger then
            lookaheadTurnsUsed = horizonThreatened
        end

        if lookaheadEnabled then
            for _, unit in ipairs(state.units or {}) do
                if unit.player ~= aiPlayer and not self:isObstacleUnit(unit) and not self:isHubUnit(unit) then
                    local unitBaseThreat = baseByUnit[unit.name] or ZERO
                    if unitBaseThreat > ZERO then
                        local projectedTurn, projectedMode = self:getUnitThreatTiming(
                            state,
                            unit,
                            ourHub,
                            lookaheadTurnsUsed,
                            {
                                requirePositiveDamage = true,
                                considerCurrentActionState = true,
                                allowMoveOnFirstTurn = true,
                                maxFrontierNodes = frontierMax
                            }
                        )

                        if projectedTurn and projectedTurn <= lookaheadTurnsUsed then
                            local turnScale = valueOr(turnWeight[projectedTurn], ZERO)
                            if turnScale > ZERO then
                                local distance = math.abs(unit.row - ourHub.row) + math.abs(unit.col - ourHub.col)
                                local threatScore = unitBaseThreat

                                if self:unitHasTag(unit, "ranged") and distance >= rangedMin and distance <= rangedMax then
                                    if self:unitHasTag(unit, "artillery") then
                                        threatScore = threatScore + artilleryBonus
                                    elseif self:unitHasTag(unit, "los") then
                                        threatScore = threatScore + corvetteLosBonus
                                    end
                                end

                                threatScore = threatScore + ((distanceBase - distance) * distanceMultiplier)
                                threatScore = threatScore * turnScale * projectedThreatMult

                                if threatScore > ZERO then
                                    projectedThreatLevel = projectedThreatLevel + threatScore
                                    table.insert(threatsProjected, {
                                        unit = unit,
                                        distance = distance,
                                        threatTurn = projectedTurn,
                                        threatMode = projectedMode,
                                        threatLevel = threatScore
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end

        totalThreat = immediateThreatLevel + projectedThreatLevel

        self:sortScoredEntries(threats, {
            scoreField = "threatLevel",
            descending = true
        })
        self:sortScoredEntries(threatsProjected, {
            scoreField = "threatLevel",
            secondaryField = "threatTurn",
            descending = true
        })

        local projectedThreatActionableScore = ZERO
        local projectedThreatUnitsInWindow = ZERO
        local projectedUnitSeen = {}
        for _, projected in ipairs(threatsProjected) do
            if projected.threatTurn and projected.threatTurn <= projectedTriggerMaxTurn then
                projectedThreatActionableScore = projectedThreatActionableScore + (projected.threatLevel or ZERO)
                local unitKey = projected.unit and self:getUnitKey(projected.unit)
                if not unitKey then
                    unitKey = projected.unit and hashPosition(projected.unit)
                end
                if unitKey and not projectedUnitSeen[unitKey] then
                    projectedUnitSeen[unitKey] = true
                    projectedThreatUnitsInWindow = projectedThreatUnitsInWindow + ONE
                end
            end
        end

        local projectedThreatActionable = projectedThreatActionableScore >= projectedTriggerMinScore
            and projectedThreatUnitsInWindow >= projectedTriggerMinUnits

        local projectedThreatReason = "none"
        if projectedThreatActionable then
            projectedThreatReason = "meets_threshold"
        elseif projectedThreatActionableScore > ZERO then
            if projectedThreatUnitsInWindow < projectedTriggerMinUnits then
                projectedThreatReason = "insufficient_units"
            else
                projectedThreatReason = "insufficient_score"
            end
        end
    
        -- Determine threat type and status
        local isUnderAttack = underImmediateThreat
        local isUnderProjectedThreat = projectedThreatLevel > ZERO
        local threatType = "none"
    
        if meleeThreats > rangedThreats then
            threatType = "melee"
        elseif rangedThreats > ZERO then
            threatType = "ranged"
        elseif isUnderProjectedThreat then
            threatType = "projected"
        elseif totalThreat > potentialThreshold then
            threatType = "potential"
        end
    
        return {
            isUnderAttack = isUnderAttack,
            isUnderProjectedThreat = isUnderProjectedThreat,
            type = threatType,
            threatLevel = totalThreat,
            immediateThreatLevel = immediateThreatLevel,
            projectedThreatLevel = projectedThreatLevel,
            meleeThreats = meleeThreats,
            rangedThreats = rangedThreats,
            projectedThreatActionable = projectedThreatActionable,
            projectedThreatActionableScore = projectedThreatActionableScore,
            projectedThreatUnitsInWindow = projectedThreatUnitsInWindow,
            projectedThreatReason = projectedThreatReason,
            lookaheadTurnsUsed = lookaheadTurnsUsed,
            threats = threats,
            threatsProjected = threatsProjected
        }
    end

    function aiClass:isProjectedThreatActionable(state, threatData)
        local data = threatData or self:analyzeHubThreat(state)
        if not data then
            return false, ZERO, ZERO, "none"
        end

        local actionable = data.projectedThreatActionable == true
        local score = data.projectedThreatActionableScore or ZERO
        local unitsInWindow = data.projectedThreatUnitsInWindow or ZERO
        local reason = data.projectedThreatReason or "none"

        return actionable, score, unitsInWindow, reason
    end

    function aiClass:updateDefenseModeState(state, threatData)
        local strategyConfig = self:getStrategyScoreConfig()
        local defenseConfig = strategyConfig.DEFENSE or {}
        local holdTurnsCfg = math.max(ONE, valueOr(defenseConfig.HYSTERESIS_HOLD_TURNS, TWO))
        local exitMult = math.max(0.1, valueOr(defenseConfig.HYSTERESIS_EXIT_MULT, 0.7))
        local currentTurn = self:getStateTurn(state)
        local data = threatData or self:analyzeHubThreat(state)
        local prior = self.defenseModeState or {}

        local immediateThreat = data and data.isUnderAttack == true
        local projectedActionable, projectedScore, _, projectedReason = self:isProjectedThreatActionable(state, data)

        local nextState = {
            active = false,
            holdTurnsLeft = ZERO,
            enterTurn = prior.enterTurn,
            reason = nil,
            enterScore = prior.enterScore or ZERO
        }

        if immediateThreat then
            nextState.active = true
            nextState.reason = "immediate"
            nextState.holdTurnsLeft = holdTurnsCfg
            nextState.enterTurn = prior.enterTurn or currentTurn
            nextState.enterScore = math.max(prior.enterScore or ZERO, projectedScore or ZERO)
        elseif projectedActionable then
            nextState.active = true
            nextState.reason = projectedReason ~= "none" and ("projected:" .. projectedReason) or "projected"
            nextState.holdTurnsLeft = holdTurnsCfg
            nextState.enterTurn = prior.active and prior.enterTurn or currentTurn
            nextState.enterScore = math.max(prior.enterScore or ZERO, projectedScore or ZERO)
        else
            local priorActive = prior.active == true
            if priorActive then
                local threshold = (prior.enterScore or ZERO) * exitMult
                local stillAboveExitBand = projectedScore > ZERO and projectedScore >= threshold
                if stillAboveExitBand then
                    nextState.active = true
                    nextState.reason = "projected:hysteresis_score_band"
                    nextState.holdTurnsLeft = math.max(ONE, prior.holdTurnsLeft or holdTurnsCfg)
                    nextState.enterTurn = prior.enterTurn or currentTurn
                    nextState.enterScore = prior.enterScore or projectedScore
                else
                    local holdLeft = (prior.holdTurnsLeft or holdTurnsCfg) - ONE
                    if holdLeft > ZERO then
                        nextState.active = true
                        nextState.reason = "projected:hysteresis_hold"
                        nextState.holdTurnsLeft = holdLeft
                        nextState.enterTurn = prior.enterTurn or currentTurn
                        nextState.enterScore = prior.enterScore or ZERO
                    else
                        nextState.active = false
                        nextState.reason = "exit"
                        nextState.holdTurnsLeft = ZERO
                        nextState.enterTurn = nil
                        nextState.enterScore = ZERO
                    end
                end
            end
        end

        self.defenseModeState = nextState
        local priorActive = prior.active == true
        local nextActive = nextState.active == true
        if (not priorActive) and nextActive then
            self.defendHardEnterReason = nextState.reason
        elseif priorActive and (not nextActive) then
            self.defendHardExitReason = nextState.reason
        end
        return nextState
    end

    function aiClass:getCommandantThreatLookup(state, aiPlayer)
        aiPlayer = aiPlayer or self:getFactionId()
        if not aiPlayer or not state then
            return {isUnderAttack = false, threatLevel = ZERO, threats = {}}, {}
        end

        local threatData = self:analyzeHubThreat(state) or {isUnderAttack = false, threatLevel = ZERO, threats = {}}
        local lookup = {}

        local function mergeThreat(threat, isProjected)
            local threatUnit = threat and threat.unit
            local key = hashPosition(threatUnit)
            if not key then
                return
            end

            local enrichedThreat = {
                unit = threatUnit,
                distance = threat.distance,
                threatLevel = threat.threatLevel or ZERO,
                threatTurn = threat.threatTurn,
                threatMode = threat.threatMode,
                projected = isProjected == true
            }
            local existing = lookup[key]
            if (not existing) or ((enrichedThreat.threatLevel or ZERO) > (existing.threatLevel or ZERO)) then
                lookup[key] = enrichedThreat
            end
        end

        for _, threat in ipairs(threatData.threats or {}) do
            mergeThreat(threat, false)
        end
        for _, threat in ipairs(threatData.threatsProjected or {}) do
            mergeThreat(threat, true)
        end

        return threatData, lookup
    end

    local STRATEGY_INTENT = {
        DEFEND_HARD = "DEFEND_HARD",
        SIEGE_SETUP = "SIEGE_SETUP",
        SIEGE_EXECUTE = "SIEGE_EXECUTE",
        STABILIZE = "STABILIZE"
    }

    local STRATEGY_ROLE_ORDER = {
        primary = ONE,
        secondary = TWO,
        screen = THREE,
        anchor = FOUR
    }

    function aiClass:getStateTurn(state)
        return state.currentTurn or state.turnNumber or (GAME.CURRENT and GAME.CURRENT.TURN) or ONE
    end

    function aiClass:getEnemySupplyRemaining(state, aiPlayer)
        if not state then
            return ZERO
        end
        local owner = aiPlayer or self:getFactionId()
        if not owner then
            return ZERO
        end
        local opponent = self:getOpponentPlayer(owner)
        if not opponent then
            return ZERO
        end
        local supply = (state.supply and state.supply[opponent]) or {}
        local remaining = ZERO
        for _, unit in ipairs(supply) do
            if unit then
                local hp = unit.currentHp or unit.startingHp or MIN_HP
                if hp > ZERO then
                    remaining = remaining + ONE
                end
            end
        end
        return remaining
    end

    function aiClass:isCombatContactTriggered(state, aiPlayer)
        if not state then
            return false, {reason = "missing_state"}
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local phaseConfig = doctrineConfig.GAME_PHASE or {}
        if valueOr(phaseConfig.MID_CONTACT_TRIGGER_ENABLED, true) == false then
            return false, {reason = "disabled"}
        end

        local owner = aiPlayer or self:getFactionId()
        if not owner then
            return false, {reason = "missing_player"}
        end

        local contactDistance = math.max(ONE, valueOr(phaseConfig.CONTACT_DISTANCE_THRESHOLD, THREE))
        local recentWindow = math.max(ONE, valueOr(phaseConfig.CONTACT_RECENT_DAMAGE_WINDOW, TWO))
        local closestDistance = math.huge
        local closeContact = false
        local damagedCombatUnits = ZERO

        for _, unit in ipairs(state.units or {}) do
            if not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                local hp = unit.currentHp or unit.startingHp or ZERO
                local maxHp = unit.startingHp or hp or ZERO
                if hp > ZERO and maxHp > ZERO and hp < maxHp then
                    damagedCombatUnits = damagedCombatUnits + ONE
                end
            end
        end

        for _, friendly in ipairs(state.units or {}) do
            if friendly.player == owner and not self:isHubUnit(friendly) and not self:isObstacleUnit(friendly) then
                for _, enemy in ipairs(state.units or {}) do
                    if self:isAttackableEnemyUnit(enemy, owner, {excludeHub = true}) then
                        local dist = math.abs(friendly.row - enemy.row) + math.abs(friendly.col - enemy.col)
                        if dist < closestDistance then
                            closestDistance = dist
                        end
                        if dist <= contactDistance then
                            closeContact = true
                            break
                        end
                    end
                end
            end
            if closeContact then
                break
            end
        end

        local turnsWithoutDamage = state.turnsWithoutDamage
        if turnsWithoutDamage == nil then
            turnsWithoutDamage = math.huge
        end
        local recentDamageSignal = turnsWithoutDamage <= recentWindow and damagedCombatUnits > ZERO
        local triggered = closeContact or recentDamageSignal
        local reason = "none"
        if closeContact then
            reason = "proximity"
        elseif recentDamageSignal then
            reason = "recent_damage"
        end

        return triggered, {
            reason = reason,
            closeContact = closeContact,
            recentDamageSignal = recentDamageSignal,
            closestDistance = (closestDistance == math.huge) and nil or closestDistance,
            damagedCombatUnits = damagedCombatUnits
        }
    end

    function aiClass:getGameTempoPhase(state)
        local doctrineConfig = self:getDoctrineScoreConfig()
        local phaseConfig = doctrineConfig.GAME_PHASE or {}
        local aiPlayer = self:getFactionId()
        local turnNumber = self:getStateTurn(state)
        local earlyTurnMax = math.max(ONE, valueOr(phaseConfig.EARLY_TURN_MAX, TEN))
        local enemySupplyRemaining = self:getEnemySupplyRemaining(state, aiPlayer)
        local endBySupply = valueOr(phaseConfig.ENEMY_SUPPLY_EMPTY_ENDGAME, true)

        local contactTriggered, contactMeta = self:isCombatContactTriggered(state, aiPlayer)
        local phase = "mid"
        local reason = "turn_cutoff"

        if endBySupply and enemySupplyRemaining <= ZERO then
            phase = "end"
            reason = "enemy_supply_empty"
        elseif turnNumber <= earlyTurnMax and not contactTriggered then
            phase = "early"
            reason = "turn_window"
        elseif contactTriggered and turnNumber <= earlyTurnMax then
            phase = "mid"
            reason = "contact_trigger"
        end

        return {
            phase = phase,
            reason = reason,
            turn = turnNumber,
            enemySupplyRemaining = enemySupplyRemaining,
            contactTriggered = contactTriggered == true,
            contactMeta = contactMeta
        }
    end

    function aiClass:estimateCommandantKillEta(state, horizonTurns)
        local aiPlayer = self:getFactionId()
        if not state or not aiPlayer then
            return math.huge
        end

        local horizon = math.max(ONE, horizonTurns or THREE)
        local enemyPlayer = self:getOpponentPlayer(aiPlayer)
        local enemyHub = state.commandHubs and state.commandHubs[enemyPlayer]
        if not enemyHub then
            return horizon + ONE
        end

        local enemyHubHp = enemyHub.currentHp or enemyHub.startingHp or ZERO
        if enemyHubHp <= ZERO then
            return ZERO
        end

        local targetHub = {
            name = "Commandant",
            player = enemyPlayer,
            row = enemyHub.row,
            col = enemyHub.col,
            currentHp = enemyHubHp,
            startingHp = enemyHub.startingHp or enemyHubHp
        }

        local projectedDamageByTurn = {}
        for turn = ONE, horizon do
            projectedDamageByTurn[turn] = ZERO
        end

        for _, unit in ipairs(state.units or {}) do
            if unit.player == aiPlayer and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                local damage = self:calculateDamage(unit, targetHub) or ZERO
                if damage > ZERO then
                    local threatTurn = self:getUnitThreatTiming(
                        state,
                        unit,
                        targetHub,
                        horizon,
                        {
                            requirePositiveDamage = true,
                            considerCurrentActionState = false,
                            allowMoveOnFirstTurn = true,
                            maxFrontierNodes = 16
                        }
                    )
                    if threatTurn and threatTurn <= horizon then
                        projectedDamageByTurn[threatTurn] = projectedDamageByTurn[threatTurn] + damage
                    end
                end
            end
        end

        local cumulativeDamage = ZERO
        for turn = ONE, horizon do
            cumulativeDamage = cumulativeDamage + (projectedDamageByTurn[turn] or ZERO)
            if cumulativeDamage >= enemyHubHp then
                return turn
            end
        end

        return horizon + ONE
    end

    function aiClass:estimateEliminateAllEta(state, horizonTurns)
        local aiPlayer = self:getFactionId()
        if not state or not aiPlayer then
            return math.huge
        end

        local horizon = math.max(ONE, horizonTurns or THREE)
        local enemyPlayer = self:getOpponentPlayer(aiPlayer)
        local enemyUnits = {}
        for _, unit in ipairs(state.units or {}) do
            if unit.player == enemyPlayer and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                enemyUnits[#enemyUnits + ONE] = unit
            end
        end

        if #enemyUnits == ZERO then
            return ZERO
        end

        local maxEta = ZERO
        for _, target in ipairs(enemyUnits) do
            local bestTurn = nil
            for _, unit in ipairs(state.units or {}) do
                if unit.player == aiPlayer and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                    local damage = self:calculateDamage(unit, target) or ZERO
                    if damage > ZERO then
                        local threatTurn = self:getUnitThreatTiming(
                            state,
                            unit,
                            target,
                            horizon,
                            {
                                requirePositiveDamage = true,
                                considerCurrentActionState = false,
                                allowMoveOnFirstTurn = true,
                                maxFrontierNodes = 16
                            }
                        )
                        if threatTurn and threatTurn <= horizon and ((not bestTurn) or threatTurn < bestTurn) then
                            bestTurn = threatTurn
                        end
                    end
                end
            end
            if not bestTurn then
                return horizon + ONE
            end
            if bestTurn > maxEta then
                maxEta = bestTurn
            end
        end

        return maxEta
    end

    function aiClass:estimateEndgamePathEta(state, path, horizonTurns)
        local selectedPath = tostring(path or "hub")
        if selectedPath == "wipe" then
            return self:estimateEliminateAllEta(state, horizonTurns)
        end
        return self:estimateCommandantKillEta(state, horizonTurns)
    end

    function aiClass:chooseEndgameWinPathByEta(state, opts)
        local options = opts or {}
        local doctrineConfig = self:getDoctrineScoreConfig()
        local closeoutConfig = doctrineConfig.ENDGAME_CLOSEOUT or {}
        local horizon = math.max(ONE, valueOr(options.horizon, valueOr(closeoutConfig.ETA_HORIZON_TURNS, THREE)))
        local preferMode = tostring(valueOr(closeoutConfig.PREFER, "eta_based"))
        local tieBreak = tostring(valueOr(closeoutConfig.TIE_BREAK, "commandant_first"))
        local hubEta = self:estimateCommandantKillEta(state, horizon)
        local wipeEta = self:estimateEliminateAllEta(state, horizon)

        local selected = "hub"
        if preferMode == "eta_based" then
            if wipeEta < hubEta then
                selected = "wipe"
            elseif hubEta < wipeEta then
                selected = "hub"
            else
                selected = (tieBreak == "commandant_first") and "hub" or "wipe"
            end
        elseif preferMode == "wipe" then
            selected = "wipe"
        end

        return {
            path = selected,
            hubEta = hubEta,
            wipeEta = wipeEta,
            horizon = horizon
        }
    end

    function aiClass:getPhaseTempoContext(state)
        if not state then
            return {
                phase = "mid",
                reason = "missing_state",
                enemySupplyRemaining = ZERO,
                contactTriggered = false
            }
        end

        local aiPlayer = self:getFactionId() or ZERO
        local turnNumber = self:getStateTurn(state)
        local cacheKey = string.format(
            "%d:%d:%d:%d",
            turnNumber,
            aiPlayer,
            state.turnActionCount or ZERO,
            state.hasDeployedThisTurn and ONE or ZERO
        )
        if self._phaseTempoContext and self._phaseTempoContext.cacheKey == cacheKey then
            return self._phaseTempoContext
        end

        local tempo = self:getGameTempoPhase(state)
        tempo.cacheKey = cacheKey

        local doctrineConfig = self:getDoctrineScoreConfig()
        local phaseConfig = doctrineConfig.GAME_PHASE or {}
        local countKey = string.format("%d:%d", turnNumber, aiPlayer)
        if self._phaseTempoCountKey ~= countKey then
            if tempo.phase == "early" then
                self.phaseEarlyTurns = (self.phaseEarlyTurns or ZERO) + ONE
            elseif tempo.phase == "end" then
                self.phaseEndTurns = (self.phaseEndTurns or ZERO) + ONE
            else
                self.phaseMidTurns = (self.phaseMidTurns or ZERO) + ONE
            end
            self._phaseTempoCountKey = countKey
        end

        local earlyTurnMax = math.max(ONE, valueOr(phaseConfig.EARLY_TURN_MAX, TEN))
        if tempo.contactTriggered and turnNumber <= earlyTurnMax and self._phaseTempoContactKey ~= countKey then
            self.midgameContactTriggerCount = (self.midgameContactTriggerCount or ZERO) + ONE
            self._phaseTempoContactKey = countKey
        end

        if tempo.phase == "end" then
            local choice = self:chooseEndgameWinPathByEta(state)
            tempo.endgamePath = choice.path
            tempo.endgameHubEta = choice.hubEta
            tempo.endgameWipeEta = choice.wipeEta
            tempo.endgameHorizon = choice.horizon
            if self._phaseTempoEndChoiceKey ~= countKey then
                if choice.path == "wipe" then
                    self.endgameEtaWipeChoiceCount = (self.endgameEtaWipeChoiceCount or ZERO) + ONE
                else
                    self.endgameEtaHubChoiceCount = (self.endgameEtaHubChoiceCount or ZERO) + ONE
                end
                self._phaseTempoEndChoiceKey = countKey
            end
        end

        self._phaseTempoContext = tempo
        return tempo
    end

    function aiClass:classifyStrategicThreat(threatData)
        if not threatData then
            return "none"
        end
        if threatData.isUnderAttack then
            return "immediate"
        end
        if threatData.isUnderProjectedThreat then
            return "projected"
        end
        return "none"
    end

    function aiClass:parseUnitKey(unitKey)
        if type(unitKey) ~= "string" then
            return nil
        end

        local name, row, col = unitKey:match("^([^:]+):(%-?%d+),(%-?%d+)$")
        if name and row and col then
            return {
                name = name,
                row = tonumber(row),
                col = tonumber(col)
            }
        end

        local bareRow, bareCol = unitKey:match("^(%-?%d+),(%-?%d+)$")
        if bareRow and bareCol then
            return {
                row = tonumber(bareRow),
                col = tonumber(bareCol)
            }
        end

        return nil
    end

    function aiClass:getUnitByKeyFromState(state, unitKey)
        local parsed = self:parseUnitKey(unitKey)
        if not parsed or not parsed.row or not parsed.col then
            return nil
        end
        local unit = self:getUnitAtPosition(state, parsed.row, parsed.col)
        if not unit then
            return nil
        end
        if parsed.name and unit.name ~= parsed.name then
            return nil
        end
        return unit
    end

    function aiClass:getStrategicRoleForUnit(unitOrName)
        if not unitOrName then
            return nil
        end

        if self:unitHasTag(unitOrName, "artillery") then
            return "primary"
        end
        if self:unitHasTag(unitOrName, "corvette") then
            return "secondary"
        end
        if self:unitHasTag(unitOrName, "tank") then
            return "anchor"
        end
        if self:unitHasTag(unitOrName, "melee") then
            return "screen"
        end
        if self:unitHasTag(unitOrName, "healer") then
            return "support"
        end

        return "screen"
    end

    function aiClass:getStrategicRoleWeight(role, strategyConfig)
        local weights = ((strategyConfig or {}).SIEGE or {}).ROLE_WEIGHTS or {}
        if role == "primary" then
            return valueOr(weights.PRIMARY, 220)
        end
        if role == "secondary" then
            return valueOr(weights.SECONDARY, 150)
        end
        if role == "screen" then
            return valueOr(weights.SCREEN, 110)
        end
        if role == "anchor" then
            return valueOr(weights.ANCHOR, 90)
        end
        return ZERO
    end

    function aiClass:buildStrategicRoleAssignments(state, previousAssignments, objectiveCells, aiPlayer)
        local refreshed = {}
        local missing = {}
        local taken = {}

        local function findReplacementByName(name, role)
            local objective = objectiveCells and objectiveCells[role]
            local candidates = {}
            for _, unit in ipairs(state.units or {}) do
                if unit.player == aiPlayer and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                    if (not name) or unit.name == name then
                        local key = self:getUnitKey(unit)
                        if key and not taken[key] then
                            local dist = objective and (math.abs(unit.row - objective.row) + math.abs(unit.col - objective.col)) or ZERO
                            candidates[#candidates + ONE] = {
                                unit = unit,
                                key = key,
                                dist = dist
                            }
                        end
                    end
                end
            end

            self:sortScoredEntries(candidates, {
                descending = false,
                scoreFn = function(entry)
                    return entry.dist
                end
            })

            if #candidates > ZERO then
                return candidates[ONE].unit
            end

            return nil
        end

        for key, role in pairs(previousAssignments or {}) do
            local unit = self:getUnitByKeyFromState(state, key)
            if not unit then
                local parsed = self:parseUnitKey(key)
                local fallbackName = parsed and parsed.name or nil
                unit = findReplacementByName(fallbackName, role)
            end

            if unit then
                local refreshedKey = self:getUnitKey(unit)
                if refreshedKey and not taken[refreshedKey] then
                    refreshed[refreshedKey] = role
                    taken[refreshedKey] = true
                else
                    missing[#missing + ONE] = role
                end
            else
                missing[#missing + ONE] = role
            end
        end

        return refreshed, missing
    end

    function aiClass:selectStrategicUnit(units, usedKeys, preferences)
        for _, pref in ipairs(preferences or {}) do
            for _, unit in ipairs(units or {}) do
                local key = self:getUnitKey(unit)
                if key and not usedKeys[key] then
                    local matched = false
                    if pref.name and unit.name == pref.name then
                        matched = true
                    elseif pref.tag and self:unitHasTag(unit, pref.tag) then
                        matched = true
                    elseif pref.role and self:getStrategicRoleForUnit(unit) == pref.role then
                        matched = true
                    end

                    if matched then
                        usedKeys[key] = true
                        return unit
                    end
                end
            end
        end
        return nil
    end

    function aiClass:getStrategicObjectiveCell(state, unit, enemyHub, role)
        if not state or not unit or not enemyHub then
            return nil
        end

        local desiredMin = TWO
        local desiredMax = THREE

        if role == "anchor" or role == "screen" then
            desiredMin = ONE
            desiredMax = TWO
        end
        if self:unitHasTag(unit, "tank") then
            desiredMin = ONE
            desiredMax = TWO
        end
        if self:unitHasTag(unit, "melee") and not self:unitHasTag(unit, "ranged") then
            desiredMin = ONE
            desiredMax = ONE
        end
        if self:unitHasTag(unit, "artillery") or self:unitHasTag(unit, "corvette") then
            desiredMin = TWO
            desiredMax = THREE
        end

        local gridSize = self:getBoardSize(state)
        local bestCell = nil
        local bestDist = math.huge

        for row = ONE, gridSize do
            for col = ONE, gridSize do
                local distToHub = math.abs(row - enemyHub.row) + math.abs(col - enemyHub.col)
                if distToHub >= desiredMin and distToHub <= desiredMax then
                    local blocked = self.aiState.isPositionBlocked(state, row, col)
                    if unit.row == row and unit.col == col then
                        blocked = false
                    end
                    if not blocked then
                        local distToUnit = math.abs(row - unit.row) + math.abs(col - unit.col)
                        if distToUnit < bestDist then
                            bestDist = distToUnit
                            bestCell = {row = row, col = col}
                        elseif distToUnit == bestDist and bestCell then
                            local currentKey = string.format("%d,%d", row, col)
                            local bestKey = string.format("%d,%d", bestCell.row, bestCell.col)
                            if currentKey < bestKey then
                                bestCell = {row = row, col = col}
                            end
                        end
                    end
                end
            end
        end

        if bestCell then
            return bestCell
        end

        return {row = unit.row, col = unit.col}
    end

    function aiClass:buildSiegePlanCandidate(state, packageType, aiPlayer)
        if not state or not aiPlayer then
            return nil
        end

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        if not enemyHub then
            return nil
        end

        local units = {}
        for _, unit in ipairs(state.units or {}) do
            if unit.player == aiPlayer and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                units[#units + ONE] = unit
            end
        end

        self:sortScoredEntries(units, {
            scoreFn = function(unit)
                local priority = self:getTargetPriority(unit) or ZERO
                return (priority * 10000) - ((unit.row or ZERO) * 100) - (unit.col or ZERO)
            end,
            descending = true
        })

        local usedKeys = {}
        local assignments = {}
        local roleNeed = {
            primary = true,
            secondary = true,
            screen = true
        }

        if packageType == "DOUBLE_CORVETTE_ANCHOR" then
            roleNeed = {
                primary = true,
                secondary = true,
                anchor = true
            }
            assignments.primary = self:selectStrategicUnit(units, usedKeys, {
                {tag = "corvette"},
                {tag = "artillery"},
                {tag = "ranged"}
            })
            assignments.secondary = self:selectStrategicUnit(units, usedKeys, {
                {tag = "corvette"},
                {tag = "ranged"}
            })
            assignments.anchor = self:selectStrategicUnit(units, usedKeys, {
                {tag = "tank"},
                {tag = "melee"},
                {role = "anchor"}
            })
        elseif packageType == "CRUSHER_LANE_RANGED_FINISH" then
            roleNeed = {
                primary = true,
                secondary = true,
                screen = true
            }
            assignments.primary = self:selectStrategicUnit(units, usedKeys, {
                {name = "Crusher"},
                {name = "Earthstalker"},
                {tag = "melee"}
            })
            assignments.secondary = self:selectStrategicUnit(units, usedKeys, {
                {tag = "artillery"},
                {tag = "corvette"},
                {tag = "ranged"}
            })
            assignments.screen = self:selectStrategicUnit(units, usedKeys, {
                {tag = "tank"},
                {tag = "melee"},
                {role = "screen"}
            })
        else
            roleNeed = {
                primary = true,
                secondary = true,
                screen = true
            }
            assignments.primary = self:selectStrategicUnit(units, usedKeys, {
                {tag = "artillery"},
                {tag = "corvette"},
                {tag = "ranged"}
            })
            assignments.secondary = self:selectStrategicUnit(units, usedKeys, {
                {tag = "corvette"},
                {tag = "ranged"}
            })
            assignments.screen = self:selectStrategicUnit(units, usedKeys, {
                {tag = "tank"},
                {tag = "melee"},
                {role = "screen"}
            })
        end

        local roleAssignments = {}
        local objectiveCells = {}
        local missingRoles = {}

        for role in pairs(roleNeed) do
            local unit = assignments[role]
            if unit then
                local key = self:getUnitKey(unit)
                if key then
                    roleAssignments[key] = role
                    objectiveCells[role] = self:getStrategicObjectiveCell(state, unit, enemyHub, role)
                else
                    missingRoles[#missingRoles + ONE] = role
                end
            else
                missingRoles[#missingRoles + ONE] = role
            end
        end

        if next(roleAssignments) == nil then
            return nil
        end

        return {
            packageType = packageType,
            targetHub = {row = enemyHub.row, col = enemyHub.col},
            roleAssignments = roleAssignments,
            objectiveCells = objectiveCells,
            missingRoles = missingRoles
        }
    end

    function aiClass:scoreStrategicPlanCandidate(state, candidate)
        if not state or not candidate then
            return -math.huge, {}
        end

        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return -math.huge, {}
        end

        local strategyConfig = self:getStrategyScoreConfig()
        local horizon = math.max(ONE, valueOr(strategyConfig.HORIZON_TURNS, THREE))
        local frontier = math.max(ONE, valueOr(strategyConfig.MAX_FRONTIER_PER_UNIT, 16))
        local pressureWeights = ((strategyConfig.SIEGE or {}).HUB_PRESSURE_WEIGHTS or {})
        local directDamageWeight = valueOr(pressureWeights.DIRECT_DAMAGE, 90)
        local timingWeight = valueOr(pressureWeights.TIMING, 70)
        local survivabilityWeight = valueOr(pressureWeights.SURVIVABILITY, 55)
        local laneWeight = valueOr(pressureWeights.LANE_QUALITY, 35)
        local pathWeight = valueOr(pressureWeights.PATH_OPENING, 30)
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        local totalScore = ZERO
        local bestImpactTurn = nil
        local details = {
            damageScore = ZERO,
            timingScore = ZERO,
            survivabilityScore = ZERO,
            laneScore = ZERO,
            pathScore = ZERO,
            openingCounterBonus = ZERO
        }

        for unitKey, role in pairs(candidate.roleAssignments or {}) do
            local unit = self:getUnitByKeyFromState(state, unitKey)
            if unit then
                totalScore = totalScore + self:getStrategicRoleWeight(role, strategyConfig)

                if enemyHub then
                    local threatTurn = self:getUnitThreatTiming(
                        state,
                        unit,
                        enemyHub,
                        horizon,
                        {
                            requirePositiveDamage = true,
                            considerCurrentActionState = false,
                            allowMoveOnFirstTurn = true,
                            maxFrontierNodes = frontier
                        }
                    )
                    if threatTurn and threatTurn <= horizon then
                        local turnScore = math.max(ONE, (horizon + ONE) - threatTurn) * timingWeight
                        local damage = self:calculateDamage(unit, enemyHub) or ZERO
                        details.timingScore = details.timingScore + turnScore
                        details.damageScore = details.damageScore + (damage * directDamageWeight)
                        totalScore = totalScore + turnScore + (damage * directDamageWeight)

                        if (not bestImpactTurn) or threatTurn < bestImpactTurn then
                            bestImpactTurn = threatTurn
                        end
                    else
                        totalScore = totalScore - timingWeight
                    end
                end

                if self:wouldUnitDieNextTurn(state, unit) then
                    totalScore = totalScore - survivabilityWeight
                    details.survivabilityScore = details.survivabilityScore - survivabilityWeight
                else
                    totalScore = totalScore + survivabilityWeight
                    details.survivabilityScore = details.survivabilityScore + survivabilityWeight
                end

                local objective = candidate.objectiveCells and candidate.objectiveCells[role]
                if objective then
                    local dist = math.abs(unit.row - objective.row) + math.abs(unit.col - objective.col)
                    local laneScore = math.max(ZERO, (EIGHT - dist) * laneWeight)
                    details.laneScore = details.laneScore + laneScore
                    totalScore = totalScore + laneScore
                end

                local enemyHubRef = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
                if enemyHubRef then
                    local hubDist = math.abs(unit.row - enemyHubRef.row) + math.abs(unit.col - enemyHubRef.col)
                    local pathScore = math.max(ZERO, (SIX - hubDist) * pathWeight)
                    details.pathScore = details.pathScore + pathScore
                    totalScore = totalScore + pathScore
                end
            else
                totalScore = totalScore - 250
            end
        end

        local missingPenalty = (#(candidate.missingRoles or {}) * 180)
        totalScore = totalScore - missingPenalty
        details.missingPenalty = missingPenalty
        details.expectedImpactTurn = bestImpactTurn

        local tempoContext = self:getPhaseTempoContext(state)
        if tempoContext and tempoContext.phase == "early" then
            local features = self:extractOpeningOpponentFeatures(state, aiPlayer)
            local mix = features.mix or {}
            local lanePressure = features.lanePressure or {}
            local openingCounterConfig = (self:getDoctrineScoreConfig().OPENING_COUNTER or {})
            local laneWeight = valueOr(openingCounterConfig.COUNTER_WEIGHT_LANE_PRESSURE, 1.2)
            local rangedWeight = valueOr(openingCounterConfig.COUNTER_WEIGHT_RANGED, 1.0)
            local tankWeight = valueOr(openingCounterConfig.COUNTER_WEIGHT_TANK, 1.0)
            local airWeight = valueOr(openingCounterConfig.COUNTER_WEIGHT_AIR, 1.0)

            local bonus = ZERO
            if candidate.packageType == "ARTILLERY_CORVETTE_SCREEN" then
                bonus = bonus + ((mix.tank or ZERO) * 28 * tankWeight)
                bonus = bonus + (((lanePressure.left or ZERO) + (lanePressure.right or ZERO)) * 6 * laneWeight)
            elseif candidate.packageType == "DOUBLE_CORVETTE_ANCHOR" then
                bonus = bonus + ((mix.ranged or ZERO) * 24 * rangedWeight)
                bonus = bonus + ((mix.air or ZERO) * 20 * airWeight)
            elseif candidate.packageType == "CRUSHER_LANE_RANGED_FINISH" then
                bonus = bonus + ((mix.tank or ZERO) * 18 * tankWeight)
                bonus = bonus + ((mix.melee or ZERO) * 16)
            end

            details.openingCounterBonus = bonus
            totalScore = totalScore + bonus
        end

        return totalScore, details
    end

    function aiClass:buildBestStrategicPlanCandidate(state, aiPlayer)
        local strategyConfig = self:getStrategyScoreConfig()
        local siegeConfig = strategyConfig.SIEGE or {}
        local packageTypes = siegeConfig.PACKAGE_TYPES or {}
        local plannerBudgetMs = valueOr(strategyConfig.PLANNER_BUDGET_MS, 170)
        local maxCandidates = math.max(ONE, valueOr(strategyConfig.MAX_PLAN_CANDIDATES, 18))
        local startClock = getMonotonicTimeSeconds()
        local scoredCandidates = {}
        local budgetExceeded = false

        if siegeConfig.ENABLED == false then
            return nil, {budgetExceeded = false}
        end

        local candidatesEvaluated = ZERO
        for _, packageType in ipairs(packageTypes) do
            local elapsedMs = (getMonotonicTimeSeconds() - startClock) * 1000
            if elapsedMs > plannerBudgetMs or candidatesEvaluated >= maxCandidates then
                budgetExceeded = true
                break
            end

            local candidate = self:buildSiegePlanCandidate(state, packageType, aiPlayer)
            if candidate then
                local score, details = self:scoreStrategicPlanCandidate(state, candidate)
                candidate.score = score
                candidate.scoreDetails = details
                candidate.expectedImpactTurn = details and details.expectedImpactTurn or nil
                scoredCandidates[#scoredCandidates + ONE] = candidate
                candidatesEvaluated = candidatesEvaluated + ONE
            end
        end

        self:sortScoredEntries(scoredCandidates, {
            descending = true,
            scoreField = "score",
            secondaryFn = function(entry)
                return tostring(entry and entry.packageType or "")
            end,
            secondaryDescending = false
        })

        return scoredCandidates[ONE], {
            budgetExceeded = budgetExceeded,
            candidates = scoredCandidates
        }
    end

    function aiClass:computeStrategicIntent(state)
        local strategyConfig = self:getStrategyScoreConfig()
        if valueOr(strategyConfig.ENABLED, true) == false then
            return STRATEGY_INTENT.STABILIZE, {reason = "strategy_disabled"}
        end

        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return STRATEGY_INTENT.STABILIZE, {reason = "missing_state"}
        end
        local tempoContext = self:getPhaseTempoContext(state)

        local defenseConfig = strategyConfig.DEFENSE or {}
        local hardTriggerTurns = math.max(ONE, valueOr(defenseConfig.HARD_TRIGGER_TURNS, TWO))
        local threatData = self:analyzeHubThreat(state)
        local projectedActionable, projectedActionableScore, _, projectedActionableReason = self:isProjectedThreatActionable(state, threatData)
        local defenseMode = self:updateDefenseModeState(state, threatData)
        local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
        local ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO
        local hubHpTrigger = valueOr((self:getCommandantThreatResponseScoreConfig() or {}).HUB_HP_TRIGGER, EIGHT)
        local projectedImmediate = false

        for _, projected in ipairs((threatData and threatData.threatsProjected) or {}) do
            if projected.threatTurn
                and projected.threatTurn <= hardTriggerTurns
                and projectedActionable then
                projectedImmediate = true
                break
            end
        end

        local lowHpUnderPressure = (ownHub and ownHubHp <= hubHpTrigger)
            and (
                projectedActionable
                or projectedImmediate
                or (threatData and threatData.isUnderAttack == true)
            )

        local hardThreat = (threatData and threatData.isUnderAttack == true)
            or projectedImmediate
            or lowHpUnderPressure
            or (defenseMode and defenseMode.active == true)

        if hardThreat then
            return STRATEGY_INTENT.DEFEND_HARD, {
                threatData = threatData,
                threatClass = self:classifyStrategicThreat(threatData),
                hardThreat = true,
                projectedActionable = projectedActionable,
                projectedActionableScore = projectedActionableScore,
                projectedActionableReason = projectedActionableReason,
                defendHardReason = defenseMode and defenseMode.reason or "none"
            }
        end

        if tempoContext and tempoContext.phase == "end" then
            return STRATEGY_INTENT.STABILIZE, {
                threatData = threatData,
                threatClass = self:classifyStrategicThreat(threatData),
                hardThreat = false,
                reason = "endgame_closeout_phase"
            }
        end

        local existing = self.strategicPlanState or {}
        local existingActive = existing.active == true
            and (existing.intent == STRATEGY_INTENT.SIEGE_SETUP or existing.intent == STRATEGY_INTENT.SIEGE_EXECUTE)

        if existingActive then
            local expectedImpact = existing.expectedImpactTurn
            if expectedImpact and expectedImpact <= ONE then
                return STRATEGY_INTENT.SIEGE_EXECUTE, {
                    threatData = threatData,
                    threatClass = self:classifyStrategicThreat(threatData),
                    hardThreat = false
                }
            end
            return STRATEGY_INTENT.SIEGE_SETUP, {
                threatData = threatData,
                threatClass = self:classifyStrategicThreat(threatData),
                hardThreat = false,
                projectedActionable = projectedActionable
            }
        end

        local bestCandidate = self:buildBestStrategicPlanCandidate(state, aiPlayer)
        if bestCandidate then
            local planScoreMin = math.max(ZERO, valueOr(strategyConfig.PLAN_SCORE_MIN, ONE))
            if (bestCandidate.score or ZERO) < planScoreMin then
                return STRATEGY_INTENT.STABILIZE, {
                    threatData = threatData,
                    threatClass = self:classifyStrategicThreat(threatData),
                    hardThreat = false,
                    bestCandidate = bestCandidate,
                    rejectedCandidateReason = "plan_score_below_min",
                    planScoreMin = planScoreMin
                }
            end
            local executeNow = bestCandidate.expectedImpactTurn and bestCandidate.expectedImpactTurn <= ONE
            return executeNow and STRATEGY_INTENT.SIEGE_EXECUTE or STRATEGY_INTENT.SIEGE_SETUP, {
                threatData = threatData,
                threatClass = self:classifyStrategicThreat(threatData),
                hardThreat = false,
                bestCandidate = bestCandidate
            }
        end

        return STRATEGY_INTENT.STABILIZE, {
            threatData = threatData,
            threatClass = self:classifyStrategicThreat(threatData),
            hardThreat = false,
            projectedActionable = projectedActionable
        }
    end

    function aiClass:updateStrategicPlanState(state)
        local strategyConfig = self:getStrategyScoreConfig()
        local prior = self.strategicPlanState or {}
        if valueOr(strategyConfig.ENABLED, true) == false then
            if prior.active == true then
                self:logDecision("PlanAbort", "Strategic planner disabled; dropping active plan", {
                    priorIntent = prior.intent,
                    priorPlanId = prior.planId
                })
            end
            self.strategicPlanState = nil
            self.defenseModeState = nil
            self.defendHardEnterReason = nil
            self.defendHardExitReason = nil
            return {
                intent = STRATEGY_INTENT.STABILIZE,
                active = false,
                planId = nil,
                planScore = ZERO,
                planTurnsLeft = ZERO
            }
        end

        local aiPlayer = self:getFactionId()
        local currentTurn = self:getStateTurn(state)
        local horizon = math.max(ONE, valueOr(strategyConfig.HORIZON_TURNS, THREE))
        local tempoContext = self:getPhaseTempoContext(state)
        local intent, intentContext = self:computeStrategicIntent(state)
        local precomputedCandidate = intentContext and intentContext.bestCandidate or nil
        local threatClass = intentContext and intentContext.threatClass or "none"

        self:logDecision("StrategyIntent", "Strategic intent evaluated", {
            intent = intent,
            priorIntent = prior.intent,
            priorPlanId = prior.planId,
            threatClass = threatClass,
            tempoPhase = tempoContext and tempoContext.phase or "mid",
            defendHardReason = intentContext and intentContext.defendHardReason or nil,
            projectedActionable = intentContext and intentContext.projectedActionable or false,
            projectedActionableScore = intentContext and intentContext.projectedActionableScore or ZERO
        })

        local newState = deepCopyValue(prior)
        newState.intent = intent
        newState.lastThreatClass = threatClass
        newState.active = false
        newState.planTurnsLeft = ZERO
        newState.planScore = ZERO
        newState.hardThreatActive = intent == STRATEGY_INTENT.DEFEND_HARD

        if intent == STRATEGY_INTENT.DEFEND_HARD then
            if prior.intent ~= STRATEGY_INTENT.DEFEND_HARD or prior.planId ~= string.format("defense:%d:%d", currentTurn, aiPlayer or ZERO) then
                self:logDecision("DefenseBundle", "Threat-first defense mode activated", {
                    priorIntent = prior.intent,
                    priorPlanId = prior.planId,
                    threatClass = threatClass
                })
            end
            newState.active = true
            newState.planId = string.format("defense:%d:%d", currentTurn, aiPlayer or ZERO)
            newState.targetHub = nil
            newState.expectedImpactTurn = ONE
            newState.expiresTurn = currentTurn + ONE
            newState.planTurnsLeft = ONE
            newState.roleAssignments = {}
            newState.objectiveCells = {}
            newState.missingRoles = {}
            newState.confidenceScore = (intentContext and intentContext.threatData and intentContext.threatData.threatLevel) or ZERO
            newState.failStreak = ZERO
            self.strategicPlanState = newState
            return newState
        end

        local shouldReplan = false
        local replanReason = nil
        local activeSiegePlan = prior.active == true
            and (prior.intent == STRATEGY_INTENT.SIEGE_SETUP or prior.intent == STRATEGY_INTENT.SIEGE_EXECUTE)
            and prior.roleAssignments and next(prior.roleAssignments) ~= nil
        if not activeSiegePlan then
            shouldReplan = true
            replanReason = "no_active_siege_plan"
        end
        if prior.lastThreatClass and prior.lastThreatClass ~= threatClass then
            shouldReplan = true
            replanReason = "threat_class_changed"
        end
        if prior.lastBudgetExceeded == true then
            shouldReplan = true
            replanReason = "planner_budget_exceeded_previous_turn"
        end

        local refreshedAssignments = {}
        local missingAssignments = {}
        if activeSiegePlan and not shouldReplan then
            refreshedAssignments, missingAssignments = self:buildStrategicRoleAssignments(
                state,
                prior.roleAssignments,
                prior.objectiveCells,
                aiPlayer
            )
            if next(refreshedAssignments) == nil or #missingAssignments > ZERO then
                shouldReplan = true
                replanReason = "missing_role_assignments"
            end
        end

        if activeSiegePlan and not shouldReplan then
            local currentDistanceScore = ZERO
            for unitKey, role in pairs(refreshedAssignments) do
                local unit = self:getUnitByKeyFromState(state, unitKey)
                local objective = prior.objectiveCells and prior.objectiveCells[role]
                if unit and objective then
                    currentDistanceScore = currentDistanceScore + math.abs(unit.row - objective.row) + math.abs(unit.col - objective.col)
                end
            end
            local previousDistanceScore = prior.lastDistanceScore
            if previousDistanceScore and currentDistanceScore >= previousDistanceScore then
                newState.failStreak = (prior.failStreak or ZERO) + ONE
            else
                newState.failStreak = ZERO
            end
            newState.lastDistanceScore = currentDistanceScore
            if (newState.failStreak or ZERO) >= TWO then
                shouldReplan = true
                replanReason = "progress_missed_two_turns"
            end
        end

        local bestCandidate = nil
        local planMeta = {budgetExceeded = false}
        if shouldReplan then
            if precomputedCandidate and not activeSiegePlan then
                bestCandidate = precomputedCandidate
            else
                bestCandidate, planMeta = self:buildBestStrategicPlanCandidate(state, aiPlayer)
            end
        end

        if not shouldReplan and activeSiegePlan then
            newState.active = true
            newState.planId = prior.planId
            newState.roleAssignments = refreshedAssignments
            newState.objectiveCells = deepCopyValue(prior.objectiveCells or {})
            newState.missingRoles = deepCopyValue(prior.missingRoles or {})
            newState.targetHub = deepCopyValue(prior.targetHub)
            newState.createdTurn = prior.createdTurn or currentTurn
            newState.expiresTurn = prior.expiresTurn or (currentTurn + horizon)
            newState.planTurnsLeft = math.max(ZERO, (newState.expiresTurn or currentTurn) - currentTurn)
            newState.expectedImpactTurn = prior.expectedImpactTurn
            newState.planScore = prior.planScore or ZERO
            newState.confidenceScore = prior.confidenceScore or ZERO
            newState.lastBudgetExceeded = false
            self.strategicPlanState = newState
            return newState
        end

        if bestCandidate then
            local score = bestCandidate.score or ZERO
            local openingCounterBonus = bestCandidate.scoreDetails and (bestCandidate.scoreDetails.openingCounterBonus or ZERO) or ZERO
            newState.active = true
            newState.intent = intent == STRATEGY_INTENT.SIEGE_EXECUTE and STRATEGY_INTENT.SIEGE_EXECUTE or STRATEGY_INTENT.SIEGE_SETUP
            newState.planId = string.format("siege:%s:%d:%d", bestCandidate.packageType or "pkg", aiPlayer or ZERO, currentTurn)
            newState.packageType = bestCandidate.packageType
            newState.targetHub = deepCopyValue(bestCandidate.targetHub)
            newState.roleAssignments = deepCopyValue(bestCandidate.roleAssignments or {})
            newState.objectiveCells = deepCopyValue(bestCandidate.objectiveCells or {})
            newState.missingRoles = deepCopyValue(bestCandidate.missingRoles or {})
            newState.createdTurn = currentTurn
            newState.expiresTurn = currentTurn + horizon
            newState.planTurnsLeft = horizon
            newState.expectedImpactTurn = bestCandidate.expectedImpactTurn
            newState.planScore = score
            newState.confidenceScore = score
            newState.failStreak = ZERO
            newState.lastDistanceScore = nil
            newState.lastBudgetExceeded = planMeta and planMeta.budgetExceeded == true
            if openingCounterBonus ~= ZERO then
                self.openingCounterScoreAppliedCount = (self.openingCounterScoreAppliedCount or ZERO) + ONE
            end
            self.strategicPlanState = newState
            self:logDecision("PlanSelected", "Strategic plan selected", {
                intent = newState.intent,
                planId = newState.planId,
                packageType = newState.packageType,
                score = newState.planScore,
                expectedImpactTurn = newState.expectedImpactTurn,
                openingCounterBonus = openingCounterBonus
            })
            return newState
        end

        if prior.active == true then
            self:logDecision("PlanAbort", "Strategic plan aborted", {
                priorIntent = prior.intent,
                priorPlanId = prior.planId,
                reason = replanReason or "no_valid_candidate",
                budgetExceeded = planMeta and planMeta.budgetExceeded == true
            })
        end

        newState.active = false
        newState.intent = STRATEGY_INTENT.STABILIZE
        newState.planId = nil
        newState.planScore = ZERO
        newState.planTurnsLeft = ZERO
        newState.roleAssignments = {}
        newState.objectiveCells = {}
        newState.missingRoles = {}
        newState.targetHub = nil
        newState.lastBudgetExceeded = planMeta and planMeta.budgetExceeded == true
        self.strategicPlanState = newState
        return newState
    end

    function aiClass:getDeploymentProjectedImpactTurn(state, deployment, horizonTurns)
        if not state or not deployment then
            return nil
        end

        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end

        local horizon = math.max(ONE, horizonTurns or THREE)
        local simState = self:applySupplyDeployment(state, deployment)
        local deployed = simState and self:getUnitAtPosition(simState, deployment.target.row, deployment.target.col)
        if not deployed then
            return nil
        end

        if self:unitHasTag(deployed, "healer") and not self:shouldHealerBeOffensive(simState) then
            return nil
        end

        local impactTurn = nil
        local function considerTarget(target)
            local threatTurn = self:getUnitThreatTiming(
                simState,
                deployed,
                target,
                horizon,
                {
                    requirePositiveDamage = true,
                    considerCurrentActionState = true,
                    allowMoveOnFirstTurn = true,
                    maxFrontierNodes = 20
                }
            )
            if threatTurn and ((not impactTurn) or threatTurn < impactTurn) then
                impactTurn = threatTurn
            end
        end

        local enemyHub = simState.commandHubs and simState.commandHubs[self:getOpponentPlayer(aiPlayer)]
        if enemyHub then
            considerTarget({
                name = "Commandant",
                player = self:getOpponentPlayer(aiPlayer),
                row = enemyHub.row,
                col = enemyHub.col,
                currentHp = enemyHub.currentHp,
                startingHp = enemyHub.startingHp
            })
        end

        for _, enemy in ipairs(simState.units or {}) do
            if self:isAttackableEnemyUnit(enemy, aiPlayer) then
                considerTarget(enemy)
            end
        end

        return impactTurn
    end

    function aiClass:getPlannedDeploymentCandidate(state, usedUnits)
        local candidate = self:findEnhancedSupplyDeployment(state, usedUnits)
        if not candidate then
            return nil
        end

        local tempoContext = self:getPhaseTempoContext(state)
        local closeoutConfig = (self:getDoctrineScoreConfig().ENDGAME_CLOSEOUT or {})
        if tempoContext and tempoContext.phase == "end"
            and tostring(valueOr(closeoutConfig.DEPLOY_STYLE, "finish_first")) == "finish_first"
            and (candidate.score or ZERO) <= ZERO then
            self:logDecision("PlanDeploy", "Skipped endgame deploy: no ETA improvement", {
                score = candidate.score or ZERO,
                endgamePath = tempoContext.endgamePath
            })
            self.endgameDeploySkippedCount = (self.endgameDeploySkippedCount or ZERO) + ONE
            return nil
        end

        local strategyConfig = self:getStrategyScoreConfig()
        if valueOr(strategyConfig.ENABLED, true) == false then
            return candidate
        end

        local planState = self.strategicPlanState or {}
        local deployConfig = strategyConfig.DEPLOY_SYNC or {}
        local horizon = math.max(ONE, valueOr(strategyConfig.HORIZON_TURNS, THREE))
        local strictImpactGate = valueOr(deployConfig.STRICT_IMPACT_GATE, true)
        local requirePlanRoleFill = valueOr(deployConfig.REQUIRE_PLAN_ROLE_FILL, true)
        local rejectNoImpact = valueOr(deployConfig.REJECT_NO_IMPACT, true)
        local rejectIfThreatBeforeImpact = valueOr(deployConfig.REJECT_IF_THREAT_BEFORE_IMPACT, true)
        local threatTieCountsAsTooLate = valueOr(deployConfig.THREAT_TIE_COUNTS_AS_TOO_LATE, true)
        local maxThreatLeadTurns = math.max(ZERO, valueOr(deployConfig.MAX_THREAT_LEAD_TURNS, ZERO))
        local maxImpactTurn = math.max(ONE, valueOr(deployConfig.MAX_IMPACT_TURN, horizon))
        local earlyThreatTurnMax = math.max(ONE, valueOr(deployConfig.EARLY_THREAT_TURN_MAX, TWO))
        local requireImmediateImpactWhenEarlyThreat = valueOr(
            deployConfig.REQUIRE_IMMEDIATE_IMPACT_WHEN_EARLY_THREAT,
            true
        )
        local strictThreatTimingRequiresHubThreat = valueOr(
            deployConfig.STRICT_THREAT_TIMING_REQUIRES_HUB_THREAT,
            true
        )
        local allowHealerOutsideDefense = valueOr(deployConfig.ALLOW_HEALER_DEPLOY_OUTSIDE_DEFENSE, false)
        local isDefenseIntent = planState.intent == STRATEGY_INTENT.DEFEND_HARD
        local isSiegeIntent = planState.intent == STRATEGY_INTENT.SIEGE_SETUP or planState.intent == STRATEGY_INTENT.SIEGE_EXECUTE
        local hubThreatData = self:analyzeHubThreat(state)
        local hubThreatActive = hubThreatData and (
            hubThreatData.isUnderAttack
            or (hubThreatData.projectedThreatActionable == true)
        )
        local strictThreatTiming = isDefenseIntent
            or (not strictThreatTimingRequiresHubThreat)
            or hubThreatActive

        if isDefenseIntent then
            local canCounter = candidate.canCounterThreat == true
            local canBlock = (candidate.strategicBonus or ZERO) > ZERO
            local defenseNeedsCounter = valueOr((strategyConfig.DEFENSE or {}).REQUIRE_NEUTRALIZE_OR_BLOCK, true)
            local deploySyncConfig = strategyConfig.DEPLOY_SYNC or {}
            local skipBadDeploy = valueOr(deploySyncConfig.SKIP_BAD_DEPLOY_WHEN_DEFENDING, true)
            local minNetImpact = valueOr(deploySyncConfig.DEFENSE_DEPLOY_MIN_NET_IMPACT, 60)
            local netImpact = (candidate.strategicBonus or ZERO) + (candidate.responseBonus or ZERO)
            if defenseNeedsCounter and not canCounter and not canBlock then
                if skipBadDeploy then
                    self.badDeploySkipped = (self.badDeploySkipped or ZERO) + ONE
                end
                return nil
            end
            if skipBadDeploy and netImpact < minNetImpact and not canCounter and not canBlock then
                self.badDeploySkipped = (self.badDeploySkipped or ZERO) + ONE
                return nil
            end
            return candidate
        end

        if self:unitHasTag(candidate.unitName, "healer") and not allowHealerOutsideDefense then
            return nil
        end

        if isSiegeIntent and requirePlanRoleFill then
            local missingRoles = {}
            for _, role in ipairs(planState.missingRoles or {}) do
                missingRoles[role] = true
            end
            if next(missingRoles) ~= nil then
                local deploymentRole = self:getStrategicRoleForUnit(candidate.unitName)
                if not missingRoles[deploymentRole] then
                    return nil
                end
            end
        end

        local impactTurn = candidate.projectedImpactTurn
        if strictImpactGate or impactTurn == nil then
            local recomputedImpactTurn = self:getDeploymentProjectedImpactTurn(state, candidate, horizon)
            if recomputedImpactTurn and ((not impactTurn) or recomputedImpactTurn < impactTurn) then
                impactTurn = recomputedImpactTurn
            end
        end

        if strictImpactGate then
            if rejectNoImpact and (not impactTurn or impactTurn > horizon) then
                return nil
            end
            if impactTurn and impactTurn > maxImpactTurn then
                return nil
            end
        end

        candidate.projectedImpactTurn = impactTurn
        local threatTurn = candidate.projectedThreatTurn

        if threatTurn and strictThreatTiming then
            if rejectNoImpact and not impactTurn then
                return nil
            end

            local threatBeforeImpact = false
            if impactTurn then
                if threatTieCountsAsTooLate then
                    threatBeforeImpact = (threatTurn + maxThreatLeadTurns) <= impactTurn
                else
                    threatBeforeImpact = (threatTurn + maxThreatLeadTurns) < impactTurn
                end
            end

            if rejectIfThreatBeforeImpact and impactTurn and threatBeforeImpact then
                return nil
            end

            if requireImmediateImpactWhenEarlyThreat and threatTurn <= earlyThreatTurnMax and ((not impactTurn) or impactTurn > ONE) then
                return nil
            end
        end

        return candidate
    end

    function aiClass:buildDefenseActionBundle(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local strategyConfig = self:getStrategyScoreConfig()
        local defenseConfig = strategyConfig.DEFENSE or {}
        local hardTriggerTurns = math.max(ONE, valueOr(defenseConfig.HARD_TRIGGER_TURNS, TWO))
        local threatData, threatLookup = self:getCommandantThreatLookup(state, aiPlayer)
        local projectedActionable = threatData and (
            threatData.projectedThreatActionable == true
            or (threatData.projectedThreatActionable == nil and threatData.isUnderProjectedThreat == true)
        )
        local hardThreat = threatData and threatData.isUnderAttack == true
        local defenseModeActive = self.defenseModeState and self.defenseModeState.active == true
        if not hardThreat then
            for _, projected in ipairs(threatData and threatData.threatsProjected or {}) do
                if projected.threatTurn and projected.threatTurn <= hardTriggerTurns then
                    if projectedActionable then
                        hardThreat = true
                        break
                    end
                end
            end
        end
        if defenseModeActive then
            hardThreat = true
        end
        if not hardThreat then
            return {}
        end

        local threatConfig = self:getCommandantThreatResponseScoreConfig()
        local defaultThreatConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_THREAT_RESPONSE or {}
        local criticalHubHp = valueOr(
            threatConfig.CRITICAL_HUB_HP,
            valueOr(defaultThreatConfig.CRITICAL_HUB_HP, SIX)
        )
        local criticalThreatLevel = valueOr(
            threatConfig.CRITICAL_THREAT_LEVEL,
            valueOr(defaultThreatConfig.CRITICAL_THREAT_LEVEL, 180)
        )
        local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
        local ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO
        local criticalDefense = (threatData and (threatData.threatLevel or ZERO) >= criticalThreatLevel)
            or (ownHub and ownHubHp <= criticalHubHp)
        local requireSafeDirectAttack = valueOr(
            threatConfig.REQUIRE_SAFE_ATTACK,
            valueOr(defaultThreatConfig.REQUIRE_SAFE_ATTACK, true)
        )
        if criticalDefense and valueOr(
            threatConfig.CRITICAL_ALLOW_UNSAFE_ATTACK,
            valueOr(defaultThreatConfig.CRITICAL_ALLOW_UNSAFE_ATTACK, false)
        ) then
            requireSafeDirectAttack = false
        end

        local bundle = {}

        local directEntries = self:collectAttackTargetEntries(state, usedUnits, {
            mode = "direct",
            aiPlayer = aiPlayer,
            allowHealerAttacks = self:shouldHealerBeOffensive(state, {
                allowEmergencyDefense = true,
                commandantThreatData = threatData
            }),
            includeFriendlyFireCheck = true,
            requirePositiveDamage = true
        })
        local directCandidates = {}
        local bestDirectByTarget = {}
        for _, entry in ipairs(directEntries) do
            local key = hashPosition(entry.target)
            local threatInfo = key and threatLookup[key]
            if threatInfo then
                local attackAllowed = true
                if requireSafeDirectAttack then
                    attackAllowed = self:isAttackSafe(state, entry.unit, entry.target)
                end

                if attackAllowed then
                    local score = (entry.damage or ZERO) * 120
                        + (threatInfo.threatLevel or ZERO) * 4
                        + ((entry.damage or ZERO) >= (entry.targetHp or MIN_HP) and 260 or ZERO)
                    local candidate = {
                        kind = "single",
                        priority = 900 + score,
                        unit = entry.unit,
                        action = entry.action,
                        addTag = "STRATEGIC_DEFENSE_DIRECT_ATTACK",
                        targetKey = key,
                        damage = entry.damage or ZERO,
                        targetHp = entry.targetHp or MIN_HP
                    }
                    directCandidates[#directCandidates + ONE] = candidate

                    local existing = bestDirectByTarget[key]
                    local lethal = candidate.damage >= candidate.targetHp
                    if (not existing)
                        or (lethal and not existing.lethal)
                        or (candidate.damage > (existing.damage or ZERO))
                        or (candidate.priority > (existing.priority or ZERO)) then
                        bestDirectByTarget[key] = {
                            damage = candidate.damage,
                            targetHp = candidate.targetHp,
                            lethal = lethal,
                            priority = candidate.priority
                        }
                    end
                end
            end
        end

        self:sortScoredEntries(directCandidates, {
            scoreField = "priority",
            descending = true
        })

        local moveAttack = self:findCommandantThreatMoveAttack(state, usedUnits, {
            criticalDefense = criticalDefense
        })
        if moveAttack then
            local pairPriority = 1000 + (moveAttack.value or ZERO)
            local moveTargetKey = hashPosition(moveAttack.target)
            local directOnSameTarget = moveTargetKey and bestDirectByTarget[moveTargetKey] or nil
            if directOnSameTarget then
                local moveDamage = moveAttack.damage or ZERO
                local moveTargetHp = moveAttack.targetHp or MIN_HP
                local moveLethal = moveDamage >= moveTargetHp
                local directDominates = directOnSameTarget.lethal
                    or (directOnSameTarget.damage or ZERO) >= moveDamage
                if directDominates and ((not moveLethal) or directOnSameTarget.lethal) then
                    pairPriority = math.min(pairPriority, (directOnSameTarget.priority or pairPriority) - 25)
                end
            elseif #directCandidates > ZERO then
                -- Prefer one-action direct threat neutralization when comparable.
                pairPriority = pairPriority - 80
            end

            bundle[#bundle + ONE] = {
                kind = "pair",
                priority = pairPriority,
                unit = moveAttack.unit,
                moveAction = moveAttack.moveAction,
                attackAction = moveAttack.attackAction,
                addTagMove = "STRATEGIC_DEFENSE_MOVE",
                addTagAttack = "STRATEGIC_DEFENSE_ATTACK"
            }
        end

        for _, candidate in ipairs(directCandidates) do
            bundle[#bundle + ONE] = candidate
        end

        local counterMove = self:findThreatCounterAttackMove(state, usedUnits)
        if counterMove then
            bundle[#bundle + ONE] = {
                kind = "single",
                priority = 520 + (counterMove.value or ZERO),
                unit = counterMove.unit,
                action = counterMove.action,
                addTag = "STRATEGIC_DEFENSE_COUNTER_MOVE"
            }
        end

        local guardMove = self:findCommandantGuardMove(state, usedUnits)
        if guardMove then
            bundle[#bundle + ONE] = {
                kind = "single",
                priority = 400 + (guardMove.score or ZERO),
                unit = guardMove.unit,
                action = guardMove.action,
                addTag = "STRATEGIC_DEFENSE_GUARD"
            }
        end

        local unblockMove = self:findCommandantDefenseUnblockMove(state, usedUnits)
        if unblockMove then
            bundle[#bundle + ONE] = {
                kind = "single",
                priority = 390 + (unblockMove.score or ZERO),
                unit = unblockMove.unit,
                action = unblockMove.action,
                addTag = "STRATEGIC_DEFENSE_UNBLOCK"
            }
        end

        local deploy = self:getPlannedDeploymentCandidate(state, usedUnits)
        if deploy then
            bundle[#bundle + ONE] = {
                kind = "single",
                priority = 360 + (deploy.score or ZERO),
                action = deploy,
                addTag = "STRATEGIC_DEFENSE_DEPLOY"
            }
        end

        self:sortScoredEntries(bundle, {
            scoreField = "priority",
            descending = true
        })
        return bundle
    end

    function aiClass:buildSiegeActionBundle(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local planState = self.strategicPlanState or {}
        if not (planState.active and (planState.intent == STRATEGY_INTENT.SIEGE_SETUP or planState.intent == STRATEGY_INTENT.SIEGE_EXECUTE)) then
            return {}
        end

        local strategyConfig = self:getStrategyScoreConfig()
        local tempoContext = self:getPhaseTempoContext(state)
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        if not enemyHub then
            return {}
        end
        local pressureWeights = ((strategyConfig.SIEGE or {}).HUB_PRESSURE_WEIGHTS or {})
        local convergeNowBonus = valueOr(
            pressureWeights.CONVERGENCE_TURN1_BONUS,
            valueOr(pressureWeights.TIMING, 70) * TWO
        )
        local convergeSoonBonus = valueOr(
            pressureWeights.CONVERGENCE_TURN2_BONUS,
            valueOr(pressureWeights.TIMING, 70)
        )
        local convergeMissPenalty = valueOr(
            pressureWeights.CONVERGENCE_MISS_PENALTY,
            math.floor(valueOr(pressureWeights.TIMING, 70) * 0.6)
        )
        local requireConvergenceForPrimarySecondary = valueOr(
            pressureWeights.CONVERGENCE_REQUIRE_PRIMARY_SECONDARY,
            true
        )
        local rangedAdjPenaltyMult = math.max(
            ONE,
            valueOr(pressureWeights.RANGED_ADJACENCY_PENALTY_MULT, ONE)
        )
        local rangedAdjHardAvoidPrimarySecondary = valueOr(
            pressureWeights.RANGED_ADJACENCY_HARD_AVOID_PRIMARY_SECONDARY,
            true
        )
        local rangedAdjAllowIfConvergeTurn1 = valueOr(
            pressureWeights.RANGED_ADJACENCY_ALLOW_IF_CONVERGENCE_TURN1,
            true
        )
        local convergeLookaheadTurns = TWO
        local convergeFrontierMax = math.max(ONE, valueOr(strategyConfig.MAX_FRONTIER_PER_UNIT, 16))
        local hubTargetRef = {
            name = "Commandant",
            player = self:getOpponentPlayer(aiPlayer),
            row = enemyHub.row,
            col = enemyHub.col,
            currentHp = enemyHub.currentHp,
            startingHp = enemyHub.startingHp
        }

        local entries = {}
        local roleEntries = {}
        for unitKey, role in pairs(planState.roleAssignments or {}) do
            roleEntries[#roleEntries + ONE] = {unitKey = unitKey, role = role}
        end
        table.sort(roleEntries, function(a, b)
            local aRank = STRATEGY_ROLE_ORDER[a.role] or 99
            local bRank = STRATEGY_ROLE_ORDER[b.role] or 99
            if aRank == bRank then
                return tostring(a.unitKey) < tostring(b.unitKey)
            end
            return aRank < bRank
        end)

        local function addEntry(entry)
            if not entry then
                return
            end
            entries[#entries + ONE] = entry
        end

        for _, assignment in ipairs(roleEntries) do
            local unit = self:getUnitByKeyFromState(state, assignment.unitKey)
            if unit and self:isUnitEligibleForAction(unit, aiPlayer, usedUnits, {
                requireNotActed = true,
                requireNotMoved = false,
                disallowCommandant = true,
                disallowRock = true,
                allowHealerAttacks = self:shouldHealerBeOffensive(state),
                requireAlive = true
            }) then
                local roleWeight = self:getStrategicRoleWeight(assignment.role, strategyConfig)
                local directAttackEntries = self:collectAttackTargetEntries(state, usedUnits, {
                    mode = "direct",
                    aiPlayer = aiPlayer,
                    includeFriendlyFireCheck = true,
                    requirePositiveDamage = true,
                    allowHealerAttacks = self:shouldHealerBeOffensive(state),
                    unitFilter = function(candidate)
                        return candidate == unit
                    end
                })

                for _, attackEntry in ipairs(directAttackEntries) do
                    local target = attackEntry.target
                    local score = (attackEntry.damage or ZERO) * 60 + roleWeight
                    if target and self:isHubUnit(target) then
                        score = score + 600
                    elseif target then
                        score = score + (self:getTargetPriority(target) or ZERO)
                    end
                    addEntry({
                        kind = "single",
                        priority = 1000 + score,
                        unit = unit,
                        action = attackEntry.action,
                        addTag = "STRATEGIC_PLAN_ATTACK",
                        role = assignment.role
                    })
                end

                if not unit.hasMoved then
                    local objective = planState.objectiveCells and planState.objectiveCells[assignment.role]
                    if objective then
                        local moveCells = self:getValidMoveCells(state, unit.row, unit.col) or {}
                        local bestMove = nil
                        local bestScore = -math.huge
                        local bestConvergingMove = nil
                        local bestConvergingScore = -math.huge
                        local roleNeedsConvergence = assignment.role == "primary" or assignment.role == "secondary"
                        for _, moveCell in ipairs(moveCells) do
                            local beforeDist = math.abs(unit.row - objective.row) + math.abs(unit.col - objective.col)
                            local afterDist = math.abs(moveCell.row - objective.row) + math.abs(moveCell.col - objective.col)
                            local gain = beforeDist - afterDist
                            local suicidal = self:isSuicidalMovement(state, moveCell, unit)
                            if not suicidal then
                                if self:unitHasTag(unit, "healer") then
                                    local healerMoveAllowed, healerRejectReason = self:isHealerMoveDoctrineAllowed(
                                        state,
                                        unit,
                                        moveCell,
                                        aiPlayer,
                                        {allowEmergencyDefense = true}
                                    )
                                    if not healerMoveAllowed then
                                        if healerRejectReason == "frontline" or healerRejectReason == "orbit" then
                                            self.healerFrontlineViolationRejected = (self.healerFrontlineViolationRejected or ZERO) + ONE
                                        end
                                        goto continue_siege_move
                                    end
                                end
                                if self:isRangedStandoffViolation(state, unit, moveCell, aiPlayer) then
                                    goto continue_siege_move
                                end
                                local convergenceScore = ZERO
                                local threatTurn = nil
                                if roleNeedsConvergence then
                                    local projectedUnit = self:buildProjectedThreatUnit(unit, moveCell.row, moveCell.col) or unit
                                    threatTurn = self:getUnitThreatTiming(
                                        state,
                                        projectedUnit,
                                        hubTargetRef,
                                        convergeLookaheadTurns,
                                        {
                                            requirePositiveDamage = true,
                                            considerCurrentActionState = true,
                                            allowMoveOnFirstTurn = false,
                                            maxFrontierNodes = convergeFrontierMax
                                        }
                                    )
                                    if threatTurn == ONE then
                                        convergenceScore = convergeNowBonus
                                    elseif threatTurn == TWO then
                                        convergenceScore = convergeSoonBonus
                                    else
                                        convergenceScore = -convergeMissPenalty
                                    end
                                end
                                local rangedAdjPenalty = self:getRangedAdjacencyPenalty(
                                    state,
                                    unit,
                                    moveCell,
                                    aiPlayer
                                ) * rangedAdjPenaltyMult
                                local isImmediateConvergence = roleNeedsConvergence and threatTurn == ONE
                                local skipForRangedAdjacency = roleNeedsConvergence
                                    and rangedAdjHardAvoidPrimarySecondary
                                    and rangedAdjPenalty > ZERO
                                    and not (rangedAdjAllowIfConvergeTurn1 and isImmediateConvergence)
                                if skipForRangedAdjacency then
                                    goto continue_siege_move
                                end
                                local positional = self:getPositionalValue(state, {
                                    row = moveCell.row,
                                    col = moveCell.col,
                                    name = unit.name,
                                    player = unit.player,
                                    currentHp = unit.currentHp,
                                    startingHp = unit.startingHp
                                })
                                local supportSimState, supportMovedUnit = self:simulateStateAfterMove(state, unit, moveCell)
                                local supportCoverage = self:calculateSupportCoverageBonus(
                                    supportSimState or state,
                                    supportMovedUnit or unit,
                                    moveCell,
                                    aiPlayer
                                )
                                local influenceFlowBonus = self:calculateMobileInfluenceFlowBonus(
                                    state,
                                    unit,
                                    moveCell,
                                    aiPlayer,
                                    tempoContext
                                )
                                local objectivePathBonus = self:calculateMultiTurnObjectivePathBonus(
                                    state,
                                    unit,
                                    moveCell,
                                    aiPlayer,
                                    tempoContext
                                )
                                local rangedDuelEvasionBonus = self:calculateRangedDuelEvasionBonus(
                                    state,
                                    unit,
                                    moveCell,
                                    aiPlayer,
                                    {
                                        simState = supportSimState,
                                        movedUnit = supportMovedUnit
                                    }
                                )
                                local score = (gain * 180)
                                    + roleWeight
                                    + (positional * 0.1)
                                    + convergenceScore
                                    + supportCoverage
                                    + influenceFlowBonus
                                    + objectivePathBonus
                                    + rangedDuelEvasionBonus
                                    - rangedAdjPenalty
                                if score > bestScore then
                                    bestScore = score
                                    bestMove = moveCell
                                end
                                if roleNeedsConvergence and threatTurn and threatTurn <= TWO and score > bestConvergingScore then
                                    bestConvergingScore = score
                                    bestConvergingMove = moveCell
                                end
                            end
                            ::continue_siege_move::
                        end

                        local selectedMove = bestMove
                        local selectedScore = bestScore
                        if roleNeedsConvergence and requireConvergenceForPrimarySecondary and bestConvergingMove then
                            selectedMove = bestConvergingMove
                            selectedScore = bestConvergingScore
                        end

                        if selectedMove then
                            addEntry({
                                kind = "single",
                                priority = 700 + selectedScore,
                                unit = unit,
                                action = {
                                    type = "move",
                                    unit = {row = unit.row, col = unit.col},
                                    target = {row = selectedMove.row, col = selectedMove.col}
                                },
                                addTag = "STRATEGIC_PLAN_MOVE",
                                role = assignment.role
                            })
                        end
                    end
                end
            end
        end

        local deployCandidate = self:getPlannedDeploymentCandidate(state, usedUnits)
        if deployCandidate then
            addEntry({
                kind = "single",
                priority = 650 + (deployCandidate.score or ZERO),
                action = deployCandidate,
                addTag = "STRATEGIC_PLAN_DEPLOY"
            })
        end

        self:sortScoredEntries(entries, {
            scoreField = "priority",
            descending = true
        })

        return entries
    end

    function aiClass:findCommandantThreatDirectAttack(state, usedUnits, opts)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return nil
        end

        local options = opts or {}
        local threatConfig = self:getCommandantThreatResponseScoreConfig()
        local defaultThreatConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_THREAT_RESPONSE or {}
        local minThreatLevel = valueOr(threatConfig.MIN_THREAT_LEVEL, valueOr(defaultThreatConfig.MIN_THREAT_LEVEL, ZERO))
        local allowHealerAttacks = valueOr(
            threatConfig.ALLOW_HEALER_ATTACKS,
            valueOr(defaultThreatConfig.ALLOW_HEALER_ATTACKS, true)
        )
        local requireSafeAttack = valueOr(threatConfig.REQUIRE_SAFE_ATTACK, valueOr(defaultThreatConfig.REQUIRE_SAFE_ATTACK, true))
        if options.criticalDefense and valueOr(
            threatConfig.CRITICAL_ALLOW_UNSAFE_ATTACK,
            valueOr(defaultThreatConfig.CRITICAL_ALLOW_UNSAFE_ATTACK, false)
        ) then
            requireSafeAttack = false
        end
        local baseAttackBonus = valueOr(threatConfig.BASE_ATTACK_BONUS, valueOr(defaultThreatConfig.BASE_ATTACK_BONUS, ZERO))
        local eliminationBonus = valueOr(
            threatConfig.THREAT_ELIMINATION_BONUS,
            valueOr(defaultThreatConfig.THREAT_ELIMINATION_BONUS, ZERO)
        )
        local criticalAttackBonus = valueOr(
            threatConfig.CRITICAL_ATTACK_BONUS,
            valueOr(defaultThreatConfig.CRITICAL_ATTACK_BONUS, ZERO)
        )
        local threatLevelMult = valueOr(threatConfig.THREAT_LEVEL_MULT, valueOr(defaultThreatConfig.THREAT_LEVEL_MULT, ONE))
        local adjacentBonus = valueOr(
            threatConfig.ADJACENT_HUB_TARGET_BONUS,
            valueOr(defaultThreatConfig.ADJACENT_HUB_TARGET_BONUS, ZERO)
        )
        local nearBonus = valueOr(
            threatConfig.NEAR_HUB_TARGET_BONUS,
            valueOr(defaultThreatConfig.NEAR_HUB_TARGET_BONUS, ZERO)
        )
        local rangedBonus = valueOr(
            threatConfig.RANGED_HUB_THREAT_BONUS,
            valueOr(defaultThreatConfig.RANGED_HUB_THREAT_BONUS, ZERO)
        )

        local threatData, threatLookup = self:getCommandantThreatLookup(state, aiPlayer)
        if (threatData.threatLevel or ZERO) < minThreatLevel then
            return nil
        end
        if allowHealerAttacks then
            allowHealerAttacks = self:shouldHealerBeOffensive(state, {
                allowEmergencyDefense = true,
                commandantThreatData = threatData
            })
        end

        local entries = self:collectAttackTargetEntries(state, usedUnits, {
            mode = "direct",
            aiPlayer = aiPlayer,
            allowHealerAttacks = allowHealerAttacks,
            includeFriendlyFireCheck = true,
            requirePositiveDamage = true
        })

        local candidates = {}
        for _, entry in ipairs(entries) do
            local threatInfo = threatLookup[hashPosition(entry.target)]
            if threatInfo then
                local attackAllowed = true
                if requireSafeAttack then
                    attackAllowed = self:isAttackSafe(state, entry.unit, entry.target)
                end

                if attackAllowed then
                    local context = self:getAttackOpportunityContext(state, entry.unit, entry.target, {
                        damage = entry.damage,
                        attackPos = {row = entry.unit.row, col = entry.unit.col},
                        includeRangedThreatToOwnHub = true
                    })

                    local score = self:getAttackOpportunityScore(
                        state,
                        entry.unit,
                        entry.target,
                        entry.damage,
                        entry.specialUsed,
                        context,
                        {
                            includeTargetValue = true,
                            useBaseTargetValue = true,
                            includeRangedThreatToOwnHub = true,
                            positionalUnit = entry.unit
                        }
                    )

                    score = score + baseAttackBonus + ((threatInfo.threatLevel or ZERO) * threatLevelMult)
                    if context and context.isAdjacentToOwnHub then
                        score = score + adjacentBonus
                    elseif context and context.isNearAdjacentToOwnHub then
                        score = score + nearBonus
                    end
                    if context and context.isRangedThreatToOwnHub then
                        score = score + rangedBonus
                    end
                    if entry.damage >= (entry.targetHp or MIN_HP) then
                        score = score + eliminationBonus
                    end
                    if options.criticalDefense then
                        score = score + criticalAttackBonus
                    end

                    candidates[#candidates + ONE] = {
                        unit = entry.unit,
                        target = entry.target,
                        action = entry.action,
                        value = score,
                        threatLevel = threatInfo.threatLevel or ZERO
                    }
                end
            end
        end

        self:sortScoredEntries(candidates, {
            scoreField = "value",
            secondaryField = "threatLevel",
            descending = true
        })

        return candidates[ONE]
    end

    function aiClass:findCommandantThreatMoveAttack(state, usedUnits, opts)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return nil
        end

        local options = opts or {}
        local threatConfig = self:getCommandantThreatResponseScoreConfig()
        local defaultThreatConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_THREAT_RESPONSE or {}
        local minThreatLevel = valueOr(threatConfig.MIN_THREAT_LEVEL, valueOr(defaultThreatConfig.MIN_THREAT_LEVEL, ZERO))
        local allowHealerAttacks = valueOr(
            threatConfig.ALLOW_HEALER_ATTACKS,
            valueOr(defaultThreatConfig.ALLOW_HEALER_ATTACKS, true)
        )
        local requireSafeMove = valueOr(threatConfig.REQUIRE_SAFE_MOVE, valueOr(defaultThreatConfig.REQUIRE_SAFE_MOVE, true))
        local checkVulnerableMove = valueOr(
            threatConfig.CHECK_VULNERABLE_MOVE,
            valueOr(defaultThreatConfig.CHECK_VULNERABLE_MOVE, true)
        )
        local requireSafeAttack = valueOr(threatConfig.REQUIRE_SAFE_ATTACK, valueOr(defaultThreatConfig.REQUIRE_SAFE_ATTACK, true))
        if options.criticalDefense then
            if valueOr(
                threatConfig.CRITICAL_ALLOW_UNSAFE_MOVE,
                valueOr(defaultThreatConfig.CRITICAL_ALLOW_UNSAFE_MOVE, false)
            ) then
                requireSafeMove = false
            end
            if valueOr(
                threatConfig.CRITICAL_IGNORE_VULNERABLE_MOVE,
                valueOr(defaultThreatConfig.CRITICAL_IGNORE_VULNERABLE_MOVE, false)
            ) then
                checkVulnerableMove = false
            end
            if valueOr(
                threatConfig.CRITICAL_ALLOW_UNSAFE_ATTACK,
                valueOr(defaultThreatConfig.CRITICAL_ALLOW_UNSAFE_ATTACK, false)
            ) then
                requireSafeAttack = false
            end
        end
        local baseAttackBonus = valueOr(threatConfig.BASE_ATTACK_BONUS, valueOr(defaultThreatConfig.BASE_ATTACK_BONUS, ZERO))
        local moveAttackBonus = valueOr(threatConfig.MOVE_ATTACK_BONUS, valueOr(defaultThreatConfig.MOVE_ATTACK_BONUS, ZERO))
        local eliminationBonus = valueOr(
            threatConfig.THREAT_ELIMINATION_BONUS,
            valueOr(defaultThreatConfig.THREAT_ELIMINATION_BONUS, ZERO)
        )
        local criticalAttackBonus = valueOr(
            threatConfig.CRITICAL_ATTACK_BONUS,
            valueOr(defaultThreatConfig.CRITICAL_ATTACK_BONUS, ZERO)
        )
        local threatLevelMult = valueOr(threatConfig.THREAT_LEVEL_MULT, valueOr(defaultThreatConfig.THREAT_LEVEL_MULT, ONE))
        local adjacentBonus = valueOr(
            threatConfig.ADJACENT_HUB_TARGET_BONUS,
            valueOr(defaultThreatConfig.ADJACENT_HUB_TARGET_BONUS, ZERO)
        )
        local nearBonus = valueOr(
            threatConfig.NEAR_HUB_TARGET_BONUS,
            valueOr(defaultThreatConfig.NEAR_HUB_TARGET_BONUS, ZERO)
        )
        local rangedBonus = valueOr(
            threatConfig.RANGED_HUB_THREAT_BONUS,
            valueOr(defaultThreatConfig.RANGED_HUB_THREAT_BONUS, ZERO)
        )

        local threatData, threatLookup = self:getCommandantThreatLookup(state, aiPlayer)
        if (threatData.threatLevel or ZERO) < minThreatLevel then
            return nil
        end
        if allowHealerAttacks then
            allowHealerAttacks = self:shouldHealerBeOffensive(state, {
                allowEmergencyDefense = true,
                commandantThreatData = threatData
            })
        end

        -- If a unit can already attack the same threat directly, avoid spending an extra
        -- move unless the move+attack strictly improves lethality/damage.
        local directThreatOptions = {}
        local directEntries = self:collectAttackTargetEntries(state, usedUnits, {
            mode = "direct",
            aiPlayer = aiPlayer,
            allowHealerAttacks = allowHealerAttacks,
            includeFriendlyFireCheck = true,
            requirePositiveDamage = true
        })
        for _, entry in ipairs(directEntries) do
            local targetKey = hashPosition(entry.target)
            local threatInfo = targetKey and threatLookup[targetKey]
            if threatInfo then
                local attackAllowed = true
                if requireSafeAttack then
                    attackAllowed = self:isAttackSafe(state, entry.unit, entry.target)
                end

                if attackAllowed then
                    local unitKey = self:getUnitKey(entry.unit)
                    if unitKey and targetKey then
                        local key = tostring(unitKey) .. "|" .. tostring(targetKey)
                        local damage = entry.damage or ZERO
                        local targetHp = entry.targetHp or MIN_HP
                        local isLethal = damage >= targetHp
                        local existing = directThreatOptions[key]
                        if (not existing)
                            or (isLethal and not existing.isLethal)
                            or (damage > (existing.damage or ZERO)) then
                            directThreatOptions[key] = {
                                damage = damage,
                                isLethal = isLethal
                            }
                        end
                    end
                end
            end
        end

        local entries = self:collectAttackTargetEntries(state, usedUnits, {
            mode = "move",
            aiPlayer = aiPlayer,
            allowHealerAttacks = allowHealerAttacks,
            requireSafeMove = requireSafeMove,
            checkVulnerableMove = checkVulnerableMove,
            includeFriendlyFireCheck = true,
            requirePositiveDamage = true
        })

        local candidates = {}
        for _, entry in ipairs(entries) do
            local targetKey = hashPosition(entry.target)
            local threatInfo = targetKey and threatLookup[targetKey]
            if threatInfo and entry.moveCell then
                local skipRedundantMove = false
                local unitKey = self:getUnitKey(entry.unit)
                if unitKey and targetKey then
                    local directKey = tostring(unitKey) .. "|" .. tostring(targetKey)
                    local directInfo = directThreatOptions[directKey]
                    if directInfo then
                        local moveDamage = entry.damage or ZERO
                        local moveLethal = moveDamage >= (entry.targetHp or MIN_HP)
                        local improvesLethality = moveLethal and not directInfo.isLethal
                        local improvesDamage = moveDamage > (directInfo.damage or ZERO)
                        if not improvesLethality and not improvesDamage then
                            skipRedundantMove = true
                        end
                    end
                end

                if not skipRedundantMove then
                    local projectedAttacker = self:buildProjectedThreatUnit(entry.unit, entry.moveCell.row, entry.moveCell.col) or entry.unit
                    local attackAllowed = true
                    if requireSafeAttack then
                        attackAllowed = self:isAttackSafe(state, projectedAttacker, entry.target)
                    end

                    if attackAllowed then
                        local context = self:getAttackOpportunityContext(state, projectedAttacker, entry.target, {
                            damage = entry.damage,
                            attackPos = {row = entry.moveCell.row, col = entry.moveCell.col},
                            includeRangedThreatToOwnHub = true
                        })

                        local score = self:getAttackOpportunityScore(
                            state,
                            projectedAttacker,
                            entry.target,
                            entry.damage,
                            entry.specialUsed,
                            context,
                            {
                                includeTargetValue = true,
                                useBaseTargetValue = true,
                                includeRangedThreatToOwnHub = true,
                                positionalUnit = projectedAttacker,
                                applyCommanderExposurePenalty = true,
                                movePos = entry.moveCell
                            }
                        )

                        score = score + baseAttackBonus + moveAttackBonus + ((threatInfo.threatLevel or ZERO) * threatLevelMult)
                        if context and context.isAdjacentToOwnHub then
                            score = score + adjacentBonus
                        elseif context and context.isNearAdjacentToOwnHub then
                            score = score + nearBonus
                        end
                        if context and context.isRangedThreatToOwnHub then
                            score = score + rangedBonus
                        end
                        if entry.damage >= (entry.targetHp or MIN_HP) then
                            score = score + eliminationBonus
                        end
                        if options.criticalDefense then
                            score = score + criticalAttackBonus
                        end

                        candidates[#candidates + ONE] = {
                            unit = entry.unit,
                            target = entry.target,
                            moveAction = entry.moveAction,
                            attackAction = entry.attackAction,
                            damage = entry.damage or ZERO,
                            targetHp = entry.targetHp or MIN_HP,
                            value = score,
                            threatLevel = threatInfo.threatLevel or ZERO
                        }
                    end
                end
            end
        end

        self:sortScoredEntries(candidates, {
            scoreField = "value",
            secondaryField = "threatLevel",
            descending = true
        })

        return candidates[ONE]
    end

    -- Delegate safety functions to aiSafety module
    function aiClass:isSuicidalMovement(state, targetPos, unit)
        return self.aiSafety.isSuicidalMovement(self, state, targetPos, unit)
    end

    function aiClass:isSuicidalAttack(state, attacker, target)
        return self.aiSafety.isSuicidalAttack(self, state, attacker, target)
    end

    function aiClass:isBeneficialSuicidalAttack(state, attacker, target)
        return self.aiSafety.isBeneficialSuicidalAttack(self, state, attacker, target)
    end

    function aiClass:isVulnerableToMoveAttack(state, targetPos, unit)
        return self.aiSafety.isVulnerableToMoveAttack(self, state, targetPos, unit)
    end

    function aiClass:calculateCommanderExposurePenalty(state, unit, targetPos)
        if not state or not unit or not targetPos then
            return ZERO
        end

        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ZERO
        end

        local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
        if not ownHub then
            return ZERO
        end
        local commanderExposureConfig = (self:getScoreConfig().SAFETY or {}).COMMANDER_EXPOSURE or {}
        local defaultCommanderExposureConfig = ((DEFAULT_SCORE_PARAMS.SAFETY or {}).COMMANDER_EXPOSURE or {})
        local lineOpenDamageMult = valueOr(commanderExposureConfig.LINE_OPEN_DAMAGE_MULT, defaultCommanderExposureConfig.LINE_OPEN_DAMAGE_MULT)
        local vacatedReachDamageMult = valueOr(commanderExposureConfig.VACATED_REACH_DAMAGE_MULT, defaultCommanderExposureConfig.VACATED_REACH_DAMAGE_MULT)
        local vacatedReachDistBuffer = valueOr(commanderExposureConfig.VACATED_REACH_DISTANCE_BUFFER, defaultCommanderExposureConfig.VACATED_REACH_DISTANCE_BUFFER)

        local originRow, originCol = unit.row, unit.col
        if not originRow or not originCol then
            return ZERO
        end

        if originRow == targetPos.row and originCol == targetPos.col then
            return ZERO
        end

        local vacatedPos = {row = originRow, col = originCol}
        local penalty = ZERO

        local hubUnit = {
            name = "Commandant",
            player = aiPlayer,
            row = ownHub.row,
            col = ownHub.col,
            currentHp = ownHub.currentHp,
            startingHp = ownHub.startingHp
        }

        local function isBlockedIgnoringVacated(row, col)
            if not self:isInsideBoard(row, col, state) then
                return true
            end

            if row == vacatedPos.row and col == vacatedPos.col then
                return false
            end

            for _, otherUnit in ipairs(state.units or {}) do
                if otherUnit.row == row and otherUnit.col == col and otherUnit ~= unit then
                    return true
                end
            end

            for _, building in ipairs(state.neutralBuildings or {}) do
                if building.row == row and building.col == col then
                    return true
                end
            end

            for playerId, hub in pairs(state.commandHubs or {}) do
                if hub and hub.row == row and hub.col == col then
                    if not (playerId == aiPlayer and row == vacatedPos.row and col == vacatedPos.col) then
                        return true
                    end
                end
            end

            return false
        end

        local function hasLineOfSightIgnoringVacated(fromPos, toPos)
            if fromPos.row == toPos.row and fromPos.col == toPos.col then
                return true
            end

            if fromPos.row ~= toPos.row and fromPos.col ~= toPos.col then
                return false
            end

            local path = self:getLinePath(fromPos, toPos)
            if not path or #path == ZERO then
                return false
            end

            for i = TWO, #path - ONE do
                local pos = path[i]
                if isBlockedIgnoringVacated(pos.row, pos.col) then
                    return false
                end
            end

            return true
        end

        for _, enemyUnit in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemyUnit, aiPlayer, {excludeHub = true}) then
                local hadLine = self:hasLineOfSight(state, enemyUnit, ownHub)
                local gainsLine = hasLineOfSightIgnoringVacated({row = enemyUnit.row, col = enemyUnit.col}, {row = ownHub.row, col = ownHub.col})

                if not hadLine and gainsLine then
                    local distance = math.abs(enemyUnit.row - ownHub.row) + math.abs(enemyUnit.col - ownHub.col)
                    local attackRange = unitsInfo:getUnitAttackRange(enemyUnit) or ZERO
                    local canThreatenHub = false

                    if self:unitHasTag(enemyUnit, "corvette") then
                        if distance >= TWO and distance <= attackRange then
                            canThreatenHub = true
                        end
                    elseif attackRange > ONE then
                        if distance <= attackRange then
                            canThreatenHub = true
                        end
                    end

                    if canThreatenHub then
                        local damage = unitsInfo:calculateAttackDamage(enemyUnit, hubUnit) or (enemyUnit.atkDamage or MIN_HP)
                        penalty = penalty + (damage * lineOpenDamageMult)
                    end
                end
            end
        end

        local function canEnemyReachVacated(enemyUnit)
            local moveRange = unitsInfo:getUnitMoveRange(enemyUnit) or ZERO
            if moveRange <= ZERO then
                return false
            end

            local canFly = unitsInfo:getUnitFlyStatus(enemyUnit)
            local queue = {{row = enemyUnit.row, col = enemyUnit.col, distance = ZERO}}
            local visited = {}
            visited[enemyUnit.row .. "," .. enemyUnit.col] = true

            while #queue > ZERO do
                local current = table.remove(queue, ONE)

                if current.row == vacatedPos.row and current.col == vacatedPos.col then
                    return true
                end

                if current.distance < moveRange then
                    for _, dir in ipairs(self:getOrthogonalDirections()) do
                        local nextRow = current.row + dir.row
                        local nextCol = current.col + dir.col
                        local key = nextRow .. "," .. nextCol

                        if not visited[key] and self:isInsideBoard(nextRow, nextCol, state) then
                            local blocked = isBlockedIgnoringVacated(nextRow, nextCol)
                            local canExplore = not blocked
                            local canLand = not blocked

                            if canFly then
                                canExplore = true
                                canLand = not blocked
                            end

                            if canExplore then
                                visited[key] = true
                                table.insert(queue, {row = nextRow, col = nextCol, distance = current.distance + ONE})
                            end

                            if canLand and nextRow == vacatedPos.row and nextCol == vacatedPos.col then
                                return true
                            end
                        end
                    end
                end
            end

            return false
        end

        local vacatedDistanceToHub = math.abs(vacatedPos.row - ownHub.row) + math.abs(vacatedPos.col - ownHub.col)
        if vacatedDistanceToHub == ONE then
            for _, enemyUnit in ipairs(state.units or {}) do
                if self:isAttackableEnemyUnit(enemyUnit, aiPlayer, {excludeHub = true}) then
                    local enemyRange = unitsInfo:getUnitMoveRange(enemyUnit) or ZERO
                    local distToVacated = math.abs(enemyUnit.row - vacatedPos.row) + math.abs(enemyUnit.col - vacatedPos.col)
                    if distToVacated <= enemyRange + vacatedReachDistBuffer then
                        if canEnemyReachVacated(enemyUnit) then
                            local damage = unitsInfo:calculateAttackDamage(enemyUnit, hubUnit) or (enemyUnit.atkDamage or MIN_HP)
                            penalty = penalty + (damage * vacatedReachDamageMult)
                        end
                    end
                end
            end
        end

        return penalty
    end

    --[[
    SECTION: POSITION SAFETY SCORING
    Estimates how secure a destination is for the acting unit after movement.
    - Evaluates direct and move-then-attack threats from every enemy.
    - Balances penalties with commander exposure and nearby ally support.
    ]]
    function aiClass:calculatePositionSafetyScore(state, unit, position)
        local safetyConfig = self:getScoreConfig().SAFETY or {}
        local defaultSafetyConfig = DEFAULT_SCORE_PARAMS.SAFETY or {}
        local safetyScore = valueOr(safetyConfig.BASE_SCORE, defaultSafetyConfig.BASE_SCORE)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return safetyScore
        end

        local tempUnit = {
            row = position.row,
            col = position.col,
            name = unit.name,
            player = unit.player,
            currentHp = unit.currentHp,
            startingHp = unit.startingHp,
            atkDamage = unit.atkDamage
        }

        -- Evaluate direct and move-then-attack threats from each opposing unit.
        for _, enemyUnit in ipairs(state.units) do
            if self:isAttackableEnemyUnit(enemyUnit, aiPlayer, {excludeHub = true}) then
                local attackCells = self:getAttackCellsForUnitAtPosition(state, enemyUnit, enemyUnit.row, enemyUnit.col)
                for _, attackCell in ipairs(attackCells) do
                    if attackCell.row == position.row and attackCell.col == position.col then
                        local damage = self:calculateDamage(enemyUnit, tempUnit)
                        safetyScore = safetyScore - (damage * valueOr(safetyConfig.DIRECT_THREAT_MULT, defaultSafetyConfig.DIRECT_THREAT_MULT))
                    end
                end

                local enemyMoveCells = self:getEnemyMoveCellsWithVacatedTile(state, enemyUnit, unit)

                for _, enemyMoveCell in ipairs(enemyMoveCells) do
                    local enemyAttackCells = self:getAttackCellsForUnitAtPosition(state, enemyUnit, enemyMoveCell.row, enemyMoveCell.col)
                    for _, attackCell in ipairs(enemyAttackCells) do
                        if attackCell.row == position.row and attackCell.col == position.col then
                            local damage = self:calculateDamage(enemyUnit, tempUnit)
                            safetyScore = safetyScore - (damage * valueOr(safetyConfig.MOVE_THREAT_MULT, defaultSafetyConfig.MOVE_THREAT_MULT))
                        end
                    end
                end
            end
        end

        local commanderPenalty = self:calculateCommanderExposurePenalty(state, unit, position)
        safetyScore = safetyScore - commanderPenalty

        -- Reward proximity to friendly support within two tiles.
        local friendlySupport = ZERO
        for _, friendlyUnit in ipairs(state.units) do
            if friendlyUnit.player == aiPlayer and not self:isHubUnit(friendlyUnit) then
                local distance = math.abs(friendlyUnit.row - position.row) + math.abs(friendlyUnit.col - position.col)
                if distance <= TWO then
                    friendlySupport = friendlySupport + ((THREE - distance) * valueOr(safetyConfig.FRIENDLY_SUPPORT_PER_TILE, defaultSafetyConfig.FRIENDLY_SUPPORT_PER_TILE))
                end
            end
        end
        safetyScore = safetyScore + friendlySupport

        return safetyScore
    end

    function aiClass:isStrategicNeutralBuildingAttack(state, attacker, building)
        return self.aiSafety.isStrategicNeutralBuildingAttack(self, state, attacker, building)
    end

    function aiClass:isDeadEndPosition(state, targetPos, unit)
        return self.aiSafety.isDeadEndPosition(self, state, targetPos, unit)
    end

    function aiClass:wouldBlockLineOfSight(state, cell, direction)
        return self.aiSafety.wouldBlockLineOfSight(self, state, cell, direction)
    end

    function aiClass:hasGoodFiringLanes(state, pos)
        return self.aiSafety.hasGoodFiringLanes(self, state, pos)
    end

    -- Wrapper to remove a unit from the list of units with remaining actions
    -- Delegates to ai_state implementation to keep logic centralized
    function aiClass:removeUnitFromRemainingActions(state, unit)
        return self.aiState.removeUnitFromRemainingActions(state, unit)
    end

    -- Helper to check if a position lies on the Manhattan path between two other positions (inclusive)
    function aiClass:isPositionBetween(pos, startPos, endPos)
        local dx = endPos.row - startPos.row
        local dy = endPos.col - startPos.col
        local distTotal = math.abs(dx) + math.abs(dy)
        if distTotal == ZERO then return false end
        for i = ONE, distTotal - ONE do -- exclude endpoints
            local checkRow = startPos.row + math.floor(dx * i / distTotal)
            local checkCol = startPos.col + math.floor(dy * i / distTotal)
            if checkRow == pos.row and checkCol == pos.col then
                return true
            end
        end
        return false
    end

    function aiClass:isPositionBetweenOrthogonal(pos, startPos, endPos)
        if not pos or not startPos or not endPos then
            return false
        end

        if startPos.row == endPos.row and pos.row == startPos.row then
            local minCol = math.min(startPos.col, endPos.col)
            local maxCol = math.max(startPos.col, endPos.col)
            return pos.col > minCol and pos.col < maxCol
        end

        if startPos.col == endPos.col and pos.col == startPos.col then
            local minRow = math.min(startPos.row, endPos.row)
            local maxRow = math.max(startPos.row, endPos.row)
            return pos.row > minRow and pos.row < maxRow
        end

        return false
    end

    function aiClass:hasLineOfSightIgnoringUnit(state, fromPos, toPos, ignoredUnit)
        local hasLOS = self:hasLineOfSight(state, fromPos, toPos)
        if hasLOS then
            return true
        end

        if not ignoredUnit or not ignoredUnit.row or not ignoredUnit.col then
            return false
        end

        return self:isPositionBetweenOrthogonal(
            {row = ignoredUnit.row, col = ignoredUnit.col},
            {row = fromPos.row, col = fromPos.col},
            {row = toPos.row, col = toPos.col}
        )
    end

    function aiClass:hasLimitedClearPath(state, startPos, endPos, maxSteps)
        if not state or not startPos or not endPos or not maxSteps or maxSteps <= ZERO then
            return false
        end

        local queue = {{row = startPos.row, col = startPos.col, steps = ZERO}}
        local visited = {}
        visited[startPos.row .. "," .. startPos.col] = true

        while #queue > ZERO do
            local current = table.remove(queue, ONE)
            if current.row == endPos.row and current.col == endPos.col then
                return true
            end

            if current.steps < maxSteps then
                for _, offset in ipairs(self:getOrthogonalDirections()) do
                    local neighbor = {
                        row = current.row + offset.row,
                        col = current.col + offset.col
                    }
                    local key = neighbor.row .. "," .. neighbor.col
                    if not visited[key] and self:isInsideBoard(neighbor.row, neighbor.col, state) then
                        local blocked = self.aiState.isPositionBlocked(state, neighbor.row, neighbor.col)
                        if neighbor.row == endPos.row and neighbor.col == endPos.col then
                            blocked = false
                        end
                        if not blocked then
                            visited[key] = true
                            table.insert(queue, {
                                row = neighbor.row,
                                col = neighbor.col,
                                steps = current.steps + ONE
                            })
                        end
                    end
                end
            end
        end

        return false
    end

    function aiClass:canUnitDamageTargetFromPosition(state, unit, target, fromRow, fromCol, opts)
        if not state or not unit or not target or not fromRow or not fromCol then
            return false
        end

        local options = opts or {}
        local requirePositiveDamage = options.requirePositiveDamage ~= false
        local projectedAttacker = self:buildProjectedThreatUnit(unit, fromRow, fromCol) or unit
        local attackCells = self:getAttackCellsForUnitAtPosition(state, projectedAttacker, fromRow, fromCol) or {}
        for _, attackCell in ipairs(attackCells) do
            if attackCell.row == target.row and attackCell.col == target.col then
                if not requirePositiveDamage then
                    return true
                end

                local damage = self:calculateDamage(projectedAttacker, target)
                return damage and damage > ZERO
            end
        end

        return false
    end

    function aiClass:getUnitThreatTiming(state, unit, target, maxTurns, opts)
        if not state or not unit or not target then
            return nil, nil
        end

        local maxLookaheadTurns = math.max(ONE, maxTurns or ONE)
        local options = opts or {}
        local requirePositiveDamage = options.requirePositiveDamage ~= false
        local considerCurrentActionState = options.considerCurrentActionState ~= false
        local allowMoveOnFirstTurn = options.allowMoveOnFirstTurn ~= false
        local maxFrontierNodes = options.maxFrontierNodes or 24

        local function distanceToTarget(posRow, posCol)
            return math.abs(posRow - target.row) + math.abs(posCol - target.col)
        end

        local frontier = {{
            state = state,
            unit = unit,
            dist = distanceToTarget(unit.row, unit.col)
        }}

        for turnIndex = ONE, maxLookaheadTurns do
            local nextFrontierByPos = {}

            for _, entry in ipairs(frontier) do
                local nodeState = entry.state
                local nodeUnit = entry.unit
                if nodeState and nodeUnit then
                    local canActThisTurn = true
                    local canMoveThisTurn = true

                    if considerCurrentActionState and turnIndex == ONE then
                        canActThisTurn = not nodeUnit.hasActed
                        canMoveThisTurn = (not nodeUnit.hasMoved) and allowMoveOnFirstTurn
                    end

                    if canActThisTurn then
                        if self:canUnitDamageTargetFromPosition(
                            nodeState,
                            nodeUnit,
                            target,
                            nodeUnit.row,
                            nodeUnit.col,
                            {requirePositiveDamage = requirePositiveDamage}
                        ) then
                            return turnIndex, "direct"
                        end

                        if canMoveThisTurn then
                            local moveCells = self:getValidMoveCells(nodeState, nodeUnit.row, nodeUnit.col) or {}
                            for _, moveCell in ipairs(moveCells) do
                                if self:canUnitDamageTargetFromPosition(
                                    nodeState,
                                    nodeUnit,
                                    target,
                                    moveCell.row,
                                    moveCell.col,
                                    {requirePositiveDamage = requirePositiveDamage}
                                ) then
                                    return turnIndex, "move_attack"
                                end
                            end
                        end
                    end

                    if turnIndex < maxLookaheadTurns then
                        local stayKey = string.format("%d,%d", nodeUnit.row, nodeUnit.col)
                        if not nextFrontierByPos[stayKey] then
                            nextFrontierByPos[stayKey] = {
                                state = nodeState,
                                unit = nodeUnit,
                                dist = distanceToTarget(nodeUnit.row, nodeUnit.col)
                            }
                        end

                        local moveCells = self:getValidMoveCells(nodeState, nodeUnit.row, nodeUnit.col) or {}
                        for _, moveCell in ipairs(moveCells) do
                            local simState, simUnit = self:simulateUnitMoveState(nodeState, nodeUnit, moveCell, {validate = true})
                            if simState and simUnit then
                                simUnit.hasActed = false
                                simUnit.hasMoved = false
                                local key = string.format("%d,%d", simUnit.row, simUnit.col)
                                local simDist = distanceToTarget(simUnit.row, simUnit.col)
                                local existing = nextFrontierByPos[key]
                                if (not existing) or simDist < (existing.dist or math.huge) then
                                    nextFrontierByPos[key] = {
                                        state = simState,
                                        unit = simUnit,
                                        dist = simDist
                                    }
                                end
                            end
                        end
                    end
                end
            end

            frontier = {}
            for _, node in pairs(nextFrontierByPos) do
                frontier[#frontier + ONE] = node
            end

            table.sort(frontier, function(a, b)
                local aDist = a.dist or math.huge
                local bDist = b.dist or math.huge
                if aDist == bDist then
                    local aKey = string.format("%d,%d", a.unit and a.unit.row or ZERO, a.unit and a.unit.col or ZERO)
                    local bKey = string.format("%d,%d", b.unit and b.unit.row or ZERO, b.unit and b.unit.col or ZERO)
                    return aKey < bKey
                end
                return aDist < bDist
            end)

            while #frontier > maxFrontierNodes do
                table.remove(frontier)
            end
        end

        return nil, nil
    end

    function aiClass:getEnemyMoveCellsWithVacatedTile(state, enemyUnit, vacatedUnit)
        local moveCells = self:getValidMoveCells(state, enemyUnit.row, enemyUnit.col) or {}
        if not vacatedUnit or not vacatedUnit.row or not vacatedUnit.col then
            return moveCells
        end

        local alreadyIncluded = false
        for _, cell in ipairs(moveCells) do
            if cell.row == vacatedUnit.row and cell.col == vacatedUnit.col then
                alreadyIncluded = true
                break
            end
        end

        if not alreadyIncluded then
            local distToUnit = math.abs(enemyUnit.row - vacatedUnit.row) + math.abs(enemyUnit.col - vacatedUnit.col)
            local enemyMoveRange = unitsInfo:getUnitMoveRange(enemyUnit, "ENEMY_MOVE_VACATED_TILE") or ZERO
            if distToUnit <= enemyMoveRange then
                table.insert(moveCells, {row = vacatedUnit.row, col = vacatedUnit.col})
            end
        end

        return moveCells
    end

    function aiClass:getAdjacentRangedThreatContext(state, aiPlayer)
        local owner = aiPlayer or self:getFactionId()
        if not state or not owner then
            return {
                active = false,
                threats = {},
                totalThreatValue = ZERO,
                highestThreatValue = ZERO
            }
        end

        local threats = {}
        local totalThreatValue = ZERO

        for _, ally in ipairs(state.units or {}) do
            if ally.player == owner
                and not self:isHubUnit(ally)
                and not self:isObstacleUnit(ally)
                and self:unitHasTag(ally, "ranged")
                and not unitsInfo:canAttackAdjacent(ally.name) then
                for _, enemy in ipairs(state.units or {}) do
                    if self:isAttackableEnemyUnit(enemy, owner, {excludeHub = true}) then
                        local dist = math.abs(enemy.row - ally.row) + math.abs(enemy.col - ally.col)
                        if dist == ONE and self:canUnitDamageTargetFromPosition(
                            state,
                            enemy,
                            ally,
                            enemy.row,
                            enemy.col,
                            {requirePositiveDamage = true}
                        ) then
                            local damage = self:calculateDamage(enemy, ally) or ZERO
                            if damage > ZERO then
                                local allyValue = self:getUnitBaseValue(ally, state) or ZERO
                                local enemyValue = self:getUnitBaseValue(enemy, state) or ZERO
                                local threatValue = (damage * 60) + (allyValue * 0.45) + (enemyValue * 0.2)
                                threats[#threats + ONE] = {
                                    ally = ally,
                                    enemy = enemy,
                                    damage = damage,
                                    threatValue = threatValue
                                }
                                totalThreatValue = totalThreatValue + threatValue
                            end
                        end
                    end
                end
            end
        end

        table.sort(threats, function(a, b)
            local aValue = a.threatValue or ZERO
            local bValue = b.threatValue or ZERO
            if aValue == bValue then
                local aKey = string.format(
                    "%d,%d|%d,%d",
                    a.ally and a.ally.row or ZERO,
                    a.ally and a.ally.col or ZERO,
                    a.enemy and a.enemy.row or ZERO,
                    a.enemy and a.enemy.col or ZERO
                )
                local bKey = string.format(
                    "%d,%d|%d,%d",
                    b.ally and b.ally.row or ZERO,
                    b.ally and b.ally.col or ZERO,
                    b.enemy and b.enemy.row or ZERO,
                    b.enemy and b.enemy.col or ZERO
                )
                return aKey < bKey
            end
            return aValue > bValue
        end)

        local highestThreatValue = threats[ONE] and (threats[ONE].threatValue or ZERO) or ZERO
        return {
            active = #threats > ZERO,
            threats = threats,
            totalThreatValue = totalThreatValue,
            highestThreatValue = highestThreatValue
        }
    end

    function aiClass:getAdjacentRangedRescueDeploymentScore(state, unit, cell, rescueContext)
        if not state or not unit or not cell or not rescueContext or not rescueContext.active then
            return ZERO
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local rescueConfig = doctrineConfig.ADJACENT_RANGED_RESCUE or {}
        if valueOr(rescueConfig.ENABLED, true) ~= true then
            return ZERO
        end

        local isHealer = self:unitHasTag(unit, "healer")
        local isRanged = self:unitHasTag(unit, "ranged")
        local canAttackAdjacent = unitsInfo:canAttackAdjacent(unit.name)
        local isFrontlineResponder = canAttackAdjacent and (
            self:unitHasTag(unit, "melee")
            or self:unitHasTag(unit, "tank")
            or self:unitHasTag(unit, "fortified")
            or self:unitHasTag(unit, "wingstalker")
        )

        local nearestThreat = nil
        local nearestThreatDist = math.huge
        for _, threat in ipairs(rescueContext.threats or {}) do
            local enemy = threat.enemy
            if enemy then
                local dist = math.abs(cell.row - enemy.row) + math.abs(cell.col - enemy.col)
                if dist < nearestThreatDist then
                    nearestThreatDist = dist
                    nearestThreat = threat
                end
            end
        end

        if not nearestThreat then
            return ZERO
        end

        local score = ZERO
        local moveRange = unitsInfo:getUnitMoveRange(unit, "ADJACENT_RANGED_RESCUE_MOVE") or ZERO
        local attackRange = unitsInfo:getUnitAttackRange(unit, "ADJACENT_RANGED_RESCUE_ATTACK") or ONE
        local reachesInOneTurn = nearestThreatDist <= (moveRange + attackRange)
        local reachesInTwoTurns = nearestThreatDist <= ((moveRange * TWO) + attackRange)

        if isHealer then
            score = score - valueOr(rescueConfig.HEALER_PENALTY, 260)
        elseif isFrontlineResponder and not isRanged then
            score = score + valueOr(rescueConfig.BASE_BONUS, 140)
            if reachesInOneTurn then
                score = score + valueOr(rescueConfig.ONE_TURN_REACH_BONUS, 180)
            elseif reachesInTwoTurns then
                score = score + valueOr(rescueConfig.TWO_TURN_REACH_BONUS, 90)
            else
                score = score + valueOr(rescueConfig.NO_REACH_BONUS, 20)
            end

            if unit.name == "Earthstalker" then
                score = score + valueOr(rescueConfig.EARTHSTALKER_BONUS, 80)
            elseif unit.name == "Crusher" then
                score = score + valueOr(rescueConfig.CRUSHER_BONUS, 70)
            elseif unit.name == "Bastion" then
                score = score + valueOr(rescueConfig.BASTION_BONUS, 55)
            elseif unit.name == "Wingstalker" then
                score = score + valueOr(rescueConfig.WINGSTALKER_BONUS, 30)
            end

            local threatScale = valueOr(rescueConfig.THREAT_VALUE_SCALE, 0.35)
            local threatCap = valueOr(rescueConfig.THREAT_VALUE_CAP, 80)
            score = score + math.min(threatCap, (nearestThreat.threatValue or ZERO) * threatScale)
        elseif isRanged and not canAttackAdjacent then
            score = score - valueOr(rescueConfig.RANGED_NONBRAWLER_PENALTY, 220)
        end

        return score
    end

    -- Scoring function used during supply deployment evaluation
    -- Returns a numeric score; higher means better deployment.
end

return M
