local punishMap = require("ai_tournament.punish_map")
local unitsInfo = require("unitsInfo")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function enabled(ctx)
    local cfg = ctx and ctx.cfg or {}
    if cfg.PIPELINE_V2_EARLY_MOVE_RISK_ORDERING_ENABLED == false then
        return false
    end
    if cfg.PIPELINE_V2_DESTINATION_EXPOSURE_SCORING_ENABLED == false then
        return false
    end
    return cfg.PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED ~= false
end

local function getUnitAt(state, row, col)
    for _, unit in ipairs((state and state.units) or {}) do
        if unit and num(unit.row, -1) == num(row, -2) and num(unit.col, -1) == num(col, -2) then
            return unit
        end
    end
    return nil
end

local function samePlayer(a, b)
    local na = tonumber(a)
    local nb = tonumber(b)
    if na and nb then
        return na == nb
    end
    return tostring(a) == tostring(b)
end

local function alive(unit)
    return unit and num(unit.currentHp or unit.startingHp, 0) > 0
end

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function manhattan(a, b)
    if not (a and b) then
        return 999
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function attackRange(ai, unit)
    if ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        local ok, value = pcall(ai.unitsInfo.getUnitAttackRange, ai.unitsInfo, unit, "EARLY_MOVE_RISK_DIRECT_CONTACT")
        if ok then
            return num(value, 1)
        end
    end
    if unitsInfo and unitsInfo.getUnitAttackRange then
        local ok, value = pcall(unitsInfo.getUnitAttackRange, unitsInfo, unit, "EARLY_MOVE_RISK_DIRECT_CONTACT")
        if ok then
            return num(value, 1)
        end
    end
    return 1
end

local function calculateDamage(ai, attacker, target)
    if ai and ai.calculateDamage then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    if ai and ai.unitsInfo and ai.unitsInfo.calculateAttackDamage then
        local ok, value = pcall(ai.unitsInfo.calculateAttackDamage, ai.unitsInfo, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    if unitsInfo and unitsInfo.calculateAttackDamage then
        local ok, value = pcall(unitsInfo.calculateAttackDamage, unitsInfo, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    return 0
end

local function directMeleeContact(ai, state, moved)
    local result = {
        active = false,
        damage = 0,
        attackers = 0,
        lethal = false
    }
    if not (state and moved) then
        return result
    end
    for _, enemy in ipairs(state.units or {}) do
        if alive(enemy)
            and enemy.name ~= "Rock"
            and enemy.player ~= nil
            and moved.player ~= nil
            and not samePlayer(enemy.player, moved.player)
            and attackRange(ai, enemy) <= 1
            and manhattan(enemy, moved) <= 1 then
            local damage = calculateDamage(ai, enemy, moved)
            if damage > 0 then
                result.active = true
                result.attackers = result.attackers + 1
                result.damage = math.max(result.damage, damage)
                result.lethal = result.lethal or damage >= unitHp(moved)
            end
        end
    end
    return result
end

local function callIsSuicidal(ai, beforeState, action)
    if not (ai and ai.isSuicidalMovement and beforeState and action and action.target) then
        return false
    end
    local unit = action.unit and getUnitAt(beforeState, action.unit.row, action.unit.col) or action.unit
    local ok, result = pcall(ai.isSuicidalMovement, ai, beforeState, action.target, unit)
    return ok and result == true
end

local function exposurePenalty(ctx, damage, lethal, suicidal)
    local cfg = ctx and ctx.cfg or {}
    local penalty = 0
    if lethal == true then
        penalty = num(cfg.PIPELINE_V2_EARLY_DESTINATION_LETHAL_PENALTY, 80000)
            + num(damage, 0) * num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT, 7000)
    elseif num(damage, 0) > 0 then
        penalty = num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_PENALTY, 22000)
            + num(damage, 0) * num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT, 7000)
    end
    if suicidal == true then
        penalty = math.max(penalty, num(cfg.PIPELINE_V2_EARLY_SUICIDAL_MOVE_PENALTY, 120000))
    end
    return math.max(0, penalty)
end

local function directContactPenalty(ctx, contact)
    if not (contact and contact.active == true) then
        return 0
    end
    local cfg = ctx and ctx.cfg or {}
    return num(cfg.PIPELINE_V2_EARLY_DIRECT_MELEE_CONTACT_PENALTY, 45000)
        + num(contact.damage, 0) * num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT, 7000)
end

function M.analyze(ai, beforeState, afterState, ctx, action)
    local result = {
        enabled = enabled(ctx),
        penalty = 0,
        damage = 0,
        lethal = false,
        suicidal = false,
        reason = nil
    }
    if not result.enabled then
        return result
    end
    if not (action and action.type == "move" and action.target and afterState) then
        return result
    end

    local moved = getUnitAt(afterState, action.target.row, action.target.col)
    if not moved then
        return result
    end

    local analysis = punishMap.analyzeCell(afterState, ai, ctx, moved, moved)
    local reply = analysis and analysis.enemyBestReply or nil
    result.damage = num(reply and (reply.damage or reply.expectedDamage), 0)
    result.lethal = reply and reply.lethal == true or false
    result.suicidal = callIsSuicidal(ai, beforeState, action)
    local contact = directMeleeContact(ai, afterState, moved)
    result.directMeleeContact = contact.active == true
    result.directMeleeContactDamage = contact.damage
    result.directMeleeContactAttackers = contact.attackers
    result.lethal = result.lethal or contact.lethal == true
    result.damage = math.max(result.damage, num(contact.damage, 0))
    result.penalty = exposurePenalty(ctx, result.damage, result.lethal, result.suicidal)
        + directContactPenalty(ctx, contact)

    if result.suicidal then
        result.reason = "suicidal_move"
    elseif result.directMeleeContact then
        result.reason = result.lethal and "enemy_direct_melee_lethal_contact" or "enemy_direct_melee_contact"
    elseif result.lethal then
        result.reason = "enemy_lethal_reply"
    elseif result.damage > 0 then
        result.reason = "enemy_damage_reply"
    end
    return result
end

function M.applyToScore(score, risk, stats)
    local penalty = num(risk and risk.penalty, 0)
    if penalty <= 0 then
        return score
    end
    if stats then
        stats.moveRiskPenalized = num(stats.moveRiskPenalized, 0) + 1
        stats.moveRiskPenaltyMax = math.max(num(stats.moveRiskPenaltyMax, 0), penalty)
        if risk.lethal == true then
            stats.moveRiskLethal = num(stats.moveRiskLethal, 0) + 1
        end
        if risk.suicidal == true then
            stats.moveRiskSuicidal = num(stats.moveRiskSuicidal, 0) + 1
        end
        if risk.directMeleeContact == true then
            stats.moveRiskDirectMeleeContact = num(stats.moveRiskDirectMeleeContact, 0) + 1
        end
    end
    return num(score, 0) - penalty
end

return M
