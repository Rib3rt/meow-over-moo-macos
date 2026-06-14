package.path = package.path .. ";./?.lua"

local rulesKernel = require("scenario_tooling.rules_kernel")

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

local function hasCell(cells, row, col)
    for _, cell in ipairs(cells or {}) do
        if tonumber(cell.row) == row and tonumber(cell.col) == col then
            return true
        end
    end
    return false
end

local function hasAction(actions, actionType, row, col)
    for _, action in ipairs(actions or {}) do
        if action.type == actionType then
            local target = action.to or action.targetCell or {}
            if tonumber(target.row) == row and tonumber(target.col) == col then
                return true
            end
        end
    end
    return false
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
        turnActions = {}
    }
    for key, value in pairs(extra or {}) do
        out[key] = value
    end
    return out
end

local function baseState(units, opts)
    opts = opts or {}
    return {
        schema = "ScenarioState",
        board = {rows = 8, cols = 8},
        currentPlayer = opts.currentPlayer or 1,
        scenarioTurn = opts.scenarioTurn or 1,
        turnLimit = opts.turnLimit or 3,
        maxActionsPerTurn = opts.maxActionsPerTurn or 2,
        objectiveType = "destroy_commandant",
        supplyEnabled = false,
        turnActions = opts.turnActions or 0,
        actionsUsed = opts.actionsUsed or opts.turnActions or 0,
        units = units
    }
end

runTest("rules_kernel_is_scenario_only", function()
    assertTrue(rulesKernel.isScenarioOnly() == true, "rules kernel should identify as scenario-only tooling")
end)

runTest("movement_matches_current_straight_line_rules", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_bastion", "Bastion", 1, 4, 4, 6, 6),
        unit("neutral_rock", "Rock", 0, 4, 5, 5, 5),
        unit("red_commandant", "Commandant", 2, 1, 4, 6, 12)
    }))

    local moves = rulesKernel.getLegalMoves(state, "blue_bastion")
    assertTrue(hasAction(moves, "move", 3, 4), "ground unit should move up")
    assertTrue(hasAction(moves, "move", 2, 4), "ground unit should move multiple cells in straight line")
    assertTrue(not hasAction(moves, "move", 4, 6), "ground unit should stop behind occupied cell")
    assertTrue(not hasAction(moves, "move", 3, 5), "movement should not be diagonal")
end)

runTest("unit_cannot_move_twice_but_can_attack_after_moving", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 4, 6, 4, 12)
    }))

    local movedState, moveResult = rulesKernel.applyAction(state, {
        type = "move",
        actorId = "blue_crusher",
        to = { row = 4, col = 5 }
    })

    assertTrue(moveResult.ok == true, tostring(moveResult.reason))
    assertEquals(#rulesKernel.getLegalMoves(movedState, "blue_crusher"), 0, "unit should not move twice in one turn")
    local attacks = rulesKernel.getLegalAttacks(movedState, "blue_crusher")
    assertTrue(hasAction(attacks, "attack", 4, 6), "unit should still be able to attack after moving")
end)

runTest("flying_movement_can_pass_blockers_but_not_land_on_them", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_wing", "Wingstalker", 1, 4, 4, 3, 3),
        unit("neutral_rock", "Rock", 0, 4, 5, 5, 5),
        unit("red_commandant", "Commandant", 2, 1, 4, 6, 12)
    }))

    local moves = rulesKernel.getLegalMoves(state, "blue_wing")
    assertTrue(not hasAction(moves, "move", 4, 5), "flying unit cannot land on occupied cell")
    assertTrue(hasAction(moves, "move", 4, 6), "flying unit can pass over occupied cell")
end)

runTest("line_of_sight_and_attack_rules_match_cloudstriker_and_artillery", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_cloud", "Cloudstriker", 1, 4, 1, 4, 4),
        unit("blue_artillery", "Artillery", 1, 5, 1, 5, 5),
        unit("neutral_rock", "Rock", 0, 4, 2, 5, 5),
        unit("red_bastion", "Bastion", 2, 4, 3, 6, 6),
        unit("red_commandant", "Commandant", 2, 1, 4, 6, 12)
    }))

    assertTrue(not rulesKernel.hasLineOfSight(state, {row = 4, col = 1}, {row = 4, col = 3}, {name = "Cloudstriker"}), "Cloudstriker LOS should be blocked by Rock")
    assertTrue(rulesKernel.hasLineOfSight(state, {row = 5, col = 1}, {row = 5, col = 4}, {name = "Artillery"}), "Artillery LOS should ignore blockers")

    local cloudAttacks = rulesKernel.getLegalAttacks(state, "blue_cloud")
    assertTrue(not hasAction(cloudAttacks, "attack", 4, 3), "Cloudstriker should not attack through Rock")

    local artilleryAttacks = rulesKernel.getLegalAttacks(state, "blue_artillery")
    assertTrue(hasAction(artilleryAttacks, "attack", 4, 1) == false, "Artillery should not attack diagonally")
    assertTrue(hasAction(artilleryAttacks, "attack", 5, 4) == false, "No target means no attack")
