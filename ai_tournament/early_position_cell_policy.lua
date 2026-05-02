local M = {}

local DEFAULT_MIN_VALUE = 120
local DEFAULT_HOLD_THREAT_COVER_BONUS = 180
local DEFAULT_RETREAT_SCORE_BONUS = 900

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function policyEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_SAFE_CELL_POLICY_ENABLED == false)
end

local function occupiedThreatHoldEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_HOLD_NONLETHAL_OCCUPIED_THREAT == false)
end

local function retreatEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_RETREAT_ENABLED == false)
end

local function threatReply(cell)
    if not cell then
        return nil
    end
    if type(cell.occupantEnemyBestReply) == "table" then
        return cell.occupantEnemyBestReply
    end
    if type(cell.occupantThreat) == "table" then
        return cell.occupantThreat
    end
    if type(cell.enemyPunish) == "table" then
        return cell.enemyPunish
    end
    if cell.risk and type(cell.risk.enemyPunish) == "table" then
        return cell.risk.enemyPunish
    end
    return nil
end

local function threatDamageWithKnown(cell)
    if cell and cell.occupantThreatDamage ~= nil then
        return num(cell.occupantThreatDamage, 0), true
    end
    local reply = threatReply(cell)
    if reply and (reply.damage ~= nil or reply.expectedDamage ~= nil) then
        return num(reply.damage, num(reply.expectedDamage, 0)), true
    end
    return 0, false
end

local function hasEnemyThreatSignal(cell)
    return M.enemyAttackCount(cell) > 0
        or M.enemyMoveAttackCount(cell) > 0
        or M.directlyAttackableByEnemy(cell)
        or M.enemyPunishAvailable(cell)
        or M.isContested(cell)
end

local function knownNonLethalThreat(cell)
    local _, knownDamage = threatDamageWithKnown(cell)
    if knownDamage then
        return true
    end
    local reply = threatReply(cell)
    return reply and reply.lethal == false
end

local function holdThreatCoverBonus(ctx, opts)
    return num(
        opts and opts.holdThreatCoverBonus,
        num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_HOLD_THREAT_COVER_BONUS, DEFAULT_HOLD_THREAT_COVER_BONUS)
    )
end

function M.minStrategicValue(ctx, opts)
    return num(
        opts and opts.minValue,
        num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_STRATEGIC_MIN_VALUE, DEFAULT_MIN_VALUE)
    )
end

function M.retreatScoreBonus(ctx, opts)
    return num(
        opts and opts.retreatScoreBonus,
        num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_EARLY_RETREAT_SCORE_BONUS, DEFAULT_RETREAT_SCORE_BONUS)
    )
end

function M.cellValue(cell)
    return num(cell and cell.earlyPositionValue, num(cell and cell.earlyStrategicValue, num(cell and cell.value, 0)))
end

function M.enemyAttackCount(cell)
    if cell and cell.enemyAttackCount ~= nil then
        return num(cell.enemyAttackCount, 0)
    end
    if cell and cell.risk and cell.risk.enemyAttack ~= nil then
        return num(cell.risk.enemyAttack, 0)
    end
    return num(cell and cell.attackInfluence and cell.attackInfluence.enemy and cell.attackInfluence.enemy.count, 0)
end

function M.enemyMoveAttackCount(cell)
    if cell and cell.enemyMoveAttackCount ~= nil then
        return num(cell.enemyMoveAttackCount, 0)
    end
    if cell and cell.risk and cell.risk.enemyMoveAttack ~= nil then
        return num(cell.risk.enemyMoveAttack, 0)
    end
    return num(cell and cell.moveAttackInfluence and cell.moveAttackInfluence.enemy and cell.moveAttackInfluence.enemy.count, 0)
end

function M.directlyAttackableByEnemy(cell)
    if cell and cell.directlyAttackableByEnemy ~= nil then
        return cell.directlyAttackableByEnemy == true
    end
    return M.enemyAttackCount(cell) > 0
end

function M.enemyPunishAvailable(cell)
    if not cell then
        return false
    end
    if cell.enemyPunish ~= nil then
        return cell.enemyPunish ~= false
    end
    if cell.risk and cell.risk.enemyPunish ~= nil then
        return cell.risk.enemyPunish == true
    end
    return false
end

function M.isContested(cell)
    return cell and cell.attackContested == true
end

function M.isGoodStrategicCell(cell, ctx, opts)
    if not cell then
        return false
    end
    if not policyEnabled(ctx) then
        return true
    end
    if cell.earlyPrimaryTarget == false and not (opts and opts.ignorePrimaryTarget == true) then
        return false
    end
    return M.cellValue(cell) >= M.minStrategicValue(ctx, opts)
        and M.enemyAttackCount(cell) <= 0
        and M.enemyMoveAttackCount(cell) <= 0
        and not M.directlyAttackableByEnemy(cell)
        and not M.enemyPunishAvailable(cell)
        and not M.isContested(cell)
