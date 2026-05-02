local unitsInfo = require("unitsInfo")

local M = {}

M.BUCKET_LIMITS = {
    lethal = 16,
    anti_lethal = 24,
    commandant_pressure = 24,
    direct_attack = 24,
    draw_reset_attack = 20,
    move_attack = 20,
    high_value_attack = 32,
    supply_defense = 24,
    supply_offense = 24,
    repair = 12,
    strategic_rock = 12,
    defensive_move = 24,
    positional_move = 32,
    fallback = 16
}

M.BUCKET_ORDER = {
    "lethal",
    "anti_lethal",
    "commandant_pressure",
    "draw_reset_attack",
    "direct_attack",
    "move_attack",
    "high_value_attack",
    "supply_defense",
    "supply_offense",
    "repair",
    "strategic_rock",
    "defensive_move",
    "positional_move",
    "fallback"
}

M.MODE_LIMIT_OVERRIDES = {
    lethal_only = {
        lethal = 28,
        commandant_pressure = 28,
        draw_reset_attack = 16,
        direct_attack = 18,
        move_attack = 16,
        high_value_attack = 12,
        supply_offense = 12,
        defensive_move = 10,
        positional_move = 10,
        fallback = 6
    },
    punish_commandant = {
        lethal = 24,
        commandant_pressure = 28,
        draw_reset_attack = 18,
        direct_attack = 18,
        move_attack = 16,
        high_value_attack = 18,
        supply_offense = 14,
        defensive_move = 10,
        positional_move = 10,
        fallback = 8
    },
    forcing_extension = {
        lethal = 20,
        anti_lethal = 24,
        commandant_pressure = 28,
        draw_reset_attack = 18,
        direct_attack = 20,
        move_attack = 18,
        high_value_attack = 20,
        supply_defense = 18,
        supply_offense = 18,
        repair = 14,
        defensive_move = 18,
        positional_move = 14,
        fallback = 10
    }
}

M.MODE_ALLOWED_BUCKETS = {
    lethal_only = {
        lethal = true,
        commandant_pressure = true,
        draw_reset_attack = true,
        direct_attack = true,
        move_attack = true,
        high_value_attack = true,
        supply_offense = true,
        defensive_move = true,
        positional_move = true,
        fallback = true
    },
    punish_commandant = {
        lethal = true,
        anti_lethal = true,
        commandant_pressure = true,
        draw_reset_attack = true,
        direct_attack = true,
        move_attack = true,
        high_value_attack = true,
        supply_offense = true,
        defensive_move = true,
        positional_move = true,
        fallback = true
    }
}

local DEFENSIVE_DEPLOY_UNITS = {
    Bastion = true,
    Earthstalker = true,
    Wingstalker = true,
    Healer = true
}

local OFFENSIVE_DEPLOY_UNITS = {
    Cloudstriker = true,
    Artillery = true,
    Crusher = true,
    Wingstalker = true
}

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

local function copyTable(value)
    local out = {}
    for k, v in pairs(value or {}) do
        out[k] = v
    end
    return out
end

local function posKey(row, col)
    return string.format("%d,%d", num(row, -1), num(col, -1))
end

