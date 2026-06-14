package.path = package.path .. ";./?.lua"

local retroGenerator = require("scenario_tooling.retro_generator")
local contractValidator = require("scenario_tooling.scenario_contract_validator")
local microLibrary = require("scenario_tooling.micro_interaction_library")
local stateEngine = require("scenario_tooling.state_engine")
local solver = require("scenario_tooling.solver")
local compositionComposer = require("scenario_tooling.composition_composer")
local qualityEvaluator = require("scenario_tooling.quality_evaluator")

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

local function actionMatches(actual, expected)
    if type(actual) ~= "table" or type(expected) ~= "table" then
        return false
    end
    if actual.type ~= expected.type then
        return false
    end
    if tostring(actual.actorId or "") ~= tostring(expected.actorId or "") then
        return false
    end
    if actual.type == "move" then
        return actual.to and expected.to and actual.to.row == expected.to.row and actual.to.col == expected.to.col
    end
    if actual.type == "attack" then
        return tostring(actual.targetId or "") == tostring(expected.targetId or "")
    end
    return actual.type == "end_turn"
end

local function hasLegalFirstAction(state, line)
    if type(line) ~= "table" or type(line[1]) ~= "table" then
        return false
    end
    local legal = stateEngine.getLegalActions(state)
    for _, action in ipairs(legal) do
        if actionMatches(action, line[1]) then
            return true
        end
    end
    return false
end

local function predicateValue(dossier, predicateName)
    for _, result in ipairs(dossier.predicateResults or {}) do
        if result.predicate == predicateName or result.name == predicateName then
            return result.value
        end
    end
    return nil
end

local function hasMicro(dossier, microId)
    for _, micro in ipairs(dossier.microInteractions or {}) do
        if tostring(micro.id or micro.microId or "") == tostring(microId) then
            return true
        end
    end
    return false
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
            local used = tonumber(nextState.turnActions) or 0
            assertTrue(used <= budget, string.format("%s action %d exceeded budget", label or "line", index))
        end
        cursor = nextState
    end
end

runTest("retro_generator_is_scenario_only_and_versioned", function()
    assertTrue(retroGenerator.isScenarioOnly() == true, "retro generator should be scenario-only")
    assertTrue(type(retroGenerator.VERSION) == "string" and retroGenerator.VERSION ~= "", "version required")
    assertTrue(type(retroGenerator.GENERATOR_ID) == "string" and retroGenerator.GENERATOR_ID ~= "", "generator id required")
    assertTrue(type(retroGenerator.GENERATOR_HASH) == "string" and retroGenerator.GENERATOR_HASH ~= "", "generator hash required")
end)

runTest("retro_generator_precheck_accepts_step7_n3_scope", function()
    local ok, report = retroGenerator.precheck({ turnLimit = 3 })
    assertTrue(ok, "precheck should accept N=3 scope")
    assertTrue(type(report) == "table", "precheck report required")
    assertTrue(report.turnLimit == 3, "precheck should report turn limit")
    assertTrue(report.microLibraryOk == true, "micro library must validate")
    assertTrue(report.finisherLibraryOk == true, "finisher library must validate")
    assertTrue(report.macroTemplateCount == 0, "no macro-template micro specs allowed")
end)

runTest("single_generation_is_deterministic_and_certified_not_approved", function()
    local first = retroGenerator.generate({ seed = 101, turnLimit = 3, solverMaxNodes = 3000 })
    local second = retroGenerator.generate({ seed = 101, turnLimit = 3, solverMaxNodes = 3000 })
    assertTrue(type(first) == "table", "dossier required")
    assertEquals(first.pipelineState, "certified", "single generation should certify")
    assertTrue(first.pipelineState ~= "approved", "Step 7 must not approve")
    assertEquals(first.id, second.id, "same seed should produce same id")
    assertEquals(first.tacticalFingerprint.signature, second.tacticalFingerprint.signature, "same seed should produce same fingerprint")
    assertEquals(first.proofCertificate.searchResult, "forced_win", "proof certificate should force win")
    assertEquals(tonumber(first.scenarioState.maxActionsPerTurn), 2, "generated scenario must use runtime action budget 2")
    assertLineLegalUnderBudget(first.scenarioState, first.solution.actions, 2, "single_generation_solution")
end)

