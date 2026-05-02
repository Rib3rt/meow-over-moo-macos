local M = {}

local DEFAULT_SUPPORT_RADIUS = 2
local DEFAULT_REAR_MARGIN = 1
local DEFAULT_FRONTIER_TARGET_BONUS = 35
local DEFAULT_FRONTIER_COVER_BONUS = 120
local DEFAULT_SUPPORT_TARGET_PENALTY = 90
local DEFAULT_SUPPORT_COVER_BONUS = 150
local DEFAULT_REAR_TARGET_PENALTY = 160
local DEFAULT_REAR_COVER_BONUS = 55
local DEFAULT_FLOOR_MARGIN = 1
local DEFAULT_LOCAL_LATERAL_MARGIN = 0.75
local DEFAULT_PROJECTED_TARGET_BONUS = 80
local DEFAULT_PROJECTED_PROGRESS_WEIGHT = 100
local DEFAULT_PROJECTED_ROUTE_WEIGHT = 70
local DEFAULT_PROJECTED_VALUE_WEIGHT = 0.08

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function cfg(ctx, key, fallback)
    return num(ctx and ctx.cfg and ctx.cfg[key], fallback)
end

local function enabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_FRONTIER_ENABLED == false)
end

local function supportRadius(ctx)
    return math.max(1, cfg(ctx, "EARLY_POSITION_FRONTIER_SUPPORT_RADIUS", DEFAULT_SUPPORT_RADIUS))
end

local function rearMargin(ctx)
    return math.max(0, cfg(ctx, "EARLY_POSITION_FRONTIER_REAR_MARGIN", DEFAULT_REAR_MARGIN))
end

local function preTargetEnabled(ctx)
    return enabled(ctx) and not (ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_FRONTIER_PRE_TARGET_ENABLED == false)
end

local function floorMargin(ctx)
    return math.max(0, cfg(ctx, "EARLY_POSITION_FRONTIER_FLOOR_MARGIN", DEFAULT_FLOOR_MARGIN))
end

local function localLateralMargin(ctx)
    return math.max(0, cfg(ctx, "EARLY_POSITION_FRONTIER_LOCAL_LATERAL_MARGIN", DEFAULT_LOCAL_LATERAL_MARGIN))
end

local function projectedEnabled(ctx)
    return preTargetEnabled(ctx)
        and not (ctx and ctx.cfg and ctx.cfg.EARLY_POSITION_FRONTIER_PROJECTED_ENABLED == false)
end

local function projectedTargetBonus(ctx)
    return cfg(ctx, "EARLY_POSITION_FRONTIER_PROJECTED_TARGET_BONUS", DEFAULT_PROJECTED_TARGET_BONUS)
end

local function projectedProgressWeight(ctx)
    return cfg(ctx, "EARLY_POSITION_FRONTIER_PROJECTED_PROGRESS_WEIGHT", DEFAULT_PROJECTED_PROGRESS_WEIGHT)
end

local function projectedRouteWeight(ctx)
    return cfg(ctx, "EARLY_POSITION_FRONTIER_PROJECTED_ROUTE_WEIGHT", DEFAULT_PROJECTED_ROUTE_WEIGHT)
end

local function projectedValueWeight(ctx)
    return cfg(ctx, "EARLY_POSITION_FRONTIER_PROJECTED_VALUE_WEIGHT", DEFAULT_PROJECTED_VALUE_WEIGHT)
end

local function targetMinDistance(ctx)
    return math.max(1, cfg(ctx, "EARLY_POSITION_TARGET_MIN_DISTANCE", 2))
end

local function targetLimit(ctx)
    return math.max(1, cfg(ctx, "EARLY_POSITION_MAP_TOP_N", 8))
end

local function primaryByKey(primaryTargets)
    local result = {}
    for _, cell in ipairs(primaryTargets or {}) do
        result[cell.key or cellKey(cell)] = true
    end
    return result
end

