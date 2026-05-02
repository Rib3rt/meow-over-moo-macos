local M = {}

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = clone(child)
    end
    return out
end

local function withoutDefendNow(activeNames)
    local out = {}
    for _, name in ipairs(activeNames or {}) do
        if name ~= "DEFEND_NOW" then
            out[#out + 1] = name
        end
    end
    return out
end

function M.isPressure(contracts)
    return contracts
        and contracts.defenseActive == true
        and contracts.defenseKind == "pressure"
end

function M.isHardDefense(contracts)
    return contracts
        and contracts.defenseActive == true
        and contracts.defenseKind ~= "pressure"
end

function M.isLethalDefense(contracts)
    return contracts
        and contracts.defenseActive == true
        and contracts.defenseKind ~= "pressure"
end

function M.softContracts(contracts)
    if not M.isPressure(contracts) then
        return contracts
    end

    local soft = clone(contracts)
    soft.defenseActive = false
    soft.defensePressureSoft = true
    soft.defensePressureActive = true
    soft.defenseSoftenedFrom = "DEFEND_NOW"
    soft.activeNames = withoutDefendNow(contracts.activeNames)
    return soft
end

function M.relaxedHardDefenseContracts(contracts, reason)
    if not M.isHardDefense(contracts) then
        return contracts
    end

    local soft = clone(contracts)
    soft.defenseActive = false
    soft.defenseHardRelaxed = true
    soft.defenseLethalSoft = true
    soft.defensePressureSoft = false
    soft.defenseSoftenedFrom = "DEFEND_NOW"
    soft.defenseSoftenedReason = reason or "hard_defense_failed"
    soft.activeNames = withoutDefendNow(contracts.activeNames)
    return soft
end

function M.withSoftContext(ctx, contracts, fn)
    if not M.isPressure(contracts) then
        return fn(contracts, false)
    end

    local soft = M.softContracts(contracts)
    local previousContracts = ctx and ctx.activeContracts or nil
    local previousRuntime = ctx and ctx.defensePressureSoftRuntime or nil

    if ctx then
        ctx.activeContracts = soft
        ctx.defensePressureSoftRuntime = true
        if ctx.stats then
            ctx.stats.defensePressureSoftenedForV2 = true
            ctx.stats.defensePressureSoftOriginalKind = contracts.defenseKind
        end
    end

    local ok, a, b, c, d = xpcall(function()
        return fn(soft, true)
    end, debug.traceback)

    if ctx then
        ctx.activeContracts = previousContracts
        ctx.defensePressureSoftRuntime = previousRuntime
    end

    if not ok then
        error(a, 0)
    end

    return a, b, c, d
end

function M.withRelaxedHardDefenseContext(ctx, contracts, reason, fn)
    if not M.isHardDefense(contracts) then
        return M.withSoftContext(ctx, contracts, fn)
    end

    local soft = M.relaxedHardDefenseContracts(contracts, reason)
    local previousContracts = ctx and ctx.activeContracts or nil
    local previousRuntime = ctx and ctx.defenseHardRelaxedRuntime or nil

    if ctx then
        ctx.activeContracts = soft
        ctx.defenseHardRelaxedRuntime = true
        if ctx.stats then
            ctx.stats.defenseHardRelaxedForV2 = true
            ctx.stats.defenseHardRelaxedReason = reason or "hard_defense_failed"
            ctx.stats.defenseHardRelaxedOriginalKind = contracts.defenseKind
            ctx.stats.pipelineV2Skipped = false
            ctx.stats.pipelineV2FailedReason = nil
        end
    end

    local ok, a, b, c, d = xpcall(function()
        return fn(soft, true)
    end, debug.traceback)

    if ctx then
        ctx.activeContracts = previousContracts
        ctx.defenseHardRelaxedRuntime = previousRuntime
    end

    if not ok then
        error(a, 0)
    end

    return a, b, c, d
end

return M
