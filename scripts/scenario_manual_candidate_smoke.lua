package.path = package.path .. ";./?.lua"

local redPolicy = require("scenarioRedPolicy")
local scenarioRedRuntime = require("scenarioRedRuntime")
local stateEngine = require("scenarioStateEngine")
local rulesKernel = require("scenarioRulesKernel")
local unitsInfo = require("unitsInfo")

local BLUE = 1
local RED = 2

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = { name = name, ok = ok, err = err }
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "assertEquals failed", tostring(expected), tostring(actual)), 2)
    end
end

local function loadScenario(path)
    local chunk, err = loadfile(path)
    assertTrue(type(chunk) == "function", "failed to load " .. tostring(path) .. ": " .. tostring(err))
    local ok, payload = pcall(chunk)
    assertTrue(ok, "scenario chunk failed " .. tostring(path) .. ": " .. tostring(payload))
    assertTrue(type(payload) == "table", "scenario payload must be a table: " .. tostring(path))
    return payload
end

local function scenarioToState(scenario)
    local snapshot = scenario.startSnapshot or {}
    local units = {}
    for _, unit in ipairs(snapshot.boardUnits or {}) do
        units[#units + 1] = {
            id = tostring(unit.scenarioUnitId or unit.id),
            name = unit.name,
            player = unit.player,
            row = unit.row,
            col = unit.col,
            currentHp = unit.currentHp,
            startingHp = unit.startingHp,
            hasMoved = false,
            hasActed = false,
            turnActions = {}
        }
    end

    return stateEngine.normalize({
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = tonumber(snapshot.currentPlayer) or BLUE,
        scenarioTurn = tonumber(snapshot.currentTurn) or 1,
        turnLimit = tonumber(scenario.turnLimitRounds) or 4,
        maxActionsPerTurn = tonumber(snapshot.maxActionsPerTurn) or 2,
        objectiveType = scenario.objectiveType or "destroy_commandant",
        supplyEnabled = false,
        turnActions = tonumber(snapshot.currentTurnActions) or 0,
        actionsUsed = tonumber(snapshot.currentTurnActions) or 0,
        units = units
    })
end

local function findUnitIndex(state, id)
    for index, unit in ipairs(state.units or {}) do
        if tostring(unit.id) == tostring(id) then
            return index, unit
        end
    end
    return nil, nil
end

local function findAction(state, actionType, actorId, row, col)
    for _, action in ipairs(stateEngine.getLegalActions(state)) do
        if action.type == actionType and tostring(action.actorId) == tostring(actorId) then
            if actionType == "move" and action.to and action.to.row == row and action.to.col == col then
                return action
            end
            if actionType == "attack" and action.targetCell and action.targetCell.row == row and action.targetCell.col == col then
                return action
            end
        end
    end
    return nil
end

local function applyRuntimeAction(state, action)
    local nextState, result = rulesKernel.applyAction(stateEngine.normalize(state), action)
    return stateEngine.normalize(nextState), result
end

local function doAction(state, actionType, actorId, row, col)
    local action = findAction(state, actionType, actorId, row, col)
    assertTrue(action ~= nil, table.concat({
        "missing legal action",
        tostring(actionType),
        tostring(actorId),
        tostring(row),
        tostring(col)
    }, " "))
    local nextState, result = applyRuntimeAction(state, action)
    assertTrue(result and result.ok, "illegal action " .. tostring(action.id) .. ": " .. tostring(result and result.reason))
    return nextState, result
end

local function endBlueTurnThroughScenarioRedPolicy(state, scenario)
    local nextState = stateEngine.normalize(state)
    if nextState.currentPlayer == BLUE then
        nextState = stateEngine.normalize((rulesKernel.applyAction(nextState, { type = "end_turn" })))
    end

    assertEquals(nextState.currentPlayer, RED, "expected Red handoff")

    while nextState.currentPlayer == RED
        and (tonumber(nextState.turnActions) or 0) < (tonumber(nextState.maxActionsPerTurn) or 2)
    do
        local action = redPolicy.chooseAction(nextState, scenario.scenarioRedPolicy or {})
        if not action or action.type == "end_turn" then
            break
        end
        local result
        nextState, result = applyRuntimeAction(nextState, action)
        assertTrue(result and result.ok, "Scenario Red Policy produced illegal action: " .. tostring(result and result.reason))
        if rulesKernel.evaluateOutcome(nextState).status ~= "ongoing" then
            break
        end
    end

    if nextState.currentPlayer == RED then
        nextState = stateEngine.normalize((rulesKernel.applyAction(nextState, { type = "end_turn" })))
    end
    assertEquals(nextState.currentPlayer, BLUE, "expected Blue turn after Scenario Red Policy")
    return nextState
end

local function findUnitAt(state, row, col)
    for index, unit in ipairs(state.units or {}) do
        if unit.row == row and unit.col == col and (tonumber(unit.currentHp) or 0) > 0 then
            return index, unit
        end
    end
    return nil, nil
end

local function applyCommandantDefense(state)
    local nextState = stateEngine.normalize(state)
    local commandant = nil
    for _, unit in ipairs(nextState.units or {}) do
        if unit.player == nextState.currentPlayer and unit.name == "Commandant" and (tonumber(unit.currentHp) or 0) > 0 then
            commandant = unit
            break
        end
    end
    if not commandant then
        return nextState
    end
    local directions = {
        { row = 0, col = 1 },
        { row = 1, col = 0 },
        { row = 0, col = -1 },
        { row = -1, col = 0 }
    }
    for _, direction in ipairs(directions) do
        local index, target = findUnitAt(nextState, commandant.row + direction.row, commandant.col + direction.col)
        if target and target.player ~= nextState.currentPlayer then
            local damageValue = unitsInfo:calculateAttackDamage(commandant, target)
            local damage = tonumber(damageValue) or 0
            target.currentHp = (tonumber(target.currentHp) or 0) - damage
            if target.currentHp <= 0 then
                table.remove(nextState.units, index)
            end
        end
    end
    return stateEngine.normalize(nextState)
end

local function endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    local nextState = stateEngine.normalize(state)
    if nextState.currentPlayer == BLUE then
        nextState = stateEngine.normalize((rulesKernel.applyAction(nextState, { type = "end_turn" })))
    end
    assertEquals(nextState.currentPlayer, RED, "expected Red handoff")
    nextState = applyCommandantDefense(nextState)
    while nextState.currentPlayer == RED
        and (tonumber(nextState.turnActions) or 0) < (tonumber(nextState.maxActionsPerTurn) or 2)
    do
        local action = redPolicy.chooseAction(nextState, scenario.scenarioRedPolicy or {})
        if not action or action.type == "end_turn" then
            break
        end
        local result
        nextState, result = applyRuntimeAction(nextState, action)
        assertTrue(result and result.ok, "Scenario Red Policy produced illegal action: " .. tostring(result and result.reason))
        if rulesKernel.evaluateOutcome(nextState).status ~= "ongoing" then
            break
        end
    end
    if nextState.currentPlayer == RED then
        nextState = stateEngine.normalize((rulesKernel.applyAction(nextState, { type = "end_turn" })))
    end
    assertEquals(nextState.currentPlayer, BLUE, "expected Blue turn after Scenario Red Policy")
    return nextState
end

local function outcome(state)
    return rulesKernel.evaluateOutcome(state).status
end

local function commandantHp(state)
    for _, unit in ipairs(state.units or {}) do
        if unit.player == RED and unit.name == "Commandant" then
            return tonumber(unit.currentHp) or 0
        end
    end
    return 0
end

local function runtimeCommandFromState(state, scenario)
    local board = {}
    for _, unit in ipairs(state.units or {}) do
        board[tostring(unit.row) .. ":" .. tostring(unit.col)] = {
            scenarioUnitId = unit.id,
            name = unit.name,
            player = unit.player,
            currentHp = unit.currentHp,
            startingHp = unit.startingHp,
            hasMoved = unit.hasMoved,
            hasActed = unit.hasActed,
            turnActions = unit.turnActions or {}
        }
    end
    local grid = {
        rows = 8,
        cols = 8,
        getUnitAt = function(_, row, col)
            return board[tostring(row) .. ":" .. tostring(col)]
        end
    }
    local ruler = {
        currentGrid = grid,
        currentPlayer = state.currentPlayer,
        currentTurn = state.scenarioTurn,
        currentTurnActions = state.turnActions,
        maxActionsPerTurn = state.maxActionsPerTurn
    }
    local previousGame = GAME
    GAME = {
        CURRENT = {
            SCENARIO = {
                turnsTarget = scenario.turnLimitRounds,
                scenarioRedPolicy = scenario.scenarioRedPolicy
            }
        }
    }
    local command, record = scenarioRedRuntime.chooseCommand(ruler, grid, {
        scenario = {
            id = scenario.id,
            turnsTarget = scenario.turnLimitRounds,
            scenarioRedPolicy = scenario.scenarioRedPolicy
        }
    })
    GAME = previousGame
    return command, record
