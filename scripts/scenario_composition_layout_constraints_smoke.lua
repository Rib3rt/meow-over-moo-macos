package.path = package.path .. ";./?.lua"

local layoutConstraints = require("scenario_tooling.composition_layout_constraints")
local retroGenerator = require("scenario_tooling.retro_generator")
local stateEngine = require("scenario_tooling.state_engine")

local results = {}

local PROFILE_ID = "composite_support_pressure_crusher_contact"
local CRUSHER_PROFILE_ID = "crusher_contact_breach"
local ROCK_LOS_PROFILE_ID = "support_reposition_rock_los_finish"
local SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID = "support_under_real_red_pressure"
local INTERCEPTOR_ARTILLERY_PROFILE_ID = "support_intercepts_finisher_threat_artillery_finish"
local DUAL_ROCK_LOCK_PROFILE_ID = "dual_rock_lock_ranged_finish"

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

local function deepClone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    local k, v
    for k, v in pairs(value) do
        out[k] = deepClone(v)
    end
    return out
end

local function hasError(report, code)
    for _, err in ipairs(report and report.errors or {}) do
        if tostring(err) == code then
            return true
        end
    end
    return false
end

local function findUnit(state, id)
    for _, unit in ipairs(state and state.units or {}) do
        if unit.id == id then
            return unit
        end
    end
    return nil
end

local function assertCell(cell, row, col, label)
    assertTrue(type(cell) == "table", label .. " cell missing")
    assertEquals(tonumber(cell.row), row, label .. " row")
    assertEquals(tonumber(cell.col), col, label .. " col")
end

local function assertUnit(state, id, name, row, col, currentHp, startingHp)
    local unit = findUnit(state, id)
    assertTrue(type(unit) == "table", id .. " missing")
    assertEquals(unit.name, name, id .. " unit type")
    assertEquals(tonumber(unit.row), row, id .. " row")
    assertEquals(tonumber(unit.col), col, id .. " col")
    assertEquals(tonumber(unit.currentHp), currentHp, id .. " currentHp")
    assertEquals(tonumber(unit.startingHp), startingHp, id .. " startingHp")
end

runTest("layout_constraints_contract_shape", function()
    assertTrue(type(layoutConstraints.VERSION) == "string" and layoutConstraints.VERSION ~= "", "VERSION required")
    assertTrue(type(layoutConstraints.CONSTRAINTS_ID) == "string" and layoutConstraints.CONSTRAINTS_ID ~= "", "CONSTRAINTS_ID required")
    assertTrue(type(layoutConstraints.isScenarioOnly) == "function", "isScenarioOnly required")
    assertEquals(layoutConstraints.isScenarioOnly(), true, "layout constraints must be scenario-only")
    assertTrue(type(layoutConstraints.listLayoutSpecs) == "function", "listLayoutSpecs required")
    assertTrue(type(layoutConstraints.getBaselineLayoutSpec) == "function", "getBaselineLayoutSpec required")
    assertTrue(type(layoutConstraints.validateLayoutSpec) == "function", "validateLayoutSpec required")
    assertTrue(type(layoutConstraints.buildBaselineLayout) == "function", "buildBaselineLayout required")
    assertTrue(type(layoutConstraints.buildTranslatedLayout) == "function", "buildTranslatedLayout required")
    assertTrue(type(layoutConstraints.enumerateLayoutCandidates) == "function", "enumerateLayoutCandidates required")
end)

