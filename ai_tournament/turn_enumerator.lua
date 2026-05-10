local candidateBuckets = require("ai_tournament.candidate_buckets")
local repairHeuristics = require("ai_tournament.repair_heuristics")

local M = {}

local function num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function copyArray(values)
    local out = {}
    for i = 1, #(values or {}) do
        out[i] = values[i]
    end
    return out
end

local function earlyDiagnosticsEnabled(ctx, playerId, replyMode)
    if replyMode then
        return false
    end
    if not (ctx and ctx.cfg and ctx.cfg.EARLY_DIAGNOSTICS_ENABLED == true and ctx.stats) then
        return false
    end
    if ctx.aiPlayer ~= nil and playerId ~= nil and ctx.aiPlayer ~= playerId then
        return false
    end
    if not (ctx.phase and ctx.phase.early == true and ctx.earlyPlan and ctx.earlyPlan.active == true) then
        return false
    end

    local maxTurn = num(ctx.cfg.EARLY_DIAGNOSTIC_MAX_TURN, 10)
    local phaseTurn = num(ctx.stats.phaseTurn or (ctx.phase and ctx.phase.turn), 0)
    return phaseTurn > 0 and phaseTurn <= maxTurn
end

local function earlyProductiveEnumerationEnabled(ctx, playerId, replyMode, options)
    if replyMode then
        return false
    end
    if options and options.diagnosticLabel == "audit" then
        return false
    end
    if not (ctx and ctx.cfg and ctx.cfg.EARLY_PRODUCTIVE_ENUMERATION_ENABLED == true) then
        return false
    end
    if ctx
        and ctx.earlyPlan
        and ctx.earlyPlan.role ~= "response"
        and not (ctx.cfg and ctx.cfg.EARLY_PRODUCTIVE_OPENING_ENABLED == true) then
        return false
    end
    return earlyDiagnosticsEnabled(ctx, playerId, false)
        or (
            ctx
            and ctx.aiPlayer == playerId
            and ctx.phase
            and ctx.phase.early == true
            and ctx.earlyPlan
            and ctx.earlyPlan.active == true
        )
end

local function simpleBucketForAction(entry)
    local action = entry and entry.action
    local actionType = action and action.type or "unknown"
    if actionType == "attack" then
        return "direct_attack"
    end
    if actionType == "supply_deploy" then
        local details = entry.deployDetails or {}
        if num(details.immediateDefense, 0) > 0 or num(details.repairValue, 0) > 0 then
            return "supply_defense"
        end
        return "supply_offense"
    end
    if actionType == "repair" then
        return "repair"
    end
    if actionType == "move" then
        return "positional_move"
    end
    return "fallback"
end

local function cheapFirstActionScore(entry, state, ai, ctx)
    local action = entry and entry.action
    local actionType = action and action.type or "unknown"
    local base = 0
    if actionType == "attack" then
        base = 4000
    elseif actionType == "supply_deploy" then
        base = 3000
    elseif actionType == "repair" then
        base = 1600
    elseif actionType == "move" then
        base = 1200
    elseif actionType == "skip" then
        base = -100
    end
    local score = base + num(entry and entry.cheapScore, 0)
    if actionType == "repair" then
        score = repairHeuristics.capFullHpRepairCheapScore(ai, state, action, score, ctx)
    end
    return score
end