end

local function blueActionSequences(state)
    local sequences = {}
    local function walk(cursor, actions)
        sequences[#sequences + 1] = {
            state = stateEngine.cloneState(cursor),
            actions = stateEngine.cloneState(actions)
        }
        if #actions >= 2 then
            return
        end
        for _, action in ipairs(stateEngine.getLegalActions(cursor)) do
            if action.type ~= "end_turn" then
                local nextState, result = applyRuntimeAction(cursor, action)
                if result and result.ok then
                    actions[#actions + 1] = action
                    walk(nextState, actions)
                    actions[#actions] = nil
                end
            end
        end
    end
    walk(stateEngine.normalize(state), {})
    return sequences
end

local function passRedTurn(state)
    local nextState = stateEngine.normalize(state)
    if nextState.currentPlayer == BLUE then
        nextState = stateEngine.normalize((rulesKernel.applyAction(nextState, { type = "end_turn" })))
    end
    assertEquals(nextState.currentPlayer, RED, "expected Red handoff for Red-pass bound")
    nextState = stateEngine.normalize((rulesKernel.applyAction(nextState, { type = "end_turn" })))
    assertEquals(nextState.currentPlayer, BLUE, "expected Blue turn after Red-pass bound")
    return nextState
end

local function hasTwoTurnBlueWinEvenIfRedPasses(state)
    local start = stateEngine.normalize(state)
    for _, firstTurn in ipairs(blueActionSequences(start)) do
        if outcome(firstTurn.state) == "blue_win" then
            return true, firstTurn.actions
        end
        local secondTurnStart = passRedTurn(firstTurn.state)
        for _, secondTurn in ipairs(blueActionSequences(secondTurnStart)) do
            if outcome(secondTurn.state) == "blue_win" then
                return true, secondTurn.actions
            end
        end
    end
    return false, nil
end

runTest("p003_material_has_four_turn_capture_discipline", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    local _, opener = findUnitIndex(state, "blue_opener")
    local _, screen = findUnitIndex(state, "blue_screen")
    local _, commandant = findUnitIndex(state, "red_commandant")
    local _, gate = findUnitIndex(state, "neutral_gate")
    local _, guard = findUnitIndex(state, "neutral_guard")
    local _, battery = findUnitIndex(state, "red_battery")
    local _, lure = findUnitIndex(state, "red_lure")

    assertEquals(scenario.turnLimitRounds, 4, "P003 should be a four-turn capture discipline puzzle")
    assertEquals(scenario.promotion.source, "manual_playtest_capture_discipline_4", "P003 should record the capture discipline playtest source")
    assertTrue(finisher and finisher.name == "Crusher" and finisher.row == 8 and finisher.col == 4 and finisher.currentHp == 4, "P003 should use a D8 Crusher as the finisher")
    assertTrue(opener and opener.name == "Cloudstriker" and opener.row == 7 and opener.col == 7, "P003 should include G7 Cloudstriker as the ranged opener")
    assertTrue(screen and screen.name == "Earthstalker" and screen.row == 5 and screen.col == 6, "P003 should include the F5 screen/false breaker")
    assertTrue(commandant and commandant.row == 2 and commandant.col == 4 and commandant.currentHp == 4, "P003 Commandant should die to one Crusher hit")
    assertTrue(gate and gate.name == "Rock" and gate.row == 4 and gate.col == 4 and gate.currentHp == 2, "P003 should include the D4 capture-discipline gate")
    assertTrue(guard and guard.name == "Rock" and guard.row == 3 and guard.col == 4 and guard.currentHp == 3, "P003 should include the D3 capture guard")
    assertTrue(battery and battery.name == "Artillery" and battery.row == 6 and battery.col == 1, "P003 should include active Red Artillery pressure")
    assertTrue(lure and lure.name == "Wingstalker" and lure.row == 5 and lure.col == 7 and lure.currentHp == 2, "P003 should include the G5 Wingstalker tempo lure")
    assertTrue(findAction(state, "move", "blue_finisher", 6, 4) ~= nil, "Crusher should be able to start the D-file march")
    assertTrue(findAction(state, "move", "blue_opener", 4, 7) ~= nil, "Cloudstriker should be able to stage on G4")
    assertTrue(findAction(state, "attack", "blue_opener", 5, 7) ~= nil, "Cloudstriker should see the tempting immediate Wingstalker shot")
    assertTrue(findAction(state, "attack", "blue_opener", 4, 4) == nil, "Cloudstriker must not open the gate without staging")
    assertTrue(findAction(state, "attack", "blue_finisher", 2, 4) == nil, "Crusher must not start with a Commandant hit")
end)

runTest("p003_runtime_red_ai_presses_wounded_crusher", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_finisher", 6, 4)
    state = doAction(state, "move", "blue_opener", 4, 7)
    state = stateEngine.normalize((rulesKernel.applyAction(state, { type = "end_turn" })))

    local command, record = runtimeCommandFromState(state, scenario)
    assertTrue(record and record.ok == true, "true runtime Scenario Red AI should resolve a command")
    assertEquals(command.actionType, "attack", "runtime AI should pressure the wounded Crusher immediately")
    assertEquals(command.fromRow, 6, "runtime AI should use the A6 battery")
    assertEquals(command.fromCol, 1, "runtime AI should use the A6 battery")
    assertEquals(command.toRow, 6, "runtime AI should shoot the Crusher on D6")
    assertEquals(command.toCol, 4, "runtime AI should shoot the Crusher on D6")
end)

runTest("p003_false_cloudstriker_opens_gate_too_early_but_delays_crusher", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_opener", 4, 7)
    state = doAction(state, "attack", "blue_opener", 4, 4)
    state = passRedTurn(state)
    state = doAction(state, "move", "blue_finisher", 6, 4)
    state = passRedTurn(state)
    state = doAction(state, "move", "blue_finisher", 4, 4)
    state = passRedTurn(state)
    assertTrue(findAction(state, "attack", "blue_finisher", 2, 4) == nil, "early gate payoff should leave Crusher one capture short on Blue turn four")
end)

runTest("p003_false_take_red_lure_loses_gate_timing", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 5, 7)
    assertTrue(findUnitIndex(state, "red_lure") == nil, "the Wingstalker lure should be a real removable target")
    state = doAction(state, "move", "blue_finisher", 6, 4)
    state = passRedTurn(state)
    state = doAction(state, "move", "blue_opener", 4, 7)
    state = doAction(state, "attack", "blue_opener", 4, 4)
    state = passRedTurn(state)
    state = doAction(state, "move", "blue_finisher", 4, 4)
    state = passRedTurn(state)
    state = doAction(state, "attack", "blue_finisher", 3, 4)
    assertTrue(findAction(state, "attack", "blue_finisher", 2, 4) == nil, "taking the obvious Red lure should leave Crusher one action short on Blue turn four")
    assertEquals(commandantHp(state), 4, "the lure line should not sneak early Commandant damage")
end)

runTest("p003_false_melee_gate_clear_blocks_the_exact_cell", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_finisher", 6, 4)
    state = doAction(state, "move", "blue_screen", 5, 4)
    state = passRedTurn(state)
    state = doAction(state, "attack", "blue_screen", 4, 4)

    local _, screen = findUnitIndex(state, "blue_screen")
    assertTrue(screen ~= nil and screen.row == 4 and screen.col == 4, "melee gate clear should capture and occupy D4")
    assertTrue(findAction(state, "move", "blue_finisher", 4, 4) == nil, "Crusher cannot move into D4 after the wrong melee capture")
end)

runTest("p003_false_skip_ranged_open_keeps_gate_closed", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_finisher", 6, 4)
    state = doAction(state, "move", "blue_opener", 4, 7)
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    assertTrue(findAction(state, "move", "blue_finisher", 4, 4) == nil, "Crusher cannot pass through the still-occupied D4 gate")
end)

runTest("p003_cannot_finish_before_blue_turn_four", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_finisher", 6, 4)
    state = doAction(state, "move", "blue_opener", 4, 7)
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    state = doAction(state, "attack", "blue_opener", 4, 4)
    state = doAction(state, "move", "blue_finisher", 4, 4)
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    state = doAction(state, "attack", "blue_finisher", 3, 4)
    assertEquals(commandantHp(state), 4, "movement setup should not damage the Commandant before the final turn")
    assertEquals(outcome(state), "ongoing", "P003 should not finish before Blue turn four")
end)

runTest("p003_intended_four_turn_capture_discipline_wins", function()
    local scenario = loadScenario("scenarios/P003.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_finisher", 6, 4)
    state = doAction(state, "move", "blue_opener", 4, 7)
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    assertTrue(finisher ~= nil and finisher.currentHp == 3, "Red battery should wound the Crusher on the first handoff")

    state = doAction(state, "attack", "blue_opener", 4, 4)
    state = doAction(state, "move", "blue_finisher", 4, 4)
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    assertTrue(findUnitIndex(state, "neutral_gate") == nil, "Cloudstriker should open D4 without occupying it")
    _, finisher = findUnitIndex(state, "blue_finisher")
    assertTrue(finisher ~= nil and finisher.row == 4 and finisher.col == 4, "Crusher should claim the opened D4 cell")

    state = doAction(state, "attack", "blue_finisher", 3, 4)
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    _, finisher = findUnitIndex(state, "blue_finisher")
    assertTrue(finisher ~= nil and finisher.row == 3 and finisher.col == 4 and finisher.currentHp == 1, "Crusher should survive on D3 after Commandant Defense")

    state = doAction(state, "attack", "blue_finisher", 2, 4)
    assertEquals(outcome(state), "blue_win", "P003 intended capture-discipline line should destroy Commandant")
end)

runTest("p004_is_distinct_material_and_has_a_productive_false_opening", function()
    local scenario = loadScenario("scenarios/P004.lua")
    local state = scenarioToState(scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    local _, artillery = findUnitIndex(state, "blue_artillery")
    local _, lure = findUnitIndex(state, "blue_lure")
    local _, guard = findUnitIndex(state, "red_cell_guard")
    local _, lineLock = findUnitIndex(state, "neutral_line_lock")
    local _, shortcutLock = findUnitIndex(state, "neutral_anti_shortcut")

    assertEquals(scenario.id, "P004", "P004 id mismatch")
    assertEquals(scenario.name, "Scenario P004", "P004 public name should stay numeric")
    assertEquals(scenario.turnLimitRounds, 3, "P004 should use the promoted 790 three-turn lane")
    assertTrue(finisher and finisher.name == "Cloudstriker", "P004 should use a Cloudstriker finisher")
    assertTrue(artillery and artillery.name == "Artillery", "P004 should include an Artillery line opener")
    assertTrue(lure and lure.name == "Earthstalker" and lure.currentHp == 1, "P004 should include the 1 HP Earthstalker lure")
    assertTrue(guard and guard.name == "Bastion" and guard.currentHp == 3, "P004 should include the E4 Bastion cell guard")
    assertTrue(lineLock and lineLock.name == "Rock" and lineLock.currentHp == 2, "P004 should include the E3 line lock")
    assertTrue(shortcutLock and shortcutLock.name == "Rock", "P004 should include an anti-shortcut line blocker")
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 5) == nil, "finisher must not start with a Commandant hit")
    assertTrue(findAction(state, "attack", "blue_artillery", 1, 5) == nil, "support must not start with a Commandant hit")
    assertTrue(findAction(state, "attack", "blue_lure", 1, 5) == nil, "lure must not start with a Commandant hit")
    assertTrue(findAction(state, "move", "blue_finisher", 4, 5) == nil, "E4 must not be available before the Bastion is lured away")

    local falseLine = doAction(state, "move", "blue_finisher", 5, 5)
    falseLine = doAction(falseLine, "move", "blue_artillery", 3, 2)
    falseLine = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(falseLine, scenario)
    falseLine = doAction(falseLine, "attack", "blue_artillery", 3, 5)
    assertTrue(findUnitIndex(falseLine, "red_cell_guard") ~= nil, "false finisher staging should leave the Bastion on E4")
    assertEquals(commandantHp(falseLine), 3, "false finisher staging should look close but still leave no Commandant damage")
    assertEquals(outcome(falseLine), "ongoing", "false finisher staging should not solve the scenario")
end)

