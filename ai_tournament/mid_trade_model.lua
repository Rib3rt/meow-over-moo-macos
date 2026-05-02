local punishMap = require("ai_tournament.punish_map")
local midPersonality = require("ai_tournament.mid_personality")
local drawPressure = require("ai_tournament.draw_pressure")

local M = {}

local UNIT_VALUE_FALLBACK = {
    Commandant = 150,
    Artillery = 90,
    Crusher = 80,
    Earthstalker = 75,
    Cloudstriker = 75,
    Bastion = 70,
    Wingstalker = 45,
    Healer = 40,
    Rock = 0
}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clamp(value, minValue, maxValue)
    local n = num(value, 0)
    if n < minValue then
        return minValue
    end
    if n > maxValue then
        return maxValue
    end
    return n
end

local function clone(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        out[clone(key, seen)] = clone(child, seen)
    end
    return out
end

local function unitHp(unit)
    return num(unit and (unit.currentHp or unit.startingHp), 0)
end

local function isAlive(unit)
    return unit and unitHp(unit) > 0
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

local function hubAsUnit(state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if not hub then
        return nil
    end
    return {
        name = hub.name or "Commandant",
        player = playerId,
        row = hub.row,
        col = hub.col,
        currentHp = hub.currentHp,
        startingHp = hub.startingHp
    }
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
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    for playerId, hub in pairs(state.commandHubs or {}) do
        if hub and num(hub.row, -1) == row and num(hub.col, -1) == col then
            return hubAsUnit(state, playerId)
        end
    end
    for _, rock in ipairs(state.neutralBuildings or {}) do
        if rock and num(rock.row, -1) == row and num(rock.col, -1) == col then
            return {
                name = rock.name or "Rock",
                player = 0,
                row = row,
                col = col,
                currentHp = rock.currentHp or rock.hp or 5,
                startingHp = rock.startingHp or rock.hp or 5
            }
        end
    end
    return nil
end

local function unitValue(ai, unit, state)
    if not unit then
        return 0
    end
    if ai and ai.getUnitBaseValue then
        local ok, value = pcall(ai.getUnitBaseValue, ai, unit, state)
        if ok and value ~= nil then
            return num(value, 0)
        end
    end
    return num(UNIT_VALUE_FALLBACK[unit.name], 25)
end

local function calculateDamage(ai, attacker, target)
    if not (attacker and target) then
        return 0
    end
    if ai and ai.calculateDamage then
        local ok, value = pcall(ai.calculateDamage, ai, attacker, target)
        if ok then
            return math.max(0, num(value, 0))
        end
    end
    return math.max(0, num(attacker.atkDamage, 0))
end

local function normalizeActions(actionOrCandidate)
    if not actionOrCandidate then
        return {}
    end
    local actions = actionOrCandidate.actions or actionOrCandidate.sequence or actionOrCandidate
    if actionOrCandidate.action and not actionOrCandidate.type and not actionOrCandidate.actions then
        actions = {actionOrCandidate.action}
    end
    if actions.type then
        return {actions}
    end
    return actions or {}
end

local function firstAttack(actions)
    for _, action in ipairs(actions or {}) do
        if action and action.type == "attack" then
            return action
        end
    end
    return nil
end

local function lastAttack(actions)
    local found = nil
    for _, action in ipairs(actions or {}) do
        if action and action.type == "attack" then
            found = action
        end
    end
    return found
end

local function isFactionTarget(ai, ctx, attacker, target)
    local playerId = ctx and ctx.aiPlayer or attacker and attacker.player
    if not (attacker and target and playerId) then
        return false
    end
    return target.player ~= nil
        and num(target.player, -1) > 0
        and num(target.player, -1) ~= num(playerId, -2)
        and not isObstacle(ai, target)
end

local function simulate(ai, state, actions, playerId, ctx)
    if ctx and ctx.cache and ctx.cache.simulate then
        local ok, simulated = pcall(ctx.cache.simulate, ai, state, actions, playerId, ctx)
        if ok and simulated then
            return simulated
        end
    end
    return nil
end

local function attackSummaries(ai, state, ctx, actions)
    local playerId = ctx and ctx.aiPlayer or 1
    local current = state
    local summaries = {}
    for _, action in ipairs(actions or {}) do
        if action and action.type == "attack" then
            local attacker = action.unit and getUnitAt(ai, current, action.unit.row, action.unit.col) or nil
            local target = action.target and getUnitAt(ai, current, action.target.row, action.target.col) or nil
            if not target and action.targetUnit then
                target = clone(action.targetUnit)
            end
            local damage = calculateDamage(ai, attacker, target)
            local targetHp = unitHp(target)
            local lethal = targetHp > 0 and damage >= targetHp
            local targetValue = unitValue(ai, target, current)
            local attackerValue = unitValue(ai, attacker, current)
            summaries[#summaries + 1] = {
                action = action,
                attacker = attacker and clone(attacker) or action.unit,
                target = target and clone(target) or nil,
                damage = damage,
                targetHp = targetHp,
                lethal = lethal,
                factionTarget = isFactionTarget(ai, ctx, attacker, target),
                targetValue = targetValue,
                attackerValue = attackerValue,
                commandantDamage = target and isHub(ai, target) and num(target.player, 0) ~= num(playerId, 0) and damage or 0
            }
        end

        if current and action then
            current = simulate(ai, current, {action}, playerId, ctx)
        end
    end
    return summaries
end

local function finalAttacker(ai, afterState, attack)
    if not (afterState and attack and attack.unit) then
        return nil
    end
    local unit = getUnitAt(ai, afterState, attack.unit.row, attack.unit.col)
    if unit then
        return unit
    end
    if attack.target then
        return getUnitAt(ai, afterState, attack.target.row, attack.target.col)
    end
    return nil
end

local function profileThresholds(profile)
    local thresholds = profile and profile.thresholds or {}
    local name = tostring(profile and profile.name or "base")
    local minMaterialDelta = thresholds.minMaterialDelta
    if minMaterialDelta == nil then
        if name == "marge" then
            minMaterialDelta = 46
        elseif name == "homer" then
            minMaterialDelta = 32
        elseif name == "burt" or name == "barnes" then
            minMaterialDelta = -8
        elseif name == "burns" then
            minMaterialDelta = 0
        else
            minMaterialDelta = 18
        end
    end
    return {
        minTradeNet = num(thresholds.attackMinTradeNet, num(thresholds.minTradeNet, 0)),
        minMaterialDelta = num(minMaterialDelta, 0),
        minDamage = num(thresholds.minAttackDamage, 1)
    }
end

local function isEndgameRuntime(ctx)
    return ctx
        and (
            ctx.pipelineV2EndRuntime == true
            or (ctx.phase and ctx.phase.endgame == true)
        )
end

local function keepLegalDamageAttacks(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_KEEP_LEGAL_DAMAGE_ATTACKS == false)
end

local function legalDamageAttackPenalty(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_DAMAGE_ATTACK_PENALTY, 1800)
end

local function keepDrawResetZeroDamageAttacks(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_KEEP_DRAW_RESET_ZERO_DAMAGE_ATTACKS == false)
end

local function drawResetZeroDamageTradePenalty(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_RESET_ZERO_DAMAGE_TRADE_PENALTY, 6500)
end

local function cfgNumber(ctx, key, fallback)
    return num(ctx and ctx.cfg and ctx.cfg[key], fallback)
end

local function supplyCount(state, ctx, playerId)
    if ctx and ctx.phase and ctx.phase.supply and ctx.phase.supply[playerId] ~= nil then
        return num(ctx.phase.supply[playerId], 0)
    end
    return #(state and state.supply and state.supply[playerId] or {})
end

local function opponentPlayer(ai, playerId)
    if ai and ai.getOpponentPlayer then
        local ok, value = pcall(ai.getOpponentPlayer, ai, playerId)
        if ok and value ~= nil then
            return value
        end
    end
    return num(playerId, 1) == 1 and 2 or 1
end

local function availableUnitCount(ai, state, ctx, playerId)
    local count = supplyCount(state, ctx, playerId)
    for _, unit in ipairs(state and state.units or {}) do
        if unit
            and num(unit.player, -1) == num(playerId, -2)
            and num(unit.currentHp or unit.startingHp, 0) > 0
            and not isHub(ai, unit)
            and not isObstacle(ai, unit) then
            count = count + 1
        end
    end
    return count
end

local function canKeepAsLegalDamageCandidate(result)
    return result
        and result.accepted ~= true
        and num(result.totalDamage, 0) > 0
        and num(result.factionAttackCount, 0) > 0
end

local function canKeepAsDrawResetZeroDamageCandidate(ai, state, ctx, result)
    if not (keepDrawResetZeroDamageAttacks(ctx) and result) then
        return false, nil
    end
    if result.accepted == true
        or num(result.totalDamage, 0) > 0
        or num(result.factionAttackCount, 0) <= 0 then
        return false, nil
    end
    local draw = drawPressure.build(ai, state, ctx)
    if not (draw and draw.active == true and draw.nearLimit == true) then
        return false, draw
    end
    return true, draw
end

local function addReason(reasons, reason, value)
    if value ~= nil and value ~= 0 then
        reasons[#reasons + 1] = {
            reason = reason,
            value = value
        }
    elseif value == nil then
        reasons[#reasons + 1] = {
            reason = reason,
            value = 0
        }
    end
end

local function compactReasons(reasons, limit)
    local sorted = {}
    for _, reason in ipairs(reasons or {}) do
        sorted[#sorted + 1] = reason
    end
    table.sort(sorted, function(a, b)
        local av = math.abs(num(a and a.value, 0))
        local bv = math.abs(num(b and b.value, 0))
        if av == bv then
            return tostring(a and a.reason or "") < tostring(b and b.reason or "")
        end
        return av > bv
    end)
    local out = {}
    for index, reason in ipairs(sorted) do
        if index > limit then
            break
        end
        out[#out + 1] = tostring(reason.reason or reason)
    end
    return out
end

local function classify(result, thresholds)
    if result.commandantLethal then
        return true, "mid_trade_win_now", "win_now"
    end
    if result.totalDamage <= 0 then
        return false, "mid_trade_zero_damage", "rejected"
    end
    if result.factionAttackCount <= 0 then
        return false, "mid_trade_not_faction_attack", "rejected"
    end
    if result.enemyReplyLethal and not result.covered and result.materialDelta < thresholds.minMaterialDelta then
        return false, "mid_trade_uncovered_lethal_reply", "unsafe"
    end
    if result.kills > 0 and result.materialDelta >= thresholds.minMaterialDelta then
        return true, result.covered and "mid_trade_covered_kill" or "mid_trade_favorable_kill", "kill"
    end
    if result.hpTradeNet >= thresholds.minTradeNet and result.materialDelta >= thresholds.minMaterialDelta then
        return true, result.covered and "mid_trade_supported_pressure" or "mid_trade_pressure", "pressure"
    end
    if result.commandantDamage > 0 and result.materialDelta >= thresholds.minMaterialDelta then
        return true, "mid_trade_commandant_pressure", "pressure"
    end
    if result.hpTradeNet < thresholds.minTradeNet then
        return false, "mid_trade_below_trade_threshold", "rejected"
    end
    return false, "mid_trade_below_material_threshold", "rejected"
end

local function recordStats(ctx, result)
    if not (ctx and ctx.stats and result) then
        return
    end
    local stats = ctx.stats
    stats.midTradeEvaluations = num(stats.midTradeEvaluations, 0) + 1
    if result.accepted then
        stats.midTradeAccepted = num(stats.midTradeAccepted, 0) + 1
    else
        stats.midTradeRejected = num(stats.midTradeRejected, 0) + 1
    end
    stats.midTradeReasonCounts = stats.midTradeReasonCounts or {}
    stats.midTradeReasonCounts[result.reason] = num(stats.midTradeReasonCounts[result.reason], 0) + 1
    stats.midTradeLastReason = result.reason
    stats.midTradeLastScore = result.score
end

function M.evaluateAttack(ai, state, ctx, actionOrCandidate, options)
    options = options or {}
    local actions = normalizeActions(actionOrCandidate)
    local attack = lastAttack(actions)
    if not attack then
        local result = {
            accepted = false,
            reason = "mid_trade_no_attack",
            class = "rejected",
            score = -math.huge,
            actions = actions
        }
        recordStats(ctx, result)
        return result
    end

    local playerId = ctx and ctx.aiPlayer or (attack.unit and attack.unit.player) or 1
    local profile = options.profile or (ctx and ctx.midPersonality and ctx.midPersonality.profile)
        or midPersonality.resolve(ai, state, ctx, options.reference)
    local thresholds = profileThresholds(profile)
    if isEndgameRuntime(ctx) then
        thresholds.minTradeNet = math.min(thresholds.minTradeNet, -100000)
        thresholds.minMaterialDelta = math.min(thresholds.minMaterialDelta, -100000)
        thresholds.endgameRelaxed = true
    end
    local afterState = simulate(ai, state, actions, playerId, ctx)
    if not afterState then
        local result = {
            accepted = false,
            reason = "mid_trade_simulation_unavailable",
            class = "rejected",
            score = -math.huge,
            actions = actions
        }
        recordStats(ctx, result)
        return result
    end

    local summaries = attackSummaries(ai, state, ctx, actions)
    local attackerAfter = finalAttacker(ai, afterState, attack)
    local exposure = attackerAfter and punishMap.analyzeCell(afterState, ai, ctx, attackerAfter, attackerAfter) or nil

    local totalDamage = 0
    local factionAttackCount = 0
    local kills = 0
    local commandantDamage = 0
    local commandantLethal = false
    local bestTargetValue = 0
    local bestFactionRemainingHp = nil
    local attackerValue = unitValue(ai, attackerAfter, afterState)
    local inflictedMaterial = 0
    for _, summary in ipairs(summaries) do
        totalDamage = totalDamage + num(summary.damage, 0)
        if summary.factionTarget then
            factionAttackCount = factionAttackCount + 1
            local targetValue = num(summary.targetValue, 0)
            local damageRatio = summary.targetHp > 0 and clamp(summary.damage / summary.targetHp, 0, 1) or 0
            local inflicted = summary.lethal and targetValue or targetValue * damageRatio * 0.62
            local remainingHp = math.max(0, num(summary.targetHp, 0) - num(summary.damage, 0))
            inflictedMaterial = inflictedMaterial + inflicted
            bestTargetValue = math.max(bestTargetValue, targetValue)
            bestFactionRemainingHp = bestFactionRemainingHp == nil
                and remainingHp
                or math.min(bestFactionRemainingHp, remainingHp)
            if summary.lethal then
                kills = kills + 1
            end
            commandantDamage = commandantDamage + num(summary.commandantDamage, 0)
            commandantLethal = commandantLethal
                or (summary.commandantDamage > 0 and summary.lethal == true)
            attackerValue = math.max(attackerValue, num(summary.attackerValue, 0))
        end
    end

    local enemyReply = exposure and exposure.enemyBestReply or nil
    local counter = exposure and exposure.counterPunish or nil
    local enemyDamage = num(enemyReply and enemyReply.damage, 0)
    local enemyReplyLethal = enemyReply and enemyReply.lethal == true or false
    local covered = exposure and exposure.covered == true or false
    local counterCredit = counter and (
        num(counter.damage, 0) * 18
        + (counter.lethal and unitValue(ai, enemyReply and enemyReply.attacker, afterState) * 0.55 or 0)
    ) or 0
    local expectedLoss = enemyReplyLethal and attackerValue or enemyDamage * 22
    if covered then
        expectedLoss = expectedLoss * 0.42
    end

    local exposureTradeNet = num(exposure and exposure.tradeNet, 0)
    local hpTradeNet = totalDamage + exposureTradeNet
    local materialDelta = inflictedMaterial - expectedLoss + counterCredit
    local setupRemainingHp = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_SUICIDE_SETUP_REMAINING_HP", 1)
    local suicideSetup = enemyReplyLethal
        and kills <= 0
        and commandantDamage <= 0
        and bestFactionRemainingHp ~= nil
        and bestFactionRemainingHp <= setupRemainingHp
    local suicideChip = enemyReplyLethal
        and not covered
        and kills <= 0
        and commandantDamage <= 0
        and counterCredit <= 0
        and materialDelta < 0
        and not suicideSetup
    local pressureScore = totalDamage * 34
        + kills * 95
        + commandantDamage * 75
        + bestTargetValue * 0.18
    local riskPenalty = math.max(0, expectedLoss - counterCredit) * num(profile.weights and profile.weights.risk, 1)
    local personalityAttack = num(profile.weights and profile.weights.attack, 1)
    local personalityTrade = num(profile.weights and profile.weights.trade, 1)
    local score = (pressureScore * personalityAttack)
        + (materialDelta * personalityTrade)
        + (hpTradeNet * 24)
        - riskPenalty

    local result = {
        accepted = false,
        reason = nil,
        class = nil,
        score = score,
        personality = profile.name,
        reference = profile.reference,
        label = profile.label,
        actions = actions,
        attack = firstAttack(actions),
        finalAttack = attack,
        afterState = options.includeAfterState and afterState or nil,
        totalDamage = totalDamage,
        factionAttackCount = factionAttackCount,
        kills = kills,
        commandantDamage = commandantDamage,
        commandantLethal = commandantLethal,
        bestTargetValue = bestTargetValue,
        bestFactionRemainingHp = bestFactionRemainingHp,
        attackerValue = attackerValue,
        inflictedMaterial = inflictedMaterial,
        expectedLoss = expectedLoss,
        counterCredit = counterCredit,
        materialDelta = materialDelta,
        hpTradeNet = hpTradeNet,
        exposureTradeNet = exposureTradeNet,
        exposure = exposure and exposure.exposure or 0,
        covered = covered,
        enemyReply = enemyReply,
        enemyReplyLethal = enemyReplyLethal,
        drawSuicideChip = suicideChip,
        drawSuicideSetup = suicideSetup,
        counterPunish = counter,
        thresholds = thresholds,
        summaries = summaries,
        reasons = {}
    }

    addReason(result.reasons, "mid_trade_damage", totalDamage * 34)
    addReason(result.reasons, "mid_trade_material_delta", materialDelta)
    addReason(result.reasons, "mid_trade_hp_trade_net", hpTradeNet * 24)
    if kills > 0 then
        addReason(result.reasons, "mid_trade_kill", kills * 95)
    end
    if commandantDamage > 0 then
        addReason(result.reasons, "mid_trade_commandant_damage", commandantDamage * 75)
    end
    if expectedLoss > 0 then
        addReason(result.reasons, "mid_trade_expected_loss", -expectedLoss)
    end
    if counterCredit > 0 then
        addReason(result.reasons, "mid_trade_counter_credit", counterCredit)
    end
    if suicideChip then
        addReason(result.reasons, "mid_trade_draw_suicide_chip")
    elseif suicideSetup then
        addReason(result.reasons, "mid_trade_draw_suicide_setup")
    end
    if isEndgameRuntime(ctx) and kills > 0 and enemyReplyLethal then
        local ownAvailable = availableUnitCount(ai, state, ctx, playerId)
        local enemyAvailable = availableUnitCount(ai, state, ctx, opponentPlayer(ai, playerId))
        local advantage = ownAvailable - enemyAvailable
        result.endgameAvailableUnits = {
            own = ownAvailable,
            enemy = enemyAvailable,
            advantage = advantage
        }
        if advantage > 0 then
            local bonus = cfgNumber(ctx, "PIPELINE_V2_ENDGAME_SUICIDE_KILL_MATERIAL_ADVANTAGE_BONUS", 3600)
                + advantage * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_SUICIDE_KILL_MATERIAL_ADVANTAGE_PER_UNIT", 700)
            result.score = num(result.score, 0) + bonus
            result.endgameSuicideKillAccepted = true
            result.endgameSuicideKillBonus = bonus
            addReason(result.reasons, "endgame_suicide_kill_material_advantage", bonus)
            if ctx and ctx.stats then
                ctx.stats.midTradeEndgameSuicideKillMaterialAdvantage =
                    num(ctx.stats.midTradeEndgameSuicideKillMaterialAdvantage, 0) + 1
            end
        end
    end

    result.accepted, result.reason, result.class = classify(result, thresholds)
    if keepLegalDamageAttacks(ctx) and canKeepAsLegalDamageCandidate(result) then
        local originalReason = result.reason
        local penalty = legalDamageAttackPenalty(ctx)
        result.accepted = true
        result.reason = "mid_trade_legal_damage_candidate"
        result.class = "legal_damage"
        result.legalDamageCandidate = true
        result.originalRejectReason = originalReason
        result.score = num(result.score, 0) - penalty
        addReason(result.reasons, originalReason)
        addReason(result.reasons, "mid_trade_legal_damage_penalty", -penalty)
        if ctx and ctx.stats then
            ctx.stats.midTradeLegalDamageKept = num(ctx.stats.midTradeLegalDamageKept, 0) + 1
            ctx.stats.midTradeLegalDamageKeptReasons = ctx.stats.midTradeLegalDamageKeptReasons or {}
            ctx.stats.midTradeLegalDamageKeptReasons[originalReason] =
                num(ctx.stats.midTradeLegalDamageKeptReasons[originalReason], 0) + 1
        end
    end
    local keepDrawReset, draw = canKeepAsDrawResetZeroDamageCandidate(ai, state, ctx, result)
    if keepDrawReset then
        local originalReason = result.reason
        local penalty = drawResetZeroDamageTradePenalty(ctx)
        result.accepted = true
        result.reason = "mid_trade_draw_reset_zero_damage"
        result.class = "draw_reset"
        result.officialDrawResetCandidate = true
        result.drawZeroDamageReset = true
        result.drawResetStreak = draw and draw.streak or nil
        result.originalRejectReason = originalReason
        result.score = num(result.score, 0) - penalty
        addReason(result.reasons, originalReason)
        addReason(result.reasons, "mid_trade_draw_reset_zero_damage_penalty", -penalty)
        if ctx and ctx.stats then
            ctx.stats.midTradeDrawResetZeroDamageKept =
                num(ctx.stats.midTradeDrawResetZeroDamageKept, 0) + 1
            ctx.stats.midTradeDrawResetZeroDamageKeptReasons =
                ctx.stats.midTradeDrawResetZeroDamageKeptReasons or {}
            ctx.stats.midTradeDrawResetZeroDamageKeptReasons[originalReason] =
                num(ctx.stats.midTradeDrawResetZeroDamageKeptReasons[originalReason], 0) + 1
        end
    end
    addReason(result.reasons, result.reason)
    result.compactReasons = compactReasons(result.reasons, 5)

    recordStats(ctx, result)
    return result
end

M._private = {
    normalizeActions = normalizeActions,
    simulate = simulate,
    profileThresholds = profileThresholds,
    getUnitAt = getUnitAt,
    calculateDamage = calculateDamage
}

return M
