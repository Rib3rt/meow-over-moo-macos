local punishMap = require("ai_tournament.punish_map")
local turnEnumerator = require("ai_tournament.turn_enumerator")
local midPositionSecondAction = require("ai_tournament.mid_position_second_action")
local movePatternPenalty = require("ai_tournament.move_pattern_penalty")
local budgetScope = require("ai_tournament.pipeline_v2_budget_scope")
local drawPressure = require("ai_tournament.draw_pressure")

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

local function pushPositionSecondBudget(ctx, stats)
    local extraMs = clampLimit(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_EXTRA_MS or 0, 0, 5000)
    if extraMs <= 0 then
        return nil
    end
    return budgetScope.push(ctx, stats, {
        extraMs = extraMs,
        extraKey = "pipelineV2MidPositionSecondExtraMs",
        remainingKey = "pipelineV2MidRemainingBeforePositionSecondMs",
        startKey = "pipelineV2MidPositionSecondStartElapsedMs",
        extendedKey = "pipelineV2MidPositionSecondExtendedHardBudgetMs",
        localWindowKey = "pipelineV2MidPositionSecondLocalWindowMs"
    })
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

local function bumpReason(map, reason)
    if not map then
        return
    end
    local key = tostring(reason or "unknown")
    map[key] = num(map[key], 0) + 1
end

local function endgameSingleActionAllowed(ctx)
    return ctx
        and ctx.pipelineV2EndRuntime == true
        and ctx.supply
        and ctx.supply.own
        and num(ctx.supply.own.count, 0) <= 0
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

local function collectMoveEntries(ai, state, ctx)
    local playerId = ctx and ctx.aiPlayer or state and state.currentPlayer or 1
    local raw = {}
    if ctx and ctx.turnEnumerator and ctx.turnEnumerator.collectTournamentActions then
        raw = ctx.turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = true,
            includeAttack = false,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    elseif ai and ai.collectLegalActions then
        raw = ai:collectLegalActions(state, {
            aiPlayer = playerId,
            includeMove = true,
            includeAttack = false,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    else
        raw = turnEnumerator.collectTournamentActions(ai, state, playerId, ctx, {
            includeMove = true,
            includeAttack = false,
            includeRepair = false,
            includeDeploy = false
        }) or {}
    end

    local entries = {}
    for _, rawEntry in ipairs(raw) do
        local entry = normalizeEntry(rawEntry)
        if entry and entry.action and entry.action.type == "move" then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function simulate(ai, state, ctx, actions)
    if ctx and ctx.cache and ctx.cache.simulate then
        return ctx.cache.simulate(ai, state, actions, ctx.aiPlayer, ctx)
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
        if unit and num(unit.row, -1) == row and num(unit.col, -1) == col then
            return unit
        end
    end
    return nil
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

local function manhattan(a, b)
    if not (a and b) then
        return nil
    end
    return math.abs(num(a.row, 0) - num(b.row, 0)) + math.abs(num(a.col, 0) - num(b.col, 0))
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

local function enemyAnchors(ai, state, playerId, enemyPlayer)
    local out = {}
    for _, unit in ipairs(state and state.units or {}) do
        if unit
            and unit.player == enemyPlayer
            and isAlive(unit)
            and not isHub(ai, unit)
            and not isObstacle(ai, unit) then
            out[#out + 1] = unit
        end
    end
    if #out == 0 then
        pushHub(out, state, enemyPlayer)
    end
    return out
end

local function closestEnemyDistance(ai, state, playerId, enemyPlayer, cell)
    if not (state and cell and playerId and enemyPlayer) then
        return nil
    end
    local best = nil
    for _, enemy in ipairs(enemyAnchors(ai, state, playerId, enemyPlayer)) do
        local distance = manhattan(cell, enemy)
        if distance and (best == nil or distance < best) then
            best = distance
        end
    end
    return best
end

local function drawActive(ai, state, ctx)
    if ctx and ctx.stats and ctx.stats.officialDrawUrgencyActive == true then
        return true
    end
    local draw = drawPressure.build(ai, state, ctx)
    return draw and draw.active == true
end

local function drawNoLegalCombat(ai, state, ctx)
    if not drawActive(ai, state, ctx) then
        return false
    end
    local stats = ctx and ctx.stats or {}
    if stats.pipelineV2MidMeaningfulInteractionCandidates ~= nil then
        return num(stats.pipelineV2MidMeaningfulInteractionCandidates, 0) <= 0
    end
    if stats.legalAttackActions == nil or stats.legalMoveAttackActions == nil then
        return false
    end
    return num(stats.legalAttackActions, 0) <= 0
        and num(stats.legalMoveAttackActions, 0) <= 0
end

local function drawWaveEnabled(ctx)
    return not (ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_WAVE_ENABLED == false)
end

local function drawWaveScale(ctx, draw)
    if not (drawWaveEnabled(ctx) and draw and draw.active == true and draw.pressureLimit == true) then
        return 1
    end
    local urgency = num(draw.urgency, 0)
    local ratio = num(draw.urgencyRatio, 0)
    return 1
        + urgency * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_WAVE_URGENCY_WEIGHT, 0.75)
        + ratio * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_WAVE_RATIO_WEIGHT, 1.25)
end

local function actionApproachProgress(ai, state, ctx, action)
    if not (action and action.unit and action.target) then
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
    local beforeDistance = closestEnemyDistance(ai, state, playerId, enemyPlayer, action.unit)
    local afterDistance = closestEnemyDistance(ai, state, playerId, enemyPlayer, action.target)
    if beforeDistance == nil or afterDistance == nil then
        return nil
    end
    return beforeDistance - afterDistance
end

local function drawApproachPreScore(ai, state, ctx, action)
    if not drawNoLegalCombat(ai, state, ctx) then
        return 0, nil
    end
    local progress = actionApproachProgress(ai, state, ctx, action)
    if not progress then
        return 0, nil
    end
    local draw = drawPressure.build(ai, state, ctx)
    local wave = drawWaveScale(ctx, draw)
    if progress > 0 then
        return progress * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_APPROACH_PRESCORE_BONUS, 450) * wave,
            progress
    end
    if progress == 0 then
        return -num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_STAGNATION_PRESCORE_PENALTY, 220) * wave,
            progress
    end
    return progress * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_RETREAT_PRESCORE_PENALTY, 420) * wave,
        progress
