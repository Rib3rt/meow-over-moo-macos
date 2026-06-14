package.path = package.path .. ";./?.lua"

local redPolicy = require("scenario_tooling.red_policy")
local runtimeRedPolicy = require("scenarioRedPolicy")
local scenarioRedRuntime = require("scenarioRedRuntime")
local runtimeStateEngine = require("scenarioStateEngine")
local runtimeRulesKernel = require("scenarioRulesKernel")
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
        turnActions = {}
    }
    for key, value in pairs(extra or {}) do
        out[key] = value
    end
    return out
end

local function state(units, currentPlayer)
    return {
        schema = "ScenarioState",
        board = {rows = 8, cols = 8},
        currentPlayer = currentPlayer or 2,
        scenarioTurn = 1,
        turnLimit = 3,
        objectiveType = "destroy_commandant",
        supplyEnabled = false,
        units = units
    }
end

local function hasReason(record, reasonCode)
    for _, scored in ipairs((record and record.scoredActions) or {}) do
        for _, reason in ipairs(scored.reasons or {}) do
            if reason == reasonCode or (type(reason) == "table" and reason.code == reasonCode) then
                return true
            end
        end
    end
    return false
end

runTest("red_policy_is_scenario_only_and_versioned", function()
    assertTrue(redPolicy.isScenarioOnly() == true, "red policy should identify as scenario-only")
    assertTrue(runtimeRedPolicy.isScenarioOnly() == true, "runtime red policy should identify as scenario-only")
    assertTrue(runtimeStateEngine.isScenarioOnly() == true, "runtime state engine should identify as scenario-only")
    assertTrue(runtimeRulesKernel.isScenarioOnly() == true, "runtime rules kernel should identify as scenario-only")
    assertEquals(redPolicy.VERSION, runtimeRedPolicy.VERSION, "tooling and runtime must share the same policy")
    assertTrue(type(redPolicy.VERSION) == "string" and redPolicy.VERSION ~= "", "policy version required")
    assertTrue(type(redPolicy.POLICY_HASH) == "string" and redPolicy.POLICY_HASH ~= "", "policy hash required")
end)

runTest("red_policy_prefers_killing_vulnerable_critical_blue_unit", function()
    local sample = state({
        unit("blue_critical", "Cloudstriker", 1, 4, 5, 1, 4),
        unit("blue_decoy", "Bastion", 1, 8, 8, 6, 6),
        unit("red_crusher", "Crusher", 2, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    })

    local action, record = redPolicy.chooseAction(sample, {
        seed = "kill-critical",
        criticalBlueUnitIds = {blue_critical = true}
    })

    assertEquals(action.type, "attack", "Red should attack")
    assertEquals(action.targetId, "blue_critical", "Red should kill critical Blue unit")
    assertTrue(hasReason(record, "attack_critical_blue"), "critical attack reason expected")
end)

runTest("red_policy_prefers_move_plus_attack_same_unit_plan", function()
    local sample = state({
        unit("blue_target", "Wingstalker", 1, 4, 7, 3, 3),
        unit("blue_far", "Bastion", 1, 8, 8, 6, 6),
        unit("red_crusher", "Crusher", 2, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    })

    local action, record = redPolicy.chooseAction(sample, { seed = "move-attack-plan" })

    assertEquals(action.type, "move", "Red should open with move for a 2-action plan")
    assertEquals(action.actorId, "red_crusher", "same unit should execute move+attack")
    assertEquals(action.to.row, 4, "plan move row")
    assertEquals(action.to.col, 6, "plan move col")
    assertEquals(record.selectedPlan.planForm, "move_attack_same_unit", "plan form should be move+attack same unit")
end)

runTest("red_policy_avoids_no_impact_end_turn_when_attack_exists", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 4, 5, 4, 4),
        unit("red_crusher", "Crusher", 2, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    })

    local action = redPolicy.chooseAction(sample, {seed = "attack-over-pass"})
    assertEquals(action.type, "attack", "meaningful attack should beat end_turn")
end)

