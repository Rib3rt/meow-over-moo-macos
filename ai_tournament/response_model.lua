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

local function clampLimit(value, minValue, maxValue)
    local n = num(value, minValue)
    if n < minValue then
        return minValue
    end
    if maxValue and n > maxValue then
        return maxValue
    end
    return n
end

local function countDeployCandidates(candidates)
    local total = 0
    for _, candidate in ipairs(candidates or {}) do
        if candidate and candidate.containsDeploy then
            total = total + 1
        end
    end
    return total
end

local function isHubUnit(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isHubUnit then
        return ai:isHubUnit(unit)
    end
    return unit.name == "Commandant"
end

local function isObstacleUnit(ai, unit)
    if not unit then
        return false
    end
    if ai and ai.isObstacleUnit then
        return ai:isObstacleUnit(unit)
    end
    return unit.name == "Rock" or unit.player == 0
end

local function getUnitValue(ai, unit, state)
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

local function unitKey(unit)
    if not unit then
        return ""
    end
    return table.concat({
        tostring(unit.player or ""),
        tostring(unit.name or ""),
        tostring(unit.row or ""),
        tostring(unit.col or "")
    }, ":")
end

local function aliveCombatUnits(ai, state, playerId)
    local units = {}
    for _, unit in ipairs((state and state.units) or {}) do
        local hp = num(unit and (unit.currentHp or unit.startingHp), 0)
        if unit
            and unit.player == playerId
            and hp > 0
            and not isHubUnit(ai, unit)
            and not isObstacleUnit(ai, unit) then
            units[unitKey(unit)] = unit
        end
    end
    return units
end

local function ownCandidateCompensationValue(ownCandidate, ctx)
    local combat = ownCandidate and ownCandidate.combatValue or nil
    if not combat then
        return 0
    end

    local targetValue = math.max(0, num(combat.targetValue, 0))
    local kills = math.max(0, num(combat.kills, 0))
    local damage = math.max(0, num(combat.damage, 0))
    local commandantDamage = math.max(0, num(combat.commandantDamage, 0))
    local damageValue = num(ctx and ctx.cfg and ctx.cfg.REPLY_FREE_UNIT_LOSS_DAMAGE_COMPENSATION, 12)
    local commandantDamageValue =
        num(ctx and ctx.cfg and ctx.cfg.REPLY_FREE_UNIT_LOSS_COMMANDANT_DAMAGE_COMPENSATION, 35)

    local killValue = kills > 0 and math.max(targetValue, targetValue * kills) or 0
    return killValue
        + (damage * damageValue)
        + (commandantDamage * commandantDamageValue)
end

local function scoreFreeOwnUnitLoss(ai, beforeEnemyTurn, afterEnemy, ownCandidate, ctx)
    if not (ctx and ctx.cfg and ctx.cfg.REPLY_FREE_UNIT_LOSS_GUARD_ENABLED == true) then
        return nil
    end
    if not (beforeEnemyTurn and afterEnemy and ownCandidate) then
        return nil
    end
    if ctx.evaluator
        and ctx.evaluator.isCommandantDead
        and ctx.evaluator.isCommandantDead(beforeEnemyTurn, ctx.enemyPlayer) then
        return nil
    end

    local beforeUnits = aliveCombatUnits(ai, beforeEnemyTurn, ctx.aiPlayer)
    local afterUnits = aliveCombatUnits(ai, afterEnemy, ctx.aiPlayer)
    local killed = {}
    local killedValue = 0
    for key, unit in pairs(beforeUnits) do
        if not afterUnits[key] then
            local value = getUnitValue(ai, unit, beforeEnemyTurn)
            killed[#killed + 1] = {
                name = unit.name,
                row = unit.row,
                col = unit.col,
                value = value
            }
            killedValue = killedValue + value
        end
    end
    if killedValue <= 0 then
        return nil
    end

    local compensation = ownCandidateCompensationValue(ownCandidate, ctx)
    local ratio = num(ctx.cfg.REPLY_FREE_UNIT_LOSS_COMPENSATION_RATIO, 0.8)
    local minNet = num(ctx.cfg.REPLY_FREE_UNIT_LOSS_MIN_NET_VALUE, 20)
    local netLoss = killedValue - (compensation / math.max(0.01, ratio))
    if netLoss < minNet then
        return {
            killedCount = #killed,
            killedValue = killedValue,
            compensation = compensation,
            netLoss = math.max(0, netLoss),
            penalty = 0,
            killed = killed
        }
    end

    local penalty = num(ctx.cfg.REPLY_FREE_UNIT_LOSS_BASE_PENALTY, 5000)
        + (netLoss * num(ctx.cfg.REPLY_FREE_UNIT_LOSS_NET_WEIGHT, 220))
    return {
        killedCount = #killed,
        killedValue = killedValue,
        compensation = compensation,
        netLoss = netLoss,
        penalty = penalty,
        killed = killed
    }
end

local function scoreEnemyDeployPunishment(ai, beforeEnemyTurn, afterEnemy, enemyCandidate, ctx)
    if not (ctx and ctx.supplyPlanner and ctx.supplyPlanner.evaluateDeployImpact) then
        return 0
    end

    local value = 0
    for _, action in ipairs((enemyCandidate and enemyCandidate.actions) or {}) do
        if action and action.type == "supply_deploy" then
            local impact = ctx.supplyPlanner.evaluateDeployImpact(
                ai,
                beforeEnemyTurn,
                afterEnemy,
                action,
                ctx.enemyPlayer,
                ctx,
                {candidate = enemyCandidate, enemyPerspective = true}
            ) or {value = 0}
            value = value + math.max(0, num(impact.value, 0))
        end
    end

    return value * 0.45
end

function M.scoreReplyForEnemy(ai, beforeEnemyTurn, afterEnemy, enemyCandidate, ctx, ownCandidate)
    local harm = 0
    local details = {}

    if not afterEnemy then
        return {
            harmToUs = 0,
            details = {reason = "nil_after_enemy"}
        }
    end

    if ctx.evaluator.isCommandantDead(afterEnemy, ctx.aiPlayer) then
        harm = harm + 1000000
        details.commandantKill = true
    end

    local beforeForUs = ctx.cache.features(ai, beforeEnemyTurn, ctx.aiPlayer, ctx)
    local afterForUs = ctx.cache.features(ai, afterEnemy, ctx.aiPlayer, ctx)

    local hpLoss = math.max(0, num(beforeForUs.ownHubHp, 0) - num(afterForUs.ownHubHp, 0))
    harm = harm + hpLoss * 1000
    details.commandantDamage = hpLoss

    local materialLoss = math.max(0, num(beforeForUs.materialDiff, 0) - num(afterForUs.materialDiff, 0))
    harm = harm + materialLoss * 120
    details.materialLoss = materialLoss

    local pressureReduction = math.max(0, num(beforeForUs.commandantPressure, 0) - num(afterForUs.commandantPressure, 0))
    harm = harm + pressureReduction * 250
    details.stopsOurPressure = pressureReduction

    local exposureGain = math.max(0, num(afterForUs.exposedFriendlyValue, 0) - num(beforeForUs.exposedFriendlyValue, 0))
    harm = harm + exposureGain * 16
    details.exposureGain = exposureGain

    local freeUnitLoss = scoreFreeOwnUnitLoss(ai, beforeEnemyTurn, afterEnemy, ownCandidate, ctx)
    if freeUnitLoss then
        local penalty = math.max(0, num(freeUnitLoss.penalty, 0))
        harm = harm + penalty
        details.freeUnitLossGuard = freeUnitLoss
        if ctx and ctx.stats then
            ctx.stats.replyOwnUnitKills =
                (ctx.stats.replyOwnUnitKills or 0) + num(freeUnitLoss.killedCount, 0)
            ctx.stats.replyOwnUnitKillValue =
                (ctx.stats.replyOwnUnitKillValue or 0) + num(freeUnitLoss.killedValue, 0)
            if penalty > 0 then
                ctx.stats.replyFreeUnitLossGuardHits =
                    (ctx.stats.replyFreeUnitLossGuardHits or 0) + 1
                ctx.stats.replyFreeUnitLossGuardPenalty =
                    (ctx.stats.replyFreeUnitLossGuardPenalty or 0) + penalty
                ctx.stats.replyFreeUnitLossGuardMaxPenalty =
                    math.max(ctx.stats.replyFreeUnitLossGuardMaxPenalty or 0, penalty)
            end
        end
    end

    if enemyCandidate and enemyCandidate.containsDeploy then
        local deployPunish = scoreEnemyDeployPunishment(ai, beforeEnemyTurn, afterEnemy, enemyCandidate, ctx)
        harm = harm + deployPunish
        details.deployCounter = deployPunish
    end

    if ctx.tacticalExtension and ctx.tacticalGate and ctx.tacticalGate.needsTacticalExtension
        and ctx.tacticalGate.needsTacticalExtension(ai, beforeEnemyTurn, enemyCandidate, ctx) then
        if ctx.stats then
            ctx.stats.enemyReplyTacticalExtensionChecks =
                (ctx.stats.enemyReplyTacticalExtensionChecks or 0) + 1
        end
        local ext = ctx.tacticalExtension.evaluateReplyContinuation(ai, beforeEnemyTurn, afterEnemy, enemyCandidate, ctx)
        harm = harm + num(ext and ext.harmToUs, 0)
        details.tacticalExtension = ext
        if ctx.stats and ext then
            ctx.stats.enemyReplyTacticalExtensionUsed =
                (ctx.stats.enemyReplyTacticalExtensionUsed or 0) + 1
        end
    end

    return {
        harmToUs = harm,
        details = details
    }
end

function M.generateAdversarialReplies(ai, enemyTurnState, ctx)
    local maxReplyCandidates = (ctx and ctx.dynamicEnemyReplyCap)
        or (ctx and ctx.cfg and ctx.cfg.MAX_ENEMY_REPLY_CANDIDATES)
        or 20
    local maxFirst = (ctx and ctx.dynamicEnemyFirstActionCap)
        or (ctx and ctx.cfg and ctx.cfg.ENEMY_REPLY_MAX_FIRST_ACTIONS)
        or (ctx and ctx.cfg and ctx.cfg.ANYTIME_MAX_FIRST_ACTIONS)
        or 12
    local maxSecond = (ctx and ctx.dynamicEnemySecondActionCap)
        or (ctx and ctx.cfg and ctx.cfg.ENEMY_REPLY_MAX_SECOND_ACTIONS)
        or (ctx and ctx.cfg and ctx.cfg.ANYTIME_MAX_SECOND_ACTIONS)
        or 6
    maxReplyCandidates = clampLimit(maxReplyCandidates, 1, 32)
    maxFirst = clampLimit(maxFirst, 1, 48)
    maxSecond = clampLimit(maxSecond, 1, 24)

    local opts = {
        mode = "enemy_adversarial",
        maxCandidates = maxReplyCandidates,
        maxFirstActions = maxFirst,
        maxSecondActions = maxSecond,
        includeDeploy = true
    }

    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(
        ai,
        enemyTurnState,
        ctx.enemyPlayer,
        ctx,
        opts
    ) or {}

    local deployCandidates = countDeployCandidates(candidates)
    if ctx and ctx.stats then
        ctx.stats.enemyReplyDeployCandidates = (ctx.stats.enemyReplyDeployCandidates or 0) + deployCandidates
        ctx.stats.enemyReplyCandidatesGenerated =
            (ctx.stats.enemyReplyCandidatesGenerated or 0) + #candidates
        ctx.stats.enemyReplyCandidatesGeneratedMax =
            math.max(ctx.stats.enemyReplyCandidatesGeneratedMax or 0, #candidates)
    end

    local result = {}
    local limit = maxReplyCandidates
    for i = 1, math.min(limit, #candidates) do
        result[#result + 1] = candidates[i]
    end

    if ctx and ctx.stats then
        local selectedDeploys = countDeployCandidates(result)
        ctx.stats.enemyDeployReplies = (ctx.stats.enemyDeployReplies or 0) + selectedDeploys
        ctx.stats.enemyReplyCandidatesSelected =
            (ctx.stats.enemyReplyCandidatesSelected or 0) + #result
    end

    return result
end

function M.generatePunitiveReplies(ai, enemyTurnState, ctx)
    return M.generateAdversarialReplies(ai, enemyTurnState, ctx)
end

function M.evaluateWorstReply(ai, afterOurTurn, ctx, ownCandidate)
    local hitsBefore = ctx and ctx.cache and num(ctx.cache.hits, 0) or 0
    local missesBefore = ctx and ctx.cache and num(ctx.cache.misses, 0) or 0
    local function finish(result)
        if ctx and ctx.cache and ctx.stats then
            ctx.stats.enemyReplyCacheHits =
                (ctx.stats.enemyReplyCacheHits or 0) + math.max(0, num(ctx.cache.hits, 0) - hitsBefore)
            ctx.stats.enemyReplyCacheMisses =
                (ctx.stats.enemyReplyCacheMisses or 0) + math.max(0, num(ctx.cache.misses, 0) - missesBefore)
        end
        return result
    end

    if ctx.cfg.USE_ENEMY_REPLY == false then
        return finish({
            total = 0,
            summary = "enemy_reply_disabled"
        })
    end

    local enemyTurnState = ai:prepareStateForPlayerTurn(afterOurTurn, ctx.enemyPlayer, {
        resetDeployment = true,
        resetActionCount = true
    })

    local replies = M.generateAdversarialReplies(ai, enemyTurnState, ctx)
    if #replies == 0 then
        return finish({
            total = 0,
            summary = "no_enemy_reply"
        })
    end
    local forceFirstReplyScore = false
    if ctx.shouldStop and ctx.shouldStop() then
        local canScoreFirstGenerated =
            ctx
            and ctx.cfg
            and ctx.cfg.REPLY_SCORE_FIRST_GENERATED_ENABLED == true
        if canScoreFirstGenerated and not (ctx.hardStop and ctx.hardStop()) then
            forceFirstReplyScore = true
            if ctx and ctx.stats then
                ctx.stats.enemyReplyFirstScoreForced =
                    (ctx.stats.enemyReplyFirstScoreForced or 0) + 1
            end
        else
            if ctx and ctx.stats then
                ctx.stats.enemyReplyWorstStoppedByBudget =
                    (ctx.stats.enemyReplyWorstStoppedByBudget or 0) + 1
                if canScoreFirstGenerated then
                    ctx.stats.enemyReplyFirstScoreForcedSkippedByHardStop =
                        (ctx.stats.enemyReplyFirstScoreForcedSkippedByHardStop or 0) + 1
                end
            end
            return finish({
                total = 0,
                summary = "no_scored_enemy_reply"
            })
        end
    end

    local worst = nil
    for index, reply in ipairs(replies) do
        local forceThisReply = forceFirstReplyScore and index == 1
        if forceThisReply and ctx.hardStop and ctx.hardStop() then
            if ctx and ctx.stats then
                ctx.stats.enemyReplyWorstStoppedByBudget =
                    (ctx.stats.enemyReplyWorstStoppedByBudget or 0) + 1
                ctx.stats.enemyReplyFirstScoreForcedSkippedByHardStop =
                    (ctx.stats.enemyReplyFirstScoreForcedSkippedByHardStop or 0) + 1
            end
            break
        end
        if (not forceThisReply) and ctx.shouldStop and ctx.shouldStop() then
            if ctx and ctx.stats then
                ctx.stats.enemyReplyWorstStoppedByBudget =
                    (ctx.stats.enemyReplyWorstStoppedByBudget or 0) + 1
            end
            break
        end
        local afterEnemy = ctx.cache.simulate(ai, enemyTurnState, reply.actions, ctx.enemyPlayer, ctx)
        local replyScore = M.scoreReplyForEnemy(ai, enemyTurnState, afterEnemy, reply, ctx, ownCandidate)
        if ctx and ctx.stats then
            ctx.stats.enemyReplyScoredWorst =
                (ctx.stats.enemyReplyScoredWorst or 0) + 1
        end

        local item = {
            candidate = reply,
            afterEnemy = afterEnemy,
            replyScore = replyScore,
            harmToUs = num(replyScore and replyScore.harmToUs, 0)
        }

        if not worst
            or item.harmToUs > worst.harmToUs
            or (item.harmToUs == worst.harmToUs and tostring(reply.signature) < tostring(worst.candidate.signature)) then
            worst = item
        end

    end

    if not worst then
        return finish({
            total = 0,
            summary = "no_scored_enemy_reply"
        })
    end

    return finish({
        total = -(worst.harmToUs or 0),
        riskPenalty = -(worst.harmToUs or 0),
        worstReply = worst.candidate.actions,
        afterEnemy = worst.afterEnemy,
        summary = {
            mode = "adversarial_worst_of_top_k",
            harmToUs = worst.harmToUs,
            signature = worst.candidate.signature,
            score = worst.replyScore
        }
    })
end

return M
