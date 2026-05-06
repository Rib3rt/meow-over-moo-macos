local stateEngine = require("scenarioStateEngine")
local redPolicy = require("scenarioRedPolicy")

local M = {
    VERSION = "scenario_red_runtime.v1",
    RUNTIME_ID = "scenario_red_runtime_policy_adapter_v1"
}

local BLUE = 1
local RED = 2
local NEUTRAL = 0

local function stableString(value)
    if value == nil then
        return ""
    end
    if type(value) == "number" then
        return string.format("%.12g", value)
    end
    return tostring(value)
end

local function scenarioTrace(opts, message)
    if type(opts) == "table" and opts.traceScenarioRuntime == true then
        print("[SCENARIO_TRACE][ScenarioRedRuntime] " .. tostring(message or ""))
    end
end

local function summarizeState(state)
    local counts = {
        total = 0,
        blue = 0,
        red = 0,
        neutral = 0,
        activeRed = 0,
        redCommandants = 0
    }
    for _, unit in ipairs(state and state.units or {}) do
        local player = tonumber(unit.player)
        local name = tostring(unit.name or "")
        counts.total = counts.total + 1
        if player == BLUE then
            counts.blue = counts.blue + 1
        elseif player == RED then
            counts.red = counts.red + 1
            if name == "Commandant" then
                counts.redCommandants = counts.redCommandants + 1
            else
                counts.activeRed = counts.activeRed + 1
            end
        else
            counts.neutral = counts.neutral + 1
        end
    end
    return string.format(
        "turn=%s player=%s actions=%s/%s units=%d blue=%d red=%d activeRed=%d redCommandants=%d neutral=%d",
        tostring(state and state.scenarioTurn or ""),
        tostring(state and state.currentPlayer or ""),
        tostring(state and state.turnActions or ""),
        tostring(state and state.maxActionsPerTurn or ""),
        counts.total,
        counts.blue,
        counts.red,
        counts.activeRed,
        counts.redCommandants,
        counts.neutral
    )
end

local function formatAction(action)
    if type(action) ~= "table" then
        return "nil"
    end
    if action.type == "move" then
        local to = action.to or {}
        return string.format(
            "move actor=%s to=%s,%s",
            tostring(action.actorId or ""),
            tostring(to.row or ""),
            tostring(to.col or "")
        )
    end
    if action.type == "attack" then
        local targetCell = action.targetCell or {}
        return string.format(
            "attack actor=%s target=%s cell=%s,%s",
            tostring(action.actorId or ""),
            tostring(action.targetId or ""),
            tostring(targetCell.row or ""),
            tostring(targetCell.col or "")
        )
    end
    return tostring(action.type or "unknown")
end

local function formatCommand(command)
    if type(command) ~= "table" then
        return "nil"
    end
    if command.actionType == "move" or command.actionType == "attack" then
        return string.format(
            "%s %s,%s->%s,%s",
            tostring(command.actionType),
            tostring(command.fromRow or ""),
            tostring(command.fromCol or ""),
            tostring(command.toRow or ""),
            tostring(command.toCol or "")
        )
    end
    return tostring(command.actionType or "unknown")
end

local function findSelectedScore(record)
    if type(record) ~= "table" then
        return nil
    end
    local selectedId = stableString(record.selectedActionId)
    for _, scored in ipairs(record.scoredActions or {}) do
        if stableString(scored.actionId) == selectedId then
            return scored
        end
    end
    return nil
end