runTest("red_policy_spends_mandatory_action_by_advancing_toward_best_blue_target", function()
    local sample = state({
        unit("blue_low_hp", "Bastion", 1, 6, 4, 3, 6),
        unit("blue_near", "Crusher", 1, 4, 6, 4, 4),
        unit("red_blocker", "Bastion", 2, 3, 4, 3, 6),
        unit("red_hunter", "Earthstalker", 2, 8, 8, 2, 3, { hasActed = true }),
        unit("red_commandant", "Commandant", 2, 1, 1, 4, 12)
    })
    sample.turnActions = 1
    sample.maxActionsPerTurn = 2

    local action, record = redPolicy.chooseAction(sample, { seed = "mandatory-fallback-move" })

    assertEquals(action.type, "move", "Red must spend a real second action when a move is available")
    assertEquals(action.actorId, "red_blocker", "available Red unit should move")
    assertEquals(action.to.row, 5, "fallback should prioritize the lowest-HP Blue unit before distance")
    assertEquals(action.to.col, 4, "fallback should prioritize the lowest-HP Blue unit before distance")
    assertTrue(hasReason(record, "fallback_toward_nearest_blue"), "fallback movement reason expected")
end)

runTest("red_policy_cloudstriker_fallback_moves_to_firing_band_not_adjacent_dead_zone", function()
    local sample = state({
        unit("blue_false_decoy", "Wingstalker", 1, 2, 3, 2, 3, { hasMoved = true, hasActed = true, turnActions = { move = true, attack = true } }),
        unit("blue_finisher", "Crusher", 1, 6, 8, 4, 4),
        unit("red_sniper", "Cloudstriker", 2, 6, 3, 4, 4),
        unit("red_guard", "Wingstalker", 2, 5, 1, 3, 3),
        unit("red_hunter", "Earthstalker", 2, 8, 5, 3, 3, { hasMoved = true, hasActed = true, turnActions = { move = true, attack = true } }),
        unit("red_commandant", "Commandant", 2, 2, 4, 3, 12)
    })
    sample.scenarioTurn = 2
    sample.turnActions = 1
    sample.maxActionsPerTurn = 2

    local action, record = redPolicy.chooseAction(sample, { seed = "cloud-fallback-band" })

    assertEquals(action.type, "move", "Red should spend the remaining action with a reposition")
    assertEquals(action.actorId, "red_sniper", "Cloudstriker should be the relevant fallback mover")
    assertEquals(action.to.row, 4, "Cloudstriker should stop at non-adjacent firing distance")
    assertEquals(action.to.col, 3, "Cloudstriker should preserve the C-file shot")
    assertTrue(hasReason(record, "fallback_toward_nearest_blue"), "fallback movement reason expected")
end)

runTest("red_policy_kill_priority_beats_non_kill_direct_threat_damage", function()
    local sample = state({
        unit("blue_direct_threat", "Crusher", 1, 3, 4, 4, 4),
        unit("blue_killable", "Wingstalker", 1, 5, 5, 3, 3),
        unit("red_bastion", "Bastion", 2, 4, 4, 6, 6),
        unit("red_crusher", "Crusher", 2, 5, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 2, 4, 12, 12)
    })

    local action = redPolicy.chooseAction(sample, { seed = "kill-priority" })
    assertEquals(action.type, "attack", "Red should attack")
    assertEquals(action.targetId, "blue_killable", "kill opportunity should be prioritized first")
end)

runTest("red_policy_prioritizes_direct_commandant_threat_target", function()
    local sample = state({
        unit("blue_direct_threat", "Crusher", 1, 3, 4, 6, 6),
        unit("blue_decoy", "Bastion", 1, 4, 5, 6, 6),
        unit("red_bastion", "Bastion", 2, 4, 4, 6, 6),
        unit("red_commandant", "Commandant", 2, 2, 4, 12, 12)
    })

    local action = redPolicy.chooseAction(sample, { seed = "direct-threat-priority" })
    assertEquals(action.type, "attack", "Red should attack")
    assertEquals(action.targetId, "blue_direct_threat", "direct Commandant threat should be targeted first")
end)

