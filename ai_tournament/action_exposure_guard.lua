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

local function scoringEnabled(ctx)
    local cfg = ctx and ctx.cfg or nil
    if cfg and cfg.PIPELINE_V2_DESTINATION_EXPOSURE_SCORING_ENABLED == false then
        return false
    end
    return not (cfg and cfg.PIPELINE_V2_DESTINATION_EXPOSURE_GUARD_ENABLED == false)
end

local function targetCell(action)
    if not action then
        return nil
    end
    if action.target then
        return action.target
    end
    if action.toRow and action.toCol then
        return {row = action.toRow, col = action.toCol}
    end
    if action.row and action.col then
        return {row = action.row, col = action.col}
    end
    return nil
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

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function alive(unit)
    return unit and unitHp(unit) > 0
end

local function samePlayer(a, b)
    local na = tonumber(a)
    local nb = tonumber(b)
    if na and nb then
        return na == nb
    end
    return tostring(a) == tostring(b)
end

local function manhattan(a, b)
    if not (a and b) then
        return 999
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function attackRange(ai, unit)
    if ai and ai.unitsInfo and ai.unitsInfo.getUnitAttackRange then
        local ok, value = pcall(ai.unitsInfo.getUnitAttackRange, ai.unitsInfo, unit, "DESTINATION_EXPOSURE_COMMANDANT")
        if ok then
            return num(value, 1)
        end
    end
    if unitsInfo and unitsInfo.getUnitAttackRange then
        local ok, value = pcall(unitsInfo.getUnitAttackRange, unitsInfo, unit, "DESTINATION_EXPOSURE_COMMANDANT")
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

local function commandantThreat(ai, state, unit, target)
    if not (state and state.commandHubs and unit and target) then
        return nil
    end

    local best = nil
    for playerId, hub in pairs(state.commandHubs or {}) do
        if hub and not samePlayer(playerId, unit.player) then
            local attacker = {
                name = "Commandant",
                player = playerId,
                row = hub.row,
                col = hub.col,
                currentHp = hub.currentHp or hub.hp or hub.startingHp,
                startingHp = hub.startingHp or hub.hp or hub.currentHp
            }
            if manhattan(attacker, target) <= attackRange(ai, attacker) then
                local damage = calculateDamage(ai, attacker, unit)
                if damage > 0 then
                    local lethal = damage >= unitHp(unit)
                    local entry = {
                        kind = "commandant_direct_attack",
                        attacker = attacker,
                        attackerName = "Commandant",
                        target = unit,
                        targetName = unit.name,
                        fromCell = {row = attacker.row, col = attacker.col},
                        damage = damage,
                        expectedDamage = damage,
                        lethal = lethal,
                        eta = 0,
                        moveDistance = 0,
                        score = damage * 100 + (lethal and 10000 or 0),
                        reason = lethal and "commandant_lethal_punish" or "commandant_damage_punish"
                    }
                    if not best
                        or entry.score > best.score
                        or (entry.score == best.score and tostring(playerId) < tostring(best.attacker and best.attacker.player)) then
                        best = entry
                    end
                end
            end
        end
    end

    return best
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

local function exposureDamage(analysis)
    local reply = analysis and analysis.enemyBestReply or nil
    return num(reply and (reply.damage or reply.expectedDamage), 0)
end

local function exposureLethal(analysis, unit)
    local reply = analysis and analysis.enemyBestReply or nil
    local damage = exposureDamage(analysis)
    return (reply and reply.lethal == true)
        or (damage > 0 and damage >= unitHp(unit))
end

local function shouldInspectAction(action, opts)
    if not action then
        return false
    end
    if action.type == "move" then
        return true
    end
    if opts and opts.includeDeploy == true and action.type == "supply_deploy" then
        return true
    end
    return false
end

local function phaseName(ctx, opts)
    if opts and opts.phase then
        return tostring(opts.phase)
    end
    if ctx and ctx.phase and ctx.phase.early == true then
        return "early"
    end
    if ctx and ctx.phase and ctx.phase.mid == true then
        return "mid"
    end
    return "generic"
