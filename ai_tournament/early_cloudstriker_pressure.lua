local punishMap = require("ai_tournament.punish_map")

local M = {}

local DEFAULT_BLOCKED_HOLD_PENALTY = 340

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function manhattan(a, b)
    if not (a and b) then
        return 99
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function enabled(ctx)
    return not (ctx
        and ctx.cfg
        and ctx.cfg.PIPELINE_V2_EARLY_CLOUDSTRIKER_BLOCKED_PRESSURE_ENABLED == false)
end

local function holdPenalty(ctx)
    return num(
        ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_CLOUDSTRIKER_BLOCKED_HOLD_PENALTY,
        DEFAULT_BLOCKED_HOLD_PENALTY
    )
end

local function opponent(playerId)
    return playerId == 1 and 2 or 1
end

local function enemyHubFor(state, ctx, unit)
    local playerId = ctx and ctx.aiPlayer or unit and unit.player or 1
    local enemyPlayer = ctx and ctx.enemyPlayer or opponent(playerId)
    return state and state.commandHubs and state.commandHubs[enemyPlayer] or nil
end

local function isCloudstriker(unit)
    return unit and tostring(unit.name or "") == "Cloudstriker"
end

local function sameLineInCloudstrikerRange(fromCell, targetCell)
    if not (fromCell and targetCell) then
        return false
    end
    local sameLine = num(fromCell.row, 0) == num(targetCell.row, 0)
        or num(fromCell.col, 0) == num(targetCell.col, 0)
    local distance = manhattan(fromCell, targetCell)
    return sameLine and distance >= 2 and distance <= 3
end

local function blockerBetween(ai, state, fromCell, targetCell)
    if not (fromCell and targetCell) then
        return nil
    end
    local rowStep = targetCell.row == fromCell.row and 0 or (targetCell.row > fromCell.row and 1 or -1)
    local colStep = targetCell.col == fromCell.col and 0 or (targetCell.col > fromCell.col and 1 or -1)
    local row = fromCell.row + rowStep
    local col = fromCell.col + colStep
    local priv = punishMap and punishMap._private or {}
    while row ~= targetCell.row or col ~= targetCell.col do
        local blocker = priv.getUnitAt and priv.getUnitAt(ai, state, row, col, true) or nil
        if blocker then
            return blocker
        end
        row = row + rowStep
        col = col + colStep
    end
    return nil
end

local function canShootEnemyHub(ai, state, unit, fromCell, enemyHub)
    local priv = punishMap and punishMap._private or {}
    if not priv.canAttackCellFrom then
        return false
    end
    return priv.canAttackCellFrom(ai, state, unit, fromCell, enemyHub, {allowEmptyTarget = false}) == true
end

function M.evaluateHold(ai, state, ctx, unit, cell, enemyReply)
    if not (enabled(ctx) and isCloudstriker(unit) and cell) then
        return nil
    end

    local enemyHub = enemyHubFor(state, ctx, unit)
    if not sameLineInCloudstrikerRange(cell, enemyHub) then
        return nil
    end
    if canShootEnemyHub(ai, state, unit, cell, enemyHub) then
        return nil
    end

    local damage = num(enemyReply and (enemyReply.damage or enemyReply.expectedDamage), 0)
    local hp = num(unit and (unit.currentHp or unit.startingHp), 0)
    local lethal = enemyReply and enemyReply.lethal == true or (damage > 0 and hp > 0 and damage >= hp)
    if damage <= 0 or lethal then
        return nil
    end

    return {
        penalty = holdPenalty(ctx),
        damage = damage,
        hp = hp,
        enemyHub = {
            row = enemyHub.row,
            col = enemyHub.col
        },
        blocker = blockerBetween(ai, state, cell, enemyHub)
    }
end

M._private = {
    enabled = enabled,
    holdPenalty = holdPenalty,
    sameLineInCloudstrikerRange = sameLineInCloudstrikerRange,
    blockerBetween = blockerBetween,
    isCloudstriker = isCloudstriker
}

return M
