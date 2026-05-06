local schemaContract = require("scenario_tooling.schema_contract")
local predicateContract = require("scenario_tooling.predicate_contract")
local compositionComposer = require("scenario_tooling.composition_composer")

local validationGate = {}

validationGate.VERSION = "scenario_validation_gate.v0.1.0-step-minus-2"

validationGate.DECISIONS = {
    include = true,
    exclude = true,
    unknown = true,
    fallback_all_legal = true
}

validationGate.HARD_REJECTION_PREDICATES = {
    static_damage_clock = {
        rejectWhen = true,
        reason = "static_damage_clock"
    },
    multi_unit_damage_clock = {
        rejectWhen = true,
        reason = "multi_unit_damage_clock"
    },
    free_finisher_move = {
        rejectWhen = true,
        reason = "free_finisher_move"
    },
    support_already_free = {
        rejectWhen = true,
        reason = "support_already_free"
    },
    cosmetic_red_pressure = {
        rejectWhen = true,
        reason = "cosmetic_red_pressure"
    },
    macro_template_signature = {
        rejectWhen = true,
        reason = "macro_template_signature"
    },
    fingerprint_distinct = {
        rejectWhen = false,
        reason = "fingerprint_not_distinct"
    },
    non_decorative_micro = {
        rejectWhen = false,
        reason = "decorative_micro_interaction"
    },
    real_pressure = {
        rejectWhen = false,
        reason = "red_pressure_not_real"
    }
}