local function sameCell(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return num(a.row, -1) == num(b.row, -2) and num(a.col, -1) == num(b.col, -2)
end

local function opponentPlayer(ai, playerId)
    if ai and ai.getOpponentPlayer then
        return ai:getOpponentPlayer(playerId)
    end
    if playerId == 1 then
        return 2
    end
    if playerId == 2 then
        return 1
    end
    return nil
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
    if not state then
        return nil
    end

    if ai and ai.getUnitAtPosition then
        return ai:getUnitAtPosition(state, row, col)
    end

    for _, unit in ipairs(state.units or {}) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end

    return nil
end

local function getNeutralRockAt(state, row, col)
    for _, building in ipairs((state and state.neutralBuildings) or {}) do
        if building and building.row == row and building.col == col then
            return {
                name = "Rock",
                player = 0,
                row = building.row,
                col = building.col,
                currentHp = building.currentHp,
                startingHp = building.startingHp
            }
        end
    end
    return nil
end

local function getActionUnit(ai, state, action)
    if type(action) ~= "table" then
        return nil
    end
    local unit = action.unit or {}
    return getUnitAtPosition(ai, state, unit.row, unit.col)
end

local function getActionTarget(ai, state, action)
    if type(action) ~= "table" then
        return nil
    end
    local target = action.target or {}
    local unit = getUnitAtPosition(ai, state, target.row, target.col)
    if unit then
        return unit
    end
    for playerId = 1, 2 do
        local hub = state and state.commandHubs and state.commandHubs[playerId]
        if hub and hub.row == target.row and hub.col == target.col then
            return {
                name = "Commandant",
                player = playerId,
                row = hub.row,
                col = hub.col,
                currentHp = hub.currentHp,
                startingHp = hub.startingHp
            }
        end
    end
    return getNeutralRockAt(state, target.row, target.col)
end

local function isFactionInteractionAttackAction(ai, state, action, actingPlayer)
    if type(action) ~= "table" or action.type ~= "attack" then
        return false
    end
    local target = getActionTarget(ai, state, action)
    if not target then
        return false
    end
    local targetPlayer = num(target.player, 0)
    return targetPlayer > 0 and targetPlayer ~= num(actingPlayer, 0)
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
    if ai and ai.calculateDamage and attacker and target then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok and value ~= nil then
            return math.max(0, num(value, 0))
        end
    end
    return 0
end

local function stateThreat(ai, state, playerToProtect, attackerPlayer, ctx)
    if not ai or not state or not playerToProtect or not attackerPlayer then
        return nil
    end

    if ctx and ctx.cache and ctx.cache.threat then
        return ctx.cache.threat(ai, state, playerToProtect, attackerPlayer, ctx)
    end

    if ctx and ctx.threatModel and ctx.threatModel.analyzeHubThreatForPlayer then
        return ctx.threatModel.analyzeHubThreatForPlayer(ai, state, playerToProtect, attackerPlayer, ctx)
    end

    if ai.analyzeHubThreatForPlayer then
        return ai:analyzeHubThreatForPlayer(state, playerToProtect, attackerPlayer, ctx)
    end

    local ok, threatModel = pcall(require, "ai_tournament.threat_model")
    if ok and threatModel and threatModel.analyzeHubThreatForPlayer then
        return threatModel.analyzeHubThreatForPlayer(ai, state, playerToProtect, attackerPlayer, ctx)
    end

    return nil
end

local function simulateSingleAction(ai, state, action, playerId, ctx)
    if not ai or not state or not action then
        return nil
    end

    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, {action}, playerId, ctx)
    end

    if ai.simulateActionSequenceForPlayer then
        return ai:simulateActionSequenceForPlayer(state, {action}, playerId, {})
    end

    if action.type == "supply_deploy" and ai.applySupplyDeploymentForPlayer then
        return ai:applySupplyDeploymentForPlayer(state, action, playerId, {
            scoreDeployments = false
        })
    end

    if action.type ~= "skip" and ai.applyMove then
        return ai:applyMove(state, action)
    end

    return state
end

local function collectLegal(ai, state, playerId, ctx, opts)
    local options = opts or {}
    if ctx and ctx.cache and ctx.cache.legalActions then
        return ctx.cache.legalActions(ai, state, playerId, ctx, options) or {}
    end
    if ai and ai.collectLegalActions then
        return ai:collectLegalActions(state, {
            aiPlayer = playerId,
            usedUnits = options.usedUnits,
            includeMove = options.includeMove,
            includeAttack = options.includeAttack,
            includeRepair = options.includeRepair,
            includeDeploy = options.includeDeploy,
            allowFullHpHealerRepairException = options.allowFullHpHealerRepairException
        }) or {}
    end
    return {}
end

local function threatHasAttacker(threat, target)
    if type(threat) ~= "table" or type(target) ~= "table" then
        return false
    end

    local key = posKey(target.row, target.col)
    for _, entry in ipairs(threat.damagingAttackers or {}) do
        local unit = entry and entry.unit
        if unit and posKey(unit.row, unit.col) == key then
            return true
        end
    end
    return false
end

local function threatHasBlockCell(threat, target)
    if type(threat) ~= "table" or type(target) ~= "table" then
        return false
    end

    local key = posKey(target.row, target.col)
    for _, cell in ipairs(threat.blockCells or {}) do
        if posKey(cell.row, cell.col) == key then
            return true
        end
    end
    return false
end

local function evaluateDefenseDelta(ai, state, action, playerId, enemyPlayer, ownThreatBefore, ctx)
    if not ownThreatBefore then
        return nil
    end

    local hasDanger = bool(ownThreatBefore.immediateDanger)
        or bool(ownThreatBefore.immediateLethal)
        or num(ownThreatBefore.projectedDamage, 0) > 0
    if not hasDanger then
        return nil
    end

    local afterState = simulateSingleAction(ai, state, action, playerId, ctx)
    if not afterState then
        return nil
    end

    local ownThreatAfter = stateThreat(ai, afterState, playerId, enemyPlayer, ctx)
    if not ownThreatAfter then
        return {
            afterState = afterState,
            threatAfter = nil,
            preventedLethal = false,
            clearedImmediateDanger = false,
            reducedProjectedDamage = false,
            reducedAttackerCount = false
        }
    end

    local beforeProjected = num(ownThreatBefore.projectedDamage, 0)
    local afterProjected = num(ownThreatAfter.projectedDamage, 0)
    local beforeCount = #((ownThreatBefore.damagingAttackers) or {})
    local afterCount = #((ownThreatAfter.damagingAttackers) or {})

    return {
        afterState = afterState,
        threatAfter = ownThreatAfter,
        preventedLethal = bool(ownThreatBefore.immediateLethal) and not bool(ownThreatAfter.immediateLethal),
        clearedImmediateDanger = bool(ownThreatBefore.immediateDanger) and not bool(ownThreatAfter.immediateDanger),
        reducedProjectedDamage = afterProjected < beforeProjected,
        reducedAttackerCount = afterCount < beforeCount
    }