local function ownedFrontierCells(cells)
    local result = {}
    local floorProgress = -math.huge
    for _, cell in ipairs(cells or {}) do
        if cell and (cell.status == "owned_uncovered" or cell.status == "owned_covered") then
            result[#result + 1] = cell
            floorProgress = math.max(floorProgress, num(cell.progress, 0))
        end
    end
    if floorProgress == -math.huge then
        floorProgress = nil
    end
    return result, floorProgress
end

local function nearestPrimary(primaryTargets, cell)
    local best = nil
    local bestDistance = 99
    for _, primary in ipairs(primaryTargets or {}) do
        local distance = manhattan(cell, primary)
        if distance < bestDistance then
            best = primary
            bestDistance = distance
        elseif distance == bestDistance
            and num(primary and primary.progress, 0) > num(best and best.progress, 0) then
            best = primary
        end
    end
    return best, bestDistance
end

local function nearestOwnedFrontier(ownedCells, cell)
    local best = nil
    local bestDistance = 99
    for _, owned in ipairs(ownedCells or {}) do
        local distance = manhattan(cell, owned)
        if distance < bestDistance then
            best = owned
            bestDistance = distance
        elseif distance == bestDistance
            and num(owned and owned.progress, 0) > num(best and best.progress, 0) then
            best = owned
        end
    end
    return best, bestDistance
end

local function nearestProjectedAnchor(anchors, cell)
    local best = nil
    local bestDistance = 99
    for _, anchor in ipairs(anchors or {}) do
        local distance = manhattan(cell, anchor)
        if distance < bestDistance then
            best = anchor
            bestDistance = distance
        elseif distance == bestDistance
            and num(anchor and anchor.progress, 0) > num(best and best.progress, 0) then
            best = anchor
        end
    end
    return best, bestDistance
end

local function appendReason(cell, reason, value)
    if not cell or value == 0 then
        return
    end
    cell.reasons = cell.reasons or {}
    cell.reasons[#cell.reasons + 1] = {
        reason = reason,
        value = value
    }
end

local function applyTargetDelta(cell, delta)
    if not cell or delta == 0 then
        return
    end
    local before = num(cell.value, 0)
    local positionBefore = num(cell.earlyPositionValue, num(cell.earlyStrategicValue, before))
    cell.value = before + delta
    cell.earlyPositionValue = positionBefore + delta
    cell.earlyFrontierTargetDelta = num(cell.earlyFrontierTargetDelta, 0) + delta
end

local function applyCoverBonus(cell, bonus)
    if not cell or bonus == 0 then
        return
    end
    cell.earlyCoverValueBonus = num(cell.earlyCoverValueBonus, 0) + bonus
end

local function mark(cell, role, nearest, distance, progressGap)
    cell.earlyFrontierRole = role
    if nearest then
        cell.earlySupportForKey = nearest.key or cellKey(nearest)
        cell.earlyFrontierDistance = distance
        cell.earlyFrontierProgressGap = progressGap
    end
end

local function classifyCell(cell, primarySelectedByKey, primaryTargets, ctx)
    local key = cell.key or cellKey(cell)
    if primarySelectedByKey[key] then
        return "frontier_target", nil, 0, 0
    end

    local nearest, distance = nearestPrimary(primaryTargets, cell)
    if not nearest then
        return nil, nil, 99, 0
    end

    local progressGap = num(nearest.progress, 0) - num(cell.progress, 0)
    if progressGap >= 0 and distance <= supportRadius(ctx) then
        if cell.status == "owned_uncovered" or cell.status == "owned_covered" then
            return "frontier_hold", nearest, distance, progressGap
        end
        return "support_cover", nearest, distance, progressGap
    end

    if progressGap >= rearMargin(ctx) then
        return "rear_support", nearest, distance, progressGap
    end

    return nil, nearest, distance, progressGap
end

local function applyRole(cell, role, nearest, distance, progressGap, ctx)
    if role == "frontier_target" then
        local targetBonus = cfg(ctx, "EARLY_POSITION_FRONTIER_TARGET_BONUS", DEFAULT_FRONTIER_TARGET_BONUS)
        local coverBonus = cfg(ctx, "EARLY_POSITION_FRONTIER_COVER_BONUS", DEFAULT_FRONTIER_COVER_BONUS)
        mark(cell, role, nearest, distance, progressGap)
        cell.earlyPrimaryTarget = true
        applyTargetDelta(cell, targetBonus)
        applyCoverBonus(cell, coverBonus)
        appendReason(cell, "frontier_target", targetBonus)
        return
    end

    if role == "frontier_hold" then
        local coverBonus = cfg(ctx, "EARLY_POSITION_FRONTIER_COVER_BONUS", DEFAULT_FRONTIER_COVER_BONUS)
        mark(cell, role, nearest, distance, progressGap)
        applyCoverBonus(cell, coverBonus)
        appendReason(cell, "frontier_hold_cover", coverBonus)
        return
    end

    if role == "support_cover" then
        local targetPenalty = -cfg(ctx, "EARLY_POSITION_FRONTIER_SUPPORT_TARGET_PENALTY", DEFAULT_SUPPORT_TARGET_PENALTY)
        local coverBonus = cfg(ctx, "EARLY_POSITION_FRONTIER_SUPPORT_COVER_BONUS", DEFAULT_SUPPORT_COVER_BONUS)
        mark(cell, role, nearest, distance, progressGap)
        cell.earlySupportTarget = true
        applyTargetDelta(cell, targetPenalty)
        applyCoverBonus(cell, coverBonus)
        appendReason(cell, "frontier_support_target_penalty", targetPenalty)
        appendReason(cell, "frontier_support_cover", coverBonus)
        return
    end

    if role == "rear_support" then
        local targetPenalty = -cfg(ctx, "EARLY_POSITION_FRONTIER_REAR_TARGET_PENALTY", DEFAULT_REAR_TARGET_PENALTY)
        local coverBonus = cfg(ctx, "EARLY_POSITION_FRONTIER_REAR_COVER_BONUS", DEFAULT_REAR_COVER_BONUS)
        mark(cell, role, nearest, distance, progressGap)
        applyTargetDelta(cell, targetPenalty)
        applyCoverBonus(cell, coverBonus)
        appendReason(cell, "frontier_rear_target_penalty", targetPenalty)
        appendReason(cell, "frontier_rear_cover", coverBonus)
    end
end

local function canBeProjectedFrontier(cell)
    return cell
        and (cell.status == "free_target" or cell.status == "next_expansion")
        and (cell.reachable == true or cell.deployable == true)
        and cell.earlyFrontierPreTargetSuppressed ~= true
end

local function projectedCandidateAllowed(cell, requireGood)
    if requireGood then
        return cell and cell.goodEarlyStrategic == true
    end
    return cell and cell.goodEarlyStrategic ~= false
end

local function projectedScore(cell, ctx)
    local progressScore = num(cell and cell.progress, 0) * projectedProgressWeight(ctx)
    local routeScore = num(cell and cell.routeProximity, 0) * projectedRouteWeight(ctx)
    local valueScore = num(cell and cell.value, 0) * projectedValueWeight(ctx)
    local lateralScore = num(cell and cell.lateralExpansionValue, 0) * 0.35
    local tollScore = num(cell and cell.tollRouteValue, 0) * 0.20
    return progressScore + routeScore + valueScore + lateralScore + tollScore
end

local function sortProjected(candidates, ctx)
    table.sort(candidates, function(a, b)
        local as = projectedScore(a, ctx)
        local bs = projectedScore(b, ctx)
        if as == bs then
            if num(a and a.value, 0) == num(b and b.value, 0) then
                return tostring(a and (a.key or cellKey(a)) or "") < tostring(b and (b.key or cellKey(b)) or "")
            end
            return num(a and a.value, 0) > num(b and b.value, 0)
        end
        return as > bs
    end)
end

local function collectProjectedCandidates(cells, requireGood)
    local result = {}
    for _, cell in ipairs(cells or {}) do
        if canBeProjectedFrontier(cell) and projectedCandidateAllowed(cell, requireGood) then
            result[#result + 1] = cell
        end
    end
    return result
end

local function selectProjectedAnchors(cells, ctx)
    local candidates = collectProjectedCandidates(cells, true)
    if #candidates == 0 then
        candidates = collectProjectedCandidates(cells, false)
    end
    sortProjected(candidates, ctx)

    local anchors = {}
    local selectedByKey = {}
    local minDistance = targetMinDistance(ctx)
    local limit = targetLimit(ctx)
    for _, cell in ipairs(candidates) do
        local tooClose = false
        for _, selected in ipairs(anchors) do
            if manhattan(cell, selected) < minDistance then
                tooClose = true
                break
            end
        end
        if not tooClose then
            anchors[#anchors + 1] = cell
            selectedByKey[cell.key or cellKey(cell)] = true
            if #anchors >= limit then
                break
            end
        end
    end

    return anchors, selectedByKey, #candidates
end

local function sameLocalFrontierLane(cell, owned, ctx)
    if not (cell and owned) then
        return false
    end
    return math.abs(num(cell.lateral, 0) - num(owned.lateral, 0)) <= localLateralMargin(ctx)
end

local function applyProjectedFrontier(cells, ctx)
    local meta = {
        enabled = projectedEnabled(ctx),
        considered = 0,
        anchors = 0,
        support = 0,
        rear = 0,
        suppressed = 0
    }
    if not meta.enabled then
        return meta
    end

    local anchors, selectedByKey, considered = selectProjectedAnchors(cells, ctx)
    meta.considered = considered
    meta.anchors = #anchors
    if #anchors == 0 then
        return meta
    end

    local bonus = projectedTargetBonus(ctx)
    for _, anchor in ipairs(anchors) do
        anchor.earlyProjectedFrontierAnchor = true
        anchor.earlyProjectedFrontierScore = projectedScore(anchor, ctx)
        applyTargetDelta(anchor, bonus)
        appendReason(anchor, "projected_frontier", bonus)
    end

    local minDistance = targetMinDistance(ctx)
    for _, cell in ipairs(cells or {}) do
        local key = cell and (cell.key or cellKey(cell))
        if canBeProjectedFrontier(cell) and selectedByKey[key] ~= true then
            local nearest, distance = nearestProjectedAnchor(anchors, cell)
            local progressGap = num(nearest and nearest.progress, 0) - num(cell.progress, 0)
            if nearest and progressGap >= 0 and distance < minDistance then
                cell.earlyFrontierPreTargetSuppressed = true
                cell.earlyFrontierPreTargetReason = "frontier_projected_support"
                cell.earlyPrimaryTarget = false
                applyRole(cell, "support_cover", nearest, distance, progressGap, ctx)
                appendReason(cell, "frontier_projected_support", -1)
                meta.suppressed = meta.suppressed + 1
                meta.support = meta.support + 1
            end
        end
    end

    return meta
end

function M.apply(cells, primaryTargets, ctx)
    local meta = {
        enabled = enabled(ctx),
        primary = 0,
        support = 0,
        hold = 0,
        rear = 0
    }

    if not meta.enabled or #(primaryTargets or {}) == 0 then
        return meta
    end

    local selectedByKey = primaryByKey(primaryTargets)
    for _, cell in ipairs(cells or {}) do
        local role, nearest, distance, progressGap = classifyCell(cell, selectedByKey, primaryTargets, ctx)
        if cell and cell.earlyFrontierPreTargetSuppressed == true and role ~= "frontier_target" then
            role = cell.earlyFrontierRole
        else
            applyRole(cell, role, nearest, distance, progressGap, ctx)
        end
        if role == "frontier_target" then
            meta.primary = meta.primary + 1
        elseif role == "support_cover" then
            meta.support = meta.support + 1
        elseif role == "frontier_hold" then
            meta.hold = meta.hold + 1
        elseif role == "rear_support" then
            meta.rear = meta.rear + 1
        end
    end

    return meta
end

function M.preselect(cells, ctx)
    local meta = {
        enabled = preTargetEnabled(ctx),
        floorProgress = nil,
        owned = 0,
        support = 0,
        rear = 0,
        suppressed = 0,
        projected = nil
    }

    if not meta.enabled then
        return meta
    end

    local ownedCells, floorProgress = ownedFrontierCells(cells)
    meta.floorProgress = floorProgress
    meta.owned = #ownedCells

    if floorProgress then
        local margin = floorMargin(ctx)
        for _, cell in ipairs(cells or {}) do
            if cell
                and (cell.status == "free_target" or cell.status == "next_expansion")
                and (cell.reachable == true or cell.deployable == true) then
                local progressGap = floorProgress - num(cell.progress, 0)
                local nearest, distance = nearestOwnedFrontier(ownedCells, cell)
                if progressGap >= margin
                    and nearest
                    and (distance <= supportRadius(ctx) or sameLocalFrontierLane(cell, nearest, ctx)) then
                    local role = distance <= supportRadius(ctx) and "support_cover" or "rear_support"
                    cell.earlyFrontierPreTargetSuppressed = true
                    cell.earlyFrontierPreTargetReason = "frontier_floor"
                    cell.earlyPrimaryTarget = false
                    applyRole(cell, role, nearest, distance, progressGap, ctx)
                    appendReason(cell, "frontier_floor", -1)
                    meta.suppressed = meta.suppressed + 1
                    if role == "support_cover" then
                        meta.support = meta.support + 1
                    else
                        meta.rear = meta.rear + 1
                    end
                end
            end
        end
    end

    meta.projected = applyProjectedFrontier(cells, ctx)
    if meta.projected then
        meta.support = meta.support + num(meta.projected.support, 0)
        meta.rear = meta.rear + num(meta.projected.rear, 0)
        meta.suppressed = meta.suppressed + num(meta.projected.suppressed, 0)
    end

    return meta
end

M._private = {
    enabled = enabled,
    preTargetEnabled = preTargetEnabled,
    projectedEnabled = projectedEnabled,
    supportRadius = supportRadius,
    rearMargin = rearMargin,
    floorMargin = floorMargin,
    localLateralMargin = localLateralMargin,
    ownedFrontierCells = ownedFrontierCells,
    nearestPrimary = nearestPrimary,
    nearestOwnedFrontier = nearestOwnedFrontier,
    nearestProjectedAnchor = nearestProjectedAnchor,
    classifyCell = classifyCell,
    projectedScore = projectedScore,
    selectProjectedAnchors = selectProjectedAnchors,
    sameLocalFrontierLane = sameLocalFrontierLane,
    manhattan = manhattan
}

return M
