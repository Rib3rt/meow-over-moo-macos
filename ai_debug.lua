local M = {}
local aiConfig = require('ai_config')

local DEFAULT_AI_PARAMS = (aiConfig and aiConfig.AI_PARAMS) or {}
local RUNTIME_DEFAULTS = DEFAULT_AI_PARAMS.RUNTIME or {}
local LOGGING_DEFAULTS = DEFAULT_AI_PARAMS.LOGGING or {}
local SYMBOL_DEFAULTS = LOGGING_DEFAULTS.UNIT_SYMBOL or {}

local ZERO = RUNTIME_DEFAULTS.ZERO
local ONE = RUNTIME_DEFAULTS.MIN_HP
local DEFAULT_LOG_GRID_SIZE = LOGGING_DEFAULTS.DEFAULT_GRID_SIZE
local DEFAULT_DETAIL_DEPTH = LOGGING_DEFAULTS.DETAIL_DEPTH_DEFAULT
local MAX_DETAIL_DEPTH = LOGGING_DEFAULTS.MAX_DETAIL_DEPTH
local ARRAY_PREVIEW_LIMIT = LOGGING_DEFAULTS.ARRAY_PREVIEW_LIMIT
local OBJECT_PREVIEW_LIMIT = LOGGING_DEFAULTS.OBJECT_PREVIEW_LIMIT
local NEUTRAL_PLAYER_ID = SYMBOL_DEFAULTS.NEUTRAL_PLAYER_ID
local PLAYER_ONE_ID = SYMBOL_DEFAULTS.PLAYER_ONE_ID
local PLAYER_TWO_ID = SYMBOL_DEFAULTS.PLAYER_TWO_ID
local HP_MIN = SYMBOL_DEFAULTS.HP_MIN
local HP_MAX = SYMBOL_DEFAULTS.HP_MAX
local UNIT_SYMBOL_WIDTH = LOGGING_DEFAULTS.UNIT_SYMBOL_WIDTH or string.len("P1HUB0 ")

