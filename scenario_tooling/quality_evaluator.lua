local validationGate = require("scenario_tooling.validation_gate")
local scenarioValidator = require("scenario_tooling.scenario_contract_validator")
local stateEngine = require("scenario_tooling.state_engine")
local solver = require("scenario_tooling.solver")
local redPolicyHarness = require("scenario_tooling.red_policy_harness")
local microLibrary = require("scenario_tooling.micro_interaction_library")
local predicateContract = require("scenario_tooling.predicate_contract")
local negativeFixtures = require("scenario_tooling.negative_fixtures")
local compositionComposer = require("scenario_tooling.composition_composer")

local M = {
    VERSION = "scenario_quality_evaluator.v1.step9",
    EVALUATOR_ID = "step9_quality_evaluator_v1",
    EVALUATOR_HASH = "quality_evaluator_v1_2026_05_03"
}

local BLUE = 1
local RED = 2
local APPROVAL_THRESHOLD = 0.72
local MAX_WINNING_FIRST_MOVES = 2

local HARD_BAD_PREDICATES = {
    static_damage_clock = { rejectWhen = true, reason = "static_damage_clock" },
    multi_unit_damage_clock = { rejectWhen = true, reason = "multi_unit_damage_clock" },
    free_finisher_move = { rejectWhen = true, reason = "free_finisher_move" },
    support_already_free = { rejectWhen = true, reason = "support_already_free" },
    cosmetic_red_pressure = { rejectWhen = true, reason = "cosmetic_red_pressure" },
    macro_template_signature = { rejectWhen = true, reason = "macro_template_signature" },
    fingerprint_distinct = { rejectWhen = false, reason = "fingerprint_not_distinct" },
    non_decorative_micro = { rejectWhen = false, reason = "decorative_micro_interaction" },
    real_pressure = { rejectWhen = false, reason = "red_pressure_not_real" }
}

local REQUIRED_APPROVAL_PREDICATES = {
    "static_damage_clock",
    "multi_unit_damage_clock",
    "free_finisher_move",
    "support_already_free",
    "cosmetic_red_pressure",
    "macro_template_signature",
    "fingerprint_distinct",
    "non_decorative_micro",
    "real_pressure"
}

local function stableString(value)
    if value == nil then
        return ""
    end
    if type(value) == "number" then
        return string.format("%.12g", value)
    end
    return tostring(value)
end