end

function M.occupantThreatDamage(cell)
    local damage = threatDamageWithKnown(cell)
    return damage
end

function M.occupantThreatLethal(cell)
    if cell and cell.occupantThreatLethal ~= nil then
        return cell.occupantThreatLethal == true
    end
    local damage, known = threatDamageWithKnown(cell)
    local hp = tonumber(cell and (cell.occupantHp or cell.occupantCurrentHp))
    if known and hp and hp > 0 and damage >= hp then
        return true
    end
    local reply = threatReply(cell)
    if reply and reply.lethal ~= nil then
        return reply.lethal == true
    end
    return cell and cell.risk and cell.risk.lethalPunish == true or false
end

function M.isHoldableOccupiedStrategicCell(cell, ctx, opts)
    if not cell then
        return false
    end
    if not policyEnabled(ctx) then
        return true
    end
    if cell.occupiedByUs == true and M.requiresRetreat(cell, ctx, opts) then
        return false
    end
    if M.cellValue(cell) < M.minStrategicValue(ctx, opts) then
        return false
    end
    if M.isGoodStrategicCell(cell, ctx, opts) then
        return true
    end
    if not (cell.occupiedByUs == true and occupiedThreatHoldEnabled(ctx)) then
        return false
    end
    if not hasEnemyThreatSignal(cell) then
        return false
    end
    if M.occupantThreatLethal(cell) then
        return false
    end

    return knownNonLethalThreat(cell)
end

function M.requiresRetreat(cell, ctx, opts)
    if not (cell and cell.occupiedByUs == true) then
        return false
    end
    if not (policyEnabled(ctx) and retreatEnabled(ctx)) then
        return false
    end
    return M.occupantThreatLethal(cell) == true
end

function M.hasHoldNonLethalThreat(cell, ctx, opts)
    if not cell then
        return false
    end
    if cell.holdNonLethalThreat ~= nil then
        return cell.holdNonLethalThreat == true
    end
    if M.isGoodStrategicCell(cell, ctx, opts) then
        return false
    end
    return M.isHoldableOccupiedStrategicCell(cell, ctx, opts)
end

function M.coverUrgencyBonus(cell, ctx, opts)
    local frontierBonus = num(cell and cell.earlyCoverValueBonus, 0)
    if cell and cell.coverUrgencyBonus ~= nil then
        return num(cell.coverUrgencyBonus, 0) + frontierBonus
    end
    if M.hasHoldNonLethalThreat(cell, ctx, opts) then
        return holdThreatCoverBonus(ctx, opts) + frontierBonus
    end
    return frontierBonus
end

function M.rejectReason(cell, ctx, opts)
    if not cell then
        return "missing_cell"
    end
    if not policyEnabled(ctx) then
        return nil
    end
    if M.requiresRetreat(cell, ctx, opts) then
        return "enemy_lethal_reply"
    end
    if cell.earlyFrontierPreTargetSuppressed == true and not (opts and opts.ignorePrimaryTarget == true) then
        return cell.earlyFrontierPreTargetReason or "frontier_floor"
    end
    if cell.earlyPrimaryTarget == false and not (opts and opts.ignorePrimaryTarget == true) then
        return "primary_target_spacing"
    end
    if M.cellValue(cell) < M.minStrategicValue(ctx, opts) then
        return "low_value"
    end
    if M.isContested(cell) then
        return "attack_contested"
    end
    if M.directlyAttackableByEnemy(cell) or M.enemyAttackCount(cell) > 0 then
        return "enemy_attack"
    end
    if M.enemyMoveAttackCount(cell) > 0 then
        return "enemy_move_attack"
    end
    if M.enemyPunishAvailable(cell) then
        return "enemy_punish"
    end
    return nil
end

function M.sortLowestValueFirst(cells)
    table.sort(cells, function(a, b)
        local av = M.cellValue(a)
        local bv = M.cellValue(b)
        if av == bv then
            return tostring(a and a.key or "") < tostring(b and b.key or "")
        end
        return av < bv
    end)
end

M._private = {
    policyEnabled = policyEnabled,
    occupiedThreatHoldEnabled = occupiedThreatHoldEnabled,
    retreatEnabled = retreatEnabled,
    holdThreatCoverBonus = holdThreatCoverBonus,
    threatDamageWithKnown = threatDamageWithKnown,
    num = num
}

return M