runTest("p004_three_turn_bound_has_explicit_action_budget", function()
    local scenario = loadScenario("scenarios/P004.lua")
    local state = scenarioToState(scenario)

    assertTrue(findAction(state, "move", "blue_artillery", 3, 2) ~= nil, "artillery setup should be legal")
    assertTrue(findAction(state, "move", "blue_lure", 5, 4) ~= nil, "Earthstalker lure setup should be legal")
    assertTrue(findAction(state, "attack", "blue_artillery", 3, 5) == nil, "line lock must require Artillery setup before it can be cleared")
    assertTrue(findAction(state, "move", "blue_finisher", 4, 5) == nil, "finisher destination must be occupied before Red is baited out")
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 5) == nil, "finisher payoff must be unavailable before the lane is opened")

    local lineSetup = doAction(state, "move", "blue_artillery", 3, 2)
    lineSetup = doAction(lineSetup, "attack", "blue_artillery", 3, 5)
    assertTrue(findUnitIndex(lineSetup, "neutral_line_lock") == nil, "two actions are required to open the line lock")
    assertTrue(findUnitIndex(lineSetup, "red_cell_guard") ~= nil, "line clearing alone must not vacate the E4 cell guard")

    local lureSetup = doAction(state, "move", "blue_lure", 5, 4)
    lureSetup = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(lureSetup, scenario)
    assertTrue(findUnitIndex(lureSetup, "blue_lure") == nil, "Red should kill the 1 HP Earthstalker lure")
    assertTrue(findUnitAt(lureSetup, 4, 5) == nil, "Red response should vacate E4 for the finisher")
end)

runTest("p004_intended_three_turn_dual_setup_lane_wins", function()
    local scenario = loadScenario("scenarios/P004.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_artillery", 3, 2) -- B4 -> B3
    state = doAction(state, "move", "blue_lure", 5, 4) -- D6 -> D5
    assertEquals(commandantHp(state), 3, "setup turn should not damage Commandant")
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)
    assertTrue(findUnitIndex(state, "blue_lure") == nil, "1 HP lure should be removed by Red")
    assertTrue(findUnitAt(state, 4, 5) == nil, "Bastion leaving E4 should open the finisher destination")

    state = doAction(state, "attack", "blue_artillery", 3, 5) -- B3 x E3
    state = doAction(state, "move", "blue_finisher", 4, 5) -- E7 -> E4
    assertTrue(findUnitIndex(state, "neutral_line_lock") == nil, "Artillery should open the Cloudstriker line")
    state = endBlueTurnThroughScenarioRedPolicyWithCommandantDefense(state, scenario)

    state = doAction(state, "attack", "blue_finisher", 1, 5) -- E4 x E1
    assertEquals(outcome(state), "blue_win", "P004 intended three-turn line should destroy Commandant")
end)

runTest("p005_material_has_crossed_march_with_mixed_axes", function()
    local scenario = loadScenario("scenarios/P005.lua")
    local state = scenarioToState(scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    local _, opener = findUnitIndex(state, "blue_opener")
    local _, cover = findUnitIndex(state, "blue_cover")
    local _, commandant = findUnitIndex(state, "red_commandant")
    local _, gate = findUnitIndex(state, "red_gate")
    local _, battery = findUnitIndex(state, "red_battery")
    local _, chaser = findUnitIndex(state, "red_chaser")
    local _, d8Lock = findUnitIndex(state, "neutral_d8_lock")
    local _, d4Screen = findUnitIndex(state, "neutral_d4_screen")

    assertEquals(scenario.id, "P005", "P005 id mismatch")
    assertEquals(scenario.name, "Scenario P005", "P005 public name should stay numeric")
    assertEquals(scenario.turnLimitRounds, 4, "P005 should use a four-turn crossed Crusher march")
    assertEquals(scenario.promotion.source, "manual_playtest_crossed_march_4", "P005 source mismatch")
    assertTrue(finisher and finisher.name == "Crusher" and finisher.row == 8 and finisher.col == 8 and finisher.currentHp == 2, "P005 should use a wounded H8 Crusher as the moving finisher")
    assertTrue(opener and opener.name == "Cloudstriker" and opener.row == 3 and opener.col == 6 and opener.currentHp == 2, "P005 should include wounded F3 Cloudstriker vertical opener")
    assertTrue(cover and cover.name == "Artillery" and cover.row == 8 and cover.col == 2, "P005 should include B8 Artillery for the E8 softening shot")
    assertTrue(commandant and commandant.row == 4 and commandant.col == 5 and commandant.currentHp == 4, "P005 Commandant should die to one Crusher hit from E5")
    assertTrue(gate and gate.name == "Earthstalker" and gate.row == 6 and gate.col == 6 and gate.currentHp == 2, "P005 should include the F6 active route gate")
    assertTrue(battery and battery.name == "Artillery" and battery.row == 8 and battery.col == 5 and battery.currentHp == 2 and battery.startingHp == 4, "P005 should include live E8 Red Artillery as the mandatory capture target")
    assertTrue(chaser and chaser.name == "Wingstalker" and chaser.row == 2 and chaser.col == 8 and chaser.currentHp == 3, "P005 should include the durable H2 Wingstalker crossing pressure")
    assertTrue(d8Lock and d8Lock.name == "Rock" and d8Lock.row == 8 and d8Lock.col == 4 and d8Lock.currentHp == 2 and d8Lock.startingHp == 2, "P005 should include the D8 lock that preserves the E8 capture route")
    assertTrue(d4Screen and d4Screen.name == "Rock" and d4Screen.row == 4 and d4Screen.col == 4, "P005 should include the D4 screen against the logged Cloudstriker shot")
    assertTrue(findAction(state, "attack", "blue_opener", 6, 6) ~= nil, "Cloudstriker should be able to open F6")
    assertTrue(findAction(state, "attack", "blue_cover", 8, 5) ~= nil, "Artillery should be able to soften the E8 battery")
    assertTrue(findAction(state, "move", "blue_finisher", 8, 6) ~= nil, "Crusher should be able to start the first horizontal leg")
    assertTrue(findAction(state, "move", "blue_finisher", 6, 6) == nil, "Crusher cannot skip the first bend on turn one")
end)

runTest("p005_false_logged_cloudstriker_c4_shot_is_screened", function()
    local scenario = loadScenario("scenarios/P005.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_opener", 3, 3)
    state = doAction(state, "move", "blue_finisher", 6, 8)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "blue_finisher") == nil, "logged bait line should still lose Crusher to the F6 Earthstalker")

    state = doAction(state, "move", "blue_opener", 4, 3)
    assertTrue(findAction(state, "attack", "blue_opener", 4, 5) == nil, "D4 screen should block the logged Cloudstriker C4 shot on Commandant")
    assertEquals(commandantHp(state), 4, "logged Cloudstriker line should not damage Commandant")