end

local function targetCell(ctx, midMap, action)
    local target = action and action.target
    if not target then
        return nil, nil, nil
    end
    local key = cellKey(target)
    local personalityCell = ctx
        and ctx.midPersonality
        and ctx.midPersonality.byKey
        and ctx.midPersonality.byKey[key]
        or nil
    local mapCell = midMap and midMap.byKey and midMap.byKey[key] or nil
    return personalityCell, mapCell, key
end

local function sourceCell(ctx, midMap, action)
    local unit = action and action.unit
    if not unit then
        return nil, nil, nil
    end
    local key = cellKey(unit)
    local personalityCell = ctx
        and ctx.midPersonality
        and ctx.midPersonality.byKey
        and ctx.midPersonality.byKey[key]
        or nil
    local mapCell = midMap and midMap.byKey and midMap.byKey[key] or nil
    return personalityCell, mapCell, key
end

local function exposureDamage(analysis)
    return num(analysis and analysis.enemyBestReply and analysis.enemyBestReply.damage, 0)
end

local function lethalExposure(analysis, unit)
    local damage = exposureDamage(analysis)
    return (analysis and analysis.enemyBestReply and analysis.enemyBestReply.lethal == true)
        or (damage > 0 and damage >= unitHp(unit))
end

local function useDynamicExposure(ctx)
    return ctx
        and ctx.cfg
        and ctx.cfg.PIPELINE_V2_MID_POSITION_DYNAMIC_EXPOSURE_ENABLED == true
end

local function mapExposure(personalityCell, mapCell, unit)
    local punish = mapCell and mapCell.enemyPunish or nil
    local damage = num(punish and punish.damage, 0)
    local lethal = (punish and punish.lethal == true)
        or (damage > 0 and unit and damage >= unitHp(unit))
    return {
        enemyBestReply = punish,
        covered = mapCell and mapCell.coveredIfOccupied == true,
        damage = damage,
        lethal = lethal,
        riskBand = personalityCell and personalityCell.riskBand or nil
    }
end

local function exposureIsLethal(analysis, unit, personalityCell, mapCell)
    if personalityCell and personalityCell.riskBand == "lethal_bad_trade" then
        return true
    end
    if mapCell and mapCell.enemyPunish and mapCell.enemyPunish.lethal == true then
        return true
    end
    return lethalExposure(analysis, unit)
end