end

local function penaltyFor(ctx, exposure, opts)
    if not (exposure and exposure.enabled ~= false) then
        return 0
    end
    local cfg = ctx and ctx.cfg or {}
    local phase = phaseName(ctx, opts)
    local damage = num(exposure.maxDamage, 0)
    if damage <= 0 and exposure.lethal ~= true then
        return 0
    end

    if phase == "early" then
        local directContactPenalty = 0
        if exposure.directMeleeContact == true then
            directContactPenalty = num(cfg.PIPELINE_V2_EARLY_DIRECT_MELEE_CONTACT_PENALTY, 45000)
                + num(exposure.directMeleeContactDamage, damage)
                    * num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT, 7000)
        end
        if exposure.lethal == true then
            return num(cfg.PIPELINE_V2_EARLY_DESTINATION_LETHAL_PENALTY, 80000)
                + damage * num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT, 7000)
                + directContactPenalty
        end
        return num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_PENALTY, 22000)
            + damage * num(cfg.PIPELINE_V2_EARLY_DESTINATION_DAMAGE_WEIGHT, 7000)
            + directContactPenalty
    end

    if phase == "mid" then
        if exposure.lethal == true then
            return num(cfg.PIPELINE_V2_MID_DESTINATION_LETHAL_PENALTY, 70000)
                + damage * num(cfg.PIPELINE_V2_MID_DESTINATION_DAMAGE_WEIGHT, 5000)
        end
        return damage * num(cfg.PIPELINE_V2_MID_DESTINATION_DAMAGE_WEIGHT, 0)
    end

    if exposure.lethal == true then
        return num(cfg.PIPELINE_V2_DESTINATION_LETHAL_PENALTY, 60000)
    end
    return damage * num(cfg.PIPELINE_V2_DESTINATION_DAMAGE_WEIGHT, 0)
end

local function record(candidate, exposure)
    if not candidate then
        return
    end
    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.destinationExposure = exposure
    candidate.tacticalTags.destinationExposureDamage = num(exposure and exposure.maxDamage, 0)
    candidate.tacticalTags.destinationExposureLethal = exposure and exposure.lethal == true
    candidate.tacticalTags.destinationExposurePenalty = num(exposure and exposure.penalty, 0)
    candidate.tacticalTags.destinationExposureActionType = exposure and exposure.actionType or nil
    candidate.tacticalTags.destinationDirectMeleeContact = exposure and exposure.directMeleeContact == true
    candidate.tacticalTags.destinationDirectMeleeContactDamage =
        num(exposure and exposure.directMeleeContactDamage, 0)
    local target = exposure and exposure.target or nil
    if target then
        candidate.tacticalTags.destinationExposureTarget =
            tostring(num(target.row, 0)) .. "," .. tostring(num(target.col, 0))
    end
    if candidate.midPosition then
        local existingPenalty = num(candidate.midPosition.destinationExposurePenalty, 0)
        local nextPenalty = math.max(existingPenalty, candidate.tacticalTags.destinationExposurePenalty)
        candidate.midPosition.destinationExposureDamage = candidate.tacticalTags.destinationExposureDamage
        candidate.midPosition.destinationExposureLethal = candidate.tacticalTags.destinationExposureLethal
            or candidate.midPosition.destinationExposureLethal == true
        candidate.midPosition.destinationExposurePenalty = nextPenalty
        candidate.midPosition.destinationExposureTarget = candidate.tacticalTags.destinationExposureTarget
    end
end

