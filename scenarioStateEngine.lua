local rulesKernel = require("scenarioRulesKernel")

local M = {
    VERSION = "scenario_state_engine.v0.1.0-step2"
}

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

local function cloneCell(cell)
    local c = type(cell) == "table" and cell or {}
    return {
        row = tonumber(c.row) or 1,
        col = tonumber(c.col) or 1
    }
end

local function safeBool(v)
    return v == true
end

local function safeNum(v, default)
    local n = tonumber(v)
    if n == nil then
        return default
    end
    return n
end

local function stableIdString(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.12g", v)
    end
    return tostring(v)
end

local function encodeScalar(v)
    local tv = type(v)
    if tv == "number" then
        return string.format("%.12g", v)
    end
    if tv == "boolean" then
        return v and "true" or "false"
    end
    if tv == "string" then
        local s = v
        s = s:gsub("\\", "\\\\")
        s = s:gsub("|", "\\|")
        s = s:gsub(":", "\\:")
        s = s:gsub(";", "\\;")
        s = s:gsub(",", "\\,")
        s = s:gsub("%[", "\\[")
        s = s:gsub("%]", "\\]")
        s = s:gsub("%{", "\\{")
        s = s:gsub("%}", "\\}")
        s = s:gsub("%(", "\\(")
        s = s:gsub("%)", "\\)")
        return s
    end
    if tv == "nil" then
        return "nil"
    end
    return tostring(v)
end

local function canonicalActionList(actions)
    if type(actions) ~= "table" then
        return "[]"
    end
    local parts = {}
    local i
    for i = 1, #actions do
        local a = actions[i]
        if type(a) == "table" then
            local t = a.type or ""
            if t == "move" then
                local to = cloneCell(a.to)
                parts[#parts + 1] = "move:" .. to.row .. "," .. to.col
            elseif t == "attack" then
                parts[#parts + 1] = "attack:" .. stableIdString(a.targetId)
            elseif t == "end_turn" then
                parts[#parts + 1] = "end_turn"
            else
                parts[#parts + 1] = encodeScalar(t)
            end
        else
            parts[#parts + 1] = encodeScalar(a)
        end
    end
    local keys = {}
    local key
    for key, _ in pairs(actions) do
        if not (type(key) == "number" and key >= 1 and key <= #actions and math.floor(key) == key) then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(a, b)
        return encodeScalar(a) < encodeScalar(b)
    end)
    for i = 1, #keys do
        key = keys[i]
        parts[#parts + 1] = encodeScalar(key) .. "=" .. encodeScalar(actions[key])
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function normalizeUnitDefaults(unit)
    unit.actionsUsed = safeNum(unit.actionsUsed, 0)
    if type(unit.turnActions) ~= "table" then
        unit.turnActions = {}
    end
    unit.hasMoved = safeBool(unit.hasMoved)
    unit.hasActed = safeBool(unit.hasActed)
    unit.currentHp = safeNum(unit.currentHp, 0)
    unit.startingHp = safeNum(unit.startingHp, unit.currentHp)
end

local function unitSortKey(u)
    return table.concat({
        stableIdString(u.id),
        encodeScalar(u.name),
        encodeScalar(u.player),
        encodeScalar(u.row),
        encodeScalar(u.col)
    }, "|")
end

local function freezeShallow(tbl)
    local source = tbl
    local proxy = {}
    setmetatable(proxy, {
        __index = source,
        __newindex = function()
            error("attempt to modify frozen action", 2)
        end,
        __pairs = function()
            return pairs(source)
        end,
        __ipairs = function()
            return ipairs(source)
        end,
        __len = function()
            return #source
        end,
        __metatable = false
    })
    return proxy
end

local TYPE_ORDER = {
    move = 1,
    attack = 2,
    end_turn = 3
}

local function actionSortValue(action)
    local t = action.type or ""
    local typeRank = TYPE_ORDER[t] or 99
    local actor = stableIdString(action.actorId)
    local to = action.to or {}
    local targetCell = action.targetCell or {}
    local row = safeNum(to.row, safeNum(targetCell.row, 0))
    local col = safeNum(to.col, safeNum(targetCell.col, 0))
    local targetId = stableIdString(action.targetId)
    return typeRank, actor, row, col, targetId
end

local function sortActions(actions)
    table.sort(actions, function(a, b)
        local ta, aa, ra, ca, ida = actionSortValue(a)
        local tb, ab, rb, cb, idb = actionSortValue(b)
        if ta ~= tb then
            return ta < tb
        end
        if aa ~= ab then
            return aa < ab
        end
        if ra ~= rb then
            return ra < rb
        end
        if ca ~= cb then
            return ca < cb
        end
        return ida < idb
    end)
end

local function buildActionId(action)
    if action.type == "move" then
        return table.concat({
            "move",
            stableIdString(action.actorId),
            tostring(action.to.row),
            tostring(action.to.col)
        }, ":")
    end
    if action.type == "attack" then
        return table.concat({
            "attack",
            stableIdString(action.actorId),
            stableIdString(action.targetId),
            tostring(action.targetCell.row),
            tostring(action.targetCell.col)
        }, ":")
    end
    return "end_turn"
end

function M.isScenarioOnly()
    return true
end

function M.cloneState(state)
    return deepCopy(state)
end

function M.normalize(state)
    local normalized = rulesKernel.normalizeState(state)
    normalized.turnActions = safeNum(normalized.turnActions, 0)
    normalized.actionsUsed = safeNum(normalized.actionsUsed, 0)
    normalized.scenarioTurn = safeNum(normalized.scenarioTurn, 1)
    normalized.turnLimit = safeNum(normalized.turnLimit, 10)
    normalized.currentPlayer = safeNum(normalized.currentPlayer, 1)
    normalized.maxActionsPerTurn = math.max(1, math.floor(safeNum(normalized.maxActionsPerTurn, 2)))
    normalized.board = type(normalized.board) == "table" and normalized.board or {}
    normalized.board.rows = safeNum(normalized.board.rows, 8)
    normalized.board.cols = safeNum(normalized.board.cols, 8)

    local units = type(normalized.units) == "table" and normalized.units or {}
    local i
    for i = 1, #units do
        normalizeUnitDefaults(units[i])
    end
    return normalized
end

function M.canonicalStateString(state)
    local s = M.normalize(state)
    local units = {}
    local i
    for i = 1, #s.units do
        units[i] = deepCopy(s.units[i])
    end
    table.sort(units, function(a, b)
        return unitSortKey(a) < unitSortKey(b)
    end)

    local chunks = {
        "board=" .. s.board.rows .. "x" .. s.board.cols,
        "currentPlayer=" .. encodeScalar(s.currentPlayer),
        "scenarioTurn=" .. encodeScalar(s.scenarioTurn),
        "turnLimit=" .. encodeScalar(s.turnLimit),
        "maxActionsPerTurn=" .. encodeScalar(s.maxActionsPerTurn),
        "turnActions=" .. encodeScalar(s.turnActions),
        "actionsUsed=" .. encodeScalar(s.actionsUsed)
    }

    for i = 1, #units do
        local u = units[i]
        local unitChunk = table.concat({
            "id=" .. encodeScalar(u.id),
            "name=" .. encodeScalar(u.name),
            "player=" .. encodeScalar(u.player),
            "hp=" .. encodeScalar(u.currentHp),
            "pos=" .. encodeScalar(u.row) .. "," .. encodeScalar(u.col),
            "hasMoved=" .. encodeScalar(u.hasMoved),
            "hasActed=" .. encodeScalar(u.hasActed),
            "actionsUsed=" .. encodeScalar(u.actionsUsed),
            "turnActions=" .. canonicalActionList(u.turnActions)
        }, ";")
        chunks[#chunks + 1] = "unit{" .. unitChunk .. "}"
    end

    return table.concat(chunks, "|")
end

function M.stateHash(state)
    local text = M.canonicalStateString(state)
    local hash = 5381
    local i
    for i = 1, #text do
        hash = ((hash * 33) + string.byte(text, i)) % 4294967296
    end
    return string.format("%08x", hash)
end

function M.getLegalActions(state)
    local s = M.normalize(state)
    local actions = {}
    local i
    for i = 1, #s.units do
        local u = s.units[i]
        if u.player == s.currentPlayer and u.currentHp > 0 then
            local legalMoves = rulesKernel.getLegalMoves(s, i)
            local legalAttacks = rulesKernel.getLegalAttacks(s, i)
            local j
            for j = 1, #legalMoves do
                local m = legalMoves[j]
                actions[#actions + 1] = {
                    type = "move",
                    actorId = m.actorId,
                    from = cloneCell(m.from),
                    to = cloneCell(m.to),
                    legal = true
                }
            end
            for j = 1, #legalAttacks do
                local a = legalAttacks[j]
                actions[#actions + 1] = {
                    type = "attack",
                    actorId = a.actorId,
                    from = cloneCell(a.from),
                    targetId = a.targetId,
                    targetCell = cloneCell(a.targetCell),
                    legal = true
                }
            end
        end
    end

    actions[#actions + 1] = {
        type = "end_turn",
        legal = true
    }

    sortActions(actions)

    for i = 1, #actions do
        actions[i].id = buildActionId(actions[i])
        actions[i] = freezeShallow(actions[i])
    end
    return actions
end

function M.applyAction(state, action)
    local s = M.normalize(state)
    local nextState, result = rulesKernel.applyAction(s, action)
    local normalizedNext = M.normalize(nextState)
    normalizedNext.stateHash = M.stateHash(normalizedNext)
    return normalizedNext, result
end

function M.applyActionWithUndo(state, action)
    local before = M.cloneState(M.normalize(state))
    local nextState, result = M.applyAction(before, action)
    local undo = {
        mode = "full_state",
        previousState = before
    }
    return nextState, undo, result
end

function M.unapplyAction(nextState, undo)
    if type(undo) ~= "table" or undo.mode ~= "full_state" then
        return M.cloneState(M.normalize(nextState))
    end
    return M.cloneState(undo.previousState)
end

function M.evaluateOutcome(state)
    return rulesKernel.evaluateOutcome(M.normalize(state))
end

return M
