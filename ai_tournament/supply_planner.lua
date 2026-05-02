local aiConfig = require("ai_config")
local reserveModel = require("ai_tournament.reserve_model")
local earlyPlanner = require("ai_tournament.early_planner")

local M = {}

local DEFAULT_PARAMS = aiConfig and aiConfig.AI_PARAMS or {}
local DEFAULT_TOURNAMENT_CFG = DEFAULT_PARAMS.TOURNAMENT_AI or {}
local DEFAULT_EVAL_CFG = DEFAULT_PARAMS.EVAL or {}
local DEFAULT_RUNTIME_CFG = DEFAULT_PARAMS.RUNTIME or {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cfgValue(ctx, key)
    local cfg = ctx and ctx.cfg
    if cfg and cfg[key] ~= nil then
        return num(cfg[key], 0)
    end
    if DEFAULT_TOURNAMENT_CFG and DEFAULT_TOURNAMENT_CFG[key] ~= nil then
        return num(DEFAULT_TOURNAMENT_CFG[key], 0)
    end
    return 0
end

local function cfgTable(ctx, key)
    local cfg = ctx and ctx.cfg
    if cfg and type(cfg[key]) == "table" then
        return cfg[key]
    end
    if DEFAULT_TOURNAMENT_CFG and type(DEFAULT_TOURNAMENT_CFG[key]) == "table" then
        return DEFAULT_TOURNAMENT_CFG[key]
    end
    return {}
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

local function runtimeValue(key)
    return num(DEFAULT_RUNTIME_CFG and DEFAULT_RUNTIME_CFG[key], 0)
end

M.UNIT_ROLE_VECTOR = DEFAULT_TOURNAMENT_CFG.SUPPLY_ROLE_VECTOR or {}

local function zeroDemand()
    return {
        commandantDefense = 0.0,
        blocker = 0.0,
        antiGround = 0.0,
        antiFlying = 0.0,
        siege = 0.0,
        mobility = 0.0,
        repair = 0.0,
        commandantPressure = 0.0,
        reasons = {}
    }
end

local function callThreatModel(ctx, ai, state, playerToProtect, attackerPlayer)
    if not playerToProtect or not attackerPlayer then
        return nil
    end

    if ctx and ctx.cache and ctx.cache.threat then
        return ctx.cache.threat(ai, state, playerToProtect, attackerPlayer, ctx)
    end

    if ctx and ctx.threatModel and ctx.threatModel.analyzeHubThreatForPlayer then
        return ctx.threatModel.analyzeHubThreatForPlayer(ai, state, playerToProtect, attackerPlayer, ctx)
    end

    if ai and ai.analyzeHubThreatForPlayer then
        return ai:analyzeHubThreatForPlayer(state, playerToProtect, attackerPlayer, ctx)
    end

    return nil
end

local function countDamagedAllies(ai, state, playerId)
    if ai and ai.countDamagedFriendlyUnits then
        return ai:countDamagedFriendlyUnits(state, playerId, {includeHub = true}) or 0
    end

    local damaged = 0
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == playerId then
            local currentHp = unit.currentHp or unit.startingHp or 0
            local maxHp = unit.startingHp or currentHp
            if currentHp < maxHp then
                damaged = damaged + 1
            end
        end
    end

    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if hub then
        local currentHp = hub.currentHp or hub.startingHp or 0
        local maxHp = hub.startingHp or currentHp
        if currentHp < maxHp then
            damaged = damaged + 1
        end
    end

    return damaged
end

local function scoreRoleFit(unitName, demand, ctx)
    local roleVector = cfgTable(ctx, "SUPPLY_ROLE_VECTOR")
    local vector = roleVector[unitName] or M.UNIT_ROLE_VECTOR[unitName] or {}
    local weight = cfgValue(ctx, "SUPPLY_ROLE_FIT_WEIGHT")
    local score = 0
    for role, need in pairs(demand or {}) do
        if type(need) == "number" then
            score = score + (vector[role] or 0) * need * weight
        end
    end
    return score
end

local function isSlowSiegeUnit(unitName, ctx)
    local roleVector = cfgTable(ctx, "SUPPLY_ROLE_VECTOR")
    local vector = roleVector[unitName] or M.UNIT_ROLE_VECTOR[unitName] or {}
    return num(vector.siege, 0) >= cfgValue(ctx, "EARLY_SLOW_SIEGE_MIN_SIEGE")
        and num(vector.mobility, 0) <= cfgValue(ctx, "EARLY_SLOW_SIEGE_MAX_MOBILITY")
end

local function hasEarlyNonSlowPresenceDeployOption(state, playerId, ctx, exceptUnitName)
    local supply = state and state.supply and state.supply[playerId] or {}
    if #supply == 0 then
        return false
    end

    local roleVector = cfgTable(ctx, "SUPPLY_ROLE_VECTOR")
    local mobilityMin = cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_ALT_MOBILITY_MIN")
    local combatMin = cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_ALT_COMBAT_MIN")

    for _, unit in ipairs(supply) do
        local unitName = tostring(unit and unit.name or "")
        if unitName ~= "" and unitName ~= tostring(exceptUnitName or "") and not isSlowSiegeUnit(unitName, ctx) then
            local vector = roleVector[unitName] or M.UNIT_ROLE_VECTOR[unitName] or {}
            local combat =
                num(vector.antiGround, 0)
                + num(vector.antiFlying, 0)
                + num(vector.commandantPressure, 0)
                + (num(vector.blocker, 0) * 0.5)
            if num(vector.mobility, 0) >= mobilityMin or combat >= combatMin then
                return true
            end
        end
    end

    return false
end

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
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

local function copyState(ai, state)
    if ai and ai.deepCopyState then
        local ok, copied = pcall(ai.deepCopyState, ai, state)
        if ok and copied then
            return copied
        end
    end
    return deepCopy(state)
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

local function getUnitAt(ai, state, row, col)
    if not state or not row or not col then
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

local function findMatchingUnit(ai, state, reference)
    if not (state and reference) then
        return nil
    end

    local unit = getUnitAt(ai, state, reference.row, reference.col)
    if unit
        and unit.player == reference.player
        and tostring(unit.name or "") == tostring(reference.name or "") then
        return unit
    end

    for _, candidate in ipairs(state.units or {}) do
        if candidate
            and candidate.player == reference.player
            and tostring(candidate.name or "") == tostring(reference.name or "") then
            return candidate
        end
    end

    return nil
end

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function unitAttackRange(ai, unit)
    local range = unit and unit.atkRange
    if range == nil and ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        range = ai.unitsInfo:getUnitAttackRange(unit, "SUPPLY_PLANNER_ATTACK_RANGE")
    end
    return num(range, 1)
end

local function unitValue(ai, unit)
    if not unit then
        return 0
    end
    if ai and ai.getUnitBaseValue then
        local ok, value = pcall(ai.getUnitBaseValue, ai, unit)
        if ok and value ~= nil then
            return num(value, 0)
        end
    end
    local values = DEFAULT_EVAL_CFG.UNIT_VALUES or {}
    local fallback = cfgValue(nil, "SUPPLY_UNIT_VALUE_FALLBACK")
    return num(values[unit.name], fallback)
end

local function isMeleeCombatUnit(ai, unit)
    return unit
        and not isHubUnit(ai, unit)
        and not isObstacleUnit(ai, unit)
        and unitAttackRange(ai, unit) <= 1
end

local function manhattan(a, b)
    if not a or not b then
        return cfgValue(nil, "DEPLOY_DISTANCE_FALLBACK")
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function nearestObstacleDistance(state, cell)
    if not (state and cell and cell.row and cell.col) then
        return 99
    end

    local best = 99
    for _, rock in ipairs(state.neutralBuildings or {}) do
        if rock and rock.row and rock.col then
            best = math.min(best, manhattan(cell, rock))
        end
    end
    for _, unit in ipairs(state.units or {}) do
        if unit and (unit.player == 0 or unit.name == "Rock") then
            best = math.min(best, manhattan(cell, unit))
        end
    end
    return best
end

local function strategicCellKey(cell)
    return tostring(num(cell and cell.row, 0)) .. "," .. tostring(num(cell and cell.col, 0))
end

local function addStrategicCells(result, seen, cells)
    for _, cell in ipairs(cells or {}) do
        if cell and cell.row and cell.col then
            local key = strategicCellKey(cell)
            if not seen[key] then
                seen[key] = true
                result[#result + 1] = {row = cell.row, col = cell.col}
            end
        end
    end
end

local function earlyPlanStrategicCells(plan)
    local cells = {}
    local seen = {}
    addStrategicCells(cells, seen, plan and plan.vanguardCells)
    addStrategicCells(cells, seen, plan and plan.denyCells)
    addStrategicCells(cells, seen, plan and plan.supportCells)
    return cells
end

local function hasStrategicLineOfSight(ai, state, unit, cell)
    if unitAttackRange(ai, unit) <= 1 or not (ai and ai.hasLineOfSight) then
        return true
    end
    local ok, value = pcall(ai.hasLineOfSight, ai, state, unit, cell)
    return ok and value == true
end

local function unitControlsStrategicCell(ai, state, unit, cell, ctx)
    if not (unit and cell) then
        return false, false
    end
    if isSlowSiegeUnit(unit.name, ctx) then
        return false, false
    end

    local occupied = unit.row == cell.row and unit.col == cell.col
    if occupied then
        return true, true
    end

    local controlRange = math.max(cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_CONTROL_RADIUS"), unitAttackRange(ai, unit))
    if manhattan(unit, cell) <= controlRange and hasStrategicLineOfSight(ai, state, unit, cell) then
        return true, false
    end
    return false, false
end

local function evaluateStrategicPresence(ai, state, playerId, ctx)
    local result = {
        controlledCells = 0,
        occupiedCells = 0,
        totalCells = 0
    }
    local cells = earlyPlanStrategicCells(ctx and ctx.earlyPlan)
    result.totalCells = #cells
    if #cells == 0 then
        return result
    end

    local controlled = {}
    local occupied = {}
    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit)
            and unitHp(unit) > 0
            and not isSlowSiegeUnit(unit.name, ctx) then
            for _, cell in ipairs(cells) do
                local controls, occupies = unitControlsStrategicCell(ai, state, unit, cell, ctx)
                if controls then
                    controlled[strategicCellKey(cell)] = true
                end
                if occupies then
                    occupied[strategicCellKey(cell)] = true
                end
            end
        end
    end

    for _ in pairs(controlled) do
        result.controlledCells = result.controlledCells + 1
    end
    for _ in pairs(occupied) do
        result.occupiedCells = result.occupiedCells + 1
    end

    return result
end

local function evaluateEarlySlowSiegeSetup(ai, state, deployAction, playerId, ctx)
    local result = {
        valid = false,
        ownUnits = 0,
        forwardUnits = 0,
        strategicCells = 0,
        occupiedStrategicCells = 0,
        totalStrategicCells = 0,
        supportDistance = 99,
        obstacleDistance = 99,
        progress = 0
    }

    if not (state and deployAction and deployAction.target and playerId and ctx and ctx.earlyPlan and ctx.earlyPlan.active == true) then
        return result
    end

    local ownHub = state.commandHubs and state.commandHubs[playerId]
    local enemyPlayer = getOpponent(ai, playerId)
    local enemyHub = state.commandHubs and state.commandHubs[enemyPlayer]
    if not (ownHub and enemyHub) then
        return result
    end

    local target = deployAction.target
    local hubDistance = manhattan(ownHub, enemyHub)
    local targetDistance = manhattan(target, enemyHub)
    result.progress = hubDistance - targetDistance
    result.obstacleDistance = nearestObstacleDistance(state, target)

    for _, unit in ipairs(state.units or {}) do
        if unit
            and unit.player == playerId
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit)
            and unitHp(unit) > 0 then
            result.ownUnits = result.ownUnits + 1
            result.supportDistance = math.min(result.supportDistance, manhattan(unit, target))
            if not isSlowSiegeUnit(unit.name, ctx) then
                local unitProgress = hubDistance - manhattan(unit, enemyHub)
                if unitProgress >= 1 then
                    result.forwardUnits = result.forwardUnits + 1
                end
            end
        end
    end

    local strategicPresence = evaluateStrategicPresence(ai, state, playerId, ctx)
    result.strategicCells = strategicPresence.controlledCells
    result.occupiedStrategicCells = strategicPresence.occupiedCells
    result.totalStrategicCells = strategicPresence.totalCells

    local enoughBodies = result.ownUnits >= cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_MIN_OWN_UNITS")
    local enoughPresence = enoughBodies
        and result.strategicCells >= cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_MIN_STRATEGIC_CELLS")
    local enoughForward = result.forwardUnits >= cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_MIN_FORWARD_UNITS")
    local supported = result.supportDistance <= cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_SUPPORT_RADIUS")
    local covered = result.obstacleDistance <= cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_ROCK_RADIUS")
    local notVanguard = result.progress <= cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_MAX_PROGRESS")

    result.valid = enoughPresence and enoughForward and supported and covered and notVanguard
    return result
end

local function unitCanAttackTarget(ai, state, unit, target)
    if not (ai and state and unit and target and ai.getValidAttackCells) then
        return false
    end
    local cells = ai:getValidAttackCells(state, unit.row, unit.col) or {}
    for _, cell in ipairs(cells) do
        if cell.row == target.row and cell.col == target.col then
            return true
        end
    end
    return false
end

local function unitCanThreatenTargetNextTurn(ai, state, unit, target)
    if unitCanAttackTarget(ai, state, unit, target) then
        return true, unit, "direct_attack", {
            etaActions = 0,
            moveDistance = 0,
            finalDistance = manhattan(unit, target)
        }
    end
    if not (ai and ai.getValidMoveCells and unit and target) then
        return false, nil, nil
    end

    local best = nil
    local moveCells = ai:getValidMoveCells(state, unit.row, unit.col) or {}
    for _, cell in ipairs(moveCells) do
        local simulated = copyState(ai, state)
        local movedUnit = findMatchingUnit(ai, simulated, unit)
        local simulatedTarget = findMatchingUnit(ai, simulated, target)
        if movedUnit and simulatedTarget then
            movedUnit.row = cell.row
            movedUnit.col = cell.col
            movedUnit.hasMoved = false
            movedUnit.hasActed = false
            movedUnit.actionsUsed = 0
            if unitCanAttackTarget(ai, simulated, movedUnit, simulatedTarget) then
                local routeInfo = {
                    etaActions = 1,
                    moveDistance = math.abs(num(cell.row, unit.row) - num(unit.row, 0))
                        + math.abs(num(cell.col, unit.col) - num(unit.col, 0)),
                    finalDistance = manhattan(movedUnit, simulatedTarget),
                    row = cell.row,
                    col = cell.col
                }
                local candidate = {
                    unit = movedUnit,
                    routeInfo = routeInfo
                }
                if not best
                    or routeInfo.moveDistance < best.routeInfo.moveDistance
                    or (routeInfo.moveDistance == best.routeInfo.moveDistance
                        and routeInfo.finalDistance < best.routeInfo.finalDistance)
                    or (routeInfo.moveDistance == best.routeInfo.moveDistance
                        and routeInfo.finalDistance == best.routeInfo.finalDistance
                        and num(routeInfo.row, 0) < num(best.routeInfo.row, 0))
                    or (routeInfo.moveDistance == best.routeInfo.moveDistance
                        and routeInfo.finalDistance == best.routeInfo.finalDistance
                        and num(routeInfo.row, 0) == num(best.routeInfo.row, 0)
                        and num(routeInfo.col, 0) < num(best.routeInfo.col, 0)) then
                    best = candidate
                end
            end
        end
    end

    if best then
        return true, best.unit, "move_attack", best.routeInfo
    end

    return false, nil, nil
end

local function sortDeployEntries(entries)
    table.sort(entries, function(a, b)
        local sa = tonumber(a.cheapScore) or -math.huge
        local sb = tonumber(b.cheapScore) or -math.huge
        if sa ~= sb then
            return sa > sb
        end

        local aa = a.action or {}
        local ab = b.action or {}

        local nameA = tostring(aa.unitName or "?")
        local nameB = tostring(ab.unitName or "?")
        if nameA ~= nameB then
            return nameA < nameB
        end

        local targetA = aa.target or {}
        local targetB = ab.target or {}
        local rowA = tonumber(targetA.row) or 0
        local rowB = tonumber(targetB.row) or 0
        if rowA ~= rowB then
            return rowA < rowB
        end

        local colA = tonumber(targetA.col) or 0
        local colB = tonumber(targetB.col) or 0
        if colA ~= colB then
            return colA < colB
        end

        local idxA = tonumber(aa.unitIndex) or 0
        local idxB = tonumber(ab.unitIndex) or 0
        return idxA < idxB
    end)
end

local function trim(entries, maxCount)
    if maxCount and maxCount > 0 and #entries > maxCount then
        for idx = #entries, maxCount + 1, -1 do
            entries[idx] = nil
        end
    end
    return entries
end

local function getEnemyAttackersOnCell(ai, state, enemyPlayer, row, col)
    if not ai or not state then
        return 0, 0
    end

    local prepared = ai:prepareStateForPlayerTurn(state, enemyPlayer, {
        resetActionCount = true,
        resetDeployment = true,
        resetFirstActionRangedAttack = true
    })

    local attackers = 0
    local projectedDamage = 0

    for _, unit in ipairs(prepared.units or {}) do
        if unit
            and unit.player == enemyPlayer
            and not ai:isHubUnit(unit)
            and not ai:isObstacleUnit(unit) then
            local attackCells = ai:getValidAttackCells(prepared, unit.row, unit.col) or {}
            for _, cell in ipairs(attackCells) do
                if cell.row == row and cell.col == col then
                    attackers = attackers + 1
                    local target = ai:getUnitAtPosition(prepared, row, col)
                    if target then
                        projectedDamage = projectedDamage + (ai:calculateDamage(unit, target) or 0)
                    end
                    break
                end
            end
        end
    end

    return attackers, projectedDamage
end

local function getImmediateMeleeThreatsToAllies(ai, state, playerId)
    local threats = {}
    if not (ai and state and playerId and ai.getValidAttackCells) then
        return threats
    end

    local enemyPlayer = getOpponent(ai, playerId)
    local prepared = state
    if ai.prepareStateForPlayerTurn then
        prepared = ai:prepareStateForPlayerTurn(state, enemyPlayer, {
            resetActionCount = true,
            resetDeployment = true,
            resetFirstActionRangedAttack = true
        })
    end

    for _, enemy in ipairs(prepared.units or {}) do
        if enemy and enemy.player == enemyPlayer and isMeleeCombatUnit(ai, enemy) then
            local attackCells = ai:getValidAttackCells(prepared, enemy.row, enemy.col) or {}
            for _, cell in ipairs(attackCells) do
                local target = getUnitAt(ai, prepared, cell.row, cell.col)
                if target
                    and target.player == playerId
                    and not isHubUnit(ai, target)
                    and not isObstacleUnit(ai, target) then
                    local damage = 0
                    if ai.calculateDamage then
                        damage = num(ai:calculateDamage(enemy, target), 0)
                    end
                    if damage > 0 then
                        local hp = unitHp(target)
                        threats[#threats + 1] = {
                            attacker = {
                                name = enemy.name,
                                player = enemy.player,
                                row = enemy.row,
                                col = enemy.col,
                                currentHp = enemy.currentHp,
                                startingHp = enemy.startingHp,
                                fly = enemy.fly,
                                atkRange = enemy.atkRange,
                                atkDamage = enemy.atkDamage,
                                move = enemy.move
                            },
                            targetName = target.name,
                            targetValue = unitValue(ai, target),
                            targetHp = hp,
                            damage = damage,
                            targetWouldDie = hp > 0 and damage >= hp
                        }
                    end
                end
            end
        end
    end

    return threats
end

local function getImmediateCommandantThreats(ai, state, playerId, ctx)
    local threats = {}
    if not (ai and state and playerId) then
        return threats, nil
    end

    local enemyPlayer = getOpponent(ai, playerId)
    local threat = callThreatModel(ctx, ai, state, playerId, enemyPlayer)
    if not (threat and threat.immediateDanger) then
        return threats, threat
    end

    local hub = state.commandHubs and state.commandHubs[playerId]
    local hubHp = unitHp(hub)
    for _, entry in ipairs(threat.damagingAttackers or {}) do
        local attacker = entry and entry.unit
        if attacker then
            local damage = num(entry.damage, 0)
            threats[#threats + 1] = {
                attacker = {
                    name = attacker.name,
                    player = attacker.player,
                    row = attacker.row,
                    col = attacker.col,
                    currentHp = attacker.currentHp,
                    startingHp = attacker.startingHp,
                    fly = attacker.fly,
                    atkRange = attacker.atkRange,
                    atkDamage = attacker.atkDamage,
                    move = attacker.move
                },
                targetName = "Commandant",
                targetValue = unitValue(ai, {name = "Commandant"}),
                targetHp = hubHp,
                damage = damage,
                targetWouldDie = hubHp > 0 and damage >= hubHp,
                attackRange = unitAttackRange(ai, attacker)
            }
        end
    end

    return threats, threat
end

local function evaluateCommandantThreatCounterDeploy(ai, state, afterState, deployAction, playerId, ctx)
    local result = {
        value = 0,
        reason = nil,
        survives = nil,
        damage = 0,
        lethal = false
    }
    if not (ai and state and afterState and deployAction and deployAction.target and playerId) then
        return result
    end

    local threats, beforeThreat = getImmediateCommandantThreats(ai, state, playerId, ctx)
    if #threats == 0 then
        return result
    end

    local enemyPlayer = getOpponent(ai, playerId)
    local afterThreat = callThreatModel(ctx, ai, afterState, playerId, enemyPlayer)
    if beforeThreat and beforeThreat.immediateLethal and afterThreat and afterThreat.immediateLethal then
        result.value = -cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_LEAVES_LETHAL_PENALTY")
        result.reason = "commandant_counter_deploy_leaves_lethal"
        return result
    end

    local deployed = getUnitAt(ai, afterState, deployAction.target.row, deployAction.target.col)
    if not deployed or deployed.player ~= playerId then
        return result
    end

    local _, projectedDamage = getEnemyAttackersOnCell(
        ai,
        afterState,
        enemyPlayer,
        deployAction.target.row,
        deployAction.target.col
    )
    local deployedHp = unitHp(deployed)
    local survives = deployedHp > 0 and projectedDamage < deployedHp
    result.survives = survives

    local nextOwnTurn = afterState
    if ai.prepareStateForPlayerTurn then
        nextOwnTurn = ai:prepareStateForPlayerTurn(afterState, playerId, {
            resetActionCount = true,
            resetDeployment = true,
            resetFirstActionRangedAttack = true
        })
    end

    local deployedNext = findMatchingUnit(ai, nextOwnTurn, deployed)
    if not deployedNext then
        return result
    end

    local baseScore = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_BASE_SCORE")
    local damageWeight = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_DAMAGE_WEIGHT")
    local threatDamageWeight = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_THREAT_DAMAGE_WEIGHT")
    local survivalBonus = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_SURVIVAL_BONUS")
    local killBonus = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_KILL_BONUS")
    local directRouteBonus = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_DIRECT_ROUTE_BONUS")
    local moveAttackRouteBonus = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_MOVE_ATTACK_ROUTE_BONUS")
    local etaActionPenalty = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_ETA_ACTION_PENALTY")
    local moveDistancePenalty = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_MOVE_DISTANCE_PENALTY")
    local diesPenalty = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_DIES_PENALTY")
    local noContestPenalty = cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_NO_CONTEST_PENALTY")

    local best = nil
    for _, threat in ipairs(threats) do
        local attacker = findMatchingUnit(ai, nextOwnTurn, threat.attacker)
        if attacker and unitHp(attacker) > 0 then
            local canThreaten, projectedUnit, route, routeInfo =
                unitCanThreatenTargetNextTurn(ai, nextOwnTurn, deployedNext, attacker)
            if canThreaten then
                local damage = 0
                if ai.calculateDamage then
                    damage = num(ai:calculateDamage(projectedUnit or deployedNext, attacker), 0)
                end
                if damage > 0 then
                    local attackerHp = unitHp(attacker)
                    local lethal = attackerHp > 0 and damage >= attackerHp
                    local etaActions = num(routeInfo and routeInfo.etaActions, route == "direct_attack" and 0 or 1)
                    local moveDistance = num(routeInfo and routeInfo.moveDistance, route == "direct_attack" and 0 or 1)
                    local value = baseScore
                        + (damage * damageWeight)
                        + (num(threat.damage, 0) * threatDamageWeight)
                        - (etaActions * etaActionPenalty)
                        - (moveDistance * moveDistancePenalty)
                    if lethal then
                        value = value + killBonus
                    end
                    if route == "direct_attack" then
                        value = value + directRouteBonus
                    elseif route == "move_attack" then
                        value = value + moveAttackRouteBonus
                    end
                    if survives then
                        value = value + survivalBonus
                    else
                        value = value - diesPenalty
                    end

                    if not best or value > best.value then
                        best = {
                            value = value,
                            damage = damage,
                            lethal = lethal,
                            route = route,
                            etaActions = etaActions,
                            moveDistance = moveDistance,
                            attackerName = attacker.name
                        }
                    end
                end
            end
        end
    end

    if best then
        result.value = best.value
        result.damage = best.damage
        result.lethal = best.lethal
        result.route = best.route
        result.etaActions = best.etaActions
        result.moveDistance = best.moveDistance
        result.survives = survives
        if survives then
            result.reason = "commandant_threat_counter_deploy"
        else
            result.reason = "commandant_threat_counter_deploy_dies_before_counter"
        end
    elseif projectedDamage > 0 and not survives then
        result.value = -math.floor(diesPenalty * cfgValue(ctx, "DEPLOY_COMMANDANT_COUNTER_DIES_NO_COUNTER_MULT"))
        result.reason = "commandant_threat_counter_deploy_dies_without_counter"
    else
        local beforeDamage = num(beforeThreat and beforeThreat.projectedDamage, 0)
        local afterDamage = num(afterThreat and afterThreat.projectedDamage, beforeDamage)
        if afterDamage >= beforeDamage then
            result.value = -noContestPenalty
            result.reason = "commandant_threat_counter_deploy_no_contest"
        end
    end

    return result
end

local function evaluateMeleeDefenseDeploy(ai, state, afterState, deployAction, playerId, ctx)
    local result = {
        value = 0,
        reason = nil,
        survives = nil,
        damage = 0,
        lethal = false
    }
    if not (ai and state and afterState and deployAction and deployAction.target and playerId) then
        return result
    end

    local threats = getImmediateMeleeThreatsToAllies(ai, state, playerId)
    if #threats == 0 then
        return result
    end

    local deployed = getUnitAt(ai, afterState, deployAction.target.row, deployAction.target.col)
    if not deployed or deployed.player ~= playerId then
        return result
    end

    local enemyPlayer = getOpponent(ai, playerId)
    local _, projectedDamage = getEnemyAttackersOnCell(
        ai,
        afterState,
        enemyPlayer,
        deployAction.target.row,
        deployAction.target.col
    )
    local deployedHp = unitHp(deployed)
    local survives = deployedHp > 0 and projectedDamage < deployedHp
    result.survives = survives

    local nextOwnTurn = afterState
    if ai.prepareStateForPlayerTurn then
        nextOwnTurn = ai:prepareStateForPlayerTurn(afterState, playerId, {
            resetActionCount = true,
            resetDeployment = true,
            resetFirstActionRangedAttack = true
        })
    end

    local deployedNext = findMatchingUnit(ai, nextOwnTurn, deployed)
    if not deployedNext then
        return result
    end

    local damageWeight = cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_DAMAGE_WEIGHT")
    local protectedDamageWeight = cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_PROTECTED_DAMAGE_WEIGHT")
    local survivalBonus = cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_SURVIVAL_BONUS")
    local killBonus = cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_KILL_BONUS")
    local targetKillBonus = cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_PROTECT_LETHAL_BONUS")
    local highValueBonusWeight = cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_TARGET_VALUE_WEIGHT")
    local diesPenalty = cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_DIES_PENALTY")

    local best = nil
    for _, threat in ipairs(threats) do
        local attacker = findMatchingUnit(ai, nextOwnTurn, threat.attacker)
        if attacker and unitHp(attacker) > 0 then
            local canThreaten, projectedUnit, route = unitCanThreatenTargetNextTurn(ai, nextOwnTurn, deployedNext, attacker)
            if canThreaten then
                local damage = 0
                if ai.calculateDamage then
                    damage = num(ai:calculateDamage(projectedUnit or deployedNext, attacker), 0)
                end
                if damage > 0 then
                    local attackerHp = unitHp(attacker)
                    local lethal = attackerHp > 0 and damage >= attackerHp
                    local value = (damage * damageWeight)
                        + (num(threat.damage, 0) * protectedDamageWeight)
                        + (num(threat.targetValue, 0) * highValueBonusWeight)
                    if lethal then
                        value = value + killBonus
                    end
                    if threat.targetWouldDie then
                        value = value + targetKillBonus
                    end
                    if survives then
                        value = value + survivalBonus
                    else
                        value = value - diesPenalty
                    end

                    if not best or value > best.value then
                        best = {
                            value = value,
                            damage = damage,
                            lethal = lethal,
                            route = route,
                            targetName = threat.targetName,
                            attackerName = attacker.name
                        }
                    end
                end
            end
        end
    end

    if best then
        result.value = best.value
        result.damage = best.damage
        result.lethal = best.lethal
        result.route = best.route
        result.survives = survives
        if survives then
            result.reason = "melee_defense_counter_deploy"
        else
            result.reason = "melee_defense_deploy_dies_before_counter"
        end
    elseif projectedDamage > 0 and not survives then
        result.value = -math.floor(diesPenalty * cfgValue(ctx, "DEPLOY_MELEE_DEFENSE_DIES_NO_COUNTER_MULT"))
        result.reason = "melee_defense_deploy_dies_without_counter"
    end

    return result
end

local function scorePerspectiveDeployCell(ai, state, deployAction, playerId, demand, ctx)
    if not (state and deployAction and deployAction.target and playerId) then
        return 0, false
    end

    local ownHub = state.commandHubs and state.commandHubs[playerId]
    local enemyPlayer = getOpponent(ai, playerId)
    local enemyHub = state.commandHubs and state.commandHubs[enemyPlayer]
    if not ownHub or not enemyHub then
        return 0, false
    end

    local row = num(deployAction.target.row, ownHub.row)
    local col = num(deployAction.target.col, ownHub.col)
    local beforeDist = math.abs(num(ownHub.row, row) - num(enemyHub.row, row))
        + math.abs(num(ownHub.col, col) - num(enemyHub.col, col))
    local afterDist = math.abs(row - num(enemyHub.row, row)) + math.abs(col - num(enemyHub.col, col))
    local forwardGain = beforeDist - afterDist

    local pressureNeed = num(demand and demand.commandantPressure, 0)
        + num(demand and demand.siege, 0)
        + (num(demand and demand.mobility, 0) * cfgValue(ctx, "DEPLOY_PERSPECTIVE_MOBILITY_PRESSURE_WEIGHT"))
    local defenseNeed = num(demand and demand.commandantDefense, 0) + num(demand and demand.blocker, 0)

    local score = clamp(
        forwardGain * (
            cfgValue(ctx, "DEPLOY_PERSPECTIVE_FORWARD_BASE")
            + pressureNeed * cfgValue(ctx, "DEPLOY_PERSPECTIVE_PRESSURE_WEIGHT")
        ),
        cfgValue(ctx, "DEPLOY_PERSPECTIVE_MIN"),
        cfgValue(ctx, "DEPLOY_PERSPECTIVE_MAX")
    )

    local gridSize = num(
        state.gridSize
            or state.gridRows
            or (_G.GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE),
        runtimeValue("DEFAULT_GRID_SIZE")
    )
    local centerRow = (gridSize + 1) / 2
    local centerCol = (gridSize + 1) / 2
    local centerDistance = math.abs(row - centerRow) + math.abs(col - centerCol)
    score = score + clamp(
        cfgValue(ctx, "DEPLOY_PERSPECTIVE_CENTER_SCORE")
            - (centerDistance * cfgValue(ctx, "DEPLOY_PERSPECTIVE_CENTER_DISTANCE_PENALTY")),
        cfgValue(ctx, "DEPLOY_PERSPECTIVE_CENTER_MIN"),
        cfgValue(ctx, "DEPLOY_PERSPECTIVE_CENTER_MAX")
    )

    if deployAction.unitName == "Artillery" or deployAction.unitName == "Cloudstriker" then
        if row == enemyHub.row or col == enemyHub.col then
            score = score + cfgValue(ctx, "DEPLOY_PERSPECTIVE_RANGED_ALIGNMENT_BONUS")
        end
    end

    if defenseNeed > cfgValue(ctx, "DEPLOY_PERSPECTIVE_DEFENSE_NEED_THRESHOLD") then
        local ownDistance = math.abs(row - ownHub.row) + math.abs(col - ownHub.col)
        score = score + clamp(
            (cfgValue(ctx, "DEPLOY_PERSPECTIVE_DEFENSE_RADIUS") - ownDistance)
                * defenseNeed
                * cfgValue(ctx, "DEPLOY_PERSPECTIVE_DEFENSE_WEIGHT"),
            cfgValue(ctx, "DEPLOY_PERSPECTIVE_DEFENSE_MIN"),
            cfgValue(ctx, "DEPLOY_PERSPECTIVE_DEFENSE_MAX")
        )
    end

    return score, math.abs(score) > 0
end

local function evaluateCloudstrikerPressure(ai, afterState, playerId, deployAction, ctx)
    if deployAction.unitName ~= "Cloudstriker" then
        return 0, false
    end

    local enemyPlayer = ai:getOpponentPlayer(playerId)
    local enemyHub = afterState and afterState.commandHubs and afterState.commandHubs[enemyPlayer]
    if not enemyHub then
        return 0, false
    end

    local deployed = ai:getUnitAtPosition(afterState, deployAction.target.row, deployAction.target.col)
    if not deployed then
        return 0, false
    end

    local distance = math.abs((deployed.row or 0) - (enemyHub.row or 0)) + math.abs((deployed.col or 0) - (enemyHub.col or 0))
    if distance <= 1 then
        return 0, false
    end

    local inRange = distance <= (
        deployed.atkRange
        or ai.unitsInfo:getUnitAttackRange(deployed, "SUPPLY_PLANNER")
        or cfgValue(ctx, "DEPLOY_DEFAULT_ATTACK_RANGE")
    )
    if inRange and ai:hasLineOfSight(afterState, deployed, enemyHub) then
        return cfgValue(ctx, "DEPLOY_CLOUDSTRIKER_PRESSURE_BONUS"), true
    end

    return 0, false
end

function M.buildRoleDemand(ai, state, playerId, ctx)
    local demand = zeroDemand()
    if not ai or not state or not playerId then
        demand.reasons[#demand.reasons + 1] = "invalid_input"
        return demand
    end

    local enemyPlayer = ai:getOpponentPlayer(playerId)
    local enemyHub = state.commandHubs and state.commandHubs[enemyPlayer]

    local ownHubThreat = callThreatModel(ctx, ai, state, playerId, enemyPlayer)
    if ownHubThreat and ownHubThreat.immediateDanger then
        demand.commandantDefense = math.max(
            demand.commandantDefense,
            cfgValue(ctx, "SUPPLY_DEMAND_IMMEDIATE_COMMANDANT_DEFENSE")
        )
        demand.blocker = math.max(demand.blocker, cfgValue(ctx, "SUPPLY_DEMAND_IMMEDIATE_BLOCKER"))
        demand.reasons[#demand.reasons + 1] = "own_commandant_threatened"
    end

    if ownHubThreat and (ownHubThreat.projectedDamage or 0) > 0 then
        demand.commandantDefense = math.max(
            demand.commandantDefense,
            cfgValue(ctx, "SUPPLY_DEMAND_PROJECTED_COMMANDANT_DEFENSE")
        )
        demand.blocker = math.max(demand.blocker, cfgValue(ctx, "SUPPLY_DEMAND_PROJECTED_BLOCKER"))
    end

    for _, enemy in ipairs(state.units or {}) do
        if enemy
            and enemy.player == enemyPlayer
            and not ai:isHubUnit(enemy)
            and not ai:isObstacleUnit(enemy) then
            if enemy.fly then
                demand.antiFlying = math.max(demand.antiFlying, cfgValue(ctx, "SUPPLY_DEMAND_ANTI_FLYING"))
            else
                demand.antiGround = math.max(demand.antiGround, cfgValue(ctx, "SUPPLY_DEMAND_ANTI_GROUND"))
            end
        end
    end

    if enemyHub then
        demand.commandantPressure = math.max(
            demand.commandantPressure,
            cfgValue(ctx, "SUPPLY_DEMAND_COMMANDANT_PRESSURE")
        )
        demand.siege = math.max(demand.siege, cfgValue(ctx, "SUPPLY_DEMAND_SIEGE"))
    end

    local damagedAllies = countDamagedAllies(ai, state, playerId)
    if damagedAllies > 0 then
        demand.repair = clamp(
            cfgValue(ctx, "SUPPLY_DEMAND_REPAIR_BASE")
                + damagedAllies * cfgValue(ctx, "SUPPLY_DEMAND_REPAIR_PER_DAMAGED"),
            0.0,
            cfgValue(ctx, "SUPPLY_DEMAND_REPAIR_MAX")
        )
        demand.reasons[#demand.reasons + 1] = "damaged_allies_present"
    end

    local ownUnits = 0
    for _, unit in ipairs(state.units or {}) do
        if unit and unit.player == playerId and not ai:isHubUnit(unit) and not ai:isObstacleUnit(unit) then
            ownUnits = ownUnits + 1
        end
    end
    if ownUnits <= cfgValue(ctx, "SUPPLY_LOW_BOARD_PRESENCE_MAX_UNITS") then
        demand.mobility = math.max(demand.mobility, cfgValue(ctx, "SUPPLY_DEMAND_LOW_BOARD_MOBILITY"))
        demand.reasons[#demand.reasons + 1] = "low_board_presence"
    end

    if ctx and ctx.earlyPlan and ctx.earlyPlan.active == true then
        local contracts = ctx.activeContracts or {}
        if contracts.defenseActive ~= true and not isPipelineV2EarlyRuntime(ctx) then
            earlyPlanner.applyDemandBias(demand, ctx.earlyPlan, ctx)
        elseif contracts.defenseActive ~= true and isPipelineV2EarlyRuntime(ctx) then
            bumpStat(ctx, "pipelineV2EarlyPlannerDemandBiasSkipped")
        end
    end

    return demand
end

function M.scoreDeployCheap(ai, state, deployAction, playerId, ctx, demand)
    local details = {
        roleFit = 0,
        immediateDefense = 0,
        commandantPressure = 0,
        commandantThreatCounter = 0,
        meleeDefense = 0,
        perspectiveTempo = 0,
        laneValue = 0,
        repairValue = 0,
        cellQuality = 0,
        exposurePenalty = 0,
        noImpactPenalty = 0,
        reserveScarcityPenalty = 0,
        reserveScarcityImpact = 0,
        earlyIntent = 0,
        reasons = {}
    }

    if not ai or not state or not deployAction or not playerId then
        details.reasons[#details.reasons + 1] = "invalid_input"
        return cfgValue(ctx, "DEPLOY_INVALID_SCORE"), details
    end

    local roleDemand = demand or M.buildRoleDemand(ai, state, playerId, ctx)
    details.roleFit = scoreRoleFit(deployAction.unitName, roleDemand, ctx)

    local afterState = ai:applySupplyDeploymentForPlayer(state, deployAction, playerId, {
        scoreDeployments = false
    })

    local enemyPlayer = ai:getOpponentPlayer(playerId)
    local beforeThreat = callThreatModel(ctx, ai, state, playerId, enemyPlayer)
    local afterThreat = callThreatModel(ctx, ai, afterState, playerId, enemyPlayer)

    local blockedImmediateDanger = beforeThreat and beforeThreat.immediateDanger
        and afterThreat and not afterThreat.immediateDanger
    local reducedProjectedDamage = beforeThreat and afterThreat
        and (beforeThreat.projectedDamage or 0) > (afterThreat.projectedDamage or 0)

    if blockedImmediateDanger or (beforeThreat and beforeThreat.immediateLethal and afterThreat and not afterThreat.immediateLethal) then
        details.immediateDefense = details.immediateDefense + cfgValue(ctx, "DEPLOY_IMMEDIATE_DEFENSE_BONUS")
        details.reasons[#details.reasons + 1] = "blocks_commandant_threat"
    elseif reducedProjectedDamage then
        details.immediateDefense = details.immediateDefense + cfgValue(ctx, "DEPLOY_REDUCED_COMMANDANT_DAMAGE_BONUS")
        details.reasons[#details.reasons + 1] = "reduces_projected_commandant_damage"
    end

    local pressureScore, pressureTagged = evaluateCloudstrikerPressure(ai, afterState, playerId, deployAction, ctx)
    details.commandantPressure = details.commandantPressure + pressureScore
    if pressureTagged then
        details.reasons[#details.reasons + 1] = "cloudstriker_pressure_lane"
    end

    local commandantCounter = evaluateCommandantThreatCounterDeploy(ai, state, afterState, deployAction, playerId, ctx)
    details.commandantThreatCounter = commandantCounter.value or 0
    details.commandantThreatCounterSurvives = commandantCounter.survives
    details.commandantThreatCounterDamage = commandantCounter.damage
    details.commandantThreatCounterLethal = commandantCounter.lethal
    details.commandantThreatCounterRoute = commandantCounter.route
    details.commandantThreatCounterEtaActions = commandantCounter.etaActions
    details.commandantThreatCounterMoveDistance = commandantCounter.moveDistance
    if commandantCounter.reason then
        details.reasons[#details.reasons + 1] = commandantCounter.reason
    end

    local meleeDefense = evaluateMeleeDefenseDeploy(ai, state, afterState, deployAction, playerId, ctx)
    details.meleeDefense = 0
    details.allyMeleeDefenseCandidate = meleeDefense.value or 0
    details.meleeDefenseSurvives = meleeDefense.survives
    details.meleeDefenseDamage = meleeDefense.damage
    details.meleeDefenseLethal = meleeDefense.lethal

    local perspectiveScore, perspectiveTagged = scorePerspectiveDeployCell(ai, state, deployAction, playerId, roleDemand, ctx)
    details.perspectiveTempo = perspectiveScore
    if perspectiveTagged then
        details.reasons[#details.reasons + 1] = "player_aware_deploy_perspective"
    end

    if ctx
        and ctx.earlyPlan
        and ctx.earlyPlan.active == true
        and not (ctx.activeContracts and ctx.activeContracts.defenseActive == true)
        and not isPipelineV2EarlyRuntime(ctx) then
        local earlyScore, earlyDetails = earlyPlanner.scoreDeploy(ai, state, deployAction, playerId, ctx, roleDemand)
        details.earlyIntent = earlyScore or 0
        details.earlyIntentDetails = earlyDetails
        if earlyDetails then
            for _, reason in ipairs(earlyDetails.reasons or {}) do
                if reason ~= "inactive" then
                    details.reasons[#details.reasons + 1] = reason
                end
            end
        end
    elseif ctx and ctx.earlyPlan and ctx.earlyPlan.active == true and isPipelineV2EarlyRuntime(ctx) then
        bumpStat(ctx, "pipelineV2EarlyPlannerDeployScoreSkipped")
    end

    local earlyFormationActive = ctx
        and ctx.earlyPlan
        and ctx.earlyPlan.active == true
        and not (ctx.activeContracts and ctx.activeContracts.defenseActive == true)
    local slowSiegeEarlyDelay = earlyFormationActive
        and isSlowSiegeUnit(deployAction.unitName, ctx)
        and details.immediateDefense <= 0
        and details.commandantThreatCounter <= 0
        and details.meleeDefense <= 0
        and num(details.allyMeleeDefenseCandidate, 0) <= 0

    if slowSiegeEarlyDelay then
        local setup = evaluateEarlySlowSiegeSetup(ai, state, deployAction, playerId, ctx)
        details.slowSiegeSetup = setup.valid == true
        details.slowSiegeSetupSupportDistance = setup.supportDistance
        details.slowSiegeSetupObstacleDistance = setup.obstacleDistance
        details.slowSiegeSetupForwardUnits = setup.forwardUnits
        details.slowSiegeSetupStrategicCells = setup.strategicCells
        details.slowSiegeSetupOccupiedStrategicCells = setup.occupiedStrategicCells
        if setup.valid then
            details.roleFit = details.roleFit * cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_ROLE_FIT_SCALE")
            details.perspectiveTempo = details.perspectiveTempo * cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_PERSPECTIVE_SCALE")
            details.laneValue = details.laneValue
                - cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_TEMPO_PENALTY")
                + cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_COVER_BONUS")
            details.reasons[#details.reasons + 1] = "early_slow_siege_protected_setup"
        else
            details.roleFit = details.roleFit * cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_ROLE_FIT_SCALE_CHEAP")
            details.perspectiveTempo = details.perspectiveTempo * cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_PERSPECTIVE_SCALE")
            details.laneValue = details.laneValue - cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_TEMPO_PENALTY")
            details.noImpactPenalty = details.noImpactPenalty + cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_FILLER_PENALTY")
            if hasEarlyNonSlowPresenceDeployOption(state, playerId, ctx, deployAction.unitName) then
                details.noImpactPenalty = details.noImpactPenalty + cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_ALT_PENALTY")
                details.reasons[#details.reasons + 1] = "early_slow_siege_mobile_presence_available"
            end
            details.reasons[#details.reasons + 1] = "early_slow_siege_delayed_role"
        end
    elseif deployAction.unitName == "Artillery" then
        details.laneValue = details.laneValue + cfgValue(ctx, "DEPLOY_ARTILLERY_LANE_BONUS")
    elseif deployAction.unitName == "Bastion" and details.immediateDefense > 0 then
        details.laneValue = details.laneValue + cfgValue(ctx, "DEPLOY_BASTION_DEFENSE_LANE_BONUS")
    end

    local damagedAllies = countDamagedAllies(ai, state, playerId)
    if deployAction.unitName == "Healer" and damagedAllies > 0 then
        details.repairValue = clamp(
            cfgValue(ctx, "DEPLOY_HEALER_REPAIR_BASE")
                + damagedAllies * cfgValue(ctx, "DEPLOY_HEALER_REPAIR_PER_DAMAGED"),
            0,
            cfgValue(ctx, "DEPLOY_HEALER_REPAIR_MAX")
        )
        details.reasons[#details.reasons + 1] = "healer_has_repair_value"
    end

    local ownHub = state.commandHubs and state.commandHubs[playerId]
    if ownHub then
        local hubDistance = math.abs((deployAction.target.row or 0) - (ownHub.row or 0))
            + math.abs((deployAction.target.col or 0) - (ownHub.col or 0))
        details.cellQuality = cfgValue(ctx, "DEPLOY_CELL_QUALITY_BASE")
            - (hubDistance * cfgValue(ctx, "DEPLOY_CELL_QUALITY_HUB_DISTANCE_PENALTY"))
    end

    local targetRow = deployAction.target and deployAction.target.row
    local targetCol = deployAction.target and deployAction.target.col
    if targetRow and targetCol then
        local attackers, projectedDamage = getEnemyAttackersOnCell(ai, afterState, enemyPlayer, targetRow, targetCol)
        if attackers > 0 then
            details.exposurePenalty = details.exposurePenalty
                + (attackers * cfgValue(ctx, "DEPLOY_EXPOSURE_ATTACKER_PENALTY"))
                + (projectedDamage * cfgValue(ctx, "DEPLOY_EXPOSURE_DAMAGE_PENALTY"))
            details.reasons[#details.reasons + 1] = "deployed_unit_exposed"
        end
    end

    local scarcity = reserveModel.evaluateOwnReserveScarcity(ai, state, afterState, {deployAction}, playerId, ctx)
    details.reserveScarcityImpact = scarcity.value or 0
    details.reserveScarcityPenalty = math.max(0, -(scarcity.value or 0))
    for _, reason in ipairs(scarcity.reasons or {}) do
        details.reasons[#details.reasons + 1] = reason
    end

    local healerNoFiller = deployAction.unitName == "Healer"
        and damagedAllies <= 0
        and not (beforeThreat and beforeThreat.immediateDanger)
        and details.immediateDefense <= 0
        and details.commandantPressure <= 0
        and details.commandantThreatCounter <= 0
        and details.meleeDefense <= 0
    if healerNoFiller then
        details.noImpactPenalty = details.noImpactPenalty + cfgValue(ctx, "DEPLOY_HEALER_NO_FILLER_PENALTY")
        details.reasons[#details.reasons + 1] = "healer_no_filler"
    end

    if details.immediateDefense <= 0
        and details.commandantPressure <= 0
        and details.commandantThreatCounter <= 0
        and details.meleeDefense <= 0
        and details.repairValue <= 0
        and details.roleFit < cfgValue(ctx, "DEPLOY_LOW_IMPACT_ROLE_FIT_MIN") then
        details.noImpactPenalty = details.noImpactPenalty + cfgValue(ctx, "DEPLOY_LOW_IMPACT_PENALTY")
    end

    local score =
        details.roleFit
        + details.immediateDefense
        + details.commandantPressure
        + details.commandantThreatCounter
        + details.meleeDefense
        + details.perspectiveTempo
        + details.earlyIntent
        + details.laneValue
        + details.repairValue
        + details.cellQuality
        - details.exposurePenalty
        - details.noImpactPenalty
        + details.reserveScarcityImpact

    return score, details
end

function M.getDeployActionEntries(ai, state, playerId, ctx)
    local entries = {}
    if not ai or not state or not playerId then
        return entries
    end

    local deployments = ai:getPossibleSupplyDeploymentsForPlayer(state, playerId, true, {
        scoreDeployments = false
    }) or {}

    local demand = M.buildRoleDemand(ai, state, playerId, ctx)

    for _, deployment in ipairs(deployments) do
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
        local action = {
            type = "supply_deploy",
            unitIndex = deployment.unitIndex,
            unitName = deployment.unitName,
            target = {
                row = deployment.target and deployment.target.row,
                col = deployment.target and deployment.target.col
            },
            hub = deployment.hub and {
                row = deployment.hub.row,
                col = deployment.hub.col
            } or nil
        }

        local score, details = M.scoreDeployCheap(ai, state, action, playerId, ctx, demand)

        entries[#entries + 1] = {
            type = "supply_deploy",
            action = action,
            unit = nil,
            target = action.target,
            cheapScore = score,
            deployDetails = details
        }
    end

    sortDeployEntries(entries)

    local maxDeploy = cfgValue(ctx, "MAX_DEPLOY_ACTIONS_PER_STATE")
    return trim(entries, maxDeploy)
end

function M.evaluateDeployImpact(ai, beforeState, afterState, deployAction, playerId, ctx, opts)
    local impact = {
        value = 0,
        breakdown = {
            roleFit = 0,
            defense = 0,
            pressure = 0,
            commandantThreatCounter = 0,
            meleeDefense = 0,
            perspectiveTempo = 0,
            earlyIntent = 0,
            repair = 0,
            survivability = 0,
            reserveCost = 0,
            slowSiegeDelay = 0,
            noImpactPenalty = 0,
            turnPattern = nil
        },
        reasons = {}
    }

    if not ai or not beforeState or not deployAction or not playerId then
        impact.reasons[#impact.reasons + 1] = "invalid_input"
        return impact
    end

    local options = opts or {}
    local finalizedAfterState = afterState
    if not finalizedAfterState then
        finalizedAfterState = ai:applySupplyDeploymentForPlayer(beforeState, deployAction, playerId, {
            scoreDeployments = false
        })
    end

    local demand = M.buildRoleDemand(ai, beforeState, playerId, ctx)
    impact.breakdown.roleFit = scoreRoleFit(deployAction.unitName, demand, ctx)

    local enemyPlayer = ai:getOpponentPlayer(playerId)
    local beforeThreat = callThreatModel(ctx, ai, beforeState, playerId, enemyPlayer)
    local afterThreat = callThreatModel(ctx, ai, finalizedAfterState, playerId, enemyPlayer)

    if beforeThreat and beforeThreat.immediateLethal and afterThreat and not afterThreat.immediateLethal then
        impact.breakdown.defense = impact.breakdown.defense + cfgValue(ctx, "DEPLOY_IMPACT_STOP_LETHAL_BONUS")
        impact.reasons[#impact.reasons + 1] = "stops_immediate_lethal"
    elseif beforeThreat and afterThreat then
        local delta = (beforeThreat.projectedDamage or 0) - (afterThreat.projectedDamage or 0)
        if delta > 0 then
            impact.breakdown.defense = impact.breakdown.defense
                + (delta * cfgValue(ctx, "DEPLOY_IMPACT_REDUCE_DAMAGE_WEIGHT"))
            impact.reasons[#impact.reasons + 1] = "reduces_commandant_damage_projection"
        end
    end

    local enemyThreatBefore = callThreatModel(ctx, ai, beforeState, enemyPlayer, playerId)
    local enemyThreatAfter = callThreatModel(ctx, ai, finalizedAfterState, enemyPlayer, playerId)
    if enemyThreatBefore and enemyThreatAfter then
        local deltaPressure = (enemyThreatAfter.projectedDamage or 0) - (enemyThreatBefore.projectedDamage or 0)
        if deltaPressure > 0 then
            impact.breakdown.pressure = impact.breakdown.pressure
                + (deltaPressure * cfgValue(ctx, "DEPLOY_IMPACT_ENEMY_PRESSURE_WEIGHT"))
            impact.reasons[#impact.reasons + 1] = "increases_enemy_commandant_pressure"
        end
    end

    if deployAction.unitName == "Cloudstriker" then
        local pressureScore, pressureTagged = evaluateCloudstrikerPressure(ai, finalizedAfterState, playerId, deployAction, ctx)
        impact.breakdown.pressure = impact.breakdown.pressure + pressureScore
        if pressureTagged then
            impact.reasons[#impact.reasons + 1] = "cloudstriker_pressure_lane"
        end
    end

    local commandantCounter = evaluateCommandantThreatCounterDeploy(
        ai,
        beforeState,
        finalizedAfterState,
        deployAction,
        playerId,
        ctx
    )
    impact.breakdown.commandantThreatCounter = commandantCounter.value or 0
    impact.breakdown.commandantThreatCounterSurvives = commandantCounter.survives
    impact.breakdown.commandantThreatCounterDamage = commandantCounter.damage
    impact.breakdown.commandantThreatCounterLethal = commandantCounter.lethal
    impact.breakdown.commandantThreatCounterRoute = commandantCounter.route
    impact.breakdown.commandantThreatCounterEtaActions = commandantCounter.etaActions
    impact.breakdown.commandantThreatCounterMoveDistance = commandantCounter.moveDistance
    if commandantCounter.reason then
        impact.reasons[#impact.reasons + 1] = commandantCounter.reason
    end

    local meleeDefense = evaluateMeleeDefenseDeploy(ai, beforeState, finalizedAfterState, deployAction, playerId, ctx)
    impact.breakdown.meleeDefense = 0
    impact.breakdown.allyMeleeDefenseCandidate = meleeDefense.value or 0
    impact.breakdown.meleeDefenseSurvives = meleeDefense.survives
    impact.breakdown.meleeDefenseDamage = meleeDefense.damage
    impact.breakdown.meleeDefenseLethal = meleeDefense.lethal

    local perspectiveScore, perspectiveTagged = scorePerspectiveDeployCell(ai, beforeState, deployAction, playerId, demand, ctx)
    impact.breakdown.perspectiveTempo = perspectiveScore
    if perspectiveTagged then
        impact.reasons[#impact.reasons + 1] = "player_aware_deploy_perspective"
    end

    if ctx
        and ctx.earlyPlan
        and ctx.earlyPlan.active == true
        and not (ctx.activeContracts and ctx.activeContracts.defenseActive == true)
        and not isPipelineV2EarlyRuntime(ctx) then
        local earlyScore, earlyDetails = earlyPlanner.scoreDeploy(ai, beforeState, deployAction, playerId, ctx, demand)
        impact.breakdown.earlyIntent = earlyScore or 0
        impact.breakdown.earlyIntentDetails = earlyDetails
        if earlyDetails then
            for _, reason in ipairs(earlyDetails.reasons or {}) do
                if reason ~= "inactive" then
                    impact.reasons[#impact.reasons + 1] = reason
                end
            end
        end
    elseif ctx and ctx.earlyPlan and ctx.earlyPlan.active == true and isPipelineV2EarlyRuntime(ctx) then
        bumpStat(ctx, "pipelineV2EarlyPlannerDeployImpactScoreSkipped")
    end

    local earlyFormationActive = ctx
        and ctx.earlyPlan
        and ctx.earlyPlan.active == true
        and not (ctx.activeContracts and ctx.activeContracts.defenseActive == true)
    local slowSiegeEarlyDelay = earlyFormationActive
        and isSlowSiegeUnit(deployAction.unitName, ctx)
        and impact.breakdown.defense <= 0
        and impact.breakdown.commandantThreatCounter <= 0
        and impact.breakdown.meleeDefense <= 0
        and num(impact.breakdown.allyMeleeDefenseCandidate, 0) <= 0

    if slowSiegeEarlyDelay then
        local setup = evaluateEarlySlowSiegeSetup(ai, beforeState, deployAction, playerId, ctx)
        impact.breakdown.slowSiegeSetup = setup.valid == true
        impact.breakdown.slowSiegeSetupSupportDistance = setup.supportDistance
        impact.breakdown.slowSiegeSetupObstacleDistance = setup.obstacleDistance
        impact.breakdown.slowSiegeSetupForwardUnits = setup.forwardUnits
        impact.breakdown.slowSiegeSetupStrategicCells = setup.strategicCells
        impact.breakdown.slowSiegeSetupOccupiedStrategicCells = setup.occupiedStrategicCells
        if setup.valid then
            impact.breakdown.roleFit = impact.breakdown.roleFit
                * cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_ROLE_FIT_SCALE")
            impact.breakdown.perspectiveTempo = impact.breakdown.perspectiveTempo
                * cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_PERSPECTIVE_SCALE")
            impact.breakdown.slowSiegeDelay = impact.breakdown.slowSiegeDelay
                - cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_IMPACT_PENALTY")
                + cfgValue(ctx, "EARLY_SLOW_SIEGE_SETUP_COVER_BONUS")
            impact.reasons[#impact.reasons + 1] = "early_slow_siege_protected_setup"
        else
            impact.breakdown.roleFit = impact.breakdown.roleFit
                * cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_ROLE_FIT_SCALE_CHEAP")
            impact.breakdown.perspectiveTempo = impact.breakdown.perspectiveTempo
                * cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_PERSPECTIVE_SCALE")
            impact.breakdown.slowSiegeDelay = impact.breakdown.slowSiegeDelay
                - cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_IMPACT_PENALTY")
            if hasEarlyNonSlowPresenceDeployOption(beforeState, playerId, ctx, deployAction.unitName) then
                impact.breakdown.slowSiegeDelay = impact.breakdown.slowSiegeDelay
                    - cfgValue(ctx, "EARLY_SLOW_SIEGE_DEPLOY_ALT_PENALTY")
                impact.reasons[#impact.reasons + 1] = "early_slow_siege_mobile_presence_available"
            end
            impact.reasons[#impact.reasons + 1] = "early_slow_siege_delayed_role"
        end
    end

    local damagedAllies = countDamagedAllies(ai, beforeState, playerId)
    if deployAction.unitName == "Healer" and damagedAllies > 0 then
        impact.breakdown.repair = clamp(
            cfgValue(ctx, "DEPLOY_IMPACT_HEALER_REPAIR_BASE")
                + damagedAllies * cfgValue(ctx, "DEPLOY_IMPACT_HEALER_REPAIR_PER_DAMAGED"),
            0,
            cfgValue(ctx, "DEPLOY_IMPACT_HEALER_REPAIR_MAX")
        )
        impact.reasons[#impact.reasons + 1] = "healer_repair_tempo"
    end

    local attackers, projectedDamage = getEnemyAttackersOnCell(
        ai,
        finalizedAfterState,
        enemyPlayer,
        deployAction.target and deployAction.target.row,
        deployAction.target and deployAction.target.col
    )
    if attackers > 0 then
        impact.breakdown.survivability = impact.breakdown.survivability
            - (
                (attackers * cfgValue(ctx, "DEPLOY_IMPACT_SURVIVABILITY_ATTACKER_PENALTY"))
                + (projectedDamage * cfgValue(ctx, "DEPLOY_IMPACT_SURVIVABILITY_DAMAGE_PENALTY"))
            )
        impact.reasons[#impact.reasons + 1] = "deployed_unit_is_immediately_contestable"
    end

    local scarcity = reserveModel.evaluateOwnReserveScarcity(ai, beforeState, finalizedAfterState, {deployAction}, playerId, ctx)
    impact.breakdown.reserveCost = scarcity.value or 0
    for _, reason in ipairs(scarcity.reasons or {}) do
        impact.reasons[#impact.reasons + 1] = reason
    end

    local meaningfulValue = impact.breakdown.defense
        + impact.breakdown.pressure
        + impact.breakdown.commandantThreatCounter
        + impact.breakdown.meleeDefense
        + impact.breakdown.repair
    if meaningfulValue <= 0 and impact.breakdown.roleFit < cfgValue(ctx, "DEPLOY_IMPACT_LOW_ROLE_FIT_MIN") then
        impact.breakdown.noImpactPenalty = cfgValue(ctx, "DEPLOY_IMPACT_NO_IMPACT_PENALTY")
        impact.reasons[#impact.reasons + 1] = "deploy_without_impact"
    end

    impact.value =
        (impact.breakdown.roleFit or 0)
        + (impact.breakdown.defense or 0)
        + (impact.breakdown.pressure or 0)
        + (impact.breakdown.commandantThreatCounter or 0)
        + (impact.breakdown.meleeDefense or 0)
        + (impact.breakdown.perspectiveTempo or 0)
        + (impact.breakdown.earlyIntent or 0)
        + (impact.breakdown.repair or 0)
        + (impact.breakdown.survivability or 0)
        + (impact.breakdown.reserveCost or 0)
        + (impact.breakdown.slowSiegeDelay or 0)
        - (impact.breakdown.noImpactPenalty or 0)

    local candidate = options.candidate or nil
    if candidate then
        impact.breakdown.turnPattern = candidate.signature or nil
        impact.reasons[#impact.reasons + 1] = "deploy_part_of_complete_turn"
    end

    return impact
end

M.scoreRoleFit = scoreRoleFit

return M