local function targetPreScore(ai, state, ctx, midMap, entry, noLegalCombat)
    local personalityCell, mapCell = targetCell(ctx, midMap, entry and entry.action)
    local sourcePersonality = sourceCell(ctx, midMap, entry and entry.action)
    local targetValue = num(personalityCell and personalityCell.value, mapCell and mapCell.value or 0)
    local sourceValue = num(sourcePersonality and sourcePersonality.value, 0)
    local score = targetValue - math.max(0, sourceValue) * 0.25 + num(entry and entry.cheapScore, 0)
    if noLegalCombat then
        score = score + drawApproachPreScore(ai, state, ctx, entry and entry.action)
    end
    return score
end

local function minCellValue(ctx)
    local cfgValue = ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_MIN_CELL_VALUE
    if cfgValue ~= nil then
        return num(cfgValue, 45)
    end
    local threshold = ctx
        and ctx.midPersonality
        and ctx.midPersonality.profile
        and ctx.midPersonality.profile.thresholds
        and ctx.midPersonality.profile.thresholds.minCellValue
        or nil
    return num(threshold, 45)
end

local function minGain(ctx)
    return num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_MIN_GAIN, 15)
end

local function classifyTargetCell(personalityCell, mapCell)
    local status = tostring((personalityCell and personalityCell.status) or (mapCell and mapCell.status) or "other")
    if status == "blocked"
        or status == "own_commandant"
        or status == "enemy_commandant"
        or status == "enemy_occupied" then
        return false, "mid_position_bad_target_status"
    end
    if mapCell and mapCell.free == false then
        return false, "mid_position_target_not_free"
    end
    return true, nil
end

local function evaluateMove(ai, state, ctx, midMap, entry)
    local action = copyAction(entry and entry.action)
    if not (action and action.type == "move" and action.target) then
        return nil, "mid_position_missing_move"
    end

    local personalityCell, mapCell, targetKey = targetCell(ctx, midMap, action)
    local sourcePersonality, sourceMap, sourceKey = sourceCell(ctx, midMap, action)
    local okTarget, targetReason = classifyTargetCell(personalityCell, mapCell)
    if not okTarget then
        return nil, targetReason
    end
    if not (personalityCell or mapCell) then
        return nil, "mid_position_target_not_on_map"
    end

    local noLegalCombat = drawNoLegalCombat(ai, state, ctx)
    local approachPreScore, approachProgress = drawApproachPreScore(ai, state, ctx, action)
    local approachAllowed = noLegalCombat and approachProgress and approachProgress > 0
    local targetValue = num(personalityCell and personalityCell.value, mapCell and mapCell.value or 0)
    local sourceValue = num(sourcePersonality and sourcePersonality.value, sourceMap and sourceMap.value or 0)
    local pressureGain = targetValue - math.max(0, sourceValue) * 0.35
    if targetValue < minCellValue(ctx) and not approachAllowed then
        return nil, "mid_position_cell_below_threshold"
    end
    if pressureGain < minGain(ctx) and not approachAllowed then
        return nil, "mid_position_gain_too_low"
    end

    local afterMove = simulate(ai, state, ctx, {action})
    if not afterMove then
        return nil, "mid_position_simulation_failed"
    end
    local moved = getUnitAt(ai, afterMove, action.target.row, action.target.col)
    if not moved then
        return nil, "mid_position_missing_moved_unit"
    end

    local exposure = useDynamicExposure(ctx)
        and punishMap.analyzeCell(afterMove, ai, ctx, moved, moved)
        or mapExposure(personalityCell, mapCell, moved)
    local damage = exposureDamage(exposure)
    local lethal = exposure and exposureIsLethal(exposure, moved, personalityCell, mapCell) == true
    local coveredBonus = exposure and exposure.covered == true and 70 or 0
    local nonLethalPenalty = damage * num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_DAMAGE_PENALTY, 90)
    local lethalPenalty = lethal and num(ctx and ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DESTINATION_LETHAL_PENALTY, 70000) or 0
    local contestedBonus = (personalityCell and personalityCell.riskBand == "contested_ok") and 85 or 0
    local score = targetValue
        + pressureGain * 0.65
        + coveredBonus
        + contestedBonus
        + approachPreScore
        + num(entry and entry.cheapScore, 0) * 0.08
        - nonLethalPenalty
        - lethalPenalty
    score = movePatternPenalty.adjustScore(ai, state, ctx, action, score, ctx and ctx.stats)
    local reason = approachAllowed and "mid_position_draw_approach"
        or lethal and "mid_position_lethal_pressure"
        or (damage > 0 and "mid_position_nonlethal_pressure" or "mid_position_pressure")

    return {
        action = action,
        afterState = afterMove,
        score = score,
        targetKey = targetKey,
        sourceKey = sourceKey,
        targetValue = targetValue,
        sourceValue = sourceValue,
        pressureGain = pressureGain,
        exposureDamage = damage,
        covered = exposure and exposure.covered == true,
        lethalExposure = lethal,
        destinationExposurePenalty = lethalPenalty,
        drawApproachProgress = approachProgress,
        drawApproachPreScore = approachPreScore,
        drawNoLegalCombat = noLegalCombat == true,
        targetStatus = personalityCell and personalityCell.status or mapCell and mapCell.status,
        intent = personalityCell and personalityCell.intent or "position",
        riskBand = personalityCell and personalityCell.riskBand or "stable",
        reason = reason
    }, nil