end)

runTest("p005_false_same_units_wrong_order_loses_tempo", function()
    local scenario = loadScenario("scenarios/P005.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 6, 6)
    state = doAction(state, "attack", "blue_cover", 8, 5)
    state = passRedTurn(state)
    state = doAction(state, "move", "blue_finisher", 8, 6)
    state = passRedTurn(state)
    state = doAction(state, "attack", "blue_finisher", 8, 5)
    state = passRedTurn(state)
    state = doAction(state, "move", "blue_finisher", 6, 5)
    assertTrue(findAction(state, "attack", "blue_finisher", 4, 5) == nil, "same useful actions in the wrong order should leave Crusher one action short on Blue turn four")
end)

runTest("p005_false_cloudstriker_chases_wingstalker_loses_commandant_race", function()
    local scenario = loadScenario("scenarios/P005.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_opener", 2, 6)
    state = doAction(state, "attack", "blue_opener", 2, 8)
    local _, chaser = findUnitIndex(state, "red_chaser")
    assertTrue(chaser ~= nil and chaser.currentHp == 1, "Wingstalker should survive the tempting Cloudstriker chase")

    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    _, chaser = findUnitIndex(state, "red_chaser")
    assertTrue(chaser ~= nil and chaser.row == 2 and chaser.col == 6, "Red should recapture onto F2 after the shortcut attempt")
    assertTrue(findUnitIndex(state, "blue_opener") == nil, "the wounded Cloudstriker chase should lose the opener")
    assertEquals(commandantHp(state), 4, "the Wingstalker chase should not make Commandant progress")
end)

runTest("p005_false_skip_artillery_capture_leaves_e_file_disrupted", function()
    local scenario = loadScenario("scenarios/P005.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 6, 6)
    state = doAction(state, "move", "blue_finisher", 8, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    state = doAction(state, "move", "blue_finisher", 6, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    state = doAction(state, "move", "blue_finisher", 6, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)

    local _, battery = findUnitIndex(state, "red_battery")
    assertTrue(battery ~= nil and battery.row == 8 and battery.col == 5, "skipping the Artillery capture should leave the E8 battery alive")
    assertTrue(findAction(state, "move", "blue_finisher", 5, 5) == nil, "Red pressure should deny the E5 finishing square after the skipped E8 capture")
    assertEquals(commandantHp(state), 4, "the skipped E8 capture should make no Commandant progress")
end)

runTest("p005_cannot_finish_before_blue_turn_four", function()
    local scenario = loadScenario("scenarios/P005.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 6, 6)
    state = doAction(state, "move", "blue_finisher", 8, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    state = doAction(state, "attack", "blue_cover", 8, 5)
    state = doAction(state, "attack", "blue_finisher", 8, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    state = doAction(state, "move", "blue_finisher", 6, 5)
    assertEquals(commandantHp(state), 4, "crossed march should not damage Commandant before final turn")
    assertEquals(outcome(state), "ongoing", "P005 should require Blue turn four")
end)

runTest("p005_intended_four_turn_crossed_march_wins", function()
    local scenario = loadScenario("scenarios/P005.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 6, 6)
    state = doAction(state, "move", "blue_finisher", 8, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "red_gate") == nil, "Cloudstriker should open F6 without occupying it")
    local _, opener = findUnitIndex(state, "blue_opener")
    assertTrue(opener == nil, "Wingstalker should remove the wounded Cloudstriker after it opens the route")

    state = doAction(state, "attack", "blue_cover", 8, 5)
    local _, battery = findUnitIndex(state, "red_battery")
    assertTrue(battery ~= nil and battery.currentHp == 1, "Artillery shot should soften E8 battery for the Crusher capture")
    state = doAction(state, "attack", "blue_finisher", 8, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    battery = select(2, findUnitIndex(state, "red_battery"))
    assertTrue(battery == nil, "Crusher should capture and remove the E8 battery")

    state = doAction(state, "move", "blue_finisher", 6, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    assertTrue(finisher ~= nil and finisher.row == 6 and finisher.col == 5 and finisher.currentHp == 1, "Crusher should survive Red pressure on E6 after the E8 capture")

    state = doAction(state, "move", "blue_finisher", 5, 5)
    state = doAction(state, "attack", "blue_finisher", 4, 5)
    assertEquals(outcome(state), "blue_win", "P005 intended crossed march should destroy Commandant")
end)

runTest("p006_material_has_bastion_siege_walk_and_decoy_timing", function()
    local scenario = loadScenario("scenarios/P006.lua")
    local state = scenarioToState(scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    local _, decoy = findUnitIndex(state, "blue_decoy")
    local _, reserve = findUnitIndex(state, "blue_reserve")
    local _, hunter = findUnitIndex(state, "red_hunter")
    local _, battery = findUnitIndex(state, "red_battery")

    assertEquals(scenario.id, "P006", "P006 id mismatch")
    assertEquals(scenario.name, "Scenario P006", "P006 public name should stay numeric")
    assertEquals(scenario.turnLimitRounds, 4, "P006 should be the first four-turn manual candidate")
    assertEquals(scenario.promotion.source, "manual_playtest_bastion_siege_walk", "P006 source mismatch")
    assertTrue(finisher and finisher.name == "Bastion" and finisher.currentHp == 4, "P006 should use a wounded Bastion as finisher")
    assertTrue(decoy and decoy.name == "Earthstalker" and decoy.currentHp == 1, "P006 should include the 1 HP Earthstalker decoy")
    assertTrue(reserve and reserve.name == "Crusher", "P006 should include the Crusher reserve tempo sink")
    assertTrue(hunter and hunter.name == "Crusher", "P006 must include active Red Crusher pressure")
    assertTrue(hunter.row == 5 and hunter.col == 7, "P006 Red Crusher should guard the first Bastion lane")
    assertTrue(battery and battery.name == "Artillery" and battery.row == 6 and battery.col == 1, "P006 must include active Red Artillery pressure")
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 2) == nil, "Bastion must not start with a Commandant hit")
    assertTrue(findAction(state, "move", "blue_finisher", 5, 8) ~= nil, "Bastion first three-step siege move should be legal")
    assertTrue(findAction(state, "move", "blue_reserve", 7, 1) ~= nil, "reserve should be a legal but non-finishing second-action outlet")
    assertTrue(findAction(state, "move", "blue_decoy", 6, 5) == nil, "decoy should not be able to enter the lure lane on turn one")
    assertTrue(findAction(state, "move", "blue_decoy", 8, 5) ~= nil, "decoy sideways staging step should be legal")
end)

runTest("p006_false_walk_without_decoy_gets_bastion_caught", function()
    local scenario = loadScenario("scenarios/P006.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "move", "blue_finisher", 5, 8)
    falseLine = doAction(falseLine, "move", "blue_decoy", 8, 5)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    local _, finisher = findUnitIndex(falseLine, "blue_finisher")
    local _, reserve = findUnitIndex(falseLine, "blue_reserve")
    assertTrue(finisher ~= nil and finisher.currentHp == 2, "Red should hit the wounded Bastion on the first handoff")
    assertTrue(reserve ~= nil and reserve.currentHp == 3, "Red battery should also pressure the reserve on the first handoff")

    falseLine = doAction(falseLine, "move", "blue_finisher", 2, 8)
    falseLine = doAction(falseLine, "move", "blue_decoy", 8, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    _, finisher = findUnitIndex(falseLine, "blue_finisher")
    assertTrue(finisher ~= nil and finisher.currentHp == 2, "without the decoy, Red should stay close to the Bastion lane")

    falseLine = doAction(falseLine, "move", "blue_finisher", 2, 5)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    assertTrue(findUnitIndex(falseLine, "blue_finisher") == nil, "Red should catch and destroy Bastion before the final attack")
end)

runTest("p006_bastion_cannot_finish_before_blue_turn_four", function()
    local scenario = loadScenario("scenarios/P006.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_finisher", 5, 8)
    state = doAction(state, "move", "blue_decoy", 8, 5)
    state = passRedTurn(state)

    state = doAction(state, "move", "blue_finisher", 2, 8)
    state = doAction(state, "move", "blue_decoy", 6, 5)
    state = passRedTurn(state)

    state = doAction(state, "move", "blue_finisher", 2, 5)
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 2) == nil, "Bastion at E2 should still be one tempo short")
    assertEquals(outcome(state), "ongoing", "P006 should not be solved on Blue turn three even if Red passes")
end)

runTest("p006_intended_four_turn_bastion_siege_walk_wins", function()
    local scenario = loadScenario("scenarios/P006.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_finisher", 5, 8) -- H8 -> H5
    state = doAction(state, "move", "blue_decoy", 8, 5) -- C8 -> E8
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    local _, reserve = findUnitIndex(state, "blue_reserve")
    assertTrue(finisher ~= nil and finisher.currentHp == 2, "first Red hit should wound but not stop Bastion")
    assertTrue(reserve ~= nil and reserve.currentHp == 3, "Red battery should make the reserve flank active")

    state = doAction(state, "move", "blue_finisher", 2, 8) -- H5 -> H2
    state = doAction(state, "move", "blue_decoy", 6, 5) -- E8 -> E6
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "blue_decoy") == nil, "Red should take the 1 HP decoy")
    local _, hunter = findUnitIndex(state, "red_hunter")
    assertTrue(hunter ~= nil and hunter.row == 6 and hunter.col == 5, "Red Crusher should be pulled off the Bastion lane")

    state = doAction(state, "move", "blue_finisher", 2, 5) -- H2 -> E2
    state = doAction(state, "move", "blue_reserve", 7, 1) -- A8 -> A7
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    _, finisher = findUnitIndex(state, "blue_finisher")
    _, reserve = findUnitIndex(state, "blue_reserve")
    assertTrue(finisher ~= nil and finisher.row == 2 and finisher.col == 5 and finisher.currentHp == 2, "Bastion should survive to the final staging cell")
    assertTrue(reserve ~= nil and reserve.currentHp == 2, "Red battery should keep the reserve under real pressure")

    state = doAction(state, "move", "blue_finisher", 2, 2) -- E2 -> B2
    state = doAction(state, "attack", "blue_finisher", 1, 2) -- B2 x B1
    assertEquals(outcome(state), "blue_win", "P006 intended Bastion siege walk should destroy Commandant")
end)

runTest("p007_material_has_shutter_shot_los_gate", function()
    local scenario = loadScenario("scenarios/P007.lua")
    local state = scenarioToState(scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    local _, opener = findUnitIndex(state, "blue_opener")
    local _, interposer = findUnitIndex(state, "blue_interposer")
    local _, reserve = findUnitIndex(state, "blue_reserve")
    local _, hunter = findUnitIndex(state, "red_hunter")
    local _, battery = findUnitIndex(state, "red_battery")
    local _, falseLure = findUnitIndex(state, "red_false_lure")
    local _, lureScreen = findUnitIndex(state, "red_lure_screen")
    local _, screen = findUnitIndex(state, "neutral_screen")

    assertEquals(scenario.id, "P007", "P007 id mismatch")
    assertEquals(scenario.name, "Scenario P007", "P007 public name should stay numeric")
    assertEquals(scenario.turnLimitRounds, 3, "P007 should be a three-turn shutter shot")
    assertEquals(scenario.promotion.source, "manual_playtest_shutter_shot", "P007 source mismatch")
    assertTrue(finisher and finisher.name == "Cloudstriker" and finisher.currentHp == 2, "P007 should use a wounded Cloudstriker finisher")
    assertTrue(opener and opener.name == "Artillery" and opener.currentHp == 1, "P007 should use a fragile Artillery opener")
    assertTrue(interposer and interposer.name == "Wingstalker" and interposer.currentHp == 1, "P007 should include the exported 1 HP Wingstalker interposer")
    assertTrue(reserve and reserve.name == "Crusher", "P007 should include the reserve flank")
    assertTrue(hunter and hunter.name == "Crusher" and hunter.row == 4 and hunter.col == 6, "P007 should include active Red Crusher pressure")
    assertTrue(battery and battery.name == "Artillery" and battery.row == 5 and battery.col == 1, "P007 should include active Red Artillery pressure")
    assertTrue(falseLure and falseLure.name == "Cloudstriker" and falseLure.row == 7 and falseLure.col == 2 and falseLure.currentHp == 2, "P007 should include the Red Cloudstriker false lure")
    assertTrue(lureScreen and lureScreen.name == "Rock" and lureScreen.player == 0 and lureScreen.row == 7 and lureScreen.col == 4, "P007 should screen the lure so it stays a temptation")
    assertTrue(screen and screen.name == "Rock" and screen.currentHp == 4, "P007 should include a 4 HP line-of-sight screen")
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 2) == nil, "Cloudstriker must not start with a Commandant shot")
    assertTrue(findAction(state, "attack", "blue_opener", 1, 4) ~= nil, "Artillery should be able to open the shutter")
    assertTrue(findAction(state, "move", "blue_interposer", 4, 5) ~= nil, "Wingstalker interposition should be legal")
end)

runTest("p007_false_wingstalker_chase_loses_the_shutter", function()
    local scenario = loadScenario("scenarios/P007.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_opener", 1, 4)
    falseLine = doAction(falseLine, "move", "blue_interposer", 7, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    assertTrue(findUnitIndex(falseLine, "blue_opener") == nil, "chasing the Red Cloudstriker lure should leave Artillery exposed")
    local _, interposer = findUnitIndex(falseLine, "blue_interposer")
    assertTrue(interposer ~= nil and interposer.row == 7 and interposer.col == 3, "wrong Wingstalker move should look materially promising but miss the shutter square")
    local _, screen = findUnitIndex(falseLine, "neutral_screen")
    assertTrue(screen ~= nil and screen.currentHp == 2, "wrong Wingstalker move should leave the Rock still blocking the line")
end)

runTest("p007_false_shoot_without_interpose_loses_opener", function()
    local scenario = loadScenario("scenarios/P007.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_opener", 1, 4)
    falseLine = doAction(falseLine, "move", "blue_reserve", 7, 1)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    assertTrue(findUnitIndex(falseLine, "blue_opener") == nil, "without interposition, Red should destroy the 1 HP Artillery opener")
    local _, screen = findUnitIndex(falseLine, "neutral_screen")
    assertTrue(screen ~= nil and screen.currentHp == 2, "false line should leave the Rock half-open but still blocking")
    assertTrue(findAction(falseLine, "attack", "blue_finisher", 1, 2) == nil, "Cloudstriker should still have no line through the Rock")
end)

runTest("p007_cloudstriker_cannot_finish_before_blue_turn_three", function()
    local scenario = loadScenario("scenarios/P007.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 1, 4)
    state = doAction(state, "move", "blue_interposer", 4, 5)
    state = passRedTurn(state)

    state = doAction(state, "attack", "blue_opener", 1, 4)
    state = doAction(state, "move", "blue_reserve", 7, 1)
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 2) == nil, "Cloudstriker at H1 should still be one move short")
    assertEquals(outcome(state), "ongoing", "P007 should not be solved before Blue turn three")
end)

runTest("p007_false_hope_wrong_cloudstriker_square_is_out_of_range", function()
    local scenario = loadScenario("scenarios/P007.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 1, 4)
    state = doAction(state, "move", "blue_interposer", 4, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)

    state = doAction(state, "attack", "blue_opener", 1, 4)
    state = doAction(state, "move", "blue_reserve", 7, 1)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "neutral_screen") == nil, "false hope setup should really open the line")

    state = doAction(state, "move", "blue_finisher", 1, 6) -- H1 -> F1
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 2) == nil, "Cloudstriker at F1 should look aligned but be out of range")
    assertEquals(outcome(state), "ongoing", "wrong firing square should not solve P007")
end)

runTest("p007_intended_three_turn_shutter_shot_wins", function()
    local scenario = loadScenario("scenarios/P007.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_opener", 1, 4) -- D4 x D1 Rock
    state = doAction(state, "move", "blue_interposer", 4, 5) -- E7 -> E4
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "blue_interposer") == nil, "Red should take the interposer shutter")
    local _, opener = findUnitIndex(state, "blue_opener")
    local _, reserve = findUnitIndex(state, "blue_reserve")
    local _, hunter = findUnitIndex(state, "red_hunter")
    assertTrue(opener ~= nil, "interposition should preserve Artillery for the second Rock shot")
    assertTrue(reserve ~= nil and reserve.currentHp == 3, "Red battery should pressure the reserve on turn one")
    assertTrue(hunter ~= nil and hunter.row == 4 and hunter.col == 5, "Red Crusher should capture the interposition square")

    state = doAction(state, "attack", "blue_opener", 1, 4) -- D4 x D1 Rock
    state = doAction(state, "move", "blue_reserve", 7, 1) -- A8 -> A7
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "neutral_screen") == nil, "second Artillery shot should clear the line-of-sight Rock")
    assertTrue(findUnitIndex(state, "blue_opener") == nil, "Red should destroy Artillery only after it has opened the shutter")
    _, reserve = findUnitIndex(state, "blue_reserve")
    assertTrue(reserve ~= nil and reserve.currentHp == 2, "Red battery should keep the reserve flank active")

    state = doAction(state, "move", "blue_finisher", 1, 5) -- H1 -> E1
    state = doAction(state, "attack", "blue_finisher", 1, 2) -- E1 x B1
    assertEquals(outcome(state), "blue_win", "P007 intended shutter shot should destroy Commandant")
