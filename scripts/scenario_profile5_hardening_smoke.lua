package.path = package.path .. ";./?.lua"

local retroGenerator = require("scenario_tooling.retro_generator")
local qualityEvaluator = require("scenario_tooling.quality_evaluator")
local negativeFixtures = require("scenario_tooling.negative_fixtures")
local solver = require("scenario_tooling.solver")
local stateEngine = require("scenario_tooling.state_engine")

local results = {}

local BLUE = 1

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
    for k, v in pairs(value) do
        out[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return out
end

local function stableString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function actionSig(action)
    if type(action) ~= "table" then
        return "nil"
    end
    local to = action.to or {}
    return table.concat({
        stableString(action.type),
        stableString(action.actorId),
        stableString(action.targetId),
        stableString(to.row),
        stableString(to.col)
    }, ":")
end

local function actionMatches(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.type ~= b.type then
        return false
    end
    if a.type == "move" then
        return stableString(a.actorId) == stableString(b.actorId)
            and a.to and b.to
            and tonumber(a.to.row) == tonumber(b.to.row)
            and tonumber(a.to.col) == tonumber(b.to.col)
    end
    if a.type == "attack" then
        return stableString(a.actorId) == stableString(b.actorId)
            and stableString(a.targetId) == stableString(b.targetId)
    end
    return a.type == "end_turn"
end

local function findUnit(state, unitId)
    for _, unit in ipairs(state and state.units or {}) do
        if stableString(unit.id) == stableString(unitId) then
            return unit
        end
    end
    return nil
end

local function findLegalAction(state, action)
    for _, legal in ipairs(stateEngine.getLegalActions(state)) do
        if actionMatches(legal, action) then
            return legal
        end
    end
    return nil
end

local function legalActionSignature(state)
    local signatures = {}
    for _, action in ipairs(stateEngine.getLegalActions(state)) do
        signatures[#signatures + 1] = actionSig(action)
    end
    table.sort(signatures)
    return table.concat(signatures, "|")
end

local function hasReason(result, code)
    for _, entry in ipairs(result and result.reasons or {}) do
        if stableString(entry.code) == stableString(code) then
            return true
        end
    end
    for _, entry in ipairs(result and result.unknowns or {}) do
        if stableString(entry.code) == stableString(code) then
            return true
        end
    end
    return false
end

local function changedOutputs(consequence)
    local out = consequence and consequence.changed_outputs
    if type(out) ~= "table" then
        out = consequence and consequence.delta_metrics and consequence.delta_metrics.changed_outputs
    end
    return type(out) == "table" and out or {}
end

local function outputSet(consequence)
    local set = {}
    for _, output in ipairs(changedOutputs(consequence)) do
        set[output] = true
    end
    return set
end

local function assertOutputEvidence(consequence, beforeState, afterState, dossier)
    local outputs = outputSet(consequence)
    local evidence = consequence.delta_metrics and consequence.delta_metrics.evidence or {}

    if outputs.legal_move_set then
        assertTrue(
            legalActionSignature(beforeState) ~= legalActionSignature(afterState),
            "legal_move_set output must be backed by changed legal actions for " .. stableString(consequence.slotId)
        )
    end
    if outputs.outcome then
        local beforeOutcome = stateEngine.evaluateOutcome(beforeState)
        local afterOutcome = stateEngine.evaluateOutcome(afterState)
        assertTrue(
            stableString(beforeOutcome and beforeOutcome.status) ~= stableString(afterOutcome and afterOutcome.status)
                or stableString(afterOutcome and afterOutcome.status) == "blue_win",
            "outcome output must be backed by changed outcome for " .. stableString(consequence.slotId)
        )
    end
    if outputs.red_response or outputs.false_line then
        assertTrue(#(dossier.falseLines or {}) >= 1, "red_response/false_line output requires at least one proven false line")
        assertTrue(
            evidence.redKillsFinisherIfBluePasses == true
                or evidence.redKillsFinisherIfIgnored == true,
            "red_response/false_line output must carry finisher-threat evidence for " .. stableString(consequence.slotId)
        )
    end
    if outputs.exactness then
        assertTrue(
            next(evidence) ~= nil,
            "exactness output must carry computable before/after evidence for " .. stableString(consequence.slotId)
        )
    end
end

local function assertReplayMatchesConsequences(dossier)
    local contract = dossier.compositionalContract or {}
    local byBlueOrdinal = {}
    for _, consequence in ipairs(contract.actionConsequences or {}) do
        byBlueOrdinal[tonumber(consequence.actionIndex)] = consequence
    end

    local cursor = stateEngine.normalize(dossier.scenarioState)
    local blueOrdinal = 0
    for _, expectedAction in ipairs(contract.intendedLine or {}) do
        local actor = expectedAction.actorId and findUnit(cursor, expectedAction.actorId) or nil
        local isBlueKey = expectedAction.type ~= "end_turn" and actor and tonumber(actor.player) == BLUE
        local beforeHash = stateEngine.stateHash(cursor)
        local legal = findLegalAction(cursor, expectedAction)
        assertTrue(legal ~= nil, "intended line action must be legal during replay: " .. actionSig(expectedAction))
        local afterState, result = stateEngine.applyAction(cursor, legal)
        assertTrue(type(result) == "table" and result.ok == true, "intended line action apply failed: " .. actionSig(expectedAction))
        local afterHash = stateEngine.stateHash(afterState)

        if isBlueKey then
            blueOrdinal = blueOrdinal + 1
            local consequence = byBlueOrdinal[blueOrdinal]
            assertTrue(type(consequence) == "table", "missing action consequence for Blue key action " .. tostring(blueOrdinal))
            assertTrue(actionMatches(consequence.action, legal), "consequence action must match replayed Blue action " .. tostring(blueOrdinal))
            local delta = consequence.delta_metrics or {}
            assertEquals(delta.before_state_hash, beforeHash, "before hash mismatch for Blue key action " .. tostring(blueOrdinal))
            assertEquals(delta.after_state_hash, afterHash, "after hash mismatch for Blue key action " .. tostring(blueOrdinal))
            assertTrue(beforeHash ~= afterHash, "Blue key action must change state hash " .. tostring(blueOrdinal))
            assertOutputEvidence(consequence, cursor, afterState, dossier)
        end

        cursor = afterState
    end
    assertEquals(blueOrdinal, 5, "interceptor Artillery profile must replay five key Blue actions")
end

runTest("interceptor_artillery_quality_evaluator_proves_red_policy_harness", function()
    local dossier = retroGenerator.generate({
        seed = 501,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = "interceptor_artillery",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "interceptor Artillery seed 501 must certify")

    local result = qualityEvaluator.evaluate(dossier)
    assertEquals(result.status, "approved", "interceptor Artillery dossier should approve through quality evaluator")
    assertEquals(result.features.redPolicyHarnessPass, true, "red policy harness must pass for interceptor Artillery")
    assertTrue(result.evidence.redPolicyHarness.falseLineChecks >= 1, "policy harness must inspect a false-line state")
    assertTrue(result.evidence.redPolicyHarness.unexpectedDeviationChecks >= 1, "policy harness must inspect an unexpected deviation")
    for _, critical in ipairs(result.evidence.redPolicyHarness.criticalStates or {}) do
        assertEquals(critical.deterministicRepeat, true, "policy critical-state decision must be deterministic")
    end
end)

runTest("interceptor_artillery_action_consequence_hashes_replay", function()
    local dossier = retroGenerator.generate({
        seed = 501,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = "interceptor_artillery",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "interceptor Artillery seed 501 must certify")
    assertReplayMatchesConsequences(dossier)
end)

runTest("interceptor_artillery_scripted_policy_negative_fixture_rejects", function()
    local fixture = negativeFixtures.getById("interceptor_artillery_scripted_policy_line_macro_template")
    assertTrue(type(fixture) == "table", "scripted policy negative fixture must exist")
    local result = qualityEvaluator.evaluateFixture(fixture)
    assertEquals(result.status, "reject", "scripted policy fixture must reject")
    assertTrue(hasReason(result, "macro_template_signature"), "scripted policy fixture must reject as macro_template_signature")
end)

runTest("interceptor_artillery_ten_seed_n3_not_two_turn_compressible", function()
    for seed = 501, 510 do
        local dossier, diagnostics = retroGenerator.generate({
            seed = seed,
            turnLimit = 3,
            solverMaxNodes = 9000,
            archetype = "interceptor_artillery",
            maxAttempts = 1,
            noveltyThreshold = 0
        })
        assertEquals(dossier.pipelineState, "certified", "interceptor Artillery proof seed " .. tostring(seed))
        assertEquals(
            diagnostics.lastCertification and diagnostics.lastCertification.twoTurnRedPassBoundStatus,
            "no_blue_win_even_with_red_pass",
            "generator diagnostics two-turn proof seed " .. tostring(seed)
        )

        local twoTurnState = deepCopy(dossier.scenarioState)
        twoTurnState.turnLimit = 2
        twoTurnState.scenarioTurn = 1
        local shortProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, {
            maxNodes = 9000,
            proofDomain = "defensive",
            scenarioRedPolicy = dossier.scenarioRedPolicy
        })
        assertEquals(shortProof.status, "no_blue_win_even_with_red_pass", "direct two-turn proof seed " .. tostring(seed))
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

print(string.format("scenario_profile5_hardening_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
