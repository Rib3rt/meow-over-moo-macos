local turnEnumerator = require("ai_tournament.turn_enumerator")
local repairHeuristics = require("ai_tournament.repair_heuristics")

local M = {}

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
    if n > maxValue then
        return maxValue
    end
    return n
end

local function copyAction(action)
    local out = {}
    for key, value in pairs(action or {}) do
        if type(value) == "table" then
            local child = {}
            for childKey, childValue in pairs(value) do
                child[childKey] = childValue
            end
            out[key] = child
        else
            out[key] = value
        end
    end
    return out
end

local function copyArray(values)
    local out = {}
    for index = 1, #(values or {}) do
        out[index] = copyAction(values[index])
    end
    return out
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

local function bumpReason(map, reason)
    if not map then
        return
    end
    local key = tostring(reason or "unknown")
    map[key] = num(map[key], 0) + 1
end

local function cellKey(row, col)
    if type(row) == "table" then
        col = row.col
        row = row.row
    end
    return tostring(num(row, 0)) .. "," .. tostring(num(col, 0))
end

local function actionSignature(ctx, action)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.actionSignature then
        return ctx.turnEnumerator.actionSignature(action)
    end
    return turnEnumerator.actionSignature(action)
end

local function sequenceSignature(ctx, actions)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.sequenceSignature then
        return ctx.turnEnumerator.sequenceSignature(actions)
    end
    return turnEnumerator.sequenceSignature(actions)
end

local function normalizeEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    if entry.action then
        return entry
    end
    if entry.type then
        return {
            action = entry,
            signature = actionSignature(nil, entry),
            cheapScore = num(entry.cheapScore, 0)
        }
    end
    return nil
end

