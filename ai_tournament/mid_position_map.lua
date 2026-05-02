local strategicInterpreter = require("ai_tournament.strategic_interpreter")
local strategicQuestions = require("ai_tournament.strategic_questions")

local M = {}

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

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clamp(value, minValue, maxValue)
    local n = num(value, 0)
    if n < minValue then
        return minValue
    end
    if n > maxValue then
        return maxValue
    end
    return n
end

local function gridSize(state)
    return num(state and state.gridSize, num(GAME and GAME.CONSTANTS and GAME.CONSTANTS.GRID_SIZE, DEFAULT_GRID_SIZE))
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

local function active(bucket)
    return bucket and bucket.active == true
end

local function count(bucket)
    return num(bucket and bucket.count, 0)
end

local function appendReason(reasons, reason, value)
    if value ~= 0 then
        reasons[#reasons + 1] = {
            reason = reason,
            value = value
        }
    end
end

local function isHub(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        local ok, value = pcall(ai.isHubUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return tostring(unit.name or "") == "Commandant"
end

local function isObstacle(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        local ok, value = pcall(ai.isObstacleUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return unit.player == 0 or tostring(unit.name or "") == "Rock"
end

local function hubAsUnit(state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not hub then
        return nil
    end
    return {
        name = hub.name or "Commandant",
        player = playerId,
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }
end

local function getUnitAt(ai, state, row, col)
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
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    for playerId, hub in pairs(state.commandHubs or {}) do
        if hub and num(hub.row, -1) == row and num(hub.col, -1) == col then
            return hubAsUnit(state, playerId)
        end
    end
    for _, rock in ipairs(state.neutralBuildings or {}) do
        if rock and num(rock.row, -1) == row and num(rock.col, -1) == col then
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

local function lineDistance(ownHub, enemyHub, cell)
    if not (ownHub and enemyHub and cell) then
        return 0
    end
    local dr = num(enemyHub.row, 0) - num(ownHub.row, 0)
    local dc = num(enemyHub.col, 0) - num(ownHub.col, 0)
    local cr = num(cell.row, 0) - num(ownHub.row, 0)
    local cc = num(cell.col, 0) - num(ownHub.col, 0)
    local denom = math.max(1, math.abs(dr) + math.abs(dc))
    return math.abs((dr * cc) - (dc * cr)) / denom
end

local function routeProgress(ownHub, enemyHub, cell)
    if not (ownHub and enemyHub and cell) then
        return 0
    end
    return manhattan(ownHub, enemyHub) - manhattan(cell, enemyHub)
end

local function routeContext(state, ctx)
    local playerId = ctx and ctx.aiPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or (playerId == 1 and 2 or 1)
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    return {
        playerId = playerId,
        enemyPlayer = enemyPlayer,
        ownHub = ownHub,
        enemyHub = enemyHub,
        distance = manhattan(ownHub, enemyHub)
    }
end

local function centerDistance(state, cell)
    local size = gridSize(state)
    local center = (size + 1) / 2
    return math.abs(num(cell.row, 0) - center) + math.abs(num(cell.col, 0) - center)
end

local function compactReasons(reasons, limit)
    local sorted = {}
    for _, entry in ipairs(reasons or {}) do
        sorted[#sorted + 1] = entry
    end
    table.sort(sorted, function(a, b)
        local av = math.abs(num(a and a.value, 0))
        local bv = math.abs(num(b and b.value, 0))
        if av == bv then
            return tostring(a and a.reason or "") < tostring(b and b.reason or "")
        end
        return av > bv
    end)

    local out = {}
    for index, entry in ipairs(sorted) do
        if index > limit then
            break
        end
        out[#out + 1] = tostring(entry.reason or entry)
    end
    return out
end

local function strategicBlend(cell, ctx)
    local pressure = strategicQuestions.scoreCell(cell, "pressure", {ctx = ctx})
    local contain = strategicQuestions.scoreCell(cell, "contain", {ctx = ctx})
    local expand = strategicQuestions.scoreCell(cell, "expand", {ctx = ctx})
    return {
        value = (num(pressure and pressure.value, 0) * 0.80)
            + (num(contain and contain.value, 0) * 0.35)
            + (num(expand and expand.value, 0) * 0.25),
        pressure = num(pressure and pressure.value, 0),
        contain = num(contain and contain.value, 0),
        expand = num(expand and expand.value, 0)
    }
end

local function classifyCell(ai, state, ctx, cell, occupant, influence)
    local playerId = ctx and ctx.aiPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or (playerId == 1 and 2 or 1)
    if occupant and isObstacle(ai, occupant) then
        return "blocked"
    end
    if occupant and isHub(ai, occupant) then
        return occupant.player == enemyPlayer and "enemy_commandant" or "own_commandant"
    end
    if occupant and occupant.player == playerId then
        return "owned_pressure"
    end
    if occupant and occupant.player == enemyPlayer then
        return "enemy_occupied"
    end
    if cell.attackContested == true then
        return "contested_pressure"
    end
    if active(influence and influence.moveAttackInfluence and influence.moveAttackInfluence.us)
        or active(cell and cell.attackInfluence and cell.attackInfluence.us)
        or (cell.opportunity and cell.opportunity.secondThreat == true) then
        return "pressure_cell"
    end
    if active(cell and cell.moveInfluence and cell.moveInfluence.us)
        or active(cell and cell.deployInfluence and cell.deployInfluence.us) then
        return "advance_cell"
    end
    if active(cell and cell.attackInfluence and cell.attackInfluence.us) then
        return "support_cell"
    end
    return "other"
end

local function scoreCell(ai, state, ctx, position, cell, route)
    local playerId = route.playerId
    local enemyPlayer = route.enemyPlayer
    local occupant = getUnitAt(ai, state, cell.row, cell.col)
    local influence = position and position.source and position.source.influenceByKey
        and position.source.influenceByKey[cellKey(cell)]
        or cell
    local ownAttack = cell.attackInfluence and cell.attackInfluence.us
    local enemyAttack = cell.attackInfluence and cell.attackInfluence.enemy
    local ownMove = cell.moveInfluence and cell.moveInfluence.us
    local ownDeploy = cell.deployInfluence and cell.deployInfluence.us
    local ownMoveAttack = cell.moveAttackInfluence and cell.moveAttackInfluence.us
    local enemyMoveAttack = cell.moveAttackInfluence and cell.moveAttackInfluence.enemy
    local directlyAttackableByEnemy = active(enemyAttack)
    local status = classifyCell(ai, state, ctx, cell, occupant, influence)
    local reasons = {}
    local blend = strategicBlend(cell, ctx)
    local value = blend.value
    appendReason(reasons, "mid_pressure_question", blend.pressure * 0.80)
    appendReason(reasons, "mid_contain_question", blend.contain * 0.35)
    appendReason(reasons, "mid_expand_question", blend.expand * 0.25)

    local progress = routeProgress(route.ownHub, route.enemyHub, cell)
    local lateral = lineDistance(route.ownHub, route.enemyHub, cell)
    local progressValue = clamp(progress * 24, -80, 190)
    value = value + progressValue
    appendReason(reasons, "mid_forward_progress", progressValue)

    local enemyHubDistance = manhattan(cell, route.enemyHub)
    local pressureValue = 0
    if enemyHubDistance <= 3 then
        pressureValue = pressureValue + 115
    elseif enemyHubDistance <= 5 then
        pressureValue = pressureValue + 70
    elseif enemyHubDistance <= 7 then
        pressureValue = pressureValue + 35
    end
    if active(ownMoveAttack) then
        pressureValue = pressureValue + 55
    end
    if active(ownAttack) then
        pressureValue = pressureValue + 30 + (count(ownAttack) * 12)
    end
    if cell.opportunity and cell.opportunity.secondThreat then
        pressureValue = pressureValue + 85
    end
    value = value + pressureValue
    appendReason(reasons, "mid_command_pressure", pressureValue)

    local contestValue = 0
    if cell.attackContested == true then
        contestValue = contestValue + 90
    elseif cell.influenceContested == true then
        contestValue = contestValue + 48
    elseif cell.potentialInfluenceContested == true then
        contestValue = contestValue + 28
    end
    if active(enemyAttack) then
        contestValue = contestValue + math.min(count(enemyAttack) * 10, 60)
    end
    if active(enemyMoveAttack) then
        contestValue = contestValue + math.min(count(enemyMoveAttack) * 8, 56)
    end
    value = value + contestValue
    appendReason(reasons, "mid_contested_pressure", contestValue)

    local reachValue = 0
    if active(ownMove) then
        reachValue = reachValue + 38
    end
    if active(ownDeploy) then
        reachValue = reachValue + 22
    end
    value = value + reachValue
    appendReason(reasons, "mid_reachable_now", reachValue)

    local tradeNet = num(cell.tradeNet, 0)
    local tradeValue = 0
    if tradeNet > 0 then
        tradeValue = tradeValue + math.min(tradeNet * 14, 220)
    elseif tradeNet < 0 then
        tradeValue = tradeValue + math.max(tradeNet * 8, -160)
    end
    if cell.coveredIfOccupied == true then
        tradeValue = tradeValue + 70
    end
    if cell.risk and cell.risk.lethalPunish and tradeNet < 0 then
        tradeValue = tradeValue - 135
    elseif cell.risk and cell.risk.enemyPunish and tradeNet < 0 then
        tradeValue = tradeValue - 45
    end
    value = value + tradeValue
    appendReason(reasons, "mid_trade_expectation", tradeValue)

    local occupancyValue = 0
    local attackableEnemy = false
    if occupant and occupant.player == enemyPlayer and not isObstacle(ai, occupant) then
        attackableEnemy = active(ownAttack) or active(ownMoveAttack)
        occupancyValue = occupancyValue + math.min(unitValue(ai, occupant, state) * (attackableEnemy and 0.65 or 0.25), 120)
        if attackableEnemy then
            occupancyValue = occupancyValue + 85
        end
    elseif occupant and occupant.player == playerId and not isObstacle(ai, occupant) then
        occupancyValue = occupancyValue + 35
        if directlyAttackableByEnemy and cell.coveredIfOccupied == true then
            occupancyValue = occupancyValue + 55
        end
    elseif status == "blocked" or status == "own_commandant" then
        occupancyValue = occupancyValue - 500
    elseif status == "enemy_commandant" then
        occupancyValue = occupancyValue + 210
        attackableEnemy = active(ownAttack) or active(ownMoveAttack)
    end
    value = value + occupancyValue
    appendReason(reasons, attackableEnemy and "mid_attackable_enemy" or "mid_occupancy", occupancyValue)

    local laneValue = clamp(lateral * 18, 0, 90)
    if lateral < 0.75 and progress > 0 then
        laneValue = laneValue - 25
    end
    value = value + laneValue
    appendReason(reasons, "mid_lane_width", laneValue)

    local centerValue = -centerDistance(state, cell) * 5
    value = value + centerValue
    appendReason(reasons, "mid_board_centrality", centerValue)

    return {
        key = cellKey(cell),
        row = cell.row,
        col = cell.col,
        value = value,
        status = status,
        free = occupant == nil,
        occupiedByUs = occupant and occupant.player == playerId and not isObstacle(ai, occupant) or false,
        occupiedByEnemy = occupant and occupant.player == enemyPlayer and not isObstacle(ai, occupant) or false,
        attackableEnemy = attackableEnemy == true,
        directlyAttackableByEnemy = directlyAttackableByEnemy == true,
        enemyAttackCount = count(enemyAttack),
        enemyMoveAttackCount = count(enemyMoveAttack),
        ownAttackCount = count(ownAttack),
        ownMoveAttackCount = count(ownMoveAttack),
        reachable = active(ownMove),
        deployable = active(ownDeploy),
        attackContested = cell.attackContested == true,
        influenceContested = cell.influenceContested == true,
        potentialInfluenceContested = cell.potentialInfluenceContested == true,
        coveredIfOccupied = cell.coveredIfOccupied == true,
        tradeNet = tradeNet,
        enemyPunish = cell.enemyPunish,
        counterPunish = cell.counterPunish,
        pressureQuestionValue = blend.pressure,
        containQuestionValue = blend.contain,
        expandQuestionValue = blend.expand,
        progress = progress,
        lateral = lateral,
        enemyHubDistance = enemyHubDistance,
        strategicValue = num(cell.strategicScore, 0),
        salience = num(cell.salience, 0),
        kinds = cell.kinds or {},
        reasons = reasons,
        compactReasons = compactReasons(reasons, 5)
    }
end

local function topCells(cells, limit, predicate)
    local out = {}
    for _, cell in ipairs(cells or {}) do
        if not predicate or predicate(cell) then
            out[#out + 1] = cell
            if #out >= limit then
                break
            end
        end
    end
    return out
end

local function summarizeTop(top)
    local out = {}
    for _, cell in ipairs(top or {}) do
        out[#out + 1] = table.concat({
            tostring(cell.row) .. "," .. tostring(cell.col),
            tostring(cell.status or "unknown"),
            tostring(math.floor(num(cell.value, 0))),
            table.concat(cell.compactReasons or {}, "+")
        }, ":")
    end
    return out
end

local function countStatuses(cells)
    local out = {}
    for _, cell in ipairs(cells or {}) do
        local status = tostring(cell.status or "other")
        out[status] = num(out[status], 0) + 1
    end
    return out
end

function M.build(ai, state, ctx, options)
    options = options or {}
    if not (state and ctx and strategicInterpreter and strategicInterpreter.interpret) then
        return nil
    end

    local position = strategicInterpreter.interpret(state, ai, ctx, options)
    local route = routeContext(state, ctx)
    local cells = {}
    local byKey = {}
    for _, cell in ipairs((position and position.cells) or {}) do
        local scored = scoreCell(ai, state, ctx, position, cell, route)
        cells[#cells + 1] = scored
        byKey[scored.key] = scored
    end

    table.sort(cells, function(a, b)
        if num(a.value, 0) == num(b.value, 0) then
            return tostring(a.key or "") < tostring(b.key or "")
        end
        return num(a.value, 0) > num(b.value, 0)
    end)

    local limit = math.max(1, num(options.limit, ctx.cfg and ctx.cfg.MID_POSITION_MAP_TOP_N or 10))
    local top = topCells(cells, limit)
    local contestedTop = topCells(cells, limit, function(cell)
        return cell.attackContested == true or cell.influenceContested == true or cell.potentialInfluenceContested == true
    end)
    local pressureTop = topCells(cells, limit, function(cell)
        return cell.status == "pressure_cell"
            or cell.status == "contested_pressure"
            or num(cell.ownMoveAttackCount, 0) > 0
            or num(cell.enemyHubDistance, 99) <= 5
    end)
    local tradeTop = topCells(cells, limit, function(cell)
        return num(cell.tradeNet, 0) > 0 or cell.coveredIfOccupied == true
    end)
    local attackTargets = topCells(cells, limit, function(cell)
        return cell.attackableEnemy == true
    end)
    local positionTop = topCells(cells, limit, function(cell)
        return cell.free == true and (cell.reachable == true or cell.deployable == true)
    end)

    local result = {
        kind = "mid_position_map",
        version = 1,
        cellCount = #cells,
        cells = cells,
        byKey = byKey,
        top = top,
        contestedTop = contestedTop,
        pressureTop = pressureTop,
        tradeTop = tradeTop,
        attackTargets = attackTargets,
        positionTop = positionTop,
        statusCounts = countStatuses(cells),
        source = position
    }

    if ctx.stats then
        ctx.stats.midPositionMapEnabled = true
        ctx.stats.midPositionMapCellCount = result.cellCount
        ctx.stats.midPositionMapTopCells = summarizeTop(top)
        ctx.stats.midPositionMapContestedTop = summarizeTop(contestedTop)
        ctx.stats.midPositionMapPressureTop = summarizeTop(pressureTop)
        ctx.stats.midPositionMapTradeTop = summarizeTop(tradeTop)
        ctx.stats.midPositionMapAttackTargets = summarizeTop(attackTargets)
        ctx.stats.midPositionMapPositionTop = summarizeTop(positionTop)
        ctx.stats.midPositionMapStatusCounts = result.statusCounts
    end

    return result
end

return M