end

local function makePrefix(ctx, evaluated)
    local action = evaluated.action
    local actions = movePatternPenalty.tagPositionMoves({action})
    return {
        actions = actions,
        signature = sequenceSignature(ctx, actions),
        source = "mid_v2_position",
        buckets = {"mid_position"},
        cheapScore = num(evaluated.score, 0),
        tacticalTags = {
            midV2 = true,
            midPosition = true,
            midTargetKey = evaluated.targetKey,
            midSourceKey = evaluated.sourceKey,
            midTargetStatus = evaluated.targetStatus,
            midTargetValue = evaluated.targetValue,
            midPositionReason = evaluated.reason,
            midPositionIntent = evaluated.intent,
            midPositionRiskBand = evaluated.riskBand,
            midDrawApproachProgress = evaluated.drawApproachProgress
        },
        containsDeploy = false,
        containsAttack = false,
        completeTurn = false,
        terminal = false,
        legalSkipReason = nil,
        midPosition = {
            accepted = true,
            class = "position",
            reason = evaluated.reason,
            score = evaluated.score,
            targetKey = evaluated.targetKey,
            sourceKey = evaluated.sourceKey,
            targetValue = evaluated.targetValue,
            sourceValue = evaluated.sourceValue,
            pressureGain = evaluated.pressureGain,
            exposureDamage = evaluated.exposureDamage,
            lethalExposure = evaluated.lethalExposure == true,
            destinationExposurePenalty = evaluated.destinationExposurePenalty,
            drawApproachProgress = evaluated.drawApproachProgress,
            drawApproachPreScore = evaluated.drawApproachPreScore,
            drawNoLegalCombat = evaluated.drawNoLegalCombat == true,
            covered = evaluated.covered,
            intent = evaluated.intent,
            riskBand = evaluated.riskBand
        },
        _midAfterState = evaluated.afterState
    }
end

local function compactCandidate(candidate)
    local position = candidate and candidate.midPosition or nil
    if not position then
        return nil
    end
    return table.concat({
        tostring(math.floor(num(candidate.cheapScore, 0))),
        tostring(position.reason or "none"),
        tostring(position.targetKey or "none"),
        tostring(position.exposureDamage or 0)
    }, ":")
end