local function append(list, value)
    list[#list + 1] = value
end

local function cloneList(source)
    local out = {}
    for _, value in ipairs(source or {}) do
        out[#out + 1] = value
    end
    return out
end

local function stableString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function asList(value)
    if type(value) ~= "table" then
        return {}
    end
    return value
end

local function normalizeBool(value)
    if value == true or value == "true" then
        return true
    end
    if value == false or value == "false" then
        return false
    end
    return nil
end

local function resultIsUnknown(result)
    if type(result) ~= "table" then
        return true
    end
    local status = tostring(result.status or result.result or "")
    return status == "unknown" or status == "uncomputed" or status == ""
end

local function resultBool(result)
    if type(result) ~= "table" then
        return nil
    end
    local explicit = normalizeBool(result.value)
    if explicit ~= nil then
        return explicit
    end
    return normalizeBool(result.status or result.result)
end

local function indexPredicateResults(dossier)
    local byName = {}
    for _, result in ipairs(asList(dossier and dossier.predicateResults)) do
        local name = tostring(result.predicate or result.name or "")
        if name ~= "" then
            byName[name] = byName[name] or {}
            append(byName[name], result)
        end
    end
    return byName
end

local function addReason(reasons, code, message, predicate, evidence)
    append(reasons, {
        code = code,
        message = message or code,
        predicate = predicate,
        evidence = evidence
    })
end

local function hasReasonCode(reasons, code)
    for _, reason in ipairs(reasons or {}) do
        if tostring(reason.code or "") == tostring(code or "") then
            return true
        end
    end
    return false
end

local function getCriticalBlueEvidence(dossier)
    for _, result in ipairs(asList(dossier and dossier.predicateResults)) do
        local name = tostring(result.predicate or result.name or "")
        if name == "critical_blue_unit" then
            local evidence = result.evidence or {}
            if type(evidence.evidence) == "table" then
                return evidence.evidence
            end
            return evidence
        end
    end
    return {}
end

local function compositionalContractRequired(dossier)
    if type(dossier) ~= "table" then
        return false
    end
    local pattern = stableString(dossier.contractPattern)
    return pattern == "composite_support_pressure_crusher_contact"
        or pattern == "crusher_contact_breach"
        or pattern == "support_reposition_rock_los_finish"
        or pattern == "support_under_real_red_pressure"
        or pattern == "support_intercepts_finisher_threat_artillery_finish"
        or pattern == "dual_rock_lock_ranged_finish"
        or type(dossier.compositionalContract) == "table"
end

local function collectCompositionalEvidence(dossier, reasons)
    if not compositionalContractRequired(dossier) then
        return
    end

    local contract = dossier.compositionalContract
    if type(contract) ~= "table" then
        addReason(
            reasons,
            "missing_compositional_contract",
            "Composite scenario claims require a computable compositional contract.",
            "required_line",
            { contractPattern = dossier.contractPattern }
        )
    else
        local ok, report = compositionComposer.validateContract(contract)
        if ok ~= true then
            addReason(
                reasons,
                "invalid_compositional_contract",
                "Composite scenario contract failed action-consequence validation.",
                "required_line",
                report
            )
        end
    end

    local evidence = getCriticalBlueEvidence(dossier)
    local pressureUnit = stableString(evidence.redPressureUnit)
    local blockerUnit = stableString(evidence.contactBlockerUnit)
    if pressureUnit ~= "" and blockerUnit ~= "" and (pressureUnit == blockerUnit or evidence.contactBlockerAlsoPressure == true) then
        addReason(
            reasons,
            "composite_pressure_blocker_same_unit",
            "Composite pressure and blocker roles must be separate units.",
            "critical_blue_unit",
            evidence
        )
    end

    if evidence.pressureCanBeAttackedAtStart == true then
        addReason(
            reasons,
            "composite_pressure_free_to_remove",
            "Composite pressure cannot be immediately removable on the opening setup.",
            "critical_blue_unit",
            evidence
        )
    end

    local firstAction = dossier.solution and dossier.solution.actions and dossier.solution.actions[1] or nil
    if type(firstAction) == "table" and firstAction.type == "attack" then
        local targetId = stableString(firstAction.targetId)
        if targetId ~= "" and (targetId == pressureUnit or targetId == blockerUnit) then
            addReason(
                reasons,
                "composite_too_obvious_first_move",
                "Composite first move cannot simply remove the pressure or blocker role.",
                "required_line",
                {
                    firstAction = firstAction,
                    pressureUnit = pressureUnit,
                    blockerUnit = blockerUnit
                }
            )
        end
    end
end

local function validateRequiredContracts(errors)
    local schemaOk, schemaErrors = schemaContract.validateFreeze()
    if not schemaOk then
        for _, err in ipairs(schemaErrors or {}) do
            append(errors, "schema_contract:" .. tostring(err))
        end
    end

    local predicateOk, predicateErrors = predicateContract.validateFreeze()
    if not predicateOk then
        for _, err in ipairs(predicateErrors or {}) do
            append(errors, "predicate_contract:" .. tostring(err))
        end
    end
end

function validationGate.validateStepMinus2Freeze()
    local errors = {}
    validateRequiredContracts(errors)
    return #errors == 0, errors
end

function validationGate.getPredicateResults(dossier, predicateName)
    local byName = indexPredicateResults(dossier)
    return cloneList(byName[tostring(predicateName or "")] or {})
end

function validationGate.validateDefensiveDomainDecisions(dossier)
    local reasons = {}
    local sawDecision = false

    for _, decision in ipairs(asList(dossier and dossier.defensiveDomainDecisions)) do
        sawDecision = true
        local value = tostring(decision.decision or "")
        if not validationGate.DECISIONS[value] then
            addReason(
                reasons,
                "invalid_defensive_domain_decision",
                "Every Red move must receive a versioned include/exclude/unknown/fallback decision.",
                "defensive_domain_inclusion",
                decision
            )
        end

        if type(decision.reasonCodes) ~= "table" or #decision.reasonCodes == 0 then
            addReason(
                reasons,
                "missing_defensive_domain_reason",
                "Defensive domain decisions require reason codes.",
                "defensive_domain_inclusion",
                decision
            )
        end

        if type(decision.predicateResults) ~= "table" or #decision.predicateResults == 0 then
            addReason(
                reasons,
                "missing_defensive_domain_predicate_evidence",
                "Defensive domain decisions require predicate evidence.",
                "defensive_domain_inclusion",
                decision
            )
        end

        if type(decision.predicateInputs) ~= "table" then
            addReason(
                reasons,
                "missing_defensive_domain_predicate_inputs",
                "Defensive domain decisions require predicate inputs.",
                "defensive_domain_inclusion",
                decision
            )
        end

        if decision.policyScoreBand == nil then
            addReason(
                reasons,
                "missing_defensive_domain_policy_score_band",
                "Defensive domain decisions require a policy score band, even when uncomputed.",
                "defensive_domain_inclusion",
                decision
            )
        end

        if decision.equivalenceReason == nil then
            addReason(
                reasons,
                "missing_defensive_domain_equivalence_reason",
                "Defensive domain decisions require an equivalence reason.",
                "defensive_domain_inclusion",
                decision
            )
        end

        if value == "unknown" then
            addReason(
                reasons,
                "unknown_defensive_domain_move",
                "Unknown Red defenses block certification until all-legal proof or stronger evidence is available.",
                "defensive_domain_inclusion",
                decision
            )
        end
    end

    if dossier and dossier.defensiveProofUsed == true and not sawDecision then
        addReason(
            reasons,
            "missing_defensive_domain_decisions",
            "Defensive proof requires a decision record for every legal Red move.",
            "defensive_domain_inclusion",
            nil
        )
    end

    return #reasons == 0, reasons
end

function validationGate.evaluateDossier(dossier)
    local freezeErrors = {}
    validateRequiredContracts(freezeErrors)
    if #freezeErrors > 0 then
        return {
            status = "unknown",
            reasons = freezeErrors
        }
    end

    local reasons = {}
    local unknowns = {}
    local byName = indexPredicateResults(dossier or {})

    if type(dossier) ~= "table" then
        addReason(reasons, "invalid_generation_dossier", "GenerationDossier is required.", nil, nil)
        return {
            status = "reject",
            reasons = reasons,
            unknowns = unknowns
        }
    end

    for predicateName, rule in pairs(validationGate.HARD_REJECTION_PREDICATES) do
        local results = byName[predicateName] or {}
        if #results == 0 then
            addReason(
                unknowns,
                "predicate_uncomputed",
                "Predicate evidence is unavailable and cannot support approval.",
                predicateName,
                nil
            )
        else
            for _, result in ipairs(results) do
                if resultIsUnknown(result) then
                    addReason(
                        unknowns,
                        "predicate_unknown",
                        "Unknown predicate evidence blocks approval.",
                        predicateName,
                        result
                    )
                elseif resultBool(result) == rule.rejectWhen then
                    addReason(reasons, rule.reason, rule.reason, predicateName, result.evidence or result)
                end
            end
        end
    end

    local defensiveOk, defensiveReasons = validationGate.validateDefensiveDomainDecisions(dossier)
    if not defensiveOk then
        for _, reason in ipairs(defensiveReasons) do
            append(unknowns, reason)
        end
    end

    collectCompositionalEvidence(dossier, reasons)

    if #reasons > 0 then
        return {
            status = "reject",
            reasons = reasons,
            unknowns = unknowns
        }
    end

    if #unknowns > 0 then
        return {
            status = "unknown",
            reasons = {},
            unknowns = unknowns
        }
    end

    return {
        status = "step_minus_2_gate_pass",
        reasons = {},
        unknowns = {}
    }
end

function validationGate.evaluateNegativeFixture(fixture)
    local dossier = fixture and fixture.dossier or nil
    local outcome = validationGate.evaluateDossier(dossier)
    local expected = tostring(fixture and fixture.expectedOutcome or "reject")
    local ok = outcome.status == expected

    if ok and type(fixture.expectedReasons) == "table" then
        for _, expectedReason in ipairs(fixture.expectedReasons) do
            if not hasReasonCode(outcome.reasons, expectedReason)
                and not hasReasonCode(outcome.unknowns, expectedReason) then
                ok = false
                append(outcome.unknowns, {
                    code = "missing_expected_fixture_reason",
                    message = tostring(expectedReason),
                    predicate = nil
                })
            end
        end
    end

    return ok, outcome
end

return validationGate
