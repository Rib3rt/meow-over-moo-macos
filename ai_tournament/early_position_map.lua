local strategicInterpreter = require("ai_tournament.strategic_interpreter")
local strategicQuestions = require("ai_tournament.strategic_questions")
local earlyCellPolicy = require("ai_tournament.early_position_cell_policy")
local earlyPositionFrontier = require("ai_tournament.early_position_frontier")
local earlyCloudstrikerPressure = require("ai_tournament.early_cloudstriker_pressure")
local tollRoute = require("ai_tournament.early_position_toll_route")
local punishMap = require("ai_tournament.punish_map")

local M = {}

local DEFAULT_GRID_SIZE = 8

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

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function active(bucket)
    return bucket and bucket.active == true
end

local function count(bucket)
    return num(bucket and bucket.count, 0)
end

local function getUnitAt(state, row, col)
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    for _, rock in ipairs((state and state.neutralBuildings) or {}) do
        if rock and num(rock.row, -1) == row and num(rock.col, -1) == col then
            return {
                name = rock.name or "Rock",
                player = 0,
                row = row,
                col = col
            }
        end
    end
    return nil
end

local function isHub(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        local ok, result = pcall(ai.isHubUnit, ai, unit)
        if ok then
            return result == true
        end
    end
    return tostring(unit.name or "") == "Commandant"
end

local function ownBoardUnits(ai, state, playerId)
    local result = {}
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and unit.player == playerId and not isHub(ai, unit) then
            result[#result + 1] = unit
        end
    end
    return result
end

local function nearestOwnDistance(ai, state, playerId, cell)
    local best = 99
    for _, unit in ipairs(ownBoardUnits(ai, state, playerId)) do
        best = math.min(best, manhattan(unit, cell))
    end
    return best
end

local function routeProgress(ownHub, enemyHub, cell)
    if not (ownHub and enemyHub and cell) then
        return 0
    end
    return manhattan(ownHub, enemyHub) - manhattan(cell, enemyHub)
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

local function buildRouteContext(ai, state, ctx)
    local playerId = ctx and ctx.aiPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or (playerId == 1 and 2 or 1)
    local ownHub = state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = state and state.commandHubs and state.commandHubs[enemyPlayer]
    local mainRouteOwnCount = 0
    local mainRouteForwardOwnCount = 0

    for _, unit in ipairs(ownBoardUnits(ai, state, playerId)) do
        local lateral = lineDistance(ownHub, enemyHub, unit)
        local progress = routeProgress(ownHub, enemyHub, unit)
        if lateral < 0.75 then
            mainRouteOwnCount = mainRouteOwnCount + 1
            if progress > 0 then
                mainRouteForwardOwnCount = mainRouteForwardOwnCount + 1
            end
        end
    end

    return {
        ownHub = ownHub,
        enemyHub = enemyHub,
        distance = manhattan(ownHub, enemyHub),
        mainRouteOwnCount = mainRouteOwnCount,
        mainRouteForwardOwnCount = mainRouteForwardOwnCount,
        mainRouteSaturation = clamp(mainRouteForwardOwnCount / 2, 0, 1)
    }
end

local function centerDistance(state, cell)
    local size = gridSize(state)
    local center = (size + 1) / 2
    return math.abs(num(cell.row, 0) - center) + math.abs(num(cell.col, 0) - center)
end

local function appendReason(reasons, reason, value)
    if value ~= 0 then
        reasons[#reasons + 1] = {
            reason = reason,
            value = value
        }
    end
end

local function hasKind(cell, kind)
    for _, value in ipairs((cell and cell.kinds) or {}) do
        if value == kind then
            return true
        end
    end
    return false
end

local function hasAnyStrategicKind(cell)
    return #(cell and cell.kinds or {}) > 0
end

local neutralPurposeForPlan

local function coveredByOwnInfluence(cell)
    local ownAttack = cell and cell.attackInfluence and cell.attackInfluence.us or nil
    return active(ownAttack) and count(ownAttack) > 0
end

local function canAttackCellFrom(ai, state, unit, fromCell, targetCell)
    local priv = punishMap and punishMap._private or {}
    if priv.canAttackCellFrom then
        return priv.canAttackCellFrom(ai, state, unit, fromCell, targetCell, {allowEmptyTarget = true}) == true
    end

    local rowDiff = math.abs(num(fromCell and fromCell.row, 0) - num(targetCell and targetCell.row, 0))
    local colDiff = math.abs(num(fromCell and fromCell.col, 0) - num(targetCell and targetCell.col, 0))
    local distance = rowDiff + colDiff
    local range = num(unit and (unit.atkRange or unit.range), 1)
    return distance > 0 and distance <= range and (rowDiff == 0 or colDiff == 0)
end

local function strictResolvedCoverEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_STRICT_RESOLVED_COVER == false)
end

local function classifyCell(cell, free, occupiedByUs, coveredByUs, lateral, progress, route, usMove, usDeploy)
    if occupiedByUs then
        if coveredByUs == true then
            return "owned_covered"
        end
        return "owned_uncovered"
    end

    if not free then
        return "blocked"
    end

    local occupiable = active(usMove) or active(usDeploy)
    local useful = occupiable
        or hasAnyStrategicKind(cell)
        or cell.potentialInfluencedByUs == true
        or progress > 0
    if not useful then
        return "other"
    end

    local routeSaturation = num(route and route.mainRouteSaturation, 0)
    if routeSaturation >= 0.5 and lateral >= 0.75 and progress > 0 then
        return "next_expansion"
    end

    return "free_target"
end

local function bestOccupantEnemyReply(ai, state, ctx, playerId, occupant, cell, cache)
    if not (punishMap and punishMap.bestEnemyReply and occupant and cell) then
        return nil
    end
    local key = cellKey(cell)
    if cache and cache[key] ~= nil then
        return cache[key] or nil
    end
    local ok, reply = pcall(punishMap.bestEnemyReply, state, ai, ctx, playerId, occupant, cell)
    if ok then
        if cache then
            cache[key] = reply or false
        end
        return reply
    end
    if cache then
        cache[key] = false
    end
    return nil
end

local function occupantThreatDamage(reply)
    return num(reply and (reply.damage or reply.expectedDamage), 0)
end

local function baseStrategicScore(ai, state, ctx, cell, route)
    local playerId = ctx and ctx.aiPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or (playerId == 1 and 2 or 1)
    local ownHub = route and route.ownHub or state and state.commandHubs and state.commandHubs[playerId]
    local enemyHub = route and route.enemyHub or state and state.commandHubs and state.commandHubs[enemyPlayer]
    local reasons = {}

    local purpose = neutralPurposeForPlan(ctx)
    local strategic = strategicQuestions.scoreCell(cell, purpose, {ctx = ctx})
    local value = num(strategic and strategic.value, 0)
    appendReason(reasons, "strategic_" .. purpose, value)

    local lateral = lineDistance(ownHub, enemyHub, cell)
    local progress = routeProgress(ownHub, enemyHub, cell)
    local routeProximity = clamp(1 - (lateral / 2.5), 0, 1)
    local toll = tollRoute.score(state, ctx, route, cell)
    value = value + num(toll and toll.value, 0)
    appendReason(reasons, "toll_route", num(toll and toll.value, 0))

    local mainRouteValue = 0
    if progress > 0 then
        mainRouteValue = clamp(progress * 22, 0, 150) * (0.55 + (routeProximity * 0.45))
    end
    value = value + mainRouteValue
    appendReason(reasons, "main_route_progress", mainRouteValue)

    local routeClosure = 0
    if progress > 0 and routeProximity > 0.35 then
        routeClosure = 30 + (routeProximity * 55)
        if hasKind(cell, "choke") then
            routeClosure = routeClosure + 45
        end
        if hasKind(cell, "support") then
            routeClosure = routeClosure + 25
        end
        if cell.coveredIfOccupied == true then
            routeClosure = routeClosure + 30
        end
    end
    value = value + routeClosure
    appendReason(reasons, "route_closure", routeClosure)

    local routeSaturation = num(route and route.mainRouteSaturation, 0)
    local lateralExpansion = clamp(lateral * (28 + (routeSaturation * 42)), 0, 150)
    value = value + lateralExpansion
    appendReason(reasons, "lateral_expansion", lateralExpansion)

    local corridorPenalty = 0
    if lateral < 0.75 and not hasKind(cell, "choke") and not hasKind(cell, "support") then
        corridorPenalty = -45 - (routeSaturation * 95)
        value = value + corridorPenalty
        appendReason(reasons, "tunnel_redundancy_penalty", corridorPenalty)
    end

    local opportunity = 0
    if progress > 0 and lateral >= 0.75 then
        opportunity = opportunity + clamp(progress * 9, 0, 55)
    end
    if hasKind(cell, "safe_staging") then
        opportunity = opportunity + 35
    end
    if hasKind(cell, "support") then
        opportunity = opportunity + 24
    end
    if hasKind(cell, "choke") then
        opportunity = opportunity + 22
    end
    if cell.potentialInfluencedByUs == true and cell.attackContested ~= true then
        opportunity = opportunity + 20
    end
    value = value + opportunity
    appendReason(reasons, "new_opportunity", opportunity)

    local nearest = nearestOwnDistance(ai, state, playerId, cell)
    local spread = 0
    if nearest <= 1 then
        spread = -45
    elseif nearest <= 3 then
        spread = 70
    elseif nearest <= 5 then
        spread = 25
    else
        spread = -35
    end
    value = value + spread
    appendReason(reasons, "formation_spread", spread)

    local center = -centerDistance(state, cell) * 8
    value = value + center
    appendReason(reasons, "board_centrality", center)

    return {
        value = value,
        reasons = reasons,
        strategicValue = num(strategic and strategic.value, 0),
        lateral = lateral,
        progress = progress,
        routeProximity = routeProximity,
        toll = toll,
        mainRouteValue = mainRouteValue,
        routeClosure = routeClosure,
        lateralExpansion = lateralExpansion,
        corridorPenalty = corridorPenalty,
        opportunity = opportunity,
        nearest = nearest
    }
end

local function coveredByOwnSupport(ai, state, ctx, position, route, cell, replyCache, holdCache)
    if not strictResolvedCoverEnabled(ctx) then
        return coveredByOwnInfluence(cell)
    end

    local playerId = ctx and ctx.aiPlayer or 1
    local targetKey = cellKey(cell)
    for _, unit in ipairs(ownBoardUnits(ai, state, playerId)) do
        if cellKey(unit) ~= targetKey and canAttackCellFrom(ai, state, unit, unit, cell) then
            return true
        end
    end
    return false
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

function neutralPurposeForPlan(ctx)
    local plan = ctx and ctx.earlyPlan or {}
    local intent = tostring(plan.intentId or plan.intent or "")
    if intent == "choke_lock" then
        return "contain"
    end
    if intent == "ranged_battery" then
        return "support"
    end
    return "expand"
end

local function activeContract(ctx, contractName)
    local contracts = ctx and ctx.activeContracts
    if contracts and contracts.defenseActive == true and contractName == "DEFEND_NOW" then
        return true
    end
    for _, name in ipairs((contracts and contracts.activeNames) or {}) do
        if tostring(name) == contractName then
            return true
        end
    end
    for _, name in ipairs((ctx and ctx.stats and ctx.stats.activeContracts) or {}) do
        if tostring(name) == contractName then
            return true
        end
    end
    return false
end

local function homeReserveEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_HOME_ADJACENT_RESERVE_ENABLED == false)
end