end)

runTest("p008_material_has_crossfire_relay", function()
    local scenario = loadScenario("scenarios/P008.lua")
    local state = scenarioToState(scenario)
    local _, crusher = findUnitIndex(state, "blue_crusher")
    local _, artillery = findUnitIndex(state, "blue_artillery")
    local _, cloud = findUnitIndex(state, "blue_cloud")
    local _, stalker = findUnitIndex(state, "blue_stalker")
    local _, wing = findUnitIndex(state, "blue_wing")
    local _, commandant = findUnitIndex(state, "red_commandant")
    local _, redCloud = findUnitIndex(state, "red_cloud")
    local _, hunter = findUnitIndex(state, "red_hunter")
    local _, battery = findUnitIndex(state, "red_battery")

    assertEquals(scenario.id, "P008", "P008 id mismatch")
    assertEquals(scenario.name, "Scenario P008", "P008 public name should stay numeric")
    assertEquals(scenario.turnLimitRounds, 4, "P008 should be a four-turn crossfire relay")
    assertEquals(scenario.promotion.source, "manual_playtest_crossfire_relay", "P008 source mismatch")
    assertTrue(crusher and crusher.name == "Crusher" and crusher.row == 6 and crusher.col == 3, "P008 should use a late Crusher finisher")
    assertTrue(artillery and artillery.name == "Artillery" and artillery.row == 2 and artillery.col == 5 and artillery.currentHp == 1, "P008 should use a doomed 1 HP Artillery opener")
    assertTrue(cloud and cloud.name == "Cloudstriker" and cloud.row == 5 and cloud.col == 5 and cloud.currentHp == 3, "P008 should use a Cloudstriker relay hit")
    assertTrue(stalker and stalker.name == "Earthstalker" and stalker.row == 4 and stalker.col == 4, "P008 should use an Earthstalker hunter answer")
    assertTrue(wing and wing.name == "Wingstalker" and wing.row == 6 and wing.col == 6, "P008 should include the tempting Wingstalker anti-air line")
    assertTrue(commandant and commandant.row == 2 and commandant.col == 2 and commandant.currentHp == 9, "P008 Commandant should require the 2+3+4 relay")
    assertTrue(redCloud and redCloud.name == "Cloudstriker" and redCloud.row == 4 and redCloud.col == 5 and redCloud.currentHp == 2, "P008 should include the Red flyer temptation")
    assertTrue(hunter and hunter.name == "Crusher" and hunter.row == 5 and hunter.col == 4 and hunter.currentHp == 4, "P008 should include a real Red hunter")
    assertTrue(battery and battery.name == "Artillery" and battery.row == 2 and battery.col == 8, "P008 should include the Red battery")
    assertTrue(findAction(state, "attack", "blue_artillery", 2, 2) ~= nil, "Artillery should start with a legal Commandant shot")
    assertTrue(findAction(state, "attack", "blue_stalker", 5, 4) ~= nil, "Earthstalker should be able to remove the Red hunter immediately")
    assertTrue(findAction(state, "move", "blue_wing", 4, 6) ~= nil, "Wingstalker should have a tempting first-turn flyer chase")
end)