runTest("baseline_layout_spec_validates_and_matches_visible_geometry", function()
    local spec = layoutConstraints.getBaselineLayoutSpec(PROFILE_ID)
    assertTrue(type(spec) == "table", "baseline layout spec required")
    local ok, report = layoutConstraints.validateLayoutSpec(spec)
    assertTrue(ok == true, "baseline layout spec should validate: " .. table.concat(report.errors or {}, ","))

    local layout = layoutConstraints.buildBaselineLayout(PROFILE_ID)
    assertTrue(type(layout) == "table", "baseline layout required")
    assertEquals(layout.profileId, PROFILE_ID, "profile id")
    assertCell(layout.commandant, 2, 4, "commandant")
    assertCell(layout.contact, 3, 4, "contact")
    assertCell(layout.contactBlocker, 3, 4, "contactBlocker")
    assertCell(layout.finisherStart, 7, 4, "finisherStart")
    assertCell(layout.finisherStaging, 5, 4, "finisherStaging")
    assertCell(layout.supportStart, 5, 5, "supportStart")
    assertCell(layout.supportKey, 3, 5, "supportKey")
    assertCell(layout.pressureStart, 5, 7, "pressureStart")
    assertEquals(#(layout.requiredCells or {}), 2, "required cell count")
    assertCell(layout.requiredCells[1], 3, 5, "required support cell")
    assertCell(layout.requiredCells[2], 3, 4, "required contact cell")
    assertEquals(layout.criticalBlueUnitIds[1], "blue_finisher", "critical finisher id")
    assertEquals(layout.criticalBlueUnitIds[2], "blue_a_support", "critical support id")
end)

runTest("crusher_contact_layout_spec_validates_and_matches_profile_geometry", function()
    local spec = layoutConstraints.getBaselineLayoutSpec(CRUSHER_PROFILE_ID)
    assertTrue(type(spec) == "table", "crusher contact baseline layout spec required")
    local ok, report = layoutConstraints.validateLayoutSpec(spec)
    assertTrue(ok == true, "crusher contact layout spec should validate: " .. table.concat(report.errors or {}, ","))

    local layout = layoutConstraints.buildBaselineLayout(CRUSHER_PROFILE_ID)
    assertTrue(type(layout) == "table", "crusher contact layout required")
    assertEquals(layout.profileId, CRUSHER_PROFILE_ID, "crusher profile id")
    assertCell(layout.commandant, 2, 4, "crusher commandant")
    assertCell(layout.contact, 3, 4, "crusher contact")
    assertCell(layout.contactBlocker, 3, 4, "crusher contactBlocker")
    assertCell(layout.finisherStart, 7, 4, "crusher finisherStart")
    assertCell(layout.finisherStaging, 5, 4, "crusher finisherStaging")
    assertCell(layout.supportStart, 5, 5, "crusher supportStart")
    assertCell(layout.supportKey, 3, 5, "crusher supportKey")
    assertCell(layout.pressureDecoy, 8, 8, "crusher pressureDecoy")
    assertEquals(#(layout.requiredCells or {}), 2, "crusher required cell count")
end)

runTest("rock_los_layout_specs_validate_and_match_profile_geometry", function()
    local leftSpec = layoutConstraints.getLayoutSpec(ROCK_LOS_PROFILE_ID, "left_lane")
    local rightSpec = layoutConstraints.getLayoutSpec(ROCK_LOS_PROFILE_ID, "right_lane")
    assertTrue(type(leftSpec) == "table", "left Rock/LOS layout spec required")
    assertTrue(type(rightSpec) == "table", "right Rock/LOS layout spec required")
    local leftOk, leftReport = layoutConstraints.validateLayoutSpec(leftSpec)
    local rightOk, rightReport = layoutConstraints.validateLayoutSpec(rightSpec)
    assertTrue(leftOk == true, "left Rock/LOS layout spec should validate: " .. table.concat(leftReport.errors or {}, ","))
    assertTrue(rightOk == true, "right Rock/LOS layout spec should validate: " .. table.concat(rightReport.errors or {}, ","))

    local left = layoutConstraints.buildLayout(ROCK_LOS_PROFILE_ID, { variant = "left_lane" })
    local right = layoutConstraints.buildLayout(ROCK_LOS_PROFILE_ID, { variant = "right_lane" })
    assertCell(left.commandant, 2, 5, "left commandant")
    assertCell(left.rock, 2, 4, "left rock")
    assertCell(left.attack, 2, 2, "left attack")
    assertCell(left.supportKey, 2, 6, "left supportKey")
    assertCell(left.finisherStaging, 3, 2, "left finisherStaging")
    assertCell(right.commandant, 2, 4, "right commandant")
    assertCell(right.rock, 2, 5, "right rock")
    assertCell(right.attack, 2, 7, "right attack")
    assertCell(right.supportKey, 2, 3, "right supportKey")
    assertCell(right.finisherStaging, 3, 7, "right finisherStaging")
end)

runTest("support_pressure_rock_los_layout_specs_validate_and_match_profile_geometry", function()
    local leftSpec = layoutConstraints.getLayoutSpec(SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID, "left_lane")
    local rightSpec = layoutConstraints.getLayoutSpec(SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID, "right_lane")
    assertTrue(type(leftSpec) == "table", "left support pressure Rock/LOS layout spec required")
    assertTrue(type(rightSpec) == "table", "right support pressure Rock/LOS layout spec required")
    local leftOk, leftReport = layoutConstraints.validateLayoutSpec(leftSpec)
    local rightOk, rightReport = layoutConstraints.validateLayoutSpec(rightSpec)
    assertTrue(leftOk == true, "left support pressure Rock/LOS layout spec should validate: " .. table.concat(leftReport.errors or {}, ","))
    assertTrue(rightOk == true, "right support pressure Rock/LOS layout spec should validate: " .. table.concat(rightReport.errors or {}, ","))

    local left = layoutConstraints.buildLayout(SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID, { variant = "left_lane" })
    local right = layoutConstraints.buildLayout(SUPPORT_PRESSURE_ROCK_LOS_PROFILE_ID, { variant = "right_lane" })
    assertCell(left.commandant, 2, 5, "left pressure commandant")
    assertCell(left.rock, 2, 4, "left pressure rock")
    assertCell(left.attack, 2, 2, "left pressure attack")
    assertCell(left.supportKey, 2, 6, "left pressure supportKey")
    assertCell(left.supportThreat, 5, 6, "left pressure supportThreat")
    assertCell(left.finisherStaging, 3, 2, "left pressure finisherStaging")
    assertEquals(left.criticalBlueUnitIds[1], "blue_finisher", "left pressure critical finisher id")
    assertEquals(left.criticalBlueUnitIds[2], "blue_a_support", "left pressure critical support id")

    assertCell(right.commandant, 2, 4, "right pressure commandant")
    assertCell(right.rock, 2, 5, "right pressure rock")
    assertCell(right.attack, 2, 7, "right pressure attack")
    assertCell(right.supportKey, 2, 3, "right pressure supportKey")
    assertCell(right.supportThreat, 5, 3, "right pressure supportThreat")
    assertCell(right.finisherStaging, 3, 7, "right pressure finisherStaging")
end)

runTest("interceptor_artillery_layout_spec_validates_and_matches_profile_geometry", function()
    local spec = layoutConstraints.getLayoutSpec(INTERCEPTOR_ARTILLERY_PROFILE_ID, "baseline")
    assertTrue(type(spec) == "table", "interceptor Artillery layout spec required")
    local ok, report = layoutConstraints.validateLayoutSpec(spec)
    assertTrue(ok == true, "interceptor Artillery layout spec should validate: " .. table.concat(report.errors or {}, ","))

    local layout = layoutConstraints.buildLayout(INTERCEPTOR_ARTILLERY_PROFILE_ID, { variant = "baseline" })
    assertTrue(type(layout) == "table", "interceptor Artillery layout required")
    assertEquals(layout.profileId, INTERCEPTOR_ARTILLERY_PROFILE_ID, "interceptor Artillery profile id")
    assertCell(layout.commandant, 2, 3, "interceptor commandant")
    assertCell(layout.artilleryFinal, 5, 3, "interceptor artilleryFinal")
    assertCell(layout.artilleryStaging, 6, 3, "interceptor artilleryStaging")
    assertCell(layout.finisherStart, 7, 3, "interceptor finisherStart")
    assertCell(layout.supportStart, 7, 2, "interceptor supportStart")
    assertCell(layout.supportKey, 6, 2, "interceptor supportKey")
    assertCell(layout.interceptor, 6, 3, "interceptor pressure unit")
    assertEquals(layout.criticalBlueUnitIds[1], "blue_finisher", "interceptor critical finisher id")
    assertEquals(layout.criticalBlueUnitIds[2], "blue_a_support", "interceptor critical support id")
end)

runTest("dual_rock_lock_layout_spec_validates_and_matches_profile_geometry", function()
    local spec = layoutConstraints.getLayoutSpec(DUAL_ROCK_LOCK_PROFILE_ID, "baseline")
    assertTrue(type(spec) == "table", "dual Rock-lock layout spec required")
    local ok, report = layoutConstraints.validateLayoutSpec(spec)
    assertTrue(ok == true, "dual Rock-lock layout spec should validate: " .. table.concat(report.errors or {}, ","))

    local layout = layoutConstraints.buildLayout(DUAL_ROCK_LOCK_PROFILE_ID, { variant = "baseline" })
    assertTrue(type(layout) == "table", "dual Rock-lock layout required")
    assertEquals(layout.profileId, DUAL_ROCK_LOCK_PROFILE_ID, "dual Rock-lock profile id")
    assertCell(layout.commandant, 2, 4, "dual commandant")
    assertCell(layout.lowerRock, 4, 4, "dual lowerRock")
    assertCell(layout.upperRock, 3, 4, "dual upperRock")
    assertCell(layout.attack, 5, 4, "dual attack")
    assertCell(layout.finisherStart, 8, 4, "dual finisherStart")
    assertCell(layout.supportStart, 5, 2, "dual supportStart")
    assertCell(layout.supportLowerKey, 4, 2, "dual supportLowerKey")
    assertCell(layout.supportUpperKey, 3, 2, "dual supportUpperKey")
    assertEquals(#(layout.requiredCells or {}), 3, "dual required cell count")
    assertEquals(layout.criticalBlueUnitIds[1], "blue_finisher", "dual critical finisher id")
    assertEquals(layout.criticalBlueUnitIds[2], "blue_a_support", "dual critical support id")
end)

runTest("layout_spec_validation_rejects_negative_mutations", function()
    local spec = layoutConstraints.getBaselineLayoutSpec(PROFILE_ID)

    local missingRequiredCell = deepClone(spec)
    missingRequiredCell.requiredCellRefs[2] = "missing_cell_ref"
    local okMissing, reportMissing = layoutConstraints.validateLayoutSpec(missingRequiredCell)
    assertTrue(okMissing == false, "missing required cell mutation should reject")
    assertTrue(hasError(reportMissing, "required_cell_unknown:missing_cell_ref"), "missing required cell error expected")

    local pressureOnBlocker = deepClone(spec)
    for _, role in ipairs(pressureOnBlocker.unitRoles or {}) do
        if role.id == "red_support_threat" then
            role.startCellRef = "contactBlocker"
        end
    end
    local okPressure, reportPressure = layoutConstraints.validateLayoutSpec(pressureOnBlocker)
    assertTrue(okPressure == false, "pressure/blocker same-cell mutation should reject")
    assertTrue(hasError(reportPressure, "pressure_blocker_same_start_cell"), "pressure/blocker separation error expected")

    local macroTemplate = deepClone(spec)
    macroTemplate.solutionOrder = { "support_setup", "blocker_clear", "crusher_payoff" }
    local okMacro, reportMacro = layoutConstraints.validateLayoutSpec(macroTemplate)
    assertTrue(okMacro == false, "macro-template layout mutation should reject")
    assertTrue(hasError(reportMacro, "macro_field_forbidden:solutionOrder"), "macro field error expected")
end)

runTest("layout_search_enumerates_translated_candidates_without_changing_baseline", function()
    local candidates, rejected = layoutConstraints.enumerateLayoutCandidates(PROFILE_ID, {
        offsets = {
            { rowOffset = 0, colOffset = 0 },
            { rowOffset = 0, colOffset = 1 },
            { rowOffset = 0, colOffset = 99 }
        },
        maxCandidates = 3
    })
    assertEquals(#candidates, 2, "valid candidate count")
    assertEquals(#rejected, 1, "rejected candidate count")
    assertCell(candidates[1].commandant, 2, 4, "baseline candidate commandant")
    assertEquals(candidates[1].variant, "baseline", "baseline candidate variant")
    assertCell(candidates[2].commandant, 2, 5, "translated candidate commandant")
    assertCell(candidates[2].pressureStart, 5, 8, "translated candidate pressure")
    assertEquals(candidates[2].colOffset, 1, "translated candidate col offset")
end)

runTest("generator_layout_search_can_certify_controlled_translated_layout_without_changing_default", function()
    local translated, diagnostics = retroGenerator.generate({
        seed = 409,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = PROFILE_ID,
        maxAttempts = 1,
        enableLayoutSearch = true,
        layoutOffsets = {
            { rowOffset = 0, colOffset = 0 },
            { rowOffset = 0, colOffset = 1 }
        }
    })
    assertEquals(translated.pipelineState, "certified", "translated pipeline state")
    assertTrue(diagnostics.layoutSearch.enabled == true, "layout search should be enabled")
    assertEquals(#(diagnostics.layoutSearch.candidates or {}), 2, "layout search candidate count")
    assertEquals(#(diagnostics.layoutAttempts or {}), 1, "layout search should certify on first translated attempt")
    assertEquals(diagnostics.layoutAttempts[1].colOffset, 1, "first certified attempt should use translated offset")
    assertEquals(stateEngine.stateHash(translated.scenarioState), "a3477969", "translated state hash")
    assertUnit(translated.scenarioState, "blue_a_support", "Earthstalker", 5, 6, 3, 3)
    assertUnit(translated.scenarioState, "blue_finisher", "Crusher", 7, 5, 4, 4)
    assertUnit(translated.scenarioState, "red_commandant", "Commandant", 2, 5, 4, 12)
    assertUnit(translated.scenarioState, "red_contact_blocker", "Bastion", 3, 5, 3, 6)
    assertUnit(translated.scenarioState, "red_support_threat", "Earthstalker", 5, 8, 3, 3)
end)

runTest("generator_uses_baseline_layout_without_visible_geometry_drift", function()
    local dossier = retroGenerator.generate({
        seed = 410,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = PROFILE_ID,
        maxAttempts = 1
    })
    assertTrue(type(dossier) == "table", "dossier required")
    assertEquals(dossier.pipelineState, "certified", "pipeline state")
    assertEquals(stateEngine.stateHash(dossier.scenarioState), "c55d3d64", "baseline state hash")
    assertEquals(dossier.tacticalFingerprint.hash, "9860c24e", "baseline tactical fingerprint")

    assertUnit(dossier.scenarioState, "blue_a_support", "Earthstalker", 5, 5, 3, 3)
    assertUnit(dossier.scenarioState, "blue_finisher", "Crusher", 7, 4, 4, 4)
    assertUnit(dossier.scenarioState, "red_commandant", "Commandant", 2, 4, 4, 12)
    assertUnit(dossier.scenarioState, "red_contact_blocker", "Bastion", 3, 4, 3, 6)
    assertUnit(dossier.scenarioState, "red_support_threat", "Earthstalker", 5, 7, 3, 3)
end)

runTest("layout_search_batch_can_return_distinct_certified_geometries", function()
    local dossiers, summary = retroGenerator.generateBatch({
        seed = 4294605268,
        count = 2,
        turnLimit = 3,
        solverMaxNodes = 9000,
        archetype = PROFILE_ID,
        enableLayoutSearch = true,
        layoutOffsets = {
            { rowOffset = 0, colOffset = 0 },
            { rowOffset = 0, colOffset = 1 }
        },
        maxAttempts = 1,
        batchMaxAttempts = 4
    })
    assertEquals(summary.certifiedCount, 2, "certified count")
    assertEquals(summary.ok, true, "batch summary ok")
    local stateHashes = {}
    for _, dossier in ipairs(dossiers or {}) do
        assertEquals(dossier.pipelineState, "certified", "batch dossier state")
        stateHashes[stateEngine.stateHash(dossier.scenarioState)] = true
    end
    assertTrue(stateHashes.c55d3d64 == true, "batch should include baseline geometry")
    assertTrue(stateHashes.a3477969 == true, "batch should include translated geometry")
end)

runTest("layout_constraints_have_no_standard_ai_or_runtime_dependency", function()
    local file = io.open("scenario_tooling/composition_layout_constraints.lua", "r")
    assertTrue(file ~= nil, "composition_layout_constraints.lua readable")
    local content = file:read("*a")
    file:close()
    assertTrue(content:find('require("ai', 1, true) == nil, "layout constraints must not require standard AI")
    assertTrue(content:find("require('ai", 1, true) == nil, "layout constraints must not require standard AI")
    assertTrue(content:find("ai_tournament", 1, true) == nil, "layout constraints must not depend on ai_tournament")
    assertTrue(content:find("gameRuler", 1, true) == nil, "layout constraints must not depend on runtime game ruler")
    assertTrue(content:find("gameplay", 1, true) == nil, "layout constraints must not depend on runtime gameplay")
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

print(string.format("scenario_composition_layout_constraints_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