local function hashText(text)
    local hash = 5381
    local i
    for i = 1, #text do
        hash = ((hash * 33) + string.byte(text, i)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function reason(code, category, message, evidence)
    return {
        code = code,
        category = category or "quality",
        message = message or code,
        evidence = evidence
    }
end

local function append(list, item)
    list[#list + 1] = item
end

local function addReasonOnce(list, code, category, message, evidence)
    local i
    for i = 1, #list do
        if list[i].code == code then
            return
        end
    end
    append(list, reason(code, category, message, evidence))
end

local function boolValue(result)
    if type(result) ~= "table" then
        return nil
    end
    if result.value == true or result.value == false then
        return result.value
    end
    local status = tostring(result.status or result.result or "")
    if status == "true" then
        return true
    end
    if status == "false" then
        return false
    end
    return nil
end

local function indexPredicates(dossier)
    local byName = {}
    for _, result in ipairs(dossier and dossier.predicateResults or {}) do
        local name = tostring(result.predicate or result.name or "")
        if name ~= "" then
            byName[name] = byName[name] or {}
            byName[name][#byName[name] + 1] = result
        end
    end
    return byName
end

local function hasNonEmptyTable(value)
    return type(value) == "table" and next(value) ~= nil
end

local function hasProofCertificate(dossier)
    return hasNonEmptyTable(dossier and dossier.proofCertificate)
end

local function getMicroId(entry)
    if type(entry) == "string" then
        return entry
    end
    if type(entry) == "table" then
        return entry.id or entry.microId
    end
    return nil
end

local function actionMatches(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.id and b.id and a.id == b.id then
        return true
    end
    if a.type ~= b.type or stableString(a.actorId) ~= stableString(b.actorId) then
        return false
    end
    if a.type == "move" then
        local at = a.to or {}
        local bt = b.to or {}
        return tonumber(at.row) == tonumber(bt.row) and tonumber(at.col) == tonumber(bt.col)
    end
    if a.type == "attack" then
        return stableString(a.targetId) == stableString(b.targetId)
    end
    return a.type == "end_turn"
end

local function actionSignature(action)
    local to = type(action) == "table" and action.to or {}
    return table.concat({
        stableString(action and action.type),
        stableString(action and action.actorId),
        stableString(action and action.targetId),
        stableString(to and to.row),
        stableString(to and to.col)
    }, ":")
end

local function collectPredicateEvidence(dossier, reasons, unknowns, allowDirectEvidence)
    local byName = indexPredicates(dossier)
    local predicateEvidence = {}

    for name, rule in pairs(HARD_BAD_PREDICATES) do
        local entries = byName[name] or {}
        predicateEvidence[name] = entries
        if #entries == 0 then
            if not allowDirectEvidence then
                addReasonOnce(unknowns, "predicate_uncomputed:" .. name, "predicate", "Predicate evidence is missing.", { predicate = name })
            end
        else
            local i
            for i = 1, #entries do
                local value = boolValue(entries[i])
                if value == nil then
                    addReasonOnce(unknowns, "predicate_unknown:" .. name, "predicate", "Predicate evidence is unknown.", entries[i])
                elseif value == rule.rejectWhen then
                    addReasonOnce(reasons, rule.reason, "predicate", rule.reason, entries[i])
                end
            end
        end
    end

    return predicateEvidence
end

local function falseLineCount(dossier)
    local count = 0
    for _, falseLine in ipairs(dossier and dossier.falseLines or {}) do
        local proof = falseLine.proof or falseLine.evidence or {}
        if falseLine.verified == true or proof.status == "false_line_proven" or falseLine.result == "false_line_proven" then
            count = count + 1
        end
    end
    return count
end

local ACTION_CONSEQUENCE_OUTPUTS = {
    winning_line = true,
    red_response = true,
    false_line = true,
    exactness = true,
    outcome = true
}

local function getCompositionalContract(dossier)
    if type(dossier) ~= "table" then
        return nil
    end
    return dossier.compositionalContract
        or dossier.compositionalEvidence
        or dossier.compositeContract
        or dossier.compositeEvidence
end

local function getCriticalBlueEvidence(dossier)
    for _, result in ipairs(dossier and dossier.predicateResults or {}) do
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

local function actionConsequenceHasChangedOutput(entry)
    if type(entry) ~= "table" then
        return false
    end
    local key
    for key in pairs(ACTION_CONSEQUENCE_OUTPUTS) do
        if entry[key] == true then
            return true
        end
    end
    local outputs = entry.changed_outputs
        or (entry.delta_metrics and entry.delta_metrics.changed_outputs)
        or {}
    for _, value in ipairs(outputs) do
        if ACTION_CONSEQUENCE_OUTPUTS[tostring(value)] then
            return true
        end
    end
    return false
end

local function actionConsequenceStats(dossier)
    local contract = getCompositionalContract(dossier)
    local consequences = type(contract) == "table" and (
        contract.actionConsequences
        or contract.action_consequences
        or contract.consequences
        or contract.evidence
    ) or nil
    local total = 0
    local proven = 0
    for _, consequence in ipairs(consequences or {}) do
        total = total + 1
        local hasMicro = consequence.microInteractionId ~= nil
            or consequence.microInteraction ~= nil
            or consequence.subject_id ~= nil
        local status = tostring(consequence.status or "")
        local statusProven = consequence.proven == true
            or status == "proven"
            or status == "verified"
            or status == "true"
        local hasAction = consequence.actionIndex ~= nil
            or consequence.action_index ~= nil
            or consequence.actionSignature ~= nil
            or consequence.action_signature ~= nil
        if hasMicro and hasAction and statusProven and consequence.changed == true and actionConsequenceHasChangedOutput(consequence) then
            proven = proven + 1
        end
    end
    local contractOk = nil
    local contractReport = nil
    if type(contract) == "table" then
        contractOk, contractReport = compositionComposer.validateContract(contract)
    end
    return {
        hasContract = type(contract) == "table",
        count = total,
        proven = proven,
        contractOk = contractOk,
        contractReport = contractReport
    }
end

local function countDistinctActors(actions)
    local actors = {}
    for _, action in ipairs(actions or {}) do
        if action.actorId ~= nil then
            actors[stableString(action.actorId)] = true
        end
    end
    local count = 0
    for _ in pairs(actors) do
        count = count + 1
    end
    return count
end

local function unitId(unit, fallback)
    return stableString(unit and (unit.id or unit.scenarioUnitId or fallback))
end

local function liveBlueUnitIds(dossier)
    local ids = {}
    local units = dossier and dossier.scenarioState and dossier.scenarioState.units or {}
    for index, unit in ipairs(units) do
        if type(unit) == "table"
            and tonumber(unit.player) == BLUE
            and (tonumber(unit.currentHp) or tonumber(unit.hp) or 0) > 0 then
            local id = unitId(unit, index)
            if id ~= "" then
                ids[id] = true
            end
        end
    end
    return ids
end

local function declaredFinisherId(dossier)
    local evidence = getCriticalBlueEvidence(dossier)
    local finisher = evidence.finisher
        or evidence.finisherId
        or evidence.criticalFinisher
        or (dossier and dossier.finisher and dossier.finisher.unitId)
        or "blue_finisher"
    return stableString(finisher)
end

local function blueCoordinationStats(actions, finisherId, blueActorIds)
    local supportActions = 0
    local finisherActions = 0
    local supportActors = {}
    local firstBlueAction = nil
    local supportAttackBeforePayoff = false
    local finisherPayoff = false

    for _, action in ipairs(actions or {}) do
        if type(action) == "table" then
            local actor = stableString(action.actorId)
            local isBlueActor = blueActorIds[actor] == true
            if isBlueActor and actor ~= finisherId then
                supportActions = supportActions + 1
                supportActors[actor] = true
                firstBlueAction = firstBlueAction or action
                if action.type == "attack" and not finisherPayoff then
                    supportAttackBeforePayoff = true
                end
            elseif isBlueActor and actor == finisherId then
                finisherActions = finisherActions + 1
                firstBlueAction = firstBlueAction or action
                if action.type == "attack" and action.targetId == "red_commandant" then
                    finisherPayoff = true
                end
            end
        end
    end

    local supportActorCount = 0
    for _ in pairs(supportActors) do
        supportActorCount = supportActorCount + 1
    end

    local firstBlueIsSupportSetup = type(firstBlueAction) == "table"
        and blueActorIds[stableString(firstBlueAction.actorId)] == true
        and stableString(firstBlueAction.actorId) ~= finisherId
        and firstBlueAction.type == "move"

    return {
        supportActions = supportActions,
        supportActorCount = supportActorCount,
        finisherActions = finisherActions,
        firstBlueIsSupportSetup = firstBlueIsSupportSetup,
        supportAttackBeforePayoff = supportAttackBeforePayoff,
        finisherPayoff = finisherPayoff,
        pass = supportActions >= 2
            and finisherActions >= 2
            and firstBlueIsSupportSetup
            and supportAttackBeforePayoff
            and finisherPayoff
    }
end

local function uniqueFinisherStats(dossier, actions, finisherId, blueActorIds)
    local payoffActors = {}
    local payoffActorCount = 0
    for _, action in ipairs(actions or {}) do
        if type(action) == "table"
            and action.type == "attack"
            and stableString(action.targetId) == "red_commandant"
            and blueActorIds[stableString(action.actorId)] == true then
            local actor = stableString(action.actorId)
            if payoffActors[actor] ~= true then
                payoffActors[actor] = true
                payoffActorCount = payoffActorCount + 1
            end
        end
    end

    local nonFinisherWinningActors = {}
    local nonFinisherWinningCount = 0
    local function recordNonFinisher(actor)
        if actor ~= "" and actor ~= finisherId and nonFinisherWinningActors[actor] ~= true then
            nonFinisherWinningActors[actor] = true
            nonFinisherWinningCount = nonFinisherWinningCount + 1
        end
    end

    local function scanLegalFinishers(state)
        if type(state) ~= "table" or tonumber(state.currentPlayer) ~= BLUE then
            return
        end
        for _, legal in ipairs(stateEngine.getLegalActions(state)) do
            local actor = stableString(legal.actorId)
            if legal.type == "attack"
                and stableString(legal.targetId) == "red_commandant"
                and blueActorIds[actor] == true then
                local after = stateEngine.applyAction(state, legal)
                local outcome = stateEngine.evaluateOutcome(after)
                if type(outcome) == "table" and outcome.status == "blue_win" then
                    recordNonFinisher(actor)
                end
            end
        end
    end

    if type(dossier and dossier.scenarioState) == "table" then
        local state = stateEngine.cloneState(stateEngine.normalize(dossier.scenarioState))
        scanLegalFinishers(state)
        for _, action in ipairs(actions or {}) do
            local nextState = stateEngine.applyAction(state, action)
            if type(nextState) ~= "table" then
                break
            end
            state = nextState
            scanLegalFinishers(state)
        end
    end

    return {
        declaredFinisherId = finisherId,
        payoffActorCount = payoffActorCount,
        nonFinisherWinningCommandantAttackCount = nonFinisherWinningCount,
        pass = payoffActorCount == 1
            and payoffActors[finisherId] == true
            and nonFinisherWinningCount == 0
    }
end

local function countUnits(dossier)
    local units = dossier and dossier.scenarioState and dossier.scenarioState.units or {}
    local total = 0
    local blue = 0
    local red = 0
    local rocks = 0
    for _, unit in ipairs(units) do
        if type(unit) == "table" and (tonumber(unit.currentHp) or 0) > 0 then
            total = total + 1
            if tonumber(unit.player) == 1 then
                blue = blue + 1
            elseif tonumber(unit.player) == 2 then
                red = red + 1
            elseif tostring(unit.name or "") == "Rock" or tonumber(unit.player) == 0 then
                rocks = rocks + 1
            end
        end
    end
    return total, blue, red, rocks
end

local function indexLiveUnitsById(dossier)
    local byId = {}
    local units = dossier and dossier.scenarioState and dossier.scenarioState.units or {}
    for index, unit in ipairs(units) do
        if type(unit) == "table" and (tonumber(unit.currentHp) or tonumber(unit.hp) or 0) > 0 then
            local id = unitId(unit, index)
            if id ~= "" then
                byId[id] = unit
            end
        end
    end
    return byId
end

local function firstActionAttacksActiveRed(dossier, firstAction)
    if type(firstAction) ~= "table" or firstAction.type ~= "attack" then
        return false
    end
    local target = indexLiveUnitsById(dossier)[stableString(firstAction.targetId)]
    return type(target) == "table"
        and tonumber(target.player) == RED
        and tostring(target.name or "") ~= "Commandant"
end

local function resetRedForPressureCheck(state)
    local s = stateEngine.cloneState(stateEngine.normalize(state))
    s.currentPlayer = RED
    s.turnActions = 0
    s.actionsUsed = 0
    for _, unit in ipairs(s.units or {}) do
        if tonumber(unit.player) == RED then
            unit.hasMoved = false
            unit.hasActed = false
            unit.actionsUsed = 0
            unit.turnActions = {}
        end
    end
    return stateEngine.normalize(s)
end

local function redThreatensFinisherWithinActionBudget(dossier, finisherId)
    if type(dossier and dossier.scenarioState) ~= "table" then
        return false
    end

    local redState = resetRedForPressureCheck(dossier.scenarioState)
    local legal = stateEngine.getLegalActions(redState)
    for _, action in ipairs(legal) do
        if action.type == "attack" and stableString(action.targetId) == finisherId then
            return true
        end
    end

    for _, action in ipairs(legal) do
        if action.type == "move" then
            local afterMove = stateEngine.applyAction(redState, action)
            for _, followup in ipairs(stateEngine.getLegalActions(afterMove)) do
                if followup.type == "attack"
                    and stableString(followup.actorId) == stableString(action.actorId)
                    and stableString(followup.targetId) == finisherId then
                    return true
                end
            end
        end
    end

    return false
end

local function microSet(dossier)
    local out = {}
    for _, micro in ipairs(dossier and dossier.microInteractions or {}) do
        local id = getMicroId(micro)
        if id then
            out[tostring(id)] = true
        end
    end
    return out
end

local function countWinningFirstMoves(dossier, firstAction)
    if type(dossier.scenarioState) ~= "table" then
        return 0
    end
    local legal = stateEngine.getLegalActions(dossier.scenarioState)
    local winningCount = 0

    for _, action in ipairs(legal) do
        if action.type ~= "end_turn" then
            if actionMatches(action, firstAction) then
                winningCount = winningCount + 1
            end
        end
    end
    return winningCount
end

local function fingerprintUsable(fingerprint)
    if type(fingerprint) ~= "table" then
        return false
    end
    local version = fingerprint.fingerprint_version or fingerprint.version
    local signature = fingerprint.signature or fingerprint.hash or fingerprint.fingerprint
    local hasMechanism = fingerprint.mechanism_family ~= nil
    local hasMicro = fingerprint.micro_sequence_signature ~= nil
    local hasRole = fingerprint.role_signature ~= nil
    local hasGeometry = fingerprint.geometry_signature ~= nil
    return version ~= nil and signature ~= nil and hasMechanism and hasMicro and hasRole and hasGeometry
end

local function validateMicroInteractions(dossier, reasons, unknowns)
    local micros = dossier.microInteractions or {}
    if #micros < 2 then
        addReasonOnce(reasons, "too_few_micro_interactions", "quality", "Multiple micro-interactions are required.", micros)
    end

    for _, micro in ipairs(micros) do
        local id = getMicroId(micro)
        local spec = microLibrary.getMicroInteraction(id)
        if not spec then
            addReasonOnce(unknowns, "unknown_micro_interaction:" .. stableString(id), "micro", "Declared micro-interaction is not in the library.", micro)
        elseif microLibrary.isMacroTemplate(spec) then
            addReasonOnce(reasons, "macro_template_signature", "micro", "Micro-interaction is a macro-template disguise.", id)
        end
    end
end

local function computeFeatures(dossier, opts)
    opts = type(opts) == "table" and opts or {}
    local solutionActions = dossier.solution and dossier.solution.actions or {}
    local firstAction = solutionActions[1]
    local totalUnits, blueUnits, redUnits, rockUnits = countUnits(dossier)
    local micros = microSet(dossier)
    local consequenceStats = actionConsequenceStats(dossier)
    local finisherId = declaredFinisherId(dossier)
    local blueActorIds = liveBlueUnitIds(dossier)
    local coordinationStats = blueCoordinationStats(solutionActions, finisherId, blueActorIds)
    local finisherStats = uniqueFinisherStats(dossier, solutionActions, finisherId, blueActorIds)
    local features = {
        pipelineState = dossier.pipelineState,
        hasProofCertificate = hasProofCertificate(dossier),
        solverStatus = dossier.solverProof and dossier.solverProof.status or "missing",
        solutionActionCount = #solutionActions,
        falseLineCount = falseLineCount(dossier),
        microInteractionCount = #(dossier.microInteractions or {}),
        distinctSolutionActors = countDistinctActors(solutionActions),
        totalUnitCount = totalUnits,
        blueUnitCount = blueUnits,
        redUnitCount = redUnits,
        rockUnitCount = rockUnits,
        hasStructuralMicro = micros.ROCK_AS_LOCK == true or micros.LOS_OPEN_RANGED == true or micros.SUPPORT_CELL_GAIN == true,
        hasSupportMicro = micros.SUPPORT_CELL_GAIN == true or micros.LOS_OPEN_RANGED == true,
        hasFalseTargetMicro = micros.WRONG_TARGET_TEMPO_LOSS == true,
        startsBlueToMove = dossier.scenarioState and dossier.scenarioState.currentPlayer == BLUE,
        immediateWin = false,
        winningFirstMoveCount = 0,
        fingerprintUsable = fingerprintUsable(dossier.tacticalFingerprint),
        redPolicyHarnessPass = false,
        hasCompositionalContract = consequenceStats.hasContract,
        actionConsequenceCount = consequenceStats.count,
        provenActionConsequenceCount = consequenceStats.proven,
        compositionalContractValid = consequenceStats.contractOk,
        compositionalContractReport = consequenceStats.contractReport,
        firstActionAttacksActiveRed = firstActionAttacksActiveRed(dossier, firstAction),
        redFinisherPressure = redThreatensFinisherWithinActionBudget(dossier, finisherId),
        declaredFinisherId = finisherId,
        uniqueFinisher = finisherStats.pass,
        finisherPayoffActorCount = finisherStats.payoffActorCount,
        nonFinisherWinningCommandantAttackCount = finisherStats.nonFinisherWinningCommandantAttackCount,
        blueCoordination = coordinationStats.pass,
        blueSupportActionCount = coordinationStats.supportActions,
        blueSupportActorCount = coordinationStats.supportActorCount,
        blueFinisherActionCount = coordinationStats.finisherActions,
        firstBlueIsSupportSetup = coordinationStats.firstBlueIsSupportSetup,
        supportAttackBeforePayoff = coordinationStats.supportAttackBeforePayoff,
        finisherPayoff = coordinationStats.finisherPayoff
    }

    if type(dossier.scenarioState) == "table" then
        local outcome = stateEngine.evaluateOutcome(dossier.scenarioState)
        features.immediateWin = type(outcome) == "table" and outcome.status == "blue_win"
        if firstAction and opts.skipExpensive ~= true then
            features.winningFirstMoveCount = countWinningFirstMoves(dossier, firstAction)
        end
    end

    if opts.skipExpensive == true then
        features.redPolicyHarness = {
            pass = false,
            skipped = true,
            reason = "not_certified"
        }
    else
        local harness = redPolicyHarness.evaluateDossier(dossier, {
            maxDeviationSamples = 1
        })
        features.redPolicyHarnessPass = harness.pass == true
        features.redPolicyHarness = harness
    end
    return features
end

local function scoreFeatures(features)
    local score = 0
    if features.hasProofCertificate then score = score + 0.14 end
    if features.solverStatus == "forced_win" then score = score + 0.16 end
    if features.solutionActionCount > 0 then score = score + 0.08 end
    if features.falseLineCount >= 1 then score = score + 0.14 end
    if features.microInteractionCount >= 2 then score = score + 0.12 end
    if features.solutionActionCount >= 3 and features.distinctSolutionActors >= 2 then score = score + 0.06 end
    if features.blueUnitCount >= 2 and features.totalUnitCount >= 4 and features.hasStructuralMicro then score = score + 0.06 end
    if features.fingerprintUsable then score = score + 0.10 end
    if features.redPolicyHarnessPass then score = score + 0.16 end
    if features.startsBlueToMove and not features.immediateWin then score = score + 0.05 end
    if features.winningFirstMoveCount > 0 and features.winningFirstMoveCount <= MAX_WINNING_FIRST_MOVES then score = score + 0.05 end
    return score
end

function M.isScenarioOnly()
    return true
end

function M.evaluate(dossier, opts)
    opts = type(opts) == "table" and opts or {}
    local reasons = {}
    local unknowns = {}
    local evidence = {
        evaluatorVersion = M.VERSION,
        evaluatorId = M.EVALUATOR_ID,
        evaluatorHash = M.EVALUATOR_HASH,
        predicateContractVersion = predicateContract.module and predicateContract.module.version or "unknown"
    }

    if type(dossier) ~= "table" then
        return {
            status = "reject",
            score = 0,
            threshold = APPROVAL_THRESHOLD,
            reasons = { reason("invalid_generation_dossier", "contract", "GenerationDossier is required.") },
            unknowns = {},
            features = {},
            evidence = evidence
        }
    end

    local contractOk, contractErrors = scenarioValidator.validateScenarioDossier(dossier)
    if not contractOk then
        addReasonOnce(reasons, "scenario_contract_failed", "contract", "Scenario dossier failed contract validation.", contractErrors)
    end

    local allowDirectEvidence = dossier.pipelineState == "certified"
    collectPredicateEvidence(dossier, reasons, unknowns, allowDirectEvidence)

    if dossier.pipelineState ~= "certified" then
        addReasonOnce(unknowns, "not_certified", "proof", "Only certified dossiers can be approved.", dossier.pipelineState)
    end
    if not hasProofCertificate(dossier) then
        addReasonOnce(unknowns, "missing_proof_certificate", "proof", "Approval requires a proof certificate.")
    end
    if not (dossier.solverProof and dossier.solverProof.status == "forced_win") then
        addReasonOnce(unknowns, "missing_forced_win_solver_proof", "proof", "Approval requires forced-win solver proof.", dossier.solverProof)
    end
    if not hasNonEmptyTable(dossier.mechanismSpec) then
        addReasonOnce(unknowns, "missing_mechanism_spec", "quality", "Approval requires a mechanism spec.")
    end
    if not fingerprintUsable(dossier.tacticalFingerprint) then
        addReasonOnce(reasons, "coordinate_only_or_unusable_fingerprint", "fingerprint", "Fingerprint must be canonical, versioned, and recomputable.")
    end

    validateMicroInteractions(dossier, reasons, unknowns)

    local features = computeFeatures(dossier, {
        skipExpensive = dossier.pipelineState ~= "certified"
    })
    evidence.redPolicyHarness = features.redPolicyHarness

    if features.immediateWin then
        addReasonOnce(reasons, "immediate_mate", "quality", "Scenario starts already won.")
    end
    if features.solutionActionCount == 0 then
        addReasonOnce(unknowns, "missing_solution_export", "proof", "Winning solution actions are required.")
    end
    if features.falseLineCount == 0 then
        addReasonOnce(unknowns, "missing_proven_false_line", "proof", "At least one solver-proven false line is required.")
    end
    if features.microInteractionCount < 2 then
        addReasonOnce(reasons, "decorative_micro_interaction", "quality", "Multiple compatible non-decorative micro-interactions are required.")
    end
    if not features.redPolicyHarnessPass then
        addReasonOnce(unknowns, "red_policy_harness_failed", "policy", "Scenario Red Policy credibility harness must pass.", features.redPolicyHarness)
    end
    if features.winningFirstMoveCount > MAX_WINNING_FIRST_MOVES then
        addReasonOnce(reasons, "too_many_winning_first_moves", "quality", "Too many equivalent winning first moves.", features.winningFirstMoveCount)
    end
    if features.firstActionAttacksActiveRed then
        addReasonOnce(reasons, "obvious_opening_attack", "quality", "Opening move cannot be a direct attack on an active Red unit.", features)
    end
    if features.solutionActionCount < 3 then
        addReasonOnce(reasons, "trivial_contract_solution", "quality", "Solution is too short to demonstrate a scenario contract.")
    end
    if features.distinctSolutionActors < 2 then
        addReasonOnce(reasons, "single_actor_solution", "quality", "Solution must require at least two Blue actors.")
    end
    if features.blueUnitCount < 2 then
        addReasonOnce(reasons, "too_few_blue_units", "quality", "Scenario must include at least two live Blue units.", features.blueUnitCount)
    end
    if features.totalUnitCount < 4 then
        addReasonOnce(reasons, "too_few_units", "quality", "Scenario must include enough material to express a tactical contract.", features.totalUnitCount)
    end
    if not features.hasStructuralMicro then
        addReasonOnce(reasons, "missing_structural_micro", "quality", "Approval requires a computable Rock, LOS, or support structural micro-interaction.")
    end
    if not features.hasSupportMicro then
        addReasonOnce(reasons, "missing_support_micro", "quality", "Approval requires support to participate in the enabling mechanism.")
    end
    if not features.hasFalseTargetMicro then
        addReasonOnce(reasons, "missing_false_target_micro", "quality", "Approval requires a computable false-target or equivalent false-line primitive.")
    end
    local roleSignature = dossier.tacticalFingerprint and dossier.tacticalFingerprint.role_signature or ""
    local requiresCompositionalContract = dossier.contractPattern == "composite_support_pressure_crusher_contact"
        or dossier.contractPattern == "crusher_contact_breach"
        or dossier.contractPattern == "support_reposition_rock_los_finish"
        or dossier.contractPattern == "support_under_real_red_pressure"
        or dossier.contractPattern == "support_intercepts_finisher_threat_artillery_finish"
        or dossier.contractPattern == "dual_rock_lock_ranged_finish"
        or (type(roleSignature) == "string" and roleSignature:find("composite", 1, true) ~= nil)
    if requiresCompositionalContract then
        local firstAction = dossier.solution and dossier.solution.actions and dossier.solution.actions[1] or nil
        if not features.blueCoordination then
            addReasonOnce(reasons, "missing_blue_coordination", "quality", "Composite scenarios require support and finisher coordination.", {
                supportActions = features.blueSupportActionCount,
                supportActors = features.blueSupportActorCount,
                finisherActions = features.blueFinisherActionCount,
                firstBlueIsSupportSetup = features.firstBlueIsSupportSetup,
                supportAttackBeforePayoff = features.supportAttackBeforePayoff,
                finisherPayoff = features.finisherPayoff
            })
        end
        if not features.uniqueFinisher then
            addReasonOnce(reasons, "multiple_or_missing_finisher", "quality", "Composite scenarios require exactly one computable finisher.", {
                declaredFinisherId = features.declaredFinisherId,
                finisherPayoffActorCount = features.finisherPayoffActorCount,
                nonFinisherWinningCommandantAttackCount = features.nonFinisherWinningCommandantAttackCount
            })
        end
        if not features.redFinisherPressure then
            addReasonOnce(reasons, "missing_finisher_red_pressure", "quality", "Composite scenarios require active Red pressure on the finisher.", {
                criticalUnit = features.declaredFinisherId,
                contractPattern = dossier.contractPattern
            })
        end
        if not features.hasCompositionalContract then
            addReasonOnce(reasons, "missing_compositional_contract", "quality", "Composite scenarios require explicit component/action consequence evidence.")
        elseif features.compositionalContractValid ~= true then
            addReasonOnce(reasons, "invalid_compositional_contract", "quality", "Composite scenario compositional contract failed composer validation.", features.compositionalContractReport)
        elseif features.provenActionConsequenceCount < 4 then
            addReasonOnce(reasons, "insufficient_action_consequence_proof", "quality", "Composite scenarios require proven consequence evidence for key actions.", {
                count = features.actionConsequenceCount,
                proven = features.provenActionConsequenceCount
            })
        end
        local compositeEvidence = getCriticalBlueEvidence(dossier)
        local pressureUnit = stableString(compositeEvidence.redPressureUnit)
        local blockerUnit = stableString(compositeEvidence.contactBlockerUnit)
        if pressureUnit ~= "" and blockerUnit ~= "" and (pressureUnit == blockerUnit or compositeEvidence.contactBlockerAlsoPressure == true) then
            addReasonOnce(reasons, "composite_pressure_blocker_same_unit", "quality", "Composite pressure and blocker roles must be separate units.", compositeEvidence)
        end
        if compositeEvidence.pressureCanBeAttackedAtStart == true then
            addReasonOnce(reasons, "composite_pressure_free_to_remove", "quality", "Composite pressure cannot be free to remove on the opening setup.", compositeEvidence)
        end
        if type(firstAction) == "table" and firstAction.type == "attack" then
            local targetId = stableString(firstAction.targetId)
            if targetId ~= "" and (targetId == pressureUnit or targetId == blockerUnit) then
                addReasonOnce(reasons, "composite_too_obvious_first_move", "quality", "Composite first move cannot be an obvious attack on pressure or blocker.", {
                    firstAction = firstAction,
                    pressureUnit = pressureUnit,
                    blockerUnit = blockerUnit
                })
            end
        end
    end

    local gate = validationGate.evaluateDossier(dossier)
    evidence.stepMinus2Gate = gate
    for _, gateReason in ipairs(gate.reasons or {}) do
        addReasonOnce(reasons, gateReason.code or stableString(gateReason), "predicate", gateReason.message or gateReason.code, gateReason)
    end
    for _, gateUnknown in ipairs(gate.unknowns or {}) do
        addReasonOnce(unknowns, gateUnknown.code or stableString(gateUnknown), "predicate", gateUnknown.message or gateUnknown.code, gateUnknown)
    end

    local score = scoreFeatures(features)
    local status
    if #reasons > 0 then
        status = "reject"
    elseif #unknowns > 0 then
        status = "unknown"
    elseif score >= APPROVAL_THRESHOLD then
        status = "approved"
    else
        status = "reject"
        addReasonOnce(reasons, "quality_score_below_threshold", "quality", "Quality score is below approval threshold.", {
            score = score,
            threshold = APPROVAL_THRESHOLD
        })
    end

    if status == "approved" and (not hasProofCertificate(dossier) or dossier.pipelineState ~= "certified") then
        status = "unknown"
        addReasonOnce(unknowns, "approval_guard_missing_certificate", "proof", "Evaluator guard blocked approval without certificate.")
    end

    return {
        status = status,
        score = score,
        threshold = APPROVAL_THRESHOLD,
        reasons = reasons,
        unknowns = unknowns,
        features = features,
        evidence = evidence
    }
end

function M.evaluateFixture(fixture, opts)
    local result = M.evaluate(fixture and fixture.dossier or nil, opts)
    result.fixtureId = fixture and fixture.id or nil
    result.expectedOutcome = fixture and fixture.expectedOutcome or nil
    return result
end

function M.evaluateFixtures(opts)
    local reports = {}
    for _, fixture in ipairs(negativeFixtures.list()) do
        reports[#reports + 1] = M.evaluateFixture(fixture, opts)
    end
    return reports
end

function M.buildControlledGoodFixture(opts)
    local ok, retroGenerator = pcall(require, "scenario_tooling.retro_generator")
    if not ok or type(retroGenerator.generate) ~= "function" then
        return nil, "retro_generator_unavailable"
    end
    return retroGenerator.generate(opts or { seed = 1, turnLimit = 3 })
end

M.EVALUATOR_HASH = hashText(table.concat({
    M.VERSION,
    M.EVALUATOR_ID,
    validationGate.VERSION or "",
    scenarioValidator.VERSION or "",
    stateEngine.VERSION or "",
    solver.VERSION or "",
    redPolicyHarness.VERSION or "",
    microLibrary.VERSION or ""
}, "|"))

return M