runTest("p008_false_save_artillery_first_loses_both_relay_pieces", function()
    local scenario = loadScenario("scenarios/P008.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "move", "blue_wing", 4, 6)
    falseLine = doAction(falseLine, "attack", "blue_wing", 4, 5)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    assertTrue(findUnitIndex(falseLine, "blue_artillery") == nil, "saving Artillery from the flyer should still lose it to Red battery")
    assertTrue(findUnitIndex(falseLine, "blue_cloud") == nil, "spending turn one on the flyer should let Red hunter kill the Cloudstriker relay")
    local _, hunter = findUnitIndex(falseLine, "red_hunter")
    assertTrue(hunter ~= nil and hunter.row == 5 and hunter.col == 5, "Red hunter should capture the Cloudstriker square")
    assertEquals(commandantHp(falseLine), 9, "false save should make no Commandant progress")
end)

runTest("p008_false_rush_crusher_before_clearing_hunter_loses_cloud", function()
    local scenario = loadScenario("scenarios/P008.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_artillery", 2, 2)
    falseLine = doAction(falseLine, "move", "blue_crusher", 4, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    local _, hunter = findUnitIndex(falseLine, "red_hunter")
    assertTrue(findUnitIndex(falseLine, "blue_cloud") == nil, "rushing Crusher should let Red hunter kill the Cloudstriker relay")
    assertTrue(hunter ~= nil and hunter.row == 5 and hunter.col == 5, "Red hunter should still be alive after the rushed line")
    assertEquals(commandantHp(falseLine), 7, "rushed line should have only the Artillery damage")
end)

runTest("p008_intended_four_turn_crossfire_relay_wins", function()
    local scenario = loadScenario("scenarios/P008.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_artillery", 2, 2)
    state = doAction(state, "attack", "blue_stalker", 5, 4)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertEquals(commandantHp(state), 7, "Artillery should supply the opening 2 damage")
    assertTrue(findUnitIndex(state, "blue_artillery") == nil, "Red should remove Artillery after it fires")
    assertTrue(findUnitIndex(state, "red_hunter") == nil, "Earthstalker should remove the Red hunter on turn one")
    local _, redCloud = findUnitIndex(state, "red_cloud")
    assertTrue(redCloud ~= nil and redCloud.row == 2 and redCloud.col == 5, "Red flyer should take the Cloudstriker firing lane")

    state = doAction(state, "attack", "blue_cloud", 2, 5)
    state = doAction(state, "move", "blue_crusher", 4, 3)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "red_cloud") == nil, "Cloudstriker should remove the Red flyer on turn two")
    local _, crusher = findUnitIndex(state, "blue_crusher")
    assertTrue(crusher ~= nil and crusher.row == 4 and crusher.col == 3, "Crusher should reach the staging square")

    state = doAction(state, "move", "blue_cloud", 2, 5)
    state = doAction(state, "attack", "blue_cloud", 2, 2)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertEquals(commandantHp(state), 4, "Cloudstriker should supply the middle 3 damage")
    local _, cloud = findUnitIndex(state, "blue_cloud")
    assertTrue(cloud ~= nil and cloud.row == 2 and cloud.col == 5 and cloud.currentHp == 2, "Cloudstriker should survive Red battery damage after its relay shot")

    state = doAction(state, "move", "blue_crusher", 2, 3)
    state = doAction(state, "attack", "blue_crusher", 2, 2)
    assertEquals(outcome(state), "blue_win", "P008 intended crossfire relay should destroy Commandant")
end)

