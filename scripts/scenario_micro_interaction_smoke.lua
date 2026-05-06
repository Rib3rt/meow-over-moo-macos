package.path = package.path .. ";./?.lua"

local microLibrary = require("scenario_tooling.micro_interaction_library")
local predicateContract = require("scenario_tooling.predicate_contract")

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

local function contains(list, value)
    for _, item in ipairs(list or {}) do
        if item == value then
            return true
        end
    end
    return false
end

runTest("micro_library_is_scenario_only_and_versioned", function()
    assertTrue(microLibrary.isScenarioOnly() == true, "micro library should be scenario-only")
    assertTrue(type(microLibrary.VERSION) == "string" and microLibrary.VERSION ~= "", "version required")
    assertTrue(type(microLibrary.LIBRARY_HASH) == "string" and microLibrary.LIBRARY_HASH ~= "", "hash required")
end)

runTest("micro_library_contains_initial_tactical_primitives", function()
    local micros = microLibrary.listMicroInteractions()
    assertTrue(#micros >= 6, "at least six primitives required")
    for _, id in ipairs({
        "LOS_OPEN_RANGED",
        "FINISHER_CELL_GAIN",
        "SUPPORT_CELL_GAIN",
        "RED_ATTACKS_SUPPORT",
        "RED_ATTACKS_FINISHER",
        "ROCK_AS_LOCK",
        "WRONG_TARGET_TEMPO_LOSS"
    }) do
        assertTrue(microLibrary.getMicroInteraction(id) ~= nil, "missing primitive " .. id)
    end
end)

runTest("micro_specs_have_required_fields_and_predicates", function()
    for _, spec in ipairs(microLibrary.listMicroInteractions()) do
        for _, field in ipairs({
            "id",
            "family",
            "involvedUnits",
            "preconditions",
            "effects",
            "tacticalTension",
            "plausibleFalseLine",
            "compatibility",
            "rejectionSignals",
            "requiredPredicates",
            "ablationSubject",
            "ablationMustChange",
            "fixtureKeys",
            "allowedFinisherFamilies"
        }) do
            assertTrue(spec[field] ~= nil, spec.id .. " missing " .. field)
            if type(spec[field]) == "table" then
                assertTrue(next(spec[field]) ~= nil, spec.id .. " empty " .. field)
            elseif type(spec[field]) == "string" then
                assertTrue(spec[field] ~= "", spec.id .. " empty " .. field)
            end
        end
        for _, predicateName in ipairs(spec.requiredPredicates) do
            assertTrue(predicateContract.getPredicate(predicateName) ~= nil, spec.id .. " uses unfrozen predicate " .. tostring(predicateName))
        end
    end
end)

runTest("micro_ablation_outputs_are_hard_gated", function()
    local allowed = {
        winning_line = true,
        false_line = true,
        red_response = true,
        exactness = true,
        fingerprint = true
    }
    for _, spec in ipairs(microLibrary.listMicroInteractions()) do
        local hasAllowed = false
        for _, output in ipairs(spec.ablationMustChange or {}) do
            hasAllowed = hasAllowed or allowed[output] == true
        end
        assertTrue(hasAllowed, spec.id .. " must change a hard-gated ablation output")
    end
end)

runTest("micro_specs_do_not_encode_macro_templates", function()
    for _, spec in ipairs(microLibrary.listMicroInteractions()) do
        assertTrue(microLibrary.isMacroTemplate(spec) == false, spec.id .. " should not be a macro-template")
        assertTrue(spec.solutionOrder == nil, spec.id .. " must not contain solutionOrder")
        assertTrue(spec.turnSequence == nil, spec.id .. " must not contain turnSequence")
        assertTrue(spec.winningLine == nil, spec.id .. " must not contain winningLine")
        assertTrue(spec.scriptedRedResponses == nil, spec.id .. " must not contain scriptedRedResponses")
    end
end)

runTest("micro_library_rejects_macro_template_shape", function()
    local bad = {
        id = "BAD_TEMPLATE",
        solutionOrder = {"A", "B", "C"},
        scriptedRedResponses = {}
    }
    assertTrue(microLibrary.isMacroTemplate(bad) == true, "macro-template shape should be detected")
end)

runTest("validate_library_reports_all_micro_specs_ok", function()
    local ok, reports = microLibrary.validateLibrary()
    assertTrue(ok, "micro library should validate")
    assertEquals(#reports, #microLibrary.listMicroInteractions(), "one report per primitive")
    for _, report in ipairs(reports) do
        assertEquals(report.ok, true, report.id .. " should pass")
    end
end)

runTest("micro_library_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/micro_interaction_library.lua", "r")
    assertTrue(file ~= nil, "micro_interaction_library.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "micro library must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "micro library must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "micro library must not depend on AI tournament modules")
    assertTrue(content:find("gameplay", 1, true) == nil, "micro library must not depend on gameplay")
    assertTrue(content:find("gameRuler", 1, true) == nil, "micro library must not depend on gameRuler")
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

print(string.format("scenario_micro_interaction_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
