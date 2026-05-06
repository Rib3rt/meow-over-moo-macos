local componentLibrary = require("scenario_tooling.composition_component_library")
local microLibrary = require("scenario_tooling.micro_interaction_library")

local M = {
    VERSION = "scenario_composition_composer.v1",
    COMPOSER_ID = "composition_composer_v1"
}

local PROFILE_REQUIRED_FIELDS = {
    "id",
    "version",
    "pattern",
    "componentIds",
    "consequenceSlots"
}

local CHANGED_OUTPUTS = {
    winning_line = true,
    red_response = true,
    false_line = true,
    exactness = true,
    outcome = true,
    legal_move_set = true
}

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

local function shallowCopyArray(arr)
    local out = {}
    local i
    for i = 1, #(arr or {}) do
        out[i] = arr[i]
    end
    return out
end

local function nonEmpty(value)
    if type(value) == "string" then
        return value ~= ""
    end
    if type(value) == "table" then
        return next(value) ~= nil
    end
    return value ~= nil
end

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

local function canonicalAction(action)
    if type(action) ~= "table" then
        return {}
    end
    local out = {
        type = action.type,
        actorId = action.actorId,
        targetId = action.targetId
    }
    if type(action.from) == "table" then
        out.from = { row = tonumber(action.from.row), col = tonumber(action.from.col) }
    end
    if type(action.to) == "table" then
        out.to = { row = tonumber(action.to.row), col = tonumber(action.to.col) }
    end
    if type(action.targetCell) == "table" then
        out.targetCell = { row = tonumber(action.targetCell.row), col = tonumber(action.targetCell.col) }
    end
    out.id = action.id
    return out
end

local function actionSignature(action)
    local a = type(action) == "table" and action or {}
    local to = type(a.to) == "table" and a.to or {}
    local from = type(a.from) == "table" and a.from or {}
    return table.concat({
        stableString(a.type),
        stableString(a.actorId),
        stableString(a.targetId),
        stableString(from.row),
        stableString(from.col),
        stableString(to.row),
        stableString(to.col)
    }, ":")
end

local function actionIsBlueKey(action)
    if type(action) ~= "table" or action.type == "end_turn" then
        return false
    end
    return stableString(action.actorId):find("^blue_", 1, false) ~= nil
end

local function hasChangedOutput(consequence)
    if type(consequence) ~= "table" then
        return false
    end
    local key
    for key in pairs(CHANGED_OUTPUTS) do
        if consequence[key] == true then
            return true
        end
    end
    local outputs = consequence.changed_outputs
        or (type(consequence.delta_metrics) == "table" and consequence.delta_metrics.changed_outputs)
        or {}
    local i
    for i = 1, #(outputs or {}) do
        if CHANGED_OUTPUTS[stableString(outputs[i])] then
            return true
        end
    end
    return false
end

local function consequenceIsProven(consequence)
    if type(consequence) ~= "table" then
        return false
    end
    local status = stableString(consequence.status)
    return consequence.proven == true
        or status == "proven"
        or status == "verified"
        or status == "true"
end

local function consequenceHasActionRef(consequence)
    return type(consequence) == "table"
        and (consequence.actionIndex ~= nil
            or consequence.action_index ~= nil
            or consequence.actionSignature ~= nil
            or consequence.action_signature ~= nil)
end

