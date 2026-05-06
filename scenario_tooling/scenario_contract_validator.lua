local M = {}

M.VERSION = "scenario_contract_validator.v0.1.0-step-0"

local function pickFirst(tbl, keys)
    if type(tbl) ~= "table" then
        return nil
    end
    local i
    for i = 1, #keys do
        local value = tbl[keys[i]]
        if value ~= nil then
            return value, keys[i]
        end
    end
    return nil
end

local function appendError(errors, code, message, path, evidence)
    errors[#errors + 1] = {
        code = code,
        message = message,
        path = path or "",
        evidence = evidence
    }
end

local function isBluePlayer(value)
    return value == 1 or value == "blue" or value == "Blue"
end

local function isRedPlayer(value)
    return value == 2 or value == "red" or value == "Red"
end

local function isNeutralPlayer(value)
    return value == 0 or value == "neutral" or value == "Neutral"
end

local function asNumber(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        local n = tonumber(value)
        if n ~= nil then
            return n
        end
    end
    return nil
end

local function normalizeObjective(value)
    if type(value) ~= "string" then
        return nil
    end
    local v = value:lower()
    if v == "destroy_commandant" or v == "destroy_red_commandant_within_turn_limit" then
        return v
    end
    return nil
end

local function isNonEmptyTable(value)
    return type(value) == "table" and next(value) ~= nil
end

local function loadMaxHpByUnitName()
    local out = {}
    local ok, unitsInfo = pcall(require, "unitsInfo")
    if not ok or type(unitsInfo) ~= "table" or type(unitsInfo.stats) ~= "table" then
        return out
    end

    local unitName, stats
    for unitName, stats in pairs(unitsInfo.stats) do
        if type(stats) == "table" then
            local maxHp = asNumber(stats.startingHp) or asNumber(stats.hp)
            if maxHp ~= nil then
                out[unitName] = maxHp
            end
        end
    end
    return out
end

local MAX_HP_BY_NAME = loadMaxHpByUnitName()

local function readStateEnvelope(input)
    local state, stateKey = pickFirst(input, {"scenarioState", "state", "scenario_state"})
    if type(state) == "table" then
        return state, stateKey
    end
    if type(input) == "table" then
        return input, ""
    end
    return nil, ""
end

local function validateCoreState(state, rootPath, errors)
    local board = select(1, pickFirst(state, {"board"}))
    if type(board) ~= "table" then
        appendError(errors, "board_missing", "Scenario board is required.", rootPath .. ".board", board)
    else
        local rows = asNumber(select(1, pickFirst(board, {"rows", "height", "h"})))
        local cols = asNumber(select(1, pickFirst(board, {"cols", "columns", "width", "w"})))
        if rows ~= 8 or cols ~= 8 then
            appendError(
                errors,
                "board_dimensions_invalid",
                "Board must be exactly 8x8.",
                rootPath .. ".board",
                {rows = rows, cols = cols}
            )
        end
    end

    local currentPlayer = select(1, pickFirst(state, {"currentPlayer", "current_player", "playerToMove", "player_to_move"}))
    if not isBluePlayer(currentPlayer) then
        appendError(
            errors,
            "blue_to_move_required",
            "Scenario must start with Blue to move.",
            rootPath .. ".currentPlayer",
            currentPlayer
        )
    end

    local objective = select(1, pickFirst(state, {"objectiveType", "objective_type", "objective"}))
    if normalizeObjective(objective) == nil then
        appendError(
            errors,
            "objective_invalid",
            "Objective must be destroy Commandant within turn limit.",
            rootPath .. ".objectiveType",
            objective
        )
    end

    local turnLimit = asNumber(select(1, pickFirst(state, {"turnLimit", "turn_limit", "maxTurns", "max_turns"})))
    if turnLimit == nil or turnLimit < 3 or turnLimit > 10 then
        appendError(
            errors,
            "turn_limit_out_of_range",
            "Turn limit must be between 3 and 10.",
            rootPath .. ".turnLimit",
            turnLimit
        )
    end

    local maxActionsPerTurn = asNumber(select(1, pickFirst(state, {"maxActionsPerTurn", "max_actions_per_turn", "actionBudget", "action_budget"})))
    if maxActionsPerTurn ~= 2 then
        appendError(
            errors,
            "action_budget_invalid",
            "Scenario proof and runtime contract require exactly 2 actions per turn.",
            rootPath .. ".maxActionsPerTurn",
            maxActionsPerTurn
        )
    end

    local supplyEnabled = select(1, pickFirst(state, {"supplyEnabled", "supply_enabled"}))
    if supplyEnabled == true then
        appendError(
            errors,
            "supply_management_forbidden",
            "Scenario contract requires no supply management.",
            rootPath .. ".supplyEnabled",
            supplyEnabled
        )
    end

    local units = select(1, pickFirst(state, {"units", "unitStates", "unit_states"}))
    if type(units) ~= "table" then
        appendError(errors, "units_missing", "Units list is required.", rootPath .. ".units", units)
        return
    end

    local occupancy = {}
    local redCommandantCount = 0
    local i
    for i = 1, #units do
        local unit = units[i]
        local unitPath = string.format("%s.units[%d]", rootPath, i)
        if type(unit) ~= "table" then
            appendError(errors, "unit_invalid", "Unit entry must be an object.", unitPath, unit)
        else
            local name = select(1, pickFirst(unit, {"name", "unitName", "unit_type", "type"}))
            local player = select(1, pickFirst(unit, {"player", "owner", "team"}))
            local row = asNumber(select(1, pickFirst(unit, {"row", "r", "y"})))
            local col = asNumber(select(1, pickFirst(unit, {"col", "column", "c", "x"})))
            local currentHp = asNumber(select(1, pickFirst(unit, {"currentHp", "current_hp", "hp"})))
            local startingHp = asNumber(select(1, pickFirst(unit, {"startingHp", "starting_hp"})))

            if row == nil or col == nil or row < 1 or row > 8 or col < 1 or col > 8 then
                appendError(
                    errors,
                    "unit_position_out_of_bounds",
                    "Unit position must be within board bounds 1..8.",
                    unitPath,
                    {row = row, col = col}
                )
            else
                local cellKey = tostring(row) .. ":" .. tostring(col)
                if occupancy[cellKey] ~= nil then
                    appendError(
                        errors,
                        "duplicate_unit_cell",
                        "Multiple units may not occupy the same cell.",
                        unitPath,
                        {row = row, col = col, otherUnitIndex = occupancy[cellKey]}
                    )
                else
                    occupancy[cellKey] = i
                end
            end

            if type(name) ~= "string" or name == "" then
                appendError(errors, "unit_name_missing", "Unit name is required.", unitPath .. ".name", name)
            else
                if name == "Commandant" then
                    if isBluePlayer(player) then
                        appendError(errors, "blue_commandant_forbidden", "Blue Commandant is not allowed.", unitPath, unit)
                    elseif isRedPlayer(player) then
                        redCommandantCount = redCommandantCount + 1
                        if row ~= nil and col ~= nil and (row < 1 or row > 2 or col < 1 or col > 8) then
                            appendError(
                                errors,
                                "red_commandant_anchor_invalid",
                                "Red Commandant must start in A1-H2.",
                                unitPath,
                                {row = row, col = col}
                            )
                        end
                    end
                elseif name == "Healer" then
                    appendError(errors, "healer_forbidden", "Healer is forbidden in scenario generation.", unitPath, unit)
                elseif name == "Rock" and not isNeutralPlayer(player) then
                    appendError(errors, "rock_must_be_neutral", "Rocks must be neutral (player = 0).", unitPath, player)
                end

                local maxHp = MAX_HP_BY_NAME[name]
                local hpToCheck = currentHp or startingHp
                if hpToCheck == nil then
                    appendError(errors, "unit_hp_missing", "Unit HP is required.", unitPath, unit)
                else
                    if hpToCheck <= 0 then
                        appendError(errors, "unit_hp_non_positive", "Unit HP must be above 0.", unitPath, hpToCheck)
                    end
                    if maxHp ~= nil and hpToCheck > maxHp then
                        appendError(
                            errors,
                            "unit_hp_above_max",
                            "Unit HP may not exceed static max HP.",
                            unitPath,
                            {hp = hpToCheck, maxHp = maxHp, unitName = name}
                        )
                    end
                end

                if currentHp ~= nil and maxHp ~= nil and currentHp > maxHp then
                    appendError(
                        errors,
                        "unit_hp_above_max",
                        "currentHp may not exceed static max HP.",
                        unitPath .. ".currentHp",
                        {currentHp = currentHp, maxHp = maxHp, unitName = name}
                    )
                end
                if startingHp ~= nil and maxHp ~= nil and startingHp > maxHp then
                    appendError(
                        errors,
                        "unit_hp_above_max",
                        "startingHp may not exceed static max HP.",
                        unitPath .. ".startingHp",
                        {startingHp = startingHp, maxHp = maxHp, unitName = name}
                    )
                end
                if currentHp ~= nil and currentHp <= 0 then
                    appendError(errors, "unit_hp_non_positive", "currentHp must be above 0.", unitPath .. ".currentHp", currentHp)
                end
                if startingHp ~= nil and startingHp <= 0 then
                    appendError(errors, "unit_hp_non_positive", "startingHp must be above 0.", unitPath .. ".startingHp", startingHp)
                end
            end
        end
    end

    if redCommandantCount ~= 1 then
        appendError(
            errors,
            "red_commandant_count_invalid",
            "Scenario must include exactly one Red Commandant.",
            rootPath .. ".units",
            {count = redCommandantCount}
        )
    end
end

local function validateMechanismAndFingerprint(holder, rootPath, errors)
    local mechanism = select(1, pickFirst(holder, {"mechanismSpec", "mechanism_spec", "mechanism", "solvingMechanism", "solving_mechanism"}))
    if not isNonEmptyTable(mechanism) and type(mechanism) ~= "string" then
        appendError(
            errors,
            "missing_mechanism_spec",
            "Scenario must declare a solving mechanism.",
            rootPath .. ".mechanismSpec",
            mechanism
        )
    end

    local fingerprint = select(1, pickFirst(holder, {"tacticalFingerprint", "tactical_fingerprint", "fingerprint"}))
    if not isNonEmptyTable(fingerprint) and type(fingerprint) ~= "string" then
        appendError(
            errors,
            "missing_tactical_fingerprint",
            "Scenario must declare a tactical fingerprint.",
            rootPath .. ".tacticalFingerprint",
            fingerprint
        )
    end
end

function M.validateScenarioState(stateInput)
    local errors = {}
    local state, stateRoot = readStateEnvelope(stateInput)
    if type(state) ~= "table" then
        appendError(errors, "scenario_state_invalid", "Scenario state must be a table.", "state", stateInput)
        return false, errors
    end

    local rootPath = stateRoot ~= "" and stateRoot or "state"
    validateCoreState(state, rootPath, errors)
    validateMechanismAndFingerprint(stateInput, rootPath == "state" and "state" or stateRoot, errors)
    if rootPath == "state" then
        validateMechanismAndFingerprint(state, rootPath, errors)
    end

    return #errors == 0, errors
end

function M.validateScenarioDossier(dossier)
    local errors = {}
    if type(dossier) ~= "table" then
        appendError(errors, "scenario_dossier_invalid", "Scenario dossier must be a table.", "dossier", dossier)
        return false, errors
    end

    local state, stateRoot = readStateEnvelope(dossier)
    if type(state) ~= "table" then
        appendError(
            errors,
            "scenario_state_missing",
            "Scenario dossier must include scenarioState/state.",
            "scenarioState",
            state
        )
    else
        local rootPath = stateRoot ~= "" and stateRoot or "scenarioState"
        validateCoreState(state, rootPath, errors)
    end

    validateMechanismAndFingerprint(dossier, "dossier", errors)
    return #errors == 0, errors
end

function M.isScenarioOnly()
    return true
end

return M