function M.generate(ai, state, ctx, midMap, options)
    options = options or {}
    local stats = ctx and ctx.stats or nil
    if stats then
        stats.pipelineV2MidPositionCandidates = 0
        stats.pipelineV2MidPositionEvaluated = 0
        stats.pipelineV2MidPositionRejectedReasons = {}
        stats.pipelineV2MidPositionTop = {}
        stats.pipelineV2MidPositionPrefixesAccepted = 0
        stats.pipelineV2MidPositionPrefixesWithoutSecond = 0
    end

    if not (ai and state and ctx and midMap) then
        return {}
    end
    if ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_CANDIDATES_ENABLED == false then
        if stats then
            stats.pipelineV2MidPositionSkippedReason = "disabled"
        end
        return {}
    end

    local entries = collectMoveEntries(ai, state, ctx)
    if stats then
        stats.pipelineV2MidPositionLegalMoves = #entries
    end

    local noLegalCombat = drawNoLegalCombat(ai, state, ctx)
    table.sort(entries, function(a, b)
        local av = targetPreScore(ai, state, ctx, midMap, a, noLegalCombat)
        local bv = targetPreScore(ai, state, ctx, midMap, b, noLegalCombat)
        if av == bv then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return av > bv
    end)

    local scanCap = clampLimit(
        options.scanCap or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SCAN_CAP) or 6,
        1,
        80
    )
    if noLegalCombat then
        scanCap = math.max(
            scanCap,
            clampLimit(ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_APPROACH_SCAN_CAP or 48, 1, 80)
        )
        if stats then
            stats.pipelineV2MidDrawApproachNoLegalCombat = true
            stats.pipelineV2MidDrawApproachScanCap = scanCap
        end
    end
    local maxCandidates = clampLimit(
        options.maxCandidates or (ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_CANDIDATE_CAP) or 4,
        1,
        32
    )
    if noLegalCombat then
        maxCandidates = math.max(
            maxCandidates,
            clampLimit(ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_APPROACH_CANDIDATE_CAP or 12, 1, 32)
        )
    end

    local candidates = {}
    local seen = {}
    local scanned = 0

    for _, entry in ipairs(entries) do
        if scanned >= scanCap then
            break
        end
        if ctx.shouldStop and ctx.shouldStop() then
            if stats then
                stats.pipelineV2MidPositionStopped = true
            end
            break
        end
        scanned = scanned + 1

        local evaluated, rejectReason = evaluateMove(ai, state, ctx, midMap, entry)
        if stats then
            stats.pipelineV2MidPositionEvaluated = num(stats.pipelineV2MidPositionEvaluated, 0) + 1
        end

        if evaluated then
            if stats then
                stats.pipelineV2MidPositionPrefixesAccepted =
                    num(stats.pipelineV2MidPositionPrefixesAccepted, 0) + 1
            end
            local prefix = makePrefix(ctx, evaluated)
            local secondBudget = pushPositionSecondBudget(ctx, stats)
            local secondScanCap = ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_SCAN_CAP or nil
            local secondCompletionCap = ctx.cfg and ctx.cfg.PIPELINE_V2_MID_POSITION_SECOND_COMPLETION_CAP or nil
            if noLegalCombat then
                secondScanCap = math.max(
                    num(secondScanCap, 0),
                    num(ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_SECOND_SCAN_CAP, 10)
                )
                secondCompletionCap = math.max(
                    num(secondCompletionCap, 0),
                    num(ctx.cfg and ctx.cfg.PIPELINE_V2_MID_DRAW_SECOND_COMPLETION_CAP, 3)
                )
            end
            local completed = midPositionSecondAction.complete(ai, state, ctx, midMap, prefix, {
                scanCap = secondScanCap,
                maxCompletions = secondCompletionCap
            })
            if secondBudget then
                secondBudget.pop()
            end
            if #completed == 0 then
                if stats then
                    stats.pipelineV2MidPositionPrefixesWithoutSecond =
                        num(stats.pipelineV2MidPositionPrefixesWithoutSecond, 0) + 1
                end
                if endgameSingleActionAllowed(ctx) then
                    prefix.completeTurn = true
                    prefix.tacticalTags.endgameSingleAction = true
                    if not seen[prefix.signature] then
                        seen[prefix.signature] = true
                        candidates[#candidates + 1] = prefix
                    end
                    if stats then
                        stats.pipelineV2MidPositionEndgameSingleActionAccepted =
                            num(stats.pipelineV2MidPositionEndgameSingleActionAccepted, 0) + 1
                    end
                else
                    bumpReason(stats and stats.pipelineV2MidPositionRejectedReasons, "mid_position_no_second_action")
                end
            end
            for _, candidate in ipairs(completed) do
                local signature = tostring(candidate.signature or sequenceSignature(ctx, candidate.actions))
                if not seen[signature] then
                    seen[signature] = true
                    candidate.signature = signature
                    candidates[#candidates + 1] = candidate
                end
                if #candidates >= maxCandidates then
                    break
                end
            end
            if #candidates >= maxCandidates then
                break
            end
        elseif stats then
            bumpReason(stats.pipelineV2MidPositionRejectedReasons, rejectReason)
        end
    end

    table.sort(candidates, function(a, b)
        local av = num(a and a.cheapScore, 0)
        local bv = num(b and b.cheapScore, 0)
        if av == bv then
            return tostring(a and a.signature or "") < tostring(b and b.signature or "")
        end
        return av > bv
    end)

    if stats then
        stats.pipelineV2MidPositionScanned = scanned
        stats.pipelineV2MidPositionCandidates = #candidates
        for index, candidate in ipairs(candidates) do
            if index > 5 then
                break
            end
            stats.pipelineV2MidPositionTop[#stats.pipelineV2MidPositionTop + 1] = compactCandidate(candidate)
        end
    end

    return candidates
end

return M