runTest("certified_dossier_has_contract_solution_false_lines_and_predicates", function()
    local dossier = retroGenerator.generate({ seed = 111, turnLimit = 3, solverMaxNodes = 3000 })
    local contractOk, contractErrors = contractValidator.validateScenarioDossier(dossier)
    assertTrue(contractOk, "dossier contract should pass: " .. tostring(contractErrors and contractErrors[1] and contractErrors[1].code))
    assertEquals(dossier.schema, "GenerationDossier", "schema required")
    assertTrue(dossier.scenarioState.scenarioTurn >= 1 and dossier.scenarioState.scenarioTurn <= dossier.scenarioState.turnLimit, "generated N=3 scenario turn should be within limit")
    assertEquals(dossier.scenarioState.turnLimit, 3, "N=3 required")
    assertEquals(tonumber(dossier.scenarioState.maxActionsPerTurn), 2, "scenario budget should be real runtime budget")
    assertEquals(dossier.solverProof.status, "forced_win", "solver proof should force win")
    assertTrue(type(dossier.solution) == "table" and type(dossier.solution.actions) == "table" and #dossier.solution.actions >= 3, "non-trivial solution actions required")
    assertLineLegalUnderBudget(dossier.scenarioState, dossier.solution.actions, 2, "dossier_solution")
    assertTrue(type(dossier.falseLines) == "table" and #dossier.falseLines >= 1, "at least one false line required")
    for _, falseLine in ipairs(dossier.falseLines) do
        assertTrue(hasLegalFirstAction(dossier.scenarioState, falseLine.actions), "false line first action must be legal")
        assertTrue(type(falseLine.proof) == "table", "false line proof required")
        assertEquals(falseLine.proof.status, "false_line_proven", "false line must be proven")
    end
    assertEquals(predicateValue(dossier, "macro_template_signature"), false, "macro-template predicate must reject false")
    assertEquals(predicateValue(dossier, "fingerprint_distinct"), true, "fingerprint distinct predicate must be computed true")
    assertEquals(predicateValue(dossier, "non_decorative_micro"), true, "micro-interactions must be non-decorative")
    assertEquals(predicateValue(dossier, "static_damage_clock"), false, "certified scenario must not be static damage clock")
    assertEquals(predicateValue(dossier, "free_finisher_move"), false, "finisher move must not be free")
    assertEquals(predicateValue(dossier, "support_already_free"), false, "support must not start already free")
    assertEquals(predicateValue(dossier, "real_pressure"), true, "red pressure predicate must be computed true")
end)

runTest("support_pressure_variant_is_certified_and_policy_driven", function()
    local dossier = retroGenerator.generate({
        seed = 202,
        turnLimit = 3,
        solverMaxNodes = 7000,
        archetype = "support_pressure",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "support pressure variant must certify")
    assertTrue(dossier.tacticalFingerprint.role_signature:find("earthstalker_pressure", 1, true) ~= nil, "fingerprint should name support pressure")
    assertTrue(hasMicro(dossier, "RED_ATTACKS_SUPPORT"), "support pressure variant must declare RED_ATTACKS_SUPPORT")
    assertEquals(predicateValue(dossier, "real_pressure"), true, "support pressure must compute real pressure")
    assertEquals(predicateValue(dossier, "cosmetic_red_pressure"), false, "support pressure must not be cosmetic")
    assertEquals(dossier.compositionalContract.profileId, "support_under_real_red_pressure", "support pressure must expose compositional profile")
    local contractOk = compositionComposer.validateContract(dossier.compositionalContract)
    assertTrue(contractOk == true, "support pressure compositional contract must validate")
    assertTrue(#(dossier.ablationResults or {}) >= 5, "support pressure must prove action consequences")
    assertTrue(hasMicro(dossier, "ROCK_AS_LOCK"), "support pressure profile must include ROCK_AS_LOCK")
    assertTrue(hasMicro(dossier, "LOS_OPEN_RANGED"), "support pressure profile must include LOS_OPEN_RANGED")
    assertTrue(hasMicro(dossier, "FINISHER_CELL_GAIN"), "support pressure profile must include FINISHER_CELL_GAIN")

    local redKillsSupport = false
    for _, action in ipairs(dossier.solution.actions or {}) do
        if action.type == "attack"
            and tostring(action.actorId or "") == "red_support_threat"
            and tostring(action.targetId or "") == "blue_a_support" then
            redKillsSupport = true
            break
        end
    end
    assertTrue(redKillsSupport, "Scenario Red Policy should execute the support-pressure attack in the certified line")

    local twoTurnState = deepCopy(dossier.scenarioState)
    twoTurnState.turnLimit = 2
    twoTurnState.scenarioTurn = 1
    local shortProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, { maxNodes = 9000 })
    assertEquals(shortProof.status, "no_blue_win_even_with_red_pass", "support pressure N=3 profile must not compress to two turns")
end)

runTest("crusher_contact_breach_is_distinct_from_rock_los_archetype", function()
    local dossier = retroGenerator.generate({
        seed = 300,
        turnLimit = 3,
        solverMaxNodes = 7000,
        archetype = "crusher_contact_breach",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "crusher contact breach must certify")
    assertEquals(dossier.finisher.unitType, "Crusher", "contact breach finisher must be Crusher")
    assertEquals(dossier.finisher.family, "melee", "contact breach finisher must be melee")
    assertTrue(dossier.tacticalFingerprint.role_signature:find("contact_breach", 1, true) ~= nil, "fingerprint should name contact breach")
    assertTrue(dossier.tacticalFingerprint.role_signature:find("rock_lock", 1, true) == nil, "contact breach must not be a rock-lock role")
    assertTrue(not hasMicro(dossier, "LOS_OPEN_RANGED"), "contact breach must not use LOS_OPEN_RANGED")
    assertTrue(not hasMicro(dossier, "ROCK_AS_LOCK"), "contact breach must not use ROCK_AS_LOCK")
    assertTrue(hasMicro(dossier, "FINISHER_CELL_GAIN"), "contact breach must require Crusher cell gain")
    assertTrue(hasMicro(dossier, "SUPPORT_CELL_GAIN"), "contact breach must include computable support positioning")
    assertEquals(dossier.compositionalContract.profileId, "crusher_contact_breach", "contact breach must expose compositional profile")
    local contractOk = compositionComposer.validateContract(dossier.compositionalContract)
    assertTrue(contractOk == true, "contact breach compositional contract must validate")
    assertTrue(#(dossier.ablationResults or {}) >= 5, "contact breach must prove action consequences")

    local finalAttack = nil
    for _, action in ipairs(dossier.solution.actions or {}) do
        if action.type == "attack" and tostring(action.targetId or "") == "red_commandant" then
            finalAttack = action
        end
    end
    assertTrue(finalAttack ~= nil, "solution needs Commandant attack")
    assertEquals(finalAttack.actorId, "blue_finisher", "Commandant kill must be performed by Crusher finisher")

    local twoTurnState = deepCopy(dossier.scenarioState)
    twoTurnState.turnLimit = 2
    twoTurnState.scenarioTurn = 1
    local shortProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, { maxNodes = 9000 })
    assertEquals(shortProof.status, "no_blue_win_even_with_red_pass", "contact breach N=3 profile must not compress to two turns")
end)

runTest("rock_los_finish_is_compositional_and_not_two_turn_compressible", function()
    local dossier = retroGenerator.generate({
        seed = 131,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = "rock_los_finish",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "rock/LOS finish must certify")
    assertEquals(dossier.compositionalContract.profileId, "support_reposition_rock_los_finish", "rock/LOS must expose compositional profile")
    local contractOk = compositionComposer.validateContract(dossier.compositionalContract)
    assertTrue(contractOk == true, "rock/LOS compositional contract must validate")
    assertTrue(#(dossier.ablationResults or {}) >= 5, "rock/LOS must prove action consequences")
    assertTrue(hasMicro(dossier, "ROCK_AS_LOCK"), "rock/LOS profile must include ROCK_AS_LOCK")
    assertTrue(hasMicro(dossier, "LOS_OPEN_RANGED"), "rock/LOS profile must include LOS_OPEN_RANGED")
    assertTrue(hasMicro(dossier, "FINISHER_CELL_GAIN"), "rock/LOS profile must include FINISHER_CELL_GAIN")
    assertTrue(dossier.tacticalFingerprint.role_signature:find("rock_lock", 1, true) ~= nil, "fingerprint should name rock lock")

    local twoTurnState = deepCopy(dossier.scenarioState)
    twoTurnState.turnLimit = 2
    twoTurnState.scenarioTurn = 1
    local shortProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, { maxNodes = 9000 })
    assertEquals(shortProof.status, "no_blue_win_even_with_red_pass", "rock/LOS N=3 profile must not compress to two turns")
end)

runTest("interceptor_artillery_is_compositional_policy_driven_and_not_two_turn_compressible", function()
    local dossier = retroGenerator.generate({
        seed = 501,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = "interceptor_artillery",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "interceptor Artillery profile must certify")
    assertEquals(dossier.compositionalContract.profileId, "support_intercepts_finisher_threat_artillery_finish", "interceptor Artillery must expose compositional profile")
    local contractOk = compositionComposer.validateContract(dossier.compositionalContract)
    assertTrue(contractOk == true, "interceptor Artillery compositional contract must validate")
    assertTrue(#(dossier.ablationResults or {}) >= 5, "interceptor Artillery must prove action consequences")
    assertTrue(hasMicro(dossier, "RED_ATTACKS_FINISHER"), "interceptor Artillery must include RED_ATTACKS_FINISHER")
    assertTrue(hasMicro(dossier, "FINISHER_CELL_GAIN"), "interceptor Artillery must include FINISHER_CELL_GAIN")
    assertTrue(dossier.tacticalFingerprint.role_signature:find("support_interceptor", 1, true) ~= nil, "fingerprint should name support interceptor")

    local redKillsFinisher = false
    for _, action in ipairs(dossier.solution.actions or {}) do
        if action.type == "attack"
            and tostring(action.actorId or "") == "red_interceptor"
            and tostring(action.targetId or "") == "blue_finisher" then
            redKillsFinisher = true
            break
        end
    end
    assertTrue(not redKillsFinisher, "certified winning line must clear interceptor before Red kills finisher")

    local twoTurnState = deepCopy(dossier.scenarioState)
    twoTurnState.turnLimit = 2
    twoTurnState.scenarioTurn = 1
    local shortProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, { maxNodes = 9000 })
    assertEquals(shortProof.status, "no_blue_win_even_with_red_pass", "interceptor Artillery N=3 profile must not compress to two turns")
end)

runTest("dual_rock_lock_ranged_finish_is_compositional_and_not_two_turn_compressible", function()
    local dossier, diagnostics = retroGenerator.generate({
        seed = 601,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = "dual_rock_lock",
        maxAttempts = 1
    })
    assertEquals(dossier.pipelineState, "certified", "dual Rock-lock profile must certify")
    local quality = qualityEvaluator.evaluate(dossier)
    assertEquals(quality.status, "approved", "dual Rock-lock profile must pass quality evaluator")
    assertEquals(quality.features.redPolicyHarnessPass, true, "dual Rock-lock profile must pass Scenario Red Policy harness")
    assertEquals(dossier.compositionalContract.profileId, "dual_rock_lock_ranged_finish", "dual Rock-lock must expose compositional profile")
    local contractOk = compositionComposer.validateContract(dossier.compositionalContract)
    assertTrue(contractOk == true, "dual Rock-lock compositional contract must validate")
    assertTrue(#(dossier.ablationResults or {}) >= 6, "dual Rock-lock must prove six action consequences")
    assertTrue(hasMicro(dossier, "ROCK_AS_LOCK"), "dual Rock-lock profile must include ROCK_AS_LOCK")
    assertTrue(hasMicro(dossier, "LOS_OPEN_RANGED"), "dual Rock-lock profile must include LOS_OPEN_RANGED")
    assertTrue(hasMicro(dossier, "ORDER_DEPENDENCY"), "dual Rock-lock profile must include ORDER_DEPENDENCY")
    assertTrue(dossier.tacticalFingerprint.role_signature:find("dual_rock_lock_chain", 1, true) ~= nil, "fingerprint should name dual Rock-lock chain")
    assertEquals(diagnostics.lastCertification.twoTurnRedPassBoundStatus, "no_blue_win_even_with_red_pass", "dual Rock-lock generator must prove N=3 is binding")

    local twoTurnState = deepCopy(dossier.scenarioState)
    twoTurnState.turnLimit = 2
    twoTurnState.scenarioTurn = 1
    local shortProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, { maxNodes = 9000 })
    assertEquals(shortProof.status, "no_blue_win_even_with_red_pass", "dual Rock-lock N=3 profile must not compress to two turns")
end)

runTest("n3_certificate_rejects_positions_solvable_in_two_turns_under_real_budget", function()
    local dossier = retroGenerator.generate({ seed = 131, turnLimit = 3, solverMaxNodes = 3000 })
    assertEquals(dossier.pipelineState, "certified", "fixture must be certified for this guardrail")
    local twoTurnState = deepCopy(dossier.scenarioState)
    twoTurnState.turnLimit = 2
    twoTurnState.scenarioTurn = 1
    local shortProof = solver.proveNoBlueWinEvenIfRedPasses(twoTurnState, { maxNodes = 3000 })
    assertEquals(shortProof.status, "no_blue_win_even_with_red_pass", "N=3 scenario must not be solvable in two turns even with Red passing")
end)

runTest("generated_micro_interactions_are_library_primitives_not_templates", function()
    local dossier = retroGenerator.generate({ seed = 121, turnLimit = 3, solverMaxNodes = 3000 })
    assertTrue(type(dossier.microInteractions) == "table" and #dossier.microInteractions >= 2, "multiple micro-interactions required")
    for _, micro in ipairs(dossier.microInteractions) do
        local spec = microLibrary.getMicroInteraction(micro.id or micro.microId)
        assertTrue(spec ~= nil, "unknown micro-interaction " .. tostring(micro.id or micro.microId))
        assertTrue(microLibrary.isMacroTemplate(spec) == false, "micro spec must not be a macro-template")
    end
end)

runTest("batch_generation_certifies_ten_distinct_n3_scenarios", function()
    local dossiers, summary = retroGenerator.generateBatch({ seed = 200, count = 10, turnLimit = 3, solverMaxNodes = 3000 })
    assertTrue(type(dossiers) == "table", "dossier batch required")
    assertTrue(type(summary) == "table", "batch summary required")
    assertTrue(#dossiers >= 10, "at least ten dossiers required")
    assertEquals(summary.certifiedCount, #dossiers, "all returned dossiers should be certified")
    assertTrue(summary.noveltyRejectRate <= summary.maxNoveltyRejectRate, "native novelty reject must stay under threshold")

    local fingerprints = {}
    for _, dossier in ipairs(dossiers) do
        assertEquals(dossier.pipelineState, "certified", "batch dossier certified")
        assertTrue(dossier.scenarioState.scenarioTurn >= 1 and dossier.scenarioState.scenarioTurn <= dossier.scenarioState.turnLimit, "batch dossier starts within N")
        assertEquals(dossier.scenarioState.turnLimit, 3, "batch dossier N=3")
        assertEquals(tonumber(dossier.scenarioState.maxActionsPerTurn), 2, "batch dossier must use runtime action budget")
        assertEquals(dossier.solverProof.status, "forced_win", "batch solver proof")
        assertTrue(#(dossier.solution.actions or {}) >= 3, "batch dossier non-trivial line")
        assertLineLegalUnderBudget(dossier.scenarioState, dossier.solution.actions, 2, "batch_solution")
        local signature = dossier.tacticalFingerprint and dossier.tacticalFingerprint.signature
        assertTrue(type(signature) == "string" and signature ~= "", "fingerprint signature required")
        fingerprints[signature] = true
    end

    local distinct = 0
    for _ in pairs(fingerprints) do
        distinct = distinct + 1
    end
    assertTrue(distinct >= 10, "ten distinct tactical fingerprints required")
end)

runTest("retro_generator_has_no_standard_ai_or_runtime_dependency", function()
    local file = io.open("scenario_tooling/retro_generator.lua", "r")
    assertTrue(file ~= nil, "retro_generator.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "retro generator must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "retro generator must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "retro generator must not depend on AI tournament modules")
    assertTrue(content:find("gameRuler", 1, true) == nil, "retro generator must not depend on runtime game ruler")
    assertTrue(content:find("factionSelect", 1, true) == nil, "retro generator must not depend on runtime menus")
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

print(string.format("scenario_retro_generator_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
