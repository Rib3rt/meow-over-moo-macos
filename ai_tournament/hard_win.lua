local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cloneValue(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = cloneValue(child)
    end
    return out
end

local function actionTargetText(action)
    local target = action and action.target or nil
    if not target then
        return nil
    end
    return string.format("%s,%s", tostring(target.row or "?"), tostring(target.col or "?"))
end

local function enemySupplyEmpty(state, enemyPlayer)
    if not (state and state.supply and enemyPlayer) then
        return false
    end
    return #((state.supply and state.supply[enemyPlayer]) or {}) <= 0
end

local function buildActions(entry)
    if not (entry and entry.action) then
        return nil
    end
    local actions = {cloneValue(entry.action)}
    if entry.secondAction then
        actions[#actions + 1] = cloneValue(entry.secondAction)
    end
    return actions
end

local function inferKind(entry)
    local reason = tostring(entry and entry.reason or "")
    if reason == "KILL_LAST_ENEMY_UNIT" then
        return "last_enemy_unit"
    end
    return "commandant"
end

local function buildSelection(entry)
    local actions = buildActions(entry)
    if not actions then
        return nil
    end

    local kind = inferKind(entry)
    local reason = kind == "last_enemy_unit"
        and "hard_win_priority00_elimination"
        or "hard_win_priority00_commandant"

    return {
        kind = kind,
        reason = reason,
        actions = actions,
        sourceReason = entry.reason,
        unit = entry.unit,
        secondUnit = entry.secondUnit,
        targetName = entry.targetName,
        damage = num(entry.damage, entry.totalDamage or 0),
        value = num(entry.value, entry.totalDamage or entry.damage or 0),
        proof = kind == "last_enemy_unit" and "elimination" or "commandant_lethal"
    }
end

function M.select(ai, state, ctx)
    local stats = ctx and ctx.stats or {}
    local enabled = ctx and ctx.cfg and ctx.cfg.HARD_WIN_PRIORITY00_ENABLED ~= false
    stats.hardWinPriority00Enabled = enabled

    if not enabled then
        stats.hardWinPriority00Skipped = "disabled"
        return nil
    end
    if not (ai and state and ctx and ai.findWinningConditionActions) then
        stats.hardWinPriority00Skipped = "hard_win_tools_unavailable"
        return nil
    end

    local entry = ai:findWinningConditionActions(state, {}) or nil
    if not entry then
        stats.hardWinPriority00Skipped = "no_priority00_win"
        return nil
    end

    local selected = buildSelection(entry)
    if not selected then
        stats.hardWinPriority00Skipped = "invalid_priority00_entry"
        return nil
    end

    if selected.kind == "last_enemy_unit" then
        if ctx.cfg.HARD_WIN_PRIORITY00_LAST_UNIT_ENABLED == false then
            stats.hardWinPriority00Skipped = "last_unit_disabled"
            return nil
        end
        if not enemySupplyEmpty(state, ctx.enemyPlayer) then
            stats.hardWinPriority00Skipped = "last_unit_enemy_supply_available"
            return nil
        end
    end

    stats.hardWinPriority00Selected = selected.reason
    stats.hardWinPriority00SelectedSourceReason = selected.sourceReason
    stats.hardWinPriority00SelectedTarget = actionTargetText(selected.actions[#selected.actions])
    return selected
end

return M
