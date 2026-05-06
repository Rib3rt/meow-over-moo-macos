local predicateContract = require("scenario_tooling.predicate_contract")

local M = {
    VERSION = "scenario_micro_interaction_library.v1",
    LIBRARY_ID = "step6_micro_interaction_library_v1"
}

local REQUIRED_FIELDS = {
    "id",
    "family",
    "involvedUnits",
    "preconditions",
    "effects",
    "tacticalTension",
    "plausibleFalseLine",
    "compatibility",
    "rejectionSignals",
    "requiredPredicates",
    "ablationSubject",
    "ablationMustChange",
    "fixtureKeys",
    "allowedFinisherFamilies"
}

local ABLATION_CHANGE_KEYS = {
    winning_line = true,
    false_line = true,
    red_response = true,
    exactness = true,
    fingerprint = true
}

local MACRO_TEMPLATE_FIELDS = {
    solutionOrder = true,
    turnSequence = true,
    winningLine = true,
    scriptedRedResponses = true
}

local REQUIRED_PREDICATE_SET = {}
local FROZEN_PROXY_SET = setmetatable({}, { __mode = "k" })
do
    local i
    for i = 1, #(predicateContract.requiredPredicates or {}) do
        REQUIRED_PREDICATE_SET[predicateContract.requiredPredicates[i]] = true
    end
end

local function shallowCopyArray(arr)
    local out = {}
    local i
    for i = 1, #arr do
        out[i] = arr[i]
    end
    return out
end

local function freezeArray(arr)
    local storage = shallowCopyArray(arr or {})
    local proxy = {}
    local mt = {
        __index = storage,
        __newindex = function()
            error("frozen_table", 2)
        end,
        __metatable = "frozen"
    }
    setmetatable(proxy, mt)
    FROZEN_PROXY_SET[proxy] = true
    return proxy
end

local function isFrozenArray(arr)
    return type(arr) == "table" and FROZEN_PROXY_SET[arr] == true
end

