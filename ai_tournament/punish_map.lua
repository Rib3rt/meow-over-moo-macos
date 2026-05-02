local M = {}

local earlyFireLane = require("ai_tournament.early_fire_lane")

local DEFAULT_GRID_SIZE = 8

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

local okUnitsInfo, unitsInfo = pcall(require, "unitsInfo")
if not okUnitsInfo then
    unitsInfo = nil
end

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function gridSize(state)
    return num(state and state.gridSize, num(GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE, DEFAULT_GRID_SIZE))
end

local function inBounds(state, row, col)
    local size = gridSize(state)
    return row >= 1 and row <= size and col >= 1 and col <= size
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
        local ok, value = pcall(ai.isHubUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return unit.name == "Commandant"
end

local function isObstacleUnit(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        local ok, value = pcall(ai.isObstacleUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return unit.name == "Rock" or unit.player == 0
end

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function isAlive(unit)
    return unit and unitHp(unit) > 0
end

local function cloneUnit(unit, overrides)
    local out = {}
    for key, value in pairs(unit or {}) do
        out[key] = value
    end
    for key, value in pairs(overrides or {}) do
        out[key] = value
    end
    return out
end

local function unitSummary(unit)
    if not unit then
        return nil
    end
    return {
        id = unit.id or unit.instanceId or unit.uid,
        name = unit.name,
        player = unit.player,
        row = unit.row,
        col = unit.col
    }
end

local function getHubAsUnit(state, playerId)
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

local function getUnitAt(ai, state, row, col, includeHubs)
    if not (state and row and col) then
        return nil
    end
    if ai and ai.getUnitAtPosition then
        local ok, unit = pcall(ai.getUnitAtPosition, ai, state, row, col)
        if ok and unit then
            return unit
        end
    end
    for _, unit in ipairs(state.units or {}) do
        if unit and unit.row == row and unit.col == col then
            return unit
        end
    end
    if includeHubs ~= false then
        for playerId, hub in pairs(state.commandHubs or {}) do
            if hub and hub.row == row and hub.col == col then
                return getHubAsUnit(state, playerId)
            end
        end
    end
    for _, rock in ipairs(state.neutralBuildings or {}) do
        if rock and rock.row == row and rock.col == col then
            return {
                name = rock.name or "Rock",
                player = 0,
                row = row,
                col = col,
                currentHp = rock.currentHp or rock.hp or 5,
                startingHp = rock.startingHp or rock.hp or 5
            }
        end
    end
    return nil
end

local function getUnitsForPlayer(ai, state, playerId, opts)
    local result = {}
    opts = opts or {}
    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and isAlive(unit)
            and not isObstacleUnit(ai, unit)
            and (opts.includeHubs or not isHubUnit(ai, unit)) then
            result[#result + 1] = unit
        end
    end
    if opts.includeHubs then
        local hub = getHubAsUnit(state, playerId)
        if isAlive(hub) then
            result[#result + 1] = hub
        end
    end
    return result
end

local function unitValue(ai, unit, state)
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

local function unitAttackRange(ai, unit)
    local range = unit and unit.atkRange
    if range == nil and ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        local ok, value = pcall(ai.unitsInfo.getUnitAttackRange, ai.unitsInfo, unit, "TOURNAMENT_PUNISH_MAP_ATTACK_RANGE")
        if ok then
            range = value
        end
    end
    if range == nil and unitsInfo and unitsInfo.getUnitAttackRange then
        local ok, value = pcall(unitsInfo.getUnitAttackRange, unitsInfo, unit, "TOURNAMENT_PUNISH_MAP_ATTACK_RANGE")
        if ok then
            range = value
        end
    end
    return num(range, 1)
end

local function unitMoveRange(ai, unit)
    local move = unit and unit.move
    if move == nil and ai and ai.unitsInfo and ai.unitsInfo.getUnitMoveRange then
        local ok, value = pcall(ai.unitsInfo.getUnitMoveRange, ai.unitsInfo, unit, "TOURNAMENT_PUNISH_MAP_MOVE_RANGE")
        if ok then
            move = value
        end
    end
    if move == nil and unitsInfo and unitsInfo.getUnitMoveRange then
        local ok, value = pcall(unitsInfo.getUnitMoveRange, unitsInfo, unit, "TOURNAMENT_PUNISH_MAP_MOVE_RANGE")
        if ok then
            move = value
        end
    end
    return num(move, 1)
end

local function calculateDamage(ai, attacker, target)
    if not (attacker and target) then
        return 0
    end
    if ai and ai.calculateDamage then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    if ai and ai.unitsInfo and ai.unitsInfo.calculateAttackDamage then
        local ok, value = pcall(ai.unitsInfo.calculateAttackDamage, ai.unitsInfo, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    if unitsInfo and unitsInfo.calculateAttackDamage then
        local ok, value = pcall(unitsInfo.calculateAttackDamage, unitsInfo, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    return math.max(0, num(attacker.atkDamage, 0))
end

local function hasLineOfSight(ai, state, unit, fromCell, targetCell)
    if not (fromCell and targetCell) then
        return false
    end
    if unit and unit.name == "Artillery" then
        return true
    end
    if ai and ai.hasLineOfSight then
        local ok, value = pcall(ai.hasLineOfSight, ai, state, fromCell, targetCell)
        if ok then
            return value == true
        end
    end

    if fromCell.row ~= targetCell.row and fromCell.col ~= targetCell.col then
        return false
    end
    local rowStep = fromCell.row == targetCell.row and 0 or (targetCell.row > fromCell.row and 1 or -1)
    local colStep = fromCell.col == targetCell.col and 0 or (targetCell.col > fromCell.col and 1 or -1)
    local row = fromCell.row + rowStep
    local col = fromCell.col + colStep
    while row ~= targetCell.row or col ~= targetCell.col do
        if getUnitAt(ai, state, row, col, true) then
            return false
        end
        row = row + rowStep
        col = col + colStep
    end
    return true
end

local function canAttackCellFrom(ai, state, unit, fromCell, targetCell, opts)
    if not (unit and fromCell and targetCell) then
        return false
    end
    opts = opts or {}
    local rowDiff = math.abs(num(fromCell.row, 0) - num(targetCell.row, 0))
    local colDiff = math.abs(num(fromCell.col, 0) - num(targetCell.col, 0))
    local distance = rowDiff + colDiff
    local range = unitAttackRange(ai, unit)
    if distance <= 0 or distance > range then
        return false
    end
    if rowDiff > 0 and colDiff > 0 then
        return false
    end

    local unitName = tostring(unit.name or "")
    local minRange = (unitName == "Cloudstriker" or unitName == "Artillery") and 2 or 1
    if distance < minRange then
        return false
    end
    if unitName == "Cloudstriker" and not hasLineOfSight(ai, state, unit, fromCell, targetCell) then
        return false
    end
    if not opts.allowEmptyTarget then
        local target = getUnitAt(ai, state, targetCell.row, targetCell.col, true)
        if not target or target.player == unit.player then
            return false
        end
    end
    return true
end

local function fallbackMoveCells(state, unit)
    local result = {}
    local moveRange = unitMoveRange(nil, unit)
    local dirs = {
        {row = 1, col = 0},
        {row = -1, col = 0},
        {row = 0, col = 1},
        {row = 0, col = -1}
    }
    for _, dir in ipairs(dirs) do
        for dist = 1, moveRange do
            local row = num(unit.row, 0) + dir.row * dist
            local col = num(unit.col, 0) + dir.col * dist
            if not inBounds(state, row, col) then
                break
            end
            if getUnitAt(nil, state, row, col, true) then
                break
            end
            result[#result + 1] = {row = row, col = col}
        end
    end
    return result
end

local function getValidMoveCells(ai, state, unit)
    if not (state and unit) then
        return {}
    end
    if ai and ai.getValidMoveCells then
        local ok, cells = pcall(ai.getValidMoveCells, ai, state, unit.row, unit.col)
        if ok and type(cells) == "table" then
            return cells
        end
    end
    return fallbackMoveCells(state, unit)
end

local function canRepairCellFrom(ai, state, unit, fromCell, targetCell)
    if not (unit and fromCell and targetCell) then
        return false
    end
    if unit.name ~= "Healer" and unit.repair ~= true then
        return false
    end
    local rowDiff = math.abs(num(fromCell.row, 0) - num(targetCell.row, 0))
    local colDiff = math.abs(num(fromCell.col, 0) - num(targetCell.col, 0))
    local distance = rowDiff + colDiff
    local range = num(unit.repairRange, 1)
    if distance <= 0 or distance > range or (rowDiff > 0 and colDiff > 0) then
        return false
    end

    local rowStep = fromCell.row == targetCell.row and 0 or (targetCell.row > fromCell.row and 1 or -1)
    local colStep = fromCell.col == targetCell.col and 0 or (targetCell.col > fromCell.col and 1 or -1)
    local row = fromCell.row + rowStep
    local col = fromCell.col + colStep
    while row ~= targetCell.row or col ~= targetCell.col do
        if getUnitAt(ai, state, row, col, true) then
            return false
        end
        row = row + rowStep
        col = col + colStep
    end

    local occupant = getUnitAt(ai, state, targetCell.row, targetCell.col, true)
    if occupant and (occupant.player ~= unit.player or isObstacleUnit(ai, occupant)) then
        return false
    end
    return true
end

local function fallbackDeployments(ai, state, playerId)
    local deployments = {}
    if not (state and playerId and state.supply and state.supply[playerId] and state.commandHubs) then
        return deployments
    end
    if state.hasDeployedThisTurn or #state.supply[playerId] <= 0 then
        return deployments
    end

    local hub = state.commandHubs[playerId]
    if not hub then
        return deployments
    end
    local dirs = {
        {row = 1, col = 0},
        {row = -1, col = 0},
        {row = 0, col = 1},
        {row = 0, col = -1}
    }
    for unitIndex, supplyUnit in ipairs(state.supply[playerId] or {}) do
        for _, dir in ipairs(dirs) do
            local row = hub.row + dir.row
            local col = hub.col + dir.col
            if inBounds(state, row, col) and not getUnitAt(ai, state, row, col, true) then
                deployments[#deployments + 1] = {
                    type = "supply_deploy",
                    unitIndex = unitIndex,
                    unitName = supplyUnit and supplyUnit.name,
                    target = {row = row, col = col},
                    hub = {row = hub.row, col = hub.col}
                }
            end
        end
    end
    return deployments
end

local function getDeploymentsForPlayer(ai, state, playerId)
    if ai and ai.getPossibleSupplyDeploymentsForPlayer then
        local ok, deployments = pcall(ai.getPossibleSupplyDeploymentsForPlayer, ai, state, playerId, true, {
            scoreDeployments = false
        })
        if ok and type(deployments) == "table" then
            return deployments
        end
    end
    if ai and ai.getPossibleSupplyDeployments then
        local ok, deployments = pcall(ai.getPossibleSupplyDeployments, ai, state, true)
        if ok and type(deployments) == "table" then
            return deployments
        end
    end
    return fallbackDeployments(ai, state, playerId)
end

local function fallbackPreparedForPlayerTurn(state, playerId)
    if not state then
        return state
    end

    local prepared = {}
    for key, value in pairs(state) do
        prepared[key] = value
    end

    prepared.units = {}
    for _, unit in ipairs(state.units or {}) do
        local copied = cloneUnit(unit)
        if copied.player == playerId and unit.name ~= "Rock" and copied.player ~= 0 then
            copied.hasActed = false
            copied.hasMoved = false
            copied.actionsUsed = 0
        end
        prepared.units[#prepared.units + 1] = copied
    end

    prepared.neutralBuildings = {}
    for _, rock in ipairs(state.neutralBuildings or {}) do
        local copied = {}
        for key, value in pairs(rock or {}) do
            copied[key] = value
        end
        prepared.neutralBuildings[#prepared.neutralBuildings + 1] = copied
    end

    prepared.commandHubs = {}
    for key, hub in pairs(state.commandHubs or {}) do
        local copied = {}
        for hubKey, value in pairs(hub or {}) do
            copied[hubKey] = value
        end
        prepared.commandHubs[key] = copied
    end

    prepared.supply = {}
    for key, list in pairs(state.supply or {}) do
        prepared.supply[key] = {}
        for _, unit in ipairs(list or {}) do
            prepared.supply[key][#prepared.supply[key] + 1] = cloneUnit(unit)
        end
    end

    prepared.turnActionCount = 0
    prepared.hasDeployedThisTurn = false
    prepared.firstActionRangedAttack = nil
    return prepared
end

local function preparedForPlayerTurn(ai, state, playerId)
    if ai and ai.prepareStateForPlayerTurn then
        local ok, prepared = pcall(ai.prepareStateForPlayerTurn, ai, state, playerId, {
            resetActionCount = true,
            resetDeployment = true,
            resetFirstActionRangedAttack = true
        })
        if ok and prepared then
            return prepared
        end
    end
    return fallbackPreparedForPlayerTurn(state, playerId)
end

local function bestThreatFromUnit(ai, state, attacker, target)
    if not (attacker and target) then
        return nil
    end
    local damage = calculateDamage(ai, attacker, target)
    if damage <= 0 then
        return nil
    end

    local best = nil
    local function consider(kind, fromCell, eta, moveDistance)
        if canAttackCellFrom(ai, state, attacker, fromCell, target, {allowEmptyTarget = true}) then
            local lethal = damage >= unitHp(target)
            local score = damage * 100
                + (lethal and 10000 or 0)
                + unitValue(ai, target, state) * (lethal and 1.0 or 0.25)
                - eta * 18
                - moveDistance * 3
            local entry = {
                kind = kind,
                attacker = attacker,
                attackerId = attacker.id or attacker.instanceId or attacker.uid,
                attackerName = attacker.name,
                target = target,
                targetName = target.name,
                fromCell = {row = fromCell.row, col = fromCell.col},
                damage = damage,
                expectedDamage = damage,
                lethal = lethal,
                eta = eta,
                moveDistance = moveDistance,
                score = score
            }
            if not best
                or entry.score > best.score
                or (entry.score == best.score and tostring(entry.attackerName) < tostring(best.attackerName)) then
                best = entry
            end
        end
    end

    consider("direct_attack", attacker, 0, 0)
    for _, cell in ipairs(getValidMoveCells(ai, state, attacker)) do
        consider("move_attack", cell, 1, manhattan(attacker, cell))
    end

    return best
end

function M.bestEnemyReply(state, ai, ctx, faction, unit, cell)
    local target = cloneUnit(unit, {
        row = cell and cell.row or unit and unit.row,
        col = cell and cell.col or unit and unit.col
    })
    local enemyPlayer = getOpponent(ai, faction or target.player)
    local replyState = preparedForPlayerTurn(ai, state, enemyPlayer)
    local best = nil
    for _, enemy in ipairs(getUnitsForPlayer(ai, replyState, enemyPlayer, {includeHubs = false})) do
        local reply = bestThreatFromUnit(ai, replyState, enemy, target)
        if reply and (not best or reply.score > best.score) then
            best = reply
        end
    end
    if best then
        best.faction = enemyPlayer
        best.reason = best.lethal and "enemy_lethal_punish" or "enemy_damage_punish"
    end
    return best
end

function M.bestCounterPunish(state, ai, ctx, faction, enemyReply)
    if not (enemyReply and enemyReply.attacker) then
        return nil
    end
    local counterState = preparedForPlayerTurn(ai, state, faction)
    local replyAttacker = cloneUnit(enemyReply.attacker, enemyReply.fromCell or {})
    local best = nil
    for _, ally in ipairs(getUnitsForPlayer(ai, counterState, faction, {includeHubs = false})) do
        if not (enemyReply.target and ally.row == enemyReply.target.row and ally.col == enemyReply.target.col) then
            local counter = bestThreatFromUnit(ai, counterState, ally, replyAttacker)
            if counter then
                counter.kind = "counter_" .. tostring(counter.kind or "attack")
                if not best or counter.score > best.score then
                    best = counter
                end
            end
        end
    end
    if best then
        best.reason = best.lethal and "covered_by_lethal_counter" or "covered_by_counter_damage"
    end
    return best
end

function M.analyzeCell(state, ai, ctx, unit, cell)
    local faction = unit and unit.player or ctx and ctx.aiPlayer or 1
    local enemyReply = M.bestEnemyReply(state, ai, ctx, faction, unit, cell)
    local counter = M.bestCounterPunish(state, ai, ctx, faction, enemyReply)
    local targetValue = unitValue(ai, unit, state)
    local enemyDamage = num(enemyReply and enemyReply.damage, 0)
    local counterDamage = num(counter and counter.damage, 0)
    local enemyLethal = enemyReply and enemyReply.lethal == true
    local counterLethal = counter and counter.lethal == true
    local tradeNet = counterDamage - enemyDamage
    if counterLethal then
        tradeNet = tradeNet + unitValue(ai, enemyReply and enemyReply.attacker, state) * 0.55
    end
    if enemyLethal then
        tradeNet = tradeNet - targetValue * 0.65
    end

    local covered = enemyReply == nil or counter ~= nil
    local reasons = {}
    if not enemyReply then
        reasons[#reasons + 1] = "no_enemy_punish_found"
    elseif counter then
        reasons[#reasons + 1] = counter.reason or "covered_by_counter"
    else
        reasons[#reasons + 1] = enemyReply.reason or "enemy_punish_uncovered"
    end

    local hp = unitHp(unit)
    local retreat = {
        useful = hp > 0 and hp <= math.max(1, num(unit and unit.startingHp, hp) * 0.45) and enemyReply ~= nil,
        etaToHealer = nil,
        chaseTrap = counter ~= nil and enemyReply ~= nil
    }

    return {
        phase = ctx and ctx.phase and ctx.phase.name or ctx and ctx.phase or "unknown",
        unitId = unit and (unit.id or unit.instanceId or unit.uid),
        unitName = unit and unit.name,
        targetCell = cell and {row = cell.row, col = cell.col},
        exposure = enemyReply and math.min(1, enemyDamage / math.max(1, hp)) or 0,
        covered = covered,
        coverProof = counter and (counter.lethal and "recapture" or "counter_damage") or (enemyReply and nil or "no_enemy_punish"),
        enemyBestReply = enemyReply,
        counterPunish = counter,
        tradeNet = tradeNet,
        sacrificeQuality = enemyReply and tradeNet or 0,
        retreat = retreat,
        healer = {
            protectedRoute = false,
            healerExposure = 0
        },
        reasons = reasons
    }
end

local function inferActionUnit(state, ai, action)
    if not action then
        return nil
    end
    if action.unit then
        return getUnitAt(ai, state, action.unit.row, action.unit.col, true) or action.unit
    end
    if action.type == "supply_deploy" then
        return {
            name = action.unitName,
            player = action.player,
            row = action.target and action.target.row,
            col = action.target and action.target.col,
            currentHp = action.currentHp or action.startingHp,
            startingHp = action.startingHp or action.currentHp
        }
    end
    return nil
end

local function inferActionCell(action, unit)
    if action and action.target and (action.type == "move" or action.type == "supply_deploy") then
        return action.target
    end
    return unit and {row = unit.row, col = unit.col} or nil
end

function M.analyzeAction(state, ai, ctx, actionOrSequence)
    local actions = actionOrSequence and actionOrSequence.actions or actionOrSequence
    if actions and actions.type then
        actions = {actions}
    end
    actions = actions or {}
    local result = {
        phase = ctx and ctx.phase and ctx.phase.name or ctx and ctx.phase or "unknown",
        actions = {},
        worstExposure = 0,
        bestTradeNet = -math.huge,
        covered = true,
        reasons = {}
    }
    for _, action in ipairs(actions) do
        local unit = inferActionUnit(state, ai, action)
        local cell = inferActionCell(action, unit)
        if unit and cell then
            unit = cloneUnit(unit, {row = cell.row, col = cell.col})
            local analysis = M.analyzeCell(state, ai, ctx, unit, cell)
            result.actions[#result.actions + 1] = analysis
            result.worstExposure = math.max(result.worstExposure, num(analysis.exposure, 0))
            result.bestTradeNet = math.max(result.bestTradeNet, num(analysis.tradeNet, 0))
            if analysis.covered ~= true then
                result.covered = false
            end
            for _, reason in ipairs(analysis.reasons or {}) do
                result.reasons[#result.reasons + 1] = reason
            end
        end
    end
    if result.bestTradeNet == -math.huge then
        result.bestTradeNet = 0
    end
    return result
end

local function addKind(cell, kind)
    cell.kindSet = cell.kindSet or {}
    cell.kinds = cell.kinds or {}
    if not cell.kindSet[kind] then
        cell.kindSet[kind] = true
        cell.kinds[#cell.kinds + 1] = kind
    end
end

local function fireLaneWeight(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.EARLY_FIRE_LANE_WEIGHT, 0.45)
end

local function deadFireLanePenalty(ctx)
    return math.abs(num(ctx and ctx.cfg and ctx.cfg.EARLY_DEAD_FIRE_LANE_PENALTY, 220))
end

local function applyFireLaneScore(cell, ctx, fireLane)
    cell.fireLane = fireLane
    cell.fireLaneScore = num(fireLane and fireLane.score, 0)
    cell.fireLaneControlledCount = num(fireLane and fireLane.controlledCount, 0)
    cell.deadFireLane = fireLane and fireLane.deadLane == true or false

    if cell.deadFireLane then
        cell.score = cell.score - deadFireLanePenalty(ctx)
        cell.reasons[#cell.reasons + 1] = "dead_fire_lane"
    elseif cell.fireLaneScore > 0 then
        addKind(cell, "fire_lane")
        cell.score = cell.score + math.min(cell.fireLaneScore * fireLaneWeight(ctx), 120)
        cell.reasons[#cell.reasons + 1] = "route_fire_lane"
    end
end

local function adjacentObstacleCount(ai, state, row, col)
    local count = 0
    local dirs = {
        {row = 1, col = 0},
        {row = -1, col = 0},
        {row = 0, col = 1},
        {row = 0, col = -1}
    }
    for _, dir in ipairs(dirs) do
        local unit = getUnitAt(ai, state, row + dir.row, col + dir.col, true)
        if unit and isObstacleUnit(ai, unit) then
            count = count + 1
        end
    end
    return count
end

local function cellControlledBy(ai, state, playerId, cell)
    local controllers = {}
    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId, {includeHubs = false})) do
        if canAttackCellFrom(ai, state, unit, unit, cell, {allowEmptyTarget = true}) then
            controllers[#controllers + 1] = unit
        end
    end
    return #controllers > 0, controllers
end

local function newInfluenceBucket()
    return {
        active = false,
        count = 0,
        units = {}
    }
end

local function addInfluence(bucket, unit, extra)
    local entry = unitSummary(unit) or {}
    for key, value in pairs(extra or {}) do
        entry[key] = value
    end
    bucket.units[#bucket.units + 1] = entry
    bucket.count = #bucket.units
    bucket.active = bucket.count > 0
end

local function attackInfluenceForPlayer(ai, state, playerId, cell)
    local bucket = newInfluenceBucket()
    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId, {includeHubs = false})) do
        if canAttackCellFrom(ai, state, unit, unit, cell, {allowEmptyTarget = true}) then
            addInfluence(bucket, unit, {kind = "attack"})
        end
    end
    return bucket
end

local function moveInfluenceForPlayer(ai, state, playerId, cell)
    local bucket = newInfluenceBucket()
    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId, {includeHubs = false})) do
        for _, moveCell in ipairs(getValidMoveCells(ai, state, unit)) do
            if moveCell.row == cell.row and moveCell.col == cell.col then
                addInfluence(bucket, unit, {kind = "move", distance = manhattan(unit, cell)})
                break
            end
        end
    end
    return bucket
end

local function moveAttackInfluenceForPlayer(ai, state, playerId, cell)
    local bucket = newInfluenceBucket()
    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId, {includeHubs = false})) do
        for _, moveCell in ipairs(getValidMoveCells(ai, state, unit)) do
            if canAttackCellFrom(ai, state, unit, moveCell, cell, {allowEmptyTarget = true}) then
                addInfluence(bucket, unit, {
                    kind = "move_attack",
                    from = {row = unit.row, col = unit.col},
                    attackFrom = {row = moveCell.row, col = moveCell.col},
                    distance = manhattan(unit, moveCell)
                })
                break
            end
        end
    end
    return bucket
end

local function influenceStateForPlayer(ai, state, playerId, opts)
    opts = opts or {}
    if opts.preparedByPlayer and opts.preparedByPlayer[playerId] then
        return opts.preparedByPlayer[playerId]
    end
    return preparedForPlayerTurn(ai, state, playerId)
end

local function deploymentsForPlayer(ai, state, playerId, opts)
    opts = opts or {}
    if opts.deploymentsByPlayer and opts.deploymentsByPlayer[playerId] then
        return opts.deploymentsByPlayer[playerId]
    end
    return getDeploymentsForPlayer(ai, state, playerId)
end

local function deployInfluenceForPlayer(ai, state, playerId, cell, opts)
    local bucket = newInfluenceBucket()
    for _, deployment in ipairs(deploymentsForPlayer(ai, state, playerId, opts)) do
        if deployment
            and deployment.target
            and deployment.target.row == cell.row
            and deployment.target.col == cell.col then
            addInfluence(bucket, {
                name = deployment.unitName,
                player = playerId,
                row = deployment.hub and deployment.hub.row,
                col = deployment.hub and deployment.hub.col
            }, {
                kind = "deploy",
                unitIndex = deployment.unitIndex,
                target = {row = cell.row, col = cell.col}
            })
        end
    end
    return bucket
end

local function healInfluenceForPlayer(ai, state, playerId, cell)
    local bucket = newInfluenceBucket()
    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId, {includeHubs = false})) do
        if canRepairCellFrom(ai, state, unit, unit, cell) then
            addInfluence(bucket, unit, {kind = "repair", range = num(unit.repairRange, 1)})
        end
    end
    return bucket
end

local function reachableOccupiers(ai, state, playerId, cell)
    local result = {}
    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId, {includeHubs = false})) do
        if unit.row == cell.row and unit.col == cell.col then
            result[#result + 1] = unit
        else
            for _, moveCell in ipairs(getValidMoveCells(ai, state, unit)) do
                if moveCell.row == cell.row and moveCell.col == cell.col then
                    result[#result + 1] = unit
                    break
                end
            end
        end
    end
    return result
end

function M.analyzeCellInfluence(state, ai, ctx, cell, opts)
    opts = opts or {}
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or getOpponent(ai, playerId)
    local ownActionState = influenceStateForPlayer(ai, state, playerId, opts)
    local enemyActionState = influenceStateForPlayer(ai, state, enemyPlayer, opts)
    local occupant = cell and getUnitAt(ai, state, cell.row, cell.col, true) or nil
    local ownAttack = attackInfluenceForPlayer(ai, ownActionState, playerId, cell)
    local enemyAttack = attackInfluenceForPlayer(ai, enemyActionState, enemyPlayer, cell)
    local ownMove = moveInfluenceForPlayer(ai, ownActionState, playerId, cell)
    local enemyMove = moveInfluenceForPlayer(ai, enemyActionState, enemyPlayer, cell)
    local ownMoveAttack = moveAttackInfluenceForPlayer(ai, ownActionState, playerId, cell)
    local enemyMoveAttack = moveAttackInfluenceForPlayer(ai, enemyActionState, enemyPlayer, cell)
    local ownDeploy = deployInfluenceForPlayer(ai, ownActionState, playerId, cell, opts)
    local enemyDeploy = deployInfluenceForPlayer(ai, enemyActionState, enemyPlayer, cell, opts)
    local ownHeal = healInfluenceForPlayer(ai, ownActionState, playerId, cell)
    local enemyHeal = healInfluenceForPlayer(ai, enemyActionState, enemyPlayer, cell)
    local occupiedByUs = occupant and occupant.player == playerId and not isObstacleUnit(ai, occupant) or false
    local occupiedByEnemy = occupant and occupant.player == enemyPlayer and not isObstacleUnit(ai, occupant) or false
    local occupiedByNeutral = occupant and (occupant.player == 0 or isObstacleUnit(ai, occupant)) or false
    local influencedByUs = ownAttack.active or ownMove.active or ownHeal.active or occupiedByUs
    local influencedByEnemy = enemyAttack.active or enemyMove.active or enemyHeal.active or occupiedByEnemy
    local potentialInfluencedByUs = influencedByUs or ownDeploy.active
    local potentialInfluencedByEnemy = influencedByEnemy or enemyDeploy.active

    return {
        row = cell and cell.row,
        col = cell and cell.col,
        occupied = occupant ~= nil,
        occupiedBy = unitSummary(occupant),
        control = {
            us = occupiedByUs,
            enemy = occupiedByEnemy,
            neutral = occupiedByNeutral
        },
        attackInfluence = {
            us = ownAttack,
            enemy = enemyAttack
        },
        moveInfluence = {
            us = ownMove,
            enemy = enemyMove
        },
        moveAttackInfluence = {
            us = ownMoveAttack,
            enemy = enemyMoveAttack
        },
        deployInfluence = {
            us = ownDeploy,
            enemy = enemyDeploy
        },
        healInfluence = {
            us = ownHeal,
            enemy = enemyHeal
        },
        influencedByUs = influencedByUs,
        influencedByEnemy = influencedByEnemy,
        potentialInfluencedByUs = potentialInfluencedByUs,
        potentialInfluencedByEnemy = potentialInfluencedByEnemy,
        contested = influencedByUs and influencedByEnemy,
        potentialContested = potentialInfluencedByUs and potentialInfluencedByEnemy,
        attackContested = ownAttack.active and enemyAttack.active
    }
end

local function bestOccupierAnalysis(ai, state, ctx, playerId, occupiers, cell)
    local best = nil
    for _, unit in ipairs(occupiers or {}) do
        local projected = cloneUnit(unit, {row = cell.row, col = cell.col})
        local analysis = M.analyzeCell(state, ai, ctx, projected, cell)
        local score = num(analysis.tradeNet, 0) - (num(analysis.exposure, 0) * 100)
        if analysis.covered == true then
            score = score + 80
        end
        if analysis.enemyBestReply == nil then
            score = score + 45
        end
        if not best or score > best.score then
            best = {
                unit = unit,
                analysis = analysis,
                score = score
            }
        end
    end
    return best
end

local function threatensEnemyFromCell(ai, state, unit, cell, enemyPlayer)
    local projected = cloneUnit(unit, {row = cell.row, col = cell.col})
    local best = nil
    for _, enemy in ipairs(getUnitsForPlayer(ai, state, enemyPlayer, {includeHubs = true})) do
        if not isObstacleUnit(ai, enemy) and canAttackCellFrom(ai, state, projected, projected, enemy) then
            local damage = calculateDamage(ai, projected, enemy)
            if damage > 0 then
                local entry = {
                    target = enemy,
                    damage = damage,
                    lethal = damage >= unitHp(enemy),
                    value = unitValue(ai, enemy, state)
                }
                if not best
                    or (entry.lethal and not best.lethal)
                    or entry.damage > best.damage
                    or (entry.damage == best.damage and entry.value > best.value) then
                    best = entry
                end
            end
        end
    end
    return best
end

function M.findStrategicFreeCells(state, ai, ctx, opts)
    opts = opts or {}
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or getOpponent(ai, playerId)
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    local size = gridSize(state)
    local ownActionState = influenceStateForPlayer(ai, state, playerId, opts)
    local enemyActionState = influenceStateForPlayer(ai, state, enemyPlayer, opts)
    local influenceOpts = {
        preparedByPlayer = {
            [playerId] = ownActionState,
            [enemyPlayer] = enemyActionState
        },
        deploymentsByPlayer = {
            [playerId] = getDeploymentsForPlayer(ai, ownActionState, playerId),
            [enemyPlayer] = getDeploymentsForPlayer(ai, enemyActionState, enemyPlayer)
        }
    }
    local cells = {}
    local byKey = {}
    local maxCells = num(opts.maxCells, 24)

    for row = 1, size do
        for col = 1, size do
            if not getUnitAt(ai, state, row, col, true) then
                local cell = {
                    row = row,
                    col = col,
                    free = true,
                    kinds = {},
                    kindSet = {},
                    reasons = {},
                    score = 0
                }
                local key = cellKey(cell)
                local progress = ownHub and enemyHub and (manhattan(ownHub, enemyHub) - manhattan(cell, enemyHub)) or 0
                local influence = M.analyzeCellInfluence(state, ai, ctx, cell, influenceOpts)
                local ownAttack = influence.attackInfluence.us
                local enemyAttack = influence.attackInfluence.enemy
                local occupiers = reachableOccupiers(ai, ownActionState, playerId, cell)
                local bestOccupier = bestOccupierAnalysis(ai, state, ctx, playerId, occupiers, cell)

                cell.occupiedBy = influence.occupiedBy
                cell.control = influence.control
                cell.influence = influence
                cell.attackInfluence = influence.attackInfluence
                cell.moveInfluence = influence.moveInfluence
                cell.moveAttackInfluence = influence.moveAttackInfluence
                cell.deployInfluence = influence.deployInfluence
                cell.healInfluence = influence.healInfluence
                cell.attackInfluencedByUs = ownAttack.active
                cell.attackInfluencedByEnemy = enemyAttack.active
                cell.influencedByUs = influence.influencedByUs
                cell.influencedByEnemy = influence.influencedByEnemy
                cell.potentialInfluencedByUs = influence.potentialInfluencedByUs
                cell.potentialInfluencedByEnemy = influence.potentialInfluencedByEnemy
                cell.attackContested = influence.attackContested
                cell.influenceContested = influence.contested
                cell.potentialInfluenceContested = influence.potentialContested
                cell.controlledByUs = ownAttack.active -- Compatibility alias: attack influence, not physical occupation.
                cell.controlledByEnemy = enemyAttack.active -- Compatibility alias: attack influence, not physical occupation.
                cell.contested = cell.attackContested -- Compatibility alias for older reports.
                cell.reachableNow = influence.moveInfluence.us.active
                cell.deployableNow = influence.deployInfluence.us.active
                cell.healableIfOccupied = influence.healInfluence.us.active
                cell.reachableNext = cell.reachableNow or ownAttack.active
                cell.progress = progress
                cell.occupier = bestOccupier and bestOccupier.unit and {
                    name = bestOccupier.unit.name,
                    row = bestOccupier.unit.row,
                    col = bestOccupier.unit.col
                } or nil
                cell.coveredIfOccupied = bestOccupier and bestOccupier.analysis and bestOccupier.analysis.covered == true or false
                cell.enemyPunish = bestOccupier and bestOccupier.analysis and bestOccupier.analysis.enemyBestReply or nil
                cell.counterPunish = bestOccupier and bestOccupier.analysis and bestOccupier.analysis.counterPunish or nil
                cell.tradeNet = bestOccupier and bestOccupier.analysis and bestOccupier.analysis.tradeNet or 0
                applyFireLaneScore(cell, ctx, bestOccupier and bestOccupier.unit
                    and earlyFireLane.score(state, ai, ctx, bestOccupier.unit, cell, {
                        canAttackCellFrom = canAttackCellFrom
                    })
                    or nil)

                if ownAttack.active then
                    addKind(cell, "support")
                    cell.score = cell.score + 55 + (ownAttack.count * 12)
                    cell.reasons[#cell.reasons + 1] = "friendly_attack_influence"
                end
                if enemyAttack.active then
                    addKind(cell, "deny")
                    cell.score = cell.score + 45 + (enemyAttack.count * 10)
                    cell.reasons[#cell.reasons + 1] = "enemy_attack_influence"
                end
                if cell.attackContested then
                    addKind(cell, "interdiction")
                    cell.score = cell.score + 70
                    cell.reasons[#cell.reasons + 1] = "contested_attack_influence"
                end
                if progress > 0 then
                    addKind(cell, "safe_staging")
                    cell.score = cell.score + math.min(progress * 22, 90)
                    cell.reasons[#cell.reasons + 1] = "forward_staging"
                end
                if adjacentObstacleCount(ai, state, row, col) >= 2 then
                    addKind(cell, "choke")
                    cell.score = cell.score + 65
                    cell.reasons[#cell.reasons + 1] = "rock_choke"
                end

                for _, unit in ipairs(occupiers) do
                    local threat = threatensEnemyFromCell(ai, state, unit, cell, enemyPlayer)
                    if threat then
                        addKind(cell, "second_threat")
                        cell.score = cell.score + math.min(threat.damage * 35 + (threat.lethal and 70 or 0), 170)
                        cell.reasons[#cell.reasons + 1] = threat.lethal and "reachable_lethal_threat" or "reachable_damage_threat"
                        break
                    end
                end

                if cell.coveredIfOccupied then
                    cell.score = cell.score + 85 + math.max(0, num(cell.tradeNet, 0) * 8)
                    cell.reasons[#cell.reasons + 1] = "covered_if_occupied"
                elseif cell.enemyPunish then
                    cell.score = cell.score - (cell.enemyPunish.lethal and 180 or 90)
                    cell.reasons[#cell.reasons + 1] = "uncovered_if_occupied"
                end

                if #cell.kinds > 0
                    and (cell.reachableNow
                        or ownAttack.active
                        or enemyAttack.active
                        or cell.deployableNow
                        or cell.healableIfOccupied) then
                    cell.kindSet = nil
                    cells[#cells + 1] = cell
                    byKey[key] = cell
                end
            end
        end
    end

    table.sort(cells, function(a, b)
        if a.score == b.score then
            if a.row == b.row then
                return a.col < b.col
            end
            return a.row < b.row
        end
        return a.score > b.score
    end)

    while #cells > maxCells do
        local removed = table.remove(cells)
        byKey[cellKey(removed)] = nil
    end

    return {
        cells = cells,
        byKey = byKey,
        aiPlayer = playerId,
        enemyPlayer = enemyPlayer
    }
end

function M.build(state, ai, ctx)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or getOpponent(ai, playerId)
    local result = {
        phase = ctx and ctx.phase and ctx.phase.name or ctx and ctx.phase or "unknown",
        aiPlayer = playerId,
        enemyPlayer = enemyPlayer,
        friendlyControlled = {},
        enemyControlled = {},
        contested = {},
        traps = {},
        safeOnlyIfCovered = {},
        multiThreat = {},
        strategicFreeCells = {},
        strategicFreeCellsByKey = {},
        influenceByKey = {},
        units = {}
    }

    local function addControlled(bucket, unit, cell)
        local key = cellKey(cell)
        bucket[key] = bucket[key] or {
            row = cell.row,
            col = cell.col,
            controllers = {}
        }
        bucket[key].controllers[#bucket[key].controllers + 1] = {
            name = unit.name,
            player = unit.player,
            row = unit.row,
            col = unit.col
        }
    end

    local size = gridSize(state)
    local ownActionState = influenceStateForPlayer(ai, state, playerId, {})
    local enemyActionState = influenceStateForPlayer(ai, state, enemyPlayer, {})
    local influenceOpts = {
        preparedByPlayer = {
            [playerId] = ownActionState,
            [enemyPlayer] = enemyActionState
        },
        deploymentsByPlayer = {
            [playerId] = getDeploymentsForPlayer(ai, ownActionState, playerId),
            [enemyPlayer] = getDeploymentsForPlayer(ai, enemyActionState, enemyPlayer)
        }
    }
    for row = 1, size do
        for col = 1, size do
            result.influenceByKey[cellKey(row, col)] =
                M.analyzeCellInfluence(state, ai, ctx, {row = row, col = col}, influenceOpts)
        end
    end

    for _, side in ipairs({
        {player = playerId, bucket = result.friendlyControlled},
        {player = enemyPlayer, bucket = result.enemyControlled}
    }) do
        for _, unit in ipairs(getUnitsForPlayer(ai, state, side.player, {includeHubs = false})) do
            for row = 1, size do
                for col = 1, size do
                    if canAttackCellFrom(ai, state, unit, unit, {row = row, col = col}, {allowEmptyTarget = true}) then
                        addControlled(side.bucket, unit, {row = row, col = col})
                    end
                end
            end
        end
    end

    for key, friendly in pairs(result.friendlyControlled) do
        if result.enemyControlled[key] then
            result.contested[key] = {
                row = friendly.row,
                col = friendly.col
            }
        end
    end

    for _, unit in ipairs(getUnitsForPlayer(ai, state, playerId, {includeHubs = false})) do
        local analysis = M.analyzeCell(state, ai, ctx, unit, unit)
        result.units[#result.units + 1] = analysis
        if analysis.enemyBestReply and not analysis.covered then
            result.traps[cellKey(unit)] = analysis
        elseif analysis.enemyBestReply and analysis.covered then
            result.safeOnlyIfCovered[cellKey(unit)] = analysis
        end
    end

    local strategic = M.findStrategicFreeCells(state, ai, ctx, {maxCells = 24})
    result.strategicFreeCells = strategic.cells
    result.strategicFreeCellsByKey = strategic.byKey

    return result
end

M._private = {
    cellKey = cellKey,
    canAttackCellFrom = canAttackCellFrom,
    calculateDamage = calculateDamage,
    unitAttackRange = unitAttackRange,
    unitMoveRange = unitMoveRange,
    getUnitAt = getUnitAt,
    cellControlledBy = cellControlledBy,
    canRepairCellFrom = canRepairCellFrom,
    getDeploymentsForPlayer = getDeploymentsForPlayer
}

return M