end

local function evaluatePressureDelta(ai, state, afterState, playerId, enemyPlayer, ctx)
    if not afterState then
        return nil
    end

    local before = stateThreat(ai, state, enemyPlayer, playerId, ctx)
    local after = stateThreat(ai, afterState, enemyPlayer, playerId, ctx)
    if not before and not after then
        return nil
    end

    local beforeProjected = num(before and before.projectedDamage, 0)
    local afterProjected = num(after and after.projectedDamage, 0)

    return {
        before = before,
        after = after,
        projectedDelta = afterProjected - beforeProjected,
        newDanger = (after and after.immediateDanger == true and not (before and before.immediateDanger == true)) or false,
        newLethal = (after and after.immediateLethal == true and not (before and before.immediateLethal == true)) or false
    }
end

local function positionalDelta(ai, state, afterState, action)
    if not ai or not ai.getPositionalValue or not afterState or not action then
        return 0
    end

    local source = action.unit or {}
    local target = action.target or {}
    local beforeUnit = getUnitAtPosition(ai, state, source.row, source.col)
    local afterUnit = getUnitAtPosition(ai, afterState, target.row, target.col)
    if not beforeUnit or not afterUnit then
        return 0
    end

    local beforeScore = num(ai:getPositionalValue(state, beforeUnit), 0)
    local afterScore = num(ai:getPositionalValue(afterState, afterUnit), 0)
    return afterScore - beforeScore
end

local function distance(rowA, colA, rowB, colB)
    return math.abs(num(rowA, 0) - num(rowB, 0)) + math.abs(num(colA, 0) - num(colB, 0))
end

local function nearestEnemyDistance(ai, state, row, col, enemyPlayer)
    local best = 999
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == enemyPlayer and not isObstacleUnit(ai, unit) then
            local d = distance(row, col, unit.row, unit.col)
            if d < best then
                best = d
            end
        end
    end
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    if enemyHub then
        local dHub = distance(row, col, enemyHub.row, enemyHub.col)
        if dHub < best then
            best = dHub
        end
    end
    return best
end

local function resolveAttackRange(unit)
    local range = tonumber(unit and (unit.atkRange or unit.attackRange or unit.range))
    if range then
        return range
    end
    if unitsInfo and unitsInfo.getUnitAttackRange and unit then
        local ok, resolved = pcall(unitsInfo.getUnitAttackRange, unitsInfo, unit, "TOURNAMENT_BLOCKER_EVACUATION")
        if ok and resolved then
            return num(resolved, 1)
        end
    end
    return 1
end

local function canThreatenTargetFromCell(ai, state, unit, cell, target)
    if not (unit and cell and target) then
        return false
    end
    if calculateDamage(ai, unit, target) <= 0 then
        return false
    end

    local dist = distance(cell.row, cell.col, target.row, target.col)
    local attackRange = resolveAttackRange(unit)
    if dist <= 0 or dist > attackRange then
        return false
    end

    local unitName = tostring(unit.name or "")
    if unitName == "Cloudstriker" then
        if dist <= 1 then
            return false
        end
        if ai and ai.hasLineOfSight then
            return ai:hasLineOfSight(state, {row = cell.row, col = cell.col}, {row = target.row, col = target.col}) == true
        end
        return false
    end
    if unitName == "Artillery" then
        return dist > 1
    end

    return true
end

local function isHubAdjacentCell(state, playerId, row, col)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    return hub and distance(row, col, hub.row, hub.col) == 1
end

local function isCellOccupiedOrBlocked(ai, state, row, col)
    if getUnitAtPosition(ai, state, row, col) then
        return true
    end
    for _, building in ipairs((state and state.neutralBuildings) or {}) do
        if building and num(building.row, -1) == num(row, -2) and num(building.col, -1) == num(col, -2) then
            return true
        end
    end
    for _, hub in pairs((state and state.commandHubs) or {}) do
        if hub and num(hub.row, -1) == num(row, -2) and num(hub.col, -1) == num(col, -2) then
            return true
        end
    end
    return false
end

local function currentUsefulDeployExists(ai, state, playerId, threatUnit)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not hub then
        return false
    end
    local directions = (ai and ai.getOrthogonalDirections and ai:getOrthogonalDirections()) or {
        {row = -1, col = 0}, {row = 1, col = 0}, {row = 0, col = -1}, {row = 0, col = 1}
    }
    for _, reserve in ipairs((state and state.supply and state.supply[playerId]) or {}) do
        if reserve and num(reserve.currentHp or reserve.startingHp, 1) > 0 then
            for _, dir in ipairs(directions) do
                local cell = {row = hub.row + dir.row, col = hub.col + dir.col}
                if not isCellOccupiedOrBlocked(ai, state, cell.row, cell.col) then
                    local deployed = copyTable(reserve)
                    deployed.player = playerId
                    deployed.row = cell.row
                    deployed.col = cell.col
                    if canThreatenTargetFromCell(ai, state, deployed, cell, threatUnit) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function reserveCanUseFreedDeployCell(ai, state, playerId, cell, threatUnit)
    if not isHubAdjacentCell(state, playerId, cell.row, cell.col) then
        return false
    end
    for _, reserve in ipairs((state and state.supply and state.supply[playerId]) or {}) do
        if reserve and num(reserve.currentHp or reserve.startingHp, 1) > 0 then
            local deployed = copyTable(reserve)
            deployed.player = playerId
            deployed.row = cell.row
            deployed.col = cell.col
            if canThreatenTargetFromCell(ai, state, deployed, cell, threatUnit) then
                return true
            end
        end
    end
    return false
