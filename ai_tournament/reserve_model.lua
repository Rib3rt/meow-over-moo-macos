local M = {}

local BLOCKER_UNITS = {
    Bastion = true,
    Crusher = true,
    Earthstalker = true
}

local SIEGE_UNITS = {
    Artillery = true,
    Cloudstriker = true,
    Crusher = true
}

local REPAIR_UNITS = {
    Healer = true
}

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local clone = {}
    seen[value] = clone
    for key, child in pairs(value) do
        clone[deepCopy(key, seen)] = deepCopy(child, seen)
    end
    return clone
end

function M.snapshotSupplyForPlayer(ai, state, playerId, ctx)
    local list = state and state.supply and state.supply[playerId] or {}
    local byName = {}
    local ordered = {}

    for index, unit in ipairs(list or {}) do
        local name = unit and unit.name or "unknown"
        byName[name] = (byName[name] or 0) + 1
        ordered[#ordered + 1] = {
            index = index,
            name = name,
            unit = unit
        }
    end

    table.sort(ordered, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.index < b.index
    end)

    return {
        playerId = playerId,
        count = #ordered,
        empty = #ordered == 0,
        byName = byName,
        ordered = ordered
    }
end

function M.buildReserveProfile(ai, supplySnapshot, ctx)
    local _ = ai
    local _ctx = ctx
    local snapshot = supplySnapshot or {
        count = 0,
        byName = {},
        ordered = {}
    }

    local profile = {
        playerId = snapshot.playerId,
        count = snapshot.count or 0,
        empty = snapshot.empty == true,
        byName = deepCopy(snapshot.byName or {}),
        hasBlocker = false,
        hasSiege = false,
        hasRepair = false,
        blockerCount = 0,
        siegeCount = 0,
        repairCount = 0,
        unitNamesOrdered = {}
    }

    for _, entry in ipairs(snapshot.ordered or {}) do
        local name = entry and entry.name or "unknown"
        profile.unitNamesOrdered[#profile.unitNamesOrdered + 1] = name

        if BLOCKER_UNITS[name] then
            profile.blockerCount = profile.blockerCount + 1
            profile.hasBlocker = true
        end
        if SIEGE_UNITS[name] then
            profile.siegeCount = profile.siegeCount + 1
            profile.hasSiege = true
        end
        if REPAIR_UNITS[name] then
            profile.repairCount = profile.repairCount + 1
            profile.hasRepair = true
        end
    end

    return profile
end

function M.evaluateOwnReserveScarcity(ai, beforeState, afterState, sequence, playerId, ctx)
    local _ = sequence
    local beforeSnapshot = M.snapshotSupplyForPlayer(ai, beforeState, playerId, ctx)
    local afterSnapshot = M.snapshotSupplyForPlayer(ai, afterState, playerId, ctx)
    local beforeProfile = M.buildReserveProfile(ai, beforeSnapshot, ctx)
    local afterProfile = M.buildReserveProfile(ai, afterSnapshot, ctx)

    local value = 0
    local reasons = {}

    local enemyPlayer = ai and ai.getOpponentPlayer and ai:getOpponentPlayer(playerId) or nil
    local beforeThreat = nil
    local afterThreat = nil
    if enemyPlayer and ctx and ctx.threatModel and ctx.threatModel.analyzeHubThreatForPlayer then
        beforeThreat = ctx.threatModel.analyzeHubThreatForPlayer(ai, beforeState, playerId, enemyPlayer, ctx)
        afterThreat = ctx.threatModel.analyzeHubThreatForPlayer(ai, afterState, playerId, enemyPlayer, ctx)
    elseif enemyPlayer and ai and ai.analyzeHubThreatForPlayer then
        beforeThreat = ai:analyzeHubThreatForPlayer(beforeState, playerId, enemyPlayer, ctx)
        afterThreat = ai:analyzeHubThreatForPlayer(afterState, playerId, enemyPlayer, ctx)
    end

    local spentLastBlocker = beforeProfile.hasBlocker and not afterProfile.hasBlocker
    if spentLastBlocker then
        local defendedLethal = beforeThreat and beforeThreat.immediateLethal == true and afterThreat and afterThreat.immediateLethal ~= true
        local reducedDanger = beforeThreat and afterThreat
            and (beforeThreat.projectedDamage or 0) > (afterThreat.projectedDamage or 0)

        if defendedLethal or reducedDanger then
            value = value + 4000
            reasons[#reasons + 1] = "spends_last_blocker_to_prevent_lethal"
        else
            value = value - 1200
            reasons[#reasons + 1] = "spends_last_blocker_without_need"
        end
    end

    local spentLastRepair = beforeProfile.hasRepair and not afterProfile.hasRepair
    if spentLastRepair then
        local hadDamagedAllies = ai and ai.countDamagedFriendlyUnits
            and ai:countDamagedFriendlyUnits(beforeState, playerId, {includeHub = true}) or 0
        if hadDamagedAllies <= 0 then
            value = value - 350
            reasons[#reasons + 1] = "spends_last_repair_without_need"
        end
    end

    if (beforeProfile.count or 0) > 0 and (afterProfile.count or 0) == 0 then
        value = value - 220
        reasons[#reasons + 1] = "reserve_depleted"
    end

    return {
        value = value,
        reasons = reasons,
        before = beforeProfile,
        after = afterProfile
    }
end

function M.evaluateEnemyReserveThreat(ai, state, enemyPlayerId, ctx)
    local snap = M.snapshotSupplyForPlayer(ai, state, enemyPlayerId, ctx)
    if snap.empty then
        return {
            value = 0,
            empty = true,
            reasons = {"enemy_supply_empty"}
        }
    end

    local profile = M.buildReserveProfile(ai, snap, ctx)
    local value = 0
    local reasons = {}

    if profile.hasBlocker then
        value = value - 180
        reasons[#reasons + 1] = "enemy_has_blocker_reserve"
    end
    if profile.hasSiege then
        value = value - 160
        reasons[#reasons + 1] = "enemy_has_siege_reserve"
    end
    if profile.hasRepair then
        value = value - 120
        reasons[#reasons + 1] = "enemy_has_repair_reserve"
    end

    return {
        value = value,
        empty = false,
        profile = profile,
        reasons = reasons
    }
end

return M
