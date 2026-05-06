local stateEngine = require("scenario_tooling.state_engine")
local rulesKernel = require("scenario_tooling.rules_kernel")
local redPolicy = require("scenario_tooling.red_policy")

local M = {
    VERSION = "defensive_domain.v1",
    DOMAIN_ID = "defensive_domain_v1",
    DOMAIN_HASH = "defensive_domain_v1_2026_05_03"
}

local BLUE = 1
local RED = 2

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

local function actionId(action)
    if type(action) ~= "table" then
        return "unknown"
    end
    if action.id then
        return tostring(action.id)
    end
    if action.type == "move" then
        local to = action.to or {}
        return "move:" .. stableString(action.actorId) .. ":" .. stableString(to.row) .. ":" .. stableString(to.col)
    end
    if action.type == "attack" then
        local tc = action.targetCell or {}
        return "attack:" .. stableString(action.actorId) .. ":" .. stableString(action.targetId) .. ":" .. stableString(tc.row) .. ":" .. stableString(tc.col)
    end
    if action.type == "end_turn" then
        return "end_turn"
    end
    return stableString(action.type)
end

local function actionSortKey(action)
    local t = stableString(action and action.type or "")
    local actorId = stableString(action and action.actorId or "")
    local targetId = stableString(action and action.targetId or "")
    local to = (action and action.to) or {}
    local targetCell = (action and action.targetCell) or {}
    local row = stableString(to.row or targetCell.row or "")
    local col = stableString(to.col or targetCell.col or "")
    return table.concat({ t, actorId, targetId, row, col, actionId(action) }, "|")
end

local function deterministicSortActions(actions)
    table.sort(actions, function(a, b)
        return actionSortKey(a) < actionSortKey(b)
    end)
end

local function buildCellSet(requiredCells)
    local out = {}
    if type(requiredCells) ~= "table" then
        return out
    end
    local i
    for i = 1, #requiredCells do
        local c = requiredCells[i]
        if type(c) == "table" then
            local row = tonumber(c.row)
            local col = tonumber(c.col)
            if row and col then
                out[tostring(row) .. "," .. tostring(col)] = true
            end
        end
    end
    local key, value
    for key, value in pairs(requiredCells) do
        if value == true and type(key) == "string" then
            local row, col = key:match("^(%-?%d+)[,:](%-?%d+)$")
            if row and col then
                out[tostring(tonumber(row)) .. "," .. tostring(tonumber(col))] = true
            end
        end
    end
    return out
end

local function buildIdSet(ids)
    local out = {}
    if type(ids) ~= "table" then
        return out
    end
    local i
    for i = 1, #ids do
        out[stableString(ids[i])] = true
    end
    local key, value
    for key, value in pairs(ids) do
        if value == true then
            out[stableString(key)] = true
        end
    end
    return out
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

local function buildPredicateEntry(name, input, result)
    return {
        name = name,
        input = input,
        result = result
    }
end

local function scoreBand(score)
    local s = toNumber(score, 0)
    if s >= 40 then
        return "high"
    end
    if s >= 15 then
        return "medium"
    end
    if s >= 0 then
        return "low"
    end
    return "negative"
end

local function findRedCommandantId(state)
    local i
    for i = 1, #state.units do
        local u = state.units[i]
        if u.player == RED and u.name == "Commandant" and toNumber(u.currentHp, 0) > 0 then
            return u.id
        end
    end
    return nil
end

local function blueThreatToRedCommandant(state)
    local commandantId = findRedCommandantId(state)
    if commandantId == nil then
        return {
            computable = true,
            attackCount = 0,
            totalDamage = 0
        }
    end
    local probeState = stateEngine.cloneState(state)
    probeState.currentPlayer = BLUE
    local legal = stateEngine.getLegalActions(probeState)
    local attackCount = 0
    local totalDamage = 0
    local i
    for i = 1, #legal do
        local a = legal[i]
        if a.type == "attack" and stableString(a.targetId) == stableString(commandantId) then
            attackCount = attackCount + 1
            local _, result = rulesKernel.applyAction(probeState, a)
            if type(result) == "table" then
                totalDamage = totalDamage + toNumber(result.damage, 0)
            end
        end
    end
    return {
        computable = true,
        attackCount = attackCount,
        totalDamage = totalDamage
    }