runTest("p009_material_has_capture_ladder", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)
    local _, crusher = findUnitIndex(state, "blue_crusher")
    local _, stalker = findUnitIndex(state, "blue_stalker")
    local _, wing = findUnitIndex(state, "blue_wing")
    local _, sideBattery = findUnitIndex(state, "blue_side_battery")
    local _, commandant = findUnitIndex(state, "red_commandant")
    local _, step1 = findUnitIndex(state, "red_step1")
    local _, step2 = findUnitIndex(state, "red_step2")
    local _, cloud = findUnitIndex(state, "red_cloud")
    local _, hunter = findUnitIndex(state, "red_hunter")

    assertEquals(scenario.id, "P009", "P009 id mismatch")
    assertEquals(scenario.name, "Scenario P009", "P009 public name should stay numeric")
    assertEquals(scenario.turnLimitRounds, 4, "P009 should be a four-turn capture ladder")
    assertEquals(scenario.promotion.source, "manual_playtest_capture_ladder", "P009 source mismatch")
    assertTrue(crusher and crusher.name == "Crusher" and crusher.row == 7 and crusher.col == 3, "P009 should use Crusher as the capture-ladder finisher")
    assertTrue(stalker and stalker.name == "Earthstalker" and stalker.row == 4 and stalker.col == 5, "P009 should include the hunter answer")
    assertTrue(wing and wing.name == "Wingstalker" and wing.row == 6 and wing.col == 7, "P009 should include delayed anti-air")
    assertTrue(sideBattery and sideBattery.name == "Artillery" and sideBattery.row == 3 and sideBattery.col == 1, "P009 should include the side battery chip")
    assertTrue(commandant and commandant.row == 1 and commandant.col == 3 and commandant.currentHp == 4, "P009 Commandant should require Crusher damage")
    assertTrue(step1 and step1.row == 6 and step1.col == 3 and step1.currentHp == 3, "P009 should include the first capture step")
    assertTrue(step2 and step2.row == 3 and step2.col == 3 and step2.currentHp == 4, "P009 should include the reinforced second capture step")
    assertTrue(cloud and cloud.row == 6 and cloud.col == 6 and cloud.currentHp == 2, "P009 should include the delayed Red flyer pressure")
    assertTrue(hunter and hunter.row == 4 and hunter.col == 6 and hunter.currentHp == 4, "P009 should include the adjacent hunter false-choice pressure")
    assertTrue(findAction(state, "attack", "blue_crusher", 6, 3) ~= nil, "Crusher should start with a capture")
    assertTrue(findAction(state, "move", "blue_stalker", 3, 5) ~= nil, "Earthstalker should be able to step into the hunter decoy square")
    assertTrue(findAction(state, "attack", "blue_stalker", 4, 6) ~= nil, "Earthstalker should have a tempting adjacent hunter kill")
    assertTrue(findAction(state, "attack", "blue_wing", 6, 6) ~= nil, "Wingstalker should have the tempting flyer kill")
    assertTrue(findAction(state, "move", "blue_wing", 3, 7) ~= nil, "Wingstalker should be able to become the hunter decoy")
    assertTrue(findAction(state, "attack", "blue_side_battery", 3, 3) ~= nil, "Side battery should threaten the second step")
end)

