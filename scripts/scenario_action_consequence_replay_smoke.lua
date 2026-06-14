package.path = package.path .. ";./?.lua"

local retroGenerator = require("scenario_tooling.retro_generator")
local stateEngine = require("scenario_tooling.state_engine")

local BLUE = 1

local results = {}

local CASES = {
    { name = "composite_support_pressure_crusher_contact", seed = 410, archetype = "composite_support_pressure_crusher_contact", minBlueActions = 5 },
    { name = "crusher_contact_breach", seed = 121, archetype = "crusher_contact", minBlueActions = 5 },
    { name = "support_reposition_rock_los_finish", seed = 131, archetype = "rock_los_finish", minBlueActions = 5 },
    { name = "support_under_real_red_pressure", seed = 143, archetype = "support_pressure", minBlueActions = 5 },
    { name = "support_intercepts_finisher_threat_artillery_finish", seed = 501, archetype = "interceptor_artillery", minBlueActions = 5 },
    { name = "dual_rock_lock_ranged_finish", seed = 601, archetype = "dual_rock_lock", minBlueActions = 6 }
}

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

local function outputSet(consequence)
    local out = consequence and consequence.changed_outputs
    if type(out) ~= "table" then
        out = consequence and consequence.delta_metrics and consequence.delta_metrics.changed_outputs
    end
    local set = {}
    for _, output in ipairs(type(out) == "table" and out or {}) do
        set[output] = true
    end
    return set
end

local function assertOutputEvidence(caseName, consequence, beforeState, afterState, dossier)
    local outputs = outputSet(consequence)
    local evidence = consequence.delta_metrics and consequence.delta_metrics.evidence or {}
    assertTrue(next(outputs) ~= nil, caseName .. " consequence outputs must be non-empty: " .. stableString(consequence.slotId))

    if outputs.legal_move_set then
        assertTrue(
            legalActionSignature(beforeState) ~= legalActionSignature(afterState),
            caseName .. " legal_move_set output must change legal actions: " .. stableString(consequence.slotId)
        )
    end
    if outputs.outcome then
        local beforeOutcome = stateEngine.evaluateOutcome(beforeState)
        local afterOutcome = stateEngine.evaluateOutcome(afterState)
        assertTrue(
            stableString(beforeOutcome and beforeOutcome.status) ~= stableString(afterOutcome and afterOutcome.status)
                or stableString(afterOutcome and afterOutcome.status) == "blue_win",
            caseName .. " outcome output must change outcome: " .. stableString(consequence.slotId)
        )
    end
    if outputs.false_line or outputs.red_response then
        assertTrue(#(dossier.falseLines or {}) >= 1, caseName .. " false_line/red_response output requires proven false-line evidence")
    end
    if outputs.exactness then
        assertTrue(next(evidence) ~= nil, caseName .. " exactness output requires before/after evidence: " .. stableString(consequence.slotId))
    end
end

local function replayCase(case)
    local dossier = retroGenerator.generate({
        seed = case.seed,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = case.archetype,
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", case.name .. " must certify before replay")

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
        assertTrue(legal ~= nil, case.name .. " intended action must be legal during replay: " .. actionSig(expectedAction))
        local afterState, result = stateEngine.applyAction(cursor, legal)
        assertTrue(type(result) == "table" and result.ok == true, case.name .. " intended action apply failed: " .. actionSig(expectedAction))
        local afterHash = stateEngine.stateHash(afterState)

        if isBlueKey then
            blueOrdinal = blueOrdinal + 1
            local consequence = byBlueOrdinal[blueOrdinal]
            assertTrue(type(consequence) == "table", case.name .. " missing consequence for Blue key action " .. tostring(blueOrdinal))
            assertTrue(actionMatches(consequence.action, legal), case.name .. " consequence action mismatch " .. tostring(blueOrdinal))
            local delta = consequence.delta_metrics or {}
            assertEquals(delta.before_state_hash, beforeHash, case.name .. " before hash mismatch " .. tostring(blueOrdinal))
            assertEquals(delta.after_state_hash, afterHash, case.name .. " after hash mismatch " .. tostring(blueOrdinal))
            assertTrue(beforeHash ~= afterHash, case.name .. " Blue key action must change state hash " .. tostring(blueOrdinal))
            assertOutputEvidence(case.name, consequence, cursor, afterState, dossier)
        end

        cursor = afterState
    end
    assertTrue(blueOrdinal >= case.minBlueActions, case.name .. " must replay minimum key Blue action count")
end

for _, case in ipairs(CASES) do
    runTest(case.name .. "_action_consequences_replay", function()
        replayCase(case)
    end)
end

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
        print("[PASS] " .. result.name)
    else
        print("[FAIL] " .. result.name .. " -> " .. tostring(result.err))
    end
end

print(string.format("scenario_action_consequence_replay_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