end

local function unitCanMoveToCell(ai, state, unit, cell)
    if not (ai and ai.getValidMoveCells and state and unit and cell) then
        return false
    end
    for _, moveCell in ipairs(ai:getValidMoveCells(state, unit.row, unit.col) or {}) do
        if num(moveCell and moveCell.row, -1) == num(cell.row, -2)
            and num(moveCell and moveCell.col, -1) == num(cell.col, -2) then
            return true
        end
    end
    return false
end

local function boardUnitCanUseFreedThreatCell(ai, afterState, blocker, playerId, cell, threatUnit)
    if not (afterState and threatUnit) then
        return false
    end
    for _, unit in ipairs(afterState.units or {}) do
        if unit
            and num(unit.player, 0) == num(playerId, 0)
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit)
            and not (num(unit.row, -1) == num(blocker and blocker.row, -2) and num(unit.col, -1) == num(blocker and blocker.col, -2))
            and num(unit.currentHp or unit.startingHp, 0) > 0
            and unitCanMoveToCell(ai, afterState, unit, cell) then
            if canThreatenTargetFromCell(ai, afterState, unit, cell, threatUnit) then
                return true
            end
        end
    end
    return false
end

local function findCurrentThreatUnit(ai, state, threatEntry)
    local unit = threatEntry and threatEntry.unit
    if not unit then
        return nil
    end
    return getUnitAtPosition(ai, state, unit.row, unit.col) or unit
end

local function evaluateDefenseBlockerEvacuation(ai, state, afterState, action, playerId, enemyPlayer, ownThreat)
    local _ = enemyPlayer
    if not (action and action.type == "move" and ownThreat and (ownThreat.immediateDanger or ownThreat.immediateLethal)) then
        return nil
    end

    local blocker = getActionUnit(ai, state, action)
    if not blocker
        or num(blocker.player, 0) ~= num(playerId, 0)
        or isHubUnit(ai, blocker)
        or isObstacleUnit(ai, blocker) then
        return nil
    end

    local sourceCell = {row = blocker.row, col = blocker.col}
    local targetCell = action.target or {}
    if num(sourceCell.row, -1) == num(targetCell.row, -2)
        and num(sourceCell.col, -1) == num(targetCell.col, -2) then
        return nil
    end

    for _, entry in ipairs(ownThreat.damagingAttackers or {}) do
        local threatUnit = findCurrentThreatUnit(ai, state, entry)
        if threatUnit and num(threatUnit.currentHp or threatUnit.startingHp, 0) > 0 then
            local adjacentToThreat = distance(sourceCell.row, sourceCell.col, threatUnit.row, threatUnit.col) == 1
            local hubAdjacent = isHubAdjacentCell(state, playerId, sourceCell.row, sourceCell.col)
            if adjacentToThreat or hubAdjacent then
                local blockerHelpsNow = canThreatenTargetFromCell(ai, state, blocker, sourceCell, threatUnit)
                if not blockerHelpsNow then
                    local opensBoardDefender = adjacentToThreat
                        and boardUnitCanUseFreedThreatCell(ai, afterState, blocker, playerId, sourceCell, threatUnit)
                    local opensDeploy = hubAdjacent
                        and not currentUsefulDeployExists(ai, state, playerId, threatUnit)
                        and reserveCanUseFreedDeployCell(ai, state, playerId, sourceCell, threatUnit)
                    if opensBoardDefender or opensDeploy then
                        return {
                            opensBoardDefender = opensBoardDefender == true,
                            opensDeploy = opensDeploy == true,
                            threatName = tostring(threatUnit.name or "?"),
                            score = (opensBoardDefender and 1200 or 0) + (opensDeploy and 1000 or 0)
                        }
                    end
                end
            end
        end
    end

    return nil
end

function M.actionSignature(action)
    if not action then
        return "nil"
    end

    if action.type == "attack" or action.type == "repair" or action.type == "move" then
        return string.format(
            "%s:%d,%d>%d,%d",
            tostring(action.type),
            num(action.unit and action.unit.row, 0),
            num(action.unit and action.unit.col, 0),
            num(action.target and action.target.row, 0),
            num(action.target and action.target.col, 0)
        )
    end

    if action.type == "supply_deploy" then
        return string.format(
            "deploy:%s>%d,%d",
            tostring(action.unitName or action.unitType or "?"),
            num(action.target and action.target.row, 0),
            num(action.target and action.target.col, 0)
        )
    end

    if action.type == "skip" then
        return "skip"
    end

    return tostring(action.type or "unknown")
