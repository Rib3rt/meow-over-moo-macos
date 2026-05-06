local stateEngine = require("scenario_tooling.state_engine")
local rulesKernel = require("scenario_tooling.rules_kernel")
local unitsInfo = require("unitsInfo")

local M = {
    VERSION = "scenario_finisher_library.v1",
    LIBRARY_ID = "step5_finisher_library_v1"
}

local BOARD_SIZE = 8
local BLUE = 1
local RED = 2

local CELL_COLUMNS = { "A", "B", "C", "D", "E", "F", "G", "H" }
local parseCell

local function shallowCopyArray(arr)
    local out = {}
    local i
    for i = 1, #arr do
        out[i] = arr[i]
    end
    return out
end

local function cloneCellArray(cells)
    local out = {}
    for i = 1, #(cells or {}) do
        local parsed = parseCell(cells[i])
        if parsed then
            out[#out + 1] = parsed
        end
    end
    return out
end

local function cloneSpec(spec)
    local out = {}
    local k, v
    for k, v in pairs(spec) do
        if k == "supportedCommandantCells" or k == "unsupportedCommandantCells" then
            out[k] = cloneCellArray(v)
        elseif type(v) == "table" then
            out[k] = shallowCopyArray(v)
        else
            out[k] = v
        end
    end
    return out
end

local function columnToNumber(col)
    if type(col) ~= "string" then
        return nil
    end
    col = string.upper(col)
    local i
    for i = 1, #CELL_COLUMNS do
        if CELL_COLUMNS[i] == col then
            return i
        end
    end
    return nil
end

local function numberToColumn(n)
    if n < 1 or n > #CELL_COLUMNS then
        return nil
    end
    return CELL_COLUMNS[n]
end

function parseCell(cell)
    if type(cell) ~= "string" then
        return nil
    end
    local col, rowText = string.match(string.upper(cell), "^([A-H])([1-8])$")
    if not col or not rowText then
        return nil
    end
    return {
        row = tonumber(rowText),
        col = columnToNumber(col)
    }
end

local function formatCell(row, col)
    local c = numberToColumn(col)
    if not c or row < 1 or row > BOARD_SIZE then
        return nil
    end
    return c .. tostring(row)
end

local function inBounds(row, col)
    return row >= 1 and row <= BOARD_SIZE and col >= 1 and col <= BOARD_SIZE
end

local function allCommandantCellsA1H2()
    local out = {}
    local row, col
    for row = 1, 2 do
        for col = 1, 8 do
            out[#out + 1] = formatCell(row, col)
        end
    end
    return out
end

local function makeDamageProbeState(unitType)
    return {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = 1,
        turnLimit = 1,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            {
                id = "blue_finisher",
                name = unitType,
                player = BLUE,
                row = 4,
                col = 4,
                currentHp = (unitsInfo.stats[unitType] and unitsInfo.stats[unitType].startingHp) or 4,
                startingHp = (unitsInfo.stats[unitType] and unitsInfo.stats[unitType].startingHp) or 4,
                hasMoved = false,
                hasActed = false,
                actionsUsed = 0,
                turnActions = {}
            },
            {
                id = "red_commandant",
                name = "Commandant",
                player = RED,
                row = 4,
                col = 5,
                currentHp = 12,
                startingHp = 12,
                hasMoved = false,
                hasActed = false,
                actionsUsed = 0,
                turnActions = {}
            }
        }
    }
end

local function computeDamageVsCommandant(unitType)
    local state = makeDamageProbeState(unitType)
    if unitType == "Cloudstriker" or unitType == "Artillery" then
        state.units[1].row = 4
        state.units[1].col = 2
        state.units[2].row = 4
        state.units[2].col = 4
    end
    local nextState, result = rulesKernel.applyAction(state, {
        type = "attack",
        actorId = "blue_finisher",
        targetId = "red_commandant"
    })
    if type(result) == "table" and result.ok == true then
        return tonumber(result.damage) or 0
    end
    return 0
end

local function makeFinisherSpecs()
    local cloudDamage = computeDamageVsCommandant("Cloudstriker")
    local crusherDamage = computeDamageVsCommandant("Crusher")
    local artilleryDamage = computeDamageVsCommandant("Artillery")

    return {
        {
            id = "cloudstriker_ranged",
            family = "ranged",
            unitType = "Cloudstriker",
            damageVsCommandant = cloudDamage,
            range = 3,
            minRange = 2,
            losRequired = true,
            canShootThroughBlockers = false,
            finalCellPolicy = "orthogonal_los_range_2_to_3",
            supportedCommandantCells = allCommandantCellsA1H2(),
            unsupportedCommandantCells = {},
            compatibleMicroInteractions = { "line_setup", "rock_clearance" },
            risks = { "line_blocked_by_occupancy_or_rock", "adjacent_invalid" },
            notes = { "Cloudstriker cannot attack adjacent cells.", "Rock and occupied cells block LOS." }
        },
        {
            id = "crusher_melee",
            family = "melee",
            unitType = "Crusher",
            damageVsCommandant = crusherDamage,
            range = 1,
            minRange = 1,
            losRequired = false,
            canShootThroughBlockers = false,
            finalCellPolicy = "adjacent_manhattan_1",
            supportedCommandantCells = allCommandantCellsA1H2(),
            unsupportedCommandantCells = {},
            compatibleMicroInteractions = { "contact_finish", "corner_pressure" },
            risks = { "adjacent_tile_occupied_by_enemy_or_rock" },
            notes = { "Crusher has +1 damage against Commandant." }
        },
        {
            id = "artillery_ranged",
            family = "artillery",
            unitType = "Artillery",
            damageVsCommandant = artilleryDamage,
            range = 3,
            minRange = 2,
            losRequired = false,
            canShootThroughBlockers = true,
            finalCellPolicy = "orthogonal_range_2_to_3",
            supportedCommandantCells = allCommandantCellsA1H2(),
            unsupportedCommandantCells = {},
            compatibleMicroInteractions = { "through_blockers", "lane_finish" },
            risks = { "diagonal_targets_invalid", "adjacent_invalid" },
            notes = { "Artillery can shoot through blockers and Rock in scenario kernel." }
        }
    }
end

local FINISHER_LIST = makeFinisherSpecs()

local FINISHER_BY_ID = {}
local i
for i = 1, #FINISHER_LIST do
    FINISHER_BY_ID[FINISHER_LIST[i].id] = FINISHER_LIST[i]
end

local function hashText(text)
    local hash = 5381
    local idx
    for idx = 1, #text do
        hash = ((hash * 33) + string.byte(text, idx)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function specFingerprint(spec)
    local fields = {
        spec.id,
        spec.family,
        spec.unitType,
        tostring(spec.damageVsCommandant),
        tostring(spec.range),
        tostring(spec.minRange),
        tostring(spec.losRequired),
        tostring(spec.canShootThroughBlockers),
        spec.finalCellPolicy
    }
    return table.concat(fields, "|")
end

local fp = {}
for i = 1, #FINISHER_LIST do
    fp[i] = specFingerprint(FINISHER_LIST[i])
end
M.LIBRARY_HASH = hashText(table.concat(fp, "||"))

function M.isScenarioOnly()
    return true
end

function M.listFinishers()
    local out = {}
    local j
    for j = 1, #FINISHER_LIST do
        out[j] = cloneSpec(FINISHER_LIST[j])
    end
    return out
end

function M.getFinisher(id)
    local spec = FINISHER_BY_ID[id]
    if not spec then
        return nil
    end
    return cloneSpec(spec)
end

function M.supportedCommandantCells(finisherId)
    local spec = FINISHER_BY_ID[finisherId]
    if not spec then
        return {}
    end
    return cloneCellArray(spec.supportedCommandantCells)
end

function M.unsupportedCommandantCells(finisherId)
    local spec = FINISHER_BY_ID[finisherId]
    if not spec then
        return {}
    end
    return cloneCellArray(spec.unsupportedCommandantCells)
end

local function enumerateFinalAttackCells(spec, commandantCell)
    local cc = parseCell(commandantCell)
    if not cc then
        return {}
    end
    local out = {}
    local distance
    if spec.family == "melee" then
        local deltas = {
            { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }
        }
        local d
        for d = 1, #deltas do
            local row = cc.row + deltas[d][1]
            local col = cc.col + deltas[d][2]
            if inBounds(row, col) then
                out[#out + 1] = formatCell(row, col)
            end
        end
        table.sort(out)
        return out
    end

    for distance = spec.minRange, spec.range do
        local orth = {
            { distance, 0 },
            { -distance, 0 },
            { 0, distance },
            { 0, -distance }
        }
        local k
        for k = 1, #orth do
            local row = cc.row + orth[k][1]
            local col = cc.col + orth[k][2]
            if inBounds(row, col) then
                out[#out + 1] = formatCell(row, col)
            end
        end
    end

    local dedup = {}
    local unique = {}
    local n
    for n = 1, #out do
        local cell = out[n]
        if not dedup[cell] then
            dedup[cell] = true
            unique[#unique + 1] = cell
        end
    end
    table.sort(unique)
    return unique
end

function M.finalAttackCells(finisherId, commandantCell)
    local spec = FINISHER_BY_ID[finisherId]
    if not spec then
        return {}
    end
    return enumerateFinalAttackCells(spec, commandantCell)
end

local function unitWithDefaults(id, name, player, row, col, hp)
    local maxHp = (unitsInfo.stats[name] and unitsInfo.stats[name].startingHp) or hp or 1
    return {
        id = id,
        name = name,
        player = player,
        row = row,
        col = col,
        currentHp = hp or maxHp,
        startingHp = maxHp,
        hasMoved = false,
        hasActed = false,
        actionsUsed = 0,
        turnActions = {}
    }
end

local function isListed(cells, cell)
    local i
    for i = 1, #cells do
        if cells[i] == cell then
            return true
        end
    end
    return false
end

function M.buildMateFixture(finisherId, commandantCell)
    local spec = FINISHER_BY_ID[finisherId]
    if not spec then
        return nil, "unknown_finisher"
    end

    local commandantCellText = commandantCell
    if type(commandantCell) == "table" then
        commandantCellText = formatCell(tonumber(commandantCell.row), tonumber(commandantCell.col))
    end
    local cc = parseCell(commandantCellText)
    if not cc then
        return nil, "invalid_commandant_cell"
    end

    local supported = spec.supportedCommandantCells
    local unsupported = spec.unsupportedCommandantCells
    if isListed(unsupported, commandantCellText) then
        return nil, "commandant_cell_blacklisted"
    end
    if not isListed(supported, commandantCellText) then
        return nil, "commandant_cell_not_supported"
    end

    local attackerCells = enumerateFinalAttackCells(spec, commandantCellText)
    if #attackerCells == 0 then
        return nil, "no_final_attack_cells"
    end

    local attackerCell = parseCell(attackerCells[1])
    local state = {
        schema = "ScenarioState",
        board = { rows = 8, cols = 8 },
        currentPlayer = BLUE,
        scenarioTurn = 1,
        turnLimit = 1,
        objectiveType = "destroy_red_commandant_within_turn_limit",
        supplyEnabled = false,
        turnActions = 0,
        actionsUsed = 0,
        units = {
            unitWithDefaults(finisherId .. "_unit", spec.unitType, BLUE, attackerCell.row, attackerCell.col),
            unitWithDefaults("red_commandant", "Commandant", RED, cc.row, cc.col, spec.damageVsCommandant)
        }
    }

    local legal, reason = rulesKernel.isLegalAttack(state, finisherId .. "_unit", "red_commandant")
    if not legal then
        return nil, "no_legal_final_attack:" .. tostring(reason)
    end

    return state
end

function M.validateFinisher(finisherId)
    local spec = FINISHER_BY_ID[finisherId]
    if not spec then
        return false, { finisherId = finisherId, error = "unknown_finisher" }
    end

    local report = {
        id = finisherId,
        finisherId = finisherId,
        checkedSupported = 0,
        checkedUnsupported = 0,
        errors = {}
    }

    local i
    for i = 1, #spec.supportedCommandantCells do
        local cell = spec.supportedCommandantCells[i]
        local fixture, reason = M.buildMateFixture(finisherId, cell)
        if not fixture then
            report.errors[#report.errors + 1] = "supported_cell_failed:" .. cell .. ":" .. tostring(reason)
        else
            local nextState, result = stateEngine.applyAction(fixture, {
                type = "attack",
                actorId = finisherId .. "_unit",
                targetId = "red_commandant"
            })
            if not (type(result) == "table" and result.ok == true) then
                report.errors[#report.errors + 1] = "attack_apply_failed:" .. cell .. ":" .. tostring(result and result.reason)
            else
                local outcome = stateEngine.evaluateOutcome(nextState)
                if not (type(outcome) == "table" and outcome.status == "blue_win") then
                    report.errors[#report.errors + 1] = "no_blue_win_after_attack:" .. cell
                end
            end
        end
        report.checkedSupported = report.checkedSupported + 1
    end

    for i = 1, #spec.unsupportedCommandantCells do
        local cell = spec.unsupportedCommandantCells[i]
        local fixture = M.buildMateFixture(finisherId, cell)
        if fixture ~= nil then
            report.errors[#report.errors + 1] = "blacklisted_cell_built_fixture:" .. cell
        end
        report.checkedUnsupported = report.checkedUnsupported + 1
    end

    report.ok = #report.errors == 0
    return report.ok, report
end

function M.validateLibrary()
    local reports = {}
    local ok = true
    local i
    for i = 1, #FINISHER_LIST do
        local finisherId = FINISHER_LIST[i].id
        local valid, report = M.validateFinisher(finisherId)
        reports[#reports + 1] = report
        if not valid then
            ok = false
        end
    end
    return ok, reports
end

return M