local function collectContinuationEntries(ai, afterPrefix, ctx)
    local playerId = ctx and ctx.aiPlayer or afterPrefix and afterPrefix.currentPlayer or 1
    local raw = {}
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        raw = ctx.turnEnumerator.collectTournamentActions(ai, afterPrefix, playerId, ctx, {
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true
        }) or {}
    elseif ai and ai.collectLegalActions then
        raw = ai:collectLegalActions(afterPrefix, {
            aiPlayer = playerId,
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true
        }) or {}
    else
        raw = turnEnumerator.collectTournamentActions(ai, afterPrefix, playerId, ctx, {
            includeMove = true,
            includeAttack = true,
            includeRepair = true,
            includeDeploy = true
        }) or {}
    end

    local entries = {}
    local skipEntries = {}
    for _, rawEntry in ipairs(raw) do
        local entry = normalizeEntry(rawEntry)
        if entry and entry.action and entry.action.type then
            if entry.action.type == "skip" then
                skipEntries[#skipEntries + 1] = entry
            else
                entries[#entries + 1] = entry
            end
        end
    end
    if #entries == 0 then
        return skipEntries
    end
    return entries
end

local function cellScore(ctx, midMap, action)
    local target = action and action.target
    if not target then
        return 0
    end
    local key = cellKey(target)
    local personalityCell = ctx
        and ctx.midPersonality
        and ctx.midPersonality.byKey
        and ctx.midPersonality.byKey[key]
        or nil
    local mapCell = midMap and midMap.byKey and midMap.byKey[key] or nil
    return num(personalityCell and personalityCell.value, 0) + num(mapCell and mapCell.value, 0) * 0.25
end

local function deployRoleScore(action)
    local name = tostring(action and (action.unitName or action.unitType) or "")
    if name == "Cloudstriker" or name == "Artillery" then
        return 90
    end
    if name == "Crusher" or name == "Earthstalker" then
        return 70
    end
    if name == "Wingstalker" then
        return 55
    end
    if name == "Bastion" then
        return 40
    end
    if name == "Healer" then
        return 30
    end
    return 0
end

local function fullHpRepairSecondPenalty(ai, beforeSecondState, ctx, action)
    if action and action.type == "repair" and repairHeuristics.isFullHpRepair(ai, beforeSecondState, action) then
        return repairHeuristics.fullHpRepairSecondActionPenalty(ctx)
    end
    return 0
end

local function secondActionScore(ai, beforeSecondState, ctx, midMap, entry, fullTrade)
    local action = entry and entry.action or nil
    local actionType = action and action.type or "unknown"
    local base = num(entry and entry.cheapScore, 0)
    local fullHpPenalty = fullHpRepairSecondPenalty(ai, beforeSecondState, ctx, action)
    if actionType == "attack" then
        if not (fullTrade and fullTrade.accepted == true) then
            return -math.huge
        end
        return base + num(fullTrade.score, 0) + 240 - fullHpPenalty
    end
    if actionType == "supply_deploy" then
        return base + cellScore(ctx, midMap, action) + deployRoleScore(action) + 150 - fullHpPenalty
    end
    if actionType == "move" then
        return base + cellScore(ctx, midMap, action) + 90 - fullHpPenalty
    end
    if actionType == "repair" then
        return base + cellScore(ctx, midMap, action) + 130 - fullHpPenalty
    end
    return base + cellScore(ctx, midMap, action) - fullHpPenalty
end

local function fallbackTradeForPrefix(prefix, rejectedTrade, afterState)
    local trade = clone(prefix and prefix.midTrade or nil)
    if not (trade and trade.accepted == true) then
        return nil
    end
    trade.afterState = afterState
    trade.secondActionFallback = true
    trade.secondActionFallbackRejectReason = rejectedTrade and rejectedTrade.reason or nil
    return trade
end

local function prefixRecoveryEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_ENABLED == false)
end

local function appendPrefixRecovery(ai, state, ctx, midMap, prefix, entries, fallbackPrepared, scanCap)
    if not (prefixRecoveryEnabled(ctx) and prefix and prefix.midTrade and prefix.midTrade.accepted == true) then
        return 0
    end
    if not (entries and #entries > 0 and fallbackPrepared) then
        return 0
    end

    local stats = ctx and ctx.stats or nil
    local recoveryScanCap = clampLimit(
        ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_SCAN_CAP or scanCap or 6,
        1,
        60
    )
    recoveryScanCap = math.min(recoveryScanCap, #entries)
    local penalty = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_PENALTY, 420)
    local attackPenalty = num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_PREFIX_RECOVERY_ATTACK_PENALTY, 1200)
    local added = 0
    local scanned = 0

    for index = 1, recoveryScanCap do
        local entry = entries[index]
        scanned = scanned + 1
        if entry and entry.action then
            local actions = copyArray(prefix.actions)
            actions[#actions + 1] = copyAction(entry.action)
            local afterState = ctx
                and ctx.cache
                and ctx.cache.simulate
                and ctx.cache.simulate(ai, state, actions, ctx.aiPlayer, ctx)
                or nil
            local recoveryTrade = fallbackTradeForPrefix(prefix, {
                reason = "prefix_recovery"
            }, afterState)
            if recoveryTrade and afterState then
                local beforeSecondState = prefix._midAfterState or state
                local score = secondActionScore(ai, beforeSecondState, ctx, midMap, entry, recoveryTrade) - penalty
                if entry.action.type == "attack" then
                    score = score - attackPenalty
                end
                fallbackPrepared[#fallbackPrepared + 1] = {
                    entry = entry,
                    trade = recoveryTrade,
                    score = score,
                    fallback = true,
                    recovery = true
                }
                added = added + 1
            end
        end
    end

    if stats then
        stats.pipelineV2MidSecondPrefixRecoveryScanned =
            num(stats.pipelineV2MidSecondPrefixRecoveryScanned, 0) + scanned
        stats.pipelineV2MidSecondPrefixRecoveryCompletions =
            num(stats.pipelineV2MidSecondPrefixRecoveryCompletions, 0) + added
        if added > 0 then
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, "using_prefix_trade_for_second_recovery")
        end
    end

    return added
end

local function annotateCandidate(ctx, prefix, secondEntry, trade, score)
    local actions = copyArray(prefix.actions or {})
    actions[#actions + 1] = copyAction(secondEntry.action)
    local secondType = secondEntry.action and secondEntry.action.type or "unknown"
    local candidate = {
        actions = actions,
        signature = sequenceSignature(ctx, actions),
        source = prefix.source or "mid_v2_attack",
        buckets = prefix.buckets or {"mid_attack"},
        cheapScore = num(prefix.cheapScore, 0) + num(score, 0),
        tacticalTags = {},
        containsDeploy = prefix.containsDeploy == true or secondType == "supply_deploy",
        containsAttack = true,
        completeTurn = true,
        terminal = false,
        legalSkipReason = nil,
        midTrade = trade,
        hasFactionAttack = num(trade and trade.factionAttackCount, 0) > 0 or prefix.hasFactionAttack == true,
        combatValue = {
            damage = num(trade and trade.totalDamage, 0),
            kills = num(trade and trade.kills, 0),
            commandantDamage = num(trade and trade.commandantDamage, 0)
        },
        midSecondReason = "mid_second_" .. tostring(secondType)
    }
    for key, value in pairs(prefix.tacticalTags or {}) do
        candidate.tacticalTags[key] = value
    end
    candidate.tacticalTags.midSecondAction = secondType
    return candidate
end

function M.complete(ai, state, ctx, midMap, tradeModel, prefix, options)
    options = options or {}
    local stats = ctx and ctx.stats or nil
    if stats then
        stats.pipelineV2MidSecondPrefixes = num(stats.pipelineV2MidSecondPrefixes, 0) + 1
        stats.pipelineV2MidSecondRejectedReasons = stats.pipelineV2MidSecondRejectedReasons or {}
    end

    if not (ai and state and ctx and tradeModel and prefix and prefix.actions and #prefix.actions > 0) then
        if stats then
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, "missing_prefix")
        end
        return {}
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_ACTION_ENABLED == false then
        if stats then
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, "disabled")
        end
        return {}
    end

    local afterPrefix = prefix._midAfterState
        or (ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, prefix.actions, ctx.aiPlayer, ctx))
        or nil
    if not afterPrefix then
        if stats then
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, "prefix_simulation_failed")
        end
        return {}
    end

    local entries = collectContinuationEntries(ai, afterPrefix, ctx)
    if stats then
        stats.pipelineV2MidSecondLegalActions = num(stats.pipelineV2MidSecondLegalActions, 0) + #entries
    end
    if #entries == 0 then
        if stats then
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, "no_second_action")
        end
        return {}
    end

    local scanCap = clampLimit(
        options.scanCap or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_SCAN_CAP) or 12,
        1,
        60
    )
    local maxCompletions = clampLimit(
        options.maxCompletions or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_SECOND_COMPLETION_CAP) or 3,
        1,
        12
    )

    local prepared = {}
    local fallbackPrepared = {}
    local scanned = 0
    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        if ctx.shouldStop and ctx.shouldStop() then
            if stats then
                stats.pipelineV2MidSecondStopped = true
            end
            break
        end
        scanned = scanned + 1

        local actions = copyArray(prefix.actions)
        actions[#actions + 1] = copyAction(entry.action)
        local trade = tradeModel.evaluateAttack(ai, state, ctx, {
            actions = actions
        }, {
            profile = ctx.midPersonality and ctx.midPersonality.profile or nil,
            includeAfterState = true
        })
        if stats then
            stats.pipelineV2MidSecondEvaluated = num(stats.pipelineV2MidSecondEvaluated, 0) + 1
        end

        if trade and trade.accepted == true then
            local score = secondActionScore(ai, afterPrefix, ctx, midMap, entry, trade)
            prepared[#prepared + 1] = {
                entry = entry,
                trade = trade,
                score = score
            }
        elseif stats then
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, trade and trade.reason or "trade_rejected")
        end
        if not (trade and trade.accepted == true)
            and prefix.midTrade
            and prefix.midTrade.accepted == true
            and entry
            and entry.action
            and entry.action.type ~= "attack" then
            local afterState = trade and trade.afterState
                or (ctx.cache and ctx.cache.simulate and ctx.cache.simulate(ai, state, actions, ctx.aiPlayer, ctx))
                or nil
            local fallbackTrade = fallbackTradeForPrefix(prefix, trade, afterState)
            if fallbackTrade and afterState then
                local score = secondActionScore(ai, afterPrefix, ctx, midMap, entry, fallbackTrade) - 220
                fallbackPrepared[#fallbackPrepared + 1] = {
                    entry = entry,
                    trade = fallbackTrade,
                    score = score,
                    fallback = true
                }
            end
        end
    end

    if #prepared == 0 and #fallbackPrepared > 0 then
        prepared = fallbackPrepared
        if stats then
            stats.pipelineV2MidSecondFallbackCompletions =
                num(stats.pipelineV2MidSecondFallbackCompletions, 0) + #fallbackPrepared
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, "using_prefix_trade_for_second_fallback")
        end
    end
    if #prepared == 0 and #fallbackPrepared == 0 then
        appendPrefixRecovery(ai, state, ctx, midMap, prefix, entries, fallbackPrepared, scanCap)
        if #fallbackPrepared > 0 then
            prepared = fallbackPrepared
        end
    end

    table.sort(prepared, function(a, b)
        if num(a and a.score, 0) == num(b and b.score, 0) then
            return tostring(a and a.entry and a.entry.signature or "") < tostring(b and b.entry and b.entry.signature or "")
        end
        return num(a and a.score, 0) > num(b and b.score, 0)
    end)

    local out = {}
    for index, item in ipairs(prepared) do
        if index > maxCompletions then
            break
        end
        local trade = item.trade
        local afterState = trade and trade.afterState or nil
        if trade then
            trade.afterState = nil
        end
        local candidate = annotateCandidate(ctx, prefix, item.entry, trade, item.score)
        candidate._midAfterState = afterState
        if item.fallback == true then
            candidate.midSecondReason = item.recovery == true
                and "mid_second_prefix_trade_recovery"
                or "mid_second_prefix_trade_fallback"
            candidate.tacticalTags = candidate.tacticalTags or {}
            candidate.tacticalTags.midSecondFallback = true
            candidate.tacticalTags.midSecondRecovery = item.recovery == true
            candidate.tacticalTags.midSecondFallbackRejectReason =
                trade and trade.secondActionFallbackRejectReason or nil
        end
        out[#out + 1] = candidate
    end

    if stats then
        stats.pipelineV2MidSecondScanned = num(stats.pipelineV2MidSecondScanned, 0) + scanned
        stats.pipelineV2MidSecondCompleted = num(stats.pipelineV2MidSecondCompleted, 0) + #out
        if #out == 0 then
            bumpReason(stats.pipelineV2MidSecondRejectedReasons, "no_accepted_completion")
        end
    end

    return out
end

return M
