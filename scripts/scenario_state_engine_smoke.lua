package.path = package.path .. ";./?.lua"

local stateEngine = require("scenario_tooling.state_engine")

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = {name = name, ok = ok, err = err}
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

local function unit(id, name, player, row, col, hp, maxHp, extra)
    local out = {
        id = id,
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = maxHp or hp,
        hasMoved = false,
        hasActed = false,
        actionsUsed = 0,
        turnActions = {}
    }
    for key, value in pairs(extra or {}) do
        out[key] = value
    end
    return out
end

local function baseState()
    return {
        schema = "ScenarioState",
        board = {rows = 8, cols = 8},
        currentPlayer = 1,
        scenarioTurn = 1,
        turnLimit = 3,
        objectiveType = "destroy_commandant",
        supplyEnabled = false,
        units = {
            unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
            unit("blue_cloud", "Cloudstriker", 1, 6, 2, 4, 4),
            unit("red_bastion", "Bastion", 2, 4, 5, 6, 6),
            unit("red_commandant", "Commandant", 2, 1, 4, 6, 12),
            unit("neutral_rock", "Rock", 0, 6, 3, 5, 5)
        }
    }
end

local function actionKey(action)
    local to = action.to or action.targetCell or {}
    return table.concat({
        tostring(action.type or ""),
        tostring(action.actorId or ""),
        tostring(action.targetId or ""),
        tostring(to.row or ""),
        tostring(to.col or "")
    }, "|")
end

runTest("state_engine_is_scenario_only", function()
    assertTrue(stateEngine.isScenarioOnly() == true, "state engine should identify as scenario-only tooling")
end)

runTest("canonical_state_string_and_hash_are_deterministic", function()
    local state = baseState()
    local firstString = stateEngine.canonicalStateString(state)
    local secondString = stateEngine.canonicalStateString(stateEngine.cloneState(state))
    assertEquals(firstString, secondString, "canonical string should be stable")
    assertEquals(stateEngine.stateHash(state), stateEngine.stateHash(stateEngine.cloneState(state)), "hash should be stable")
end)

runTest("canonical_hash_includes_action_flags_and_hp", function()
    local state = baseState()
    local baseline = stateEngine.stateHash(state)

    local moved = stateEngine.cloneState(state)
    moved.units[1].hasMoved = true
    assertTrue(stateEngine.stateHash(moved) ~= baseline, "hasMoved must affect hash")

    local actionFlagged = stateEngine.cloneState(state)
    actionFlagged.units[1].turnActions.move = true
    assertTrue(stateEngine.stateHash(actionFlagged) ~= baseline, "turnActions map flags must affect hash")

    local damaged = stateEngine.cloneState(state)
    damaged.units[3].currentHp = 5
    assertTrue(stateEngine.stateHash(damaged) ~= baseline, "currentHp must affect hash")
end)

