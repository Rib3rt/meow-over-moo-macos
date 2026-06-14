package.path = package.path .. ";./?.lua"

local qualityEvaluator = require("scenario_tooling.quality_evaluator")
local retroGenerator = require("scenario_tooling.retro_generator")
local negativeFixtures = require("scenario_tooling.negative_fixtures")

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

local function hasReason(result, code)
    for _, reason in ipairs(result.reasons or {}) do
        if reason.code == code or reason == code then
            return true
        end
    end
    for _, reason in ipairs(result.unknowns or {}) do
        if reason.code == code or reason == code then
            return true
        end
    end
    return false
end

local function predicate(name, value)
    return {
        schema = "PredicateResult",
        predicate = name,
        predicateVersion = "test",
        inputDigest = "test:" .. name,
        status = tostring(value),
        value = value,
        deterministic = true,
        ownerModule = "scenario_quality_evaluator_smoke"
    }
end

runTest("quality_evaluator_is_scenario_only_and_versioned", function()
    assertTrue(qualityEvaluator.isScenarioOnly() == true, "quality evaluator should be scenario-only")
    assertTrue(type(qualityEvaluator.VERSION) == "string" and qualityEvaluator.VERSION ~= "", "version required")
    assertTrue(type(qualityEvaluator.EVALUATOR_ID) == "string" and qualityEvaluator.EVALUATOR_ID ~= "", "evaluator id required")
    assertTrue(type(qualityEvaluator.EVALUATOR_HASH) == "string" and qualityEvaluator.EVALUATOR_HASH ~= "", "evaluator hash required")
end)

