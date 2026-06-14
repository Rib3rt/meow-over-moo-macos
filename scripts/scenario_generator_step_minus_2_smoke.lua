package.path = package.path .. ";./?.lua"

local schemaContract = require("scenario_tooling.schema_contract")
local predicateContract = require("scenario_tooling.predicate_contract")
local validationGate = require("scenario_tooling.validation_gate")
local scenarioContractValidator = require("scenario_tooling.scenario_contract_validator")
local negativeFixtures = require("scenario_tooling.negative_fixtures")

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

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function contains(list, needle)
    for _, value in ipairs(list or {}) do
        if value == needle then
            return true
        end
    end
    return false
end

local function hasReason(reasons, code)
    for _, reason in ipairs(reasons or {}) do
        if tostring(reason.code or "") == tostring(code or "") then
            return true
        end
    end
    return false
end

local function predicate(name, value)
    return {
        schema = "PredicateResult",
        predicate = name,
        predicateVersion = "smoke",
        inputDigest = "smoke:" .. tostring(name),
        status = tostring(value),
        value = value,
        deterministic = true,
        ownerModule = "scripts.scenario_generator_step_minus_2_smoke",
        evidence = {}
    }
end

local function passingDossier()
    return {
        schema = "GenerationDossier",
        id = "smoke_pass",
        seed = "smoke:pass",
        pipelineState = "candidate",
        schemaFreezeVersion = "1.0.0",
        predicateFreezeVersion = "step-2-freeze-v1",
        scenarioState = {
            schema = "ScenarioState",
            board = {rows = 8, cols = 8},
            units = {},
            currentPlayer = 1,
            scenarioTurn = 1,
            turnLimit = 3,
            maxActionsPerTurn = 2,
            objectiveType = "destroy_commandant",
            supplyEnabled = false
        },
        mechanismSpec = {schema = "MechanismSpec"},
        tacticalFingerprint = {schema = "TacticalFingerprint", fingerprint = "smoke"},
        proofCertificate = {schema = "ProofCertificate", status = "fixture"},
        qualityFeatureSet = {schema = "QualityFeatureSet", pass = true},
        rejectionReasons = {},
        predicateResults = {
            predicate("static_damage_clock", false),
            predicate("multi_unit_damage_clock", false),
            predicate("free_finisher_move", false),
            predicate("support_already_free", false),
            predicate("cosmetic_red_pressure", false),
            predicate("macro_template_signature", false),
            predicate("fingerprint_distinct", true),
            predicate("non_decorative_micro", true),
            predicate("real_pressure", true)
        },
        defensiveProofUsed = true,
        defensiveDomainDecisions = {
            {
                schema = "DefensiveDomainDecision",
                redAction = {type = "end_turn", actorId = "red_smoke"},
                decision = "include",
                reasonCodes = {"policy_choice"},
                predicateInputs = {state = "smoke_pass"},
                predicateResults = {
                    predicate("defensive_domain_inclusion", true)
                },
                policyScoreBand = "top",
                equivalenceReason = "policy_choice",
                domainVersion = "smoke"
            }
        }
    }
end

local function contractUnit(id, name, player, row, col, hp, maxHp)
    return {
        id = id,
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = maxHp or hp,
        hasMoved = false,
        hasActed = false
    }
end

local function validScenarioContractDossier()
    return {
        schema = "GenerationDossier",
        id = "contract_valid",
        seed = "contract:valid",
        pipelineState = "candidate",
        mechanismSpec = {
            schema = "MechanismSpec",
            id = "contract_valid_mechanism",
            lock = "line_lock",
            key = "open_line",
            path = "move_support",
            risk = "red_pressure",
            decoy = "wrong_target",
            payoff = "finisher_shot"
        },
        tacticalFingerprint = {
            schema = "TacticalFingerprint",
            version = "fixture",
            fingerprint = "contract_valid"
        },
        scenarioState = {
            schema = "ScenarioState",
            board = {rows = 8, cols = 8},
            currentPlayer = 1,
            scenarioTurn = 1,
            turnLimit = 3,
            maxActionsPerTurn = 2,
            objectiveType = "destroy_commandant",
            supplyEnabled = false,
            units = {
                contractUnit("blue_cloud", "Cloudstriker", 1, 6, 2, 4, 4),
                contractUnit("red_commandant", "Commandant", 2, 1, 4, 6, 12),
                contractUnit("neutral_rock", "Rock", 0, 4, 4, 5, 5)
            }
        }
    }
end