local function valueOr(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

local LOGGED_PRIORITIES = {
    Priority00 = true,
    Priority01 = true,
    Priority02 = true,
    Priority03 = true,
    Priority04 = true,
    Priority05 = true,
    Priority06 = true,
    Priority07 = true,
    Priority08 = true,
    Priority09 = true,
    Priority10 = true,
    Priority11 = true,
    Priority12 = true,
    Priority13 = true,
    Priority14 = true,
    Priority15 = true,
    Priority16 = true,
    Priority17 = true,
    Priority18 = true,
    Priority19 = true,
    Priority20 = true,
    Priority21 = true,
    Priority22 = true,
    Priority23 = true,
    Priority24 = true,
    Priority25 = true,
    Priority26 = true,
    Priority27 = true,
    Priority28 = true,
    Priority29 = true,
    Priority30 = true,
    Priority31 = true,
    Priority32 = true,
    Priority33 = true,
    Priority34 = true,
    Priority35 = true,
}

local function formatCell(cell)
    if not cell then
        return "(?, ?)"
    end
    local row = cell.row ~= nil and tostring(cell.row) or "?"
    local col = cell.col ~= nil and tostring(cell.col) or "?"
    return string.format("(%s,%s)", row, col)
end

local function describeUnitSymbol(unit)
    if not unit or not unit.name then
        return " "
    end
    local owner = valueOr(unit.player, NEUTRAL_PLAYER_ID)
    local prefix = (owner == PLAYER_ONE_ID and "P") or (owner == PLAYER_TWO_ID and "E") or "N"
    local base = unit.name:sub(ONE, ONE)
    local hpBase = valueOr(unit.currentHp, unit.startingHp)
    local hp = math.max(HP_MIN, math.min(HP_MAX, valueOr(hpBase, ZERO)))
    return string.format("%s%s%d", prefix, base, hp)
end

function M.mixin(aiClass)
    function aiClass:formatCell(cell)
        return formatCell(cell)
    end

    function aiClass:getUnitNameFromState(state, row, col)
        if not state or not state.units or not row or not col then
            return nil
        end
        for _, stateUnit in ipairs(state.units) do
            if stateUnit.row == row and stateUnit.col == col and stateUnit.name then
                return stateUnit.name
            end
        end
        return nil
    end

    function aiClass:resolveUnitName(unit)
        if not unit then
            return nil
        end

        if unit.name and unit.name ~= "" then
            return unit.name
        end

        local row, col = unit.row, unit.col
        if row and col then
            if self._logState then
                local name = self:getUnitNameFromState(self._logState, row, col)
                if name then return name end
            end

            if self._lastSequenceStateForLogging and self._lastSequenceStateForLogging ~= self._logState then
                local name = self:getUnitNameFromState(self._lastSequenceStateForLogging, row, col)
                if name then return name end
            end

            if self.grid and self.grid.getUnitAt then
                local gridUnit = self.grid:getUnitAt(row, col)
                if gridUnit and gridUnit.name then
                    return gridUnit.name
                end
            end
        end

        return nil
    end

    function aiClass:describeUnitStatus(unit)
        if not unit then
            return "unit=nil"
        end
        local name = self:resolveUnitName(unit) or unit.name or "unknown"
        local row = unit.row ~= nil and tostring(unit.row) or "?"
        local col = unit.col ~= nil and tostring(unit.col) or "?"
        local currentHp = unit.currentHp ~= nil and tostring(unit.currentHp) or "?"
        local startingHp = unit.startingHp ~= nil and tostring(unit.startingHp) or "?"
        local owner = unit.player ~= nil and ("P" .. tostring(unit.player)) or "P?"
        return string.format("%s %s - (%s,%s) - HP %s/%s", owner, name, row, col, currentHp, startingHp)
    end

    function aiClass:countAiUnits(state)
        if not state or not state.units then
            return ZERO
        end
        local aiFaction = self:getFactionId()
        local count = ZERO
        for _, unit in ipairs(state.units) do
            if aiFaction and unit.player == aiFaction then
                local isCommandHub = (unit.isCommandHub == true) or (unit.name == "Commandant")
                if not isCommandHub then
                    count = count + ONE
                end
            end
        end
        return count
    end

    function aiClass:describeUnit(unit)
        if not unit then
            return "unit=nil"
        end
        local parts = {}
        local resolvedName = self:resolveUnitName(unit)
        table.insert(parts, resolvedName or unit.name or "unknown")
        if unit.player then
            table.insert(parts, "P" .. tostring(unit.player))
        end
        if unit.row and unit.col then
            table.insert(parts, formatCell(unit))
        end
        return table.concat(parts, " ")
    end

    function aiClass:isActionTable(value)
        return type(value) == "table" and (value.type ~= nil or value.actionType ~= nil)
    end

    function aiClass:describeAction(action)
        if not action then
            return "action=nil"
        end

        local parts = { action.type or action.actionType or "unknown" }

        if action.unit then
            table.insert(parts, "unit=" .. self:describeUnit(action.unit))
        end

        if action.target then
            table.insert(parts, "target=" .. formatCell(action.target))
        end

        if action.moveAction then
            table.insert(parts, "move=" .. self:describeAction(action.moveAction))
        end

        if action.attackAction then
            table.insert(parts, "attack=" .. self:describeAction(action.attackAction))
        end

        if action.reason then
            table.insert(parts, "reason=" .. tostring(action.reason))
        end

        if action.score then
            table.insert(parts, "score=" .. tostring(action.score))
        end

        return table.concat(parts, " | ")
    end

    function aiClass:describeUnitShort(unit)
        if not unit then
            return "unit=nil"
        end
        local name = self:resolveUnitName(unit) or unit.name or "unknown"
        local owner = unit.player ~= nil and ("P" .. tostring(unit.player)) or "P?"
        local row = unit.row ~= nil and tostring(unit.row) or "?"
        local col = unit.col ~= nil and tostring(unit.col) or "?"
        return string.format("%s %s @ (%s,%s)", owner, name, row, col)
    end

    -- Shared formatting/grid/logging methods are defined in ai_core.lua.
end

return M