runTest("legal_actions_are_deterministic_and_action_shaped", function()
    local actionsA = stateEngine.getLegalActions(baseState())
    local actionsB = stateEngine.getLegalActions(baseState())
    assertTrue(#actionsA > 0, "legal actions expected")
    assertEquals(#actionsA, #actionsB, "action counts should match")
    for index, action in ipairs(actionsA) do
        assertEquals(actionKey(action), actionKey(actionsB[index]), "action order should be deterministic at index " .. tostring(index))
        assertTrue(type(action.id) == "string" and action.id ~= "", "action id required")
        assertTrue(action.legal == true, "action should be legal")
        if action.type == "move" then
            assertTrue(type(action.actorId) == "string", "move actorId required")
            assertTrue(type(action.from) == "table", "move from required")
            assertTrue(type(action.to) == "table", "move to required")
        elseif action.type == "attack" then
            assertTrue(type(action.actorId) == "string", "attack actorId required")
            assertTrue(type(action.targetId) == "string", "attack targetId required")
            assertTrue(type(action.targetCell) == "table", "attack targetCell required")
        elseif action.type == "end_turn" then
            assertEquals(action.actorId, nil, "end_turn has no actor")
        else
            error("unexpected action type " .. tostring(action.type))
        end
    end
end)

runTest("legal_actions_include_move_attack_and_end_turn", function()
    local actions = stateEngine.getLegalActions(baseState())
    local hasMove = false
    local hasAttack = false
    local hasEnd = false
    for _, action in ipairs(actions) do
        hasMove = hasMove or action.type == "move"
        hasAttack = hasAttack or action.type == "attack"
        hasEnd = hasEnd or action.type == "end_turn"
    end
    assertTrue(hasMove, "move action expected")
    assertTrue(hasAttack, "attack action expected")
    assertTrue(hasEnd, "end_turn action expected")
end)

runTest("apply_action_sets_hash_and_does_not_mutate_input", function()
    local state = baseState()
    local beforeHash = stateEngine.stateHash(state)
    local chosen = nil
    for _, action in ipairs(stateEngine.getLegalActions(state)) do
        if action.type == "move" then
            chosen = action
            break
        end
    end
    assertTrue(chosen ~= nil, "move action required")

    local nextState, result = stateEngine.applyAction(state, chosen)
    assertTrue(result.ok == true, tostring(result.reason))
    assertEquals(stateEngine.stateHash(state), beforeHash, "input state should not mutate")
    assertTrue(type(nextState.stateHash) == "string" and nextState.stateHash ~= "", "next state should carry stateHash")
    assertTrue(nextState.stateHash ~= beforeHash, "move should change state hash")
end)

runTest("apply_with_undo_restores_previous_state", function()
    local state = baseState()
    local beforeHash = stateEngine.stateHash(state)
    local chosen = nil
    for _, action in ipairs(stateEngine.getLegalActions(state)) do
        if action.type == "attack" then
            chosen = action
            break
        end
    end
    assertTrue(chosen ~= nil, "attack action required")

    local nextState, undo, result = stateEngine.applyActionWithUndo(state, chosen)
    assertTrue(result.ok == true, tostring(result.reason))
    assertTrue(stateEngine.stateHash(nextState) ~= beforeHash, "attack should change state")
    local restored = stateEngine.unapplyAction(nextState, undo)
    assertEquals(stateEngine.stateHash(restored), beforeHash, "undo should restore exact hash")
end)

runTest("move_preserves_later_attack_legality_for_same_unit", function()
    local state = {
        schema = "ScenarioState",
        board = {rows = 8, cols = 8},
        currentPlayer = 1,
        scenarioTurn = 1,
        turnLimit = 3,
        objectiveType = "destroy_commandant",
        supplyEnabled = false,
        units = {
            unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
            unit("red_commandant", "Commandant", 2, 4, 6, 6, 12)
        }
    }

    local nextState, result = stateEngine.applyAction(state, {
        type = "move",
        actorId = "blue_crusher",
        to = {row = 4, col = 5}
    })
    assertTrue(result.ok == true, tostring(result.reason))

    local hasFollowupAttack = false
    for _, action in ipairs(stateEngine.getLegalActions(nextState)) do
        if action.type == "attack" and action.actorId == "blue_crusher" and action.targetId == "red_commandant" then
            hasFollowupAttack = true
        end
    end
    assertTrue(hasFollowupAttack, "move must not consume attack in current rules")
end)

runTest("melee_destroying_attack_occupies_target_cell_but_ranged_does_not", function()
    local meleeState = {
        schema = "ScenarioState",
        board = {rows = 8, cols = 8},
        currentPlayer = 1,
        scenarioTurn = 1,
        turnLimit = 3,
        objectiveType = "destroy_commandant",
        supplyEnabled = false,
        units = {
            unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
            unit("red_bastion", "Bastion", 2, 4, 5, 2, 6),
            unit("red_commandant", "Commandant", 2, 1, 8, 12, 12)
        }
    }

    local nextMelee, meleeResult = stateEngine.applyAction(meleeState, {
        type = "attack",
        actorId = "blue_crusher",
        targetId = "red_bastion"
    })
    assertTrue(meleeResult.ok == true, tostring(meleeResult.reason))
    assertTrue(meleeResult.targetDestroyed == true, "melee target should be destroyed")
    assertEquals(nextMelee.units[1].row, 4, "melee attacker should keep target row")
    assertEquals(nextMelee.units[1].col, 5, "melee attacker should occupy target col")

    local rangedState = {
        schema = "ScenarioState",
        board = {rows = 8, cols = 8},
        currentPlayer = 1,
        scenarioTurn = 1,
        turnLimit = 3,
        objectiveType = "destroy_commandant",
        supplyEnabled = false,
        units = {
            unit("blue_cloud", "Cloudstriker", 1, 4, 1, 4, 4),
            unit("red_bastion", "Bastion", 2, 4, 4, 2, 6),
            unit("red_commandant", "Commandant", 2, 1, 8, 12, 12)
        }
    }

    local nextRanged, rangedResult = stateEngine.applyAction(rangedState, {
        type = "attack",
        actorId = "blue_cloud",
        targetId = "red_bastion"
    })
    assertTrue(rangedResult.ok == true, tostring(rangedResult.reason))
    assertTrue(rangedResult.targetDestroyed == true, "ranged target should be destroyed")
    assertEquals(nextRanged.units[1].row, 4, "ranged attacker should keep original row")
    assertEquals(nextRanged.units[1].col, 1, "ranged attacker should keep original col")
end)

runTest("state_engine_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/state_engine.lua", "r")
    assertTrue(file ~= nil, "state_engine.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "state engine must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "state engine must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "state engine must not depend on AI tournament modules")
    assertTrue(content:find("gameplay", 1, true) == nil, "state engine must not depend on gameplay")
    assertTrue(content:find("gameRuler", 1, true) == nil, "state engine must not depend on gameRuler")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. " -> " .. tostring(result.err))
    end
end

print(string.format("scenario_state_engine_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