local function selectProductiveFirstActions(entries, maxTotal, state, ai, ctx)
    local prepared = {}
    local seen = {}
    for _, raw in ipairs(entries or {}) do
        local entry = M.normalizeEntry(raw)
        if entry and entry.action then
            local signature = tostring(entry.signature or M.actionSignature(entry.action))
            if not seen[signature] then
                seen[signature] = true
                local normalized = {}
                for key, value in pairs(entry) do
                    normalized[key] = value
                end
                normalized.action = entry.action
                normalized.signature = signature
                normalized.bucket = normalized.bucket or simpleBucketForAction(normalized)
                normalized.cheapScore = cheapFirstActionScore(normalized, state, ai, ctx)
                normalized.buckets = normalized.buckets or {normalized.bucket}
                normalized.source = normalized.source or "productive_first_action"
                prepared[#prepared + 1] = normalized
            end
        end
    end

    table.sort(prepared, function(a, b)
        local scoreA = num(a and a.cheapScore, 0)
        local scoreB = num(b and b.cheapScore, 0)
        if scoreA ~= scoreB then
            return scoreA > scoreB
        end
        return tostring(a and a.signature or "") < tostring(b and b.signature or "")
    end)

    local selected = {}
    for i = 1, math.min(num(maxTotal, #prepared), #prepared) do
        selected[#selected + 1] = prepared[i]
    end
    return selected, #prepared
end

local function appendUniqueBucket(target, bucket, seen)
    if not bucket or bucket == "" then
        return
    end
    if seen[bucket] then
        return
    end
    seen[bucket] = true
    target[#target + 1] = bucket
end

local function actionHasPosition(action, key)
    return type(action) == "table" and type(action[key]) == "table"
end

local function collectLegal(ai, state, playerId, ctx, options)
    local opts = options or {}
    if ctx and ctx.cache and ctx.cache.legalActions then
        return ctx.cache.legalActions(ai, state, playerId, ctx, opts) or {}
    end
    if ai and ai.collectLegalActions then
        return ai:collectLegalActions(state, {
            aiPlayer = playerId,
            usedUnits = opts.usedUnits,
            includeMove = opts.includeMove,
            includeAttack = opts.includeAttack,
            includeRepair = opts.includeRepair,
            includeDeploy = opts.includeDeploy,
            allowFullHpHealerRepairException = opts.allowFullHpHealerRepairException
        }) or {}
    end
    return {}
end

function M.actionSignature(action)
    return candidateBuckets.actionSignature(action)
end

function M.sequenceSignature(actions)
    local parts = {}
    for _, action in ipairs(actions or {}) do
        parts[#parts + 1] = M.actionSignature(action)
    end
    return table.concat(parts, "|")
end

function M.normalizeEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end

    if entry.action then
        return entry
    end

    if entry.type then
        return {
            type = entry.type,
            action = entry,
            unit = entry.unit,
            target = entry.target,
            cheapScore = entry.cheapScore
        }
    end

    return nil
end

function M.collectTournamentActions(ai, state, playerId, ctx, opts)
    local options = opts or {}
    local entries = {}
    local allowHealerRepairException = options.allowFullHpHealerRepairException
    if allowHealerRepairException == nil then
        local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
        allowHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    end

    local nonDeploy = collectLegal(ai, state, playerId, ctx, {
        includeMove = options.includeMove ~= false,
        includeAttack = options.includeAttack ~= false,
        includeRepair = options.includeRepair ~= false,
        includeDeploy = false,
        allowFullHpHealerRepairException = allowHealerRepairException == true
    }) or {}

    for _, entry in ipairs(nonDeploy) do
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
        local normalized = M.normalizeEntry(entry)
        if normalized and normalized.action then
            entries[#entries + 1] = normalized
        end
    end

    if options.includeDeploy ~= false and ctx and ctx.supplyPlanner and ctx.supplyPlanner.getDeployActionEntries then
        local deployEntries = ctx.supplyPlanner.getDeployActionEntries(ai, state, playerId, ctx) or {}
        if ctx and ctx.stats then
            if playerId == ctx.aiPlayer then
                ctx.stats.deployCandidatesOwn = (ctx.stats.deployCandidatesOwn or 0) + #deployEntries
            elseif playerId == ctx.enemyPlayer then
                ctx.stats.deployCandidatesEnemy = (ctx.stats.deployCandidatesEnemy or 0) + #deployEntries
            end
        end
        for _, entry in ipairs(deployEntries) do
            if ctx and ctx.shouldStop and ctx.shouldStop() then
                break
            end
            local normalized = M.normalizeEntry(entry)
            if normalized and normalized.action and normalized.action.type == "supply_deploy" then
                entries[#entries + 1] = normalized
            end
        end
    end

    return entries
end

function M.addCandidate(result, seen, actions, firstEntry, secondEntry, maxCandidates, opts)
    local options = opts or {}
    local sequence = copyArray(actions or {})
    if #sequence == 0 then
        return nil
    end

    if #sequence >= 2 then
        local deployCount = 0
        for _, action in ipairs(sequence) do
            if action and action.type == "supply_deploy" then
                deployCount = deployCount + 1
                if deployCount > 1 then
                    return nil
                end
            end
        end
    end

    local signature = M.sequenceSignature(sequence)
    if seen[signature] then
        return nil
    end

    local buckets = {}
    local bucketSeen = {}
    appendUniqueBucket(buckets, firstEntry and firstEntry.bucket, bucketSeen)
    appendUniqueBucket(buckets, secondEntry and secondEntry.bucket, bucketSeen)

    local candidate = {
        actions = sequence,
        signature = signature,
        source = "full_turn",
        buckets = buckets,
        cheapScore = num(firstEntry and firstEntry.cheapScore, 0) + num(secondEntry and secondEntry.cheapScore, 0),
        tacticalTags = {},
        containsDeploy = false,
        containsAttack = false,
        completeTurn = options.completeTurn == true,
        terminal = options.terminal == true,
        legalSkipReason = options.legalSkipReason
    }

    if firstEntry and type(firstEntry.tags) == "table" then
        for key, value in pairs(firstEntry.tags) do
            candidate.tacticalTags[key] = value
        end
    end
    if secondEntry and type(secondEntry.tags) == "table" then
        for key, value in pairs(secondEntry.tags) do
            candidate.tacticalTags[key] = value
        end
    end

    for _, action in ipairs(sequence) do
        if action and action.type == "supply_deploy" then
            candidate.containsDeploy = true
        elseif action and action.type == "attack" then
            candidate.containsAttack = true
        end
    end

    if options.prefixOnly == true then
        return candidate
    end

    seen[signature] = true
    result[#result + 1] = candidate
    if maxCandidates and #result > maxCandidates then
        result[#result] = nil
    end
    return candidate
end

local function isTerminalState(ai, state, playerId, ctx)
    if not state or not playerId then
        return false
    end

    local enemyPlayer = ai:getOpponentPlayer(playerId)
    if ctx and ctx.evaluator and ctx.evaluator.isCommandantDead then
        if ctx.evaluator.isCommandantDead(state, enemyPlayer) then
            return true, "terminal_win"
        end
        if ctx.evaluator.isCommandantDead(state, playerId) then
            return true, "terminal_loss"
        end
    end

    return false, nil
end

function M.addTerminalOrNoContinuationCandidate(result, seen, ai, stateAfterPrefix, playerId, ctx, prefixActions, firstEntry, maxCandidates, opts)
    if ctx and ctx.shouldStop and ctx.shouldStop() then
        return nil
    end

    local options = opts or {}
    local terminal, reason = isTerminalState(ai, stateAfterPrefix, playerId, ctx)
    if terminal then
        return M.addCandidate(result, seen, prefixActions, firstEntry, nil, maxCandidates, {
            completeTurn = true,
            terminal = true,
            legalSkipReason = reason
        })
    end

    local hasExecutableContinuation = options.hasExecutableContinuation
    if hasExecutableContinuation == nil then
        local continuations = M.collectTournamentActions(ai, stateAfterPrefix, playerId, ctx, {
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true
        })
        hasExecutableContinuation = #continuations > 0
    end

    if not hasExecutableContinuation then
        return M.addCandidate(result, seen, prefixActions, firstEntry, nil, maxCandidates, {
            completeTurn = true,
            terminal = false,
            legalSkipReason = "no_legal_continuation"
        })
    end

    return nil
end

local function legalActionCount(ai)
    local turnCfg = (((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).TURN or {}
    local maxActions = num(turnCfg.ACTIONS_PER_TURN, nil)
    if maxActions and maxActions > 0 then
        return maxActions
    end
    return 2
end

local function guaranteedFallbackEnabled(ctx, options)
    if options and options.allowGuaranteedFallback ~= nil then
        return options.allowGuaranteedFallback == true
    end
    return ctx and ctx.cfg and ctx.cfg.FULL_TURN_GUARANTEED_FALLBACK_ENABLED == true
end

local function buildGuaranteedFallbackCandidate(ai, state, playerId, ctx, opts)
    if not ai or not state or not playerId or not ai.getMandatoryFallbackCandidates then
        return nil
    end

    local options = opts or {}
    local maxActions = options.maxActions or legalActionCount(ai)
    local allowHealerRepairException = options.allowFullHpHealerRepairException
    if allowHealerRepairException == nil then
        local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
        allowHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
    end

    local legalEntries = collectLegal(ai, state, playerId, ctx, {
        includeMove = true,
        includeAttack = true,
        includeRepair = true,
        includeDeploy = true,
        allowFullHpHealerRepairException = allowHealerRepairException == true,
        avoidMoveAttackExposure = options.avoidMoveAttackExposure == true
    }) or {}

    if #legalEntries == 0 then
        return nil
    end

    local function fallbackOpts()
        return {
            aiPlayer = playerId,
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true,
            allowFullHpHealerRepairException = allowHealerRepairException == true,
            avoidMoveAttackExposure = options.avoidMoveAttackExposure == true
        }
    end

    local function simulate(actionState, action)
        if not (actionState and action and action.type and action.type ~= "skip") then
            return actionState
        end
        if ctx and ctx.cache and ctx.cache.simulate then
            return ctx.cache.simulate(ai, actionState, {action}, playerId, ctx)
        end
        if ai.simulateActionSequenceForPlayer then
            return ai:simulateActionSequenceForPlayer(actionState, {action}, playerId, {})
        end
        return nil
    end

    local proposed = {}
    local currentState = state
    local deployUsed = false
    for _ = 1, maxActions do
        local fallbackEntries = ai:getMandatoryFallbackCandidates(currentState, fallbackOpts()) or {}
        local selected = nil
        for _, entry in ipairs(fallbackEntries) do
            local action = entry and (entry.action or entry) or nil
            if action
                and action.type
                and action.type ~= "skip"
                and not (deployUsed and action.type == "supply_deploy") then
                selected = action
                break
            end
        end

        if not selected then
            break
        end

        proposed[#proposed + 1] = selected
        if selected.type == "supply_deploy" then
            deployUsed = true
        end

        currentState = simulate(currentState, selected)
        if not currentState then
            break
        end
    end

    local sanitized, sanitizeSummary = ai:sanitizeActionSequenceForState(state, proposed, {
        aiPlayer = playerId,
        maxActions = maxActions,
        allowFullHpHealerRepairException = allowHealerRepairException == true,
        rejectZeroDamageFactionAttacks = true
    })

    if not sanitized or #sanitized == 0 then
        return nil
    end

    local containsDeploy = false
    local containsAttack = false
    for _, action in ipairs(sanitized) do
        if action and action.type == "supply_deploy" then
            containsDeploy = true
        elseif action and action.type == "attack" then
            containsAttack = true
        end
    end

    return {
        actions = sanitized,
        signature = M.sequenceSignature(sanitized),
        source = "full_turn_guaranteed_fallback",
        buckets = {"fallback"},
        cheapScore = 0,
        tacticalTags = {},
        containsDeploy = containsDeploy,
        containsAttack = containsAttack,
        completeTurn = true,
        terminal = false,
        legalSkipReason = nil,
        sanitizeSummary = sanitizeSummary
    }
end

function M.generateFullTurnCandidates(ai, state, playerId, ctx, opts)
    local options = opts or {}
    local maxFirst = options.maxFirstActions or (ctx and ctx.cfg and ctx.cfg.MAX_FIRST_ACTIONS) or 72
    local maxSecond = options.maxSecondActions or (ctx and ctx.cfg and ctx.cfg.MAX_SECOND_ACTIONS) or 36
    local maxCandidates = options.maxCandidates or (ctx and ctx.cfg and ctx.cfg.MAX_OWN_CANDIDATES) or 320
    local replyMode = options.mode == "enemy_adversarial"
    local productiveEnumeration = earlyProductiveEnumerationEnabled(ctx, playerId, replyMode, options)
    local diagnosticsEnabled = earlyDiagnosticsEnabled(ctx, playerId, replyMode)
        and options.diagnosticLabel ~= nil
    local minSecondContinuations = options.minSecondContinuationsAfterRank
        or (ctx and ctx.cfg and ctx.cfg.MIN_SECOND_CONTINUATIONS_AFTER_RANK)
        or (replyMode and 1 or 4)
    minSecondContinuations = math.max(1, math.min(maxSecond, num(minSecondContinuations, replyMode and 1 or 4)))

    local result = {}
    local seen = {}

    local function recordDiagnosticsComplete()
        if diagnosticsEnabled and ctx and ctx.stats then
            ctx.stats.earlyDiagFullCandidatesReturned = #result
        end
    end

    if diagnosticsEnabled then
        ctx.stats.earlyDiagnosticsEnabled = true
        ctx.stats.earlyDiagSource = tostring(options.diagnosticLabel or "normal")
        ctx.stats.earlyDiagFirstBeamCap = maxFirst
        ctx.stats.earlyDiagSecondBeamCap = maxSecond
        ctx.stats.earlyDiagCandidateCap = maxCandidates
        ctx.stats.earlyDiagFirstRankMode = productiveEnumeration and "productive_shortlist" or "bucket_rank"
    end

    local rawFirstActions = M.collectTournamentActions(ai, state, playerId, ctx, options)
    if diagnosticsEnabled then
        ctx.stats.earlyDiagFirstLegalActions = #rawFirstActions
    end
    local firstActions = nil
    local productivePrepared = nil
    if productiveEnumeration then
        local cheapShortlist = nil
        cheapShortlist, productivePrepared = selectProductiveFirstActions(rawFirstActions, maxFirst, state, ai, ctx)
        firstActions = candidateBuckets.rankAndSelect(ai, state, cheapShortlist, playerId, ctx, {
            maxTotal = maxFirst,
            scanLimit = #cheapShortlist,
            mode = options.mode,
            stage = "first"
        })
        if ctx and ctx.stats then
            ctx.stats.earlyProductiveEnumerationEnabled = true
            ctx.stats.earlyProductiveFirstPrepared = productivePrepared or #firstActions
            ctx.stats.earlyProductiveFirstShortlisted = #cheapShortlist
            ctx.stats.earlyProductiveFirstSelected = #firstActions
        end
    else
        firstActions = candidateBuckets.rankAndSelect(ai, state, rawFirstActions, playerId, ctx, {
            maxTotal = maxFirst,
            scanLimit = options.firstActionScanLimit or math.max(maxFirst * 2, maxFirst + 12),
            mode = options.mode,
            stage = "first"
        })
    end
    if ctx and ctx.stats then
        ctx.stats.firstActionPool = #firstActions
        if diagnosticsEnabled then
            ctx.stats.earlyDiagFirstBeamSelected = #firstActions
        end
        if replyMode then
            ctx.stats.enemyReplyBatches = (ctx.stats.enemyReplyBatches or 0) + 1
            ctx.stats.enemyReplyFirstActionPoolTotal =
                (ctx.stats.enemyReplyFirstActionPoolTotal or 0) + #firstActions
            ctx.stats.enemyReplyFirstActionPoolMax =
                math.max(ctx.stats.enemyReplyFirstActionPoolMax or 0, #firstActions)
        end
    end

    for _, first in ipairs(firstActions) do
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end

        local a1 = first.action
        local s1 = first.stateAfter
            or ctx and ctx.cache and ctx.cache.simulate
            and ctx.cache.simulate(ai, state, {a1}, playerId, ctx)
            or ai:simulateActionSequenceForPlayer(state, {a1}, playerId, {})

        if s1 then
            M.addCandidate(result, seen, {a1}, first, nil, maxCandidates, {
                prefixOnly = true,
                stateAfter = s1
            })

            local requiredActions = legalActionCount(ai)
            if requiredActions > 1 then
                local rawSecondActions = M.collectTournamentActions(ai, s1, playerId, ctx, options)
                if diagnosticsEnabled then
                    ctx.stats.earlyDiagSecondStates = (ctx.stats.earlyDiagSecondStates or 0) + 1
                    ctx.stats.earlyDiagSecondLegalActionsTotal =
                        (ctx.stats.earlyDiagSecondLegalActionsTotal or 0) + #rawSecondActions
                    ctx.stats.earlyDiagSecondLegalActionsMax =
                        math.max(ctx.stats.earlyDiagSecondLegalActionsMax or 0, #rawSecondActions)
                end
                local secondActions = candidateBuckets.rankAndSelect(ai, s1, rawSecondActions, playerId, ctx, {
                    maxTotal = maxSecond,
                    scanLimit = options.secondActionScanLimit or math.max(maxSecond * 2, maxSecond + 8),
                    mode = options.mode,
                    stage = "second",
                    minPreparedBeforeStop = minSecondContinuations
                })
                if ctx and ctx.stats then
                    if diagnosticsEnabled then
                        ctx.stats.earlyDiagSecondBeamSelectedTotal =
                            (ctx.stats.earlyDiagSecondBeamSelectedTotal or 0) + #secondActions
                        ctx.stats.earlyDiagSecondBeamSelectedMax =
                            math.max(ctx.stats.earlyDiagSecondBeamSelectedMax or 0, #secondActions)
                    end
                    if replyMode then
                        ctx.stats.enemyReplySecondActionStates =
                            (ctx.stats.enemyReplySecondActionStates or 0) + 1
                        ctx.stats.enemyReplySecondActionPoolTotal =
                            (ctx.stats.enemyReplySecondActionPoolTotal or 0) + #secondActions
                        ctx.stats.enemyReplySecondActionPoolMax =
                            math.max(ctx.stats.enemyReplySecondActionPoolMax or 0, #secondActions)
                    end
                end
                local addedExecutableContinuation = false

                for secondIndex, second in ipairs(secondActions) do
                    if secondIndex > minSecondContinuations and ctx and ctx.shouldStop and ctx.shouldStop() then
                        break
                    end

                    local a2 = second.action
                    if a2 and not (a1.type == "supply_deploy" and a2.type == "supply_deploy") then
                        local fullSim = ctx and ctx.cache and ctx.cache.simulate
                            and ctx.cache.simulate(ai, state, {a1, a2}, playerId, ctx)
                            or ai:simulateActionSequenceForPlayer(state, {a1, a2}, playerId, {})
                        if fullSim then
                            M.addCandidate(result, seen, {a1, a2}, first, second, maxCandidates, {
                                completeTurn = true,
                                terminal = false
                            })
                            addedExecutableContinuation = true
                        end
                        if #result >= maxCandidates then
                            recordDiagnosticsComplete()
                            return result
                        end
                    end
                end

                M.addTerminalOrNoContinuationCandidate(result, seen, ai, s1, playerId, ctx, {a1}, first, maxCandidates, {
                    hasExecutableContinuation = addedExecutableContinuation
                })
            else
                M.addTerminalOrNoContinuationCandidate(result, seen, ai, s1, playerId, ctx, {a1}, first, maxCandidates, {
                    hasExecutableContinuation = false
                })
            end
        end

        if ctx and ctx.shouldStop and ctx.shouldStop() then
            break
        end
    end

    if diagnosticsEnabled and ctx and ctx.stats then
        ctx.stats.earlyDiagFullCandidatesGeneratedBeforeFallback = #result
    end

    if #result == 0 and guaranteedFallbackEnabled(ctx, options) then
        local guaranteed = buildGuaranteedFallbackCandidate(ai, state, playerId, ctx, {
            maxActions = legalActionCount(ai),
            allowFullHpHealerRepairException = options.allowFullHpHealerRepairException,
            avoidMoveAttackExposure = options.avoidMoveAttackExposure == true
        })
        if guaranteed then
            if ctx and ctx.stats then
                ctx.stats.guaranteedFallbackCandidate = true
                ctx.stats.guaranteedFallbackSanitizerReplacements =
                    (guaranteed.sanitizeSummary and guaranteed.sanitizeSummary.replacements) or 0
            end
            result[#result + 1] = guaranteed
        end
    end

    recordDiagnosticsComplete()
    return result
end

return M