end

local function classifyOne(normalized, redAction, ctx)
    local decision = "exclude"
    local reasonCodes = {}
    local predicateInputs = {}
    local predicateResults = {}
    local equivalenceReason = "not_equivalent_to_policy"

    local function addReason(code)
        reasonCodes[#reasonCodes + 1] = code
    end

    local function addPredicate(name, input, result)
        local entry = buildPredicateEntry(name, input, result)
        predicateInputs[#predicateInputs + 1] = { name = entry.name, input = entry.input }
        predicateResults[#predicateResults + 1] = { name = entry.name, result = entry.result }
    end

    local selectedByPolicy = ctx.policyActionId ~= "" and actionId(redAction) == ctx.policyActionId
    addPredicate("defensive_equivalence", { selectedActionId = ctx.policyActionId, actionId = actionId(redAction) }, {
        selectedByPolicy = selectedByPolicy,
        equivalentToPolicy = ctx.equivalentSet[actionId(redAction)] == true
    })

    if normalized.currentPlayer ~= RED then
        local isDeterministicNoop = (redAction.type == "end_turn") or (redAction.type == "noop")
        addPredicate("defensive_domain_inclusion", { nonRedTurn = true, actionType = redAction.type }, {
            include = isDeterministicNoop
        })
        if isDeterministicNoop then
            decision = "include"
            addReason("non_red_turn")
        else
            decision = "exclude"
        end
        return {
            redAction = redAction,
            decision = decision,
            reasonCodes = reasonCodes,
            predicateInputs = predicateInputs,
            predicateResults = predicateResults,
            policyScoreBand = ctx.policyScoreBand[actionId(redAction)] or "low",
            equivalenceReason = equivalenceReason,
            domainVersion = M.VERSION,
            domainHash = M.DOMAIN_HASH
        }
    end

    local include = false
    local unknown = false
    if ctx.forceUnknownActionIdSet[actionId(redAction)] == true then
        unknown = true
        addReason("forced_unknown_for_fixture")
        addPredicate("defensive_domain_inclusion", { actionId = actionId(redAction), forcedUnknown = true }, {
            include = false,
            unknown = true
        })
    end

    if selectedByPolicy then
        include = true
        equivalenceReason = "selected_by_policy"
        addReason("policy_choice")
    end

    local isAttackBlue = false
    local attackIsCriticalBlue = false
    local clearsRequiredCell = false
    if redAction.type == "attack" then
        local target = rulesKernel.getUnitById(normalized, redAction.targetId)
        if target == nil then
            unknown = true
        else
            isAttackBlue = target.player == BLUE
            if isAttackBlue then
                addReason("attacks_blue_unit")
            end
            if isAttackBlue and ctx.criticalBlueIdSet[stableString(redAction.targetId)] then
                attackIsCriticalBlue = true
                addReason("attacks_critical_blue_unit")
            end
            local k = tostring(target.row) .. "," .. tostring(target.col)
            if ctx.requiredCellSet[k] then
                clearsRequiredCell = true
                include = true
                addReason("clears_required_cell")
            end
        end
    end
    addPredicate("critical_blue_unit", { actionType = redAction.type, targetId = redAction.targetId }, {
        isAttackBlue = isAttackBlue,
        isCriticalBlueTarget = attackIsCriticalBlue
    })
    addPredicate("required_cell", { actionType = redAction.type }, {
        clearsRequiredCell = clearsRequiredCell
    })

    local blocksRequiredCell = false
    if redAction.type == "move" then
        local to = redAction.to or {}
        local moveKey = tostring(to.row) .. "," .. tostring(to.col)
        if ctx.requiredCellSet[moveKey] then
            blocksRequiredCell = true
            include = true
            addReason("blocks_required_cell")
        end
    end
    addPredicate("required_cell", { actionType = redAction.type, to = redAction.to }, {
        blocksRequiredCell = blocksRequiredCell
    })

    local threatReduced = false
    if ctx.baselineThreat.computable then
        local nextState, _ = stateEngine.applyAction(normalized, redAction)
        if type(nextState) ~= "table" then
            unknown = true
        else
            local afterThreat = blueThreatToRedCommandant(nextState)
            if not afterThreat.computable then
                unknown = true
            else
                local attackDelta = toNumber(ctx.baselineThreat.attackCount, 0) - toNumber(afterThreat.attackCount, 0)
                local damageDelta = toNumber(ctx.baselineThreat.totalDamage, 0) - toNumber(afterThreat.totalDamage, 0)
                threatReduced = (attackDelta > 0) or (damageDelta > 0)
                if threatReduced then
                    include = true
                    addReason("reduces_commandant_threat")
                end
                addPredicate("gains_time", { attackCountBefore = ctx.baselineThreat.attackCount, attackCountAfter = afterThreat.attackCount, damageBefore = ctx.baselineThreat.totalDamage, damageAfter = afterThreat.totalDamage }, {
                    reducesCommandantThreat = threatReduced
                })
            end
        end
    else
        unknown = true
    end

    if ctx.equivalentSet[actionId(redAction)] then
        equivalenceReason = "equivalent_policy_risk"
        addPredicate("prevents_micro_interaction", { actionId = actionId(redAction), selectedActionId = ctx.policyActionId }, {
            equivalentRisk = true
        })
    else
        addPredicate("prevents_micro_interaction", { actionId = actionId(redAction), selectedActionId = ctx.policyActionId }, {
            equivalentRisk = false
        })
    end

    local noImpact = (not include) and redAction.type ~= "end_turn"
    addPredicate("defensive_domain_inclusion", { actionType = redAction.type }, {
        include = include,
        noImpact = noImpact
    })

    if unknown then
        decision = "unknown"
    elseif include then
        decision = "include"
    elseif redAction.type == "end_turn" then
        if ctx.meaningfulIncludedCount > 0 then
            decision = "exclude"
            addReason("no_impact_end_turn")
        else
            decision = "fallback_all_legal"
        end
    elseif ctx.equivalentSet[actionId(redAction)] then
        decision = "include"
    else
        decision = "exclude"
    end

    if reasonCodes[1] == nil then
        if decision == "exclude" then
            reasonCodes = { "no_inclusion_predicate_true" }
        elseif decision == "fallback_all_legal" then
            reasonCodes = { "fallback_all_legal" }
        elseif decision == "unknown" then
            reasonCodes = { "unknown_defensive_domain_move" }
        else
            reasonCodes = { "included_by_defensive_domain" }
        end
    end

    return {
        redAction = redAction,
        decision = decision,
        reasonCodes = reasonCodes,
        predicateInputs = predicateInputs,
        predicateResults = predicateResults,
        policyScoreBand = ctx.policyScoreBand[actionId(redAction)] or "low",
        equivalenceReason = equivalenceReason,
        domainVersion = M.VERSION,
        domainHash = M.DOMAIN_HASH
    }
end

function M.isScenarioOnly()
    return true
end

function M.classifyRedAction(state, redAction, opts)
    opts = type(opts) == "table" and opts or {}
    local normalized = stateEngine.normalize(state)
    local allDecisions, _ = M.classifyAll(normalized, opts)
    local targetId = actionId(redAction)
    local i
    for i = 1, #allDecisions do
        local d = allDecisions[i]
        if actionId(d.redAction) == targetId then
            return d
        end
    end
    return {
        redAction = redAction,
        decision = "unknown",
        reasonCodes = { "action_not_legal" },
        predicateInputs = {
            { name = "defensive_domain_inclusion", input = { legal = false } }
        },
        predicateResults = {
            { name = "defensive_domain_inclusion", result = { legal = false } }
        },
        policyScoreBand = "low",
        equivalenceReason = nil,
        domainVersion = M.VERSION,
        domainHash = M.DOMAIN_HASH
    }
end

function M.classifyAll(state, opts)
    opts = type(opts) == "table" and opts or {}
    local normalized = stateEngine.normalize(state)
    local legalActions = shallowCopyArray(stateEngine.getLegalActions(normalized))
    deterministicSortActions(legalActions)

    local selectedAction, policyRecord = redPolicy.chooseAction(normalized, opts)
    local selectedActionId = selectedAction and actionId(selectedAction) or ""
    local equivalentActions = {}
    if selectedAction and opts.includeEquivalentActions == true then
        equivalentActions = redPolicy.getEquivalentActions(normalized, selectedAction, opts)
    end
    deterministicSortActions(equivalentActions)
    local equivalentSet = {}
    local i
    for i = 1, #equivalentActions do
        equivalentSet[actionId(equivalentActions[i])] = true
    end

    local policyScoreBand = {}
    for i = 1, #(policyRecord and policyRecord.scoredActions or {}) do
        local scored = policyRecord.scoredActions[i]
        policyScoreBand[stableString(scored and scored.actionId)] = scoreBand(scored and scored.score or 0)
    end
    for i = 1, #legalActions do
        local id = actionId(legalActions[i])
        if policyScoreBand[id] == nil then
            policyScoreBand[id] = (id == selectedActionId) and "high" or "low"
        end
    end

    local context = {
        policyActionId = selectedActionId,
        equivalentSet = equivalentSet,
        requiredCellSet = buildCellSet(opts.requiredCells),
        criticalBlueIdSet = buildIdSet(opts.criticalBlueUnitIds),
        forceUnknownActionIdSet = buildIdSet(opts.forceUnknownRedActionIds),
        baselineThreat = blueThreatToRedCommandant(normalized),
        meaningfulIncludedCount = 0,
        policyScoreBand = policyScoreBand
    }

    local draft = {}
    for i = 1, #legalActions do
        draft[i] = classifyOne(normalized, legalActions[i], context)
        if draft[i].decision == "include" and draft[i].redAction.type ~= "end_turn" then
            context.meaningfulIncludedCount = context.meaningfulIncludedCount + 1
        end
    end

    local decisions = {}
    local counts = {
        include = 0,
        exclude = 0,
        unknown = 0,
        fallback_all_legal = 0
    }
    local hasUnknown = false
    local hasIncluded = false
    for i = 1, #draft do
        local d = draft[i]
        if d.redAction.type == "end_turn" and d.decision == "fallback_all_legal" and context.meaningfulIncludedCount > 0 then
            d.decision = "exclude"
            d.reasonCodes = { "no_impact_end_turn" }
        end
        counts[d.decision] = counts[d.decision] + 1
        hasUnknown = hasUnknown or d.decision == "unknown"
        hasIncluded = hasIncluded or d.decision == "include"
        decisions[#decisions + 1] = d
    end

    local fallbackAllLegal = false
    if not hasUnknown and not hasIncluded and #decisions > 0 then
        fallbackAllLegal = true
        counts.fallback_all_legal = 0
        for i = 1, #decisions do
            decisions[i].decision = "fallback_all_legal"
            counts.fallback_all_legal = counts.fallback_all_legal + 1
            if decisions[i].reasonCodes[1] == nil then
                decisions[i].reasonCodes = { "fallback_all_legal" }
            end
        end
        counts.include = 0
        counts.exclude = 0
    end

    local summary = {
        total = #decisions,
        counts = counts,
        fallbackAllLegal = fallbackAllLegal,
        solverStatus = hasUnknown and "unknown" or "ok",
        domainVersion = M.VERSION,
        domainHash = M.DOMAIN_HASH
    }

    return decisions, summary
end

function M.includedActions(state, opts)
    opts = type(opts) == "table" and opts or {}
    local decisions, summary = M.classifyAll(state, opts)
    local actions = {}
    local hasUnknown = false
    local i
    for i = 1, #decisions do
        local d = decisions[i]
        if d.decision == "unknown" then
            hasUnknown = true
        end
        if d.decision == "include" or d.decision == "fallback_all_legal" then
            actions[#actions + 1] = d.redAction
        end
    end
    if hasUnknown and opts.allowUnknown ~= true then
        summary.solverStatus = "unknown"
    end
    return actions, decisions, summary
end

return M
