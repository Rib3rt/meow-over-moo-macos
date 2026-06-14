package.path = package.path .. ";./?.lua"

local componentLibrary = require("scenario_tooling.composition_component_library")

local composerOk, composerOrError = pcall(require, "scenario_tooling.composition_composer")
if not composerOk then
    print("[FAIL] composition_composer_module_loads -> " .. tostring(composerOrError))
    print("scenario_composition_composer_smoke: 0/1 passed")
    print("expected_failure: scenario_tooling/composition_composer.lua is not implemented yet")
    os.exit(1)
end

local composer = composerOrError
local results = {}

local REQUIRED_PROFILE_ID = "composite_support_pressure_crusher_contact"
local SECOND_PROFILE_ID = "crusher_contact_breach"
local ROCK_LOS_PROFILE_ID = "support_reposition_rock_los_finish"
local SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID = "support_under_real_red_pressure"
local INTERCEPTOR_ARTILLERY_PROFILE_ID = "support_intercepts_finisher_threat_artillery_finish"
local DUAL_ROCK_LOCK_PROFILE_ID = "dual_rock_lock_ranged_finish"
local REQUIRED_COMPONENT_IDS = {
    "support_pressure_answer",
    "contact_blocker_clear",
    "finisher_staging_gain",
    "exact_contact_payoff",
    "wrong_target_tempo_branch"
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

local function normalizeValidationResult(ok, report)
    if type(ok) == "boolean" then
        return ok, report
    end
    if type(ok) == "table" and ok.ok ~= nil then
        return ok.ok == true, ok
    end
    if ok == nil and type(report) == "table" and report.ok ~= nil then
        return report.ok == true, report
    end
    return ok == true, report
end

local function makeIntendedLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 5, col = 4 } },
        { type = "attack", actorId = "blue_a_support", targetId = "red_contact_blocker" },
        { type = "move", actorId = "blue_finisher", to = { row = 5, col = 5 } },
        { type = "move", actorId = "blue_finisher", to = { row = 3, col = 5 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function makeCrusherContactLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 3, col = 5 } },
        { type = "attack", actorId = "blue_a_support", targetId = "red_contact_blocker" },
        { type = "move", actorId = "blue_finisher", to = { row = 5, col = 4 } },
        { type = "move", actorId = "blue_finisher", to = { row = 3, col = 4 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function makeRockLosLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 2, col = 6 } },
        { type = "attack", actorId = "blue_a_support", targetId = "neutral_rock" },
        { type = "move", actorId = "blue_finisher", to = { row = 3, col = 2 } },
        { type = "move", actorId = "blue_finisher", to = { row = 2, col = 2 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function makeSupportPressureRockLosLine()
    return makeRockLosLine()
end

local function makeInterceptorArtilleryLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 6, col = 2 } },
        { type = "attack", actorId = "blue_a_support", targetId = "red_interceptor" },
        { type = "move", actorId = "blue_finisher", to = { row = 6, col = 3 } },
        { type = "move", actorId = "blue_finisher", to = { row = 5, col = 3 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function makeDualRockLockLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 4, col = 2 } },
        { type = "attack", actorId = "blue_a_support", targetId = "neutral_lower_rock" },
        { type = "move", actorId = "blue_a_support", to = { row = 3, col = 2 } },
        { type = "attack", actorId = "blue_a_support", targetId = "neutral_upper_rock" },
        { type = "move", actorId = "blue_finisher", to = { row = 5, col = 4 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function makeActionConsequences(componentIds)
    local out = {}
    local i
    for i = 1, #componentIds do
        local componentId = componentIds[i]
        local componentSpec = componentLibrary.getComponent(componentId) or {}
        out[#out + 1] = {
            ablation_id = "smoke_" .. tostring(componentId) .. "_" .. tostring(i),
            subject_type = "micro_interaction",
            subject_id = tostring(componentId),
            baseline_outcome = "forced_win",
            ablated_outcome = "unsolved",
            horizon = 3,
            actionIndex = i,
            actionSignature = "smoke_action_" .. tostring(i),
            action = makeIntendedLine()[i],
            componentId = componentId,
            microInteractionId = componentSpec.producedMicroInteractions and componentSpec.producedMicroInteractions[1] or "SUPPORT_CELL_GAIN",
            consequence = "smoke consequence",
            status = "proven",
            proven = true,
            changed = true,
            winning_line = true,
            changed_outputs = { "winning_line" }
        }
    end
    return out
end

local function makeContractFixtures()
    local profile = composer.getProfile(REQUIRED_PROFILE_ID)
    assertTrue(type(profile) == "table", "required profile must exist")
    local componentIds = profile.componentIds or {}
    local intendedLine = makeIntendedLine()
    local actionConsequences = makeActionConsequences(componentIds)
    local contract = composer.buildContract(REQUIRED_PROFILE_ID, intendedLine, actionConsequences)
    assertTrue(type(contract) == "table", "buildContract must return contract fixture")
    return profile, componentIds, intendedLine, actionConsequences, contract
end

local function findConsequenceSlotHelper()
    local namedCandidates = {
        "buildConsequenceSlots",
        "buildActionConsequenceSlots",
        "getConsequenceSlots",
        "createConsequenceSlots"
    }
    local i
    for i = 1, #namedCandidates do
        local helperName = namedCandidates[i]
        local helper = composer[helperName]
        if type(helper) == "function" then
            return helperName, helper
        end
    end

    local helperName, helper
    for helperName, helper in pairs(composer) do
        local lowered = tostring(helperName):lower()
        if type(helper) == "function"
            and lowered:find("consequence", 1, true)
            and lowered:find("slot", 1, true) then
            return helperName, helper
        end
    end
    return nil, nil
end

local function normalizeConsequenceSlots(result)
    if type(result) ~= "table" then
        return nil
    end
    if result[1] ~= nil then
        return result
    end
    if type(result.actionConsequences) == "table" then
        return result.actionConsequences
    end
    if type(result.consequenceSlots) == "table" then
        return result.consequenceSlots
    end
    return nil
end

local function invokeConsequenceSlotHelper(helper, profile, intendedLine)
    local attempts = {
        function()
            return helper(REQUIRED_PROFILE_ID, deepClone(intendedLine))
        end,
        function()
            return helper(deepClone(profile), deepClone(intendedLine))
        end,
        function()
            return helper({
                profileId = REQUIRED_PROFILE_ID,
                profile = deepClone(profile),
                intendedLine = deepClone(intendedLine)
            })
        end
    }

    local i
    for i = 1, #attempts do
        local ok, result = pcall(attempts[i])
        if ok then
            local slots = normalizeConsequenceSlots(result)
            if type(slots) == "table" then
                return slots
            end
        end
    end
    return nil
end

local function validateProfile(profile)
    local ok, report = composer.validateProfile(profile)
    return normalizeValidationResult(ok, report)
end

local function validateContract(contract)
    local ok, report = composer.validateContract(contract)
    return normalizeValidationResult(ok, report)
end

runTest("composition_composer_contract_shape", function()
    assertTrue(type(composer.VERSION) == "string" and composer.VERSION ~= "", "VERSION must be present")
    assertTrue(type(composer.COMPOSER_ID) == "string" and composer.COMPOSER_ID ~= "", "COMPOSER_ID must be present")
    assertTrue(type(composer.isScenarioOnly) == "function", "isScenarioOnly must exist")
    assertTrue(composer.isScenarioOnly() == true, "composer must be scenario-only")
    assertTrue(type(composer.getProfile) == "function", "getProfile must exist")
    assertTrue(type(composer.validateProfile) == "function", "validateProfile must exist")
    assertTrue(type(composer.buildContract) == "function", "buildContract must exist")
    assertTrue(type(composer.validateContract) == "function", "validateContract must exist")
end)

runTest("required_profile_exists_and_references_component_library", function()
    local profile = composer.getProfile(REQUIRED_PROFILE_ID)
    assertTrue(type(profile) == "table", "required profile must exist")
    local profileId = profile.id or profile.profileId
    assertEquals(profileId, REQUIRED_PROFILE_ID, "required profile id mismatch")

    local componentIds = profile.componentIds
    assertTrue(type(componentIds) == "table" and #componentIds > 0, "profile.componentIds must exist and be non-empty")

    for _, requiredId in ipairs(REQUIRED_COMPONENT_IDS) do
        assertTrue(contains(componentIds, requiredId), "profile missing required component id " .. requiredId)
    end

    for _, componentId in ipairs(componentIds) do
        local componentSpec = componentLibrary.getComponent(componentId)
        assertTrue(type(componentSpec) == "table", "profile component id missing from component library: " .. tostring(componentId))
    end
end)

runTest("second_profile_crusher_contact_breach_validates_and_contracts", function()
    local profile = composer.getProfile(SECOND_PROFILE_ID)
    assertTrue(type(profile) == "table", "second profile must exist")
    assertEquals(profile.id, SECOND_PROFILE_ID, "second profile id mismatch")
    assertTrue(contains(profile.componentIds, "contact_blocker_clear"), "second profile missing contact blocker component")
    assertTrue(contains(profile.componentIds, "finisher_staging_gain"), "second profile missing staging component")
    assertTrue(contains(profile.componentIds, "exact_contact_payoff"), "second profile missing exact payoff component")
    assertTrue(contains(profile.componentIds, "wrong_target_tempo_branch"), "second profile missing false branch component")

    local profileOk = validateProfile(profile)
    assertTrue(profileOk == true, "second profile should validate")

    local line = makeCrusherContactLine()
    local consequences = composer.buildActionConsequences(
        SECOND_PROFILE_ID,
        {
            { slotId = "support_contact_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "before_1", afterStateHash = "after_1" },
            { slotId = "support_blocker_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "before_2", afterStateHash = "after_2" },
            { slotId = "finisher_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "before_3", afterStateHash = "after_3" },
            { slotId = "crusher_contact_move", actionIndex = 4, action = line[4], beforeStateHash = "before_4", afterStateHash = "after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "before_5", afterStateHash = "after_5" }
        },
        { seed = 300, horizon = 3 }
    )
    assertTrue(type(consequences) == "table" and #consequences == 5, "second profile should build five action consequences")

    local contract = composer.buildContract(SECOND_PROFILE_ID, line, consequences, { seed = 300 })
    assertTrue(type(contract) == "table", "second profile should build contract")
    local contractOk = validateContract(contract)
    assertTrue(contractOk == true, "second profile contract should validate")

    local missing = deepClone(contract)
    table.remove(missing.actionConsequences, 1)
    local missingOk = validateContract(missing)
    assertTrue(missingOk == false, "second profile contract should reject missing action consequence")
end)

runTest("rock_los_profile_validates_and_contracts", function()
    local profile = composer.getProfile(ROCK_LOS_PROFILE_ID)
    assertTrue(type(profile) == "table", "rock/LOS profile must exist")
    assertEquals(profile.id, ROCK_LOS_PROFILE_ID, "rock/LOS profile id mismatch")
    assertTrue(contains(profile.componentIds, "rock_lock_conversion"), "rock/LOS profile missing rock lock component")
    assertTrue(contains(profile.componentIds, "los_open_ranged_lane"), "rock/LOS profile missing LOS component")
    assertTrue(contains(profile.componentIds, "finisher_staging_gain"), "rock/LOS profile missing staging component")
    assertTrue(contains(profile.componentIds, "exact_contact_payoff"), "rock/LOS profile missing payoff component")
    assertTrue(contains(profile.componentIds, "wrong_target_tempo_branch"), "rock/LOS profile missing false branch component")

    local profileOk = validateProfile(profile)
    assertTrue(profileOk == true, "rock/LOS profile should validate")

    local line = makeRockLosLine()
    local consequences = composer.buildActionConsequences(
        ROCK_LOS_PROFILE_ID,
        {
            { slotId = "support_los_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "before_1", afterStateHash = "after_1" },
            { slotId = "support_rock_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "before_2", afterStateHash = "after_2" },
            { slotId = "finisher_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "before_3", afterStateHash = "after_3" },
            { slotId = "finisher_los_cell_move", actionIndex = 4, action = line[4], beforeStateHash = "before_4", afterStateHash = "after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "before_5", afterStateHash = "after_5" }
        },
        { seed = 131, horizon = 3 }
    )
    assertTrue(type(consequences) == "table" and #consequences == 5, "rock/LOS profile should build five action consequences")

    local contract = composer.buildContract(ROCK_LOS_PROFILE_ID, line, consequences, { seed = 131 })
    assertTrue(type(contract) == "table", "rock/LOS profile should build contract")
    local contractOk = validateContract(contract)
    assertTrue(contractOk == true, "rock/LOS profile contract should validate")

    local missing = deepClone(contract)
    table.remove(missing.actionConsequences, 2)
    local missingOk = validateContract(missing)
    assertTrue(missingOk == false, "rock/LOS profile contract should reject missing action consequence")
end)

runTest("support_pressure_rock_los_profile_validates_and_contracts", function()
    local profile = composer.getProfile(SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID)
    assertTrue(type(profile) == "table", "support pressure Rock/LOS profile must exist")
    assertEquals(profile.id, SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID, "support pressure Rock/LOS profile id mismatch")
    assertTrue(contains(profile.componentIds, "support_pressure_answer"), "support pressure Rock/LOS profile missing pressure component")
    assertTrue(contains(profile.componentIds, "rock_lock_conversion"), "support pressure Rock/LOS profile missing rock lock component")
    assertTrue(contains(profile.componentIds, "los_open_ranged_lane"), "support pressure Rock/LOS profile missing LOS component")
    assertTrue(contains(profile.componentIds, "finisher_staging_gain"), "support pressure Rock/LOS profile missing staging component")
    assertTrue(contains(profile.componentIds, "exact_contact_payoff"), "support pressure Rock/LOS profile missing payoff component")
    assertTrue(contains(profile.componentIds, "wrong_target_tempo_branch"), "support pressure Rock/LOS profile missing false branch component")

    local profileOk = validateProfile(profile)
    assertTrue(profileOk == true, "support pressure Rock/LOS profile should validate")

    local line = makeSupportPressureRockLosLine()
    local consequences = composer.buildActionConsequences(
        SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID,
        {
            { slotId = "support_pressure_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "before_1", afterStateHash = "after_1" },
            { slotId = "support_rock_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "before_2", afterStateHash = "after_2" },
            { slotId = "finisher_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "before_3", afterStateHash = "after_3" },
            { slotId = "finisher_los_cell_move", actionIndex = 4, action = line[4], beforeStateHash = "before_4", afterStateHash = "after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "before_5", afterStateHash = "after_5" }
        },
        { seed = 202, horizon = 3 }
    )
    assertTrue(type(consequences) == "table" and #consequences == 5, "support pressure Rock/LOS profile should build five action consequences")

    local contract = composer.buildContract(SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID, line, consequences, { seed = 202 })
    assertTrue(type(contract) == "table", "support pressure Rock/LOS profile should build contract")
    local contractOk = validateContract(contract)
    assertTrue(contractOk == true, "support pressure Rock/LOS profile contract should validate")

    local missing = deepClone(contract)
    table.remove(missing.actionConsequences, 1)
    local missingOk = validateContract(missing)
    assertTrue(missingOk == false, "support pressure Rock/LOS profile contract should reject missing pressure action consequence")
end)

runTest("interceptor_artillery_profile_validates_and_contracts", function()
    local profile = composer.getProfile(INTERCEPTOR_ARTILLERY_PROFILE_ID)
    assertTrue(type(profile) == "table", "interceptor Artillery profile must exist")
    assertEquals(profile.id, INTERCEPTOR_ARTILLERY_PROFILE_ID, "interceptor Artillery profile id mismatch")
    assertTrue(contains(profile.componentIds, "finisher_interceptor_clear"), "interceptor Artillery profile missing interceptor component")
    assertTrue(contains(profile.componentIds, "finisher_staging_gain"), "interceptor Artillery profile missing staging component")
    assertTrue(contains(profile.componentIds, "exact_contact_payoff"), "interceptor Artillery profile missing payoff component")
    assertTrue(contains(profile.componentIds, "wrong_target_tempo_branch"), "interceptor Artillery profile missing false branch component")

    local profileOk = validateProfile(profile)
    assertTrue(profileOk == true, "interceptor Artillery profile should validate")

    local line = makeInterceptorArtilleryLine()
    local consequences = composer.buildActionConsequences(
        INTERCEPTOR_ARTILLERY_PROFILE_ID,
        {
            { slotId = "support_interceptor_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "before_1", afterStateHash = "after_1" },
            { slotId = "support_interceptor_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "before_2", afterStateHash = "after_2" },
            { slotId = "artillery_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "before_3", afterStateHash = "after_3" },
            { slotId = "artillery_final_cell_move", actionIndex = 4, action = line[4], beforeStateHash = "before_4", afterStateHash = "after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "before_5", afterStateHash = "after_5" }
        },
        { seed = 501, horizon = 3 }
    )
    assertTrue(type(consequences) == "table" and #consequences == 5, "interceptor Artillery profile should build five action consequences")

    local contract = composer.buildContract(INTERCEPTOR_ARTILLERY_PROFILE_ID, line, consequences, { seed = 501 })
    assertTrue(type(contract) == "table", "interceptor Artillery profile should build contract")
    local contractOk = validateContract(contract)
    assertTrue(contractOk == true, "interceptor Artillery profile contract should validate")

    local missing = deepClone(contract)
    table.remove(missing.actionConsequences, 2)
    local missingOk = validateContract(missing)
    assertTrue(missingOk == false, "interceptor Artillery profile contract should reject missing interceptor consequence")

    local duplicate = deepClone(contract)
    duplicate.actionConsequences[#duplicate.actionConsequences + 1] = deepClone(duplicate.actionConsequences[2])
    local duplicateOk = validateContract(duplicate)
    assertTrue(duplicateOk == false, "interceptor Artillery profile contract should reject duplicate key-action consequence coverage")
end)

runTest("dual_rock_lock_profile_validates_and_contracts", function()
    local profile = composer.getProfile(DUAL_ROCK_LOCK_PROFILE_ID)
    assertTrue(type(profile) == "table", "dual Rock-lock profile must exist")
    assertEquals(profile.id, DUAL_ROCK_LOCK_PROFILE_ID, "dual Rock-lock profile id mismatch")
    assertTrue(contains(profile.componentIds, "dual_rock_lock_chain"), "dual Rock-lock profile missing dual lock component")
    assertTrue(contains(profile.componentIds, "los_open_ranged_lane"), "dual Rock-lock profile missing LOS component")
    assertTrue(contains(profile.componentIds, "exact_contact_payoff"), "dual Rock-lock profile missing payoff component")
    assertTrue(contains(profile.componentIds, "wrong_target_tempo_branch"), "dual Rock-lock profile missing false branch component")

    local profileOk = validateProfile(profile)
    assertTrue(profileOk == true, "dual Rock-lock profile should validate")

    local line = makeDualRockLockLine()
    local consequences = composer.buildActionConsequences(
        DUAL_ROCK_LOCK_PROFILE_ID,
        {
            { slotId = "support_lower_lock_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "before_1", afterStateHash = "after_1" },
            { slotId = "support_lower_rock_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "before_2", afterStateHash = "after_2" },
            { slotId = "support_upper_lock_setup_move", actionIndex = 3, action = line[3], beforeStateHash = "before_3", afterStateHash = "after_3" },
            { slotId = "support_upper_rock_clear_attack", actionIndex = 4, action = line[4], beforeStateHash = "before_4", afterStateHash = "after_4" },
            { slotId = "finisher_dual_lock_cell_move", actionIndex = 5, action = line[5], beforeStateHash = "before_5", afterStateHash = "after_5" },
            { slotId = "commandant_payoff_attack", actionIndex = 6, action = line[6], beforeStateHash = "before_6", afterStateHash = "after_6" }
        },
        { seed = 601, horizon = 3 }
    )
    assertTrue(type(consequences) == "table" and #consequences == 6, "dual Rock-lock profile should build six action consequences")

    local contract = composer.buildContract(DUAL_ROCK_LOCK_PROFILE_ID, line, consequences, { seed = 601 })
    assertTrue(type(contract) == "table", "dual Rock-lock profile should build contract")
    local contractOk = validateContract(contract)
    assertTrue(contractOk == true, "dual Rock-lock profile contract should validate")

    local missing = deepClone(contract)
    table.remove(missing.actionConsequences, 4)
    local missingOk = validateContract(missing)
    assertTrue(missingOk == false, "dual Rock-lock profile contract should reject missing upper-lock consequence")
end)

runTest("validate_profile_accepts_profile_and_rejects_mutations", function()
    local profile = composer.getProfile(REQUIRED_PROFILE_ID)
    assertTrue(type(profile) == "table", "required profile must exist")

    local ok = validateProfile(profile)
    assertTrue(ok == true, "validateProfile should pass for required profile")

    local missingComponentIds = deepClone(profile)
    missingComponentIds.componentIds = nil
    local missingOk = validateProfile(missingComponentIds)
    assertTrue(missingOk == false, "validateProfile must reject missing componentIds")

    local duplicateIds = deepClone(profile)
    duplicateIds.componentIds = deepClone(profile.componentIds or {})
    duplicateIds.componentIds[#duplicateIds.componentIds + 1] = duplicateIds.componentIds[1]
    local duplicateOk = validateProfile(duplicateIds)
    assertTrue(duplicateOk == false, "validateProfile must reject duplicate component ids")
end)

runTest("build_contract_shape_and_component_expansion", function()
    local profile = composer.getProfile(REQUIRED_PROFILE_ID)
    local componentIds = profile.componentIds or {}
    local intendedLine = makeIntendedLine()
    local actionConsequences = makeActionConsequences(componentIds)

    local contract = composer.buildContract(REQUIRED_PROFILE_ID, intendedLine, actionConsequences, { seed = 410 })
    assertTrue(type(contract) == "table", "buildContract must return a table")
    assertTrue(type(contract.schema) == "string" and contract.schema ~= "", "contract.schema must exist")
    assertTrue(type(contract.version) == "string" and contract.version ~= "", "contract.version must exist")
    assertTrue(type(contract.pattern) == "string" and contract.pattern ~= "", "contract.pattern must exist")
    assertEquals(contract.seed, 410, "contract.seed mismatch")
    assertEquals(contract.profileId, REQUIRED_PROFILE_ID, "contract.profileId mismatch")
    assertTrue(type(contract.components) == "table" and #contract.components > 0, "contract.components must exist")
    assertTrue(type(contract.intendedLine) == "table", "contract.intendedLine must exist")
    assertTrue(type(contract.actionConsequences) == "table", "contract.actionConsequences must exist")

    for _, component in ipairs(contract.components) do
        assertTrue(type(component) == "table", "contract.components entries must be records")
        assertTrue(type(component.id) == "string" and component.id ~= "", "component record missing id")
        assertTrue(type(component.family) == "string" and component.family ~= "", "component record missing family")
        assertTrue(type(component.role) == "string" and component.role ~= "", "component record missing role")
        assertTrue(type(component.producedMicroInteractions) == "table", "component record missing producedMicroInteractions")
        assertTrue(type(component.consequenceOutputs) == "table", "component record missing consequenceOutputs")
    end
end)

runTest("build_contract_supports_composer_owned_consequence_slots_when_available", function()
    local profile, componentIds, intendedLine, actionConsequences = makeContractFixtures()
    assertTrue(#componentIds > 0, "required profile must include componentIds")
    assertTrue(#actionConsequences > 0, "fixture action consequences must be non-empty")

    local helperName, helper = findConsequenceSlotHelper()
    if not helper then
        local contract = composer.buildContract(REQUIRED_PROFILE_ID, intendedLine, actionConsequences, { seed = 910 })
        assertTrue(type(contract) == "table", "buildContract must work without consequence slot helper")
        assertEquals(contract.seed, 910, "contract.seed mismatch without helper")
        assertTrue(type(contract.actionConsequences) == "table" and #contract.actionConsequences > 0, "contract.actionConsequences must be preserved")
        return
    end

    local slots = invokeConsequenceSlotHelper(helper, profile, intendedLine)
    assertTrue(type(slots) == "table", "consequence slot helper must return a slot/action consequence list: " .. tostring(helperName))
    local contract = composer.buildContract(REQUIRED_PROFILE_ID, intendedLine, slots, { seed = 911 })
    assertTrue(type(contract) == "table", "buildContract must accept composer-owned consequence slots")
    assertEquals(contract.seed, 911, "contract.seed mismatch with helper")
    assertTrue(type(contract.actionConsequences) == "table", "contract.actionConsequences must exist with helper")
    if #slots > 0 then
        assertEquals(#contract.actionConsequences, #slots, "contract.actionConsequences must preserve helper slot count")
    end
end)

runTest("validate_contract_accepts_complete_exact_one_to_one_coverage", function()
    local _, _, _, _, contract = makeContractFixtures()
    local ok = validateContract(contract)
    assertTrue(ok == true, "validateContract should pass for a complete one-to-one key-action consequence contract")
end)

runTest("validate_contract_rejects_duplicate_key_blue_action_coverage", function()
    local _, _, _, _, contract = makeContractFixtures()
    local duplicateCoverage = deepClone(contract)
    duplicateCoverage.actionConsequences[#duplicateCoverage.actionConsequences + 1] = deepClone(duplicateCoverage.actionConsequences[1])
    local duplicateOk = validateContract(duplicateCoverage)
    assertTrue(duplicateOk == false, "validateContract must reject duplicate proven changed consequence coverage for the same key Blue action/signature/index")
end)

runTest("validate_contract_rejects_missing_key_blue_action_coverage", function()
    local _, _, _, _, contract = makeContractFixtures()
    local missingBlueCoverage = deepClone(contract)
    missingBlueCoverage.actionConsequences[1].proven = false
    missingBlueCoverage.actionConsequences[1].status = "pending"
    missingBlueCoverage.actionConsequences[1].changed = false
    missingBlueCoverage.actionConsequences[1].changed_outputs = {}
    local missingBlueCoverageOk = validateContract(missingBlueCoverage)
    assertTrue(missingBlueCoverageOk == false, "validateContract must reject when any key Blue action lacks exactly one proven changed consequence")
end)

runTest("validate_contract_rejects_required_component_with_zero_proven_coverage", function()
    local _, componentIds, _, _, contract = makeContractFixtures()
    local noComponentCoverage = deepClone(contract)
    local uncoveredComponentId = componentIds[1]
    for _, consequence in ipairs(noComponentCoverage.actionConsequences) do
        if consequence.componentId == uncoveredComponentId or consequence.subject_id == uncoveredComponentId then
            consequence.proven = false
            consequence.status = "pending"
            consequence.changed = false
            consequence.changed_outputs = {}
        end
    end
    local uncoveredOk = validateContract(noComponentCoverage)
    assertTrue(uncoveredOk == false, "validateContract must reject when any required profile component has zero proven consequence coverage")
end)

runTest("validate_contract_rejects_removed_required_component_with_remaining_action_consequences", function()
    local _, _, _, _, contract = makeContractFixtures()
    local removed = deepClone(contract)
    assertTrue(type(removed.components) == "table" and #removed.components > 1, "contract.components must be removable for this test")
    local removedComponentId = removed.components[1].id
    table.remove(removed.components, 1)
    if type(removed.componentIds) == "table" then
        local filtered = {}
        for _, componentId in ipairs(removed.componentIds) do
            if componentId ~= removedComponentId then
                filtered[#filtered + 1] = componentId
            end
        end
        removed.componentIds = filtered
    end
    assertTrue(type(removed.actionConsequences) == "table" and #removed.actionConsequences > 0, "actionConsequences must remain populated for removed-component coverage test")

    local removedOk = validateContract(removed)
    assertTrue(removedOk == false, "validateContract must reject contracts missing required components while actionConsequences remain")

    local emptyConsequences = deepClone(contract)
    emptyConsequences.actionConsequences = {}
    local emptyOk = validateContract(emptyConsequences)
    assertTrue(emptyOk == false, "validateContract must reject empty actionConsequences")
end)

runTest("composition_composer_has_no_standard_ai_or_runtime_gameplay_dependencies", function()
    local file = io.open("scenario_tooling/composition_composer.lua", "r")
    assertTrue(file ~= nil, "composition_composer.lua must be readable")
    local content = file:read("*a")
    file:close()

    assertTrue(content:find('require("ai', 1, true) == nil, "composer must not require ai")
    assertTrue(content:find("require('ai", 1, true) == nil, "composer must not require ai")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "composer must not require ai_tournament")
    assertTrue(content:find("standardAI", 1, true) == nil, "composer must not require standardAI")
    assertTrue(content:find('require("gameplay', 1, true) == nil, "composer must not require gameplay")
    assertTrue(content:find("require('gameplay", 1, true) == nil, "composer must not require gameplay")
    assertTrue(content:find('require("gameRuler', 1, true) == nil, "composer must not require gameRuler")
    assertTrue(content:find("require('gameRuler", 1, true) == nil, "composer must not require gameRuler")
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

print(string.format("scenario_composition_composer_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