end)

runTest("artillery_can_attack_through_units_and_rocks_orthogonally", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_artillery", "Artillery", 1, 4, 1, 5, 5),
        unit("neutral_rock", "Rock", 0, 4, 2, 5, 5),
        unit("red_bastion", "Bastion", 2, 4, 3, 6, 6),
        unit("red_commandant", "Commandant", 2, 1, 4, 6, 12)
    }))

    local attacks = rulesKernel.getLegalAttacks(state, "blue_artillery")
    assertTrue(not hasAction(attacks, "attack", 4, 2), "Artillery cannot target adjacent Rock")
    assertTrue(hasAction(attacks, "attack", 4, 3), "Artillery can target unit behind Rock")
end)

runTest("apply_attack_uses_static_damage_and_does_not_mutate_input", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 4, 5, 4, 12)
    }))

    local nextState, result = rulesKernel.applyAction(state, {
        type = "attack",
        actorId = "blue_crusher",
        targetId = "red_commandant"
    })

    assertTrue(result.ok == true, tostring(result.reason))
    assertEquals(state.units[2].currentHp, 4, "input state should not mutate")
    local outcome = rulesKernel.evaluateOutcome(nextState)
    assertEquals(outcome.status, "blue_win", "Crusher should destroy 4 HP Commandant with Commandant bonus")
end)

runTest("destroying_all_red_units_except_commandant_is_not_victory", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_bastion", "Bastion", 2, 4, 5, 1, 6),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }))

    local nextState, result = rulesKernel.applyAction(state, {
        type = "attack",
        actorId = "blue_crusher",
        targetId = "red_bastion"
    })

    assertTrue(result.ok == true, tostring(result.reason))
    local outcome = rulesKernel.evaluateOutcome(nextState)
    assertEquals(outcome.status, "ongoing", "Red Commandant alive means no scenario victory")
end)

runTest("scenario_loss_conditions_match_contract", function()
    local noBlue = rulesKernel.normalizeState(baseState({
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }))
    local noBlueOutcome = rulesKernel.evaluateOutcome(noBlue)
    assertEquals(noBlueOutcome.status, "blue_loss", "no Blue units should lose")
    assertEquals(noBlueOutcome.reason, "blue_units_eliminated", "no Blue reason")

    local expired = rulesKernel.normalizeState(baseState({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, {
        currentPlayer = 1,
        scenarioTurn = 4,
        turnLimit = 3
    }))
    local expiredOutcome = rulesKernel.evaluateOutcome(expired)
    assertEquals(expiredOutcome.status, "blue_loss", "Blue turn N+1 should lose")
    assertEquals(expiredOutcome.reason, "turn_limit_exceeded", "turn limit reason")
end)

runTest("end_turn_advances_scenario_turn_and_resets_next_player_flags", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4, {hasMoved = true}),
        unit("red_bastion", "Bastion", 2, 3, 4, 6, 6, {hasActed = true}),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, {
        currentPlayer = 2,
        scenarioTurn = 1
    }))

    local nextState, result = rulesKernel.applyAction(state, {type = "end_turn"})
    assertTrue(result.ok == true, tostring(result.reason))
    assertEquals(nextState.currentPlayer, 1, "Red end turn returns to Blue")
    assertEquals(nextState.scenarioTurn, 2, "scenario turn increments on Blue return")
    local blue = rulesKernel.getUnitById(nextState, "blue_crusher")
    assertEquals(blue.hasMoved, false, "next player move flag should reset")
    assertEquals(blue.hasActed, false, "next player acted flag should reset")
    assertEquals(type(blue.turnActions), "table", "next player turnActions should reset")
    assertEquals(next(blue.turnActions), nil, "next player turnActions should be empty")
end)

