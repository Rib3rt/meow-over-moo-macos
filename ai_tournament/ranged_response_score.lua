local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cfgNumber(ctx, key, fallback)
    return num(ctx and ctx.cfg and ctx.cfg[key], fallback)
end

local function enabled(ctx)
    local cfg = ctx and ctx.cfg or nil
    return not (cfg and cfg.PIPELINE_V2_SOFT_DEFENSE_RANGED_RESPONSE_ENABLED == false)
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    if row == nil or col == nil then
        return nil
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function isAlive(unit)
    return unit and unitHp(unit) > 0
end

local function threatPayload(threatResult)
    if not threatResult then
        return nil
    end
    return threatResult.threat or threatResult
end

local function threatEntries(threatResult)
    local threat = threatPayload(threatResult)
    return (threatResult and threatResult.damagingAttackers)
        or (threat and threat.damagingAttackers)
        or {}
end

local function getUnitAt(ai, state, row, col)
    if not (state and row and col) then
        return nil
    end
    if ai and ai.getUnitAtPosition then
        local ok, unit = pcall(ai.getUnitAtPosition, ai, state, row, col)
        if ok and unit then
            return unit
        end
    end
    for _, unit in ipairs(state.units or {}) do
        if unit and num(unit.row, -1) == num(row, -2) and num(unit.col, -1) == num(col, -2) then
            return unit
        end
    end
    return nil
end

local function calculateDamage(ai, attacker, target)
    if not (attacker and target) then
        return 0
    end
    if ai and ai.calculateDamage then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok and tonumber(value) then
            return math.max(0, num(value, 0))
        end
    end
    return math.max(0, num(attacker.atkDamage, 0))
end

local function isRangedUnit(ai, unit)
    if not unit then
        return false
    end
    local range = num(unit.atkRange or unit.attackRange or unit.range, nil)
    if range and range > 1 then
        return true
    end
    if ai and ai.unitHasTag then
        local ok, value = pcall(ai.unitHasTag, ai, unit, "ranged")
        if ok and value == true then
            return true
        end
    end
    local name = tostring(unit.name or "")
    return name == "Cloudstriker" or name == "Artillery"
end

