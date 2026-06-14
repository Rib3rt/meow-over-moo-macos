package.path = package.path .. ";./?.lua"

local microLibrary = require("scenario_tooling.micro_interaction_library")
local predicateContract = require("scenario_tooling.predicate_contract")

local componentLibraryOk, componentLibraryOrError = pcall(require, "scenario_tooling.composition_component_library")
if not componentLibraryOk then
    print("[FAIL] composition_component_library_module_loads -> " .. tostring(componentLibraryOrError))
    print("scenario_composition_component_smoke: 0/1 passed")
    print("expected_failure: scenario_tooling/composition_component_library.lua is not implemented yet")
    os.exit(1)
end

local componentLibrary = componentLibraryOrError
local results = {}

local REQUIRED_COMPONENT_IDS = {
    "support_pressure_answer",
    "contact_blocker_clear",
    "finisher_staging_gain",
    "exact_contact_payoff",
    "wrong_target_tempo_branch",
    "finisher_interceptor_clear",
    "dual_rock_lock_chain",
    "rock_lock_conversion",
    "los_open_ranged_lane"
}

local REQUIRED_COMPONENT_FIELDS = {
    "id",
    "version",
    "family",
    "role",
    "involvedUnits",
    "preconditions",
    "producedMicroInteractions",
    "requiredPredicates",
    "consequenceOutputs",
    "ablationSubject",
    "incompatibilities",
    "evidenceRequirements",
    "fixtureKeys"
}

local REQUIRED_CONSEQUENCE_OUTPUTS = {
    winning_line = true,
    red_response = true,
    false_line = true,
    exactness = true,
    outcome = true,
    legal_move_set = true
}

local FORBIDDEN_MACRO_FIELDS = {
    "solutionOrder",
    "turnSequence",
    "winningLine",
    "scriptedRedResponses",
    "fullSolution",
    "redScript",
    "turnScript"
}

local PREDICATE_SET = {}
do
    local i
    for i = 1, #(predicateContract.requiredPredicates or {}) do
        PREDICATE_SET[predicateContract.requiredPredicates[i]] = true
    end
end

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

local function contains(list, expected)
    local _, value
    for _, value in ipairs(list or {}) do
        if value == expected then
            return true
        end
    end
    return false
end

local function deepClone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    local k, v
    for k, v in pairs(value) do
        out[k] = deepClone(v)
    end
    local i = 1
    while value[i] ~= nil do
        out[i] = deepClone(value[i])
        i = i + 1
    end
    return out
end

local function validateComponentOk(component)
    local ok, report = componentLibrary.validateComponent(component)
    assertTrue(ok == true, tostring(component.id) .. " validateComponent should pass")
    if type(report) == "table" and report.ok ~= nil then
        assertTrue(report.ok == true, tostring(component.id) .. " validation report should pass")
    end
end

local function validateComponentRejected(component, label)
    local ok, report = componentLibrary.validateComponent(component)
    assertTrue(ok == false, label .. " should be rejected by validateComponent")
    if type(report) == "table" and report.ok ~= nil then
        assertTrue(report.ok == false, label .. " report should mark rejection")
    end
end

runTest("composition_component_library_contract_shape", function()
    assertTrue(type(componentLibrary.VERSION) == "string" and componentLibrary.VERSION ~= "", "VERSION must be present")
    local libraryId = componentLibrary.LIBRARY_ID or componentLibrary.COMPONENT_LIBRARY_ID
    assertTrue(type(libraryId) == "string" and libraryId ~= "", "LIBRARY_ID or COMPONENT_LIBRARY_ID must be present")
    assertTrue(type(componentLibrary.isScenarioOnly) == "function", "isScenarioOnly must exist")
    assertTrue(componentLibrary.isScenarioOnly() == true, "library must be scenario-only")
    assertTrue(type(componentLibrary.listComponents) == "function", "listComponents must exist")
    assertTrue(type(componentLibrary.getComponent) == "function", "getComponent must exist")
    assertTrue(type(componentLibrary.validateComponent) == "function", "validateComponent must exist")
    assertTrue(type(componentLibrary.validateLibrary) == "function", "validateLibrary must exist")
end)

