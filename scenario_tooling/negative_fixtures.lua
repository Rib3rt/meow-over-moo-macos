local negativeFixtures = {}
local compositionComposer = require("scenario_tooling.composition_composer")

negativeFixtures.VERSION = "scenario_negative_fixtures.v0.1.0-step-minus-1"

local function unit(id, name, player, row, col, hp, extra)
    local entry = {
        id = id,
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = hp,
        hasActed = false,
        hasMoved = false
    }
    for key, value in pairs(extra or {}) do
        entry[key] = value
    end
    return entry
end

local function baseState(id, units)
    return {
        schema = "ScenarioState",
        id = id,
        board = {
            rows = 8,
            cols = 8
        },
        currentPlayer = 1,
        scenarioTurn = 1,
        turnLimit = 3,
        objectiveType = "destroy_commandant",
        units = units,
        supplyEnabled = false
    }
end

local function predicate(name, value, evidence)
    return {
        schema = "PredicateResult",
        predicate = name,
        predicateVersion = "fixture",
        inputDigest = "fixture:" .. tostring(name),
        status = value == nil and "unknown" or tostring(value),
        value = value,
        deterministic = true,
        ownerModule = "scenario_tooling.negative_fixtures",
        evidence = evidence or {}
    }
end

local function dossier(id, state, predicateResults, options)
    options = options or {}
    return {
        schema = "GenerationDossier",
        id = id,
        seed = "negative-fixture:" .. id,
        pipelineState = "candidate",
        schemaFreezeVersion = "1.0.0",
        predicateFreezeVersion = "step-2-freeze-v1",
        scenarioState = state,
        mechanismSpec = options.mechanismSpec or {
            schema = "MechanismSpec",
            id = id .. "_mechanism",
            lock = "negative_fixture_lock",
            key = "negative_fixture_key",
            path = "negative_fixture_path",
            risk = "negative_fixture_risk",
            decoy = "negative_fixture_decoy",
            payoff = "negative_fixture_payoff",
            microInteractions = {}
        },
        tacticalFingerprint = options.tacticalFingerprint or {
            schema = "TacticalFingerprint",
            version = "fixture",
            fingerprint = id,
            features = {}
        },
        proofCertificate = options.proofCertificate or {
            schema = "ProofCertificate",
            status = options.proofStatus or "untrusted_fixture",
            proofDomain = options.proofDomain or "defensive",
            winningLine = {}
        },
        qualityFeatureSet = options.qualityFeatureSet or {
            schema = "QualityFeatureSet",
            status = "fixture_only",
            features = {},
            componentScores = {},
            totalScore = 0,
            pass = false,
            reasons = {"negative_fixture"}
        },
        predicateResults = predicateResults or {},
        contractPattern = options.contractPattern,
        microInteractions = options.microInteractions or {},
        solution = options.solution or { actions = {} },
        solverProof = options.solverProof or {},
        falseLines = options.falseLines or {},
        compositionalContract = options.compositionalContract,
        ablationResults = options.ablationResults or {},
        defensiveProofUsed = options.defensiveProofUsed == true,
        defensiveDomainDecisions = options.defensiveDomainDecisions or {},
        rejectionReasons = {}
    }
end