local function consequenceComponentIds(consequence)
    local out = {}
    if type(consequence) ~= "table" then
        return out
    end
    if consequence.componentId ~= nil then
        out[#out + 1] = consequence.componentId
    end
    for _, componentId in ipairs(consequence.componentIds or {}) do
        out[#out + 1] = componentId
    end
    for _, componentId in ipairs(consequence.relatedComponentIds or {}) do
        out[#out + 1] = componentId
    end
    return out
end

local function predicateEntry(name, value, evidence)
    return {
        schema = "PredicateResult",
        predicate = name,
        predicateVersion = "composition-composer-v1",
        inputDigest = hashText(name .. "|" .. stableString(value) .. "|" .. stableString(evidence and evidence.slotId)),
        status = tostring(value),
        value = value,
        deterministic = true,
        ownerModule = "scenario_tooling.composition_composer",
        evidence = evidence or {}
    }
end

local function componentIdSet(componentIds)
    local set = {}
    local i
    for i = 1, #(componentIds or {}) do
        set[componentIds[i]] = true
    end
    return set
end

local PROFILES = {
    {
        id = "composite_support_pressure_crusher_contact",
        version = "1.0.0",
        pattern = "composite_support_pressure_crusher_contact",
        componentIds = {
            "support_pressure_answer",
            "contact_blocker_clear",
            "finisher_staging_gain",
            "exact_contact_payoff",
            "wrong_target_tempo_branch"
        },
        consequenceSlots = {
            {
                id = "support_setup_move",
                componentId = "support_pressure_answer",
                microInteractionId = "SUPPORT_CELL_GAIN",
                consequence = "Support move changes the legal move set and answers real Red pressure before support can be removed.",
                consequenceOutputs = { "winning_line", "legal_move_set", "red_response" }
            },
            {
                id = "support_blocker_clear_attack",
                componentId = "contact_blocker_clear",
                relatedComponentIds = { "wrong_target_tempo_branch" },
                microInteractionId = "ORDER_DEPENDENCY",
                consequence = "Support attack resolves the contact blocker and proves the tempting tempo/target branch is not equivalent.",
                consequenceOutputs = { "winning_line", "false_line", "legal_move_set" }
            },
            {
                id = "finisher_staging_move",
                componentId = "finisher_staging_gain",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Finisher staging changes exact reachability without already winning.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "crusher_contact_move",
                componentId = "exact_contact_payoff",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Crusher contact move changes the attack set and enables the payoff window.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "commandant_payoff_attack",
                componentId = "exact_contact_payoff",
                microInteractionId = "HP_EXACT_WINDOW",
                consequence = "Final attack changes the outcome from unresolved to Blue win inside the horizon.",
                consequenceOutputs = { "outcome", "exactness", "winning_line" }
            }
        },
        description = "Support answers real Red pressure, clears contact access, then Crusher earns exact contact payoff.",
        fixtureKeys = {
            "fixture.profile.composite_support_pressure_crusher_contact.true",
            "fixture.profile.composite_support_pressure_crusher_contact.false"
        }
    },
    {
        id = "crusher_contact_breach",
        version = "1.0.0",
        pattern = "crusher_contact_breach",
        componentIds = {
            "contact_blocker_clear",
            "finisher_staging_gain",
            "exact_contact_payoff",
            "wrong_target_tempo_branch"
        },
        consequenceSlots = {
            {
                id = "support_contact_setup_move",
                componentId = "contact_blocker_clear",
                microInteractionId = "SUPPORT_CELL_GAIN",
                consequence = "Support move changes the legal blocker-clear set for the required contact cell.",
                consequenceOutputs = { "winning_line", "legal_move_set" }
            },
            {
                id = "support_blocker_clear_attack",
                componentId = "contact_blocker_clear",
                relatedComponentIds = { "wrong_target_tempo_branch" },
                microInteractionId = "ORDER_DEPENDENCY",
                consequence = "Support attack resolves the contact blocker and proves target/order tempo is not equivalent.",
                consequenceOutputs = { "winning_line", "false_line", "legal_move_set" }
            },
            {
                id = "finisher_staging_move",
                componentId = "finisher_staging_gain",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Crusher staging changes exact reachability without already winning.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "crusher_contact_move",
                componentId = "exact_contact_payoff",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Crusher contact move changes the attack set and enables the melee payoff window.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "commandant_payoff_attack",
                componentId = "exact_contact_payoff",
                microInteractionId = "HP_EXACT_WINDOW",
                consequence = "Final attack changes the outcome from unresolved to Blue win inside the horizon.",
                consequenceOutputs = { "outcome", "exactness", "winning_line" }
            }
        },
        description = "Support clears a contact blocker, then Crusher earns exact melee contact payoff.",
        fixtureKeys = {
            "fixture.profile.crusher_contact_breach.true",
            "fixture.profile.crusher_contact_breach.false"
        }
    },
    {
        id = "support_reposition_rock_los_finish",
        version = "1.0.0",
        pattern = "support_reposition_rock_los_finish",
        componentIds = {
            "rock_lock_conversion",
            "los_open_ranged_lane",
            "finisher_staging_gain",
            "exact_contact_payoff",
            "wrong_target_tempo_branch"
        },
        consequenceSlots = {
            {
                id = "support_los_setup_move",
                componentId = "rock_lock_conversion",
                microInteractionId = "SUPPORT_CELL_GAIN",
                consequence = "Support move changes the legal Rock-lock conversion set.",
                consequenceOutputs = { "winning_line", "legal_move_set" }
            },
            {
                id = "support_rock_clear_attack",
                componentId = "rock_lock_conversion",
                relatedComponentIds = { "los_open_ranged_lane", "wrong_target_tempo_branch" },
                microInteractionId = "ROCK_AS_LOCK",
                consequence = "Support attack converts the Rock lock and proves ignoring the lock loses tempo.",
                consequenceOutputs = { "winning_line", "false_line", "legal_move_set" }
            },
            {
                id = "finisher_staging_move",
                componentId = "finisher_staging_gain",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Finisher staging changes exact reachability without already winning.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "finisher_los_cell_move",
                componentId = "los_open_ranged_lane",
                microInteractionId = "LOS_OPEN_RANGED",
                consequence = "Finisher reaches the opened line cell and changes the Commandant attack set.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "commandant_payoff_attack",
                componentId = "exact_contact_payoff",
                microInteractionId = "HP_EXACT_WINDOW",
                consequence = "Final ranged attack changes the outcome from unresolved to Blue win inside the horizon.",
                consequenceOutputs = { "outcome", "exactness", "winning_line" }
            }
        },
        description = "Support converts a Rock/LOS lock, then Cloudstriker earns the exact ranged payoff.",
        fixtureKeys = {
            "fixture.profile.support_reposition_rock_los_finish.true",
            "fixture.profile.support_reposition_rock_los_finish.false"
        }
    },
    {
        id = "support_under_real_red_pressure",
        version = "1.0.0",
        pattern = "support_under_real_red_pressure",
        componentIds = {
            "support_pressure_answer",
            "rock_lock_conversion",
            "los_open_ranged_lane",
            "finisher_staging_gain",
            "exact_contact_payoff",
            "wrong_target_tempo_branch"
        },
        consequenceSlots = {
            {
                id = "support_pressure_setup_move",
                componentId = "support_pressure_answer",
                relatedComponentIds = { "rock_lock_conversion" },
                microInteractionId = "SUPPORT_CELL_GAIN",
                consequence = "Support move changes the Rock-clear set while answering deterministic Red pressure.",
                consequenceOutputs = { "winning_line", "legal_move_set", "red_response" }
            },
            {
                id = "support_rock_clear_attack",
                componentId = "rock_lock_conversion",
                relatedComponentIds = { "los_open_ranged_lane", "wrong_target_tempo_branch" },
                microInteractionId = "ROCK_AS_LOCK",
                consequence = "Support attack converts the Rock lock and proves ignoring the pressure/lock branch loses tempo.",
                consequenceOutputs = { "winning_line", "false_line", "legal_move_set" }
            },
            {
                id = "finisher_staging_move",
                componentId = "finisher_staging_gain",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Finisher staging changes exact reachability without already winning.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "finisher_los_cell_move",
                componentId = "los_open_ranged_lane",
                microInteractionId = "LOS_OPEN_RANGED",
                consequence = "Finisher reaches the opened ranged line cell and changes the Commandant attack set.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "commandant_payoff_attack",
                componentId = "exact_contact_payoff",
                microInteractionId = "HP_EXACT_WINDOW",
                consequence = "Final ranged attack changes the outcome from unresolved to Blue win inside the horizon.",
                consequenceOutputs = { "outcome", "exactness", "winning_line" }
            }
        },
        description = "Support answers real Red pressure, converts Rock/LOS access, then Cloudstriker earns exact ranged payoff.",
        fixtureKeys = {
            "fixture.profile.support_under_real_red_pressure.true",
            "fixture.profile.support_under_real_red_pressure.false"
        }
    },
    {
        id = "support_intercepts_finisher_threat_artillery_finish",
        version = "1.0.0",
        pattern = "support_intercepts_finisher_threat_artillery_finish",
        componentIds = {
            "finisher_interceptor_clear",
            "finisher_staging_gain",
            "exact_contact_payoff",
            "wrong_target_tempo_branch"
        },
        consequenceSlots = {
            {
                id = "support_interceptor_setup_move",
                componentId = "finisher_interceptor_clear",
                microInteractionId = "SUPPORT_CELL_GAIN",
                consequence = "Support move changes the interceptor-clear set before Red can remove the finisher.",
                consequenceOutputs = { "winning_line", "legal_move_set", "red_response" }
            },
            {
                id = "support_interceptor_clear_attack",
                componentId = "finisher_interceptor_clear",
                relatedComponentIds = { "wrong_target_tempo_branch" },
                microInteractionId = "RED_ATTACKS_FINISHER",
                consequence = "Support attack removes the finisher interceptor and proves skipping it loses the finisher.",
                consequenceOutputs = { "winning_line", "false_line", "red_response" }
            },
            {
                id = "artillery_staging_move",
                componentId = "finisher_staging_gain",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Artillery staging changes exact reachability without already winning.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "artillery_final_cell_move",
                componentId = "exact_contact_payoff",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Artillery reaches the final orthogonal firing cell and changes the Commandant attack set.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "commandant_payoff_attack",
                componentId = "exact_contact_payoff",
                microInteractionId = "HP_EXACT_WINDOW",
                consequence = "Final artillery attack changes the outcome from unresolved to Blue win inside the horizon.",
                consequenceOutputs = { "outcome", "exactness", "winning_line" }
            }
        },
        description = "Support intercepts a Red finisher killer, then Artillery stages into an exact orthogonal payoff.",
        fixtureKeys = {
            "fixture.profile.support_intercepts_finisher_threat_artillery_finish.true",
            "fixture.profile.support_intercepts_finisher_threat_artillery_finish.false"
        }
    },
    {
        id = "dual_rock_lock_ranged_finish",
        version = "1.0.0",
        pattern = "dual_rock_lock_ranged_finish",
        componentIds = {
            "dual_rock_lock_chain",
            "los_open_ranged_lane",
            "exact_contact_payoff",
            "wrong_target_tempo_branch"
        },
        consequenceSlots = {
            {
                id = "support_lower_lock_setup_move",
                componentId = "dual_rock_lock_chain",
                microInteractionId = "SUPPORT_CELL_GAIN",
                consequence = "Support move changes the first Rock-lock conversion set without opening the full lane.",
                consequenceOutputs = { "winning_line", "legal_move_set" }
            },
            {
                id = "support_lower_rock_clear_attack",
                componentId = "dual_rock_lock_chain",
                microInteractionId = "ROCK_AS_LOCK",
                consequence = "Support attack removes the lower Rock while the upper Rock still blocks the final line.",
                consequenceOutputs = { "winning_line", "false_line", "legal_move_set" }
            },
            {
                id = "support_upper_lock_setup_move",
                componentId = "dual_rock_lock_chain",
                microInteractionId = "ORDER_DEPENDENCY",
                consequence = "Support second setup move changes the remaining upper-lock conversion set.",
                consequenceOutputs = { "winning_line", "legal_move_set", "exactness" }
            },
            {
                id = "support_upper_rock_clear_attack",
                componentId = "dual_rock_lock_chain",
                relatedComponentIds = { "los_open_ranged_lane", "wrong_target_tempo_branch" },
                microInteractionId = "LOS_OPEN_RANGED",
                consequence = "Support attack removes the upper Rock and opens the ranged lane for the finisher.",
                consequenceOutputs = { "winning_line", "false_line", "legal_move_set", "exactness" }
            },
            {
                id = "finisher_dual_lock_cell_move",
                componentId = "exact_contact_payoff",
                microInteractionId = "FINISHER_CELL_GAIN",
                consequence = "Finisher reaches the now-open ranged cell and changes the Commandant attack set.",
                consequenceOutputs = { "winning_line", "exactness", "legal_move_set" }
            },
            {
                id = "commandant_payoff_attack",
                componentId = "exact_contact_payoff",
                microInteractionId = "HP_EXACT_WINDOW",
                consequence = "Final ranged attack changes the outcome from unresolved to Blue win inside the horizon.",
                consequenceOutputs = { "outcome", "exactness", "winning_line" }
            }
        },
        description = "Support converts two Rock locks across two turns, then Cloudstriker earns exact ranged payoff.",
        fixtureKeys = {
            "fixture.profile.dual_rock_lock_ranged_finish.true",
            "fixture.profile.dual_rock_lock_ranged_finish.false"
        }
    }
}

local PROFILE_BY_ID = {}
do
    local i
    for i = 1, #PROFILES do
        PROFILE_BY_ID[PROFILES[i].id] = PROFILES[i]
    end
end

local function findSlot(profile, slotId)
    for _, slot in ipairs(profile and profile.consequenceSlots or {}) do
        if slot.id == slotId then
            return slot
        end
    end
    return nil
end

local function expandComponent(componentId)
    local spec = componentLibrary.getComponent(componentId)
    if type(spec) ~= "table" then
        return nil
    end
    return {
        id = spec.id,
        version = spec.version,
        family = spec.family,
        role = spec.role,
        producedMicroInteractions = shallowCopyArray(spec.producedMicroInteractions),
        requiredPredicates = shallowCopyArray(spec.requiredPredicates),
        consequenceOutputs = shallowCopyArray(spec.consequenceOutputs),
        ablationSubject = spec.ablationSubject,
        evidenceRequirements = shallowCopyArray(spec.evidenceRequirements),
        incompatibilities = shallowCopyArray(spec.incompatibilities)
    }
end

local function addError(report, code)
    report.errors[#report.errors + 1] = code
end

function M.isScenarioOnly()
    return true
end

function M.listProfiles()
    local out = {}
    local i
    for i = 1, #PROFILES do
        out[i] = cloneValue(PROFILES[i])
    end
    return out
end

function M.getProfile(id)
    local profile = PROFILE_BY_ID[id]
    if not profile then
        return nil
    end
    return cloneValue(profile)
end

function M.getConsequenceSlots(profileOrId)
    local profile = type(profileOrId) == "table" and profileOrId or M.getProfile(profileOrId)
    if type(profile) ~= "table" then
        return nil
    end
    return cloneValue(profile.consequenceSlots or {})
end

function M.validateProfile(profile)
    local spec = profile
    if type(profile) == "string" then
        spec = PROFILE_BY_ID[profile]
    end
    local report = {
        id = type(spec) == "table" and spec.id or profile,
        ok = true,
        errors = {}
    }
    if type(spec) ~= "table" then
        addError(report, "profile_missing")
        report.ok = false
        return false, report
    end

    local i
    for i = 1, #PROFILE_REQUIRED_FIELDS do
        local field = PROFILE_REQUIRED_FIELDS[i]
        if not nonEmpty(spec[field]) then
            addError(report, "missing_or_empty_field:" .. field)
        end
    end

    local seen = {}
    for _, componentId in ipairs(spec.componentIds or {}) do
        if seen[componentId] then
            addError(report, "duplicate_component_id:" .. stableString(componentId))
        else
            seen[componentId] = true
        end
        if not componentLibrary.getComponent(componentId) then
            addError(report, "unknown_component_id:" .. stableString(componentId))
        end
    end

    local knownComponents = componentIdSet(spec.componentIds or {})
    local seenSlots = {}
    for _, slot in ipairs(spec.consequenceSlots or {}) do
        if type(slot) ~= "table" then
            addError(report, "invalid_consequence_slot")
        else
            if type(slot.id) ~= "string" or slot.id == "" then
                addError(report, "consequence_slot_id_missing")
            elseif seenSlots[slot.id] then
                addError(report, "duplicate_consequence_slot:" .. slot.id)
            else
                seenSlots[slot.id] = true
            end
            if not knownComponents[slot.componentId] then
                addError(report, "slot_unknown_component:" .. stableString(slot.componentId))
            end
            for _, relatedId in ipairs(slot.relatedComponentIds or {}) do
                if not knownComponents[relatedId] then
                    addError(report, "slot_unknown_related_component:" .. stableString(relatedId))
                end
            end
            if not microLibrary.getMicroInteraction(slot.microInteractionId) then
                addError(report, "slot_unknown_micro:" .. stableString(slot.microInteractionId))
            end
            if not hasChangedOutput({ changed_outputs = slot.consequenceOutputs or {} }) then
                addError(report, "slot_outputs_missing:" .. stableString(slot.id))
            end
        end
    end

    report.ok = #report.errors == 0
    return report.ok, report
end

function M.buildActionConsequence(profileOrId, slotId, params)
    params = type(params) == "table" and params or {}
    local profile = type(profileOrId) == "table" and profileOrId or M.getProfile(profileOrId)
    if not profile then
        return nil, "profile_missing"
    end
    local slot = findSlot(profile, slotId)
    if not slot then
        return nil, "slot_missing"
    end

    local action = canonicalAction(params.action)
    local outputs = shallowCopyArray(slot.consequenceOutputs)
    local beforeHash = params.beforeStateHash or params.before_hash or "unknown"
    local afterHash = params.afterStateHash or params.after_hash or "unknown"
    local relatedComponentIds = shallowCopyArray(slot.relatedComponentIds)
    local componentIds = { slot.componentId }
    for _, relatedId in ipairs(relatedComponentIds) do
        componentIds[#componentIds + 1] = relatedId
    end

    local result = {
        schema = "AblationResult",
        ablation_id = "action_consequence_" .. hashText(table.concat({
            stableString(params.seed or profile.seed),
            stableString(slot.id),
            stableString(params.actionIndex),
            actionSignature(action),
            beforeHash,
            afterHash
        }, "|")),
        subject_type = "micro_interaction",
        subject_id = slot.microInteractionId,
        microInteractionId = slot.microInteractionId,
        actionIndex = params.actionIndex,
        actionSignature = params.actionSignature or actionSignature(action),
        action = action,
        slotId = slot.id,
        componentId = slot.componentId,
        componentIds = componentIds,
        relatedComponentIds = relatedComponentIds,
        consequence = params.consequence or slot.consequence,
        status = "proven",
        proven = true,
        baseline_outcome = "forced_win",
        ablated_outcome = "unsolved",
        changed = true,
        changed_outputs = outputs,
        horizon = params.horizon,
        delta_metrics = {
            changed_outputs = outputs,
            before_state_hash = beforeHash,
            after_state_hash = afterHash,
            evidence = params.evidence or {}
        },
        predicate_results = {
            predicateEntry("non_decorative_micro", true, {
                slotId = slot.id,
                microInteraction = slot.microInteractionId,
                componentId = slot.componentId,
                relatedComponentIds = relatedComponentIds,
                actionSignature = params.actionSignature or actionSignature(action),
                changedOutputs = outputs
            })
        },
        notes = params.consequence or slot.consequence
    }
    local i
    for i = 1, #outputs do
        result[outputs[i]] = true
    end
    return result
end

function M.buildActionConsequences(profileOrId, slotInputs, opts)
    opts = type(opts) == "table" and opts or {}
    local out = {}
    for _, input in ipairs(slotInputs or {}) do
        local params = cloneValue(input)
        params.seed = params.seed or opts.seed
        params.horizon = params.horizon or opts.horizon
        local consequence, err = M.buildActionConsequence(profileOrId, input.slotId, params)
        if not consequence then
            return nil, err
        end
        out[#out + 1] = consequence
    end
    return out
end

function M.buildContract(profileOrId, intendedLine, actionConsequences, opts)
    opts = type(opts) == "table" and opts or {}
    local profile = type(profileOrId) == "table" and cloneValue(profileOrId) or M.getProfile(profileOrId)
    if not profile then
        return nil, "profile_missing"
    end
    local ok, report = M.validateProfile(profile)
    if not ok then
        return nil, report
    end

    local components = {}
    local i
    for i = 1, #(profile.componentIds or {}) do
        components[#components + 1] = expandComponent(profile.componentIds[i])
    end

    return {
        schema = "CompositionalContract",
        version = "scenario_composition.v1",
        composerVersion = M.VERSION,
        composerId = M.COMPOSER_ID,
        seed = opts.seed or profile.seed,
        profileId = profile.id,
        pattern = profile.pattern,
        componentIds = shallowCopyArray(profile.componentIds),
        consequenceSlots = cloneValue(profile.consequenceSlots),
        components = components,
        intendedLine = cloneValue(intendedLine or {}),
        actionConsequences = cloneValue(actionConsequences or {})
    }
end

function M.validateContract(contract)
    local report = {
        id = type(contract) == "table" and contract.profileId or nil,
        ok = true,
        errors = {}
    }
    if type(contract) ~= "table" then
        addError(report, "contract_missing")
        report.ok = false
        return false, report
    end
    if contract.schema ~= "CompositionalContract" then
        addError(report, "schema_invalid")
    end
    if contract.version ~= "scenario_composition.v1" then
        addError(report, "version_invalid")
    end
    if type(contract.profileId) ~= "string" or contract.profileId == "" then
        addError(report, "profile_id_missing")
    elseif not PROFILE_BY_ID[contract.profileId] then
        addError(report, "profile_unknown")
    end
    local expectedProfile = contract.profileId and PROFILE_BY_ID[contract.profileId] or nil
    local expectedComponents = expectedProfile and componentIdSet(expectedProfile.componentIds) or {}
    local contractComponents = componentIdSet(contract.componentIds or {})
    if expectedProfile then
        for _, componentId in ipairs(expectedProfile.componentIds or {}) do
            if not contractComponents[componentId] then
                addError(report, "profile_component_missing:" .. componentId)
            end
        end
        for componentId in pairs(contractComponents) do
            if not expectedComponents[componentId] then
                addError(report, "profile_component_unexpected:" .. componentId)
            end
        end
    end
    if type(contract.components) ~= "table" or #contract.components == 0 then
        addError(report, "components_missing")
    else
        for _, component in ipairs(contract.components) do
            if type(component) ~= "table" or type(component.id) ~= "string" or component.id == "" then
                addError(report, "component_record_invalid")
            elseif not componentLibrary.getComponent(component.id) then
                addError(report, "component_record_unknown:" .. stableString(component.id))
            end
            if type(component) == "table" then
                if type(component.family) ~= "string" or component.family == "" then
                    addError(report, "component_family_missing:" .. stableString(component.id))
                end
                if type(component.role) ~= "string" or component.role == "" then
                    addError(report, "component_role_missing:" .. stableString(component.id))
                end
                if type(component.producedMicroInteractions) ~= "table" or #component.producedMicroInteractions == 0 then
                    addError(report, "component_micros_missing:" .. stableString(component.id))
                end
                if type(component.consequenceOutputs) ~= "table" or #component.consequenceOutputs == 0 then
                    addError(report, "component_outputs_missing:" .. stableString(component.id))
                end
            end
        end
    end
    if type(contract.actionConsequences) ~= "table" or #contract.actionConsequences == 0 then
        addError(report, "action_consequences_missing")
    end

    local keyActionCount = 0
    local keyActionEntries = {}
    for _, action in ipairs(contract.intendedLine or {}) do
        if actionIsBlueKey(action) then
            keyActionCount = keyActionCount + 1
            keyActionEntries[#keyActionEntries + 1] = {
                ordinal = keyActionCount,
                signature = actionSignature(action)
            }
        end
    end

    local provenConsequenceCount = 0
    local coverageBySignature = {}
    local coverageByOrdinal = {}
    local componentCoverage = {}
    for _, consequence in ipairs(contract.actionConsequences or {}) do
        if consequenceHasActionRef(consequence)
            and consequenceIsProven(consequence)
            and consequence.changed == true
            and hasChangedOutput(consequence) then
            provenConsequenceCount = provenConsequenceCount + 1
            local signature = stableString(consequence.actionSignature or consequence.action_signature)
            if signature ~= "" then
                coverageBySignature[signature] = (coverageBySignature[signature] or 0) + 1
            end
            local ordinal = tonumber(consequence.actionIndex or consequence.action_index or consequence.index)
            if ordinal then
                coverageByOrdinal[ordinal] = (coverageByOrdinal[ordinal] or 0) + 1
            end
            for _, componentId in ipairs(consequenceComponentIds(consequence)) do
                componentCoverage[componentId] = (componentCoverage[componentId] or 0) + 1
            end
        end
    end

    if keyActionCount > 0 then
        for _, entry in ipairs(keyActionEntries) do
            local count = coverageBySignature[entry.signature]
            if count == nil then
                count = coverageByOrdinal[entry.ordinal] or 0
            end
            if count == 0 then
                addError(report, "key_action_consequence_missing:" .. tostring(entry.ordinal))
            elseif count > 1 then
                addError(report, "key_action_consequence_duplicate:" .. tostring(entry.ordinal))
            end
        end
    elseif type(contract.components) == "table" and provenConsequenceCount < #contract.components then
        addError(report, "insufficient_proven_action_consequences")
    end
    if expectedProfile then
        for _, componentId in ipairs(expectedProfile.componentIds or {}) do
            if (componentCoverage[componentId] or 0) == 0 then
                addError(report, "component_consequence_missing:" .. componentId)
            end
        end
    end

    report.ok = #report.errors == 0
    return report.ok, report
end

return M