runTest("required_component_ids_exist", function()
    local components = componentLibrary.listComponents()
    assertTrue(type(components) == "table", "listComponents must return a table")
    for _, id in ipairs(REQUIRED_COMPONENT_IDS) do
        local component = componentLibrary.getComponent(id)
        assertTrue(type(component) == "table", "missing required component " .. id)
        assertEquals(component.id, id, "component id mismatch")
    end
end)

runTest("component_specs_are_computable_and_cross_library_valid", function()
    for _, component in ipairs(componentLibrary.listComponents()) do
        for _, field in ipairs(REQUIRED_COMPONENT_FIELDS) do
            local value = component[field]
            assertTrue(value ~= nil, tostring(component.id) .. " missing " .. field)
            if type(value) == "string" then
                assertTrue(value ~= "", tostring(component.id) .. " empty " .. field)
            elseif type(value) == "table" then
                assertTrue(next(value) ~= nil, tostring(component.id) .. " empty " .. field)
            end
        end

        for _, microId in ipairs(component.producedMicroInteractions or {}) do
            assertTrue(type(microId) == "string" and microId ~= "", tostring(component.id) .. " has invalid micro id")
            assertTrue(microLibrary.getMicroInteraction(microId) ~= nil, tostring(component.id) .. " references missing micro " .. tostring(microId))
        end

        for _, predicateName in ipairs(component.requiredPredicates or {}) do
            assertTrue(PREDICATE_SET[predicateName] == true, tostring(component.id) .. " references unfrozen predicate " .. tostring(predicateName))
        end

        local hasRequiredConsequenceOutput = false
        for _, outputName in ipairs(component.consequenceOutputs or {}) do
            if REQUIRED_CONSEQUENCE_OUTPUTS[outputName] then
                hasRequiredConsequenceOutput = true
            end
        end
        assertTrue(hasRequiredConsequenceOutput, tostring(component.id) .. " must declare at least one required consequence output")

        for _, forbiddenField in ipairs(FORBIDDEN_MACRO_FIELDS) do
            assertTrue(component[forbiddenField] == nil, tostring(component.id) .. " must not contain macro field " .. forbiddenField)
        end

        validateComponentOk(component)
    end
end)

runTest("validate_library_passes", function()
    local ok, reports = componentLibrary.validateLibrary()
    assertTrue(ok == true, "validateLibrary should pass for composition component library")
    assertTrue(type(reports) == "table", "validateLibrary should return reports table")
    for _, report in ipairs(reports) do
        if type(report) == "table" and report.ok ~= nil then
            assertTrue(report.ok == true, tostring(report.id or "component") .. " report should pass")
        end
    end
end)

runTest("validate_component_rejects_negative_mutations", function()
    local source = componentLibrary.getComponent("support_pressure_answer")
    assertTrue(type(source) == "table", "support_pressure_answer fixture component missing")

    local emptyConsequence = deepClone(source)
    emptyConsequence.id = "support_pressure_answer_mut_empty_consequence"
    emptyConsequence.consequenceOutputs = {}
    validateComponentRejected(emptyConsequence, "empty consequenceOutputs mutation")

    local macroTemplate = deepClone(source)
    macroTemplate.id = "support_pressure_answer_mut_macro_field"
    macroTemplate.solutionOrder = { "support_move", "finisher_attack" }
    validateComponentRejected(macroTemplate, "macro-template field mutation")
end)

runTest("component_library_has_no_standard_ai_dependency", function()
    local file = io.open("scenario_tooling/composition_component_library.lua", "r")
    assertTrue(file ~= nil, "composition_component_library.lua must be readable")
    local content = file:read("*a")
    file:close()

    assertTrue(content:find('require("ai', 1, true) == nil, "component library must not require ai")
    assertTrue(content:find("require('ai", 1, true) == nil, "component library must not require ai")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "component library must not require ai_tournament")
    assertTrue(content:find("standardAI", 1, true) == nil, "component library must not require standardAI")
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

print(string.format("scenario_composition_component_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
