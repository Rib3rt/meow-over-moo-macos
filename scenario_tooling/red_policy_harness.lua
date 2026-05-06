local stateEngine = require("scenario_tooling.state_engine")
local redPolicy = require("scenario_tooling.red_policy")

local okSolver, solver = pcall(require, "scenario_tooling.solver")
if not okSolver then
    solver = nil
end

local M = {
    VERSION = "scenario_red_policy_harness.v1.step8",
    HARNESS_ID = "step8_red_policy_credibility_harness_v1",
    HARNESS_HASH = "red_policy_harness_v1_2026_05_03"
}

local BLUE = 1
local RED = 2
local DEFAULT_ADVANCE_PLIES = 4
local DEFAULT_PROOF_DOMAIN = "all_legal"

local function stableString(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.12g", v)
    end
    return tostring(v)
end

local function toNumber(v, defaultValue)
    local n = tonumber(v)
    if n == nil then
        return defaultValue
    end
    return n
end

local function shallowCopyArray(arr)
    local out = {}
    if type(arr) ~= "table" then
        return out
    end
    local i
    for i = 1, #arr do
        out[i] = arr[i]
    end
    return out
end

local function canonicalAction(action)
    if type(action) ~= "table" then
        return {}
    end
    local out = {
        type = action.type,
        actorId = action.actorId,
        targetId = action.targetId,
        id = action.id
    }
    if type(action.from) == "table" then
        out.from = {
            row = tonumber(action.from.row),
            col = tonumber(action.from.col)
        }
    end
    if type(action.to) == "table" then
        out.to = {
            row = tonumber(action.to.row),
            col = tonumber(action.to.col)
        }
    end
    if type(action.targetCell) == "table" then
        out.targetCell = {
            row = tonumber(action.targetCell.row),
            col = tonumber(action.targetCell.col)
        }
    end
    return out
end

local function actionSortKey(action)
    local t = stableString(action and action.type or "")
    local actor = stableString(action and action.actorId or "")
    local target = stableString(action and action.targetId or "")
    local to = (action and action.to) or {}
    local targetCell = (action and action.targetCell) or {}
    local row = stableString(to.row or targetCell.row or "")
    local col = stableString(to.col or targetCell.col or "")
    local id = stableString(action and action.id or "")
    return table.concat({ t, actor, target, row, col, id }, "|")
end

local function deterministicSortActions(actions)
    table.sort(actions, function(a, b)
        return actionSortKey(a) < actionSortKey(b)
    end)
end

local function actionMatches(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.id and b.id and a.id == b.id then
        return true
    end
    if a.type ~= b.type then
        return false
    end
    if a.type == "move" then
        local ato = a.to or {}
        local bto = b.to or {}
        return stableString(a.actorId) == stableString(b.actorId)
            and toNumber(ato.row, -999) == toNumber(bto.row, -998)
            and toNumber(ato.col, -999) == toNumber(bto.col, -998)
    end
    if a.type == "attack" then
        return stableString(a.actorId) == stableString(b.actorId)
            and stableString(a.targetId) == stableString(b.targetId)
    end
    return a.type == "end_turn"
end

local function actionMatchesSpec(action, spec)
    if type(action) ~= "table" then
        return false
    end
    if type(spec) == "string" then
        return stableString(action.id) == spec
    end
    if type(spec) ~= "table" then
        return false
    end
    return actionMatches(action, spec)
end

local function isExpectedAction(action, expected)
    if expected == nil then
        return true
    end
    if type(expected) == "table" and expected.id ~= nil then
        return actionMatchesSpec(action, expected)
    end
    if type(expected) == "table" and expected.type ~= nil then
        return actionMatchesSpec(action, expected)
    end
    if type(expected) == "table" then
        local i
        for i = 1, #expected do
            if actionMatchesSpec(action, expected[i]) then
                return true
            end
        end
        return false
    end
    return actionMatchesSpec(action, expected)
end

local function resolveExpectedActions(context, stateHash)
    if type(context) ~= "table" then
        return nil
    end
    if context.expectedAction ~= nil then
        return context.expectedAction
    end
    local expectedPolicyActions = context.expectedPolicyActions
    if type(expectedPolicyActions) ~= "table" then
        return nil
    end
    if stateHash and expectedPolicyActions[stateHash] ~= nil then
        return expectedPolicyActions[stateHash]
    end
    return expectedPolicyActions
end

local function findLegalMatch(legalActions, action)
    local i
    for i = 1, #(legalActions or {}) do
        if actionMatches(legalActions[i], action) then
            return legalActions[i], i
        end
    end
    return nil, nil
end

local function selectAdvanceAction(state)
    local legal = shallowCopyArray(stateEngine.getLegalActions(state))
    deterministicSortActions(legal)
    local i
    for i = 1, #legal do
        if legal[i].type == "end_turn" then
            return legal[i], legal
        end
    end
    return legal[1], legal
end

local function advanceToRed(state, maxPlies)
    local cursor = stateEngine.normalize(state)
    local limit = toNumber(maxPlies, DEFAULT_ADVANCE_PLIES)
    local trace = {}
    local i
    for i = 1, limit do
        if cursor.currentPlayer == RED then
            break
        end
        local chosen, legal = selectAdvanceAction(cursor)
        if chosen == nil then
            return cursor, trace, {
                ok = false,
                reason = "no_legal_actions_to_advance",
                legalCount = #(legal or {})
            }
        end
        cursor = stateEngine.applyAction(cursor, chosen)
        trace[#trace + 1] = canonicalAction(chosen)
    end
    if cursor.currentPlayer ~= RED then
        return cursor, trace, {
            ok = false,
            reason = "unable_to_reach_red_turn_within_limit",
            limit = limit
        }
    end
    return cursor, trace, { ok = true }
end

local function findRedCommandantId(state)
    local i
    for i = 1, #(state.units or {}) do
        local u = state.units[i]
        if toNumber(u.player, 0) == RED and u.name == "Commandant" and toNumber(u.currentHp, 0) > 0 then
            return u.id
        end
    end
    return nil
end

local function deriveCriticalBlueUnitIds(state, context)
    local set = {}
    local list = {}
    local ctxList = type(context) == "table" and context.criticalBlueUnitIds or nil
    local i
    if type(ctxList) == "table" then
        for i = 1, #ctxList do
            local id = stableString(ctxList[i])
            if id ~= "" and not set[id] then
                set[id] = true
                list[#list + 1] = id
            end
        end
    end
    if #list > 0 then
        return list, set
    end

    local commandantId = findRedCommandantId(state)
    if commandantId ~= nil then
        local blueProbe = stateEngine.cloneState(state)
        blueProbe.currentPlayer = BLUE
        local legal = stateEngine.getLegalActions(blueProbe)
        for i = 1, #legal do
            local a = legal[i]
            if a.type == "attack" and stableString(a.targetId) == stableString(commandantId) then
                local actor = stableString(a.actorId)
                if actor ~= "" and not set[actor] then
                    set[actor] = true
                    list[#list + 1] = actor
                end
            end
        end
    end

    if #list == 0 then
        for i = 1, #(state.units or {}) do
            local u = state.units[i]
            if toNumber(u.player, 0) == BLUE and toNumber(u.currentHp, 0) > 0 then
                local id = stableString(u.id)
                if id ~= "" and not set[id] then
                    set[id] = true
                    list[#list + 1] = id
                end
            end
        end
    end
    return list, set
end

local function hasMeaningfulAlternative(state, legalActions, policyOpts)
    local i
    for i = 1, #legalActions do
        local a = legalActions[i]
        local score = redPolicy.scoreAction(state, a, policyOpts)
        local meaningful = score and score.features and score.features.hasMeaningfulImpact == true
        if a.type ~= "end_turn" and meaningful then
            return true
        end
    end
    return false
end

local function proofRerun(state, selectedAction, selectedIsLegal, context)
    local rerun = {
        required = true,
        status = "unavailable",
        reason = "solver_unavailable"
    }
    if not solver or type(solver.solve) ~= "function" then
        return rerun
    end
    local base = stateEngine.normalize(state)
    local rerunState = base
    if selectedIsLegal and base.currentPlayer == RED and type(selectedAction) == "table" then
        rerunState = stateEngine.applyAction(base, selectedAction)
    end
    local domain = context and context.proofDomain or nil
    if domain ~= "defensive" and domain ~= "all_legal" then
        domain = DEFAULT_PROOF_DOMAIN
    end
    local solveProof = solver.solve(rerunState, {
        seed = context and context.seed or nil,
        proofDomain = domain
    })
    rerun.status = solveProof and solveProof.status or "unknown"
    rerun.reason = "rerun_complete"
    rerun.proofDomain = domain
    rerun.fromStateHash = stateEngine.stateHash(rerunState)
    rerun.searchResult = solveProof and solveProof.status or "unknown"
    return rerun
end

local function chooseDeterministic(state, context)
    local seed = context and context.seed or nil
    local actionA, recA = redPolicy.chooseAction(state, { seed = seed })
    local actionB, recB = redPolicy.chooseAction(state, { seed = seed })
    local deterministic = actionMatches(actionA, actionB)
    return actionA, recA, deterministic, actionB, recB
end

function M.isScenarioOnly()
    return true
end

function M.checkCriticalState(state, context)
    context = type(context) == "table" and context or {}
    local normalized = stateEngine.normalize(state or {})
    local stateHash = stateEngine.stateHash(normalized)
    local legalActions = shallowCopyArray(stateEngine.getLegalActions(normalized))
    deterministicSortActions(legalActions)
    local legalCount = #legalActions
    local reasons = {}

    local modulesScenarioOnly = stateEngine.isScenarioOnly and stateEngine.isScenarioOnly() == true
        and redPolicy.isScenarioOnly and redPolicy.isScenarioOnly() == true
    if not modulesScenarioOnly then
        reasons[#reasons + 1] = "scenario_only_contract_failed"
    end

    local selectedAction, policyRecord, deterministicRepeat, selectedActionRepeat = chooseDeterministic(normalized, context)
    local selectedLegal, selectedLegalIndex = findLegalMatch(legalActions, selectedAction)
    local currentPlayer = toNumber(normalized.currentPlayer, BLUE)
    local legalRedAction = true

    if currentPlayer == RED then
        legalRedAction = selectedLegal ~= nil
        if not legalRedAction then
            reasons[#reasons + 1] = "selected_action_not_legal_for_red"
        end
    end

    if not deterministicRepeat then
        reasons[#reasons + 1] = "deterministic_repeat_failed"
    end

    local criticalBlueIds, criticalBlueSet = deriveCriticalBlueUnitIds(normalized, context)
    local policyScore = nil
    local meaningfulAlternative = false
    local classification = "unclassified"
    local credibilityPass = true

    if currentPlayer ~= RED then
        classification = "non_red_turn"
        credibilityPass = false
        reasons[#reasons + 1] = "not_red_to_move"
    else
        policyScore = redPolicy.scoreAction(normalized, selectedAction or {}, {
            seed = context.seed,
            criticalBlueUnitIds = criticalBlueIds,
            requiredCells = context.requiredCells
        })
        meaningfulAlternative = hasMeaningfulAlternative(normalized, legalActions, {
            seed = context.seed,
            criticalBlueUnitIds = criticalBlueIds,
            requiredCells = context.requiredCells
        })

        local targetId = stableString(selectedAction and selectedAction.targetId or "")
        local isCriticalAttack = selectedAction and selectedAction.type == "attack" and criticalBlueSet[targetId] == true
        local hasMeaningfulImpact = policyScore and policyScore.features and policyScore.features.hasMeaningfulImpact == true

        if isCriticalAttack then
            classification = "attack_critical_blue_unit"
        elseif hasMeaningfulImpact and selectedAction and selectedAction.type ~= "end_turn" then
            classification = "block_or_pressure"
        elseif not meaningfulAlternative and (
            (selectedAction and selectedAction.type == "end_turn") or not hasMeaningfulImpact
        ) then
            classification = "no_op_no_meaningful_action"
        else
            classification = "not_credible"
            credibilityPass = false
            reasons[#reasons + 1] = "credibility_classification_failed"
        end
    end

    local expected = resolveExpectedActions(context, stateHash)
    local divergedFromExpected = false
    local rerun = {
        required = false,
        status = "not_required"
    }
    if expected ~= nil and not isExpectedAction(selectedAction or {}, expected) then
        divergedFromExpected = true
        reasons[#reasons + 1] = "policy_diverged_from_expected_action"
        rerun = proofRerun(normalized, selectedLegal or selectedAction, selectedLegal ~= nil, context)
        if rerun.status ~= "unsolved" then
            credibilityPass = false
            reasons[#reasons + 1] = "divergence_not_reproven_unsolved"
        end
    end

    local pass = modulesScenarioOnly
        and legalRedAction
        and deterministicRepeat
        and credibilityPass

    local evidence = {
        harnessVersion = M.VERSION,
        harnessId = M.HARNESS_ID,
        harnessHash = M.HARNESS_HASH,
        policyVersion = redPolicy.VERSION,
        policyHash = redPolicy.POLICY_HASH,
        stateEngineVersion = stateEngine.VERSION,
        stateHash = stateHash,
        currentPlayer = currentPlayer,
        selectedAction = canonicalAction(selectedAction),
        selectedActionRepeat = canonicalAction(selectedActionRepeat),
        selectedActionLegalIndex = selectedLegalIndex,
        legalActionCount = legalCount,
        deterministicRepeat = deterministicRepeat,
        legalRedAction = legalRedAction,
        classification = classification,
        criticalBlueUnitIds = criticalBlueIds,
        meaningfulAlternativeExists = meaningfulAlternative,
        score = policyScore and policyScore.score or nil,
        scoreReasons = policyScore and policyScore.reasons or {},
        policyRecord = policyRecord,
        divergedFromExpected = divergedFromExpected,
        proofRerun = rerun
    }

    local primaryReason = nil
    if #reasons > 0 then
        primaryReason = reasons[1]
    end

    return {
        pass = pass,
        reason = primaryReason,
        currentPlayer = currentPlayer,
        selectedAction = evidence.selectedAction,
        legalActionCount = legalCount,
        deterministicRepeat = deterministicRepeat,
        policyVersion = redPolicy.VERSION,
        policyHash = redPolicy.POLICY_HASH,
        stateHash = stateHash,
        classification = classification,
        divergedFromExpected = divergedFromExpected,
        proofRerun = rerun,
        reasons = reasons,
        evidence = evidence
    }
end

local function replayActions(baseState, actions)
    local cursor = stateEngine.normalize(baseState)
    local replay = {
        applied = {}
    }
    local line = type(actions) == "table" and actions or {}
    local i
    for i = 1, #line do
        local legal = shallowCopyArray(stateEngine.getLegalActions(cursor))
        deterministicSortActions(legal)
        local chosen = nil
        local j
        for j = 1, #legal do
            if actionMatches(legal[j], line[i]) then
                chosen = legal[j]
                break
            end
        end
        if chosen == nil then
            return cursor, replay, {
                ok = false,
                failingIndex = i,
                reason = "line_action_not_legal",
                attempted = canonicalAction(line[i]),
                stateHash = stateEngine.stateHash(cursor)
            }
        end
        cursor = stateEngine.applyAction(cursor, chosen)
        replay.applied[#replay.applied + 1] = {
            action = canonicalAction(chosen),
            stateHash = stateEngine.stateHash(cursor)
        }
    end
    return cursor, replay, { ok = true }
end

local function getFalseLineActions(falseLine)
    if type(falseLine) ~= "table" then
        return {}
    end
    if type(falseLine.actions) == "table" then
        return falseLine.actions
    end
    if type(falseLine.line) == "table" then
        return falseLine.line
    end
    if type(falseLine.proof) == "table" and type(falseLine.proof.replay) == "table" and type(falseLine.proof.replay.applied) == "table" then
        local out = {}
        local i
        for i = 1, #falseLine.proof.replay.applied do
            local entry = falseLine.proof.replay.applied[i]
            if type(entry) == "table" and type(entry.action) == "table" then
                out[#out + 1] = entry.action
            end
        end
        return out
    end
    return {}
end

local function buildOpeningDeviationActions(initialState, winningFirst, maxSamples)
    local legal = shallowCopyArray(stateEngine.getLegalActions(initialState))
    deterministicSortActions(legal)
    local out = {}
    local i
    for i = 1, #legal do
        local a = legal[i]
        if not actionMatches(a, winningFirst or {}) then
            out[#out + 1] = a
        end
    end
    local limit = toNumber(maxSamples, #out)
    if limit < 0 then
        limit = 0
    end
    if limit < #out then
        local trimmed = {}
        for i = 1, limit do
            trimmed[#trimmed + 1] = out[i]
        end
        return trimmed
    end
    return out
end

function M.evaluateDossier(dossier, opts)
    opts = type(opts) == "table" and opts or {}
    local out = {
        pass = true,
        harnessVersion = M.VERSION,
        harnessId = M.HARNESS_ID,
        harnessHash = M.HARNESS_HASH,
        checks = {},
        summary = {
            criticalStatesChecked = 0,
            falseLineStatesChecked = 0,
            blueDeviationStatesChecked = 0,
            failures = 0
        }
    }

    if type(dossier) ~= "table" or type(dossier.scenarioState) ~= "table" then
        out.pass = false
        out.reason = "invalid_dossier_or_missing_scenario_state"
        return out
    end

    local initialState = stateEngine.normalize(dossier.scenarioState)
    local proofDomain = opts.proofDomain
        or (dossier.proofCertificate and dossier.proofCertificate.proof_domain_version)
        or (dossier.mechanismSpec and dossier.mechanismSpec.proofDomain)
        or DEFAULT_PROOF_DOMAIN
    if proofDomain ~= "all_legal" and proofDomain ~= "defensive" then
        proofDomain = DEFAULT_PROOF_DOMAIN
    end

    local baseContext = {
        seed = opts.seed or dossier.seed,
        proofDomain = proofDomain,
        expectedPolicyActions = opts.expectedPolicyActions
    }

    local function recordCheck(source, index, state, extraEvidence)
        local ctx = {
            seed = baseContext.seed,
            proofDomain = baseContext.proofDomain,
            expectedPolicyActions = baseContext.expectedPolicyActions,
            requiredCells = opts.requiredCells,
            criticalBlueUnitIds = opts.criticalBlueUnitIds
        }
        local check = M.checkCriticalState(state, ctx)
        local entry = {
            source = source,
            index = index,
            pass = check.pass,
            reasons = check.reasons,
            evidence = check.evidence
        }
        if type(extraEvidence) == "table" then
            entry.extraEvidence = extraEvidence
        end
        out.checks[#out.checks + 1] = entry
        out.summary.criticalStatesChecked = out.summary.criticalStatesChecked + 1
        if source == "false_line" then
            out.summary.falseLineStatesChecked = out.summary.falseLineStatesChecked + 1
        elseif source == "blue_deviation" then
            out.summary.blueDeviationStatesChecked = out.summary.blueDeviationStatesChecked + 1
        end
        if not check.pass then
            out.pass = false
            out.summary.failures = out.summary.failures + 1
        end
    end

    local falseLines = type(dossier.falseLines) == "table" and dossier.falseLines or {}
    local i
    for i = 1, #falseLines do
        local lineActions = getFalseLineActions(falseLines[i])
        local postLine, replay, replayStatus = replayActions(initialState, lineActions)
        if not replayStatus.ok then
            out.pass = false
            out.summary.failures = out.summary.failures + 1
            out.checks[#out.checks + 1] = {
                source = "false_line",
                index = i,
                pass = false,
                reasons = { "false_line_replay_failed" },
                evidence = replayStatus
            }
        else
            local redState, advanceTrace, advanceStatus = advanceToRed(postLine, opts.maxAdvancePlies or DEFAULT_ADVANCE_PLIES)
            if not advanceStatus.ok then
                out.pass = false
                out.summary.failures = out.summary.failures + 1
                out.checks[#out.checks + 1] = {
                    source = "false_line",
                    index = i,
                    pass = false,
                    reasons = { "advance_to_red_failed" },
                    evidence = {
                        replay = replay,
                        advanceTrace = advanceTrace,
                        advanceStatus = advanceStatus
                    }
                }
            else
                recordCheck("false_line", i, redState, {
                    replay = replay,
                    advanceTrace = advanceTrace,
                    replayStartStateHash = stateEngine.stateHash(initialState),
                    replayEndStateHash = stateEngine.stateHash(postLine)
                })
            end
        end
    end

    if toNumber(initialState.currentPlayer, BLUE) == BLUE then
        local winningFirst = dossier.solution and dossier.solution.actions and dossier.solution.actions[1] or nil
        local deviations = buildOpeningDeviationActions(initialState, winningFirst, opts.maxDeviationSamples)
        for i = 1, #deviations do
            local deviationAction = deviations[i]
            local postDeviation = stateEngine.applyAction(initialState, deviationAction)
            local redState, advanceTrace, advanceStatus = advanceToRed(postDeviation, opts.maxAdvancePlies or DEFAULT_ADVANCE_PLIES)
            if not advanceStatus.ok then
                out.pass = false
                out.summary.failures = out.summary.failures + 1
                out.checks[#out.checks + 1] = {
                    source = "blue_deviation",
                    index = i,
                    pass = false,
                    reasons = { "advance_to_red_failed" },
                    evidence = {
                        deviationAction = canonicalAction(deviationAction),
                        advanceTrace = advanceTrace,
                        advanceStatus = advanceStatus
                    }
                }
            else
                recordCheck("blue_deviation", i, redState, {
                    deviationAction = canonicalAction(deviationAction),
                    advanceTrace = advanceTrace,
                    deviationStateHash = stateEngine.stateHash(postDeviation)
                })
            end
        end
    else
        out.checks[#out.checks + 1] = {
            source = "blue_deviation",
            index = 0,
            pass = true,
            reasons = {},
            evidence = {
                skipped = true,
                reason = "initial_state_not_blue_turn",
                currentPlayer = initialState.currentPlayer
            }
        }
    end

    out.falseLineChecks = out.summary.falseLineStatesChecked
    out.unexpectedDeviationChecks = out.summary.blueDeviationStatesChecked
    out.criticalStates = {}
    local ci
    for ci = 1, #out.checks do
        local check = out.checks[ci]
        if type(check.evidence) == "table" then
            out.criticalStates[#out.criticalStates + 1] = check.evidence
        end
    end
    return out
end

return M