runTest("p009_false_kill_flyer_on_turn_two_lets_hunter_finish_crusher", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_crusher", 6, 3)
    falseLine = doAction(falseLine, "move", "blue_stalker", 3, 5)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    falseLine = doAction(falseLine, "attack", "blue_wing", 6, 6)
    falseLine = doAction(falseLine, "move", "blue_crusher", 4, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    falseLine = doAction(falseLine, "attack", "blue_side_battery", 3, 3)
    falseLine = doAction(falseLine, "attack", "blue_crusher", 3, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    assertTrue(findUnitIndex(falseLine, "blue_crusher") == nil, "killing the flyer should leave the hunter free to finish Crusher")
end)

runTest("p009_false_take_adjacent_hunter_kill_loses_side_battery", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_crusher", 6, 3)
    falseLine = doAction(falseLine, "attack", "blue_stalker", 4, 6)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    local _, sideBattery = findUnitIndex(falseLine, "blue_side_battery")
    assertTrue(sideBattery ~= nil and sideBattery.currentHp == 2, "taking the adjacent hunter kill should expose the side battery")
    local _, step2 = findUnitIndex(falseLine, "red_step2")
    assertTrue(step2 ~= nil and step2.row == 3 and step2.col == 2, "Red second step should leave the ladder to pressure the battery")

    falseLine = doAction(falseLine, "attack", "blue_wing", 6, 6)
    falseLine = doAction(falseLine, "move", "blue_crusher", 4, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    assertTrue(findUnitIndex(falseLine, "blue_side_battery") == nil, "the wrong first-turn kill should lose the timed battery chip")
end)

runTest("p009_false_ignore_flyer_on_turn_two_loses_crusher", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_crusher", 6, 3)
    falseLine = doAction(falseLine, "move", "blue_stalker", 3, 5)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    falseLine = doAction(falseLine, "move", "blue_crusher", 4, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    local _, crusher = findUnitIndex(falseLine, "blue_crusher")
    assertTrue(crusher ~= nil and crusher.currentHp == 1, "Red second step should wound Crusher to 1 HP")

    falseLine = doAction(falseLine, "attack", "blue_side_battery", 3, 3)
    falseLine = doAction(falseLine, "attack", "blue_crusher", 3, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    assertTrue(findUnitIndex(falseLine, "blue_crusher") == nil, "ignoring the flyer should let it kill Crusher before the final attack")
end)

runTest("p009_false_three_turn_shortcut_no_longer_captures_second_step", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_crusher", 6, 3)
    falseLine = doAction(falseLine, "attack", "blue_wing", 6, 6)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    falseLine = doAction(falseLine, "move", "blue_crusher", 4, 3)
    local shortcutAttack = findAction(falseLine, "attack", "blue_crusher", 3, 3)
    if shortcutAttack ~= nil then
        falseLine = doAction(falseLine, "attack", "blue_crusher", 3, 3)
        local _, crusher = findUnitIndex(falseLine, "blue_crusher")
        local _, step2 = findUnitIndex(falseLine, "red_step2")
        assertTrue(crusher ~= nil and crusher.row == 4 and crusher.col == 3, "shortcut Crusher should not capture the reinforced second step")
        assertTrue(step2 ~= nil and step2.row == 3 and step2.col == 3 and step2.currentHp == 1, "reinforced second step should survive the shortcut attack")
    else
        assertTrue(true, "shortcut attack is already denied by Red's reply")
    end

    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    assertTrue(outcome(falseLine) ~= "blue_win", "three-turn shortcut should not win after the reinforced second step")
end)

runTest("p009_false_fire_side_battery_early_loses_ladder_timing", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "attack", "blue_crusher", 6, 3)
    falseLine = doAction(falseLine, "attack", "blue_side_battery", 3, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    assertTrue(findUnitIndex(falseLine, "blue_stalker") == nil, "early battery shot should leave the hunter free to kill Earthstalker")

    falseLine = doAction(falseLine, "move", "blue_crusher", 4, 3)
    falseLine = doAction(falseLine, "attack", "blue_crusher", 3, 3)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)
    assertTrue(findUnitIndex(falseLine, "blue_crusher") == nil, "early battery shortcut should let Red flyers collapse the ladder")
end)

runTest("p009_turn_two_battery_and_wing_decoy_pulls_hunter_off_ladder", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_crusher", 6, 3)
    state = doAction(state, "move", "blue_stalker", 3, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)

    state = doAction(state, "attack", "blue_side_battery", 3, 3)
    state = doAction(state, "move", "blue_wing", 3, 7)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)

    assertTrue(findUnitIndex(state, "blue_wing") == nil, "Wingstalker decoy should be sacrificed on G3")
    local _, hunter = findUnitIndex(state, "red_hunter")
    assertTrue(hunter ~= nil and hunter.row == 3 and hunter.col == 7, "hunter should be pulled away from the C-file ladder")
    local _, step2 = findUnitIndex(state, "red_step2")
    assertTrue(step2 ~= nil and step2.currentHp == 3, "turn-two battery shot should prepare the second step")
end)

runTest("p009_intended_four_turn_capture_ladder_wins", function()
    local scenario = loadScenario("scenarios/P009.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "attack", "blue_crusher", 6, 3)
    state = doAction(state, "move", "blue_stalker", 3, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    local _, crusher = findUnitIndex(state, "blue_crusher")
    assertTrue(crusher ~= nil and crusher.row == 6 and crusher.col == 3 and crusher.currentHp == 4, "Crusher should capture the first ladder step")
    assertTrue(findUnitIndex(state, "blue_stalker") == nil, "Red hunter should take Earthstalker after its decoy move")

    state = doAction(state, "attack", "blue_side_battery", 3, 3)
    state = doAction(state, "move", "blue_wing", 3, 7)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "blue_wing") == nil, "Wingstalker should pull the hunter away on turn two")
    local _, hunter = findUnitIndex(state, "red_hunter")
    assertTrue(hunter ~= nil and hunter.row == 3 and hunter.col == 7, "hunter should end on the Wingstalker decoy square")
    local _, step2 = findUnitIndex(state, "red_step2")
    assertTrue(step2 ~= nil and step2.row == 3 and step2.col == 3 and step2.currentHp == 3, "side battery should prepare the reinforced second step early")

    state = doAction(state, "move", "blue_crusher", 4, 3)
    state = doAction(state, "attack", "blue_crusher", 3, 3)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    _, crusher = findUnitIndex(state, "blue_crusher")
    assertTrue(crusher ~= nil and crusher.row == 3 and crusher.col == 3 and crusher.currentHp == 2, "Crusher should capture the second ladder step and survive Cloudstriker damage")

    state = doAction(state, "move", "blue_crusher", 2, 3)
    state = doAction(state, "attack", "blue_crusher", 1, 3)
    assertEquals(outcome(state), "blue_win", "P009 intended capture ladder should destroy Commandant")
end)

runTest("p010_material_has_gate_march", function()
    local scenario = loadScenario("scenarios/P010.lua")
    local state = scenarioToState(scenario)
    local _, breaker = findUnitIndex(state, "blue_breaker")
    local _, finisher = findUnitIndex(state, "blue_finisher")
    local _, decoy = findUnitIndex(state, "blue_decoy")
    local _, screen = findUnitIndex(state, "blue_screen")
    local _, commandant = findUnitIndex(state, "red_commandant")
    local _, gate = findUnitIndex(state, "neutral_gate")
    local _, lineScreen = findUnitIndex(state, "neutral_screen")
    local _, sniperScreen = findUnitIndex(state, "neutral_sniper_screen")
    local _, hunter = findUnitIndex(state, "red_hunter")
    local _, sniper = findUnitIndex(state, "red_sniper")

    assertEquals(scenario.id, "P010", "P010 id mismatch")
    assertEquals(scenario.name, "Scenario P010", "P010 public name should stay numeric")
    assertEquals(scenario.turnLimitRounds, 5, "P010 should be a five-turn gate march")
    assertEquals(scenario.promotion.source, "manual_playtest_gate_march", "P010 source mismatch")
    assertTrue(breaker and breaker.name == "Artillery" and breaker.row == 8 and breaker.col == 4, "P010 should use Artillery on the D-file as the gate breaker")
    assertTrue(finisher and finisher.name == "Cloudstriker" and finisher.row == 1 and finisher.col == 8 and finisher.currentHp == 4, "P010 should use Cloudstriker finisher from H1")
    assertTrue(decoy and decoy.name == "Bastion" and decoy.row == 4 and decoy.col == 6 and decoy.currentHp == 2, "P010 should include staged Bastion screen")
    assertTrue(screen and screen.name == "Wingstalker" and screen.row == 8 and screen.col == 5, "P010 should include first screen")
    assertTrue(commandant and commandant.row == 1 and commandant.col == 2 and commandant.currentHp == 3, "P010 Commandant should need Cloudstriker damage")
    assertTrue(gate and gate.name == "Rock" and gate.row == 1 and gate.col == 4 and gate.currentHp == 2, "P010 should include the D1 gate")
    assertTrue(lineScreen and lineScreen.name == "Rock" and lineScreen.row == 3 and lineScreen.col == 5 and lineScreen.currentHp == 5, "P010 should include the E3 line screen")
    assertTrue(sniperScreen and sniperScreen.name == "Rock" and sniperScreen.row == 1 and sniperScreen.col == 6 and sniperScreen.currentHp == 5, "P010 should include the F1 sniper screen")
    assertTrue(hunter and hunter.name == "Crusher" and hunter.row == 7 and hunter.col == 5, "P010 should include the melee hunter")
    assertTrue(sniper and sniper.name == "Cloudstriker" and sniper.row == 4 and sniper.col == 5 and sniper.currentHp == 3, "P010 should include the wounded line sniper")
    assertTrue(findAction(state, "move", "blue_breaker", 7, 4) ~= nil, "Artillery should start its D-file march")
    assertTrue(findAction(state, "move", "blue_decoy", 7, 6) ~= nil, "Bastion should be able to stage for turn two")
    assertTrue(findAction(state, "attack", "blue_decoy", 4, 5) ~= nil, "Bastion should have a tempting adjacent sniper hit")
    assertTrue(findAction(state, "move", "blue_finisher", 1, 5) ~= nil, "Cloudstriker should have the final firing square")
end)

runTest("p010_false_skip_bastion_stage_cannot_make_turn_two_screen", function()
    local scenario = loadScenario("scenarios/P010.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "move", "blue_breaker", 7, 4)
    falseLine = doAction(falseLine, "move", "blue_finisher", 1, 5)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    assertTrue(findAction(falseLine, "move", "blue_decoy", 8, 6) == nil, "unstaged Bastion should not reach the second screen square")
end)

runTest("p010_false_hit_adjacent_sniper_loses_bastion_screen", function()
    local scenario = loadScenario("scenarios/P010.lua")
    local state = scenarioToState(scenario)

    local falseLine = doAction(state, "move", "blue_breaker", 7, 4)
    falseLine = doAction(falseLine, "attack", "blue_decoy", 4, 5)
    falseLine = endBlueTurnThroughScenarioRedPolicy(falseLine, scenario)

    local _, sniper = findUnitIndex(falseLine, "red_sniper")
    assertTrue(sniper ~= nil and sniper.currentHp == 2, "Bastion hit should wound but not remove the sniper")
    assertTrue(findAction(falseLine, "move", "blue_decoy", 8, 6) == nil, "Bastion should lose the two-turn screen route after attacking sniper")
end)

runTest("p010_false_wait_on_turn_four_leaves_gate_alive", function()
    local scenario = loadScenario("scenarios/P010.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_breaker", 7, 4)
    state = doAction(state, "move", "blue_decoy", 7, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    state = doAction(state, "move", "blue_breaker", 6, 4)
    state = doAction(state, "move", "blue_decoy", 8, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    state = doAction(state, "move", "blue_breaker", 5, 4)
    state = doAction(state, "move", "blue_finisher", 1, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    state = doAction(state, "move", "blue_breaker", 4, 4)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)

    local _, gate = findUnitIndex(state, "neutral_gate")
    assertTrue(gate ~= nil and gate.currentHp == 2, "waiting on turn four should leave the gate alive")
    assertTrue(findAction(state, "attack", "blue_finisher", 1, 2) == nil, "live gate should still block the Cloudstriker finish")
end)

runTest("p010_intended_five_turn_gate_march_wins", function()
    local scenario = loadScenario("scenarios/P010.lua")
    local state = scenarioToState(scenario)

    state = doAction(state, "move", "blue_breaker", 7, 4)
    state = doAction(state, "move", "blue_decoy", 7, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "blue_screen") == nil, "Wingstalker should be the first screen")
    local _, hunter = findUnitIndex(state, "red_hunter")
    assertTrue(hunter ~= nil and hunter.row == 8 and hunter.col == 5, "Crusher should take the first screen")
    local _, sniper = findUnitIndex(state, "red_sniper")
    assertTrue(sniper ~= nil and sniper.row == 4 and sniper.col == 6, "sniper should take the Bastion firing lane")

    state = doAction(state, "move", "blue_breaker", 6, 4)
    state = doAction(state, "move", "blue_decoy", 8, 6)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    assertTrue(findUnitIndex(state, "blue_decoy") == nil, "Bastion should be the second screen")
    _, hunter = findUnitIndex(state, "red_hunter")
    assertTrue(hunter ~= nil and hunter.row == 8 and hunter.col == 6, "Crusher should be pulled to F8")
    _, sniper = findUnitIndex(state, "red_sniper")
    assertTrue(sniper ~= nil and sniper.row == 4 and sniper.col == 8, "sniper should keep chasing a firing lane")

    state = doAction(state, "move", "blue_breaker", 5, 4)
    state = doAction(state, "move", "blue_finisher", 1, 5)
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    local _, finisher = findUnitIndex(state, "blue_finisher")
    assertTrue(finisher ~= nil and finisher.row == 1 and finisher.col == 5, "Cloudstriker should wait on the firing square")
    _, sniper = findUnitIndex(state, "red_sniper")
    assertTrue(sniper ~= nil and sniper.row == 1 and sniper.col == 8, "F1 Rock should keep the sniper from shooting the finisher")

    state = doAction(state, "move", "blue_breaker", 4, 4)
    state = doAction(state, "attack", "blue_breaker", 1, 4)
    assertTrue(findUnitIndex(state, "neutral_gate") == nil, "Artillery should destroy the D1 gate")
    state = endBlueTurnThroughScenarioRedPolicy(state, scenario)
    local _, breaker = findUnitIndex(state, "blue_breaker")
    assertTrue(breaker ~= nil and breaker.currentHp == 5, "sniper screen should keep the breaker untouched")
    local _, sniperScreen = findUnitIndex(state, "neutral_sniper_screen")
    assertTrue(sniperScreen ~= nil and sniperScreen.currentHp == 2, "red sniper should spend its shot into the screen")

    state = doAction(state, "attack", "blue_finisher", 1, 2)
    assertEquals(outcome(state), "blue_win", "P010 intended gate march should destroy Commandant")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. ": " .. tostring(result.err))
    end
end

if passed ~= #results then
    error(string.format("%d/%d tests failed", #results - passed, #results), 0)
end

print(string.format("[PASS] scenario_manual_candidate_smoke.lua passed %d/%d tests", passed, #results))