function M.analyze(ai, afterState, ctx, candidate, opts)
    opts = opts or {}
    local result = {
        enabled = scoringEnabled(ctx),
        phase = phaseName(ctx, opts),
        inspected = 0,
        maxDamage = 0,
        lethal = false,
        penalty = 0
    }

    if not result.enabled then
        record(candidate, result)
        return result
    end
    if not (afterState and candidate and candidate.actions) then
        record(candidate, result)
        return result
    end

    for _, action in ipairs(candidate.actions or {}) do
        if shouldInspectAction(action, opts) then
            local target = targetCell(action)
            local unit = target and getUnitAt(ai, afterState, target.row, target.col) or nil
            if unit and (not ctx or not ctx.aiPlayer or num(unit.player, ctx.aiPlayer) == num(ctx.aiPlayer, unit.player)) then
                local analysis = punishMap.analyzeCell(afterState, ai, ctx, unit, unit)
                local damage = exposureDamage(analysis)
                local lethal = exposureLethal(analysis, unit)
                local commandantReply = commandantThreat(ai, afterState, unit, target)
                local commandantDamage = num(commandantReply and (commandantReply.damage or commandantReply.expectedDamage), 0)
                local commandantLethal = commandantReply and commandantReply.lethal == true
                local contact = directMeleeContact(ai, afterState, unit)
                local contactDamage = num(contact and contact.damage, 0)
                if commandantReply and (commandantLethal or (not lethal and commandantDamage > damage)) then
                    damage = commandantDamage
                    lethal = commandantLethal
                    analysis = analysis or {}
                    analysis.enemyBestReply = commandantReply
                    analysis.reasons = analysis.reasons or {}
                        analysis.reasons[#analysis.reasons + 1] = commandantReply.reason
                end
                if contact and contact.active == true then
                    damage = math.max(damage, contactDamage)
                    lethal = lethal or contact.lethal == true
                end
                result.inspected = result.inspected + 1
                if lethal or (result.lethal ~= true and damage > num(result.maxDamage, 0)) then
                    result.maxDamage = damage
                    result.lethal = lethal
                    result.actionType = action.type
                    result.target = target
                    result.unitName = unit.name
                    result.analysis = analysis
                    result.directMeleeContact = contact and contact.active == true
                    result.directMeleeContactDamage = contactDamage
                    result.directMeleeContactAttackers = contact and contact.attackers or 0
                end
            end
        end
    end

    if result.lethal == true then
        result.reason = tostring(result.phase) .. "_destination_lethal_exposure_penalty"
    elseif num(result.maxDamage, 0) > 0 then
        result.reason = tostring(result.phase) .. "_destination_damage_exposure_penalty"
    end
    result.penalty = penaltyFor(ctx, result, opts)
    record(candidate, result)
    return result
end

function M.applyScorePenalty(ctx, candidate, score, opts)
    if not (candidate and score) then
        return score
    end
    local exposure = candidate.tacticalTags and candidate.tacticalTags.destinationExposure or nil
    if not exposure then
        exposure = M.analyze(nil, nil, ctx, candidate, opts)
    end
    local penalty = num(exposure and exposure.penalty, 0)
    if penalty <= 0 then
        return score
    end

    score.survival = num(score.survival, 0) - penalty
    score.risk = num(score.risk, 0) - math.floor(penalty * 0.15)
    score.breakdown = score.breakdown or {}
    score.breakdown.destinationExposure = {
        phase = exposure.phase,
        damage = exposure.maxDamage,
        lethal = exposure.lethal == true,
        penalty = penalty,
        directMeleeContact = exposure.directMeleeContact == true,
        directMeleeContactDamage = exposure.directMeleeContactDamage,
        target = candidate.tacticalTags and candidate.tacticalTags.destinationExposureTarget or nil,
        actionType = exposure.actionType,
        reason = exposure.reason
    }
    score.breakdown.reasons = score.breakdown.reasons or {}
    score.breakdown.reasons[#score.breakdown.reasons + 1] = exposure.reason or "destination_exposure_penalty"
    if ctx and ctx.score and ctx.score.finalize then
        return ctx.score.finalize(score)
    end
    score.total = num(score.total, 0) - penalty
    return score
end

function M.check(ai, afterState, ctx, candidate, opts)
    local exposure = M.analyze(ai, afterState, ctx, candidate, opts)
    return true, exposure and exposure.reason, exposure
end

return M