runTest("red_policy_prioritizes_projected_commandant_threat_target", function()
    local sample = state({
        unit("blue_projected_threat", "Crusher", 1, 5, 4, 6, 6),
        unit("blue_decoy", "Bastion", 1, 5, 6, 6, 6),
        unit("red_crusher", "Crusher", 2, 5, 5, 4, 4),
        unit("red_commandant", "Commandant", 2, 2, 4, 12, 12)
    })

    local action = redPolicy.chooseAction(sample, { seed = "projected-threat-priority" })
    assertEquals(action.type, "attack", "Red should attack")
    assertEquals(action.targetId, "blue_projected_threat", "projected Commandant threat should be prioritized")
end)

runTest("red_policy_uses_deterministic_tie_break", function()
    local sample = state({
        unit("blue_left", "Bastion", 1, 4, 3, 6, 6),
        unit("blue_right", "Bastion", 1, 4, 5, 6, 6),
        unit("red_crusher", "Crusher", 2, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 1, 12, 12)
    })

    local first = redPolicy.chooseAction(sample, { seed = "deterministic-a" })
    local second = redPolicy.chooseAction(sample, { seed = "deterministic-b" })
    local third = redPolicy.chooseAction(sample, { seed = "deterministic-a" })

    assertEquals(first.id, second.id, "tie break should be deterministic and seed-independent")
    assertEquals(first.id, third.id, "same input should always produce same action")
end)

runTest("red_policy_returns_safe_noop_when_not_red_turn", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, 1)

    local action, record = redPolicy.chooseAction(sample, {seed = "blue-turn"})
    assertEquals(action.type, "end_turn", "non-Red turn should not call AI")
    assertEquals(record.candidateCount, 1, "only noop candidate expected")
end)

runTest("red_policy_records_forbidden_inputs_check", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    })
    local _, record = redPolicy.chooseAction(sample, {
        seed = "forbidden-check",
        scenarioId = "must_not_read",
        solutionStep = 2,
        falseLineId = "must_not_read"
    })
    assertEquals(record.forbiddenInputsChecked, true, "forbidden input check should be recorded")
end)

runTest("scenario_red_runtime_converts_live_board_to_policy_command", function()
    local board = {
        ["5:1"] = { name = "Cloudstriker", player = 1, currentHp = 4, startingHp = 4, hasMoved = false, hasActed = false, turnActions = {} },
        ["5:4"] = { name = "Cloudstriker", player = 2, currentHp = 4, startingHp = 4, hasMoved = false, hasActed = false, turnActions = {} },
        ["2:4"] = { name = "Commandant", player = 2, currentHp = 12, startingHp = 12, hasMoved = false, hasActed = false, turnActions = {} }
    }
    local grid = {
        rows = 8,
        cols = 8,
        getUnitAt = function(_, row, col)
            return board[tostring(row) .. ":" .. tostring(col)]
        end
    }
    local ruler = {
        currentGrid = grid,
        currentPlayer = 2,
        currentTurn = 1,
        currentTurnActions = 0
    }

    local command, record = scenarioRedRuntime.chooseCommand(ruler, grid, {
        scenario = {
            id = "runtime-policy-smoke",
            turnsTarget = 3,
            scenarioRedPolicy = {
                seed = "runtime-policy-smoke",
                criticalBlueUnitIds = { "blue_finisher" }
            }
        }
    })

    assertTrue(record.ok == true, "runtime policy command should resolve")
    assertEquals(command.fromRow, 5, "command source row")
    assertEquals(command.fromCol, 4, "command source col")
    if command.actionType == "attack" then
        assertEquals(command.toRow, 5, "attack target row")
        assertEquals(command.toCol, 1, "attack target col")
    else
        assertEquals(command.actionType, "move", "runtime policy should return first step of best deterministic plan")
        assertEquals(command.toRow, 5, "move target row")
        assertEquals(command.toCol, 3, "move target col")
        assertEquals(record.selectedPlan.planForm, "move_attack_same_unit", "runtime record should expose chosen 2-action plan form")
    end
end)