local function formatReasonCodes(scored)
    local codes = {}
    for _, reason in ipairs(scored and scored.reasons or {}) do
        if type(reason) == "table" then
            codes[#codes + 1] = tostring(reason.code or "")
        else
            codes[#codes + 1] = tostring(reason or "")
        end
    end
    return table.concat(codes, ",")
end

local function normalizePlayer(unit)
    local player = tonumber(unit and unit.player)
    if tostring(unit and unit.name or "") == "Rock" then
        return NEUTRAL
    end
    if player == BLUE or player == RED then
        return player
    end
    return NEUTRAL
end

local function unitIdFor(unit, row, col, ordinal)
    local explicit = unit and (unit.scenarioUnitId or unit.id)
    if explicit ~= nil and tostring(explicit) ~= "" then
        return tostring(explicit)
    end

    local name = tostring(unit and unit.name or "unit")
    local player = normalizePlayer(unit)
    if player == BLUE and name == "Cloudstriker" then
        return "blue_finisher"
    end
    if player == BLUE and name == "Artillery" then
        return "blue_a_support"
    end
    if player == RED and name == "Commandant" then
        return "red_commandant"
    end
    if player == RED and name == "Cloudstriker" then
        return "red_decoy"
    end
    if player == NEUTRAL and name == "Rock" then
        return "neutral_rock"
    end

    return table.concat({
        "unit",
        stableString(player),
        name:gsub("%W+", "_"):lower(),
        stableString(row),
        stableString(col),
        stableString(ordinal)
    }, "_")
end

local function readPolicyConfig(scenario)
    local config = type(scenario) == "table" and scenario.scenarioRedPolicy or nil
    if type(config) ~= "table" then
        config = {}
    end
    return {
        seed = config.seed or (scenario and scenario.id) or 1,
        requiredCells = config.requiredCells or {},
        criticalBlueUnitIds = config.criticalBlueUnitIds or {}
    }
end

function M.isScenarioOnly()
    return true
end

function M.buildScenarioState(gameRuler, grid)
    grid = grid or (gameRuler and gameRuler.currentGrid)
    if type(gameRuler) ~= "table" or type(grid) ~= "table" or type(grid.getUnitAt) ~= "function" then
        return nil, nil, "missing_runtime_grid"
    end

    local rows = tonumber(grid.rows) or 8
    local cols = tonumber(grid.cols) or 8
    local units = {}
    local byId = {}
    local ordinal = 0

    local row, col
    for row = 1, rows do
        for col = 1, cols do
            local runtimeUnit = grid:getUnitAt(row, col)
            if runtimeUnit and (tonumber(runtimeUnit.currentHp) or 1) > 0 then
                ordinal = ordinal + 1
                local id = unitIdFor(runtimeUnit, row, col, ordinal)
                local currentHp = tonumber(runtimeUnit.currentHp) or tonumber(runtimeUnit.hp) or tonumber(runtimeUnit.startingHp) or 1
                local startingHp = tonumber(runtimeUnit.startingHp) or tonumber(runtimeUnit.hp) or currentHp
                local scenarioUnit = {
                    id = id,
                    name = tostring(runtimeUnit.name or ""),
                    player = normalizePlayer(runtimeUnit),
                    row = row,
                    col = col,
                    currentHp = currentHp,
                    startingHp = startingHp,
                    hasMoved = runtimeUnit.hasMoved == true or (type(runtimeUnit.turnActions) == "table" and runtimeUnit.turnActions.move == true),
                    hasActed = runtimeUnit.hasActed == true,
                    actionsUsed = tonumber(runtimeUnit.actionsUsed) or 0,
                    turnActions = type(runtimeUnit.turnActions) == "table" and runtimeUnit.turnActions or {}
                }
                units[#units + 1] = scenarioUnit
                byId[id] = {
                    id = id,
                    row = row,
                    col = col,
                    runtimeUnit = runtimeUnit,
                    scenarioUnit = scenarioUnit
                }
            end
        end
    end

    local scenario = GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO or nil
    local turnLimit = tonumber(scenario and scenario.turnsTarget) or 3
    local state = {
        schema = "ScenarioState",
        board = { rows = rows, cols = cols },
        currentPlayer = tonumber(gameRuler.currentPlayer) or BLUE,
        scenarioTurn = tonumber(gameRuler.currentTurn) or 1,
        turnLimit = turnLimit,
        maxActionsPerTurn = tonumber(gameRuler.maxActionsPerTurn) or 2,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = tonumber(gameRuler.currentTurnActions) or 0,
        actionsUsed = tonumber(gameRuler.currentTurnActions) or 0,
        units = units
    }
    return stateEngine.normalize(state), byId, nil
end

function M.actionToCommand(action, byId)
    if type(action) ~= "table" then
        return nil, "missing_policy_action"
    end
    if action.type == "end_turn" then
        return { actionType = "end_turn" }, nil
    end

    local actor = byId and byId[stableString(action.actorId)] or nil
    if not actor then
        return nil, "policy_actor_not_found"
    end

    if action.type == "move" then
        local to = action.to or {}
        local toRow = tonumber(to.row)
        local toCol = tonumber(to.col)
        if not toRow or not toCol then
            return nil, "policy_move_missing_destination"
        end
        return {
            actionType = "move",
            fromRow = actor.row,
            fromCol = actor.col,
            toRow = toRow,
            toCol = toCol
        }, nil
    end

    if action.type == "attack" then
        local target = byId and byId[stableString(action.targetId)] or nil
        if not target then
            return nil, "policy_target_not_found"
        end
        return {
            actionType = "attack",
            fromRow = actor.row,
            fromCol = actor.col,
            toRow = target.row,
            toCol = target.col
        }, nil
    end

    return nil, "unsupported_policy_action"
end

function M.chooseCommand(gameRuler, grid, opts)
    opts = type(opts) == "table" and opts or {}
    local state, byId, stateErr = M.buildScenarioState(gameRuler, grid)
    if not state then
        scenarioTrace(opts, "state.unavailable reason=" .. tostring(stateErr or "scenario_state_unavailable"))
        return nil, {
            ok = false,
            reason = stateErr or "scenario_state_unavailable"
        }
    end
    scenarioTrace(opts, "state " .. summarizeState(state) .. " hash=" .. stateEngine.stateHash(state))
    if state.currentPlayer ~= RED then
        return nil, {
            ok = false,
            reason = "not_red_to_move",
            stateHash = stateEngine.stateHash(state)
        }
    end

    local policyConfig = readPolicyConfig(opts.scenario or (GAME and GAME.CURRENT and GAME.CURRENT.SCENARIO))
    scenarioTrace(opts, string.format(
        "policy.config seed=%s requiredCells=%d criticalBlueUnitIds=%d",
        tostring(policyConfig.seed or ""),
        #(policyConfig.requiredCells or {}),
        #(policyConfig.criticalBlueUnitIds or {})
    ))
    local action, record = redPolicy.chooseAction(state, policyConfig)
    local command, commandErr = M.actionToCommand(action, byId)
    record = record or {}
    record.ok = command ~= nil
    record.reason = commandErr
    record.selectedAction = action
    record.command = command
    local selectedScore = findSelectedScore(record)
    scenarioTrace(opts, string.format(
        "policy.result candidates=%s selected=%s score=%s reasons=%s command=%s commandErr=%s",
        tostring(record.candidateCount or ""),
        formatAction(action),
        tostring(selectedScore and selectedScore.score or ""),
        formatReasonCodes(selectedScore),
        formatCommand(command),
        tostring(commandErr or "")
    ))
    return command, record
end

M.RUNTIME_HASH = redPolicy.POLICY_HASH .. "|" .. M.VERSION

return M
