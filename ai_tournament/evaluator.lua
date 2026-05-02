local earlyPlanner = require("ai_tournament.early_planner")
local drawPressure = require("ai_tournament.draw_pressure")

local M = {}

local UNIT_VALUE_FALLBACK = {
    Commandant = 150,
    Artillery = 90,
    Crusher = 80,
    Earthstalker = 75,
    Cloudstriker = 75,
    Bastion = 70,
    Wingstalker = 45,
    Healer = 40,
    Rock = 0
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function bool(value)
    return value == true
end

local function isPipelineV2EarlyRuntime(ctx)
    if not (ctx and ctx.phase and ctx.phase.early == true) then
        return false
    end
    return ctx.pipelineV2Runtime == true
        or (ctx.stats and ctx.stats.pipelineV2Enabled == true)
end

local function bumpStat(ctx, key)
    if not (ctx and ctx.stats and key) then
        return
    end
    ctx.stats[key] = num(ctx.stats[key], 0) + 1
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local clone = {}
    seen[value] = clone
    for key, child in pairs(value) do
        clone[deepCopy(key, seen)] = deepCopy(child, seen)
    end
    return clone
end

local function copyArray(values)
    local out = {}
    for i = 1, #(values or {}) do
        out[i] = values[i]
    end
    return out
end

local function getOpponent(ai, playerId)
    if ai and ai.getOpponentPlayer then
        return ai:getOpponentPlayer(playerId)
    end
    return playerId == 1 and 2 or 1
end

local function isHubUnit(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        return ai:isHubUnit(unit)
    end
    return unit.name == "Commandant"
end

local function isObstacleUnit(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        return ai:isObstacleUnit(unit)
    end
    return unit.name == "Rock" or unit.player == 0
end

local function getUnitAtPosition(ai, state, row, col)
    if ai and ai.getUnitAtPosition then
        return ai:getUnitAtPosition(state, row, col)
    end

    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end
    return nil
end

local function buildHubAsUnit(state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not hub then
        return nil
    end
    return {
        name = "Commandant",
        player = playerId,
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }
end

local function getUnitValue(ai, unit, state)
    if not unit then
        return 0
    end
    if ai and ai.getUnitBaseValue then
        local ok, value = pcall(ai.getUnitBaseValue, ai, unit, state)
        if ok and value ~= nil then
            return num(value, 0)
        end
    end
    return num(UNIT_VALUE_FALLBACK[unit.name], 25)
end

local function calculateDamage(ai, attacker, target)
    if not attacker or not target or not ai or not ai.calculateDamage then
        return 0
    end
    local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
    if not ok then
        return 0
    end
    return math.max(0, num(value, 0))
end

local function canAttackCell(ai, state, unit, row, col)
    if not ai or not ai.getValidAttackCells or not unit then
        return false
    end
    local cells = ai:getValidAttackCells(state, unit.row, unit.col) or {}
    for _, cell in ipairs(cells) do
        if cell.row == row and cell.col == col then
            return true
        end
    end
    return false
end

local function buildQuickHubThreat(ai, state, playerToProtect, attackerPlayer, ctx)
    local threat = {
        playerToProtect = playerToProtect,
        attackerPlayer = attackerPlayer,
        immediateDanger = false,
        immediateLethal = false,
        projectedDamage = 0,
        maxSingleDamage = 0,
        damagingAttackers = {},
        lethalAttackers = {},
        reasons = {}
    }

    if not state or not playerToProtect or not attackerPlayer then
        return threat
    end

    local hub = state.commandHubs and state.commandHubs[playerToProtect]
    if not hub then
        threat.reasons[#threat.reasons + 1] = "missing_hub"
        return threat
    end
    threat.hub = {
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }

    local prepared = state
    if ai and ai.prepareStateForPlayerTurn then
        prepared = ai:prepareStateForPlayerTurn(state, attackerPlayer, {
            resetActionCount = true,
            resetDeployment = true,
            resetFirstActionRangedAttack = true
        })
    end

    local hubAsUnit = buildHubAsUnit(prepared, playerToProtect)
    local hubHp = num(hubAsUnit and (hubAsUnit.currentHp or hubAsUnit.startingHp), 0)

    local attackers = nil
    if ctx and ctx.threatModel and ctx.threatModel.findCommandantAttackers then
        attackers = ctx.threatModel.findCommandantAttackers(ai, prepared, attackerPlayer, playerToProtect, ctx)
    end
    attackers = attackers or {}

    for _, entry in ipairs(attackers) do
        local damage = num(entry and entry.damage, 0)
        threat.projectedDamage = threat.projectedDamage + damage
        threat.maxSingleDamage = math.max(threat.maxSingleDamage, damage)
        threat.damagingAttackers[#threat.damagingAttackers + 1] = deepCopy(entry)
        if damage >= hubHp and hubHp > 0 then
            threat.lethalAttackers[#threat.lethalAttackers + 1] = deepCopy(entry)
        end
    end

    threat.immediateDanger = #threat.damagingAttackers > 0
    threat.immediateLethal = #threat.lethalAttackers > 0 or (hubHp > 0 and threat.projectedDamage >= hubHp)

    if threat.immediateDanger then
        threat.reasons[#threat.reasons + 1] = "direct_attackers_detected"
    end
    if threat.immediateLethal then
        threat.reasons[#threat.reasons + 1] = "direct_lethal_projection"
    end

    return threat
end

local function buildFullHubThreat(ai, state, playerToProtect, attackerPlayer, ctx)
    if ctx and ctx.cache and ctx.cache.threat then
        return ctx.cache.threat(ai, state, playerToProtect, attackerPlayer, ctx)
    end

    if ctx and ctx.threatModel and ctx.threatModel.analyzeHubThreatForPlayer then
        return ctx.threatModel.analyzeHubThreatForPlayer(ai, state, playerToProtect, attackerPlayer, ctx)
    end

    return buildQuickHubThreat(ai, state, playerToProtect, attackerPlayer, ctx)
end

local function candidateMovesNearOwnHub(candidate, state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not (candidate and hub) then
        return false
    end

    for _, action in ipairs(candidate.actions or {}) do
        if action and action.type == "move" and action.unit then
            local originDistance = math.abs(num(action.unit.row, 0) - num(hub.row, 0))
                + math.abs(num(action.unit.col, 0) - num(hub.col, 0))
            local target = action.target or {}
            local targetDistance = math.abs(num(target.row, 0) - num(hub.row, 0))
                + math.abs(num(target.col, 0) - num(hub.col, 0))
            if originDistance <= 3 or targetDistance <= 3 then
                return true
            end
        end
    end

    return false
end

local function scoreOpenedCommandantPressure(ai, beforeState, afterOurTurn, candidate, ctx)
    if not (ctx and ctx.aiPlayer and ctx.enemyPlayer) then
        return nil
    end
    if not candidateMovesNearOwnHub(candidate, beforeState, ctx.aiPlayer) then
        return nil
    end

    local beforeThreat = buildFullHubThreat(ai, beforeState, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    local afterThreat = buildFullHubThreat(ai, afterOurTurn, ctx.aiPlayer, ctx.enemyPlayer, ctx)
    local beforeDanger = beforeThreat and beforeThreat.immediateDanger == true
    local afterDanger = afterThreat and afterThreat.immediateDanger == true
    local beforeDamage = num(beforeThreat and beforeThreat.projectedDamage, 0)
    local afterDamage = num(afterThreat and afterThreat.projectedDamage, 0)
    if not afterDanger then
        return nil
    end
    if beforeDanger and afterDamage <= beforeDamage then
        return nil
    end

    local cfg = ctx.cfg or {}
    local damageIncrease = math.max(0, afterDamage - beforeDamage)
    local penalty = num(cfg.OPEN_COMMANDANT_PRESSURE_PENALTY, 28000)
        + math.max(afterDamage, damageIncrease) * num(cfg.OPEN_COMMANDANT_PRESSURE_DAMAGE_WEIGHT, 4200)
    if afterThreat and afterThreat.immediateLethal == true then
        penalty = penalty + num(cfg.OPEN_COMMANDANT_PRESSURE_LETHAL_BONUS, 70000)
    end

    return {
        penalty = penalty,
        beforeDamage = beforeDamage,
        afterDamage = afterDamage,
        damageIncrease = damageIncrease,
        lethal = afterThreat and afterThreat.immediateLethal == true,
        reasons = afterThreat and afterThreat.reasons or {}
    }
end

local function exposedValueForSide(ai, state, defenderPlayer, attackerPlayer)
    local prepared = state
    if ai and ai.prepareStateForPlayerTurn then
        prepared = ai:prepareStateForPlayerTurn(state, attackerPlayer, {
            resetActionCount = true,
            resetDeployment = true,
            resetFirstActionRangedAttack = true
        })
    end

    local total = 0
    for _, unit in ipairs((prepared and prepared.units) or {}) do
        if unit
            and unit.player == defenderPlayer
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit) then
            local hp = num(unit.currentHp or unit.startingHp, 1)
            local threatenedDamage = 0
            local maxDamage = 0

            for _, enemy in ipairs((prepared and prepared.units) or {}) do
                if enemy
                    and enemy.player == attackerPlayer
                    and not isHubUnit(ai, enemy)
                    and not isObstacleUnit(ai, enemy) then
                    local canDamage = false
                    if ai and ai.canUnitDamageTargetFromPosition then
                        canDamage = ai:canUnitDamageTargetFromPosition(
                            prepared,
                            enemy,
                            unit,
                            enemy.row,
                            enemy.col,
                            {requirePositiveDamage = true}
                        ) == true
                    else
                        canDamage = canAttackCell(ai, prepared, enemy, unit.row, unit.col)
                    end

                    if canDamage then
                        local damage = calculateDamage(ai, enemy, unit)
                        if damage > 0 then
                            threatenedDamage = threatenedDamage + damage
                            if damage > maxDamage then
                                maxDamage = damage
                            end
                        end
                    end
                end
            end

            if threatenedDamage > 0 then
                local unitValue = getUnitValue(ai, unit, prepared)
                local ratio = math.min(1, threatenedDamage / math.max(1, hp))
                local weighted = unitValue * (0.4 + ratio * 0.6)
                if maxDamage >= hp then
                    weighted = weighted + (unitValue * 0.5)
                end
                total = total + weighted
            end
        end
    end

    return total
end

local function countMaterialAndUnits(ai, state, playerId)
    local material = 0
    local count = 0

    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit) then
            local hp = num(unit.currentHp or unit.startingHp, 0)
            if hp > 0 then
                material = material + getUnitValue(ai, unit, state)
                count = count + 1
            end
        end
    end

    return material, count
end

local function hasDamagedFriendlyCombatUnit(ai, state, playerId)
    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit) then
            local hp = num(unit.currentHp or unit.startingHp, 0)
            local maxHp = num(unit.startingHp, hp)
            if hp > 0 and hp < maxHp then
                return true
            end
        end
    end
    return false
end

local function distance(rowA, colA, rowB, colB)
    return math.abs(num(rowA, 0) - num(rowB, 0)) + math.abs(num(colA, 0) - num(colB, 0))
end

local function positionalScoreForSide(ai, state, playerId, enemyPlayer)
    local score = 0
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local centerRow, centerCol = 4.5, 4.5

    local units = (state and state.units) or {}
    for _, unit in ipairs(units) do
        if unit
            and unit.player == playerId
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit) then
            if enemyHub then
                local dEnemy = distance(unit.row, unit.col, enemyHub.row, enemyHub.col)
                score = score + math.max(0, (9 - dEnemy) * 8)
            end

            local dCenter = math.abs(num(unit.row, 0) - centerRow) + math.abs(num(unit.col, 0) - centerCol)
            score = score + math.max(0, (6 - dCenter) * 4)

            if ownHub then
                local dOwn = distance(unit.row, unit.col, ownHub.row, ownHub.col)
                if dOwn > 5 then
                    score = score - ((dOwn - 5) * 2)
                end
            end

            local support = 0
            for _, ally in ipairs(units) do
                if ally
                    and ally ~= unit
                    and ally.player == playerId
                    and not isHubUnit(ai, ally)
                    and not isObstacleUnit(ai, ally) then
                    if distance(unit.row, unit.col, ally.row, ally.col) == 1 then
                        support = support + 1
                    end
                end
            end

            score = score + (support * 6)
            if support == 0 then
                score = score - 8
            end
        end
    end

    return score
end

local function closestOwnUnitDistanceToEnemyHub(ai, state, playerId, enemyPlayer)
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    if not enemyHub then
        return 99
    end

    local best = 99
    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit) then
            local dEnemy = distance(unit.row, unit.col, enemyHub.row, enemyHub.col)
            if dEnemy < best then
                best = dEnemy
            end
        end
    end

    return best
end

local function commandantPressureScore(ownThreatToEnemy)
    if not ownThreatToEnemy then
        return 0
    end

    local score = num(ownThreatToEnemy.projectedDamage, 0) * 180
    score = score + #((ownThreatToEnemy.damagingAttackers) or {}) * 60
    if ownThreatToEnemy.immediateDanger then
        score = score + 120
    end
    if ownThreatToEnemy.immediateLethal then
        score = score + 800
    end
    return score
end

local function getTargetPlayerAt(beforeState, row, col)
    for _, unit in ipairs((beforeState and beforeState.units) or {}) do
        if unit and unit.row == row and unit.col == col then
            return num(unit.player, 0)
        end
    end

    for playerId = 1, 2 do
        local hub = beforeState and beforeState.commandHubs and beforeState.commandHubs[playerId]
        if hub and hub.row == row and hub.col == col then
            return playerId
        end
    end

    return 0
end

local function getTargetUnitForAction(ai, beforeState, action)
    local target = action and action.target
    if not target then
        return nil
    end

    local unit = getUnitAtPosition(ai, beforeState, target.row, target.col)
    if unit then
        return unit
    end

    for playerId = 1, 2 do
        local hub = beforeState and beforeState.commandHubs and beforeState.commandHubs[playerId]
        if hub and hub.row == target.row and hub.col == target.col then
            return buildHubAsUnit(beforeState, playerId)
        end
    end

    return nil
end

local function isFactionInteractionAttackAction(beforeState, action, actingPlayer)
    if not action or action.type ~= "attack" or not action.target then
        return false
    end
    local targetPlayer = getTargetPlayerAt(beforeState, action.target.row, action.target.col)
    return targetPlayer > 0 and targetPlayer ~= num(actingPlayer, 0)
end

local function candidateHasFactionInteractionAttack(beforeState, candidate, actingPlayer)
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if isFactionInteractionAttackAction(beforeState, action, actingPlayer) then
            return true
        end
    end
    return false
end

local function candidateHasDamagingFactionInteractionAttack(ai, beforeState, candidate, actingPlayer)
    local currentState = beforeState
    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "attack" and currentState then
            if isFactionInteractionAttackAction(currentState, action, actingPlayer) then
                local attacker = getUnitAtPosition(ai, currentState, action.unit and action.unit.row, action.unit and action.unit.col)
                local target = getTargetUnitForAction(ai, currentState, action)
                if calculateDamage(ai, attacker, target) > 0 then
                    return true
                end
            end
        end

        if action and action.type and action.type ~= "skip" and currentState then
            if ai and ai.simulateActionSequenceForPlayer then
                currentState = ai:simulateActionSequenceForPlayer(currentState, {action}, actingPlayer, {})
            else
                currentState = nil
            end
        end
    end
    return false
end

local function candidateIsPassiveOnly(candidate, beforeState, actingPlayer)
    local actions = (candidate and candidate.actions) or {}
    if #actions == 0 then
        return true
    end

    for _, action in ipairs(actions) do
        local actionType = action and action.type or "unknown"
        if actionType == "attack" then
            if isFactionInteractionAttackAction(beforeState, action, actingPlayer) then
                return false
            end
            -- Neutral/rock attacks are not faction interaction and should still
            -- be treated as passive for draw/conversion pressure purposes.
        elseif actionType ~= "move"
            and actionType ~= "supply_deploy"
            and actionType ~= "repair"
            and actionType ~= "skip" then
            return false
        end
    end

    return true
end

local function buildOfficialDrawUrgency(ai, beforeState)
    return drawPressure.build(ai, beforeState)
end

local function scoreOfficialAntiDraw(ai, beforeState, candidate, ctx)
    local _ = ctx
    local urgencyState = buildOfficialDrawUrgency(ai, beforeState)
    if not urgencyState.active then
        return {
            active = false,
            value = 0,
            streak = urgencyState.streak,
            urgency = urgencyState.urgency,
            hasFactionAttack = false,
            countFromFullTurn = urgencyState.countFromFullTurn,
            noInteractionLimit = urgencyState.noInteractionLimit
        }
    end

    local streak = urgencyState.streak
    local limit = urgencyState.noInteractionLimit
    local hasFactionAttack = candidateHasDamagingFactionInteractionAttack(ai, beforeState, candidate, ctx and ctx.aiPlayer)
    local urgency = urgencyState.urgency
    local preWindow = urgencyState.preWindow
    local nearLimit = urgencyState.nearLimit == true
    local criticalLimit = urgencyState.criticalLimit == true
    local scale = preWindow and 0.70 or 1.0

    local value = 0
    if hasFactionAttack then
        value = 220 + (streak * 220) + (urgency * 600)
        if nearLimit then
            value = value + 1100
        end
        if criticalLimit then
            value = value + 1300
        end
    else
        value = -(
            160
            + (streak * 170)
            + (urgency * 720)
        )
        if nearLimit then
            value = value - 1500
        end
        if criticalLimit then
            value = value - 1700
        end
    end
    value = value * scale

    return {
        active = true,
        preWindow = preWindow,
        value = value,
        streak = streak,
        urgency = urgency,
        hasFactionAttack = hasFactionAttack,
        countFromFullTurn = urgencyState.countFromFullTurn,
        noInteractionLimit = limit,
        nearStreak = urgencyState.nearStreak,
        criticalStreak = urgencyState.criticalStreak,
        nearLimit = nearLimit,
        criticalLimit = criticalLimit
    }
end

local function buildConversionDiagnostics(before, after, candidate, attackImpact, antiDraw, ctx)
    local cfg = (ctx and ctx.cfg) or {}
    local materialAdvMin = num(cfg.CONVERSION_MATERIAL_ADV_MIN, 50)
    local unitAdvMin = num(cfg.CONVERSION_UNIT_ADV_MIN, 1)
    local drawStreakMin = num(cfg.CONVERSION_DRAW_STREAK_MIN, 2)
    local drawEarlyStreakMin = num(cfg.CONVERSION_DRAW_STREAK_EARLY_MIN, math.max(1, drawStreakMin - 1))
    local enemyHubHpMax = num(cfg.CONVERSION_ENEMY_HUB_HP_MAX, 8)
    local commandantPressureMin = num(cfg.CONVERSION_COMMANDANT_PRESSURE_MIN, 220)
    local lowEnemyUnitCountMax = num(cfg.CONVERSION_LOW_UNIT_COUNT_MAX, 2)
    local criticalEnemyHubHp = num(cfg.CONVERSION_FINISH_CRITICAL_HUB_HP_MAX, 4)
    local lastEnemyUnitMax = num(cfg.CONVERSION_LAST_ENEMY_UNIT_MAX, 1)

    local materialDiff = num(before and before.materialDiff, 0)
    local ownUnits = num(before and before.ownUnitCount, 0)
    local enemyUnits = num(before and before.enemyUnitCount, 0)
    local ownHubHp = num(before and before.ownHubHp, 0)
    local enemyHubHp = num(before and before.enemyHubHp, 0)
    local commandantPressure = num(before and before.commandantPressure, 0)
    local drawStreak = num(antiDraw and antiDraw.streak, 0)
    local drawUrgency = num(antiDraw and antiDraw.urgency, 0)
    local drawActive = antiDraw and antiDraw.active == true
    local nowFactionAttackOptions = num(before and before.availableFactionAttackActions, 0)
    local nextFactionAttackOptions = num(after and after.availableFactionAttackActions, 0)
    local nowCommandantAttackOptions = num(before and before.availableCommandantAttackActions, 0)
    local nextCommandantAttackOptions = num(after and after.availableCommandantAttackActions, 0)
    local nowKillAttackOptions = num(before and before.availableKillAttackActions, 0)
    local nextKillAttackOptions = num(after and after.availableKillAttackActions, 0)
    local nowHighValueKillAttackOptions = num(before and before.availableHighValueKillAttackActions, 0)
    local nextHighValueKillAttackOptions = num(after and after.availableHighValueKillAttackActions, 0)

    local convertWinningPosition = materialDiff >= materialAdvMin or (ownUnits - enemyUnits) >= unitAdvMin
    local breakDrawClock = drawActive and (
        drawStreak >= drawStreakMin
        or drawUrgency > 0
        or (drawStreak >= drawEarlyStreakMin and nowFactionAttackOptions > 0)
    )
    local forceCommandantPressure = enemyHubHp > 0
        and (
            enemyHubHp <= enemyHubHpMax
            or commandantPressure >= commandantPressureMin
            or nowCommandantAttackOptions > 0
            or nextCommandantAttackOptions > 0
            or (convertWinningPosition and num(attackImpact and attackImpact.damagingFactionAttackCount, 0) > 0)
            or (breakDrawClock and num(attackImpact and attackImpact.damagingFactionAttackCount, 0) > 0)
            or (drawActive and drawStreak >= drawEarlyStreakMin and (nowFactionAttackOptions > 0 or nextFactionAttackOptions > 0))
        )
    local eliminateLowHpUnit = enemyUnits <= lowEnemyUnitCountMax
        or num(attackImpact and attackImpact.expectedKillValue, 0) >= num(cfg.CONVERSION_KILL_VALUE_MIN, 60)
        or (enemyUnits <= (lowEnemyUnitCountMax + 1) and (nowFactionAttackOptions > 0 or nextFactionAttackOptions > 0))
        or (drawActive and drawStreak >= drawEarlyStreakMin and enemyUnits <= (lastEnemyUnitMax + 1))
    local finishWindow = enemyHubHp > 0 and (
        enemyHubHp <= num(cfg.CONVERSION_FINISH_ENEMY_HUB_HP_MAX, 7)
        or enemyUnits <= num(cfg.CONVERSION_FINISH_ENEMY_UNITS_MAX, 1)
        or materialDiff >= num(cfg.CONVERSION_FINISH_MATERIAL_ADV_MIN, 120)
        or (drawActive and drawStreak >= drawEarlyStreakMin and nowFactionAttackOptions > 0)
    )
    local criticalCommandantWindow = enemyHubHp > 0 and enemyHubHp <= criticalEnemyHubHp
    local lastEnemyUnitWindow = enemyUnits <= lastEnemyUnitMax

    local contractActive = convertWinningPosition
        or breakDrawClock
        or forceCommandantPressure
        or eliminateLowHpUnit
        or finishWindow
    local hasFactionAttack = num(attackImpact and attackImpact.damagingFactionAttackCount, 0) > 0
    local setupCreatesRealThreat = not hasFactionAttack
        and (
            nextCommandantAttackOptions > nowCommandantAttackOptions
            or nextKillAttackOptions > nowKillAttackOptions
            or nextHighValueKillAttackOptions > nowHighValueKillAttackOptions
            or (after and after.enemyHubThreat and after.enemyHubThreat.immediateLethal == true)
            or (
                forceCommandantPressure
                and num(after and after.commandantPressure, 0) > num(before and before.commandantPressure, 0)
            )
        )
    local setupChosen = not hasFactionAttack
        and setupCreatesRealThreat
        and (
            nextFactionAttackOptions > nowFactionAttackOptions
            or nextCommandantAttackOptions > nowCommandantAttackOptions
            or nextKillAttackOptions > nowKillAttackOptions
        )
    local chosen = contractActive and (hasFactionAttack or setupChosen)
    local missReason = nil
    if contractActive and not hasFactionAttack then
        if setupChosen then
            missReason = nil
        elseif candidate and candidate.passiveOnly and candidate.containsDeploy then
            missReason = "deploy_rebuild_under_conversion_pressure"
        elseif candidate and candidate.passiveOnly and (criticalCommandantWindow or lastEnemyUnitWindow or breakDrawClock) then
            missReason = "passive_line_under_finish_or_draw_pressure"
        elseif candidate and candidate.passiveOnly then
            missReason = "passive_line_under_conversion_pressure"
        elseif candidate and candidate.containsDeploy then
            missReason = "deploy_rebuild_under_conversion_pressure"
        elseif candidate and (not setupCreatesRealThreat) and (criticalCommandantWindow or lastEnemyUnitWindow or breakDrawClock or forceCommandantPressure) then
            missReason = "setup_without_real_threat_progress"
        elseif forceCommandantPressure and nowCommandantAttackOptions > 0 and nextCommandantAttackOptions <= nowCommandantAttackOptions then
            missReason = "commandant_pressure_not_improved"
        elseif eliminateLowHpUnit and nowKillAttackOptions > 0 and nextKillAttackOptions <= nowKillAttackOptions then
            missReason = "kill_window_not_improved"
        else
            missReason = "conversion_opportunity_not_attacked"
        end
    end

    return {
        contractActive = contractActive,
        convertWinningPosition = convertWinningPosition,
        breakDrawClock = breakDrawClock,
        forceCommandantPressure = forceCommandantPressure,
        eliminateLowHpUnit = eliminateLowHpUnit,
        opportunity = contractActive,
        chosen = chosen,
        setupChosen = setupChosen,
        missReason = missReason,
        hasFactionAttack = hasFactionAttack,
        finishWindow = finishWindow,
        criticalCommandantWindow = criticalCommandantWindow,
        lastEnemyUnitWindow = lastEnemyUnitWindow,
        materialDiff = materialDiff,
        ownUnits = ownUnits,
        enemyUnits = enemyUnits,
        ownHubHp = ownHubHp,
        enemyHubHp = enemyHubHp,
        commandantPressure = commandantPressure,
        availableFactionAttackOptions = nowFactionAttackOptions,
        availableCommandantAttackOptions = nowCommandantAttackOptions,
        availableKillAttackOptions = nowKillAttackOptions,
        availableHighValueKillAttackOptions = nowHighValueKillAttackOptions,
        nextFactionAttackOptions = nextFactionAttackOptions,
        nextCommandantAttackOptions = nextCommandantAttackOptions,
        nextKillAttackOptions = nextKillAttackOptions,
        nextHighValueKillAttackOptions = nextHighValueKillAttackOptions,
        drawStreak = drawStreak,
        drawUrgency = drawUrgency,
        setupCreatesRealThreat = setupCreatesRealThreat,
        selectedCommandantDamage = num(attackImpact and attackImpact.commandantDamage, 0),
        selectedKillCount = num(attackImpact and attackImpact.expectedKills, 0),
        createsNextTurnCommandantLethal = after and after.enemyHubThreat and after.enemyHubThreat.immediateLethal == true,
        removesEnemyLastAttacker = num(before and before.ownHubThreat and before.ownHubThreat.projectedDamage, 0) > 0
            and num(after and after.ownHubThreat and after.ownHubThreat.projectedDamage, 0) <= 0
    }
end

local function evaluateFactionAttackImpact(ai, beforeState, candidate, actingPlayer)
    local enemyPlayer = getOpponent(ai, actingPlayer)
    local impact = {
        attackCount = 0,
        factionAttackCount = 0,
        damagingFactionAttackCount = 0,
        zeroDamageFactionAttackCount = 0,
        commandantAttackCount = 0,
        totalDamage = 0,
        commandantDamage = 0,
        unitDamage = 0,
        expectedKills = 0,
        expectedKillValue = 0
    }

    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "attack" then
            impact.attackCount = impact.attackCount + 1
            if isFactionInteractionAttackAction(beforeState, action, actingPlayer) then
                impact.factionAttackCount = impact.factionAttackCount + 1
                local attacker = getUnitAtPosition(ai, beforeState, action.unit and action.unit.row, action.unit and action.unit.col)
                local target = getTargetUnitForAction(ai, beforeState, action)
                local damage = calculateDamage(ai, attacker, target)
                local targetHp = num(target and (target.currentHp or target.startingHp), 0)
                local targetValue = getUnitValue(ai, target, beforeState)
                local isCommandant = target and target.player == enemyPlayer and isHubUnit(ai, target)

                impact.totalDamage = impact.totalDamage + damage
                if damage > 0 then
                    impact.damagingFactionAttackCount = impact.damagingFactionAttackCount + 1
                else
                    impact.zeroDamageFactionAttackCount = impact.zeroDamageFactionAttackCount + 1
                end
                if isCommandant then
                    impact.commandantAttackCount = impact.commandantAttackCount + 1
                    impact.commandantDamage = impact.commandantDamage + damage
                else
                    impact.unitDamage = impact.unitDamage + damage
                end

                if targetHp > 0 and damage >= targetHp then
                    impact.expectedKills = impact.expectedKills + 1
                    impact.expectedKillValue = impact.expectedKillValue + targetValue
                end
            end
        end
    end

    return impact
end

local function countImmediateFactionAttackOptions(ai, state, actingPlayer, ctx)
    local result = {
        total = 0,
        commandant = 0,
        kills = 0,
        highValueKills = 0,
        maxKillValue = 0
    }
    if not (ai and state and actingPlayer and ai.collectLegalActions) then
        return result
    end

    local turnState = state
    if ai.prepareStateForPlayerTurn then
        turnState = ai:prepareStateForPlayerTurn(state, actingPlayer, {
            resetDeployment = true,
            resetActionCount = true,
            resetFirstActionRangedAttack = true
        })
    end

    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local legalOpts = {
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false,
        allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    }
    local entries = nil
    if ctx and ctx.cache and ctx.cache.legalActions then
        entries = ctx.cache.legalActions(ai, turnState, actingPlayer, ctx, legalOpts)
    else
        entries = ai:collectLegalActions(turnState, {
            aiPlayer = actingPlayer,
            includeMove = legalOpts.includeMove,
            includeAttack = legalOpts.includeAttack,
            includeRepair = legalOpts.includeRepair,
            includeDeploy = legalOpts.includeDeploy,
            allowFullHpHealerRepairException = legalOpts.allowFullHpHealerRepairException
        }) or {}
    end

    local enemyPlayer = getOpponent(ai, actingPlayer)
    local highValueKillMin = num((ctx and ctx.cfg and ctx.cfg.CONVERSION_KILL_VALUE_MIN), 60)
    for _, entry in ipairs(entries) do
        local action = entry and entry.action or nil
        if isFactionInteractionAttackAction(turnState, action, actingPlayer) then
            result.total = result.total + 1
            local target = getTargetUnitForAction(ai, turnState, action)
            if target and target.player == enemyPlayer and isHubUnit(ai, target) then
                result.commandant = result.commandant + 1
            end

            local attacker = getUnitAtPosition(ai, turnState, action.unit and action.unit.row, action.unit and action.unit.col)
            local damage = calculateDamage(ai, attacker, target)
            local targetHp = num(target and (target.currentHp or target.startingHp), 0)
            if targetHp > 0 and damage >= targetHp then
                result.kills = result.kills + 1
                local targetValue = getUnitValue(ai, target, turnState)
                result.maxKillValue = math.max(result.maxKillValue, targetValue)
                if targetValue >= highValueKillMin then
                    result.highValueKills = result.highValueKills + 1
                end
            end
        end
    end

    return result
end

local function scoreActionEfficiency(candidate, ctx, beforeState)
    local _ = ctx
    local actions = (candidate and candidate.actions) or {}
    local actionCount = #actions
    local value = 0

    if actionCount >= 2 then
        value = value + 80
    elseif candidate and candidate.terminal then
        value = value + 40
    else
        value = value - 180
    end

    if candidate and candidate.legalSkipReason == "no_legal_continuation" then
        value = value + 20
    end

    local factionAttackCount = 0
    for _, action in ipairs(actions) do
        if action and action.type == "attack" then
            local targetPlayer = getTargetPlayerAt(beforeState, action.target and action.target.row, action.target and action.target.col)
            if targetPlayer > 0 and targetPlayer ~= num(ctx and ctx.aiPlayer, 0) then
                factionAttackCount = factionAttackCount + 1
                value = value + 180
            else
                value = value - 260
            end
        elseif action and action.type == "move" then
            value = value - 8
        elseif action and action.type == "supply_deploy" then
            value = value + 10
        elseif action and action.type == "repair" then
            value = value + 6
        elseif action and action.type == "skip" then
            value = value - 220
        end
    end

    if actionCount >= 2 and factionAttackCount == 0 then
        value = value - 120
    elseif factionAttackCount > 0 then
        value = value + 80
    end

    local buckets = candidate and candidate.buckets or {}
    for _, bucket in ipairs(buckets) do
        if bucket == "anti_lethal" then
            value = value + 40
        elseif bucket == "supply_defense" then
            value = value + 18
        elseif bucket == "supply_offense" then
            value = value + 14
        elseif bucket == "fallback" then
            value = value - 10
        end
    end

    return value
end

local function evaluateSequenceDeployImpact(ai, beforeState, afterState, candidate, ctx)
    local aggregate = {
        value = 0,
        breakdown = {},
        reasons = {}
    }

    if not (ctx and ctx.supplyPlanner and ctx.supplyPlanner.evaluateDeployImpact) then
        return aggregate
    end

    for _, action in ipairs((candidate and candidate.actions) or {}) do
        if action and action.type == "supply_deploy" then
            local impact = ctx.supplyPlanner.evaluateDeployImpact(
                ai,
                beforeState,
                afterState,
                action,
                ctx.aiPlayer,
                ctx,
                {candidate = candidate}
            ) or {value = 0, reasons = {}}

            aggregate.value = aggregate.value + num(impact.value, 0)
            aggregate.breakdown[#aggregate.breakdown + 1] = impact.breakdown or {}
            for _, reason in ipairs(impact.reasons or {}) do
                aggregate.reasons[#aggregate.reasons + 1] = reason
            end
        end
    end

    return aggregate
end

function M.isCommandantDead(state, playerId)
    if not state or not playerId then
        return true
    end

    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if hub and (hub.currentHp or hub.startingHp or 1) <= 0 then
        return true
    end

    local foundCommandant = false
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == playerId and unit.name == "Commandant" then
            foundCommandant = true
            return (unit.currentHp or unit.startingHp or 1) <= 0
        end
    end

    if not hub and not foundCommandant then
        return true
    end

    return false
end

function M.buildStateFeatures(ai, state, playerId, ctx)
    local enemyPlayer = getOpponent(ai, playerId)
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]

    local ownMaterial, ownUnitCount = countMaterialAndUnits(ai, state, playerId)
    local enemyMaterial, enemyUnitCount = countMaterialAndUnits(ai, state, enemyPlayer)

    local ownHubThreat = buildQuickHubThreat(ai, state, playerId, enemyPlayer, ctx)
    local enemyHubThreat = buildQuickHubThreat(ai, state, enemyPlayer, playerId, ctx)

    local ownPos = positionalScoreForSide(ai, state, playerId, enemyPlayer)
    local enemyPos = positionalScoreForSide(ai, state, enemyPlayer, playerId)
    local immediateAttacks = countImmediateFactionAttackOptions(ai, state, playerId, ctx)

    local ownSupply = nil
    local enemySupply = nil
    if ctx and ctx.cache and ctx.cache.supplySnapshot then
        ownSupply = ctx.cache.supplySnapshot(ai, state, playerId, ctx)
        enemySupply = ctx.cache.supplySnapshot(ai, state, enemyPlayer, ctx)
    end
    return {
        playerId = playerId,
        enemyPlayer = enemyPlayer,
        ownHub = deepCopy(ownHub),
        enemyHub = deepCopy(enemyHub),
        ownHubHp = num(ownHub and (ownHub.currentHp or ownHub.startingHp), 0),
        enemyHubHp = num(enemyHub and (enemyHub.currentHp or enemyHub.startingHp), 0),
        ownMaterial = ownMaterial,
        enemyMaterial = enemyMaterial,
        materialDiff = ownMaterial - enemyMaterial,
        ownUnitCount = ownUnitCount,
        enemyUnitCount = enemyUnitCount,
        ownHubThreat = ownHubThreat,
        enemyHubThreat = enemyHubThreat,
        exposedFriendlyValue = exposedValueForSide(ai, state, playerId, enemyPlayer),
        exposedEnemyValue = exposedValueForSide(ai, state, enemyPlayer, playerId),
        commandantPressure = commandantPressureScore(enemyHubThreat),
        availableFactionAttackActions = num(immediateAttacks and immediateAttacks.total, 0),
        availableCommandantAttackActions = num(immediateAttacks and immediateAttacks.commandant, 0),
        availableKillAttackActions = num(immediateAttacks and immediateAttacks.kills, 0),
        availableHighValueKillAttackActions = num(immediateAttacks and immediateAttacks.highValueKills, 0),
        closestOwnUnitToEnemyHub = closestOwnUnitDistanceToEnemyHub(ai, state, playerId, enemyPlayer),
        position = ownPos - enemyPos,
        supply = {
            own = ownSupply,
            enemy = enemySupply
        }
    }
end

function M.scoreStateForPlayer(ai, referenceState, state, playerId, ctx)
    local ref = nil
    local cur = nil

    if ctx and ctx.cache and ctx.cache.features then
        ref = ctx.cache.features(ai, referenceState, playerId, ctx)
        cur = ctx.cache.features(ai, state, playerId, ctx)
    else
        ref = M.buildStateFeatures(ai, referenceState, playerId, ctx)
        cur = M.buildStateFeatures(ai, state, playerId, ctx)
    end

    local value = 0
    value = value + (num(cur.materialDiff, 0) - num(ref.materialDiff, 0)) * 100
    value = value + (num(ref.ownHubHp, 0) - num(cur.ownHubHp, 0)) * -500
    value = value + (num(ref.enemyHubHp, 0) - num(cur.enemyHubHp, 0)) * 600
    value = value + (num(cur.commandantPressure, 0) - num(ref.commandantPressure, 0)) * 2
    value = value + (num(cur.position, 0) - num(ref.position, 0)) * 10
    value = value - math.max(0, num(cur.exposedFriendlyValue, 0) - num(ref.exposedFriendlyValue, 0)) * 12

    return {
        value = value,
        reference = ref,
        current = cur
    }
end

function M.scoreOwnTurnFast(ai, beforeState, afterOurTurn, candidate, ctx)
    local score = ctx.score.new(candidate and candidate.signature or "")
    score.breakdown = {
        reasons = {}
    }

    local before = ctx.cache.features(ai, beforeState, ctx.aiPlayer, ctx)
    local after = ctx.cache.features(ai, afterOurTurn, ctx.aiPlayer, ctx)

    if M.isCommandantDead(afterOurTurn, ctx.enemyPlayer) then
        score.tier = ctx.score.TIER.WIN_NOW
        score.terminal = 1000000
        score.breakdown.terminal = "enemy_commandant_dead"
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "immediate_win"
        return ctx.score.finalize(score)
    end

    if M.isCommandantDead(afterOurTurn, ctx.aiPlayer) then
        score.tier = ctx.score.TIER.INVALID
        score.terminal = -1000000
        score.breakdown.terminal = "own_commandant_dead"
        return ctx.score.finalize(score)
    end

    if candidate and candidate.tacticalTags and candidate.tacticalTags.preventsImmediateLoss then
        score.tier = math.max(score.tier, ctx.score.TIER.AVOID_LOSS)
        score.survival = score.survival + 50000
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "prevents_immediate_loss"
    end

    if candidate and candidate.tacticalTags and candidate.tacticalTags.defensiveThreatRemovalSetup then
        local setupDamage = num(candidate.tacticalTags.threatRemovalSetupDamage, 0)
        local setupBonus = num((ctx and ctx.cfg and ctx.cfg.DEFENSIVE_THREAT_REMOVAL_SETUP_BONUS), 5200)
            + (setupDamage * num((ctx and ctx.cfg and ctx.cfg.DEFENSIVE_THREAT_REMOVAL_SETUP_DAMAGE_WEIGHT), 1600))
            + math.max(0, num(candidate.tacticalTags.threatRemovalSetupDeployScore, 0)) * 0.35
        if candidate.tacticalTags.threatRemovalSetupLethal == true then
            setupBonus = setupBonus
                + num((ctx and ctx.cfg and ctx.cfg.DEFENSIVE_THREAT_REMOVAL_SETUP_LETHAL_BONUS), 2600)
        end
        score.survival = score.survival + setupBonus
        score.force = score.force + math.floor(setupBonus * 0.20)
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "defensive_threat_removal_setup"
        score.breakdown.defensiveThreatRemovalSetup = {
            damage = setupDamage,
            lethal = candidate.tacticalTags.threatRemovalSetupLethal == true,
            unit = candidate.tacticalTags.threatRemovalSetupUnit,
            target = candidate.tacticalTags.threatRemovalSetupTarget,
            bonus = setupBonus
        }
    end

    if candidate and candidate.tacticalTags and candidate.tacticalTags.defenseRaceProof then
        local proof = tostring(candidate.tacticalTags.defenseRaceProof or "")
        local eta = num(candidate.tacticalTags.defenseRaceBestETA, 99)
        local projectedDelta = math.max(0, num(candidate.tacticalTags.defenseRaceProjectedDamageDelta, 0))
        local attackerDelta = math.max(0, num(candidate.tacticalTags.defenseRaceAttackerDelta, 0))
        local baseBonus = 0
        if proof == "immediate_removal" then
            baseBonus = 17000
        elseif proof == "focus_fire" then
            baseBonus = 15000
        elseif proof == "reinforce_eta1" then
            baseBonus = 6200
        elseif proof == "evacuate_blocker" then
            baseBonus = 5600
        elseif proof == "ranged_line_block" then
            baseBonus = 5400
        elseif proof == "reinforce_eta_gt1" then
            baseBonus = 3600
        elseif proof == "win_race" then
            baseBonus = 7000
        elseif proof == "reduced_projected_pressure" then
            baseBonus = 3200
        end

        if baseBonus > 0 then
            local etaBonus = math.max(0, 4 - eta) * 420
            local deltaBonus = (projectedDelta * 700) + (attackerDelta * 500)
            local defenseRaceBonus = baseBonus + etaBonus + deltaBonus
            score.survival = score.survival + defenseRaceBonus
            score.force = score.force + math.floor(defenseRaceBonus * 0.12)
            score.breakdown.reasons[#score.breakdown.reasons + 1] = "defense_race_proof"
            score.breakdown.defenseRace = {
                proof = proof,
                eta = eta,
                projectedDamageDelta = projectedDelta,
                attackerDelta = attackerDelta,
                bonus = defenseRaceBonus
            }
        end
    end

    if candidate and candidate.tacticalTags and candidate.tacticalTags.allowsImmediateLoss then
        score.survival = score.survival - 90000
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "allows_immediate_loss"
    end

    local tags = candidate and candidate.tacticalTags or nil
    if tags and tags.earlyPositionLowValueTarget == true then
        local penalty = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_LOW_VALUE_TARGET_PENALTY, 900)
        local minValue = num(tags.earlyPositionLowValueTargetMin, 0)
        local targetValue = num(tags.earlyPositionLowValueTargetValue, 0)
        local gap = math.max(0, minValue - targetValue)
        local totalPenalty = penalty + gap * 4
        score.position = score.position - totalPenalty
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "early_low_value_target_penalty"
        score.breakdown.earlyLowValueTarget = {
            value = targetValue,
            minValue = minValue,
            penalty = totalPenalty
        }
    end

    local hasDefenseProof = tags
        and (
            tags.preventsImmediateLoss == true
            or tags.defensiveThreatRemovalSetup == true
            or tags.defenseRaceProof ~= nil
            or tags.pressureDefenseProof ~= nil
        )
    local openedPressure = nil
    if not hasDefenseProof then
        openedPressure = scoreOpenedCommandantPressure(ai, beforeState, afterOurTurn, candidate, ctx)
    end
    if openedPressure then
        candidate.tacticalTags = candidate.tacticalTags or {}
        candidate.tacticalTags.opensCommandantPressure = true
        candidate.tacticalTags.openedCommandantPressureDamage = openedPressure.afterDamage
        score.survival = score.survival - num(openedPressure.penalty, 0)
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "opens_commandant_pressure"
        score.breakdown.openedCommandantPressure = {
            beforeDamage = openedPressure.beforeDamage,
            afterDamage = openedPressure.afterDamage,
            damageIncrease = openedPressure.damageIncrease,
            lethal = openedPressure.lethal == true,
            penalty = openedPressure.penalty
        }
    end

    score.commandant = score.commandant
        + (num(before.enemyHubHp, 0) - num(after.enemyHubHp, 0)) * 900
        + (num(after.commandantPressure, 0) - num(before.commandantPressure, 0)) * 360

    score.survival = score.survival
        + (num(before.ownHubThreat and before.ownHubThreat.projectedDamage, 0) - num(after.ownHubThreat and after.ownHubThreat.projectedDamage, 0)) * 700
        + (num(after.ownHubHp, 0) - num(before.ownHubHp, 0)) * 500

    score.material = score.material
        + (num(after.materialDiff, 0) - num(before.materialDiff, 0)) * 100

    score.position = score.position
        + (num(after.position, 0) - num(before.position, 0)) * 95

    score.risk = score.risk
        - math.max(0, num(after.exposedFriendlyValue, 0) - num(before.exposedFriendlyValue, 0)) * 80
        + math.max(0, num(after.exposedEnemyValue, 0) - num(before.exposedEnemyValue, 0)) * 20

    score.efficiency = score.efficiency + scoreActionEfficiency(candidate, ctx, beforeState)

    local attackImpact = evaluateFactionAttackImpact(ai, beforeState, candidate, ctx.aiPlayer)
    local setupAttackDelta = num(after.availableFactionAttackActions, 0) - num(before.availableFactionAttackActions, 0)
    local setupCommandantDelta = num(after.availableCommandantAttackActions, 0) - num(before.availableCommandantAttackActions, 0)
    if setupAttackDelta ~= 0 then
        score.force = score.force + (setupAttackDelta * num((ctx and ctx.cfg and ctx.cfg.SETUP_ATTACK_OPTION_DELTA_WEIGHT), 320))
        if setupAttackDelta > 0 then
            score.breakdown.reasons[#score.breakdown.reasons + 1] = "setup_increases_next_attack_options"
        end
    end
    if setupCommandantDelta ~= 0 then
        score.commandant = score.commandant
            + (setupCommandantDelta * num((ctx and ctx.cfg and ctx.cfg.SETUP_COMMANDANT_OPTION_DELTA_WEIGHT), 720))
        if setupCommandantDelta > 0 then
            score.breakdown.reasons[#score.breakdown.reasons + 1] = "setup_increases_next_commandant_pressure"
        end
    end
    score.force = score.force
        + (num(attackImpact.unitDamage, 0) * 190)
        + (num(attackImpact.expectedKillValue, 0) * 20)
        + (num(attackImpact.damagingFactionAttackCount, 0) * 220)
    score.commandant = score.commandant
        + (num(attackImpact.commandantDamage, 0) * 1100)
        + (num(attackImpact.commandantAttackCount, 0) * 350)
    if num(attackImpact.damagingFactionAttackCount, 0) > 0 then
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "faction_attack_pressure"
    end
    if num(attackImpact.zeroDamageFactionAttackCount, 0) > 0 then
        score.efficiency = score.efficiency - 2600
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "zero_damage_faction_attack_penalty"
    end

    if ctx
        and ctx.phase
        and ctx.phase.early == true
        and tostring(candidate and candidate.combatClass or "") == "low_value_safe_chip" then
        local earlyChipPenalty = num((ctx and ctx.cfg and ctx.cfg.EARLY_LOW_VALUE_CHIP_PENALTY), 4200)
        local containsMove = false
        for _, action in ipairs(candidate.actions or {}) do
            if action and action.type == "move" then
                containsMove = true
                break
            end
        end
        if containsMove then
            earlyChipPenalty = earlyChipPenalty
                + num((ctx and ctx.cfg and ctx.cfg.EARLY_LOW_VALUE_MOVE_ATTACK_EXTRA_PENALTY), 1200)
        end
        score.efficiency = score.efficiency - earlyChipPenalty
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "early_low_value_chip_deferred"
    end

    if ctx
        and ctx.earlyPlan
        and ctx.earlyPlan.active == true
        and not (ctx.activeContracts and ctx.activeContracts.defenseActive == true)
        and not isPipelineV2EarlyRuntime(ctx) then
        local earlyIntentScore = earlyPlanner.scoreCandidate(ai, beforeState, afterOurTurn, candidate, ctx, {
            attackImpact = attackImpact
        })
        if earlyIntentScore and num(earlyIntentScore.value, 0) ~= 0 then
            score.position = score.position + num(earlyIntentScore.value, 0)
            score.breakdown.earlyIntent = earlyIntentScore
            score.breakdown.reasons[#score.breakdown.reasons + 1] = "early_intent_bias"
        elseif earlyIntentScore then
            score.breakdown.earlyIntent = earlyIntentScore
        end
    elseif ctx and ctx.earlyPlan and ctx.earlyPlan.active == true and isPipelineV2EarlyRuntime(ctx) then
        bumpStat(ctx, "pipelineV2EarlyPlannerCandidateScoreSkipped")
    end

    local antiDraw = scoreOfficialAntiDraw(ai, beforeState, candidate, ctx)
    score.efficiency = score.efficiency + num(antiDraw.value, 0)
    score.breakdown.officialDraw = antiDraw
    if antiDraw.active and antiDraw.hasFactionAttack then
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "official_draw_faction_attack_reset"
    elseif antiDraw.active then
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "official_draw_no_interaction_penalty"
    end

    local legalFactionAttackActions = num(ctx and ctx.stats and ctx.stats.legalAttackActions, 0)
    if legalFactionAttackActions > 0 and num(attackImpact.factionAttackCount, 0) == 0 then
        local passivePenalty = 220
            + (num(antiDraw.streak, 0) * 90)
            + (num(antiDraw.urgency, 0) * 180)
        score.efficiency = score.efficiency - passivePenalty
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "ignored_faction_attack_opportunity"
        score.breakdown.ignoredFactionAttackOpportunity = {
            legalFactionAttackActions = legalFactionAttackActions,
            penalty = passivePenalty,
            drawStreak = num(antiDraw.streak, 0),
            urgency = num(antiDraw.urgency, 0)
        }
    end

    local conversion = buildConversionDiagnostics(before, after, candidate, attackImpact, antiDraw, ctx)
    score.breakdown.conversion = conversion
    if conversion.contractActive
        and num(attackImpact.damagingFactionAttackCount, 0) <= 0
        and candidate
        and candidate.containsAttack == true then
        local neutralAttackPenalty = 900
            + (num(conversion.drawStreak, 0) * 110)
            + (num(conversion.drawUrgency, 0) * 220)
        score.efficiency = score.efficiency - neutralAttackPenalty
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_neutral_attack_penalty"
    end
    if num(attackImpact.damagingFactionAttackCount, 0) <= 0
        and candidate
        and candidate.containsAttack == true then
        score.efficiency = score.efficiency - 420
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "neutral_attack_low_value_penalty"
    end
    if conversion.contractActive then
        local bonusScale = 1.0
        if conversion.convertWinningPosition then
            bonusScale = bonusScale + 0.25
        end
        if conversion.breakDrawClock then
            bonusScale = bonusScale + 0.35
        end
        if conversion.forceCommandantPressure then
            bonusScale = bonusScale + 0.30
        end
        if conversion.eliminateLowHpUnit then
            bonusScale = bonusScale + 0.20
        end
        if conversion.finishWindow then
            bonusScale = bonusScale + 0.30
        end

        if conversion.hasFactionAttack then
            local contractLanes = candidate and candidate.contractLanes or {}
            local inDirectCommandantLane = contractLanes and contractLanes.direct_commandant_damage == true
            local inDirectKillLane = contractLanes and contractLanes.direct_kill == true
            local inDrawResetLane = contractLanes and contractLanes.draw_reset_attack == true
            local lowValueChip = tostring(candidate and candidate.combatClass or "") == "low_value_safe_chip"
            local commandantProgress = num(attackImpact.commandantDamage, 0) + math.max(0, setupCommandantDelta) * 2
            local killProgress = num(attackImpact.expectedKills, 0)
            local killOptionsNow = num(conversion.availableKillAttackOptions, 0)
            local commandantOptionsNow = num(conversion.availableCommandantAttackOptions, 0)
            local commandantPressureDelta = num(after.commandantPressure, 0) - num(before.commandantPressure, 0)
            local createsRealThreatNow = commandantProgress > 0
                or killProgress > 0
                or commandantPressureDelta > 0
                or math.max(0, setupAttackDelta) > 0
                or math.max(0, setupCommandantDelta) > 0
                or conversion.createsNextTurnCommandantLethal
            local conversionForceBonus = (
                num(attackImpact.unitDamage, 0) * 140
                + num(attackImpact.expectedKillValue, 0) * 34
                + num(attackImpact.expectedKills, 0) * 980
            ) * bonusScale
            local conversionCommandantBonus = (
                num(attackImpact.commandantDamage, 0) * 2200
                + num(attackImpact.commandantAttackCount, 0) * 1350
            ) * bonusScale
            score.force = score.force + conversionForceBonus
            score.commandant = score.commandant + conversionCommandantBonus

            if conversion.forceCommandantPressure then
                if commandantPressureDelta > 0 then
                    score.commandant = score.commandant + math.floor(commandantPressureDelta * 4.8 * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_commandant_pressure_delta"
                elseif num(attackImpact.commandantDamage, 0) <= 0 then
                    score.efficiency = score.efficiency - math.floor(800 * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_attack_without_commandant_progress"
                end
                if num(attackImpact.commandantDamage, 0) > 0 then
                    score.commandant = score.commandant + math.floor(1450 * bonusScale)
                elseif inDirectCommandantLane then
                    score.commandant = score.commandant + math.floor(900 * bonusScale)
                end
                if commandantProgress <= 0 and killProgress <= 0 then
                    score.efficiency = score.efficiency
                        - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_ATTACK_NO_PROGRESS_PENALTY), 1100) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_commandant_progress_missing_penalty"
                end
                if commandantOptionsNow > 0 and num(attackImpact.commandantDamage, 0) <= 0 and conversion.criticalCommandantWindow then
                    score.efficiency = score.efficiency
                        - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_CRITICAL_COMMANDANT_MISS_PENALTY), 2100) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_missed_available_commandant_hit"
                end
            end

            if conversion.breakDrawClock then
                score.efficiency = score.efficiency + math.floor(720 * bonusScale)
                if inDrawResetLane then
                    score.efficiency = score.efficiency + math.floor(420 * bonusScale)
                end
                if lowValueChip and commandantProgress <= 0 and killProgress <= 0 and setupAttackDelta <= 0 then
                    score.efficiency = score.efficiency
                        - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_LOW_VALUE_CHIP_PENALTY), 900) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_draw_reset_low_value_chip_penalty"
                end
                if lowValueChip and not createsRealThreatNow and num(conversion.drawStreak, 0) >= 2 then
                    score.efficiency = score.efficiency
                        - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_DRAW_PRESSURE_STALE_CHIP_PENALTY), 1700) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_draw_pressure_stale_chip_penalty"
                end
            end
            if lowValueChip
                and conversion.convertWinningPosition
                and commandantProgress <= 0
                and killProgress <= 0 then
                score.efficiency = score.efficiency
                    - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_LOW_VALUE_CHIP_AHEAD_PENALTY), 1200) * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_low_value_chip_ahead_penalty"
            end
            if conversion.eliminateLowHpUnit and (num(attackImpact.expectedKills, 0) > 0 or inDirectKillLane) then
                score.force = score.force + math.floor(950 * bonusScale)
                score.material = score.material + math.floor(num(attackImpact.expectedKillValue, 0) * 14 * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_low_hp_elimination"
            elseif conversion.eliminateLowHpUnit and killOptionsNow > 0 and killProgress <= 0 then
                score.efficiency = score.efficiency
                    - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_MISSED_AVAILABLE_KILL_PENALTY), 1800) * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_missed_available_kill"
            end
            if conversion.finishWindow then
                local finishPressure = (
                    num(attackImpact.commandantDamage, 0) * 1300
                    + num(attackImpact.expectedKills, 0) * 1800
                    + num(attackImpact.expectedKillValue, 0) * 38
                )
                score.commandant = score.commandant + math.floor(finishPressure * bonusScale)
                score.material = score.material + math.floor(num(attackImpact.expectedKillValue, 0) * 14 * bonusScale)
                if num(attackImpact.commandantDamage, 0) <= 0 and num(attackImpact.expectedKills, 0) <= 0 then
                    score.efficiency = score.efficiency - math.floor(1250 * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "finish_window_without_progress_penalty"
                end
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_finish_window_attack"
            end
            if conversion.criticalCommandantWindow then
                if num(attackImpact.commandantDamage, 0) > 0 then
                    score.commandant = score.commandant
                        + math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_FINISH_CRITICAL_DAMAGE_BONUS), 2800) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "finish_critical_commandant_damage"
                elseif killProgress <= 0 and setupCommandantDelta <= 0 then
                    score.efficiency = score.efficiency
                        - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_FINISH_CRITICAL_MISS_PENALTY), 2200) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "finish_critical_commandant_missed"
                end
            end
            if conversion.lastEnemyUnitWindow then
                if killProgress > 0 then
                    score.force = score.force
                        + math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_LAST_UNIT_KILL_BONUS), 2400) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "finish_last_enemy_unit_elimination"
                elseif num(attackImpact.commandantDamage, 0) <= 0 and setupAttackDelta <= 0 then
                    score.efficiency = score.efficiency
                        - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_LAST_UNIT_MISS_PENALTY), 1500) * bonusScale)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "finish_last_enemy_unit_missed"
                    if killOptionsNow > 0 then
                        score.efficiency = score.efficiency
                            - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_LAST_UNIT_AVAILABLE_KILL_MISS_PENALTY), 2200) * bonusScale)
                        score.breakdown.reasons[#score.breakdown.reasons + 1] = "finish_last_unit_available_kill_missed"
                    end
                end
            end
            if conversion.createsNextTurnCommandantLethal then
                score.commandant = score.commandant + math.floor(1900 * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_creates_next_turn_commandant_lethal"
            end
            if conversion.removesEnemyLastAttacker then
                score.survival = score.survival + math.floor(880 * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_removes_enemy_last_attacker"
            end
            if tostring(candidate and candidate.combatClass or "") == "low_value_safe_chip" and conversion.finishWindow then
                score.efficiency = score.efficiency - math.floor(900 * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_finish_window_low_value_chip_penalty"
            end
            if conversion.convertWinningPosition
                and commandantProgress <= 0
                and killProgress <= 0
                and setupAttackDelta <= 0
                and setupCommandantDelta <= 0 then
                score.efficiency = score.efficiency
                    - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_AHEAD_NO_PROGRESS_PENALTY), 850) * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_ahead_without_progress_penalty"
            end
            if candidate
                and candidate.containsDeploy == true
                and not (candidate.tacticalTags and candidate.tacticalTags.preventsImmediateLoss) then
                local deployAttackPenalty = num((ctx and ctx.cfg and ctx.cfg.CONVERSION_ATTACK_WITH_DEPLOY_PENALTY), 1200)
                if conversion.breakDrawClock then
                    deployAttackPenalty = deployAttackPenalty + num((ctx and ctx.cfg and ctx.cfg.CONVERSION_ATTACK_WITH_DEPLOY_DRAW_PENALTY), 900)
                end
                if conversion.finishWindow then
                    deployAttackPenalty = deployAttackPenalty + num((ctx and ctx.cfg and ctx.cfg.CONVERSION_ATTACK_WITH_DEPLOY_FINISH_PENALTY), 1100)
                end
                if not createsRealThreatNow then
                    deployAttackPenalty = deployAttackPenalty + num((ctx and ctx.cfg and ctx.cfg.CONVERSION_ATTACK_WITH_DEPLOY_STALE_PENALTY), 800)
                elseif setupCommandantDelta > 0 or setupAttackDelta > 0 then
                    deployAttackPenalty = math.floor(deployAttackPenalty * 0.55)
                end
                score.supply = score.supply - math.floor(deployAttackPenalty * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_attack_with_deploy_penalty"
            end
            if not createsRealThreatNow and conversion.contractActive then
                score.efficiency = score.efficiency
                    - math.floor(num((ctx and ctx.cfg and ctx.cfg.CONVERSION_ATTACK_NO_REAL_THREAT_PENALTY), 1600) * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_attack_no_real_threat_penalty"
            end
            score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_attack_selected"
        else
            local setupBonus = 0
            local distanceDelta = num(before.closestOwnUnitToEnemyHub, 99) - num(after.closestOwnUnitToEnemyHub, 99)
            if setupAttackDelta > 0 then
                setupBonus = setupBonus + (setupAttackDelta * num((ctx and ctx.cfg and ctx.cfg.CONVERSION_SETUP_ATTACK_BONUS), 460))
            end
            if setupCommandantDelta > 0 then
                setupBonus = setupBonus
                    + (setupCommandantDelta * num((ctx and ctx.cfg and ctx.cfg.CONVERSION_SETUP_COMMANDANT_BONUS), 950))
            end
            if distanceDelta > 0 then
                setupBonus = setupBonus + (distanceDelta * num((ctx and ctx.cfg and ctx.cfg.CONVERSION_SETUP_ADVANCE_BONUS), 240))
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_setup_advances_toward_commandant"
            elseif distanceDelta < 0 and conversion.forceCommandantPressure then
                score.efficiency = score.efficiency
                    - (math.abs(distanceDelta) * num((ctx and ctx.cfg and ctx.cfg.CONVERSION_SETUP_RETREAT_PENALTY), 320))
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_setup_retreat_penalty"
            end
            if setupBonus > 0 then
                score.force = score.force + setupBonus
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_setup_bonus"
            end

            local passivePenalty = num((ctx and ctx.cfg and ctx.cfg.CONVERSION_PASSIVE_PENALTY_BASE), 950)
                + (conversion.breakDrawClock and 1700 or 0)
                + (conversion.convertWinningPosition and 1150 or 0)
                + (conversion.forceCommandantPressure and 1700 or 0)
                + (conversion.eliminateLowHpUnit and 980 or 0)
                + (conversion.finishWindow and 1600 or 0)
                + (conversion.breakDrawClock and antiDraw.active and not antiDraw.preWindow
                    and num((ctx and ctx.cfg and ctx.cfg.CONVERSION_PASSIVE_PENALTY_DRAW_LATE_BONUS), 900)
                    or 0)
                + (conversion.criticalCommandantWindow
                    and num((ctx and ctx.cfg and ctx.cfg.CONVERSION_PASSIVE_PENALTY_CRITICAL_HUB_BONUS), 1800)
                    or 0)
                + (conversion.lastEnemyUnitWindow
                    and num((ctx and ctx.cfg and ctx.cfg.CONVERSION_PASSIVE_PENALTY_LAST_UNIT_BONUS), 1300)
                    or 0)
                + num(conversion.drawStreak, 0) * 190
                + num(conversion.drawUrgency, 0) * 340
            if conversion.setupChosen and conversion.setupCreatesRealThreat and setupBonus > 0 then
                local setupScale = 0.55
                if candidate and candidate.containsDeploy then
                    setupScale = num((ctx and ctx.cfg and ctx.cfg.CONVERSION_SETUP_DEPLOY_SCALE), 0.86)
                end
                passivePenalty = math.floor(passivePenalty * setupScale)
                score.efficiency = score.efficiency + math.floor(220 * bonusScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_setup_line_selected"
            elseif setupBonus > 0 and conversion.setupCreatesRealThreat ~= true and conversion.contractActive then
                passivePenalty = passivePenalty + num((ctx and ctx.cfg and ctx.cfg.CONVERSION_SETUP_FALSE_PROGRESS_PENALTY), 1400)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_setup_without_real_threat_penalty"
            end
            score.efficiency = score.efficiency - passivePenalty
            if candidate and candidate.containsDeploy and not (candidate.tacticalTags and candidate.tacticalTags.preventsImmediateLoss) then
                local deployPenaltyScale = conversion.finishWindow and 1.70 or 1.35
                score.supply = score.supply - math.floor(passivePenalty * deployPenaltyScale)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_deploy_rebuild_penalty"
                score.supply = score.supply
                    - num((ctx and ctx.cfg and ctx.cfg.CONVERSION_DEPLOY_HARD_AVOID_PENALTY), 22000)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_deploy_hard_avoid_penalty"
                if conversion.forceCommandantPressure and setupCommandantDelta <= 0 and setupAttackDelta <= 0 then
                    score.supply = score.supply
                        - num((ctx and ctx.cfg and ctx.cfg.CONVERSION_DEPLOY_NO_PRESSURE_PENALTY), 1600)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_deploy_without_pressure_progress"
                end
                if conversion.breakDrawClock and antiDraw and antiDraw.active and not antiDraw.preWindow then
                    score.supply = score.supply
                        - num((ctx and ctx.cfg and ctx.cfg.CONVERSION_DEPLOY_DRAW_CLOCK_PENALTY), 2100)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_deploy_under_draw_clock_penalty"
                end
            end
            score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_passive_penalty"
        end
    end

    if candidate and candidate.containsDeploy then
        local deployImpact = evaluateSequenceDeployImpact(ai, beforeState, afterOurTurn, candidate, ctx)
        score.supply = score.supply + num(deployImpact.value, 0)
        score.breakdown.supply = deployImpact

        local healerDeploy = false
        for _, action in ipairs(candidate.actions or {}) do
            if action and action.type == "supply_deploy" and tostring(action.unitName or action.unitType or "") == "Healer" then
                healerDeploy = true
                break
            end
        end

        if healerDeploy
            and not hasDamagedFriendlyCombatUnit(ai, beforeState, ctx.aiPlayer)
            and not (before.ownHubThreat and (before.ownHubThreat.immediateDanger or before.ownHubThreat.immediateLethal)) then
            score.supply = score.supply - 120000
            score.breakdown.reasons[#score.breakdown.reasons + 1] = "healer_filler_penalty"

            local firstAction = candidate and candidate.actions and candidate.actions[1] or nil
            if firstAction and firstAction.type == "supply_deploy"
                and tostring(firstAction.unitName or firstAction.unitType or "") == "Healer" then
                score.supply = score.supply - 80000
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "healer_filler_first_action_penalty"
            end
        end
    end

    if candidate and candidate.containsDeploy and num(score.supply, 0) <= 0 then
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "healer_no_filler"
    end

    score.breakdown.before = {
        ownHubHp = before.ownHubHp,
        enemyHubHp = before.enemyHubHp,
        materialDiff = before.materialDiff,
        commandantPressure = before.commandantPressure,
        position = before.position
    }
    score.breakdown.after = {
        ownHubHp = after.ownHubHp,
        enemyHubHp = after.enemyHubHp,
        materialDiff = after.materialDiff,
        commandantPressure = after.commandantPressure,
        position = after.position
    }
    score.breakdown.attackImpact = attackImpact
    score.breakdown.selectedPassiveOnly = candidateIsPassiveOnly(candidate, beforeState, ctx.aiPlayer)
    score.breakdown.hasFactionAttack = num(attackImpact.factionAttackCount, 0) > 0
    score.breakdown.hasDamagingFactionAttack = num(attackImpact.damagingFactionAttackCount, 0) > 0

    return ctx.score.finalize(score)
end

local function evaluateConversionForcing(ai, stateForNextTurn, candidate, ctx)
    local _ = candidate
    local result = {
        enabled = false,
        attackOptions = 0,
        commandantAttackOptions = 0,
        safeKillOptions = 0,
        maxKillValue = 0,
        maxCommandantDamage = 0,
        forcesEnemyDefense = false,
        immediateLethal = false,
        forceDelta = 0,
        commandantDelta = 0
    }
    if not (ctx and stateForNextTurn and ai) then
        return result
    end

    local nextTurn = stateForNextTurn
    if ai.prepareStateForPlayerTurn then
        nextTurn = ai:prepareStateForPlayerTurn(stateForNextTurn, ctx.aiPlayer, {
            resetDeployment = true,
            resetActionCount = true,
            resetFirstActionRangedAttack = true
        })
    end

    local actions = {}
    local legalOpts = {
        includeMove = false,
        includeAttack = true,
        includeRepair = false,
        includeDeploy = false
    }
    if ctx.cache and ctx.cache.legalActions then
        actions = ctx.cache.legalActions(ai, nextTurn, ctx.aiPlayer, ctx, legalOpts) or {}
    elseif ai.collectLegalActions then
        actions = ai:collectLegalActions(nextTurn, {
            aiPlayer = ctx.aiPlayer,
            includeMove = false,
            includeAttack = true,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    end
    actions = copyArray(actions)
    table.sort(actions, function(a, b)
        local aa = a and a.action or nil
        local bb = b and b.action or nil
        local function key(action)
            if not action then
                return ""
            end
            return string.format(
                "%s:%s,%s->%s,%s",
                tostring(action.type or "unknown"),
                tostring(action.unit and action.unit.row or "?"),
                tostring(action.unit and action.unit.col or "?"),
                tostring(action.target and action.target.row or "?"),
                tostring(action.target and action.target.col or "?")
            )
        end
        return key(aa) < key(bb)
    end)

    local scanCap = math.max(4, num((ctx.cfg or {}).CONVERSION_FORCING_SCAN_CAP, 20))
    local scanned = 0
    for _, entry in ipairs(actions) do
        if scanned >= scanCap then
            break
        end
        scanned = scanned + 1
        local action = entry and entry.action or nil
        if isFactionInteractionAttackAction(nextTurn, action, ctx.aiPlayer) then
            result.attackOptions = result.attackOptions + 1
            local attacker = getUnitAtPosition(ai, nextTurn, action.unit and action.unit.row, action.unit and action.unit.col)
            local target = getTargetUnitForAction(ai, nextTurn, action)
            local damage = calculateDamage(ai, attacker, target)
            local targetHp = num(target and (target.currentHp or target.startingHp), 0)
            if target and target.player == ctx.enemyPlayer and isHubUnit(ai, target) then
                result.commandantAttackOptions = result.commandantAttackOptions + 1
                result.maxCommandantDamage = math.max(result.maxCommandantDamage, damage)
            elseif target and targetHp > 0 and damage >= targetHp then
                result.safeKillOptions = result.safeKillOptions + 1
                result.maxKillValue = math.max(result.maxKillValue, getUnitValue(ai, target, nextTurn))
            end
        end
    end

    if ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
        result.immediateLethal = ctx.threatModel.hasImmediateCommandantLethal(
            ai,
            nextTurn,
            ctx.aiPlayer,
            ctx.enemyPlayer,
            ctx
        ) == true
    end

    result.forcesEnemyDefense = result.immediateLethal
        or result.commandantAttackOptions >= 2
        or (result.safeKillOptions > 0 and result.attackOptions >= 2)

    result.forceDelta = (result.attackOptions * num((ctx.cfg or {}).CONVERSION_FORCING_ATTACK_OPTION_BONUS, 220))
        + (result.safeKillOptions * num((ctx.cfg or {}).CONVERSION_FORCING_SAFE_KILL_OPTION_BONUS, 420))
        + (result.maxKillValue * num((ctx.cfg or {}).CONVERSION_FORCING_KILL_VALUE_WEIGHT, 18))
    result.commandantDelta = (result.commandantAttackOptions * num((ctx.cfg or {}).CONVERSION_FORCING_COMMANDANT_OPTION_BONUS, 900))
        + (result.maxCommandantDamage * num((ctx.cfg or {}).CONVERSION_FORCING_COMMANDANT_DAMAGE_BONUS, 950))
    if result.immediateLethal then
        result.commandantDelta = result.commandantDelta
            + num((ctx.cfg or {}).CONVERSION_FORCING_IMMEDIATE_WIN_BONUS, 2600)
    end

    result.enabled = true
    return result
end

function M.scoreAfterEnemyReply(ai, beforeState, afterOurTurn, replyResult, candidate, ctx, extensionResult)
    local score = M.scoreOwnTurnFast(ai, beforeState, afterOurTurn, candidate, ctx)

    if replyResult and replyResult.afterEnemy then
        if M.isCommandantDead(replyResult.afterEnemy, ctx.aiPlayer) then
            score.tier = math.min(score.tier, ctx.score.TIER.BAD_BUT_LEGAL)
            score.survival = score.survival - 1000000
            score.breakdown.enemyReply = "reply_kills_own_commandant"
            return ctx.score.finalize(score)
        end

        local afterEnemyFeatures = ctx.cache.features(ai, replyResult.afterEnemy, ctx.aiPlayer, ctx)
        local afterOwnFeatures = ctx.cache.features(ai, afterOurTurn, ctx.aiPlayer, ctx)

        score.survival = score.survival
            - math.max(0, num(afterOwnFeatures.ownHubHp, 0) - num(afterEnemyFeatures.ownHubHp, 0)) * 1000
            - math.max(0, num(afterEnemyFeatures.ownHubThreat and afterEnemyFeatures.ownHubThreat.projectedDamage, 0)) * 500

        score.material = score.material
            + (num(afterEnemyFeatures.materialDiff, 0) - num(afterOwnFeatures.materialDiff, 0)) * 100

        score.risk = score.risk + num(replyResult.riskPenalty, 0)
        score.breakdown.enemyReply = replyResult.summary
    end

    if ctx and ctx.reserveModel and ctx.reserveModel.evaluateEnemyReserveThreat then
        local enemyReserveThreat = ctx.reserveModel.evaluateEnemyReserveThreat(ai, afterOurTurn, ctx.enemyPlayer, ctx)
        score.risk = score.risk + num(enemyReserveThreat and enemyReserveThreat.value, 0)
        score.breakdown.enemyReserveThreat = enemyReserveThreat
    end

    if extensionResult then
        score.survival = score.survival + num(extensionResult.survivalDelta, 0)
        score.force = score.force + num(extensionResult.forceDelta, 0)
        score.commandant = score.commandant + num(extensionResult.commandantDelta, 0)
        score.material = score.material + num(extensionResult.materialDelta, 0)
        score.risk = score.risk + num(extensionResult.riskDelta, 0)

        if extensionResult.tierUpgrade then
            score.tier = math.max(score.tier, extensionResult.tierUpgrade)
        end
        if extensionResult.tierDowngrade then
            score.tier = math.min(score.tier, extensionResult.tierDowngrade)
        end

        score.breakdown.tacticalExtension = extensionResult
    end

    local conversion = score.breakdown and score.breakdown.conversion or nil
    local forcingTopN = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_FORCING_CHECK_TOP_N, 3)
    local forcingMinRemainingMs = num(ctx and ctx.cfg and ctx.cfg.CONVERSION_FORCING_CHECK_MIN_REMAINING_MS, 90)
    local forcingChecks = num(ctx and ctx.stats and ctx.stats.conversionForcingChecks, 0)
    local canCheckForcing = conversion
        and conversion.contractActive == true
        and forcingChecks < forcingTopN
        and (ctx and ctx.remainingMs and ctx.remainingMs() >= forcingMinRemainingMs)
    if canCheckForcing then
        local forcingState = (replyResult and replyResult.afterEnemy) or afterOurTurn
        local forcing = evaluateConversionForcing(ai, forcingState, candidate, ctx)
        if ctx and ctx.stats then
            ctx.stats.conversionForcingChecks = forcingChecks + 1
            if forcing.attackOptions > 0 then
                ctx.stats.conversionForcingSignals = num(ctx.stats.conversionForcingSignals, 0) + 1
            end
        end

        if forcing.enabled then
            score.force = score.force + num(forcing.forceDelta, 0)
            score.commandant = score.commandant + num(forcing.commandantDelta, 0)
            if forcing.forcesEnemyDefense then
                score.force = score.force + num((ctx and ctx.cfg and ctx.cfg.CONVERSION_FORCING_ENEMY_DEFENSE_BONUS), 650)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_forcing_enemy_defense"
            end
            if conversion.hasFactionAttack ~= true and forcing.attackOptions > 0 then
                score.position = score.position
                    + num((ctx and ctx.cfg and ctx.cfg.CONVERSION_FORCING_SETUP_POSITION_BONUS), 380)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_forcing_setup"
                if forcing.safeKillOptions > 0 then
                    score.force = score.force + math.floor(num(forcing.safeKillOptions, 0) * 220)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_forcing_safe_kill_setup"
                end
            elseif conversion.hasFactionAttack ~= true and forcing.attackOptions <= 0 then
                score.efficiency = score.efficiency
                    - num((ctx and ctx.cfg and ctx.cfg.CONVERSION_FORCING_NO_FOLLOWUP_PENALTY), 420)
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_forcing_no_followup"
            else
                score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_forcing_attack_line"
                if forcing.attackOptions <= 0 and forcing.immediateLethal ~= true then
                    score.efficiency = score.efficiency
                        - num((ctx and ctx.cfg and ctx.cfg.CONVERSION_FORCING_ATTACK_DEAD_END_PENALTY), 480)
                    score.breakdown.reasons[#score.breakdown.reasons + 1] = "conversion_forcing_attack_dead_end"
                end
            end
            score.breakdown.conversionForcing = forcing
        end
    end

    return ctx.score.finalize(score)
end

function M.isFactionInteractionAttackAction(beforeState, action, actingPlayer)
    return isFactionInteractionAttackAction(beforeState, action, actingPlayer)
end

function M.candidateHasFactionInteractionAttack(beforeState, candidate, actingPlayer)
    return candidateHasFactionInteractionAttack(beforeState, candidate, actingPlayer)
end

function M.candidateIsPassiveOnly(candidate, beforeState, actingPlayer)
    return candidateIsPassiveOnly(candidate, beforeState, actingPlayer)
end

function M.getOfficialDrawUrgency(ai, beforeState)
    return buildOfficialDrawUrgency(ai, beforeState)
end

return M