local function cloneValue(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    local k, v
    for k, v in pairs(value) do
        if type(v) == "table" then
            out[k] = cloneValue(v)
        else
            out[k] = v
        end
    end
    local i = 1
    while value[i] ~= nil do
        out[i] = cloneValue(value[i])
        i = i + 1
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

local MICRO_INTERACTIONS = {
    {
        id = "LOS_OPEN_RANGED",
        family = "line_setup",
        involvedUnits = { "blue_support", "blue_finisher", "red_blocker" },
        preconditions = "Ranged finisher lacks legal LOS; support can open one lane without losing finisher timing.",
        effects = "Opens exactly one legal ranged lane for finisher while preserving turn budget.",
        tacticalTension = "Support must spend action now, creating exposure if Red punishes immediately.",
        plausibleFalseLine = "Blue advances finisher first and runs into blocked or delayed shot window.",
        compatibility = "Works with ranged and artillery finishers when lane geometry is orthogonal.",
        rejectionSignals = { "lane_already_open", "support_action_cosmetic" },
        requiredPredicates = freezeArray({ "required_line", "required_cell", "non_decorative_micro" }),
        ablationSubject = "support_lane_open_action",
        ablationMustChange = { "winning_line", "false_line" },
        fixtureKeys = { "fixture.micro.los_open_ranged.true", "fixture.micro.los_open_ranged.false" },
        allowedFinisherFamilies = { "ranged", "artillery" }
    },
    {
        id = "FINISHER_CELL_GAIN",
        family = "position_gain",
        involvedUnits = { "blue_finisher", "red_threat" },
        preconditions = "Finisher starts outside legal finish cells and must gain one exact attack cell.",
        effects = "Finisher reaches a required cell that enables legal kill pressure this turn.",
        tacticalTension = "Cell gain can be punished if done before support timing or shield timing.",
        plausibleFalseLine = "Finisher takes a nearby but non-required cell and loses exact kill window.",
        compatibility = "Applicable across melee, ranged, and artillery finishers with cell constraints.",
        rejectionSignals = { "equivalent_cell_exists", "position_gain_not_required" },
        requiredPredicates = freezeArray({ "position_gained", "required_cell", "required_line" }),
        ablationSubject = "finisher_positioning_step",
        ablationMustChange = { "exactness", "winning_line" },
        fixtureKeys = { "fixture.micro.finisher_cell_gain.true", "fixture.micro.finisher_cell_gain.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    },
    {
        id = "SUPPORT_CELL_GAIN",
        family = "support_reposition",
        involvedUnits = { "blue_support", "blue_finisher", "red_pressure" },
        preconditions = "Support is not initially in enabling location and must reposition to unlock finisher plan.",
        effects = "Support reaches an enabling cell that changes feasible winning branches.",
        tacticalTension = "Support path can lose tempo if Red pressure is real and not cosmetic.",
        plausibleFalseLine = "Blue keeps support static and attempts direct damage race that fails.",
        compatibility = "Pairs with finishers needing setup utility rather than flat damage.",
        rejectionSignals = { "support_already_free", "support_move_only_cosmetic" },
        requiredPredicates = freezeArray({ "position_gained", "support_already_free", "non_decorative_micro" }),
        ablationSubject = "support_reposition_step",
        ablationMustChange = { "winning_line", "red_response" },
        fixtureKeys = { "fixture.micro.support_cell_gain.true", "fixture.micro.support_cell_gain.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    },
    {
        id = "RED_ATTACKS_SUPPORT",
        family = "pressure_response",
        involvedUnits = { "red_attacker", "blue_support", "blue_finisher" },
        preconditions = "Red has credible attack on support that can disrupt blue tactical sequence.",
        effects = "Forces blue to adapt order or protection to preserve win within limit.",
        tacticalTension = "Ignoring support pressure can collapse planned enabling interaction.",
        plausibleFalseLine = "Blue commits greedily to finisher line and loses support before payoff.",
        compatibility = "Valid when Red pressure alters best response set under same horizon.",
        rejectionSignals = { "cosmetic_red_pressure", "support_hit_does_not_change_outcome" },
        requiredPredicates = freezeArray({ "real_pressure", "gains_time", "prevents_micro_interaction" }),
        ablationSubject = "red_support_attack_option",
        ablationMustChange = { "red_response", "false_line" },
        fixtureKeys = { "fixture.micro.red_attacks_support.true", "fixture.micro.red_attacks_support.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    },
    {
        id = "RED_ATTACKS_FINISHER",
        family = "pressure_response",
        involvedUnits = { "red_interceptor", "blue_finisher", "blue_support" },
        preconditions = "Red has a credible move+attack or attack that can remove the critical finisher if Blue skips the intercept.",
        effects = "Forces Blue to spend support tempo neutralizing the interceptor before finisher staging.",
        tacticalTension = "The locally slow support action protects the only unit that can finish within the horizon.",
        plausibleFalseLine = "Blue advances the finisher first and Red removes it before the payoff cell is reached.",
        compatibility = "Works with exact finisher payoffs when the finisher is critical and fragile.",
        rejectionSignals = { "interceptor_cosmetic", "finisher_not_critical", "interceptor_free_to_remove" },
        requiredPredicates = freezeArray({ "critical_blue_unit", "real_pressure", "prevents_micro_interaction" }),
        ablationSubject = "red_finisher_interceptor_option",
        ablationMustChange = { "red_response", "false_line" },
        fixtureKeys = { "fixture.micro.red_attacks_finisher.true", "fixture.micro.red_attacks_finisher.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    },
    {
        id = "ROCK_AS_LOCK",
        family = "board_lock_key",
        involvedUnits = { "rock", "blue_support", "blue_finisher", "red_commandant" },
        preconditions = "Rock occupancy currently locks a lane/path that matters for tactical conversion.",
        effects = "Blue key action converts lock state and changes attack geometry or access.",
        tacticalTension = "Using a key action on rock trades tempo for structural access.",
        plausibleFalseLine = "Blue ignores lock and tries direct attack clock through blocked geometry.",
        compatibility = "Strong with ranged/artillery lanes and narrow melee access corridors.",
        rejectionSignals = { "rock_irrelevant_to_line", "lock_state_not_changed" },
        requiredPredicates = freezeArray({ "required_cell", "required_line", "non_decorative_micro" }),
        ablationSubject = "rock_lock_conversion",
        ablationMustChange = { "winning_line", "fingerprint" },
        fixtureKeys = { "fixture.micro.rock_as_lock.true", "fixture.micro.rock_as_lock.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    },
    {
        id = "WRONG_TARGET_TEMPO_LOSS",
        family = "target_selection",
        involvedUnits = { "blue_finisher", "blue_support", "red_decoy", "red_commandant" },
        preconditions = "Blue has at least one tempting non-commandant target that appears strong but loses tempo.",
        effects = "Correct target preserves exact turn budget while wrong target misses finish window.",
        tacticalTension = "Decoy damage can look locally optimal but globally fails objective timing.",
        plausibleFalseLine = "Blue spends attack on decoy and cannot recover mate distance.",
        compatibility = "Useful in scenarios with decoys and strict turn-bound objectives.",
        rejectionSignals = { "all_targets_equivalent", "tempo_not_changed" },
        requiredPredicates = freezeArray({ "gains_time", "required_line", "non_decorative_micro" }),
        ablationSubject = "target_choice_constraint",
        ablationMustChange = { "false_line", "exactness" },
        fixtureKeys = { "fixture.micro.wrong_target_tempo_loss.true", "fixture.micro.wrong_target_tempo_loss.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    },
    {
        id = "ORDER_DEPENDENCY",
        family = "action_order",
        involvedUnits = { "blue_support", "blue_finisher", "red_pressure" },
        preconditions = "Two blue actions are both legal but only one order preserves forced win.",
        effects = "Establishes local partial order requirement without encoding full scenario sequence.",
        tacticalTension = "Premature finisher action invites Red interruption before setup resolves.",
        plausibleFalseLine = "Blue inverts local order and drops required precondition before finish.",
        compatibility = "Common across mixed-unit tactical conversions with narrow timing windows.",
        rejectionSignals = { "order_equivalent", "order_changes_nothing" },
        requiredPredicates = freezeArray({ "required_line", "prevents_micro_interaction", "non_decorative_micro" }),
        ablationSubject = "local_order_constraint",
        ablationMustChange = { "winning_line", "red_response" },
        fixtureKeys = { "fixture.micro.order_dependency.true", "fixture.micro.order_dependency.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    },
    {
        id = "HP_EXACT_WINDOW",
        family = "hp_window",
        involvedUnits = { "blue_finisher", "blue_support", "red_commandant" },
        preconditions = "Commandant HP and blue damage distribution require exact setup before final hit.",
        effects = "Creates an exact HP window where only precise prior interaction enables finisher.",
        tacticalTension = "Over- or under-damaging early invalidates exact kill path.",
        plausibleFalseLine = "Blue frontloads damage and falls into non-lethal or mistimed end state.",
        compatibility = "Most visible with combined support+finisher damage packages.",
        rejectionSignals = { "hp_window_not_exact", "any_damage_order_wins" },
        requiredPredicates = freezeArray({ "required_line", "non_decorative_micro", "fingerprint_distinct" }),
        ablationSubject = "hp_window_exactness",
        ablationMustChange = { "exactness", "winning_line" },
        fixtureKeys = { "fixture.micro.hp_exact_window.true", "fixture.micro.hp_exact_window.false" },
        allowedFinisherFamilies = { "melee", "ranged", "artillery" }
    }
}

local MICRO_BY_ID = {}
do
    local i
    for i = 1, #MICRO_INTERACTIONS do
        MICRO_BY_ID[MICRO_INTERACTIONS[i].id] = MICRO_INTERACTIONS[i]
    end
end

local function specFingerprint(spec)
    local fields = {
        spec.id,
        spec.family,
        spec.ablationSubject,
        table.concat(spec.ablationMustChange or {}, ",")
    }
    return table.concat(fields, "|")
end

do
    local fp = {}
    local i
    for i = 1, #MICRO_INTERACTIONS do
        fp[i] = specFingerprint(MICRO_INTERACTIONS[i])
    end
    M.LIBRARY_HASH = hashText(table.concat(fp, "||"))
end

function M.isScenarioOnly()
    return true
end

function M.isMacroTemplate(spec)
    if type(spec) ~= "table" then
        return false
    end
    local field
    for field, _ in pairs(MACRO_TEMPLATE_FIELDS) do
        if spec[field] ~= nil then
            return true
        end
    end
    return false
end

function M.listMicroInteractions()
    local out = {}
    local i
    for i = 1, #MICRO_INTERACTIONS do
        out[i] = cloneValue(MICRO_INTERACTIONS[i])
    end
    return out
end

function M.getMicroInteraction(id)
    local spec = MICRO_BY_ID[id]
    if not spec then
        return nil
    end
    return cloneValue(spec)
end

local function nonEmpty(value)
    if type(value) == "string" then
        return value ~= ""
    end
    if type(value) == "table" then
        return next(value) ~= nil or value[1] ~= nil
    end
    return value ~= nil
end

local function hasRequiredAblationChange(keys)
    local i
    for i = 1, #keys do
        if ABLATION_CHANGE_KEYS[keys[i]] then
            return true
        end
    end
    return false
end

function M.validateMicroInteraction(id)
    local spec = MICRO_BY_ID[id]
    if not spec then
        return false, {
            id = id,
            ok = false,
            errors = { "unknown_micro_interaction" }
        }
    end

    local report = { id = id, ok = true, errors = {} }

    local i
    for i = 1, #REQUIRED_FIELDS do
        local field = REQUIRED_FIELDS[i]
        if not nonEmpty(spec[field]) then
            report.errors[#report.errors + 1] = "missing_or_empty_field:" .. field
        end
    end

    if not isFrozenArray(spec.requiredPredicates) then
        report.errors[#report.errors + 1] = "required_predicates_not_frozen"
    end

    local p = 1
    while spec.requiredPredicates[p] ~= nil do
        if not REQUIRED_PREDICATE_SET[spec.requiredPredicates[p]] then
            report.errors[#report.errors + 1] = "unknown_required_predicate:" .. tostring(spec.requiredPredicates[p])
        end
        p = p + 1
    end

    if not hasRequiredAblationChange(spec.ablationMustChange or {}) then
        report.errors[#report.errors + 1] = "ablation_must_change_missing_required_key"
    end

    if M.isMacroTemplate(spec) then
        report.errors[#report.errors + 1] = "macro_template_fields_forbidden"
    end

    if type(spec.rejectionSignals) ~= "table" or next(spec.rejectionSignals) == nil then
        report.errors[#report.errors + 1] = "rejection_signals_empty"
    end

    report.ok = #report.errors == 0
    return report.ok, report
end

function M.validateLibrary()
    local reports = {}
    local ok = true
    local i
    for i = 1, #MICRO_INTERACTIONS do
        local itemId = MICRO_INTERACTIONS[i].id
        local valid, report = M.validateMicroInteraction(itemId)
        reports[#reports + 1] = report
        if not valid then
            ok = false
        end
    end
    return ok, reports
end

return M
