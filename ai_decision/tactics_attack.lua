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
    function aiClass:buildProjectedThreatUnit(unit, row, col)
        if not unit or not row or not col then
            return nil
        end

        return {
            row = row,
            col = col,
            name = unit.name,
            player = unit.player,
            currentHp = unit.currentHp or unit.startingHp or MIN_HP,
            startingHp = unit.startingHp or unit.currentHp or MIN_HP,
            atkDamage = unit.atkDamage,
            move = unit.move,
            atkRange = unit.atkRange,
            fly = unit.fly
        }
    end

    function aiClass:collectProjectedThreatTargets(state, attacker, aiPlayer, opts)
        if not state or not attacker or not aiPlayer then
            return {}, ZERO
        end

        local options = opts or {}
        local requireTargetCoordinates = options.requireTargetCoordinates == true
        local requireCurrentHp = options.requireCurrentHp == true
        local processedTargets = options.processedTargets
        local markProcessed = options.markProcessed == true

        local entries = {}
        local attackCells = self:getAttackCellsForUnitAtPosition(state, attacker, attacker.row, attacker.col) or {}
        local attackCellCount = #attackCells

        for _, attackCell in ipairs(attackCells) do
            local target = self:getUnitAtPosition(state, attackCell.row, attackCell.col)
            if target and target.player ~= aiPlayer then
                if requireTargetCoordinates and (not target.row or not target.col) then
                    goto continue_collect_target
                end
                if requireCurrentHp and target.currentHp == nil then
                    goto continue_collect_target
                end

                local targetKey = nil
                if target.row and target.col then
                    targetKey = target.row .. "," .. target.col
                end
                if processedTargets and targetKey and processedTargets[targetKey] then
                    goto continue_collect_target
                end

                local damage = unitsInfo:calculateAttackDamage(attacker, target)
                if damage and damage > ZERO then
                    if processedTargets and targetKey and markProcessed then
                        processedTargets[targetKey] = true
                    end

                    entries[#entries + ONE] = {
                        key = targetKey,
                        target = target,
                        damage = damage,
                        targetValue = self:getUnitBaseValue(target, state),
                        targetHp = target.currentHp or target.startingHp or MIN_HP,
                        isHub = self:unitHasTag(target, "hub")
                    }
                end
            end

            ::continue_collect_target::
        end

        return entries, attackCellCount
    end

    function aiClass:evaluateThreatFromProjectedPosition(state, attacker, aiPlayer, scoreWeights, processedTargets, opts)
        if not state or not attacker or not aiPlayer then
            return ZERO, ZERO
        end

        local weights = scoreWeights or {}
        local valueScale = valueOr(weights.valueScale, ZERO)
        local damageScale = valueOr(weights.damageScale, ZERO)
        local killBonus = valueOr(weights.killBonus, ZERO)
        local hubBonus = valueOr(weights.hubBonus, ZERO)

        local threatScore = ZERO
        local targets, attackCellCount = self:collectProjectedThreatTargets(state, attacker, aiPlayer, {
            requireTargetCoordinates = opts and opts.requireTargetCoordinates,
            requireCurrentHp = opts and opts.requireCurrentHp,
            processedTargets = processedTargets,
            markProcessed = true
        })

        for _, entry in ipairs(targets) do
            threatScore = threatScore
                + (entry.targetValue * valueScale)
                + (entry.damage * damageScale)

            if killBonus ~= ZERO and entry.damage >= entry.targetHp then
                threatScore = threatScore + killBonus
            end

            if hubBonus ~= ZERO and entry.isHub then
                threatScore = threatScore + hubBonus
            end
        end

        return threatScore, attackCellCount
    end

    -- Calculate projected multi-turn threat value from a destination (bounded lookahead).
    function aiClass:calculateNextTurnThreatValue(state, unit, movePos)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ZERO
        end
        local threatValue = ZERO
        local killRiskConfig = self:getKillRiskScoreConfig()
        local projectionConfig = killRiskConfig.THREAT_PROJECTION or {}
        local defaultProjectionConfig = ((DEFAULT_SCORE_PARAMS.KILL_RISK or {}).THREAT_PROJECTION or {})

        -- Guard against missing state, unit, or destination data.
        if not state or not unit or not movePos then
            return ZERO
        end

        if not movePos.row or not movePos.col or not unit.name or not unit.player then
            return ZERO
        end

        local lookaheadTurns = math.max(
            ONE,
            valueOr(projectionConfig.LOOKAHEAD_TURNS, valueOr(defaultProjectionConfig.LOOKAHEAD_TURNS, ONE))
        )
        local frontierMax = math.max(
            ONE,
            valueOr(projectionConfig.FRONTIER_MAX, valueOr(defaultProjectionConfig.FRONTIER_MAX, 24))
        )
        local turnScaleConfig = projectionConfig.TURN_SCALE or defaultProjectionConfig.TURN_SCALE or {}
        local function getTurnScale(turnIndex)
            local explicit = turnScaleConfig[turnIndex]
            if explicit ~= nil then
                return explicit
            end
            if turnIndex <= ONE then
                return ONE
            elseif turnIndex == TWO then
                return 0.65
            end
            return 0.4
        end

        local projectionState, projectionUnit = self:simulateUnitMoveState(state, unit, movePos, {validate = true})
        if not projectionUnit then
            projectionState = state
            projectionUnit = self:getUnitAtPosition(state, movePos.row, movePos.col)
        end
        if not projectionUnit then
            return ZERO
        end

        projectionUnit.hasActed = false
        projectionUnit.hasMoved = false

        local opponentPlayer = self:getOpponentPlayer(aiPlayer)
        local enemyHub = projectionState.commandHubs and projectionState.commandHubs[opponentPlayer] or nil

        local targetBestScores = {}
        local forkThreatCells = ZERO

        local function evaluateProjectedEntries(attackerState, attackerUnit, weights, turnIndex)
            if not attackerState or not attackerUnit then
                return ZERO
            end

            local scale = getTurnScale(turnIndex)
            local turnThreatCells = ZERO
            local targets, attackCellCount = self:collectProjectedThreatTargets(attackerState, attackerUnit, aiPlayer, {
                requireTargetCoordinates = true,
                requireCurrentHp = false,
                markProcessed = false
            })
            turnThreatCells = turnThreatCells + attackCellCount

            local valueScale = valueOr(weights.valueScale, ZERO)
            local damageScale = valueOr(weights.damageScale, ZERO)
            local killBonus = valueOr(weights.killBonus, ZERO)
            local hubBonus = valueOr(weights.hubBonus, ZERO)

            for _, entry in ipairs(targets) do
                local score = (entry.targetValue * valueScale) + (entry.damage * damageScale)
                if killBonus ~= ZERO and entry.damage >= entry.targetHp then
                    score = score + killBonus
                end
                if hubBonus ~= ZERO and entry.isHub then
                    score = score + hubBonus
                end

                local scaledScore = score * scale
                local key = entry.key or (entry.target and (entry.target.row .. "," .. entry.target.col))
                if key then
                    local existing = targetBestScores[key]
                    if (not existing)
                        or (turnIndex < existing.turn)
                        or (turnIndex == existing.turn and scaledScore > existing.score) then
                        targetBestScores[key] = {
                            turn = turnIndex,
                            score = scaledScore
                        }
                    end
                end
            end

            return turnThreatCells
        end

        local frontier = {{
            state = projectionState,
            unit = projectionUnit
        }}

        for turnIndex = ONE, lookaheadTurns do
            if #frontier == ZERO then
                break
            end

            local nextFrontierByPos = {}

            local function upsertFrontierNode(nodeState, nodeUnit)
                if not nodeState or not nodeUnit then
                    return
                end
                local key = string.format("%d,%d", nodeUnit.row or ZERO, nodeUnit.col or ZERO)
                local distToEnemyHub = math.huge
                if enemyHub and nodeUnit.row and nodeUnit.col then
                    distToEnemyHub = math.abs(nodeUnit.row - enemyHub.row) + math.abs(nodeUnit.col - enemyHub.col)
                end

                local existing = nextFrontierByPos[key]
                if (not existing) or distToEnemyHub < (existing.distToEnemyHub or math.huge) then
                    nextFrontierByPos[key] = {
                        state = nodeState,
                        unit = nodeUnit,
                        distToEnemyHub = distToEnemyHub
                    }
                end
            end

            for _, node in ipairs(frontier) do
                local nodeState = node.state
                local nodeUnit = node.unit
                if nodeState and nodeUnit then
                    local directCellCount = evaluateProjectedEntries(
                        nodeState,
                        nodeUnit,
                        {
                            valueScale = valueOr(projectionConfig.DIRECT_VALUE_SCALE, defaultProjectionConfig.DIRECT_VALUE_SCALE),
                            damageScale = valueOr(projectionConfig.DIRECT_DAMAGE_SCALE, defaultProjectionConfig.DIRECT_DAMAGE_SCALE),
                            killBonus = valueOr(projectionConfig.DIRECT_KILL_BONUS, defaultProjectionConfig.DIRECT_KILL_BONUS),
                            hubBonus = valueOr(projectionConfig.DIRECT_HUB_BONUS, defaultProjectionConfig.DIRECT_HUB_BONUS)
                        },
                        turnIndex
                    )
                    if turnIndex == ONE then
                        forkThreatCells = forkThreatCells + directCellCount
                    end

                    local moveCells = self:getValidMoveCells(nodeState, nodeUnit.row, nodeUnit.col) or {}
                    for _, moveCell in ipairs(moveCells) do
                        local simState, simUnit = self:simulateUnitMoveState(nodeState, nodeUnit, moveCell, {validate = true})
                        if simUnit then
                            simUnit.hasActed = false
                            simUnit.hasMoved = false

                            local moveCellCount = evaluateProjectedEntries(
                                simState,
                                simUnit,
                                {
                                    valueScale = valueOr(projectionConfig.MOVE_VALUE_SCALE, defaultProjectionConfig.MOVE_VALUE_SCALE),
                                    damageScale = valueOr(projectionConfig.MOVE_DAMAGE_SCALE, defaultProjectionConfig.MOVE_DAMAGE_SCALE),
                                    killBonus = valueOr(projectionConfig.MOVE_KILL_BONUS, defaultProjectionConfig.MOVE_KILL_BONUS),
                                    hubBonus = valueOr(projectionConfig.MOVE_HUB_BONUS, defaultProjectionConfig.MOVE_HUB_BONUS)
                                },
                                turnIndex
                            )
                            if turnIndex == ONE then
                                forkThreatCells = forkThreatCells + moveCellCount
                            end

                            if turnIndex < lookaheadTurns then
                                upsertFrontierNode(simState, simUnit)
                            end
                        end
                    end

                    if turnIndex < lookaheadTurns then
                        upsertFrontierNode(nodeState, nodeUnit)
                    end
                end
            end

            frontier = {}
            for _, nextNode in pairs(nextFrontierByPos) do
                frontier[#frontier + ONE] = nextNode
            end
            table.sort(frontier, function(a, b)
                local aDist = a.distToEnemyHub or math.huge
                local bDist = b.distToEnemyHub or math.huge
                if aDist == bDist then
                    local aKey = string.format("%d,%d", a.unit and a.unit.row or ZERO, a.unit and a.unit.col or ZERO)
                    local bKey = string.format("%d,%d", b.unit and b.unit.row or ZERO, b.unit and b.unit.col or ZERO)
                    return aKey < bKey
                end
                return aDist < bDist
            end)
            while #frontier > frontierMax do
                table.remove(frontier)
            end
        end

        for _, entry in pairs(targetBestScores) do
            threatValue = threatValue + (entry.score or ZERO)
        end

        -- Bonus for creating multiple threats (fork tactics)
        if forkThreatCells >= valueOr(projectionConfig.FORK_MIN_ATTACK_CELLS, defaultProjectionConfig.FORK_MIN_ATTACK_CELLS) then
            threatValue = threatValue + (forkThreatCells * valueOr(projectionConfig.FORK_BONUS_PER_CELL, defaultProjectionConfig.FORK_BONUS_PER_CELL))  -- Multi-option fork bonus
        end

        return threatValue
    end

    -- Calculate path-opening bonus - rewards moves that unblock valuable allies
    function aiClass:calculatePathOpeningBonus(state, unit, movePos)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state or not unit or not movePos then
            return ZERO
        end
    
        local bonus = ZERO
        local enemyHub = state.commandHubs and state.commandHubs[self:getOpponentPlayer(aiPlayer)]
        if not enemyHub then
            return ZERO
        end
    
        -- Check if any ally is blocked by this unit's current position
        for _, ally in ipairs(state.units) do
            if self:isUnitEligibleForAction(ally, aiPlayer, nil, {
                requireNotActed = false,
                requireNotMoved = false,
                disallowRock = true
            }) then
                if not (ally.row == unit.row and ally.col == unit.col) then
                    -- Calculate ally's distance to enemy hub
                    local allyDistToEnemy = math.abs(ally.row - enemyHub.row) + math.abs(ally.col - enemyHub.col)

                    -- Check if this unit is blocking the ally's path toward enemy
                    local unitDistToEnemy = math.abs(unit.row - enemyHub.row) + math.abs(unit.col - enemyHub.col)

                    -- If this unit is closer to enemy than ally, it might be blocking
                    if unitDistToEnemy < allyDistToEnemy then
                        -- Check if unit is adjacent to ally (potential blocker)
                        local distToAlly = math.abs(unit.row - ally.row) + math.abs(unit.col - ally.col)
                        if distToAlly == ONE then
                            -- Check if moving away opens a better path for ally
                            local newDistToAlly = math.abs(movePos.row - ally.row) + math.abs(movePos.col - ally.col)

                            if newDistToAlly > distToAlly then
                                -- Moving away from ally - potentially opening path
                                local allyValue = self:getUnitBaseValue(ally, state)
                                local pathOpeningConfig = self:getPathOpeningConfig()
                                local defaultPathOpeningConfig = DEFAULT_SCORE_PARAMS.PATH_OPENING or {}
                                local highValueBonus = valueOr(pathOpeningConfig.HIGH_VALUE_BONUS, defaultPathOpeningConfig.HIGH_VALUE_BONUS)
                                local midValueBonus = valueOr(pathOpeningConfig.MID_VALUE_BONUS, defaultPathOpeningConfig.MID_VALUE_BONUS)
                                local baseBonus = valueOr(pathOpeningConfig.BASE_BONUS, defaultPathOpeningConfig.BASE_BONUS)

                                if self:unitHasTag(ally, "high_value") then
                                    bonus = bonus + highValueBonus
                                elseif self:unitHasTag(ally, "tank") then
                                    bonus = bonus + midValueBonus
                                else
                                    bonus = bonus + baseBonus
                                end
                            end
                        end
                    end
                end
            end
        end
    
        return bonus
    end

    -- Calculate next-turn reachability bonus - rewards moves toward currently unreachable valuable targets
    function aiClass:calculateNextTurnReachabilityBonus(state, unit, movePos)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state or not unit or not movePos then
            return ZERO
        end
    
        local bonus = ZERO
        local reachabilityConfig = (self:getKillRiskScoreConfig().REACHABILITY or {})
        local defaultReachabilityConfig = ((DEFAULT_SCORE_PARAMS.KILL_RISK or {}).REACHABILITY or {})
    
        local tempUnit = self:buildProjectedThreatUnit(unit, movePos.row, movePos.col)
        if not tempUnit then
            return ZERO
        end
    
        local currentUnit = self:buildProjectedThreatUnit(unit, unit.row, unit.col)
        local currentTargets = {}
        if currentUnit then
            local currentEntries = self:collectProjectedThreatTargets(state, currentUnit, aiPlayer, {
                requireTargetCoordinates = true
            })
            for _, entry in ipairs(currentEntries) do
                if entry.key then
                    currentTargets[entry.key] = true
                end
            end
        end
    
        -- Get potential next-turn attack range from new position
        local nextTurnMoves = self:getValidMoveCells(state, movePos.row, movePos.col)
        if not nextTurnMoves then
            return ZERO
        end
    
        local newReachableTargets = {}
    
        for _, nextMove in ipairs(nextTurnMoves) do
            if nextMove and nextMove.row and nextMove.col then
                local nextTurnUnit = self:buildProjectedThreatUnit(unit, nextMove.row, nextMove.col)
                if nextTurnUnit then
                    local nextEntries = self:collectProjectedThreatTargets(state, nextTurnUnit, aiPlayer, {
                        requireTargetCoordinates = true
                    })
                    for _, entry in ipairs(nextEntries) do
                        local targetKey = entry.key
                        -- Check if this target is NOT currently reachable
                        if targetKey and not currentTargets[targetKey] then
                            newReachableTargets[targetKey] = entry
                        end
                    end
                end
            end
        end
    
        -- Calculate bonus for newly reachable high-value targets
        for _, entry in pairs(newReachableTargets) do
            local target = entry.target
            local targetValue = entry.targetValue
            local damage = entry.damage
        
            if damage and damage > ZERO then
                -- Base bonus for making target reachable
                local reachBonus = targetValue * valueOr(reachabilityConfig.VALUE_SCALE, defaultReachabilityConfig.VALUE_SCALE)
                    + damage * valueOr(reachabilityConfig.DAMAGE_SCALE, defaultReachabilityConfig.DAMAGE_SCALE)
            
                -- Extra bonus for high-priority targets
                if self:unitHasTag(target, "hub") then
                    reachBonus = reachBonus + valueOr(reachabilityConfig.HUB_BONUS, defaultReachabilityConfig.HUB_BONUS)
                elseif self:unitHasTag(target, "high_value") then
                    reachBonus = reachBonus + valueOr(reachabilityConfig.HIGH_VALUE_BONUS, defaultReachabilityConfig.HIGH_VALUE_BONUS)
                elseif self:unitHasTag(target, "tank") then
                    reachBonus = reachBonus + valueOr(reachabilityConfig.TANK_BONUS, defaultReachabilityConfig.TANK_BONUS)
                end
            
                -- Extra bonus if target can be killed next turn
                local targetHp = entry.targetHp
                if damage >= targetHp then
                    reachBonus = reachBonus + valueOr(reachabilityConfig.KILL_BONUS, defaultReachabilityConfig.KILL_BONUS)
                end
            
                bonus = bonus + reachBonus
            end
        end
    
        -- BALANCED: Cap reachability bonus to prevent it from exceeding attack value
        -- This ensures positioning moves don't become more valuable than actual attacks
        bonus = math.min(valueOr(reachabilityConfig.MAX_TOTAL_BONUS, defaultReachabilityConfig.MAX_TOTAL_BONUS), bonus)
    
        return bonus
    end
    function aiClass:collectKillAttackCandidates(state, usedUnits, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local moveThenAttack = options.moveThenAttack == true
        local requireAttackSafe = options.requireAttackSafe == true
        local allowBeneficialSuicide = options.allowBeneficialSuicide == true
        local includeSafetyScore = options.includeSafetyScore == true
        local includeTargetHp = options.includeTargetHp == true
        local allowHealerAttacks = options.allowHealerAttacks
        local checkFriendlyFire = options.checkFriendlyFire == true
        local minDamage = valueOr(options.minDamage, ZERO)
        local scoreField = options.scoreField or "value"
        local scoreFn = options.scoreFn
        local targetHpFallbackTag = options.targetHpFallbackTag or "KILL_TARGET_HP"
        local entryMode = moveThenAttack and "move" or "direct"
        local candidates = {}

        local function resolveDamage(attacker, target)
            return self:calculateDamage(attacker, target) or ZERO
        end

        local function resolveTargetHp(target, hintedHp)
            return hintedHp
                or target.currentHp
                or target.startingHp
                or unitsInfo:getUnitHP(target, targetHpFallbackTag)
                or MIN_HP
        end

        local function resolveScore(unit, target, damage, movePos)
            local score = ZERO
            if scoreFn then
                score = scoreFn(unit, target, damage, movePos) or ZERO
            else
                score = self:getUnitBaseValue(target, state) or ZERO
            end
            local attackKind = movePos and "move_attack" or "direct_attack"
            local attackPos = movePos or {row = unit.row, col = unit.col}
            score = score + self:getThreatReleaseOffenseBonus(state, target, attackPos, attackKind)
            return score
        end

        local entrySources = self:collectAttackTargetEntries(state, usedUnits, {
            mode = entryMode,
            aiPlayer = aiPlayer,
            allowHealerAttacks = allowHealerAttacks,
            requireSafeMove = false,
            checkVulnerableMove = false,
            enforceHealerOrbit = false,
            includeFriendlyFireCheck = checkFriendlyFire,
            requirePositiveDamage = false,
            minDamage = ZERO,
            unitEligibility = {}
        })

        for _, base in ipairs(entrySources) do
            local unit = base.unit
            local target = base.target
            if unit and target then
                local damage = valueOr(base.damage, resolveDamage(unit, target))
                local targetHp = resolveTargetHp(target, base.targetHp)
                local movePos = moveThenAttack and base.moveCell or nil

                if damage >= minDamage and damage >= targetHp then
                    local attackerForSafety = unit
                    if moveThenAttack and movePos then
                        attackerForSafety = self:buildProjectedThreatUnit(unit, movePos.row, movePos.col) or unit
                    end

                    local attackAllowed = true
                    if requireAttackSafe or allowBeneficialSuicide then
                        attackAllowed = self:isAttackSafe(state, attackerForSafety, target, {
                            allowBeneficialSuicide = allowBeneficialSuicide
                        })
                    end

                    if attackAllowed then
                        local entry = {
                            unit = unit,
                            targetName = target.name,
                            damage = damage
                        }

                        if moveThenAttack then
                            entry.moveAction = base.moveAction
                            entry.attackAction = base.attackAction
                            entry.movePosition = {row = movePos.row, col = movePos.col}
                        else
                            entry.action = base.action
                        end

                        entry[scoreField] = resolveScore(unit, target, damage, movePos)

                        if includeTargetHp then
                            entry.targetHp = targetHp
                        end

                        if includeSafetyScore and movePos then
                            entry.safetyScore = self:calculatePositionSafetyScore(state, unit, movePos)
                        end

                        candidates[#candidates + ONE] = entry
                    end
                end
            end
        end

        self:sortScoredEntries(candidates, {
            scoreField = scoreField,
            secondaryField = includeSafetyScore and "safetyScore" or nil,
            descending = true
        })

        return candidates
    end

    -- Obvious action 01: One Action Safe kill attacks (Check safety, adjacent and move+attack and ranged check)
    function aiClass:findSafeKillAttacks(state, usedUnits)
        return self:collectKillAttackCandidates(state, usedUnits, {
            allowHealerAttacks = self:shouldHealerBeOffensive(state),
            requireAttackSafe = true,
            checkFriendlyFire = true
        })
    end

    -- Obvious action 07: One Action kill attacks
    function aiClass:findNotSoSafeKillAttacks(state, usedUnits)
        return self:collectKillAttackCandidates(state, usedUnits, {
            allowHealerAttacks = self:shouldHealerBeOffensive(state),
            requireAttackSafe = false,
            allowBeneficialSuicide = true,
            checkFriendlyFire = true
        })
    end

    --  Obvious action 02: 2 Actions Move+Attack Safe kill (Check only adjacent safe cells)
    function aiClass:findSafeMoveAttackKills(state, usedUnits)
        return self:collectKillAttackCandidates(state, usedUnits, {
            moveThenAttack = true,
            allowHealerAttacks = self:shouldHealerBeOffensive(state),
            requireAttackSafe = true,
            includeSafetyScore = true
        })
    end

    --  Obvious action 08: 2 Actions Move+Attack NOT safe kill (No suicide check)
    function aiClass:findNotSoSafeMoveAttackKills(state, usedUnits)
        return self:collectKillAttackCandidates(state, usedUnits, {
            moveThenAttack = true,
            requireAttackSafe = false,
            allowBeneficialSuicide = true,
            includeSafetyScore = false
        })
    end

    function aiClass:collectAttackersAgainstTarget(state, usedUnits, aiPlayer, target, opts)
        local options = opts or {}
        if not aiPlayer or not state or not target or not target.row or not target.col then
            return {}
        end

        local requirePositiveDamage = options.requirePositiveDamage ~= false
        local eligibilityOptions = options.eligibilityOptions or {}
        local attackers = {}

        for _, unit in ipairs(state.units or {}) do
            local unitEligibility = {}
            for key, value in pairs(eligibilityOptions) do
                unitEligibility[key] = value
            end
            if options.allowHealerAttacks ~= nil then
                unitEligibility.allowHealerAttacks = options.allowHealerAttacks
            end

            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits, unitEligibility) then
                local canHit = self:canUnitDamageTargetFromPosition(
                    state,
                    unit,
                    target,
                    unit.row,
                    unit.col,
                    {requirePositiveDamage = requirePositiveDamage}
                )
                if canHit then
                    local damage = self:calculateDamage(unit, target)
                    attackers[#attackers + ONE] = {
                        unit = unit,
                        damage = damage
                    }
                end
            end
        end

        return attackers
    end

    function aiClass:findBestTwoAttackKillCombo(state, target, attackers, targetHp, opts)
        local options = opts or {}
        if not state or not target or not attackers or #attackers < TWO then
            return nil
        end

        local requiredTargetHp = targetHp or target.currentHp or target.startingHp or target.hp or MIN_HP
        local requireSecondNotSolo = options.requireSecondNotSolo == true
        local requireFinisherSafe = options.requireFinisherSafe == true
        local scoreFn = options.scoreFn
        local bestCombo = nil

        local function isBetterCandidate(candidate, incumbent)
            if not incumbent then
                return true
            end
            if (candidate.value or ZERO) ~= (incumbent.value or ZERO) then
                return (candidate.value or ZERO) > (incumbent.value or ZERO)
            end
            if (candidate.totalDamage or ZERO) ~= (incumbent.totalDamage or ZERO) then
                return (candidate.totalDamage or ZERO) > (incumbent.totalDamage or ZERO)
            end
            local candDamager = candidate.damageAction and candidate.damageAction.unit or {}
            local incDamager = incumbent.damageAction and incumbent.damageAction.unit or {}
            if (candDamager.row or ZERO) ~= (incDamager.row or ZERO) then
                return (candDamager.row or ZERO) < (incDamager.row or ZERO)
            end
            if (candDamager.col or ZERO) ~= (incDamager.col or ZERO) then
                return (candDamager.col or ZERO) < (incDamager.col or ZERO)
            end
            local candKiller = candidate.killAction and candidate.killAction.unit or {}
            local incKiller = incumbent.killAction and incumbent.killAction.unit or {}
            if (candKiller.row or ZERO) ~= (incKiller.row or ZERO) then
                return (candKiller.row or ZERO) < (incKiller.row or ZERO)
            end
            return (candKiller.col or ZERO) < (incKiller.col or ZERO)
        end

        for i = ONE, #attackers do
            for j = ONE, #attackers do
                if i ~= j then
                    local damager = attackers[i]
                    local killer = attackers[j]
                    local damagerDamage = damager.damage or ZERO
                    local killerDamage = killer.damage or ZERO
                    local totalDamage = damagerDamage + killerDamage

                    if totalDamage >= requiredTargetHp then
                        local canUseSecondAttack = (not requireSecondNotSolo) or (killerDamage < requiredTargetHp)
                        if canUseSecondAttack and damager.unit and killer.unit then
                            local isSafeKillAttack = true
                            if requireFinisherSafe then
                                isSafeKillAttack = self:isAttackSafe(state, killer.unit, target)
                            end

                            if isSafeKillAttack then
                                local score = scoreFn and scoreFn(damager, killer, totalDamage, target) or totalDamage
                                local candidate = {
                                    damager = damager.unit,
                                    killer = killer.unit,
                                    target = target,
                                    damageAction = {
                                        type = "attack",
                                        unit = {row = damager.unit.row, col = damager.unit.col},
                                        target = {row = target.row, col = target.col}
                                    },
                                    killAction = {
                                        type = "attack",
                                        unit = {row = killer.unit.row, col = killer.unit.col},
                                        target = {row = target.row, col = target.col}
                                    },
                                    totalDamage = totalDamage,
                                    value = score or ZERO
                                }

                                if isBetterCandidate(candidate, bestCombo) then
                                    bestCombo = candidate
                                end
                            end
                        end
                    end
                end
            end
        end

        return bestCombo
    end

    function aiClass:findWinningMoveAttackCombo(state, usedUnits, aiPlayer, target, targetHp, opts)
        local options = opts or {}
        if not state or not target or not aiPlayer then
            return nil
        end

        local requiredTargetHp = targetHp or target.currentHp or target.startingHp or target.hp or MIN_HP
        local singleUnitMode = options.singleUnitMode == true
        local requireShooterRanged = options.requireShooterRanged == true
        local useSimulatedStateForShooter = options.useSimulatedStateForShooter == true
        local scoreFn = options.scoreFn
        local candidates = {}

        for _, mover in ipairs(state.units or {}) do
            if self:isUnitEligibleForAction(mover, aiPlayer, usedUnits, {requireNotMoved = true}) then
                local moveCells = self:getValidMoveCells(state, mover.row, mover.col) or {}

                for _, moveCell in ipairs(moveCells) do
                    if singleUnitMode then
                        local moverAtPosition = self:buildProjectedThreatUnit(mover, moveCell.row, moveCell.col) or mover
                        local canHit = self:canUnitDamageTargetFromPosition(
                            state,
                            moverAtPosition,
                            target,
                            moveCell.row,
                            moveCell.col,
                            {requirePositiveDamage = true}
                        )
                        if canHit then
                            local damage = unitsInfo:calculateAttackDamage(moverAtPosition, target) or ZERO
                            if damage >= requiredTargetHp then
                                candidates[#candidates + ONE] = {
                                    mover = mover,
                                    shooter = mover,
                                    damage = damage,
                                    moveAction = {
                                        type = "move",
                                        unit = {row = mover.row, col = mover.col},
                                        target = {row = moveCell.row, col = moveCell.col}
                                    },
                                    attackAction = {
                                        type = "attack",
                                        unit = {row = moveCell.row, col = moveCell.col},
                                        target = {row = target.row, col = target.col}
                                    },
                                    value = scoreFn and scoreFn(mover, mover, damage, moveCell) or damage
                                }
                            end
                        end
                    else
                        local evalState = state
                        if useSimulatedStateForShooter then
                            evalState = select(ONE, self:simulateUnitMoveState(state, mover, moveCell)) or state
                        end

                        for _, shooter in ipairs(state.units or {}) do
                            if shooter ~= mover
                                and self:isUnitEligibleForAction(shooter, aiPlayer, usedUnits)
                                and ((not requireShooterRanged) or self:unitHasTag(shooter, "ranged")) then
                                local shooterRef = shooter
                                if evalState ~= state then
                                    shooterRef = self:getUnitAtPosition(evalState, shooter.row, shooter.col) or shooter
                                end

                                local canHit = self:canUnitDamageTargetFromPosition(
                                    evalState,
                                    shooterRef,
                                    target,
                                    shooterRef.row,
                                    shooterRef.col,
                                    {requirePositiveDamage = true}
                                )
                                if canHit then
                                    local damage = unitsInfo:calculateAttackDamage(shooterRef, target) or ZERO
                                    if damage >= requiredTargetHp then
                                        candidates[#candidates + ONE] = {
                                            mover = mover,
                                            shooter = shooter,
                                            damage = damage,
                                            moveAction = {
                                                type = "move",
                                                unit = {row = mover.row, col = mover.col},
                                                target = {row = moveCell.row, col = moveCell.col}
                                            },
                                            attackAction = {
                                                type = "attack",
                                                unit = {row = shooter.row, col = shooter.col},
                                                target = {row = target.row, col = target.col}
                                            },
                                            value = scoreFn and scoreFn(mover, shooter, damage, moveCell) or damage
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        self:sortScoredEntries(candidates, {
            scoreField = "value",
            secondaryField = "damage",
            descending = true
        })

        return candidates[ONE]
    end

    function aiClass:findDirectLethalAttackOnTarget(state, usedUnits, aiPlayer, target, opts)
        local options = opts or {}
        if not state or not target or not aiPlayer then
            return nil
        end

        local requiredTargetHp = options.targetHp or target.currentHp or target.startingHp or target.hp or MIN_HP
        local scoreFn = options.scoreFn
        local eligibilityOptions = options.eligibilityOptions or {}
        local candidates = {}

        for _, unit in ipairs(state.units or {}) do
            local unitEligibility = {}
            for key, value in pairs(eligibilityOptions) do
                unitEligibility[key] = value
            end

            if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits, unitEligibility) then
                local canHit = self:canUnitDamageTargetFromPosition(
                    state,
                    unit,
                    target,
                    unit.row,
                    unit.col,
                    {requirePositiveDamage = true}
                )
                if canHit then
                    local damage = unitsInfo:calculateAttackDamage(unit, target) or ZERO
                    if damage >= requiredTargetHp then
                        candidates[#candidates + ONE] = {
                            unit = unit,
                            action = {
                                type = "attack",
                                unit = {row = unit.row, col = unit.col},
                                target = {row = target.row, col = target.col}
                            },
                            damage = damage,
                            targetHp = requiredTargetHp,
                            targetName = target.name,
                            value = scoreFn and scoreFn(unit, damage, target, requiredTargetHp) or damage
                        }
                    end
                end
            end
        end

        self:sortScoredEntries(candidates, {
            scoreField = "value",
            secondaryField = "damage",
            descending = true
        })

        return candidates[ONE]
    end

    -- Obvious action 03: Two units attack same enemy - first damages, second kills (Check only adjacent safe cells)
    function aiClass:findTwoUnitKillCombinations(state, usedUnits, safetyCheck)
        safetyCheck = safetyCheck or false
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end
        local killCombos = {}


        -- Find all enemy units that could potentially be killed with 2 attacks
        for _, target in ipairs(state.units) do
            if self:isAttackableEnemyUnit(target, aiPlayer) then
                local targetHp = target.currentHp or target.hp

                -- Find all AI units that can attack this target
                local allowHealerAttacks = self:shouldHealerBeOffensive(state)
                local attackers = self:collectAttackersAgainstTarget(state, usedUnits, aiPlayer, target, {
                    requirePositiveDamage = true,
                    allowHealerAttacks = allowHealerAttacks
                })

                if #attackers >= TWO then
                    local targetValue = self:getUnitBaseValue(target, state)
                    local bestComboForTarget = self:findBestTwoAttackKillCombo(state, target, attackers, targetHp, {
                        requireSecondNotSolo = true,
                        requireFinisherSafe = safetyCheck,
                        scoreFn = function()
                            local offenseBonus = self:getThreatReleaseOffenseBonus(
                                state,
                                target,
                                {row = target.row, col = target.col},
                                "direct_attack"
                            )
                            return targetValue + offenseBonus
                        end
                    })
                    if bestComboForTarget then
                        table.insert(killCombos, bestComboForTarget)
                    end
                end
            end
        end

        -- Sort by value (highest first)
        self:sortScoredEntries(killCombos, {
            scoreField = "value",
            descending = true
        })
        return killCombos
    end

    function aiClass:getBestLineOfSightClearingMove(state, blockingUnit, corvette, target)
        if not state or not blockingUnit or not corvette or not target then
            return nil
        end

        local moveCandidates = {}
        local moveCells = self:getValidMoveCells(state, blockingUnit.row, blockingUnit.col) or {}
        local currentValue = self:getPositionalValue(state, blockingUnit)

        for _, moveCell in ipairs(moveCells) do
            local targetPos = {row = moveCell.row, col = moveCell.col}
            if self:isMoveSafe(state, blockingUnit, targetPos, {checkVulnerable = true}) then
                local tempState = self:deepCopyState(state)
                local tempUnit = self:getUnitAtPosition(tempState, blockingUnit.row, blockingUnit.col)
                if tempUnit then
                    tempUnit.row = moveCell.row
                    tempUnit.col = moveCell.col
                end

                local lineOpened = self:hasLineOfSight(
                    tempState,
                    {row = corvette.row, col = corvette.col},
                    {row = target.row, col = target.col}
                )

                if lineOpened and self:isAttackSafe(tempState, corvette, target) then
                    local newValue = self:getPositionalValue(state, {
                        row = moveCell.row,
                        col = moveCell.col,
                        name = blockingUnit.name,
                        player = blockingUnit.player,
                        currentHp = blockingUnit.currentHp or blockingUnit.hp
                    })
                    local simulatedState = self:applyMove(state, {
                        type = "move",
                        unit = {row = blockingUnit.row, col = blockingUnit.col},
                        target = {row = moveCell.row, col = moveCell.col}
                    })
                    local mobilityBonus = self:calculateMobilityBonus(state, simulatedState, blockingUnit, moveCell)
                    moveCandidates[#moveCandidates + ONE] = {
                        cell = moveCell,
                        isBeneficial = newValue > currentValue,
                        benefit = (newValue - currentValue) + mobilityBonus
                    }
                end
            end
        end

        self:sortScoredEntries(moveCandidates, {
            descending = true,
            scoreFn = function(entry)
                local beneficialRank = entry.isBeneficial and ONE or ZERO
                return (beneficialRank * 1000000) + (entry.benefit or ZERO)
            end,
            secondaryFn = function(entry)
                local row = entry and entry.cell and entry.cell.row or ZERO
                local col = entry and entry.cell and entry.cell.col or ZERO
                -- Keep deterministic row/col ascending when score ties.
                return -((row * 100) + col)
            end
        })

        return moveCandidates[ONE]
    end

    -- Obvious action 04: Corvette line-of-sight kill (move to clear path + Corvette shoot) (Check both adjacent cells and vulnerability to moves+attack)
    function aiClass:findCorvetteLineOfSightKills(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end
        local corvetteKills = {}
        local corvetteLosConfig = (self:getKillRiskScoreConfig().CORVETTE_LOS or {})
        local targetHpMax = corvetteLosConfig.TARGET_HP_MAX or MIN_HP

        for _, corvette in ipairs(state.units or {}) do
            if self:isUnitEligibleForAction(corvette, aiPlayer, usedUnits)
                and self:unitHasTag(corvette, "corvette") then
                for _, target in ipairs(state.units or {}) do
                    if self:isAttackableEnemyUnit(target, aiPlayer) then
                        local targetHp = target.currentHp or MIN_HP
                        if targetHp <= targetHpMax then
                            local hasLineOfSight = self:hasLineOfSight(
                                state,
                                {row = corvette.row, col = corvette.col},
                                {row = target.row, col = target.col}
                            )

                            if not hasLineOfSight then
                                local blockingPositions = self:getBlockingPositions(
                                    state,
                                    {row = corvette.row, col = corvette.col},
                                    {row = target.row, col = target.col}
                                ) or {}
                                local bestComboForTarget = nil

                                for _, blockingPos in ipairs(blockingPositions) do
                                    local blockingUnit = self:getUnitAtPosition(state, blockingPos.row, blockingPos.col)
                                    if self:isUnitEligibleForAction(blockingUnit, aiPlayer, usedUnits, {requireNotMoved = true}) then
                                        local bestMove = self:getBestLineOfSightClearingMove(state, blockingUnit, corvette, target)
                                        if bestMove then
                                            local combo = {
                                                mover = blockingUnit,
                                                corvette = corvette,
                                                target = target,
                                                moveAction = {
                                                    type = "move",
                                                    unit = {row = blockingUnit.row, col = blockingUnit.col},
                                                    target = {row = bestMove.cell.row, col = bestMove.cell.col}
                                                },
                                                attackAction = {
                                                    type = "attack",
                                                    unit = {row = corvette.row, col = corvette.col},
                                                    target = {row = target.row, col = target.col}
                                                },
                                                value = self:getUnitBaseValue(target, state),
                                                benefit = bestMove.benefit
                                            }

                                            if not bestComboForTarget then
                                                bestComboForTarget = combo
                                            else
                                                if combo.value > bestComboForTarget.value then
                                                    bestComboForTarget = combo
                                                elseif combo.value == bestComboForTarget.value then
                                                    if (combo.benefit or ZERO) > (bestComboForTarget.benefit or ZERO) then
                                                        bestComboForTarget = combo
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end

                                if bestComboForTarget then
                                    corvetteKills[#corvetteKills + ONE] = bestComboForTarget
                                end
                            end
                        end
                    end
                end
            end
        end

        self:sortScoredEntries(corvetteKills, {
            scoreField = "value",
            secondaryField = "benefit",
            descending = true
        })
        return corvetteKills
    end

    --  Obvious action 10: Evasion From a Secure Kill (Check adjacent cells and possible enemy move+attack range)
    function aiClass:findSafeEvasionMoves(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end

        local doctrineConfig = self:getDoctrineScoreConfig()
        local rangedDoctrine = doctrineConfig.RANGED_STANDOFF or {}
        local duelDoctrine = doctrineConfig.RANGED_DUEL_EVASION or {}
        local pinEscapeBaseBonus = valueOr(rangedDoctrine.PIN_ESCAPE_BASE_BONUS, 95)
        local pinEscapeThreatDeltaBonus = valueOr(rangedDoctrine.PIN_ESCAPE_THREAT_DELTA_BONUS, 75)
        local pinEscapeUnsafePenalty = valueOr(rangedDoctrine.PIN_ESCAPE_UNSAFE_PENALTY, 55)
        local minDuelForceBonus = valueOr(duelDoctrine.MIN_BONUS_TO_FORCE_EVASION, 35)
        local duelPressureByUnitKey = {}

        local function countAdjacentDirectThreats(evalState, targetUnit)
            if not evalState or not targetUnit then
                return ZERO
            end

            local threats = ZERO
            for _, enemy in ipairs(evalState.units or {}) do
                if enemy.player ~= aiPlayer and not self:isHubUnit(enemy) and not self:isObstacleUnit(enemy) then
                    local dist = math.abs(targetUnit.row - enemy.row) + math.abs(targetUnit.col - enemy.col)
                    if dist == ONE and self:canUnitDamageTargetFromPosition(
                        evalState,
                        enemy,
                        targetUnit,
                        enemy.row,
                        enemy.col,
                        {requirePositiveDamage = true}
                    ) then
                        threats = threats + ONE
                    end
                end
            end
            return threats
        end

        local function isPinnedRangedUnit(evalState, targetUnit)
            if not targetUnit then
                return false, ZERO
            end
            if not self:unitHasTag(targetUnit, "ranged") then
                return false, ZERO
            end
            if self:unitHasTag(targetUnit, "tank")
                or self:unitHasTag(targetUnit, "fortified")
                or self:unitHasTag(targetUnit, "healer") then
                return false, ZERO
            end

            local adjacentThreats = countAdjacentDirectThreats(evalState, targetUnit)
            return adjacentThreats > ZERO, adjacentThreats
        end

        local evasionMoves = {}
        local moveEntries = self:collectMoveEvaluationEntries(state, usedUnits, {
            aiPlayer = aiPlayer,
            unitEligibility = {requireNotMoved = true},
            requireSimulation = true,
            preUnitFilter = function(unitRef)
                if self:wouldUnitDieNextTurn(state, unitRef) then
                    return true
                end
                local pinned = select(ONE, isPinnedRangedUnit(state, unitRef))
                if pinned then
                    return true
                end
                local duelTargets = self:getRangedDuelPressureTargets(state, unitRef, aiPlayer)
                local unitKey = self:getUnitKey(unitRef)
                if unitKey then
                    duelPressureByUnitKey[unitKey] = duelTargets
                end
                return duelTargets and #duelTargets > ZERO
            end
        })

        for _, entry in ipairs(moveEntries) do
            local unit = entry.unit
            local moveCell = entry.moveCell
            local simState = entry.simState
            local movedUnit = entry.movedUnit
            local commanderExposurePenalty = self:calculateCommanderExposurePenalty(state, unit, moveCell)

            if simState and movedUnit then
                if commanderExposurePenalty > ZERO then
                    goto continue_evasion_move
                end

                local currentPinned, currentAdjThreats = isPinnedRangedUnit(state, unit)
                local _, movedAdjThreats = isPinnedRangedUnit(simState, movedUnit)
                local breaksPin = currentPinned and movedAdjThreats < currentAdjThreats
                local survivesMove = not self:wouldUnitDieNextTurn(simState, movedUnit)
                local unitKey = self:getUnitKey(unit)
                local duelPressureTargets = (unitKey and duelPressureByUnitKey[unitKey]) or self:getRangedDuelPressureTargets(state, unit, aiPlayer)

                local _, _, positionalDelta = self:getMovePositionalDelta(
                    state,
                    unit,
                    moveCell,
                    {simState = simState, movedUnit = movedUnit}
                )

                local pinEscapeBonus = ZERO
                if breaksPin then
                    pinEscapeBonus = pinEscapeBaseBonus + ((currentAdjThreats - movedAdjThreats) * pinEscapeThreatDeltaBonus)
                    if not survivesMove then
                        pinEscapeBonus = pinEscapeBonus - pinEscapeUnsafePenalty
                    end
                end

                local duelEvasionBonus = self:calculateRangedDuelEvasionBonus(
                    state,
                    unit,
                    moveCell,
                    aiPlayer,
                    {
                        simState = simState,
                        movedUnit = movedUnit,
                        pressureTargets = duelPressureTargets
                    }
                )

                local forceByDuelSignal = duelEvasionBonus >= minDuelForceBonus
                local shouldAdd = survivesMove or breaksPin or forceByDuelSignal
                if #duelPressureTargets > ZERO and (not currentPinned) and (not self:wouldUnitDieNextTurn(state, unit)) then
                    shouldAdd = survivesMove and forceByDuelSignal
                end
                if not shouldAdd then
                    goto continue_evasion_move
                end

                local adjustedPositionalDelta = positionalDelta - commanderExposurePenalty + pinEscapeBonus + duelEvasionBonus

                table.insert(evasionMoves, {
                    action = {
                        type = "move",
                        unit = {row = unit.row, col = unit.col},
                        target = {row = moveCell.row, col = moveCell.col}
                    },
                    unit = unit,
                    value = self:getUnitBaseValue(unit, state),
                    positionalBenefit = adjustedPositionalDelta,
                    breaksPin = breaksPin,
                    duelEvasionBonus = duelEvasionBonus
                })
            end
            ::continue_evasion_move::
        end

        -- Sort by positional benefit first (higher benefit = better position), then unit value.
        self:sortScoredEntries(evasionMoves, {
            scoreField = "positionalBenefit",
            secondaryField = "value",
            descending = true
        })
        return evasionMoves
    end

    function aiClass:collectAttackTargetEntries(state, usedUnits, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local mode = options.mode or "direct"
        local isMoveMode = (mode == "move")
        local allowHealerAttacks = options.allowHealerAttacks
        local includeFriendlyFireCheck = options.includeFriendlyFireCheck == true
        local requirePositiveDamage = options.requirePositiveDamage == true
        local minDamage = valueOr(options.minDamage, ZERO)
        local requireSafeMove = options.requireSafeMove == true
        local checkVulnerableMove = options.checkVulnerableMove == true
        local enforceHealerOrbit = options.enforceHealerOrbit == true
        local allowRangedAdjacent = options.allowRangedAdjacent == true
        local doctrineConfig = self:getDoctrineScoreConfig()
        local rangedDoctrine = doctrineConfig.RANGED_STANDOFF or {}
        local allowRangedAdjacentIfLethal = options.allowRangedAdjacentIfLethal
        if allowRangedAdjacentIfLethal == nil then
            allowRangedAdjacentIfLethal = valueOr(rangedDoctrine.EXCEPT_IF_LETHAL_OR_PRIORITY00, true)
        end
        local unitFilter = options.unitFilter
        local unitEligibility = options.unitEligibility or {}
        local entries = {}

        for _, unit in ipairs(state.units or {}) do
            local includeUnit = true
            if unitFilter and (not unitFilter(unit)) then
                includeUnit = false
            end

            if includeUnit then
                local eligibilityOpts = {}
                for key, value in pairs(unitEligibility) do
                    eligibilityOpts[key] = value
                end
                if isMoveMode then
                    eligibilityOpts.requireNotMoved = true
                end
                if allowHealerAttacks ~= nil then
                    eligibilityOpts.allowHealerAttacks = allowHealerAttacks
                end

                if self:isUnitEligibleForAction(unit, aiPlayer, usedUnits, eligibilityOpts) then
                    local attackPositions = {}
                    if isMoveMode then
                        local moveCells = self:getValidMoveCells(state, unit.row, unit.col) or {}
                        for _, moveCell in ipairs(moveCells) do
                            local skipMove = false
                            if enforceHealerOrbit and allowHealerAttacks == false and self:unitHasTag(unit, "healer") then
                                if not self:isHealerOrbitMoveAllowed(state, unit, moveCell, aiPlayer) then
                                    skipMove = true
                                end
                            end

                            if not skipMove and self:unitHasTag(unit, "healer") then
                                local healerMoveAllowed, healerRejectReason = self:isHealerMoveDoctrineAllowed(
                                    state,
                                    unit,
                                    moveCell,
                                    aiPlayer,
                                    {allowEmergencyDefense = true}
                                )
                                if not healerMoveAllowed then
                                    skipMove = true
                                    if healerRejectReason == "frontline" or healerRejectReason == "orbit" then
                                        self.healerFrontlineViolationRejected = (self.healerFrontlineViolationRejected or ZERO) + ONE
                                    end
                                end
                            end

                            if not skipMove then
                                local moveSafe = true
                                if requireSafeMove then
                                    moveSafe = self:isMoveSafe(state, unit, moveCell, {checkVulnerable = checkVulnerableMove})
                                end

                                if moveSafe then
                                    local rangedStandoffViolation = false
                                    if not allowRangedAdjacent then
                                        rangedStandoffViolation = self:isRangedStandoffViolation(state, unit, moveCell, aiPlayer, {
                                            enforceAnyAdjacent = true,
                                            moveCells = moveCells
                                        })
                                    end
                                    attackPositions[#attackPositions + ONE] = {
                                        row = moveCell.row,
                                        col = moveCell.col,
                                        moveCell = {row = moveCell.row, col = moveCell.col},
                                        rangedStandoffViolation = rangedStandoffViolation,
                                        moveAction = {
                                            type = "move",
                                            unit = {row = unit.row, col = unit.col},
                                            target = {row = moveCell.row, col = moveCell.col}
                                        }
                                    }
                                end
                            end
                        end
                    else
                        attackPositions[#attackPositions + ONE] = {
                            row = unit.row,
                            col = unit.col
                        }
                    end

                    for _, attackPos in ipairs(attackPositions) do
                        local attackCells = isMoveMode
                            and (self:getAttackCellsForUnitAtPosition(state, unit, attackPos.row, attackPos.col) or {})
                            or (self:getAttackCellsForUnit(state, unit) or {})

                        for _, attackCell in ipairs(attackCells) do
                            local target = self:getUnitAtPosition(state, attackCell.row, attackCell.col)
                            if self:isAttackableEnemyUnit(target, aiPlayer)
                                and ((not includeFriendlyFireCheck) or (not self:isFriendlyFireAttack(unit, target))) then
                                local damage, specialUsed = self.unitsInfo:calculateAttackDamage(unit, target)
                                if damage >= minDamage and ((not requirePositiveDamage) or damage > ZERO) then
                                    local targetHp = target.currentHp or MIN_HP
                                    local lethal = damage >= targetHp
                                    if isMoveMode
                                        and attackPos.rangedStandoffViolation == true
                                        and (not allowRangedAdjacent)
                                        and (not (allowRangedAdjacentIfLethal and lethal)) then
                                        goto continue_attack_cell
                                    end

                                    local entry = {
                                        unit = unit,
                                        target = target,
                                        attackCell = {row = attackCell.row, col = attackCell.col},
                                        damage = damage,
                                        specialUsed = specialUsed,
                                        targetHp = targetHp
                                    }

                                    if isMoveMode then
                                        entry.moveCell = attackPos.moveCell
                                        entry.moveAction = attackPos.moveAction
                                        entry.attackAction = {
                                            type = "attack",
                                            unit = {row = attackPos.row, col = attackPos.col},
                                            target = {row = attackCell.row, col = attackCell.col}
                                        }
                                    else
                                        entry.action = {
                                            type = "attack",
                                            unit = {row = unit.row, col = unit.col},
                                            target = {row = attackCell.row, col = attackCell.col}
                                        }
                                    end

                                    entries[#entries + ONE] = entry
                                end
                            end
                            ::continue_attack_cell::
                        end
                    end
                end
            end
        end

        return entries
    end

    function aiClass:collectHighValueAttackCandidates(state, usedUnits, opts)
        local options = opts or {}
        local aiPlayer = self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local highValueAttacks = {}
        usedUnits = usedUnits or {}
        local allowHealerAttacks = options.allowHealerAttacks
        if allowHealerAttacks == nil then
            allowHealerAttacks = self:shouldHealerBeOffensive(state)
        end

        local includeRangedThreatToOwnHub = options.includeRangedThreatToOwnHub == true
        local includeSafeEnemyHubAdjacency = options.includeSafeEnemyHubAdjacency ~= false
        local requireAttackerSurvival = options.requireAttackerSurvival == true
        local requireAttackSafety = options.requireAttackSafety == true
        local allowBeneficialSuicide = options.allowBeneficialSuicide == true
        local requireHubThreatForDefenseBonus = options.requireHubThreatForDefenseBonus == true
        local applyCorvetteRetaliationPenalty = options.applyCorvetteRetaliationPenalty == true
        local strictFortified = options.strictFortified
        if strictFortified == nil then
            strictFortified = false
        end

        local entries = self:collectAttackTargetEntries(state, usedUnits, {
            mode = "direct",
            aiPlayer = aiPlayer,
            allowHealerAttacks = allowHealerAttacks,
            includeFriendlyFireCheck = false,
            requirePositiveDamage = true
        })

        highValueAttacks = self:collectEvaluatedAttackEntries(state, entries, {
            evaluateOptionsFn = function(entry)
                local unit = entry.unit
                return {
                    strictFortified = strictFortified,
                    includeRangedThreatToOwnHub = includeRangedThreatToOwnHub,
                    includeSafeEnemyHubAdjacency = includeSafeEnemyHubAdjacency,
                    prioritizeOptions = includeRangedThreatToOwnHub and {includeRangedThreatToOwnHub = true} or nil,
                    requireAttackSafety = requireAttackSafety,
                    allowBeneficialSuicide = allowBeneficialSuicide,
                    requireAttackerSurvival = requireAttackerSurvival,
                    scoreOptions = {
                        positionalUnit = unit,
                        requireHubThreatForDefenseBonus = requireHubThreatForDefenseBonus,
                        includeRangedThreatToOwnHub = includeRangedThreatToOwnHub,
                        applyCorvetteRetaliationPenalty = applyCorvetteRetaliationPenalty
                    }
                }
            end,
            resultFn = function(entry, evaluation)
                return {
                    unit = entry.unit,
                    action = entry.action,
                    value = evaluation.value
                }
            end
        })

        return highValueAttacks
    end

    function aiClass:getHighValueAttackProfileOptions(state, profileName)
        local allowHealerAttacks = self:shouldHealerBeOffensive(state)
        local profile = profileName or "safe"

        if profile == "aggressive" then
            return {
                allowHealerAttacks = allowHealerAttacks,
                includeRangedThreatToOwnHub = true,
                includeSafeEnemyHubAdjacency = true,
                requireAttackSafety = true,
                allowBeneficialSuicide = true,
                requireAttackerSurvival = false,
                requireHubThreatForDefenseBonus = true,
                applyCorvetteRetaliationPenalty = true,
                strictFortified = false
            }
        end

        return {
            allowHealerAttacks = allowHealerAttacks,
            includeRangedThreatToOwnHub = false,
            includeSafeEnemyHubAdjacency = true,
            requireAttackSafety = true,
            allowBeneficialSuicide = false,
            requireAttackerSurvival = true,
            requireHubThreatForDefenseBonus = false,
            applyCorvetteRetaliationPenalty = false,
            strictFortified = false
        }
    end

    -- Obvious action 10: High Damage Attack (includes suicide check)
    function aiClass:findHighValueSafeAttacks(state, usedUnits)
        return self:collectHighValueAttackCandidates(
            state,
            usedUnits,
            self:getHighValueAttackProfileOptions(state, "safe")
        )
    end

    -- Obvious action 11: High Damage Attack (NO suicide check)
    function aiClass:findHighValueAttacks(state, usedUnits)
        return self:collectHighValueAttackCandidates(
            state,
            usedUnits,
            self:getHighValueAttackProfileOptions(state, "aggressive")
        )
    end

    function aiClass:collectMoveAttackOpportunityCombos(state, usedUnits, opts)
        local options = opts or {}
        local aiPlayer = options.aiPlayer or self:getFactionId()
        if not aiPlayer or not state then
            return {}
        end

        local allowHealerAttacks = options.allowHealerAttacks
        local requireSafeMove = options.requireSafeMove == true
        local requireSafeAttack = options.requireSafeAttack == true
        local allowBeneficialSuicide = options.allowBeneficialSuicide == true
        local checkVulnerableMove = options.checkVulnerableMove == true
        local enforceHealerOrbit = options.enforceHealerOrbit == true
        local includeSafeEnemyHubAdjacency = options.includeSafeEnemyHubAdjacency == true
        local includeUnsafeEnemyHubAdj = options.includeUnsafeEnemyHubAdj == true
        local requireHubThreatForDefenseBonus = options.requireHubThreatForDefenseBonus == true
        local applyCommanderExposurePenalty = options.applyCommanderExposurePenalty == true
        local strictFortified = options.strictFortified
        if strictFortified == nil then
            strictFortified = true
        end

        local prioritizeOptions = includeUnsafeEnemyHubAdj and {includeUnsafeEnemyHubAdj = true} or nil
        local entries = self:collectAttackTargetEntries(state, usedUnits, {
            mode = "move",
            aiPlayer = aiPlayer,
            allowHealerAttacks = allowHealerAttacks,
            requireSafeMove = requireSafeMove,
            checkVulnerableMove = checkVulnerableMove,
            enforceHealerOrbit = enforceHealerOrbit,
            includeFriendlyFireCheck = false,
            requirePositiveDamage = true,
            minDamage = ZERO,
            unitEligibility = {}
        })

        local combos = self:collectEvaluatedAttackEntries(state, entries, {
            evaluateOptionsFn = function(entry)
                local scoreOptions = {
                    positionalUnit = entry.unit
                }
                if requireHubThreatForDefenseBonus then
                    scoreOptions.requireHubThreatForDefenseBonus = true
                end
                if includeUnsafeEnemyHubAdj then
                    scoreOptions.includeUnsafeEnemyHubAdj = true
                end
                if applyCommanderExposurePenalty then
                    scoreOptions.applyCommanderExposurePenalty = true
                    scoreOptions.movePos = entry.moveCell
                end

                return {
                    attackPos = entry.moveCell,
                    strictFortified = strictFortified,
                    includeSafeEnemyHubAdjacency = includeSafeEnemyHubAdjacency,
                    prioritizeOptions = prioritizeOptions,
                    requireAttackSafety = requireSafeAttack,
                    allowBeneficialSuicide = allowBeneficialSuicide,
                    scoreOptions = scoreOptions
                }
            end,
            resultFn = function(entry, evaluation)
                return {
                    moveAction = entry.moveAction,
                    attackAction = entry.attackAction,
                    unit = entry.unit,
                    value = evaluation.value
                }
            end,
            scoreField = "value",
            descending = true,
            secondaryDescending = false,
            secondaryFn = function(entry)
                local move = entry and entry.moveAction and entry.moveAction.target or {}
                local target = entry and entry.attackAction and entry.attackAction.target or {}
                local moveRow = move.row or ZERO
                local moveCol = move.col or ZERO
                local targetRow = target.row or ZERO
                local targetCol = target.col or ZERO
                return (moveRow * 1000000) + (moveCol * 10000) + (targetRow * 100) + targetCol
            end
        })

        return combos
    end

    function aiClass:getMoveAttackOpportunityProfileOptions(state, profileName)
        local profile = profileName or "safe"

        if profile == "risky" then
            return {
                requireSafeMove = false,
                requireSafeAttack = true,
                allowBeneficialSuicide = true,
                checkVulnerableMove = false,
                enforceHealerOrbit = false,
                includeSafeEnemyHubAdjacency = false,
                includeUnsafeEnemyHubAdj = true,
                requireHubThreatForDefenseBonus = false,
                applyCommanderExposurePenalty = true,
                strictFortified = true
            }
        end

        return {
            allowHealerAttacks = self:shouldHealerBeOffensive(state),
            requireSafeMove = true,
            requireSafeAttack = true,
            allowBeneficialSuicide = false,
            checkVulnerableMove = true,
            enforceHealerOrbit = true,
            includeSafeEnemyHubAdjacency = true,
            includeUnsafeEnemyHubAdj = false,
            requireHubThreatForDefenseBonus = true,
            applyCommanderExposurePenalty = false,
            strictFortified = true
        }
    end

    -- Obvious actions 12: Move+Attack High Damage Combinations (Check adjacent safe cells and possible enemy move+attack range)
    function aiClass:findMoveAttackCombinations(state, usedUnits)
        return self:collectMoveAttackOpportunityCombos(
            state,
            usedUnits,
            self:getMoveAttackOpportunityProfileOptions(state, "safe")
        )
    end

    -- Obvious actions 13: Beneficial No-Damage Moves (Safe positions)
    function aiClass:findBeneficialNoDamageMoves(state, usedUnits)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return {}
        end

        local beneficialMoves = {}
        local componentWeights = self:getPositionalComponentWeights()
        local supportMode = (state.attackedObjectivesThisTurn and #state.attackedObjectivesThisTurn > ZERO)
        local supportCandidatesFound = false
        local rangedLaneConfig = self:getPositionalScoreConfig().RANGED_LANE or {}
        local defaultRangedLaneConfig = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).RANGED_LANE or {})
        local rangedIdealRange = valueOr(rangedLaneConfig.IDEAL_RANGE, valueOr(defaultRangedLaneConfig.IDEAL_RANGE, TWO))
        local rangedIdealBonus = valueOr(rangedLaneConfig.IDEAL_RANGE_BONUS, valueOr(defaultRangedLaneConfig.IDEAL_RANGE_BONUS, ZERO))
        local rangedSetupBonus = valueOr(rangedLaneConfig.SETUP_RANGE_BONUS, valueOr(defaultRangedLaneConfig.SETUP_RANGE_BONUS, ZERO))
        local noTargetPenaltyRanged = valueOr(rangedLaneConfig.NO_TARGET_PENALTY_RANGED, valueOr(defaultRangedLaneConfig.NO_TARGET_PENALTY_RANGED, ZERO))
        local noTargetPenaltyMelee = valueOr(rangedLaneConfig.NO_TARGET_PENALTY_MELEE, valueOr(defaultRangedLaneConfig.NO_TARGET_PENALTY_MELEE, ZERO))
        local newTargetOnlyPenalty = valueOr(rangedLaneConfig.NEW_TARGET_ONLY_PENALTY, valueOr(defaultRangedLaneConfig.NEW_TARGET_ONLY_PENALTY, ZERO))
        local zeroOverlapPenalty = valueOr(rangedLaneConfig.ZERO_OVERLAP_PENALTY, valueOr(defaultRangedLaneConfig.ZERO_OVERLAP_PENALTY, ZERO))
        local rangeRegressionPenalty = valueOr(rangedLaneConfig.RANGE_REGRESSION_PENALTY, valueOr(defaultRangedLaneConfig.RANGE_REGRESSION_PENALTY, ZERO))
        local friendlyLosBlockPenalty = valueOr(rangedLaneConfig.FRIENDLY_LOS_BLOCK_PENALTY, valueOr(defaultRangedLaneConfig.FRIENDLY_LOS_BLOCK_PENALTY, ZERO))
        local crossfireOverlapBonus = valueOr(rangedLaneConfig.CROSSFIRE_OVERLAP_BONUS, valueOr(defaultRangedLaneConfig.CROSSFIRE_OVERLAP_BONUS, ZERO))
        local hubThreatFocusBonus = valueOr(rangedLaneConfig.HUB_THREAT_FOCUS_BONUS, valueOr(defaultRangedLaneConfig.HUB_THREAT_FOCUS_BONUS, ZERO))
        local hubThreatDistanceMax = math.max(
            ONE,
            valueOr(rangedLaneConfig.HUB_THREAT_DISTANCE_MAX, valueOr(defaultRangedLaneConfig.HUB_THREAT_DISTANCE_MAX, THREE))
        )

        local function closestEnemyDistance(boardState, position)
            if not boardState or not boardState.units or not position then
                return math.huge
            end

            local minDist = math.huge
            for _, enemy in ipairs(boardState.units) do
                if enemy.player and enemy.player ~= ZERO and enemy.player ~= aiPlayer then
                    local dist = math.abs(enemy.row - position.row) + math.abs(enemy.col - position.col)
                    if dist < minDist then
                        minDist = dist
                    end
                end
            end

            return minDist
        end

        local allowHealerAttacks = self:shouldHealerBeOffensive(state)
        local function preMoveFilter(unit, moveCell)
            if not allowHealerAttacks and self:unitHasTag(unit, "healer")
                and not self:isHealerOrbitMoveAllowed(state, unit, moveCell, aiPlayer) then
                return false
            end

            local prohibitsAdjacent = not unitsInfo:canAttackAdjacent(unit.name or "")
            if prohibitsAdjacent and closestEnemyDistance(state, moveCell) <= ONE then
                return false
            end

            return true
        end

        local moveEntries = self:collectMoveEvaluationEntries(state, usedUnits, {
            aiPlayer = aiPlayer,
            unitEligibility = {requireNotMoved = true, disallowRock = true},
            allowHealerAttacks = allowHealerAttacks,
            preMoveFilter = preMoveFilter,
            requireSimulation = true
        })

        for _, entry in ipairs(moveEntries) do
            local unit = entry.unit
            local moveCell = entry.moveCell
            local simState = entry.simState
            local movedUnit = entry.movedUnit
            local attackRange = unit.atkRange or unitsInfo:getUnitAttackRange(unit, "FIND_BENEFICIAL_MOVES_RANGE") or MIN_HP
            local prohibitsAdjacent = not unitsInfo:canAttackAdjacent(unit.name or "")

            local isSafePosition = self.aiSafety.isPositionCompletelySafe(self, simState, moveCell, movedUnit)
            local objectiveBonus, supportTriggered = self:calculateObjectiveMobilityBonus(state, simState, unit, moveCell)

            local allowRiskySupport = false
            if supportMode and supportTriggered then
                supportCandidatesFound = true
                allowRiskySupport = self:isMoveSafe(state, unit, moveCell)
            end

            if isSafePosition or allowRiskySupport then
                local currentValue = self:getPositionalValue(state, unit)
                local newValue = self:getPositionalValue(simState, movedUnit)

                local pathOpeningBonus = self:calculatePathOpeningBonus(simState, movedUnit, moveCell)
                local reachabilityBonus = self:calculateNextTurnReachabilityBonus(simState, movedUnit, moveCell)

                local improvement = (newValue - currentValue) + pathOpeningBonus + reachabilityBonus + objectiveBonus

                local isRangedUnit = attackRange and attackRange > ONE
                if isRangedUnit then
                    local function cloneAt(row, col)
                        return {
                            row = row,
                            col = col,
                            name = unit.name,
                            player = unit.player,
                            currentHp = unit.currentHp,
                            startingHp = unit.startingHp,
                            atkDamage = unit.atkDamage,
                            move = unit.move,
                            atkRange = attackRange,
                            fly = unit.fly
                        }
                    end

                    local currentClone = cloneAt(unit.row, unit.col)
                    local movedClone = cloneAt(moveCell.row, moveCell.col)

                    local currentAttackCells = self:getAttackCellsForUnitAtPosition(state, currentClone, currentClone.row, currentClone.col) or {}
                    local newAttackCells = self:getAttackCellsForUnitAtPosition(simState, movedClone, movedClone.row, movedClone.col) or {}

                    local function buildAttackMap(cells)
                        local map = {}
                        for _, cell in ipairs(cells) do
                            map[#map + ONE] = {row = cell.row, col = cell.col}
                        end
                        return map
                    end

                    local currentMap = buildAttackMap(currentAttackCells)
                    local newMap = buildAttackMap(newAttackCells)

                    local currentHasTargets = #currentMap > ZERO
                    local newHasTargets = #newMap > ZERO

                    if not newHasTargets then
                        local basePenalty = isRangedUnit and noTargetPenaltyRanged or noTargetPenaltyMelee
                        improvement = improvement - basePenalty
                    elseif not currentHasTargets then
                        improvement = improvement - newTargetOnlyPenalty
                    else
                        local overlap = ZERO
                        for _, currentCell in ipairs(currentMap) do
                            for _, newCell in ipairs(newMap) do
                                if currentCell.row == newCell.row and currentCell.col == newCell.col then
                                    overlap = overlap + ONE
                                    break
                                end
                            end
                        end
                        if overlap == ZERO then
                            improvement = improvement - zeroOverlapPenalty
                        end
                    end

                    if currentHasTargets and newHasTargets then
                        local function bestRangeFrom(originRow, originCol, cells)
                            local best = math.huge
                            for _, cell in ipairs(cells) do
                                local dist = math.abs(originRow - cell.row) + math.abs(originCol - cell.col)
                                if dist < best then
                                    best = dist
                                end
                            end
                            return best
                        end

                        local bestCurrentRange = bestRangeFrom(unit.row, unit.col, currentMap)
                        local bestNewRange = bestRangeFrom(moveCell.row, moveCell.col, newMap)

                        if prohibitsAdjacent and bestNewRange ~= math.huge then
                            if bestNewRange == rangedIdealRange then
                                improvement = improvement + rangedIdealBonus
                            elseif bestNewRange > rangedIdealRange and bestNewRange <= attackRange then
                                improvement = improvement + rangedSetupBonus
                            end
                        end

                        if bestNewRange >= bestCurrentRange then
                            improvement = improvement - rangeRegressionPenalty
                        end

                        local friendlyRanged = {}
                        for _, ally in ipairs(state.units) do
                            if ally.player == aiPlayer and ally ~= unit then
                                local allyRange = ally.atkRange or unitsInfo:getUnitAttackRange(ally, "LOS_BLOCK_CHECK_RANGE") or MIN_HP
                                if allyRange > ONE and not ally.hasActed then
                                    friendlyRanged[#friendlyRanged + ONE] = ally
                                end
                            end
                        end

                        for _, ally in ipairs(friendlyRanged) do
                            local blockedLineOfSight = false
                            for _, currentCell in ipairs(currentMap) do
                                local targetUnit = self:getUnitAtPosition(state, currentCell.row, currentCell.col)
                                if targetUnit and targetUnit.player ~= aiPlayer then
                                    if self:hasLineOfSight(state, ally, targetUnit)
                                        and self:isPositionBetweenOrthogonal(moveCell, ally, currentCell) then
                                        improvement = improvement - friendlyLosBlockPenalty
                                        blockedLineOfSight = true
                                        break
                                    end
                                end
                            end
                            if blockedLineOfSight then
                                break
                            end
                        end

                        if crossfireOverlapBonus ~= ZERO or hubThreatFocusBonus ~= ZERO then
                            local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
                            local newAttackLookup = {}
                            for _, newCell in ipairs(newMap) do
                                local key = hashPosition(newCell)
                                if key then
                                    newAttackLookup[key] = newCell
                                end
                            end

                            local overlapCount = ZERO
                            local threatFocusCount = ZERO
                            local seenOverlap = {}

                            for _, ally in ipairs(friendlyRanged) do
                                local allyAttackCells = self:getAttackCellsForUnitAtPosition(state, ally, ally.row, ally.col) or {}
                                for _, allyCell in ipairs(allyAttackCells) do
                                    local key = hashPosition(allyCell)
                                    local overlapCell = key and newAttackLookup[key] or nil
                                    if overlapCell and not seenOverlap[key] then
                                        seenOverlap[key] = true
                                        overlapCount = overlapCount + ONE

                                        if ownHub then
                                            local distToOwnHub = math.abs(overlapCell.row - ownHub.row) + math.abs(overlapCell.col - ownHub.col)
                                            if distToOwnHub <= hubThreatDistanceMax then
                                                threatFocusCount = threatFocusCount + ONE
                                            end
                                        end
                                    end
                                end
                            end

                            improvement = improvement + (overlapCount * crossfireOverlapBonus) + (threatFocusCount * hubThreatFocusBonus)
                        end
                    end
                end

                local _, _, currentEscapeRoutes = self.aiSafety.isDeadEndPosition(self, state, {row = unit.row, col = unit.col}, unit)
                local _, _, newEscapeRoutesRaw = self.aiSafety.isDeadEndPosition(self, simState, moveCell, movedUnit)

                local newEscapeRoutes = newEscapeRoutesRaw or ZERO
                local currentRoutes = currentEscapeRoutes or ZERO

                if math.abs(moveCell.row - unit.row) + math.abs(moveCell.col - unit.col) == ONE then
                    local originalOccupant = self.aiState.getUnitAtPosition(state, unit.row, unit.col)
                    if originalOccupant == unit then
                        newEscapeRoutes = newEscapeRoutes + ONE
                    end
                end

                local positionalWeights = aiInfluence.CONFIG.POSITIONAL_WEIGHTS or {}
                local escapeRouteBonus = valueOr(
                    positionalWeights.DEAD_END_ESCAPE_ROUTE_BONUS,
                    valueOr(defaultRangedLaneConfig.DEAD_END_ESCAPE_ROUTE_BONUS, ZERO)
                )
                local newSingleExitPenalty = valueOr(
                    positionalWeights.DEAD_END_NEW_SINGLE_EXIT_PENALTY,
                    valueOr(defaultRangedLaneConfig.DEAD_END_NEW_SINGLE_EXIT_PENALTY, ZERO)
                )
                local maxDirectionalFreedom = valueOr(
                    positionalWeights.MAX_ESCAPE_ROUTE_COUNT,
                    valueOr(defaultRangedLaneConfig.MAX_ESCAPE_ROUTE_COUNT, FOUR)
                )
                local directionalFreedomBonus = valueOr(
                    positionalWeights.MAX_ESCAPE_ROUTE_DIRECTIONAL_BONUS,
                    valueOr(defaultRangedLaneConfig.MAX_ESCAPE_ROUTE_DIRECTIONAL_BONUS, ZERO)
                )

                local escapeRouteDelta = newEscapeRoutes - currentRoutes
                if escapeRouteDelta ~= ZERO then
                    improvement = improvement + (escapeRouteDelta * escapeRouteBonus)
                end

                if newEscapeRoutes <= ONE and currentRoutes > newEscapeRoutes then
                    improvement = improvement - newSingleExitPenalty
                end

                if type(directionalFreedomBonus) == "number"
                    and type(maxDirectionalFreedom) == "number"
                    and directionalFreedomBonus ~= ZERO
                    and maxDirectionalFreedom > ZERO then
                    local cappedRoutes = math.min(newEscapeRoutes, maxDirectionalFreedom)
                    local freedomRatio = cappedRoutes / maxDirectionalFreedom
                    improvement = improvement + (freedomRatio * directionalFreedomBonus)
                end

                local offensiveBonus = self:calculateOffensiveBonus(simState, movedUnit, moveCell)
                local forwardPressureBonus = self:getForwardPressureBonus(state, unit, moveCell, aiPlayer)
                local lowImpactPenalty = self:getLowImpactMovePenalty(state, unit, moveCell, aiPlayer)
                local rangedAdjacencyPenalty = self:getRangedAdjacencyPenalty(simState, movedUnit, moveCell, aiPlayer)

                if self:unitHasTag(unit, "wingstalker") then
                    local currentEnemyDist = closestEnemyDistance(state, {row = unit.row, col = unit.col})
                    local newEnemyDist = closestEnemyDistance(simState, moveCell)
                    local disengageConfig = self:getPositionalScoreConfig().WINGSTALKER_DISENGAGE or {}
                    local defaultDisengageConfig = ((DEFAULT_SCORE_PARAMS.POSITIONAL or {}).WINGSTALKER_DISENGAGE or {})
                    local threatDistanceMax = valueOr(disengageConfig.THREAT_DISTANCE_MAX, valueOr(defaultDisengageConfig.THREAT_DISTANCE_MAX, ZERO))
                    local disengagePenalty = valueOr(disengageConfig.PENALTY, valueOr(defaultDisengageConfig.PENALTY, ZERO))

                    if currentEnemyDist ~= math.huge and currentEnemyDist <= threatDistanceMax and newEnemyDist > currentEnemyDist then
                        improvement = improvement - disengagePenalty
                    end
                end

                local scoredMove = self:scoreStrategicMove(state, unit, moveCell, {
                    aiPlayer = aiPlayer,
                    simState = simState,
                    movedUnit = movedUnit,
                    improvement = improvement,
                    threatState = state,
                    threatUnit = unit,
                    repairState = simState,
                    repairUnit = unit,
                    componentWeights = componentWeights,
                    offensiveBonus = offensiveBonus,
                    forwardPressureBonus = forwardPressureBonus,
                    extraPenalty = lowImpactPenalty + rangedAdjacencyPenalty,
                    includeCommanderPenalty = true,
                    includeFreeAdjacent = true,
                    thresholdPolicy = "safe"
                })

                local finalScore = scoredMove.finalScore
                local improvementThreshold = scoredMove.threshold

                if self:unitHasTag(unit, "healer") and not allowHealerAttacks then
                    local ownHub = state.commandHubs and state.commandHubs[aiPlayer]
                    if ownHub then
                        finalScore = finalScore + self:getHealerOrbitBonus(unit, moveCell, ownHub)
                    end
                end

                if finalScore > improvementThreshold then
                    table.insert(beneficialMoves, {
                        unit = unit,
                        action = {
                            type = "move",
                            unit = {row = unit.row, col = unit.col},
                            target = {row = moveCell.row, col = moveCell.col}
                        },
                        value = finalScore,
                        threatValue = scoredMove.threatValue,
                        positionalValue = improvement
                    })
                end
            end
        end

        self:sortScoredEntries(beneficialMoves, {
            scoreField = "value",
            descending = true
        })
        return beneficialMoves, supportCandidatesFound
    end

    -- Obvious actions 22: Beneficial Moves (Using suicide check)
    function aiClass:findBeneficialMoves(state, usedUnits)
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
            movePolicyOptions = {checkVulnerable = true},
            requireSimulation = true
        })

        for _, entry in ipairs(moveEntries) do
            local unit = entry.unit
            local moveCell = entry.moveCell
            local simState = entry.simState
            local movedUnit = entry.movedUnit

            local mobilityBonus = self:calculateMobilityBonus(state, simState, unit, moveCell)
            local pathOpeningBonus = self:calculatePathOpeningBonus(simState, movedUnit, moveCell)
            local reachabilityBonus = self:calculateNextTurnReachabilityBonus(simState, movedUnit, moveCell)
            local offensiveBonus = self:calculateOffensiveBonus(simState, movedUnit, moveCell)
            local forwardPressureBonus = self:getForwardPressureBonus(state, unit, moveCell, aiPlayer)
            local lowImpactPenalty = self:getLowImpactMovePenalty(state, unit, moveCell, aiPlayer)
            local rangedAdjacencyPenalty = self:getRangedAdjacencyPenalty(simState, movedUnit, moveCell, aiPlayer)
            local scoredMove = self:scoreStrategicMove(state, unit, moveCell, {
                aiPlayer = aiPlayer,
                simState = simState,
                movedUnit = movedUnit,
                mobilityBonus = mobilityBonus,
                pathOpeningBonus = pathOpeningBonus,
                reachabilityBonus = reachabilityBonus,
                offensiveBonus = offensiveBonus,
                forwardPressureBonus = forwardPressureBonus,
                componentWeights = componentWeights,
                extraPenalty = lowImpactPenalty + rangedAdjacencyPenalty,
                includeCommanderPenalty = true,
                includeFreeAdjacent = true,
                thresholdPolicy = "safe"
            })

            if scoredMove.finalScore > scoredMove.threshold then
                table.insert(beneficialMoves, {
                    unit = unit,
                    action = {
                        type = "move",
                        unit = {row = unit.row, col = unit.col},
                        target = {row = moveCell.row, col = moveCell.col}
                    },
                    value = scoredMove.finalScore,
                    threatValue = scoredMove.threatValue,
                    positionalValue = scoredMove.improvement
                })
            end
        end

        self:sortScoredEntries(beneficialMoves, {
            scoreField = "value",
            descending = true
        })
        return beneficialMoves
    end

    -- Obvious action 14: Move+Attack combinations without safety filters (used after safe options)
    function aiClass:findNotSoSafeMoveAttackCombinations(state, usedUnits)
        return self:collectMoveAttackOpportunityCombos(
            state,
            usedUnits,
            self:getMoveAttackOpportunityProfileOptions(state, "risky")
        )
    end



    -- Calculate offensive bonus based on next-turn move+attack opportunities from a position
    function aiClass:calculateOffensiveBonus(state, unit, movePos)
        local aiPlayer = self:getFactionId()
        if not aiPlayer then
            return ZERO
        end
        local offensiveConfig = self:getScoreConfig().OFFENSIVE or {}
        local defaultOffensiveConfig = DEFAULT_SCORE_PARAMS.OFFENSIVE or {}
        local offensiveBonus = ZERO
        local attackableEnemies = ZERO
        local totalPotentialDamage = ZERO
        local highValueTargets = ZERO
        local multiTargetBonus = ZERO

        -- Create temporary unit at the move position
        local tempUnit = {
            row = movePos.row,
            col = movePos.col,
            name = unit.name,
            player = unit.player,
            currentHp = unit.currentHp,
            startingHp = unit.startingHp
        }

        -- Get all valid attack cells from this position (next turn the unit could attack these)
        local attackCells = self:getValidAttackCells(state, tempUnit.row, tempUnit.col)

        for _, attackCell in ipairs(attackCells) do
            local target = self:getUnitAtPosition(state, attackCell.row, attackCell.col)
            if self:isAttackableEnemyUnit(target, aiPlayer) then
                attackableEnemies = attackableEnemies + ONE

                -- Calculate potential damage using centralized function
                local damage = unitsInfo:calculateAttackDamage(tempUnit, target)
                totalPotentialDamage = totalPotentialDamage + damage

                -- Count high-value targets for bonus calculation
                if self:unitHasTag(target, "hub") then
                    highValueTargets = highValueTargets + THREE
                elseif self:unitHasTag(target, "high_value") then
                    highValueTargets = highValueTargets + TWO
                else
                    highValueTargets = highValueTargets + ONE
                end
            end
        end

        -- Bonuses for offensive positioning
        if attackableEnemies > ZERO then
            -- Attack count bonus: +20 points per attackable enemy
            local attackCountBonus = attackableEnemies * valueOr(offensiveConfig.ATTACK_COUNT_BONUS, defaultOffensiveConfig.ATTACK_COUNT_BONUS)

            -- Damage potential bonus: +15 points per point of potential damage
            local damagePotentialBonus = totalPotentialDamage * valueOr(offensiveConfig.DAMAGE_POTENTIAL_BONUS, defaultOffensiveConfig.DAMAGE_POTENTIAL_BONUS)

            -- High-value target bonus (already calculated above)
            local highValueBonus = highValueTargets * valueOr(offensiveConfig.HIGH_VALUE_TARGET_BONUS, defaultOffensiveConfig.HIGH_VALUE_TARGET_BONUS)

            -- Multi-target bonus: +30 additional points for positions attacking 2+ enemies
            if attackableEnemies >= TWO then
                multiTargetBonus = valueOr(offensiveConfig.MULTI_TARGET_BONUS, defaultOffensiveConfig.MULTI_TARGET_BONUS)
            end

            offensiveBonus = attackCountBonus + damagePotentialBonus + highValueBonus + multiTargetBonus

        end

        return offensiveBonus
    end

    function aiClass:simulateUnitMoveState(stateSnapshot, unit, moveCell, opts)
        if not stateSnapshot or not unit or not moveCell then
            return stateSnapshot, nil
        end

        local options = opts or {}
        local simState = self:deepCopyState(stateSnapshot)
        local simUnitRef

        for _, simUnit in ipairs(simState.units or {}) do
            if simUnit.player == unit.player and simUnit.row == unit.row and simUnit.col == unit.col and simUnit.name == unit.name then
                simUnit.row = moveCell.row
                simUnit.col = moveCell.col
                simUnitRef = simUnit
            elseif simUnit.row == moveCell.row and simUnit.col == moveCell.col then
                simUnit.row = unit.row
                simUnit.col = unit.col
            end
        end

        if options.validate then
            simState = self:validateAndFixUnitStates(simState)
        end

        return simState, simUnitRef
    end

    function aiClass:isDoomedFinisherAttack(specialUsed, wouldLeaveAt1HP)
        return specialUsed or wouldLeaveAt1HP
    end

    function aiClass:isDoomedEliminationAttack(damage, targetHp, specialUsed, wouldLeaveAt1HP, opts)
        local options = opts or {}
        local lethal = (damage or ZERO) >= (targetHp or MIN_HP)
        if lethal then
            return true
        end
        if options.requireLethalOnly then
            return false
        end
        if options.includeFinishers == false then
            return false
        end
        return self:isDoomedFinisherAttack(specialUsed, wouldLeaveAt1HP)
    end

    function aiClass:getDoomedAttackPriority(state, ownHub, unit, target, damage, specialUsed, wouldLeaveAt1HP, movePos, targetHp)
        local attackConfig = self:getScoreConfig().ATTACK_DECISION or {}
        local defaultAttackConfig = DEFAULT_SCORE_PARAMS.ATTACK_DECISION or {}

        local damageMult = valueOr(attackConfig.DAMAGE_MULT, defaultAttackConfig.DAMAGE_MULT or ZERO)
        local specialBonus = valueOr(attackConfig.SPECIAL_FINISH_BONUS, defaultAttackConfig.SPECIAL_FINISH_BONUS or ZERO)
        local nearDeathBonus = valueOr(attackConfig.NEAR_DEATH_FINISH_BONUS, defaultAttackConfig.NEAR_DEATH_FINISH_BONUS or ZERO)
        local doomedKillBonus = valueOr(attackConfig.DOOMED_KILL_BONUS, valueOr(defaultAttackConfig.DOOMED_KILL_BONUS, 220))
        local distanceFallback = valueOr(attackConfig.DISTANCE_FALLBACK, defaultAttackConfig.DISTANCE_FALLBACK or ZERO)

        local distToOwnHub = distanceFallback
        if ownHub and target and target.row and target.col then
            distToOwnHub = math.abs(target.row - ownHub.row) + math.abs(target.col - ownHub.col)
        end
        local effectiveTargetHp = targetHp or (target and (target.currentHp or target.startingHp or MIN_HP)) or MIN_HP

        local priority = (damage or ZERO) * damageMult
        if specialUsed then
            priority = priority + specialBonus
        end
        if wouldLeaveAt1HP then
            priority = priority + nearDeathBonus
        end
        if (damage or ZERO) >= effectiveTargetHp then
            priority = priority + doomedKillBonus + (self:getTargetPriority(target) or ZERO)
        end
        priority = priority - distToOwnHub

        if movePos then
            priority = priority - self:calculateCommanderExposurePenalty(state, unit, movePos)
        end

        return priority, distToOwnHub
    end

    -- Find direct attacks for units that are likely to die next turn.
end

return M
