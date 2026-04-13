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
    function aiClass:getWeightedMoveStrategicScore(componentWeights, improvement, repairBonus, weightedThreatValue)
        local weights = componentWeights or self:getPositionalComponentWeights()
        local safeWeights = {
            improvement = valueOr(weights.improvement, ONE),
            repair = valueOr(weights.repair, ONE),
            threat = valueOr(weights.threat, ONE)
        }

        local weightedImprovement = valueOr(improvement, ZERO) * safeWeights.improvement
        local weightedRepair = valueOr(repairBonus, ZERO) * safeWeights.repair
        local weightedThreat = valueOr(weightedThreatValue, ZERO) * safeWeights.threat

        return weightedImprovement + weightedRepair + weightedThreat
    end

    function aiClass:isDrawUrgencyActive()
        return self.drawUrgencyMode and self.drawUrgencyMode.active
    end

    function aiClass:isDrawUrgencyCritical()
        return self.drawUrgencyMode and self.drawUrgencyMode.active and self.drawUrgencyMode.critical == true
    end

    function aiClass:isStalematePressureActive(state)
        local drawParams = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        local pressureConfig = drawParams.STALEMATE_PRESSURE or {}
        if pressureConfig.ENABLED == false then
            return false
        end
        local startStreak = math.max(ZERO, valueOr(pressureConfig.START_STREAK, ZERO))
        local turnsWithoutDamage = state and (state.turnsWithoutDamage or ZERO) or ZERO
        return turnsWithoutDamage >= startStreak
    end

    function aiClass:isRiskDamageEligible(unit, damage, sectionName)
        if not unit then
            return false
        end
        local killRisk = self:getKillRiskScoreConfig()
        local section = killRisk[sectionName] or {}
        local minDamage = section.MIN_DAMAGE
        local chipMin = section.CHIP_DAMAGE_MIN
        local allowRangedChip = section.ALLOW_RANGED_CHIP ~= false
        local allowDrawUrgencyChip = section.ALLOW_DRAW_URGENCY_CHIP ~= false

        if damage >= minDamage then
            return true
        end
        if allowRangedChip and self:unitHasTag(unit, "ranged") and damage >= chipMin then
            return true
        end
        if allowDrawUrgencyChip and self:isDrawUrgencyActive() and damage >= chipMin then
            return true
        end

        return false
    end

    function aiClass:getRepairAdjacencyBonus(boardState, unit, movePos, aiPlayer)
        if not boardState or not unit or not movePos then
            return ZERO
        end

        local positioningConfig = self:getPositionalScoreConfig()
        local repairConfig = positioningConfig.REPAIR_ADJACENCY or {}
        local baseBonus = repairConfig.BASE
        local missingHpMult = repairConfig.MISSING_HP_MULT
        local owner = aiPlayer or unit.player

        local unitCurrentHp = unit.currentHp or unitsInfo:getUnitHP(unit, "REPAIR_ADJ_BONUS_CURRENT")
        local unitMaxHp = unitsInfo:getUnitHP(unit, "REPAIR_ADJ_BONUS_MAX")
        if unitCurrentHp <= ZERO or unitCurrentHp >= unitMaxHp then
            return ZERO
        end

        local adjacentCells = {
            {row = movePos.row - ONE, col = movePos.col},
            {row = movePos.row + ONE, col = movePos.col},
            {row = movePos.row, col = movePos.col - ONE},
            {row = movePos.row, col = movePos.col + ONE}
        }

        for _, adjCell in ipairs(adjacentCells) do
            local adjacentUnit = self:getUnitAtPosition(boardState, adjCell.row, adjCell.col)
            if adjacentUnit and adjacentUnit.player == owner and self:unitHasTag(adjacentUnit, "healer") then
                local hpDeficit = unitMaxHp - unitCurrentHp
                return baseBonus + (hpDeficit * missingHpMult)
            end
        end

        return ZERO
    end

    function aiClass:getForwardPressureBonus(state, unit, movePos, aiPlayer)
        if not state or not unit or not movePos then
            return ZERO
        end

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        if not enemyHub then
            return ZERO
        end

        local pressureConfig = (self:getPositionalScoreConfig().FORWARD_PRESSURE or {})
        local closerPerTile = pressureConfig.CLOSER_PER_TILE
        local closeRange = pressureConfig.CLOSE_RANGE
        local closeRangeBonus = pressureConfig.CLOSE_RANGE_BONUS
        local retreatPerTile = pressureConfig.RETREAT_PER_TILE

        local currentDist = math.abs(unit.row - enemyHub.row) + math.abs(unit.col - enemyHub.col)
        local newDist = math.abs(movePos.row - enemyHub.row) + math.abs(movePos.col - enemyHub.col)
        local distDelta = currentDist - newDist
        local score = ZERO

        if distDelta > ZERO then
            score = score + (distDelta * closerPerTile)
            if newDist <= closeRange then
                score = score + closeRangeBonus
            end
        elseif distDelta < ZERO then
            score = score + (distDelta * retreatPerTile)
        end

        return score
    end

    function aiClass:getStalematePressureBonus(state, unit, movePos, aiPlayer)
        if not state or not unit or not movePos then
            return ZERO
        end

        local drawParams = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        local pressureConfig = drawParams.STALEMATE_PRESSURE or {}
        if pressureConfig.ENABLED == false then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end

        if self:isOwnHubThreatened(state, owner) and not valueOr(pressureConfig.ALLOW_WHEN_HUB_THREATENED, false) then
            return ZERO
        end

        local turnsWithoutDamage = state.turnsWithoutDamage or ZERO
        local startStreak = math.max(ZERO, valueOr(pressureConfig.START_STREAK, ZERO))
        if turnsWithoutDamage < startStreak then
            return ZERO
        end

        local function nearestEnemyDistance(position)
            local bestDist = math.huge
            for _, enemy in ipairs(state.units or {}) do
                if self:isAttackableEnemyUnit(enemy, owner) then
                    local dist = math.abs(position.row - enemy.row) + math.abs(position.col - enemy.col)
                    if dist < bestDist then
                        bestDist = dist
                    end
                end
            end
            return bestDist
        end

        local currentPos = {row = unit.row, col = unit.col}
        local newPos = {row = movePos.row, col = movePos.col}
        local currentEnemyDist = nearestEnemyDistance(currentPos)
        local newEnemyDist = nearestEnemyDistance(newPos)
        if currentEnemyDist == math.huge and newEnemyDist == math.huge then
            return ZERO
        end

        local distGainWeight = valueOr(pressureConfig.DIST_GAIN_WEIGHT, ZERO)
        local retreatPenaltyWeight = valueOr(pressureConfig.RETREAT_PENALTY_WEIGHT, ZERO)
        local enemyProxBase = valueOr(pressureConfig.ENEMY_PROX_BASE, ZERO)
        local enemyProxDecay = valueOr(pressureConfig.ENEMY_PROX_DECAY, ZERO)
        local hubDistGainWeight = valueOr(pressureConfig.HUB_DIST_GAIN_WEIGHT, ZERO)
        local scalePerStreak = valueOr(pressureConfig.SCALE_PER_STREAK, ZERO)
        local maxScale = math.max(ONE, valueOr(pressureConfig.MAX_SCALE, ONE))

        local distGain = ZERO
        if currentEnemyDist ~= math.huge and newEnemyDist ~= math.huge then
            distGain = currentEnemyDist - newEnemyDist
        end

        local score = ZERO
        if distGain > ZERO then
            score = score + (distGain * distGainWeight)
        elseif distGain < ZERO then
            score = score + (distGain * retreatPenaltyWeight)
        end

        if newEnemyDist ~= math.huge then
            score = score + math.max(ZERO, enemyProxBase - (newEnemyDist * enemyProxDecay))
        end

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(owner)] or nil
        if enemyHub then
            local currentHubDist = math.abs(currentPos.row - enemyHub.row) + math.abs(currentPos.col - enemyHub.col)
            local newHubDist = math.abs(newPos.row - enemyHub.row) + math.abs(newPos.col - enemyHub.col)
            local hubDistGain = math.max(ZERO, currentHubDist - newHubDist)
            score = score + (hubDistGain * hubDistGainWeight)
        end

        local streakOver = math.max(ZERO, turnsWithoutDamage - startStreak + ONE)
        local scale = math.min(maxScale, ONE + (streakOver * scalePerStreak))
        return score * scale
    end

    function aiClass:getLowImpactMovePenalty(state, unit, movePos, aiPlayer)
        if not state or not unit or not movePos then
            return ZERO
        end

        local drawParams = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        local pressureConfig = drawParams.STALEMATE_PRESSURE or {}
        if pressureConfig.ENABLED == false then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end
        if self:isOwnHubThreatened(state, owner) then
            return ZERO
        end

        local patternPenalty = self:getRepeatedLowImpactPatternPenalty(state, unit, movePos, owner, pressureConfig)
        local turnsWithoutDamage = state.turnsWithoutDamage or ZERO
        local triggerStreak = math.max(ZERO, valueOr(pressureConfig.LOW_IMPACT_TRIGGER_STREAK, TWO))
        if turnsWithoutDamage < triggerStreak then
            return patternPenalty
        end

        local function nearestEnemyDistance(position)
            local bestDist = math.huge
            for _, enemy in ipairs(state.units or {}) do
                if self:isAttackableEnemyUnit(enemy, owner) then
                    local dist = math.abs(position.row - enemy.row) + math.abs(position.col - enemy.col)
                    if dist < bestDist then
                        bestDist = dist
                    end
                end
            end
            return bestDist
        end

        local currentEnemyDist = nearestEnemyDistance({row = unit.row, col = unit.col})
        local newEnemyDist = nearestEnemyDistance(movePos)
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(owner)] or nil
        local currentHubDist = enemyHub and (math.abs(unit.row - enemyHub.row) + math.abs(unit.col - enemyHub.col)) or math.huge
        local newHubDist = enemyHub and (math.abs(movePos.row - enemyHub.row) + math.abs(movePos.col - enemyHub.col)) or math.huge

        local noProgressPenalty = valueOr(pressureConfig.LOW_IMPACT_NO_PROGRESS_PENALTY, 80)
        local retreatPenalty = valueOr(pressureConfig.LOW_IMPACT_RETREAT_PENALTY, 130)
        local noThreatPenalty = valueOr(pressureConfig.LOW_IMPACT_NO_THREAT_PENALTY, 55)
        local scalePerStreak = valueOr(pressureConfig.LOW_IMPACT_SCALE_PER_STREAK, 0.20)
        local maxScale = math.max(ONE, valueOr(pressureConfig.LOW_IMPACT_MAX_SCALE, TWO))

        local penalty = ZERO
        local noEnemyProgress = (newEnemyDist >= currentEnemyDist)
        local noHubProgress = (newHubDist >= currentHubDist)

        if noEnemyProgress and noHubProgress then
            penalty = penalty + noProgressPenalty
        end
        if (newEnemyDist > currentEnemyDist) and noHubProgress then
            penalty = penalty + retreatPenalty
        end

        local projectedThreat = self:calculateNextTurnThreatValue(state, unit, movePos)
        if projectedThreat <= ZERO then
            penalty = penalty + noThreatPenalty
        end

        if penalty <= ZERO then
            return patternPenalty
        end

        local streakOver = math.max(ZERO, turnsWithoutDamage - triggerStreak)
        local scale = math.min(maxScale, ONE + (streakOver * scalePerStreak))
        return (penalty * scale) + patternPenalty
    end

    function aiClass:calculateSupportCoverageBonus(state, unit, movePos, aiPlayer)
        if not state or not unit then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end

        local pos = movePos or {row = unit.row, col = unit.col}
        if not pos or not pos.row or not pos.col then
            return ZERO
        end

        local nearbyAllies = ZERO
        local nearbyFrontlineSupport = ZERO
        local nearbyRangedSupport = ZERO
        local nearestEnemyDist = math.huge

        for _, boardUnit in ipairs(state.units or {}) do
            if boardUnit.player == owner and not self:isHubUnit(boardUnit) and not self:isObstacleUnit(boardUnit) then
                local isSelf = boardUnit.row == pos.row and boardUnit.col == pos.col and boardUnit.name == unit.name
                if not isSelf then
                    local dist = math.abs(pos.row - boardUnit.row) + math.abs(pos.col - boardUnit.col)
                    if dist <= TWO then
                        nearbyAllies = nearbyAllies + ONE
                        if self:unitHasTag(boardUnit, "tank") or self:unitHasTag(boardUnit, "melee") then
                            nearbyFrontlineSupport = nearbyFrontlineSupport + ONE
                        end
                        if self:unitHasTag(boardUnit, "ranged") then
                            nearbyRangedSupport = nearbyRangedSupport + ONE
                        end
                    end
                end
            elseif self:isAttackableEnemyUnit(boardUnit, owner, {excludeHub = true}) then
                local enemyDist = math.abs(pos.row - boardUnit.row) + math.abs(pos.col - boardUnit.col)
                if enemyDist < nearestEnemyDist then
                    nearestEnemyDist = enemyDist
                end
            end
        end

        local bonus = nearbyAllies * 18
        if self:unitHasTag(unit, "ranged") and nearbyFrontlineSupport > ZERO then
            bonus = bonus + 25
        end
        if (self:unitHasTag(unit, "melee") or self:unitHasTag(unit, "tank")) and nearbyRangedSupport > ZERO then
            bonus = bonus + 20
        end
        if nearestEnemyDist <= TWO and nearbyAllies == ZERO then
            bonus = bonus - 70
        elseif nearestEnemyDist <= THREE and nearbyAllies == ZERO then
            bonus = bonus - 35
        end

        return bonus
    end

    function aiClass:calculateWideFrontFlankBonus(state, unit, movePos, aiPlayer, tempoContext)
        if not state or not unit or not movePos or not movePos.row or not movePos.col then
            return ZERO
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local wideFrontConfig = doctrineConfig.WIDE_FRONT or {}
        if wideFrontConfig.ENABLED == false then
            return ZERO
        end

        local phase = (tempoContext and tempoContext.phase) or "mid"
        local applyPhases = wideFrontConfig.APPLY_PHASES or {}
        if applyPhases[phase] == false then
            return ZERO
        end
        if applyPhases[phase] == nil and phase == "end" then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end

        local minMove = math.max(TWO, valueOr(wideFrontConfig.MOBILE_MIN_MOVE, THREE))
        local moveRange = unitsInfo:getUnitMoveRange(unit, "WIDE_FRONT_MOBILITY") or unit.move or ZERO
        local explicitMobileRole = self:unitHasTag(unit, "mobile")
            or self:unitHasTag(unit, "wingstalker")
            or self:unitHasTag(unit, "corvette")
            or self:unitHasTag(unit, "scout")
        local roleExcluded = self:unitHasTag(unit, "tank")
            or self:unitHasTag(unit, "fortified")
            or self:unitHasTag(unit, "artillery")
            or self:unitHasTag(unit, "healer")
        local fastNonFrontline = moveRange >= minMove and not roleExcluded
        local isMobileUnit = explicitMobileRole or fastNonFrontline
        if not isMobileUnit then
            return ZERO
        end

        local currentColLoad = ZERO
        local newColLoad = ZERO
        local nearbyAllies = ZERO
        local nearestEnemyDist = math.huge

        for _, boardUnit in ipairs(state.units or {}) do
            if boardUnit.player == owner and not self:isHubUnit(boardUnit) and not self:isObstacleUnit(boardUnit) then
                local isSelf = boardUnit == unit
                    or (
                        boardUnit.row == unit.row
                        and boardUnit.col == unit.col
                        and boardUnit.name == unit.name
                        and boardUnit.player == unit.player
                    )
                if not isSelf then
                    if boardUnit.col == unit.col then
                        currentColLoad = currentColLoad + ONE
                    end
                    if boardUnit.col == movePos.col then
                        newColLoad = newColLoad + ONE
                    end
                    local allyDist = math.abs(movePos.row - boardUnit.row) + math.abs(movePos.col - boardUnit.col)
                    if allyDist <= TWO then
                        nearbyAllies = nearbyAllies + ONE
                    end
                end
            elseif self:isAttackableEnemyUnit(boardUnit, owner, {excludeHub = true}) then
                local enemyDist = math.abs(movePos.row - boardUnit.row) + math.abs(movePos.col - boardUnit.col)
                if enemyDist < nearestEnemyDist then
                    nearestEnemyDist = enemyDist
                end
            end
        end

        local bonus = ZERO
        local stackThreshold = math.max(ONE, valueOr(wideFrontConfig.STACK_THRESHOLD, TWO))
        local spreadBonus = valueOr(wideFrontConfig.SPREAD_FROM_STACK_BONUS, 38)
        local stackPenalty = valueOr(wideFrontConfig.STACK_PENALTY, 34)
        local isolationPenalty = valueOr(wideFrontConfig.ISOLATION_PENALTY, 58)

        if currentColLoad > newColLoad then
            bonus = bonus + ((currentColLoad - newColLoad) * spreadBonus)
        end
        if newColLoad >= stackThreshold then
            bonus = bonus - ((newColLoad - stackThreshold + ONE) * stackPenalty)
        end

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(owner)] or nil
        if enemyHub then
            local flankMin = math.max(ONE, valueOr(wideFrontConfig.FLANK_OFFSET_MIN, TWO))
            local flankBaseBonus = valueOr(wideFrontConfig.FLANK_OFFSET_BONUS, 62)
            local flankApproachBonus = valueOr(wideFrontConfig.FLANK_APPROACH_BONUS, 26)
            local backlineReachRows = math.max(ONE, valueOr(wideFrontConfig.BACKLINE_REACH_ROWS, THREE))
            local backlineBonus = valueOr(wideFrontConfig.BACKLINE_FLANK_BONUS, 36)

            local currentOffset = math.abs(unit.col - enemyHub.col)
            local newOffset = math.abs(movePos.col - enemyHub.col)
            local currentHubDist = math.abs(unit.row - enemyHub.row) + math.abs(unit.col - enemyHub.col)
            local newHubDist = math.abs(movePos.row - enemyHub.row) + math.abs(movePos.col - enemyHub.col)

            if newOffset >= flankMin and newOffset > currentOffset then
                bonus = bonus + flankBaseBonus + ((newOffset - currentOffset) * 12)
                if newHubDist < currentHubDist then
                    bonus = bonus + flankApproachBonus
                end
            end

            if newOffset >= flankMin and math.abs(movePos.row - enemyHub.row) <= backlineReachRows then
                bonus = bonus + backlineBonus
            end
        end

        if nearbyAllies == ZERO and nearestEnemyDist <= TWO then
            bonus = bonus - isolationPenalty
        end

        return bonus
    end

    function aiClass:calculateMobileInfluenceFlowBonus(state, unit, movePos, aiPlayer, tempoContext)
        if not state or not unit or not movePos or not movePos.row or not movePos.col then
            return ZERO
        end
        if not self.influenceMap then
            return ZERO
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local flowConfig = doctrineConfig.INFLUENCE_MOBILITY or {}
        if flowConfig.ENABLED == false then
            return ZERO
        end

        local phase = (tempoContext and tempoContext.phase) or "mid"
        local applyPhases = flowConfig.APPLY_PHASES or {}
        if applyPhases[phase] == false then
            return ZERO
        end
        if applyPhases[phase] == nil and phase == "end" then
            return ZERO
        end

        local minMove = math.max(TWO, valueOr(flowConfig.MOBILE_MIN_MOVE, THREE))
        local moveRange = unitsInfo:getUnitMoveRange(unit, "INFLUENCE_MOBILITY_RANGE") or unit.move or ZERO
        local explicitMobileRole = self:unitHasTag(unit, "mobile")
            or self:unitHasTag(unit, "wingstalker")
            or self:unitHasTag(unit, "corvette")
            or self:unitHasTag(unit, "scout")
        local roleExcluded = self:unitHasTag(unit, "healer")
            or self:unitHasTag(unit, "artillery")
            or self:unitHasTag(unit, "fortified")
        if not (explicitMobileRole or (moveRange >= minMove and not roleExcluded)) then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end

        local moveDeltaScore = valueOr(
            select(ONE, aiInfluence:evaluateMove(self.influenceMap, unit.row, unit.col, movePos.row, movePos.col)),
            ZERO
        )

        local gridSize = (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or DEFAULT_GRID_SIZE or EIGHT
        local function sampleRingInfluence(row, col)
            local total = ZERO
            local count = ZERO
            local positiveCells = ZERO

            local function addCell(r, c)
                if r < ONE or c < ONE or r > gridSize or c > gridSize then
                    return
                end
                if not (self.influenceMap[r] and self.influenceMap[r][c] ~= nil) then
                    return
                end
                local influenceScore = valueOr(select(ONE, aiInfluence:evaluatePosition(self.influenceMap, r, c)), ZERO)
                total = total + influenceScore
                count = count + ONE
                if influenceScore > ZERO then
                    positiveCells = positiveCells + ONE
                end
            end

            addCell(row - ONE, col)
            addCell(row + ONE, col)
            addCell(row, col - ONE)
            addCell(row, col + ONE)

            if count <= ZERO then
                return ZERO, ZERO
            end
            return total / count, positiveCells
        end

        local currentRingAvg, currentRingPositive = sampleRingInfluence(unit.row, unit.col)
        local newRingAvg, newRingPositive = sampleRingInfluence(movePos.row, movePos.col)
        local ringDelta = newRingAvg - currentRingAvg
        local ringPositiveDelta = newRingPositive - currentRingPositive

        local bonus = (moveDeltaScore * valueOr(flowConfig.MOVE_DELTA_WEIGHT, 1.4))
            + (ringDelta * valueOr(flowConfig.RING_DELTA_WEIGHT, 0.9))
            + (ringPositiveDelta * valueOr(flowConfig.RING_POSITIVE_CELL_BONUS, 11))

        local nearestEnemy = nil
        local nearestEnemyDist = math.huge
        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, owner, {excludeHub = true}) then
                local dist = math.abs(movePos.row - enemy.row) + math.abs(movePos.col - enemy.col)
                if dist < nearestEnemyDist then
                    nearestEnemyDist = dist
                    nearestEnemy = enemy
                end
            end
        end

        local anchor = nearestEnemy
        if not anchor then
            anchor = state.commandHubs and state.commandHubs[self:getOpponentPlayer(owner)] or nil
        end

        if anchor then
            local currentAnchorDist = math.abs(unit.row - anchor.row) + math.abs(unit.col - anchor.col)
            local newAnchorDist = math.abs(movePos.row - anchor.row) + math.abs(movePos.col - anchor.col)
            local currentOffset = math.abs(unit.col - anchor.col)
            local newOffset = math.abs(movePos.col - anchor.col)
            local maxRetreat = math.max(ZERO, valueOr(flowConfig.ORBIT_MAX_RETREAT, ONE))
            local orbitBonus = valueOr(flowConfig.ORBIT_OFFSET_BONUS, 30)
            local retreatPenalty = valueOr(flowConfig.ORBIT_RETREAT_PENALTY, 26)
            local strategyIntent = self.strategicState and self.strategicState.intent or nil
            local allowDefensiveRetreat = strategyIntent == "DEFEND_HARD"

            if newOffset > currentOffset and newAnchorDist <= (currentAnchorDist + maxRetreat) then
                bonus = bonus + ((newOffset - currentOffset) * orbitBonus)
            end

            if (not allowDefensiveRetreat)
                and newAnchorDist > (currentAnchorDist + maxRetreat)
                and newOffset <= currentOffset then
                bonus = bonus - ((newAnchorDist - (currentAnchorDist + maxRetreat)) * retreatPenalty)
            end
        end

        local cap = math.max(40, valueOr(flowConfig.BONUS_CAP, 140))
        if bonus > cap then
            bonus = cap
        elseif bonus < -cap then
            bonus = -cap
        end

        return bonus
    end

    function aiClass:getObjectivePathingContext(state, aiPlayer)
        if not state then
            return {
                targets = {},
                actionableTargets = {},
                threatTimingCache = {}
            }
        end

        local owner = aiPlayer or self:getFactionId()
        if not owner then
            return {
                targets = {},
                actionableTargets = {},
                threatTimingCache = {}
            }
        end

        local cacheKey = string.format(
            "%s:%d:%d:%d:%d:%d",
            tostring(state),
            self:getStateTurn(state) or ZERO,
            owner,
            state.turnActionCount or ZERO,
            state.hasDeployedThisTurn and ONE or ZERO,
            #(state.units or {})
        )
        if self._objectivePathingContext and self._objectivePathingContext.cacheKey == cacheKey then
            return self._objectivePathingContext
        end

        local enemyPlayer = self:getOpponentPlayer(owner)
        local targets = {}

        for _, unit in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(unit, owner, {excludeHub = true}) then
                targets[#targets + ONE] = unit
            end
        end

        local enemyHub = state.commandHubs and state.commandHubs[enemyPlayer] or nil
        if enemyHub then
            local hubHp = enemyHub.currentHp or enemyHub.startingHp or ZERO
            if hubHp > ZERO then
                targets[#targets + ONE] = {
                    name = enemyHub.name or "Commandant",
                    player = enemyPlayer,
                    row = enemyHub.row,
                    col = enemyHub.col,
                    currentHp = hubHp,
                    startingHp = enemyHub.startingHp or hubHp
                }
            end
        end

        table.sort(targets, function(a, b)
            local aPriority = self:getTargetPriority(a) or ZERO
            local bPriority = self:getTargetPriority(b) or ZERO
            if aPriority == bPriority then
                local aKey = hashPosition(a) or ""
                local bKey = hashPosition(b) or ""
                return aKey < bKey
            end
            return aPriority > bPriority
        end)

        local actionableTargets = {}
        local friendlyUnits = {}
        for _, unit in ipairs(state.units or {}) do
            if unit.player == owner and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                friendlyUnits[#friendlyUnits + ONE] = unit
            end
        end

        local function markIfActionable(target)
            local targetKey = hashPosition(target)
            if not targetKey then
                return
            end
            if actionableTargets[targetKey] then
                return
            end

            for _, ally in ipairs(friendlyUnits) do
                if not ally.hasActed and self:canUnitDamageTargetFromPosition(
                    state,
                    ally,
                    target,
                    ally.row,
                    ally.col,
                    {requirePositiveDamage = true}
                ) then
                    actionableTargets[targetKey] = true
                    return
                end

                if not ally.hasActed and not ally.hasMoved then
                    local moveCells = self:getValidMoveCells(state, ally.row, ally.col) or {}
                    for _, moveCell in ipairs(moveCells) do
                        if self:canUnitDamageTargetFromPosition(
                            state,
                            ally,
                            target,
                            moveCell.row,
                            moveCell.col,
                            {requirePositiveDamage = true}
                        ) then
                            actionableTargets[targetKey] = true
                            return
                        end
                    end
                end
            end
        end

        for _, target in ipairs(targets) do
            markIfActionable(target)
        end

        local context = {
            cacheKey = cacheKey,
            targets = targets,
            actionableTargets = actionableTargets,
            threatTimingCache = {}
        }
        self._objectivePathingContext = context
        return context
    end

    function aiClass:getObjectiveThreatTimingCached(state, context, unit, target, horizon)
        if not state or not context or not unit or not target then
            return nil
        end

        local cache = context.threatTimingCache or {}
        context.threatTimingCache = cache

        local targetKey = hashPosition(target) or "target"
        local unitKey = string.format(
            "%s:%d,%d:%d",
            tostring(unit.name or "unit"),
            unit.row or ZERO,
            unit.col or ZERO,
            unit.player or ZERO
        )
        local key = string.format("%s>%s@%d#%s", unitKey, targetKey, horizon or ONE, tostring(state))
        if cache[key] ~= nil then
            return cache[key] == false and nil or cache[key]
        end

        local turn = self:getUnitThreatTiming(
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
        cache[key] = turn or false
        return turn
    end

    function aiClass:calculateAttackPostureDistance(unit, target)
        if not unit or not target then
            return math.huge
        end

        local dr = math.abs((unit.row or ZERO) - (target.row or ZERO))
        local dc = math.abs((unit.col or ZERO) - (target.col or ZERO))
        local manhattan = dr + dc
        local attackRange = unitsInfo:getUnitAttackRange(unit, "OBJECTIVE_PATH_ATTACK_RANGE") or unit.atkRange or ONE
        local canAttackAdjacent = unitsInfo:canAttackAdjacent(unit.name)
        local minRange = canAttackAdjacent and ONE or TWO

        if self:unitHasTag(unit, "ranged") or attackRange > ONE then
            local laneOffset = math.min(dr, dc)
            local alignedDistance = (dr == ZERO or dc == ZERO) and manhattan or math.max(dr, dc)
            local rangeGap = ZERO
            if alignedDistance < minRange then
                rangeGap = minRange - alignedDistance
            elseif alignedDistance > attackRange then
                rangeGap = alignedDistance - attackRange
            end
            return laneOffset + rangeGap
        end

        if manhattan < minRange then
            return minRange - manhattan
        end
        if manhattan > attackRange then
            return manhattan - attackRange
        end
        return ZERO
    end

    function aiClass:calculateMultiTurnObjectivePathBonus(state, unit, movePos, aiPlayer, tempoContext, opts)
        if not state or not unit or not movePos or not movePos.row or not movePos.col then
            return ZERO
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local pathConfig = doctrineConfig.OBJECTIVE_PATHING or {}
        if pathConfig.ENABLED == false then
            return ZERO
        end
        if self:isHubUnit(unit) or self:isObstacleUnit(unit) or self:unitHasTag(unit, "healer") then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end
        local options = opts or {}

        local context = self:getObjectivePathingContext(state, owner)
        local targets = context.targets or {}
        if #targets <= ZERO then
            return ZERO
        end

        local requireUncontested = valueOr(pathConfig.REQUIRE_UNCONTESTED_OBJECTIVE, true)
        local horizonTurns = math.max(ONE, valueOr(pathConfig.HORIZON_TURNS, THREE))
        local maxTargetsPerUnit = math.max(ONE, valueOr(pathConfig.MAX_TARGETS_PER_UNIT, 4))
        local etaGainBonus = valueOr(pathConfig.ETA_GAIN_BONUS, 115)
        local etaAcquireBonus = valueOr(pathConfig.ETA_ACQUIRE_BONUS, 90)
        local distGainBonus = valueOr(pathConfig.DIST_GAIN_BONUS, 24)
        local targetPriorityScale = valueOr(pathConfig.TARGET_PRIORITY_SCALE, 0.45)
        local hubFocusBonus = valueOr(pathConfig.HUB_FOCUS_BONUS, 40)
        local bonusCap = math.max(40, valueOr(pathConfig.BONUS_CAP, 220))

        local rankedTargets = {}
        for _, target in ipairs(targets) do
            local targetKey = hashPosition(target)
            if targetKey and (not requireUncontested or not context.actionableTargets[targetKey]) then
                local quickPriority = self:getTargetPriority(target) or ZERO
                local quickDist = math.abs(movePos.row - target.row) + math.abs(movePos.col - target.col)
                local quickScore = (quickPriority * 20) - (quickDist * SIX)
                if self:isHubUnit(target) then
                    quickScore = quickScore + 80
                end
                rankedTargets[#rankedTargets + ONE] = {
                    target = target,
                    key = targetKey,
                    quickScore = quickScore
                }
            end
        end

        if #rankedTargets <= ZERO then
            return ZERO
        end

        table.sort(rankedTargets, function(a, b)
            local aQuick = a.quickScore or ZERO
            local bQuick = b.quickScore or ZERO
            if aQuick == bQuick then
                return tostring(a.key or "") < tostring(b.key or "")
            end
            return aQuick > bQuick
        end)

        local currentUnit = unit
        local projectedState = options.simState
        local projectedUnit = options.movedUnit
        if not projectedState or not projectedUnit then
            projectedState, projectedUnit = self:simulateStateAfterMove(state, unit, movePos)
        end
        projectedState = projectedState or state
        projectedUnit = projectedUnit or self:buildProjectedThreatUnit(unit, movePos.row, movePos.col) or unit
        local bestBonus = ZERO
        local limit = math.min(maxTargetsPerUnit, #rankedTargets)

        for index = ONE, limit do
            local entry = rankedTargets[index]
            local target = entry and entry.target
            if target then
                local currentEta = self:getObjectiveThreatTimingCached(state, context, currentUnit, target, horizonTurns)
                local projectedEta = self:getObjectiveThreatTimingCached(projectedState, context, projectedUnit, target, horizonTurns)
                local currentPostureDist = self:calculateAttackPostureDistance(currentUnit, target)
                local projectedPostureDist = self:calculateAttackPostureDistance(projectedUnit, target)
                local distGain = currentPostureDist - projectedPostureDist

                local bonus = distGain * distGainBonus
                if currentEta and projectedEta then
                    bonus = bonus + ((currentEta - projectedEta) * etaGainBonus)
                elseif (not currentEta) and projectedEta then
                    bonus = bonus + etaAcquireBonus
                elseif currentEta and (not projectedEta) then
                    bonus = bonus - (etaGainBonus * 0.6)
                end

                bonus = bonus + ((self:getTargetPriority(target) or ZERO) * targetPriorityScale)
                if self:isHubUnit(target) then
                    bonus = bonus + hubFocusBonus
                end

                if bonus > bestBonus then
                    bestBonus = bonus
                end
            end
        end

        if bestBonus <= ZERO then
            return ZERO
        end

        return math.min(bestBonus, bonusCap)
    end

    function aiClass:getRepeatedLowImpactPatternPenalty(state, unit, movePos, aiPlayer, pressureConfigOverride)
        if not state or not unit or not movePos then
            return ZERO
        end

        local drawParams = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        local pressureConfig = pressureConfigOverride or drawParams.STALEMATE_PRESSURE or {}
        if pressureConfig.ENABLED == false then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end

        local history = self.lowImpactMoveHistory
        if type(history) ~= "table" then
            return ZERO
        end

        local repeatWindow = math.max(ONE, valueOr(pressureConfig.PATTERN_REPEAT_WINDOW, 5))
        local repeatPenalty = valueOr(pressureConfig.PATTERN_REPEAT_PENALTY, 65)
        local oscillationPenalty = valueOr(pressureConfig.PATTERN_OSCILLATION_PENALTY, 95)
        local scalePerRepeat = valueOr(pressureConfig.PATTERN_SCALE_PER_REPEAT, 0.35)
        local maxScale = math.max(ONE, valueOr(pressureConfig.PATTERN_MAX_SCALE, 2.4))
        local currentTurn = self:getStateTurn(state) or (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or ZERO

        local forwardKey = buildMovePatternKey(owner, unit.name, unit.row, unit.col, movePos.row, movePos.col)
        local reverseKey = buildMovePatternKey(owner, unit.name, movePos.row, movePos.col, unit.row, unit.col)

        local function activeCountForKey(key)
            local entry = history[key]
            if not entry then
                return ZERO
            end
            local lastTurn = entry.lastTurn or ZERO
            if currentTurn - lastTurn > repeatWindow then
                return ZERO
            end
            return math.max(ZERO, entry.count or ZERO)
        end

        local repeatedCount = activeCountForKey(forwardKey)
        local oscillationCount = activeCountForKey(reverseKey)
        if repeatedCount <= ZERO and oscillationCount <= ZERO then
            return ZERO
        end

        local rawPenalty = (repeatedCount * repeatPenalty) + (oscillationCount * oscillationPenalty)
        local repeatIntensity = math.max(ZERO, (repeatedCount + oscillationCount) - ONE)
        local scale = math.min(maxScale, ONE + (repeatIntensity * scalePerRepeat))
        return rawPenalty * scale
    end

    function aiClass:recordExecutedLowImpactMovePattern(unit, fromPos, toPos, sourceTag, turnOverride)
        if not unit or not fromPos or not toPos or not sourceTag then
            return
        end

        local trackedTags = {
            SAFE_POSITIONING_MOVE = true,
            SAFE_EVASION = true,
            STRATEGIC_PLAN_MOVE = true,
            HUB_SPACE = true,
            RISKY_MOVE = true,
            STRATEGIC_DEFENSE_MOVE = true,
            STRATEGIC_DEFENSE_COUNTER_MOVE = true,
            STRATEGIC_DEFENSE_GUARD = true,
            STRATEGIC_DEFENSE_UNBLOCK = true,
            COMMANDANT_THREAT_MOVE = true
        }
        if not trackedTags[sourceTag] then
            return
        end

        local owner = unit.player or self:getFactionId()
        if not owner then
            return
        end

        local drawParams = (self.AI_PARAMS and self.AI_PARAMS.DRAW_URGENCY) or {}
        local pressureConfig = drawParams.STALEMATE_PRESSURE or {}
        local repeatWindow = math.max(ONE, valueOr(pressureConfig.PATTERN_REPEAT_WINDOW, 5))
        local currentTurn = turnOverride or (GAME and GAME.CURRENT and GAME.CURRENT.TURN) or ZERO

        self.lowImpactMoveHistory = self.lowImpactMoveHistory or {}
        local history = self.lowImpactMoveHistory
        local key = buildMovePatternKey(owner, unit.name, fromPos.row, fromPos.col, toPos.row, toPos.col)
        local entry = history[key] or {count = ZERO, lastTurn = currentTurn}
        if currentTurn - (entry.lastTurn or ZERO) > repeatWindow then
            entry.count = ZERO
        end
        entry.count = (entry.count or ZERO) + ONE
        entry.lastTurn = currentTurn
        entry.lastTag = sourceTag
        history[key] = entry

        for patternKey, patternEntry in pairs(history) do
            if currentTurn - (patternEntry.lastTurn or ZERO) > (repeatWindow + TWO) then
                history[patternKey] = nil
            end
        end
    end

    function aiClass:getRangedAdjacencyPenalty(state, unit, movePos, aiPlayer)
        if not state or not unit or not movePos then
            return ZERO
        end

        local unitName = unit.name or ""
        if unitsInfo:canAttackAdjacent(unitName) then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end

        local positionalConfig = self:getPositionalScoreConfig()
        local defaultPositionalConfig = DEFAULT_SCORE_PARAMS.POSITIONAL or {}
        local penaltyPerEnemy = valueOr(
            positionalConfig.RANGED_ADJACENT_THREAT_PENALTY,
            valueOr(defaultPositionalConfig.RANGED_ADJACENT_THREAT_PENALTY, ZERO)
        )
        if penaltyPerEnemy <= ZERO then
            return ZERO
        end

        local adjacentThreats = ZERO
        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, owner) then
                local dist = math.abs(movePos.row - enemy.row) + math.abs(movePos.col - enemy.col)
                if dist == ONE then
                    adjacentThreats = adjacentThreats + ONE
                end
            end
        end

        return adjacentThreats * penaltyPerEnemy
    end

    function aiClass:getHealerOrbitBonus(unit, movePos, ownHub)
        if not unit or not movePos or not ownHub then
            return ZERO
        end

        local orbitConfig = (self:getPositionalScoreConfig().HEALER_ORBIT or {})
        local idealMin = orbitConfig.IDEAL_MIN
        local idealMax = orbitConfig.IDEAL_MAX
        local idealBonus = orbitConfig.IDEAL_BONUS
        local distancePenaltyMult = orbitConfig.DISTANCE_PENALTY_MULT
        local repositionBonus = orbitConfig.REPOSITION_BONUS
        local adjacentPenalty = orbitConfig.ADJACENT_PENALTY

        local currentDist = math.abs(unit.row - ownHub.row) + math.abs(unit.col - ownHub.col)
        local newDist = math.abs(movePos.row - ownHub.row) + math.abs(movePos.col - ownHub.col)
        local score = ZERO

        if newDist >= idealMin and newDist <= idealMax then
            score = score + idealBonus
        else
            local idealCenter = (idealMin + idealMax) / TWO
            local distanceDiff = math.abs(newDist - idealCenter)
            score = score - (distanceDiff * distancePenaltyMult)
            if currentDist > idealMax and newDist < currentDist then
                score = score + repositionBonus
            elseif currentDist < idealMin and newDist > currentDist then
                score = score + repositionBonus
            end
        end

        if newDist <= ONE then
            score = score - adjacentPenalty
        end

        return score
    end

    function aiClass:isHealerOrbitMoveAllowed(state, unit, moveCell, aiPlayer)
        if not state or not unit or not moveCell or not aiPlayer then
            return false
        end

        local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
        if not ownHub then
            return false
        end

        local orbitConfig = (self:getPositionalScoreConfig().HEALER_ORBIT or {})
        local defaultOrbitConfig = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).HEALER_ORBIT or {})
        local doctrineConfig = self:getDoctrineScoreConfig()
        local healerDoctrine = doctrineConfig.HEALER or {}
        local idealMin = valueOr(
            healerDoctrine.ORBIT_MIN,
            valueOr(orbitConfig.IDEAL_MIN, valueOr(defaultOrbitConfig.IDEAL_MIN, TWO))
        )
        local idealMax = valueOr(
            healerDoctrine.ORBIT_MAX,
            valueOr(orbitConfig.IDEAL_MAX, valueOr(defaultOrbitConfig.IDEAL_MAX, THREE))
        )
        if idealMin > idealMax then
            idealMin, idealMax = idealMax, idealMin
        end

        local currentDist = math.abs(unit.row - ownHub.row) + math.abs(unit.col - ownHub.col)
        local newDist = math.abs(moveCell.row - ownHub.row) + math.abs(moveCell.col - ownHub.col)

        local function distanceFromDesiredBand(dist)
            if dist < idealMin then
                return idealMin - dist
            end
            if dist > idealMax then
                return dist - idealMax
            end
            return ZERO
        end

        local withinDesired = newDist >= idealMin and newDist <= idealMax
        local currentGap = distanceFromDesiredBand(currentDist)
        local newGap = distanceFromDesiredBand(newDist)
        local movingTowardDesiredBand = newGap < currentGap

        return withinDesired or movingTowardDesiredBand
    end

    function aiClass:getPressurePhaseValues(currentTurn)
        local turn = currentTurn or DEFAULT_TURN
        local positionalConfig = self:getPositionalScoreConfig()
        local pressureConfig = positionalConfig.PRESSURE_PHASE or {}
        local defaultPressureConfig = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).PRESSURE_PHASE or {})
        local turnBucket = math.max(MIN_HP, valueOr(pressureConfig.TURN_BUCKET, valueOr(defaultPressureConfig.TURN_BUCKET, MIN_HP)))
        local offensiveMult = valueOr(pressureConfig.OFFENSIVE_LOG_MULT, valueOr(defaultPressureConfig.OFFENSIVE_LOG_MULT, ZERO))
        local defensiveMult = valueOr(pressureConfig.DEFENSIVE_LOG_MULT, valueOr(defaultPressureConfig.DEFENSIVE_LOG_MULT, ZERO))

        local turnPhase = math.floor((turn - ONE) / turnBucket)
        return {
            turnBucket = turnBucket,
            turnPhase = turnPhase,
            offensiveBonus = math.floor(offensiveMult * math.log(turnPhase + ONE)),
            defensivePenalty = math.floor(defensiveMult * math.log(turnPhase + ONE))
        }
    end

    function aiClass:getFreeAdjacentCounts(boardState, row, col)
        if not boardState or not row or not col then
            return ZERO, ZERO
        end

        local free = ZERO
        local occupied = ZERO
        for _, offset in ipairs(self:getOrthogonalDirections()) do
            local checkRow = row + offset.row
            local checkCol = col + offset.col
            if self:isInsideBoard(checkRow, checkCol, boardState) then
                local occupant = self:getUnitAtPosition(boardState, checkRow, checkCol)
                if occupant then
                    occupied = occupied + ONE
                else
                    free = free + ONE
                end
            end
        end

        return free, occupied
    end

    function aiClass:getFreeAdjacentDeltaScore(state, simState, unit, moveCell)
        if not state or not simState or not unit or not moveCell then
            return ZERO
        end

        local freeCellWeights = aiInfluence.CONFIG.POSITIONAL_WEIGHTS or {}
        local freeAdjBonus = valueOr(
            freeCellWeights.FREE_CELL_BONUS,
            valueOr((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).FREE_CELL_BONUS, ZERO)
        )
        local freeAdjPenalty = valueOr(
            freeCellWeights.FREE_CELL_PENALTY,
            valueOr((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).FREE_CELL_PENALTY, ZERO)
        )

        local currentFree, currentBlocked = self:getFreeAdjacentCounts(state, unit.row, unit.col)
        local newFree, newBlocked = self:getFreeAdjacentCounts(simState, moveCell.row, moveCell.col)

        local scoreDelta = ZERO
        local freeDelta = newFree - currentFree
        if freeDelta ~= ZERO then
            scoreDelta = scoreDelta + (freeDelta * freeAdjBonus)
        end

        local blockedDelta = newBlocked - currentBlocked
        if blockedDelta > ZERO then
            scoreDelta = scoreDelta - (blockedDelta * freeAdjPenalty)
        end

        return scoreDelta
    end

    function aiClass:getSafeMoveImprovementThreshold(unit, threatValue)
        local thresholdConfig = self:getPositionalScoreConfig().SAFE_THRESHOLD or {}
        local defaultThresholdConfig = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).SAFE_THRESHOLD or {})
        local base = valueOr(thresholdConfig.BASE, valueOr(defaultThresholdConfig.BASE, ZERO))
        local threshold = base
        local highThreatValue = valueOr(thresholdConfig.HIGH_THREAT_VALUE, valueOr(defaultThresholdConfig.HIGH_THREAT_VALUE, ZERO))
        local highMin = valueOr(thresholdConfig.HIGH_MIN, valueOr(defaultThresholdConfig.HIGH_MIN, base))
        local highFactor = valueOr(thresholdConfig.HIGH_FACTOR, valueOr(defaultThresholdConfig.HIGH_FACTOR, ZERO))
        local medThreatValue = valueOr(thresholdConfig.MED_THREAT_VALUE, valueOr(defaultThresholdConfig.MED_THREAT_VALUE, ZERO))
        local medMin = valueOr(thresholdConfig.MED_MIN, valueOr(defaultThresholdConfig.MED_MIN, base))
        local medFactor = valueOr(thresholdConfig.MED_FACTOR, valueOr(defaultThresholdConfig.MED_FACTOR, ZERO))

        threatValue = valueOr(threatValue, ZERO)

        if threatValue > highThreatValue then
            threshold = math.max(highMin, base * highFactor)
        elseif threatValue > medThreatValue then
            threshold = math.max(medMin, base * medFactor)
        end

        local unitOverride = deepMerge(defaultThresholdConfig.UNIT_OVERRIDE or {}, thresholdConfig.UNIT_OVERRIDE or {})
        if self:unitHasTag(unit, "corvette") and unitOverride.corvette ~= nil then
            threshold = unitOverride.corvette
        elseif self:unitHasTag(unit, "healer") and unitOverride.healer ~= nil then
            threshold = unitOverride.healer
        elseif self:unitHasTag(unit, "earthstalker") and unitOverride.earthstalker ~= nil then
            threshold = unitOverride.earthstalker
        end

        return threshold
    end

    function aiClass:getRiskyMoveImprovementThreshold(unit, threatValue)
        local thresholdConfig = self:getPositionalScoreConfig().RISKY_THRESHOLD or {}
        local defaultThresholdConfig = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).RISKY_THRESHOLD or {})
        local base = valueOr(thresholdConfig.BASE, valueOr(defaultThresholdConfig.BASE, ZERO))
        local threshold = base
        local highThreatValue = valueOr(thresholdConfig.HIGH_THREAT_VALUE, valueOr(defaultThresholdConfig.HIGH_THREAT_VALUE, ZERO))
        local highMin = valueOr(thresholdConfig.HIGH_MIN, valueOr(defaultThresholdConfig.HIGH_MIN, base))
        local highFactor = valueOr(thresholdConfig.HIGH_FACTOR, valueOr(defaultThresholdConfig.HIGH_FACTOR, ZERO))
        local medThreatValue = valueOr(thresholdConfig.MED_THREAT_VALUE, valueOr(defaultThresholdConfig.MED_THREAT_VALUE, ZERO))
        local medMin = valueOr(thresholdConfig.MED_MIN, valueOr(defaultThresholdConfig.MED_MIN, base))
        local medFactor = valueOr(thresholdConfig.MED_FACTOR, valueOr(defaultThresholdConfig.MED_FACTOR, ZERO))
        local lowThreatValue = valueOr(thresholdConfig.LOW_THREAT_VALUE, valueOr(defaultThresholdConfig.LOW_THREAT_VALUE, ZERO))
        local lowMin = valueOr(thresholdConfig.LOW_MIN, valueOr(defaultThresholdConfig.LOW_MIN, base))
        local lowFactor = valueOr(thresholdConfig.LOW_FACTOR, valueOr(defaultThresholdConfig.LOW_FACTOR, ZERO))

        threatValue = valueOr(threatValue, ZERO)

        if threatValue > highThreatValue then
            threshold = math.max(highMin, base * highFactor)
        elseif threatValue > medThreatValue then
            threshold = math.max(medMin, base * medFactor)
        elseif threatValue > lowThreatValue then
            threshold = math.max(lowMin, base * lowFactor)
        end

        local unitOverride = deepMerge(defaultThresholdConfig.UNIT_OVERRIDE or {}, thresholdConfig.UNIT_OVERRIDE or {})
        if self:unitHasTag(unit, "corvette") and unitOverride.corvette ~= nil then
            threshold = unitOverride.corvette
        elseif self:unitHasTag(unit, "healer") and unitOverride.healer ~= nil then
            threshold = unitOverride.healer
        elseif self:unitHasTag(unit, "earthstalker") and unitOverride.earthstalker ~= nil then
            threshold = unitOverride.earthstalker
        end

        return threshold
    end

    function aiClass:matchesDeploymentSelector(unit, selector)
        if not unit or not unit.name or not selector then
            return false
        end

        if type(selector) == "string" then
            local selectorType, selectorValue = selector:match("^(%w+):(.+)$")
            if selectorType == "tag" then
                return self:unitHasTag(unit, selectorValue)
            end
            if selectorType == "name" then
                return unit.name == selectorValue
            end
            return unit.name == selector
        end

        if type(selector) == "table" then
            if selector.tag then
                return self:unitHasTag(unit, selector.tag)
            end
            if selector.name then
                return unit.name == selector.name
            end
        end

        return false
    end

    function aiClass:getPreferredSupplyUnitIndex(supply, opts)
        if not supply or #supply == ZERO then
            return nil
        end

        local options = opts or {}
        local doctrineConfig = self:getDoctrineScoreConfig()
        local openingConfig = doctrineConfig.OPENING or {}
        local healerDoctrine = doctrineConfig.HEALER or {}
        local openingMode = tostring(valueOr(openingConfig.MODE, "adaptive_guardrails"))
        local noHealerBeforeTurn = math.max(ONE, valueOr(openingConfig.NO_HEALER_BEFORE_TURN, FIVE))
        local requireOpeningSynergy = valueOr(openingConfig.REQUIRE_OPENING_SYNERGY, true)
        local currentTurn = tonumber(options.turnNumber) or ((GAME and GAME.CURRENT and GAME.CURRENT.TURN) or ONE)
        local hubPos = options.hubPos
        local openingState = options.state
        local opponentFeatures = openingState and self:extractOpeningOpponentFeatures(openingState, self:getFactionId()) or nil

        local rootProfileConfig = (self.AI_PARAMS or {}).PROFILE or {}
        local deploymentConfig = rootProfileConfig.INITIAL_DEPLOYMENT or {}
        local activeReference = tostring(self:getEffectiveAiReference(openingState, {
            lock = false,
            context = "opening_deploy_profile"
        }) or BASE_AI_REFERENCE)
        local selectors = deploymentConfig[activeReference]
        if type(selectors) ~= "table" then
            selectors = deploymentConfig[BASE_AI_REFERENCE] or {}
        end
        if openingMode ~= "adaptive_guardrails" and #selectors > ZERO then
            for _, selector in ipairs(selectors) do
                for idx, unit in ipairs(supply) do
                    if self:matchesDeploymentSelector(unit, selector) then
                        return idx
                    end
                end
            end
            return nil
        end

        local supplyByName = {}
        for _, unit in ipairs(supply) do
            if unit and unit.name then
                supplyByName[unit.name] = (supplyByName[unit.name] or ZERO) + ONE
            end
        end

        local hubEdgeBias = ZERO
        if hubPos then
            local gridSize = (GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE) or DEFAULT_GRID_SIZE
            local edgeDistance = math.min(
                hubPos.row - ONE,
                hubPos.col - ONE,
                gridSize - hubPos.row,
                gridSize - hubPos.col
            )
            if edgeDistance <= ONE then
                hubEdgeBias = ONE
            end
        end

        local bestIndex = nil
        local bestScore = -math.huge
        local bestName = nil
        local bestBaseIndex = nil
        local bestBaseScore = -math.huge
        local bestBaseName = nil

        for idx, unit in ipairs(supply) do
            local name = unit and unit.name or ""
            local score = ZERO
            local blocked = false

            if self:unitHasTag(unit, "healer") and currentTurn < noHealerBeforeTurn then
                if valueOr(healerDoctrine.ALLOW_EARLY_IF_HUB_THREAT, true) ~= true then
                    blocked = true
                else
                    blocked = true
                end
                if blocked then
                    self.openingHealerBlockedCount = (self.openingHealerBlockedCount or ZERO) + ONE
                end
            end

            if not blocked then
                if name == "Bastion" then
                    score = score + 130
                elseif name == "Artillery" then
                    score = score + 125
                elseif name == "Cloudstriker" then
                    score = score + 115
                elseif name == "Wingstalker" then
                    score = score + 100
                elseif name == "Earthstalker" then
                    score = score + 95
                elseif name == "Crusher" then
                    score = score + 90
                elseif name == "Healer" then
                    score = score + 35
                else
                    score = score + 50
                end

                if requireOpeningSynergy then
                    if name == "Bastion" and (supplyByName.Artillery or ZERO) > ZERO then
                        score = score + 45
                    elseif name == "Artillery" and (supplyByName.Bastion or ZERO) > ZERO then
                        score = score + 45
                    elseif name == "Cloudstriker" and (supplyByName.Wingstalker or ZERO) > ZERO then
                        score = score + 35
                    elseif name == "Wingstalker" and (supplyByName.Cloudstriker or ZERO) > ZERO then
                        score = score + 35
                    elseif name == "Earthstalker" and ((supplyByName.Bastion or ZERO) + (supplyByName.Crusher or ZERO) > ZERO) then
                        score = score + 20
                    end
                end

                if hubEdgeBias == ONE then
                    if name == "Bastion" or name == "Artillery" or name == "Crusher" then
                        score = score + 30
                    end
                else
                    if name == "Cloudstriker" or name == "Wingstalker" then
                        score = score + 20
                    end
                end

                local baseScore = score
                local counterScore = ZERO
                if openingState then
                    counterScore = self:getOpeningCounterScore(openingState, self:getFactionId(), name, {
                        features = opponentFeatures
                    })
                    score = score + counterScore
                end

                local betterBase = false
                if baseScore > bestBaseScore then
                    betterBase = true
                elseif baseScore == bestBaseScore then
                    local resolvedName = tostring(name)
                    local currentBaseName = tostring(bestBaseName or "")
                    if resolvedName < currentBaseName then
                        betterBase = true
                    elseif resolvedName == currentBaseName and (not bestBaseIndex or idx < bestBaseIndex) then
                        betterBase = true
                    end
                end
                if betterBase then
                    bestBaseIndex = idx
                    bestBaseScore = baseScore
                    bestBaseName = name
                end
            end

            if not blocked then
                local better = false
                if score > bestScore then
                    better = true
                elseif score == bestScore then
                    local resolvedName = tostring(name)
                    local currentBestName = tostring(bestName or "")
                    if resolvedName < currentBestName then
                        better = true
                    elseif resolvedName == currentBestName and (not bestIndex or idx < bestIndex) then
                        better = true
                    end
                end

                if better then
                    bestIndex = idx
                    bestScore = score
                    bestName = name
                end
            end
        end

        if bestIndex then
            if openingState and bestBaseIndex and bestIndex ~= bestBaseIndex then
                self.openingCounterScoreAppliedCount = (self.openingCounterScoreAppliedCount or ZERO) + ONE
            end
            return bestIndex
        end

        return nil
    end

    function aiClass:extractOpeningOpponentFeatures(state, aiPlayer)
        local owner = aiPlayer or self:getFactionId()
        if not state or not owner then
            return {
                mix = {ranged = ZERO, tank = ZERO, air = ZERO, melee = ZERO},
                lanePressure = {left = ZERO, center = ZERO, right = ZERO},
                dominantLane = "center",
                approachVector = "center"
            }
        end

        local enemyPlayer = self:getOpponentPlayer(owner)
        local ownHub = state.commandHubs and state.commandHubs[owner]
        local gridSize = self:getBoardSize(state)
        local leftBoundary = math.max(ONE, math.floor(gridSize / THREE))
        local rightBoundary = math.max(ONE, gridSize - leftBoundary + ONE)

        local mix = {
            ranged = ZERO,
            tank = ZERO,
            air = ZERO,
            melee = ZERO
        }
        local lanePressure = {
            left = ZERO,
            center = ZERO,
            right = ZERO
        }
        local approach = {
            left = ZERO,
            center = ZERO,
            right = ZERO
        }

        local function laneForColumn(col)
            if col <= leftBoundary then
                return "left"
            end
            if col >= rightBoundary then
                return "right"
            end
            return "center"
        end

        for _, unit in ipairs(state.units or {}) do
            if unit.player == enemyPlayer and not self:isHubUnit(unit) and not self:isObstacleUnit(unit) then
                if self:unitHasTag(unit, "ranged") then
                    mix.ranged = mix.ranged + ONE
                end
                if self:unitHasTag(unit, "tank") then
                    mix.tank = mix.tank + ONE
                end
                if unit.fly or self:unitHasTag(unit, "corvette") then
                    mix.air = mix.air + ONE
                end
                if self:unitHasTag(unit, "melee") then
                    mix.melee = mix.melee + ONE
                end

                local lane = laneForColumn(unit.col or ONE)
                local pressure = ONE
                if ownHub then
                    local hubDist = math.abs((unit.row or ONE) - ownHub.row) + math.abs((unit.col or ONE) - ownHub.col)
                    pressure = pressure + math.max(ZERO, (gridSize - hubDist) * 0.15)
                    if (unit.col or ONE) < ownHub.col then
                        approach.left = approach.left + ONE
                    elseif (unit.col or ONE) > ownHub.col then
                        approach.right = approach.right + ONE
                    else
                        approach.center = approach.center + ONE
                    end
                end
                lanePressure[lane] = lanePressure[lane] + pressure
            end
        end

        local dominantLane = "center"
        local dominantLaneValue = lanePressure.center or ZERO
        for _, lane in ipairs({"left", "right"}) do
            local laneValue = lanePressure[lane] or ZERO
            if laneValue > dominantLaneValue then
                dominantLane = lane
                dominantLaneValue = laneValue
            end
        end

        local approachVector = "center"
        local approachValue = approach.center or ZERO
        for _, lane in ipairs({"left", "right"}) do
            local laneValue = approach[lane] or ZERO
            if laneValue > approachValue then
                approachVector = lane
                approachValue = laneValue
            end
        end

        return {
            mix = mix,
            lanePressure = lanePressure,
            dominantLane = dominantLane,
            approachVector = approachVector
        }
    end

    function aiClass:getOpeningCounterScore(state, aiPlayer, unitName, opts)
        if not state or not unitName then
            return ZERO
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local counterConfig = doctrineConfig.OPENING_COUNTER or {}
        if tostring(valueOr(counterConfig.MODE, "dynamic_score")) ~= "dynamic_score" then
            return ZERO
        end

        local features = (opts and opts.features) or self:extractOpeningOpponentFeatures(state, aiPlayer)
        local mix = features.mix or {}
        local lanePressure = features.lanePressure or {}
        local dominantLane = features.dominantLane or "center"
        local approachVector = features.approachVector or "center"

        local rangedWeight = valueOr(counterConfig.COUNTER_WEIGHT_RANGED, 1.0)
        local tankWeight = valueOr(counterConfig.COUNTER_WEIGHT_TANK, 1.0)
        local airWeight = valueOr(counterConfig.COUNTER_WEIGHT_AIR, 1.0)
        local laneWeight = valueOr(counterConfig.COUNTER_WEIGHT_LANE_PRESSURE, 1.2)
        local standoffWeight = valueOr(counterConfig.FORMATION_WEIGHT_STANDOFF, 1.0)

        local score = ZERO
        local unit = {name = unitName}
        local rangedPressure = (mix.ranged or ZERO)
        local tankPressure = (mix.tank or ZERO)
        local airPressure = (mix.air or ZERO)
        local dominantLanePressure = lanePressure[dominantLane] or ZERO

        if rangedPressure > ZERO then
            if unitName == "Wingstalker" or unitName == "Cloudstriker" then
                score = score + (35 * rangedWeight)
            elseif unitName == "Bastion" then
                score = score + (18 * rangedWeight)
            end
        end

        if tankPressure > ZERO then
            if unitName == "Earthstalker" then
                score = score + (45 * tankWeight)
            elseif unitName == "Artillery" or unitName == "Bastion" then
                score = score + (20 * tankWeight)
            end
        end

        if airPressure > ZERO then
            if unitName == "Wingstalker" then
                score = score + (32 * airWeight)
            elseif unitName == "Cloudstriker" then
                score = score + (20 * airWeight)
            end
        end

        if dominantLanePressure > ZERO then
            if unitName == "Bastion" or unitName == "Artillery" or unitName == "Crusher" then
                score = score + (math.min(60, dominantLanePressure * 6) * laneWeight)
            end
            if (unitName == "Cloudstriker" or unitName == "Wingstalker") and approachVector == dominantLane then
                score = score + (18 * laneWeight)
            end
        end

        if self:unitHasTag(unit, "ranged") then
            score = score + (15 * standoffWeight)
        end

        return score
    end

    function aiClass:isObstacleUnit(unit)
        return unit and self:unitHasTag(unit, "obstacle") or false
    end

    function aiClass:isHubUnit(unit)
        return unit and self:unitHasTag(unit, "hub") or false
    end

    function aiClass:isAttackableEnemyUnit(unit, aiPlayer, opts)
        if not unit or not aiPlayer then
            return false
        end
        if unit.player == aiPlayer then
            return false
        end

        local options = opts or {}
        if options.excludeHub and self:isHubUnit(unit) then
            return false
        end
        if options.excludeObstacle ~= false and self:isObstacleUnit(unit) then
            return false
        end

        return true
    end

    function aiClass:countDamagedFriendlyUnits(state, aiPlayer, opts)
        if not state or not aiPlayer then
            return ZERO
        end

        local options = opts or {}
        local includeHub = options.includeHub == true
        local count = ZERO

        for _, unit in ipairs(state.units or {}) do
            if unit.player == aiPlayer and not self:isObstacleUnit(unit) and not self:isHubUnit(unit) then
                local hp = unit.currentHp or unit.hp or unit.startingHp or ZERO
                local maxHp = unit.startingHp or unitsInfo:getUnitHP(unit, "DOCTRINE_DAMAGED_UNIT_MAX_HP") or hp
                if hp > ZERO and hp < maxHp then
                    count = count + ONE
                end
            end
        end

        if includeHub and state.commandHubs and state.commandHubs[aiPlayer] then
            local hub = state.commandHubs[aiPlayer]
            local hp = hub.currentHp or hub.startingHp or ZERO
            local maxHp = hub.startingHp or hp
            if hp > ZERO and hp < maxHp then
                count = count + ONE
            end
        end

        return count
    end

    function aiClass:isHealerEarlyDeployAllowed(state, aiPlayer, threatData)
        if not state or not aiPlayer then
            return true
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local healerConfig = doctrineConfig.HEALER or {}
        local minTurn = math.max(ONE, valueOr(healerConfig.EARLY_DEPLOY_TURN_MIN, FIVE))
        local currentTurn = self:getStateTurn(state)
        if currentTurn >= minTurn then
            return true
        end

        local threat = threatData or self:analyzeHubThreat(state)
        if valueOr(healerConfig.ALLOW_EARLY_IF_HUB_THREAT, true) then
            local hubThreat = threat and (
                threat.isUnderAttack == true
                or threat.projectedThreatActionable == true
            )
            if hubThreat then
                return true
            end
        end

        local minDamaged = math.max(
            ONE,
            valueOr(healerConfig.ALLOW_EARLY_IF_DAMAGED_ALLIES_AT_LEAST, TWO)
        )
        local damagedAllies = self:countDamagedFriendlyUnits(state, aiPlayer, {includeHub = true})
        if damagedAllies >= minDamaged then
            return true
        end

        return false
    end

    function aiClass:isRangedStandoffViolation(state, unit, moveCell, aiPlayer, opts)
        if not state or not unit or not moveCell then
            return false
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local rangedConfig = doctrineConfig.RANGED_STANDOFF or {}
        if valueOr(rangedConfig.HARD_AVOID_ADJACENT, false) ~= true then
            return false
        end

        if unitsInfo:canAttackAdjacent(unit.name) then
            return false
        end

        local options = opts or {}
        local enforceAnyAdjacent = options.enforceAnyAdjacent == true

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return false
        end

        local function hasAdjacentThreatAt(pos, meleeOnly)
            if not pos then
                return false, nil
            end
            local proxyTarget = {
                name = unit.name,
                player = owner,
                row = pos.row,
                col = pos.col,
                currentHp = unit.currentHp,
                startingHp = unit.startingHp
            }

            for _, enemy in ipairs(state.units or {}) do
                if self:isAttackableEnemyUnit(enemy, owner) then
                    local dist = math.abs(pos.row - enemy.row) + math.abs(pos.col - enemy.col)
                    if dist == ONE then
                        local canAdjacent = unitsInfo:canAttackAdjacent(enemy.name)
                        if (not meleeOnly) or canAdjacent then
                            local damage = self:calculateDamage(enemy, proxyTarget) or ZERO
                            if damage > ZERO then
                                return true, enemy
                            end
                        end
                    end
                end
            end

            return false, nil
        end

        if unit.name == "Cloudstriker"
            and (not enforceAnyAdjacent)
            and valueOr(rangedConfig.CLOUDSTRIKER_HARD_NO_ADJ_IF_ESCAPE, true) then
            local isAdjacentMeleeThreat = hasAdjacentThreatAt(moveCell, true)
            if not isAdjacentMeleeThreat then
                return false
            end

            if valueOr(rangedConfig.CLOUDSTRIKER_ALLOW_ADJ_IN_EXTREME_DEFENSE, true) then
                local threatData = options.threatData or self:analyzeHubThreat(state)
                local strategicState = options.strategicState or self.strategicPlanState or {}
                local extremeDefense = (threatData and threatData.isUnderAttack == true)
                    or (threatData and threatData.projectedThreatActionable == true and strategicState.intent == "DEFEND_HARD")
                if extremeDefense then
                    return false
                end
            end

            local candidateMoveCells = options.moveCells or self:getValidMoveCells(state, unit.row, unit.col) or {}
            for _, alt in ipairs(candidateMoveCells) do
                if not (alt.row == moveCell.row and alt.col == moveCell.col) then
                    local altIsAdjacentMeleeThreat = hasAdjacentThreatAt(alt, true)
                    if not altIsAdjacentMeleeThreat then
                        return true
                    end
                end
            end

            return false
        end

        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, owner) then
                local dist = math.abs(moveCell.row - enemy.row) + math.abs(moveCell.col - enemy.col)
                if dist == ONE then
                    return true, enemy
                end
            end
        end

        return false
    end

    function aiClass:isHealerMoveDoctrineAllowed(state, unit, moveCell, aiPlayer, opts)
        if not state or not unit or not moveCell then
            return true, nil
        end
        if not self:unitHasTag(unit, "healer") then
            return true, nil
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local healerConfig = doctrineConfig.HEALER or {}
        local owner = aiPlayer or unit.player or self:getFactionId()
        local options = opts or {}
        local allowEmergencyDefense = options.allowEmergencyDefense ~= false
        local allowOffensive = valueOr(healerConfig.ALLOW_OFFENSIVE, true)
        local healerOffensive = self:shouldHealerBeOffensive(state, {
            allowEmergencyDefense = allowEmergencyDefense
        })
        if allowOffensive and healerOffensive then
            return true, nil
        end
        if healerOffensive and not allowOffensive then
            -- Emergency-only offensive windows are still allowed when doctrine disables normal offense.
            return true, nil
        end

        if not self:isHealerOrbitMoveAllowed(state, unit, moveCell, owner) then
            return false, "orbit"
        end

        local frontlineMinDist = math.max(ONE, valueOr(healerConfig.FRONTLINE_MIN_DISTANCE, TWO))
        local nearestEnemyDist = math.huge
        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, owner, {excludeHub = true}) then
                local dist = math.abs(moveCell.row - enemy.row) + math.abs(moveCell.col - enemy.col)
                if dist < nearestEnemyDist then
                    nearestEnemyDist = dist
                end
            end
        end

        if nearestEnemyDist < frontlineMinDist then
            return false, "frontline"
        end

        return true, nil
    end

    function aiClass:isStrategicRockAttack(state, action, opts)
        if not state or not action or action.type ~= "attack" or not action.target then
            return false, "not_attack"
        end

        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer then
            return false, "missing_player"
        end

        local target = options.target
        if not target then
            target = self:getUnitAtPosition(state, action.target.row, action.target.col)
            if not target then
                for _, building in ipairs(state.neutralBuildings or {}) do
                    if building.row == action.target.row and building.col == action.target.col then
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
        end

        if not target or not self:isObstacleUnit(target) then
            return false, "not_rock"
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local rockConfig = doctrineConfig.ROCK_ATTACK or {}
        local requireLosOrPath = valueOr(rockConfig.REQUIRE_LOS_OR_PATH_IMPROVEMENT, true)
        local progressWindow = math.max(ONE, valueOr(rockConfig.ENEMY_HUB_PROGRESS_WINDOW, TWO))
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)] or nil

        if enemyHub then
            local distToEnemyHub = math.abs(target.row - enemyHub.row) + math.abs(target.col - enemyHub.col)
            if distToEnemyHub <= progressWindow then
                return true, "near_enemy_hub"
            end
        end

        if requireLosOrPath and enemyHub then
            for _, friendly in ipairs(state.units or {}) do
                if friendly.player == aiPlayer and self:unitHasTag(friendly, "corvette") then
                    if self:isBlockingLineOfSight(friendly, enemyHub, target) then
                        return true, "opens_corvette_los"
                    end
                end
            end
        end

        if action.unit and action.unit.row and action.unit.col then
            local attacker = self:getUnitAtPosition(state, action.unit.row, action.unit.col)
            if attacker then
                local safeMoveCount = ZERO
                local moveCells = self:getValidMoveCells(state, attacker.row, attacker.col) or {}
                for _, moveCell in ipairs(moveCells) do
                    if self:isMoveSafe(state, attacker, moveCell, {checkVulnerable = true}) then
                        safeMoveCount = safeMoveCount + ONE
                    end
                end
                if safeMoveCount <= ONE then
                    return true, "prevents_tactical_dead_end"
                end
            end
        end

        return false, "no_strategic_impact"
    end

    function aiClass:isNearDeathTarget(target, remainingHp, opts)
        local options = opts or {}
        local thresholds = self:getScoreConfig().TARGET_HEALTH_THRESHOLDS or {}
        local defaultThreshold = thresholds.DEFAULT
        local fortifiedThreshold = options.strictFortified and thresholds.FORTIFIED_STRICT or thresholds.FORTIFIED
        local artilleryThreshold = thresholds.ARTILLERY

        if self:unitHasTag(target, "fortified") then
            return remainingHp <= fortifiedThreshold
        end

        if self:unitHasTag(target, "artillery") then
            return remainingHp <= artilleryThreshold
        end

        return remainingHp == defaultThreshold
    end

    function aiClass:isPositionThreatenedByEnemy(state, aiPlayer, pos, opts)
        if not state or not aiPlayer or not pos then
            return false
        end

        local options = opts or {}
        local ignoreCommandant = options.ignoreCommandant ~= false
        local ignoreRock = options.ignoreRock ~= false

        for _, enemy in ipairs(state.units or {}) do
            if enemy.player and enemy.player ~= aiPlayer then
                local ignore = (ignoreCommandant and self:isHubUnit(enemy))
                    or (ignoreRock and self:isObstacleUnit(enemy))
                if not ignore then
                    local attackCells = self:getValidAttackCells(state, enemy.row, enemy.col) or {}
                    for _, attackCell in ipairs(attackCells) do
                        if attackCell.row == pos.row and attackCell.col == pos.col then
                            return true
                        end
                    end
                end
            end
        end

        return false
    end

    function aiClass:getMirrorCorvetteRetaliationPenalty(state, attacker, target, attackPos, remainingHp)
        if not (self:unitHasTag(attacker, "corvette") and self:unitHasTag(target, "corvette")) then
            return ZERO
        end

        if not attackPos or remainingHp == nil or remainingHp <= ZERO then
            return ZERO
        end

        local distToTarget = math.abs(attackPos.row - target.row) + math.abs(attackPos.col - target.col)
        local targetProfile = self:getUnitProfile(target)
        local minRange = targetProfile and targetProfile.minRange or MIN_HP
        local maxRange = targetProfile and targetProfile.maxRange or MIN_HP
        if distToTarget < minRange or distToTarget > maxRange then
            return ZERO
        end

        if not self:hasLineOfSight(state, target, attackPos) then
            return ZERO
        end

        local attackerTemp = {
            row = attackPos.row,
            col = attackPos.col,
            name = attacker.name,
            player = attacker.player,
            currentHp = attacker.currentHp,
            startingHp = attacker.startingHp,
            atkDamage = attacker.atkDamage
        }
        local retaliatoryDamage = self:calculateDamage(target, attackerTemp)
        if not retaliatoryDamage or retaliatoryDamage <= ZERO then
            return ZERO
        end

        local attackerHp = attacker.currentHp or attacker.startingHp or MIN_HP
        local attackConfig = self:getScoreConfig().ATTACK_DECISION or {}
        if attackerHp - retaliatoryDamage <= ZERO then
            return attackConfig.CORVETTE_RETALIATION_LETHAL_PENALTY
        end

        return attackConfig.CORVETTE_RETALIATION_NONLETHAL_PENALTY
    end

    function aiClass:getAttackOpportunityContext(state, attacker, target, opts)
        if not state or not attacker or not target then
            return nil
        end

        local options = opts or {}
        local aiPlayer = attacker.player or self:getFactionId()
        if not aiPlayer then
            return nil
        end

        local attackPos = options.attackPos or {row = attacker.row, col = attacker.col}
        local targetHp = target.currentHp or target.startingHp or MIN_HP
        local remainingHp = options.remainingHp
        if remainingHp == nil then
            local damage = options.damage or ZERO
            remainingHp = targetHp - damage
        end

        local context = {
            attackPos = {row = attackPos.row, col = attackPos.col},
            remainingHp = remainingHp,
            isNearDeath = self:isNearDeathTarget(target, remainingHp, {strictFortified = options.strictFortified}),
            isHighValueTarget = self:unitHasTag(target, "high_value"),
            isCommandant = self:unitHasTag(target, "hub"),
            isAdjacentToOwnHub = false,
            isNearAdjacentToOwnHub = false,
            hubThreatened = false,
            isRangedThreatToOwnHub = false,
            isSafeAdjacentToEnemyHub = false,
            willBeAdjacentToEnemyHub = false
        }

        local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
        if ownHub then
            local rowDiff = math.abs(target.row - ownHub.row)
            local colDiff = math.abs(target.col - ownHub.col)
            local manhattanDist = rowDiff + colDiff

            context.isAdjacentToOwnHub = (manhattanDist == ONE)
            context.isNearAdjacentToOwnHub = (rowDiff == ONE and colDiff == ONE)

            if context.isAdjacentToOwnHub or context.isNearAdjacentToOwnHub then
                context.hubThreatened = self:isOwnHubThreatened(state, aiPlayer)
            end

            if options.includeRangedThreatToOwnHub and manhattanDist >= TWO then
                local targetRange = unitsInfo:getUnitAttackRange(target, "HIGH_VALUE_RANGED_THREAT_CHECK")
                if targetRange and targetRange > ONE and manhattanDist <= targetRange then
                    if self:unitHasTag(target, "artillery") then
                        context.isRangedThreatToOwnHub = true
                    elseif self:unitHasTag(target, "los") and self:hasLineOfSight(state, target, ownHub) then
                        context.isRangedThreatToOwnHub = true
                    end
                end
            end
        end

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        if enemyHub and context.isCommandant then
            local distToEnemyHub = math.abs(attackPos.row - enemyHub.row) + math.abs(attackPos.col - enemyHub.col)
            context.willBeAdjacentToEnemyHub = (distToEnemyHub == ONE)

            if options.includeSafeEnemyHubAdjacency and context.willBeAdjacentToEnemyHub then
                context.isSafeAdjacentToEnemyHub = not self:isPositionThreatenedByEnemy(state, aiPlayer, attackPos, {
                    ignoreCommandant = true,
                    ignoreRock = true
                })
            end
        end

        return context
    end

    function aiClass:shouldPrioritizeAttackContext(context, damage, opts)
        if not context then
            return false
        end

        local options = opts or {}
        if context.isNearDeath then
            return true
        end
        if context.isHighValueTarget and damage > ZERO then
            return true
        end
        if context.isCommandant then
            return true
        end
        if context.isAdjacentToOwnHub or context.isNearAdjacentToOwnHub then
            return true
        end
        if options.includeRangedThreatToOwnHub and context.isRangedThreatToOwnHub then
            return true
        end
        if context.isSafeAdjacentToEnemyHub then
            return true
        end
        if options.includeUnsafeEnemyHubAdj and context.willBeAdjacentToEnemyHub then
            return true
        end

        return false
    end

    function aiClass:evaluateAttackOpportunityEntry(state, entry, opts)
        if not state or not entry or not entry.unit or not entry.target then
            return nil
        end

        local options = opts or {}
        local unit = entry.unit
        local target = entry.target
        local damage = entry.damage or ZERO
        local specialAbilitiesUsed = entry.specialUsed
        local attackPos = options.attackPos
            or entry.moveCell
            or {row = unit.row, col = unit.col}

        local context = self:getAttackOpportunityContext(state, unit, target, {
            damage = damage,
            attackPos = {row = attackPos.row, col = attackPos.col},
            strictFortified = options.strictFortified,
            includeRangedThreatToOwnHub = options.includeRangedThreatToOwnHub,
            includeSafeEnemyHubAdjacency = options.includeSafeEnemyHubAdjacency
        })

        local projectedAttacker = unit
        if attackPos and attackPos.row and attackPos.col
            and (attackPos.row ~= unit.row or attackPos.col ~= unit.col) then
            projectedAttacker = self:buildProjectedThreatUnit(unit, attackPos.row, attackPos.col) or unit
        end

        if not self:shouldPrioritizeAttackContext(context, damage, options.prioritizeOptions) then
            return nil
        end

        if options.requireAttackSafety then
            local attackAllowed = self:isAttackSafe(state, projectedAttacker, target, {
                allowBeneficialSuicide = options.allowBeneficialSuicide == true
            })
            if not attackAllowed then
                return nil
            end
        end

        if options.requireAttackerSurvival and self:wouldUnitDieNextTurn(state, projectedAttacker) then
            return nil
        end

        local requireBackedNonLethal = options.requireBackedNonLethal
        if requireBackedNonLethal == nil then
            requireBackedNonLethal = valueOr(
                (self:getStrategyScoreConfig().DEFENSE or {}).REQUIRE_BACKED_ATTACK_NONLETHAL,
                true
            )
        end
        if requireBackedNonLethal and attackPos and attackPos.row == unit.row and attackPos.col == unit.col then
            local isBacked = self:isNonLethalAttackBacked(state, {
                type = "attack",
                unit = {row = unit.row, col = unit.col},
                target = {row = target.row, col = target.col}
            })
            if not isBacked then
                return nil
            end
        end

        local scoreOptions = {}
        for key, value in pairs(options.scoreOptions or {}) do
            scoreOptions[key] = value
        end

        local value = self:getAttackOpportunityScore(
            state,
            unit,
            target,
            damage,
            specialAbilitiesUsed,
            context,
            scoreOptions
        )

        return {
            value = value,
            context = context
        }
    end

    function aiClass:collectEvaluatedAttackEntries(state, entries, opts)
        if not state or not entries then
            return {}
        end

        local options = opts or {}
        local evaluateOptionsFn = options.evaluateOptionsFn
        local resultFn = options.resultFn
        local scoredEntries = {}

        for _, entry in ipairs(entries) do
            local evaluateOpts = evaluateOptionsFn and evaluateOptionsFn(entry) or {}
            local evaluation = self:evaluateAttackOpportunityEntry(state, entry, evaluateOpts)
            if evaluation then
                local result = resultFn and resultFn(entry, evaluation) or {
                    entry = entry,
                    value = evaluation.value,
                    context = evaluation.context
                }
                if result then
                    scoredEntries[#scoredEntries + ONE] = result
                end
            end
        end

        self:sortScoredEntries(scoredEntries, {
            scoreField = options.scoreField or "value",
            secondaryField = options.secondaryField,
            descending = options.descending ~= false,
            secondaryDescending = options.secondaryDescending,
            secondaryFn = options.secondaryFn
        })

        return scoredEntries
    end

    function aiClass:getStateUnitValueTotals(state, aiPlayer)
        if not state or not aiPlayer then
            return {
                friendlyValue = ZERO,
                enemyValue = ZERO,
                materialDiff = ZERO
            }
        end

        local opponent = self:getOpponentPlayer(aiPlayer)
        local friendlyValue = ZERO
        local enemyValue = ZERO

        for _, unit in ipairs(state.units or {}) do
            local hp = unit.currentHp or unit.startingHp or ZERO
            if hp > ZERO and not self:isObstacleUnit(unit) and not self:isHubUnit(unit) then
                local maxHp = math.max(MIN_HP, unit.startingHp or hp or MIN_HP)
                local hpRatio = math.max(0, math.min(ONE, hp / maxHp))
                local baseValue = self:getUnitBaseValue(unit, state) or (self:getTargetPriority(unit) or ZERO)
                local weightedValue = baseValue * hpRatio
                if unit.player == aiPlayer then
                    friendlyValue = friendlyValue + weightedValue
                elseif unit.player == opponent then
                    enemyValue = enemyValue + weightedValue
                end
            end
        end

        return {
            friendlyValue = friendlyValue,
            enemyValue = enemyValue,
            materialDiff = friendlyValue - enemyValue
        }
    end

    function aiClass:estimateExchangeDelta(state, action, horizonPlies)
        if not state or not action or action.type ~= "attack" or not action.unit or not action.target then
            return NEGATIVE_MIN_HP
        end

        local attacker = self:getUnitAtPosition(state, action.unit.row, action.unit.col)
        local target = self:getUnitAtPosition(state, action.target.row, action.target.col)
        if not attacker or not target then
            return NEGATIVE_MIN_HP
        end

        local targetHp = target.currentHp or target.startingHp or MIN_HP
        local damage = self:calculateDamage(attacker, target) or ZERO
        local targetValue = self:getUnitBaseValue(target, state) or ZERO
        local attackerValue = self:getUnitBaseValue(attacker, state) or ZERO

        local simState = self:applyMove(state, action)
        local targetAfter = self:getUnitAtPosition(simState, action.target.row, action.target.col)
        local targetKilled = (not targetAfter)
            or targetAfter.player == attacker.player
            or (targetAfter.currentHp or ZERO) <= ZERO

        local attackerAfter = self:getUnitAtPosition(simState, action.unit.row, action.unit.col)
        if not attackerAfter and targetKilled then
            local isAdjacent = math.abs(action.unit.row - action.target.row) + math.abs(action.unit.col - action.target.col) == ONE
            if isAdjacent and not self:unitHasTag(attacker, "corvette") then
                attackerAfter = self:getUnitAtPosition(simState, action.target.row, action.target.col)
            end
        end

        local attackerDiesNextTurn = attackerAfter and self:wouldUnitDieNextTurn(simState, attackerAfter) or false
        local inflictedValue = targetKilled
            and targetValue
            or (targetValue * math.max(ZERO, math.min(ONE, damage / math.max(MIN_HP, targetHp))))
        local lossValue = attackerDiesNextTurn and attackerValue or ZERO

        if horizonPlies and horizonPlies > ONE and (not targetKilled) and targetAfter then
            local continuationThreat = false
            local aiPlayer = attacker.player
            for _, ally in ipairs(simState.units or {}) do
                if ally.player == aiPlayer and not self:isHubUnit(ally) and not self:isObstacleUnit(ally) then
                    local sameAsAttacker = false
                    if attackerAfter then
                        sameAsAttacker = ally.row == attackerAfter.row
                            and ally.col == attackerAfter.col
                            and ally.name == attackerAfter.name
                    end
                    if not sameAsAttacker then
                        local turn = self:getUnitThreatTiming(
                            simState,
                            ally,
                            targetAfter,
                            horizonPlies,
                            {
                                requirePositiveDamage = true,
                                considerCurrentActionState = false,
                                allowMoveOnFirstTurn = true,
                                maxFrontierNodes = 16
                            }
                        )
                        if turn and turn <= horizonPlies then
                            continuationThreat = true
                            break
                        end
                    end
                end
            end
            if continuationThreat then
                inflictedValue = inflictedValue + (targetValue * 0.25)
            end
        end

        return inflictedValue - lossValue
    end

    function aiClass:evaluateAttackSupportAfterAction(state, action, horizonPlies)
        local horizon = math.max(ONE, horizonPlies or TWO)
        local result = {
            exchangeDelta = NEGATIVE_MIN_HP,
            followupAttackers = ZERO,
            targetEliminated = false,
            attackerWillDie = false
        }

        if not state or not action or action.type ~= "attack" or not action.unit or not action.target then
            return result
        end

        local attacker = self:getUnitAtPosition(state, action.unit.row, action.unit.col)
        local target = self:getUnitAtPosition(state, action.target.row, action.target.col)
        if not attacker or not target then
            return result
        end

        local simState = self:applyMove(state, action)
        local targetAfter = self:getUnitAtPosition(simState, action.target.row, action.target.col)
        local targetEliminated = (not targetAfter)
            or targetAfter.player == attacker.player
            or (targetAfter.currentHp or ZERO) <= ZERO
        result.targetEliminated = targetEliminated

        local attackerAfter = self:getUnitAtPosition(simState, action.unit.row, action.unit.col)
        if not attackerAfter and targetEliminated then
            local isAdjacent = math.abs(action.unit.row - action.target.row) + math.abs(action.unit.col - action.target.col) == ONE
            if isAdjacent and not self:unitHasTag(attacker, "corvette") then
                attackerAfter = self:getUnitAtPosition(simState, action.target.row, action.target.col)
            end
        end

        result.attackerWillDie = attackerAfter and self:wouldUnitDieNextTurn(simState, attackerAfter) or false
        result.exchangeDelta = self:estimateExchangeDelta(state, action, horizon)

        if targetAfter and not targetEliminated then
            local aiPlayer = attacker.player
            local attackerKey = attackerAfter and self:getUnitKey(attackerAfter) or nil
            for _, ally in ipairs(simState.units or {}) do
                if ally.player == aiPlayer and not self:isHubUnit(ally) and not self:isObstacleUnit(ally) then
                    local allyKey = self:getUnitKey(ally)
                    if (not attackerKey) or allyKey ~= attackerKey then
                        local turn = self:getUnitThreatTiming(
                            simState,
                            ally,
                            targetAfter,
                            horizon,
                            {
                                requirePositiveDamage = true,
                                considerCurrentActionState = false,
                                allowMoveOnFirstTurn = true,
                                maxFrontierNodes = 16
                            }
                        )
                        if turn and turn <= horizon then
                            result.followupAttackers = result.followupAttackers + ONE
                        end
                    end
                end
            end
        end

        return result
    end

    function aiClass:isLosingRangedDuelAfterAttack(state, action, opts)
        local options = opts or {}
        if not state or not action or action.type ~= "attack" or not action.unit or not action.target then
            return false, {reason = "invalid_action"}
        end

        local attacker = self:getUnitAtPosition(state, action.unit.row, action.unit.col)
        local target = self:getUnitAtPosition(state, action.target.row, action.target.col)
        if not attacker or not target then
            return false, {reason = "invalid_source_or_target"}
        end

        if not self:unitHasTag(attacker, "ranged") or not self:unitHasTag(target, "ranged") then
            return false, {reason = "not_ranged_duel"}
        end

        local attackerDamage = self:calculateDamage(attacker, target) or ZERO
        local targetDamage = self:calculateDamage(target, attacker) or ZERO
        local targetHp = target.currentHp or target.startingHp or MIN_HP
        local attackerHp = attacker.currentHp or attacker.startingHp or MIN_HP
        if attackerDamage <= ZERO or targetDamage <= ZERO then
            return false, {reason = "no_mutual_damage"}
        end

        if attackerDamage >= targetHp then
            return false, {reason = "lethal_now"}
        end

        local retaliationTurn = self:getUnitThreatTiming(
            state,
            target,
            attacker,
            TWO,
            {
                requirePositiveDamage = true,
                considerCurrentActionState = false,
                allowMoveOnFirstTurn = true,
                maxFrontierNodes = 16
            }
        )
        if not retaliationTurn or retaliationTurn > ONE then
            return false, {reason = "retaliation_not_immediate", retaliationTurn = retaliationTurn}
        end

        local remainingTargetHp = math.max(ZERO, targetHp - attackerDamage)
        local attackerShotsRemaining = math.ceil(remainingTargetHp / math.max(MIN_HP, attackerDamage))
        local targetShotsToKill = math.ceil(attackerHp / math.max(MIN_HP, targetDamage))
        local losingRace = attackerShotsRemaining >= targetShotsToKill

        return losingRace, {
            reason = losingRace and "duel_unfavorable" or "duel_favorable",
            retaliationTurn = retaliationTurn,
            attackerShotsRemaining = attackerShotsRemaining,
            targetShotsToKill = targetShotsToKill,
            attackerDamage = attackerDamage,
            targetDamage = targetDamage
        }
    end

    function aiClass:getRangedDuelPressureTargets(state, unit, aiPlayer, opts)
        local options = opts or {}
        if not state or not unit then
            return {}
        end
        if not self:unitHasTag(unit, "ranged") then
            return {}
        end
        if self:unitHasTag(unit, "tank")
            or self:unitHasTag(unit, "fortified")
            or self:unitHasTag(unit, "healer") then
            return {}
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return {}
        end

        local cacheStateKey = tostring(state)
        local cacheUnitKey = self:getUnitKey(unit)
            or string.format(
                "%s:%d,%d:%d:%d",
                tostring(unit.name or "unit"),
                unit.row or ZERO,
                unit.col or ZERO,
                unit.player or ZERO,
                unit.currentHp or unit.startingHp or ZERO
            )
        local cacheKey = string.format("%s#%s", cacheStateKey, cacheUnitKey)
        if options.useCache ~= false then
            self._rangedDuelPressureCache = self._rangedDuelPressureCache or {}
            if self._rangedDuelPressureCache[cacheKey] ~= nil then
                return self._rangedDuelPressureCache[cacheKey]
            end
        end

        local pressureTargets = {}
        local unitHp = unit.currentHp or unit.startingHp or MIN_HP

        for _, enemy in ipairs(state.units or {}) do
            if self:isAttackableEnemyUnit(enemy, owner, {excludeHub = true})
                and self:unitHasTag(enemy, "ranged") then
                local canHitEnemy = self:canUnitDamageTargetFromPosition(
                    state,
                    unit,
                    enemy,
                    unit.row,
                    unit.col,
                    {requirePositiveDamage = true}
                )
                local enemyCanHitBack = self:canUnitDamageTargetFromPosition(
                    state,
                    enemy,
                    unit,
                    enemy.row,
                    enemy.col,
                    {requirePositiveDamage = true}
                )
                if canHitEnemy and enemyCanHitBack then
                    local attackerDamage = self:calculateDamage(unit, enemy) or ZERO
                    local targetDamage = self:calculateDamage(enemy, unit) or ZERO
                    local enemyHp = enemy.currentHp or enemy.startingHp or MIN_HP
                    if attackerDamage > ZERO and targetDamage > ZERO and attackerDamage < enemyHp then
                        local retaliationTurn = self:getUnitThreatTiming(
                            state,
                            enemy,
                            unit,
                            TWO,
                            {
                                requirePositiveDamage = true,
                                considerCurrentActionState = false,
                                allowMoveOnFirstTurn = true,
                                maxFrontierNodes = 16
                            }
                        )
                        if retaliationTurn and retaliationTurn <= ONE then
                            local attackerShotsRemaining = math.ceil(enemyHp / math.max(MIN_HP, attackerDamage))
                            local targetShotsToKill = math.ceil(unitHp / math.max(MIN_HP, targetDamage))
                            if attackerShotsRemaining >= targetShotsToKill then
                                pressureTargets[#pressureTargets + ONE] = {
                                    enemy = enemy,
                                    retaliationTurn = retaliationTurn,
                                    attackerShotsRemaining = attackerShotsRemaining,
                                    targetShotsToKill = targetShotsToKill,
                                    attackerDamage = attackerDamage,
                                    targetDamage = targetDamage,
                                    threatScore = ((self:getUnitBaseValue(enemy, state) or ZERO) * 0.6)
                                        + (targetDamage * 80)
                                }
                            end
                        end
                    end
                end
            end
        end

        self:sortScoredEntries(pressureTargets, {
            scoreField = "threatScore",
            descending = true
        })

        if options.useCache ~= false then
            self._rangedDuelPressureCache = self._rangedDuelPressureCache or {}
            self._rangedDuelPressureCache[cacheKey] = pressureTargets
        end

        return pressureTargets
    end

    function aiClass:calculateRangedDuelEvasionBonus(state, unit, movePos, aiPlayer, opts)
        if not state or not unit or not movePos or not movePos.row or not movePos.col then
            return ZERO
        end
        if not self:unitHasTag(unit, "ranged") then
            return ZERO
        end
        if self:unitHasTag(unit, "tank")
            or self:unitHasTag(unit, "fortified")
            or self:unitHasTag(unit, "healer") then
            return ZERO
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local duelConfig = doctrineConfig.RANGED_DUEL_EVASION or {}
        if duelConfig.ENABLED == false then
            return ZERO
        end

        local owner = aiPlayer or unit.player or self:getFactionId()
        if not owner then
            return ZERO
        end

        local options = opts or {}
        local simState = options.simState
        local movedUnit = options.movedUnit
        if not simState or not movedUnit then
            simState, movedUnit = self:simulateStateAfterMove(state, unit, movePos)
        end
        if not simState or not movedUnit then
            return ZERO
        end

        local pressureTargets = options.pressureTargets or self:getRangedDuelPressureTargets(state, unit, owner)
        if not pressureTargets or #pressureTargets <= ZERO then
            return ZERO
        end

        local retaliationBreakBonus = valueOr(duelConfig.RETALIATION_BREAK_BONUS, 165)
        local retaliationDelayBonus = valueOr(duelConfig.RETALIATION_DELAY_BONUS, 90)
        local attackPostureBonus = valueOr(duelConfig.ATTACK_POSTURE_BONUS, 65)
        local losMaintainBonus = valueOr(duelConfig.LOS_MAINTAIN_BONUS, 40)
        local failedPosturePenalty = valueOr(duelConfig.FAILED_POSTURE_PENALTY, 55)
        local bonusCap = math.max(80, valueOr(duelConfig.BONUS_CAP, 240))

        local bestBonus = ZERO

        for _, duel in ipairs(pressureTargets) do
            local enemy = duel and duel.enemy
            if enemy then
                local score = ZERO
                local currentRetaliationTurn = duel.retaliationTurn or ONE
                local newRetaliationTurn = self:getUnitThreatTiming(
                    simState,
                    enemy,
                    movedUnit,
                    TWO,
                    {
                        requirePositiveDamage = true,
                        considerCurrentActionState = false,
                        allowMoveOnFirstTurn = true,
                        maxFrontierNodes = 16
                    }
                )

                if not newRetaliationTurn then
                    score = score + retaliationBreakBonus
                elseif newRetaliationTurn > currentRetaliationTurn then
                    score = score + ((newRetaliationTurn - currentRetaliationTurn) * retaliationDelayBonus)
                end

                local canThreatNow = self:canUnitDamageTargetFromPosition(
                    simState,
                    movedUnit,
                    enemy,
                    movedUnit.row,
                    movedUnit.col,
                    {requirePositiveDamage = true}
                )
                local canThreatSoon = self:getUnitThreatTiming(
                    simState,
                    movedUnit,
                    enemy,
                    TWO,
                    {
                        requirePositiveDamage = true,
                        considerCurrentActionState = false,
                        allowMoveOnFirstTurn = true,
                        maxFrontierNodes = 16
                    }
                )
                local keepsPosture = canThreatNow or (canThreatSoon and canThreatSoon <= TWO)
                if keepsPosture then
                    score = score + attackPostureBonus
                    if canThreatNow and self:unitHasTag(movedUnit, "los") and self:hasLineOfSight(simState, movedUnit, enemy) then
                        score = score + losMaintainBonus
                    end
                else
                    score = score - failedPosturePenalty
                end

                if score > bestBonus then
                    bestBonus = score
                end
            end
        end

        if bestBonus <= ZERO then
            return ZERO
        end
        return math.min(bestBonus, bonusCap)
    end

    function aiClass:isNonLethalAttackBacked(state, action, opts)
        local options = opts or {}
        if not state or not action or action.type ~= "attack" or not action.unit or not action.target then
            return false, {reason = "invalid_action"}
        end

        local attacker = self:getUnitAtPosition(state, action.unit.row, action.unit.col)
        local target = self:getUnitAtPosition(state, action.target.row, action.target.col)
        if not attacker or not target then
            return false, {reason = "invalid_source_or_target"}
        end

        local damage = self:calculateDamage(attacker, target) or ZERO
        local targetHp = target.currentHp or target.startingHp or MIN_HP
        local lethal = damage >= targetHp
        if lethal then
            return true, {
                lethal = true,
                reason = "lethal"
            }
        end

        local strategyConfig = self:getStrategyScoreConfig()
        local defenseConfig = strategyConfig.DEFENSE or {}
        local requireBacked = valueOr(defenseConfig.REQUIRE_BACKED_ATTACK_NONLETHAL, true)
        if not requireBacked then
            return true, {
                lethal = false,
                reason = "gate_disabled"
            }
        end

        local support = self:evaluateAttackSupportAfterAction(state, action, options.horizonPlies or TWO)
        local minExchangeDelta = valueOr(defenseConfig.MIN_NONLETHAL_EXCHANGE_DELTA, ZERO)
        local tempoContext = options.tempoContext or self:getPhaseTempoContext(state)
        local doctrineConfig = self:getDoctrineScoreConfig()
        local earlyTempoConfig = doctrineConfig.EARLY_TEMPO or {}
        local midTempoConfig = doctrineConfig.MID_TEMPO or {}

        if tempoContext and tempoContext.phase == "early" then
            minExchangeDelta = math.max(minExchangeDelta, valueOr(earlyTempoConfig.MIN_SUPPORTED_ATTACK_GAIN, 120))
        elseif tempoContext and tempoContext.phase == "mid" and valueOr(midTempoConfig.ENABLE_FREQUENT_INTERACTIONS, true) then
            minExchangeDelta = math.max(minExchangeDelta, valueOr(midTempoConfig.LOWER_SUPPORTED_ATTACK_GAIN, 70))
        end

        local minFollowups = math.max(ZERO, valueOr(defenseConfig.MIN_FOLLOWUP_ATTACKERS, ONE))
        local exchangeOk = (support.exchangeDelta or NEGATIVE_MIN_HP) >= minExchangeDelta
        local followupOk = (support.followupAttackers or ZERO) >= minFollowups
        local supported = exchangeOk or followupOk
        local emergencyDefense = options.allowEmergencyDefense ~= false
            and self.strategicState
            and self.strategicState.intent == "DEFEND_HARD"
        local duelLosing, duelContext = self:isLosingRangedDuelAfterAttack(state, action, options)
        if duelLosing and (not followupOk) and (not emergencyDefense) then
            supported = false
        end

        support.lethal = false
        support.minExchangeDelta = minExchangeDelta
        support.minFollowups = minFollowups
        support.exchangeOk = exchangeOk
        support.followupOk = followupOk
        support.duelLosing = duelLosing
        support.duelContext = duelContext
        support.emergencyDefense = emergencyDefense
        support.tempoPhase = tempoContext and tempoContext.phase or nil
        if duelLosing and (not followupOk) and (not emergencyDefense) then
            support.reason = "unsupported_ranged_duel"
        else
            support.reason = supported and "supported" or "unsupported_nonlethal"
        end

        return supported, support
    end

    function aiClass:isNonLethalMoveAttackBacked(state, moveAction, attackAction, opts)
        if not state or not moveAction or not attackAction then
            return false, {reason = "invalid_move_attack"}
        end

        local simState = self:applyMove(state, moveAction)
        if not simState then
            return false, {reason = "move_simulation_failed"}
        end

        return self:isNonLethalAttackBacked(simState, attackAction, opts)
    end

    function aiClass:getCanonicalAttackScore(state, attacker, target, damage, opts)
        if not state or not attacker or not target then
            return ZERO
        end

        local options = opts or {}
        local attackConfig = self:getScoreConfig().ATTACK_DECISION or {}
        local multiplier = valueOr(options.damageMultiplier, attackConfig.DAMAGE_MULT)
        local score = (damage or ZERO) * (multiplier or ZERO)

        if options.includeTargetValue then
            if options.useBaseTargetValue then
                score = score + (self:getUnitBaseValue(target, state) or ZERO)
            else
                score = score + (self:getTargetPriority(target) or ZERO)
            end
        end

        if options.includeOwnHubAdjBonus then
            local aiPlayer = options.aiPlayer or attacker.player or self:getFactionId()
            local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
            if ownHub and target.row and target.col then
                local rowDiff = math.abs(target.row - ownHub.row)
                local colDiff = math.abs(target.col - ownHub.col)
                local dist = rowDiff + colDiff
                if dist == ONE then
                    score = score + (options.ownHubAdjBonus or attackConfig.OWN_HUB_ADJ_BONUS or ZERO)
                elseif options.includeNearOwnHubAdjBonus and rowDiff == ONE and colDiff == ONE then
                    score = score + (options.nearOwnHubAdjBonus or attackConfig.OWN_HUB_NEAR_ADJ_BONUS or ZERO)
                end
            end
        end

        if options.commandantBonus and self:unitHasTag(target, "hub") then
            score = score + options.commandantBonus
        end

        return score
    end

    function aiClass:getAttackOpportunityScore(state, attacker, target, damage, specialAbilitiesUsed, context, opts)
        local options = opts or {}
        local scoreConfig = self:getScoreConfig()
        local attackConfig = scoreConfig.ATTACK_DECISION or {}

        local score = self:getCanonicalAttackScore(state, attacker, target, damage, {
            damageMultiplier = attackConfig.DAMAGE_MULT,
            includeTargetValue = options.includeTargetValue == true,
            useBaseTargetValue = options.useBaseTargetValue == true,
            includeOwnHubAdjBonus = false
        })

        local positionalUnit = options.positionalUnit or attacker
        score = score + self:getPositionalValue(state, {
            row = positionalUnit.row,
            col = positionalUnit.col,
            name = positionalUnit.name,
            player = positionalUnit.player
        })

        if specialAbilitiesUsed then
            score = score + attackConfig.SPECIAL_ABILITY_BONUS
        end

        if context and context.isCommandant then
            score = score + attackConfig.COMMANDANT_BONUS
        end

        local applyDefenseBonus = true
        if options.requireHubThreatForDefenseBonus then
            applyDefenseBonus = context and context.hubThreatened or false
        end
        if applyDefenseBonus and context then
            if context.isAdjacentToOwnHub then
                score = score + attackConfig.OWN_HUB_ADJ_BONUS
            elseif context.isNearAdjacentToOwnHub then
                score = score + attackConfig.OWN_HUB_NEAR_ADJ_BONUS
            end
        end

        if options.includeRangedThreatToOwnHub and context and context.isRangedThreatToOwnHub then
            score = score + attackConfig.OWN_HUB_RANGED_THREAT_BONUS
        end

        if context then
            if context.isSafeAdjacentToEnemyHub then
                score = score + attackConfig.SAFE_ENEMY_HUB_ADJ_BONUS
            elseif options.includeUnsafeEnemyHubAdj and context.willBeAdjacentToEnemyHub then
                score = score + attackConfig.UNSAFE_ENEMY_HUB_ADJ_BONUS
            end
        end

        if options.applyCorvetteRetaliationPenalty and context then
            score = score - self:getMirrorCorvetteRetaliationPenalty(
                state,
                attacker,
                target,
                context.attackPos,
                context.remainingHp
            )
        end

        if options.applyCommanderExposurePenalty and options.movePos then
            score = score - self:calculateCommanderExposurePenalty(state, attacker, options.movePos)
        end

        if options.includeThreatReleaseOffense ~= false then
            local attackKind = options.movePos and "move_attack" or "direct_attack"
            local attackPos = options.movePos or (context and context.attackPos) or {row = attacker.row, col = attacker.col}
            score = score + self:getThreatReleaseOffenseBonus(state, target, attackPos, attackKind)
        end

        return score
    end

    function aiClass:isSingleHpPriorityRepairTarget(target)
        if not target or not target.name then
            return false
        end

        local repairConfig = self:getScoreConfig().REPAIR or {}
        local preferredUnits = repairConfig.SINGLE_HP_PRIORITY_UNITS or {}
        for _, unitName in ipairs(preferredUnits) do
            if unitName == target.name then
                return true
            end
        end
        return false
    end

    function aiClass:getRepairTargetPriority(state, target, currentHp, maxHp, repairAmount)
        if not state or not target or not target.name or not currentHp or not maxHp then
            return nil, false
        end
        if currentHp <= ZERO or currentHp >= maxHp then
            return nil, false
        end

        local repairConfig = self:getScoreConfig().REPAIR or {}
        local missingHp = maxHp - currentHp
        local baseEligible = nil
        local survivalBonusApplied = false
        local wouldDieWithoutRepair = self:wouldUnitDieNextTurn(state, target)

        if wouldDieWithoutRepair then
            local repairedTarget = {
                row = target.row,
                col = target.col,
                name = target.name,
                player = target.player,
                currentHp = math.min(currentHp + (repairAmount or MIN_HP), maxHp),
                startingHp = maxHp
            }
            local survivesAfterRepair = not self:wouldUnitDieNextTurn(state, repairedTarget)
            if survivesAfterRepair then
                baseEligible = repairConfig.BASE_ELIGIBLE
                survivalBonusApplied = true
            end
        end

        if not baseEligible then
            if self:unitHasTag(target, "hub") then
                baseEligible = repairConfig.BASE_ELIGIBLE
            elseif missingHp >= MIN_HP + MIN_HP then
                baseEligible = repairConfig.BASE_ELIGIBLE
            elseif missingHp == MIN_HP and self:isSingleHpPriorityRepairTarget(target) then
                baseEligible = repairConfig.SINGLE_HP_PRIORITY_BASE
            end
        end

        if not baseEligible then
            return nil, false
        end

        local unitPriority = (repairConfig.UNIT_PRIORITY or {})[target.name]
        local priority = unitPriority or baseEligible
        priority = priority + (missingHp * repairConfig.HP_MISSING_MULT)

        if survivalBonusApplied then
            priority = priority + repairConfig.SURVIVAL_BONUS
        elseif wouldDieWithoutRepair then
            priority = priority + repairConfig.NO_SURVIVAL_BONUS
        end

        return priority, true
    end

    function aiClass:passesSafetyPolicy(state, unit, opts)
        if not state or not unit then
            return false, "missing_state_or_unit"
        end

        local options = self:resolveSafetyPolicyOptions(opts or {})
        local targetPos = options.targetPos
        local targetUnit = options.targetUnit
        local checkVulnerable = options.checkVulnerable or false
        local requireVulnerable = options.requireVulnerable or false
        local allowSuicidalMove = options.allowSuicidalMove or false
        local allowSuicidalAttack = options.allowSuicidalAttack or false
        local allowBeneficialSuicide = options.allowBeneficialSuicide or false

        if targetPos and not allowSuicidalMove and self:isSuicidalMovement(state, targetPos, unit) then
            return false, "suicidal_move"
        end

        if targetPos and requireVulnerable and not self:isVulnerableToMoveAttack(state, targetPos, unit) then
            return false, "requires_move_attack_vulnerability"
        end

        if targetPos and checkVulnerable and self:isVulnerableToMoveAttack(state, targetPos, unit) then
            return false, "move_attack_vulnerable"
        end

        if targetUnit then
            local suicidalAttack = self:isSuicidalAttack(state, unit, targetUnit)
            if suicidalAttack and not allowSuicidalAttack then
                if allowBeneficialSuicide and self:isBeneficialSuicidalAttack(state, unit, targetUnit) then
                    return true, "beneficial_suicidal_attack"
                end
                return false, "suicidal_attack"
            end
        end

        return true, "safe"
    end

    function aiClass:isMoveSafe(state, unit, targetPos, opts)
        local options = self:resolveSafetyPolicyOptions("move_base", opts)
        options.targetPos = targetPos
        return self:passesSafetyPolicy(state, unit, options)
    end

    function aiClass:isOpenSafeMoveCell(state, unit, moveCell, opts)
        if not state or not unit or not moveCell or not moveCell.row or not moveCell.col then
            return false, "invalid_move_cell"
        end

        if self:getUnitAtPosition(state, moveCell.row, moveCell.col) then
            return false, "occupied_destination"
        end

        local targetPos = {row = moveCell.row, col = moveCell.col}
        return self:isMoveSafe(state, unit, targetPos, opts)
    end

    function aiClass:isVulnerableMovePosition(state, unit, targetPos, opts)
        local options = self:resolveSafetyPolicyOptions("move_risky", opts)
        options.targetPos = targetPos
        return self:passesSafetyPolicy(state, unit, options)
    end

    function aiClass:isAttackSafe(state, attacker, target, opts)
        local options = self:resolveSafetyPolicyOptions("attack_base", opts)
        options.targetUnit = target
        return self:passesSafetyPolicy(state, attacker, options)
    end

    function aiClass:simulateStateAfterMove(state, unit, moveCell)
        if not state or not unit or not moveCell or not moveCell.row or not moveCell.col then
            return nil, nil
        end

        local simState = self:deepCopyState(state)
        local movedUnit = nil

        for _, simUnit in ipairs(simState.units or {}) do
            if simUnit.player == unit.player
                and simUnit.row == unit.row
                and simUnit.col == unit.col
                and simUnit.name == unit.name then
                simUnit.row = moveCell.row
                simUnit.col = moveCell.col
                movedUnit = simUnit
            elseif simUnit.row == moveCell.row and simUnit.col == moveCell.col then
                simUnit.row = unit.row
                simUnit.col = unit.col
            end
        end

        if simState.commandHubs then
            for _, hub in pairs(simState.commandHubs) do
                if hub.row == unit.row and hub.col == unit.col then
                    hub.row = moveCell.row
                    hub.col = moveCell.col
                elseif hub.row == moveCell.row and hub.col == moveCell.col then
                    hub.row = unit.row
                    hub.col = unit.col
                end
            end
        end

        simState = self:validateAndFixUnitStates(simState)
        movedUnit = movedUnit or {
            row = moveCell.row,
            col = moveCell.col,
            name = unit.name,
            player = unit.player,
            currentHp = unit.currentHp,
            startingHp = unit.startingHp
        }

        return simState, movedUnit
    end

    function aiClass:getMovePositionalDelta(state, unit, movePos, opts)
        if not state or not unit or not movePos or not movePos.row or not movePos.col then
            return ZERO, ZERO, ZERO
        end

        local currentValue = self:getPositionalValue(state, unit)
        local options = opts or {}
        local newValue = ZERO

        if options.simState and options.movedUnit then
            newValue = self:getPositionalValue(options.simState, options.movedUnit)
        else
            local tempUnit = {
                row = movePos.row,
                col = movePos.col,
                name = unit.name,
                player = unit.player,
                currentHp = unit.currentHp,
                startingHp = unit.startingHp,
                atkDamage = unit.atkDamage,
                atkRange = unit.atkRange,
                move = unit.move,
                fly = unit.fly
            }
            newValue = self:getPositionalValue(state, tempUnit)
        end

        return currentValue, newValue, (newValue - currentValue)
    end

    function aiClass:scoreStrategicMove(state, unit, movePos, opts)
        if not state or not unit or not movePos then
            return {
                finalScore = ZERO,
                threshold = nil,
                threatValue = ZERO,
                improvement = ZERO
            }
        end

        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        local simState = options.simState
        local movedUnit = options.movedUnit

        local improvement = options.improvement
        if improvement == nil then
            local _, _, positionalDelta = self:getMovePositionalDelta(state, unit, movePos, {
                simState = simState,
                movedUnit = movedUnit
            })
            improvement = positionalDelta
                + valueOr(options.mobilityBonus, ZERO)
                + valueOr(options.pathOpeningBonus, ZERO)
                + valueOr(options.reachabilityBonus, ZERO)
                + valueOr(options.objectiveBonus, ZERO)
        end

        local threatState = options.threatState or simState or state
        local threatUnit = options.threatUnit or movedUnit or unit
        local threatValue = valueOr(
            options.threatValue,
            self:calculateNextTurnThreatValue(threatState, threatUnit, movePos)
        )
        local weightedThreatValue = threatValue * valueOr(options.threatWeight, self:getProfileThreatWeight())

        local repairState = options.repairState or simState or state
        local repairUnit = options.repairUnit or movedUnit or unit
        local repairBonus = valueOr(
            options.repairBonus,
            self:getRepairAdjacencyBonus(repairState, repairUnit, movePos, aiPlayer)
        )
        local supportState = options.supportState or simState or state
        local supportUnit = options.supportUnit or movedUnit or unit
        local supportCoverageBonus = valueOr(
            options.supportCoverageBonus,
            self:calculateSupportCoverageBonus(supportState, supportUnit, movePos, aiPlayer)
        )
        local tempoContext = options.tempoContext or self:getPhaseTempoContext(state)
        local wideFrontBonus = valueOr(
            options.wideFrontBonus,
            self:calculateWideFrontFlankBonus(state, unit, movePos, aiPlayer, tempoContext)
        )
        local influenceFlowBonus = valueOr(
            options.influenceFlowBonus,
            self:calculateMobileInfluenceFlowBonus(state, unit, movePos, aiPlayer, tempoContext)
        )
        local objectivePathBonus = valueOr(
            options.objectivePathBonus,
            self:calculateMultiTurnObjectivePathBonus(state, unit, movePos, aiPlayer, tempoContext, {
                simState = simState,
                movedUnit = movedUnit
            })
        )
        local rangedDuelEvasionBonus = valueOr(
            options.rangedDuelEvasionBonus,
            self:calculateRangedDuelEvasionBonus(state, unit, movePos, aiPlayer, {
                simState = simState,
                movedUnit = movedUnit
            })
        )
        local rangedStandoffBonus = ZERO
        if tempoContext and tempoContext.phase == "early" then
            supportCoverageBonus = supportCoverageBonus * 1.15
            if self:unitHasTag(supportUnit, "ranged") then
                local nearestEnemy = math.huge
                for _, enemy in ipairs(state.units or {}) do
                    if self:isAttackableEnemyUnit(enemy, aiPlayer, {excludeHub = true}) then
                        local dist = math.abs(movePos.row - enemy.row) + math.abs(movePos.col - enemy.col)
                        if dist < nearestEnemy then
                            nearestEnemy = dist
                        end
                    end
                end
                if nearestEnemy == ONE then
                    rangedStandoffBonus = rangedStandoffBonus - 90
                elseif nearestEnemy == TWO or nearestEnemy == THREE then
                    rangedStandoffBonus = rangedStandoffBonus + 35
                elseif nearestEnemy == FOUR then
                    rangedStandoffBonus = rangedStandoffBonus + 20
                end
            end
        end

        local componentWeights = options.componentWeights or self:getPositionalComponentWeights()
        local totalValue = self:getWeightedMoveStrategicScore(
            componentWeights,
            improvement,
            repairBonus,
            weightedThreatValue
        )

        local stalematePressureBonus = valueOr(
            options.stalematePressureBonus,
            self:getStalematePressureBonus(state, unit, movePos, aiPlayer)
        )

        totalValue = totalValue
            + (valueOr(options.offensiveBonus, ZERO) * valueOr(componentWeights.offensive, ONE))
            + (valueOr(options.forwardPressureBonus, ZERO) * valueOr(componentWeights.forwardPressure, ONE))
            + supportCoverageBonus
            + wideFrontBonus
            + influenceFlowBonus
            + objectivePathBonus
            + rangedDuelEvasionBonus
            + rangedStandoffBonus
            + stalematePressureBonus
            + valueOr(options.extraBonus, ZERO)
            - valueOr(options.extraPenalty, ZERO)

        if options.includeCommanderPenalty then
            totalValue = totalValue - self:calculateCommanderExposurePenalty(state, unit, movePos)
        end

        if options.includeFreeAdjacent then
            local freeAdjState = simState
            if not freeAdjState then
                freeAdjState = options.freeAdjState
            end
            if not freeAdjState then
                freeAdjState = state
            end
            totalValue = totalValue + self:getFreeAdjacentDeltaScore(state, freeAdjState, unit, movePos)
        end

        local threshold = nil
        if options.thresholdPolicy == "safe" then
            threshold = self:getSafeMoveImprovementThreshold(unit, threatValue)
        elseif options.thresholdPolicy == "risky" then
            threshold = self:getRiskyMoveImprovementThreshold(unit, threatValue)
        elseif type(options.thresholdValue) == "number" then
            threshold = options.thresholdValue
        end

        return {
            finalScore = totalValue,
            threshold = threshold,
            threatValue = threatValue,
            weightedThreatValue = weightedThreatValue,
            repairBonus = repairBonus,
            supportCoverageBonus = supportCoverageBonus,
            wideFrontBonus = wideFrontBonus,
            influenceFlowBonus = influenceFlowBonus,
            objectivePathBonus = objectivePathBonus,
            rangedDuelEvasionBonus = rangedDuelEvasionBonus,
            rangedStandoffBonus = rangedStandoffBonus,
            improvement = improvement,
            stalematePressureBonus = stalematePressureBonus
        }
    end

    function aiClass:getDeterministicEntrySortKey(entry)
        local action = entry and entry.action or nil
        local moveAction = entry and entry.moveAction or nil
        local attackAction = entry and entry.attackAction or nil

        local unitPos = {}
        local targetPos = {}

        if action and action.unit then
            unitPos = action.unit
        elseif moveAction and moveAction.unit then
            unitPos = moveAction.unit
        elseif entry and entry.movePos then
            unitPos = entry.movePos
        elseif entry and entry.cell then
            unitPos = entry.cell
        elseif entry and entry.unit then
            unitPos = entry.unit
        end

        if action and action.target then
            targetPos = action.target
        elseif attackAction and attackAction.target then
            targetPos = attackAction.target
        elseif moveAction and moveAction.target then
            targetPos = moveAction.target
        elseif entry and entry.target then
            targetPos = entry.target
        elseif entry and entry.targetPos then
            targetPos = entry.targetPos
        elseif entry and entry.cell then
            targetPos = entry.cell
        end

        local actionType = nil
        if action and action.type then
            actionType = action.type
        elseif moveAction and attackAction then
            actionType = "move_attack"
        else
            actionType = entry and (entry.actionType or entry.reason) or ""
        end

        local unitName = ""
        if entry and entry.unit and entry.unit.name then
            unitName = entry.unit.name
        elseif entry and entry.targetName then
            unitName = entry.targetName
        end

        return {
            uRow = unitPos.row or ZERO,
            uCol = unitPos.col or ZERO,
            tRow = targetPos.row or ZERO,
            tCol = targetPos.col or ZERO,
            actionType = tostring(actionType or ""),
            unitName = tostring(unitName or "")
        }
    end

    function aiClass:sortScoredEntries(entries, opts)
        local options = opts or {}
        local scoreField = options.scoreField or "value"
        local secondaryField = options.secondaryField
        local descending = options.descending ~= false
        local secondaryDescending = options.secondaryDescending
        if secondaryDescending == nil then
            secondaryDescending = descending
        end
        local scoreFn = options.scoreFn
        local secondaryFn = options.secondaryFn

        table.sort(entries, function(a, b)
            local scoreA = scoreFn and scoreFn(a) or (a and a[scoreField]) or ZERO
            local scoreB = scoreFn and scoreFn(b) or (b and b[scoreField]) or ZERO
            if scoreA ~= scoreB then
                if descending then
                    return scoreA > scoreB
                end
                return scoreA < scoreB
            end

            local secondaryA = secondaryFn and secondaryFn(a) or (secondaryField and a and a[secondaryField]) or nil
            local secondaryB = secondaryFn and secondaryFn(b) or (secondaryField and b and b[secondaryField]) or nil
            if secondaryA ~= nil and secondaryB ~= nil and secondaryA ~= secondaryB then
                if secondaryDescending then
                    return secondaryA > secondaryB
                end
                return secondaryA < secondaryB
            end

            local keyA = self:getDeterministicEntrySortKey(a)
            local keyB = self:getDeterministicEntrySortKey(b)
            if keyA.uRow ~= keyB.uRow then
                return keyA.uRow < keyB.uRow
            end
            if keyA.uCol ~= keyB.uCol then
                return keyA.uCol < keyB.uCol
            end
            if keyA.tRow ~= keyB.tRow then
                return keyA.tRow < keyB.tRow
            end
            if keyA.tCol ~= keyB.tCol then
                return keyA.tCol < keyB.tCol
            end
            if keyA.actionType ~= keyB.actionType then
                return keyA.actionType < keyB.actionType
            end
            return keyA.unitName < keyB.unitName
        end)

        return entries
    end

    function aiClass:selectUniqueEntries(entries, opts)
        local options = opts or {}
        local limit = valueOr(options.limit, ONE)
        local keyFns = options.uniqueKeyFns or {}
        local selected = {}
        local seenByKeyFn = {}

        for index = ONE, #keyFns do
            seenByKeyFn[index] = {}
        end

        for _, entry in ipairs(entries or {}) do
            local blocked = false

            for idx, keyFn in ipairs(keyFns) do
                local key = keyFn and keyFn(entry) or nil
                if key ~= nil and seenByKeyFn[idx][key] then
                    blocked = true
                    break
                end
            end

            if not blocked then
                selected[#selected + ONE] = entry

                for idx, keyFn in ipairs(keyFns) do
                    local key = keyFn and keyFn(entry) or nil
                    if key ~= nil then
                        seenByKeyFn[idx][key] = true
                    end
                end

                if #selected >= limit then
                    break
                end
            end
        end

        return selected
    end

    --[[
    SECTION: EVALUATION METRICS
    Centralizes scoring helpers in aiEvaluation for a single source of truth.
    ]]
    function aiClass:getUnitBaseValue(unit, state)
        return self.aiEvaluation.getUnitBaseValue(self, unit, state)
    end

    function aiClass:isOwnHubThreatened(state, aiPlayer)
        aiPlayer = aiPlayer or self:getFactionId()
        if not aiPlayer or not state or not state.commandHubs then
            return false
        end

        local ownHub = state.commandHubs[aiPlayer]
        if not ownHub then
            return false
        end

        -- Explicit attack on the hub this turn
        if state.attackedObjectivesThisTurn then
            for _, entry in ipairs(state.attackedObjectivesThisTurn) do
                if entry.row == ownHub.row and entry.col == ownHub.col then
                    return true
                end
            end
        end

        -- Enemy units within threat radius (Manhattan distance <= 2)
        if state.units then
            for _, unit in ipairs(state.units) do
                if unit.player and unit.player ~= aiPlayer and unit.row and unit.col then
                    local dist = math.abs(unit.row - ownHub.row) + math.abs(unit.col - ownHub.col)
                    if dist <= TWO then
                        return true
                    end

                    local attackRange = unitsInfo:getUnitAttackRange(unit, "OWN_HUB_THREAT_RANGE_CHECK")
                    if attackRange and attackRange > ONE and dist >= TWO and dist <= attackRange then
                        if self:unitHasTag(unit, "artillery") then
                            return true
                        elseif self:unitHasTag(unit, "los") and self:hasLineOfSight(state, unit, ownHub) then
                            return true
                        end
                    end
                end
            end
        end

        return false
    end

    --[[
    SECTION: POSITIONAL SCORING
    Evaluates how favorable a unit's current position is.
    - Blends adaptive pressure, hub safety, and influence map feedback.
    - Penalizes repeat positions, dead ends, and point-blank exposure for ranged units.
    ]]
    function aiClass:getPositionalValue(state, unit)
        local score = ZERO
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ZERO
        end

        if not state or not state.commandHubs then
            return ZERO
        end

        local ownHub = state.commandHubs[aiPlayer]
        if not ownHub then
            return ZERO
        end

        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        local hubThreatened = self:isOwnHubThreatened(state, aiPlayer)
        local activeReference = tostring(self:getEffectiveAiReference(state, {
            lock = false,
            context = "positional_profile"
        }) or BASE_AI_REFERENCE)

        local distToOwnHub = math.abs(unit.row - ownHub.row) + math.abs(unit.col - ownHub.col)
        local distToEnemyHub = enemyHub and math.abs(unit.row - enemyHub.row) + math.abs(unit.col - enemyHub.col) or math.huge

        -- Phase schedule grows pressure while tapering defense.
        local currentTurn = state.currentTurn or DEFAULT_TURN
        local pressureValues = self:getPressurePhaseValues(currentTurn)
        local pressureConfig = (self:getPositionalScoreConfig().PRESSURE_PHASE or {})
        local offensivePressureBonus = pressureValues.offensiveBonus
        local defensiveValueReduction = pressureValues.defensivePenalty

        if enemyHub and aiInfluence.CONFIG.POSITIONAL_WEIGHTS then
            local proximityConfig = aiInfluence.CONFIG.POSITIONAL_WEIGHTS.ENEMY_PROXIMITY or {}
            local profileWeight = proximityConfig
            if type(proximityConfig[activeReference]) == "table" then
                profileWeight = proximityConfig[activeReference]
            elseif type(proximityConfig.base) == "table" then
                profileWeight = proximityConfig.base
            end
            local proximityBase = valueOr(profileWeight.base, ZERO)
            local proximityDecay = valueOr(profileWeight.decay, ZERO)
            local proximityValue = math.max(ZERO, proximityBase - (distToEnemyHub * proximityDecay))
            local pressureScale = valueOr(pressureConfig.PRESSURE_SCALE, ZERO)
            pressureScale = valueOr(pressureScale, ONE)
            local distNorm = math.max(MIN_HP, pressureConfig.ENEMY_PROX_DIST_NORMALIZER)
            proximityValue = proximityValue + (offensivePressureBonus * pressureScale * (ONE - distToEnemyHub / distNorm))
            score = score + proximityValue
        end

        if self:unitHasTag(unit, "corvette") then
            score = score + self:getCorvettePositionalScore(state, unit)
        elseif aiInfluence.CONFIG.POSITIONAL_WEIGHTS then
            if hubThreatened then
                local weights = aiInfluence.CONFIG.POSITIONAL_WEIGHTS.OWN_PROXIMITY
                if distToOwnHub <= MIN_HP + MIN_HP + MIN_HP then
                    local defensiveBonus = math.max(ZERO, weights.base - (distToOwnHub * weights.decay))
                    defensiveBonus = math.max(ZERO, defensiveBonus - defensiveValueReduction)
                    score = score + defensiveBonus
                end
            else
                local weights = aiInfluence.CONFIG.POSITIONAL_WEIGHTS
                local centerRow = math.floor(GAME.CONSTANTS.GRID_SIZE / (MIN_HP + MIN_HP))
                local centerCol = math.floor(GAME.CONSTANTS.GRID_SIZE / (MIN_HP + MIN_HP))
                local distToCenter = math.abs(unit.row - centerRow) + math.abs(unit.col - centerCol)
                score = score + math.max(ZERO, weights.CENTER_POSITIONING - (distToCenter * weights.CENTER_DECAY))
            end
        end

        if distToOwnHub <= MIN_HP + MIN_HP then
            score = score - defensiveValueReduction * ((MIN_HP + MIN_HP + MIN_HP) - distToOwnHub)
        end

        local isDeadEnd, restrictionLevel, escapeRoutes = self:isDeadEndPosition(state, {row = unit.row, col = unit.col}, unit)
        if isDeadEnd and aiInfluence.CONFIG.POSITIONAL_WEIGHTS then
            local weights = aiInfluence.CONFIG.POSITIONAL_WEIGHTS
            local maxEscapeRoutes = weights.MAX_ESCAPE_ROUTE_COUNT or FOUR
            local deadEndPenalty = weights.DEAD_END_BASE + (weights.DEAD_END_PER_LEVEL * (restrictionLevel - ONE))
            local escapeRoutePenalty = -(maxEscapeRoutes - escapeRoutes) * (weights.DEAD_END_PER_LEVEL / TWO)
            local totalDeadEndPenalty = math.min(weights.DEAD_END_MAX, deadEndPenalty + escapeRoutePenalty)
            score = score + totalDeadEndPenalty
        end

        if self.influenceMap then
            local influenceScore, influenceValue = aiInfluence:evaluatePosition(
                self.influenceMap,
                unit.row,
                unit.col,
                activeReference
            )
            local positionalConfig = self:getPositionalScoreConfig()
            local defaultPositionalConfig = DEFAULT_SCORE_PARAMS.POSITIONAL or {}
            local influenceWeight = valueOr(
                positionalConfig.INFLUENCE_WEIGHT,
                valueOr(defaultPositionalConfig.INFLUENCE_WEIGHT, ONE)
            )
            score = score + (influenceScore * influenceWeight)
            -- Debug logging remains disabled to avoid noisy decision traces.
            -- if aiInfluence.CONFIG.DEBUG_ENABLED and influenceValue and math.abs(influenceValue) > 10 then
            --     self:logDecision("Influence", string.format("%s at (%d,%d): influence=%.1f score=%+.1f",
            --         unit.name or "unknown", unit.row, unit.col, influenceValue, influenceScore))
            -- end
        end

        if self.positionHistory and unit.name and aiInfluence.CONFIG.POSITIONAL_WEIGHTS then
            local weights = aiInfluence.CONFIG.POSITIONAL_WEIGHTS
            local posKey = string.format("%s_%d_%d", unit.name, unit.row, unit.col)
            local history = self.positionHistory[posKey]
            if history then
                local turnsSince = currentTurn - history.turn
                if turnsSince >= MIN_HP and turnsSince <= weights.HISTORY_DECAY_TURNS then
                    local decayFactor = ONE - (turnsSince / weights.HISTORY_DECAY_TURNS)
                    local historyPenalty = weights.HISTORY_RECENT * decayFactor
                    score = score + historyPenalty
                end
            end
        end

        if not unitsInfo:canAttackAdjacent(unit.name) then
            local adjacentThreats = ZERO
            for _, enemy in ipairs(state.units or {}) do
                if self:isAttackableEnemyUnit(enemy, aiPlayer) then
                    local dist = math.abs(enemy.row - unit.row) + math.abs(enemy.col - unit.col)
                    if dist == MIN_HP then
                        adjacentThreats = adjacentThreats + MIN_HP
                    end
                end
            end

            if adjacentThreats > ZERO then
                local scoreConfig = self:getScoreConfig()
                local penaltyPerEnemy = scoreConfig.POSITIONAL.RANGED_ADJACENT_THREAT_PENALTY
                score = score - (penaltyPerEnemy * adjacentThreats)
            end
        end

        return score
    end

end

return M
