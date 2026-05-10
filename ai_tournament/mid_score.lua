local scoreModel = require("ai_tournament.score")
local drawPressure = require("ai_tournament.draw_pressure")
local drawAttackSetup = require("ai_tournament.draw_attack_setup")

local M = {}
local noLegalCombatAvailable

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

local function cfgBool(ctx, key, fallback)
    local value = ctx and ctx.cfg and ctx.cfg[key]
    if value == nil then
        return fallback
    end
    if value == false or value == 0 then
        return false
    end
    local text = tostring(value):lower()
    return not (text == "false" or text == "0" or text == "off" or text == "no")
end

local function drawWaveScale(ctx, draw)
    if ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_WAVE_ENABLED == false then
        return 1
    end
    if not (draw and draw.active == true and draw.pressureLimit == true) then
        return 1
    end
    return 1
        + num(draw.urgency, 0) * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_WAVE_URGENCY_WEIGHT", 0.75)
        + num(draw.urgencyRatio, 0) * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_WAVE_RATIO_WEIGHT", 1.25)
end

local function manhattan(a, b)
    if not (a and b) then
        return nil
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
end

local function isAlive(unit)
    return unit and num(unit.currentHp, unit.startingHp or 1) > 0
end

local function isHub(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        local ok, result = pcall(ai.isHubUnit, ai, unit)
        if ok then
            return result == true
        end
    end
    return tostring(unit.name or "") == "Commandant"
end

local function isObstacle(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        local ok, result = pcall(ai.isObstacleUnit, ai, unit)
        if ok then
            return result == true
        end
    end
    return unit.player == 0 or tostring(unit.name or "") == "Rock"
end

local function pushHub(list, state, playerId)
    local hub = state and state.commandHubs and state.commandHubs[playerId]
    if hub then
        list[#list + 1] = {
            name = hub.name or "Commandant",
            player = playerId,
            row = hub.row,
            col = hub.col,
            currentHp = hub.currentHp,
            startingHp = hub.startingHp
        }
    end
end

local function livingFactionUnits(ai, state, playerId, includeHubs)
    local out = {}
    for _, unit in ipairs((state and state.units) or {}) do
        if unit
            and unit.player == playerId
            and isAlive(unit)
            and not isObstacle(ai, unit)
            and (includeHubs == true or not isHub(ai, unit)) then
            out[#out + 1] = unit
        end
    end
    if includeHubs == true then
        pushHub(out, state, playerId)
    end
    return out
end

local function closestFactionDistance(ai, state, playerId, enemyPlayer, includeHubs)
    local ownUnits = livingFactionUnits(ai, state, playerId, includeHubs)
    local enemyUnits = livingFactionUnits(ai, state, enemyPlayer, includeHubs)
    if #ownUnits == 0 or #enemyUnits == 0 then
        return nil
    end
    local best = nil
    for _, own in ipairs(ownUnits) do
        for _, enemy in ipairs(enemyUnits) do
            local distance = manhattan(own, enemy)
            if distance and (best == nil or distance < best) then
                best = distance
            end
        end
    end
    return best
end

local function applyDrawApproach(score, ai, state, ctx, afterOur, draw, candidate, hasInteraction)
    if hasInteraction or not afterOur then
        return nil
    end
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer
    local enemyPlayer = ctx and ctx.enemyPlayer
    if not enemyPlayer and ai and ai.getOpponentPlayer and playerId then
        enemyPlayer = ai:getOpponentPlayer(playerId)
    end
    if not (playerId and enemyPlayer) then
        return nil
    end

    local beforeDistance = closestFactionDistance(ai, state, playerId, enemyPlayer, false)
        or closestFactionDistance(ai, state, playerId, enemyPlayer, true)
    local afterDistance = closestFactionDistance(ai, afterOur, playerId, enemyPlayer, false)
        or closestFactionDistance(ai, afterOur, playerId, enemyPlayer, true)
    if beforeDistance == nil or afterDistance == nil then
        return nil
    end

    local progress = beforeDistance - afterDistance
    local urgency = num(draw and draw.urgency, 0)
    local streak = num(draw and draw.streak, 0)
    local wave = drawWaveScale(ctx, draw)
    local value = 0
    local reason = nil
    if progress > 0 then
        local base = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_APPROACH_BONUS", 900)
        value = math.floor(progress * base * (1 + streak * 0.30 + urgency * 0.45) * wave)
        score.force = score.force + value
        reason = "mid_draw_clock_approach_bonus"
    elseif progress == 0 then
        local base = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_STAGNATION_PENALTY", 700)
        value = math.floor(base * (1 + streak * 0.25 + urgency * 0.35) * wave)
        score.force = score.force - value
        reason = "mid_draw_clock_stagnation_penalty"
    else
        local base = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_RETREAT_PENALTY", 900)
        value = math.floor(math.abs(progress) * base * (1 + streak * 0.30 + urgency * 0.45) * wave)
        score.force = score.force - value
        reason = "mid_draw_clock_retreat_penalty"
    end

    if reason then
        score.breakdown.reasons = score.breakdown.reasons or {}
        score.breakdown.reasons[#score.breakdown.reasons + 1] = reason
    end
    if candidate and candidate.tacticalTags then
        candidate.tacticalTags.drawApproachProgress = progress
    end
    return {
        beforeDistance = beforeDistance,
        afterDistance = afterDistance,
        progress = progress,
        wave = wave,
        value = value,
        reason = reason
    }
end

local function applyDrawNextAttackSetup(score, ai, state, ctx, afterOur, draw, candidate, hasInteraction)
    if hasInteraction or not afterOur then
        return nil
    end
    if not (draw and draw.active == true and draw.pressureLimit == true) then
        return nil
    end
    if not noLegalCombatAvailable(ctx) then
        return nil
    end

    local setup = drawAttackSetup.compare(ai, state, afterOur, ctx)
    if not setup then
        return nil
    end

    local after = setup.after or {}
    local wave = drawWaveScale(ctx, draw)
    local value = 0
    local reasons = {}
    if num(after.readyAttacks, 0) > 0 then
        local bonus = math.floor(cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_NEXT_ATTACK_READY_BONUS", 8500) * wave)
        value = value + bonus
        reasons[#reasons + 1] = "mid_draw_next_attack_ready"
    elseif num(after.nextTurnThreats, 0) > 0 then
        local bonus = math.floor(cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_NEXT_ATTACK_SETUP_BONUS", 4200) * wave)
        value = value + bonus
        reasons[#reasons + 1] = "mid_draw_next_attack_setup"
    end

    local progress = tonumber(setup.gapProgress)
    if progress and progress > 0 then
        value = value + math.floor(progress
            * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_ATTACK_GAP_PROGRESS_BONUS", 2600)
            * wave)
        reasons[#reasons + 1] = "mid_draw_attack_gap_progress"
    elseif progress == 0 then
        value = value - math.floor(cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_ATTACK_GAP_STAGNATION_PENALTY", 1800) * wave)
        reasons[#reasons + 1] = "mid_draw_attack_gap_stagnation"
    elseif progress and progress < 0 then
        value = value - math.floor(math.abs(progress)
            * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_ATTACK_GAP_RETREAT_PENALTY", 2600)
            * wave)
        reasons[#reasons + 1] = "mid_draw_attack_gap_retreat"
    end

    if value == 0 and #reasons == 0 then
        return nil
    end

    score.force = score.force + value
    score.breakdown.reasons = score.breakdown.reasons or {}
    for _, reason in ipairs(reasons) do
        score.breakdown.reasons[#score.breakdown.reasons + 1] = reason
    end
    score.breakdown.midDrawNextAttackSetup = {
        value = value,
        wave = wave,
        gapProgress = setup.gapProgress,
        beforeGap = setup.before and setup.before.bestGap or nil,
        afterGap = setup.after and setup.after.bestGap or nil,
        readyAttacks = setup.after and setup.after.readyAttacks or 0,
        nextTurnThreats = setup.after and setup.after.nextTurnThreats or 0,
        bestUnitName = setup.after and setup.after.bestUnitName or nil,
        bestTargetName = setup.after and setup.after.bestTargetName or nil
    }
    if candidate and candidate.tacticalTags then
        candidate.tacticalTags.drawNextAttackReady = num(after.readyAttacks, 0)
        candidate.tacticalTags.drawNextAttackThreats = num(after.nextTurnThreats, 0)
        candidate.tacticalTags.drawAttackGapProgress = setup.gapProgress
    end
    if ctx and ctx.stats then
        ctx.stats.pipelineV2MidDrawNextAttackSetupApplied =
            num(ctx.stats.pipelineV2MidDrawNextAttackSetupApplied, 0) + 1
        ctx.stats.pipelineV2MidDrawNextAttackSetupLastValue = value
        ctx.stats.pipelineV2MidDrawNextAttackSetupLastProgress = setup.gapProgress
    end
    return score.breakdown.midDrawNextAttackSetup
end

local function applyDrawPressure(score, ai, state, ctx, candidate, trade, options)
    local draw = drawPressure.build(ai, state, ctx)
    if not (draw and draw.active == true) then
        return
    end

    local weakSuicideChip = trade and trade.drawSuicideChip == true
    local officialDrawReset = candidate
        and candidate.containsAttack == true
        and trade
        and trade.accepted == true
        and num(trade.factionAttackCount, 0) > 0
    local hasInteraction = officialDrawReset and num(trade.totalDamage, 0) > 0
    local zeroDamageReset = officialDrawReset
        and num(trade.totalDamage, 0) <= 0
        and trade.drawZeroDamageReset == true

    local urgency = num(draw.urgency, 0)
    local value = 0
    local reason = nil
    if officialDrawReset then
        value = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_INTERACTION_BONUS_BASE", 2600)
            + (num(draw.streak, 0) * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_INTERACTION_STREAK_WEIGHT", 1800))
            + (urgency * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_INTERACTION_URGENCY_WEIGHT", 2600))
        if draw.nearLimit == true then
            value = value + cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_INTERACTION_NEAR_BONUS", 3500)
        end
        if draw.criticalLimit == true then
            value = value + cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_INTERACTION_CRITICAL_BONUS", 5000)
        end
        local suicideChipPenalty = 0
        if weakSuicideChip then
            suicideChipPenalty = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_SUICIDE_CHIP_FORCE_PENALTY", 80000)
            value = value - suicideChipPenalty
            score.breakdown.midDrawSuicideChipPenalty = {
                penalty = suicideChipPenalty,
                expectedLoss = num(trade.expectedLoss, 0),
                totalDamage = num(trade.totalDamage, 0),
                bestFactionRemainingHp = trade.bestFactionRemainingHp
            }
        end
        local zeroDamagePenalty = 0
        if zeroDamageReset then
            zeroDamagePenalty = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_ZERO_DAMAGE_RESET_FORCE_PENALTY", 22000)
            value = value - zeroDamagePenalty
            score.breakdown.midDrawZeroDamageResetPenalty = {
                penalty = zeroDamagePenalty,
                expectedLoss = num(trade.expectedLoss, 0)
            }
        end
        score.force = score.force + value
        reason = zeroDamageReset and "mid_draw_clock_zero_damage_reset"
            or (weakSuicideChip and "mid_draw_clock_suicide_chip_penalty")
            or (draw.nearLimit == true and "mid_draw_clock_interaction_bonus" or "mid_draw_clock_interaction_pressure")
    else
        value = cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_NO_INTERACTION_PENALTY_BASE", 2400)
            + (num(draw.streak, 0) * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_NO_INTERACTION_STREAK_WEIGHT", 2000))
            + (urgency * cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_NO_INTERACTION_URGENCY_WEIGHT", 3200))
        if draw.nearLimit == true then
            value = value + cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_NO_INTERACTION_NEAR_PENALTY", 4500)
        end
        if draw.criticalLimit == true then
            value = value + cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_NO_INTERACTION_CRITICAL_PENALTY", 6500)
        end
        score.force = score.force - value
        reason = draw.nearLimit == true and "mid_draw_clock_no_interaction_penalty" or "mid_draw_clock_passive_pressure"
        if candidate and candidate.containsDeploy == true and draw.pressureLimit == true then
            local ratio = math.max(0, math.min(1, num(draw.urgencyRatio, 0)))
            local minScale = math.max(0, cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_DEPLOY_PRESSURE_SCALE_MIN", 0.35))
            local deployScale = math.min(1, minScale + (1 - minScale) * ratio)
            local deployPenalty = math.floor(cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_DEPLOY_STALL_PENALTY", 1800) * deployScale)
                + (draw.criticalLimit == true
                    and cfgNumber(ctx, "PIPELINE_V2_MID_DRAW_DEPLOY_CRITICAL_EXTRA_PENALTY", 2400)
                    or 0)
            score.supply = score.supply - deployPenalty
            value = value + deployPenalty
            score.breakdown.midDrawDeployStallPenalty = {
                penalty = deployPenalty,
                scale = deployScale,
                urgency = urgency,
                urgencyRatio = ratio
            }
        end
    end
    local afterOur = options and options.afterOur
    local approach = applyDrawApproach(score, ai, state, ctx, afterOur, draw, candidate, officialDrawReset)
    local nextAttackSetup = applyDrawNextAttackSetup(
        score,
        ai,
        state,
        ctx,
        afterOur,
        draw,
        candidate,
        officialDrawReset
    )

    score.breakdown.reasons = score.breakdown.reasons or {}
    score.breakdown.reasons[#score.breakdown.reasons + 1] = reason
    score.breakdown.midDrawPressure = {
        active = true,
        streak = draw.streak,
        limit = draw.noInteractionLimit,
        pressureStreak = draw.pressureStreak,
        nearStreak = draw.nearStreak,
        criticalStreak = draw.criticalStreak,
        urgencyMax = draw.urgencyMax,
        urgencyRatio = draw.urgencyRatio,
        pressureLimit = draw.pressureLimit == true,
        nearLimit = draw.nearLimit == true,
        criticalLimit = draw.criticalLimit == true,
        hasInteraction = hasInteraction,
        officialDrawReset = officialDrawReset == true,
        zeroDamageReset = zeroDamageReset == true,
        weakSuicideChip = weakSuicideChip == true,
        value = value,
        component = "force",
        approach = approach,
        nextAttackSetup = nextAttackSetup
    }
end

local function isEndgameRuntime(ctx)
    return ctx
        and (
            ctx.pipelineV2EndRuntime == true
            or (ctx.phase and ctx.phase.endgame == true)
        )
end

function noLegalCombatAvailable(ctx)
    local stats = ctx and ctx.stats or nil
    if not stats then
        return false
    end
    if stats.legalAttackActions ~= nil or stats.legalMoveAttackActions ~= nil then
        return num(stats.legalAttackActions, 0) <= 0
            and num(stats.legalMoveAttackActions, 0) <= 0
    end
    if stats.pipelineV2MidMeaningfulInteractionCandidates ~= nil then
        return num(stats.pipelineV2MidMeaningfulInteractionCandidates, 0) <= 0
    end
    return false
end

local function supplyCount(ctx, playerId, side)
    if ctx and ctx.supply and side and ctx.supply[side] and ctx.supply[side].count ~= nil then
        return num(ctx.supply[side].count, 0)
    end
    if ctx and ctx.phase and ctx.phase.supply and playerId ~= nil then
        return num(ctx.phase.supply[playerId], 0)
    end
    return 0
end

local function reserveSupplyCount(state, ctx, playerId, side)
    if ctx and ctx.supply and side and ctx.supply[side] and ctx.supply[side].count ~= nil then
        return num(ctx.supply[side].count, 0)
    end
    if ctx and ctx.phase and ctx.phase.supply and playerId ~= nil and ctx.phase.supply[playerId] ~= nil then
        return num(ctx.phase.supply[playerId], 0)
    end
    return #(state and state.supply and state.supply[playerId] or {})
end

local function currentTurn(state, ctx)
    return num(
        state and (state.currentTurn or state.turnNumber),
        num(ctx and (ctx.currentTurn or ctx.turnNumber), 1)
    )
end

local function enemyPlayerFor(ai, state, ctx, playerId)
    if ctx and ctx.enemyPlayer then
        return ctx.enemyPlayer
    end
    if ai and ai.getOpponentPlayer and playerId then
        local ok, result = pcall(ai.getOpponentPlayer, ai, playerId)
        if ok and result then
            return result
        end
    end
    if playerId == 1 then
        return 2
    elseif playerId == 2 then
        return 1
    end
    return state and state.currentPlayer == 1 and 2 or 1
end

local function boardUnitCount(ai, state, playerId)
    if not (state and playerId) then
        return 0
    end
    local total = 0
    for _, unit in ipairs(state.units or {}) do
        if unit
            and num(unit.player, -999) == num(playerId, -998)
            and isAlive(unit)
            and not isObstacle(ai, unit)
            and not isHub(ai, unit) then
            total = total + 1
        end
    end
    return total
end

local function midUnitBalanceState(ai, state, ctx)
    if cfgBool(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_ENABLED", true) ~= true then
        return nil
    end
    if isEndgameRuntime(ctx) or not (ctx and ctx.phase and ctx.phase.mid == true) then
        return nil
    end

    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer
    if not playerId then
        return nil
    end
    local enemyPlayer = enemyPlayerFor(ai, state, ctx, playerId)
    if not enemyPlayer then
        return nil
    end

    local ownBoard = boardUnitCount(ai, state, playerId)
    local enemyBoard = boardUnitCount(ai, state, enemyPlayer)
    local ownSupply = reserveSupplyCount(state, ctx, playerId, "own")
    local enemySupply = reserveSupplyCount(state, ctx, enemyPlayer, "enemy")
    local ownTotal = ownBoard + ownSupply
    local enemyTotal = enemyBoard + enemySupply
    local delta = ownTotal - enemyTotal
    local threshold = math.max(1, cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_GAP_THRESHOLD", 3))
    local absDelta = math.abs(delta)
    if absDelta < threshold then
        return nil
    end

    return {
        playerId = playerId,
        enemyPlayer = enemyPlayer,
        ownBoard = ownBoard,
        enemyBoard = enemyBoard,
        ownSupply = ownSupply,
        enemySupply = enemySupply,
        ownTotal = ownTotal,
        enemyTotal = enemyTotal,
        delta = delta,
        threshold = threshold,
        gap = absDelta - threshold + 1,
        losing = delta <= -threshold,
        winning = delta >= threshold
    }
end

local function defensivePostureScale(candidate, position)
    if candidate and candidate.containsDeploy == true then
        return 0.80
    end
    local intent = tostring(position and position.intent or "")
    local riskBand = tostring(position and position.riskBand or "")
    if position and (position.covered == true or intent == "cover" or intent == "support" or intent == "retreat") then
        return 1.0
    end
    if riskBand == "stable" or riskBand == "covered" or riskBand == "contested_ok" then
        return 0.85
    end
    return 0.45
end

local function applyMidUnitBalance(score, ai, state, ctx, candidate, trade, position)
    local balance = midUnitBalanceState(ai, state, ctx)
    if not balance then
        return
    end

    score.breakdown.reasons = score.breakdown.reasons or {}
    local containsAttack = candidate and candidate.containsAttack == true
    local draw = drawPressure.build(ai, state, ctx)
    local value = 0
    local mode = nil

    if balance.losing then
        if containsAttack and trade and trade.accepted == true then
            local base = cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_LOSING_ATTACK_PENALTY", 1700)
            local expectedLoss = math.max(0, num(trade.expectedLoss, 0) - num(trade.counterCredit, 0))
            local lossPenalty = expectedLoss
                * cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_LOSING_EXPECTED_LOSS_WEIGHT", 22)
            local commandantRushPenalty = 0
            if num(trade.commandantDamage, 0) > 0
                and num(trade.kills, 0) <= 0
                and trade.commandantLethal ~= true then
                commandantRushPenalty = num(trade.commandantDamage, 0)
                    * cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_LOSING_COMMANDANT_RUSH_PENALTY", 700)
            end
            local safeKillRelief = num(trade.kills, 0)
                * cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_LOSING_SAFE_KILL_RELIEF", 2600)
                + math.max(0, num(trade.materialDelta, 0)) * 0.35
            value = math.max(0, math.floor(base * balance.gap + lossPenalty + commandantRushPenalty - safeKillRelief))
            if value > 0 then
                score.force = score.force - value
                score.risk = score.risk - math.floor(value * 0.25)
                mode = "losing_attack_tempered"
            end
        elseif position and position.accepted == true then
            local base = cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_LOSING_DEFENSE_BONUS", 900)
            local scale = defensivePostureScale(candidate, position)
            value = math.floor(base * balance.gap * scale)
            if value > 0 then
                score.survival = score.survival + value
                mode = "losing_defensive_posture"
            end
        end
    elseif balance.winning then
        if containsAttack and trade and trade.accepted == true then
            value = math.floor(
                cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_WINNING_ATTACK_BONUS", 1300) * balance.gap
                + num(trade.totalDamage, 0) * cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_WINNING_DAMAGE_WEIGHT", 90)
                + num(trade.kills, 0) * cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_WINNING_KILL_BONUS", 700)
                + num(trade.commandantDamage, 0) * cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_WINNING_COMMANDANT_WEIGHT", 420)
            )
            if draw and draw.active == true then
                value = value + math.floor(
                    cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_WINNING_DRAW_BONUS", 1100)
                    * balance.gap
                    * (1 + num(draw.urgencyRatio, 0))
                )
            end
            if value > 0 then
                score.force = score.force + value
                mode = "winning_attack_pressure"
            end
        elseif draw and draw.active == true and position and position.accepted == true then
            value = math.floor(
                cfgNumber(ctx, "PIPELINE_V2_MID_UNIT_BALANCE_WINNING_PASSIVE_DRAW_PENALTY", 900)
                * balance.gap
                * (1 + num(draw.urgencyRatio, 0))
            )
            if value > 0 then
                score.force = score.force - value
                mode = "winning_passive_draw_pressure"
            end
        end
    end

    if mode then
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "mid_unit_balance_" .. mode
        score.breakdown.midUnitBalance = {
            mode = mode,
            value = value,
            ownBoard = balance.ownBoard,
            enemyBoard = balance.enemyBoard,
            ownSupply = balance.ownSupply,
            enemySupply = balance.enemySupply,
            ownTotal = balance.ownTotal,
            enemyTotal = balance.enemyTotal,
            delta = balance.delta,
            threshold = balance.threshold,
            gap = balance.gap,
            drawActive = draw and draw.active == true or false,
            drawUrgencyRatio = draw and draw.urgencyRatio or nil
        }
        if candidate then
            candidate.tacticalTags = candidate.tacticalTags or {}
            candidate.tacticalTags.midUnitBalanceMode = mode
            candidate.tacticalTags.midUnitBalanceDelta = balance.delta
        end
        if ctx and ctx.stats then
            ctx.stats.pipelineV2MidUnitBalanceApplied = num(ctx.stats.pipelineV2MidUnitBalanceApplied, 0) + 1
            ctx.stats.pipelineV2MidUnitBalanceLastMode = mode
            ctx.stats.pipelineV2MidUnitBalanceLastDelta = balance.delta
            ctx.stats.pipelineV2MidUnitBalanceLastValue = value
        end
    end
end

local function skipActionCount(candidate)
    local total = 0
    for _, action in ipairs(candidate and candidate.actions or {}) do
        if action and action.type == "skip" then
            total = total + 1
        end
    end
    return total
end

local function lateAggressionState(ai, state, ctx)
    if not cfgBool(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_ENABLED", true) then
        return nil
    end

    local turn = currentTurn(state, ctx)
    local startTurn = math.floor(cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_START_TURN", 51))
    if turn < startTurn then
        return nil
    end

    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer
    if not playerId then
        return nil
    end
    local enemyPlayer = enemyPlayerFor(ai, state, ctx, playerId)
    local ownUnits = boardUnitCount(ai, state, playerId)
    local enemyUnits = boardUnitCount(ai, state, enemyPlayer)
    if ownUnits < enemyUnits then
        return nil
    end

    local unitAdvantage = ownUnits - enemyUnits
    local age = math.max(0, turn - startTurn + 1)
    local value = cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_BASE_BONUS", 4500)
        + age * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_PER_TURN", 250)
        + unitAdvantage * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_UNIT_ADVANTAGE_BONUS", 1800)

    return {
        turn = turn,
        startTurn = startTurn,
        age = age,
        ownUnits = ownUnits,
        enemyUnits = enemyUnits,
        unitAdvantage = unitAdvantage,
        equalUnits = unitAdvantage == 0,
        value = math.floor(value)
    }
end

local function applyLateEndgameAggression(score, ai, state, ctx, candidate, trade, position)
    local late = lateAggressionState(ai, state, ctx)
    if not late then
        return
    end

    local mode = nil
    local forceBonus = 0
    local commandantBonus = 0
    local pressureBonus = 0
    local positionPenalty = 0
    local damage = 0
    local kills = 0
    local commandantDamage = 0

    if trade and trade.accepted == true and candidate and candidate.containsAttack == true then
        mode = "attack"
        damage = num(trade.totalDamage, 0)
        kills = num(trade.kills, 0)
        commandantDamage = num(trade.commandantDamage, 0)
        forceBonus = late.value
            + damage * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_DAMAGE_WEIGHT", 450)
            + kills * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_KILL_BONUS", 1800)
        commandantBonus = commandantDamage
            * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_AGGRESSION_COMMANDANT_WEIGHT", 1600)
        score.force = score.force + forceBonus
        score.commandant = score.commandant + commandantBonus
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "endgame_late_aggression_attack"
    elseif position and position.accepted == true then
        mode = "position"
        pressureBonus = math.max(0, num(position.pressureGain, 0))
            * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_POSITION_PRESSURE_WEIGHT", 450)
            + math.max(0, num(position.targetValue, 0)) * 0.04
        positionPenalty = cfgNumber(ctx, "PIPELINE_V2_ENDGAME_LATE_POSITION_ONLY_PENALTY", 2200)
        forceBonus = math.floor(late.value * 0.35 + pressureBonus - positionPenalty)
        score.force = score.force + forceBonus
        score.breakdown.reasons[#score.breakdown.reasons + 1] =
            forceBonus >= 0 and "endgame_late_aggression_pressure" or "endgame_late_aggression_position_penalty"
    else
        return
    end

    score.breakdown.endgameLateAggression = {
        mode = mode,
        turn = late.turn,
        startTurn = late.startTurn,
        age = late.age,
        ownUnits = late.ownUnits,
        enemyUnits = late.enemyUnits,
        unitAdvantage = late.unitAdvantage,
        equalUnits = late.equalUnits,
        baseValue = late.value,
        forceBonus = math.floor(forceBonus),
        commandantBonus = math.floor(commandantBonus),
        pressureBonus = math.floor(pressureBonus),
        positionPenalty = math.floor(positionPenalty),
        damage = damage,
        kills = kills,
        commandantDamage = commandantDamage
    }
end

local function positionActionProgress(position)
    local total = 0
    local seen = false
    local first = tonumber(position and position.drawApproachProgress)
    if first ~= nil then
        total = total + first
        seen = true
    end
    local second = position and position.secondDrawPressure and tonumber(position.secondDrawPressure.progress)
    if second ~= nil then
        total = total + second
        seen = true
    end
    return seen and total or nil
end

local function closestDistanceAfter(ai, afterOur, ctx)
    if not afterOur then
        return nil
    end
    local playerId = ctx and ctx.aiPlayer or afterOur.currentPlayer
    local enemyPlayer = ctx and ctx.enemyPlayer
    if not enemyPlayer and ai and ai.getOpponentPlayer and playerId then
        local ok, result = pcall(ai.getOpponentPlayer, ai, playerId)
        if ok and result then
            enemyPlayer = result
        end
    end
    if not (playerId and enemyPlayer) then
        return nil
    end
    return closestFactionDistance(ai, afterOur, playerId, enemyPlayer, false)
        or closestFactionDistance(ai, afterOur, playerId, enemyPlayer, true)
end

local function applyEndgameDrawClosure(score, ai, state, ctx, candidate, position, options)
    if not (isEndgameRuntime(ctx) and position and position.accepted == true) then
        return
    end
    if cfgBool(ctx, "PIPELINE_V2_ENDGAME_DRAW_CLOSURE_ENABLED", true) ~= true then
        return
    end
    if candidate and candidate.containsAttack == true then
        return
    end

    local draw = drawPressure.build(ai, state, ctx)
    if not (draw and draw.active == true and draw.pressureLimit == true) then
        return
    end
    if not noLegalCombatAvailable(ctx) then
        return
    end

    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer
    local enemyPlayer = ctx and ctx.enemyPlayer
    if not enemyPlayer and ai and ai.getOpponentPlayer and playerId then
        local ok, result = pcall(ai.getOpponentPlayer, ai, playerId)
        if ok and result then
            enemyPlayer = result
        end
    end

    local beforeDistance = nil
    if playerId and enemyPlayer then
        beforeDistance = closestFactionDistance(ai, state, playerId, enemyPlayer, false)
            or closestFactionDistance(ai, state, playerId, enemyPlayer, true)
    end
    local afterDistance = closestDistanceAfter(ai, options and options.afterOur, ctx)
    local globalProgress = (beforeDistance and afterDistance) and (beforeDistance - afterDistance) or nil
    local actionProgress = positionActionProgress(position)
    local progress = actionProgress
    if progress == nil then
        progress = globalProgress
    end

    local wave = drawWaveScale(ctx, draw)
    local value = 0
    local reason = nil
    if progress and progress > 0 then
        value = value + math.floor(progress
            * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DRAW_CLOSURE_PROGRESS_BONUS", 2200)
            * wave)
        reason = "endgame_draw_closure_progress"
    elseif progress == 0 then
        value = value - math.floor(cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DRAW_CLOSURE_STAGNATION_PENALTY", 3500) * wave)
        reason = "endgame_draw_closure_stagnation"
    elseif progress and progress < 0 then
        value = value - math.floor(math.abs(progress)
            * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DRAW_CLOSURE_RETREAT_PENALTY", 4200)
            * wave)
        reason = "endgame_draw_closure_retreat"
    end

    local rangeBonus = 0
    if afterDistance ~= nil then
        if afterDistance <= 1 then
            rangeBonus = cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DRAW_CLOSURE_ADJACENT_BONUS", 6500)
        elseif afterDistance <= 2 then
            rangeBonus = cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DRAW_CLOSURE_RANGE2_BONUS", 2800)
        end
        value = value + math.floor(rangeBonus * wave)
    end

    if value == 0 and reason == nil then
        return
    end

    score.force = score.force + value
    score.breakdown.reasons[#score.breakdown.reasons + 1] = reason or "endgame_draw_closure_range"
    score.breakdown.endgameDrawClosure = {
        value = value,
        reason = reason,
        actionProgress = actionProgress,
        globalProgress = globalProgress,
        beforeDistance = beforeDistance,
        afterDistance = afterDistance,
        rangeBonus = rangeBonus,
        wave = wave,
        streak = draw.streak,
        urgency = draw.urgency,
        urgencyRatio = draw.urgencyRatio,
        remainingBeforeLimit = draw.remainingBeforeLimit
    }
    if ctx and ctx.stats then
        ctx.stats.pipelineV2EndDrawClosureApplied =
            num(ctx.stats.pipelineV2EndDrawClosureApplied, 0) + 1
        ctx.stats.pipelineV2EndDrawClosureLastValue = value
        ctx.stats.pipelineV2EndDrawClosureLastProgress = progress
    end
end

local function applyEndgamePressure(score, ai, state, ctx, candidate, trade, position, options)
    score.breakdown.reasons = score.breakdown.reasons or {}

    if not isEndgameRuntime(ctx) then
        applyLateEndgameAggression(score, ai, state, ctx, candidate, trade, position)
        return
    end

    local skips = skipActionCount(candidate)
    if skips > 0 then
        local skipPenalty = skips * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_SKIP_ACTION_PENALTY", 12000)
        score.force = score.force - skipPenalty
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "endgame_skip_action_penalty"
        score.breakdown.endgameSkipPenalty = {
            skips = skips,
            penalty = skipPenalty
        }
    end

    if trade and trade.accepted == true and candidate and candidate.containsAttack == true then
        local damage = num(trade.totalDamage, 0)
        local kills = num(trade.kills, 0)
        local commandantDamage = num(trade.commandantDamage, 0)
        local attackBonus = cfgNumber(ctx, "PIPELINE_V2_ENDGAME_ATTACK_BONUS", 2400)
        local damageBonus = damage * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DAMAGE_WEIGHT", 520)
        local killBonus = kills * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_KILL_BONUS", 1600)
        local commandantBonus = commandantDamage
            * cfgNumber(ctx, "PIPELINE_V2_ENDGAME_COMMANDANT_DAMAGE_WEIGHT", 2400)

        score.force = score.force + attackBonus + damageBonus + killBonus
        score.commandant = score.commandant + commandantBonus
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "endgame_attack_closure_bias"
        score.breakdown.endgame = {
            mode = "attack",
            damage = damage,
            kills = kills,
            commandantDamage = commandantDamage,
            attackBonus = attackBonus,
            damageBonus = damageBonus,
            killBonus = killBonus,
            commandantBonus = commandantBonus
        }
        applyLateEndgameAggression(score, ai, state, ctx, candidate, trade, position)
        return
    end

    if position and position.accepted == true then
        local pressureGain = num(position.pressureGain, 0)
        local targetValue = num(position.targetValue, 0)
        local positionPenalty = cfgNumber(ctx, "PIPELINE_V2_ENDGAME_POSITION_ONLY_PENALTY", 1600)
        local ownSupply = supplyCount(ctx, ctx and ctx.aiPlayer or nil, "own")
        local deployPenalty = candidate
            and candidate.containsDeploy == true
            and (
                ownSupply > 0
                and cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DEPLOY_WITH_SUPPLY_PENALTY", 600)
                or cfgNumber(ctx, "PIPELINE_V2_ENDGAME_DEPLOY_PENALTY", 9000)
            )
            or 0

        score.force = score.force - positionPenalty
        score.supply = score.supply - deployPenalty
        score.position = score.position + pressureGain * 0.18 + targetValue * 0.08
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "endgame_position_only_penalty"
        score.breakdown.endgame = {
            mode = "position",
            pressureGain = pressureGain,
            targetValue = targetValue,
            positionPenalty = positionPenalty,
            deployPenalty = deployPenalty,
            ownSupply = ownSupply
        }
        applyEndgameDrawClosure(score, ai, state, ctx, candidate, position, options)
        applyLateEndgameAggression(score, ai, state, ctx, candidate, trade, position)
    end
end

function M.score(ai, state, ctx, candidate, options)
    local _ = ai
    local _state = state
    local score = scoreModel.new(candidate and candidate.signature or "mid_v2")
    local trade = candidate and candidate.midTrade or nil
    local position = candidate and candidate.midPosition or nil
    local tags = candidate and candidate.tacticalTags or {}

    if trade and trade.class == "win_now" then
        score.tier = scoreModel.TIER.WIN_NOW
        score.terminal = 100000
    elseif trade and trade.class == "kill" then
        score.tier = scoreModel.TIER.MAJOR_ADVANTAGE
    else
        score.tier = scoreModel.TIER.NORMAL
    end

    if position and position.accepted == true and not trade then
        local exposureDamage = num(position.exposureDamage, 0) + num(position.secondExposureDamage, 0)
        local destinationExposureDamage = num(position.destinationExposureDamage, 0)
        local destinationExposurePenalty = num(position.destinationExposurePenalty, 0)
        local pressureGain = num(position.pressureGain, 0)
        local targetValue = num(position.targetValue, 0)
        score.survival = score.survival - destinationExposurePenalty
        score.position = num(position.score, 0) + targetValue * 0.35 + pressureGain * 0.4
        score.risk = -exposureDamage * 120 - math.floor(destinationExposurePenalty * 0.15)
        score.efficiency = num(candidate and candidate.cheapScore, 0) * 0.08
        score.breakdown.midPosition = {
            reason = position.reason or "mid_position",
            targetKey = position.targetKey,
            targetValue = targetValue,
            pressureGain = pressureGain,
            exposureDamage = exposureDamage,
            destinationExposureDamage = destinationExposureDamage,
            destinationExposureLethal = position.destinationExposureLethal == true,
            destinationExposurePenalty = destinationExposurePenalty,
            covered = position.covered,
            intent = position.intent,
            riskBand = position.riskBand
        }
        applyDrawPressure(score, ai, state, ctx, candidate, nil, options)
        applyEndgamePressure(score, ai, state, ctx, candidate, nil, position, options)
        applyMidUnitBalance(score, ai, state, ctx, candidate, nil, position)
        return scoreModel.finalize(score)
    end

    local tradeScore = num(trade and trade.score, 0)
    local materialDelta = num(trade and trade.materialDelta, 0)
    local commandantDamage = num(trade and trade.commandantDamage, 0)
    local targetValue = num(tags.midTargetValue, 0)
    local hpTradeNet = num(trade and trade.hpTradeNet, 0)
    local risk = -math.max(0, num(trade and trade.expectedLoss, 0) - num(trade and trade.counterCredit, 0))

    score.commandant = commandantDamage * 120
    score.material = materialDelta + num(trade and trade.inflictedMaterial, 0)
    score.position = targetValue * 0.45
    score.risk = risk
    score.efficiency = tradeScore + (hpTradeNet * 18) + num(candidate and candidate.cheapScore, 0) * 0.05
    if trade and trade.legalDamageCandidate == true then
        local penalty = cfgNumber(ctx, "PIPELINE_V2_MID_LEGAL_DAMAGE_ATTACK_PENALTY", 1800)
        score.material = score.material - penalty
        score.risk = score.risk - math.floor(penalty * 0.35)
        score.breakdown.midLegalDamageCandidate = {
            originalRejectReason = trade.originalRejectReason,
            penalty = penalty
        }
        score.breakdown.reasons = score.breakdown.reasons or {}
        score.breakdown.reasons[#score.breakdown.reasons + 1] = "mid_legal_damage_candidate_penalty"
    end
    score.breakdown.midTrade = {
        reason = trade and trade.reason or "no_trade",
        class = trade and trade.class or "none",
        personality = trade and trade.personality or (ctx and ctx.midPersonality and ctx.midPersonality.profile and ctx.midPersonality.profile.name),
        hpTradeNet = hpTradeNet,
        materialDelta = materialDelta,
        targetValue = targetValue,
        legalDamageCandidate = trade and trade.legalDamageCandidate == true,
        originalRejectReason = trade and trade.originalRejectReason or nil
    }
    applyDrawPressure(score, ai, state, ctx, candidate, trade, options)
    applyEndgamePressure(score, ai, state, ctx, candidate, trade, nil, options)
    applyMidUnitBalance(score, ai, state, ctx, candidate, trade, nil)

    return scoreModel.finalize(score)
end

return M
