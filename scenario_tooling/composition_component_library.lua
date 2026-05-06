local microLibrary = require("scenario_tooling.micro_interaction_library")
local predicateContract = require("scenario_tooling.predicate_contract")

local M = {
    VERSION = "scenario_composition_component_library.v1",
    COMPONENT_LIBRARY_ID = "composition_component_library_v1"
}
M.LIBRARY_ID = M.COMPONENT_LIBRARY_ID

-- CompositionComponentSpec v1:
-- A component is a local tactical mechanism fragment, not a scenario script.
-- It may declare roles, predicates, produced micro-interactions, and required
-- consequence outputs, but it must not encode a full solution or Red reply line.
local REQUIRED_FIELDS = {
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

local CONSEQUENCE_OUTPUTS = {
    winning_line = true,
    red_response = true,
    false_line = true,
    exactness = true,
    outcome = true,
    legal_move_set = true
}

local MACRO_TEMPLATE_FIELDS = {
    solutionOrder = true,
    turnSequence = true,
    winningLine = true,
    scriptedRedResponses = true,
    fullSolution = true,
    redScript = true,
    turnScript = true
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

local function hashText(text)
    local hash = 5381
    local i
    for i = 1, #text do
        hash = ((hash * 33) + string.byte(text, i)) % 4294967296
    end
    return string.format("%08x", hash)
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

local function hasAllowedConsequenceOutput(outputs)
    local i
    for i = 1, #(outputs or {}) do
        if CONSEQUENCE_OUTPUTS[outputs[i]] then
            return true
        end
    end
    return false
end

local function componentFingerprint(spec)
    return table.concat({
        stableString(spec.id),
        stableString(spec.version),
        stableString(spec.family),
        stableString(spec.role),
        table.concat(spec.producedMicroInteractions or {}, ","),
        table.concat(spec.requiredPredicates or {}, ","),
        table.concat(spec.consequenceOutputs or {}, ",")
    }, "|")
end

local COMPONENTS = {
    {
        id = "support_pressure_answer",
        version = "1.0.0",
        family = "pressure_response",
        role = "answer real Red pressure on an enabling support before the payoff path collapses",
        involvedUnits = { "blue_support", "red_pressure", "blue_finisher" },
        preconditions = {
            "red_pressure has a deterministic policy move+attack against blue_support if Blue skips setup",
            "blue_support is critical to at least one downstream component",
            "opening attack on red_pressure is not free or immediately available"
        },
        producedMicroInteractions = { "SUPPORT_CELL_GAIN", "RED_ATTACKS_SUPPORT" },
        requiredPredicates = {
            "critical_blue_unit",
            "real_pressure",
            "position_gained",
            "prevents_micro_interaction",
            "non_decorative_micro"
        },
        consequenceOutputs = { "red_response", "false_line", "winning_line" },
        ablationSubject = "red_support_attack_option",
        incompatibilities = {
            "pressure_same_as_contact_blocker",
            "pressure_free_to_remove_on_opening"
        },
        evidenceRequirements = {
            "policy_plan_kills_or_disables_support_on_false_line",
            "support_action_changes_legal_or_policy response",
            "pressure_unit_id_distinct_from_blocker_unit_id"
        },
        fixtureKeys = {
            "fixture.component.support_pressure_answer.true",
            "fixture.component.support_pressure_answer.false"
        }
    },
    {
        id = "contact_blocker_clear",
        version = "1.0.0",
        family = "access_lock",
        role = "remove or neutralize a blocker occupying the finisher contact/access cell",
        involvedUnits = { "blue_support", "blue_finisher", "red_blocker", "red_commandant" },
        preconditions = {
            "red_blocker occupies or controls a required finisher access cell",
            "blue_finisher cannot reach payoff contact before blocker is resolved",
            "blue_support action changes the blocker/access legal move set"
        },
        producedMicroInteractions = { "SUPPORT_CELL_GAIN", "ORDER_DEPENDENCY" },
        requiredPredicates = {
            "required_cell",
            "required_line",
            "position_gained",
            "non_decorative_micro"
        },
        consequenceOutputs = { "legal_move_set", "winning_line", "false_line" },
        ablationSubject = "contact_blocker_access_lock",
        incompatibilities = {
            "blocker_already_absent",
            "finisher_contact_already_free",
            "blocker_same_as_pressure_unit"
        },
        evidenceRequirements = {
            "blocker_present_before_component",
            "blocker_absent_or_accessible_after_component",
            "finisher_required_cell_changes_after_component"
        },
        fixtureKeys = {
            "fixture.component.contact_blocker_clear.true",
            "fixture.component.contact_blocker_clear.false"
        }
    },
    {
        id = "finisher_interceptor_clear",
        version = "1.0.0",
        family = "threat_screen",
        role = "use support tempo to neutralize a Red interceptor that would remove the critical finisher",
        involvedUnits = { "blue_support", "blue_finisher", "red_interceptor", "red_commandant" },
        preconditions = {
            "red_interceptor can kill or disable blue_finisher if Blue skips support interception",
            "blue_support starts outside the interception cell",
            "opening attack on red_interceptor is not immediately available"
        },
        producedMicroInteractions = { "SUPPORT_CELL_GAIN", "RED_ATTACKS_FINISHER", "ORDER_DEPENDENCY" },
        requiredPredicates = {
            "critical_blue_unit",
            "real_pressure",
            "prevents_micro_interaction",
            "required_line",
            "non_decorative_micro"
        },
        consequenceOutputs = { "red_response", "false_line", "winning_line", "legal_move_set" },
        ablationSubject = "red_finisher_interceptor_option",
        incompatibilities = {
            "interceptor_already_absent",
            "interceptor_free_to_remove_on_opening",
            "finisher_not_critical"
        },
        evidenceRequirements = {
            "policy_plan_kills_finisher_on_false_line",
            "support_intercept_action_removes_or_disables_interceptor",
            "finisher_payoff_fails_when_interceptor_remains"
        },
        fixtureKeys = {
            "fixture.component.finisher_interceptor_clear.true",
            "fixture.component.finisher_interceptor_clear.false"
        }
    },
    {
        id = "finisher_staging_gain",
        version = "1.0.0",
        family = "position_gain",
        role = "move the finisher to an earned staging cell that makes the final access cell reachable later",
        involvedUnits = { "blue_finisher", "red_pressure", "red_commandant" },
        preconditions = {
            "finisher starts outside the final payoff cell",
            "staging cell is useful only after earlier components resolve",
            "staging does not already produce a legal Commandant kill"
        },
        producedMicroInteractions = { "FINISHER_CELL_GAIN", "ORDER_DEPENDENCY" },
        requiredPredicates = {
            "position_gained",
            "required_cell",
            "required_line",
            "free_finisher_move",
            "non_decorative_micro"
        },
        consequenceOutputs = { "legal_move_set", "exactness", "winning_line" },
        ablationSubject = "finisher_positioning_step",
        incompatibilities = {
            "free_finisher_move_and_shoot",
            "staging_cell_equivalent_to_start",
            "staging_already_wins"
        },
        evidenceRequirements = {
            "final_contact_unreachable_before_staging",
            "final_contact_reachable_after_staging_and_policy_response",
            "Commandant_attack_illegal_from_staging"
        },
        fixtureKeys = {
            "fixture.component.finisher_staging_gain.true",
            "fixture.component.finisher_staging_gain.false"
        }
    },
    {
        id = "exact_contact_payoff",
        version = "1.0.0",
        family = "payoff_exactness",
        role = "convert the earned final cell into the only exact Commandant kill window",
        involvedUnits = { "blue_finisher", "red_commandant" },
        preconditions = {
            "finisher is not yet on the final payoff cell",
            "Commandant attack is illegal before final cell gain",
            "Commandant HP is inside the declared finisher payoff window"
        },
        producedMicroInteractions = { "FINISHER_CELL_GAIN", "HP_EXACT_WINDOW" },
        requiredPredicates = {
            "critical_blue_unit",
            "required_cell",
            "required_line",
            "position_gained",
            "non_decorative_micro"
        },
        consequenceOutputs = { "outcome", "exactness", "winning_line" },
        ablationSubject = "final_payoff_window",
        incompatibilities = {
            "commandant_already_dead",
            "attack_legal_before_payoff_cell",
            "payoff_not_exact"
        },
        evidenceRequirements = {
            "outcome_before_payoff_is_not_blue_win",
            "outcome_after_payoff_is_blue_win",
            "payoff_attack_actor_is_finisher"
        },
        fixtureKeys = {
            "fixture.component.exact_contact_payoff.true",
            "fixture.component.exact_contact_payoff.false"
        }
    },
    {
        id = "wrong_target_tempo_branch",
        version = "1.0.0",
        family = "false_line",
        role = "provide a plausible but losing target or branch that consumes exact tempo",
        involvedUnits = { "blue_finisher", "blue_support", "red_false_target", "red_commandant" },
        preconditions = {
            "false target or branch is legal or strategically plausible in the current local state",
            "taking the branch changes remaining tempo or exactness",
            "solver proves the branch cannot still win inside the horizon"
        },
        producedMicroInteractions = { "WRONG_TARGET_TEMPO_LOSS" },
        requiredPredicates = {
            "gains_time",
            "required_line",
            "prevents_micro_interaction",
            "non_decorative_micro"
        },
        consequenceOutputs = { "false_line", "exactness", "winning_line" },
        ablationSubject = "target_choice_constraint",
        incompatibilities = {
            "all_targets_equivalent",
            "false_branch_still_forced_win",
            "false_target_not_legal_or_not_plausible"
        },
        evidenceRequirements = {
            "false_line_replays_or_fails_legally",
            "false_line_proven_losing",
            "false_branch_changes_tempo_or_exactness"
        },
        fixtureKeys = {
            "fixture.component.wrong_target_tempo_branch.true",
            "fixture.component.wrong_target_tempo_branch.false"
        }
    },
    {
        id = "dual_rock_lock_chain",
        version = "1.0.0",
        family = "board_lock_chain",
        role = "convert two independent Rock locks in sequence before a ranged finisher line becomes usable",
        involvedUnits = { "blue_support", "blue_finisher", "lower_rock_lock", "upper_rock_lock", "red_commandant" },
        preconditions = {
            "two distinct Rock locks block the declared finisher line or support route",
            "blue_support must spend separate turns/actions to convert both locks",
            "finisher payoff is unavailable until both locks are converted"
        },
        producedMicroInteractions = { "SUPPORT_CELL_GAIN", "ROCK_AS_LOCK", "ORDER_DEPENDENCY", "LOS_OPEN_RANGED" },
        requiredPredicates = {
            "required_cell",
            "required_line",
            "position_gained",
            "prevents_micro_interaction",
            "non_decorative_micro"
        },
        consequenceOutputs = { "legal_move_set", "winning_line", "false_line", "exactness" },
        ablationSubject = "dual_rock_lock_chain",
        incompatibilities = {
            "one_lock_already_absent",
            "second_lock_decorative",
            "single_action_opens_both_locks",
            "finisher_line_already_open"
        },
        evidenceRequirements = {
            "lower_rock_present_before_first_conversion",
            "upper_rock_present_after_first_conversion",
            "both_rocks_absent_before_final_payoff",
            "two_turn_bound_fails_when either lock remains"
        },
        fixtureKeys = {
            "fixture.component.dual_rock_lock_chain.true",
            "fixture.component.dual_rock_lock_chain.false"
        }
    },
    {
        id = "rock_lock_conversion",
        version = "1.0.0",
        family = "board_lock_key",
        role = "convert a Rock-locked lane or access cell into a necessary tactical opening",
        involvedUnits = { "neutral_rock", "blue_support", "blue_finisher", "red_commandant" },
        preconditions = {
            "neutral_rock occupies or blocks a required lane, path, or payoff support cell",
            "blue_support can change the Rock lock state through a legal action",
            "finisher payoff is unavailable before the Rock lock is converted"
        },
        producedMicroInteractions = { "SUPPORT_CELL_GAIN", "ROCK_AS_LOCK" },
        requiredPredicates = {
            "required_cell",
            "required_line",
            "prevents_micro_interaction",
            "non_decorative_micro"
        },
        consequenceOutputs = { "legal_move_set", "winning_line", "false_line" },
        ablationSubject = "rock_lock_conversion",
        incompatibilities = {
            "rock_irrelevant_to_line",
            "lane_already_open",
            "lock_state_not_changed"
        },
        evidenceRequirements = {
            "rock_present_before_component",
            "rock_absent_or_lock_converted_after_component",
            "proof_or_false_line_changes_when_rock_lock_is_removed_or_ignored"
        },
        fixtureKeys = {
            "fixture.component.rock_lock_conversion.true",
            "fixture.component.rock_lock_conversion.false"
        }
    },
    {
        id = "los_open_ranged_lane",
        version = "1.0.0",
        family = "line_setup",
        role = "open a required ranged or artillery line that makes the finisher payoff legal",
        involvedUnits = { "blue_support", "blue_finisher", "red_commandant", "line_blocker" },
        preconditions = {
            "ranged or artillery finisher lacks legal Commandant line before setup",
            "support action changes line/path occupancy or required attack cell reachability",
            "opened line is useful only after the local lock/key interaction resolves"
        },
        producedMicroInteractions = { "LOS_OPEN_RANGED" },
        requiredPredicates = {
            "required_cell",
            "required_line",
            "position_gained",
            "non_decorative_micro"
        },
        consequenceOutputs = { "legal_move_set", "exactness", "winning_line" },
        ablationSubject = "support_lane_open_action",
        incompatibilities = {
            "lane_already_open",
            "support_action_cosmetic",
            "all_finish_cells_equivalent"
        },
        evidenceRequirements = {
            "commandant_attack_illegal_before_los_opening",
            "commandant_attack_or_required_finisher_cell_legal_after_los_opening",
            "opened_line_changes_exactness_or_winning_line"
        },
        fixtureKeys = {
            "fixture.component.los_open_ranged_lane.true",
            "fixture.component.los_open_ranged_lane.false"
        }
    }
}

local COMPONENT_BY_ID = {}
do
    local fingerprints = {}
    local i
    for i = 1, #COMPONENTS do
        COMPONENT_BY_ID[COMPONENTS[i].id] = COMPONENTS[i]
        fingerprints[i] = componentFingerprint(COMPONENTS[i])
    end
    M.LIBRARY_HASH = hashText(table.concat(fingerprints, "||"))
end

function M.isScenarioOnly()
    return true
end

function M.isMacroTemplate(spec)
    if type(spec) ~= "table" then
        return false
    end
    local field
    for field in pairs(MACRO_TEMPLATE_FIELDS) do
        if spec[field] ~= nil then
            return true
        end
    end
    return false
end

function M.listComponents()
    local out = {}
    local i
    for i = 1, #COMPONENTS do
        out[i] = cloneValue(COMPONENTS[i])
    end
    return out
end

function M.getComponent(id)
    local spec = COMPONENT_BY_ID[id]
    if not spec then
        return nil
    end
    return cloneValue(spec)
end

function M.validateComponent(component)
    local spec = component
    if type(component) == "string" then
        spec = COMPONENT_BY_ID[component]
    end
    local report = {
        id = type(spec) == "table" and spec.id or component,
        ok = true,
        errors = {}
    }
    if type(spec) ~= "table" then
        report.errors[#report.errors + 1] = "component_missing"
        report.ok = false
        return false, report
    end

    local i
    for i = 1, #REQUIRED_FIELDS do
        local field = REQUIRED_FIELDS[i]
        if not nonEmpty(spec[field]) then
            report.errors[#report.errors + 1] = "missing_or_empty_field:" .. field
        end
    end

    if M.isMacroTemplate(spec) then
        report.errors[#report.errors + 1] = "macro_template_fields_forbidden"
    end

    for _, microId in ipairs(spec.producedMicroInteractions or {}) do
        if not microLibrary.getMicroInteraction(microId) then
            report.errors[#report.errors + 1] = "unknown_micro_interaction:" .. tostring(microId)
        end
    end

    for _, predicateName in ipairs(spec.requiredPredicates or {}) do
        if not predicateContract.getPredicate(predicateName) then
            report.errors[#report.errors + 1] = "unknown_required_predicate:" .. tostring(predicateName)
        end
    end

    if not hasAllowedConsequenceOutput(spec.consequenceOutputs or {}) then
        report.errors[#report.errors + 1] = "consequence_outputs_missing_required_key"
    end

    report.ok = #report.errors == 0
    return report.ok, report
end

function M.validateLibrary()
    local reports = {}
    local ok = true
    local seen = {}
    local i
    for i = 1, #COMPONENTS do
        local id = COMPONENTS[i].id
        if seen[id] then
            ok = false
            reports[#reports + 1] = {
                id = id,
                ok = false,
                errors = { "duplicate_component_id" }
            }
        else
            seen[id] = true
        end
        local valid, report = M.validateComponent(COMPONENTS[i])
        reports[#reports + 1] = report
        if not valid then
            ok = false
        end
    end
    return ok, reports
end

return M