local function homeReservePenaltyValue(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_HOME_ADJACENT_RESERVE_PENALTY, 160)
end

local function homeReserveOccupiedExtraPenalty(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_HOME_ADJACENT_OCCUPIED_EXTRA_PENALTY, 100)
end

local function homeAdjacentReservePenalty(ctx, route, cell, occupiedByUs)
    if not (homeReserveEnabled(ctx) and route and route.ownHub and cell) then
        return 0
    end
    if activeContract(ctx, "DEFEND_NOW") then
        return 0
    end
    if manhattan(route.ownHub, cell) ~= 1 then
        return 0
    end

    local penalty = homeReservePenaltyValue(ctx)
    if occupiedByUs == true then
        penalty = penalty + homeReserveOccupiedExtraPenalty(ctx)
    end
    return -math.max(0, penalty)
end

local function scoreCell(ai, state, ctx, position, cell, route, replyCache, holdCache)
    local playerId = ctx and ctx.aiPlayer or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or (playerId == 1 and 2 or 1)
    local occupant = getUnitAt(state, cell.row, cell.col)
    local occupiedByUs = occupant and occupant.player == playerId
    local free = occupant == nil
    local base = baseStrategicScore(ai, state, ctx, cell, route)
    local reasons = base.reasons
    local value = base.value
    local lateral = base.lateral
    local progress = base.progress
    local routeProximity = base.routeProximity
    local toll = base.toll
    local mainRouteValue = base.mainRouteValue
    local routeClosure = base.routeClosure
    local lateralExpansion = base.lateralExpansion
    local corridorPenalty = base.corridorPenalty
    local opportunity = base.opportunity
    local nearest = base.nearest

    local usMove = cell.moveInfluence and cell.moveInfluence.us
    local usDeploy = cell.deployInfluence and cell.deployInfluence.us
    local enemyAttack = cell.attackInfluence and cell.attackInfluence.enemy
    local enemyAttackCount = count(enemyAttack)
    local enemyMoveAttack = cell.moveAttackInfluence and cell.moveAttackInfluence.enemy
    local enemyMoveAttackCount = count(enemyMoveAttack)
    local enemyPunishAvailable = earlyCellPolicy.enemyPunishAvailable(cell)
    local attackContested = cell.attackContested == true
    local coveredByUs = coveredByOwnSupport(ai, state, ctx, position, route, cell, replyCache, holdCache)
    local status = classifyCell(cell, free, occupiedByUs, coveredByUs, lateral, progress, route, usMove, usDeploy)
    local earlyStrategicValue = value
    local homeReservePenalty = homeAdjacentReservePenalty(ctx, route, cell, occupiedByUs == true)
    if homeReservePenalty ~= 0 then
        value = value + homeReservePenalty
        earlyStrategicValue = earlyStrategicValue + homeReservePenalty
        appendReason(reasons, "home_adjacent_reserve", homeReservePenalty)
    end

    local statusValue = 0
    if status == "free_target" then
        statusValue = 50
    elseif status == "owned_uncovered" then
        statusValue = 95
    elseif status == "owned_covered" then
        statusValue = -165
    elseif status == "next_expansion" then
        statusValue = 75
    end
    value = value + statusValue
    appendReason(reasons, "cell_state_" .. status, statusValue)

    local reach = 0
    if active(usMove) then
        reach = reach + 35
    end
    if active(usDeploy) then
        reach = reach + 24
    end
    value = value + reach
    appendReason(reasons, "occupiable_now", reach)

    local neutralPenalty = 0
    if hasKind(cell, "second_threat") then
        neutralPenalty = neutralPenalty - 55
    end
    if attackContested then
        neutralPenalty = neutralPenalty - 35
    end
    if enemyAttackCount > 0 and cell.coveredIfOccupied ~= true then
        neutralPenalty = neutralPenalty - (30 + (enemyAttackCount * 12))
    end
    if cell.risk and cell.risk.lethalPunish then
        neutralPenalty = neutralPenalty - 180
    elseif cell.risk and cell.risk.enemyPunish then
        neutralPenalty = neutralPenalty - 95
    end
    value = value + neutralPenalty
    appendReason(reasons, "neutral_no_forced_contact", neutralPenalty)

    if occupiedByUs then
        value = value - 80
        appendReason(reasons, "already_occupied_by_us", -80)
    elseif not free then
        value = value - 220
        appendReason(reasons, "blocked_cell", -220)
    end

    local directlyAttackableByEnemy = enemyAttackCount > 0
    local occupantReply = occupiedByUs and bestOccupantEnemyReply(ai, state, ctx, playerId, occupant, cell, replyCache) or nil
    local cloudstrikerPressure = occupiedByUs
        and earlyCloudstrikerPressure.evaluateHold(ai, state, ctx, occupant, cell, occupantReply)
        or nil
    if cloudstrikerPressure then
        local penalty = num(cloudstrikerPressure.penalty, 0)
        value = value - penalty
        earlyStrategicValue = earlyStrategicValue - penalty
        appendReason(reasons, "cloudstriker_blocked_pressure", -penalty)
    end
    local policyCell = {
        value = value,
        earlyStrategicValue = earlyStrategicValue,
        enemyAttackCount = enemyAttackCount,
        enemyMoveAttackCount = enemyMoveAttackCount,
        directlyAttackableByEnemy = directlyAttackableByEnemy,
        attackContested = attackContested,
        enemyPunish = cell.enemyPunish,
        risk = cell.risk,
        occupiedByUs = occupiedByUs == true,
        occupantEnemyBestReply = occupantReply,
        occupantThreatDamage = occupantReply and occupantThreatDamage(occupantReply) or nil,
        occupantThreatLethal = occupantReply and occupantReply.lethal == true or nil,
        occupantHp = occupant and num(occupant.currentHp or occupant.startingHp, 0) or nil
    }
    local strictGoodEarlyStrategic = earlyCellPolicy.isGoodStrategicCell(policyCell, ctx)
    local goodEarlyStrategic = strictGoodEarlyStrategic
        or (occupiedByUs and earlyCellPolicy.isHoldableOccupiedStrategicCell(policyCell, ctx))
    local holdNonLethalThreat = goodEarlyStrategic and not strictGoodEarlyStrategic
    local coverUrgencyBonus = holdNonLethalThreat and earlyCellPolicy.coverUrgencyBonus(policyCell, ctx) or 0
    if goodEarlyStrategic and not strictGoodEarlyStrategic then
        appendReason(reasons, "hold_nonlethal_threat", 25)
        value = value + 25
    end

    return {
        key = cellKey(cell),
        row = cell.row,
        col = cell.col,
        value = value,
        earlyStrategicValue = earlyStrategicValue,
        status = status,
        free = free,
        occupiedByUs = occupiedByUs == true,
        coveredByUs = coveredByUs == true,
        attackContested = attackContested,
        enemyAttackCount = enemyAttackCount,
        enemyMoveAttackCount = enemyMoveAttackCount,
        directlyAttackableByEnemy = directlyAttackableByEnemy,
        enemyPunish = cell.enemyPunish,
        enemyPunishAvailable = enemyPunishAvailable,
        enemyPunishKind = cell.enemyPunish and cell.enemyPunish.kind or nil,
        occupantEnemyBestReply = occupantReply,
        occupantThreatDamage = occupantReply and occupantThreatDamage(occupantReply) or nil,
        occupantThreatLethal = occupantReply and occupantReply.lethal == true or false,
        occupantHp = occupant and num(occupant.currentHp or occupant.startingHp, 0) or nil,
        cloudstrikerBlockedPressure = cloudstrikerPressure ~= nil,
        cloudstrikerBlockedPressurePenalty = cloudstrikerPressure and cloudstrikerPressure.penalty or 0,
        cloudstrikerBlockedPressureDamage = cloudstrikerPressure and cloudstrikerPressure.damage or 0,
        cloudstrikerBlockedPressureBlocker =
            cloudstrikerPressure
                and cloudstrikerPressure.blocker
                and tostring(cloudstrikerPressure.blocker.name or "?")
            or nil,
        holdNonLethalThreat = holdNonLethalThreat == true,
        coverUrgencyBonus = coverUrgencyBonus,
        goodEarlyStrategic = goodEarlyStrategic == true,
        reachable = active(usMove),
        deployable = active(usDeploy),
        lateral = lateral,
        progress = progress,
        routeProximity = routeProximity,
        tollRouteValue = num(toll and toll.value, 0),
        tollRouteSlack = num(toll and toll.routeSlack, 99),
        tollRouteFit = num(toll and toll.routeFit, 0),
        tollFieldProgress = num(toll and toll.fieldProgress, 0),
        tollPressure = num(toll and toll.tollPressure, 0),
        fireLaneScore = num(cell.fireLaneScore, num(cell.fireLane and cell.fireLane.score, 0)),
        fireLaneControlledCount =
            num(cell.fireLaneControlledCount, num(cell.fireLane and cell.fireLane.controlledCount, 0)),
        deadFireLane = cell.deadFireLane == true,
        mainRouteValue = mainRouteValue,
        routeClosureValue = routeClosure,
        lateralExpansionValue = lateralExpansion,
        tunnelRedundancyPenalty = corridorPenalty,
        newOpportunityValue = opportunity,
        nearestOwn = nearest,
        homeAdjacentReservePenalty = homeReservePenalty,
        strategicValue = base.strategicValue,
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

local function targetSpacingEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_TARGET_SPACING_ENABLED == false)
end