runTest("runtime_state_uses_stable_scenario_unit_ids_after_movement", function()
    local function buildGrid(row, col)
        local board = {
            ["5:1"] = {
                scenarioUnitId = "blue_generic_stable",
                name = "Bastion",
                player = 1,
                currentHp = 6,
                startingHp = 6,
                hasMoved = false,
                hasActed = false,
                turnActions = {}
            },
            [tostring(row) .. ":" .. tostring(col)] = {
                scenarioUnitId = "red_generic_stable",
                name = "Bastion",
                player = 2,
                currentHp = 6,
                startingHp = 6,
                hasMoved = false,
                hasActed = false,
                turnActions = {}
            },
            ["2:4"] = {
                scenarioUnitId = "red_commandant_stable",
                name = "Commandant",
                player = 2,
                currentHp = 12,
                startingHp = 12,
                hasMoved = false,
                hasActed = false,
                turnActions = {}
            }
        }
        return {
            rows = 8,
            cols = 8,
            getUnitAt = function(_, r, c)
                return board[tostring(r) .. ":" .. tostring(c)]
            end
        }
    end

    local beforeGrid = buildGrid(4, 4)
    local afterGrid = buildGrid(4, 5)
    local beforeState = scenarioRedRuntime.buildScenarioState({
        currentGrid = beforeGrid,
        currentPlayer = 2,
        currentTurn = 1,
        currentTurnActions = 0
    }, beforeGrid)
    local afterState = scenarioRedRuntime.buildScenarioState({
        currentGrid = afterGrid,
        currentPlayer = 2,
        currentTurn = 1,
        currentTurnActions = 0
    }, afterGrid)

    local beforeRed = runtimeRulesKernel.getUnitById(beforeState, "red_generic_stable")
    local afterRed = runtimeRulesKernel.getUnitById(afterState, "red_generic_stable")
    assertTrue(beforeRed ~= nil, "stable Red id should be present before move")
    assertTrue(afterRed ~= nil, "stable Red id should survive after move")
    assertEquals(afterRed.col, 5, "stable id should follow the moved unit")
end)

runTest("p001_advertised_turn_limit_matches_current_contract_label", function()
    local scenario = dofile("scenarios/P001.lua")
    assertEquals(scenario.turnLimitRounds, 3, "P001 should advertise the certified three-turn contract")
    assertTrue(tostring(scenario.objectiveText or ""):find("3 turns", 1, true) ~= nil, "P001 objective text should match turn limit")
    for index, unitState in ipairs(scenario.startSnapshot and scenario.startSnapshot.boardUnits or {}) do
        assertTrue(type(unitState.scenarioUnitId) == "string" and unitState.scenarioUnitId ~= "", "P001 board unit needs stable scenarioUnitId at index " .. tostring(index))
    end
end)

runTest("red_policy_has_no_standard_ai_dependency", function()
    local file = io.open("scenarioRedPolicy.lua", "r")
    assertTrue(file ~= nil, "red_policy.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "red policy must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "red policy must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "red policy must not depend on AI tournament modules")
    assertTrue(content:find("gameplay", 1, true) == nil, "red policy must not depend on gameplay")
    assertTrue(content:find("gameRuler", 1, true) == nil, "red policy must not depend on gameRuler")
    assertTrue(content:find("scenario_tooling", 1, true) == nil, "runtime red policy must not depend on internal tooling modules")
    assertTrue(content:find("scenarioId", 1, true) == nil or content:find("forbiddenInputsChecked", 1, true) ~= nil, "scenario id must not drive policy")

    local runtimeFile = io.open("scenarioRedRuntime.lua", "r")
    assertTrue(runtimeFile ~= nil, "scenarioRedRuntime.lua readable")
    local runtimeContent = runtimeFile:read("*a")
    runtimeFile:close()
    assertTrue(runtimeContent:find('require("ai', 1, true) == nil, "runtime red policy must not require standard AI")
    assertTrue(runtimeContent:find("ai_tournament", 1, true) == nil, "runtime red policy must not depend on AI tournament modules")
    assertTrue(runtimeContent:find("scenario_tooling", 1, true) == nil, "runtime red adapter must not depend on internal tooling modules")
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

print(string.format("scenario_red_policy_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
