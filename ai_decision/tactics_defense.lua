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
    function aiClass:findLastAttackForDoomedUnits(state, usedUnits, opts)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        if not state or not state.units or not state.commandHubs then
            return {}
        end
        local options = opts or {}
        local requireLethalOnly = options.requireLethalOnly == true
        local includeFinishers = options.includeFinishers ~= false
        local ownHub = state.commandHubs[aiPlayer]
        local lastAttackCandidates = {}


        -- Find AI units that will die next turn but can still attack
        for _, unit in ipairs(state.units) do
            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits) then
                -- Check if unit will die next turn
                local willDie = self:wouldUnitDieNextTurn(state, unit)

                if willDie then

                    -- Find all enemies this unit can attack without moving
                    local attackCells = self:getValidAttackCells(state, unit.row, unit.col)

                    for _, attackCell in ipairs(attackCells) do
                        local target = self:getUnitAtPosition(state, attackCell.row, attackCell.col)
                        if self:isAttackableEnemyUnit(target, aiPlayer, {excludeHub = true}) then
                            -- Calculate damage and check for special abilities
                            local damage, specialUsed = unitsInfo:calculateAttackDamage(unit, target)

                            -- Check if target would have 1 HP remaining after attack
                            local targetCurrentHp = target.currentHp or ZERO
                            local wouldLeaveAt1HP = (targetCurrentHp - damage) == ONE

                            if self:isDoomedEliminationAttack(damage, targetCurrentHp, specialUsed, wouldLeaveAt1HP, {
                                requireLethalOnly = requireLethalOnly,
                                includeFinishers = includeFinishers
                            }) then
                                local priority, distToOwnHub = self:getDoomedAttackPriority(
                                    state,
                                    ownHub,
                                    unit,
                                    target,
                                    damage,
                                    specialUsed,
                                    wouldLeaveAt1HP,
                                    nil,
                                    targetCurrentHp
                                )

                                local attackAction = {
                                    type = "attack",
                                    unit = {row = unit.row, col = unit.col},
                                    target = {row = target.row, col = target.col}
                                }

                                table.insert(lastAttackCandidates, {
                                    unit = unit,
                                    target = target,
                                    action = attackAction,
                                    damage = damage,
                                    specialUsed = specialUsed,
                                    wouldLeaveAt1HP = wouldLeaveAt1HP,
                                    distToOwnHub = distToOwnHub,
                                    priority = priority
                                })
                            end
                        end
                    end
                end
            end
        end

        -- Sort by priority (highest damage, special ability use, leaves at 1HP, closest to own hub)
        self:sortScoredEntries(lastAttackCandidates, {
            scoreField = "priority",
            descending = true
        })

        if #lastAttackCandidates > ZERO then
            local bestAttack = lastAttackCandidates[ONE]
            return bestAttack
        end

        return nil
    end

    function aiClass:getUncounteredThreatNearCommandant(state, usedUnits, aiPlayer)
        aiPlayer = aiPlayer or self:getFactionId()
        if not aiPlayer or not state or not state.commandHubs then
            return nil
        end

        local ownHub = state.commandHubs[aiPlayer]
        if not ownHub then
            return nil
        end

        local function allyIsAvailable(ally)
            return self:isUnitEligibleForAction(ally, aiPlayer, usedUnits, {
                requireNotActed = true,
                requireNotMoved = false,
                disallowCommandant = true,
                requireAlive = true
            })
        end

        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, aiPlayer) then
                local dist = math.abs(enemy.row - ownHub.row) + math.abs(enemy.col - ownHub.col)
                if dist <= THREE then
                    local canBeDamaged = false
                    for _, ally in ipairs(state.units or {}) do
                        if allyIsAvailable(ally) then
                            canBeDamaged = self:canUnitDamageTargetFromPosition(
                                state,
                                ally,
                                enemy,
                                ally.row,
                                ally.col,
                                {requirePositiveDamage = true}
                            )

                            if not canBeDamaged then
                                local moveCells = self:getValidMoveCells(state, ally.row, ally.col) or {}
                                for _, moveCell in ipairs(moveCells) do
                                    local moveOk = self:isOpenSafeMoveCell(state, ally, moveCell)
                                    if not moveOk then
                                        goto continue_move_check
                                    end

                                    local simState, simUnit = self:simulateUnitMoveState(state, ally, moveCell, {validate = true})
                                    simUnit = simUnit or {
                                        row = moveCell.row,
                                        col = moveCell.col,
                                        name = ally.name,
                                        player = ally.player,
                                        currentHp = ally.currentHp,
                                        startingHp = ally.startingHp
                                    }

                                    canBeDamaged = self:canUnitDamageTargetFromPosition(
                                        simState,
                                        simUnit,
                                        enemy,
                                        moveCell.row,
                                        moveCell.col,
                                        {requirePositiveDamage = true}
                                    )

                                    if canBeDamaged then
                                        break
                                    end

                                    ::continue_move_check::
                                end
                            end
                        end
                        if canBeDamaged then
                            break
                        end
                    end
                    if not canBeDamaged then
                        return enemy
                    end
                end
            end
        end

        return nil
    end

    function aiClass:findCommandantDefenseUnblockMove(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state or not state.commandHubs then
            return nil
        end

        local ownHub = state.commandHubs[aiPlayer]
        if not ownHub then
            return nil
        end

        local unblockConfig = self:getCommandantDefenseUnblockScoreConfig()
        local defaultUnblockConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_DEFENSE_UNBLOCK or {}
        local enabled = valueOr(unblockConfig.ENABLED, valueOr(defaultUnblockConfig.ENABLED, true))
        if not enabled then
            return nil
        end

        local threatUnit = self:getUncounteredThreatNearCommandant(state, usedUnits, aiPlayer)
        if not threatUnit then
            return nil
        end

        local blockerMaxHubDistance = valueOr(
            unblockConfig.BLOCKER_MAX_HUB_DISTANCE,
            valueOr(defaultUnblockConfig.BLOCKER_MAX_HUB_DISTANCE, TWO)
        )
        local checkVulnerableMove = valueOr(
            unblockConfig.CHECK_VULNERABLE_MOVE,
            valueOr(defaultUnblockConfig.CHECK_VULNERABLE_MOVE, true)
        )
        local counterLookaheadTurns = math.max(
            ONE,
            valueOr(
                unblockConfig.COUNTER_LOOKAHEAD_TURNS,
                valueOr(defaultUnblockConfig.COUNTER_LOOKAHEAD_TURNS, TWO)
            )
        )
        local freeCellGainBonus = valueOr(
            unblockConfig.FREE_CELL_GAIN_BONUS,
            valueOr(defaultUnblockConfig.FREE_CELL_GAIN_BONUS, ZERO)
        )
        local enableCounterNowBonus = valueOr(
            unblockConfig.ENABLE_COUNTER_NOW_BONUS,
            valueOr(defaultUnblockConfig.ENABLE_COUNTER_NOW_BONUS, ZERO)
        )
        local enableCounterSoonBonus = valueOr(
            unblockConfig.ENABLE_COUNTER_SOON_BONUS,
            valueOr(defaultUnblockConfig.ENABLE_COUNTER_SOON_BONUS, ZERO)
        )
        local hubRingExitBonus = valueOr(
            unblockConfig.HUB_RING_EXIT_BONUS,
            valueOr(defaultUnblockConfig.HUB_RING_EXIT_BONUS, ZERO)
        )
        local hubDistanceGainBonus = valueOr(
            unblockConfig.HUB_DISTANCE_GAIN_BONUS,
            valueOr(defaultUnblockConfig.HUB_DISTANCE_GAIN_BONUS, ZERO)
        )
        local moveDistancePenalty = valueOr(
            unblockConfig.MOVE_DISTANCE_PENALTY,
            valueOr(defaultUnblockConfig.MOVE_DISTANCE_PENALTY, ZERO)
        )
        local stayAdjHubPenalty = valueOr(
            unblockConfig.STAY_ADJ_HUB_PENALTY,
            valueOr(defaultUnblockConfig.STAY_ADJ_HUB_PENALTY, ZERO)
        )
        local exposurePenaltyScale = valueOr(
            unblockConfig.EXPOSURE_PENALTY_SCALE,
            valueOr(defaultUnblockConfig.EXPOSURE_PENALTY_SCALE, ZERO)
        )
        local minScore = valueOr(
            unblockConfig.MIN_SCORE,
            valueOr(defaultUnblockConfig.MIN_SCORE, ZERO)
        )

        local function isExcludedUnit(unit, excludedPos)
            if not excludedPos then
                return false
            end
            return unit
                and unit.player == excludedPos.player
                and unit.name == excludedPos.name
                and unit.row == excludedPos.row
                and unit.col == excludedPos.col
        end

        local function canDefenderPressureThreat(boardState, defender, allowMove)
            if self:canUnitDamageTargetFromPosition(
                boardState,
                defender,
                threatUnit,
                defender.row,
                defender.col,
                {requirePositiveDamage = true}
            ) then
                return true, true, ONE
            end

            if not allowMove or defender.hasMoved then
                local threatTurn = self:getUnitThreatTiming(
                    boardState,
                    defender,
                    threatUnit,
                    counterLookaheadTurns,
                    {
                        considerCurrentActionState = true,
                        allowMoveOnFirstTurn = false,
                        requirePositiveDamage = true
                    }
                )
                if threatTurn then
                    return true, false, threatTurn
                end
                return false, false, nil
            end

            local moveCells = self:getValidMoveCells(boardState, defender.row, defender.col) or {}
            for _, moveCell in ipairs(moveCells) do
                local moveOk = self:isOpenSafeMoveCell(boardState, defender, moveCell, {
                    checkVulnerable = checkVulnerableMove
                })
                if moveOk then
                    local simState, simUnit = self:simulateUnitMoveState(boardState, defender, moveCell, {validate = true})
                    local projectedDefender = simUnit or self:buildProjectedThreatUnit(defender, moveCell.row, moveCell.col) or defender
                    if self:canUnitDamageTargetFromPosition(
                        simState,
                        projectedDefender,
                        threatUnit,
                        moveCell.row,
                        moveCell.col,
                        {requirePositiveDamage = true}
                    ) then
                        return true, false, ONE
                    end
                end
            end

            local threatTurn = self:getUnitThreatTiming(
                boardState,
                defender,
                threatUnit,
                counterLookaheadTurns,
                {
                    considerCurrentActionState = true,
                    allowMoveOnFirstTurn = true,
                    requirePositiveDamage = true
                }
            )
            if threatTurn then
                return true, false, threatTurn
            end

            return false, false, nil
        end

        local function countThreatResponders(boardState, excludedPos)
            local directCount = ZERO
            local moveCount = ZERO
            local soonCount = ZERO

            for _, ally in ipairs(boardState.units or {}) do
                if not isExcludedUnit(ally, excludedPos) and self:isUnitEligibleForAction(ally, aiPlayer, usedUnits, {
                    requireNotActed = true,
                    requireNotMoved = false,
                    disallowCommandant = true,
                    requireAlive = true
                }) then
                    local canRespond, isDirect, threatTurn = canDefenderPressureThreat(boardState, ally, true)
                    if canRespond then
                        if threatTurn and threatTurn > ONE then
                            soonCount = soonCount + ONE
                        elseif isDirect then
                            directCount = directCount + ONE
                        else
                            moveCount = moveCount + ONE
                        end
                    end
                end
            end

            return directCount, moveCount, soonCount
        end

        local freeBefore = #self:getFreeCellsAroundHub(state, ownHub, true)
        local bestCandidate = nil
        local bestScore = -math.huge

        for _, blocker in ipairs(state.units or {}) do
            if self:isUnitEligibleForAction(blocker, aiPlayer, usedUnits, {
                requireNotActed = true,
                requireNotMoved = true,
                disallowCommandant = true,
                requireAlive = true
            }) then
                local blockerDistToHub = math.abs(blocker.row - ownHub.row) + math.abs(blocker.col - ownHub.col)
                if blockerDistToHub <= blockerMaxHubDistance then
                    local blockerCanRespond = canDefenderPressureThreat(state, blocker, true)
                    if not blockerCanRespond then
                        local excludedBefore = {
                            player = blocker.player,
                            name = blocker.name,
                            row = blocker.row,
                            col = blocker.col
                        }
                        local beforeDirect, beforeMove, beforeSoon = countThreatResponders(state, excludedBefore)
                        local beforeTotal = beforeDirect + beforeMove + beforeSoon

                        local moveCells = self:getValidMoveCells(state, blocker.row, blocker.col) or {}
                        for _, moveCell in ipairs(moveCells) do
                            local moveOk = self:isOpenSafeMoveCell(state, blocker, moveCell, {
                                checkVulnerable = checkVulnerableMove
                            })
                            if moveOk then
                                local simState = self:simulateUnitMoveState(state, blocker, moveCell, {validate = true})
                                local excludedAfter = {
                                    player = blocker.player,
                                    name = blocker.name,
                                    row = moveCell.row,
                                    col = moveCell.col
                                }
                                local afterDirect, afterMove, afterSoon = countThreatResponders(simState, excludedAfter)
                                local afterTotal = afterDirect + afterMove + afterSoon
                                local freeAfter = #self:getFreeCellsAroundHub(simState, ownHub, true)
                                local freeGain = math.max(ZERO, freeAfter - freeBefore)

                                local newlyEnabledTotal = math.max(ZERO, afterTotal - beforeTotal)
                                local newlyEnabledDirect = math.max(ZERO, afterDirect - beforeDirect)
                                local newlyEnabledMove = math.max(ZERO, afterMove - beforeMove)
                                local newlyEnabledSoon = math.max(ZERO, afterSoon - beforeSoon)

                                local moveDistance = math.abs(blocker.row - moveCell.row) + math.abs(blocker.col - moveCell.col)
                                local newDistToHub = math.abs(moveCell.row - ownHub.row) + math.abs(moveCell.col - ownHub.col)
                                local hubDistanceGain = math.max(ZERO, newDistToHub - blockerDistToHub)
                                local ringExit = (blockerDistToHub == ONE and newDistToHub > ONE) and ONE or ZERO
                                local exposurePenalty = ZERO
                                if exposurePenaltyScale > ZERO then
                                    exposurePenalty = math.floor(
                                        self:calculateCommanderExposurePenalty(state, blocker, moveCell) * exposurePenaltyScale
                                    )
                                end

                                local score = ZERO
                                score = score + (freeGain * freeCellGainBonus)
                                score = score + (newlyEnabledDirect * enableCounterNowBonus)
                                score = score + ((newlyEnabledMove + newlyEnabledSoon) * enableCounterSoonBonus)
                                score = score + (ringExit * hubRingExitBonus)
                                score = score + (hubDistanceGain * hubDistanceGainBonus)
                                score = score - (moveDistance * moveDistancePenalty)
                                score = score - exposurePenalty
                                if newDistToHub <= ONE then
                                    score = score - stayAdjHubPenalty
                                end
                                local patternPenalty = self:getRepeatedLowImpactPatternPenalty(state, blocker, moveCell, aiPlayer)
                                if patternPenalty > ZERO then
                                    score = score - math.min(patternPenalty, 220)
                                end

                                local createsRealDefensiveOptions = (freeGain > ZERO)
                                    or (newlyEnabledDirect > ZERO)
                                    or (newlyEnabledMove > ZERO)
                                    or (newlyEnabledSoon > ZERO)
                                if createsRealDefensiveOptions and score >= minScore and score > bestScore then
                                    bestScore = score
                                    bestCandidate = {
                                        unit = blocker,
                                        action = {
                                            type = "move",
                                            unit = {row = blocker.row, col = blocker.col},
                                            target = {row = moveCell.row, col = moveCell.col}
                                        },
                                        score = score,
                                        freeGain = freeGain,
                                        newlyEnabledDirect = newlyEnabledDirect,
                                        newlyEnabledMove = newlyEnabledMove,
                                        newlyEnabledSoon = newlyEnabledSoon,
                                        threatTarget = {
                                            row = threatUnit.row,
                                            col = threatUnit.col,
                                            name = threatUnit.name
                                        }
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end

        return bestCandidate
    end

    function aiClass:findEmergencyDefensiveSupply(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end

        if not state or not state.supply or not state.supply[aiPlayer] or #state.supply[aiPlayer] == ZERO then
            return nil
        end

        local threatUnit = self:getUncounteredThreatNearCommandant(state, usedUnits, aiPlayer)
        if not threatUnit then
            return nil
        end

        return self:findEnhancedSupplyDeployment(state, usedUnits)
    end

    function aiClass:findThreatCounterAttackMove(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state or not state.commandHubs then
            return nil
        end

        local threatUnit = self:getUncounteredThreatNearCommandant(state, usedUnits, aiPlayer)
        if not threatUnit then
            return nil
        end

        local bestCandidate = nil
        local bestScore = -math.huge
        local counterConfig = self:getThreatCounterConfig()
        local defaultCounterConfig = DEFAULT_SCORE_PARAMS.THREAT_COUNTER or {}
        local lookaheadTurns = math.max(
            ONE,
            valueOr(counterConfig.LOOKAHEAD_TURNS, valueOr(defaultCounterConfig.LOOKAHEAD_TURNS, TWO))
        )
        local maxThreatTurn = math.max(
            ONE,
            valueOr(counterConfig.MAX_THREAT_TURN, valueOr(defaultCounterConfig.MAX_THREAT_TURN, TWO))
        )
        local frontierMax = math.max(
            ONE,
            valueOr(counterConfig.FRONTIER_MAX, valueOr(defaultCounterConfig.FRONTIER_MAX, 24))
        )
        local lookaheadBonusConfig = counterConfig.LOOKAHEAD_BONUS or {}
        local defaultLookaheadBonusConfig = defaultCounterConfig.LOOKAHEAD_BONUS or {}
        local nowBonus = valueOr(lookaheadBonusConfig.NOW, valueOr(defaultLookaheadBonusConfig.NOW, ZERO))
        local nextBonus = valueOr(lookaheadBonusConfig.NEXT, valueOr(defaultLookaheadBonusConfig.NEXT, ZERO))
        local lateBonus = valueOr(lookaheadBonusConfig.LATE, valueOr(defaultLookaheadBonusConfig.LATE, ZERO))

        local function allyEligible(ally)
            return self:isUnitEligibleForAction(ally, aiPlayer, usedUnits, {
                requireNotActed = true,
                requireNotMoved = true,
                disallowCommandant = true,
                requireAlive = true
            })
        end

        for _, ally in ipairs(state.units or {}) do
            if allyEligible(ally) then
                local moveCells = self:getValidMoveCells(state, ally.row, ally.col) or {}
                for _, moveCell in ipairs(moveCells) do
                    if self:unitHasTag(ally, "ranged")
                        and (not unitsInfo:canAttackAdjacent(ally.name))
                        and (math.abs(moveCell.row - threatUnit.row) + math.abs(moveCell.col - threatUnit.col) == ONE) then
                        goto continue_counter_move
                    end

                    local moveOk = self:isOpenSafeMoveCell(state, ally, moveCell)
                    if moveOk then
                        local simState, simUnit = self:simulateUnitMoveState(state, ally, moveCell, {validate = true})
                        local projectedUnit = simUnit or self:buildProjectedThreatUnit(ally, moveCell.row, moveCell.col) or ally
                        projectedUnit.hasMoved = true
                        projectedUnit.hasActed = ally.hasActed or false

                        local canPressureNow = self:canUnitDamageTargetFromPosition(
                            simState,
                            projectedUnit,
                            threatUnit,
                            moveCell.row,
                            moveCell.col,
                            {requirePositiveDamage = true}
                        )

                        local threatTurn, threatMode = nil, nil
                        if canPressureNow then
                            threatTurn = ONE
                            threatMode = "direct"
                        else
                            threatTurn, threatMode = self:getUnitThreatTiming(
                                simState,
                                projectedUnit,
                                threatUnit,
                                lookaheadTurns,
                                {
                                    considerCurrentActionState = true,
                                    allowMoveOnFirstTurn = false,
                                    requirePositiveDamage = true,
                                    maxFrontierNodes = frontierMax
                                }
                            )
                        end

                        if threatTurn and threatTurn <= maxThreatTurn then
                            local threatDist = math.abs(moveCell.row - threatUnit.row) + math.abs(moveCell.col - threatUnit.col)
                            local unitValue = self:getUnitBaseValue(ally, state) or ZERO
                            local positionalBonus = valueOr(counterConfig.BASE, defaultCounterConfig.BASE)
                                - (threatDist * valueOr(counterConfig.DISTANCE_PENALTY, defaultCounterConfig.DISTANCE_PENALTY))
                            local bonusByTag = counterConfig.BONUS_BY_TAG or {}
                            local defaultCounterBonusByTag = defaultCounterConfig.BONUS_BY_TAG or {}
                            if self:unitHasTag(ally, "tank") then
                                positionalBonus = positionalBonus + valueOr(bonusByTag.tank, defaultCounterBonusByTag.tank)
                            elseif self:unitHasTag(ally, "corvette") then
                                positionalBonus = positionalBonus + valueOr(bonusByTag.corvette, defaultCounterBonusByTag.corvette)
                            end

                            local lookaheadBonus = ZERO
                            if threatTurn == ONE then
                                lookaheadBonus = nowBonus
                            elseif threatTurn == TWO then
                                lookaheadBonus = nextBonus
                            else
                                lookaheadBonus = lateBonus
                            end

                            local score = unitValue + positionalBonus
                            score = score + lookaheadBonus
                            local patternPenalty = self:getRepeatedLowImpactPatternPenalty(state, ally, moveCell, aiPlayer)
                            if patternPenalty > ZERO then
                                score = score - math.min(patternPenalty, 180)
                            end
                            if score > bestScore then
                                bestScore = score
                                bestCandidate = {
                                    unit = ally,
                                    action = {
                                        type = "move",
                                        unit = {row = ally.row, col = ally.col},
                                        target = {row = moveCell.row, col = moveCell.col},
                                        threatTarget = {row = threatUnit.row, col = threatUnit.col}
                                    },
                                    threatTurn = threatTurn,
                                    threatMode = threatMode
                                }
                            end
                        end
                    end
                    ::continue_counter_move::
                end
            end
        end

        return bestCandidate
    end

    function aiClass:findCommandantGuardMove(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end

        if not state or not state.commandHubs then
            return nil
        end

        local ownHub = state.commandHubs[aiPlayer]
        if not ownHub then
            return nil
        end

        local guardConfig = self:getCommandantGuardScoreConfig()
        local guardCellBonus = guardConfig.CELL_BONUS or {}
        local guardScore = guardConfig.SCORE or {}
        local defaultGuardConfig = DEFAULT_SCORE_PARAMS.COMMANDANT_GUARD or {}
        local defaultGuardCellBonus = defaultGuardConfig.CELL_BONUS or {}
        local defaultGuardScore = defaultGuardConfig.SCORE or {}

        local gridSize = state.gridSize or (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or DEFAULT_GRID_SIZE

        local adjacentOffsets = self:getOrthogonalDirections()

        local function addUniqueGuardCell(cells, lookup, row, col, bonus, purpose)
            if row < ONE or row > gridSize or col < ONE or col > gridSize then
                return
            end
            local key = row .. "," .. col
            if not lookup[key] then
                lookup[key] = true
                cells[#cells + ONE] = {
                    row = row,
                    col = col,
                    bonus = bonus or ZERO,
                    purpose = purpose or "adjacent"
                }
            end
        end

        local function collectThreatData(enemy)
            local guardCells = {}
            local guardLookup = {}
            local distToHub = math.abs(enemy.row - ownHub.row) + math.abs(enemy.col - ownHub.col)
            local attackRange = unitsInfo:getUnitAttackRange(enemy, "COMMANDANT_GUARD_RANGE_CHECK") or MIN_HP

            local isRangedThreat = false
            if attackRange > ONE and distToHub <= attackRange then
                if self:unitHasTag(enemy, "artillery") then
                    isRangedThreat = true
                elseif self:unitHasTag(enemy, "los") and self:hasLineOfSight(state, enemy, ownHub) then
                    isRangedThreat = true
                end
            end

            if distToHub <= TWO then
                for _, offset in ipairs(adjacentOffsets) do
                    addUniqueGuardCell(guardCells, guardLookup, enemy.row + offset.row, enemy.col + offset.col, ZERO, "adjacent")
                end
            end

            if isRangedThreat then
                if self:unitHasTag(enemy, "los") then
                    local path = self:getLinePath({row = enemy.row, col = enemy.col}, ownHub)
                    if path and #path > TWO then
                        for i = TWO, #path - ONE do
                            local pos = path[i]
                            addUniqueGuardCell(
                                guardCells,
                                guardLookup,
                                pos.row,
                                pos.col,
                                valueOr(guardCellBonus.line_block, defaultGuardCellBonus.line_block),
                                "line_block"
                            )
                        end
                    end
                end

                if distToHub > TWO then
                    for _, offset in ipairs(adjacentOffsets) do
                        addUniqueGuardCell(
                            guardCells,
                            guardLookup,
                            enemy.row + offset.row,
                            enemy.col + offset.col,
                            valueOr(guardCellBonus.pressure, defaultGuardCellBonus.pressure),
                            "pressure"
                        )
                    end
                end
            elseif distToHub == THREE then
                -- Melee enemy just outside range: prepare intercept spots adjacent to hub
                for _, offset in ipairs(adjacentOffsets) do
                    addUniqueGuardCell(
                        guardCells,
                        guardLookup,
                        ownHub.row + offset.row,
                        ownHub.col + offset.col,
                        valueOr(guardCellBonus.hub_screen, defaultGuardCellBonus.hub_screen),
                        "hub_screen"
                    )
                end
            end

            return guardCells, isRangedThreat
        end

        local threateningEnemies = {}
        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, aiPlayer) then
                local guardCells, isRangedThreat = collectThreatData(enemy)
                if #guardCells > ZERO then
                    threateningEnemies[#threateningEnemies + ONE] = {
                        enemy = enemy,
                        guardCells = guardCells,
                        isRangedThreat = isRangedThreat
                    }
                end
            end
        end

        if #threateningEnemies == ZERO then
            return nil
        end

        local bestCandidate = nil
        local bestScore = -math.huge
        local guardAssignments = state.guardAssignments or {}

        local function allyEligible(ally)
            return self:isUnitEligibleForAction(ally, aiPlayer, usedUnits, {
                requireNotActed = true,
                requireNotMoved = false,
                disallowCommandant = true,
                requireAlive = true
            })
        end

        for _, threat in ipairs(threateningEnemies) do
            for _, ally in ipairs(state.units or {}) do
                if allyEligible(ally) then
                    local unitKey = self:getUnitKey(ally)
                    local assignedGuard = unitKey and guardAssignments[unitKey] or nil
                    local moveCells = self:getValidMoveCells(state, ally.row, ally.col) or {}
                    for _, moveCell in ipairs(moveCells) do
                        for _, guardCell in ipairs(threat.guardCells) do
                            if moveCell.row == guardCell.row and moveCell.col == guardCell.col then
                                local adjacentToThreat = (math.abs(moveCell.row - threat.enemy.row) + math.abs(moveCell.col - threat.enemy.col)) == ONE
                                if adjacentToThreat and not unitsInfo:canAttackAdjacent(ally.name) then
                                    goto continue_guard_cell
                                end

                                local moveOk = self:isOpenSafeMoveCell(state, ally, moveCell)
                                if moveOk then
                                    if self:unitHasTag(ally, "ranged") then
                                        local canPressureThreat = self:canUnitDamageTargetFromPosition(
                                            state,
                                            ally,
                                            threat.enemy,
                                            moveCell.row,
                                            moveCell.col,
                                            {requirePositiveDamage = true}
                                        )
                                        local isLineBlockCell = (guardCell.purpose == "line_block")
                                        if not canPressureThreat and not isLineBlockCell then
                                            goto continue_guard_cell
                                        end
                                    end

                                    local distanceFromAlly = math.abs(ally.row - moveCell.row) + math.abs(ally.col - moveCell.col)
                                    local guardCellDistToHub = math.abs(moveCell.row - ownHub.row) + math.abs(moveCell.col - ownHub.col)
                                    local score = valueOr(guardScore.BASE, defaultGuardScore.BASE)
                                        - distanceFromAlly * valueOr(guardScore.DISTANCE_PENALTY, defaultGuardScore.DISTANCE_PENALTY)
                                    if not threat.isRangedThreat then
                                        if guardCellDistToHub == ONE then
                                            score = score + valueOr(guardScore.MELEE_ADJ_HUB_BONUS, defaultGuardScore.MELEE_ADJ_HUB_BONUS)
                                        elseif guardCellDistToHub == TWO then
                                            score = score + valueOr(guardScore.MELEE_NEAR_HUB_BONUS, defaultGuardScore.MELEE_NEAR_HUB_BONUS)
                                        end
                                    end
                                    if threat.isRangedThreat then
                                        score = score + valueOr(guardScore.RANGED_THREAT_BONUS, defaultGuardScore.RANGED_THREAT_BONUS)
                                    end
                                    if guardCell.purpose == "hub_screen" then
                                        score = score + valueOr(guardScore.HUB_SCREEN_PURPOSE_BONUS, defaultGuardScore.HUB_SCREEN_PURPOSE_BONUS)
                                    elseif guardCell.purpose == "line_block" and threat.isRangedThreat then
                                        score = score + valueOr(guardScore.LINE_BLOCK_PURPOSE_BONUS, defaultGuardScore.LINE_BLOCK_PURPOSE_BONUS)
                                    end
                                    if assignedGuard then
                                        if moveCell.row == assignedGuard.row and moveCell.col == assignedGuard.col then
                                            score = score + valueOr(guardScore.ASSIGNED_MATCH_BONUS, defaultGuardScore.ASSIGNED_MATCH_BONUS)
                                        else
                                            score = score - valueOr(guardScore.ASSIGNED_MISMATCH_PENALTY, defaultGuardScore.ASSIGNED_MISMATCH_PENALTY)
                                        end
                                    end
                                    score = score + (guardCell.bonus or ZERO)
                                    local patternPenalty = self:getRepeatedLowImpactPatternPenalty(state, ally, moveCell, aiPlayer)
                                    if patternPenalty > ZERO then
                                        score = score - math.min(patternPenalty, 180)
                                    end
                                    if score > bestScore then
                                        bestScore = score
                                        bestCandidate = {
                                            unit = ally,
                                            action = {
                                                type = "move",
                                                unit = {row = ally.row, col = ally.col},
                                                target = {row = moveCell.row, col = moveCell.col},
                                                guardUnitKey = unitKey,
                                                guardIntent = {
                                                    row = moveCell.row,
                                                    col = moveCell.col
                                                }
                                            },
                                            enemyTarget = {
                                                row = threat.enemy.row,
                                                col = threat.enemy.col,
                                                name = threat.enemy.name,
                                                guardType = guardCell.purpose
                                            }
                                        }
                                    end
                                end
                                ::continue_guard_cell::
                            end
                        end
                    end
                end
            end
        end

        return bestCandidate
    end

    -- Obvious action 19: Enhanced supply deployment with survival-first logic
    function aiClass:findEnhancedSupplyDeployment(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        if not state then
            return nil
        end

        -- Check if AI has supply remaining
        if not state.supply or not state.supply[aiPlayer] or #state.supply[aiPlayer] == ZERO then
            return nil
        end

        if not state.commandHubs then
            return nil
        end

        -- Check if Commandant exists and has free cells
        local ownHub = state.commandHubs[aiPlayer]
        if not ownHub then
            return nil
        end

        -- Get all possible supply deployments using existing function
        local supplyDeployments = self:getPossibleSupplyDeployments(state)
        if #supplyDeployments == ZERO then
            return nil
        end

        -- SURVIVAL-FIRST FILTERING: Only consider deployments where unit survives next turn
        local survivableDeployments = {}

        local hubThreat = self:analyzeHubThreat(state)
        local hubPos = state.commandHubs[aiPlayer]
        local supplyScoreConfig = self:getSupplyDeploymentScoreConfig()
        local supplyEvalConfig = self:getSupplyEvalScoreConfig()
        local defaultSupplyScoreConfig = DEFAULT_SCORE_PARAMS.SUPPLY_DEPLOYMENT or {}
        local defaultSupplyEvalConfig = DEFAULT_SCORE_PARAMS.SUPPLY_EVAL or {}
        local strategyConfig = self:getStrategyScoreConfig()
        local deploySyncConfig = strategyConfig.DEPLOY_SYNC or {}
        local planState = self.strategicPlanState or {}
        local defenseIntentActive = planState.intent == STRATEGY_INTENT.DEFEND_HARD
        local defensiveProximityConfig = supplyScoreConfig.DEFENSIVE_PROXIMITY or {}
        local responseConfig = supplyScoreConfig.RESPONSE or {}
        local strategicConfig = supplyScoreConfig.STRATEGIC_BONUS or {}
        local selectionConfig = supplyScoreConfig.SELECTION or {}
        local threatGatingConfig = supplyScoreConfig.THREAT_GATING or {}
        local defaultDefensiveProximityConfig = defaultSupplyScoreConfig.DEFENSIVE_PROXIMITY or {}
        local defaultResponseConfig = defaultSupplyScoreConfig.RESPONSE or {}
        local defaultStrategicConfig = defaultSupplyScoreConfig.STRATEGIC_BONUS or {}
        local defaultThreatGatingConfig = defaultSupplyScoreConfig.THREAT_GATING or {}
        local blockLineBonus = valueOr(supplyEvalConfig.BLOCK_LINE_OF_SIGHT, defaultSupplyEvalConfig.BLOCK_LINE_OF_SIGHT)
        local threatLookaheadTurns = math.max(
            ONE,
            valueOr(threatGatingConfig.LOOKAHEAD_TURNS, valueOr(defaultThreatGatingConfig.LOOKAHEAD_TURNS, TWO))
        )
        local threatFrontierMax = math.max(
            ONE,
            valueOr(threatGatingConfig.FRONTIER_MAX, valueOr(defaultThreatGatingConfig.FRONTIER_MAX, 20))
        )
        local earlyThreatTurnMax = math.max(
            ONE,
            valueOr(threatGatingConfig.EARLY_THREAT_TURN_MAX, valueOr(defaultThreatGatingConfig.EARLY_THREAT_TURN_MAX, TWO))
        )
        local strictGatingRequiresHubThreat = valueOr(
            threatGatingConfig.STRICT_GATING_REQUIRES_HUB_THREAT,
            valueOr(defaultThreatGatingConfig.STRICT_GATING_REQUIRES_HUB_THREAT, true)
        )
        local requireCounterOrBlockWhenHubThreat = valueOr(
            threatGatingConfig.REQUIRE_COUNTER_OR_BLOCK_WHEN_HUB_THREAT,
            valueOr(defaultThreatGatingConfig.REQUIRE_COUNTER_OR_BLOCK_WHEN_HUB_THREAT, true)
        )
        local rejectIfThreatBeforeImpact = valueOr(
            threatGatingConfig.REJECT_IF_THREAT_BEFORE_IMPACT,
            valueOr(defaultThreatGatingConfig.REJECT_IF_THREAT_BEFORE_IMPACT, true)
        )
        local rejectIfThreatTieImpact = valueOr(
            threatGatingConfig.REJECT_IF_THREAT_TIE_IMPACT,
            valueOr(defaultThreatGatingConfig.REJECT_IF_THREAT_TIE_IMPACT, true)
        )
        local maxImpactTurn = math.max(
            ONE,
            valueOr(threatGatingConfig.MAX_IMPACT_TURN, valueOr(defaultThreatGatingConfig.MAX_IMPACT_TURN, threatLookaheadTurns))
        )
        local rejectIfNoImpactAndEarlyThreat = valueOr(
            threatGatingConfig.REJECT_IF_NO_IMPACT_AND_EARLY_THREAT,
            valueOr(defaultThreatGatingConfig.REJECT_IF_NO_IMPACT_AND_EARLY_THREAT, true)
        )
        local threatBeforeImpactPenalty = valueOr(
            threatGatingConfig.THREAT_BEFORE_IMPACT_PENALTY,
            valueOr(defaultThreatGatingConfig.THREAT_BEFORE_IMPACT_PENALTY, 140)
        )
        local noImpactUnderThreatPenalty = valueOr(
            threatGatingConfig.NO_IMPACT_UNDER_THREAT_PENALTY,
            valueOr(defaultThreatGatingConfig.NO_IMPACT_UNDER_THREAT_PENALTY, 220)
        )
        local impactTurn1Bonus = valueOr(
            threatGatingConfig.IMPACT_TURN_1_BONUS,
            valueOr(defaultThreatGatingConfig.IMPACT_TURN_1_BONUS, 45)
        )
        local impactTurn2Bonus = valueOr(
            threatGatingConfig.IMPACT_TURN_2_BONUS,
            valueOr(defaultThreatGatingConfig.IMPACT_TURN_2_BONUS, 20)
        )
        local blockPrimaryThreatBonus = valueOr(
            responseConfig.BLOCK_PRIMARY_THREAT_BONUS,
            valueOr(
                defaultResponseConfig.BLOCK_PRIMARY_THREAT_BONUS,
                valueOr(responseConfig.FAIL_PENALTY_CLOSE, valueOr(defaultResponseConfig.FAIL_PENALTY_CLOSE, 200))
            )
        )
        local counterThreatTurn1Bonus = valueOr(
            responseConfig.COUNTER_THREAT_TURN1_BONUS,
            valueOr(
                defaultResponseConfig.COUNTER_THREAT_TURN1_BONUS,
                valueOr(responseConfig.COUNTER_BASE_CLOSE, valueOr(defaultResponseConfig.COUNTER_BASE_CLOSE, 45)) * TWO
            )
        )
        local counterThreatTurn2Bonus = valueOr(
            responseConfig.COUNTER_THREAT_TURN2_BONUS,
            valueOr(
                defaultResponseConfig.COUNTER_THREAT_TURN2_BONUS,
                valueOr(responseConfig.COUNTER_BASE_CLOSE, valueOr(defaultResponseConfig.COUNTER_BASE_CLOSE, 45))
            )
        )
        local hubThreatActive = hubThreat and (
            hubThreat.isUnderAttack
            or (hubThreat.projectedThreatActionable == true)
            or (self.defenseModeState and self.defenseModeState.active == true)
        )
        local strictThreatTiming = (not strictGatingRequiresHubThreat) or hubThreatActive
        local allowHealerProjectedOffense = self:shouldHealerBeOffensive(state)
        local skipBadDeployWhenDefending = valueOr(deploySyncConfig.SKIP_BAD_DEPLOY_WHEN_DEFENDING, true)
        local defenseDeployMinNetImpact = valueOr(deploySyncConfig.DEFENSE_DEPLOY_MIN_NET_IMPACT, 60)
        local rejectionCounts = {}
        local rejectionSamples = {}

        local function trackRejection(reason, deployment, details)
            local key = reason or "unknown"
            rejectionCounts[key] = (rejectionCounts[key] or ZERO) + ONE
            if not rejectionSamples[key] then
                rejectionSamples[key] = {
                    unit = deployment and deployment.unitName or "?",
                    target = deployment and deployment.target or nil,
                    details = details
                }
            end
        end

        local primaryThreat = nil
        if hubThreat and hubThreat.threats then
            for _, threatInfo in ipairs(hubThreat.threats) do
                if threatInfo.unit then
                    if not primaryThreat
                        or (threatInfo.distance or math.huge) < (primaryThreat.distance or math.huge)
                        or ((threatInfo.distance or math.huge) == (primaryThreat.distance or math.huge)
                            and (threatInfo.threatLevel or ZERO) > (primaryThreat.threatLevel or ZERO)) then
                        primaryThreat = threatInfo
                    end
                end
            end
        end

        local function canDeploymentCounterThreat(unitName, spawnCell, threatInfo)
            if not threatInfo or not threatInfo.unit or not hubPos then
                return true
            end

            local threatUnit = threatInfo.unit
            local threatDistanceFromHub = threatInfo.distance
                or (math.abs(threatUnit.row - hubPos.row) + math.abs(threatUnit.col - hubPos.col))

            local unitStats = unitsInfo:getUnitStats({name = unitName}, "SUPPLY_DEPLOYMENT_SELECTION")
            local moveRange = unitStats.move or ZERO
            local attackRange = unitStats.atkRange or MIN_HP
            local canAttackAdjacent = unitsInfo:canAttackAdjacent(unitName)

            local distToThreatFromSpawn = math.abs(spawnCell.row - threatUnit.row) + math.abs(spawnCell.col - threatUnit.col)

            if threatDistanceFromHub <= TWO then
                if not canAttackAdjacent then
                    return false
                end
                return distToThreatFromSpawn <= (moveRange + ONE)
            end

            if attackRange <= ONE and not canAttackAdjacent then
                return false
            end

            local effectiveRange = math.max(attackRange, ONE) + moveRange
            return distToThreatFromSpawn <= effectiveRange
        end

        local function blocksPrimaryThreatLine(spawnCell, threatInfo)
            if not spawnCell or not threatInfo or not threatInfo.unit or not hubPos then
                return false
            end

            local threatUnit = threatInfo.unit
            if not self:unitHasTag(threatUnit, "los") then
                return false
            end

            return self:isPositionBetweenOrthogonal(
                spawnCell,
                {row = threatUnit.row, col = threatUnit.col},
                {row = hubPos.row, col = hubPos.col}
            )
        end

        local function getCounterThreatTurnForDeployment(simState, deployedUnit, threatInfo)
            if not simState or not deployedUnit or not threatInfo or not threatInfo.unit then
                return nil
            end

            local targetThreat = self:getUnitAtPosition(simState, threatInfo.unit.row, threatInfo.unit.col) or threatInfo.unit
            return self:getUnitThreatTiming(
                simState,
                deployedUnit,
                targetThreat,
                threatLookaheadTurns,
                {
                    requirePositiveDamage = true,
                    considerCurrentActionState = true,
                    allowMoveOnFirstTurn = true,
                    maxFrontierNodes = threatFrontierMax
                }
            )
        end

        local function scoreDefensiveProximity(cell)
            if not hubPos then
                return ZERO
            end

            local baseBonus = ZERO

            if hubThreat and hubThreat.isUnderAttack then
                local bestDiff = math.huge
                for _, threatInfo in ipairs(hubThreat.threats or {}) do
                    local threatUnit = threatInfo.unit
                    if threatUnit and threatUnit.row and threatUnit.col then
                        local dist = math.abs(cell.row - threatUnit.row) + math.abs(cell.col - threatUnit.col)
                        if dist < bestDiff then
                            bestDiff = dist
                        end
                    end
                end

                if bestDiff < math.huge then
                    baseBonus = baseBonus + math.max(
                        ZERO,
                        valueOr(defensiveProximityConfig.THREAT_BASE, defaultDefensiveProximityConfig.THREAT_BASE)
                            - bestDiff * valueOr(defensiveProximityConfig.THREAT_DECAY, defaultDefensiveProximityConfig.THREAT_DECAY)
                    )
                end

                if hubThreat.direction and self:wouldBlockLineOfSight(state, cell, hubThreat.direction) then
                    baseBonus = baseBonus + blockLineBonus
                end

                local distToHub = math.abs(cell.row - hubPos.row) + math.abs(cell.col - hubPos.col)
                baseBonus = baseBonus + math.max(
                    ZERO,
                    valueOr(defensiveProximityConfig.HUB_BASE, defaultDefensiveProximityConfig.HUB_BASE)
                        - distToHub * valueOr(defensiveProximityConfig.HUB_DECAY, defaultDefensiveProximityConfig.HUB_DECAY)
                )
            else
                local distToHub = math.abs(cell.row - hubPos.row) + math.abs(cell.col - hubPos.col)
                baseBonus = baseBonus + math.max(
                    ZERO,
                    valueOr(defensiveProximityConfig.CALM_BASE, defaultDefensiveProximityConfig.CALM_BASE)
                        - distToHub * valueOr(defensiveProximityConfig.CALM_DECAY, defaultDefensiveProximityConfig.CALM_DECAY)
                )
            end

            return baseBonus
        end

        local function getProjectedThreatTurnForDeployment(simState, deployedUnit)
            if not simState or not deployedUnit then
                return nil
            end

            local threatTurn = nil
            for _, enemy in ipairs(simState.units or {}) do
                if enemy and enemy.player and enemy.player ~= aiPlayer and enemy.player ~= ZERO
                    and not self:isHubUnit(enemy) and not self:isObstacleUnit(enemy) then
                    local turn = self:getUnitThreatTiming(
                        simState,
                        enemy,
                        deployedUnit,
                        threatLookaheadTurns,
                        {
                            requirePositiveDamage = true,
                            considerCurrentActionState = false,
                            allowMoveOnFirstTurn = true,
                            maxFrontierNodes = threatFrontierMax
                        }
                    )
                    if turn and (not threatTurn or turn < threatTurn) then
                        threatTurn = turn
                        if threatTurn == ONE then
                            break
                        end
                    end
                end
            end

            return threatTurn
        end

        local function getProjectedImpactTurnForDeployment(simState, deployedUnit, unitName)
            if not simState or not deployedUnit then
                return nil
            end
            if self:unitHasTag(unitName, "healer") and not allowHealerProjectedOffense then
                return nil
            end

            local impactTurn = nil
            local function considerTarget(target)
                if not target then
                    return
                end

                local turn = self:getUnitThreatTiming(
                    simState,
                    deployedUnit,
                    target,
                    threatLookaheadTurns,
                    {
                        requirePositiveDamage = true,
                        considerCurrentActionState = true,
                        allowMoveOnFirstTurn = true,
                        maxFrontierNodes = threatFrontierMax
                    }
                )
                if turn and (not impactTurn or turn < impactTurn) then
                    impactTurn = turn
                end
            end

            for _, enemy in ipairs(simState.units or {}) do
                if self:isAttackableEnemyUnit(enemy, aiPlayer) then
                    considerTarget(enemy)
                    if impactTurn == ONE then
                        return impactTurn
                    end
                end
            end

            local enemyHub = simState.commandHubs and simState.commandHubs[self:getOpponentPlayer(aiPlayer)]
            if enemyHub then
                local hubTarget = {
                    name = "Commandant",
                    player = self:getOpponentPlayer(aiPlayer),
                    row = enemyHub.row,
                    col = enemyHub.col,
                    currentHp = enemyHub.currentHp,
                    startingHp = enemyHub.startingHp
                }
                considerTarget(hubTarget)
            end

            return impactTurn
        end

        for _, deployment in ipairs(supplyDeployments) do
            -- Create temporary unit object for survival checking
            local tempUnit = {
                row = deployment.target.row,
                col = deployment.target.col,
                name = deployment.unitName,
                player = aiPlayer,
                currentHp = nil -- Will be set using centralized function
            }

            -- Use centralized function to get unit HP with debug printing
            tempUnit.currentHp = unitsInfo:getUnitHP(tempUnit, "ENHANCED_SUPPLY_DEPLOYMENT")

            -- CRITICAL: Check if unit would survive next turn
            local wouldSurvive = not self:wouldUnitDieNextTurn(state, tempUnit)

            if wouldSurvive then

                -- Calculate positional value for surviving deployments
                local positionalValue = self:getPositionalValue(state, tempUnit)
                positionalValue = positionalValue + scoreDefensiveProximity(deployment.target)

                -- Combine original deployment score with positional value
                local enhancedScore = deployment.score + positionalValue

                -- Check if this is a beneficial deployment (positive positional value)
                local isBeneficial = positionalValue > ZERO

                -- Special strategic considerations for specific units
                local strategicBonus = ZERO
                local responseBonus = ZERO
                local canCounterThreat = true
                local blocksPrimaryThreat = false
                local counterThreatTurn = nil
                if primaryThreat and primaryThreat.unit then
                    canCounterThreat = canDeploymentCounterThreat(deployment.unitName, deployment.target, primaryThreat)
                    local threatUnit = primaryThreat.unit
                    local distToThreat = math.abs(deployment.target.row - threatUnit.row) + math.abs(deployment.target.col - threatUnit.col)
                    blocksPrimaryThreat = blocksPrimaryThreatLine(deployment.target, primaryThreat)

                    if canCounterThreat then
                        local closeThreatDistance = valueOr(responseConfig.CLOSE_THREAT_DISTANCE, defaultResponseConfig.CLOSE_THREAT_DISTANCE)
                        local base = (primaryThreat.distance or math.huge) <= closeThreatDistance
                            and valueOr(responseConfig.COUNTER_BASE_CLOSE, defaultResponseConfig.COUNTER_BASE_CLOSE)
                            or valueOr(responseConfig.COUNTER_BASE_FAR, defaultResponseConfig.COUNTER_BASE_FAR)
                        responseBonus = responseBonus + math.max(ZERO, base - distToThreat * valueOr(responseConfig.COUNTER_DECAY, defaultResponseConfig.COUNTER_DECAY))
                    else
                        local closeThreatDistance = valueOr(responseConfig.CLOSE_THREAT_DISTANCE, defaultResponseConfig.CLOSE_THREAT_DISTANCE)
                        local penalty = (primaryThreat.distance or math.huge) <= closeThreatDistance
                            and valueOr(responseConfig.FAIL_PENALTY_CLOSE, defaultResponseConfig.FAIL_PENALTY_CLOSE)
                            or valueOr(responseConfig.FAIL_PENALTY_FAR, defaultResponseConfig.FAIL_PENALTY_FAR)
                        responseBonus = responseBonus - penalty
                    end

                    if blocksPrimaryThreat and hubThreatActive then
                        strategicBonus = strategicBonus + blockPrimaryThreatBonus
                    end
                end

                -- Corvette blocking line of sight to enemy hub
                if self:unitHasTag(deployment.unitName, "corvette") then
                    local enemyHub = state.commandHubs[self:getOpponentPlayer(aiPlayer)]
                    if enemyHub and self:wouldBlockLineOfSight(state, deployment.target, {row = enemyHub.row - ownHub.row, col = enemyHub.col - ownHub.col}) then
                        strategicBonus = strategicBonus + valueOr(strategicConfig.CORVETTE_LINE_BLOCK, defaultStrategicConfig.CORVETTE_LINE_BLOCK)
                    end
                end

                -- Wingstalker blocking line of sight when hub under threat
                hubThreat = hubThreat or self:analyzeHubThreat(state)
                if self:unitHasTag(deployment.unitName, "scout") and hubThreat and hubThreat.isUnderAttack and hubThreat.direction then
                    if self:wouldBlockLineOfSight(state, deployment.target, hubThreat.direction) then
                        strategicBonus = strategicBonus + valueOr(strategicConfig.SCOUT_LINE_BLOCK, defaultStrategicConfig.SCOUT_LINE_BLOCK)
                    end
                end

                local projectedThreatTurn = nil
                local projectedImpactTurn = nil
                local projectionRejected = false
                local projectionRejectReason = nil
                local simDeploymentState = self:applySupplyDeployment(state, deployment)
                local projectedUnit = simDeploymentState and self:getUnitAtPosition(simDeploymentState, deployment.target.row, deployment.target.col) or nil

                if simDeploymentState and projectedUnit then
                    projectedThreatTurn = getProjectedThreatTurnForDeployment(simDeploymentState, projectedUnit)
                    projectedImpactTurn = getProjectedImpactTurnForDeployment(simDeploymentState, projectedUnit, deployment.unitName)
                    if primaryThreat and primaryThreat.unit then
                        counterThreatTurn = getCounterThreatTurnForDeployment(simDeploymentState, projectedUnit, primaryThreat)
                        if counterThreatTurn then
                            canCounterThreat = counterThreatTurn <= threatLookaheadTurns
                            if counterThreatTurn == ONE then
                                responseBonus = responseBonus + counterThreatTurn1Bonus
                            elseif counterThreatTurn == TWO then
                                responseBonus = responseBonus + counterThreatTurn2Bonus
                            end
                        else
                            canCounterThreat = false
                        end
                    end

                    local hasDefensiveImpact = blocksPrimaryThreat
                        or (counterThreatTurn and counterThreatTurn <= earlyThreatTurnMax)

                    if projectedImpactTurn == ONE then
                        responseBonus = responseBonus + impactTurn1Bonus
                    elseif projectedImpactTurn == TWO then
                        responseBonus = responseBonus + impactTurn2Bonus
                    end

                    if projectedImpactTurn and projectedImpactTurn > maxImpactTurn and not hasDefensiveImpact then
                        projectionRejected = true
                        projectionRejectReason = "impact_after_horizon"
                    end

                    if strictThreatTiming and projectedThreatTurn and projectedThreatTurn <= earlyThreatTurnMax then
                        if not projectedImpactTurn then
                            responseBonus = responseBonus - noImpactUnderThreatPenalty
                            if rejectIfNoImpactAndEarlyThreat and not hasDefensiveImpact then
                                projectionRejected = true
                                projectionRejectReason = projectionRejectReason or "no_impact_early_threat"
                            end
                        else
                            local threatAheadOfImpact = projectedThreatTurn < projectedImpactTurn
                            if rejectIfThreatTieImpact and projectedThreatTurn == projectedImpactTurn then
                                threatAheadOfImpact = true
                            end
                            if threatAheadOfImpact then
                                responseBonus = responseBonus - threatBeforeImpactPenalty
                                if rejectIfThreatBeforeImpact and not hasDefensiveImpact then
                                    projectionRejected = true
                                    projectionRejectReason = projectionRejectReason or "threat_before_impact"
                                end
                            end
                        end
                    end
                end

                if requireCounterOrBlockWhenHubThreat and hubThreatActive and primaryThreat and primaryThreat.unit then
                    local canBlockThreat = blocksPrimaryThreat or strategicBonus > ZERO
                    if not canCounterThreat and not canBlockThreat then
                        projectionRejected = true
                        projectionRejectReason = projectionRejectReason or "cannot_counter_or_block"
                    end
                end

                local guardIntent = nil
                if hubThreat and hubThreat.isUnderAttack then
                    guardIntent = {
                        row = deployment.target.row,
                        col = deployment.target.col
                    }
                end

                local totalScore = enhancedScore + strategicBonus + responseBonus
                local netImpact = strategicBonus + responseBonus
                if skipBadDeployWhenDefending and (defenseIntentActive or hubThreatActive) then
                    local hasDefensiveCounter = canCounterThreat or blocksPrimaryThreat
                    if netImpact < defenseDeployMinNetImpact and not hasDefensiveCounter then
                        projectionRejected = true
                        projectionRejectReason = projectionRejectReason or "low_defensive_net_impact"
                        self.badDeploySkipped = (self.badDeploySkipped or ZERO) + ONE
                    end
                end

                if not projectionRejected then
                    table.insert(survivableDeployments, {
                        type = "supply_deploy",
                        unitIndex = deployment.unitIndex,
                        unitName = deployment.unitName,
                        target = deployment.target,
                        hub = deployment.hub,
                        originalScore = deployment.score,
                        positionalValue = positionalValue,
                        strategicBonus = strategicBonus,
                        responseBonus = responseBonus,
                        projectedThreatTurn = projectedThreatTurn,
                        projectedImpactTurn = projectedImpactTurn,
                        score = totalScore,
                        isBeneficial = isBeneficial,
                        wouldSurvive = true,
                        guardIntent = guardIntent,
                        persistentGuard = true,
                        canCounterThreat = canCounterThreat,
                        counterThreatTurn = counterThreatTurn,
                        blocksPrimaryThreat = blocksPrimaryThreat
                    })
                else
                    trackRejection(projectionRejectReason or "threat_gating", deployment, {
                        projectedThreatTurn = projectedThreatTurn,
                        projectedImpactTurn = projectedImpactTurn,
                        canCounterThreat = canCounterThreat,
                        blocksPrimaryThreat = blocksPrimaryThreat,
                        strategicBonus = strategicBonus,
                        responseBonus = responseBonus
                    })
                end
            end
        end

        if DEBUG and DEBUG.AI and next(rejectionCounts) ~= nil then
            local summaryParts = {}
            for reason, count in pairs(rejectionCounts) do
                summaryParts[#summaryParts + ONE] = string.format("%s=%d", tostring(reason), count)
            end
            table.sort(summaryParts)
            self:logDecision("SUPPLY_DEPLOY", "Threat-gating rejections (aggregated)", {
                totalRejected = (#supplyDeployments - #survivableDeployments),
                reasons = table.concat(summaryParts, ", "),
                sample = rejectionSamples
            })
        end

        -- If no survivable deployments, return nil
        if #survivableDeployments == ZERO then
            return nil
        end

        local candidateDeployments = survivableDeployments
        if primaryThreat and primaryThreat.unit then
            local countering = {}
            for _, deployment in ipairs(survivableDeployments) do
                if deployment.canCounterThreat or deployment.blocksPrimaryThreat then
                    countering[#countering + ONE] = deployment
                end
            end

            if primaryThreat.distance and primaryThreat.distance <= TWO then
                if #countering > ZERO then
                    candidateDeployments = countering
                end
            elseif #countering > ZERO then
                candidateDeployments = countering
            end
        end

        -- Sort deployments by enhanced score (best first), with beneficial deployments prioritized
        self:sortScoredEntries(candidateDeployments, {
            descending = true,
            scoreFn = function(entry)
                local defensePriority = ZERO
                if hubThreatActive then
                    if entry and entry.blocksPrimaryThreat then
                        defensePriority = defensePriority + 3000000
                    end
                    if entry and entry.counterThreatTurn then
                        defensePriority = defensePriority + math.max(ZERO, (earlyThreatTurnMax + ONE - entry.counterThreatTurn)) * 1000000
                    elseif entry and entry.canCounterThreat then
                        defensePriority = defensePriority + 500000
                    end
                end
                local beneficialRank = (entry and entry.isBeneficial) and ONE or ZERO
                local score = entry and entry.score or ZERO
                return defensePriority + (beneficialRank * 100000) + score
            end
        })

        -- Strategic selection from survivable options
        local bestDeployment = nil
        local currentHubThreat = self:analyzeHubThreat(state)
        local defensiveSelectors = selectionConfig.DEFENSIVE_UNITS or {}

        local function isDefensiveDeploymentUnit(unitName)
            for _, selector in ipairs(defensiveSelectors) do
                if self:matchesDeploymentSelector({name = unitName}, selector) then
                    return true
                end
            end
            return false
        end

        for _, deployment in ipairs(candidateDeployments) do
            -- Priority 1: If hub is under threat, prioritize guarding units that can block.
            if currentHubThreat and currentHubThreat.isUnderAttack then
                local isDefensiveUnit = isDefensiveDeploymentUnit(deployment.unitName)
                local canBlockThreat = deployment.blocksPrimaryThreat or deployment.strategicBonus > ZERO -- Has strategic blocking bonus

                if isDefensiveUnit or canBlockThreat then
                    bestDeployment = deployment
                    break
                end
            end

            -- Priority 2: Prefer deployments with strategic bonuses (line of sight blocking)
            if deployment.strategicBonus > ZERO then
                bestDeployment = deployment
                break
            end

            -- Priority 3: Prefer beneficial deployments
            if deployment.isBeneficial then
                bestDeployment = deployment
                break
            end
        end

        -- Fallback: Use best scoring survivable deployment
        if not bestDeployment and #candidateDeployments > ZERO then
            bestDeployment = candidateDeployments[ONE]
        elseif not bestDeployment and #survivableDeployments > ZERO then
            bestDeployment = survivableDeployments[ONE]
        end

        if bestDeployment and bestDeployment.guardIntent then
            self.guardAssignments = self.guardAssignments or {}
            local key = string.format("spawn:%d,%d", bestDeployment.target.row, bestDeployment.target.col)
            self.guardAssignments[key] = {
                row = bestDeployment.guardIntent.row,
                col = bestDeployment.guardIntent.col
            }
        end

        return bestDeployment
    end

    -- Find move+attack sequences for units that are likely to die next turn.
    function aiClass:findLastMoveAttackForDoomedUnits(state, usedUnits, opts)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        if not state or not state.units or not state.commandHubs then
            return nil
        end
        local options = opts or {}
        local requireLethalOnly = options.requireLethalOnly == true
        local includeFinishers = options.includeFinishers ~= false
        local ownHub = state.commandHubs[aiPlayer]

        if not ownHub then
            return nil
        end

        local bestMoveAttack = nil
        local bestPriority = - ONE


        for _, unit in ipairs(state.units) do
            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits) then
                -- Check if unit will die next turn
                if self:wouldUnitDieNextTurn(state, unit) then

                    -- Get valid move positions for this unit
                    local movePositions = self:getValidMoveCells(state, unit.row, unit.col)

                    for _, movePos in ipairs(movePositions) do
                        -- Check what this unit can attack from the new position
                        local attackCells = self:getAttackCellsForUnitAtPosition(state, unit, movePos.row, movePos.col)

                        for _, attackCell in ipairs(attackCells) do
                            local target = self:getUnitAtPosition(state, attackCell.row, attackCell.col)

                            if self:isAttackableEnemyUnit(target, aiPlayer) then
                                -- Calculate damage and check for special abilities
                                local damage, specialUsed = self.unitsInfo:calculateAttackDamage(unit, target)
                                local targetCurrentHp = target.currentHp or MIN_HP
                                local wouldLeaveAt1HP = (targetCurrentHp - damage) == ONE

                                if self:isDoomedEliminationAttack(damage, targetCurrentHp, specialUsed, wouldLeaveAt1HP, {
                                    requireLethalOnly = requireLethalOnly,
                                    includeFinishers = includeFinishers
                                }) then
                                    local priority = self:getDoomedAttackPriority(
                                        state,
                                        ownHub,
                                        unit,
                                        target,
                                        damage,
                                        specialUsed,
                                        wouldLeaveAt1HP,
                                        movePos,
                                        targetCurrentHp
                                    )

                                    if priority > bestPriority then
                                        bestPriority = priority
                                        bestMoveAttack = {
                                            unit = unit,
                                            moveAction = {
                                                type = "move",
                                                unit = {row = unit.row, col = unit.col},  -- Use position reference
                                                target = {row = movePos.row, col = movePos.col}
                                            },
                                            attackAction = {
                                                type = "attack",
                                                unit = {row = movePos.row, col = movePos.col},  -- Use NEW position after move
                                                target = {row = attackCell.row, col = attackCell.col}
                                            },
                                            damage = damage,
                                            specialUsed = specialUsed,
                                            wouldLeaveAt1HP = wouldLeaveAt1HP,
                                            priority = priority
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        return bestMoveAttack
    end

    function aiClass:collectRiskyAttackCandidates(state, usedUnits, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local moveThenAttack = options.moveThenAttack == true
        local riskConfigKey = options.riskConfigKey or (moveThenAttack and "RISKY_MOVE_ATTACK" or "RISKY_ATTACK")
        local riskConfig = self:getKillRiskScoreConfig()[riskConfigKey] or {}
        local includeFriendlyFireCheck = options.includeFriendlyFireCheck ~= false
        local requireSafeMove = moveThenAttack and (options.requireSafeMove ~= false) or false
        local requireSafeAttack = options.requireSafeAttack ~= false
        local includeAttackerWillDie = options.includeAttackerWillDie == true
        local useRiskDamageEligibility = options.useRiskDamageEligibility ~= false
        local minDamageOverride = options.minDamage
        local rejectSpecialOverride = options.rejectSpecial
        local rejectLeaveAtOneHpOverride = options.rejectLeaveAtOneHp
        local scoreFn = options.scoreFn
        local unitEligibility = options.unitEligibility or {}
        local entryMode = moveThenAttack and "move" or "direct"
        local candidates = {}

        local function evaluateCandidate(unit, target, damage, targetCurrentHp, specialUsed, movePos, moveAction, attackAction)
            local wouldLeaveAt1HP = (targetCurrentHp - damage) == ONE
            local minDamage = valueOr(minDamageOverride, riskConfig.MIN_DAMAGE)
            local damageEligible = useRiskDamageEligibility
                and self:isRiskDamageEligible(unit, damage, riskConfigKey)
                or (damage >= valueOr(minDamage, MIN_HP))
            local rejectSpecial = valueOr(rejectSpecialOverride, riskConfig.REJECT_SPECIAL ~= false)
            local rejectLeaveAtOneHp = valueOr(rejectLeaveAtOneHpOverride, riskConfig.REJECT_LEAVE_AT_ONE_HP ~= false)
            local rejectedBySpecial = rejectSpecial and specialUsed
            local rejectedByLeaveAtOneHp = rejectLeaveAtOneHp and wouldLeaveAt1HP

            if not damageEligible or rejectedBySpecial or rejectedByLeaveAtOneHp then
                return
            end

            local attackerForSafety = unit
            if moveThenAttack and movePos then
                attackerForSafety = self:buildProjectedThreatUnit(unit, movePos.row, movePos.col) or unit
            end

            if requireSafeAttack and (not self:isAttackSafe(state, attackerForSafety, target)) then
                return
            end

            local attackValue = scoreFn and scoreFn(unit, target, damage, targetCurrentHp, movePos)
                or self:getCanonicalAttackScore(state, unit, target, damage, {
                    includeTargetValue = true
                })

            if moveThenAttack and movePos then
                local retaliationPenalty = self:getMirrorCorvetteRetaliationPenalty(
                    state,
                    unit,
                    target,
                    movePos,
                    targetCurrentHp - damage
                )
                if retaliationPenalty > ZERO then
                    attackValue = attackValue - retaliationPenalty
                end
            end

            local entry = {
                unit = unit,
                target = target,
                targetName = target.name,
                damage = damage,
                targetHp = targetCurrentHp,
                attackValue = attackValue
            }

            if moveThenAttack then
                entry.moveAction = moveAction
                entry.attackAction = attackAction
            else
                entry.action = attackAction
            end

            if includeAttackerWillDie then
                entry.attackerWillDie = not self:isAttackSafe(state, attackerForSafety, target)
            end

            candidates[#candidates + ONE] = entry
        end

        local attackEntries = self:collectAttackTargetEntries(state, usedUnits, {
            mode = entryMode,
            aiPlayer = aiPlayer,
            allowHealerAttacks = unitEligibility.allowHealerAttacks,
            requireSafeMove = requireSafeMove,
            checkVulnerableMove = false,
            enforceHealerOrbit = false,
            includeFriendlyFireCheck = includeFriendlyFireCheck,
            requirePositiveDamage = false,
            minDamage = ZERO,
            unitEligibility = unitEligibility
        })

        for _, base in ipairs(attackEntries) do
            local movePos = moveThenAttack and base.moveCell or nil
            local moveAction = moveThenAttack and base.moveAction or nil
            local attackAction = moveThenAttack and base.attackAction or base.action

            evaluateCandidate(
                base.unit,
                base.target,
                base.damage,
                base.targetHp or MIN_HP,
                base.specialUsed,
                movePos,
                moveAction,
                attackAction
            )
        end

        self:sortScoredEntries(candidates, {
            scoreField = "attackValue",
            descending = true
        })

        return candidates
    end

    -- Obvious action 22: Risky but potentially valuable attacks (2+ damage, not special/1HP) (Check adjacent safe cells)
    function aiClass:findRiskyValuableAttacks(state, usedUnits)
        local candidates = self:collectRiskyAttackCandidates(state, usedUnits, {
            moveThenAttack = false,
            riskConfigKey = "RISKY_ATTACK",
            includeFriendlyFireCheck = true,
            requireSafeAttack = true,
            unitEligibility = {
                disallowRock = true
            }
        })
        return candidates[ONE]
    end

    -- Obvious action 24: Find risky move+attack combos (2+ damage, not special/1HP, safe for attacker) (Check adjacent safe cells only)
    function aiClass:findRiskyMoveAttackCombos(state, usedUnits)
        local candidates = self:collectRiskyAttackCandidates(state, usedUnits, {
            moveThenAttack = true,
            riskConfigKey = "RISKY_MOVE_ATTACK",
            includeFriendlyFireCheck = false,
            requireSafeMove = true,
            requireSafeAttack = true,
            unitEligibility = {}
        })
        return candidates[ONE]
    end

    function aiClass:collectRepairActionCandidates(state, usedUnits, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local moveThenRepair = options.moveThenRepair == true
        local requireSafeMove = options.requireSafeMove == true
        local repairAmount = valueOr(options.repairAmount, ONE)
        local applyMoveDistanceBonus = options.applyMoveDistanceBonus == true
        local maxHpContext = options.maxHpContext or "REPAIR_TARGET_MAX_HP"
        local unitEligibility = options.unitEligibility or {}
        local candidates = {}

        local repairConfig = self:getScoreConfig().REPAIR or {}
        local defaultRepairConfig = DEFAULT_SCORE_PARAMS.REPAIR or {}
        local moveBonusBase = valueOr(repairConfig.MOVE_DISTANCE_BASE, defaultRepairConfig.MOVE_DISTANCE_BASE)
        local moveDistanceDecay = valueOr(repairConfig.MOVE_DISTANCE_DECAY, defaultRepairConfig.MOVE_DISTANCE_DECAY)

        for _, repairUnit in ipairs(state.units or {}) do
            local eligibilityOpts = {}
            for key, value in pairs(unitEligibility) do
                eligibilityOpts[key] = value
            end
            if moveThenRepair then
                eligibilityOpts.requireNotMoved = true
            end
            eligibilityOpts.allowHealerAttacks = true

            if self:isUnitEligibleForAction(repairUnit, aiPlayer, usedUnits, eligibilityOpts)
                and self:unitHasTag(repairUnit, "healer") then
                local positions = moveThenRepair
                    and (self:getValidMoveCells(state, repairUnit.row, repairUnit.col) or {})
                    or {{row = repairUnit.row, col = repairUnit.col}}

                for _, pos in ipairs(positions) do
                    local movePos = {row = pos.row, col = pos.col}
                    if (not moveThenRepair)
                        or (not requireSafeMove)
                        or self:isMoveSafe(state, repairUnit, movePos) then
                        local repairCells = moveThenRepair
                            and (self:getAttackCellsForUnitAtPosition(state, repairUnit, movePos.row, movePos.col) or {})
                            or (self:getValidAttackCells(state, repairUnit.row, repairUnit.col) or {})

                        for _, cell in ipairs(repairCells) do
                            local target = self:getUnitAtPosition(state, cell.row, cell.col)
                            if target and target.player == aiPlayer then
                                local targetCurrentHp = target.currentHp or ZERO
                                local targetMaxHp = unitsInfo:getUnitHP(target, maxHpContext) or ZERO

                                if targetCurrentHp < targetMaxHp and targetCurrentHp > ZERO then
                                    local repairPriority = self:getRepairTargetPriority(
                                        state,
                                        target,
                                        targetCurrentHp,
                                        targetMaxHp,
                                        repairAmount
                                    )

                                    if repairPriority then
                                        local moveDistance = math.abs(repairUnit.row - movePos.row) + math.abs(repairUnit.col - movePos.col)
                                        if moveThenRepair and applyMoveDistanceBonus then
                                            local moveBonus = math.max(ZERO, moveBonusBase - (moveDistance * moveDistanceDecay))
                                            repairPriority = repairPriority + moveBonus
                                        end

                                        local candidate = {
                                            unit = repairUnit,
                                            target = target,
                                            targetName = target.name,
                                            targetCurrentHp = targetCurrentHp,
                                            targetMaxHp = targetMaxHp,
                                            priority = repairPriority,
                                            moveDistance = moveDistance
                                        }

                                        if moveThenRepair then
                                            candidate.movePos = movePos
                                            candidate.moveAction = {
                                                type = "move",
                                                unit = {row = repairUnit.row, col = repairUnit.col},
                                                target = {row = movePos.row, col = movePos.col}
                                            }
                                            candidate.repairAction = {
                                                type = "repair",
                                                unit = {row = movePos.row, col = movePos.col},
                                                target = {row = target.row, col = target.col}
                                            }
                                        else
                                            candidate.action = {
                                                type = "repair",
                                                unit = {row = repairUnit.row, col = repairUnit.col},
                                                target = {row = target.row, col = target.col}
                                            }
                                        end

                                        candidates[#candidates + ONE] = candidate
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        self:sortScoredEntries(candidates, {
            scoreField = "priority",
            descending = true
        })

        return candidates
    end

    -- Obvious action 25: Find survival repair actions (single repair unit, no movement, must guarantee survival)
    function aiClass:findSurvivalRepairActions(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        local repairCandidates = self:collectRepairActionCandidates(state, usedUnits, {
            aiPlayer = aiPlayer,
            moveThenRepair = false,
            repairAmount = ONE,
            maxHpContext = "REPAIR_TARGET_MAX_HP",
            unitEligibility = {}
        })

        local selected = self:selectUniqueEntries(repairCandidates, {
            limit = ONE,
            uniqueKeyFns = {
                function(entry)
                    if not entry or not entry.target then
                        return nil
                    end
                    return string.format("%d,%d", entry.target.row or ZERO, entry.target.col or ZERO)
                end
            }
        })

        if #selected == ZERO then
            return {}
        end

        return selected
    end

    -- Obvious action 26: Find survival move+repair actions (only if sequence == 0, up to 2 combos, must guarantee survival)
    function aiClass:findSurvivalMoveRepairActions(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        local moveRepairCandidates = self:collectRepairActionCandidates(state, usedUnits, {
            aiPlayer = aiPlayer,
            moveThenRepair = true,
            requireSafeMove = true,
            repairAmount = TWO,
            maxHpContext = "REPAIR_MAX_HP",
            applyMoveDistanceBonus = true,
            unitEligibility = {}
        })

        local selectedMoveRepairs = self:selectUniqueEntries(moveRepairCandidates, {
            limit = ONE, -- One move+repair combo consumes both actions
            uniqueKeyFns = {
                function(entry)
                    if not entry or not entry.target then
                        return nil
                    end
                    return string.format("%d,%d", entry.target.row or ZERO, entry.target.col or ZERO)
                end,
                function(entry)
                    if not entry or not entry.unit then
                        return nil
                    end
                    return string.format("%d,%d", entry.unit.row or ZERO, entry.unit.col or ZERO)
                end
            }
        })

        return selectedMoveRepairs
    end

    -- Helper function to get attack cells for a unit at its current position
    function aiClass:getAttackCellsForUnit(state, unit)
        local attackPattern = self:getAttackPattern(unit)
        local unitProfile = self:getUnitProfile(unit)
        local minRange = (unitProfile and unitProfile.minRange) or ONE
        local maxRange = (unitProfile and unitProfile.maxRange) or unitsInfo:getUnitAttackRange(unit, "GET_ATTACK_CELLS_FOR_UNIT_RANGE") or minRange
        if attackPattern == "corvette" then
            local cells = {}
            for _, enemy in ipairs(state.units) do
                if self:isAttackableEnemyUnit(enemy, unit.player) then
                    local dist = math.abs(unit.row - enemy.row) + math.abs(unit.col - enemy.col)
                    if dist >= minRange and dist <= maxRange and self:hasLineOfSight(state, unit, enemy) then
                        table.insert(cells, {row = enemy.row, col = enemy.col})
                    end
                end
            end
            return cells
        elseif attackPattern == "artillery" then
            local cells = {}
            for _, enemy in ipairs(state.units) do
                if self:isAttackableEnemyUnit(enemy, unit.player) then
                    local rowDiff = math.abs(unit.row - enemy.row)
                    local colDiff = math.abs(unit.col - enemy.col)
                    local manhattan = rowDiff + colDiff
                    local isOrthogonal = (rowDiff == ZERO and colDiff >= minRange and colDiff <= maxRange) or (colDiff == ZERO and rowDiff >= minRange and rowDiff <= maxRange)
                    if isOrthogonal and manhattan >= minRange and manhattan <= maxRange then
                        table.insert(cells, {row = enemy.row, col = enemy.col})
                    end
                end
            end
            return cells
        else
            return self:getValidAttackCells(state, unit.row, unit.col)
        end
    end

    -- Helper function to get attack cells for a unit at a hypothetical position
    function aiClass:getAttackCellsForUnitAtPosition(state, unit, row, col)
        local cells = {}
        local attackPattern = self:getAttackPattern(unit)
        local unitProfile = self:getUnitProfile(unit)
        local minRange = (unitProfile and unitProfile.minRange) or ONE

        -- Special handling for Corvette
        if attackPattern == "corvette" then
            -- Use centralized function to get Corvette attack range with debug printing
            local attackRange = unitsInfo:getUnitAttackRange(unit, "GET_ATTACK_CELLS_FOR_UNIT_AT_POSITION_CORVETTE")
            for _, dir in ipairs(self:getOrthogonalDirections()) do
                for dist = minRange, attackRange do
                    local r = row + (dir.row * dist)
                    local c = col + (dir.col * dist)

                    if self:isInsideBoard(r, c, state) then
                        local isBlocked = false
                        for checkDist = ONE, dist - ONE do
                            local checkR = row + (dir.row * checkDist)
                            local checkC = col + (dir.col * checkDist)

                            local blockingUnit = self:getUnitAtPosition(state, checkR, checkC)
                            if blockingUnit then
                                isBlocked = true
                                break
                            end

                            if state.neutralBuildings then
                                for _, building in ipairs(state.neutralBuildings) do
                                    if building.row == checkR and building.col == checkC then
                                        isBlocked = true
                                        break
                                    end
                                end
                            end
                            if isBlocked then break end
                        end

                        if not isBlocked then
                            local targetUnit = self:getUnitAtPosition(state, r, c)
                            if targetUnit and targetUnit.player ~= unit.player then
                                table.insert(cells, {row = r, col = c})
                            end
                        end
                    end
                end
            end
        elseif attackPattern == "artillery" then
            -- Artillery: cannot attack adjacent cells, orthogonal only, can shoot through Rocks
            local attackRange = unitsInfo:getUnitAttackRange(unit, "GET_ATTACK_CELLS_FOR_UNIT_AT_POSITION_ARTILLERY")
            for _, dir in ipairs(self:getOrthogonalDirections()) do
                for dist = minRange, attackRange do
                    local r = row + (dir.row * dist)
                    local c = col + (dir.col * dist)

                    if self:isInsideBoard(r, c, state) then
                        local targetUnit = self:getUnitAtPosition(state, r, c)

                        if targetUnit and targetUnit.player ~= unit.player then
                            table.insert(cells, {row = r, col = c})
                        end

                        if state.neutralBuildings then
                            for _, building in ipairs(state.neutralBuildings) do
                                if building.row == r and building.col == c then
                                    table.insert(cells, {row = r, col = c})
                                    break
                                end
                            end
                        end
                    end
                end
            end
        else
            local attackRange = unitsInfo:getUnitAttackRange(unit, "GET_ATTACK_CELLS_FOR_UNIT_AT_POSITION")
            if attackRange and attackRange >= minRange then
                -- Normal attack handling for other units
                for _, dir in ipairs(self:getOrthogonalDirections()) do
                    for dist = minRange, attackRange do
                        local r = row + (dir.row * dist)
                        local c = col + (dir.col * dist)

                        if self:isInsideBoard(r, c, state) then
                            local targetUnit = self:getUnitAtPosition(state, r, c)
                            if targetUnit and targetUnit.player ~= unit.player then
                                table.insert(cells, {row = r, col = c})
                            end
                        end
                    end
                end
            end
        end

        return cells
    end

    -- Helper function to find positions that are blocking line of sight between two points
    function aiClass:getBlockingPositions(state, from, to)
        local blockingPositions = {}

        -- Calculate the line between from and to positions
        local dx = to.col - from.col
        local dy = to.row - from.row

        -- CRITICAL: Only orthogonal lines allowed - no diagonal line of sight
        -- If both dx and dy are non-zero, this is a diagonal line which is NOT ALLOWED
        if dx ~= ZERO and dy ~= ZERO then
            -- For orthogonal-only games, diagonal lines are invalid
            -- Return all positions as blocking to prevent diagonal line of sight
            return {{row = NEGATIVE_ONE, col = NEGATIVE_ONE}} -- Invalid position to block any diagonal line of sight
        end

        local steps = math.abs(dx) + math.abs(dy)  -- Manhattan distance only

        if steps == ZERO then
            return blockingPositions  -- Same position, no blocking
        end

        -- Only horizontal or vertical lines allowed
        if dx ~= ZERO then
            -- Horizontal line only
            local stepDirection = dx > ZERO and MIN_HP or NEGATIVE_MIN_HP
            for i = ONE, math.abs(dx) - ONE do  -- Exclude start and end points
                local checkCol = from.col + (stepDirection * i)
                local checkRow = from.row
            
                -- Check if there's a unit at this position
                local unitAtPos = self:getUnitAtPosition(state, checkRow, checkCol)
                if unitAtPos then
                    table.insert(blockingPositions, {row = checkRow, col = checkCol})
                end
            end
        elseif dy ~= ZERO then
            -- Vertical line only
            local stepDirection = dy > ZERO and MIN_HP or NEGATIVE_MIN_HP
            for i = ONE, math.abs(dy) - ONE do  -- Exclude start and end points
                local checkRow = from.row + (stepDirection * i)
                local checkCol = from.col
            
                -- Check if there's a unit at this position
                local unitAtPos = self:getUnitAtPosition(state, checkRow, checkCol)
                if unitAtPos then
                    table.insert(blockingPositions, {row = checkRow, col = checkCol})
                end
            end
        end

        return blockingPositions
    end

    -- Obvious action 18: Find hub space creation move
    function aiClass:findHubSpaceCreationMove(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end
        if not state or not state.commandHubs or not state.commandHubs[aiPlayer] then
            return nil -- No hub found
        end

        local hub = state.commandHubs[aiPlayer]
        local directions = self:getOrthogonalDirections()

        -- Iterate over each adjacent direction around the hub
        for _, dir in ipairs(directions) do
            local adjRow = hub.row + dir.row
            local adjCol = hub.col + dir.col

            -- Check if there is one of our units occupying that cell
            local occupyingUnit = self:getUnitAtPosition(state, adjRow, adjCol)
            local occupyingKey = occupyingUnit and self:getUnitKey(occupyingUnit)
            if occupyingUnit and occupyingUnit.player == aiPlayer and not (occupyingKey and usedUnits[occupyingKey]) then
                -- Get possible move cells for that unit
                local moveCells = self:getValidMoveCells(state, occupyingUnit.row, occupyingUnit.col)

                -- First, try to find beneficial moves that also free hub space
                local beneficialMoves = {}
                local safeMoves = {}

                -- Evaluate all possible moves and categorize them
                for _, cell in ipairs(moveCells) do
                    local dist = math.abs(cell.row - hub.row) + math.abs(cell.col - hub.col)
                    -- Only consider cells that are NOT adjacent to the hub (to avoid swapping)
                    if dist > ONE and self:isMoveSafe(state, occupyingUnit, {row = cell.row, col = cell.col}, {checkVulnerable = true}) then
                        -- Calculate positional value for this move
                        local currentValue = self:getPositionalValue(state, occupyingUnit)
                        local tempUnitForEval = {
                            row = cell.row,
                            col = cell.col,
                            name = occupyingUnit.name,
                            player = occupyingUnit.player,
                            currentHp = occupyingUnit.currentHp,
                            startingHp = occupyingUnit.startingHp
                        }
                        local newValue = self:getPositionalValue(state, tempUnitForEval)

                        local simulatedState = self:applyMove(state, {
                            type = "move",
                            unit = {row = occupyingUnit.row, col = occupyingUnit.col},
                            target = {row = cell.row, col = cell.col}
                        })
                        local mobilityBonus = self:calculateMobilityBonus(state, simulatedState, occupyingUnit, cell)

                        local moveData = {
                            cell = cell,
                            currentValue = currentValue,
                            newValue = newValue,
                            benefit = (newValue - currentValue) + mobilityBonus,
                            mobilityBonus = mobilityBonus
                        }

                        -- Categorize as beneficial or just safe
                        if newValue > currentValue then
                            table.insert(beneficialMoves, moveData)
                        else
                            table.insert(safeMoves, moveData)
                        end
                    end
                end

                -- Sort beneficial moves by benefit (highest first)
                self:sortScoredEntries(beneficialMoves, {
                    scoreField = "benefit",
                    descending = true
                })

                -- Try beneficial moves first, then fallback to safe moves
                local movesToTry = {}
                for _, move in ipairs(beneficialMoves) do
                    table.insert(movesToTry, move)
                end
                for _, move in ipairs(safeMoves) do
                    table.insert(movesToTry, move)
                end

                -- Return the best move (beneficial first, then safe)
                if #movesToTry > ZERO then
                    local bestMove = movesToTry[ONE]
                    local moveAction = {
                        type = "move",
                        unit = {row = occupyingUnit.row, col = occupyingUnit.col},
                        target = {row = bestMove.cell.row, col = bestMove.cell.col}
                    }
                    return {unit = occupyingUnit, action = moveAction}
                end
            end
        end

        -- No suitable unit found or no valid moves
        return nil
    end

    -- Helper function to check if a unit would die next turn in a specific position
    function aiClass:wouldUnitDieNextTurn(state, unit)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return false
        end
        local oneActionDamages = {}
        local twoActionDamages = {}

        local function getDamage(attacker, defender)
            local damage = select(ONE, self:calculateDamage(attacker, defender))
            return damage or ZERO
        end

        local function addOneActionDamage(damage)
            if damage and damage > ZERO then
                table.insert(oneActionDamages, damage)
            end
        end

        local function addTwoActionDamage(damage)
            if damage and damage > ZERO then
                table.insert(twoActionDamages, damage)
            end
        end

        local unitRow = unit.row
        local unitCol = unit.col

        -- Track debug output when evaluating low-HP corvette units.
        local isDebugUnit = (self:unitHasTag(unit, "corvette") and (unit.currentHp or unit.hp or ZERO) <= TWO)

        -- Gather all possible enemy threats, categorized by action cost
        for _, enemy in ipairs(state.units) do
            if enemy.player ~= aiPlayer and not self:isHubUnit(enemy) and not self:isObstacleUnit(enemy) then
                local distance = math.abs(unitRow - enemy.row) + math.abs(unitCol - enemy.col)
                local immediateDamage = ZERO
                local moveAttackDamage = ZERO
                local enemyPattern = self:getAttackPattern(enemy)

                if enemyPattern == "corvette" then
                    local hasLOS = self:hasLineOfSightIgnoringUnit(state, enemy, unit, unit)
                    if distance >= TWO and distance <= THREE and hasLOS then
                        immediateDamage = math.max(immediateDamage, getDamage(enemy, unit))
                        if isDebugUnit and DEBUG and DEBUG.AI then
                            print(string.format("  THREAT CHECK: Enemy %s @ (%d,%d) can DIRECTLY attack (%d,%d) - dist=%d, dmg=%d",
                                enemy.name, enemy.row, enemy.col, unitRow, unitCol, distance, immediateDamage))
                        end
                    end

                    local moveCells = self:getEnemyMoveCellsWithVacatedTile(state, enemy, unit)
                    for _, moveCell in ipairs(moveCells) do
                        local moveDistance = math.abs(unitRow - moveCell.row) + math.abs(unitCol - moveCell.col)
                        if moveDistance >= TWO and moveDistance <= THREE then
                            local hasLOS = self:hasLineOfSightIgnoringUnit(
                                state,
                                {row = moveCell.row, col = moveCell.col},
                                unit,
                                unit
                            )

                            if hasLOS then
                                moveAttackDamage = math.max(moveAttackDamage, getDamage(enemy, unit))
                            end
                        end
                    end
                elseif enemyPattern == "artillery" then
                    if distance >= TWO and distance <= THREE then
                        local rowDiff = math.abs(unitRow - enemy.row)
                        local colDiff = math.abs(unitCol - enemy.col)
                        local isOrthogonal = (rowDiff == ZERO and colDiff >= TWO and colDiff <= THREE) or (colDiff == ZERO and rowDiff >= TWO and rowDiff <= THREE)

                        if isOrthogonal and self:hasLineOfSight(state, enemy, unit) then
                            immediateDamage = math.max(immediateDamage, getDamage(enemy, unit))
                        end
                    end

                    local moveCells = self:getEnemyMoveCellsWithVacatedTile(state, enemy, unit)

                    for _, moveCell in ipairs(moveCells) do
                        local moveDistance = math.abs(unitRow - moveCell.row) + math.abs(unitCol - moveCell.col)
                        if moveDistance == ONE then
                            moveAttackDamage = math.max(moveAttackDamage, getDamage(enemy, unit))
                        end
                    end
                else
                    if distance == ONE then
                        immediateDamage = math.max(immediateDamage, getDamage(enemy, unit))
                    end

                    local moveCells = self:getEnemyMoveCellsWithVacatedTile(state, enemy, unit)

                    for _, moveCell in ipairs(moveCells) do
                        local moveDistance = math.abs(unitRow - moveCell.row) + math.abs(unitCol - moveCell.col)
                        if moveDistance == ONE then
                            moveAttackDamage = math.max(moveAttackDamage, getDamage(enemy, unit))
                        end
                    end
                end

                addOneActionDamage(immediateDamage)
                addTwoActionDamage(moveAttackDamage)
            end
        end

        -- Commandant adjacency threat (does not consume actions)
        if state.commandHubs then
            for playerNum, hub in pairs(state.commandHubs) do
                if hub and playerNum ~= aiPlayer then
                    local distance = math.abs(unitRow - hub.row) + math.abs(unitCol - hub.col)
                    if distance <= ONE then
                        local hubUnit = {
                            name = "Commandant",
                            player = playerNum,
                            row = hub.row,
                            col = hub.col,
                            currentHp = hub.currentHp,
                            startingHp = hub.startingHp
                        }
                        addOneActionDamage(getDamage(hubUnit, unit))
                    end
                end
            end
        end

        table.sort(oneActionDamages, function(a, b) return a > b end)
        table.sort(twoActionDamages, function(a, b) return a > b end)

        local unitHp = unit.currentHp or unit.hp or ZERO

        -- Two-action threats (single move+attack combo)
        local highestTwoActionDamage = twoActionDamages[ONE] or ZERO
        if highestTwoActionDamage >= unitHp then
            return true
        end

        -- Up to two single-action threats (two separate attacks)
        local firstOneAction = oneActionDamages[ONE] or ZERO
        local secondOneAction = oneActionDamages[TWO] or ZERO
        if (firstOneAction + secondOneAction) >= unitHp then
            return true
        end

        return false
    end

    -- Get unit at specific grid position
    function aiClass:getUnitAt(row, col)
        if not self.grid or not row or not col then return nil end

        -- Try to get unit from grid if grid has getUnitAt method
        if self.grid.getUnitAt then
            return self.grid:getUnitAt(row, col)
        end

        -- Fallback: search through grid cells if grid is a 2D array
        if self.grid[row] and self.grid[row][col] then
            return self.grid[row][col].unit
        end

        return nil
    end

    function aiClass:validateAndFixUnitStates(state)
        if not state or not state.units then return state end

        for _, unit in ipairs(state.units) do
            -- Fix HP values
            if not unit.currentHp or unit.currentHp < ZERO then
                unit.currentHp = ZERO
            end

            if not unit.startingHp or unit.startingHp <= ZERO then
                unit.startingHp = unit.currentHp > ZERO and unit.currentHp or MIN_HP
            end

            if unit.currentHp > unit.startingHp then
                unit.currentHp = unit.startingHp
            end

            -- Fix flags
            if unit.corvetteDamageFlag == nil then
                unit.corvetteDamageFlag = false
            end
        
            if unit.artilleryDamageFlag == nil then
                unit.artilleryDamageFlag = false
            end

            -- Fix action states
            if unit.hasActed == nil then
                unit.hasActed = false
            end

            if unit.hasMoved == nil then
                unit.hasMoved = false
            end

            if unit.actionsUsed == nil then
                unit.actionsUsed = ZERO
            end
        end

        for player, hub in pairs(state.commandHubs or {}) do
        end
        return state
    end

    function aiClass:getFreeCellsAroundHub(state, hub, skipGridCheck)
        local freeCells = {}
        local gridSize = self:getBoardSize(state)

        for _, dir in ipairs(self:getOrthogonalDirections()) do
            local row = hub.row + dir.row
            local col = hub.col + dir.col
            if row >= ONE and row <= gridSize and col >= ONE and col <= gridSize then
                local blockedInState = state and self.aiState.isPositionBlocked(state, row, col)
                local blockedOnGrid = (not skipGridCheck) and self.grid and self.grid.getUnitAt and self.grid:getUnitAt(row, col) ~= nil
                if not blockedInState and not blockedOnGrid then
                    table.insert(freeCells, {row = row, col = col})
                end
            end
        end

        return freeCells
    end

    -- Obvious action 28: Find Rock attacks (Fallback/Desperation priority) (Check adjacent safe cells and possible enemy move+attack range)
    function aiClass:findNeutralBuildingAttacks(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        local doctrineConfig = self:getDoctrineScoreConfig()
        local rockDoctrine = doctrineConfig.ROCK_ATTACK or {}
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        local neutralAttackCandidates = {}
        local neutralScoreConfig = self:getNeutralBuildingAttackScoreConfig()
        local defaultNeutralScoreConfig = DEFAULT_SCORE_PARAMS.NEUTRAL_BUILDING_ATTACK or {}

        local baseDamageMult = valueOr(neutralScoreConfig.BASE_DAMAGE_MULT, defaultNeutralScoreConfig.BASE_DAMAGE_MULT)
        local blockedMoveThreshold = valueOr(neutralScoreConfig.BLOCKED_UNIT_SAFE_MOVE_THRESHOLD, defaultNeutralScoreConfig.BLOCKED_UNIT_SAFE_MOVE_THRESHOLD)
        local blockedUnitBonus = valueOr(neutralScoreConfig.BLOCKED_UNIT_BONUS, defaultNeutralScoreConfig.BLOCKED_UNIT_BONUS)
        local enemyHubAdjBonus = valueOr(neutralScoreConfig.ENEMY_HUB_ADJ_BONUS, defaultNeutralScoreConfig.ENEMY_HUB_ADJ_BONUS)
        local corvetteLosMaxHubDistance = valueOr(neutralScoreConfig.CORVETTE_LOS_MAX_HUB_DISTANCE, defaultNeutralScoreConfig.CORVETTE_LOS_MAX_HUB_DISTANCE)
        local corvetteLosBonus = valueOr(neutralScoreConfig.CORVETTE_LOS_BONUS, defaultNeutralScoreConfig.CORVETTE_LOS_BONUS)

        local legalAttacks = self:collectLegalActions(state, {
            aiPlayer = aiPlayer,
            usedUnits = usedUnits,
            includeMove = false,
            includeAttack = true,
            includeRepair = false,
            includeDeploy = false
        })

        local corvettes = {}
        for _, boardUnit in ipairs(state.units or {}) do
            if boardUnit.player == aiPlayer and self:unitHasTag(boardUnit, "corvette") then
                corvettes[#corvettes + ONE] = boardUnit
            end
        end
        local hasCorvette = #corvettes > ZERO

        local safeMoveCountCache = {}
        local function getSafeMoveCount(unit)
            local unitKey = self:getUnitKey(unit) or string.format("%s_%d_%d", tostring(unit.name or "u"), unit.row or ZERO, unit.col or ZERO)
            local cached = safeMoveCountCache[unitKey]
            if cached ~= nil then
                return cached
            end

            local safeMoveCount = ZERO
            local movePositions = self:getValidMoveCells(state, unit.row, unit.col) or {}
            for _, movePos in ipairs(movePositions) do
                if self:isMoveSafe(state, unit, movePos, {checkVulnerable = true}) then
                    safeMoveCount = safeMoveCount + ONE
                end
            end
            safeMoveCountCache[unitKey] = safeMoveCount
            return safeMoveCount
        end

        for _, entry in ipairs(legalAttacks) do
            local unit = entry.unit
            local target = entry.target
            local attackAction = entry.action

            if entry.type == "attack" and unit and target and attackAction and self:isObstacleUnit(target) then
                local damage = self:calculateDamage(unit, target)
                if damage > ZERO then
                    local strategicRock, strategicReason = self:isStrategicRockAttack(state, attackAction, {
                        aiPlayer = aiPlayer,
                        target = target
                    })
                    if valueOr(rockDoctrine.ONLY_IF_STRATEGIC, true) and not strategicRock then
                        self.fillerAttackAvoidedCount = (self.fillerAttackAvoidedCount or ZERO) + ONE
                        goto continue_neutral_attack_candidate
                    end

                    local targetCurrentHp = target.currentHp or MIN_HP
                    local willDestroy = damage >= targetCurrentHp

                    local safetyCheckPos
                    if willDestroy then
                        safetyCheckPos = {row = target.row, col = target.col}
                    else
                        safetyCheckPos = {row = unit.row, col = unit.col}
                    end

                    local isSafe = self:isMoveSafe(state, unit, safetyCheckPos, {checkVulnerable = true})
                    if isSafe then
                        local reason = nil
                        local priority = damage * baseDamageMult

                        local safeMoveCount = getSafeMoveCount(unit)
                        if safeMoveCount <= blockedMoveThreshold then
                            reason = "blocked_unit"
                            priority = priority + blockedUnitBonus
                        end

                        if enemyHub then
                            local distToEnemyHub = math.abs(target.row - enemyHub.row) + math.abs(target.col - enemyHub.col)
                            if distToEnemyHub == ONE then
                                reason = "adjacent_to_enemy_hub"
                                priority = priority + enemyHubAdjBonus
                            end

                            if hasCorvette and distToEnemyHub <= corvetteLosMaxHubDistance then
                                for _, corvette in ipairs(corvettes) do
                                    if self:isBlockingLineOfSight(corvette, enemyHub, target) then
                                        reason = "blocking_corvette_los"
                                        priority = priority + corvetteLosBonus
                                        break
                                    end
                                end
                            end
                        end

                        if reason or strategicRock then
                            if strategicRock then
                                priority = priority + 180
                            end
                            neutralAttackCandidates[#neutralAttackCandidates + ONE] = {
                                unit = unit,
                                target = target,
                                action = attackAction,
                                damage = damage,
                                reason = reason or strategicReason or "strategic_rock_attack",
                                strategicRock = strategicRock == true,
                                strategicReason = strategicReason,
                                priority = priority
                            }
                        end
                    end
                end
            end
            ::continue_neutral_attack_candidate::
        end

        -- Sort by priority (highest damage, special reasons, unit survival)
        self:sortScoredEntries(neutralAttackCandidates, {
            scoreField = "priority",
            descending = true
        })

        if #neutralAttackCandidates > ZERO then
            -- Use randomization to select from equal-priority attacks
            local selectedAttack = self:randomizeEqualValueActions(neutralAttackCandidates, "priority")
            if selectedAttack then
                return selectedAttack
            end
        else
            return nil
        end
    end

    -- Obvious action 29: Find risky expanded attacks (1+ damage, avoid suicidal adjacent cell, prioritize Commandant)
    function aiClass:findRiskyExpandedAttacks(state, usedUnits, sequence)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end
        local isSequenceZero = (sequence and #sequence == ZERO) or false
        local riskyExpandedConfig = self:getKillRiskScoreConfig().RISKY_EXPANDED or {}
        local minDamage = riskyExpandedConfig.MIN_DAMAGE or MIN_HP
        local candidates = self:collectRiskyAttackCandidates(state, usedUnits, {
            aiPlayer = aiPlayer,
            moveThenAttack = false,
            riskConfigKey = "RISKY_EXPANDED",
            includeFriendlyFireCheck = true,
            requireSafeAttack = true,
            useRiskDamageEligibility = false,
            minDamage = minDamage,
            rejectSpecial = false,
            rejectLeaveAtOneHp = false,
            scoreFn = function(unit, target, damage)
                return self:getCanonicalAttackScore(state, unit, target, damage, {
                    includeTargetValue = true,
                    useBaseTargetValue = true,
                    includeOwnHubAdjBonus = true,
                    aiPlayer = aiPlayer
                })
            end
        })

        -- Return logic based on sequence
        if #candidates == ZERO then
            return nil
        end
        if isSequenceZero then
            return candidates
        end
        return candidates[ONE]
    end

    -- Obvious actions 21.1: Beneficial Moves (Check adjacent safe cells only)
    function aiClass:findNotSoSafeBeneficialMoves(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        local beneficialMoves = {}
        local componentWeights = self:getPositionalComponentWeights()
        local moveEntries = self:collectMoveEvaluationEntries(state, usedUnits, {
            aiPlayer = aiPlayer,
            unitEligibility = {requireNotMoved = true, disallowRock = true},
            movePolicy = "safe",
            requireSimulation = false
        })

        for _, entry in ipairs(moveEntries) do
            local unit = entry.unit
            local moveCell = entry.moveCell
            local isVulnerable = self:isVulnerableMovePosition(state, unit, moveCell)
            local _, _, positionalDelta = self:getMovePositionalDelta(state, unit, moveCell)

            local tempUnit = {
                row = moveCell.row,
                col = moveCell.col,
                name = unit.name,
                player = unit.player,
                currentHp = unit.currentHp,
                startingHp = unit.startingHp
            }

            local pathOpeningBonus = self:calculatePathOpeningBonus(state, unit, moveCell)
            local reachabilityBonus = self:calculateNextTurnReachabilityBonus(state, unit, moveCell)
            local improvement = positionalDelta + pathOpeningBonus + reachabilityBonus

            local immediateDamagePenalty = ZERO
            local riskyPenaltyConfig = self:getPositionalScoreConfig().RISKY_PENALTY or {}
            local defaultRiskyPenaltyConfig = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).RISKY_PENALTY or {})
            local adjacentEnemyPositions = {
                {row = moveCell.row - ONE, col = moveCell.col},
                {row = moveCell.row + ONE, col = moveCell.col},
                {row = moveCell.row, col = moveCell.col - ONE},
                {row = moveCell.row, col = moveCell.col + ONE}
            }

            for _, adjPos in ipairs(adjacentEnemyPositions) do
                local adjacentEnemy = self:getUnitAtPosition(state, adjPos.row, adjPos.col)
                if self:isAttackableEnemyUnit(adjacentEnemy, aiPlayer) then
                    local damage = unitsInfo:calculateAttackDamage(adjacentEnemy, tempUnit)
                    if damage and damage > ZERO then
                        local immediateDamagePerHp = valueOr(riskyPenaltyConfig.IMMEDIATE_DAMAGE_PER_HP, defaultRiskyPenaltyConfig.IMMEDIATE_DAMAGE_PER_HP)
                        immediateDamagePenalty = immediateDamagePenalty + (damage * immediateDamagePerHp)
                    end
                end
            end

            local threatValue = self:calculateNextTurnThreatValue(state, unit, moveCell)
            local repairDroneBonus = self:getRepairAdjacencyBonus(state, unit, moveCell, aiPlayer)

            local vulnerabilityPenalty = ZERO
            if isVulnerable then
                vulnerabilityPenalty = valueOr(
                    riskyPenaltyConfig.VULNERABLE_VALUE,
                    valueOr(defaultRiskyPenaltyConfig.VULNERABLE_VALUE, ZERO)
                )
            end
            local lowImpactPenalty = self:getLowImpactMovePenalty(state, unit, moveCell, aiPlayer)
            local rangedAdjacencyPenalty = self:getRangedAdjacencyPenalty(state, tempUnit, moveCell, aiPlayer)

            local scoredMove = self:scoreStrategicMove(state, unit, moveCell, {
                aiPlayer = aiPlayer,
                improvement = improvement,
                threatState = state,
                threatUnit = unit,
                threatValue = threatValue,
                repairState = state,
                repairUnit = unit,
                repairBonus = repairDroneBonus,
                componentWeights = componentWeights,
                extraPenalty = immediateDamagePenalty + vulnerabilityPenalty + lowImpactPenalty + rangedAdjacencyPenalty,
                thresholdPolicy = "risky"
            })

            if scoredMove.finalScore >= scoredMove.threshold then
                table.insert(beneficialMoves, {
                    unit = unit,
                    action = {
                        type = "move",
                        unit = {row = unit.row, col = unit.col},
                        target = {row = moveCell.row, col = moveCell.col}
                    },
                    value = scoredMove.finalScore,
                    threatValue = scoredMove.threatValue,
                    positionalValue = improvement,
                    riskLevel = isVulnerable and "high" or "moderate"
                })
            end
        end

        self:sortScoredEntries(beneficialMoves, {
            scoreField = "value",
            descending = true
        })
        return beneficialMoves
    end

    function aiClass:getNoGateKillAttackValue(state, aiPlayer, target, damage)
        local noGateConfig = (self:getKillRiskScoreConfig().NO_GATE or {})
        local defaultNoGateConfig = ((DEFAULT_SCORE_PARAMS.KILL_RISK or {}).NO_GATE or {})
        local defaultAttackConfig = DEFAULT_SCORE_PARAMS.ATTACK_DECISION or {}
        local attackConfig = self:getScoreConfig().ATTACK_DECISION or {}
        local targetValue = self:getUnitBaseValue(target, state)

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        if enemyHub then
            local distToEnemyHub = math.abs(target.row - enemyHub.row) + math.abs(target.col - enemyHub.col)
            if distToEnemyHub == ONE then
                targetValue = targetValue + valueOr(noGateConfig.ENEMY_HUB_ADJ_BONUS, defaultNoGateConfig.ENEMY_HUB_ADJ_BONUS)
            end
        end

        return damage * valueOr(attackConfig.NO_GATE_DAMAGE_MULT, defaultAttackConfig.NO_GATE_DAMAGE_MULT) + targetValue
    end

    -- Obvious action 30: Find kill shots without safety gates (guaranteed kills)
    function aiClass:findKillShotsNoGate(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end

        local noGateConfig = (self:getKillRiskScoreConfig().NO_GATE or {})
        local defaultNoGateConfig = ((DEFAULT_SCORE_PARAMS.KILL_RISK or {}).NO_GATE or {})
        local minDamage = valueOr(noGateConfig.MIN_DAMAGE, defaultNoGateConfig.MIN_DAMAGE)

        return self:collectKillAttackCandidates(state, usedUnits, {
            aiPlayer = aiPlayer,
            moveThenAttack = false,
            minDamage = minDamage,
            scoreField = "attackValue",
            includeTargetHp = true,
            targetHpFallbackTag = "NO_GATE_KILL_TARGET_HP",
            scoreFn = function(unit, target, damage)
                return self:getNoGateKillAttackValue(state, aiPlayer, target, damage)
            end
        })
    end

    -- Priority 21.2b: Find move+kill combos without safety gates
    function aiClass:findMoveKillShotsNoGate(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end

        local noGateConfig = (self:getKillRiskScoreConfig().NO_GATE or {})
        local defaultNoGateConfig = ((DEFAULT_SCORE_PARAMS.KILL_RISK or {}).NO_GATE or {})
        local minDamage = valueOr(noGateConfig.MIN_DAMAGE, defaultNoGateConfig.MIN_DAMAGE)

        return self:collectKillAttackCandidates(state, usedUnits, {
            aiPlayer = aiPlayer,
            moveThenAttack = true,
            minDamage = minDamage,
            scoreField = "attackValue",
            includeTargetHp = true,
            targetHpFallbackTag = "NO_GATE_MOVE_KILL_TARGET_HP",
            scoreFn = function(unit, target, damage)
                return self:getNoGateKillAttackValue(state, aiPlayer, target, damage)
            end
        })
    end

    function aiClass:evaluateRiskyMoveComponents(state, unit, movePos, aiPlayer)
        local resolvedAiPlayer = aiPlayer or self:getFactionId()
        if not resolvedAiPlayer or not state or not unit or not movePos then
            return {
                totalValue = ZERO,
                trapBonus = ZERO,
                reasonThreatBonus = ZERO
            }
        end

        local riskyMoveConfig = self:getRiskyMoveScoreConfig()
        local defaultRiskyMoveConfig = DEFAULT_SCORE_PARAMS.RISKY_MOVE or {}
        local threatScale = valueOr(riskyMoveConfig.THREAT_SCALE, defaultRiskyMoveConfig.THREAT_SCALE)

        local _, _, positionalImprovement = self:getMovePositionalDelta(state, unit, movePos)
        local pathOpeningBonus = self:calculatePathOpeningBonus(state, unit, movePos)
        local reachabilityBonus = self:calculateNextTurnReachabilityBonus(state, unit, movePos)

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(resolvedAiPlayer)]
        local ownHub = state.commandHubs and state.commandHubs[resolvedAiPlayer]
        local currentDistToEnemyHub = nil
        local newDistToEnemyHub = nil
        local hubPressureBonus = ZERO

        if enemyHub then
            currentDistToEnemyHub = math.abs(unit.row - enemyHub.row) + math.abs(unit.col - enemyHub.col)
            newDistToEnemyHub = math.abs(movePos.row - enemyHub.row) + math.abs(movePos.col - enemyHub.col)

            if newDistToEnemyHub < currentDistToEnemyHub then
                hubPressureBonus = hubPressureBonus
                    + ((currentDistToEnemyHub - newDistToEnemyHub)
                    * valueOr(riskyMoveConfig.FORWARD_PROGRESS_PER_TILE, defaultRiskyMoveConfig.FORWARD_PROGRESS_PER_TILE))
            end

            if newDistToEnemyHub == ONE then
                hubPressureBonus = hubPressureBonus
                    + valueOr(riskyMoveConfig.ENEMY_HUB_ADJ_BONUS, defaultRiskyMoveConfig.ENEMY_HUB_ADJ_BONUS)
            end
        end

        local trapBonus = self:calculateTrapBonus(state, unit, movePos)
        local projectedThreatValue = self:calculateNextTurnThreatValue(state, unit, movePos)
        local projectedThreatBonus = projectedThreatValue * threatScale
        local blockingBonus = self:calculateBlockingBonus(state, unit, movePos, enemyHub, ownHub)
        local reasonThreatBonus = self:calculateThreatBonus(state, unit, movePos)

        local totalValue = positionalImprovement
            + pathOpeningBonus
            + reachabilityBonus
            + hubPressureBonus
            + trapBonus
            + projectedThreatBonus
            + blockingBonus

        return {
            totalValue = totalValue,
            positionalImprovement = positionalImprovement,
            pathOpeningBonus = pathOpeningBonus,
            reachabilityBonus = reachabilityBonus,
            hubPressureBonus = hubPressureBonus,
            trapBonus = trapBonus,
            projectedThreatValue = projectedThreatValue,
            projectedThreatBonus = projectedThreatBonus,
            blockingBonus = blockingBonus,
            reasonThreatBonus = reasonThreatBonus,
            enemyHub = enemyHub,
            currentDistToEnemyHub = currentDistToEnemyHub,
            newDistToEnemyHub = newDistToEnemyHub
        }
    end

    -- Priority 22: Find risky moves (dangerous but strategic positions)
    function aiClass:findRiskyMoves(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end
        local candidates = {}
        local moveEntries = self:collectMoveEvaluationEntries(state, usedUnits, {
            aiPlayer = aiPlayer,
            movePolicy = "vulnerable",
            requireSimulation = false
        })

        for _, entry in ipairs(moveEntries) do
            local unit = entry.unit
            local movePos = entry.moveCell
            local evaluation = self:evaluateRiskyMoveComponents(state, unit, movePos, aiPlayer)
            local reason = self:getRiskyMoveReason(state, unit, movePos, evaluation)

            candidates[#candidates + ONE] = {
                unit = unit,
                action = {
                    type = "move",
                    unit = unit,
                    target = movePos
                },
                targetPos = movePos,
                moveValue = evaluation.totalValue,
                reason = reason
            }
        end

        if #candidates == ZERO then
            return nil
        end

        self:sortScoredEntries(candidates, {
            scoreField = "moveValue",
            descending = true
        })

        return candidates[ONE]
    end

    -- Calculate strategic value of a risky move position
    function aiClass:calculateRiskyMoveValue(state, unit, movePos, evaluation)
        local resolvedEvaluation = evaluation or self:evaluateRiskyMoveComponents(state, unit, movePos)
        return resolvedEvaluation and resolvedEvaluation.totalValue or ZERO
    end

    -- Calculate trap bonus: if enemy kills this unit, do they become vulnerable?
    function aiClass:calculateTrapBonus(state, unit, movePos)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ZERO
        end
        local trapBonus = ZERO
        local riskyMoveConfig = self:getRiskyMoveScoreConfig()
        local defaultRiskyMoveConfig = DEFAULT_SCORE_PARAMS.RISKY_MOVE or {}
    
        -- Check what enemy units could attack this position
        for _, enemyUnit in ipairs(state.units) do
            if self:isAttackableEnemyUnit(enemyUnit, aiPlayer, {excludeHub = true}) then
                local enemyAttackCells = self:getValidAttackCells(state, enemyUnit.row, enemyUnit.col)
            
                for _, attackCell in ipairs(enemyAttackCells) do
                    if attackCell.row == movePos.row and attackCell.col == movePos.col then
                        -- This enemy can attack our unit at movePos
                        -- Check if enemy would be vulnerable after attacking
                            local damage = unitsInfo:calculateAttackDamage(enemyUnit, unit)
                            if damage >= (unit.currentHp or MIN_HP) then
                                -- Enemy would kill our unit, check if they become vulnerable
                                local enemyPos = {row = enemyUnit.row, col = enemyUnit.col}
                            local enemyWouldBeVulnerable = (not self:isMoveSafe(state, enemyUnit, enemyPos))
                                    or self:isVulnerableMovePosition(state, enemyUnit, enemyPos)
                        
                            if enemyWouldBeVulnerable then
                                trapBonus = trapBonus + valueOr(riskyMoveConfig.TRAP_VULNERABLE_BONUS, defaultRiskyMoveConfig.TRAP_VULNERABLE_BONUS)  -- Good trap: enemy becomes vulnerable after killing us
                            end
                        end
                    end
                end
            end
        end
    
        return trapBonus
    end

    -- Calculate bonus for threatening high-value enemy units from new position
    function aiClass:calculateThreatBonus(state, unit, movePos)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ZERO
        end
        local riskyMoveConfig = self:getRiskyMoveScoreConfig()
        local defaultRiskyMoveConfig = DEFAULT_SCORE_PARAMS.RISKY_MOVE or {}
        local tempUnit = self:buildProjectedThreatUnit(unit, movePos.row, movePos.col)
        if not tempUnit then
            return ZERO
        end

        local threatBonus = self:evaluateThreatFromProjectedPosition(
            state,
            tempUnit,
            aiPlayer,
            {
                valueScale = valueOr(riskyMoveConfig.THREAT_TARGET_VALUE_SCALE, defaultRiskyMoveConfig.THREAT_TARGET_VALUE_SCALE),
                damageScale = valueOr(riskyMoveConfig.THREAT_DAMAGE_SCALE, defaultRiskyMoveConfig.THREAT_DAMAGE_SCALE)
            },
            nil,
            {
                requireTargetCoordinates = false,
                requireCurrentHp = false
            }
        )

        return threatBonus
    end

    -- Calculate bonus for blocking enemy paths or objectives
    function aiClass:calculateBlockingBonus(state, unit, movePos, enemyHub, ownHub)
        local blockingBonus = ZERO
        local riskyMoveConfig = self:getRiskyMoveScoreConfig()
        local defaultRiskyMoveConfig = DEFAULT_SCORE_PARAMS.RISKY_MOVE or {}
    
        if enemyHub and ownHub then
            -- Bonus for positioning between enemy hub and our hub
            local enemyToOwnDist = math.abs(enemyHub.row - ownHub.row) + math.abs(enemyHub.col - ownHub.col)
            local enemyToPosDist = math.abs(enemyHub.row - movePos.row) + math.abs(enemyHub.col - movePos.col)
            local posToOwnDist = math.abs(movePos.row - ownHub.row) + math.abs(movePos.col - ownHub.col)
        
            -- If we're roughly on the path between hubs
            if (enemyToPosDist + posToOwnDist) <= (enemyToOwnDist + ONE) then
                blockingBonus = blockingBonus + valueOr(riskyMoveConfig.BLOCKING_PATH_BONUS, defaultRiskyMoveConfig.BLOCKING_PATH_BONUS)  -- Bonus for blocking enemy advance
            end
        end
    
        return blockingBonus
    end

    -- Get reason description for risky move
    function aiClass:getRiskyMoveReason(state, unit, movePos, evaluation)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ""
        end
        local evaluated = evaluation or self:evaluateRiskyMoveComponents(state, unit, movePos, aiPlayer)
        local enemyHub = evaluated and evaluated.enemyHub or nil
    
        if enemyHub and evaluated.newDistToEnemyHub and evaluated.currentDistToEnemyHub then
            if evaluated.newDistToEnemyHub == ONE then
                return "threaten_enemy_hub"
            end
        
            if evaluated.newDistToEnemyHub < evaluated.currentDistToEnemyHub then
                return "advance_toward_enemy_hub"
            end
        end
    
        -- Check for trap potential
        if evaluated.trapBonus > ZERO then
            return "trap_setup"
        end
    
        -- Check for threat potential
        local riskyMoveConfig = self:getRiskyMoveScoreConfig()
        local defaultRiskyMoveConfig = DEFAULT_SCORE_PARAMS.RISKY_MOVE or {}
        if evaluated.reasonThreatBonus > valueOr(riskyMoveConfig.THREAT_REASON_THRESHOLD, defaultRiskyMoveConfig.THREAT_REASON_THRESHOLD) then
            return "threaten_enemies"
        end
    
        return "strategic_positioning"
    end

    -- Priority 23: Find desperate suicidal attacks (1+ damage, attacker may die)
    function aiClass:findDesperateAttacks(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end
        local desperateConfig = self:getKillRiskScoreConfig().DESPERATE or {}
        local minDamage = desperateConfig.MIN_DAMAGE or MIN_HP
        local candidates = self:collectRiskyAttackCandidates(state, usedUnits, {
            aiPlayer = aiPlayer,
            moveThenAttack = false,
            riskConfigKey = "DESPERATE",
            includeFriendlyFireCheck = true,
            requireSafeAttack = false,
            includeAttackerWillDie = true,
            useRiskDamageEligibility = false,
            minDamage = minDamage,
            rejectSpecial = false,
            rejectLeaveAtOneHp = false,
            scoreFn = function(unit, target, damage)
                return self:getCanonicalAttackScore(state, unit, target, damage, {
                    includeTargetValue = true,
                    useBaseTargetValue = true,
                    includeOwnHubAdjBonus = true,
                    aiPlayer = aiPlayer,
                    commandantBonus = self:getTargetPriority(target)
                })
            end
        })

        return candidates[ONE]
    end

    -- Helper function to check if a unit is blocking line of sight between two other units
    function aiClass:isBlockingLineOfSight(from, to, blocker)
        return self:isPositionBetweenOrthogonal(blocker, from, to)
    end

    --- Obvious action 23: Find blocking moves to interfere with enemy objectives
    function aiClass:findBlockingEnemyObjectives(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        if not state or not state.commandHubs then
            return nil
        end
        local enemyPlayer = self:getOpponentPlayer(aiPlayer)
        local aiHub = state.commandHubs[aiPlayer]
        local enemyHub = state.commandHubs[enemyPlayer]
    
        if not aiHub or not enemyHub then
            return nil
        end

        local enemyUnits = {}
        local allyUnits = {}
        for _, boardUnit in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(boardUnit, aiPlayer, {excludeHub = true}) then
                enemyUnits[#enemyUnits + ONE] = boardUnit
            elseif boardUnit.player == aiPlayer and not self:isHubUnit(boardUnit) then
                allyUnits[#allyUnits + ONE] = boardUnit
            end
        end

        if #enemyUnits == ZERO then
            return nil
        end

        local enemyHubFreeCells = self:getFreeCellsAroundHub(state, enemyHub, true) or {}
        local candidates = {}
        local blockingConfig = self:getBlockingObjectivesScoreConfig()
        local defaultBlockingConfig = DEFAULT_SCORE_PARAMS.BLOCKING_OBJECTIVES or {}
        local hubProximityThreshold = valueOr(blockingConfig.HUB_PROXIMITY_THRESHOLD, defaultBlockingConfig.HUB_PROXIMITY_THRESHOLD)
        local enemyHubBlockRange = valueOr(blockingConfig.ENEMY_HUB_BLOCK_RANGE, defaultBlockingConfig.ENEMY_HUB_BLOCK_RANGE)
        local enemySupplyAdjThreshold = valueOr(blockingConfig.ENEMY_SUPPLY_ADJ_THRESHOLD, defaultBlockingConfig.ENEMY_SUPPLY_ADJ_THRESHOLD)
    
    
        for _, unit in ipairs(state.units) do
            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits) then
                local moveCells = self:getValidMoveCells(state, unit.row, unit.col)
            
                for _, moveCell in ipairs(moveCells) do
                    local movePos = {row = moveCell.row, col = moveCell.col}
                
                    -- Skip suicidal moves
                    if self:isMoveSafe(state, unit, movePos) then
                        local blockingValue = ZERO
                        local blockingReason = "unknown"
                    
                        -- 1. Block enemy access to AI hub (high priority)
                        local distToAiHub = math.abs(movePos.row - aiHub.row) + math.abs(movePos.col - aiHub.col)
                        if distToAiHub <= hubProximityThreshold then
                            -- Check if this position blocks enemy paths to AI hub
                            for _, enemy in ipairs(enemyUnits) do
                                local enemyDistToAiHub = math.abs(enemy.row - aiHub.row) + math.abs(enemy.col - aiHub.col)
                                local enemyDistToBlockPos = math.abs(enemy.row - movePos.row) + math.abs(enemy.col - movePos.col)
                            
                                -- If we're between enemy and our hub
                                if enemyDistToBlockPos < enemyDistToAiHub and distToAiHub < enemyDistToAiHub then
                                    blockingValue = blockingValue + valueOr(blockingConfig.HUB_ACCESS_BONUS, defaultBlockingConfig.HUB_ACCESS_BONUS)
                                    blockingReason = "block_enemy_access_to_hub"
                                end
                            end
                        end
                    
                        -- 2. Block enemy attack lanes to AI units
                        for _, allyUnit in ipairs(allyUnits) do
                            if allyUnit ~= unit then
                                for _, enemy in ipairs(enemyUnits) do
                                    -- Check if move position blocks line of sight from enemy to ally
                                    if self:isPositionBetweenOrthogonal(movePos, {row = enemy.row, col = enemy.col}, {row = allyUnit.row, col = allyUnit.col}) then
                                        blockingValue = blockingValue + valueOr(blockingConfig.ATTACK_LANE_BONUS, defaultBlockingConfig.ATTACK_LANE_BONUS)
                                        blockingReason = "block_attack_lane"
                                    end
                                end
                            end
                        end
                    
                        -- 3. Block enemy movement corridors (medium priority)
                        local corridorBlocking = ZERO
                        for _, enemy in ipairs(enemyUnits) do
                            local enemyDistToMove = math.abs(enemy.row - movePos.row) + math.abs(enemy.col - movePos.col)
                            if enemyDistToMove == ONE then
                                corridorBlocking = corridorBlocking + valueOr(blockingConfig.CORRIDOR_DIST1_BONUS, defaultBlockingConfig.CORRIDOR_DIST1_BONUS)
                            elseif enemyDistToMove == TWO then
                                corridorBlocking = corridorBlocking + valueOr(blockingConfig.CORRIDOR_DIST2_BONUS, defaultBlockingConfig.CORRIDOR_DIST2_BONUS)
                            end
                        end
                    
                        if corridorBlocking > ZERO then
                            blockingValue = blockingValue + corridorBlocking
                            if blockingReason == "unknown" then
                                blockingReason = "block_movement_corridor"
                            end
                        end
                    
                        -- 4. Block enemy supply deployment (if near enemy hub)
                        local distToEnemyHub = math.abs(movePos.row - enemyHub.row) + math.abs(movePos.col - enemyHub.col)
                        if distToEnemyHub <= enemyHubBlockRange and #enemyHubFreeCells > ZERO then
                            -- Check if we're blocking potential supply deployment positions
                            for _, freeCell in ipairs(enemyHubFreeCells) do
                                local distToFreeCell = math.abs(movePos.row - freeCell.row) + math.abs(movePos.col - freeCell.col)
                                if distToFreeCell <= enemySupplyAdjThreshold then
                                    blockingValue = blockingValue + valueOr(blockingConfig.ENEMY_SUPPLY_BONUS, defaultBlockingConfig.ENEMY_SUPPLY_BONUS)
                                    blockingReason = "block_enemy_supply"
                                    break
                                end
                            end
                        end

                        if blockingValue > ZERO then
                            candidates[#candidates + ONE] = {
                                unit = unit,
                                action = {
                                    type = "move",
                                    unit = {row = unit.row, col = unit.col},
                                    target = {row = movePos.row, col = movePos.col}
                                },
                                blockingValue = blockingValue,
                                reason = blockingReason
                            }
                        end
                    end
                end
            end
        end

        if #candidates == ZERO then
            return nil
        end

        self:sortScoredEntries(candidates, {
            scoreField = "blockingValue",
            descending = true
        })

        return candidates[ONE]
    end

    -- Obvious action 24: Find random legal actions (including survival-focused actions)
    function aiClass:findRandomLegalActions(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return nil
        end

        local randomActionConfig = self:getRandomActionScoreConfig()
        local defaultRandomActionConfig = DEFAULT_SCORE_PARAMS.RANDOM_ACTION or {}
        local doctrineConfig = self:getDoctrineScoreConfig()
        local fallbackDoctrine = doctrineConfig.FALLBACK or {}
        local rockDoctrine = doctrineConfig.ROCK_ATTACK or {}
        local preferDeployOrPosition = valueOr(fallbackDoctrine.PREFER_DEPLOY_OR_POSITION, true)
        local rockPenalty = valueOr(fallbackDoctrine.ROCK_ATTACK_PENALTY, 4000)

        local legalActions = self:collectLegalActions(state, {
            aiPlayer = aiPlayer,
            usedUnits = usedUnits,
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true,
            allowFullHpHealerRepairException = false
        })

        local allActions = {}
        for _, entry in ipairs(legalActions) do
            local action = entry.action
            local unit = entry.unit
            local target = entry.target

            if action and entry.type == "move" and unit and action.target then
                if self:unitHasTag(unit, "healer") then
                    local healerMoveAllowed, healerRejectReason = self:isHealerMoveDoctrineAllowed(
                        state,
                        unit,
                        action.target,
                        aiPlayer,
                        {allowEmergencyDefense = true}
                    )
                    if not healerMoveAllowed then
                        if healerRejectReason == "frontline" or healerRejectReason == "orbit" then
                            self.healerFrontlineViolationRejected = (self.healerFrontlineViolationRejected or ZERO) + ONE
                        end
                        goto continue_random_action
                    end
                end
                if self:isRangedStandoffViolation(state, unit, action.target, aiPlayer) then
                    goto continue_random_action
                end
                if self:isMoveSafe(state, unit, action.target) then
                    table.insert(allActions, {
                        unit = unit,
                        action = action,
                        actionType = "safe_move",
                        reason = "survival_focused",
                        priority = (preferDeployOrPosition and 4 or ZERO)
                            + valueOr(randomActionConfig.SAFE_MOVE_PRIORITY, defaultRandomActionConfig.SAFE_MOVE_PRIORITY)
                    })
                end
            elseif action and entry.type == "attack" and unit and target then
                local damage = unitsInfo:calculateAttackDamage(unit, target)
                if damage >= ZERO and self:isAttackSafe(state, unit, target) then
                    local isRock = self:isObstacleUnit(target)
                    local rockStrategic = false
                    if isRock then
                        rockStrategic = self:isStrategicRockAttack(state, action, {
                            aiPlayer = aiPlayer,
                            target = target
                        })
                        if valueOr(rockDoctrine.ONLY_IF_STRATEGIC, true) and not rockStrategic then
                            self.fillerAttackAvoidedCount = (self.fillerAttackAvoidedCount or ZERO) + ONE
                            goto continue_random_action
                        end
                    end

                    local priority = damage > ZERO
                        and valueOr(randomActionConfig.SAFE_ATTACK_PRIORITY, defaultRandomActionConfig.SAFE_ATTACK_PRIORITY)
                        or valueOr(randomActionConfig.ZERO_DAMAGE_ATTACK_PRIORITY, defaultRandomActionConfig.ZERO_DAMAGE_ATTACK_PRIORITY)
                    if isRock and not rockStrategic then
                        priority = priority - rockPenalty
                    end
                    table.insert(allActions, {
                        unit = unit,
                        action = action,
                        actionType = "safe_attack",
                        reason = isRock and (rockStrategic and "strategic_rock_attack" or "rock_attack")
                            or (damage > ZERO and "damage_attack" or "zero_damage_attack"),
                        priority = priority
                    })
                end
            elseif action and entry.type == "repair" and target then
                local targetMaxHp = unitsInfo:getUnitHP(target, "RANDOM_ACTION_REPAIR_MAX_HP")
                local targetCurrentHp = target.currentHp or targetMaxHp
                if targetCurrentHp < targetMaxHp then
                    table.insert(allActions, {
                        unit = unit,
                        action = action,
                        actionType = "repair",
                        reason = "healing_repair",
                        priority = valueOr(randomActionConfig.HEALING_REPAIR_PRIORITY, defaultRandomActionConfig.HEALING_REPAIR_PRIORITY)
                    })
                end
            elseif action and entry.type == "supply_deploy" then
                table.insert(allActions, {
                        unit = nil,
                        action = action,
                        actionType = "supply_deploy",
                        reason = "deploy_supply",
                        priority = (preferDeployOrPosition and 3 or ZERO)
                            + valueOr(randomActionConfig.DEPLOY_PRIORITY, valueOr(defaultRandomActionConfig.DEPLOY_PRIORITY, ZERO))
                    })
            end
            ::continue_random_action::
        end

        if #allActions == ZERO then
            return nil
        end

        self:sortScoredEntries(allActions, {
            scoreField = "priority",
            descending = true
        })

        return allActions[ONE]
    end

    -- Obvious move 00 Winning Condition Actions (ABSOLUTE HIGHEST PRIORITY)
    function aiClass:findWinningConditionActions(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return nil
        end
        if not state or not state.units or not state.commandHubs then
            return nil
        end
        local enemyPlayer = self:getOpponentPlayer(aiPlayer)
        local winningConfig = self:getWinningScoreConfig()
        local defaultWinningConfig = DEFAULT_SCORE_PARAMS.WINNING or {}

        -- WINNING CONDITION 1: Can we destroy the enemy Commandant?
        -- Check: 1) Single attack, 2) Two attacks, 3) Move+attack, 4) Move+attack with two units
        local enemyHub = state.commandHubs[enemyPlayer]
        if enemyHub then
            local hubCurrentHp = enemyHub.currentHp
                or enemyHub.startingHp
                or valueOr(winningConfig.HUB_FALLBACK_HP, defaultWinningConfig.HUB_FALLBACK_HP)

            -- Strategy 1: Single unit can destroy hub with one attack
            local directHubKill = self:findDirectLethalAttackOnTarget(state, usedUnits, aiPlayer, enemyHub, {
                targetHp = hubCurrentHp,
                scoreFn = function(_, damage)
                    return damage
                end
            })

            if directHubKill then
                -- WINNING MOVE: Single attack destroys Commandant!
                self:logDecision("Priority00", string.format("WINNING: %s destroys enemy Commandant in a single attack! (Damage: %d, HP: %d)",
                    directHubKill.unit.name, directHubKill.damage, hubCurrentHp))
                return {
                    unit = directHubKill.unit,
                    action = directHubKill.action,
                    reason = "DESTROY_COMMANDANT_SINGLE_ATTACK",
                    damage = directHubKill.damage,
                    hubHp = hubCurrentHp
                }
            end

            -- Strategy 2: Two units can destroy hub with two attacks (no movement)
            local attackers = self:collectAttackersAgainstTarget(state, usedUnits, aiPlayer, enemyHub, {
                requirePositiveDamage = true
            })

            -- Check if two attackers can destroy hub
            if #attackers >= TWO then
                local bestHubCombo = self:findBestTwoAttackKillCombo(state, enemyHub, attackers, hubCurrentHp, {
                    requireSecondNotSolo = false,
                    requireFinisherSafe = false,
                    scoreFn = function(_, _, totalDamage)
                        return totalDamage
                    end
                })

                if bestHubCombo then
                    -- WINNING MOVE: Two attacks destroy Commandant!
                    self:logDecision("Priority00", string.format("WINNING: %s + %s destroy enemy Commandant! (Total Damage: %d, HP: %d)",
                        bestHubCombo.damager.name, bestHubCombo.killer.name, bestHubCombo.totalDamage, hubCurrentHp))
                    return {
                        unit = bestHubCombo.damager,
                        secondUnit = bestHubCombo.killer,
                        action = bestHubCombo.damageAction,
                        secondAction = bestHubCombo.killAction,
                        reason = "DESTROY_COMMANDANT_TWO_ATTACKS",
                        totalDamage = bestHubCombo.totalDamage,
                        hubHp = hubCurrentHp,
                        isTwoUnitCombo = true
                    }
                end
            end

            -- Strategy 3: Single unit move+attack to destroy hub
            local singleUnitMoveAttackWin = self:findWinningMoveAttackCombo(state, usedUnits, aiPlayer, enemyHub, hubCurrentHp, {
                singleUnitMode = true,
                scoreFn = function(_, _, damage)
                    return damage
                end
            })

            if singleUnitMoveAttackWin then
                -- WINNING MOVE: Move+attack destroys Commandant!
                self:logDecision("Priority00", string.format("WINNING: %s move+attack destroys enemy Commandant! (Damage: %d, HP: %d)",
                    singleUnitMoveAttackWin.mover.name, singleUnitMoveAttackWin.damage, hubCurrentHp))
                return {
                    unit = singleUnitMoveAttackWin.mover,
                    action = singleUnitMoveAttackWin.moveAction,
                    secondAction = singleUnitMoveAttackWin.attackAction,
                    reason = "DESTROY_COMMANDANT_MOVE_ATTACK",
                    damage = singleUnitMoveAttackWin.damage,
                    hubHp = hubCurrentHp,
                    isMoveAttackCombo = true
                }
            end

            -- Strategy 4: One unit moves, another unit (Cloudstriker/Artillery) attacks from range
            -- This is valid because: Action 1 = move, Action 2 = ranged attack (different units)
            local movePlusRangedWin = self:findWinningMoveAttackCombo(state, usedUnits, aiPlayer, enemyHub, hubCurrentHp, {
                singleUnitMode = false,
                requireShooterRanged = true,
                useSimulatedStateForShooter = true,
                scoreFn = function(_, _, damage)
                    return damage
                end
            })

            if movePlusRangedWin then
                -- WINNING MOVE: One unit moves (positioning), ranged unit attacks to destroy!
                self:logDecision("Priority00", string.format("WINNING: %s moves + %s attacks destroys Commandant! (Damage: %d, HP: %d)",
                    movePlusRangedWin.mover.name, movePlusRangedWin.shooter.name, movePlusRangedWin.damage, hubCurrentHp))
                return {
                    unit = movePlusRangedWin.mover,
                    secondUnit = movePlusRangedWin.shooter,
                    action = movePlusRangedWin.moveAction,
                    secondAction = movePlusRangedWin.attackAction,
                    reason = "DESTROY_COMMANDANT_MOVE_PLUS_RANGED_ATTACK",
                    damage = movePlusRangedWin.damage,
                    hubHp = hubCurrentHp,
                    isMoveAndRangedAttack = true
                }
            end
        end

        -- WINNING CONDITION 2: Can we kill the last enemy unit (if enemy has no supply units)?
        -- Count enemy units (excluding Commandant and Rock)
        local enemyUnits = {}

        for _, unit in ipairs(state.units) do
            if unit.player == enemyPlayer then
                if not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                    table.insert(enemyUnits, unit)
                end
            end
        end

        -- If there's only 1 enemy unit left (excluding Commandant), killing it might be a win condition
        if #enemyUnits == (winningConfig.LAST_ENEMY_UNIT_COUNT or MIN_HP) then
            local lastEnemyUnit = enemyUnits[ONE]

            local lastEnemyKill = self:findDirectLethalAttackOnTarget(state, usedUnits, aiPlayer, lastEnemyUnit, {
                scoreFn = function(_, damage)
                    return damage
                end
            })

            if lastEnemyKill then
                -- POTENTIAL WINNING MOVE: This kills the last enemy unit
                -- Note: This assumes enemy has no supply units to deploy
                self:logDecision("Priority00", string.format("POTENTIAL WINNING CONDITION: %s can kill last enemy unit %s! (Damage: %d, HP: %d)",
                    lastEnemyKill.unit.name, lastEnemyUnit.name, lastEnemyKill.damage, lastEnemyKill.targetHp))
                return {
                    unit = lastEnemyKill.unit,
                    action = lastEnemyKill.action,
                    reason = "KILL_LAST_ENEMY_UNIT",
                    damage = lastEnemyKill.damage,
                    targetHp = lastEnemyKill.targetHp,
                    targetName = lastEnemyUnit.name
                }
            end
        end

        return nil
    end

end

return M