end

function M.classifyAction(ai, state, action, playerId, ctx, opts)
    local options = opts or {}
    local entry = options.entry or {}
    local actionType = action and action.type or "unknown"
    local enemyPlayer = opponentPlayer(ai, playerId)
    local ownThreat = stateThreat(ai, state, playerId, enemyPlayer, ctx)
    local drawUrgency = nil
    if ctx and ctx.evaluator and ctx.evaluator.getOfficialDrawUrgency then
        drawUrgency = ctx.evaluator.getOfficialDrawUrgency(ai, state)
    end
    local drawPressureActive = drawUrgency and drawUrgency.active == true

    local bucket = "fallback"
    local cheapScore = num(entry.cheapScore, 0)
    local tags = {}
    local stateAfter = nil

    if actionType == "attack" then
        local attacker = getActionUnit(ai, state, action)
        local target = getActionTarget(ai, state, action)
        local damage = calculateDamage(ai, attacker, target)
        local targetHp = num(target and (target.currentHp or target.startingHp), 0)
        local targetValue = getUnitValue(ai, target, state)
        local targetIsEnemyCommandant = target and target.player == enemyPlayer and isHubUnit(ai, target)
        local targetIsRock = target and isObstacleUnit(ai, target)

        if targetIsEnemyCommandant and targetHp > 0 and damage >= targetHp then
            bucket = "lethal"
            cheapScore = math.max(cheapScore, 100000)
            tags.winsNow = true
            tags.commandantPressure = true
        elseif ownThreat and threatHasAttacker(ownThreat, target) and damage > 0 then
            bucket = "anti_lethal"
            cheapScore = math.max(cheapScore, 90000 + (damage * 200))
            tags.killsThreateningUnit = true
            tags.targetsCommandantThreat = true
            tags.addressesCommandantPressure = true
            tags.preventsImmediateLoss = true
        elseif targetIsRock then
            local strategicRock = false
            if damage > 0 and ai and ai.isStrategicRockAttack then
                strategicRock = ai:isStrategicRockAttack(state, action, {
                    aiPlayer = playerId,
                    target = target
                }) == true
            end
            if strategicRock then
                bucket = "strategic_rock"
                cheapScore = math.max(cheapScore, 2600)
            else
                bucket = "fallback"
                cheapScore = math.max(cheapScore, 300)
            end
        elseif targetIsEnemyCommandant and damage > 0 then
            bucket = "commandant_pressure"
            cheapScore = math.max(cheapScore, 7000 + (damage * 1200))
            tags.commandantPressure = true
        elseif target and target.player == enemyPlayer then
            if damage <= 0 then
                bucket = "fallback"
                cheapScore = math.max(cheapScore, 120)
                tags.zeroDamageFactionAttack = true
            else
                local lethalHit = targetHp > 0 and damage >= targetHp
                local heavyHit = damage >= math.max(2, math.floor(targetHp * 0.6))
                if drawPressureActive then
                    bucket = "draw_reset_attack"
                    cheapScore = math.max(
                        cheapScore,
                        3300 + (targetValue * 18) + (damage * 180) + (lethalHit and 500 or 0)
                    )
                    tags.drawResetAttack = true
                elseif lethalHit or (heavyHit and targetValue >= 40) then
                    bucket = "high_value_attack"
                    cheapScore = math.max(cheapScore, 3200 + (targetValue * 28) + (damage * 200) + (lethalHit and 1300 or 0))
                else
                    bucket = "direct_attack"
                    cheapScore = math.max(cheapScore, 2400 + (targetValue * 12) + (damage * 115))
                end
            end
        end

        if bucket ~= "lethal" and ownThreat then
            local defense = evaluateDefenseDelta(ai, state, action, playerId, enemyPlayer, ownThreat, ctx)
            stateAfter = defense and defense.afterState or stateAfter
            if damage > 0 and defense and (defense.preventedLethal or defense.clearedImmediateDanger or defense.reducedProjectedDamage) then
                bucket = "anti_lethal"
                cheapScore = math.max(cheapScore, 88000 + (defense.preventedLethal and 4000 or 0))
                tags.addressesCommandantPressure = true
                tags.preventsImmediateLoss = true
            end
        end
    elseif actionType == "supply_deploy" then
        local details = entry.deployDetails or {}
        local unitName = tostring(action.unitName or action.unitType or "?")
        local defenseWeight = num(details.immediateDefense, 0) + num(details.repairValue, 0)
        local offenseWeight = num(details.commandantPressure, 0) + num(details.laneValue, 0)
        if DEFENSIVE_DEPLOY_UNITS[unitName] then
            defenseWeight = defenseWeight + 300
        end
        if OFFENSIVE_DEPLOY_UNITS[unitName] then
            offenseWeight = offenseWeight + 280
        end

        if ownThreat
            and (bool(ownThreat.immediateDanger) or bool(ownThreat.immediateLethal))
            and threatHasBlockCell(ownThreat, action.target) then
                bucket = "anti_lethal"
                cheapScore = math.max(cheapScore, 92000 + defenseWeight)
                tags.blocksThreatLine = true
                tags.addressesCommandantPressure = true
                tags.preventsImmediateLoss = true
        else
            local defense = evaluateDefenseDelta(ai, state, action, playerId, enemyPlayer, ownThreat, ctx)
            stateAfter = defense and defense.afterState or stateAfter
            if defense and defense.preventedLethal then
                bucket = "anti_lethal"
                cheapScore = math.max(cheapScore, 90000 + defenseWeight + 3000)
                tags.addressesCommandantPressure = true
                tags.preventsImmediateLoss = true
            elseif defense and (defense.clearedImmediateDanger or defense.reducedProjectedDamage) then
                bucket = "supply_defense"
                cheapScore = math.max(cheapScore, 2600 + defenseWeight)
                tags.addressesCommandantPressure = true
            elseif defenseWeight > 0 and defenseWeight >= offenseWeight then
                bucket = "supply_defense"
                cheapScore = math.max(cheapScore, 2400 + defenseWeight)
            elseif offenseWeight > 0 then
                bucket = "supply_offense"
                cheapScore = math.max(cheapScore, 2200 + offenseWeight)
            else
                bucket = "fallback"
                cheapScore = math.max(cheapScore, 600)
            end
        end

        if num(details.commandantPressure, 0) > 0 then
            tags.commandantPressure = true
        end
    elseif actionType == "repair" then
        local target = getActionTarget(ai, state, action)
        local currentHp = num(target and target.currentHp, 0)
        local maxHp = num(target and target.startingHp, currentHp)
        local healed = math.max(0, maxHp - currentHp)
        local targetValue = getUnitValue(ai, target, state)

        local defense = evaluateDefenseDelta(ai, state, action, playerId, enemyPlayer, ownThreat, ctx)
        stateAfter = defense and defense.afterState or stateAfter
        if defense and (defense.preventedLethal or defense.clearedImmediateDanger or defense.reducedProjectedDamage) then
            bucket = "anti_lethal"
            cheapScore = math.max(cheapScore, 86000 + (healed * 200))
            tags.addressesCommandantPressure = true
            tags.preventsImmediateLoss = true
            if target and isHubUnit(ai, target) then
                tags.repairsCommandant = true
            end
        else
            bucket = "repair"
            cheapScore = math.max(cheapScore, 1500 + (healed * 220) + (targetValue * 8))
        end
    elseif actionType == "move" then
        local defense = evaluateDefenseDelta(ai, state, action, playerId, enemyPlayer, ownThreat, ctx)
        local afterState = defense and defense.afterState or simulateSingleAction(ai, state, action, playerId, ctx)
        stateAfter = afterState
        local evacuation = evaluateDefenseBlockerEvacuation(ai, state, afterState, action, playerId, enemyPlayer, ownThreat)

        if defense and defense.preventedLethal then
            bucket = "anti_lethal"
            cheapScore = math.max(cheapScore, 86000)
            tags.addressesCommandantPressure = true
            tags.preventsImmediateLoss = true
        elseif defense and (defense.clearedImmediateDanger or defense.reducedProjectedDamage or defense.reducedAttackerCount) then
            bucket = "defensive_move"
            cheapScore = math.max(cheapScore, 2600)
            tags.addressesCommandantPressure = true
            tags.defensivePressureMove = true
        elseif evacuation then
            bucket = "defensive_move"
            cheapScore = math.max(cheapScore, 86000 + num(evacuation.score, 0))
            tags.addressesCommandantPressure = true
            tags.defensivePressureMove = true
            tags.defensiveBlockerEvacuation = true
            tags.defensiveBlockerOpensBoardDefender = evacuation.opensBoardDefender == true
            tags.defensiveBlockerOpensDeploy = evacuation.opensDeploy == true
            tags.defensiveBlockerThreat = evacuation.threatName
        else
            local pressure = evaluatePressureDelta(ai, state, afterState, playerId, enemyPlayer, ctx)
            if pressure and (pressure.newLethal or pressure.newDanger or pressure.projectedDelta > 0) then
                bucket = "commandant_pressure"
                cheapScore = math.max(cheapScore, 2000 + (pressure.projectedDelta * 180))
                tags.commandantPressure = true
            else
                local followupFactionAttacks = 0
                local bestFollowupDamage = 0
                local bestFollowupTargetsCommandant = false
                local stage = tostring(options.stage or "")
                local checkFollowup = stage == "first" or stage == "first_actions"
                if checkFollowup and afterState and ai and ai.collectLegalActions then
                    local followups = collectLegal(ai, afterState, playerId, ctx, {
                        includeMove = false,
                        includeAttack = true,
                        includeRepair = false,
                        includeDeploy = false
                    }) or {}

                    for _, entry2 in ipairs(followups) do
                        local attackAction = entry2 and entry2.action or nil
                        if isFactionInteractionAttackAction(ai, afterState, attackAction, playerId) then
                            followupFactionAttacks = followupFactionAttacks + 1
                            local attacker2 = getActionUnit(ai, afterState, attackAction)
                            local target2 = getActionTarget(ai, afterState, attackAction)
                            local damage2 = calculateDamage(ai, attacker2, target2)
                            bestFollowupDamage = math.max(bestFollowupDamage, damage2)
                            if target2 and target2.player == enemyPlayer and isHubUnit(ai, target2) then
                                bestFollowupTargetsCommandant = true
                            end
                            if followupFactionAttacks >= 3 then
                                break
                            end
                        end
                    end
                end

                if followupFactionAttacks > 0 then
                    if bestFollowupTargetsCommandant then
                        bucket = "commandant_pressure"
                    elseif drawPressureActive then
                        bucket = "draw_reset_attack"
                    else
                        bucket = "move_attack"
                    end
                    cheapScore = math.max(
                        cheapScore,
                        2800 + (followupFactionAttacks * 280) + (bestFollowupDamage * 140) + (bestFollowupTargetsCommandant and 420 or 0)
                    )
                    tags.enablesFactionAttack = true
                    if bestFollowupTargetsCommandant then
                        tags.commandantPressure = true
                    end
                end

                local delta = positionalDelta(ai, state, afterState, action)
                if followupFactionAttacks == 0 then
                    bucket = "positional_move"
                    cheapScore = math.max(cheapScore, 1000 + (delta * 20))
                else
                    cheapScore = math.max(cheapScore, 1400 + (delta * 12))
                end

                local source = action.unit or {}
                local target = action.target or {}
                local beforeEnemyDist = nearestEnemyDistance(ai, state, source.row, source.col, enemyPlayer)
                local afterEnemyDist = nearestEnemyDistance(ai, afterState, target.row, target.col, enemyPlayer)
                local engageDelta = beforeEnemyDist - afterEnemyDist
                if engageDelta > 0 then
                    cheapScore = cheapScore + (engageDelta * 220)
                    tags.engagesEnemy = true
                elseif engageDelta < 0 then
                    cheapScore = cheapScore + (engageDelta * 120)
                end

                local drawStreak = math.max(0, num(state and state.turnsWithoutDamage, 0))
                if drawStreak > 0 then
                    local streakScale = math.min(260, 80 + (drawStreak * 40))
                    cheapScore = cheapScore + (engageDelta * streakScale)
                    if engageDelta <= 0 then
                        cheapScore = cheapScore - (drawStreak * 60)
                    end
                end
            end
        end
    elseif actionType == "skip" then
        bucket = "fallback"
        cheapScore = math.max(cheapScore, -100)
    else
        bucket = "fallback"
        cheapScore = math.max(cheapScore, 0)
    end

    return {
        bucket = bucket,
        cheapScore = math.floor(cheapScore),
        tags = tags,
        stateAfter = stateAfter
    }
