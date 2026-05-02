local midPositionMap = require("ai_tournament.mid_position_map")
local midPersonality = require("ai_tournament.mid_personality")
local midTradeModel = require("ai_tournament.mid_trade_model")
local midAttackCandidates = require("ai_tournament.mid_attack_candidates")
local midPositionCandidates = require("ai_tournament.mid_position_candidates")
local midDeployCandidates = require("ai_tournament.mid_deploy_candidates")
local midScore = require("ai_tournament.mid_score")
local midGate = require("ai_tournament.pipeline_v2_mid_gate")
local actionExposureGuard = require("ai_tournament.action_exposure_guard")
local budgetScope = require("ai_tournament.pipeline_v2_budget_scope")
local softPressureScore = require("ai_tournament.pipeline_v2_soft_pressure_score")
local drawPressure = require("ai_tournament.draw_pressure")
local turnEnumerator = require("ai_tournament.turn_enumerator")

local M = {}

local function count(list)
    return type(list) == "table" and #list or 0
end

local function isEndgameRuntime(ctx)
    return ctx and ctx.pipelineV2EndRuntime == true
end

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

local function bumpReason(map, reason)
    local key = tostring(reason or "unknown")
    map[key] = num(map[key], 0) + 1
end

local function copyMap(map)
    local out = {}
    for key, value in pairs(map or {}) do
        out[key] = value
    end
    return out
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

local function copyActions(actions)
    local out = {}
    for index, action in ipairs(actions or {}) do
        out[index] = copyAction(action)
    end
    return out
end

local function cellKey(pos)
    if type(pos) ~= "table" then
        return nil
    end
    if pos.row == nil or pos.col == nil then
        return nil
    end
    return tostring(num(pos.row, 0)) .. "," .. tostring(num(pos.col, 0))
end

local function mergeReasonCounts(target, source, prefix)
    for reason, countValue in pairs(source or {}) do
        local key = tostring(reason or "unknown")
        if prefix and prefix ~= "" then
            key = prefix .. key
        end
        target[key] = num(target[key], 0) + num(countValue, 0)
    end
end

local function scoreTotal(score)
    if type(score) == "table" then
        return num(score.total, 0)
    end
    return num(score, 0)
end

local function sequenceSignature(ctx, actions)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.sequenceSignature then
        return ctx.turnEnumerator.sequenceSignature(actions)
    end
    return turnEnumerator.sequenceSignature(actions)
end

local function simulateActions(ai, state, ctx, actions)
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, actions, ctx.aiPlayer, ctx)
    end
    if ai and ai.simulateActionSequenceForPlayer then
        return ai:simulateActionSequenceForPlayer(state, actions, ctx and ctx.aiPlayer, {})
    end
    return nil
end

local function attachTrade(candidate, trade)
    if not (candidate and trade) then
        return
    end
    candidate._midAfterState = trade.afterState
    trade.afterState = nil
    candidate.midTrade = trade
    candidate.hasFactionAttack = num(trade.factionAttackCount, 0) > 0
    candidate.combatValue = {
        damage = num(trade.totalDamage, 0),
        kills = num(trade.kills, 0),
        commandantDamage = num(trade.commandantDamage, 0)
    }
    candidate.cheapScore = num(candidate.cheapScore, 0) + num(trade.score, 0)
    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.midTradeReason = trade.reason
    candidate.tacticalTags.midTradeClass = trade.class
    candidate.tacticalTags.drawZeroDamageReset = trade.drawZeroDamageReset == true or nil
    candidate.tacticalTags.winsNow = trade.class == "win_now"
end

local function containsSkipAction(candidate)
    for _, action in ipairs(candidate and candidate.actions or {}) do
        if action and action.type == "skip" then
            return true
        end
    end
    return false
end

local function exactSanitizerOk(ai, state, ctx, candidate, rejectedReasons)
    if not (ai and ai.sanitizeActionSequenceForState and state and candidate and candidate.actions) then
        return true
    end

    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local allowZeroDamageDrawReset = candidate.midTrade
        and candidate.midTrade.drawZeroDamageReset == true
        and candidate.midTrade.officialDrawResetCandidate == true
    local allowRejectedLegalFloorAttack = candidate.tacticalTags
        and candidate.tacticalTags.midLegalFloorRejectedAttackKept == true
    local ok, sanitized, summary = pcall(function()
        local sanitizedActions, sanitizeSummary = ai:sanitizeActionSequenceForState(state, candidate.actions, {
            aiPlayer = ctx and ctx.aiPlayer,
            maxActions = math.max(1, num(ctx and ctx.maxActions, 2)),
            allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true,
            rejectZeroDamageFactionAttacks = not (allowZeroDamageDrawReset or allowRejectedLegalFloorAttack)
        })
        return sanitizedActions, sanitizeSummary
    end)
    if not ok then
        if ctx and ctx.stats then
            ctx.stats.pipelineV2MidExactSanitizerErrors = num(ctx.stats.pipelineV2MidExactSanitizerErrors, 0) + 1
        end
        bumpReason(rejectedReasons, "mid_exact_sanitize_error")
        return false
    end

    local replacements = num(summary and summary.replacements, 0)
    local sanitizedCount = type(sanitized) == "table" and #sanitized or 0
    if sanitizedCount <= 0 or replacements > 0 then
        local stats = ctx and ctx.stats or nil
        if stats then
            stats.pipelineV2MidExactSanitizerRejected =
                num(stats.pipelineV2MidExactSanitizerRejected, 0) + 1
            stats.pipelineV2MidExactSanitizerRejectedReasons =
                stats.pipelineV2MidExactSanitizerRejectedReasons or {}
            if summary and summary.reasonCounts then
                mergeReasonCounts(stats.pipelineV2MidExactSanitizerRejectedReasons, summary.reasonCounts)
                mergeReasonCounts(rejectedReasons, summary.reasonCounts, "mid_exact_sanitize_")
            else
                bumpReason(stats.pipelineV2MidExactSanitizerRejectedReasons, "empty_after_sanitize")
                bumpReason(rejectedReasons, "mid_exact_sanitize_empty")
            end
            stats.pipelineV2MidExactSanitizerLastRawSignature = candidate.signature
            stats.pipelineV2MidExactSanitizerLastSanitizedSignature =
                sanitizedCount > 0 and sequenceSignature(ctx, sanitized) or nil
        end
        return false
    end

    candidate.sanitizerOk = true
    candidate.allowsZeroDamageDrawReset = allowZeroDamageDrawReset == true
    candidate.allowsRejectedLegalFloorAttack = allowRejectedLegalFloorAttack == true
    candidate.sanitizeSummary = {
        replacements = replacements,
        reasonCounts = copyMap(summary and summary.reasonCounts or {})
    }
    return true