local function standardUnits(extra)
    local units = {
        unit("blue_cloud", "Cloudstriker", 1, 6, 2, 4),
        unit("blue_artillery", "Artillery", 1, 6, 4, 5),
        unit("red_commandant", "Commandant", 2, 1, 4, 6),
        unit("red_bastion", "Bastion", 2, 2, 4, 6)
    }
    for _, entry in ipairs(extra or {}) do
        units[#units + 1] = entry
    end
    return units
end

local function cloneValue(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    local k, v
    for k, v in pairs(value) do
        out[cloneValue(k, seen)] = cloneValue(v, seen)
    end
    return out
end

local function compositeLine(firstActionOverride)
    local line = {
        { type = "move", actorId = "blue_a_support", to = { row = 3, col = 5 } },
        { type = "attack", actorId = "blue_a_support", targetId = "red_contact_blocker" },
        { type = "move", actorId = "blue_finisher", to = { row = 5, col = 4 } },
        { type = "move", actorId = "blue_finisher", to = { row = 3, col = 4 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
    if firstActionOverride then
        line[1] = firstActionOverride
    end
    return line
end

local function compositeContract(mutator, firstActionOverride)
    local line = compositeLine(firstActionOverride)
    local consequences = assert(compositionComposer.buildActionConsequences(
        "composite_support_pressure_crusher_contact",
        {
            { slotId = "support_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "fixture_before_1", afterStateHash = "fixture_after_1" },
            { slotId = "support_blocker_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "fixture_before_2", afterStateHash = "fixture_after_2" },
            { slotId = "finisher_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "fixture_before_3", afterStateHash = "fixture_after_3" },
            { slotId = "crusher_contact_move", actionIndex = 4, action = line[4], beforeStateHash = "fixture_before_4", afterStateHash = "fixture_after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "fixture_before_5", afterStateHash = "fixture_after_5" }
        },
        { seed = "negative_fixture_composite", horizon = 3 }
    ))
    local contract = assert(compositionComposer.buildContract(
        "composite_support_pressure_crusher_contact",
        line,
        consequences,
        { seed = "negative_fixture_composite" }
    ))
    if mutator then
        mutator(contract)
    end
    return contract, line
end

local function compositePredicateResults(extra, roleEvidence)
    local results = {
        predicate("static_damage_clock", false),
        predicate("multi_unit_damage_clock", false),
        predicate("free_finisher_move", false),
        predicate("support_already_free", false),
        predicate("cosmetic_red_pressure", false),
        predicate("macro_template_signature", false),
        predicate("fingerprint_distinct", true),
        predicate("non_decorative_micro", true),
        predicate("real_pressure", true),
        predicate("critical_blue_unit", true, {
            evidence = roleEvidence or {
                redPressureUnit = "red_support_threat",
                contactBlockerUnit = "red_contact_blocker",
                contactBlockerAlsoPressure = false,
                pressureCanBeAttackedAtStart = false
            }
        })
    }
    for _, result in ipairs(extra or {}) do
        results[#results + 1] = result
    end
    return results
end

local function compositeDossier(id, contract, line, predicates, options)
    options = options or {}
    return dossier(
        id,
        baseState(id, standardUnits()),
        predicates or compositePredicateResults(),
        {
            contractPattern = "composite_support_pressure_crusher_contact",
            microInteractions = {
                { id = "SUPPORT_CELL_GAIN" },
                { id = "RED_ATTACKS_SUPPORT" },
                { id = "FINISHER_CELL_GAIN" },
                { id = "WRONG_TARGET_TEMPO_LOSS" },
                { id = "ORDER_DEPENDENCY" },
                { id = "HP_EXACT_WINDOW" }
            },
            tacticalFingerprint = {
                schema = "TacticalFingerprint",
                fingerprint_version = "fixture",
                signature = id,
                hash = id,
                mechanism_family = "access_lock",
                micro_sequence_signature = "SUPPORT_CELL_GAIN>RED_ATTACKS_SUPPORT>FINISHER_CELL_GAIN",
                role_signature = "Crusher+composite+support_pressure+contact_breach+melee_blocker",
                geometry_signature = "fixture"
            },
            solution = { actions = cloneValue(line or compositeLine()) },
            compositionalContract = contract,
            ablationResults = contract and cloneValue(contract.actionConsequences) or {},
            solverProof = { status = "fixture_only" },
            falseLines = {},
            mechanismSpec = {
                schema = "MechanismSpec",
                id = id .. "_mechanism",
                lock = "negative_composite_fixture_lock",
                key = "negative_composite_fixture_key",
                path = "negative_composite_fixture_path",
                risk = "negative_composite_fixture_risk",
                payoff = "negative_composite_fixture_payoff"
            }
        }
    )
end

local function crusherContactContract(mutator, firstActionOverride)
    local line = compositeLine(firstActionOverride)
    local consequences = assert(compositionComposer.buildActionConsequences(
        "crusher_contact_breach",
        {
            { slotId = "support_contact_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "crusher_before_1", afterStateHash = "crusher_after_1" },
            { slotId = "support_blocker_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "crusher_before_2", afterStateHash = "crusher_after_2" },
            { slotId = "finisher_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "crusher_before_3", afterStateHash = "crusher_after_3" },
            { slotId = "crusher_contact_move", actionIndex = 4, action = line[4], beforeStateHash = "crusher_before_4", afterStateHash = "crusher_after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "crusher_before_5", afterStateHash = "crusher_after_5" }
        },
        { seed = "negative_fixture_crusher_contact", horizon = 3 }
    ))
    local contract = assert(compositionComposer.buildContract(
        "crusher_contact_breach",
        line,
        consequences,
        { seed = "negative_fixture_crusher_contact" }
    ))
    if mutator then
        mutator(contract)
    end
    return contract, line
end

local function crusherContactDossier(id, contract, line, predicates)
    return dossier(
        id,
        baseState(id, standardUnits()),
        predicates or compositePredicateResults(nil, {
            contactBlockerUnit = "red_contact_blocker",
            pressureCanBeAttackedAtStart = false
        }),
        {
            contractPattern = "crusher_contact_breach",
            microInteractions = {
                { id = "SUPPORT_CELL_GAIN" },
                { id = "FINISHER_CELL_GAIN" },
                { id = "WRONG_TARGET_TEMPO_LOSS" },
                { id = "ORDER_DEPENDENCY" },
                { id = "HP_EXACT_WINDOW" }
            },
            tacticalFingerprint = {
                schema = "TacticalFingerprint",
                fingerprint_version = "fixture",
                signature = id,
                hash = id,
                mechanism_family = "access_lock",
                micro_sequence_signature = "SUPPORT_CELL_GAIN>ORDER_DEPENDENCY>FINISHER_CELL_GAIN",
                role_signature = "Crusher+contact_breach+melee_blocker",
                geometry_signature = "fixture"
            },
            solution = { actions = cloneValue(line or compositeLine()) },
            compositionalContract = contract,
            ablationResults = contract and cloneValue(contract.actionConsequences) or {},
            solverProof = { status = "fixture_only" },
            falseLines = {},
            mechanismSpec = {
                schema = "MechanismSpec",
                id = id .. "_mechanism",
                lock = "negative_crusher_contact_lock",
                key = "negative_crusher_contact_key",
                path = "negative_crusher_contact_path",
                risk = "negative_crusher_contact_risk",
                payoff = "negative_crusher_contact_payoff"
            }
        }
    )
end

local function rockLosLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 2, col = 6 } },
        { type = "attack", actorId = "blue_a_support", targetId = "neutral_rock" },
        { type = "move", actorId = "blue_finisher", to = { row = 3, col = 2 } },
        { type = "move", actorId = "blue_finisher", to = { row = 2, col = 2 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function rockLosContract(mutator)
    local line = rockLosLine()
    local consequences = assert(compositionComposer.buildActionConsequences(
        "support_reposition_rock_los_finish",
        {
            { slotId = "support_los_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "rock_los_before_1", afterStateHash = "rock_los_after_1" },
            { slotId = "support_rock_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "rock_los_before_2", afterStateHash = "rock_los_after_2" },
            { slotId = "finisher_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "rock_los_before_3", afterStateHash = "rock_los_after_3" },
            { slotId = "finisher_los_cell_move", actionIndex = 4, action = line[4], beforeStateHash = "rock_los_before_4", afterStateHash = "rock_los_after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "rock_los_before_5", afterStateHash = "rock_los_after_5" }
        },
        { seed = "negative_fixture_rock_los", horizon = 3 }
    ))
    local contract = assert(compositionComposer.buildContract(
        "support_reposition_rock_los_finish",
        line,
        consequences,
        { seed = "negative_fixture_rock_los" }
    ))
    if mutator then
        mutator(contract)
    end
    return contract, line
end

local function rockLosDossier(id, contract, line, predicates)
    return dossier(
        id,
        baseState(id, standardUnits({
            unit("neutral_rock", "Rock", 0, 2, 4, 2)
        })),
        predicates or compositePredicateResults(),
        {
            contractPattern = "support_reposition_rock_los_finish",
            microInteractions = {
                { id = "SUPPORT_CELL_GAIN" },
                { id = "ROCK_AS_LOCK" },
                { id = "LOS_OPEN_RANGED" },
                { id = "FINISHER_CELL_GAIN" },
                { id = "WRONG_TARGET_TEMPO_LOSS" },
                { id = "HP_EXACT_WINDOW" }
            },
            tacticalFingerprint = {
                schema = "TacticalFingerprint",
                fingerprint_version = "fixture",
                signature = id,
                hash = id,
                mechanism_family = "line_setup",
                micro_sequence_signature = "SUPPORT_CELL_GAIN>ROCK_AS_LOCK>LOS_OPEN_RANGED",
                role_signature = "Cloudstriker+support_artillery+rock_lock+tempo_decoy",
                geometry_signature = "fixture"
            },
            solution = { actions = cloneValue(line or rockLosLine()) },
            compositionalContract = contract,
            ablationResults = contract and cloneValue(contract.actionConsequences) or {},
            solverProof = { status = "fixture_only" },
            falseLines = {},
            mechanismSpec = {
                schema = "MechanismSpec",
                id = id .. "_mechanism",
                lock = "negative_rock_los_lock",
                key = "negative_rock_los_key",
                path = "negative_rock_los_path",
                risk = "negative_rock_los_risk",
                payoff = "negative_rock_los_payoff"
            }
        }
    )
end

local function supportPressureRockLosLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 2, col = 6 } },
        { type = "attack", actorId = "blue_a_support", targetId = "neutral_rock" },
        { type = "move", actorId = "blue_finisher", to = { row = 3, col = 2 } },
        { type = "move", actorId = "blue_finisher", to = { row = 2, col = 2 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function supportPressureRockLosContract(mutator)
    local line = supportPressureRockLosLine()
    local consequences = assert(compositionComposer.buildActionConsequences(
        "support_under_real_red_pressure",
        {
            { slotId = "support_pressure_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "pressure_rock_los_before_1", afterStateHash = "pressure_rock_los_after_1" },
            { slotId = "support_rock_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "pressure_rock_los_before_2", afterStateHash = "pressure_rock_los_after_2" },
            { slotId = "finisher_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "pressure_rock_los_before_3", afterStateHash = "pressure_rock_los_after_3" },
            { slotId = "finisher_los_cell_move", actionIndex = 4, action = line[4], beforeStateHash = "pressure_rock_los_before_4", afterStateHash = "pressure_rock_los_after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "pressure_rock_los_before_5", afterStateHash = "pressure_rock_los_after_5" }
        },
        { seed = "negative_fixture_support_pressure_rock_los", horizon = 3 }
    ))
    local contract = assert(compositionComposer.buildContract(
        "support_under_real_red_pressure",
        line,
        consequences,
        { seed = "negative_fixture_support_pressure_rock_los" }
    ))
    if mutator then
        mutator(contract)
    end
    return contract, line
end

local function supportPressureRockLosState(id)
    return baseState(id, {
        unit("blue_a_support", "Artillery", 1, 3, 6, 5),
        unit("blue_finisher", "Cloudstriker", 1, 6, 2, 4),
        unit("red_commandant", "Commandant", 2, 2, 5, 12),
        unit("red_decoy", "Crusher", 2, 6, 5, 4),
        unit("red_support_threat", "Earthstalker", 2, 5, 6, 3),
        unit("neutral_rock", "Rock", 0, 2, 4, 2),
        unit("neutral_shortcut_rock", "Rock", 0, 3, 5, 2)
    })
end

local function supportPressureRockLosPredicates(extra, roleEvidence)
    return compositePredicateResults(extra, roleEvidence or {
        redPressureUnit = "red_support_threat",
        contactBlockerUnit = "neutral_rock",
        contactBlockerAlsoPressure = false,
        pressureCanBeAttackedAtStart = false
    })
end

local function supportPressureRockLosDossier(id, contract, line, predicates)
    return dossier(
        id,
        supportPressureRockLosState(id),
        predicates or supportPressureRockLosPredicates(),
        {
            contractPattern = "support_under_real_red_pressure",
            microInteractions = {
                { id = "SUPPORT_CELL_GAIN" },
                { id = "RED_ATTACKS_SUPPORT" },
                { id = "ROCK_AS_LOCK" },
                { id = "LOS_OPEN_RANGED" },
                { id = "FINISHER_CELL_GAIN" },
                { id = "WRONG_TARGET_TEMPO_LOSS" },
                { id = "HP_EXACT_WINDOW" }
            },
            tacticalFingerprint = {
                schema = "TacticalFingerprint",
                fingerprint_version = "fixture",
                signature = id,
                hash = id,
                mechanism_family = "line_setup_pressure",
                micro_sequence_signature = "SUPPORT_CELL_GAIN>RED_ATTACKS_SUPPORT>ROCK_AS_LOCK>LOS_OPEN_RANGED",
                role_signature = "Cloudstriker+earthstalker_pressure+support_artillery+rock_lock",
                geometry_signature = "fixture"
            },
            solution = { actions = cloneValue(line or supportPressureRockLosLine()) },
            compositionalContract = contract,
            ablationResults = contract and cloneValue(contract.actionConsequences) or {},
            solverProof = { status = "fixture_only" },
            falseLines = {},
            mechanismSpec = {
                schema = "MechanismSpec",
                id = id .. "_mechanism",
                lock = "negative_support_pressure_rock_los_lock",
                key = "negative_support_pressure_rock_los_key",
                path = "negative_support_pressure_rock_los_path",
                risk = "negative_support_pressure_rock_los_risk",
                payoff = "negative_support_pressure_rock_los_payoff"
            }
        }
    )
end

local function interceptorArtilleryLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 6, col = 2 } },
        { type = "attack", actorId = "blue_a_support", targetId = "red_interceptor" },
        { type = "move", actorId = "blue_finisher", to = { row = 6, col = 3 } },
        { type = "move", actorId = "blue_finisher", to = { row = 5, col = 3 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function interceptorArtilleryContract(mutator)
    local line = interceptorArtilleryLine()
    local consequences = assert(compositionComposer.buildActionConsequences(
        "support_intercepts_finisher_threat_artillery_finish",
        {
            { slotId = "support_interceptor_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "interceptor_before_1", afterStateHash = "interceptor_after_1" },
            { slotId = "support_interceptor_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "interceptor_before_2", afterStateHash = "interceptor_after_2" },
            { slotId = "artillery_staging_move", actionIndex = 3, action = line[3], beforeStateHash = "interceptor_before_3", afterStateHash = "interceptor_after_3" },
            { slotId = "artillery_final_cell_move", actionIndex = 4, action = line[4], beforeStateHash = "interceptor_before_4", afterStateHash = "interceptor_after_4" },
            { slotId = "commandant_payoff_attack", actionIndex = 5, action = line[5], beforeStateHash = "interceptor_before_5", afterStateHash = "interceptor_after_5" }
        },
        { seed = "negative_fixture_interceptor_artillery", horizon = 3 }
    ))
    local contract = assert(compositionComposer.buildContract(
        "support_intercepts_finisher_threat_artillery_finish",
        line,
        consequences,
        { seed = "negative_fixture_interceptor_artillery" }
    ))
    if mutator then
        mutator(contract)
    end
    return contract, line
end

local function interceptorArtilleryState(id)
    return baseState(id, {
        unit("blue_a_support", "Bastion", 1, 7, 2, 6),
        unit("blue_finisher", "Artillery", 1, 7, 3, 4),
        unit("red_commandant", "Commandant", 2, 2, 3, 2),
        unit("red_interceptor", "Earthstalker", 2, 6, 3, 1)
    })
end

local function interceptorArtilleryPredicates(extra, roleEvidence)
    return compositePredicateResults(extra, roleEvidence or {
        redPressureUnit = "red_interceptor",
        finisherInterceptorUnit = "red_interceptor",
        pressureCanBeAttackedAtStart = false
    })
end

local function interceptorArtilleryDossier(id, contract, line, predicates)
    return dossier(
        id,
        interceptorArtilleryState(id),
        predicates or interceptorArtilleryPredicates(),
        {
            contractPattern = "support_intercepts_finisher_threat_artillery_finish",
            microInteractions = {
                { id = "SUPPORT_CELL_GAIN" },
                { id = "RED_ATTACKS_FINISHER" },
                { id = "FINISHER_CELL_GAIN" },
                { id = "WRONG_TARGET_TEMPO_LOSS" },
                { id = "ORDER_DEPENDENCY" },
                { id = "HP_EXACT_WINDOW" }
            },
            tacticalFingerprint = {
                schema = "TacticalFingerprint",
                fingerprint_version = "fixture",
                signature = id,
                hash = id,
                mechanism_family = "timing_lock",
                micro_sequence_signature = "SUPPORT_CELL_GAIN>RED_ATTACKS_FINISHER>FINISHER_CELL_GAIN",
                role_signature = "Artillery+support_interceptor+finisher_pressure",
                geometry_signature = "fixture"
            },
            solution = { actions = cloneValue(line or interceptorArtilleryLine()) },
            compositionalContract = contract,
            ablationResults = contract and cloneValue(contract.actionConsequences) or {},
            solverProof = { status = "fixture_only" },
            falseLines = {},
            mechanismSpec = {
                schema = "MechanismSpec",
                id = id .. "_mechanism",
                lock = "negative_interceptor_artillery_lock",
                key = "negative_interceptor_artillery_key",
                path = "negative_interceptor_artillery_path",
                risk = "negative_interceptor_artillery_risk",
                payoff = "negative_interceptor_artillery_payoff"
            }
        }
    )
end

local function dualRockLockLine()
    return {
        { type = "move", actorId = "blue_a_support", to = { row = 4, col = 2 } },
        { type = "attack", actorId = "blue_a_support", targetId = "neutral_lower_rock" },
        { type = "move", actorId = "blue_a_support", to = { row = 3, col = 2 } },
        { type = "attack", actorId = "blue_a_support", targetId = "neutral_upper_rock" },
        { type = "move", actorId = "blue_finisher", to = { row = 5, col = 4 } },
        { type = "attack", actorId = "blue_finisher", targetId = "red_commandant" }
    }
end

local function dualRockLockContract(mutator)
    local line = dualRockLockLine()
    local consequences = assert(compositionComposer.buildActionConsequences(
        "dual_rock_lock_ranged_finish",
        {
            { slotId = "support_lower_lock_setup_move", actionIndex = 1, action = line[1], beforeStateHash = "dual_lock_before_1", afterStateHash = "dual_lock_after_1" },
            { slotId = "support_lower_rock_clear_attack", actionIndex = 2, action = line[2], beforeStateHash = "dual_lock_before_2", afterStateHash = "dual_lock_after_2" },
            { slotId = "support_upper_lock_setup_move", actionIndex = 3, action = line[3], beforeStateHash = "dual_lock_before_3", afterStateHash = "dual_lock_after_3" },
            { slotId = "support_upper_rock_clear_attack", actionIndex = 4, action = line[4], beforeStateHash = "dual_lock_before_4", afterStateHash = "dual_lock_after_4" },
            { slotId = "finisher_dual_lock_cell_move", actionIndex = 5, action = line[5], beforeStateHash = "dual_lock_before_5", afterStateHash = "dual_lock_after_5" },
            { slotId = "commandant_payoff_attack", actionIndex = 6, action = line[6], beforeStateHash = "dual_lock_before_6", afterStateHash = "dual_lock_after_6" }
        },
        { seed = "negative_fixture_dual_rock_lock", horizon = 3 }
    ))
    local contract = assert(compositionComposer.buildContract(
        "dual_rock_lock_ranged_finish",
        line,
        consequences,
        { seed = "negative_fixture_dual_rock_lock" }
    ))
    if mutator then
        mutator(contract)
    end
    return contract, line
end

local function dualRockLockState(id)
    return baseState(id, {
        unit("blue_a_support", "Artillery", 1, 5, 2, 5),
        unit("blue_finisher", "Cloudstriker", 1, 8, 4, 4),
        unit("red_commandant", "Commandant", 2, 2, 4, 3),
        unit("neutral_lower_rock", "Rock", 0, 4, 4, 2),
        unit("neutral_upper_rock", "Rock", 0, 3, 4, 2)
    })
end

local function dualRockLockPredicates(extra, roleEvidence)
    roleEvidence = roleEvidence or {
        dualRockLockChain = true,
        lowerRockMustBeResolved = true,
        upperRockMustBeResolved = true,
        pressureCanBeAttackedAtStart = false
    }
    return compositePredicateResults(extra, roleEvidence)
end

local function dualRockLockDossier(id, contract, line, predicates)
    return dossier(
        id,
        dualRockLockState(id),
        predicates or dualRockLockPredicates(),
        {
            contractPattern = "dual_rock_lock_ranged_finish",
            microInteractions = {
                { id = "SUPPORT_CELL_GAIN" },
                { id = "ROCK_AS_LOCK" },
                { id = "ORDER_DEPENDENCY" },
                { id = "LOS_OPEN_RANGED" },
                { id = "FINISHER_CELL_GAIN" },
                { id = "WRONG_TARGET_TEMPO_LOSS" },
                { id = "HP_EXACT_WINDOW" }
            },
            tacticalFingerprint = {
                schema = "TacticalFingerprint",
                fingerprint_version = "fixture",
                signature = id,
                hash = id,
                mechanism_family = "line_setup",
                micro_sequence_signature = "SUPPORT_CELL_GAIN>ROCK_AS_LOCK>ORDER_DEPENDENCY>LOS_OPEN_RANGED",
                role_signature = "Cloudstriker+dual_rock_lock_chain+ranged_payoff",
                geometry_signature = "fixture"
            },
            solution = { actions = cloneValue(line or dualRockLockLine()) },
            compositionalContract = contract,
            ablationResults = contract and cloneValue(contract.actionConsequences) or {},
            solverProof = { status = "fixture_only" },
            falseLines = {},
            mechanismSpec = {
                schema = "MechanismSpec",
                id = id .. "_mechanism",
                lock = "negative_dual_rock_lock_lock",
                key = "negative_dual_rock_lock_key",
                path = "negative_dual_rock_lock_path",
                risk = "negative_dual_rock_lock_risk",
                payoff = "negative_dual_rock_lock_payoff"
            }
        }
    )
end

negativeFixtures.requiredFixtureIds = {
    "already_ready_damage_clock",
    "free_finisher_move_and_shoot",
    "support_already_in_position",
    "cosmetic_red_pressure",
    "decorative_rock",
    "novelty_history_rejects_everything",
    "micro_interactions_same_order",
    "finisher_library_macro_template",
    "unexpected_red_defense_breaks_solution",
    "passive_red_blocks_key_cell",
    "red_attacks_rock_or_critical_blue",
    "too_narrow_defensive_domain_false_forced_win",
    "component_listed_without_action_consequence",
    "component_consequence_empty_changed_outputs",
    "component_pressure_blocker_same_unit",
    "component_first_move_obvious_attack",
    "component_order_scripted_macro_template",
    "crusher_component_listed_without_action_consequence",
    "crusher_component_consequence_empty_changed_outputs",
    "crusher_component_first_move_obvious_attack",
    "rock_lock_component_decorative",
    "los_opening_component_already_open",
    "rock_los_component_listed_without_action_consequence",
    "rock_los_component_consequence_empty_changed_outputs",
    "support_pressure_rock_los_component_listed_without_action_consequence",
    "support_pressure_rock_los_component_consequence_empty_changed_outputs",
    "support_pressure_not_real_or_cosmetic",
    "support_pressure_unit_free_to_remove_opening",
    "support_pressure_rock_decorative",
    "support_pressure_los_already_open",
    "interceptor_artillery_component_listed_without_action_consequence",
    "interceptor_artillery_component_consequence_empty_changed_outputs",
    "interceptor_artillery_pressure_not_real_or_cosmetic",
    "interceptor_artillery_pressure_free_to_remove",
    "interceptor_artillery_interceptor_decorative",
    "interceptor_artillery_finisher_final_cell_free",
    "interceptor_artillery_scripted_policy_line_macro_template",
    "dual_lock_component_listed_without_action_consequence",
    "dual_lock_component_consequence_empty_changed_outputs",
    "dual_lock_upper_rock_decorative",
    "dual_lock_lane_already_open",
    "dual_lock_scripted_macro_template"
}

negativeFixtures.fixtures = {
    {
        id = "already_ready_damage_clock",
        title = "Already-ready Blue units repeatedly damage the Commandant",
        expectedOutcome = "reject",
        expectedReasons = {"static_damage_clock", "multi_unit_damage_clock"},
        primaryPredicates = {"static_damage_clock", "multi_unit_damage_clock"},
        dossier = dossier(
            "already_ready_damage_clock",
            baseState("already_ready_damage_clock", standardUnits()),
            {
                predicate("static_damage_clock", true, {
                    note = "All Commandant damage is already available at start."
                }),
                predicate("multi_unit_damage_clock", true, {
                    note = "Two ready attackers repeat damage without transformation."
                })
            }
        )
    },
    {
        id = "free_finisher_move_and_shoot",
        title = "Finisher only moves for free and shoots",
        expectedOutcome = "reject",
        expectedReasons = {"free_finisher_move"},
        primaryPredicates = {"free_finisher_move", "position_gained"},
        dossier = dossier(
            "free_finisher_move_and_shoot",
            baseState("free_finisher_move_and_shoot", standardUnits()),
            {
                predicate("free_finisher_move", true, {
                    finisher = "Cloudstriker",
                    note = "No cost, risk, blocker, timing, or trade-off makes the final cell earned."
                }),
                predicate("position_gained", false, {
                    cell = "D4"
                })
            }
        )
    },
    {
        id = "support_already_in_position",
        title = "Support unit is already in position from the start",
        expectedOutcome = "reject",
        expectedReasons = {"support_already_free"},
        primaryPredicates = {"support_already_free", "position_gained"},
        dossier = dossier(
            "support_already_in_position",
            baseState("support_already_in_position", standardUnits()),
            {
                predicate("support_already_free", true, {
                    support = "Artillery",
                    note = "The support shot contributes damage without needing a key, path, or risk."
                }),
                predicate("position_gained", false, {
                    unit = "blue_artillery"
                })
            }
        )
    },
    {
        id = "cosmetic_red_pressure",
        title = "Red pressure changes no Blue decision",
        expectedOutcome = "reject",
        expectedReasons = {"cosmetic_red_pressure", "red_pressure_not_real"},
        primaryPredicates = {"cosmetic_red_pressure", "real_pressure"},
        dossier = dossier(
            "cosmetic_red_pressure",
            baseState("cosmetic_red_pressure", standardUnits()),
            {
                predicate("cosmetic_red_pressure", true, {
                    note = "Removing the Red threat preserves winning line, false line, and exactness."
                }),
                predicate("real_pressure", false, {
                    redFeature = "red_bastion_zone"
                })
            }
        )
    },
    {
        id = "decorative_rock",
        title = "Rock is listed but has no tactical effect",
        expectedOutcome = "reject",
        expectedReasons = {"decorative_micro_interaction"},
        primaryPredicates = {"non_decorative_micro", "required_cell", "required_line"},
        dossier = dossier(
            "decorative_rock",
            baseState(
                "decorative_rock",
                standardUnits({
                    unit("neutral_rock", "Rock", 0, 8, 8, 5)
                })
            ),
            {
                predicate("non_decorative_micro", false, {
                    microId = "ROCK_AS_LOCK",
                    note = "Ablation removes the Rock with no proof, replay, or fingerprint change."
                }),
                predicate("required_cell", false, {
                    cell = "H8"
                }),
                predicate("required_line", false, {
                    line = "H-file"
                })
            }
        )
    },
    {
        id = "novelty_history_rejects_everything",
        title = "History rejects almost every otherwise valid seed",
        expectedOutcome = "reject",
        expectedReasons = {"fingerprint_not_distinct"},
        primaryPredicates = {"fingerprint_distinct", "macro_template_signature"},
        dossier = dossier(
            "novelty_history_rejects_everything",
            baseState("novelty_history_rejects_everything", standardUnits()),
            {
                predicate("fingerprint_distinct", false, {
                    collisionRate = 0.85,
                    note = "Novelty comes from history filtering instead of native generative variety."
                })
            }
        )
    },
    {
        id = "micro_interactions_same_order",
        title = "Micro-interactions appear in the same order repeatedly",
        expectedOutcome = "reject",
        expectedReasons = {"macro_template_signature"},
        primaryPredicates = {"macro_template_signature", "fingerprint_distinct"},
        dossier = dossier(
            "micro_interactions_same_order",
            baseState("micro_interactions_same_order", standardUnits()),
            {
                predicate("macro_template_signature", true, {
                    sequence = {"LOS_OPEN_RANGED", "SUPPORT_CELL_GAIN", "HP_EXACT_WINDOW"},
                    note = "The local order repeats as a disguised macro-template."
                })
            }
        )
    },
    {
        id = "finisher_library_macro_template",
        title = "Finisher library determines the whole puzzle",
        expectedOutcome = "reject",
        expectedReasons = {"macro_template_signature"},
        primaryPredicates = {"macro_template_signature"},
        dossier = dossier(
            "finisher_library_macro_template",
            baseState("finisher_library_macro_template", standardUnits()),
            {
                predicate("macro_template_signature", true, {
                    finisher = "Crusher",
                    note = "The finisher selection implies the global lock, path, false line, and payoff."
                })
            }
        )
    },
    {
        id = "unexpected_red_defense_breaks_solution",
        title = "Unexpected Red defense breaks the certified line",
        expectedOutcome = "unknown",
        expectedReasons = {"unknown_defensive_domain_move"},
        primaryPredicates = {"defensive_domain_inclusion", "gains_time"},
        dossier = dossier(
            "unexpected_red_defense_breaks_solution",
            baseState("unexpected_red_defense_breaks_solution", standardUnits()),
            {
                predicate("static_damage_clock", false),
                predicate("multi_unit_damage_clock", false),
                predicate("free_finisher_move", false),
                predicate("support_already_free", false),
                predicate("cosmetic_red_pressure", false),
                predicate("macro_template_signature", false),
                predicate("fingerprint_distinct", true),
                predicate("non_decorative_micro", true),
                predicate("real_pressure", true),
                predicate("gains_time", true, {
                    redAction = "Bastion to D2"
                })
            },
            {
                defensiveProofUsed = true,
                defensiveDomainDecisions = {
                    {
                        schema = "DefensiveDomainDecision",
                        redAction = {type = "move", unitId = "red_bastion", to = "D2"},
                        decision = "unknown",
                        reasonCodes = {"unmodeled_commandant_defense"},
                        predicateInputs = {
                            state = "unexpected_red_defense_breaks_solution",
                            redAction = "Bastion to D2"
                        },
                        predicateResults = {
                            predicate("gains_time", true)
                        },
                        policyScoreBand = "fixture_uncomputed",
                        equivalenceReason = "not_proven_equivalent",
                        domainVersion = "fixture"
                    }
                }
            }
        )
    },
    {
        id = "passive_red_blocks_key_cell",
        title = "Passive Red move blocks a required key cell",
        expectedOutcome = "unknown",
        expectedReasons = {"unknown_defensive_domain_move"},
        primaryPredicates = {"required_cell", "defensive_domain_inclusion"},
        dossier = dossier(
            "passive_red_blocks_key_cell",
            baseState("passive_red_blocks_key_cell", standardUnits()),
            {
                predicate("static_damage_clock", false),
                predicate("multi_unit_damage_clock", false),
                predicate("free_finisher_move", false),
                predicate("support_already_free", false),
                predicate("cosmetic_red_pressure", false),
                predicate("macro_template_signature", false),
                predicate("fingerprint_distinct", true),
                predicate("non_decorative_micro", true),
                predicate("real_pressure", true),
                predicate("required_cell", true, {
                    cell = "D2"
                })
            },
            {
                defensiveProofUsed = true,
                defensiveDomainDecisions = {
                    {
                        schema = "DefensiveDomainDecision",
                        redAction = {type = "move", unitId = "red_bastion", to = "D2"},
                        decision = "unknown",
                        reasonCodes = {"blocks_required_cell"},
                        predicateInputs = {
                            state = "passive_red_blocks_key_cell",
                            redAction = "Bastion to D2"
                        },
                        predicateResults = {
                            predicate("required_cell", true)
                        },
                        policyScoreBand = "fixture_uncomputed",
                        equivalenceReason = "not_proven_equivalent",
                        domainVersion = "fixture"
                    }
                }
            }
        )
    },
    {
        id = "red_attacks_rock_or_critical_blue",
        title = "Red can attack Rock or critical Blue unit",
        expectedOutcome = "unknown",
        expectedReasons = {"unknown_defensive_domain_move"},
        primaryPredicates = {"critical_blue_unit", "prevents_micro_interaction", "defensive_domain_inclusion"},
        dossier = dossier(
            "red_attacks_rock_or_critical_blue",
            baseState(
                "red_attacks_rock_or_critical_blue",
                standardUnits({
                    unit("neutral_lock_rock", "Rock", 0, 3, 4, 5)
                })
            ),
            {
                predicate("static_damage_clock", false),
                predicate("multi_unit_damage_clock", false),
                predicate("free_finisher_move", false),
                predicate("support_already_free", false),
                predicate("cosmetic_red_pressure", false),
                predicate("macro_template_signature", false),
                predicate("fingerprint_distinct", true),
                predicate("non_decorative_micro", true),
                predicate("real_pressure", true),
                predicate("critical_blue_unit", true, {
                    unit = "blue_cloud"
                }),
                predicate("prevents_micro_interaction", true, {
                    microId = "ROCK_AS_LOCK"
                })
            },
            {
                defensiveProofUsed = true,
                defensiveDomainDecisions = {
                    {
                        schema = "DefensiveDomainDecision",
                        redAction = {type = "attack", unitId = "red_bastion", targetId = "blue_cloud"},
                        decision = "unknown",
                        reasonCodes = {"attacks_critical_blue_unit"},
                        predicateInputs = {
                            state = "red_attacks_rock_or_critical_blue",
                            redAction = "Bastion attacks Cloudstriker"
                        },
                        predicateResults = {
                            predicate("critical_blue_unit", true)
                        },
                        policyScoreBand = "fixture_uncomputed",
                        equivalenceReason = "not_proven_equivalent",
                        domainVersion = "fixture"
                    },
                    {
                        schema = "DefensiveDomainDecision",
                        redAction = {type = "attack", unitId = "red_bastion", targetId = "neutral_lock_rock"},
                        decision = "unknown",
                        reasonCodes = {"attacks_required_rock_lock"},
                        predicateInputs = {
                            state = "red_attacks_rock_or_critical_blue",
                            redAction = "Bastion attacks Rock"
                        },
                        predicateResults = {
                            predicate("prevents_micro_interaction", true)
                        },
                        policyScoreBand = "fixture_uncomputed",
                        equivalenceReason = "not_proven_equivalent",
                        domainVersion = "fixture"
                    }
                }
            }
        )
    },
    {
        id = "too_narrow_defensive_domain_false_forced_win",
        title = "Too-narrow defensive domain creates false forced_win",
        expectedOutcome = "unknown",
        expectedReasons = {"missing_defensive_domain_decisions"},
        primaryPredicates = {"defensive_domain_inclusion", "defensive_equivalence"},
        dossier = dossier(
            "too_narrow_defensive_domain_false_forced_win",
            baseState("too_narrow_defensive_domain_false_forced_win", standardUnits()),
            {
                predicate("static_damage_clock", false),
                predicate("multi_unit_damage_clock", false),
                predicate("free_finisher_move", false),
                predicate("support_already_free", false),
                predicate("cosmetic_red_pressure", false),
                predicate("macro_template_signature", false),
                predicate("fingerprint_distinct", true),
                predicate("non_decorative_micro", true),
                predicate("real_pressure", true),
                predicate("defensive_equivalence", nil, {
                    note = "The excluded Red moves were never proven equivalent."
                })
            },
            {
                defensiveProofUsed = true,
                defensiveDomainDecisions = {}
            }
        )
    },
    {
        id = "component_listed_without_action_consequence",
        title = "Component is listed but has no action consequence",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro", "required_line"},
        dossier = (function()
            local contract, line = compositeContract(function(c)
                table.remove(c.actionConsequences, 1)
            end)
            return compositeDossier("component_listed_without_action_consequence", contract, line)
        end)()
    },
    {
        id = "component_consequence_empty_changed_outputs",
        title = "Component consequence exists but changed outputs are empty",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro"},
        dossier = (function()
            local contract, line = compositeContract(function(c)
                local consequence = c.actionConsequences[1]
                consequence.changed = false
                consequence.changed_outputs = {}
                consequence.delta_metrics = consequence.delta_metrics or {}
                consequence.delta_metrics.changed_outputs = {}
                consequence.winning_line = nil
                consequence.red_response = nil
                consequence.false_line = nil
                consequence.exactness = nil
                consequence.outcome = nil
                consequence.legal_move_set = nil
            end)
            return compositeDossier("component_consequence_empty_changed_outputs", contract, line)
        end)()
    },
    {
        id = "component_pressure_blocker_same_unit",
        title = "Component uses the same Red unit as pressure and blocker",
        expectedOutcome = "reject",
        expectedReasons = {"composite_pressure_blocker_same_unit"},
        primaryPredicates = {"critical_blue_unit", "real_pressure"},
        dossier = (function()
            local contract, line = compositeContract()
            return compositeDossier(
                "component_pressure_blocker_same_unit",
                contract,
                line,
                compositePredicateResults(nil, {
                    redPressureUnit = "red_contact_blocker",
                    contactBlockerUnit = "red_contact_blocker",
                    contactBlockerAlsoPressure = true,
                    pressureCanBeAttackedAtStart = false
                })
            )
        end)()
    },
    {
        id = "component_first_move_obvious_attack",
        title = "First move is an obvious attack on pressure or blocker",
        expectedOutcome = "reject",
        expectedReasons = {"composite_too_obvious_first_move"},
        primaryPredicates = {"required_line", "non_decorative_micro"},
        dossier = (function()
            local firstAction = { type = "attack", actorId = "blue_a_support", targetId = "red_contact_blocker" }
            local contract, line = compositeContract(nil, firstAction)
            return compositeDossier("component_first_move_obvious_attack", contract, line)
        end)()
    },
    {
        id = "component_order_scripted_macro_template",
        title = "Component order is a scripted macro-template",
        expectedOutcome = "reject",
        expectedReasons = {"macro_template_signature"},
        primaryPredicates = {"macro_template_signature"},
        dossier = (function()
            local contract, line = compositeContract()
            return compositeDossier(
                "component_order_scripted_macro_template",
                contract,
                line,
                compositePredicateResults({
                    predicate("macro_template_signature", true, {
                        sequence = {
                            "support_pressure_answer",
                            "contact_blocker_clear",
                            "finisher_staging_gain",
                            "exact_contact_payoff"
                        },
                        note = "The component order is being used as a full scenario macro-template."
                    })
                })
            )
        end)()
    },
    {
        id = "crusher_component_listed_without_action_consequence",
        title = "Crusher contact component is listed but has no action consequence",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro", "required_line"},
        dossier = (function()
            local contract, line = crusherContactContract(function(c)
                table.remove(c.actionConsequences, 1)
            end)
            return crusherContactDossier("crusher_component_listed_without_action_consequence", contract, line)
        end)()
    },
    {
        id = "crusher_component_consequence_empty_changed_outputs",
        title = "Crusher contact component consequence exists but changed outputs are empty",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro"},
        dossier = (function()
            local contract, line = crusherContactContract(function(c)
                local consequence = c.actionConsequences[1]
                consequence.changed = false
                consequence.changed_outputs = {}
                consequence.delta_metrics = consequence.delta_metrics or {}
                consequence.delta_metrics.changed_outputs = {}
                consequence.winning_line = nil
                consequence.red_response = nil
                consequence.false_line = nil
                consequence.exactness = nil
                consequence.outcome = nil
                consequence.legal_move_set = nil
            end)
            return crusherContactDossier("crusher_component_consequence_empty_changed_outputs", contract, line)
        end)()
    },
    {
        id = "crusher_component_first_move_obvious_attack",
        title = "Crusher contact first move is an obvious attack on the blocker",
        expectedOutcome = "reject",
        expectedReasons = {"composite_too_obvious_first_move"},
        primaryPredicates = {"required_line", "non_decorative_micro"},
        dossier = (function()
            local firstAction = { type = "attack", actorId = "blue_a_support", targetId = "red_contact_blocker" }
            local contract, line = crusherContactContract(nil, firstAction)
            return crusherContactDossier("crusher_component_first_move_obvious_attack", contract, line)
        end)()
    },
    {
        id = "rock_lock_component_decorative",
        title = "Rock lock component is decorative and changes no proof",
        expectedOutcome = "reject",
        expectedReasons = {"decorative_micro_interaction"},
        primaryPredicates = {"non_decorative_micro", "required_cell", "required_line"},
        dossier = dossier(
            "rock_lock_component_decorative",
            baseState(
                "rock_lock_component_decorative",
                standardUnits({
                    unit("neutral_rock", "Rock", 0, 8, 8, 5)
                })
            ),
            {
                predicate("static_damage_clock", false),
                predicate("multi_unit_damage_clock", false),
                predicate("free_finisher_move", false),
                predicate("support_already_free", false),
                predicate("cosmetic_red_pressure", false),
                predicate("macro_template_signature", false),
                predicate("fingerprint_distinct", true),
                predicate("real_pressure", true),
                predicate("non_decorative_micro", false, {
                    componentId = "rock_lock_conversion",
                    microId = "ROCK_AS_LOCK",
                    note = "The Rock is present but no replay, legal set, proof, or fingerprint changes."
                }),
                predicate("required_cell", false, {
                    cell = "H8"
                }),
                predicate("required_line", false, {
                    componentId = "rock_lock_conversion"
                })
            },
            {
                microInteractions = {
                    { id = "ROCK_AS_LOCK" }
                },
                tacticalFingerprint = {
                    schema = "TacticalFingerprint",
                    fingerprint_version = "fixture",
                    signature = "rock_lock_component_decorative",
                    hash = "rock_lock_component_decorative",
                    mechanism_family = "board_lock_key",
                    micro_sequence_signature = "ROCK_AS_LOCK",
                    role_signature = "decorative_rock_lock",
                    geometry_signature = "fixture"
                }
            }
        )
    },
    {
        id = "los_opening_component_already_open",
        title = "LOS opening component is already open at start",
        expectedOutcome = "reject",
        expectedReasons = {"decorative_micro_interaction", "free_finisher_move"},
        primaryPredicates = {"non_decorative_micro", "required_cell", "free_finisher_move"},
        dossier = dossier(
            "los_opening_component_already_open",
            baseState("los_opening_component_already_open", standardUnits()),
            {
                predicate("static_damage_clock", false),
                predicate("multi_unit_damage_clock", false),
                predicate("free_finisher_move", true, {
                    componentId = "los_open_ranged_lane",
                    note = "The finisher already has the relevant line and setup does not earn it."
                }),
                predicate("support_already_free", false),
                predicate("cosmetic_red_pressure", false),
                predicate("macro_template_signature", false),
                predicate("fingerprint_distinct", true),
                predicate("real_pressure", true),
                predicate("non_decorative_micro", false, {
                    componentId = "los_open_ranged_lane",
                    microId = "LOS_OPEN_RANGED",
                    note = "The declared opening is decorative because the lane is already open."
                }),
                predicate("required_cell", false, {
                    componentId = "ranged_los_opening"
                })
            },
            {
                microInteractions = {
                    { id = "LOS_OPEN_RANGED" }
                },
                tacticalFingerprint = {
                    schema = "TacticalFingerprint",
                    fingerprint_version = "fixture",
                    signature = "los_opening_component_already_open",
                    hash = "los_opening_component_already_open",
                    mechanism_family = "line_setup",
                    micro_sequence_signature = "LOS_OPEN_RANGED",
                    role_signature = "decorative_los_opening",
                    geometry_signature = "fixture"
                }
            }
        )
    },
    {
        id = "rock_los_component_listed_without_action_consequence",
        title = "Rock/LOS profile component is listed but has no action consequence",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro", "required_line"},
        dossier = (function()
            local contract, line = rockLosContract(function(c)
                table.remove(c.actionConsequences, 1)
            end)
            return rockLosDossier("rock_los_component_listed_without_action_consequence", contract, line)
        end)()
    },
    {
        id = "rock_los_component_consequence_empty_changed_outputs",
        title = "Rock/LOS profile component consequence exists but changed outputs are empty",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro"},
        dossier = (function()
            local contract, line = rockLosContract(function(c)
                local consequence = c.actionConsequences[1]
                consequence.changed = false
                consequence.changed_outputs = {}
                consequence.delta_metrics = consequence.delta_metrics or {}
                consequence.delta_metrics.changed_outputs = {}
                consequence.winning_line = nil
                consequence.red_response = nil
                consequence.false_line = nil
                consequence.exactness = nil
                consequence.outcome = nil
                consequence.legal_move_set = nil
            end)
            return rockLosDossier("rock_los_component_consequence_empty_changed_outputs", contract, line)
        end)()
    },
    {
        id = "support_pressure_rock_los_component_listed_without_action_consequence",
        title = "Support pressure Rock/LOS component is listed but has no action consequence",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro", "required_line", "real_pressure"},
        dossier = (function()
            local contract, line = supportPressureRockLosContract(function(c)
                table.remove(c.actionConsequences, 1)
            end)
            return supportPressureRockLosDossier("support_pressure_rock_los_component_listed_without_action_consequence", contract, line)
        end)()
    },
    {
        id = "support_pressure_rock_los_component_consequence_empty_changed_outputs",
        title = "Support pressure Rock/LOS action consequence exists but changed outputs are empty",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro", "real_pressure"},
        dossier = (function()
            local contract, line = supportPressureRockLosContract(function(c)
                local consequence = c.actionConsequences[1]
                consequence.changed = false
                consequence.changed_outputs = {}
                consequence.delta_metrics = consequence.delta_metrics or {}
                consequence.delta_metrics.changed_outputs = {}
                consequence.winning_line = nil
                consequence.red_response = nil
                consequence.false_line = nil
                consequence.exactness = nil
                consequence.outcome = nil
                consequence.legal_move_set = nil
            end)
            return supportPressureRockLosDossier("support_pressure_rock_los_component_consequence_empty_changed_outputs", contract, line)
        end)()
    },
    {
        id = "support_pressure_not_real_or_cosmetic",
        title = "Support pressure profile declares pressure that is cosmetic",
        expectedOutcome = "reject",
        expectedReasons = {"cosmetic_red_pressure", "red_pressure_not_real"},
        primaryPredicates = {"real_pressure", "cosmetic_red_pressure"},
        dossier = (function()
            local contract, line = supportPressureRockLosContract()
            local predicates = supportPressureRockLosPredicates({
                predicate("cosmetic_red_pressure", true, {
                    componentId = "support_pressure_answer",
                    note = "Red pressure does not change a false line, replay, or policy proof."
                }),
                predicate("real_pressure", false, {
                    componentId = "support_pressure_answer",
                    note = "The pressure is named but not computably threatening."
                })
            })
            return supportPressureRockLosDossier("support_pressure_not_real_or_cosmetic", contract, line, predicates)
        end)()
    },
    {
        id = "support_pressure_unit_free_to_remove_opening",
        title = "Support pressure can be removed on the opening instead of answered",
        expectedOutcome = "reject",
        expectedReasons = {"composite_pressure_free_to_remove"},
        primaryPredicates = {"critical_blue_unit", "real_pressure"},
        dossier = (function()
            local contract, line = supportPressureRockLosContract()
            local predicates = supportPressureRockLosPredicates(nil, {
                redPressureUnit = "red_support_threat",
                contactBlockerUnit = "neutral_rock",
                contactBlockerAlsoPressure = false,
                pressureCanBeAttackedAtStart = true
            })
            return supportPressureRockLosDossier("support_pressure_unit_free_to_remove_opening", contract, line, predicates)
        end)()
    },
    {
        id = "support_pressure_rock_decorative",
        title = "Support pressure Rock lock is decorative",
        expectedOutcome = "reject",
        expectedReasons = {"decorative_micro_interaction"},
        primaryPredicates = {"non_decorative_micro", "required_cell", "required_line"},
        dossier = (function()
            local contract, line = supportPressureRockLosContract()
            local predicates = supportPressureRockLosPredicates({
                predicate("non_decorative_micro", false, {
                    componentId = "rock_lock_conversion",
                    microId = "ROCK_AS_LOCK",
                    note = "The pressure profile keeps the Rock label, but removing it changes no proof output."
                }),
                predicate("required_cell", false, {
                    cell = "B2",
                    componentId = "rock_lock_conversion"
                }),
                predicate("required_line", false, {
                    componentId = "rock_lock_conversion"
                })
            })
            return supportPressureRockLosDossier("support_pressure_rock_decorative", contract, line, predicates)
        end)()
    },
    {
        id = "support_pressure_los_already_open",
        title = "Support pressure LOS lane is already open at start",
        expectedOutcome = "reject",
        expectedReasons = {"decorative_micro_interaction", "free_finisher_move"},
        primaryPredicates = {"non_decorative_micro", "required_cell", "free_finisher_move"},
        dossier = (function()
            local contract, line = supportPressureRockLosContract()
            local predicates = supportPressureRockLosPredicates({
                predicate("free_finisher_move", true, {
                    componentId = "los_open_ranged_lane",
                    note = "The finisher already has the ranged lane and no action earns it."
                }),
                predicate("non_decorative_micro", false, {
                    componentId = "los_open_ranged_lane",
                    microId = "LOS_OPEN_RANGED",
                    note = "LOS_OPEN_RANGED is declared but already true at start."
                })
            })
            return supportPressureRockLosDossier("support_pressure_los_already_open", contract, line, predicates)
        end)()
    },
    {
        id = "interceptor_artillery_component_listed_without_action_consequence",
        title = "Interceptor Artillery profile component is listed but has no action consequence",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro", "required_line", "real_pressure"},
        dossier = (function()
            local contract, line = interceptorArtilleryContract(function(c)
                table.remove(c.actionConsequences, 2)
            end)
            return interceptorArtilleryDossier("interceptor_artillery_component_listed_without_action_consequence", contract, line)
        end)()
    },
    {
        id = "interceptor_artillery_component_consequence_empty_changed_outputs",
        title = "Interceptor Artillery consequence exists but changed outputs are empty",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"non_decorative_micro", "real_pressure"},
        dossier = (function()
            local contract, line = interceptorArtilleryContract(function(c)
                local consequence = c.actionConsequences[2]
                consequence.changed = false
                consequence.changed_outputs = {}
                consequence.delta_metrics = consequence.delta_metrics or {}
                consequence.delta_metrics.changed_outputs = {}
                consequence.winning_line = nil
                consequence.red_response = nil
                consequence.false_line = nil
                consequence.exactness = nil
                consequence.outcome = nil
                consequence.legal_move_set = nil
            end)
            return interceptorArtilleryDossier("interceptor_artillery_component_consequence_empty_changed_outputs", contract, line)
        end)()
    },
    {
        id = "interceptor_artillery_pressure_not_real_or_cosmetic",
        title = "Interceptor Artillery pressure is declared but cosmetic",
        expectedOutcome = "reject",
        expectedReasons = {"cosmetic_red_pressure", "red_pressure_not_real"},
        primaryPredicates = {"real_pressure", "cosmetic_red_pressure"},
        dossier = (function()
            local contract, line = interceptorArtilleryContract()
            local predicates = interceptorArtilleryPredicates({
                predicate("cosmetic_red_pressure", true, {
                    componentId = "finisher_interceptor_clear",
                    note = "The interceptor is named but does not change Red response or false-line proof."
                }),
                predicate("real_pressure", false, {
                    componentId = "finisher_interceptor_clear",
                    note = "The finisher threat is not computably real."
                })
            })
            return interceptorArtilleryDossier("interceptor_artillery_pressure_not_real_or_cosmetic", contract, line, predicates)
        end)()
    },
    {
        id = "interceptor_artillery_pressure_free_to_remove",
        title = "Interceptor Artillery pressure can be removed for free on opening",
        expectedOutcome = "reject",
        expectedReasons = {"composite_pressure_free_to_remove"},
        primaryPredicates = {"critical_blue_unit", "real_pressure"},
        dossier = (function()
            local contract, line = interceptorArtilleryContract()
            local predicates = interceptorArtilleryPredicates(nil, {
                redPressureUnit = "red_interceptor",
                finisherInterceptorUnit = "red_interceptor",
                pressureCanBeAttackedAtStart = true
            })
            return interceptorArtilleryDossier("interceptor_artillery_pressure_free_to_remove", contract, line, predicates)
        end)()
    },
    {
        id = "interceptor_artillery_interceptor_decorative",
        title = "Interceptor Artillery threat is decorative",
        expectedOutcome = "reject",
        expectedReasons = {"decorative_micro_interaction"},
        primaryPredicates = {"non_decorative_micro", "prevents_micro_interaction"},
        dossier = (function()
            local contract, line = interceptorArtilleryContract()
            local predicates = interceptorArtilleryPredicates({
                predicate("non_decorative_micro", false, {
                    componentId = "finisher_interceptor_clear",
                    microId = "RED_ATTACKS_FINISHER",
                    note = "Removing the interceptor changes no Red response or proof output."
                }),
                predicate("prevents_micro_interaction", false, {
                    componentId = "finisher_interceptor_clear"
                })
            })
            return interceptorArtilleryDossier("interceptor_artillery_interceptor_decorative", contract, line, predicates)
        end)()
    },
    {
        id = "interceptor_artillery_finisher_final_cell_free",
        title = "Interceptor Artillery final cell is already free",
        expectedOutcome = "reject",
        expectedReasons = {"free_finisher_move"},
        primaryPredicates = {"free_finisher_move", "position_gained"},
        dossier = (function()
            local contract, line = interceptorArtilleryContract()
            local predicates = interceptorArtilleryPredicates({
                predicate("free_finisher_move", true, {
                    componentId = "exact_contact_payoff",
                    note = "Artillery can reach or use the final firing cell without earning it."
                }),
                predicate("position_gained", false, {
                    componentId = "finisher_staging_gain"
                })
            })
            return interceptorArtilleryDossier("interceptor_artillery_finisher_final_cell_free", contract, line, predicates)
        end)()
    },
    {
        id = "interceptor_artillery_scripted_policy_line_macro_template",
        title = "Interceptor Artillery embeds a scripted Red policy line",
        expectedOutcome = "reject",
        expectedReasons = {"macro_template_signature"},
        primaryPredicates = {"macro_template_signature"},
        dossier = (function()
            local contract, line = interceptorArtilleryContract(function(c)
                c.scriptedRedResponses = {
                    { turn = 1, action = { type = "attack", actorId = "red_interceptor", targetId = "blue_finisher" } }
                }
            end)
            local predicates = interceptorArtilleryPredicates({
                predicate("macro_template_signature", true, {
                    componentId = "finisher_interceptor_clear",
                    note = "The profile declares a fixed Red reply instead of relying on the versioned Scenario Red Policy state function."
                })
            })
            return interceptorArtilleryDossier("interceptor_artillery_scripted_policy_line_macro_template", contract, line, predicates)
        end)()
    },
    {
        id = "dual_lock_component_listed_without_action_consequence",
        title = "Dual-lock profile component is listed but has no action consequence",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"required_line", "non_decorative_micro"},
        dossier = (function()
            local contract, line = dualRockLockContract(function(c)
                table.remove(c.actionConsequences, 4)
            end)
            return dualRockLockDossier("dual_lock_component_listed_without_action_consequence", contract, line)
        end)()
    },
    {
        id = "dual_lock_component_consequence_empty_changed_outputs",
        title = "Dual-lock consequence exists but changed outputs are empty",
        expectedOutcome = "reject",
        expectedReasons = {"invalid_compositional_contract"},
        primaryPredicates = {"required_line", "non_decorative_micro"},
        dossier = (function()
            local contract, line = dualRockLockContract(function(c)
                local consequence = c.actionConsequences[4]
                consequence.changed = false
                consequence.changed_outputs = {}
                consequence.delta_metrics = consequence.delta_metrics or {}
                consequence.delta_metrics.changed_outputs = {}
                consequence.winning_line = nil
                consequence.false_line = nil
                consequence.legal_move_set = nil
                consequence.exactness = nil
            end)
            return dualRockLockDossier("dual_lock_component_consequence_empty_changed_outputs", contract, line)
        end)()
    },
    {
        id = "dual_lock_upper_rock_decorative",
        title = "Dual-lock upper Rock does not affect the line",
        expectedOutcome = "reject",
        expectedReasons = {"decorative_micro_interaction"},
        primaryPredicates = {"non_decorative_micro", "prevents_micro_interaction"},
        dossier = (function()
            local contract, line = dualRockLockContract()
            local predicates = dualRockLockPredicates({
                predicate("non_decorative_micro", false, {
                    componentId = "dual_rock_lock_chain",
                    microId = "ROCK_AS_LOCK",
                    note = "The second Rock is declared but removing it changes no legal line or proof output."
                }),
                predicate("prevents_micro_interaction", false, {
                    componentId = "dual_rock_lock_chain"
                })
            })
            return dualRockLockDossier("dual_lock_upper_rock_decorative", contract, line, predicates)
        end)()
    },
    {
        id = "dual_lock_lane_already_open",
        title = "Dual-lock ranged lane is already open",
        expectedOutcome = "reject",
        expectedReasons = {"free_finisher_move", "decorative_micro_interaction"},
        primaryPredicates = {"free_finisher_move", "non_decorative_micro"},
        dossier = (function()
            local contract, line = dualRockLockContract()
            local predicates = dualRockLockPredicates({
                predicate("free_finisher_move", true, {
                    componentId = "dual_rock_lock_chain",
                    note = "The finisher line is already open without converting both Rock locks."
                }),
                predicate("non_decorative_micro", false, {
                    componentId = "los_open_ranged_lane",
                    microId = "LOS_OPEN_RANGED"
                })
            })
            return dualRockLockDossier("dual_lock_lane_already_open", contract, line, predicates)
        end)()
    },
    {
        id = "dual_lock_scripted_macro_template",
        title = "Dual-lock profile embeds scripted order as a macro-template",
        expectedOutcome = "reject",
        expectedReasons = {"macro_template_signature"},
        primaryPredicates = {"macro_template_signature"},
        dossier = (function()
            local contract, line = dualRockLockContract(function(c)
                c.turnScript = {
                    "move support to lower key",
                    "clear lower Rock",
                    "move support to upper key",
                    "clear upper Rock"
                }
            end)
            local predicates = dualRockLockPredicates({
                predicate("macro_template_signature", true, {
                    componentId = "dual_rock_lock_chain",
                    note = "The profile is reduced to a scripted order rather than computable lock predicates."
                })
            })
            return dualRockLockDossier("dual_lock_scripted_macro_template", contract, line, predicates)
        end)()
    }
}

function negativeFixtures.list()
    local out = {}
    for _, fixture in ipairs(negativeFixtures.fixtures) do
        out[#out + 1] = fixture
    end
    return out
end

function negativeFixtures.getById(id)
    local needle = tostring(id or "")
    for _, fixture in ipairs(negativeFixtures.fixtures) do
        if tostring(fixture.id or "") == needle then
            return fixture
        end
    end
    return nil
end

return negativeFixtures
