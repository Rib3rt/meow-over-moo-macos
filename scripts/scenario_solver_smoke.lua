package.path = package.path .. ";./?.lua"

local defensiveDomain = require("scenario_tooling.defensive_domain")
local solver = require("scenario_tooling.solver")
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

local function state(units, opts)
    opts = opts or {}
    return {
        schema = "ScenarioState",
        board = {rows = 8, cols = 8},
        currentPlayer = opts.currentPlayer or 1,
        scenarioTurn = opts.scenarioTurn or 1,
        turnLimit = opts.turnLimit or 3,
        maxActionsPerTurn = opts.maxActionsPerTurn or 2,
        turnActions = opts.turnActions or 0,
        actionsUsed = opts.actionsUsed or opts.turnActions or 0,
        objectiveType = "destroy_commandant",
        supplyEnabled = false,
        units = units
    }
end

local function actionMatches(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.type ~= b.type then
        return false
    end
    if tostring(a.actorId or "") ~= tostring(b.actorId or "") then
        return false
    end
    if a.type == "move" then
        return a.to and b.to and tonumber(a.to.row) == tonumber(b.to.row) and tonumber(a.to.col) == tonumber(b.to.col)
    end
    if a.type == "attack" then
        return tostring(a.targetId or "") == tostring(b.targetId or "")
    end
    return a.type == "end_turn"
end

local function assertLineLegalUnderBudget(initialState, line, budget, label)
    local cursor = stateEngine.normalize(initialState)
    local actions = type(line) == "table" and line or {}
    for index = 1, #actions do
        local action = actions[index]
        local legal = stateEngine.getLegalActions(cursor)
        local matched = nil
        for _, candidate in ipairs(legal) do
            if actionMatches(candidate, action) then
                matched = candidate
                break
            end
        end
        assertTrue(matched ~= nil, string.format("%s action %d must be legal", label or "line", index))
        local nextState, result = stateEngine.applyAction(cursor, matched)
        assertTrue(type(result) == "table" and result.ok == true, string.format("%s action %d apply failed", label or "line", index))
        if matched.type ~= "end_turn" then
            assertTrue((tonumber(nextState.turnActions) or 0) <= budget, string.format("%s action %d exceeded budget", label or "line", index))
        end
        cursor = nextState
    end
end

local function hasReason(decision, reasonCode)
    for _, code in ipairs((decision and decision.reasonCodes) or {}) do
        if code == reasonCode then
            return true
        end
    end
    return false
end

local function findDecision(decisions, actionType, actorId, targetOrRow, col)
    for _, decision in ipairs(decisions or {}) do
        local action = decision.redAction or {}
        if action.type == actionType and action.actorId == actorId then
            if actionType == "attack" and action.targetId == targetOrRow then
                return decision
            elseif actionType == "move" and action.to and action.to.row == targetOrRow and action.to.col == col then
                return decision
            elseif actionType == "end_turn" then
                return decision
            end
        end
    end
    return nil
end

runTest("defensive_domain_is_scenario_only_and_versioned", function()
    assertTrue(defensiveDomain.isScenarioOnly() == true, "defensive domain should be scenario-only")
    assertTrue(type(defensiveDomain.VERSION) == "string" and defensiveDomain.VERSION ~= "", "domain version required")
    assertTrue(type(defensiveDomain.DOMAIN_HASH) == "string" and defensiveDomain.DOMAIN_HASH ~= "", "domain hash required")
end)

runTest("defensive_domain_emits_decision_for_every_legal_red_move", function()
    local sample = state({
        unit("blue_critical", "Cloudstriker", 1, 4, 5, 1, 4),
        unit("red_crusher", "Crusher", 2, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, {currentPlayer = 2})

    local legal = stateEngine.getLegalActions(sample)
    local decisions, summary = defensiveDomain.classifyAll(sample, {
        criticalBlueUnitIds = {blue_critical = true}
    })
    assertEquals(#decisions, #legal, "every legal Red action needs a decision")
    assertTrue(summary.counts.include > 0, "at least one include expected")

    local attackDecision = findDecision(decisions, "attack", "red_crusher", "blue_critical")
    assertTrue(attackDecision ~= nil, "attack decision expected")
    assertEquals(attackDecision.decision, "include", "critical attack should be included")
    assertTrue(hasReason(attackDecision, "attacks_critical_blue_unit"), "critical reason expected")
    assertTrue(type(attackDecision.predicateResults) == "table" and #attackDecision.predicateResults > 0, "predicate evidence required")
end)

runTest("defensive_domain_includes_required_cell_blocks", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_bastion", "Bastion", 2, 2, 4, 6, 6),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, {currentPlayer = 2})

    local decisions = defensiveDomain.classifyAll(sample, {
        requiredCells = {["3:4"] = true}
    })
    local blockDecision = findDecision(decisions, "move", "red_bastion", 3, 4)
    assertTrue(blockDecision ~= nil, "block decision expected")
    assertEquals(blockDecision.decision, "include", "required-cell block should be included")
    assertTrue(hasReason(blockDecision, "blocks_required_cell"), "required-cell reason expected")
end)

runTest("solver_is_scenario_only_and_solves_mate_in_one", function()
    assertTrue(solver.isScenarioOnly() == true, "solver should be scenario-only")
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_commandant", "Commandant", 2, 4, 5, 4, 12)
    }, {turnLimit = 3})
    local proof = solver.solve(sample, {
        proofDomain = "all_legal",
        maxPlies = 4
    })
    assertEquals(proof.status, "forced_win", "mate in one should solve")
    assertTrue(type(proof.winningLine) == "table" and #proof.winningLine >= 1, "winning line required")
    assertEquals(proof.winningLine[1].type, "attack", "first move should attack")
    assertTrue(type(proof.proofCertificate) == "table", "certificate required")
    assertEquals(proof.proofCertificate.searchResult, "forced_win", "certificate search result")
end)

runTest("solver_rejects_timeout_position", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 8, 8, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, {
        currentPlayer = 1,
        scenarioTurn = 4,
        turnLimit = 3
    })
    local proof = solver.solve(sample, {proofDomain = "all_legal", maxPlies = 4})
    assertEquals(proof.status, "unsolved", "timeout should be unsolved")
end)

runTest("solver_defensive_domain_unknown_blocks_false_forced_win", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_bastion", "Bastion", 2, 2, 4, 6, 6),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, {currentPlayer = 2})
    local proof = solver.solve(sample, {
        proofDomain = "defensive",
        maxPlies = 4,
        forceUnknownRedActionIds = {["move:red_bastion:3:4"] = true},
        requiredCells = {["3:4"] = true}
    })
    assertEquals(proof.status, "unknown", "unknown Red defense must block proof")
    assertTrue(type(proof.defensiveDomainDecisions) == "table" and #proof.defensiveDomainDecisions > 0, "decisions should be emitted")
end)

runTest("solver_proves_simple_two_blue_action_line_with_red_policy_response", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 4, 4, 4, 4),
        unit("red_bastion", "Bastion", 2, 8, 8, 6, 6),
        unit("red_commandant", "Commandant", 2, 4, 6, 4, 12)
    }, {turnLimit = 3})
    local proof = solver.solve(sample, {
        proofDomain = "defensive",
        maxPlies = 6,
        seed = "two-action"
    })
    assertEquals(proof.status, "forced_win", "move plus attack should solve")
    assertTrue(#proof.winningLine >= 2, "line should include move and attack")
    assertLineLegalUnderBudget(sample, proof.winningLine, 2, "two_action_line")
end)

runTest("solver_respects_two_action_turn_transitions", function()
    local sample = state({
        unit("blue_a_support", "Artillery", 1, 3, 6, 5, 5),
        unit("blue_finisher", "Cloudstriker", 1, 6, 2, 4, 4),
        unit("red_commandant", "Commandant", 2, 2, 5, 4, 12),
        unit("red_decoy", "Crusher", 0, 6, 5, 4, 4),
        unit("neutral_rock", "Rock", 0, 2, 4, 2, 5)
    }, {turnLimit = 3, maxActionsPerTurn = 2})

    local proof = solver.solve(sample, {
        proofDomain = "all_legal",
        maxPlies = 12,
        seed = "two-action-turn-transition"
    })
    assertEquals(proof.status, "forced_win", "fixture should be solved under the two-action budget")
    assertTrue(type(proof.winningLine) == "table" and #proof.winningLine >= 3, "line should include turn transitions")
    assertLineLegalUnderBudget(sample, proof.winningLine, 2, "turn_transition_line")
end)

runTest("solver_compute_limit_returns_unknown_without_certifying", function()
    local sample = state({
        unit("blue_a_support", "Artillery", 1, 3, 6, 5, 5),
        unit("blue_finisher", "Cloudstriker", 1, 6, 2, 4, 4),
        unit("red_commandant", "Commandant", 2, 2, 5, 4, 12),
        unit("red_decoy", "Crusher", 0, 6, 5, 4, 4),
        unit("neutral_rock", "Rock", 0, 2, 4, 2, 5)
    }, {turnLimit = 3, maxActionsPerTurn = 2})

    local proof = solver.solve(sample, {
        proofDomain = "all_legal",
        maxPlies = 12,
        maxNodes = 5,
        seed = "compute-limit"
    })
    assertEquals(proof.status, "unknown", "compute limit should report unknown, not forced_win")
    assertEquals(proof.stats.maxNodes, 5, "certificate should include node budget")
end)

runTest("false_line_proof_reports_losing_timeout_line", function()
    local sample = state({
        unit("blue_crusher", "Crusher", 1, 8, 8, 4, 4),
        unit("red_commandant", "Commandant", 2, 1, 4, 12, 12)
    }, {turnLimit = 3})
    local result = solver.proveFalseLine(sample, {
        {type = "end_turn"},
        {type = "end_turn"},
        {type = "end_turn"},
        {type = "end_turn"},
        {type = "end_turn"},
        {type = "end_turn"}
    }, {
        proofDomain = "all_legal",
        maxPlies = 4
    })
    assertEquals(result.status, "false_line_proven", "hopeless timeout line should be proven false")
end)

runTest("solver_has_no_standard_ai_dependency", function()
    for _, path in ipairs({
        "scenario_tooling/defensive_domain.lua",
        "scenario_tooling/solver.lua"
    }) do
        local file = io.open(path, "r")
        assertTrue(file ~= nil, path .. " readable")
        local content = file:read("*a")
        file:close()
        assertTrue(content:find('require("ai', 1, true) == nil, path .. " must not require standard AI")
        assertTrue(content:find("require('ai", 1, true) == nil, path .. " must not require standard AI")
        assertTrue(content:find("ai_tournament", 1, true) == nil, path .. " must not depend on AI tournament modules")
        assertTrue(content:find("gameplay", 1, true) == nil, path .. " must not depend on gameplay")
        assertTrue(content:find("gameRuler", 1, true) == nil, path .. " must not depend on gameRuler")
    end
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

print(string.format("scenario_solver_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