local function targetMinDistance(ctx)
    return math.max(1, num(ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_TARGET_MIN_DISTANCE, 2))
end

local function reachablePrimaryTarget(cell)
    return cell
        and (cell.status == "free_target" or cell.status == "next_expansion")
        and (cell.reachable == true or cell.deployable == true)
        and cell.earlyFrontierPreTargetSuppressed ~= true
end

local function spacedTopCells(cells, limit, predicate, minDistance)
    local out = {}
    local suppressed = {}
    local suppressedByKey = {}
    local selectedByKey = {}
    local considered = 0

    for _, cell in ipairs(cells or {}) do
        if not predicate or predicate(cell) then
            considered = considered + 1
            local tooClose = false
            for _, selected in ipairs(out) do
                if manhattan(cell, selected) < minDistance then
                    tooClose = true
                    break
                end
            end
            if tooClose then
                suppressed[#suppressed + 1] = cell
                suppressedByKey[cell.key or cellKey(cell)] = true
            else
                out[#out + 1] = cell
                selectedByKey[cell.key or cellKey(cell)] = true
                if #out >= limit then
                    break
                end
            end
        end
    end

    return out, {
        considered = considered,
        suppressed = suppressed,
        suppressedByKey = suppressedByKey,
        selectedByKey = selectedByKey
    }
end

local function markPrimaryTargets(cells, predicate, selectedByKey, spacingEnabled)
    if not spacingEnabled then
        return 0
    end

    local suppressed = 0
    for _, cell in ipairs(cells or {}) do
        if predicate(cell) then
            local selected = selectedByKey[cell.key or cellKey(cell)] == true
            cell.earlyPrimaryTarget = selected
            if not selected then
                suppressed = suppressed + 1
            end
        end
    end
    return suppressed
end

local function sortCellsByValue(cells)
    table.sort(cells, function(a, b)
        if num(a.value, 0) == num(b.value, 0) then
            return tostring(a.key or "") < tostring(b.key or "")
        end
        return num(a.value, 0) > num(b.value, 0)
    end)
end

local function summarizeTop(top)
    local out = {}
    for _, cell in ipairs(top or {}) do
        local reasonText = table.concat(cell.compactReasons or {}, "+")
        if cell.earlyFrontierRole then
            reasonText = reasonText ~= ""
                and (reasonText .. "+frontier_" .. tostring(cell.earlyFrontierRole))
                or ("frontier_" .. tostring(cell.earlyFrontierRole))
        end
        if cell.deadFireLane == true then
            reasonText = reasonText ~= "" and (reasonText .. "+dead_fire_lane") or "dead_fire_lane"
        elseif num(cell.fireLaneScore, 0) > 0 then
            local fireText = "fire_lane" .. tostring(math.floor(num(cell.fireLaneScore, 0)))
            reasonText = reasonText ~= "" and (reasonText .. "+" .. fireText) or fireText
        end
        out[#out + 1] = table.concat({
            tostring(cell.row) .. "," .. tostring(cell.col),
            tostring(cell.status or "unknown"),
            tostring(math.floor(num(cell.value, 0))),
            reasonText
        }, ":")
    end
    return out
end

local function countStatuses(cells)
    local counts = {
        free_target = 0,
        owned_uncovered = 0,
        owned_covered = 0,
        next_expansion = 0,
        blocked = 0,
        other = 0
    }
    for _, cell in ipairs(cells or {}) do
        local status = tostring(cell.status or "other")
        counts[status] = num(counts[status], 0) + 1
    end
    return counts
end

function M.build(ai, state, ctx, opts)
    opts = opts or {}
    if not (state and ctx and strategicInterpreter and strategicInterpreter.interpret) then
        return nil
    end

    local position = strategicInterpreter.interpret(state, ai, ctx)
    local route = buildRouteContext(ai, state, ctx)
    local occupantReplyCache = {}
    local supportHoldCache = {}
    local scored = {}
    for _, cell in ipairs((position and position.cells) or {}) do
        scored[#scored + 1] = scoreCell(ai, state, ctx, position, cell, route, occupantReplyCache, supportHoldCache)
    end
    sortCellsByValue(scored)
    local frontierPreMeta = earlyPositionFrontier.preselect(scored, ctx)
    sortCellsByValue(scored)

    local limit = math.max(1, num(opts.limit, ctx.cfg and ctx.cfg.EARLY_POSITION_MAP_TOP_N or 8))
    local spacingEnabled = targetSpacingEnabled(ctx)
    local spacingDistance = targetMinDistance(ctx)
    local primaryTargets, spacingMeta = nil, nil
    local spacingSuppressed = 0
    if spacingEnabled then
        primaryTargets, spacingMeta = spacedTopCells(scored, limit, reachablePrimaryTarget, spacingDistance)
        spacingSuppressed = markPrimaryTargets(scored, reachablePrimaryTarget, spacingMeta.selectedByKey, spacingEnabled)
    else
        primaryTargets = topCells(scored, limit, reachablePrimaryTarget)
        spacingMeta = {
            considered = #primaryTargets,
            suppressed = {},
            suppressedByKey = {},
            selectedByKey = {}
        }
    end
    local frontierMeta = earlyPositionFrontier.apply(scored, primaryTargets, ctx)
    sortCellsByValue(scored)
    sortCellsByValue(primaryTargets)

    local freeTop = primaryTargets
    local freeTargets = topCells(primaryTargets, limit, function(cell)
        return cell.status == "free_target"
    end)
    local ownedUncovered = topCells(scored, limit, function(cell)
        return cell.status == "owned_uncovered"
    end)
    local ownedUncoveredAll = topCells(scored, #scored, function(cell)
        return cell.status == "owned_uncovered"
    end)
    local ownedCovered = topCells(scored, limit, function(cell)
        return cell.status == "owned_covered"
    end)
    local ownedCoveredAll = topCells(scored, #scored, function(cell)
        return cell.status == "owned_covered"
    end)
    local nextExpansion = topCells(primaryTargets, limit, function(cell)
        return cell.status == "next_expansion"
    end)
    local allTop = topCells(scored, limit)
    local laneWidth = 0
    local centerlineCount = 0
    for _, cell in ipairs(freeTop) do
        laneWidth = math.max(laneWidth, num(cell.lateral, 0))
        if num(cell.lateral, 0) < 0.75 then
            centerlineCount = centerlineCount + 1
        end
    end

    local result = {
        kind = "early_position_map",
        version = 1,
        purpose = neutralPurposeForPlan(ctx),
        cellCount = #scored,
        cells = scored,
        top = allTop,
        freeTop = freeTop,
        freeTargets = freeTargets,
        ownedUncovered = ownedUncovered,
        ownedUncoveredAll = ownedUncoveredAll,
        ownedCovered = ownedCovered,
        ownedCoveredAll = ownedCoveredAll,
        nextExpansion = nextExpansion,
        statusCounts = countStatuses(scored),
        laneWidth = laneWidth,
        centerlineBias = #freeTop > 0 and (centerlineCount / #freeTop) or 0,
        mainRouteOwnCount = route.mainRouteOwnCount,
        mainRouteForwardOwnCount = route.mainRouteForwardOwnCount,
        mainRouteSaturation = route.mainRouteSaturation,
        source = position
    }

    if ctx.stats then
        ctx.stats.earlyPositionMapEnabled = true
        ctx.stats.earlyPositionMapPurpose = result.purpose
        ctx.stats.earlyPositionMapCellCount = result.cellCount
        ctx.stats.earlyPositionMapTopCells = summarizeTop(freeTop)
        ctx.stats.earlyPositionMapFreeTargets = summarizeTop(freeTargets)
        ctx.stats.earlyPositionMapOwnedUncovered = summarizeTop(ownedUncovered)
        ctx.stats.earlyPositionMapOwnedCovered = summarizeTop(ownedCovered)
        ctx.stats.earlyPositionMapNextExpansion = summarizeTop(nextExpansion)
        ctx.stats.earlyPositionMapStatusCounts = result.statusCounts
        ctx.stats.earlyPositionMapLaneWidth = result.laneWidth
        ctx.stats.earlyPositionMapCenterlineBias = result.centerlineBias
        ctx.stats.earlyPositionMapMainRouteOwnCount = result.mainRouteOwnCount
        ctx.stats.earlyPositionMapMainRouteForwardOwnCount = result.mainRouteForwardOwnCount
        ctx.stats.earlyPositionMapMainRouteSaturation = result.mainRouteSaturation
        ctx.stats.earlyPositionTargetSpacingEnabled = spacingEnabled
        ctx.stats.earlyPositionTargetMinDistance = spacingDistance
        ctx.stats.earlyPositionTargetSpacingConsidered = num(spacingMeta and spacingMeta.considered, 0)
        ctx.stats.earlyPositionTargetSpacingSuppressed = spacingSuppressed
        ctx.stats.earlyPositionFrontierEnabled = frontierMeta.enabled == true
        ctx.stats.earlyPositionFrontierPreTargetEnabled = frontierPreMeta.enabled == true
        ctx.stats.earlyPositionFrontierFloorProgress = frontierPreMeta.floorProgress
        ctx.stats.earlyPositionFrontierFloorOwnedCount = num(frontierPreMeta.owned, 0)
        ctx.stats.earlyPositionFrontierPreTargetSuppressed = num(frontierPreMeta.suppressed, 0)
        ctx.stats.earlyPositionFrontierPreTargetSupport = num(frontierPreMeta.support, 0)
        ctx.stats.earlyPositionFrontierPreTargetRear = num(frontierPreMeta.rear, 0)
        ctx.stats.earlyPositionFrontierProjectedEnabled =
            frontierPreMeta.projected and frontierPreMeta.projected.enabled == true or false
        ctx.stats.earlyPositionFrontierProjectedConsidered =
            num(frontierPreMeta.projected and frontierPreMeta.projected.considered, 0)
        ctx.stats.earlyPositionFrontierProjectedAnchors =
            num(frontierPreMeta.projected and frontierPreMeta.projected.anchors, 0)
        ctx.stats.earlyPositionFrontierProjectedSuppressed =
            num(frontierPreMeta.projected and frontierPreMeta.projected.suppressed, 0)
        ctx.stats.earlyPositionFrontierPrimaryCount = num(frontierMeta.primary, 0)
        ctx.stats.earlyPositionFrontierSupportCount = num(frontierMeta.support, 0)
        ctx.stats.earlyPositionFrontierHoldCount = num(frontierMeta.hold, 0)
        ctx.stats.earlyPositionFrontierRearCount = num(frontierMeta.rear, 0)
    end

    return result
end

M._private = {
    spacedTopCells = spacedTopCells,
    markPrimaryTargets = markPrimaryTargets,
    sortCellsByValue = sortCellsByValue,
    reachablePrimaryTarget = reachablePrimaryTarget,
    activeContract = activeContract,
    homeAdjacentReservePenalty = homeAdjacentReservePenalty,
    manhattan = manhattan
}

return M
