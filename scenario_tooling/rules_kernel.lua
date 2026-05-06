local unitsInfo = require("unitsInfo")

local M = {
    VERSION = "scenario_rules_kernel.v0.1.0-step1"
}

local BOARD_SIZE = 8
local BLUE = 1
local RED = 2
local NEUTRAL = 0

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    local k, v
    for k, v in pairs(value) do
        out[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return out
end

local function normalizePlayer(player)
    if player == "blue" or player == "Blue" then
        return BLUE
    end
    if player == "red" or player == "Red" then
        return RED
    end
    if player == "neutral" or player == "Neutral" then
        return NEUTRAL
    end
    local n = tonumber(player)
    if n == BLUE or n == RED or n == NEUTRAL then
        return n
    end
    return BLUE
end

local function unitStats(name)
    if type(unitsInfo) == "table" and type(unitsInfo.stats) == "table" then
        return unitsInfo.stats[name]
    end
    return nil
end

local function normalizeUnit(unit, index)
    local out = deepCopy(unit or {})
    local stats = unitStats(out.name) or {}
    out.id = out.id or index
    out.name = tostring(out.name or "Unknown")
    out.player = normalizePlayer(out.player)
    out.row = math.max(1, math.min(BOARD_SIZE, tonumber(out.row) or 1))
    out.col = math.max(1, math.min(BOARD_SIZE, tonumber(out.col) or 1))
    out.startingHp = tonumber(out.startingHp) or tonumber(stats.startingHp) or tonumber(stats.hp) or 1
    out.currentHp = tonumber(out.currentHp) or tonumber(out.hp) or out.startingHp
    if out.currentHp > out.startingHp then
        out.currentHp = out.startingHp
    end
    if out.currentHp < 0 then
        out.currentHp = 0
    end
    out.hp = nil
    out.fly = out.fly == true or stats.fly == true
    out.hasMoved = out.hasMoved == true
    out.hasActed = out.hasActed == true
    return out
end

local function findUnitIndex(state, unitIdOrIndex)
    if type(unitIdOrIndex) == "number" then
        if state.units[unitIdOrIndex] then
            return unitIdOrIndex
        end
    end
    local i
    for i = 1, #state.units do
        if state.units[i].id == unitIdOrIndex then
            return i
        end
    end
    return nil
end

local function canActInScenarioStep1(unit)
    if not unit then
        return false
    end
    if unit.name == "Rock" or unit.name == "Commandant" or unit.name == "Healer" then
        return false
    end
    return true
end

local function isMeleeAttacker(unit)
    if not unit then
        return false
    end
    if unit.name == "Cloudstriker" or unit.name == "Artillery" then
        return false
    end
    local stats = unitStats(unit.name) or {}
    return (tonumber(stats.atkRange) or 1) <= 1
end

local function inBounds(row, col)
    return row >= 1 and row <= BOARD_SIZE and col >= 1 and col <= BOARD_SIZE
end

function M.isScenarioOnly()
    return true
end

function M.cloneState(state)
    return deepCopy(state)
end

function M.normalizeState(state)
    local input = type(state) == "table" and state or {}
    local out = deepCopy(input)
    out.board = type(out.board) == "table" and out.board or {}
    out.board.rows = BOARD_SIZE
    out.board.cols = BOARD_SIZE
    out.currentPlayer = normalizePlayer(out.currentPlayer)
    out.scenarioTurn = tonumber(out.scenarioTurn) or 1
    out.turnLimit = tonumber(out.turnLimit) or 10
    out.objectiveType = out.objectiveType or "destroy_red_commandant_within_turn_limit"
    out.supplyEnabled = out.supplyEnabled == true
    out.turnActions = tonumber(out.turnActions) or 0
    out.actionsUsed = tonumber(out.actionsUsed) or 0
    out.maxActionsPerTurn = math.max(1, math.floor(tonumber(out.maxActionsPerTurn) or 2))

    local unitsIn = type(out.units) == "table" and out.units or {}
    local unitsOut = {}
    local i
    for i = 1, #unitsIn do
        unitsOut[#unitsOut + 1] = normalizeUnit(unitsIn[i], i)
    end
    out.units = unitsOut
    return out
end

function M.findUnitIndexAt(state, row, col)
    local s = M.normalizeState(state)
    local i
    for i = 1, #s.units do
        local u = s.units[i]
        if u.row == row and u.col == col and u.currentHp > 0 then
            return i
        end
    end
    return nil
end

function M.getUnitAt(state, row, col)
    local s = M.normalizeState(state)
    local idx = M.findUnitIndexAt(s, row, col)
    if not idx then
        return nil
    end
    return s.units[idx]
end

function M.getUnitById(state, unitId)
    local s = M.normalizeState(state)
    local idx = findUnitIndex(s, unitId)
    if not idx then
        return nil
    end
    return s.units[idx]
end

function M.getLinePath(fromCell, toCell)
    if type(fromCell) ~= "table" or type(toCell) ~= "table" then
        return {}
    end
    local fromRow = tonumber(fromCell.row)
    local fromCol = tonumber(fromCell.col)
    local toRow = tonumber(toCell.row)
    local toCol = tonumber(toCell.col)
    if not fromRow or not fromCol or not toRow or not toCol then
        return {}
    end
    if fromRow ~= toRow and fromCol ~= toCol then
        return {}
    end

    local path = {}
    if fromRow == toRow and fromCol == toCol then
        path[1] = { row = fromRow, col = fromCol }
        return path
    end

    if fromRow == toRow then
        local step = (toCol > fromCol) and 1 or -1
        local c
        for c = fromCol, toCol, step do
            path[#path + 1] = { row = fromRow, col = c }
        end
        return path
    end

    local step = (toRow > fromRow) and 1 or -1
    local r
    for r = fromRow, toRow, step do
        path[#path + 1] = { row = r, col = fromCol }
    end
    return path
end

function M.hasLineOfSight(state, fromCell, toCell, attacker)
    local path = M.getLinePath(fromCell, toCell)
    if #path == 0 then
        return false
    end
    if #path <= 2 then
        return true
    end

    local ignoreBlockers = attacker and attacker.name == "Artillery"
    local i
    for i = 2, #path - 1 do
        local p = path[i]
        if not ignoreBlockers and M.findUnitIndexAt(state, p.row, p.col) then
            return false
        end
    end
    return true
end

function M.getLegalMoves(state, unitIdOrIndex)
    local s = M.normalizeState(state)
    if (tonumber(s.turnActions) or 0) >= (tonumber(s.maxActionsPerTurn) or 2) then
        return {}
    end
    local idx = findUnitIndex(s, unitIdOrIndex)
    if not idx then
        return {}
    end
    local unit = s.units[idx]
    if unit.player ~= s.currentPlayer or unit.hasActed or unit.hasMoved or not canActInScenarioStep1(unit) then
        return {}
    end

    local stats = unitStats(unit.name) or {}
    local moveRange = tonumber(stats.move) or 0
    if moveRange <= 0 then
        return {}
    end

    local out = {}
    local directions = {
        { dr = 0, dc = 1 },
        { dr = 0, dc = -1 },
        { dr = 1, dc = 0 },
        { dr = -1, dc = 0 }
    }
    local _, dir
    for _, dir in ipairs(directions) do
        local dist
        for dist = 1, moveRange do
            local r = unit.row + dir.dr * dist
            local c = unit.col + dir.dc * dist
            if not inBounds(r, c) then
                break
            end
            local occupied = M.findUnitIndexAt(s, r, c) ~= nil
            if unit.fly then
                if not occupied then
                    out[#out + 1] = {
                        type = "move",
                        actorId = unit.id,
                        actorIndex = idx,
                        from = { row = unit.row, col = unit.col },
                        to = { row = r, col = c },
                        legal = true
                    }
                end
            else
                if occupied then
                    break
                end
                out[#out + 1] = {
                    type = "move",
                    actorId = unit.id,
                    actorIndex = idx,
                    from = { row = unit.row, col = unit.col },
                    to = { row = r, col = c },
                    legal = true
                }
            end
        end
    end
    return out
end

function M.isLegalAttack(state, attackerIdOrIndex, targetIdOrIndex)
    local s = M.normalizeState(state)
    local ai = findUnitIndex(s, attackerIdOrIndex)
    local ti = findUnitIndex(s, targetIdOrIndex)
    if not ai or not ti then
        return false, "unit_not_found"
    end

    local attacker = s.units[ai]
    local target = s.units[ti]
    if attacker.player ~= s.currentPlayer then
        return false, "wrong_player"
    end
    if attacker.hasActed or not canActInScenarioStep1(attacker) then
        return false, "attacker_unavailable"
    end
    if target.currentHp <= 0 then
        return false, "target_dead"
    end
    if target.player == attacker.player then
        return false, "friendly_target"
    end

    local rowDiff = math.abs(target.row - attacker.row)
    local colDiff = math.abs(target.col - attacker.col)
    local distance = rowDiff + colDiff
    local stats = unitStats(attacker.name) or {}
    local maxRange = tonumber(stats.atkRange) or 1
    local isCloudstriker = attacker.name == "Cloudstriker"
    local isArtillery = attacker.name == "Artillery"
    local minRange = (isCloudstriker or isArtillery) and 2 or 1

    if distance < minRange or distance > maxRange then
        return false, "out_of_range"
    end
    if isArtillery then
        if not ((rowDiff == 0 and colDiff > 0) or (colDiff == 0 and rowDiff > 0)) then
            return false, "artillery_orthogonal_only"
        end
        return true
    end
    if isCloudstriker then
        if not M.hasLineOfSight(s, { row = attacker.row, col = attacker.col }, { row = target.row, col = target.col }, attacker) then
            return false, "blocked_line_of_sight"
        end
        return true
    end
    return true
end

function M.getLegalAttacks(state, unitIdOrIndex)
    local s = M.normalizeState(state)
    if (tonumber(s.turnActions) or 0) >= (tonumber(s.maxActionsPerTurn) or 2) then
        return {}
    end
    local ai = findUnitIndex(s, unitIdOrIndex)
    if not ai then
        return {}
    end
    local out = {}
    local i
    for i = 1, #s.units do
        if i ~= ai then
            local ok = M.isLegalAttack(s, ai, i)
            if ok then
                out[#out + 1] = {
                    type = "attack",
                    actorId = s.units[ai].id,
                    actorIndex = ai,
                    targetId = s.units[i].id,
                    targetIndex = i,
                    from = { row = s.units[ai].row, col = s.units[ai].col },
                    targetCell = { row = s.units[i].row, col = s.units[i].col },
                    legal = true
                }
            end
        end
    end
    return out
end

function M.nextTurn(state)
    local s = M.normalizeState(state)
    local nextPlayer = (s.currentPlayer == BLUE) and RED or BLUE
    s.currentPlayer = nextPlayer
    if nextPlayer == BLUE then
        s.scenarioTurn = (tonumber(s.scenarioTurn) or 1) + 1
    end
    s.turnActions = 0
    local i
    for i = 1, #s.units do
        local u = s.units[i]
        if u.player == nextPlayer then
            u.hasMoved = false
            u.hasActed = false
            u.turnActions = {}
            u.actionsUsed = 0
        end
    end
    return s
end

function M.evaluateOutcome(state)
    local s = M.normalizeState(state)
    local blueAlive = false
    local redCommandantAlive = false
    local i
    for i = 1, #s.units do
        local u = s.units[i]
        if u.currentHp > 0 then
            if u.player == BLUE then
                blueAlive = true
            end
            if u.player == RED and u.name == "Commandant" then
                redCommandantAlive = true
            end
        end
    end

    if not redCommandantAlive then
        return { status = "blue_win", reason = "red_commandant_destroyed" }
    end
    if not blueAlive then
        return { status = "blue_loss", reason = "blue_units_eliminated" }
    end
    if s.currentPlayer == BLUE and (tonumber(s.scenarioTurn) or 1) > (tonumber(s.turnLimit) or 10) then
        return { status = "blue_loss", reason = "turn_limit_exceeded" }
    end
    return { status = "ongoing", reason = "none" }
end

function M.applyAction(state, action)
    local s = M.normalizeState(state)
    if type(action) ~= "table" then
        return s, { ok = false, code = "invalid_action", reason = "action_must_be_table" }
    end

    local actionType = action.type
    if actionType == "end_turn" then
        local ns = M.nextTurn(s)
        return ns, { ok = true, code = "ok", type = "end_turn", outcome = M.evaluateOutcome(ns) }
    end

    local actorIdx = findUnitIndex(s, action.actorId or action.unitId or action.unitIndex)
    if not actorIdx then
        return s, { ok = false, code = "actor_not_found", reason = "actor_missing" }
    end
    local actor = s.units[actorIdx]

    if actionType == "move" then
        if actor.player ~= s.currentPlayer then
            return s, { ok = false, code = "wrong_player", reason = "actor_not_current_player" }
        end
        local to = action.to or {}
        local toRow = tonumber(to.row)
        local toCol = tonumber(to.col)
        if not toRow or not toCol or not inBounds(toRow, toCol) then
            return s, { ok = false, code = "invalid_destination", reason = "out_of_bounds_or_missing" }
        end
        local legal = M.getLegalMoves(s, actorIdx)
        local i
        local found = false
        for i = 1, #legal do
            local legalTo = legal[i].to or {}
            if legalTo.row == toRow and legalTo.col == toCol then
                found = true
                break
            end
        end
        if not found then
            return s, { ok = false, code = "illegal_move", reason = "destination_not_legal" }
        end

        actor.row = toRow
        actor.col = toCol
        actor.hasMoved = true
        s.turnActions = (tonumber(s.turnActions) or 0) + 1
        s.actionsUsed = (tonumber(s.actionsUsed) or 0) + 1
        return s, { ok = true, code = "ok", type = "move", actorId = actor.id, outcome = M.evaluateOutcome(s) }
    end

    if actionType == "attack" then
        local targetIdx = findUnitIndex(s, action.targetId or action.targetIndex)
        if not targetIdx then
            return s, { ok = false, code = "target_not_found", reason = "target_missing" }
        end
        local legal, reason = M.isLegalAttack(s, actorIdx, targetIdx)
        if not legal then
            return s, { ok = false, code = "illegal_attack", reason = reason }
        end

        local target = s.units[targetIdx]
        local targetRow = target.row
        local targetCol = target.col
        local damage = unitsInfo:calculateAttackDamage(actor, target)
        damage = tonumber(damage) or 0
        target.currentHp = target.currentHp - damage
        actor.hasActed = true
        s.turnActions = (tonumber(s.turnActions) or 0) + 1
        s.actionsUsed = (tonumber(s.actionsUsed) or 0) + 1

        local destroyed = false
        if target.currentHp <= 0 then
            destroyed = true
            table.remove(s.units, targetIdx)
            if isMeleeAttacker(actor) then
                actor.row = targetRow
                actor.col = targetCol
            end
        end

        return s, {
            ok = true,
            code = "ok",
            type = "attack",
            actorId = actor.id,
            damage = damage,
            targetDestroyed = destroyed,
            outcome = M.evaluateOutcome(s)
        }
    end

    return s, { ok = false, code = "unsupported_action", reason = "supported: move, attack, end_turn" }
end

return M
