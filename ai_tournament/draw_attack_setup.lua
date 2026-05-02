local punishMap = require("ai_tournament.punish_map")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function manhattan(a, b)
    if not (a and b) then
        return nil
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function isAlive(unit)
    return unit and num(unit.currentHp, unit.startingHp or 1) > 0
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

local function isObstacle(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        local ok, result = pcall(ai.isObstacleUnit, ai, unit)
        if ok then
            return result == true
        end
    end
    return unit.player == 0 or tostring(unit.name or "") == "Rock"
end

local function pushHub(list, state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if hub then
        list[#list + 1] = {
            name = hub.name or "Commandant",
            player = playerId,
            row = hub.row,
            col = hub.col,
            currentHp = hub.currentHp,
            startingHp = hub.startingHp
        }
    end
end

local function livingUnits(ai, state, playerId, includeHub)
    local out = {}
    for _, unit in ipairs(state and state.units or {}) do
        if unit
            and num(unit.player, -999) == num(playerId, -998)
            and isAlive(unit)
            and not isObstacle(ai, unit)
            and (includeHub == true or not isHub(ai, unit)) then
            out[#out + 1] = unit
        end
    end
    if includeHub == true then
        pushHub(out, state, playerId)
    end
    return out
end

local function enemyUnits(ai, state, enemyPlayer)
    local out = livingUnits(ai, state, enemyPlayer, false)
    if #out == 0 then
        pushHub(out, state, enemyPlayer)
    end
    return out
end

local function opponentFor(ai, state, ctx, playerId)
    if ctx and ctx.enemyPlayer then
        return ctx.enemyPlayer
    end
    if ai and ai.getOpponentPlayer and playerId then
        local ok, result = pcall(ai.getOpponentPlayer, ai, playerId)
        if ok and result then
            return result
        end
    end
    if playerId == 1 then
        return 2
    elseif playerId == 2 then
        return 1
    end
    return state and state.currentPlayer == 1 and 2 or 1
end

local function sameLine(a, b)
    return a and b and (num(a.row, 0) == num(b.row, 1) or num(a.col, 0) == num(b.col, 1))
end

function M.analyze(ai, state, ctx, opts)
    if not state then
        return nil
    end
    opts = opts or {}
    local playerId = opts.playerId or (ctx and ctx.aiPlayer) or state.currentPlayer
    local enemyPlayer = opts.enemyPlayer or opponentFor(ai, state, ctx, playerId)
    if not (playerId and enemyPlayer) then
        return nil
    end

    local private = punishMap and punishMap._private or {}
    local canAttackCellFrom = private.canAttackCellFrom
    local unitAttackRange = private.unitAttackRange
    local unitMoveRange = private.unitMoveRange
    local ownUnits = livingUnits(ai, state, playerId, false)
    local targets = enemyUnits(ai, state, enemyPlayer)
    if #ownUnits == 0 or #targets == 0 then
        return nil
    end

    local result = {
        readyAttacks = 0,
        nextTurnThreats = 0,
        lineThreats = 0,
        bestGap = nil,
        bestDistance = nil,
        bestUnitName = nil,
        bestTargetName = nil
    }

    for _, unit in ipairs(ownUnits) do
        local attackRange = math.max(1, num(unitAttackRange and unitAttackRange(ai, unit), unit.atkRange or 1))
        local moveRange = math.max(0, num(unitMoveRange and unitMoveRange(ai, unit), unit.move or 1))
        for _, target in ipairs(targets) do
            local distance = manhattan(unit, target)
            if distance and distance > 0 then
                local direct = canAttackCellFrom
                    and canAttackCellFrom(ai, state, unit, unit, target)
                    or (sameLine(unit, target) and distance <= attackRange)
                local gap = math.max(0, distance - attackRange)
                if direct then
                    result.readyAttacks = result.readyAttacks + 1
                    gap = 0
                elseif sameLine(unit, target) and gap <= moveRange then
                    result.nextTurnThreats = result.nextTurnThreats + 1
                end
                if sameLine(unit, target) then
                    result.lineThreats = result.lineThreats + 1
                end
                if result.bestGap == nil or gap < result.bestGap or (gap == result.bestGap and distance < result.bestDistance) then
                    result.bestGap = gap
                    result.bestDistance = distance
                    result.bestUnitName = unit.name
                    result.bestTargetName = target.name
                end
            end
        end
    end

    return result
end

function M.compare(ai, beforeState, afterState, ctx)
    local before = M.analyze(ai, beforeState, ctx)
    local after = M.analyze(ai, afterState, ctx)
    if not (before and after) then
        return nil
    end
    local beforeGap = num(before.bestGap, 99)
    local afterGap = num(after.bestGap, 99)
    return {
        before = before,
        after = after,
        gapProgress = beforeGap - afterGap
    }
end

return M