runTest("schema_freeze_contains_all_required_step_minus_2_schemas", function()
    local ok, errors = schemaContract.validateFreeze()
    assertTrue(ok, table.concat(errors or {}, "\n"))
    assertEquals(#schemaContract.requiredSchemaNames, 15, "required schema count")

    for _, name in ipairs({
        "ScenarioState",
        "UnitState",
        "Action",
        "LegalMoveSet",
        "MicroInteractionSpec",
        "MechanismSpec",
        "TacticalFingerprint",
        "DefensiveDomainRule",
        "DefensiveDomainDecision",
        "PredicateResult",
        "AblationResult",
        "QualityFeatureSet",
        "ProofCertificate",
        "RejectionReason",
        "GenerationDossier"
    }) do
        assertTrue(schemaContract.getSchema(name) ~= nil, "missing schema " .. name)
    end

    local scenarioStateSchema = schemaContract.getSchema("ScenarioState")
    assertTrue(contains(scenarioStateSchema.required, "maxActionsPerTurn"), "ScenarioState must freeze the two-action runtime budget")

    local certificateSchema = schemaContract.getSchema("ProofCertificate")
    assertTrue(contains(certificateSchema.required, "max_actions_per_turn"), "ProofCertificate must record the proven action budget")
end)

runTest("defensive_domain_decision_schema_requires_per_red_move_evidence", function()
    local schema = schemaContract.getSchema("DefensiveDomainDecision")
    for _, field in ipairs({
        "redAction",
        "decision",
        "reasonCodes",
        "predicateInputs",
        "predicateResults",
        "policyScoreBand",
        "equivalenceReason",
        "domainVersion"
    }) do
        assertTrue(contains(schema.required, field), "DefensiveDomainDecision missing required field " .. field)
    end
    assertTrue(contains(schema.enums.decision, "include"), "include decision missing")
    assertTrue(contains(schema.enums.decision, "exclude"), "exclude decision missing")
    assertTrue(contains(schema.enums.decision, "unknown"), "unknown decision missing")
    assertTrue(contains(schema.enums.decision, "fallback_all_legal"), "fallback decision missing")
end)

runTest("predicate_freeze_contains_all_required_computable_features", function()
    local ok, errors = predicateContract.validateFreeze()
    assertTrue(ok, table.concat(errors or {}, "\n"))
    assertEquals(#predicateContract.requiredPredicates, 17, "required predicate count")

    for _, name in ipairs(predicateContract.requiredPredicates) do
        local entry = predicateContract.getPredicate(name)
        assertTrue(entry ~= nil, "missing predicate " .. name)
        assertTrue(
            type(entry.unknownBehavior) == "string"
                and (entry.unknownBehavior:find("Unknown") ~= nil or entry.unknownBehavior:find("unknown") ~= nil),
            "unknown behavior missing for " .. name
        )
        assertTrue(type(entry.fixtureCoverageKeys) == "table" and #entry.fixtureCoverageKeys >= 2, "fixture coverage missing for " .. name)
    end
end)

runTest("anti_self_acquittal_rule_is_explicit", function()
    local rule = predicateContract.module and predicateContract.module.antiSelfAcquittalRule or ""
    assertTrue(rule:find("never approved", 1, true) ~= nil, "anti-self-acquittal rule should block approval")
end)

runTest("validation_gate_passes_only_when_required_evidence_is_computed", function()
    local outcome = validationGate.evaluateDossier(passingDossier())
    assertEquals(outcome.status, "step_minus_2_gate_pass", "computed dossier should pass Step -2 gate")

    local missing = passingDossier()
    missing.predicateResults = {}
    local missingOutcome = validationGate.evaluateDossier(missing)
    assertEquals(missingOutcome.status, "unknown", "missing predicate evidence must be unknown")
    assertTrue(hasReason(missingOutcome.unknowns, "predicate_uncomputed"), "missing evidence reason expected")
end)

runTest("validation_gate_rejects_or_blocks_invalid_defensive_decisions", function()
    local sample = passingDossier()
    sample.defensiveDomainDecisions[1].decision = "exclude_by_vibes"
    sample.defensiveDomainDecisions[1].predicateResults = {}
    sample.defensiveDomainDecisions[1].predicateInputs = nil
    local outcome = validationGate.evaluateDossier(sample)
    assertEquals(outcome.status, "unknown", "invalid defensive decision should block certification")
    assertTrue(hasReason(outcome.unknowns, "invalid_defensive_domain_decision"), "invalid decision reason expected")
    assertTrue(hasReason(outcome.unknowns, "missing_defensive_domain_predicate_evidence"), "missing predicate evidence reason expected")
    assertTrue(hasReason(outcome.unknowns, "missing_defensive_domain_predicate_inputs"), "missing predicate inputs reason expected")
end)

runTest("scenario_contract_validator_accepts_minimal_valid_dossier", function()
    assertTrue(scenarioContractValidator.isScenarioOnly() == true, "validator should identify as scenario-only tooling")
    local ok, errors = scenarioContractValidator.validateScenarioDossier(validScenarioContractDossier())
    assertTrue(ok, "valid scenario contract should pass: " .. tostring((errors[1] or {}).code))
end)

runTest("scenario_contract_validator_rejects_forbidden_units_and_commandants", function()
    local blueCommandant = validScenarioContractDossier()
    blueCommandant.scenarioState.units[#blueCommandant.scenarioState.units + 1] =
        contractUnit("blue_cmd", "Commandant", 1, 8, 8, 12, 12)
    local okBlue, errorsBlue = scenarioContractValidator.validateScenarioDossier(blueCommandant)
    assertTrue(not okBlue, "Blue Commandant should fail")
    assertTrue(hasReason(errorsBlue, "blue_commandant_forbidden"), "Blue Commandant reason expected")

    local healer = validScenarioContractDossier()
    healer.scenarioState.units[#healer.scenarioState.units + 1] =
        contractUnit("blue_healer", "Healer", 1, 7, 7, 4, 4)
    local okHealer, errorsHealer = scenarioContractValidator.validateScenarioDossier(healer)
    assertTrue(not okHealer, "Healer should fail")
    assertTrue(hasReason(errorsHealer, "healer_forbidden"), "Healer reason expected")

    local noRedCommandant = validScenarioContractDossier()
    noRedCommandant.scenarioState.units[2].name = "Bastion"
    local okNone, errorsNone = scenarioContractValidator.validateScenarioDossier(noRedCommandant)
    assertTrue(not okNone, "zero Red Commandants should fail")
    assertTrue(hasReason(errorsNone, "red_commandant_count_invalid"), "zero Red Commandant reason expected")

    local duplicateRedCommandant = validScenarioContractDossier()
    duplicateRedCommandant.scenarioState.units[#duplicateRedCommandant.scenarioState.units + 1] =
        contractUnit("red_cmd_2", "Commandant", 2, 1, 5, 12, 12)
    local okDup, errorsDup = scenarioContractValidator.validateScenarioDossier(duplicateRedCommandant)
    assertTrue(not okDup, "multiple Red Commandants should fail")
    assertTrue(hasReason(errorsDup, "red_commandant_count_invalid"), "multiple Red Commandant reason expected")
end)

runTest("scenario_contract_validator_rejects_board_and_contract_violations", function()
    local redOutside = validScenarioContractDossier()
    redOutside.scenarioState.units[2].row = 3
    local okOutside, errorsOutside = scenarioContractValidator.validateScenarioDossier(redOutside)
    assertTrue(not okOutside, "Red Commandant outside A1-H2 should fail")
    assertTrue(hasReason(errorsOutside, "red_commandant_anchor_invalid"), "anchor reason expected")

    local highHp = validScenarioContractDossier()
    highHp.scenarioState.units[1].currentHp = 99
    local okHp, errorsHp = scenarioContractValidator.validateScenarioDossier(highHp)
    assertTrue(not okHp, "HP above max should fail")
    assertTrue(hasReason(errorsHp, "unit_hp_above_max"), "HP reason expected")

    local badRock = validScenarioContractDossier()
    badRock.scenarioState.units[3].player = 1
    local okRock, errorsRock = scenarioContractValidator.validateScenarioDossier(badRock)
    assertTrue(not okRock, "non-neutral Rock should fail")
    assertTrue(hasReason(errorsRock, "rock_must_be_neutral"), "Rock reason expected")

    local duplicateCell = validScenarioContractDossier()
    duplicateCell.scenarioState.units[1].row = 1
    duplicateCell.scenarioState.units[1].col = 4
    local okDupCell, errorsDupCell = scenarioContractValidator.validateScenarioDossier(duplicateCell)
    assertTrue(not okDupCell, "duplicate cell should fail")
    assertTrue(hasReason(errorsDupCell, "duplicate_unit_cell"), "duplicate cell reason expected")

    local shortLimit = validScenarioContractDossier()
    shortLimit.scenarioState.turnLimit = 2
    local okShort, errorsShort = scenarioContractValidator.validateScenarioDossier(shortLimit)
    assertTrue(not okShort, "turn limit below 3 should fail")
    assertTrue(hasReason(errorsShort, "turn_limit_out_of_range"), "turn limit reason expected")

    local missingActionBudget = validScenarioContractDossier()
    missingActionBudget.scenarioState.maxActionsPerTurn = nil
    local okMissingBudget, errorsMissingBudget = scenarioContractValidator.validateScenarioDossier(missingActionBudget)
    assertTrue(not okMissingBudget, "missing action budget should fail")
    assertTrue(hasReason(errorsMissingBudget, "action_budget_invalid"), "missing budget reason expected")

    local wrongActionBudget = validScenarioContractDossier()
    wrongActionBudget.scenarioState.maxActionsPerTurn = 99
    local okWrongBudget, errorsWrongBudget = scenarioContractValidator.validateScenarioDossier(wrongActionBudget)
    assertTrue(not okWrongBudget, "action budget other than two should fail")
    assertTrue(hasReason(errorsWrongBudget, "action_budget_invalid"), "wrong budget reason expected")
end)

runTest("scenario_contract_validator_rejects_missing_mechanism_or_fingerprint", function()
    local noMechanism = validScenarioContractDossier()
    noMechanism.mechanismSpec = nil
    local okMechanism, errorsMechanism = scenarioContractValidator.validateScenarioDossier(noMechanism)
    assertTrue(not okMechanism, "missing mechanism should fail")
    assertTrue(hasReason(errorsMechanism, "missing_mechanism_spec"), "missing mechanism reason expected")

    local noFingerprint = validScenarioContractDossier()
    noFingerprint.tacticalFingerprint = nil
    local okFingerprint, errorsFingerprint = scenarioContractValidator.validateScenarioDossier(noFingerprint)
    assertTrue(not okFingerprint, "missing fingerprint should fail")
    assertTrue(hasReason(errorsFingerprint, "missing_tactical_fingerprint"), "missing fingerprint reason expected")
end)

runTest("step_minus_1_negative_fixture_inventory_is_complete", function()
    local fixtures = negativeFixtures.list()
    assertEquals(#fixtures, #negativeFixtures.requiredFixtureIds, "negative fixture count")
    for _, id in ipairs(negativeFixtures.requiredFixtureIds) do
        assertTrue(negativeFixtures.getById(id) ~= nil, "missing negative fixture " .. id)
    end
end)

runTest("step_minus_1_negative_fixtures_fail_for_computable_reasons", function()
    for _, fixture in ipairs(negativeFixtures.list()) do
        local ok, outcome = validationGate.evaluateNegativeFixture(fixture)
        assertTrue(ok, fixture.id .. " expected " .. tostring(fixture.expectedOutcome) .. " got " .. tostring(outcome.status))
        for _, expectedReason in ipairs(fixture.expectedReasons or {}) do
            assertTrue(
                hasReason(outcome.reasons, expectedReason) or hasReason(outcome.unknowns, expectedReason),
                fixture.id .. " missing expected reason " .. expectedReason
            )
        end
    end
end)

runTest("negative_fixture_primary_predicates_are_frozen", function()
    for _, fixture in ipairs(negativeFixtures.list()) do
        for _, predicateName in ipairs(fixture.primaryPredicates or {}) do
            assertTrue(predicateContract.getPredicate(predicateName) ~= nil, fixture.id .. " uses unfrozen predicate " .. tostring(predicateName))
        end
    end
end)

runTest("scenario_tooling_has_no_standard_ai_dependency", function()
    for _, path in ipairs({
        "scenario_tooling/schema_contract.lua",
        "scenario_tooling/predicate_contract.lua",
        "scenario_tooling/validation_gate.lua",
        "scenario_tooling/scenario_contract_validator.lua",
        "scenario_tooling/negative_fixtures.lua"
    }) do
        local content = readFile(path)
        assertTrue(type(content) == "string", path .. " not readable")
        assertTrue(content:find('require("ai', 1, true) == nil, path .. " must not require standard AI")
        assertTrue(content:find("require('ai", 1, true) == nil, path .. " must not require standard AI")
        assertTrue(content:find("ai_tournament", 1, true) == nil, path .. " must not depend on AI tournament modules")
        assertTrue(content:find('require("gameplay")', 1, true) == nil, path .. " must not require gameplay")
        assertTrue(content:find('require("gameRuler")', 1, true) == nil, path .. " must not require gameRuler")
        assertTrue(content:find('require("scenarioEditor")', 1, true) == nil, path .. " must not require scenario editor")
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

print(string.format("scenario_generator_step_minus_2_smoke: %d/%d passed", passed, #results))
if passed ~= #results then
    os.exit(1)
end