runTest("action_budget_allows_only_two_blue_actions_before_end_turn", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("blue_bastion", "Bastion", 1, 6, 6, 6, 6),
        unit("red_commandant", "Commandant", 2, 4, 6, 12, 12)
    }, {
        turnActions = 2,
        maxActionsPerTurn = 2
    }))

    assertEquals(#rulesKernel.getLegalMoves(state, "blue_bastion"), 0, "move should be blocked after action budget")
    assertEquals(#rulesKernel.getLegalAttacks(state, "blue_crusher"), 0, "attack should be blocked after action budget")
end)

runTest("local_fixture_requires_third_blue_turn_under_two_action_budget", function()
    local function buildState(turnLimit)
        return rulesKernel.normalizeState(baseState({
            unit("blue_a_support", "Artillery", 1, 3, 6, 5, 5),
            unit("blue_finisher", "Cloudstriker", 1, 6, 2, 4, 4),
            unit("red_commandant", "Commandant", 2, 2, 5, 3, 12),
            unit("red_decoy", "Crusher", 2, 6, 6, 4, 4),
            unit("neutral_rock", "Rock", 0, 2, 4, 2, 5)
        }, {
            currentPlayer = 1,
            scenarioTurn = 1,
            turnLimit = turnLimit,
            maxActionsPerTurn = 2
        }))
    end

    local function findAction(state, matcher)
        for _, action in ipairs(require("scenario_tooling.state_engine").getLegalActions(state)) do
            if matcher(action) then
                return action
            end
        end
        return nil
    end

    local function applyRequired(state, matcher, label)
        local action = findAction(state, matcher)
        assertTrue(action ~= nil, "missing scripted local fixture action: " .. label)
        local nextState, result = rulesKernel.applyAction(state, action)
        assertTrue(result.ok == true, label .. " failed: " .. tostring(result.reason))
        return nextState
    end

    local tooShort = buildState(2)
    tooShort = applyRequired(tooShort, function(a)
        return a.type == "move" and a.actorId == "blue_a_support" and a.to.row == 2 and a.to.col == 6
    end, "support key move")
    tooShort = applyRequired(tooShort, function(a)
        return a.type == "attack" and a.actorId == "blue_a_support" and a.targetId == "neutral_rock"
    end, "support rock attack")
    tooShort = rulesKernel.applyAction(tooShort, { type = "end_turn" })
    tooShort = rulesKernel.applyAction(tooShort, { type = "end_turn" })
    tooShort = applyRequired(tooShort, function(a)
        return a.type == "move" and a.actorId == "blue_finisher" and a.to.row == 3 and a.to.col == 2
    end, "finisher staging move")
    tooShort = rulesKernel.applyAction(tooShort, { type = "end_turn" })
    tooShort = rulesKernel.applyAction(tooShort, { type = "end_turn" })
    assertEquals(rulesKernel.evaluateOutcome(tooShort).status, "blue_loss", "fixture must not be solvable inside two turns")

    local exact = buildState(3)
    exact = applyRequired(exact, function(a)
        return a.type == "move" and a.actorId == "blue_a_support" and a.to.row == 2 and a.to.col == 6
    end, "support key move")
    exact = applyRequired(exact, function(a)
        return a.type == "attack" and a.actorId == "blue_a_support" and a.targetId == "neutral_rock"
    end, "support rock attack")
    exact = rulesKernel.applyAction(exact, { type = "end_turn" })
    exact = rulesKernel.applyAction(exact, { type = "end_turn" })
    exact = applyRequired(exact, function(a)
        return a.type == "move" and a.actorId == "blue_finisher" and a.to.row == 3 and a.to.col == 2
    end, "finisher staging move")
    exact = rulesKernel.applyAction(exact, { type = "end_turn" })
    exact = rulesKernel.applyAction(exact, { type = "end_turn" })
    exact = applyRequired(exact, function(a)
        return a.type == "move" and a.actorId == "blue_finisher" and a.to.row == 2 and a.to.col == 2
    end, "finisher key move")
    exact = applyRequired(exact, function(a)
        return a.type == "attack" and a.actorId == "blue_finisher" and a.targetId == "red_commandant"
    end, "finisher attack")
    assertEquals(rulesKernel.evaluateOutcome(exact).status, "blue_win", "fixture scripted line should win on turn three")
end)

runTest("first_kernel_excludes_healer_rock_and_commandant_actions", function()
    local state = rulesKernel.normalizeState(baseState({
        unit("blue_healer", "Healer", 1, 4, 4, 4, 4),
        unit("neutral_rock", "Rock", 0, 4, 5, 5, 5),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }))

    assertEquals(#rulesKernel.getLegalMoves(state, "blue_healer"), 0, "Healer excluded from first generator mode")
    assertEquals(#rulesKernel.getLegalAttacks(state, "blue_healer"), 0, "Healer attacks excluded")
    assertEquals(#rulesKernel.getLegalMoves(state, "neutral_rock"), 0, "Rock cannot act")
    assertEquals(#rulesKernel.getLegalAttacks(state, "red_commandant"), 0, "Commandant cannot act as normal unit")
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

print(string.format("scenario_rules_kernel_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