end

local function legalFloorEnabled(ctx)
    if ctx and ctx.pipelineV2EndRuntime == true and ctx.cfg and ctx.cfg.PIPELINE_V2_ENDGAME_LEGAL_FLOOR_ENABLED ~= nil then
        return ctx.cfg.PIPELINE_V2_ENDGAME_LEGAL_FLOOR_ENABLED == true
    end
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_ENABLED == false)
end

local function keepRejectedLegalFloorAttacks(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_KEEP_REJECTED_ATTACKS == false)
end

local function prepareLegalFloorCandidate(ai, state, ctx, midMap, candidate, reason)
    if not (candidate and candidate.actions and #candidate.actions > 0) then
        return nil
    end

    local mandatoryFloor = candidate.source == "mid_v2_mandatory_floor"
    candidate.source = mandatoryFloor and "mid_v2_mandatory_floor" or "mid_v2_legal_floor"
    candidate.buckets = candidate.buckets or {"legal_floor"}
    candidate.tacticalTags = candidate.tacticalTags or {}
    candidate.tacticalTags.midV2 = true
    candidate.tacticalTags.midLegalFloor = true
    candidate.tacticalTags.midMandatoryFloor = mandatoryFloor or nil
    candidate.tacticalTags.legalFloorReason = reason
    candidate.signature = candidate.signature or sequenceSignature(ctx, candidate.actions)

    local penalty = math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_PENALTY, 9000))
    if ctx and ctx.pipelineV2EndRuntime == true then
        penalty = math.max(0, num(ctx.cfg.PIPELINE_V2_ENDGAME_LEGAL_FLOOR_PENALTY, penalty))
    end
    if mandatoryFloor then
        penalty = math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MANDATORY_FLOOR_PENALTY, penalty))
    end
    if containsSkipAction(candidate) then
        penalty = penalty + math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_SKIP_PENALTY, 2500))
    end
    candidate.cheapScore = num(candidate.cheapScore, 0) - penalty

    local rejectedAttackReason = nil
    local rejectedAttackPenalty = 0
    if candidate.containsAttack == true then
        local trade = midTradeModel.evaluateAttack(ai, state, ctx, candidate, {
            profile = ctx and ctx.midPersonality and ctx.midPersonality.profile or nil,
            includeAfterState = true
        })
        if not (trade and trade.accepted == true) then
            rejectedAttackReason = trade and trade.reason or "mid_legal_floor_trade_rejected"
            if ctx and ctx.stats then
                ctx.stats.pipelineV2MidLegalFloorAttackRejected =
                    num(ctx.stats.pipelineV2MidLegalFloorAttackRejected, 0) + 1
                ctx.stats.pipelineV2MidLegalFloorAttackRejectedReasons =
                    ctx.stats.pipelineV2MidLegalFloorAttackRejectedReasons or {}
                bumpReason(
                    ctx.stats.pipelineV2MidLegalFloorAttackRejectedReasons,
                    rejectedAttackReason
                )
            end
            if not keepRejectedLegalFloorAttacks(ctx) then
                return nil
            end
            rejectedAttackPenalty =
                math.max(0, num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_REJECTED_ATTACK_PENALTY, 4500))
            candidate.containsAttack = false
            candidate.hasFactionAttack = false
            candidate.combatValue = {
                damage = 0,
                kills = 0,
                commandantDamage = 0
            }
            candidate.cheapScore = num(candidate.cheapScore, 0) - rejectedAttackPenalty
            candidate.tacticalTags.midLegalFloorRejectedAttack = rejectedAttackReason
            candidate.tacticalTags.midLegalFloorRejectedAttackKept = true
            if ctx and ctx.stats then
                ctx.stats.pipelineV2MidLegalFloorRejectedAttackKept =
                    num(ctx.stats.pipelineV2MidLegalFloorRejectedAttackKept, 0) + 1
            end
        else
            candidate.tacticalTags.midAttack = true
            attachTrade(candidate, trade)
            return candidate
        end
    end

    candidate.tacticalTags.midPosition = true
    candidate.midPosition = {
        accepted = true,
        class = "legal_floor",
        reason = "mid_legal_floor_" .. tostring(reason or "backup"),
        score = -penalty - rejectedAttackPenalty + (num(candidate.cheapScore, 0) * 0.10),
        targetKey = nil,
        targetValue = 0,
        pressureGain = 0,
        exposureDamage = 0,
        destinationExposureDamage = 0,
        destinationExposurePenalty = 0,
        destinationExposureLethal = false,
        covered = nil,
        intent = "legal_floor",
        riskBand = "floor",
        rejectedAttackReason = rejectedAttackReason,
        rejectedAttackPenalty = rejectedAttackPenalty
    }
    if midMap and midMap.top then
        candidate.midPosition.targetKey = midMap.top.key
        candidate.midPosition.targetValue = num(midMap.top.value, 0)
    end
    return candidate
end

local function mandatoryFloorEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MANDATORY_FLOOR_ENABLED == false)
end

local function normalizeEntry(ctx, entry)
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.normalizeEntry then
        return ctx.turnEnumerator.normalizeEntry(entry)
    end
    return turnEnumerator.normalizeEntry(entry)
end

