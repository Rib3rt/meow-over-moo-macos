local stateEngine = require("scenarioStateEngine")
local rulesKernel = require("scenarioRulesKernel")
local unitsInfo = require("unitsInfo")

local M = {
    VERSION = "scenario_red_policy.v2",
    POLICY_ID = "scenario_red_policy_v2_plan2",
    POLICY_HASH = "red_policy_v2_plan2_static_2026_05_03"
}

local BLUE = 1
local RED = 2
local INF_DISTANCE = 9999
local EPSILON_DEFAULT = 1e-6

local function toNumber(v, defaultValue)
    local n = tonumber(v)
    if n == nil then
        return defaultValue
    end
    return n
end

local function stableString(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.12g", v)
    end
    return tostring(v)
end

local function actionId(action)
    if type(action) ~= "table" then
        return "unknown"
    end
    if action.id then
        return tostring(action.id)
    end
    if action.type == "move" then
        local to = action.to or {}
        return "move:" .. stableString(action.actorId) .. ":" .. stableString(to.row) .. ":" .. stableString(to.col)
    end
    if action.type == "attack" then
        return "attack:" .. stableString(action.actorId) .. ":" .. stableString(action.targetId)
    end
    if action.type == "end_turn" then
        return "end_turn"
    end
    return stableString(action.type)
end

local function actionSortKey(action)
    local t = stableString(action and action.type or "")
    local actorId = stableString(action and action.actorId or "")
    local targetId = stableString(action and action.targetId or "")
    local to = (action and action.to) or {}
    local targetCell = (action and action.targetCell) or {}
    local row = stableString(to.row or targetCell.row or "")
    local col = stableString(to.col or targetCell.col or "")
    return table.concat({ t, actorId, targetId, row, col, actionId(action) }, "|")
end

local function deterministicSortActions(actions)
    table.sort(actions, function(a, b)
        return actionSortKey(a) < actionSortKey(b)
    end)
end

local function shallowCopyArray(arr)
    local out = {}
    if type(arr) ~= "table" then
        return out
    end
    local i
    for i = 1, #arr do
        out[i] = arr[i]
    end
    return out
end

local function sortReasons(reasons)
    table.sort(reasons, function(a, b)
        local ac = stableString(a and a.code or "")
        local bc = stableString(b and b.code or "")
        if ac ~= bc then
            return ac < bc
        end
        local aw = toNumber(a and a.weight, 0)
        local bw = toNumber(b and b.weight, 0)
        if aw ~= bw then
            return aw < bw
        end
        return stableString(a and a.detail or "") < stableString(b and b.detail or "")
    end)
end

local function buildIdSet(list)
    local out = {}
    if type(list) ~= "table" then
        return out
    end
    local i
    for i = 1, #list do
        out[stableString(list[i])] = true
    end
    local key, value
    for key, value in pairs(list) do
        if value == true then
            out[stableString(key)] = true
        end
    end
    return out
end

local function findRedCommandantId(state)
    local i
    for i = 1, #(state.units or {}) do
        local u = state.units[i]
        if toNumber(u.player, 0) == RED and u.name == "Commandant" and toNumber(u.currentHp, 0) > 0 then
            return u.id
        end
    end
    return nil
end

local findUnitById

local function unitStats(unitName)
    if type(unitsInfo) == "table" and type(unitsInfo.stats) == "table" then
        return unitsInfo.stats[unitName]
    end
    return nil
end

local function canScenarioUnitAct(unit)
    if not unit or toNumber(unit.currentHp, 0) <= 0 then
        return false
    end
    return unit.name ~= "Rock" and unit.name ~= "Commandant" and unit.name ~= "Healer"
end

local function occupiedCells(state)
    local out = {}
    local i
    for i = 1, #(state.units or {}) do
        local unit = state.units[i]
        if toNumber(unit.currentHp, 0) > 0 then
            out[tostring(unit.row) .. ":" .. tostring(unit.col)] = true
        end
    end
    return out
end

local function isOccupied(occupied, row, col)
    return occupied[tostring(row) .. ":" .. tostring(col)] == true
end

local function inBounds(row, col)
    return row >= 1 and row <= 8 and col >= 1 and col <= 8
end

local function hasFastLineOfSight(state, fromRow, fromCol, toRow, toCol, attacker)
    if fromRow ~= toRow and fromCol ~= toCol then
        return false
    end
    local ignoreBlockers = attacker and attacker.name == "Artillery"
    if ignoreBlockers then
        return true
    end
    local rowStep = (toRow == fromRow) and 0 or ((toRow > fromRow) and 1 or -1)
    local colStep = (toCol == fromCol) and 0 or ((toCol > fromCol) and 1 or -1)
    local row = fromRow + rowStep
    local col = fromCol + colStep
    local occupied = occupiedCells(state)
    while row ~= toRow or col ~= toCol do
        if isOccupied(occupied, row, col) then
            return false
        end
        row = row + rowStep
        col = col + colStep
    end
    return true
end

local function canFastAttackCommandant(state, attacker, commandant)
    if not canScenarioUnitAct(attacker) or not commandant then
        return false
    end
    local rowDiff = math.abs(toNumber(commandant.row, 0) - toNumber(attacker.row, 0))
    local colDiff = math.abs(toNumber(commandant.col, 0) - toNumber(attacker.col, 0))
    local distance = rowDiff + colDiff
    local stats = unitStats(attacker.name) or {}
    local maxRange = toNumber(stats.atkRange, 1)
    local isRanged = attacker.name == "Cloudstriker" or attacker.name == "Artillery"
    local minRange = isRanged and 2 or 1
    if distance < minRange or distance > maxRange then
        return false
    end
    if attacker.name == "Artillery" then
        return (rowDiff == 0 and colDiff > 0) or (colDiff == 0 and rowDiff > 0)
    end
    if attacker.name == "Cloudstriker" then
        return hasFastLineOfSight(state, attacker.row, attacker.col, commandant.row, commandant.col, attacker)
    end
    return true
end

local function canFastAttackTarget(state, attacker, target)
    if not canScenarioUnitAct(attacker) or not target or toNumber(target.currentHp, 0) <= 0 then
        return false
    end
    if toNumber(attacker.player, 0) == toNumber(target.player, 0) then
        return false
    end
    local rowDiff = math.abs(toNumber(target.row, 0) - toNumber(attacker.row, 0))
    local colDiff = math.abs(toNumber(target.col, 0) - toNumber(attacker.col, 0))
    local distance = rowDiff + colDiff
    local stats = unitStats(attacker.name) or {}
    local maxRange = toNumber(stats.atkRange, 1)
    local isRanged = attacker.name == "Cloudstriker" or attacker.name == "Artillery"
    local minRange = isRanged and 2 or 1
    if distance < minRange or distance > maxRange then
        return false
    end
    if attacker.name == "Artillery" then
        return (rowDiff == 0 and colDiff > 0) or (colDiff == 0 and rowDiff > 0)
    end
    if attacker.name == "Cloudstriker" then
        return hasFastLineOfSight(state, attacker.row, attacker.col, target.row, target.col, attacker)
    end
    return true
end

local function moveEnablesSameActorAttack(state, moveAction)
    if type(moveAction) ~= "table" or moveAction.type ~= "move" then
        return false
    end
    local actor = findUnitById(state, moveAction.actorId)
    if not actor then
        return false
    end
    local movedState = stateEngine.cloneState(state)
    local movedActor = findUnitById(movedState, moveAction.actorId)
    if not movedActor or not moveAction.to then
        return false
    end
    movedActor.row = toNumber(moveAction.to.row, movedActor.row)
    movedActor.col = toNumber(moveAction.to.col, movedActor.col)
    local i
    for i = 1, #(movedState.units or {}) do
        local target = movedState.units[i]
        if toNumber(target.player, 0) == BLUE and canFastAttackTarget(movedState, movedActor, target) then
            return true
        end
    end
    return false
end

local function fastMoveCells(state, unit)
    local out = {}
    if not canScenarioUnitAct(unit) then
        return out
    end
    local stats = unitStats(unit.name) or {}
    local moveRange = toNumber(stats.move, 0)
    if moveRange <= 0 then
        return out
    end
    local occupied = occupiedCells(state)
    local directions = {
        { dr = 0, dc = 1 },
        { dr = 0, dc = -1 },
        { dr = 1, dc = 0 },
        { dr = -1, dc = 0 }
    }
    local i
    for i = 1, #directions do
        local direction = directions[i]
        local dist
        for dist = 1, moveRange do
            local row = toNumber(unit.row, 0) + direction.dr * dist
            local col = toNumber(unit.col, 0) + direction.dc * dist
            if not inBounds(row, col) then
                break
            end
            local occupiedCell = isOccupied(occupied, row, col)
            if unit.fly then
                if not occupiedCell then
                    out[#out + 1] = { row = row, col = col }
                end
            else
                if occupiedCell then
                    break
                end
                out[#out + 1] = { row = row, col = col }
            end
        end
    end
    return out
end

local function resetForBlueTurn(state)
    local s = stateEngine.cloneState(stateEngine.normalize(state))
    s.currentPlayer = BLUE
    s.turnActions = 0
    s.actionsUsed = 0
    local i
    for i = 1, #(s.units or {}) do
        local u = s.units[i]
        if toNumber(u.player, 0) == BLUE then
            u.hasMoved = false
            u.hasActed = false
            u.actionsUsed = 0
            u.turnActions = {}
        end
    end
    return s
end

local function blueThreatAgainstRedCommandant(state)
    local normalized = stateEngine.normalize(state)
    local commandantId = findRedCommandantId(normalized)
    if commandantId == nil then
        return {
            hasCommandant = false,
            directAttackCount = 0,
            directDamage = 0,
            directAttackerSet = {},
            projectedAttackCount = 0,
            projectedDamage = 0,
            projectedAttackerSet = {}
        }
    end

    local blueState = resetForBlueTurn(normalized)
    local directAttackerSet = {}
    local projectedAttackerSet = {}
    local directDamageByAttacker = {}
    local projectedDamageByAttacker = {}
    local directAttackCount = 0
    local directDamage = 0
    local projectedAttackCount = 0
    local projectedDamage = 0

    local i
    for i = 1, #(blueState.units or {}) do
        local unit = blueState.units[i]
        if toNumber(unit.player, 0) == BLUE and toNumber(unit.currentHp, 0) > 0 then
            local commandant = findUnitById(blueState, commandantId)
            local canDirectAttack = canFastAttackCommandant(blueState, unit, commandant)
            if canDirectAttack then
                directAttackCount = directAttackCount + 1
                directAttackerSet[stableString(unit.id)] = true
                local damage = toNumber(unitsInfo:calculateAttackDamage(unit, commandant), 0)
                directDamageByAttacker[stableString(unit.id)] = math.max(
                    toNumber(directDamageByAttacker[stableString(unit.id)], 0),
                    damage
                )
                directDamage = directDamage + damage
            end
        end
    end

    for i = 1, #(blueState.units or {}) do
        local unit = blueState.units[i]
        if toNumber(unit.player, 0) == BLUE and toNumber(unit.currentHp, 0) > 0 then
            local moves = fastMoveCells(blueState, unit)
            local j
            for j = 1, #moves do
                local move = moves[j]
                local movedState = stateEngine.cloneState(blueState)
                local movedUnit = findUnitById(movedState, unit.id)
                if movedUnit and move then
                    movedUnit.row = toNumber(move.row, movedUnit.row)
                    movedUnit.col = toNumber(move.col, movedUnit.col)
                    movedUnit.hasMoved = true
                end
                local commandant = findUnitById(movedState, commandantId)
                local canProjectedAttack = canFastAttackCommandant(movedState, movedUnit, commandant)
                if canProjectedAttack then
                    local commandant = findUnitById(movedState, commandantId)
                    projectedAttackCount = projectedAttackCount + 1
                    projectedAttackerSet[stableString(unit.id)] = true
                    local damage = toNumber(unitsInfo:calculateAttackDamage(movedUnit, commandant), 0)
                    projectedDamageByAttacker[stableString(unit.id)] = math.max(
                        toNumber(projectedDamageByAttacker[stableString(unit.id)], 0),
                        damage
                    )
                    projectedDamage = projectedDamage + damage
                end
            end
        end
    end

    return {
        hasCommandant = true,
        directAttackCount = directAttackCount,
        directDamage = directDamage,
        directAttackerSet = directAttackerSet,
        directDamageByAttacker = directDamageByAttacker,
        projectedAttackCount = projectedAttackCount,
        projectedDamage = projectedDamage,
        projectedAttackerSet = projectedAttackerSet,
        projectedDamageByAttacker = projectedDamageByAttacker
    }
end

-- Retained for reference in tooling comparisons; runtime uses the direct per-unit threat scan above.
local function blueThreatAgainstRedCommandantExhaustive(state)
    local normalized = stateEngine.normalize(state)
    local commandantId = findRedCommandantId(normalized)
    if commandantId == nil then
        return {
            hasCommandant = false,
            directAttackCount = 0,
            directDamage = 0,
            directAttackerSet = {},
            projectedAttackCount = 0,
            projectedDamage = 0,
            projectedAttackerSet = {}
        }
    end

    local blueState = resetForBlueTurn(normalized)
    local legal = shallowCopyArray(stateEngine.getLegalActions(blueState))
    deterministicSortActions(legal)

    local directAttackerSet = {}
    local projectedAttackerSet = {}
    local directAttackCount = 0
    local directDamage = 0
    local projectedAttackCount = 0
    local projectedDamage = 0

    local i
    for i = 1, #legal do
        local a = legal[i]
        if a.type == "attack" and stableString(a.targetId) == stableString(commandantId) then
            directAttackCount = directAttackCount + 1
            directAttackerSet[stableString(a.actorId)] = true
            local _, attackResult = stateEngine.applyAction(blueState, a)
            directDamage = directDamage + toNumber(attackResult and attackResult.damage, 0)
        end
    end

    for i = 1, #legal do
        local first = legal[i]
        if first.type == "move" then
            local afterMove = stateEngine.applyAction(blueState, first)
            local legalSecond = shallowCopyArray(stateEngine.getLegalActions(afterMove))
            deterministicSortActions(legalSecond)
            local j
            for j = 1, #legalSecond do
                local second = legalSecond[j]
                if second.type == "attack" and stableString(second.targetId) == stableString(commandantId) then
                    projectedAttackCount = projectedAttackCount + 1
                    projectedAttackerSet[stableString(second.actorId)] = true
                    projectedAttackerSet[stableString(first.actorId)] = true
                    local _, projectedResult = stateEngine.applyAction(afterMove, second)
                    projectedDamage = projectedDamage + toNumber(projectedResult and projectedResult.damage, 0)
                end
            end
        end
    end

    return {
        hasCommandant = true,
        directAttackCount = directAttackCount,
        directDamage = directDamage,
        directAttackerSet = directAttackerSet,
        projectedAttackCount = projectedAttackCount,
        projectedDamage = projectedDamage,
        projectedAttackerSet = projectedAttackerSet
    }
end

local function blueHpMap(state)
    local map = {}
    local i
    for i = 1, #(state.units or {}) do
        local u = state.units[i]
        if toNumber(u.player, 0) == BLUE and toNumber(u.currentHp, 0) > 0 then
            map[stableString(u.id)] = toNumber(u.currentHp, 0)
        end
    end
    return map
end

function findUnitById(state, unitId)
    local i
    for i = 1, #(state.units or {}) do
        local unit = state.units[i]
        if stableString(unit.id) == stableString(unitId) then
            return unit
        end
    end
    return nil
end

local function findRedCommandant(state)
    local i
    for i = 1, #(state.units or {}) do
        local unit = state.units[i]
        if toNumber(unit.player, 0) == RED
            and unit.name == "Commandant"
            and toNumber(unit.currentHp, 0) > 0 then
            return unit
        end
    end
    return nil
end

local function blueCommandantDamagePriority(state, blueUnit)
    local commandant = findRedCommandant(state)
    if not commandant or not blueUnit then
        return 0
    end
    return toNumber(unitsInfo:calculateAttackDamage(blueUnit, commandant), 0)
end

local function chooseFallbackBlueTarget(state, redUnit)
    if not redUnit then
        return nil
    end
    local blues = {}
    local i
    for i = 1, #(state.units or {}) do
        local u = state.units[i]
        if toNumber(u.currentHp, 0) > 0 and toNumber(u.player, 0) == BLUE then
            blues[#blues + 1] = u
        end
    end
    table.sort(blues, function(a, b)
        local ahp = toNumber(a.currentHp, 0)
        local bhp = toNumber(b.currentHp, 0)
        if ahp ~= bhp then
            return ahp < bhp
        end
        local ad = math.abs(toNumber(redUnit.row, 0) - toNumber(a.row, 0))
            + math.abs(toNumber(redUnit.col, 0) - toNumber(a.col, 0))
        local bd = math.abs(toNumber(redUnit.row, 0) - toNumber(b.row, 0))
            + math.abs(toNumber(redUnit.col, 0) - toNumber(b.col, 0))
        if ad ~= bd then
            return ad < bd
        end
        local adamage = blueCommandantDamagePriority(state, a)
        local bdamage = blueCommandantDamagePriority(state, b)
        if adamage ~= bdamage then
            return adamage > bdamage
        end
        return stableString(a.id) < stableString(b.id)
    end)
    return blues[1]
end

local function cloneStateWithUnitAt(state, unit, row, col)
    if not unit then
        return state, nil
    end
    local movedState = stateEngine.cloneState(state)
    local movedUnit = nil
    local i
    for i = 1, #(movedState.units or {}) do
        local candidate = movedState.units[i]
        if stableString(candidate.id) == stableString(unit.id) then
            candidate.row = row
            candidate.col = col
            movedUnit = candidate
            break
        end
    end
    return movedState, movedUnit
end

local function attackPositionDistance(state, redUnit, row, col, target)
    if not redUnit or not target then
        return INF_DISTANCE
    end

    local movedState, movedUnit = cloneStateWithUnitAt(state, redUnit, row, col)
    if movedUnit and canFastAttackTarget(movedState, movedUnit, target) then
        return 0
    end

    local rowDiff = math.abs(toNumber(target.row, 0) - toNumber(row, 0))
    local colDiff = math.abs(toNumber(target.col, 0) - toNumber(col, 0))
    local distance = rowDiff + colDiff
    local stats = unitStats(redUnit.name) or {}
    local maxRange = toNumber(stats.atkRange, 1)
    local isRanged = redUnit.name == "Cloudstriker" or redUnit.name == "Artillery"
    local minRange = isRanged and 2 or 1

    if distance < minRange then
        return minRange - distance
    end
    if distance > maxRange then
        return distance - maxRange
    end

    -- In range but not a legal firing cell, usually because of line/shape rules.
    return 1
end

local function fallbackTargetDistance(state, action)
    if type(action) ~= "table" or action.type ~= "move" then
        return INF_DISTANCE
    end
    local redUnit = findUnitById(state, action.actorId)
    local target = chooseFallbackBlueTarget(state, redUnit)
    if not target then
        return INF_DISTANCE
    end
    local to = action.to or {}
    return attackPositionDistance(state, redUnit, toNumber(to.row, redUnit.row), toNumber(to.col, redUnit.col), target)
end

local function fallbackTargetBeforeDistance(state, action)
    if type(action) ~= "table" or action.type ~= "move" then
        return INF_DISTANCE
    end
    local redUnit = findUnitById(state, action.actorId)
    local target = chooseFallbackBlueTarget(state, redUnit)
    if not redUnit or not target then
        return INF_DISTANCE
    end
    return attackPositionDistance(state, redUnit, toNumber(redUnit.row, 0), toNumber(redUnit.col, 0), target)
end

local function planForm(actions)
    local a1 = actions[1]
    local a2 = actions[2]
    if #actions == 0 then
        return "empty"
    end
    if #actions == 1 then
        if a1.type == "attack" then
            return "attack"
        end
        if a1.type == "move" then
            return "move"
        end
        if a1.type == "end_turn" then
            return "end_turn"
        end
        return "single_other"
    end
    if a1.type == "move" and a2.type == "attack" and stableString(a1.actorId) == stableString(a2.actorId) then
        return "move_attack_same_unit"
    end
    if a1.type == "attack" and a2.type == "attack" then
        return "attack_attack"
    end
    if a1.type == "move" and a2.type == "move" then
        return "move_move"
    end
    return "mixed_two_action"
end

local function planKey(actions)
    local parts = {}
    local i
    for i = 1, #actions do
        parts[#parts + 1] = actionSortKey(actions[i])
    end
    return table.concat(parts, "->")
end

local function collectKilledBlueIds(beforeHp, afterHp)
    local out = {}
    local id, hpBefore
    for id, hpBefore in pairs(beforeHp) do
        local hpAfter = toNumber(afterHp[id], 0)
        if hpBefore > 0 and hpAfter <= 0 then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

local function countIdsInSet(ids, set)
    local total = 0
    local i
    for i = 1, #ids do
        if set[stableString(ids[i])] == true then
            total = total + 1
        end
    end
    return total
end

local function attackTargetIds(actions)
    local out = {}
    local i
    for i = 1, #(actions or {}) do
        local action = actions[i]
        if action and action.type == "attack" and action.targetId ~= nil then
            out[#out + 1] = stableString(action.targetId)
        end
    end
    return out
end

local function maxThreatDamageForTargets(targetIds, damageByAttacker)
    local maxDamage = 0
    local i
    for i = 1, #(targetIds or {}) do
        maxDamage = math.max(maxDamage, toNumber(damageByAttacker and damageByAttacker[stableString(targetIds[i])], 0))
    end
    return maxDamage
end

local function cachedBlueThreatAgainstRedCommandant(state, cache)
    if type(cache) ~= "table" then
        return blueThreatAgainstRedCommandant(state)
    end
    local key = stateEngine.stateHash(state)
    if cache[key] == nil then
        cache[key] = blueThreatAgainstRedCommandant(state)
    end
    return cache[key]
end

local function enumeratePlans(state, maxDepth)
    local out = {}
    local function walk(cursor, depth, actions, states)
        if #actions > 0 then
            out[#out + 1] = {
                actions = shallowCopyArray(actions),
                states = shallowCopyArray(states),
                finalState = cursor
            }
        end
        if depth <= 0 or toNumber(cursor.currentPlayer, BLUE) ~= RED then
            return
        end
        local legal = shallowCopyArray(stateEngine.getLegalActions(cursor))
        deterministicSortActions(legal)
        local realLegal = {}
        local i
        for i = 1, #legal do
            if legal[i].type ~= "end_turn" then
                realLegal[#realLegal + 1] = legal[i]
            end
        end
        if #realLegal > 0 then
            legal = realLegal
        end
        for i = 1, #legal do
            local action = legal[i]
            local nextState = stateEngine.applyAction(cursor, action)
            actions[#actions + 1] = action
            states[#states + 1] = nextState
            walk(nextState, depth - 1, actions, states)
            states[#states] = nil
            actions[#actions] = nil
        end
    end
    walk(state, maxDepth, {}, {})
    return out
end

local function addPlan(out, actions, states, finalState)
    if #actions <= 0 then
        return
    end
    out[#out + 1] = {
        actions = shallowCopyArray(actions),
        states = shallowCopyArray(states),
        finalState = finalState
    }
end

local function chooseBestFallbackMove(state, legalMoves)
    local best = nil
    local bestBefore = INF_DISTANCE
    local bestAfter = INF_DISTANCE
    local i
    for i = 1, #legalMoves do
        local action = legalMoves[i]
        local before = fallbackTargetBeforeDistance(state, action)
        local after = fallbackTargetDistance(state, action)
        if best == nil
            or after < bestAfter
            or (after == bestAfter and before < bestBefore)
            or (after == bestAfter and before == bestBefore and actionSortKey(action) < actionSortKey(best)) then
            best = action
            bestBefore = before
            bestAfter = after
        end
    end
    return best
end

local function enumerateFocusedPlans(state, maxDepth)
    if maxDepth >= 2 and type(M) == "table" and M.USE_EXHAUSTIVE_PLAN_ENUMERATION == true then
        return enumeratePlans(state, maxDepth)
    end

    local out = {}
    local legal = shallowCopyArray(stateEngine.getLegalActions(state))
    deterministicSortActions(legal)

    local realLegal = {}
    local i
    for i = 1, #legal do
        if legal[i].type ~= "end_turn" then
            realLegal[#realLegal + 1] = legal[i]
        end
    end
    if #realLegal == 0 then
        legal = legal
    else
        legal = realLegal
    end

    local allowedFirstActionIds = {}
    local bestInitialFallbackMove = nil
    local initialMoves = {}
    for i = 1, #legal do
        if legal[i].type == "attack" then
            allowedFirstActionIds[actionId(legal[i])] = true
        elseif legal[i].type == "move" then
            initialMoves[#initialMoves + 1] = legal[i]
        elseif legal[i].type == "end_turn" then
            allowedFirstActionIds[actionId(legal[i])] = true
        end
    end
    bestInitialFallbackMove = chooseBestFallbackMove(state, initialMoves)
    if bestInitialFallbackMove then
        allowedFirstActionIds[actionId(bestInitialFallbackMove)] = true
    end

    if maxDepth >= 2 then
        for i = 1, #initialMoves do
            local first = initialMoves[i]
            if moveEnablesSameActorAttack(state, first) then
                allowedFirstActionIds[actionId(first)] = true
            end
        end
    end

    for i = 1, #legal do
        local first = legal[i]
        if allowedFirstActionIds[actionId(first)] ~= true then
            goto continue_first_action
        end
        local firstState = stateEngine.applyAction(state, first)
        local actions = { first }
        local states = { firstState }
        addPlan(out, actions, states, firstState)

        if maxDepth >= 2
            and first.type ~= "end_turn"
            and toNumber(firstState.currentPlayer, BLUE) == RED
            and toNumber(firstState.turnActions, 0) < toNumber(firstState.maxActionsPerTurn, 2) then
            local secondLegal = shallowCopyArray(stateEngine.getLegalActions(firstState))
            deterministicSortActions(secondLegal)

            local secondAttacks = {}
            local secondMoves = {}
            local j
            for j = 1, #secondLegal do
                local second = secondLegal[j]
                if second.type == "attack"
                    and (
                        first.type ~= "move"
                        or stableString(second.actorId) == stableString(first.actorId)
                    ) then
                    secondAttacks[#secondAttacks + 1] = second
                elseif second.type == "move" then
                    secondMoves[#secondMoves + 1] = second
                end
            end

            for j = 1, #secondAttacks do
                local second = secondAttacks[j]
                local nextState = stateEngine.applyAction(firstState, second)
                addPlan(out, { first, second }, { firstState, nextState }, nextState)
            end

            if first.type == "move" then
                local sameActorFallback = chooseBestFallbackMove(firstState, secondMoves)
                if sameActorFallback and stableString(sameActorFallback.actorId) == stableString(first.actorId) then
                    local nextState = stateEngine.applyAction(firstState, sameActorFallback)
                    addPlan(out, { first, sameActorFallback }, { firstState, nextState }, nextState)
                end
            elseif #secondAttacks == 0 then
                local fallbackMove = chooseBestFallbackMove(firstState, secondMoves)
                if fallbackMove then
                    local nextState = stateEngine.applyAction(firstState, fallbackMove)
                    addPlan(out, { first, fallbackMove }, { firstState, nextState }, nextState)
                end
            end
        end
        ::continue_first_action::
    end

    return out
end

local function evaluatePlan(initialState, plan, opts, baselineThreat)
    opts = type(opts) == "table" and opts or {}
    local actions = plan.actions or {}
    local finalState = plan.finalState or initialState
    local firstState = (plan.states and plan.states[1]) or finalState
    local firstAction = actions[1]
    local actionType = firstAction and firstAction.type or "end_turn"
    local criticalBlueSet = buildIdSet(opts.criticalBlueUnitIds)

    local hpBefore = blueHpMap(initialState)
    local hpAfter = blueHpMap(finalState)
    local hpAfterFirst = blueHpMap(firstState)
    local killedBlueIds = collectKilledBlueIds(hpBefore, hpAfter)
    local killedBlueIdsFirst = collectKilledBlueIds(hpBefore, hpAfterFirst)
    local damageToBlue = 0
    local id, hp
    for id, hp in pairs(hpBefore) do
        local hpAfterId = toNumber(hpAfter[id], 0)
        if hpAfterId < hp then
            damageToBlue = damageToBlue + (hp - hpAfterId)
        end
    end

    local threatCache = opts.__threatCache
    local beforeThreat = baselineThreat or cachedBlueThreatAgainstRedCommandant(initialState, threatCache)
    local attackedTargetIds = attackTargetIds(actions)
    local attackedDirectThreat = countIdsInSet(attackedTargetIds, beforeThreat.directAttackerSet or {})
    local attackedProjectedThreat = countIdsInSet(attackedTargetIds, beforeThreat.projectedAttackerSet or {})
    local directThreatReduction = attackedDirectThreat
    local projectedThreatReduction = attackedProjectedThreat
    local directDamageReduction = maxThreatDamageForTargets(attackedTargetIds, beforeThreat.directDamageByAttacker or {})
    local projectedDamageReduction = maxThreatDamageForTargets(attackedTargetIds, beforeThreat.projectedDamageByAttacker or {})
    local killedDirectThreat = countIdsInSet(killedBlueIds, beforeThreat.directAttackerSet or {})
    local killedProjectedThreat = countIdsInSet(killedBlueIds, beforeThreat.projectedAttackerSet or {})

    local criticalTargeted = false
    if firstAction and firstAction.type == "attack" and criticalBlueSet[stableString(firstAction.targetId)] then
        criticalTargeted = true
    end

    local distanceBefore = fallbackTargetBeforeDistance(initialState, firstAction)
    local distanceAfterFirst = fallbackTargetDistance(initialState, firstAction)
    local distanceAfterPlan = distanceAfterFirst
    local fallbackAdvance = math.max(0, distanceBefore - distanceAfterFirst)

    local rank = {
        killAny = (#killedBlueIds > 0) and 1 or 0,
        killNow = (#killedBlueIdsFirst > 0) and 1 or 0,
        killCount = #killedBlueIds,
        directPriority = (killedDirectThreat * 1000) + (directDamageReduction * 100) + (directThreatReduction * 10),
        projectedPriority = (killedProjectedThreat * 1000) + (projectedDamageReduction * 100) + (projectedThreatReduction * 10),
        damageToBlue = damageToBlue,
        fallbackAdvance = fallbackAdvance,
        avoidEndTurn = (actionType ~= "end_turn") and 1 or 0,
        firstActionTypePriority = (actionType == "attack") and 2 or ((actionType == "move") and 1 or 0),
        criticalBoost = criticalTargeted and 1 or 0
    }

    local score = 0
    score = score + rank.killAny * 100000000
    score = score + rank.killNow * 10000000
    score = score + rank.killCount * 1000000
    score = score + rank.directPriority * 10000
    score = score + rank.projectedPriority * 100
    score = score + rank.damageToBlue
    score = score + rank.firstActionTypePriority * 0.1
    score = score + rank.fallbackAdvance * 0.01
    score = score + rank.avoidEndTurn * 0.001
    score = score + rank.criticalBoost * 0.0001

    local reasons = {}
    if rank.killAny > 0 then
        reasons[#reasons + 1] = { code = "kill_blue", weight = rank.killCount, detail = killedBlueIds }
    end
    if rank.killNow > 0 then
        reasons[#reasons + 1] = { code = "kill_blue_immediate", weight = rank.killNow, detail = killedBlueIdsFirst }
    end
    if rank.directPriority > 0 then
        reasons[#reasons + 1] = {
            code = "target_direct_commandant_threat",
            weight = rank.directPriority,
            detail = {
                killedThreats = killedDirectThreat,
                threatReduction = directThreatReduction,
                damageReduction = directDamageReduction
            }
        }
    end
    if rank.projectedPriority > 0 then
        reasons[#reasons + 1] = {
            code = "target_projected_commandant_threat",
            weight = rank.projectedPriority,
            detail = {
                killedThreats = killedProjectedThreat,
                threatReduction = projectedThreatReduction,
                damageReduction = projectedDamageReduction
            }
        }
    end
    if rank.damageToBlue > 0 then
        reasons[#reasons + 1] = { code = "damage_to_blue", weight = rank.damageToBlue }
    end
    if rank.fallbackAdvance > 0 then
        reasons[#reasons + 1] = { code = "fallback_toward_nearest_blue", weight = rank.fallbackAdvance }
    end
    if criticalTargeted then
        reasons[#reasons + 1] = { code = "attack_critical_blue", weight = 1, detail = stableString(firstAction.targetId) }
    end
    if actionType == "end_turn" then
        reasons[#reasons + 1] = { code = "end_turn_penalty", weight = -1 }
    end

    sortReasons(reasons)
    local features = {
        actionId = actionId(firstAction),
        actionType = actionType,
        tacticalClass = planForm(actions),
        planLength = #actions,
        planForm = planForm(actions),
        planKey = planKey(actions),
        killAny = rank.killAny == 1,
        killNow = rank.killNow == 1,
        killCount = rank.killCount,
        killedBlueIds = killedBlueIds,
        directThreatReduction = directThreatReduction,
        projectedThreatReduction = projectedThreatReduction,
        directDamageReduction = directDamageReduction,
        projectedDamageReduction = projectedDamageReduction,
        damageToBlue = damageToBlue,
        fallbackAdvance = fallbackAdvance,
        distanceBefore = distanceBefore,
        distanceAfterPlan = distanceAfterPlan,
        distanceAfterFirst = distanceAfterFirst,
        hasMeaningfulImpact = (
            rank.killAny > 0
            or rank.directPriority > 0
            or rank.projectedPriority > 0
            or rank.damageToBlue > 0
            or rank.fallbackAdvance > 0
        )
    }

    return {
        score = score,
        reasons = reasons,
        features = features,
        rank = rank
    }
end

local function compareRank(a, b)
    if a.rank.killAny ~= b.rank.killAny then
        return a.rank.killAny > b.rank.killAny
    end
    if a.rank.killNow ~= b.rank.killNow then
        return a.rank.killNow > b.rank.killNow
    end
    if a.rank.killCount ~= b.rank.killCount then
        return a.rank.killCount > b.rank.killCount
    end
    if a.rank.directPriority ~= b.rank.directPriority then
        return a.rank.directPriority > b.rank.directPriority
    end
    if a.rank.projectedPriority ~= b.rank.projectedPriority then
        return a.rank.projectedPriority > b.rank.projectedPriority
    end
    if a.rank.damageToBlue ~= b.rank.damageToBlue then
        return a.rank.damageToBlue > b.rank.damageToBlue
    end
    if a.rank.fallbackAdvance ~= b.rank.fallbackAdvance then
        return a.rank.fallbackAdvance > b.rank.fallbackAdvance
    end
    if a.rank.firstActionTypePriority ~= b.rank.firstActionTypePriority then
        return a.rank.firstActionTypePriority > b.rank.firstActionTypePriority
    end
    if a.rank.avoidEndTurn ~= b.rank.avoidEndTurn then
        return a.rank.avoidEndTurn > b.rank.avoidEndTurn
    end
    if a.rank.criticalBoost ~= b.rank.criticalBoost then
        return a.rank.criticalBoost > b.rank.criticalBoost
    end
    return a.planKey < b.planKey
end

local function fallbackNoopAction(legalActions)
    local i
    for i = 1, #legalActions do
        if legalActions[i].type == "end_turn" then
            return legalActions[i]
        end
    end
    return legalActions[1] or { type = "end_turn", id = "end_turn" }
end

local function evaluateSingleAction(state, action, opts)
    local nextState = stateEngine.applyAction(state, action)
    local baselineThreat = blueThreatAgainstRedCommandant(state)
    local plan = {
        actions = { action },
        states = { nextState },
        finalState = nextState
    }
    return evaluatePlan(state, plan, opts, baselineThreat)
end

function M.isScenarioOnly()
    return true
end

function M.scoreAction(state, action, opts)
    local normalized = stateEngine.normalize(state)
    opts = type(opts) == "table" and opts or {}
    local scored = evaluateSingleAction(normalized, action, opts)
    return {
        score = scored.score,
        reasons = scored.reasons,
        features = scored.features,
        policyVersion = M.VERSION
    }
end

function M.chooseAction(state, opts)
    opts = type(opts) == "table" and opts or {}
    local normalized = stateEngine.normalize(state)
    local currentPlayer = toNumber(normalized.currentPlayer, BLUE)
    local legalActions = shallowCopyArray(stateEngine.getLegalActions(normalized))
    deterministicSortActions(legalActions)
    local stateHash = stateEngine.stateHash(normalized)

    if currentPlayer ~= RED then
        local fallback = fallbackNoopAction(legalActions)
        local record = {
            policyVersion = M.VERSION,
            policyHash = M.POLICY_HASH,
            stateHash = stateHash,
            seed = opts.seed,
            candidateCount = 1,
            planCandidateCount = 1,
            scoredActions = {
                {
                    actionId = actionId(fallback),
                    action = fallback,
                    score = 0,
                    reasons = { { code = "non_red_noop", weight = 0 } },
                    features = {
                        actionId = actionId(fallback),
                        actionType = fallback.type,
                        tacticalClass = "end_turn",
                        hasMeaningfulImpact = false
                    }
                }
            },
            tieBreak = "deterministic_plan_key",
            selectedActionId = actionId(fallback),
            selectedPlan = { actions = { fallback }, planForm = "end_turn", planKey = actionSortKey(fallback) },
            forbiddenInputsChecked = true
        }
        return fallback, record
    end

    local remainingActions = math.max(0, toNumber(normalized.maxActionsPerTurn, 2) - toNumber(normalized.turnActions, 0))
    local depth = math.min(2, remainingActions)
    if depth <= 0 then
        local forcedEnd = fallbackNoopAction(legalActions)
        return forcedEnd, {
            policyVersion = M.VERSION,
            policyHash = M.POLICY_HASH,
            stateHash = stateHash,
            seed = opts.seed,
            candidateCount = #legalActions,
            planCandidateCount = 1,
            scoredActions = {},
            tieBreak = "deterministic_plan_key",
            selectedActionId = actionId(forcedEnd),
            selectedPlan = { actions = { forcedEnd }, planForm = "end_turn", planKey = actionSortKey(forcedEnd) },
            forbiddenInputsChecked = true
        }
    end

    local threatCache = {}
    opts.__threatCache = threatCache
    local baselineThreat = cachedBlueThreatAgainstRedCommandant(normalized, threatCache)
    local planCandidates = enumerateFocusedPlans(normalized, depth)
    local scoredPlans = {}
    local i
    for i = 1, #planCandidates do
        local plan = planCandidates[i]
        local planEval = evaluatePlan(normalized, plan, opts, baselineThreat)
        scoredPlans[#scoredPlans + 1] = {
            actions = plan.actions,
            planKey = planEval.features.planKey,
            planForm = planEval.features.planForm,
            score = planEval.score,
            reasons = planEval.reasons,
            features = planEval.features,
            rank = planEval.rank
        }
    end

    table.sort(scoredPlans, compareRank)
    local selectedPlan = scoredPlans[1]
    local selectedAction = selectedPlan and selectedPlan.actions[1] or fallbackNoopAction(legalActions)

    local bestByFirstAction = {}
    local order = {}
    for i = 1, #scoredPlans do
        local plan = scoredPlans[i]
        local first = plan.actions[1]
        local key = actionId(first)
        local existing = bestByFirstAction[key]
        if existing == nil or compareRank(plan, existing) then
            bestByFirstAction[key] = plan
        end
        if existing == nil then
            order[#order + 1] = key
        end
    end

    local scoredActions = {}
    for i = 1, #order do
        local entry = bestByFirstAction[order[i]]
        scoredActions[#scoredActions + 1] = {
            actionId = actionId(entry.actions[1]),
            action = entry.actions[1],
            score = entry.score,
            reasons = entry.reasons,
            features = entry.features
        }
    end
    table.sort(scoredActions, function(a, b)
        if math.abs(a.score - b.score) > EPSILON_DEFAULT then
            return a.score > b.score
        end
        return actionSortKey(a.action) < actionSortKey(b.action)
    end)

    local record = {
        policyVersion = M.VERSION,
        policyHash = M.POLICY_HASH,
        stateHash = stateHash,
        seed = opts.seed,
        candidateCount = #legalActions,
        planCandidateCount = #scoredPlans,
        scoredActions = scoredActions,
        tieBreak = "deterministic_plan_key",
        selectedActionId = actionId(selectedAction),
        selectedPlan = {
            actions = selectedPlan and selectedPlan.actions or { selectedAction },
            planForm = selectedPlan and selectedPlan.planForm or "single_other",
            planKey = selectedPlan and selectedPlan.planKey or actionSortKey(selectedAction),
            rank = selectedPlan and selectedPlan.rank or nil,
            score = selectedPlan and selectedPlan.score or nil
        },
        forbiddenInputsChecked = true
    }
    return selectedAction, record
end

function M.getEquivalentActions(state, selectedAction, opts)
    opts = type(opts) == "table" and opts or {}
    local epsilon = toNumber(opts.epsilon, EPSILON_DEFAULT)
    local normalized = stateEngine.normalize(state)
    local remainingActions = math.max(0, toNumber(normalized.maxActionsPerTurn, 2) - toNumber(normalized.turnActions, 0))
    local depth = math.min(2, remainingActions)
    if depth <= 0 then
        return {}
    end

    local threatCache = {}
    opts.__threatCache = threatCache
    local baselineThreat = cachedBlueThreatAgainstRedCommandant(normalized, threatCache)
    local plans = enumerateFocusedPlans(normalized, depth)
    local bestPerAction = {}
    local i
    for i = 1, #plans do
        local plan = plans[i]
        local eval = evaluatePlan(normalized, plan, opts, baselineThreat)
        local first = plan.actions[1]
        local key = actionId(first)
        local candidate = {
            action = first,
            score = eval.score,
            rank = eval.rank,
            planKey = eval.features.planKey
        }
        if bestPerAction[key] == nil or compareRank(candidate, bestPerAction[key]) then
            bestPerAction[key] = candidate
        end
    end

    local selectedKey = actionId(selectedAction)
    local selectedBest = bestPerAction[selectedKey]
    if selectedBest == nil then
        return {}
    end

    local out = {}
    local key, candidate
    for key, candidate in pairs(bestPerAction) do
        local _ = key
        if math.abs(candidate.score - selectedBest.score) <= epsilon then
            out[#out + 1] = candidate.action
        end
    end
    deterministicSortActions(out)
    return out
end

return M
