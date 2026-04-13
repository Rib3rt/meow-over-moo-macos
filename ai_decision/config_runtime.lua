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
    function aiClass:isUnitEligibleForAction(unit, aiPlayer, usedUnits, opts)
        if not unit or not aiPlayer then
            return false
        end
        if unit.player ~= aiPlayer then
            return false
        end

        local options = opts or {}
        local requireNotActed = options.requireNotActed ~= false
        local requireNotMoved = options.requireNotMoved or false
        local disallowCommandant = options.disallowCommandant ~= false
        local disallowRock = options.disallowRock or false
        local allowHealerAttacks = options.allowHealerAttacks
        local requireAlive = options.requireAlive or false

        if requireNotActed and unit.hasActed then
            return false
        end
        if requireNotMoved and unit.hasMoved then
            return false
        end
        if disallowCommandant and self:isHubUnit(unit) then
            return false
        end
        if disallowRock and self:isObstacleUnit(unit) then
            return false
        end
        if allowHealerAttacks == false and self:unitHasTag(unit, "healer") then
            return false
        end
        if requireAlive then
            local hp = unit.currentHp or unit.hp or unit.startingHp or ONE
            if hp <= ZERO then
                return false
            end
        end

        if usedUnits then
            local key = self:getUnitKey(unit)
            if key and usedUnits[key] then
                return false
            end
        end

        return true
    end

    function aiClass:collectMoveEvaluationEntries(state, usedUnits, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local unitEligibility = options.unitEligibility or {}
        local allowHealerAttacks = options.allowHealerAttacks
        local preUnitFilter = options.preUnitFilter
        local preMoveFilter = options.preMoveFilter
        local movePolicy = options.movePolicy or "none"
        local movePolicyOptions = options.movePolicyOptions
        local requireSimulation = options.requireSimulation ~= false
        local allowRangedAdjacent = options.allowRangedAdjacent == true
        local rangedStandoffThreatData = nil
        local entries = {}

        for _, unit in ipairs(state.units or {}) do
            local eligibilityOpts = {}
            for key, value in pairs(unitEligibility) do
                eligibilityOpts[key] = value
            end
            if allowHealerAttacks ~= nil then
                eligibilityOpts.allowHealerAttacks = allowHealerAttacks
            end

            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits, eligibilityOpts) then
                local unitAllowed = true
                if preUnitFilter then
                    unitAllowed = preUnitFilter(unit, state, aiPlayer) == true
                end

                if unitAllowed then
                    local moveCells = self:getValidMoveCells(state, unit.row, unit.col) or {}
                    for _, moveCell in ipairs(moveCells) do
                        local includeMove = true

                        if preMoveFilter then
                            includeMove = preMoveFilter(unit, moveCell, state, aiPlayer) == true
                        end

                        if includeMove then
                            if movePolicy == "safe" then
                                includeMove = self:isMoveSafe(state, unit, moveCell, movePolicyOptions)
                            elseif movePolicy == "open_safe" then
                                includeMove = self:isOpenSafeMoveCell(state, unit, moveCell, movePolicyOptions)
                            elseif movePolicy == "vulnerable" then
                                includeMove = self:isVulnerableMovePosition(state, unit, moveCell, movePolicyOptions)
                            end
                        end

                        if includeMove and self:unitHasTag(unit, "healer") then
                            local healerMoveAllowed, healerRejectReason = self:isHealerMoveDoctrineAllowed(
                                state,
                                unit,
                                moveCell,
                                aiPlayer,
                                {allowEmergencyDefense = true}
                            )
                            if not healerMoveAllowed then
                                includeMove = false
                                if healerRejectReason == "frontline" or healerRejectReason == "orbit" then
                                    self.healerFrontlineViolationRejected = (self.healerFrontlineViolationRejected or ZERO) + ONE
                                end
                            end
                        end

                        if includeMove and not allowRangedAdjacent then
                            if not rangedStandoffThreatData and unit and unit.name == "Cloudstriker" then
                                rangedStandoffThreatData = self:analyzeHubThreat(state)
                            end
                            local rangedViolation = self:isRangedStandoffViolation(state, unit, moveCell, aiPlayer, {
                                moveCells = moveCells,
                                threatData = rangedStandoffThreatData
                            })
                            if rangedViolation then
                                includeMove = false
                            end
                        end

                        if includeMove then
                            local entry = {
                                unit = unit,
                                moveCell = {row = moveCell.row, col = moveCell.col}
                            }

                            if requireSimulation then
                                local simState, movedUnit = self:simulateStateAfterMove(state, unit, moveCell)
                                if simState and movedUnit then
                                    entry.simState = simState
                                    entry.movedUnit = movedUnit
                                    entries[#entries + ONE] = entry
                                end
                            else
                                entries[#entries + ONE] = entry
                            end
                        end
                    end
                end
            end
        end

        return entries
    end

    function aiClass:getScoreConfig()
        local identityReference = tostring(self.aiReference or BASE_AI_REFERENCE)
        local effectiveReference = tostring(self:getEffectiveAiReference(self._referenceResolutionState, {
            lock = false,
            context = "score_config"
        }) or BASE_AI_REFERENCE)
        local cacheKey = effectiveReference
        if identityReference == "burns" then
            cacheKey = string.format("burns:%s:%s", tostring(self.factionId or ZERO), effectiveReference)
        end

        if not self._scoreConfig or self._scoreConfigReference ~= cacheKey then
            local overrides = (self.AI_PARAMS and self.AI_PARAMS.SCORES) or {}
            local profileConfig = (self.AI_PARAMS and self.AI_PARAMS.PROFILE) or {}
            local scoreOverrides = profileConfig.SCORE_OVERRIDES or {}
            local referenceOverrides = scoreOverrides[effectiveReference] or scoreOverrides[BASE_AI_REFERENCE] or {}
            self._scoreConfig = deepMerge(deepMerge(DEFAULT_SCORE_PARAMS, overrides), referenceOverrides)
            self._scoreConfigReference = cacheKey
        end
        return self._scoreConfig
    end

    function aiClass:getUnitProfiles()
        local identityReference = tostring(self.aiReference or BASE_AI_REFERENCE)
        local effectiveReference = tostring(self:getEffectiveAiReference(self._referenceResolutionState, {
            lock = false,
            context = "unit_profiles"
        }) or BASE_AI_REFERENCE)
        local cacheKey = effectiveReference
        if identityReference == "burns" then
            cacheKey = string.format("burns:%s:%s", tostring(self.factionId or ZERO), effectiveReference)
        end

        if not self._unitProfiles or self._unitProfilesReference ~= cacheKey then
            local overrides = (self.AI_PARAMS and self.AI_PARAMS.UNIT_PROFILES) or {}
            local profileConfig = (self.AI_PARAMS and self.AI_PARAMS.PROFILE) or {}
            local unitProfileOverrides = profileConfig.UNIT_PROFILE_OVERRIDES or {}
            local referenceOverrides = unitProfileOverrides[effectiveReference] or unitProfileOverrides[BASE_AI_REFERENCE] or {}
            self._unitProfiles = deepMerge(deepMerge(DEFAULT_UNIT_PROFILES, overrides), referenceOverrides)
            self._unitProfilesReference = cacheKey
        end
        return self._unitProfiles
    end

    function aiClass:getUnitProfile(unitOrName)
        local name = type(unitOrName) == "table" and unitOrName.name or unitOrName
        local profiles = self:getUnitProfiles()
        if name and profiles[name] then
            return profiles[name]
        end
        return profiles.DEFAULT
    end

    function aiClass:unitHasTag(unitOrName, tag)
        local profile = self:getUnitProfile(unitOrName)
        return profile and profile.tags and profile.tags[tag] == true
    end

    function aiClass:getTargetPriority(unit)
        local profile = self:getUnitProfile(unit)
        local defaultProfile = self:getUnitProfile("DEFAULT")
        return (profile and profile.targetPriority) or (defaultProfile and defaultProfile.targetPriority)
    end

    function aiClass:getAttackPattern(unit)
        local profile = self:getUnitProfile(unit)
        local defaultProfile = self:getUnitProfile("DEFAULT")
        return (profile and profile.attackPattern) or (defaultProfile and defaultProfile.attackPattern)
    end

    function aiClass:getPositionalScoreConfig()
        return self:getScoreConfig().POSITIONAL or {}
    end

    function aiClass:getSafetyPolicyConfig()
        return self:getScoreConfig().SAFETY_POLICY or {}
    end

    function aiClass:resolveSafetyPolicyOptions(policyNameOrOpts, opts)
        local policyName = nil
        local inlineOpts = {}

        if type(policyNameOrOpts) == "string" then
            policyName = policyNameOrOpts
            inlineOpts = opts or {}
        else
            inlineOpts = policyNameOrOpts or {}
            policyName = inlineOpts.policy
        end

        local policy = {}
        if type(policyName) == "string" then
            policy = self:getSafetyPolicyConfig()[policyName] or {}
        end

        local resolved = {}
        for k, v in pairs(policy) do
            resolved[k] = v
        end
        for k, v in pairs(inlineOpts) do
            if k ~= "policy" then
                resolved[k] = v
            end
        end

        return resolved
    end

    function aiClass:getPathOpeningConfig()
        return self:getScoreConfig().PATH_OPENING or {}
    end

    function aiClass:getThreatCounterConfig()
        return self:getScoreConfig().THREAT_COUNTER or {}
    end

    function aiClass:getCommandantThreatResponseScoreConfig()
        return self:getScoreConfig().COMMANDANT_THREAT_RESPONSE or {}
    end

    function aiClass:getHubThreatLookaheadScoreConfig()
        return self:getScoreConfig().HUB_THREAT_LOOKAHEAD or {}
    end

    function aiClass:getThreatReleaseOffenseScoreConfig()
        return self:getScoreConfig().THREAT_RELEASE_OFFENSE or {}
    end

    function aiClass:getCommandantGuardScoreConfig()
        return self:getScoreConfig().COMMANDANT_GUARD or {}
    end

    function aiClass:getCommandantDefenseUnblockScoreConfig()
        return self:getScoreConfig().COMMANDANT_DEFENSE_UNBLOCK or {}
    end

    function aiClass:getSupplyDeploymentScoreConfig()
        return self:getScoreConfig().SUPPLY_DEPLOYMENT or {}
    end

    function aiClass:getNeutralBuildingAttackScoreConfig()
        return self:getScoreConfig().NEUTRAL_BUILDING_ATTACK or {}
    end

    function aiClass:getRiskyMoveScoreConfig()
        return self:getScoreConfig().RISKY_MOVE or {}
    end

    function aiClass:getBlockingObjectivesScoreConfig()
        return self:getScoreConfig().BLOCKING_OBJECTIVES or {}
    end

    function aiClass:getRandomActionScoreConfig()
        return self:getScoreConfig().RANDOM_ACTION or {}
    end

    function aiClass:getHealerOffenseScoreConfig()
        return self:getScoreConfig().HEALER_OFFENSE or {}
    end

    function aiClass:getStrategyScoreConfig()
        return self:getScoreConfig().STRATEGY or {}
    end

    function aiClass:getDoctrineScoreConfig()
        return self:getScoreConfig().DOCTRINE or {}
    end

    function aiClass:getTurnFlowScoreConfig()
        return self:getScoreConfig().TURN_FLOW or {}
    end

    function aiClass:getPerformanceRuleConfig()
        return PERFORMANCE_RULE_CONTRACT or {}
    end

    function aiClass:getRuntimeDiagnostics()
        local plannerState = self.strategicPlanState or {}
        local defenseState = self.defenseModeState or {}
        return {
            lastDecisionLatencyMs = self.lastDecisionLatencyMs,
            latencySummary = self.lastDecisionLatencySummary,
            decisionCount = self.decisionCount or ZERO,
            determinism = self._determinismStats or {checks = ZERO, mismatches = ZERO},
            counters = {
                badDeploySkipped = self.badDeploySkipped or ZERO,
                unsupportedAttackRejected = self.unsupportedAttackRejected or ZERO,
                verifierOverrideCount = self.verifierOverrideCount or ZERO,
                verifierTimeoutCount = self.verifierTimeoutCount or ZERO,
                verifierSiegeRuns = self.verifierSiegeRuns or ZERO,
                verifierSiegeOverrides = self.verifierSiegeOverrides or ZERO,
                rockAttackChosenCount = self.rockAttackChosenCount or ZERO,
                rockAttackStrategicCount = self.rockAttackStrategicCount or ZERO,
                fillerAttackAvoidedCount = self.fillerAttackAvoidedCount or ZERO,
                healerFrontlineViolationRejected = self.healerFrontlineViolationRejected or ZERO,
                openingHealerBlockedCount = self.openingHealerBlockedCount or ZERO,
                phaseEarlyTurns = self.phaseEarlyTurns or ZERO,
                phaseMidTurns = self.phaseMidTurns or ZERO,
                phaseEndTurns = self.phaseEndTurns or ZERO,
                midgameContactTriggerCount = self.midgameContactTriggerCount or ZERO,
                earlyAttackSuppressedCount = self.earlyAttackSuppressedCount or ZERO,
                openingCounterScoreAppliedCount = self.openingCounterScoreAppliedCount or ZERO,
                endgameEtaHubChoiceCount = self.endgameEtaHubChoiceCount or ZERO,
                endgameEtaWipeChoiceCount = self.endgameEtaWipeChoiceCount or ZERO,
                endgameDeploySkippedCount = self.endgameDeploySkippedCount or ZERO
            },
            defenseTransitions = {
                defendHardEnterReason = self.defendHardEnterReason,
                defendHardExitReason = self.defendHardExitReason
            },
            defenseMode = {
                active = defenseState.active == true,
                holdTurnsLeft = defenseState.holdTurnsLeft or ZERO,
                enterTurn = defenseState.enterTurn,
                reason = defenseState.reason,
                enterScore = defenseState.enterScore or ZERO
            },
            strategy = {
                intent = plannerState.intent,
                planId = plannerState.planId,
                planTurnsLeft = plannerState.planTurnsLeft,
                planScore = plannerState.planScore,
                active = plannerState.active == true,
                budgetExceeded = plannerState.lastBudgetExceeded == true
            }
        }
    end

    function aiClass:benchmarkDecisionState(state, iterations)
        local runs = math.max(ONE, math.floor(tonumber(iterations) or 20))
        local signatures = {}
        local latencies = {}
        local unique = {}

        local snapshot = {
            lastProcessedTurnKey = self.lastProcessedTurnKey,
            lastSequence = deepCopyValue(self.lastSequence),
            isProcessingTurn = self.isProcessingTurn,
            positionHistory = deepCopyValue(self.positionHistory),
            drawUrgencyMode = deepCopyValue(self.drawUrgencyMode),
            threatReleaseOffenseState = deepCopyValue(self.threatReleaseOffenseState),
            strategicPlanState = deepCopyValue(self.strategicPlanState),
            defenseModeState = deepCopyValue(self.defenseModeState),
            verifierOverrideCount = self.verifierOverrideCount,
            verifierTimeoutCount = self.verifierTimeoutCount,
            verifierSiegeRuns = self.verifierSiegeRuns,
            verifierSiegeOverrides = self.verifierSiegeOverrides,
            badDeploySkipped = self.badDeploySkipped,
            unsupportedAttackRejected = self.unsupportedAttackRejected,
            rockAttackChosenCount = self.rockAttackChosenCount,
            rockAttackStrategicCount = self.rockAttackStrategicCount,
            fillerAttackAvoidedCount = self.fillerAttackAvoidedCount,
            healerFrontlineViolationRejected = self.healerFrontlineViolationRejected,
            openingHealerBlockedCount = self.openingHealerBlockedCount,
            phaseEarlyTurns = self.phaseEarlyTurns,
            phaseMidTurns = self.phaseMidTurns,
            phaseEndTurns = self.phaseEndTurns,
            midgameContactTriggerCount = self.midgameContactTriggerCount,
            earlyAttackSuppressedCount = self.earlyAttackSuppressedCount,
            openingCounterScoreAppliedCount = self.openingCounterScoreAppliedCount,
            endgameEtaHubChoiceCount = self.endgameEtaHubChoiceCount,
            endgameEtaWipeChoiceCount = self.endgameEtaWipeChoiceCount,
            endgameDeploySkippedCount = self.endgameDeploySkippedCount,
            defendHardEnterReason = self.defendHardEnterReason,
            defendHardExitReason = self.defendHardExitReason
        }

        local function percentile(values, ratio)
            if #values == ZERO then
                return ZERO
            end
            local sorted = {}
            for i = ONE, #values do
                sorted[i] = values[i]
            end
            table.sort(sorted)
            local idx = math.max(ONE, math.ceil(#sorted * ratio))
            return sorted[idx] or ZERO
        end

        for i = ONE, runs do
            self.lastProcessedTurnKey = nil
            self.lastSequence = nil
            self.isProcessingTurn = false
            self.positionHistory = deepCopyValue(snapshot.positionHistory)
            self.drawUrgencyMode = deepCopyValue(snapshot.drawUrgencyMode)
            self.threatReleaseOffenseState = deepCopyValue(snapshot.threatReleaseOffenseState)
            self.strategicPlanState = deepCopyValue(snapshot.strategicPlanState)
            self.defenseModeState = deepCopyValue(snapshot.defenseModeState)
            self.verifierOverrideCount = snapshot.verifierOverrideCount
            self.verifierTimeoutCount = snapshot.verifierTimeoutCount
            self.verifierSiegeRuns = snapshot.verifierSiegeRuns
            self.verifierSiegeOverrides = snapshot.verifierSiegeOverrides
            self.badDeploySkipped = snapshot.badDeploySkipped
            self.unsupportedAttackRejected = snapshot.unsupportedAttackRejected
            self.rockAttackChosenCount = snapshot.rockAttackChosenCount
            self.rockAttackStrategicCount = snapshot.rockAttackStrategicCount
            self.fillerAttackAvoidedCount = snapshot.fillerAttackAvoidedCount
            self.healerFrontlineViolationRejected = snapshot.healerFrontlineViolationRejected
            self.openingHealerBlockedCount = snapshot.openingHealerBlockedCount
            self.phaseEarlyTurns = snapshot.phaseEarlyTurns
            self.phaseMidTurns = snapshot.phaseMidTurns
            self.phaseEndTurns = snapshot.phaseEndTurns
            self.midgameContactTriggerCount = snapshot.midgameContactTriggerCount
            self.earlyAttackSuppressedCount = snapshot.earlyAttackSuppressedCount
            self.openingCounterScoreAppliedCount = snapshot.openingCounterScoreAppliedCount
            self.endgameEtaHubChoiceCount = snapshot.endgameEtaHubChoiceCount
            self.endgameEtaWipeChoiceCount = snapshot.endgameEtaWipeChoiceCount
            self.endgameDeploySkippedCount = snapshot.endgameDeploySkippedCount
            self.defendHardEnterReason = snapshot.defendHardEnterReason
            self.defendHardExitReason = snapshot.defendHardExitReason

            local stateCopy = self:deepCopyState(state)
            local sequence = self:getBestSequence(stateCopy)
            local signature = self:buildActionSequenceSignature(sequence)
            signatures[i] = signature
            unique[signature] = (unique[signature] or ZERO) + ONE
            latencies[i] = self.lastDecisionLatencyMs or ZERO
        end

        self.lastProcessedTurnKey = snapshot.lastProcessedTurnKey
        self.lastSequence = snapshot.lastSequence
        self.isProcessingTurn = snapshot.isProcessingTurn
        self.positionHistory = snapshot.positionHistory
        self.drawUrgencyMode = snapshot.drawUrgencyMode
        self.threatReleaseOffenseState = snapshot.threatReleaseOffenseState
        self.strategicPlanState = snapshot.strategicPlanState
        self.defenseModeState = snapshot.defenseModeState
        self.verifierOverrideCount = snapshot.verifierOverrideCount
        self.verifierTimeoutCount = snapshot.verifierTimeoutCount
        self.verifierSiegeRuns = snapshot.verifierSiegeRuns
        self.verifierSiegeOverrides = snapshot.verifierSiegeOverrides
        self.badDeploySkipped = snapshot.badDeploySkipped
        self.unsupportedAttackRejected = snapshot.unsupportedAttackRejected
        self.rockAttackChosenCount = snapshot.rockAttackChosenCount
        self.rockAttackStrategicCount = snapshot.rockAttackStrategicCount
        self.fillerAttackAvoidedCount = snapshot.fillerAttackAvoidedCount
        self.healerFrontlineViolationRejected = snapshot.healerFrontlineViolationRejected
        self.openingHealerBlockedCount = snapshot.openingHealerBlockedCount
        self.phaseEarlyTurns = snapshot.phaseEarlyTurns
        self.phaseMidTurns = snapshot.phaseMidTurns
        self.phaseEndTurns = snapshot.phaseEndTurns
        self.midgameContactTriggerCount = snapshot.midgameContactTriggerCount
        self.earlyAttackSuppressedCount = snapshot.earlyAttackSuppressedCount
        self.openingCounterScoreAppliedCount = snapshot.openingCounterScoreAppliedCount
        self.endgameEtaHubChoiceCount = snapshot.endgameEtaHubChoiceCount
        self.endgameEtaWipeChoiceCount = snapshot.endgameEtaWipeChoiceCount
        self.endgameDeploySkippedCount = snapshot.endgameDeploySkippedCount
        self.defendHardEnterReason = snapshot.defendHardEnterReason
        self.defendHardExitReason = snapshot.defendHardExitReason

        local uniqueCount = ZERO
        for _ in pairs(unique) do
            uniqueCount = uniqueCount + ONE
        end

        return {
            runs = runs,
            uniqueSignatures = uniqueCount,
            deterministic = uniqueCount == ONE,
            signatures = signatures,
            latency = {
                medianMs = percentile(latencies, 0.5),
                p95Ms = percentile(latencies, 0.95),
                samples = latencies
            }
        }
    end

    function aiClass:buildDeterminismStateKey(state)
        if not state then
            return "state:nil"
        end

        local parts = {
            "t=" .. tostring(state.currentTurn or ZERO),
            "p=" .. tostring(state.currentPlayer or ZERO),
            "d=" .. tostring(state.hasDeployedThisTurn and 1 or 0),
            "tw=" .. tostring(state.turnsWithoutDamage or ZERO)
        }

        local units = {}
        for _, unit in ipairs(state.units or {}) do
            units[#units + ONE] = string.format(
                "%s|%s|%d|%d|%d|%d|%d",
                tostring(unit.player or ZERO),
                tostring(unit.name or "?"),
                unit.row or ZERO,
                unit.col or ZERO,
                unit.currentHp or unit.startingHp or ZERO,
                unit.hasActed and ONE or ZERO,
                unit.hasMoved and ONE or ZERO
            )
        end
        table.sort(units)
        parts[#parts + ONE] = "u=" .. table.concat(units, ";")

        local supply = {}
        for playerId, unitsInSupply in pairs(state.supply or {}) do
            local names = {}
            for _, unit in ipairs(unitsInSupply or {}) do
                names[#names + ONE] = tostring(unit.name or "?")
            end
            table.sort(names)
            supply[#supply + ONE] = tostring(playerId) .. ":" .. table.concat(names, ",")
        end
        table.sort(supply)
        parts[#parts + ONE] = "s=" .. table.concat(supply, ";")

        local hubs = {}
        for playerId, hub in pairs(state.commandHubs or {}) do
            hubs[#hubs + ONE] = string.format(
                "%s|%d|%d|%d",
                tostring(playerId),
                hub and hub.row or ZERO,
                hub and hub.col or ZERO,
                hub and (hub.currentHp or hub.startingHp or ZERO) or ZERO
            )
        end
        table.sort(hubs)
        parts[#parts + ONE] = "h=" .. table.concat(hubs, ";")

        local rocks = {}
        for _, building in ipairs(state.neutralBuildings or {}) do
            rocks[#rocks + ONE] = string.format(
                "%d|%d|%d",
                building.row or ZERO,
                building.col or ZERO,
                building.currentHp or building.startingHp or ZERO
            )
        end
        table.sort(rocks)
        parts[#parts + ONE] = "r=" .. table.concat(rocks, ";")

        return table.concat(parts, "||")
    end

    function aiClass:buildActionSequenceSignature(sequence)
        local parts = {}
        for i, action in ipairs(sequence or {}) do
            local actionType = action and action.type or "?"
            local unit = action and action.unit or {}
            local target = action and action.target or {}
            local descriptor = string.format(
                "%d:%s:%d,%d->%d,%d",
                i,
                tostring(actionType),
                unit.row or ZERO,
                unit.col or ZERO,
                target.row or ZERO,
                target.col or ZERO
            )

            if actionType == "supply_deploy" then
                descriptor = string.format(
                    "%d:%s:%s@%d,%d",
                    i,
                    tostring(actionType),
                    tostring(action.unitName or "?"),
                    target.row or ZERO,
                    target.col or ZERO
                )
            end

            parts[#parts + ONE] = descriptor
        end
        return table.concat(parts, "|")
    end

    function aiClass:recordDeterminismObservation(state, sequence)
        local perfConfig = self:getPerformanceRuleConfig()
        if perfConfig.DETERMINISM_CHECK == false then
            return
        end

        local key = self:buildDeterminismStateKey(state)
        local signature = self:buildActionSequenceSignature(sequence or {})

        self._determinismMap = self._determinismMap or {}
        self._determinismOrder = self._determinismOrder or {}
        self._determinismStats = self._determinismStats or {checks = ZERO, mismatches = ZERO}
        self._determinismStats.checks = self._determinismStats.checks + ONE

        local previous = self._determinismMap[key]
        if previous and previous ~= signature then
            self._determinismStats.mismatches = self._determinismStats.mismatches + ONE
            self:logDecision("Determinism", "Sequence mismatch for identical state key", {
                previous = previous,
                current = signature
            })
            return
        end

        if not previous then
            self._determinismMap[key] = signature
            self._determinismOrder[#self._determinismOrder + ONE] = key
            local maxCache = valueOr(perfConfig.DETERMINISM_CACHE_SIZE, 500)
            while #self._determinismOrder > maxCache do
                local oldest = table.remove(self._determinismOrder, ONE)
                if oldest then
                    self._determinismMap[oldest] = nil
                end
            end
        end
    end

    function aiClass:isActionEquivalent(actionA, actionB)
        if not actionA or not actionB then
            return false
        end
        if actionA.type ~= actionB.type then
            return false
        end

        local function posEqual(posA, posB)
            if not posA or not posB then
                return false
            end
            return posA.row == posB.row and posA.col == posB.col
        end

        if actionA.type == "supply_deploy" then
            return actionA.unitIndex == actionB.unitIndex and posEqual(actionA.target, actionB.target)
        end

        return posEqual(actionA.unit, actionB.unit) and posEqual(actionA.target, actionB.target)
    end

    function aiClass:resolveActionAgainstState(state, proposedAction, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        local allowHealerRepairException = options.allowFullHpHealerRepairException == true
        local fallbackCell = (self:getTurnFlowScoreConfig().SKIP_FALLBACK_CELL)
            or ((DEFAULT_SCORE_PARAMS.TURN_FLOW or {}).SKIP_FALLBACK_CELL)
            or {row = ONE, col = ONE}
        local skipAction = {
            type = "skip",
            unit = {row = fallbackCell.row, col = fallbackCell.col}
        }

        if not state or not aiPlayer then
            return skipAction, true, "no_state"
        end

        local legalEntries = self:collectLegalActions(state, {
            aiPlayer = aiPlayer,
            usedUnits = options.usedUnits,
            includeMove = options.includeMove ~= false,
            includeAttack = options.includeAttack ~= false,
            includeRepair = options.includeRepair ~= false,
            includeDeploy = options.includeDeploy ~= false,
            allowFullHpHealerRepairException = allowHealerRepairException
        })

        if #legalEntries == ZERO then
            return skipAction, true, "no_legal_actions"
        end

        if proposedAction and proposedAction.type ~= "skip" then
            for _, legalEntry in ipairs(legalEntries) do
                if legalEntry and legalEntry.action and self:isActionEquivalent(proposedAction, legalEntry.action) then
                    return proposedAction, false, "as_selected"
                end
            end
        end

        local fallback = self:getMandatoryFallbackCandidates(state, {
            aiPlayer = aiPlayer,
            usedUnits = options.usedUnits,
            includeMove = options.includeMove ~= false,
            includeAttack = options.includeAttack ~= false,
            includeRepair = options.includeRepair ~= false,
            includeDeploy = options.includeDeploy ~= false,
            allowFullHpHealerRepairException = allowHealerRepairException
        })
        if fallback[ONE] and fallback[ONE].action then
            return fallback[ONE].action, true, "fallback_replacement"
        end

        return skipAction, true, "skip_fallback"
    end

    function aiClass:sanitizeActionSequenceForState(state, sequence, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        local maxActions = valueOr(
            options.maxActions,
            valueOr(TURN_RULE_CONTRACT.ACTIONS_PER_TURN, valueOr(ACTION_RULE_CONTRACT.MANDATORY_ACTION_COUNT, TWO))
        )
        local allowHealerRepairException = options.allowFullHpHealerRepairException == true

        if not state then
            return sequence or {}, {replacements = ZERO, reasonCounts = {}}
        end

        local simulatedState = self:deepCopyState(state)
        local sanitized = {}
        local replacements = ZERO
        local reasonCounts = {}

        for actionIndex = ONE, maxActions do
            local proposed = sequence and sequence[actionIndex] or nil
            local resolved, replaced, reason = self:resolveActionAgainstState(simulatedState, proposed, {
                aiPlayer = aiPlayer,
                includeMove = true,
                includeAttack = true,
                includeRepair = true,
                includeDeploy = true,
                allowFullHpHealerRepairException = allowHealerRepairException
            })

            sanitized[#sanitized + ONE] = resolved
            if replaced then
                replacements = replacements + ONE
                reasonCounts[reason or "unknown"] = (reasonCounts[reason or "unknown"] or ZERO) + ONE
            end

            if resolved and resolved.type and resolved.type ~= "skip" then
                if resolved.type == "supply_deploy" then
                    simulatedState = self:applySupplyDeployment(simulatedState, resolved)
                else
                    simulatedState = self:applyMove(simulatedState, resolved)
                end
            end
        end

        return sanitized, {
            replacements = replacements,
            reasonCounts = reasonCounts
        }
    end

    function aiClass:collectLegalActions(state, opts)
        if not state then
            return {}
        end

        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer then
            return {}
        end

        local includeMove = options.includeMove ~= false
        local includeAttack = options.includeAttack ~= false
        local includeRepair = options.includeRepair ~= false
        local includeDeploy = options.includeDeploy ~= false
        local allowFullHpHealerRepairException = options.allowFullHpHealerRepairException == true
        local usedUnits = options.usedUnits
        local actions = {}

        local function addAction(entry)
            if entry and entry.action then
                actions[#actions + ONE] = entry
            end
        end

        for _, unit in ipairs(state.units or {}) do
            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits, {
                requireNotActed = true,
                requireNotMoved = false,
                disallowCommandant = true
            }) then
                if includeAttack then
                    local attackCells = self:getValidAttackCells(state, unit.row, unit.col) or {}
                    for _, cell in ipairs(attackCells) do
                        local target = self:getUnitAtPosition(state, cell.row, cell.col)
                        if not target then
                            for _, building in ipairs(state.neutralBuildings or {}) do
                                if building.row == cell.row and building.col == cell.col then
                                    target = {
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
                        if target and target.player ~= aiPlayer then
                            addAction({
                                type = "attack",
                                unit = unit,
                                target = target,
                                action = {
                                    type = "attack",
                                    unit = {row = unit.row, col = unit.col},
                                    target = {row = cell.row, col = cell.col}
                                }
                            })
                        end
                    end
                end

                if includeRepair and self:unitHasTag(unit, "healer") then
                    local repairCells = self:getValidRepairCells(state, unit.row, unit.col) or {}
                    for _, cell in ipairs(repairCells) do
                        local target = self:getUnitAtPosition(state, cell.row, cell.col)
                        if target and target.player == aiPlayer then
                            addAction({
                                type = "repair",
                                unit = unit,
                                target = target,
                                action = {
                                    type = "repair",
                                    unit = {row = unit.row, col = unit.col},
                                    target = {row = cell.row, col = cell.col}
                                }
                            })
                        end
                    end

                    if allowFullHpHealerRepairException and #repairCells == ZERO then
                        for _, dir in ipairs(self:getOrthogonalDirections()) do
                            local checkRow = unit.row + dir.row
                            local checkCol = unit.col + dir.col
                            local target = self:getUnitAtPosition(state, checkRow, checkCol)
                            if target and target.player == aiPlayer then
                                addAction({
                                    type = "repair",
                                    unit = unit,
                                    target = target,
                                    action = {
                                        type = "repair",
                                        unit = {row = unit.row, col = unit.col},
                                        target = {row = checkRow, col = checkCol}
                                    },
                                    mandatoryException = "healer_full_hp_repair"
                                })
                            end
                        end
                    end
                end

                if includeMove and not unit.hasMoved then
                    local moveCells = self:getValidMoveCells(state, unit.row, unit.col) or {}
                    for _, cell in ipairs(moveCells) do
                        addAction({
                            type = "move",
                            unit = unit,
                            action = {
                                type = "move",
                                unit = {row = unit.row, col = unit.col},
                                target = {row = cell.row, col = cell.col}
                            }
                        })
                    end
                end
            end
        end

        if includeDeploy then
            local deployments = self:getPossibleSupplyDeployments(state, true) or {}
            for _, deployment in ipairs(deployments) do
                addAction({
                    type = "supply_deploy",
                    action = deployment
                })
            end
        end

        return actions
    end

    function aiClass:getMandatoryFallbackCandidates(state, opts)
        local options = opts or {}
        local fallbackAiPlayer = options.aiPlayer or self:getFactionId()
        local doctrineConfig = self:getDoctrineScoreConfig()
        local fallbackDoctrine = doctrineConfig.FALLBACK or {}
        local rockDoctrine = doctrineConfig.ROCK_ATTACK or {}
        local preferDeployOrPosition = valueOr(fallbackDoctrine.PREFER_DEPLOY_OR_POSITION, true)
        local rockPenalty = math.max(ZERO, valueOr(fallbackDoctrine.ROCK_ATTACK_PENALTY, 4000))
        local unsupportedPenalty = math.max(ZERO, valueOr(fallbackDoctrine.UNSUPPORTED_NONLETHAL_PENALTY, 6000))

        local legalActions = self:collectLegalActions(state, {
            aiPlayer = fallbackAiPlayer,
            usedUnits = options.usedUnits,
            includeMove = options.includeMove ~= false,
            includeAttack = options.includeAttack ~= false,
            includeRepair = options.includeRepair ~= false,
            includeDeploy = options.includeDeploy ~= false,
            allowFullHpHealerRepairException = options.allowFullHpHealerRepairException == true
        })

        if #legalActions == ZERO and ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION then
            legalActions = self:collectLegalActions(state, {
                aiPlayer = fallbackAiPlayer,
                usedUnits = options.usedUnits,
                includeMove = true,
                includeAttack = true,
                includeRepair = true,
                includeDeploy = true,
                allowFullHpHealerRepairException = true
            })
        end

        if #legalActions == ZERO then
            return {}
        end

        local function evaluateImmediateThreatAtPosition(boardState, targetUnit)
            if not boardState or not targetUnit or not fallbackAiPlayer then
                return {
                    threateningAttackers = ZERO,
                    totalDamage = ZERO,
                    maxDamage = ZERO,
                    lethalAttackers = ZERO
                }
            end

            local hp = targetUnit.currentHp or targetUnit.startingHp or MIN_HP
            local summary = {
                threateningAttackers = ZERO,
                totalDamage = ZERO,
                maxDamage = ZERO,
                lethalAttackers = ZERO
            }

            for _, enemy in ipairs(boardState.units or {}) do
                if enemy.player ~= fallbackAiPlayer and not self:isHubUnit(enemy) and not self:isObstacleUnit(enemy) then
                    local canDamage = self:canUnitDamageTargetFromPosition(
                        boardState,
                        enemy,
                        targetUnit,
                        enemy.row,
                        enemy.col,
                        {requirePositiveDamage = true}
                    )
                    if canDamage then
                        local damage = self:calculateDamage(enemy, targetUnit) or ZERO
                        if damage > ZERO then
                            summary.threateningAttackers = summary.threateningAttackers + ONE
                            summary.totalDamage = summary.totalDamage + damage
                            if damage > summary.maxDamage then
                                summary.maxDamage = damage
                            end
                            if damage >= hp then
                                summary.lethalAttackers = summary.lethalAttackers + ONE
                            end
                        end
                    end
                end
            end

            return summary
        end

        local function scoreAction(entry)
            if entry.type == "attack" then
                local damage = (entry.unit and entry.target) and self:calculateDamage(entry.unit, entry.target) or ZERO
                local targetValue = entry.target and (self:getUnitBaseValue(entry.target, state) or ZERO) or ZERO
                local targetHp = entry.target and (entry.target.currentHp or entry.target.startingHp or MIN_HP) or MIN_HP
                local lethal = damage >= targetHp
                local baseScore = lethal
                    and (12000 + (damage * 120) + (targetValue * TWO))
                    or (6200 + (damage * 90) + targetValue)

                local isRockAttack = self:isObstacleUnit(entry.target)
                entry.isRockAttack = isRockAttack
                if isRockAttack then
                    local rockStrategic, rockReason = self:isStrategicRockAttack(state, entry.action, {
                        aiPlayer = fallbackAiPlayer,
                        target = entry.target
                    })
                    entry.rockStrategic = rockStrategic == true
                    entry.rockStrategicReason = rockReason

                    if valueOr(rockDoctrine.ONLY_IF_STRATEGIC, true) and not rockStrategic then
                        baseScore = baseScore - (rockPenalty * TWO)
                    end
                    if valueOr(rockDoctrine.LAST_RESORT_ONLY, true) then
                        baseScore = baseScore - rockPenalty
                    end
                    if rockStrategic then
                        baseScore = baseScore + math.floor(rockPenalty * 0.35)
                    end
                end

                local backedAttackOk = true
                local backedContext = nil
                if not lethal and entry.action and entry.action.type == "attack" then
                    backedAttackOk, backedContext = self:isNonLethalAttackBacked(state, entry.action, {
                        horizonPlies = TWO
                    })
                end
                entry.unsupportedNonLethal = not backedAttackOk
                entry.backedAttackContext = backedContext
                if not backedAttackOk then
                    baseScore = baseScore - unsupportedPenalty
                end
                if preferDeployOrPosition and not lethal then
                    baseScore = baseScore - 1200
                end
                return baseScore
            elseif entry.type == "repair" then
                local target = entry.target
                local currentHp = target and (target.currentHp or target.startingHp or MIN_HP) or MIN_HP
                local maxHp = target and (target.startingHp or MIN_HP) or MIN_HP
                local healValue = math.max(ZERO, maxHp - currentHp)
                local targetValue = target and (self:getUnitBaseValue(target, state) or ZERO) or ZERO
                local exceptionPenalty = entry.mandatoryException and NEGATIVE_ONE or ZERO
                local doctrineBias = preferDeployOrPosition and 600 or ZERO
                return 7600 + doctrineBias + (healValue * 100) + targetValue + exceptionPenalty
            elseif entry.type == "move" then
                local unit = entry.unit
                if not unit or not entry.action or not entry.action.target then
                    return 7000
                end
                local tempUnit = {
                    row = entry.action.target.row,
                    col = entry.action.target.col,
                    name = unit.name,
                    player = unit.player,
                    currentHp = unit.currentHp,
                    startingHp = unit.startingHp
                }
                local currentScore = self:getPositionalValue(state, unit)
                local newScore = self:getPositionalValue(state, tempUnit)
                local doctrineBias = preferDeployOrPosition and 1200 or ZERO
                local score = 7000 + doctrineBias + (newScore - currentScore)

                local currentThreat = evaluateImmediateThreatAtPosition(state, unit)
                local movedThreat = evaluateImmediateThreatAtPosition(state, tempUnit)

                local threatPenalty = ZERO
                local lethalDelta = (movedThreat.lethalAttackers or ZERO) - (currentThreat.lethalAttackers or ZERO)
                if movedThreat.lethalAttackers > ZERO then
                    threatPenalty = threatPenalty + 1800 + (movedThreat.lethalAttackers * 450)
                end
                if lethalDelta > ZERO then
                    threatPenalty = threatPenalty + (lethalDelta * 800)
                end

                local damageDelta = (movedThreat.totalDamage or ZERO) - (currentThreat.totalDamage or ZERO)
                if damageDelta > ZERO then
                    threatPenalty = threatPenalty + (damageDelta * 120)
                end

                local attackerDelta = (movedThreat.threateningAttackers or ZERO) - (currentThreat.threateningAttackers or ZERO)
                if attackerDelta > ZERO then
                    threatPenalty = threatPenalty + (attackerDelta * 150)
                end

                score = score - threatPenalty
                return score
            elseif entry.type == "supply_deploy" then
                local doctrineBias = preferDeployOrPosition and 1400 or ZERO
                return 7000 + doctrineBias + (entry.action.score or ZERO)
            end
            return ZERO
        end

        self:sortScoredEntries(legalActions, {
            scoreFn = scoreAction,
            descending = true
        })

        return legalActions
    end

    function aiClass:simulateActionSequence(state, sequence)
        if not state then
            return nil
        end

        local simulatedState = self:deepCopyState(state)
        simulatedState.turnActionCount = simulatedState.turnActionCount or ZERO
        simulatedState.firstActionRangedAttack = simulatedState.firstActionRangedAttack

        for _, action in ipairs(sequence or {}) do
            if action and action.type == "supply_deploy" then
                simulatedState = self:applySupplyDeployment(simulatedState, action)
            elseif action and action.type ~= "skip" then
                simulatedState = self:applyMove(simulatedState, action)
            end
        end

        return simulatedState
    end

    function aiClass:getPlanProgressDistanceForState(state, aiPlayer)
        local planState = self.strategicPlanState or {}
        if not state or not aiPlayer or not planState.active then
            return nil
        end

        local objectiveCells = planState.objectiveCells or {}
        local assignments, _ = self:buildStrategicRoleAssignments(
            state,
            planState.roleAssignments or {},
            objectiveCells,
            aiPlayer
        )

        local totalDistance = ZERO
        local count = ZERO
        for unitKey, role in pairs(assignments or {}) do
            local unit = self:getUnitByKeyFromState(state, unitKey)
            local objective = objectiveCells[role]
            if unit and objective then
                totalDistance = totalDistance + math.abs(unit.row - objective.row) + math.abs(unit.col - objective.col)
                count = count + ONE
            end
        end

        if count <= ZERO then
            return nil
        end

        return totalDistance / count
    end

    function aiClass:buildVerifierStateMetrics(state, aiPlayer)
        local ownHub = state and state.commandHubs and state.commandHubs[aiPlayer] or nil
        local enemyPlayer = self:getOpponentPlayer(aiPlayer)
        local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer] or nil
        local values = self:getStateUnitValueTotals(state, aiPlayer)
        local friendlyUnitCount = ZERO
        local enemyUnitCount = ZERO
        for _, unit in ipairs((state and state.units) or {}) do
            if not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                if unit.player == aiPlayer then
                    friendlyUnitCount = friendlyUnitCount + ONE
                elseif unit.player == enemyPlayer then
                    enemyUnitCount = enemyUnitCount + ONE
                end
            end
        end

        return {
            ownHubHp = ownHub and (ownHub.currentHp or ownHub.startingHp or ZERO) or ZERO,
            enemyHubHp = enemyHub and (enemyHub.currentHp or enemyHub.startingHp or ZERO) or ZERO,
            friendlyValue = values.friendlyValue or ZERO,
            enemyValue = values.enemyValue or ZERO,
            materialDiff = values.materialDiff or ZERO,
            friendlyUnitCount = friendlyUnitCount,
            enemyUnitCount = enemyUnitCount,
            planDistance = self:getPlanProgressDistanceForState(state, aiPlayer)
        }
    end

    function aiClass:buildVerifierResponseCandidates(state, aiPlayer, responseK)
        if not state or not aiPlayer then
            return {}
        end

        local maxResponses = math.max(ONE, responseK or FOUR)
        local candidates = {}

        local function addCandidate(sequence, score, source)
            if not sequence or #sequence == ZERO then
                return
            end
            local signature = self:buildActionSequenceSignature(sequence)
            if signature == "" then
                return
            end
            candidates[#candidates + ONE] = {
                sequence = sequence,
                score = score or ZERO,
                source = source or "unknown",
                signature = signature
            }
        end

        local killCandidates = self:collectKillAttackCandidates(state, nil, {
            aiPlayer = aiPlayer,
            requireAttackSafe = false,
            allowBeneficialSuicide = true,
            checkFriendlyFire = true,
            allowHealerAttacks = true
        })
        for i = ONE, math.min(#killCandidates, maxResponses) do
            local candidate = killCandidates[i]
            addCandidate({candidate.action}, 4000 + (candidate.value or ZERO), "direct_kill")
        end

        local moveKillCandidates = self:collectKillAttackCandidates(state, nil, {
            aiPlayer = aiPlayer,
            moveThenAttack = true,
            requireAttackSafe = false,
            allowBeneficialSuicide = true,
            checkFriendlyFire = false,
            allowHealerAttacks = true
        })
        for i = ONE, math.min(#moveKillCandidates, maxResponses) do
            local candidate = moveKillCandidates[i]
            addCandidate(
                {candidate.moveAction, candidate.attackAction},
                4200 + (candidate.value or ZERO),
                "move_kill"
            )
        end

        local attackEntries = self:collectAttackTargetEntries(state, nil, {
            mode = "direct",
            aiPlayer = aiPlayer,
            includeFriendlyFireCheck = true,
            requirePositiveDamage = true,
            allowHealerAttacks = true
        })
        local directAttacks = {}
        for _, entry in ipairs(attackEntries) do
            local score = self:getCanonicalAttackScore(
                state,
                entry.unit,
                entry.target,
                entry.damage,
                {
                    includeTargetValue = true,
                    useBaseTargetValue = true
                }
            )
            directAttacks[#directAttacks + ONE] = {
                action = entry.action,
                score = score
            }
        end
        self:sortScoredEntries(directAttacks, {
            scoreField = "score",
            descending = true
        })
        for i = ONE, math.min(#directAttacks, maxResponses) do
            addCandidate({directAttacks[i].action}, 2000 + (directAttacks[i].score or ZERO), "direct_attack")
        end

        self:sortScoredEntries(candidates, {
            scoreField = "score",
            descending = true,
            secondaryField = "signature",
            secondaryDescending = false
        })

        local unique = {}
        local pruned = {}
        for _, candidate in ipairs(candidates) do
            if #pruned >= maxResponses then
                break
            end
            if not unique[candidate.signature] then
                unique[candidate.signature] = true
                pruned[#pruned + ONE] = candidate
            end
        end

        return pruned
    end

    function aiClass:collectSequenceCandidates(state, primarySequence, opts)
        if not state then
            return {}
        end

        local strategyConfig = self:getStrategyScoreConfig()
        local verifierConfig = strategyConfig.VERIFIER or {}
        local options = opts or {}
        local maxCandidates = math.max(ONE, valueOr(verifierConfig.MAX_CANDIDATES, 12))
        local variantTopK = math.max(ONE, valueOr(verifierConfig.TOP_K, SIX))
        local maxActions = valueOr(
            TURN_RULE_CONTRACT.ACTIONS_PER_TURN,
            valueOr(ACTION_RULE_CONTRACT.MANDATORY_ACTION_COUNT, valueOr(GAME.CONSTANTS.MAX_ACTIONS_PER_TURN, TWO))
        )
        local aiPlayer = self:getFactionId()

        local candidates = {}
        local seen = {}
        local primaryAttackCount = ZERO
        local primaryDefenseAttackCount = ZERO
        local defenseAttackTags = {
            STRATEGIC_DEFENSE_ATTACK = true,
            STRATEGIC_DEFENSE_DIRECT_ATTACK = true,
            COMMANDANT_THREAT_ATTACK = true
        }
        for _, action in ipairs(primarySequence or {}) do
            if action and action.type == "attack" then
                primaryAttackCount = primaryAttackCount + ONE
                if defenseAttackTags[action._aiTag] then
                    primaryDefenseAttackCount = primaryDefenseAttackCount + ONE
                end
            end
        end
        local intent = (self.strategicPlanState and self.strategicPlanState.intent) or nil
        local tempoContext = options.tempoContext or self:getPhaseTempoContext(state)
        local budgetHintMs = options.verifierBudgetMs
            or options.remainingDecisionBudgetMs
            or valueOr(verifierConfig.BUDGET_MS, 180)
        if budgetHintMs and budgetHintMs <= 80 then
            maxCandidates = math.min(maxCandidates, 3)
            variantTopK = math.min(variantTopK, ONE)
        elseif budgetHintMs and budgetHintMs <= 120 then
            maxCandidates = math.min(maxCandidates, 4)
            variantTopK = math.min(variantTopK, TWO)
        elseif budgetHintMs and budgetHintMs <= 160 then
            maxCandidates = math.min(maxCandidates, 6)
            variantTopK = math.min(variantTopK, THREE)
        end
        local doctrineConfig = self:getDoctrineScoreConfig()
        local phaseGuardConfig = doctrineConfig.VERIFIER_PHASE_GUARD or {}
        local earlyFallbackVariantLimit = math.max(
            ZERO,
            valueOr(phaseGuardConfig.EARLY_FALLBACK_VARIANT_LIMIT, ZERO)
        )
        local allowFallbackVariants = (primaryAttackCount <= ZERO)
        if intent == "DEFEND_HARD" and primaryDefenseAttackCount > ZERO then
            allowFallbackVariants = false
        end
        if tempoContext and tempoContext.phase == "early" and primaryAttackCount > ZERO and intent ~= "DEFEND_HARD" then
            allowFallbackVariants = earlyFallbackVariantLimit > ZERO
        end
        if tempoContext and tempoContext.phase == "early" then
            maxCandidates = math.min(maxCandidates, 5)
            variantTopK = math.min(variantTopK, earlyFallbackVariantLimit)
        end
        local sanitizeOpts = {
            aiPlayer = aiPlayer,
            maxActions = maxActions,
            allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
        }

        local function fillSequenceWithFallback(baseState, sequence, includeDeploy)
            local filled = {}
            for _, action in ipairs(sequence or {}) do
                filled[#filled + ONE] = deepCopyValue(action)
            end

            while #filled < maxActions do
                local simState = self:simulateActionSequence(baseState, filled)
                local fallback = self:getMandatoryFallbackCandidates(simState, {
                    aiPlayer = aiPlayer,
                    includeDeploy = includeDeploy ~= false,
                    allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
                })

                if fallback and #fallback > ZERO and fallback[ONE].action then
                    filled[#filled + ONE] = deepCopyValue(fallback[ONE].action)
                else
                    filled[#filled + ONE] = self:createSkipAction(baseState)
                end
            end

            return filled
        end

        local function addCandidate(sequence, source)
            if not sequence then
                return
            end
            local copied = deepCopyValue(sequence)
            local sanitized = self:sanitizeActionSequenceForState(state, copied, sanitizeOpts)
            if not sanitized or #sanitized == ZERO then
                return
            end
            local signature = self:buildActionSequenceSignature(sanitized)
            if signature == "" or seen[signature] then
                return
            end
            seen[signature] = true
            candidates[#candidates + ONE] = {
                sequence = sanitized,
                signature = signature,
                source = source or "candidate"
            }
        end

        local primary = fillSequenceWithFallback(state, primarySequence or {}, true)
        addCandidate(primary, "primary")

        local hasDeploy = false
        for _, action in ipairs(primarySequence or {}) do
            if action and action.type == "supply_deploy" then
                hasDeploy = true
                break
            end
        end
        if hasDeploy then
            local noDeploySeq = {}
            for _, action in ipairs(primarySequence or {}) do
                if action and action.type ~= "supply_deploy" then
                    noDeploySeq[#noDeploySeq + ONE] = deepCopyValue(action)
                end
            end
            noDeploySeq = fillSequenceWithFallback(state, noDeploySeq, false)
            addCandidate(noDeploySeq, "no_deploy_variant")
        end

        for i = ONE, math.max(ZERO, #primarySequence - ONE) do
            local first = primarySequence[i]
            local second = primarySequence[i + ONE]
            if first and second
                and first.type == "move"
                and second.type == "attack"
                and first.target
                and second.unit
                and first.target.row == second.unit.row
                and first.target.col == second.unit.col then
                local targetPos = second.target
                local directEntries = self:collectAttackTargetEntries(state, nil, {
                    mode = "direct",
                    aiPlayer = aiPlayer,
                    includeFriendlyFireCheck = true,
                    requirePositiveDamage = true,
                    allowHealerAttacks = self:shouldHealerBeOffensive(state, {allowEmergencyDefense = true})
                })
                local bestDirect = nil
                for _, entry in ipairs(directEntries) do
                    if entry.target and targetPos
                        and entry.target.row == targetPos.row
                        and entry.target.col == targetPos.col then
                        local targetHp = entry.targetHp or (entry.target.currentHp or entry.target.startingHp or MIN_HP)
                        local lethal = (entry.damage or ZERO) >= targetHp
                        local score = (entry.damage or ZERO) * 1000 + (lethal and 100000 or ZERO)
                        if (not bestDirect) or score > (bestDirect.score or ZERO) then
                            bestDirect = {
                                action = entry.action,
                                score = score
                            }
                        end
                    end
                end

                if bestDirect and bestDirect.action then
                    local variant = {}
                    for idx, action in ipairs(primarySequence or {}) do
                        if idx == i then
                            variant[#variant + ONE] = deepCopyValue(bestDirect.action)
                        elseif idx ~= (i + ONE) then
                            variant[#variant + ONE] = deepCopyValue(action)
                        end
                    end
                    variant = fillSequenceWithFallback(state, variant, true)
                    addCandidate(variant, "direct_over_move")
                end
            end
        end

        if allowFallbackVariants then
            local fallbackCandidates = self:getMandatoryFallbackCandidates(state, {
                aiPlayer = aiPlayer,
                allowFullHpHealerRepairException = ACTION_RULE_CONTRACT.HEALER_FULL_HP_REPAIR_EXCEPTION == true
            })
            local primaryFirst = primarySequence and primarySequence[ONE] or nil
            local variantsAdded = ZERO
            for _, candidate in ipairs(fallbackCandidates or {}) do
                if variantsAdded >= variantTopK then
                    break
                end
                if candidate.action and ((not primaryFirst) or (not self:isActionEquivalent(candidate.action, primaryFirst))) then
                    local variant = fillSequenceWithFallback(state, {candidate.action}, true)
                    addCandidate(variant, "fallback_variant")
                    variantsAdded = variantsAdded + ONE
                end
            end
        end

        table.sort(candidates, function(a, b)
            return tostring(a.signature or "") < tostring(b.signature or "")
        end)

        while #candidates > maxCandidates do
            table.remove(candidates)
        end

        return candidates
    end

    function aiClass:scoreSequenceTwoPly(state, sequence, responseK, opts)
        local options = opts or {}
        local deadlineSeconds = options.deadlineSeconds
        local aiPlayer = self:getFactionId()
        if not state or not aiPlayer then
            return -math.huge, {
                timeout = false
            }
        end

        local tempoContext = self:getPhaseTempoContext(state)
        local baseMetrics = self:buildVerifierStateMetrics(state, aiPlayer)
        local afterState = self:simulateActionSequence(state, sequence or {})
        local afterMetrics = self:buildVerifierStateMetrics(afterState, aiPlayer)

        local function computeComposite(metrics)
            local hubSafetyDelta = ((metrics.ownHubHp - baseMetrics.ownHubHp) * 90)
                + ((baseMetrics.enemyHubHp - metrics.enemyHubHp) * 110)
            local exchangeDelta = (metrics.materialDiff - baseMetrics.materialDiff)
            local unitValueDelta = (metrics.friendlyValue - baseMetrics.friendlyValue)
            local planProgressDelta = ZERO
            if baseMetrics.planDistance and metrics.planDistance then
                planProgressDelta = baseMetrics.planDistance - metrics.planDistance
            end
            local closeoutDelta = ZERO
            if tempoContext and tempoContext.phase == "end" then
                local chosenPath = tempoContext.endgamePath or "hub"
                if chosenPath == "wipe" then
                    closeoutDelta = ((baseMetrics.enemyUnitCount or ZERO) - (metrics.enemyUnitCount or ZERO)) * 180
                        + ((baseMetrics.enemyHubHp or ZERO) - (metrics.enemyHubHp or ZERO)) * 25
                else
                    closeoutDelta = ((baseMetrics.enemyHubHp or ZERO) - (metrics.enemyHubHp or ZERO)) * 180
                        + ((baseMetrics.enemyUnitCount or ZERO) - (metrics.enemyUnitCount or ZERO)) * 30
                end
            end
            local composite = hubSafetyDelta
                + (exchangeDelta * FIVE)
                + (unitValueDelta * TWO)
                + (planProgressDelta * 35)
                + closeoutDelta
            return composite, {
                hubSafetyDelta = hubSafetyDelta,
                exchangeDelta = exchangeDelta,
                unitValueDelta = unitValueDelta,
                planProgressDelta = planProgressDelta,
                closeoutDelta = closeoutDelta
            }
        end

        local bestScoreAfterMove, baseComponents = computeComposite(afterMetrics)
        local worstScore = bestScoreAfterMove
        local worstResponseSignature = nil
        local responseCandidates = self:buildVerifierResponseCandidates(
            afterState,
            self:getOpponentPlayer(aiPlayer),
            responseK
        )

        for _, response in ipairs(responseCandidates) do
            if deadlineSeconds and getMonotonicTimeSeconds() > deadlineSeconds then
                return -math.huge, {
                    timeout = true
                }
            end

            local responseState = self:simulateActionSequence(afterState, response.sequence)
            local responseMetrics = self:buildVerifierStateMetrics(responseState, aiPlayer)
            local responseScore = computeComposite(responseMetrics)
            if responseScore < worstScore then
                worstScore = responseScore
                worstResponseSignature = response.signature
            end
        end

        return worstScore, {
            timeout = false,
            baseComponents = baseComponents,
            responseCount = #responseCandidates,
            worstResponseSignature = worstResponseSignature
        }
    end

    function aiClass:selectVerifiedSequence(state, candidates, budgetMs)
        local list = candidates or {}
        if #list == ZERO then
            return nil, {timedOut = false, evaluated = ZERO}
        end

        local strategyConfig = self:getStrategyScoreConfig()
        local verifierConfig = strategyConfig.VERIFIER or {}
        local budget = math.max(10, budgetMs or valueOr(verifierConfig.BUDGET_MS, 180))
        local responseK = math.max(ONE, valueOr(verifierConfig.RESPONSE_K, FOUR))
        local tempoContext = self:getPhaseTempoContext(state)
        if budget <= 90 then
            responseK = math.min(responseK, TWO)
        elseif budget <= 140 then
            responseK = math.min(responseK, THREE)
        end
        if tempoContext and tempoContext.phase == "early" then
            responseK = math.min(responseK, THREE)
        end

        local maxEvaluate = #list
        if budget <= 80 then
            maxEvaluate = math.min(maxEvaluate, TWO)
        elseif budget <= 120 then
            maxEvaluate = math.min(maxEvaluate, THREE)
        elseif budget <= 170 then
            maxEvaluate = math.min(maxEvaluate, FOUR)
        else
            maxEvaluate = math.min(maxEvaluate, math.max(TWO, valueOr(verifierConfig.TOP_K, SIX)))
        end

        local sourcePriority = {
            primary = 0,
            direct_over_move = 1,
            no_deploy_variant = 2,
            fallback_variant = 3
        }
        local evalList = {}
        for _, candidate in ipairs(list) do
            evalList[#evalList + ONE] = candidate
        end
        table.sort(evalList, function(a, b)
            local aRank = sourcePriority[a.source or "fallback_variant"] or 9
            local bRank = sourcePriority[b.source or "fallback_variant"] or 9
            if aRank == bRank then
                local aAttacks = ZERO
                local bAttacks = ZERO
                for _, action in ipairs(a.sequence or {}) do
                    if action and action.type == "attack" then
                        aAttacks = aAttacks + ONE
                    end
                end
                for _, action in ipairs(b.sequence or {}) do
                    if action and action.type == "attack" then
                        bAttacks = bAttacks + ONE
                    end
                end
                if aAttacks == bAttacks then
                    return tostring(a.signature or "") < tostring(b.signature or "")
                end
                return aAttacks > bAttacks
            end
            return aRank < bRank
        end)
        while #evalList > maxEvaluate do
            table.remove(evalList)
        end

        local deadline = getMonotonicTimeSeconds() + (budget / 1000)
        local bestCandidate = nil
        local primaryCandidate = nil
        local timedOut = false
        local evaluated = ZERO

        for _, candidate in ipairs(evalList) do
            if getMonotonicTimeSeconds() > deadline then
                timedOut = true
                break
            end

            local score, details = self:scoreSequenceTwoPly(state, candidate.sequence, responseK, {
                deadlineSeconds = deadline
            })
            if details and details.timeout then
                timedOut = true
                break
            end

            evaluated = evaluated + ONE
            candidate.verifiedScore = score
            candidate.verifiedDetails = details
            if candidate.source == "primary" then
                primaryCandidate = candidate
            end

            if (not bestCandidate)
                or (candidate.verifiedScore > (bestCandidate.verifiedScore or -math.huge))
                or (candidate.verifiedScore == (bestCandidate.verifiedScore or -math.huge)
                    and tostring(candidate.signature or "") < tostring(bestCandidate.signature or "")) then
                bestCandidate = candidate
            end
        end

        if timedOut then
            self.verifierTimeoutCount = (self.verifierTimeoutCount or ZERO) + ONE
        end

        if not bestCandidate then
            bestCandidate = evalList[ONE] or list[ONE]
        end
        if not primaryCandidate then
            for _, candidate in ipairs(list) do
                if candidate.source == "primary" then
                    primaryCandidate = candidate
                    break
                end
            end
        end

        return bestCandidate and deepCopyValue(bestCandidate.sequence) or nil, {
            timedOut = timedOut,
            evaluated = evaluated,
            considered = #evalList,
            bestSignature = bestCandidate and bestCandidate.signature or nil,
            bestScore = bestCandidate and bestCandidate.verifiedScore or nil,
            bestSource = bestCandidate and bestCandidate.source or nil,
            primarySignature = primaryCandidate and primaryCandidate.signature or nil,
            primaryScore = primaryCandidate and primaryCandidate.verifiedScore or nil
        }
    end

    function aiClass:getSetupScoreConfig()
        return self:getScoreConfig().SETUP or {}
    end

    function aiClass:getKillRiskScoreConfig()
        return self:getScoreConfig().KILL_RISK or {}
    end

    function aiClass:getWinningScoreConfig()
        return self:getScoreConfig().WINNING or {}
    end

    function aiClass:getMobilityScoreConfig()
        local scoreConfig = self:getScoreConfig()
        if scoreConfig.MOBILITY then
            return scoreConfig.MOBILITY
        end
        return DEFAULT_SCORE_PARAMS.MOBILITY or {}
    end

    function aiClass:getSupplyEvalScoreConfig()
        local scoreConfig = self:getScoreConfig()
        if scoreConfig.SUPPLY_EVAL then
            return scoreConfig.SUPPLY_EVAL
        end
        return DEFAULT_SCORE_PARAMS.SUPPLY_EVAL or {}
    end

    function aiClass:getOpponentPlayer(playerId)
        local player = playerId or self:getFactionId()
        if not player then
            return nil
        end
        return PLAYER_INDEX_SUM - player
    end

    function aiClass:getSupportFollowUpConfig()
        local mobility = self:getMobilityScoreConfig()
        return mobility.SUPPORT_FOLLOW_UP or {}
    end

    function aiClass:getProfileThreatWeight()
        local positionalConfig = self:getPositionalScoreConfig()
        local defaultPositionalConfig = DEFAULT_SCORE_PARAMS.POSITIONAL or {}
        return valueOr(positionalConfig.THREAT_WEIGHT, valueOr(defaultPositionalConfig.THREAT_WEIGHT, ONE))
    end

    function aiClass:getPositionalComponentWeights()
        local positionalConfig = self:getPositionalScoreConfig()
        local weights = positionalConfig.COMPONENT_WEIGHTS
        if type(weights) ~= "table" then
            weights = DEFAULT_POSITIONAL_COMPONENT_WEIGHTS
        end

        return {
            improvement = valueOr(weights.IMPROVEMENT, DEFAULT_POSITIONAL_COMPONENT_WEIGHTS.IMPROVEMENT),
            repair = valueOr(weights.REPAIR, DEFAULT_POSITIONAL_COMPONENT_WEIGHTS.REPAIR),
            threat = valueOr(weights.THREAT, DEFAULT_POSITIONAL_COMPONENT_WEIGHTS.THREAT),
            offensive = valueOr(weights.OFFENSIVE, DEFAULT_POSITIONAL_COMPONENT_WEIGHTS.OFFENSIVE),
            forwardPressure = valueOr(weights.FORWARD_PRESSURE, DEFAULT_POSITIONAL_COMPONENT_WEIGHTS.FORWARD_PRESSURE)
        }
    end

end

return M
