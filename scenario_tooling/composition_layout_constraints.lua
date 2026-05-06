local compositionComposer = require("scenario_tooling.composition_composer")

local M = {
    VERSION = "scenario_composition_layout_constraints.v1",
    CONSTRAINTS_ID = "composition_layout_constraints_v1"
}

local BOARD_MIN = 1
local BOARD_MAX = 8

local REQUIRED_SPEC_FIELDS = {
    "id",
    "version",
    "profileId",
    "variant",
    "board",
    "cells",
    "unitRoles",
    "requiredCellRefs",
    "criticalBlueUnitIds",
    "constraints"
}

local FORBIDDEN_MACRO_FIELDS = {
    solutionOrder = true,
    turnSequence = true,
    winningLine = true,
    scriptedRedResponses = true,
    fullSolution = true,
    redScript = true,
    turnScript = true
}

local KNOWN_CONSTRAINT_TYPES = {
    legal_move_required = true,
    legal_move_forbidden_at_start = true,
    legal_attack_forbidden_at_start = true,
    legal_attack_required_after_cell_gain = true,
    policy_outcome_required = true,
    role_unit_distinct = true,
    legal_move_required_after_red_turn = true,
    legal_move_required_after_staging_and_red_turn = true,
    legal_attack_required_after_contact = true,
    legal_attack_required_after_los_opening = true
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

local function stableString(value)
    if value == nil then
        return ""
    end
    if type(value) == "number" then
        return string.format("%.12g", value)
    end
    return tostring(value)
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

local function inBounds(board, cell)
    if type(cell) ~= "table" then
        return false
    end
    local rows = tonumber(board and board.rows) or BOARD_MAX
    local cols = tonumber(board and board.cols) or BOARD_MAX
    local row = tonumber(cell.row)
    local col = tonumber(cell.col)
    return row ~= nil
        and col ~= nil
        and row >= BOARD_MIN
        and col >= BOARD_MIN
        and row <= rows
        and col <= cols
end

local function cellKey(cell)
    return tostring(tonumber(cell and cell.row)) .. "," .. tostring(tonumber(cell and cell.col))
end

local function addError(report, code)
    report.errors[#report.errors + 1] = code
end

local function cellByRef(spec, ref)
    if type(spec) ~= "table" or type(spec.cells) ~= "table" then
        return nil
    end
    return spec.cells[ref]
end

local function unitRoleById(spec)
    local roles = {}
    for _, role in ipairs(spec and spec.unitRoles or {}) do
        if type(role) == "table" and type(role.id) == "string" then
            roles[role.id] = role
        end
    end
    return roles
end

local LAYOUT_SPECS = {
    {
        id = "layout.composite_support_pressure_crusher_contact.baseline.v1",
        version = "1.0.0",
        profileId = "composite_support_pressure_crusher_contact",
        variant = "baseline",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 4 },
            contact = { row = 3, col = 4 },
            finisherStart = { row = 7, col = 4 },
            finisherStaging = { row = 5, col = 4 },
            supportStart = { row = 5, col = 5 },
            supportKey = { row = 3, col = 5 },
            contactBlocker = { row = 3, col = 4 },
            pressureStart = { row = 5, col = 7 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Earthstalker", startCellRef = "supportStart", role = "support" },
            { id = "blue_finisher", player = "blue", unitType = "Crusher", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "red_contact_blocker", player = "red", unitType = "Bastion", startCellRef = "contactBlocker", role = "contact_blocker" },
            { id = "red_support_threat", player = "red", unitType = "Earthstalker", startCellRef = "pressureStart", role = "support_pressure" }
        },
        requiredCellRefs = {
            "supportKey",
            "contact"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_setup_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_attack_blocker_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "red_contact_blocker"
            },
            {
                id = "support_cannot_attack_pressure_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "red_support_threat"
            },
            {
                id = "finisher_cannot_enter_contact_at_start",
                type = "legal_move_forbidden_at_start",
                actorId = "blue_finisher",
                toCellRef = "contact"
            },
            {
                id = "pressure_blocker_separate_units",
                type = "role_unit_distinct",
                leftUnitId = "red_support_threat",
                rightUnitId = "red_contact_blocker"
            },
            {
                id = "pressure_punishes_pass",
                type = "policy_outcome_required",
                policyId = "scenario_red_policy",
                ifBlueAction = "end_turn",
                targetUnitId = "blue_a_support",
                requiredOutcome = "target_removed"
            },
            {
                id = "support_clears_contact_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "red_contact_blocker",
                requiredFromCellRef = "supportKey"
            },
            {
                id = "finisher_staging_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_finisher",
                toCellRef = "finisherStaging"
            },
            {
                id = "contact_payoff_requires_staging",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "contact"
            },
            {
                id = "commandant_payoff_after_contact",
                type = "legal_attack_required_after_contact",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    },
    {
        id = "layout.crusher_contact_breach.baseline.v1",
        version = "1.0.0",
        profileId = "crusher_contact_breach",
        variant = "baseline",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 4 },
            contact = { row = 3, col = 4 },
            finisherStart = { row = 7, col = 4 },
            finisherStaging = { row = 5, col = 4 },
            supportStart = { row = 5, col = 5 },
            supportKey = { row = 3, col = 5 },
            contactBlocker = { row = 3, col = 4 },
            pressureDecoy = { row = 8, col = 8 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Earthstalker", startCellRef = "supportStart", role = "support" },
            { id = "blue_finisher", player = "blue", unitType = "Crusher", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "red_contact_blocker", player = "red", unitType = "Earthstalker", startCellRef = "contactBlocker", role = "contact_blocker" },
            { id = "red_decoy", player = "red", unitType = "Wingstalker", startCellRef = "pressureDecoy", role = "false_target" }
        },
        requiredCellRefs = {
            "supportKey",
            "contact"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_setup_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_attack_blocker_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "red_contact_blocker"
            },
            {
                id = "finisher_cannot_enter_contact_at_start",
                type = "legal_move_forbidden_at_start",
                actorId = "blue_finisher",
                toCellRef = "contact"
            },
            {
                id = "support_clears_contact_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "red_contact_blocker",
                requiredFromCellRef = "supportKey"
            },
            {
                id = "finisher_staging_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_finisher",
                toCellRef = "finisherStaging"
            },
            {
                id = "contact_payoff_requires_staging",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "contact"
            },
            {
                id = "commandant_payoff_after_contact",
                type = "legal_attack_required_after_contact",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    },
    {
        id = "layout.support_reposition_rock_los_finish.left_lane.v1",
        version = "1.0.0",
        profileId = "support_reposition_rock_los_finish",
        variant = "left_lane",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 5 },
            rock = { row = 2, col = 4 },
            attack = { row = 2, col = 2 },
            finisherStart = { row = 6, col = 2 },
            finisherStaging = { row = 3, col = 2 },
            decoy = { row = 6, col = 5 },
            supportStart = { row = 3, col = 6 },
            supportKey = { row = 2, col = 6 },
            supportThreat = { row = 5, col = 6 },
            shortcutBlocker = { row = 3, col = 5 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Artillery", startCellRef = "supportStart", role = "support" },
            { id = "blue_finisher", player = "blue", unitType = "Cloudstriker", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "red_decoy", player = "red", unitType = "Crusher", startCellRef = "decoy", role = "false_target" },
            { id = "neutral_rock", player = "neutral", unitType = "Rock", startCellRef = "rock", role = "rock_lock" },
            { id = "neutral_shortcut_rock", player = "neutral", unitType = "Rock", startCellRef = "shortcutBlocker", role = "shortcut_lock" }
        },
        requiredCellRefs = {
            "supportKey",
            "attack"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_setup_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_clear_rock_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "neutral_rock"
            },
            {
                id = "finisher_cannot_enter_los_cell_at_start",
                type = "legal_move_forbidden_at_start",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "support_clears_rock_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "neutral_rock",
                requiredFromCellRef = "supportKey"
            },
            {
                id = "finisher_staging_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_finisher",
                toCellRef = "finisherStaging"
            },
            {
                id = "los_cell_requires_staging",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "commandant_payoff_after_los_cell",
                type = "legal_attack_required_after_los_opening",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    },
    {
        id = "layout.support_reposition_rock_los_finish.right_lane.v1",
        version = "1.0.0",
        profileId = "support_reposition_rock_los_finish",
        variant = "right_lane",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 4 },
            rock = { row = 2, col = 5 },
            attack = { row = 2, col = 7 },
            finisherStart = { row = 6, col = 7 },
            finisherStaging = { row = 3, col = 7 },
            decoy = { row = 6, col = 4 },
            supportStart = { row = 3, col = 3 },
            supportKey = { row = 2, col = 3 },
            supportThreat = { row = 5, col = 3 },
            shortcutBlocker = { row = 3, col = 4 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Artillery", startCellRef = "supportStart", role = "support" },
            { id = "blue_finisher", player = "blue", unitType = "Cloudstriker", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "red_decoy", player = "red", unitType = "Crusher", startCellRef = "decoy", role = "false_target" },
            { id = "neutral_rock", player = "neutral", unitType = "Rock", startCellRef = "rock", role = "rock_lock" },
            { id = "neutral_shortcut_rock", player = "neutral", unitType = "Rock", startCellRef = "shortcutBlocker", role = "shortcut_lock" }
        },
        requiredCellRefs = {
            "supportKey",
            "attack"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_setup_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_clear_rock_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "neutral_rock"
            },
            {
                id = "finisher_cannot_enter_los_cell_at_start",
                type = "legal_move_forbidden_at_start",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "support_clears_rock_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "neutral_rock",
                requiredFromCellRef = "supportKey"
            },
            {
                id = "finisher_staging_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_finisher",
                toCellRef = "finisherStaging"
            },
            {
                id = "los_cell_requires_staging",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "commandant_payoff_after_los_cell",
                type = "legal_attack_required_after_los_opening",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    },
    {
        id = "layout.support_under_real_red_pressure.left_lane.v1",
        version = "1.0.0",
        profileId = "support_under_real_red_pressure",
        variant = "left_lane",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 5 },
            rock = { row = 2, col = 4 },
            attack = { row = 2, col = 2 },
            finisherStart = { row = 6, col = 2 },
            finisherStaging = { row = 3, col = 2 },
            decoy = { row = 6, col = 5 },
            supportStart = { row = 3, col = 6 },
            supportKey = { row = 2, col = 6 },
            supportThreat = { row = 5, col = 6 },
            shortcutBlocker = { row = 3, col = 5 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Artillery", startCellRef = "supportStart", role = "support" },
            { id = "blue_finisher", player = "blue", unitType = "Cloudstriker", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "red_decoy", player = "red", unitType = "Crusher", startCellRef = "decoy", role = "false_target" },
            { id = "red_support_threat", player = "red", unitType = "Earthstalker", startCellRef = "supportThreat", role = "support_pressure" },
            { id = "neutral_rock", player = "neutral", unitType = "Rock", startCellRef = "rock", role = "rock_lock" },
            { id = "neutral_shortcut_rock", player = "neutral", unitType = "Rock", startCellRef = "shortcutBlocker", role = "shortcut_lock" }
        },
        requiredCellRefs = {
            "supportKey",
            "attack"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_setup_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_clear_rock_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "neutral_rock"
            },
            {
                id = "support_cannot_attack_pressure_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "red_support_threat"
            },
            {
                id = "pressure_punishes_pass",
                type = "policy_outcome_required",
                policyId = "scenario_red_policy",
                ifBlueAction = "end_turn",
                targetUnitId = "blue_a_support",
                requiredOutcome = "target_removed"
            },
            {
                id = "pressure_decoy_separate_units",
                type = "role_unit_distinct",
                leftUnitId = "red_support_threat",
                rightUnitId = "red_decoy"
            },
            {
                id = "finisher_cannot_enter_los_cell_at_start",
                type = "legal_move_forbidden_at_start",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "support_clears_rock_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "neutral_rock",
                requiredFromCellRef = "supportKey"
            },
            {
                id = "finisher_staging_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_finisher",
                toCellRef = "finisherStaging"
            },
            {
                id = "los_cell_requires_staging",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "commandant_payoff_after_los_cell",
                type = "legal_attack_required_after_los_opening",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    },
    {
        id = "layout.support_under_real_red_pressure.right_lane.v1",
        version = "1.0.0",
        profileId = "support_under_real_red_pressure",
        variant = "right_lane",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 4 },
            rock = { row = 2, col = 5 },
            attack = { row = 2, col = 7 },
            finisherStart = { row = 6, col = 7 },
            finisherStaging = { row = 3, col = 7 },
            decoy = { row = 6, col = 4 },
            supportStart = { row = 3, col = 3 },
            supportKey = { row = 2, col = 3 },
            supportThreat = { row = 5, col = 3 },
            shortcutBlocker = { row = 3, col = 4 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Artillery", startCellRef = "supportStart", role = "support" },
            { id = "blue_finisher", player = "blue", unitType = "Cloudstriker", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "red_decoy", player = "red", unitType = "Crusher", startCellRef = "decoy", role = "false_target" },
            { id = "red_support_threat", player = "red", unitType = "Earthstalker", startCellRef = "supportThreat", role = "support_pressure" },
            { id = "neutral_rock", player = "neutral", unitType = "Rock", startCellRef = "rock", role = "rock_lock" },
            { id = "neutral_shortcut_rock", player = "neutral", unitType = "Rock", startCellRef = "shortcutBlocker", role = "shortcut_lock" }
        },
        requiredCellRefs = {
            "supportKey",
            "attack"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_setup_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_clear_rock_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "neutral_rock"
            },
            {
                id = "support_cannot_attack_pressure_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "red_support_threat"
            },
            {
                id = "pressure_punishes_pass",
                type = "policy_outcome_required",
                policyId = "scenario_red_policy",
                ifBlueAction = "end_turn",
                targetUnitId = "blue_a_support",
                requiredOutcome = "target_removed"
            },
            {
                id = "pressure_decoy_separate_units",
                type = "role_unit_distinct",
                leftUnitId = "red_support_threat",
                rightUnitId = "red_decoy"
            },
            {
                id = "finisher_cannot_enter_los_cell_at_start",
                type = "legal_move_forbidden_at_start",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "support_clears_rock_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "neutral_rock",
                requiredFromCellRef = "supportKey"
            },
            {
                id = "finisher_staging_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_finisher",
                toCellRef = "finisherStaging"
            },
            {
                id = "los_cell_requires_staging",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "commandant_payoff_after_los_cell",
                type = "legal_attack_required_after_los_opening",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    },
    {
        id = "layout.support_intercepts_finisher_threat_artillery_finish.baseline.v1",
        version = "1.0.0",
        profileId = "support_intercepts_finisher_threat_artillery_finish",
        variant = "baseline",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 3 },
            artilleryFinal = { row = 5, col = 3 },
            artilleryStaging = { row = 6, col = 3 },
            finisherStart = { row = 7, col = 3 },
            supportStart = { row = 7, col = 2 },
            supportKey = { row = 6, col = 2 },
            interceptor = { row = 6, col = 3 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Bastion", startCellRef = "supportStart", role = "support_interceptor" },
            { id = "blue_finisher", player = "blue", unitType = "Artillery", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "red_interceptor", player = "red", unitType = "Earthstalker", startCellRef = "interceptor", role = "finisher_pressure" }
        },
        requiredCellRefs = {
            "supportKey",
            "artilleryFinal"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_intercept_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_attack_interceptor_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "red_interceptor"
            },
            {
                id = "interceptor_punishes_pass",
                type = "policy_outcome_required",
                policyId = "scenario_red_policy",
                ifBlueAction = "end_turn",
                targetUnitId = "blue_finisher",
                requiredOutcome = "target_removed"
            },
            {
                id = "support_clears_interceptor_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "red_interceptor",
                requiredFromCellRef = "supportKey"
            },
            {
                id = "artillery_staging_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_finisher",
                toCellRef = "artilleryStaging"
            },
            {
                id = "artillery_final_cell_requires_staging",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "artilleryFinal"
            },
            {
                id = "commandant_payoff_after_final_cell",
                type = "legal_attack_required_after_los_opening",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    },
    {
        id = "layout.dual_rock_lock_ranged_finish.baseline.v1",
        version = "1.0.0",
        profileId = "dual_rock_lock_ranged_finish",
        variant = "baseline",
        board = { rows = 8, cols = 8 },
        cells = {
            commandant = { row = 2, col = 4 },
            lowerRock = { row = 4, col = 4 },
            upperRock = { row = 3, col = 4 },
            attack = { row = 5, col = 4 },
            finisherStart = { row = 8, col = 4 },
            supportStart = { row = 5, col = 2 },
            supportLowerKey = { row = 4, col = 2 },
            supportUpperKey = { row = 3, col = 2 }
        },
        unitRoles = {
            { id = "blue_a_support", player = "blue", unitType = "Artillery", startCellRef = "supportStart", role = "dual_lock_support" },
            { id = "blue_finisher", player = "blue", unitType = "Cloudstriker", startCellRef = "finisherStart", role = "finisher" },
            { id = "red_commandant", player = "red", unitType = "Commandant", startCellRef = "commandant", role = "objective" },
            { id = "neutral_lower_rock", player = "neutral", unitType = "Rock", startCellRef = "lowerRock", role = "lower_rock_lock" },
            { id = "neutral_upper_rock", player = "neutral", unitType = "Rock", startCellRef = "upperRock", role = "upper_rock_lock" }
        },
        requiredCellRefs = {
            "supportLowerKey",
            "supportUpperKey",
            "attack"
        },
        criticalBlueUnitIds = {
            "blue_finisher",
            "blue_a_support"
        },
        constraints = {
            {
                id = "support_lower_setup_move_exists",
                type = "legal_move_required",
                actorId = "blue_a_support",
                toCellRef = "supportLowerKey",
                microInteractionId = "SUPPORT_CELL_GAIN"
            },
            {
                id = "support_cannot_clear_lower_rock_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "neutral_lower_rock"
            },
            {
                id = "support_cannot_clear_upper_rock_at_start",
                type = "legal_attack_forbidden_at_start",
                actorId = "blue_a_support",
                targetId = "neutral_upper_rock"
            },
            {
                id = "support_clears_lower_rock_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "neutral_lower_rock",
                requiredFromCellRef = "supportLowerKey"
            },
            {
                id = "support_upper_setup_move_required",
                type = "legal_move_required_after_red_turn",
                actorId = "blue_a_support",
                toCellRef = "supportUpperKey"
            },
            {
                id = "support_clears_upper_rock_after_setup",
                type = "legal_attack_required_after_cell_gain",
                actorId = "blue_a_support",
                targetId = "neutral_upper_rock",
                requiredFromCellRef = "supportUpperKey"
            },
            {
                id = "finisher_final_cell_requires_dual_lock",
                type = "legal_move_required_after_staging_and_red_turn",
                actorId = "blue_finisher",
                toCellRef = "attack"
            },
            {
                id = "commandant_payoff_after_dual_los_opening",
                type = "legal_attack_required_after_los_opening",
                actorId = "blue_finisher",
                targetId = "red_commandant"
            }
        }
    }
}

local SPEC_BY_ID = {}
local SPECS_BY_PROFILE = {}
do
    for _, spec in ipairs(LAYOUT_SPECS) do
        SPEC_BY_ID[spec.id] = spec
        SPECS_BY_PROFILE[spec.profileId] = SPECS_BY_PROFILE[spec.profileId] or {}
        SPECS_BY_PROFILE[spec.profileId][#SPECS_BY_PROFILE[spec.profileId] + 1] = spec
    end
end

local function resolveSpec(idOrSpec, variant)
    if type(idOrSpec) == "table" then
        return idOrSpec
    end
    local id = stableString(idOrSpec)
    if SPEC_BY_ID[id] then
        return SPEC_BY_ID[id]
    end
    local specs = SPECS_BY_PROFILE[id]
    if not specs then
        return nil
    end
    local wantedVariant = variant or "baseline"
    for _, spec in ipairs(specs) do
        if spec.variant == wantedVariant then
            return spec
        end
    end
    return specs[1]
end

local function translatedSpec(source, rowOffset, colOffset)
    local spec = cloneValue(source)
    rowOffset = math.floor(tonumber(rowOffset) or 0)
    colOffset = math.floor(tonumber(colOffset) or 0)
    if rowOffset == 0 and colOffset == 0 then
        spec.rowOffset = 0
        spec.colOffset = 0
        return spec
    end
    spec.id = table.concat({
        stableString(source.id),
        "offset",
        "r" .. tostring(rowOffset),
        "c" .. tostring(colOffset)
    }, ".")
    spec.variant = table.concat({
        stableString(source.variant or "baseline"),
        "offset",
        "r" .. tostring(rowOffset),
        "c" .. tostring(colOffset)
    }, ".")
    spec.rowOffset = rowOffset
    spec.colOffset = colOffset
    local _, cell
    for _, cell in pairs(spec.cells or {}) do
        cell.row = tonumber(cell.row) + rowOffset
        cell.col = tonumber(cell.col) + colOffset
    end
    return spec
end

local function validateConstraint(spec, constraint, report, roles)
    if type(constraint) ~= "table" then
        addError(report, "constraint_invalid")
        return
    end
    if type(constraint.id) ~= "string" or constraint.id == "" then
        addError(report, "constraint_id_missing")
    end
    if not KNOWN_CONSTRAINT_TYPES[constraint.type] then
        addError(report, "constraint_type_unknown:" .. stableString(constraint.id))
    end
    if constraint.actorId ~= nil and not roles[constraint.actorId] then
        addError(report, "constraint_actor_unknown:" .. stableString(constraint.actorId))
    end
    if constraint.targetId ~= nil and not roles[constraint.targetId] then
        addError(report, "constraint_target_unknown:" .. stableString(constraint.targetId))
    end
    if constraint.targetUnitId ~= nil and not roles[constraint.targetUnitId] then
        addError(report, "constraint_target_unit_unknown:" .. stableString(constraint.targetUnitId))
    end
    if constraint.leftUnitId ~= nil and not roles[constraint.leftUnitId] then
        addError(report, "constraint_left_unit_unknown:" .. stableString(constraint.leftUnitId))
    end
    if constraint.rightUnitId ~= nil and not roles[constraint.rightUnitId] then
        addError(report, "constraint_right_unit_unknown:" .. stableString(constraint.rightUnitId))
    end
    if constraint.toCellRef ~= nil and not cellByRef(spec, constraint.toCellRef) then
        addError(report, "constraint_to_cell_unknown:" .. stableString(constraint.id))
    end
    if constraint.requiredFromCellRef ~= nil and not cellByRef(spec, constraint.requiredFromCellRef) then
        addError(report, "constraint_from_cell_unknown:" .. stableString(constraint.id))
    end
    if constraint.type == "role_unit_distinct" and constraint.leftUnitId == constraint.rightUnitId then
        addError(report, "constraint_units_not_distinct:" .. stableString(constraint.id))
    end
end

function M.isScenarioOnly()
    return true
end

function M.listLayoutSpecs()
    return cloneValue(LAYOUT_SPECS)
end

function M.getLayoutSpec(profileOrSpecId, variant)
    local spec = resolveSpec(profileOrSpecId, variant)
    if not spec then
        return nil
    end
    return cloneValue(spec)
end

function M.getBaselineLayoutSpec(profileId)
    return M.getLayoutSpec(profileId, "baseline")
end

function M.validateLayoutSpec(specOrId)
    local spec = resolveSpec(specOrId)
    local report = {
        id = type(spec) == "table" and spec.id or specOrId,
        ok = true,
        errors = {}
    }
    if type(spec) ~= "table" then
        addError(report, "layout_spec_missing")
        report.ok = false
        return false, report
    end

    for _, field in ipairs(REQUIRED_SPEC_FIELDS) do
        if not nonEmpty(spec[field]) then
            addError(report, "missing_or_empty_field:" .. field)
        end
    end

    for field in pairs(FORBIDDEN_MACRO_FIELDS) do
        if spec[field] ~= nil then
            addError(report, "macro_field_forbidden:" .. field)
        end
    end

    local profileOk = false
    if type(spec.profileId) == "string" and spec.profileId ~= "" then
        profileOk = compositionComposer.validateProfile(spec.profileId)
    end
    if not profileOk then
        addError(report, "profile_invalid:" .. stableString(spec.profileId))
    end

    if type(spec.board) ~= "table" or tonumber(spec.board.rows) ~= 8 or tonumber(spec.board.cols) ~= 8 then
        addError(report, "board_invalid")
    end

    local seenCells = {}
    for cellRef, cell in pairs(spec.cells or {}) do
        if not inBounds(spec.board, cell) then
            addError(report, "cell_out_of_bounds:" .. stableString(cellRef))
        else
            seenCells[cellKey(cell)] = (seenCells[cellKey(cell)] or 0) + 1
        end
    end

    local roles = unitRoleById(spec)
    local seenRoleIds = {}
    local seenStartCells = {}
    for _, role in ipairs(spec.unitRoles or {}) do
        if type(role) ~= "table" then
            addError(report, "unit_role_invalid")
        else
            if type(role.id) ~= "string" or role.id == "" then
                addError(report, "unit_role_id_missing")
            elseif seenRoleIds[role.id] then
                addError(report, "unit_role_duplicate:" .. role.id)
            else
                seenRoleIds[role.id] = true
            end
            if role.player ~= "blue" and role.player ~= "red" and role.player ~= "neutral" then
                addError(report, "unit_role_player_invalid:" .. stableString(role.id))
            end
            if type(role.unitType) ~= "string" or role.unitType == "" then
                addError(report, "unit_role_type_missing:" .. stableString(role.id))
            end
            local startCell = cellByRef(spec, role.startCellRef)
            if not startCell then
                addError(report, "unit_role_start_cell_unknown:" .. stableString(role.id))
            else
                local key = cellKey(startCell)
                if seenStartCells[key] then
                    addError(report, "unit_start_cell_duplicate:" .. stableString(role.id))
                else
                    seenStartCells[key] = role.id
                end
            end
        end
    end

    for _, ref in ipairs(spec.requiredCellRefs or {}) do
        if not cellByRef(spec, ref) then
            addError(report, "required_cell_unknown:" .. stableString(ref))
        end
    end

    for _, unitId in ipairs(spec.criticalBlueUnitIds or {}) do
        local role = roles[unitId]
        if not role then
            addError(report, "critical_blue_unit_unknown:" .. stableString(unitId))
        elseif role.player ~= "blue" then
            addError(report, "critical_blue_unit_not_blue:" .. stableString(unitId))
        end
    end

    local seenConstraints = {}
    for _, constraint in ipairs(spec.constraints or {}) do
        if type(constraint) == "table" and constraint.id ~= nil then
            if seenConstraints[constraint.id] then
                addError(report, "constraint_duplicate:" .. stableString(constraint.id))
            else
                seenConstraints[constraint.id] = true
            end
        end
        validateConstraint(spec, constraint, report, roles)
    end

    local pressureRole = roles.red_support_threat
    local blockerRole = roles.red_contact_blocker
    if pressureRole and blockerRole then
        if pressureRole.id == blockerRole.id then
            addError(report, "pressure_blocker_same_unit")
        end
        if pressureRole.startCellRef == blockerRole.startCellRef then
            addError(report, "pressure_blocker_same_start_cell")
        end
    end

    report.ok = #report.errors == 0
    return report.ok, report
end

function M.buildLayout(profileOrSpecId, opts)
    opts = type(opts) == "table" and opts or {}
    local spec = resolveSpec(profileOrSpecId, opts.variant)
    if not spec then
        return nil, "layout_spec_missing"
    end
    local ok, report = M.validateLayoutSpec(spec)
    if not ok then
        return nil, report
    end

    local layout = {
        layoutSpecId = spec.id,
        layoutSpecVersion = spec.version,
        layoutConstraintVersion = M.VERSION,
        profileId = spec.profileId,
        variant = spec.variant,
        rowOffset = tonumber(spec.rowOffset) or 0,
        colOffset = tonumber(spec.colOffset) or 0,
        requiredCells = {},
        criticalBlueUnitIds = cloneValue(spec.criticalBlueUnitIds),
        unitRoles = cloneValue(spec.unitRoles),
        constraints = cloneValue(spec.constraints)
    }
    for name, cell in pairs(spec.cells or {}) do
        layout[name] = {
            row = tonumber(cell.row),
            col = tonumber(cell.col)
        }
    end
    for _, ref in ipairs(spec.requiredCellRefs or {}) do
        local cell = cellByRef(spec, ref)
        layout.requiredCells[#layout.requiredCells + 1] = {
            row = tonumber(cell.row),
            col = tonumber(cell.col),
            ref = ref
        }
    end
    return layout
end

function M.buildBaselineLayout(profileId)
    return M.buildLayout(profileId, { variant = "baseline" })
end

function M.buildTranslatedLayout(profileId, rowOffset, colOffset)
    local baseline = resolveSpec(profileId, "baseline")
    if not baseline then
        return nil, "layout_spec_missing"
    end
    local spec = translatedSpec(baseline, rowOffset, colOffset)
    return M.buildLayout(spec)
end

function M.enumerateLayoutCandidates(profileId, opts)
    opts = type(opts) == "table" and opts or {}
    local offsets = opts.offsets or {
        { rowOffset = 0, colOffset = 0 },
        { rowOffset = 0, colOffset = -1 },
        { rowOffset = 0, colOffset = 1 }
    }
    local maxCandidates = tonumber(opts.maxCandidates) or #offsets
    local candidates = {}
    local rejected = {}
    for i = 1, #offsets do
        if #candidates >= maxCandidates then
            break
        end
        local offset = offsets[i] or {}
        local rowOffset = offset.rowOffset or offset.row or offset[1] or 0
        local colOffset = offset.colOffset or offset.col or offset[2] or 0
        local layout, err = M.buildTranslatedLayout(profileId, rowOffset, colOffset)
        if layout then
            candidates[#candidates + 1] = layout
        else
            rejected[#rejected + 1] = {
                rowOffset = rowOffset,
                colOffset = colOffset,
                reason = err
            }
        end
    end
    return candidates, rejected
end

return M