end

function M.selectByBuckets(entries, limits, maxTotal)
    local grouped = {}
    for _, entry in ipairs(entries or {}) do
        local bucket = entry.bucket or "fallback"
        grouped[bucket] = grouped[bucket] or {}
        grouped[bucket][#grouped[bucket] + 1] = entry
    end

    for _, list in pairs(grouped) do
        table.sort(list, function(a, b)
            local scoreA = num(a.cheapScore, 0)
            local scoreB = num(b.cheapScore, 0)
            if scoreA ~= scoreB then
                return scoreA > scoreB
            end
            return tostring(a.signature or "") < tostring(b.signature or "")
        end)
    end

    local selected = {}
    for _, bucket in ipairs(M.BUCKET_ORDER) do
        local limit = num(limits and limits[bucket], 0)
        local list = grouped[bucket] or {}
        for i = 1, math.min(limit, #list) do
            selected[#selected + 1] = list[i]
            if maxTotal and #selected >= maxTotal then
                return selected
            end
        end
    end

    return selected
end

local function resolveLimits(mode, providedLimits)
    local limits = copyTable(providedLimits or M.BUCKET_LIMITS)
    local overrides = M.MODE_LIMIT_OVERRIDES[mode]
    if overrides then
        for bucket, value in pairs(overrides) do
            limits[bucket] = value
        end
    end
    return limits
end

local function modeAllows(mode, bucket)
    local allowed = M.MODE_ALLOWED_BUCKETS[mode]
    if not allowed then
        return true
    end
    return allowed[bucket] == true
end

local function normalizeEntry(raw)
    if type(raw) ~= "table" then
        return nil
    end

    if raw.action then
        return raw
    end

    if raw.type then
        return {
            type = raw.type,
            action = raw,
            unit = raw.unit,
            target = raw.target,
            cheapScore = raw.cheapScore
        }
    end

    return nil
end

function M.rankAndSelect(ai, state, entries, playerId, ctx, opts)
    local options = opts or {}
    local mode = options.mode
    local maxTotal = options.maxTotal or #((entries) or {})
    local minPreparedBeforeStop = math.max(0, math.min(maxTotal, num(options.minPreparedBeforeStop, 0)))
    local scanLimit = options.scanLimit
    if scanLimit == nil then
        scanLimit = math.max(maxTotal * 3, maxTotal + 16)
    end
    local limits = resolveLimits(mode, options.limits or M.BUCKET_LIMITS)

    local prepared = {}
    local seen = {}
    local prioritized = {}
    local preparedFactionAttackCount = 0
    local bestPreparedFactionAttack = nil

    for _, raw in ipairs(entries or {}) do
        local entry = normalizeEntry(raw)
        local actionType = entry and entry.action and entry.action.type or nil
        if actionType == "attack" or actionType == "supply_deploy" then
            prioritized[#prioritized + 1] = raw
        end
    end
    for _, raw in ipairs(entries or {}) do
        local entry = normalizeEntry(raw)
        local actionType = entry and entry.action and entry.action.type or nil
        if actionType ~= "attack" and actionType ~= "supply_deploy" then
            prioritized[#prioritized + 1] = raw
        end
    end

    for _, raw in ipairs(prioritized) do
        if #prepared >= minPreparedBeforeStop and ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
        if scanLimit and #prepared >= scanLimit then
            break
        end
        if maxTotal and #prepared >= (maxTotal * 2) and ctx and ctx.softStop and ctx.softStop() then
            break
        end
        local entry = normalizeEntry(raw)
        if entry and entry.action then
            local signature = tostring(entry.signature or M.actionSignature(entry.action))
            if not seen[signature] then
                local classified = M.classifyAction(ai, state, entry.action, playerId, ctx, {
                    entry = entry,
                    mode = mode,
                    stage = options.stage
                })
                local bucket = classified.bucket or "fallback"
                if modeAllows(mode, bucket) then
                    local normalized = copyTable(entry)
                    normalized.action = entry.action
                    normalized.signature = signature
                    normalized.bucket = bucket
                    normalized.cheapScore = num(classified.cheapScore, num(entry.cheapScore, 0))
                    normalized.tags = classified.tags or {}
                    normalized.stateAfter = classified.stateAfter or normalized.stateAfter
                    normalized.buckets = normalized.buckets or {bucket}
                    normalized.source = normalized.source or "tournament_action"
                    normalized.factionAttack = isFactionInteractionAttackAction(ai, state, normalized.action, playerId)
                    prepared[#prepared + 1] = normalized
                    if normalized.factionAttack then
                        preparedFactionAttackCount = preparedFactionAttackCount + 1
                        if not bestPreparedFactionAttack then
                            bestPreparedFactionAttack = normalized
                        else
                            local lhs = num(normalized.cheapScore, 0)
                            local rhs = num(bestPreparedFactionAttack.cheapScore, 0)
                            if lhs > rhs or (lhs == rhs and tostring(normalized.signature) < tostring(bestPreparedFactionAttack.signature)) then
                                bestPreparedFactionAttack = normalized
                            end
                        end
                    end
                    seen[signature] = true
                end
            end
        end
    end

    local selected = M.selectByBuckets(prepared, limits, maxTotal)
    local selectedFactionAttackCount = 0
    local selectedSignatures = {}
    for _, entry in ipairs(selected or {}) do
        selectedSignatures[tostring(entry and entry.signature or "")] = true
        if entry and entry.factionAttack then
            selectedFactionAttackCount = selectedFactionAttackCount + 1
        end
    end

    if preparedFactionAttackCount > 0
        and selectedFactionAttackCount == 0
        and bestPreparedFactionAttack
        and not selectedSignatures[tostring(bestPreparedFactionAttack.signature or "")] then
        if not maxTotal or #selected < maxTotal then
            selected[#selected + 1] = bestPreparedFactionAttack
        elseif #selected > 0 then
            selected[#selected] = bestPreparedFactionAttack
        end
        selectedFactionAttackCount = 1
        if ctx and ctx.stats then
            ctx.stats.factionAttackRescueInjected = (ctx.stats.factionAttackRescueInjected or 0) + 1
        end
    end

    if ctx and ctx.stats then
        local stage = tostring(options.stage or "")
        if stage == "first" or stage == "first_actions" then
            ctx.stats.firstActionPrepared = #prepared
            ctx.stats.firstActionFactionAttackPrepared = preparedFactionAttackCount
            ctx.stats.firstActionFactionAttackSelected = selectedFactionAttackCount
        elseif stage == "second" or stage == "second_actions" then
            ctx.stats.secondActionPrepared = (ctx.stats.secondActionPrepared or 0) + #prepared
            ctx.stats.secondActionFactionAttackPrepared = (ctx.stats.secondActionFactionAttackPrepared or 0) + preparedFactionAttackCount
            ctx.stats.secondActionFactionAttackSelected = (ctx.stats.secondActionFactionAttackSelected or 0) + selectedFactionAttackCount
        else
            ctx.stats.bucketPrepared = (ctx.stats.bucketPrepared or 0) + #prepared
            ctx.stats.bucketPreparedFactionAttack = (ctx.stats.bucketPreparedFactionAttack or 0) + preparedFactionAttackCount
        end
    end

    return selected
end

return M