runTest("quality_evaluator_rejects_step_minus_1_negative_fixtures", function()
    local reports = qualityEvaluator.evaluateFixtures()
    assertEquals(#reports, #negativeFixtures.list(), "one result per negative fixture")
    for _, report in ipairs(reports) do
        assertTrue(report.status ~= "approved", report.fixtureId .. " must not approve")
        if report.expectedOutcome == "reject" then
            assertEquals(report.status, "reject", report.fixtureId .. " should reject")
        end
    end
end)

runTest("negative_fixture_required_ids_are_present", function()
    for _, fixtureId in ipairs(negativeFixtures.requiredFixtureIds or {}) do
        assertTrue(type(negativeFixtures.getById(fixtureId)) == "table", fixtureId .. " fixture missing")
    end
end)

runTest("quality_evaluator_rejects_specific_failed_system_patterns", function()
    local cases = {
        already_ready_damage_clock = "static_damage_clock",
        free_finisher_move_and_shoot = "free_finisher_move",
        support_already_in_position = "support_already_free",
        cosmetic_red_pressure = "cosmetic_red_pressure",
        decorative_rock = "decorative_micro_interaction",
        micro_interactions_same_order = "macro_template_signature",
        finisher_library_macro_template = "macro_template_signature"
    }
    for fixtureId, reasonCode in pairs(cases) do
        local fixture = negativeFixtures.getById(fixtureId)
        local result = qualityEvaluator.evaluateFixture(fixture)
        assertEquals(result.status, "reject", fixtureId .. " should reject")
        assertTrue(hasReason(result, reasonCode), fixtureId .. " should include " .. reasonCode)
    end
end)

runTest("quality_evaluator_rejects_persistent_composition_negative_fixtures", function()
    local cases = {
        component_listed_without_action_consequence = "invalid_compositional_contract",
        component_consequence_empty_changed_outputs = "invalid_compositional_contract",
        component_pressure_blocker_same_unit = "composite_pressure_blocker_same_unit",
        component_first_move_obvious_attack = "composite_too_obvious_first_move",
        component_order_scripted_macro_template = "macro_template_signature",
        crusher_component_listed_without_action_consequence = "invalid_compositional_contract",
        crusher_component_consequence_empty_changed_outputs = "invalid_compositional_contract",
        crusher_component_first_move_obvious_attack = "composite_too_obvious_first_move",
        rock_lock_component_decorative = "decorative_micro_interaction",
        los_opening_component_already_open = "decorative_micro_interaction",
        rock_los_component_listed_without_action_consequence = "invalid_compositional_contract",
        rock_los_component_consequence_empty_changed_outputs = "invalid_compositional_contract",
        support_pressure_rock_los_component_listed_without_action_consequence = "invalid_compositional_contract",
        support_pressure_rock_los_component_consequence_empty_changed_outputs = "invalid_compositional_contract",
        support_pressure_not_real_or_cosmetic = "cosmetic_red_pressure",
        support_pressure_unit_free_to_remove_opening = "composite_pressure_free_to_remove",
        support_pressure_rock_decorative = "decorative_micro_interaction",
        support_pressure_los_already_open = "decorative_micro_interaction",
        interceptor_artillery_component_listed_without_action_consequence = "invalid_compositional_contract",
        interceptor_artillery_component_consequence_empty_changed_outputs = "invalid_compositional_contract",
        interceptor_artillery_pressure_not_real_or_cosmetic = "cosmetic_red_pressure",
        interceptor_artillery_pressure_free_to_remove = "composite_pressure_free_to_remove",
        interceptor_artillery_interceptor_decorative = "decorative_micro_interaction",
        interceptor_artillery_finisher_final_cell_free = "free_finisher_move",
        interceptor_artillery_scripted_policy_line_macro_template = "macro_template_signature",
        dual_lock_component_listed_without_action_consequence = "invalid_compositional_contract",
        dual_lock_component_consequence_empty_changed_outputs = "invalid_compositional_contract",
        dual_lock_upper_rock_decorative = "decorative_micro_interaction",
        dual_lock_lane_already_open = "free_finisher_move",
        dual_lock_scripted_macro_template = "macro_template_signature"
    }
    for fixtureId, reasonCode in pairs(cases) do
        local fixture = negativeFixtures.getById(fixtureId)
        assertTrue(type(fixture) == "table", fixtureId .. " fixture missing")
        local result = qualityEvaluator.evaluateFixture(fixture)
        assertEquals(result.status, "reject", fixtureId .. " should reject")
        assertTrue(hasReason(result, reasonCode), fixtureId .. " should include " .. reasonCode)
    end
end)

runTest("quality_evaluator_approves_controlled_good_certified_fixture", function()
    local dossier = retroGenerator.generate({ seed = 410, turnLimit = 3, solverMaxNodes = 3000 })
    local result = qualityEvaluator.evaluate(dossier)
    assertEquals(dossier.pipelineState, "certified", "generator should produce certified fixture")
    assertEquals(result.status, "approved", "controlled good fixture should approve")
    assertTrue(result.score >= result.threshold, "approved fixture should meet score threshold")
    assertTrue(result.features.falseLineCount >= 1, "approved fixture should include false line")
    assertTrue(result.features.microInteractionCount >= 2, "approved fixture should include multiple micro-interactions")
    assertTrue(result.features.solutionActionCount >= 3, "approved fixture should include a non-trivial action line")
    assertTrue(result.features.distinctSolutionActors >= 2, "approved fixture should require multiple Blue actors")
    assertTrue(result.features.blueUnitCount >= 2, "approved fixture should include multiple Blue units")
    assertTrue(result.features.hasStructuralMicro == true, "approved fixture should include structural micro")
    assertTrue(result.features.hasSupportMicro == true, "approved fixture should include support micro")
end)

runTest("quality_evaluator_preserves_384_513_contract_floor", function()
    local cases = {
        { name = "384", seed = 1782660757 },
        { name = "513", seed = 2791865279 }
    }
    for _, case in ipairs(cases) do
        local dossier = retroGenerator.generate({
            seed = case.seed,
            turnLimit = 3,
            archetype = "composite_support_pressure_crusher_contact",
            solverMaxNodes = 9000,
            maxAttempts = 1
        })
        local result = qualityEvaluator.evaluate(dossier)
        assertEquals(dossier.pipelineState, "certified", case.name .. " contract floor should certify")
        assertEquals(result.status, "approved", case.name .. " contract floor should approve")
        assertTrue(result.features.blueCoordination == true, case.name .. " should require support/finisher coordination")
        assertTrue(result.features.redFinisherPressure == true, case.name .. " should have real Red pressure on the finisher")
        assertTrue(result.features.uniqueFinisher == true, case.name .. " should have exactly one computable finisher")
        assertEquals(result.features.declaredFinisherId, "blue_finisher", case.name .. " should declare the proof finisher")
        assertTrue(result.features.firstActionAttacksActiveRed == false, case.name .. " first action should not be an obvious attack")
        assertTrue((result.features.blueSupportActionCount or 0) >= 2, case.name .. " support must take repeated meaningful actions")
        assertTrue((result.features.blueSupportActorCount or 0) >= 1, case.name .. " support contribution may come from one or more non-finisher Blue units")
        assertTrue((result.features.blueFinisherActionCount or 0) >= 2, case.name .. " finisher must take repeated meaningful actions")
    end
end)

runTest("quality_evaluator_rejects_weak_editor_pool_patterns", function()
    local cases = {
        { name = "standalone crusher contact", seed = 142, archetype = "crusher_contact_breach" },
        { name = "dual rock without active pressure", seed = 142, archetype = "dual_rock_lock_ranged_finish" }
    }
    for _, case in ipairs(cases) do
        local dossier = retroGenerator.generate({
            seed = case.seed,
            turnLimit = 3,
            archetype = case.archetype,
            solverMaxNodes = 9000,
            maxAttempts = 1
        })
        local result = qualityEvaluator.evaluate(dossier)
        assertEquals(result.status, "reject", case.name .. " should not pass the release quality floor")
        assertTrue(hasReason(result, "missing_finisher_red_pressure"), case.name .. " should fail for missing active Red finisher pressure")
    end
end)

runTest("quality_evaluator_never_approves_without_certificate", function()
    local dossier = retroGenerator.generate({ seed = 420, turnLimit = 3, solverMaxNodes = 3000 })
    local withoutCertificate = deepCopy(dossier)
    withoutCertificate.proofCertificate = nil
    local result = qualityEvaluator.evaluate(withoutCertificate)
    assertTrue(result.status ~= "approved", "missing certificate must block approval")
    assertTrue(hasReason(result, "missing_proof_certificate"), "missing certificate reason required")

    local candidateOnly = deepCopy(dossier)
    candidateOnly.pipelineState = "candidate"
    local candidateResult = qualityEvaluator.evaluate(candidateOnly)
    assertTrue(candidateResult.status ~= "approved", "candidate state must not approve")
    assertTrue(hasReason(candidateResult, "not_certified"), "not certified reason required")
end)

runTest("quality_evaluator_rejects_macro_and_decorative_variants", function()
    local dossier = retroGenerator.generate({ seed = 430, turnLimit = 3, solverMaxNodes = 3000 })

    local macro = deepCopy(dossier)
    macro.predicateResults[#macro.predicateResults + 1] = predicate("macro_template_signature", true)
    local macroResult = qualityEvaluator.evaluate(macro)
    assertEquals(macroResult.status, "reject", "macro-template variant should reject")
    assertTrue(hasReason(macroResult, "macro_template_signature"), "macro-template reason required")

    local decorative = deepCopy(dossier)
    decorative.predicateResults[#decorative.predicateResults + 1] = predicate("non_decorative_micro", false)
    local decorativeResult = qualityEvaluator.evaluate(decorative)
    assertEquals(decorativeResult.status, "reject", "decorative variant should reject")
    assertTrue(hasReason(decorativeResult, "decorative_micro_interaction"), "decorative reason required")
end)

runTest("quality_evaluator_contract_includes_support_finisher_coordination_guards", function()
    local file = io.open("scenario_tooling/quality_evaluator.lua", "r")
    assertTrue(file ~= nil, "quality_evaluator.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('dossier.contractPattern == "support_under_real_red_pressure"', 1, true) ~= nil, "support pressure profile must be part of compositional contract checks")
    assertTrue(content:find("missing_finisher_red_pressure", 1, true) ~= nil, "quality contract must reject missing active Red pressure on finisher")
    assertTrue(content:find("missing_blue_coordination", 1, true) ~= nil, "quality contract must reject missing support/finisher coordination")
    assertTrue(content:find("blueSupportActionCount", 1, true) ~= nil, "quality features must count support actions")
    assertTrue(content:find("blueSupportActorCount", 1, true) ~= nil, "quality features must allow support actions across one or more support actors")
    assertTrue(content:find("blueFinisherActionCount", 1, true) ~= nil, "quality features must count finisher actions")
    assertTrue(content:find("firstBlueIsSupportSetup", 1, true) ~= nil, "quality features must require support setup before finisher routine")
    assertTrue(content:find("supportAttackBeforePayoff", 1, true) ~= nil, "quality features must prove support resolves a blocker/lock before payoff")
    assertTrue(content:find("uniqueFinisher", 1, true) ~= nil, "quality features must prove there is exactly one finisher")
    assertTrue(content:find("multiple_or_missing_finisher", 1, true) ~= nil, "quality contract must reject multiple or missing finishers")
    assertTrue(content:find("actor ~= finisherId", 1, true) ~= nil, "support role must be computed as non-finisher Blue actors, not one hardcoded support unit")
    assertTrue(content:find("single_actor_solution", 1, true) ~= nil, "quality contract must reject solo-actor solution lines")
    assertTrue(content:find("missing_support_micro", 1, true) ~= nil, "quality contract must require support participation evidence")
    assertTrue(content:find("composite_too_obvious_first_move", 1, true) ~= nil, "quality contract must reject obvious opening attacks on pressure/blocker")
end)

runTest("quality_evaluator_rejects_support_pressure_without_active_real_red_pressure", function()
    local fixture = negativeFixtures.getById("support_pressure_not_real_or_cosmetic")
    assertTrue(type(fixture) == "table", "support pressure fixture missing")
    local result = qualityEvaluator.evaluateFixture(fixture)
    assertEquals(result.status, "reject", "support profile without active real pressure should reject")
    assertTrue(hasReason(result, "red_pressure_not_real"), "missing active real pressure reason required")
end)

runTest("quality_evaluator_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/quality_evaluator.lua", "r")
    assertTrue(file ~= nil, "quality_evaluator.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "quality evaluator must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "quality evaluator must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "quality evaluator must not depend on AI tournament modules")
    assertTrue(content:find("ai_config", 1, true) == nil, "quality evaluator must not depend on AI config")
    assertTrue(content:find("gameRuler", 1, true) == nil, "quality evaluator must not depend on runtime game ruler")
    assertTrue(content:find("factionSelect", 1, true) == nil, "quality evaluator must not depend on runtime menus")
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

print(string.format("scenario_quality_evaluator_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
