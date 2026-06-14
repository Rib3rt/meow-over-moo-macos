package.path = package.path .. ";./?.lua"

local retroGenerator = require("scenario_tooling.retro_generator")
local harness = require("scenario_tooling.red_policy_harness")
local stateEngine = require("scenario_tooling.state_engine")

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

local function actionSig(action)
    if type(action) ~= "table" then
        return "nil"
    end
    local to = action.to or {}
    return table.concat({
        tostring(action.type or ""),
        tostring(action.actorId or ""),
        tostring(action.targetId or ""),
        tostring(to.row or ""),
        tostring(to.col or "")
    }, ":")
end

local function applyLineAndAdvanceToRed(state, actions)
    local cursor = stateEngine.cloneState(state)
    for _, action in ipairs(actions or {}) do
        cursor = stateEngine.applyAction(cursor, action)
    end
    if cursor.currentPlayer == 1 then
        cursor = stateEngine.applyAction(cursor, { type = "end_turn" })
    end
    return cursor
end

local function firstNonWinningDeviation(dossier)
    local winningFirst = dossier.solution and dossier.solution.actions and dossier.solution.actions[1]
    for _, action in ipairs(stateEngine.getLegalActions(dossier.scenarioState)) do
        if actionSig(action) ~= actionSig(winningFirst) then
            return action
        end
    end
    return nil
end

runTest("red_policy_harness_is_scenario_only_and_versioned", function()
    assertTrue(harness.isScenarioOnly() == true, "harness should be scenario-only")
    assertTrue(type(harness.VERSION) == "string" and harness.VERSION ~= "", "version required")
    assertTrue(type(harness.HARNESS_ID) == "string" and harness.HARNESS_ID ~= "", "harness id required")
    assertTrue(type(harness.HARNESS_HASH) == "string" and harness.HARNESS_HASH ~= "", "harness hash required")
end)

runTest("critical_false_line_state_gets_credible_red_reply", function()
    local dossier = retroGenerator.generate({ seed = 310, turnLimit = 3, solverMaxNodes = 3000 })
    local falseLine = dossier.falseLines[1]
    local redState = applyLineAndAdvanceToRed(dossier.scenarioState, falseLine.actions)
    local report = harness.checkCriticalState(redState, {
        dossierId = dossier.id,
        criticalStateId = "false_line_1",
        criticalBlueUnitIds = { "blue_finisher" },
        requiredResponse = "refute_false_line"
    })

    assertTrue(report.pass == true, "critical false-line state should pass")
    assertEquals(report.currentPlayer, 2, "critical state should be Red to move")
    assertTrue(report.legalActionCount > 0, "legal Red actions required")
    assertEquals(report.deterministicRepeat, true, "policy should be deterministic")
    assertTrue(report.selectedAction.type ~= "end_turn", "credible reply should spend a real Red action")
    assertEquals(report.evidence.policyRecord.selectedPlan.planForm, "move_attack_same_unit", "credible reply should be backed by a move+attack plan")
end)

runTest("evaluate_dossier_checks_false_lines_and_unexpected_deviations", function()
    local dossier = retroGenerator.generate({ seed = 320, turnLimit = 3, solverMaxNodes = 3000 })
    local report = harness.evaluateDossier(dossier)
    assertTrue(report.pass == true, "generated dossier should pass policy harness")
    assertTrue(report.falseLineChecks >= 1, "false-line checks required")
    assertTrue(report.unexpectedDeviationChecks >= 1, "unexpected deviation checks required")
    assertTrue(#report.criticalStates >= report.falseLineChecks, "critical state reports required")
    for _, critical in ipairs(report.criticalStates) do
        assertTrue(critical.deterministicRepeat == true, "each check should prove deterministic policy repeat")
        assertTrue(critical.policyVersion ~= nil, "policy version evidence required")
        assertTrue(critical.policyHash ~= nil, "policy hash evidence required")
    end
end)

runTest("policy_divergence_requires_solver_rerun_evidence", function()
    local dossier = retroGenerator.generate({ seed = 330, turnLimit = 3, solverMaxNodes = 3000 })
    local falseLine = dossier.falseLines[1]
    local redState = applyLineAndAdvanceToRed(dossier.scenarioState, falseLine.actions)
    local report = harness.checkCriticalState(redState, {
        criticalStateId = "forced_divergence",
        criticalBlueUnitIds = { "blue_finisher" },
        expectedAction = { type = "end_turn" }
    })

    assertTrue(report.divergedFromExpected == true, "bad expected action should diverge")
    assertTrue(type(report.proofRerun) == "table", "proof rerun evidence required")
    assertTrue(report.proofRerun.required == true, "divergence should require rerun")
    assertTrue(type(report.proofRerun.status) == "string" and report.proofRerun.status ~= "", "rerun status required")
end)

runTest("non_red_state_is_not_credited_as_policy_decision", function()
    local dossier = retroGenerator.generate({ seed = 340, turnLimit = 3, solverMaxNodes = 3000 })
    local report = harness.checkCriticalState(dossier.scenarioState, {
        criticalStateId = "blue_to_move_start"
    })
    assertTrue(report.pass == false, "Blue-to-move state should not pass as Red policy check")
    assertEquals(report.reason, "not_red_to_move", "reason should identify non-Red state")
end)

runTest("red_policy_harness_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/red_policy_harness.lua", "r")
    assertTrue(file ~= nil, "red_policy_harness.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "harness must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "harness must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "harness must not depend on AI tournament modules")
    assertTrue(content:find("ai_config", 1, true) == nil, "harness must not depend on AI config")
    assertTrue(content:find("gameRuler", 1, true) == nil, "harness must not depend on runtime game ruler")
    assertTrue(content:find("factionSelect", 1, true) == nil, "harness must not depend on runtime menus")
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

print(string.format("scenario_red_policy_harness_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