local function collectMandatoryFloorEntries(ai, state, ctx, includeAttack)
    local actionCfg = ((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {})
    local raw = {}
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        raw = ctx.turnEnumerator.collectTournamentActions(ai, state, ctx.aiPlayer, ctx, {
            includeMove = true,
            includeAttack = includeAttack == true,
            includeRepair = true,
            includeDeploy = true,
            allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
        }) or {}
    else
        raw = turnEnumerator.collectTournamentActions(ai, state, ctx and ctx.aiPlayer, ctx, {
            includeMove = true,
            includeAttack = includeAttack == true,
            includeRepair = true,
            includeDeploy = true,
            allowFullHpHealerRepairException = actionCfg.HEALER_FULL_HP_REPAIR_EXCEPTION == true
        }) or {}
    end

    local entries = {}
    for _, rawEntry in ipairs(raw) do
        local entry = normalizeEntry(ctx, rawEntry)
        local action = entry and entry.action or nil
        if action and action.type and action.type ~= "skip" then
            entries[#entries + 1] = entry
        end
    end
    return entries, #raw
end

local function targetValue(ctx, midMap, action)
    local key = cellKey(action and action.target)
    if not key then
        return 0
    end
    local personalityCell = ctx
        and ctx.midPersonality
        and ctx.midPersonality.byKey
        and ctx.midPersonality.byKey[key]
        or nil
    local mapCell = midMap and midMap.byKey and midMap.byKey[key] or nil
    return num(personalityCell and personalityCell.value, mapCell and mapCell.value or 0), key
end

local function actionDistance(action)
    if not (action and action.unit and action.target) then
        return 0
    end
    return math.abs(num(action.unit.row, 0) - num(action.target.row, 0))
        + math.abs(num(action.unit.col, 0) - num(action.target.col, 0))
end

local function floorEntryScore(ctx, midMap, entry, stepIndex)
    local action = entry and entry.action or nil
    local actionType = action and action.type or "unknown"
    local value = targetValue(ctx, midMap, action)
    local score = num(entry and entry.cheapScore, 0) * 0.08 + value * 0.42
    if actionType == "move" then
        score = score + 160 - actionDistance(action) * 8
    elseif actionType == "supply_deploy" then
        score = score + 135
    elseif actionType == "repair" then
        score = score + 115
    elseif actionType == "attack" then
        score = score - 900
    end
    return score - num(stepIndex, 1) * 0.01
end

local function containsActionType(actions, actionType)
    for _, action in ipairs(actions or {}) do
        if action and action.type == actionType then
            return true
        end
    end
    return false
end

local function buildMandatoryCandidate(ctx, actions, firstEntry, secondEntry, afterState, midMap)
    local copied = copyActions(actions)
    local score = floorEntryScore(ctx, midMap, firstEntry, 1)
        + floorEntryScore(ctx, midMap, secondEntry, 2)
    return {
        actions = copied,
        signature = sequenceSignature(ctx, copied),
        source = "mid_v2_mandatory_floor",
        buckets = {"legal_floor", "mandatory_floor"},
        cheapScore = score,
        tacticalTags = {
            midV2 = true,
            midPosition = true,
            midMandatoryFloor = true
        },
        containsDeploy = containsActionType(copied, "supply_deploy"),
        containsAttack = containsActionType(copied, "attack"),
        completeTurn = true,
        terminal = false,
        legalSkipReason = nil,
        _midAfterState = afterState
    }
end

local function buildMandatoryFloorPass(ai, state, ctx, midMap, opts)
    local options = opts or {}
    local stats = ctx and ctx.stats or nil
    local cap = clampLimit(options.cap, 1, 48)
    local firstCap = clampLimit(options.firstCap, 1, 120)
    local secondCap = clampLimit(options.secondCap, 1, 80)
    local includeAttack = options.includeAttack == true
    local firstEntries, rawFirst = collectMandatoryFloorEntries(ai, state, ctx, includeAttack)
    if stats then
        stats.pipelineV2MidMandatoryFloorRawFirst =
            num(stats.pipelineV2MidMandatoryFloorRawFirst, 0) + num(rawFirst, 0)
        stats.pipelineV2MidMandatoryFloorFirstEntries =
            num(stats.pipelineV2MidMandatoryFloorFirstEntries, 0) + #firstEntries
    end

    table.sort(firstEntries, function(a, b)
        local av = floorEntryScore(ctx, midMap, a, 1)
        local bv = floorEntryScore(ctx, midMap, b, 1)
        if av == bv then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return av > bv
    end)

    local out = {}
    local seen = {}
    local firstScanned = 0
    local secondScanned = 0
    for _, firstEntry in ipairs(firstEntries) do
        if #out >= cap or firstScanned >= firstCap then
            break
        end
        if ctx and ctx.shouldStop and ctx.shouldStop() then
            if stats then
                stats.pipelineV2MidMandatoryFloorStopped = true
            end
            break
        end
        firstScanned = firstScanned + 1
        local firstAction = firstEntry and firstEntry.action and copyAction(firstEntry.action) or nil
        local afterFirst = firstAction and simulateActions(ai, state, ctx, {firstAction}) or nil
        if afterFirst then
            local secondEntries, rawSecond = collectMandatoryFloorEntries(ai, afterFirst, ctx, includeAttack)
            if stats then
                stats.pipelineV2MidMandatoryFloorRawSecond =
                    num(stats.pipelineV2MidMandatoryFloorRawSecond, 0) + num(rawSecond, 0)
                stats.pipelineV2MidMandatoryFloorSecondEntries =
                    num(stats.pipelineV2MidMandatoryFloorSecondEntries, 0) + #secondEntries
            end
            table.sort(secondEntries, function(a, b)
                local av = floorEntryScore(ctx, midMap, a, 2)
                local bv = floorEntryScore(ctx, midMap, b, 2)
                if av == bv then
                    return tostring(a and a.signature or "") < tostring(b and b.signature or "")
                end
                return av > bv
            end)

            local localSecondScanned = 0
            for _, secondEntry in ipairs(secondEntries) do
                if #out >= cap or localSecondScanned >= secondCap then
                    break
                end
                if ctx and ctx.shouldStop and ctx.shouldStop() then
                    if stats then
                        stats.pipelineV2MidMandatoryFloorStopped = true
                    end
                    break
                end
                localSecondScanned = localSecondScanned + 1
                secondScanned = secondScanned + 1
                local secondAction = secondEntry and secondEntry.action and copyAction(secondEntry.action) or nil
                if secondAction
                    and not (firstAction.type == "supply_deploy" and secondAction.type == "supply_deploy") then
                    local actions = {firstAction, secondAction}
                    local signature = sequenceSignature(ctx, actions)
                    if not seen[signature] then
                        local afterFull = simulateActions(ai, state, ctx, actions)
                        if afterFull then
                            seen[signature] = true
                            out[#out + 1] = buildMandatoryCandidate(
                                ctx,
                                actions,
                                firstEntry,
                                secondEntry,
                                afterFull,
                                midMap
                            )
                        end
                    end
                end
            end
        elseif stats then
            stats.pipelineV2MidMandatoryFloorFirstSimulationFailed =
                num(stats.pipelineV2MidMandatoryFloorFirstSimulationFailed, 0) + 1
        end
    end

    if stats then
        stats.pipelineV2MidMandatoryFloorFirstScanned =
            num(stats.pipelineV2MidMandatoryFloorFirstScanned, 0) + firstScanned
        stats.pipelineV2MidMandatoryFloorSecondScanned =
            num(stats.pipelineV2MidMandatoryFloorSecondScanned, 0) + secondScanned
    end
    return out
end

local function buildMandatoryFloorCandidates(ai, state, ctx, midMap, reason)
    local stats = ctx and ctx.stats or nil
    if not mandatoryFloorEnabled(ctx) then
        if stats then
            stats.pipelineV2MidMandatoryFloorSkippedReason = "disabled"
        end
        return {}
    end

    local cap = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MANDATORY_FLOOR_CANDIDATE_CAP or 6, 1, 48)
    local firstCap = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MANDATORY_FLOOR_FIRST_SCAN_CAP or 24, 1, 120)
    local secondCap = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MANDATORY_FLOOR_SECOND_SCAN_CAP or 16, 1, 80)
    local extraMs = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_MANDATORY_FLOOR_EXTRA_MS or 0, 0, 5000)
    local floorBudget = nil
    if extraMs > 0 then
        floorBudget = budgetScope.push(ctx, stats, {
            extraMs = extraMs,
            extraKey = "pipelineV2MidMandatoryFloorExtraMs",
            remainingKey = "pipelineV2MidRemainingBeforeMandatoryFloorMs",
            startKey = "pipelineV2MidMandatoryFloorStartElapsedMs",
            extendedKey = "pipelineV2MidMandatoryFloorExtendedHardBudgetMs",
            localWindowKey = "pipelineV2MidMandatoryFloorLocalWindowMs"
        })
    end

    local raw = buildMandatoryFloorPass(ai, state, ctx, midMap, {
        cap = cap,
        firstCap = firstCap,
        secondCap = secondCap,
        includeAttack = false
    })
    if #raw == 0 then
        raw = buildMandatoryFloorPass(ai, state, ctx, midMap, {
            cap = cap,
            firstCap = math.max(1, math.floor(firstCap / 2)),
            secondCap = math.max(1, math.floor(secondCap / 2)),
            includeAttack = true
        })
        if stats then
            stats.pipelineV2MidMandatoryFloorAttackPass = true
        end
    end

    if floorBudget then
        floorBudget.pop()
    end

    local prepared = {}
    for _, candidate in ipairs(raw) do
        local floor = prepareLegalFloorCandidate(ai, state, ctx, midMap, candidate, reason)
        if floor then
            prepared[#prepared + 1] = floor
        end
    end

    if stats then
        stats.pipelineV2MidMandatoryFloorGenerated = #raw
        stats.pipelineV2MidMandatoryFloorCandidates = #prepared
        stats.pipelineV2MidMandatoryFloorReason = reason
    end
    return prepared
end

local function buildLegalFloorCandidates(ai, state, ctx, midMap, reason)
    local stats = ctx and ctx.stats or nil
    if not legalFloorEnabled(ctx) then
        if stats then
            stats.pipelineV2MidLegalFloorSkippedReason = "disabled"
        end
        return {}
    end

    local cap = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_CANDIDATE_CAP or 12, 1, 48)
    local firstCap = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_FIRST_SCAN_CAP or 16, 1, 80)
    local secondCap = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_SECOND_SCAN_CAP or 8, 1, 48)
    local extraMs = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_LEGAL_FLOOR_EXTRA_MS or 0, 0, 5000)
    if ctx and ctx.pipelineV2EndRuntime == true then
        extraMs = clampLimit(ctx.cfg.PIPELINE_V2_ENDGAME_LEGAL_FLOOR_EXTRA_MS or extraMs, 0, 5000)
    end
    local floorBudget = nil
    if extraMs > 0 then
        floorBudget = budgetScope.push(ctx, stats, {
            extraMs = extraMs,
            extraKey = "pipelineV2MidLegalFloorExtraMs",
            remainingKey = "pipelineV2MidRemainingBeforeLegalFloorMs",
            startKey = "pipelineV2MidLegalFloorStartElapsedMs",
            extendedKey = "pipelineV2MidLegalFloorExtendedHardBudgetMs",
            localWindowKey = "pipelineV2MidLegalFloorLocalWindowMs"
        })
    end
    if ctx and ctx.shouldStop and ctx.shouldStop() then
        if stats then
            stats.pipelineV2MidLegalFloorSkippedReason = "budget"
        end
        if floorBudget then
            floorBudget.pop()
        end
        return {}
    end
    local raw = turnEnumerator.generateFullTurnCandidates(ai, state, ctx.aiPlayer, ctx, {
        maxCandidates = cap,
        maxFirstActions = firstCap,
        maxSecondActions = secondCap,
        firstActionScanLimit = math.max(firstCap * 2, firstCap + 8),
        secondActionScanLimit = math.max(secondCap * 2, secondCap + 6),
        minSecondContinuationsAfterRank = math.min(2, secondCap),
        allowGuaranteedFallback = false,
        allowFullHpHealerRepairException =
            (((((ai or {}).AI_PARAMS or {}).RULE_CONTRACT or {}).ACTIONS or {}).HEALER_FULL_HP_REPAIR_EXCEPTION == true)
    }) or {}
    if floorBudget then
        floorBudget.pop()
    end

    local prepared = {}
    for _, candidate in ipairs(raw) do
        local floor = prepareLegalFloorCandidate(ai, state, ctx, midMap, candidate, reason)
        if floor then
            prepared[#prepared + 1] = floor
        end
    end

    if #prepared == 0 then
        local mandatory = buildMandatoryFloorCandidates(ai, state, ctx, midMap, reason)
        for _, candidate in ipairs(mandatory or {}) do
            prepared[#prepared + 1] = candidate
        end
    end

    if stats then
        stats.pipelineV2MidLegalFloorGenerated = #raw
        stats.pipelineV2MidLegalFloorCandidates = #prepared
        stats.pipelineV2MidLegalFloorReason = reason
    end
    return prepared
end

local function sortByScore(ctx, items)
    table.sort(items, function(a, b)
        if ctx and ctx.score and ctx.score.isBetter then
            return ctx.score.isBetter(a and a.finalScore, b and b.finalScore)
        end
        local av = scoreTotal(a and a.finalScore)
        local bv = scoreTotal(b and b.finalScore)
        if av == bv then
            return tostring(a and a.candidate and a.candidate.signature or "")
                < tostring(b and b.candidate and b.candidate.signature or "")
        end
        return av > bv
    end)
end

local function candidateHasOfficialDrawReset(item)
    local candidate = item and item.candidate or nil
    local trade = candidate and candidate.midTrade or item and item.midTrade or nil
    return candidate
        and candidate.containsAttack == true
        and trade
        and trade.accepted == true
        and num(trade.factionAttackCount, 0) > 0
end

local function candidateHasInteraction(item)
    local candidate = item and item.candidate or nil
    local trade = candidate and candidate.midTrade or item and item.midTrade or nil
    return candidateHasOfficialDrawReset(item)
        and num(trade.totalDamage, 0) > 0
end

local function candidateHasMeaningfulInteraction(item)
    local candidate = item and item.candidate or nil
    local trade = candidate and candidate.midTrade or item and item.midTrade or nil
    return candidateHasInteraction(item)
        and not (trade and trade.drawSuicideChip == true)
end

local function applyDrawPressureSelection(ai, state, ctx, accepted, best)
    local draw = drawPressure.build(ai, state, ctx)
    local stats = ctx and ctx.stats or nil
    if stats then
        stats.pipelineV2MidDrawPressureActive = draw and draw.active == true
        stats.pipelineV2MidDrawPressureWindow = draw and draw.pressureLimit == true
        stats.pipelineV2MidDrawPressureNearLimit = draw and draw.nearLimit == true
        stats.pipelineV2MidDrawPressureCriticalLimit = draw and draw.criticalLimit == true
        stats.pipelineV2MidDrawPressureStreak = draw and draw.streak or nil
        stats.pipelineV2MidDrawNoInteractionLimit = draw and draw.noInteractionLimit or nil
        stats.pipelineV2MidDrawPressureUrgency = draw and draw.urgency or nil
        stats.pipelineV2MidDrawPressureUrgencyMax = draw and draw.urgencyMax or nil
        stats.pipelineV2MidDrawPressureRemaining = draw and draw.remainingBeforeLimit or nil
    end
    if not (draw and draw.active == true and draw.pressureLimit == true) then
        return best
    end
    if candidateHasMeaningfulInteraction(best)
        or (draw.criticalLimit == true and candidateHasOfficialDrawReset(best)) then
        return best
    end

    local bestInteraction = nil
    for _, item in ipairs(accepted or {}) do
        if candidateHasMeaningfulInteraction(item)
            and (
                not bestInteraction
                or (ctx and ctx.score and ctx.score.isBetter
                    and ctx.score.isBetter(item.finalScore, bestInteraction.finalScore))
                or (not (ctx and ctx.score and ctx.score.isBetter)
                    and scoreTotal(item.finalScore) > scoreTotal(bestInteraction.finalScore))
            ) then
            bestInteraction = item
        end
    end

    if bestInteraction then
        if stats then
            stats.pipelineV2MidDrawPressureForcedInteraction = true
            if draw.criticalLimit == true then
                stats.pipelineV2MidDrawPressureForcedReason = "draw_clock_critical_minus_1"
            elseif draw.nearLimit == true then
                stats.pipelineV2MidDrawPressureForcedReason = "draw_clock_near_minus_2"
            else
                stats.pipelineV2MidDrawPressureForcedReason = "draw_clock_pressure_minus_" .. tostring(draw.remainingBeforeLimit or 0)
            end
            stats.pipelineV2MidDrawPressureOriginalSignature =
                best and best.candidate and best.candidate.signature or nil
            stats.pipelineV2MidDrawPressureForcedSignature =
                bestInteraction.candidate and bestInteraction.candidate.signature or nil
        end
        bestInteraction.acceptReason = bestInteraction.acceptReason or "mid_draw_clock_interaction"
        bestInteraction.finalAcceptReason = draw.criticalLimit == true
            and "mid_draw_clock_critical_interaction"
            or (draw.nearLimit == true and "mid_draw_clock_near_interaction" or "mid_draw_clock_pressure_interaction")
        return bestInteraction
    end

    if draw.criticalLimit == true then
        for _, item in ipairs(accepted or {}) do
            if candidateHasOfficialDrawReset(item)
                and (
                    not bestInteraction
                    or (ctx and ctx.score and ctx.score.isBetter
                        and ctx.score.isBetter(item.finalScore, bestInteraction.finalScore))
                    or (not (ctx and ctx.score and ctx.score.isBetter)
                        and scoreTotal(item.finalScore) > scoreTotal(bestInteraction.finalScore))
                ) then
                bestInteraction = item
            end
        end
        if bestInteraction then
            if stats then
                stats.pipelineV2MidDrawPressureForcedWeakInteraction = true
                stats.pipelineV2MidDrawPressureForcedReason = "draw_clock_critical_official_reset"
                stats.pipelineV2MidDrawPressureOriginalSignature =
                    best and best.candidate and best.candidate.signature or nil
                stats.pipelineV2MidDrawPressureForcedSignature =
                    bestInteraction.candidate and bestInteraction.candidate.signature or nil
            end
            bestInteraction.acceptReason = bestInteraction.acceptReason or "mid_draw_clock_critical_official_reset"
            bestInteraction.finalAcceptReason = "mid_draw_clock_critical_official_reset"
            return bestInteraction
        end
    end

    if stats then
        stats.pipelineV2MidDrawPressureNoInteractionCandidate = true
    end
    return best
end

local function applyEndgameSelection(ctx, accepted, best)
    local stats = ctx and ctx.stats or nil
    if not isEndgameRuntime(ctx) then
        return best
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_ENDGAME_FORCE_INTERACTION == false then
        if stats then
            stats.pipelineV2EndForceInteraction = false
        end
        return best
    end

    if stats then
        stats.pipelineV2EndForceInteraction = true
        stats.pipelineV2EndBestWasInteraction = candidateHasInteraction(best)
    end
    if candidateHasInteraction(best) then
        return best
    end

    local bestInteraction = nil
    for _, item in ipairs(accepted or {}) do
        if candidateHasInteraction(item)
            and (
                not bestInteraction
                or (ctx and ctx.score and ctx.score.isBetter
                    and ctx.score.isBetter(item.finalScore, bestInteraction.finalScore))
                or (not (ctx and ctx.score and ctx.score.isBetter)
                    and scoreTotal(item.finalScore) > scoreTotal(bestInteraction.finalScore))
            ) then
            bestInteraction = item
        end
    end

    if bestInteraction then
        if stats then
            stats.pipelineV2EndForcedInteraction = true
            stats.pipelineV2EndOriginalSignature =
                best and best.candidate and best.candidate.signature or nil
            stats.pipelineV2EndForcedSignature =
                bestInteraction.candidate and bestInteraction.candidate.signature or nil
        end
        bestInteraction.acceptReason = bestInteraction.acceptReason or "endgame_interaction_pressure"
        bestInteraction.finalAcceptReason = "endgame_interaction_pressure"
        return bestInteraction
    end

    if stats then
        stats.pipelineV2EndNoInteractionCandidate = true
    end
    return best
end

local function simulate(ai, state, ctx, candidate)
    if candidate and candidate._midAfterState then
        local after = candidate._midAfterState
        candidate._midAfterState = nil
        return after
    end
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, candidate.actions, ctx.aiPlayer, ctx)
    end
    return nil
end

local function annotateCandidate(ai, state, ctx, candidate, callbacks)
    if callbacks and callbacks.annotateCandidate then
        return callbacks.annotateCandidate(ai, state, ctx, candidate) or candidate
    end
    return candidate
end

local function basicCandidateKindOk(candidate)
    if not candidate then
        return false, "missing_candidate"
    end
    if candidate.containsAttack == true then
        local trade = candidate.midTrade
        if not (trade and trade.accepted == true) then
            return false, trade and trade.reason or "mid_best_attack_trade_rejected"
        end
        return true, nil
    end
    if candidate.tacticalTags and candidate.tacticalTags.midPosition == true then
        local position = candidate.midPosition
        if not (position and position.accepted == true) then
            return false, position and position.reason or "mid_best_position_rejected"
        end
        return true, nil
    end
    return false, "mid_best_unknown_candidate_kind"
end

local function setSkipped(stats, reason)
    if stats then
        stats.pipelineV2MidSkipped = true
        stats.pipelineV2MidSkippedReason = reason
        stats.pipelineV2MidFailedReason = reason
    end
    return {
        attempted = false,
        reason = reason
    }
end

local function materializeCandidate(ai, state, ctx, contracts, callbacks, candidate, rejectedReasons)
    if not (candidate and candidate.actions and #candidate.actions > 0) then
        bumpReason(rejectedReasons, "mid_missing_actions")
        return nil
    end
    local requiredActions = math.max(1, num(ctx and ctx.maxActions, 2))
    local endgameSingleAction = isEndgameRuntime(ctx)
        and candidate.tacticalTags
        and candidate.tacticalTags.endgameSingleAction == true
    if (#candidate.actions < requiredActions or candidate.completeTurn ~= true)
        and not endgameSingleAction then
        if ctx and ctx.stats then
            ctx.stats.pipelineV2MidIncompleteCandidates = num(ctx.stats.pipelineV2MidIncompleteCandidates, 0) + 1
        end
        bumpReason(rejectedReasons, "mid_incomplete_turn")
        return nil
    end

    if not exactSanitizerOk(ai, state, ctx, candidate, rejectedReasons) then
        return nil
    end

    candidate = annotateCandidate(ai, state, ctx, candidate, callbacks or {})
    local afterOur = simulate(ai, state, ctx, candidate)
    if not afterOur then
        bumpReason(rejectedReasons, "mid_simulation_failed")
        return nil
    end
    local basicOk, basicReason = basicCandidateKindOk(candidate)
    if not basicOk then
        bumpReason(rejectedReasons, basicReason)
        return nil
    end

    actionExposureGuard.analyze(ai, afterOur, ctx, candidate, {
        includeDeploy = true,
        phase = isEndgameRuntime(ctx) and "endgame" or "mid"
    })
    local finalScore = midScore.score(ai, state, ctx, candidate, {
        afterOur = afterOur
    })
    finalScore = softPressureScore.apply(ai, afterOur, ctx, contracts, candidate, finalScore)
    return {
        candidate = candidate,
        afterOur = afterOur,
        fastScore = finalScore,
        finalScore = finalScore,
        reply = {
            total = 0,
            riskPenalty = 0,
            summary = "mid_trade_model_reply"
        },
        source = "pipeline_v2_mid"
    }
end

local function evaluateGate(ai, state, ctx, contracts, item, rejectedReasons)
    local accepted, reason = midGate.check(ai, state, ctx, contracts, item, {})
    if not accepted then
        bumpReason(rejectedReasons, reason)
        if item then
            item.midGateRejectReason = reason
        end
        return false, reason
    end
    item.acceptReason = reason
    item.finalAcceptReason = reason
    return true, reason
end

local function recoverBestPrepared(ai, ctx, stats, prepared, reason)
    if not (ctx and stats and prepared and #prepared > 0) then
        return nil
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_MID_RETURN_BEST_ON_GATE_EMPTY == false then
        stats.pipelineV2MidBestRecoveryRejected = "disabled"
        return nil
    end

    sortByScore(ctx, prepared)
    for _, item in ipairs(prepared) do
        local candidate = item and item.candidate or nil
        local basicOk, basicReason = basicCandidateKindOk(candidate)
        if basicOk and item and item.afterOur then
            if ctx.evaluator and ctx.evaluator.isCommandantDead
                and ctx.evaluator.isCommandantDead(item.afterOur, ctx.aiPlayer) == true then
                stats.pipelineV2MidBestRecoveryRejected = "own_commandant_dead"
            else
                local recoveryReason = "mid_best_candidate_after_gate_empty"
                item.acceptReason = recoveryReason
                item.finalAcceptReason = recoveryReason
                item.midGateRecoveredRejectReason = item.midGateRejectReason

                stats.pipelineV2MidRecoveredBestCandidate = true
                stats.pipelineV2MidRecoveredFromReason = reason
                stats.pipelineV2MidRecoveredGateRejectReason = item.midGateRejectReason
                stats.pipelineV2MidSelectedSignature = candidate.signature
                stats.pipelineV2MidSelectedAcceptReason = recoveryReason
                stats.pipelineV2MidSelectedSource = candidate.source
                stats.pipelineV2MidSelectedTradeReason = candidate.midTrade and candidate.midTrade.reason or nil
                stats.pipelineV2MidSelectedDrawZeroDamageReset =
                    candidate.midTrade and candidate.midTrade.drawZeroDamageReset == true or false
                stats.pipelineV2MidSelectedAllowsZeroDamageDrawReset =
                    candidate.allowsZeroDamageDrawReset == true
                stats.pipelineV2MidSelectedScore = scoreTotal(item.finalScore)

                return {
                    attempted = true,
                    item = item,
                    reason = "pipeline_v2_mid_best_candidate_before_fail_closed",
                    recoveredFrom = reason
                }
            end
        else
            stats.pipelineV2MidBestRecoveryRejected = basicReason or "invalid_prepared_candidate"
        end
    end

    return nil
end

function M.run(ai, state, ctx, contracts, callbacks)
    local _callbacks = callbacks
    if not (ai and state and ctx and ctx.cfg) then
        return {
            attempted = false,
            reason = "missing_context"
        }
    end

    local stats = ctx.stats or {}
    local endRuntime = isEndgameRuntime(ctx)
    if endRuntime then
        stats.pipelineV2MidEnabled = ctx.cfg.PIPELINE_V2_ENDGAME_ENABLED == true
    else
        stats.pipelineV2MidEnabled = ctx.cfg.PIPELINE_V2_MID_ENABLED == true
    end

    if stats.pipelineV2MidEnabled ~= true then
        return setSkipped(stats, "disabled")
    end

    if not (ctx.phase and (ctx.phase.mid == true or endRuntime)) then
        return setSkipped(stats, "not_mid_phase")
    end

    if contracts and contracts.defenseActive == true then
        return setSkipped(stats, "hard_defense_contract")
    end

    stats.pipelineV2MidAttempted = true
    stats.pipelineV2MidSkipped = false
    stats.pipelineV2MidSkippedReason = nil
    stats.pipelineV2MidFailClosed = false
    ctx.pipelineV2MidRuntime = true

    ctx.beginStage("pipeline_v2_mid_position_map")
    local midMap = midPositionMap.build(ai, state, ctx, {})
    ctx.endStage("pipeline_v2_mid_position_map")
    ctx.midPositionMap = midMap

    ctx.beginStage("pipeline_v2_mid_personality")
    local midInterpretation = midPersonality.interpretMap(ai, state, ctx, midMap, {})
    ctx.endStage("pipeline_v2_mid_personality")
    ctx.midPersonality = midInterpretation

    local attackExtraMs = clampLimit(ctx.cfg.PIPELINE_V2_MID_ATTACK_EXTRA_MS or 0, 0, 5000)
    local attackBudget = nil
    if attackExtraMs > 0 then
        attackBudget = budgetScope.push(ctx, stats, {
            extraMs = attackExtraMs,
            extraKey = "pipelineV2MidAttackExtraMs",
            remainingKey = "pipelineV2MidRemainingBeforeAttackMs",
            startKey = "pipelineV2MidAttackStartElapsedMs",
            extendedKey = "pipelineV2MidAttackExtendedHardBudgetMs",
            localWindowKey = "pipelineV2MidAttackLocalWindowMs"
        })
    end
    ctx.beginStage("pipeline_v2_mid_attack_candidates")
    local attackCandidates = midAttackCandidates.generate(ai, state, ctx, midMap, midTradeModel, {})
    ctx.endStage("pipeline_v2_mid_attack_candidates")
    if attackBudget then
        attackBudget.pop()
    end

    local positionExtraMs = clampLimit(ctx.cfg.PIPELINE_V2_MID_POSITION_EXTRA_MS or 0, 0, 5000)
    local positionBudget = nil
    if positionExtraMs > 0 then
        positionBudget = budgetScope.push(ctx, stats, {
            extraMs = positionExtraMs,
            extraKey = "pipelineV2MidPositionExtraMs",
            remainingKey = "pipelineV2MidRemainingBeforePositionMs",
            startKey = "pipelineV2MidPositionStartElapsedMs",
            extendedKey = "pipelineV2MidPositionExtendedHardBudgetMs",
            localWindowKey = "pipelineV2MidPositionLocalWindowMs"
        })
    end
    ctx.beginStage("pipeline_v2_mid_position_candidates")
    local positionCandidates = midPositionCandidates.generate(ai, state, ctx, midMap, {})
    ctx.endStage("pipeline_v2_mid_position_candidates")
    if positionBudget then
        positionBudget.pop()
    end

    ctx.beginStage("pipeline_v2_mid_deploy_candidates")
    local deployCandidates = midDeployCandidates.generate(ai, state, ctx, midMap, {})
    ctx.endStage("pipeline_v2_mid_deploy_candidates")

    local legalFloorCandidates = nil
    local candidateCount = count(attackCandidates) + count(positionCandidates) + count(deployCandidates)
    stats.pipelineV2MidCandidates = candidateCount
    stats.pipelineV2MidAttackCandidates = count(attackCandidates)
    stats.pipelineV2MidPositionCandidates = count(positionCandidates)
    stats.pipelineV2MidDeployCandidates = count(deployCandidates)
    stats.pipelineV2MidRejectedReasons = {}

    if candidateCount <= 0 then
        legalFloorCandidates = buildLegalFloorCandidates(ai, state, ctx, midMap, "no_mid_candidates")
        candidateCount = count(legalFloorCandidates)
        stats.pipelineV2MidCandidates = candidateCount
        if candidateCount <= 0 then
            stats.pipelineV2MidFinalists = 0
            stats.pipelineV2MidFailedReason = "no_mid_candidates"
            stats.pipelineV2MidFellThroughToTournament = false
            stats.pipelineV2MidFailClosed = true

            return {
                attempted = true,
                reason = "no_mid_candidates",
                failClosed = true
            }
        end
    end

    local candidates = {}
    for _, candidate in ipairs(attackCandidates or {}) do
        candidates[#candidates + 1] = candidate
    end
    for _, candidate in ipairs(positionCandidates or {}) do
        candidates[#candidates + 1] = candidate
    end
    for _, candidate in ipairs(deployCandidates or {}) do
        candidates[#candidates + 1] = candidate
    end
    if legalFloorCandidates then
        for _, candidate in ipairs(legalFloorCandidates or {}) do
            candidates[#candidates + 1] = candidate
        end
    end

    local accepted = {}
    local prepared = {}
    local maxRanked = math.max(1, math.min(num(ctx.cfg.PIPELINE_V2_MID_MAX_RANKED, 8), #candidates))
    local gateExtraMs = clampLimit(ctx.cfg.PIPELINE_V2_MID_GATE_EXTRA_MS or 0, 0, 5000)
    local gateBudget = nil
    if gateExtraMs > 0 then
        gateBudget = budgetScope.push(ctx, stats, {
            extraMs = gateExtraMs,
            extraKey = "pipelineV2MidGateExtraMs",
            remainingKey = "pipelineV2MidRemainingBeforeGateMs",
            startKey = "pipelineV2MidGateStartElapsedMs",
            extendedKey = "pipelineV2MidGateExtendedHardBudgetMs",
            localWindowKey = "pipelineV2MidGateLocalWindowMs"
        })
    end

    ctx.beginStage("pipeline_v2_mid_gate")
    for _, candidate in ipairs(candidates) do
        if ctx.shouldStop and ctx.shouldStop() then
            stats.timeout = true
            break
        end
        stats.pipelineV2MidGateEvaluated = num(stats.pipelineV2MidGateEvaluated, 0) + 1
        local item = materializeCandidate(ai, state, ctx, contracts, callbacks, candidate, stats.pipelineV2MidRejectedReasons)
        if item then
            prepared[#prepared + 1] = item
        end
        local gateAccepted = item
            and evaluateGate(ai, state, ctx, contracts, item, stats.pipelineV2MidRejectedReasons)
            or false
        if gateAccepted then
            accepted[#accepted + 1] = item
        end
        if #accepted >= maxRanked then
            break
        end
    end
    ctx.endStage("pipeline_v2_mid_gate")
    if gateBudget then
        gateBudget.pop()
    end

    stats.pipelineV2MidPrepared = #prepared
    stats.pipelineV2MidAccepted = #accepted
    if #accepted == 0 then
        local failedReason = "pipeline_v2_mid_no_gate_valid_candidates"
        if stats.timeout == true and num(stats.pipelineV2MidGateEvaluated, 0) == 0 and #candidates > 0 then
            stats.pipelineV2MidGateSkippedByBudget = true
            failedReason = "pipeline_v2_mid_gate_skipped_by_budget"
        end

        local recovered = recoverBestPrepared(ai, ctx, stats, prepared, failedReason)
        if recovered then
            return recovered
        end

        local floorCandidates = buildLegalFloorCandidates(ai, state, ctx, midMap, failedReason)
        if #floorCandidates > 0 then
            stats.pipelineV2MidLegalFloorGateAttempted = true
            ctx.beginStage("pipeline_v2_mid_legal_floor_gate")
            for _, candidate in ipairs(floorCandidates) do
                if ctx.shouldStop and ctx.shouldStop() then
                    stats.timeout = true
                    break
                end
                stats.pipelineV2MidGateEvaluated = num(stats.pipelineV2MidGateEvaluated, 0) + 1
                local item = materializeCandidate(ai, state, ctx, contracts, callbacks, candidate, stats.pipelineV2MidRejectedReasons)
                if item then
                    prepared[#prepared + 1] = item
                end
                local gateAccepted = item
                    and evaluateGate(ai, state, ctx, contracts, item, stats.pipelineV2MidRejectedReasons)
                    or false
                if gateAccepted then
                    accepted[#accepted + 1] = item
                end
                if #accepted >= maxRanked then
                    break
                end
            end
            ctx.endStage("pipeline_v2_mid_legal_floor_gate")
            stats.pipelineV2MidPrepared = #prepared
            stats.pipelineV2MidAccepted = #accepted
        end

        if #accepted == 0 then
            local recoveredAfterFloor = recoverBestPrepared(ai, ctx, stats, prepared, failedReason)
            if recoveredAfterFloor then
                stats.pipelineV2MidRecoveredAfterLegalFloor = true
                return recoveredAfterFloor
            end

            stats.pipelineV2MidFinalists = 0
            stats.pipelineV2MidFailedReason = failedReason
            stats.pipelineV2MidFellThroughToTournament = false
            stats.pipelineV2MidFailClosed = true

            return {
                attempted = true,
                reason = failedReason,
                rejectedReasons = stats.pipelineV2MidRejectedReasons,
                failClosed = true
            }
        end
    end

    sortByScore(ctx, accepted)
    local maxFinalists = math.max(1, math.min(num(ctx.cfg.PIPELINE_V2_MID_MAX_FINALISTS, 4), #accepted))
    stats.pipelineV2MidFinalists = maxFinalists
    local best = accepted[1]
    for index = 2, maxFinalists do
        local item = accepted[index]
        if item and ctx.score and ctx.score.isBetter and ctx.score.isBetter(item.finalScore, best and best.finalScore) then
            best = item
        end
    end
    best = applyDrawPressureSelection(ai, state, ctx, accepted, best)
    best = applyEndgameSelection(ctx, accepted, best)

    if not best then
        stats.pipelineV2MidFailedReason = "pipeline_v2_mid_no_selection"
        stats.pipelineV2MidFellThroughToTournament = false
        stats.pipelineV2MidFailClosed = true
        return {
            attempted = true,
            reason = "pipeline_v2_mid_no_selection",
            failClosed = true
        }
    end

    stats.pipelineV2MidFellThroughToTournament = false
    stats.pipelineV2MidSelectedSignature = best.candidate and best.candidate.signature or nil
    stats.pipelineV2MidSelectedAcceptReason = best.finalAcceptReason or best.acceptReason
    stats.pipelineV2MidSelectedSource = best.candidate and best.candidate.source or nil
    stats.pipelineV2MidSelectedTradeReason = best.candidate
        and best.candidate.midTrade
        and best.candidate.midTrade.reason
        or nil
    stats.pipelineV2MidSelectedDrawZeroDamageReset = best.candidate
        and best.candidate.midTrade
        and best.candidate.midTrade.drawZeroDamageReset == true
        or false
    stats.pipelineV2MidSelectedAllowsZeroDamageDrawReset = best.candidate
        and best.candidate.allowsZeroDamageDrawReset == true
        or false
    stats.pipelineV2MidSelectedScore = scoreTotal(best.finalScore)

    return {
        attempted = true,
        item = best,
        reason = "pipeline_v2_mid_selected"
    }
end

return M