local function isHub(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        local ok, value = pcall(ai.isHubUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return tostring(unit.name or "") == "Commandant"
end

local function isObstacle(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        local ok, value = pcall(ai.isObstacleUnit, ai, unit)
        if ok then
            return value == true
        end
    end
    return unit.player == 0 or tostring(unit.name or "") == "Rock"
end

local function manhattan(a, b)
    if not (a and b) then
        return nil
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function attackRange(unit)
    return math.max(1, num(unit and (unit.atkRange or unit.attackRange or unit.range), 1))
end

local function canAttackCell(ai, state, unit, target)
    if not (unit and target) then
        return false
    end
    if ai and ai.getValidAttackCells then
        local ok, cells = pcall(ai.getValidAttackCells, ai, state, unit.row, unit.col)
        if ok and type(cells) == "table" then
            for _, cell in ipairs(cells) do
                if cell and num(cell.row, -1) == num(target.row, -2) and num(cell.col, -1) == num(target.col, -2) then
                    return true
                end
            end
            return false
        end
    end
    local distance = manhattan(unit, target)
    return distance ~= nil and distance <= attackRange(unit)
end

local function sourceCanHitCell(ai, state, source, cell)
    return canAttackCell(ai, state, source, cell)
end

local function collectRangedSources(ai, beforeThreat)
    local out = {}
    for _, entry in ipairs(threatEntries(beforeThreat)) do
        local unit = entry and entry.unit
        local key = cellKey(unit)
        if key and isRangedUnit(ai, unit) then
            out[#out + 1] = {
                key = key,
                unit = unit,
                damage = num(entry and entry.damage, 0)
            }
        end
    end
    return out
end

local function supportCanFinish(ai, state, ctx, source, remainingHp, excluded)
    if remainingHp <= 0 then
        return false, 0
    end
    local playerId = ctx and ctx.aiPlayer
    local bestDamage = 0
    for _, unit in ipairs(state and state.units or {}) do
        local key = cellKey(unit)
        if unit
            and unit.player == playerId
            and isAlive(unit)
            and not isHub(ai, unit)
            and not isObstacle(ai, unit)
            and not (excluded and excluded[key] == true)
            and canAttackCell(ai, state, unit, source.unit) then
            local damage = calculateDamage(ai, unit, source.unit)
            bestDamage = math.max(bestDamage, damage)
            if damage >= remainingHp then
                return true, damage
            end
        end
    end
    return false, bestDamage
end

local function analyzeSourceAttacks(ai, beforeState, afterState, ctx, candidate, sourceByKey)
    local result = {
        damageBySource = {},
        usedAttackers = {},
        attackedRangedSource = false,
        rangedCounter = false,
        killNow = false,
        setupKill = false,
        setupDamage = 0,
        totalSourceDamage = 0
    }

    for _, action in ipairs(candidate and candidate.actions or {}) do
        if action and action.type == "attack" then
            local targetKey = cellKey(action.target)
            local source = targetKey and sourceByKey[targetKey] or nil
            if source then
                local attacker = getUnitAt(ai, beforeState, action.unit and action.unit.row, action.unit and action.unit.col)
                    or action.attackerUnit
                    or action.unit
                local damage = calculateDamage(ai, attacker, source.unit)
                result.attackedRangedSource = true
                result.damageBySource[targetKey] = num(result.damageBySource[targetKey], 0) + damage
                result.totalSourceDamage = result.totalSourceDamage + damage
                if isRangedUnit(ai, attacker) then
                    result.rangedCounter = true
                end
                local attackerKey = cellKey(attacker or action.unit)
                if attackerKey then
                    result.usedAttackers[attackerKey] = true
                end
            end
        end
    end

    for key, source in pairs(sourceByKey or {}) do
        local damage = num(result.damageBySource[key], 0)
        if damage > 0 then
            local afterSource = getUnitAt(ai, afterState, source.unit.row, source.unit.col)
            local killed = (not afterSource)
                or afterSource.player ~= source.unit.player
                or unitHp(afterSource) <= 0
                or damage >= unitHp(source.unit)
            if killed then
                result.killNow = true
            else
                local remaining = math.max(0, unitHp(source.unit) - damage)
                local canFinish, supportDamage = supportCanFinish(ai, afterState, ctx, source, remaining, result.usedAttackers)
                if canFinish then
                    result.setupKill = true
                    result.setupDamage = math.max(result.setupDamage, supportDamage)
                end
            end
        end
    end

    return result
end

local function analyzeReposition(ai, beforeState, afterState, ctx, candidate, sources)
    local out = {
        safe = false,
        awkward = false,
        static = false,
        movedThreatened = false,
        bestDistanceGain = 0
    }
    local playerId = ctx and ctx.aiPlayer
    for _, action in ipairs(candidate and candidate.actions or {}) do
        if action and action.type == "move" and action.unit and action.target then
            local unitBefore = getUnitAt(ai, beforeState, action.unit.row, action.unit.col) or action.unit
            if unitBefore and unitBefore.player == playerId then
                local beforeCell = {row = action.unit.row, col = action.unit.col}
                local afterCell = {row = action.target.row, col = action.target.col}
                for _, source in ipairs(sources or {}) do
                    local beforeHit = sourceCanHitCell(ai, beforeState, source.unit, beforeCell)
                    if beforeHit then
                        out.movedThreatened = true
                        local afterHit = sourceCanHitCell(ai, afterState, source.unit, afterCell)
                        local beforeDistance = manhattan(source.unit, beforeCell) or 0
                        local afterDistance = manhattan(source.unit, afterCell) or beforeDistance
                        local gain = afterDistance - beforeDistance
                        out.bestDistanceGain = math.max(out.bestDistanceGain, gain)
                        if not afterHit then
                            out.safe = true
                        elseif gain > 0 then
                            out.awkward = true
                        else
                            out.static = true
                        end
                    end
                end
            end
        end
    end
    return out
end

function M.analyze(ai, ctx, params)
    if not enabled(ctx) then
        return nil
    end
    params = params or {}
    local sources = collectRangedSources(ai, params.beforeThreat)
    if #sources == 0 then
        return nil
    end

    local sourceByKey = {}
    for _, source in ipairs(sources) do
        sourceByKey[source.key] = source
    end

    local beforeState = params.beforeState
    local afterState = params.afterState or beforeState
    local candidate = params.candidate
    local attacks = analyzeSourceAttacks(ai, beforeState, afterState, ctx, candidate, sourceByKey)
    local reposition = analyzeReposition(ai, beforeState, afterState, ctx, candidate, sources)
    local delta = params.delta or {}

    local out = {
        bonus = 0,
        penalty = 0,
        reasons = {},
        hasRangedSource = true,
        attackedRangedSource = attacks.attackedRangedSource == true,
        rangedCounter = attacks.rangedCounter == true,
        killNow = attacks.killNow == true,
        setupKill = attacks.setupKill == true,
        totalSourceDamage = attacks.totalSourceDamage,
        setupDamage = attacks.setupDamage,
        repositionSafe = reposition.safe == true,
        repositionAwkward = reposition.awkward == true,
        repositionStatic = reposition.static == true,
        repositionDistanceGain = reposition.bestDistanceGain
    }

    if attacks.killNow then
        out.bonus = out.bonus + cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_SOURCE_KILL_BONUS", 9000)
        out.reasons[#out.reasons + 1] = "soft_pressure_ranged_source_kill"
    elseif attacks.setupKill then
        out.bonus = out.bonus
            + cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_SOURCE_SETUP_KILL_BONUS", 5500)
            + attacks.setupDamage
                * cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_SOURCE_SETUP_DAMAGE_WEIGHT", 1200)
        out.reasons[#out.reasons + 1] = "soft_pressure_ranged_setup_kill"
    elseif attacks.attackedRangedSource and attacks.rangedCounter and not delta.reduced then
        out.penalty = out.penalty + cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_DUEL_FUTILE_PENALTY", 7000)
        out.reasons[#out.reasons + 1] = "soft_pressure_ranged_duel_futile"
    end

    if reposition.safe then
        out.bonus = out.bonus + cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_REPOSITION_SAFE_BONUS", 4500)
        out.reasons[#out.reasons + 1] = "soft_pressure_ranged_reposition_safe"
    elseif reposition.awkward then
        out.bonus = out.bonus
            + cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_REPOSITION_AWKWARD_BONUS", 2500)
            + math.max(0, reposition.bestDistanceGain)
                * cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_REPOSITION_DISTANCE_WEIGHT", 900)
        out.reasons[#out.reasons + 1] = "soft_pressure_ranged_reposition_awkward"
    elseif reposition.static then
        out.penalty = out.penalty + cfgNumber(ctx, "PIPELINE_V2_SOFT_DEFENSE_RANGED_REPOSITION_STATIC_PENALTY", 3000)
        out.reasons[#out.reasons + 1] = "soft_pressure_ranged_reposition_static"
    end

    if out.bonus == 0 and out.penalty == 0 then
        return nil
    end
    return out
end

return M
