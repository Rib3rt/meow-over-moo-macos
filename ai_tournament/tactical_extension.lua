local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local REQUIRED_BUCKETS = {
    lethal = true,
    anti_lethal = true,
    commandant_pressure = true,
    high_value_attack = true,
    supply_defense = true,
    supply_offense = true,
    repair = true
}

local function defaultResult(mode)
    return {
        mode = mode or "forcing_line",
        result = "neutral",
        depth = 0,
        harmToUs = 0,
        tierUpgrade = nil,
        tierDowngrade = nil,
        survivalDelta = 0,
        forceDelta = 0,
        commandantDelta = 0,
        materialDelta = 0,
        riskDelta = 0,
        proof = {},
        refutation = {},
        reasons = {}
    }
end

local function copyActions(actions)
    local out = {}
    for i = 1, #(actions or {}) do
        out[i] = actions[i]
    end
    return out
end

local function addReason(result, reason)
    if reason and reason ~= "" then
        result.reasons[#result.reasons + 1] = reason
    end
end

function M.shouldExtendCandidate(ai, candidate, fastScore, replyResult, ctx)
    local _ = ai
    local _ = replyResult
    if not candidate or not ctx then
        return false
    end

    if ctx.hardStop and ctx.hardStop() then
        return false
    end

    if ctx.tacticalGate and ctx.tacticalGate.needsTacticalExtension
        and ctx.tacticalGate.needsTacticalExtension(ai, nil, candidate, ctx) then
        return true
    end

    local scoreObj = fastScore or candidate.fastScore
    if scoreObj and ctx.score then
        local tier = scoreObj.tier
        if tier == ctx.score.TIER.FORCE_WIN_NEXT
            or tier == ctx.score.TIER.STOP_FORCE
            or tier == ctx.score.TIER.AVOID_LOSS
            or tier == ctx.score.TIER.MAJOR_ADVANTAGE then
            return true
        end
    end

    return false
end

function M.generateForcingContinuations(ai, state, playerId, ctx, opts)
    local options = opts or {}
    local maxCandidates = options.maxCandidates
        or (ctx and ctx.dynamicMaxTacticalExtensions)
        or (ctx.cfg.MAX_TACTICAL_EXTENSIONS or 24)
    local remainingMs = ctx.remainingMs and ctx:remainingMs() or nil
    if remainingMs and remainingMs < 180 then
        maxCandidates = math.min(maxCandidates, 12)
    end
    if remainingMs and remainingMs < 120 then
        maxCandidates = math.min(maxCandidates, 8)
    end
    local candidates = ctx.turnEnumerator.generateFullTurnCandidates(ai, state, playerId, ctx, {
        mode = options.mode or "forcing_extension",
        includeDeploy = options.includeDeploy ~= false,
        maxCandidates = maxCandidates,
        maxFirstActions = options.maxFirstActions or 32,
        maxSecondActions = options.maxSecondActions or 16
    }) or {}

    local filtered = {}
    for _, candidate in ipairs(candidates) do
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
        local keep = false
        for _, bucket in ipairs(candidate.buckets or {}) do
            if REQUIRED_BUCKETS[bucket] then
                keep = true
                break
            end
        end
        if not keep and candidate.containsDeploy then
            keep = true
        end
        if keep then
            filtered[#filtered + 1] = candidate
        end
    end

    if #filtered > 0 then
        return filtered
    end

    return candidates
end

function M.scoreExtensionResult(ai, line, ctx)
    local _ = ai
    local _ = ctx
    local result = defaultResult("forcing_line")
    if not line then
        addReason(result, "no_line")
        return result
    end

    if line.timeout then
        result.result = "timeout"
        result.depth = num(line.depth, 0)
        result.harmToUs = num(line.harmToUs, 0)
        result.proof = line.proof or {}
        result.refutation = line.refutation or {}
        addReason(result, "tactical_extension_timeout")
        return result
    end

    if line.provedForce then
        result.result = "proved_force"
        result.depth = num(line.depth, 1)
        result.tierUpgrade = ctx and ctx.score and ctx.score.TIER.FORCE_WIN_NEXT or nil
        result.survivalDelta = result.survivalDelta + num(line.survivalDelta, 300)
        result.forceDelta = result.forceDelta + num(line.forceDelta, 3200)
        result.commandantDelta = result.commandantDelta + num(line.commandantDelta, 1800)
        result.materialDelta = result.materialDelta + num(line.materialDelta, 150)
        result.riskDelta = result.riskDelta + num(line.riskDelta, -120)
        result.proof = line.proof or {}
        addReason(result, "tactical_extension_proved_force")
        return result
    end

    if line.refutedForce then
        result.result = "refuted_force"
        result.depth = num(line.depth, 1)
        result.tierDowngrade = ctx and ctx.score and ctx.score.TIER.NORMAL or nil
        result.forceDelta = result.forceDelta + num(line.forceDelta, -2200)
        result.commandantDelta = result.commandantDelta + num(line.commandantDelta, -800)
        result.materialDelta = result.materialDelta + num(line.materialDelta, -120)
        result.riskDelta = result.riskDelta + num(line.riskDelta, -380)
        result.refutation = line.refutation or {}

        if line.ownCommandantDies and ctx and ctx.score then
            result.tierDowngrade = ctx.score.TIER.BAD_BUT_LEGAL
            result.survivalDelta = result.survivalDelta - 900000
            addReason(result, "reply_kills_own_commandant")
        end

        addReason(result, "tactical_extension_refuted_force")
        return result
    end

    result.depth = num(line.depth, 0)
    result.proof = line.proof or {}
    result.refutation = line.refutation or {}
    addReason(result, "tactical_extension_neutral")
    return result
end

function M.evaluateReplyContinuation(ai, beforeEnemyTurn, afterEnemyTurn, enemyCandidate, ctx)
    local result = defaultResult("reply_continuation")
    if not beforeEnemyTurn or not afterEnemyTurn then
        addReason(result, "missing_reply_state")
        return result
    end

    if ctx.evaluator.isCommandantDead(afterEnemyTurn, ctx.aiPlayer) then
        result.harmToUs = 1000000
        result.result = "refuted_force"
        result.ownCommandantDies = true
        addReason(result, "reply_kills_own_commandant")
        return result
    end

    local beforeFeatures = ctx.cache.features(ai, beforeEnemyTurn, ctx.aiPlayer, ctx)
    local afterFeatures = ctx.cache.features(ai, afterEnemyTurn, ctx.aiPlayer, ctx)

    local hpLoss = math.max(0, num(beforeFeatures.ownHubHp, 0) - num(afterFeatures.ownHubHp, 0))
    local materialLoss = math.max(0, num(beforeFeatures.materialDiff, 0) - num(afterFeatures.materialDiff, 0))
    local pressureDrop = math.max(0, num(beforeFeatures.commandantPressure, 0) - num(afterFeatures.commandantPressure, 0))
    local exposureRise = math.max(0, num(afterFeatures.exposedFriendlyValue, 0) - num(beforeFeatures.exposedFriendlyValue, 0))

    result.harmToUs = (hpLoss * 900) + (materialLoss * 110) + (pressureDrop * 180) + (exposureRise * 14)
    if enemyCandidate and enemyCandidate.containsDeploy then
        result.harmToUs = result.harmToUs + 120
    end

    if result.harmToUs > 0 then
        result.result = "refuted_force"
        result.refutedForce = true
        addReason(result, "enemy_reply_continuation_harms_us")
    end

    return result
end

function M.evaluateFinalist(ai, beforeState, afterOurTurn, replyResult, candidate, ctx)
    local _ = beforeState
    local extension = defaultResult("forcing_line")
    local pressureCandidate = false

    for _, bucket in ipairs((candidate and candidate.buckets) or {}) do
        if bucket == "commandant_pressure" then
            pressureCandidate = true
            break
        end
    end
    if candidate and candidate.tacticalTags and candidate.tacticalTags.commandantPressure then
        pressureCandidate = true
    end

    if ctx.hardStop and ctx.hardStop() then
        extension.result = "timeout"
        addReason(extension, "budget_hard_stop")
        return extension
    end

    if ctx.remainingMs and ctx:remainingMs() < num(ctx.cfg.MIN_EXTENSION_BUDGET_MS, 120) then
        addReason(extension, "insufficient_extension_budget")
        return extension
    end

    if not M.shouldExtendCandidate(ai, candidate, nil, replyResult, ctx) then
        addReason(extension, "candidate_not_forcing")
        return extension
    end

    local startState = nil
    if replyResult and replyResult.afterEnemy then
        startState = ai:prepareStateForPlayerTurn(replyResult.afterEnemy, ctx.aiPlayer, {
            resetDeployment = true,
            resetActionCount = true
        })
    else
        startState = ai:prepareStateForPlayerTurn(afterOurTurn, ctx.aiPlayer, {
            resetDeployment = true,
            resetActionCount = true
        })
    end

    local forcing = M.generateForcingContinuations(ai, startState, ctx.aiPlayer, ctx, {
        mode = "forcing_extension",
        includeDeploy = true
    })

    local probeLimit = math.min(#forcing, (ctx.dynamicMaxTacticalExtensions or ctx.cfg.MAX_TACTICAL_EXTENSIONS or 24))
    if probeLimit <= 0 then
        addReason(extension, "no_forcing_continuations")
        return extension
    end

    local refutedLine = nil
    local timedOut = false
    local sawOwnForce = false

    for index = 1, probeLimit do
        if ctx.shouldStop and ctx.shouldStop() then
            timedOut = true
            break
        end
        local cont = forcing[index]
        local afterContinuation = ctx.cache.simulate(ai, startState, cont.actions, ctx.aiPlayer, ctx)
        if afterContinuation then
            if ctx.evaluator.isCommandantDead(afterContinuation, ctx.enemyPlayer) then
                local line = {
                    provedForce = true,
                    depth = 1,
                    proof = {
                        {
                            candidateSignature = cont.signature,
                            actions = copyActions(cont.actions)
                        }
                    }
                }
                return M.scoreExtensionResult(ai, line, ctx)
            end

            local ownForce = false
            if ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
                ownForce = ctx.threatModel.hasImmediateCommandantLethal(ai, afterContinuation, ctx.aiPlayer, ctx.enemyPlayer, ctx) == true
            end

            if ownForce then
                sawOwnForce = true
                local enemyTurn = ai:prepareStateForPlayerTurn(afterContinuation, ctx.enemyPlayer, {
                    resetDeployment = true,
                    resetActionCount = true
                })

                local enemyReplies = M.generateForcingContinuations(ai, enemyTurn, ctx.enemyPlayer, ctx, {
                    mode = "enemy_adversarial",
                    maxCandidates = math.min(12, ctx.cfg.MAX_ENEMY_REPLY_CANDIDATES or 20),
                    maxFirstActions = 24,
                    maxSecondActions = 12
                })

                local refuted = false
                local ownCommandantDies = false
                local refSig = nil

                for _, enemyCandidate in ipairs(enemyReplies) do
                    if ctx.shouldStop and ctx.shouldStop() then
                        timedOut = true
                        break
                    end
                    local afterEnemy = ctx.cache.simulate(ai, enemyTurn, enemyCandidate.actions, ctx.enemyPlayer, ctx)
                    if afterEnemy then
                        if ctx.evaluator.isCommandantDead(afterEnemy, ctx.aiPlayer) then
                            refuted = true
                            ownCommandantDies = true
                            refSig = enemyCandidate.signature
                            break
                        end

                        local ourNext = ai:prepareStateForPlayerTurn(afterEnemy, ctx.aiPlayer, {
                            resetDeployment = true,
                            resetActionCount = true
                        })
                        local stillForce = false
                        if ctx.threatModel and ctx.threatModel.hasImmediateCommandantLethal then
                            stillForce = ctx.threatModel.hasImmediateCommandantLethal(ai, ourNext, ctx.aiPlayer, ctx.enemyPlayer, ctx) == true
                        end
                        if not stillForce then
                            refuted = true
                            refSig = enemyCandidate.signature
                            break
                        end
                    end
                end

                if timedOut then
                    break
                end

                if not refuted then
                    local line = {
                        provedForce = true,
                        depth = 2,
                        proof = {
                            {candidateSignature = cont.signature, actions = copyActions(cont.actions)}
                        }
                    }
                    return M.scoreExtensionResult(ai, line, ctx)
                end

                refutedLine = {
                    refutedForce = true,
                    ownCommandantDies = ownCommandantDies,
                    depth = 2,
                    proof = {
                        {candidateSignature = cont.signature, actions = copyActions(cont.actions)}
                    },
                    refutation = {
                        {candidateSignature = refSig}
                    }
                }
            end
        end

        if ctx.hardStop and ctx.hardStop() then
            timedOut = true
            break
        end
    end

    if timedOut then
        local line = {
            timeout = true,
            depth = 1,
            harmToUs = 0
        }
        return M.scoreExtensionResult(ai, line, ctx)
    end

    if pressureCandidate and (not sawOwnForce) and (not refutedLine) then
        local line = {
            refutedForce = true,
            depth = 1,
            refutation = {
                {
                    reason = "no_forcing_continuation"
                }
            }
        }
        return M.scoreExtensionResult(ai, line, ctx)
    end

    if refutedLine then
        return M.scoreExtensionResult(ai, refutedLine, ctx)
    end

    return extension
end

return M
